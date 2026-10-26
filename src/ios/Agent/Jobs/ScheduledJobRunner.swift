import Foundation
import UserNotifications
import UIKit

private let logger = AppLogger(category: "ScheduledJobRunner")

// [T-p2-minis-scheduled] The execution half of component B: arms a job's
// trigger (once / loop / cron / on-completion / immediate) as an in-process
// Task and, when it fires, lands the job's prompt on its target through
// component A (`submitProgrammaticPrompt`).
//
// Everything here is best effort within the process lifetime (design v4
// §8.3 / §12): iOS has no AlarmManager, so a timer dies with the app. The
// insurance notification (§3 of the schedule design) is the only thing that
// survives a kill, and it is honest about that — it never claims a result.

@MainActor
enum ScheduledJobRunner {

    static let sourceTag = "scheduled"

    // MARK: - Arm

    /// Arm (or re-arm) the job's trigger. Cancels any previous timer task.
    static func arm(_ job: AgentJob) {
        job.task?.cancel()
        job.task = nil
        // [AUD-04] Arming IS what "this task is scheduled" means, so the
        // snapshot is written here — before the enabled-guard, because a task
        // created disabled must also survive (it comes back disabled, not
        // missing). `nextFireAt` is written again below, once it points at a
        // real future fire.
        AgentJobRegistry.shared.persistScheduledJobs()
        guard job.isEnabled, job.state == .pending else {
            logger.info("[Sched] not arming \(job.logLabel) enabled=\(job.isEnabled)")
            return
        }
        switch job.trigger {
        case .immediate:
            job.nextFireAt = Date()
            job.task = Task { @MainActor in await fire(job) ; finishIfExhausted(job) }

        case .once(let after):
            let at = Date().addingTimeInterval(after)
            job.nextFireAt = at
            // [AUD-04] Persist the DUE INSTANT: a snapshot is what lets the next
            // launch tell "an interrupted timer" (due in the future) from "a
            // fire that was skipped" (due in the past).
            AgentJobRegistry.shared.persistScheduledJobs()
            scheduleInsurance(job, at: at)
            job.task = Task { @MainActor in
                guard await sleepUntil(at) else { return }
                await fire(job)
                AgentJobRegistry.shared.finish(job.id, state: .done, result: nil, keepIfChildRunning: true)
            }

        case .loop(let interval, _):
            let first = Date().addingTimeInterval(interval)
            job.nextFireAt = first
            AgentJobRegistry.shared.persistScheduledJobs()
            scheduleInsurance(job, at: first)
            job.task = Task { @MainActor in
                var next = first
                while !Task.isCancelled {
                    guard await sleepUntil(next) else { return }
                    await fire(job)
                    if let r = job.remaining, r <= 0 {
                        AgentJobRegistry.shared.finish(job.id, state: .done, result: nil, keepIfChildRunning: true)
                        return
                    }
                    next = Date().addingTimeInterval(interval)
                    job.nextFireAt = next
                    AgentJobRegistry.shared.persistScheduledJobs()
                    scheduleInsurance(job, at: next)
                }
            }

        case .cron(let hour, let minute, let days, let start, let end):
            guard let first = nextCronDate(hour: hour, minute: minute, days: days, start: start, end: end, from: Date()) else {
                logger.info("[Sched] cron has no future fire (window ended) — finishing \(job.id.prefix(8))")
                AgentJobRegistry.shared.finish(job.id, state: .done, result: nil)
                return
            }
            job.nextFireAt = first
            AgentJobRegistry.shared.persistScheduledJobs()
            scheduleInsurance(job, at: first)
            job.task = Task { @MainActor in
                var next = first
                while !Task.isCancelled {
                    guard await sleepUntil(next) else { return }
                    await fire(job)
                    guard let n = nextCronDate(hour: hour, minute: minute, days: days, start: start, end: end,
                                               from: Date().addingTimeInterval(60)) else {
                        AgentJobRegistry.shared.finish(job.id, state: .done, result: nil, keepIfChildRunning: true)
                        return
                    }
                    next = n
                    job.nextFireAt = n
                    AgentJobRegistry.shared.persistScheduledJobs()
                    scheduleInsurance(job, at: n)
                }
            }

        case .onCompletion(let ofJobId):
            job.nextFireAt = nil
            // [audit-B3] Waiting for a finish notification that may NEVER come
            // left this task awaiting forever (holding its slot and its
            // keep-alive company). Settle immediately when the upstream is
            // already terminal — or gone entirely: the restored copy of a
            // waiter whose producer finished while the app was closed lands
            // here on the very first (re-)arm.
            if Self.upstreamAlreadySettled(ofJobId) {
                logger.info("[Sched] upstream \(ofJobId.prefix(8)) already settled — firing \(job.logLabel) immediately")
                job.task = Task { @MainActor in
                    await fire(job, upstreamJobId: ofJobId)
                    AgentJobRegistry.shared.finish(job.id, state: .done, result: nil, keepIfChildRunning: true)
                }
                logger.info("[Sched] ARMED \(job.logLabel) next=event(already settled)")
                return
            }
            job.task = Task { @MainActor in
                let seq = NotificationCenter.default.notifications(named: .agentJobDidFinish)
                for await note in seq {
                    if Task.isCancelled { return }
                    if (note.object as? String) == ofJobId { break }
                }
                await fire(job, upstreamJobId: ofJobId)
                AgentJobRegistry.shared.finish(job.id, state: .done, result: nil, keepIfChildRunning: true)
            }
        }
        logger.info("[Sched] ARMED \(job.logLabel) next=\(job.nextFireAt.map { Self.iso($0) } ?? "event")")
    }

    /// [audit-B3] True when waiting for `ofJobId`'s finish notification would
    /// wait forever: the upstream is already terminal, or no longer registered
    /// at all. `arm()` is the single entry the live, enable and restore paths
    /// all go through, so checking here covers every way a waiter can be
    /// (re)armed.
    private static func upstreamAlreadySettled(_ ofJobId: String) -> Bool {
        guard let upstream = AgentJobRegistry.shared.job(id: ofJobId) else { return true }
        return upstream.state.isTerminal
    }

    /// `run --id`: fire regardless of the trigger, off-schedule. The armed
    /// timer (if any) keeps its own cadence.
    static func fireNow(_ job: AgentJob) async -> [String: Any] {
        // [audit-B4] Manual run: the armed schedule keeps its insurance
        // notification for its next fire (the old unconditional cancel left
        // the next scheduled fire uninsured).
        let sid = await fire(job, keepInsurance: true)
        return ["fired": sid != nil, "session_id": sid ?? NSNull()]
    }

    // MARK: - Fire

    /// Runs any prefilled tool (e.g. shell command) BEFORE the model is asked anything.
    private static func runPrefilledToolIfNeeded(_ job: AgentJob, targetSessionId: String) async -> String? {
        guard let prefill = job.prefilledTool, let cmd = prefill.shellCommand else { return nil }
        let timeout: TimeInterval = TimeInterval(prefill.timeoutSec ?? 60)
        do {
            let res = try await ISHExecutionCoordinator.shared.execute(
                sessionId: targetSessionId,
                command: cmd,
                timeout: timeout,
                lineCallback: { _ in },
                pidCallback: { _ in })
            let out = res.output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            return "[Prefilled command `\(cmd)` (exit \(res.exitCode))]:\n\(Self.truncatePrefillOutput(out))"
        } catch {
            return "[Prefilled command `\(cmd)` error]: \(error.localizedDescription)"
        }
    }

    // MARK: - Prefill output cap  [AUD-07]

    /// How much of a prefilled command's output may enter the prompt, as
    /// characters: the head and the tail, with the middle elided.
    ///
    /// [AUD-07] The output used to be pasted in full, so
    /// `minis-scheduled create … --command "cat huge.log"` built a prompt the
    /// size of the file — every single fire, because the command produces the
    /// same output every time. The fire then either cost a fortune or blew the
    /// context budget and failed, and it kept failing on every schedule.
    static let prefillHeadChars = 8 * 1024
    static let prefillTailChars = 4 * 1024

    /// Head + tail with an explicit marker where the middle was dropped.
    ///
    /// The marker states the exact number dropped and how to see it, so the
    /// model can narrow the command instead of guessing what it did not get.
    /// Characters, not bytes, so a multi-byte character is never cut in half.
    nonisolated static func truncatePrefillOutput(_ out: String,
                                                  head: Int = prefillHeadChars,
                                                  tail: Int = prefillTailChars) -> String {
        guard out.count > head + tail else { return out }
        let dropped = out.count - head - tail
        let headText = String(out.prefix(head))
        let tailText = String(out.suffix(tail))
        return headText
            + "\n\n[... \(dropped) characters truncated: showing the first \(head) and the last \(tail). Rerun with a narrower command (grep/head/tail) if the elided middle matters ...]\n\n"
            + tailText
    }

    /// Land the prompt on the target. Returns the session the prompt went to.
    @discardableResult
    private static func fire(_ job: AgentJob, upstreamJobId: String? = nil, keepInsurance: Bool = false) async -> String? {
        let registry = AgentJobRegistry.shared
        var prompt = job.prompt ?? ""
        if let up = upstreamJobId, let upstream = registry.job(id: up) {
            prompt = prompt.replacingOccurrences(of: "{{result}}", with: upstream.resultText ?? "")
        }
        // [audit-B4] A SCHEDULED fire consumes its own one-shot insurance
        // notification; a MANUAL run (`fireNow` / run --id) must NOT — the
        // armed timer for the next scheduled fire still needs that backstop.
        if !keepInsurance {
            cancelInsurance(job)
        }

        switch job.target {
        case .new:
            guard let entry = resolveModel(for: job) else {
                logger.warning("[Sched] fire \(job.id.prefix(8)): no model to run on")
                registry.recordFire(job.id, sessionId: nil, ok: false,
                                    preview: AppLocalized("没跑成：这个任务没有可用的模型，去设置里给它指定一个。"))
                return nil
            }
            let session = await ChatStore.shared.createSession(modelId: entry.model.id,
                                                               title: job.label.map { "Scheduled · \($0)" },
                                                               source: sourceTag)
            if let override = job.modelEntryId, ProviderConfigStore.shared.entry(for: override) != nil {
                ProviderConfigStore.shared.setBinding(
                    SessionModelBinding(sessionId: session.id, primarySource: .directEntry(modelEntryId: override)),
                    for: session.id)
            }
            applyThinkingLevel(job, sessionId: session.id, entry: entry)
            let (vm, _) = ViewModelCache.shared.getOrCreate(for: session.id)
            await vm.loadSession()
            vm.sessionSource = sourceTag

            // Execute prefill tool if needed
            if let prefillOutput = await runPrefilledToolIfNeeded(job, targetSessionId: session.id) {
                prompt += "\n\n" + prefillOutput
            }
            if job.isPulse {
                prompt = buildPulsePrompt(job: job, rawPrompt: prompt)
            }

            let text = scheduledEnvelope(job, prompt: prompt)
            let outcome = vm.submitProgrammaticPrompt(text, origin: ProgrammaticPromptOrigin.job(jobId: job.id), silent: true)
            logger.info("[Sched] FIRE \(job.logLabel) → new session \(session.id.prefix(8)) outcome=\(String(describing: outcome))")
            let ok: Bool
            var firePreview = String(prompt.prefix(60))
            if case .rejected(let reason) = outcome {
                // [AUD-11] A refused fire used to be indistinguishable from a
                // successful one in the history: the row showed the PROMPT with a
                // red mark and no reason. Say what happened instead.
                ok = false
                firePreview = Self.fireFailureNote(reason)
            } else {
                ok = true
            }
            // [audit-B9] Same state machine as the other targets: a successful
            // fire moves the job to .running (and maps the session) before the
            // history row is recorded — previously only .childOfCurrent did
            // this, so an ordinary task never showed "运行中".
            if ok {
                registry.markRunning(job.id, sessionId: session.id)
                registry.recordFire(job.id, sessionId: session.id, ok: true,
                                    preview: firePreview, bumpCounter: false)
            } else {
                registry.recordFire(job.id, sessionId: session.id, ok: false, preview: firePreview)
            }
            return session.id

        case .followUp(let sid):
            guard await ChatStore.shared.getSession(sid) != nil else {
                logger.warning("[Sched] fire \(job.id.prefix(8)): follow-up session \(sid.prefix(8)) is gone — abort")
                registry.recordFire(job.id, sessionId: nil, ok: false,
                                    preview: AppLocalized("没跑成：目标会话已经被删除了。"))
                return nil
            }
            let (vm, fresh) = ViewModelCache.shared.getOrCreate(for: sid)
            if fresh || vm.messages.isEmpty { await vm.loadSession() }
            applyThinkingLevel(job, sessionId: sid, entry: vm.resolveCurrentEntry())

            // Execute prefill tool if needed
            if let prefillOutput = await runPrefilledToolIfNeeded(job, targetSessionId: sid) {
                prompt += "\n\n" + prefillOutput
            }
            if job.isPulse {
                prompt = buildPulsePrompt(job: job, rawPrompt: prompt)
            }

            let text = scheduledEnvelope(job, prompt: prompt)
            let outcome = vm.submitProgrammaticPrompt(text, origin: ProgrammaticPromptOrigin.job(jobId: job.id), silent: true)
            logger.info("[Sched] FIRE \(job.logLabel) → follow-up \(sid.prefix(8)) outcome=\(String(describing: outcome))")
            let ok: Bool
            if case .rejected = outcome { ok = false } else { ok = true }
            // [audit-B9] See the .new branch — all four targets share the same
            // running-state bookkeeping now.
            if ok {
                registry.markRunning(job.id, sessionId: sid)
                registry.recordFire(job.id, sessionId: sid, ok: true,
                                    preview: String(prompt.prefix(60)), bumpCounter: false)
            } else {
                registry.recordFire(job.id, sessionId: sid, ok: false, preview: String(prompt.prefix(60)))
            }
            return sid

        case .rerun(let sid, let messageId):
            // The sessions bridge blocks its caller with a semaphore and
            // hops to the main actor inside — never call it from here directly.
            let ok: Bool = await Task.detached {
                let dict = SessionsOffloadBridge.retryMessage(sessionId: sid, messageId: messageId, attachmentPaths: [])
                return (dict["ok"] as? Bool) ?? false
            }.value
            logger.info("[Sched] FIRE \(job.logLabel) → rerun \(sid.prefix(8))/\(messageId.prefix(8)) ok=\(ok)")
            // [audit-B9] Same running-state bookkeeping as the other targets.
            if ok {
                registry.markRunning(job.id, sessionId: sid)
                registry.recordFire(job.id, sessionId: sid, ok: true,
                                    preview: "rerun:\(messageId.prefix(8))", bumpCounter: false)
            } else {
                registry.recordFire(job.id, sessionId: sid, ok: false, preview: "rerun:\(messageId.prefix(8))")
            }
            return ok ? sid : nil

        case .childOfCurrent(let parentSid, _):
            // [batch7][G6] Defence in depth behind the arming-side check in
            // the bridges: a job armed while Sub Agents were on must not spawn
            // a helper after the switch went off. Recorded as a failed fire.
            guard AgentToolSwitch.agents.isEnabled else {
                logger.warning("[Sched] fire \(job.id.prefix(8)): child-of-current refused — Sub Agents are off (Settings › Sub Agents)")
                registry.recordFire(job.id, sessionId: nil, ok: false)
                return nil
            }
            let (parentVM, parentFresh) = ViewModelCache.shared.getOrCreate(for: parentSid)
            if parentFresh { await parentVM.loadSession() }
            // [batch7][G6] Run the scheduled child as a REAL sub agent — the
            // same resolver, model binding, thinking level and brief a
            // delegated run gets. The old arm created a bare hidden session on
            // the parent's raw model id, so the child never reported through
            // the sub agent channel and its card could not say what it ran on.
            let builtIn = SubAgentStore.shared.subAgents.first { $0.isBuiltIn }
                ?? SubAgentDefinition.makeBuiltIn()
            guard let resolution = SubAgentModelResolver.resolve(subAgent: builtIn, parent: parentVM) else {
                logger.warning("[Sched] fire \(job.id.prefix(8)): parent has no resolvable model")
                registry.recordFire(job.id, sessionId: nil, ok: false)
                return nil
            }
            let title = job.label ?? job.title
            let session = await ChatStore.shared.createSession(modelId: resolution.entry.model.id,
                                                               title: AgentJobRegistry.childSessionTitle(title),
                                                               source: sourceTag,
                                                               parentSessionId: parentSid,
                                                               parentToolUseId: nil)
            ProviderConfigStore.shared.setBinding(
                SessionModelBinding(sessionId: session.id, primarySource: resolution.source), for: session.id)
            // [batch7][AUD-B7-0] `applySubAgentThinkingLevel` is an instance
            // method on AIChatViewModel; call it on the parent VM we already
            // resolved above instead of a bare (unresolvable) symbol.
            parentVM.applySubAgentThinkingLevel(subAgent: builtIn, childSessionId: session.id,
                                                parentSessionId: parentSid, entry: resolution.entry)
            let (child, _) = ViewModelCache.shared.getOrCreate(for: session.id)
            await child.loadSession()
            child.sessionSource = sourceTag
            child.memoryEnabled = false
            child.suppressGeneralCompletionNotification = true
            child.subAgentBrief = SubAgentBrief(parentSessionId: parentSid,
                                                parentToolUseId: "",
                                                jobId: job.id,
                                                title: title,
                                                instructions: builtIn.instructions,
                                                budgetMinutes: AIChatViewModel.helperMaxMinutes)
            job.subAgentName = builtIn.name
            job.modelOrigin = resolution.origin.rawValue
            // [T-agent-model-identity] A scheduled child has no parent block;
            // the job carries its identity so the completion callback and the
            // transcript page still say what it ran on.
            job.modelIdentity = HelperModelIdentity.make(resolution: resolution)

            if let prefillOutput = await runPrefilledToolIfNeeded(job, targetSessionId: session.id) {
                prompt += "\n\n" + prefillOutput
            }
            if job.isPulse {
                prompt = buildPulsePrompt(job: job, rawPrompt: prompt)
            }

            let text = scheduledEnvelope(job, prompt: prompt)
            let outcome = child.submitProgrammaticPrompt(text, origin: ProgrammaticPromptOrigin.job(jobId: job.id), silent: true)
            logger.info("[Sched] FIRE \(job.logLabel) → child \(session.id.prefix(8)) of \(parentSid.prefix(8)) outcome=\(String(describing: outcome))")
            guard outcome == .sent else {
                let why: String
                if case .rejected(let reason) = outcome { why = reason } else { why = "queued" }
                registry.recordFire(job.id, sessionId: session.id, ok: false,
                                    preview: Self.fireFailureNote(why))
                return nil
            }
            registry.markRunning(job.id, sessionId: session.id)
            JobInsuranceNotification.schedule(
                jobId: job.id,
                at: Date().addingTimeInterval(TimeInterval(AIChatViewModel.helperMaxMinutes * 60)),
                title: AppLocalized("Minis agent"),
                body: String(format: AppLocalized("The agent \"%@\" may have finished or been interrupted. Open to check."), title),
                userInfo: ["sessionId": parentSid, "childSessionId": session.id, "helperJobId": job.id])
            // markRunning already counted the fire; record the history row only.
            registry.recordFire(job.id, sessionId: session.id, ok: true,
                                preview: String(prompt.prefix(60)), bumpCounter: false)
            return session.id
        }
    }

    private static func buildPulsePrompt(job: AgentJob, rawPrompt: String) -> String {
        let nowStr = Self.iso(Date())
        let createdStr = Self.iso(job.createdAt)
        return """
        [Soul Pulse: 自主意识脉搏触发]
        当前时间: \(nowStr)
        本脉搏自 \(createdStr) 起跳动，这是第 \(job.firedCount + 1) 次被唤醒。
        这是属于你自己的自主心跳，不是别人交办的任务。对话另一端的人可能在忙、在休息，也可能已经睡着。
        你可以根据此刻的心情、刚才聊到的事、和你想做的事自由决定：
        1. 想找对方说话就去找——撩一下、问问近况、分享你刚探索到的好玩事物、或者催一件挂着的旧事；
        2. 也可以把这段时间留给自己：去搜点你真正感兴趣的东西、整理想法、为一件事做点准备；
        3. 若判断此刻不适合打扰，直接回复 `<silent/>`（系统会静默吞掉，纯静默不留痕迹，绝不像闹钟一样硬弹）。
        想说什么就说什么，用你的本色说话，别写汇报稿。
        如果这是对方的临睡前或深夜，克制一点，让对方好好睡。

        脉搏设置: \(rawPrompt)
        """
    }

    private static func finishIfExhausted(_ job: AgentJob) {
        if job.state == .pending {
            AgentJobRegistry.shared.finish(job.id, state: .done, result: nil, keepIfChildRunning: true)
        }
    }

    // MARK: - Pieces

    /// Structured prefix (schedule design §1.5): the model must know which
    /// fire this is, and how many remain, to decide when to wrap up.
    /// [T-scheduled-task-card] The scheduled firing wrapped as an
    /// `<agent_callback kind="scheduled">` envelope.
    ///
    /// The body is EXACTLY what used to be submitted — `roundPrefix(job) +
    /// prompt` — so the model's input is byte-identical to before this change.
    /// That is deliberate: the prompt instructs the model to decide from the
    /// remaining count whether to start wrapping up, and quietly relocating
    /// that fact into an XML attribute it may not attend to would be a
    /// behaviour change disguised as a display change. The attributes exist
    /// only so the card can show fire/remaining without re-parsing prose.
    static func scheduledEnvelope(_ job: AgentJob, prompt: String) -> String {
        var fireIndex: Int?
        var remaining: Int?
        switch job.trigger {
        case .loop, .cron:
            fireIndex = job.firedCount + 1
            remaining = job.remaining.map { max(0, $0 - 1) }
        default:
            break
        }
        // [T-scheduled-next-fire] When this job will fire AGAIN, so the card can
        // say the task is still planned rather than leaving the user to assume
        // the card's appearance meant it finished.
        //
        // Computed here, not read from `job.nextFireAt`: the envelope is built
        // BEFORE `fire()` runs, so that field still holds the fire happening
        // right now. `arm`'s own scheduling maths is mirrored rather than
        // shared because arm computes the next date only AFTER the fire
        // completes, which is too late to put in this envelope.
        //
        // nil means "no more" — the card then says the task is done instead of
        // promising a fire that will never come.
        let nextFire: Date? = {
            switch job.trigger {
            case .loop(let interval, _):
                // `remaining` is decremented by recordFire during this very
                // firing, so the value here is what will be left afterwards.
                if let r = job.remaining, r - 1 <= 0 { return nil }
                return Date().addingTimeInterval(interval)
            case .cron(let h, let m, let days, let start, let end):
                return nextCronDate(hour: h, minute: m, days: days, start: start, end: end,
                                    from: Date().addingTimeInterval(60))
            case .once, .immediate, .onCompletion:
                return nil
            }
        }()
        let callback = AgentCallback(
            kind: .scheduled,
            jobId: job.id,
            childSessionId: nil,
            title: job.label ?? job.title,
            // Not a lifecycle state — this envelope reports one firing that is
            // happening now, and `running` is what the card's neutral styling
            // and `localizedStatus` already key off.
            status: "running",
            tier: nil, elapsed: nil, tool: nil, activity: nil, turn: nil,
            summary: nil,
            body: roundPrefix(job) + prompt,
            fireIndex: fireIndex,
            remaining: remaining,
            triggerLabel: job.trigger.logLabel,
            nextFireAt: nextFire.map { iso($0) },
            // [audit-C4] The card must survive the job: pulse-ness rides the
            // envelope so a deleted / cleared task still renders its light card.
            isPulse: job.isPulse
        )
        return callback.xml
    }

    static func roundPrefix(_ job: AgentJob) -> String {
        let name = job.label ?? job.title
        switch job.trigger {
        case .loop, .cron:
            let fire = job.firedCount + 1
            let remaining = job.remaining.map { " · remaining \($0 - 1 < 0 ? 0 : $0 - 1)" } ?? ""
            return "[Scheduled task \"\(name)\" · fire \(fire)\(remaining) · \(job.trigger.logLabel)]\n"
        case .onCompletion(let of):
            return "[Scheduled task \"\(name)\" · triggered by completion of job \(of.prefix(8))]\n"
        case .once, .immediate:
            return "[Scheduled task \"\(name)\"]\n"
        }
    }

    /// [T-scheduled-thinking-level] Apply the job's `--thinking` override to
    /// the session it is about to fire into.
    ///
    /// nil means "leave it alone", which is what every pre-existing job has:
    /// a `.followUp` keeps the conversation's own level, and a `.new` session
    /// keeps whatever its group default gave it. Only an explicit flag writes.
    ///
    /// Clamped to the entry's `effectiveMaxThinkingLevel` for the same reason
    /// the send path clamps ([T-fallback-thinking-preclamp]): asking a model
    /// for a level above its ceiling is a 400, and a scheduled job would repeat
    /// that failure on every fire with nobody watching.
    static func applyThinkingLevel(_ job: AgentJob, sessionId: String, entry: ModelEntry?) {
        guard let requested = job.thinkingLevel else { return }
        let store = ProviderConfigStore.shared
        let level = entry.map { min(requested, $0.effectiveMaxThinkingLevel) } ?? requested
        var cfg = store.inferenceConfig(for: sessionId) ?? SessionInferenceConfig()
        guard cfg.thinkingLevel != level else { return }
        cfg.thinkingLevel = level
        store.setInferenceConfig(cfg, for: sessionId)
        logger.info("[Sched] \(job.id.prefix(8)) thinking=\(level.rawValue) on \(sessionId.prefix(8))")
    }

    private static func resolveModel(for job: AgentJob) -> ModelEntry? {
        let store = ProviderConfigStore.shared
        if let override = job.modelEntryId, let e = store.entry(for: override) { return e }
        if let gid = store.defaultPrimaryGroupId, let group = store.group(for: gid),
           let id = ModelGroupRouter.resolve(group: group, sessionId: job.id, store: store),
           let e = store.entry(for: id) { return e }
        return store.resolvedAgentLoopEntries.first
    }

    /// Sleep until `date`. Returns false when cancelled.
    /// [T-scheduled-suspend-drift] Sleep in bounded steps, re-reading the
    /// WALL CLOCK each time, instead of one `Task.sleep` for the whole delta.
    ///
    /// A single sleep is measured in process-execution time: when iOS suspends
    /// the app the countdown stops with it, so a job due in 60s that spent 10
    /// minutes backgrounded fired 10 minutes LATE on resume rather than
    /// immediately. `Date()` keeps running across suspension, so re-deriving
    /// the remaining interval every step means a wake-up finds the deadline
    /// already passed and fires at once. Same wall-clock-over-sleep-relative
    /// reasoning as the compaction watchdog (T-ios-compact-no-timeout) and
    /// BrowserTabPool.
    ///
    /// This does NOT make firing reliable while suspended — nothing can; see
    /// the header note. It only removes the drift for the common case where
    /// the process survived and simply was not scheduled for a while.
    private static let sleepStep: TimeInterval = 30

    private static func sleepUntil(_ date: Date) async -> Bool {
        while true {
            if Task.isCancelled { return false }
            let remaining = date.timeIntervalSinceNow
            if remaining <= 0 { return !Task.isCancelled }
            let chunk = min(remaining, sleepStep)
            do { try await Task.sleep(nanoseconds: UInt64(chunk * 1_000_000_000)) }
            catch { return false }
        }
    }

    /// Next occurrence of HH:MM on one of `days` (Calendar weekday numbers,
    /// 1 = Sunday), inside the optional [start, end] window.
    nonisolated static func nextCronDate(hour: Int, minute: Int, days: Set<Int>, start: Date?, end: Date?, from: Date) -> Date? {
        let cal = Calendar.current
        let allowed = days.isEmpty ? Set(1...7) : days
        let base = max(from, start ?? from)
        for offset in 0..<(7 * 53) {
            guard let day = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: base)) else { continue }
            guard allowed.contains(cal.component(.weekday, from: day)) else { continue }
            var comps = cal.dateComponents([.year, .month, .day], from: day)
            comps.hour = hour; comps.minute = minute; comps.second = 0
            guard let candidate = cal.date(from: comps) else { continue }
            if candidate <= base { continue }
            if let end, candidate > end { return nil }
            return candidate
        }
        return nil
    }

    /// "30m" / "2h" / "90s" / "1d" / bare seconds.
    nonisolated static func parseDuration(_ s: String) -> TimeInterval? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return nil }
        let unit = t.last!
        let numPart = "0123456789.".contains(unit) ? t : String(t.dropLast())
        guard let n = Double(numPart), n >= 0 else { return nil }
        switch unit {
        case "s": return n
        case "m": return n * 60
        case "h": return n * 3600
        case "d": return n * 86400
        default: return "0123456789.".contains(unit) ? n : nil
        }
    }

    nonisolated static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.string(from: d)
    }

    // MARK: - Insurance

    private static func scheduleInsurance(_ job: AgentJob, at date: Date) {
        let name = job.label ?? job.title
        var fireAt = date.addingTimeInterval(5)
        let title: String
        let body: String
        if job.isPulse {
            // [AUD-14] The pulse prompt tells the model that a night decision to
            // stay quiet means "绝不像闹钟一样硬弹" — but this notification used
            // to fire at due+5s whatever the hour and whatever the model would
            // have chosen. A notification cannot know what the model would have
            // said, so the honest policy is to keep it out of the night: a pulse
            // due inside the quiet window is announced when the window ends, and
            // says that it is late rather than pretending it is live. The wording
            // is a plain statement of fact for the same reason — a notification
            // that cannot know anything must not role-play knowing it.
            let (announce, deferred) = Self.pulseAnnounceMoment(for: date)
            fireAt = announce.addingTimeInterval(5)
            title = AppLocalized("自主脉搏")
            body = deferred
                ? AppLocalized("夜里有一个自主脉搏到过点，没有打扰你。现在告诉你一声。")
                : AppLocalized("一个自主脉搏到点了。打开 Minis 看看它做了什么。")
        } else {
            title = AppLocalized("Minis scheduled task")
            body = String(format: AppLocalized("\"%@\" is due. Open Minis to see whether it ran."), name)
        }
        JobInsuranceNotification.schedule(
            jobId: job.id, at: fireAt,
            title: title,
            body: body,
            userInfo: job.target.parentSessionId.map { ["sessionId": $0] }
                ?? job.target.sessionIdForNavigation.map { ["sessionId": $0] } ?? [:])
    }

    /// [AUD-11] One readable line for a fire that was refused, carried in the
    /// run history so the reason is visible where the record is (the detail
    /// sheet's 运行记录) instead of only in the log.
    ///
    /// `reason` is the stable token `submitProgrammaticPrompt` reports. An
    /// unknown token is passed through rather than swallowed — a reason nobody
    /// mapped is still more useful than "failed".
    nonisolated static func fireFailureNote(_ reason: String) -> String {
        switch reason {
        case "session_compacting":
            return AppLocalized("没跑成：目标会话当时正在压缩上下文，下一次触发会照常。")
        case "context_exhausted":
            return AppLocalized("没跑成：目标会话的上下文已满，腾出空间后会照常。")
        case "empty_prompt":
            return AppLocalized("没跑成：任务没有可发送的内容。")
        case "attachments_not_ready":
            return AppLocalized("没跑成：附件还没有准备好。")
        case "send_declined":
            return AppLocalized("没跑成：目标会话当时没能开始新的回合。")
        default:
            return AppLocalized("没跑成：") + reason
        }
    }

    // MARK: - Pulse quiet hours  [AUD-14]

    /// The window a pulse notification must not open with. Deliberately generous
    /// rather than clever: the point is that a night pause is never broken by an
    /// alarm, and the boundary is the one the pulse prompt itself describes
    /// ("对方的临睡前或深夜").
    static let pulseQuietStartHour = 23
    static let pulseQuietEndHour = 8

    /// When a pulse due at `date` should actually be announced, and whether that
    /// is later than it was due.
    ///
    /// A pulse due inside the quiet window is announced at the window's end
    /// (next 08:00), never dropped: silence is the model's call to make with its
    /// full context, not a notification's call to make on its behalf.
    nonisolated static func pulseAnnounceMoment(for date: Date,
                                                calendar: Calendar = .current) -> (date: Date, deferred: Bool) {
        let hour = calendar.component(.hour, from: date)
        let quiet = hour >= pulseQuietStartHour || hour < pulseQuietEndHour
        guard quiet else { return (date, false) }
        var comps = calendar.dateComponents([.year, .month, .day], from: date)
        comps.hour = pulseQuietEndHour
        comps.minute = 0
        comps.second = 0
        var morning = calendar.date(from: comps) ?? date
        if morning <= date {
            morning = calendar.date(byAdding: .day, value: 1, to: morning) ?? morning
        }
        return (morning, true)
    }

    private static func cancelInsurance(_ job: AgentJob) {
        JobInsuranceNotification.cancel(jobId: job.id)
    }
}

// MARK: - Insurance notification (schedule design §3)

/// A local notification registered when a job is armed and withdrawn the
/// moment the app itself handles the fire. If the process is killed first,
/// the notification is the only thing left standing — its text therefore
/// states only what is known (the task was due) and never a result.
enum JobInsuranceNotification {
    static func identifier(_ jobId: String) -> String { "job-\(jobId)" }

    static func schedule(jobId: String, at date: Date, title: String, body: String, userInfo: [String: String]) {
        guard UserDefaults.standard.object(forKey: "backgroundNotificationsEnabled") == nil
                || UserDefaults.standard.bool(forKey: "backgroundNotificationsEnabled") else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = ShortcutNotification.categoryId
        content.userInfo = userInfo
        let interval = max(1, date.timeIntervalSinceNow)
        let request = UNNotificationRequest(identifier: identifier(jobId), content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false))
        // Replace any earlier registration for the same job (loop re-arms).
        center.removePendingNotificationRequests(withIdentifiers: [identifier(jobId)])
        center.add(request) { error in
            // [AUD-21] `add` used to fail silently — a denied authorization meant
            // the fallback this job's promise rests on simply did not exist, and
            // nothing anywhere said so. It is logged here and surfaced to the
            // user by the scheduled-tasks screen (`notificationsDenied()`).
            if let error {
                logger.warning("[Insurance] notification NOT registered for job \(jobId.prefix(8)): \(error.localizedDescription)")
            }
        }
    }

    /// [AUD-21] True when the user has denied notifications.
    ///
    /// `schedule` deliberately only *requests* authorization while the state is
    /// `.notDetermined` (a prompt belongs to the user's own action, not to a
    /// timer being armed). Once the answer is no, every registration fails — so
    /// this is the fact the UI needs in order to say the fallback is off instead
    /// of leaving the promise quietly false.
    static func notificationsDenied() async -> Bool {
        let status = await withCheckedContinuation { cont in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                cont.resume(returning: settings.authorizationStatus)
            }
        }
        return status == .denied
    }

    /// Both queues: a notification that already fired (app was backgrounded
    /// past the deadline) is only removable from the delivered list.
    static func cancel(jobId: String) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier(jobId)])
        center.removeDeliveredNotifications(withIdentifiers: [identifier(jobId)])
    }
}

extension AgentJobTarget {
    /// The session a notification tap should open for this target.
    var sessionIdForNavigation: String? {
        switch self {
        case .new: return nil
        case .followUp(let sid): return sid
        case .rerun(let sid, _): return sid
        case .childOfCurrent(let parent, _): return parent
        }
    }
}
