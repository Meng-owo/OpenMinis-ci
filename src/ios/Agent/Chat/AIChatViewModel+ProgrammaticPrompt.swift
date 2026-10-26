import Combine
import Foundation

private let logger = AppLogger(category: "ProgrammaticPrompt")

// [T-p0-programmatic-prompt] Component A of the sub-agent / scheduled-task
// design (docs: subagent_design_v4 §8.1): the ONE channel through which
// anything that is not the user's own tap — the sessions CLI, a Shortcut, a
// scheduled job firing, a helper reporting back — injects a prompt into a
// session.
//
// Why a dedicated entry point instead of `vm.inputText = …; vm.send()`:
//
//  1. `send()` silently returns while `isProcessing` is true, and
//     `enqueuePrompt()` silently returns while it is false. A caller that reads
//     `isProcessing` and then picks one of them races the loop's own
//     epilogue: the classic check-then-act window in which the prompt
//     evaporates. Doing the check and the hand-off in one synchronous
//     @MainActor step (no `await` in between) closes that window.
//  2. The queue's only consumers are loop epilogues. A prompt that lands in
//     the queue after the epilogue's drain already returned (there are DB
//     awaits between that drain and `isProcessing = false`) has no consumer.
//     `startDrainIfIdle` — called from the isProcessing didSet and defensively
//     here — is the rescue.
//  3. Callers get the truth back (`.sent` / `.queued` / `.rejected`) instead of
//     an unconditional "ok".
//  4. `silent` suppresses the tap + completion haptics for a turn nobody tapped.

/// Who is injecting the prompt. Recorded for logs; P2's job machinery will
/// key completion hooks and notification identifiers off it.
enum ProgrammaticPromptOrigin: Equatable {
    /// `minis-sessions-cli send` from inside the sandbox.
    case cli
    /// An App Intent (Shortcuts / Siri).
    case shortcut
    /// An `AgentJobRegistry` job (scheduled trigger, helper completion, …).
    case job(jobId: String)
    /// The user saved an edited code block and asked the active assistant to
    /// see the new version.
    case userCodeEdit

    var logLabel: String {
        switch self {
        case .cli: return "cli"
        case .shortcut: return "shortcut"
        case .job(let id): return "job:\(id.prefix(8))"
        case .userCodeEdit: return "user-code-edit"
        }
    }
}

/// Truthful outcome of `submitProgrammaticPrompt`.
enum ProgrammaticSubmitOutcome: Equatable {
    /// No loop was running; a new turn started immediately.
    case sent
    /// A loop was running; the prompt is in `promptQueue` and will run as a
    /// fresh turn when that loop ends (or via the idle-drain rescue).
    case queued
    /// The vm declined it. `reason` is a stable snake_case token for callers
    /// that surface it to a script or a Shortcut result.
    case rejected(reason: String)
}

extension AIChatViewModel {

    /// Inject `text` into this session as a user turn, atomically choosing
    /// between starting a loop and queueing behind the running one.
    ///
    /// Must be called on the main actor and must not be preceded by an
    /// `await` that read `isProcessing` — the whole point is that the check
    /// and the hand-off happen in the same synchronous step.
    ///
    /// - Parameters:
    ///   - text: the prompt. Trimmed; an empty prompt with no ready
    ///     attachment is rejected rather than silently dropped.
    ///   - origin: who is asking (logs only in P0).
    ///   - silent: suppress the send/enqueue haptic and, for a `.sent` turn,
    ///     the completion haptic. A `.queued` prompt drains inside the user's
    ///     own loop, whose completion haptic is theirs and is kept.
    @MainActor
    @discardableResult
    func submitProgrammaticPrompt(_ text: String,
                                  origin: ProgrammaticPromptOrigin,
                                  silent: Bool = true) -> ProgrammaticSubmitOutcome {
        let tag = "📨[Programmatic] origin=\(origin.logLabel) vm=\(vmInstanceId) sid=\(sessionId?.prefix(8) ?? "nil")"

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // [S1-fix] A programmatic prompt no longer rides the composer's staged
        // attachments, so only its text can qualify a submit. (The old check
        // inspected `attachments`, which meant an empty programmatic prompt
        // could "pass" on the strength of chips the user had merely picked.)
        guard !trimmed.isEmpty else {
            logger.warning("\(tag) REJECTED — empty prompt (programmatic prompts carry no attachments, staged=\(self.attachments.count))")
            return .rejected(reason: "empty_prompt")
        }
        if isCompacting {
            // compactAndSend has its own queue + post-compact drain; a foreign
            // prompt landing mid-compaction would be rolled back or double
            // drained. Refuse rather than guess.
            logger.warning("\(tag) REJECTED — session is compacting")
            return .rejected(reason: "session_compacting")
        }

        // [T-programmatic-prompt-no-composer] The prompt travels as an
        // argument, NOT through `inputText`.
        //
        // This used to be `inputText = text`, which made the composer — a
        // two-way binding to whatever the user is typing right now — the
        // transport for a prompt nobody typed. Any background turn landing
        // mid-sentence (a helper reporting back, a scheduled job firing, the
        // CLI) overwrote the draft and then send()/enqueuePrompt() cleared it
        // to "", destroying it with no way back. Android never had this: its
        // headless path carries the text in a local and leaves `_inputText`
        // to the composer.
        //
        // Restoring the draft afterwards would not do: `inputText` is
        // @Published with a didSet that drives the slash and mention menus and
        // resets `voiceUsedInComposition`, so a write/restore pair would
        // shut an open mention popup and disturb the caret mid-typing.
        //
        // [S1-fix] `attachments` is NO LONGER shared with this path. The old
        // claim that the CLI and the Shortcut intent stage onto it before
        // calling was wrong: both go through `inputText` + `send()` (see
        // SessionsOffloadBridge / SendPromptIntent), which still consumes the
        // composer normally. A background prompt that reached into `attachments`
        // therefore did nothing but ship — and then destroy — a photo the user
        // had picked but not sent.

        if isProcessing {
            // Busy: hand to the queue. A programmatic prompt carries no
            // attachments, so the queue entry is text-only.
            let before = promptQueue.count
            let prompt = QueuedPrompt(text: text, attachments: [])
            promptQueue.append(prompt)
            let chatMsg = ChatMessage(role: .user, content: text, isQueued: true)
            chatMsg.queuedPromptId = prompt.id
            messages.append(chatMsg)
            scrollToBottomSignal.send()
            logger.info("\(tag) QUEUED — position \(self.promptQueue.count), loop still running")
            return .queued
        }

        // Idle: start a loop. `overrideText` carries the prompt, so `send()`
        // never reads (and never clears) the composer's draft.
        send(overrideText: text)
        guard isProcessing else {
            let reason = showContextExhaustedPrompt ? "context_exhausted" : "send_declined"
            logger.warning("\(tag) REJECTED — send() did not start a loop (\(reason))")
            return .rejected(reason: reason)
        }
        logger.info("\(tag) SENT — new loop started silent=\(silent)")
        return .sent
    }
}

// MARK: - Waiting for a programmatic turn  [T-shortcut-wait-queued-turn]

extension AIChatViewModel {

    /// The id of the prompt `submitProgrammaticPrompt` just queued, or nil when
    /// the outcome was not `.queued`. Read it IMMEDIATELY after the submit, on
    /// the main actor, before anything else can touch the queue.
    func lastQueuedProgrammaticPromptId(for outcome: ProgrammaticSubmitOutcome) -> UUID? {
        guard outcome == .queued else { return nil }
        return promptQueue.last?.id
    }

    /// Suspends until the turn carrying a programmatic prompt has finished.
    ///
    /// Callers used to do `for await p in $isProcessing.values { if !p { break } }`
    /// directly. That is right for `.sent` — send() flips isProcessing before it
    /// returns, so the first value the publisher replays is `true` — but wrong for
    /// `.queued`: the session was busy with an EARLIER turn, and the first `false`
    /// is that turn ending, before the queued prompt has even started. A "Wait for
    /// Result" Shortcut then returned the previous answer as if it were its own.
    ///
    /// Completion is therefore defined as: the queued prompt (if any) has left
    /// `promptQueue` (the drain took it) AND `isProcessing` is false. Both are
    /// watched together so a flip in either re-evaluates the pair, and the
    /// current values are replayed on subscription, so a turn that already
    /// finished resolves immediately rather than waiting for a change that will
    /// never come.
    ///
    /// Returns `false` if the task was cancelled before the turn finished
    /// (Shortcuts cancels perform() when its own time limit expires or the user
    /// stops the run); the caller decides what partial result to hand back.
    @discardableResult
    func awaitProgrammaticTurn(queuedPromptId: UUID?) async -> Bool {
        let states = Publishers.CombineLatest($isProcessing, $promptQueue)
            .map { processing, queue -> ProgrammaticTurnState in
                let stillQueued = queuedPromptId.map { id in queue.contains { $0.id == id } } ?? false
                return ProgrammaticTurnState(processing: processing, stillQueued: stillQueued)
            }
            .values
        return await Self.awaitTurnCompletion(in: states)
    }

    /// The pure part of `awaitProgrammaticTurn`, over any state sequence, so the
    /// completion rule is unit-testable without a view model.
    nonisolated static func awaitTurnCompletion<S: AsyncSequence>(in states: S) async -> Bool
    where S.Element == ProgrammaticTurnState {
        do {
            for try await state in states {
                if Task.isCancelled { return false }
                if state.isFinished { return true }
            }
        } catch {
            return false
        }
        // The sequence ended without a finished state: the publisher completed
        // (vm deallocated) or the task was cancelled mid-await.
        return false
    }
}

/// One observation of the pair `awaitTurnCompletion` decides on.
struct ProgrammaticTurnState: Equatable, Sendable {
    let processing: Bool
    /// Only meaningful for a `.queued` submit: true while the drain has not yet
    /// picked the prompt up. Always false for `.sent`.
    let stillQueued: Bool

    /// Finished = nothing left to run for this prompt AND the loop is idle.
    var isFinished: Bool { !processing && !stillQueued }
}

extension AIChatViewModel {
    nonisolated static func resolvedStatus(_ status: String, result: String) -> String {
        if status == "completed" && result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "empty"
        }
        return status
    }

    static let helperMaxMinutes: Int = 10
    static let helperWrapUpGraceSeconds: TimeInterval = 30.0
    /// What the parent is told when a sub agent produced no final text.
    ///
    /// [T-sub-agents-empty-result] Never hand the parent an empty result: from
    /// "" it cannot tell "finished and had nothing to say" from "was stopped"
    /// from "crashed", so it either re-delegates the same task or reports that
    /// nothing happened. Every terminal state gets a sentence instead.
    static func emptyResultNote(status: String) -> String {
        switch status {
        case "cancelled":
            return "(The sub agent was stopped before it produced a result. Treat its work as unfinished — delegate it again if it is still needed.)"
        case "timeout":
            return "(The sub agent hit its time budget before writing a result. Delegate a narrower task, or do the work in this conversation.)"
        case "failed":
            return "(The sub agent's run failed before producing a result. Do not assume the work was done — delegate again or do it here.)"
        default:
            return "(The sub agent ended without writing a final answer. Treat its result as unknown — do not assume the work was done.)"
        }
    }

    /// Parsed `subagent_task` result JSON — the parent's tool block content.
    /// Used by the block's completed rendering and the history entry point.
    nonisolated static func parseDelegateResult(_ content: String) -> [String: Any]? {
        guard content.hasPrefix("{"), let data = content.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    /// [T-stop-sibling-subagent] True after the USER stopped this conversation
    /// and before they send their next own message.
    ///
    /// `AgentJobRegistry.runThen` reads this at DELIVERY time: a sub agent that
    /// finished a moment after the user pressed Stop must not wake the very
    /// conversation that was stopped (its "cancelled" result reads as a failed
    /// sub-task, so the parent would immediately delegate it again).
    var delegationResultsAreMuted: Bool { delegationResultsMuted }

    /// [T-sub-agents-queue] Start a delegation that had been waiting for a slot.
    ///
    /// Called by `AgentJobRegistry.drainQueuedDelegations()`. The tool call that
    /// queued it returned `status: queued` long ago, so there is no tool block
    /// to write and no tool result to produce here — the run reports through the
    /// job's normal completion callback like any other.
    @discardableResult
    func executeDelegateTaskQueued(args: [String: Any], toolUseId: String) async -> Bool {
        let (_, ok) = await executeDelegateTask(args: args, toolUseId: toolUseId, msgIdx: -1, blockIdx: -1)
        return ok
    }
}

// MARK: - Sub agents: the delegate task  [T-sub-agents-v1]
//
// [BUG-09] `subagent_task` was DEFINED in the tool table and dispatched
// nowhere: every call fell through to `default:` and returned
// `Error: Unknown tool 'subagent_task'`, while the system prompt encouraged the
// model to use it. This section is the execution end.
//
// Shape borrowed from the mature implementations of the same idea (Claude
// Code's sub agents / Agent tool, OpenAI Agents SDK's `agent.as_tool`):
//
//   * A sub agent runs in its OWN session (its own context window, its own
//     system prompt), so the parent conversation never carries the child's
//     searching, tool output or dead ends — only the final answer comes back.
//   * Delegation is asynchronous by default (`wait: false`): the tool result
//     says `status: running` at once, the parent keeps working, and the result
//     arrives later as an `<agent_callback>` card. `wait: true` is the opt-in
//     for "my next step needs this result before anything else".
//   * The child's final message IS the result, verbatim — no summarising step.
//   * Slots are bounded (3 running, 10 queued) and overflow is QUEUED rather
//     than refused, because a turn that fans out five tasks must not see two of
//     them come back "rejected".
//   * Delegation depth is 1: a sub agent cannot delegate again.
//   * Stop means quiet: stopping the parent cancels its sub agents silently and
//     mutes late results for that turn.

/// What a CHILD session's view model knows about the delegation it runs.
///
/// Set before the child's first turn. Its presence is what `isSubAgentChild`
/// keys off — the child gets the sub agent identity section in place of the
/// app's own SOUL, exactly as the old `helperConfig` did.
struct SubAgentBrief: Equatable, Sendable {
    let parentSessionId: String
    let parentToolUseId: String
    let jobId: String
    /// The parent's `tool_title`, or the head of the task.
    let title: String
    /// The sub agent definition's standing instructions (may be empty).
    let instructions: String
    /// Wall-clock budget in minutes before the run is stopped.
    let budgetMinutes: Int
}

extension AIChatViewModel {

    /// Stable snake_case JSON, one line — tool results are persisted and
    /// diffed, so key order must not wobble between runs.
    static func delegateJSON(_ obj: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"ok":false,"status":"error","reason":"encoding_failed"}"#
        }
        return text
    }

    static func argString(_ args: [String: Any], _ key: String) -> String {
        ((args[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Write the delegation JSON into the parent's tool block.
    ///
    /// `msgIdx < 0` means there is no block to write: a delegation re-entered
    /// from the queue, or one started after the turn that asked for it ended.
    @MainActor
    func writeDelegateBlock(msgIdx: Int, blockIdx: Int, _ json: String) {
        guard msgIdx >= 0, blockIdx >= 0,
              msgIdx < messages.count, blockIdx < messages[msgIdx].blocks.count else { return }
        messages[msgIdx].blocks[blockIdx].content = json
    }

    /// [batch7-fix] Stop this turn from being driven by sub agent results,
    /// without cancelling the turn itself. Lives here (not only in the
    /// non-compiled HelperRunner) because the card's Stop button calls it.
    func muteDelegationResultsLive(reason: String) {
        guard !delegationResultsMuted else { return }
        delegationResultsMuted = true
        logger.info("[subagent_task] parent \(self.sessionId?.prefix(8) ?? "nil") muted for sub agent results — \(reason)")
    }

    /// [batch7-fix] Release the render state a transcript page allocated for
    /// this VM. The local build has no separate render-state object, so this
    /// is the honest no-op the caller can rely on.
    func helperReleaseRenderState() {}

    /// [batch7][AUD-B7-6] Write a delegate block located by tool_use id —
    /// the index-free twin of `writeDelegateBlock`, used by the closing chain
    /// where the parent's block indices may have moved.
    func writeDelegateBlock(toolUseId: String, content: String, status: ToolBlockStatus? = nil) {
        for msg in messages where msg.role == .assistant {
            if let block = msg.blocks.first(where: { $0.toolUseId == toolUseId }) {
                block.content = content
                if let status, block.toolStatus != status { block.toolStatus = status }
                return
            }
        }
    }

    /// [batch7][AUD-B7-6] The ◐ progress line the block parser reads while a
    /// delegation is still running. Mirrors HelperRunner's format exactly so
    /// the same parse path (icon · title · tool · status · clock) applies.
    static func progressLine(title: String, tool: String, status: String, elapsed: TimeInterval) -> String {
        let s = Int(elapsed)
        let clock = String(format: "%d:%02d", s / 60, s % 60)
        var parts = ["◐ \(AppLocalized("Agent")) · \(title)"]
        if !tool.isEmpty { parts.append(tool) }
        if !status.isEmpty { parts.append(String(status.prefix(80))) }
        parts.append(clock)
        return parts.joined(separator: " · ")
    }

    /// [batch7][AUD-B7-6] Classify a child's raw error message into the short
    /// label the card shows. Moved here from HelperRunner (which is kept
    /// in-tree but not compiled): the live delegate path needs it to fill the
    /// completion payload's `error_kind`.
    nonisolated static func errorKind(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let s = raw.lowercased()
        // Ordered most-specific first: an overload response also contains
        // "429"-adjacent wording on some providers, and a context error often
        // mentions "token" which the quota branch would otherwise claim.
        if s.contains("context") && (s.contains("length") || s.contains("window") || s.contains("too long")) {
            return AppLocalized("Context limit")
        }
        if s.contains("rate limit") || s.contains("429") || s.contains("too many requests") {
            return AppLocalized("Rate limited")
        }
        if s.contains("quota") || s.contains("insufficient") || s.contains("credit") || s.contains("billing") {
            return AppLocalized("Quota exhausted")
        }
        if s.contains("overload") || s.contains("529") || s.contains("503") || s.contains("unavailable") {
            return AppLocalized("Provider overloaded")
        }
        if s.contains("timed out") || s.contains("timeout") { return AppLocalized("Timed out") }
        if s.contains("unauthor") || s.contains("401") || s.contains("403")
            || s.contains("api key") || s.contains("credential") {
            return AppLocalized("Auth failed")
        }
        if s.contains("offline") || s.contains("network") || s.contains("connection")
            || s.contains("host") || s.contains("internet") {
            return AppLocalized("Network error")
        }
        if s.contains("cancel") { return AppLocalized("Cancelled") }
        return nil
    }

    /// [batch7][AUD-B7-6] Persist the final delegate JSON into the stored
    /// tool_result so a reload shows the same finished card, not the running
    /// snapshot that was last written before the process died.
    func persistFinalDelegateResult(toolUseId: String, content: String, status: ToolBlockStatus) {
        guard let sid = sessionId else { return }
        let success: Bool = { if case .success = status { return true }; return false }()
        let statusText: String? = { if case .failed(let m) = status { return m }; return nil }()
        Task { @MainActor in
            let raws = await ChatStore.shared.loadMessages(sessionId: sid)
            for raw in raws where raw.role == .user {
                guard raw.parts.contains(where: { if case .toolResult(let tr) = $0 { return tr.toolUseId == toolUseId }; return false }) else { continue }
                let parts: [ContentPart] = raw.parts.map { part in
                    guard case .toolResult(let tr) = part, tr.toolUseId == toolUseId else { return part }
                    return .toolResult(ToolResult(toolUseId: tr.toolUseId, output: content, success: success,
                                                  mediaRef: tr.mediaRef, snapshot: tr.snapshot,
                                                  pageURL: tr.pageURL, status: statusText))
                }
                await ChatStore.shared.updateMessageParts(messageId: raw.id, parts: parts)
                await ChatStore.shared.markDirty(recordType: "Message", recordId: raw.id)
                return
            }
            logger.warning("[subagent_task] final result NOT persisted — no stored tool_result for \(toolUseId.prefix(12))")
        }
    }

    /// Whether this view model is the child of a delegation.
    var isSubAgentChild: Bool { subAgentBrief != nil }

    /// System-prompt preamble for a sub agent — replaces the SOUL identity
    /// section, the same way `minis-model-use` describes an environment without
    /// assigning an identity (OpenMinis#103: identity pollution).
    var subAgentIdentitySection: String {
        guard let brief = subAgentBrief else { return "" }
        let instructions = brief.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        var section = """
        You are running as a sub agent inside an app called Minis, on an iOS device with a fully functional iSH Linux shell (Alpine Linux, aarch64). This is the calling environment, not your identity — keep your own model identity unchanged.
        A parent agent delegated ONE focused task to you: "\(brief.title)". You cannot see the parent conversation and it cannot see yours; everything you need is in the task text. Work the task to completion using your tools, then finish with a single clear final answer — that final message is returned verbatim to the parent agent as the result, and it is the ONLY thing the parent receives. So the final message must contain the complete deliverable itself: the full report, document, list, code or answer the task asked for, in full — never a summary of what you did, a pointer to a file you wrote, or "see above". If you produced a file, paste its full content into the final message as well. Do not ask the parent or the user questions; make reasonable assumptions and state them. Do not restate the task or add meta-commentary.
        You have about \(brief.budgetMinutes) minutes of wall-clock time; write the deliverable before the run is stopped.
        """
        if !instructions.isEmpty {
            section += "\n\n--- Sub agent instructions (set by the user) ---\n\(instructions)"
        }
        return section
    }

    /// `subagent_task` — the router for the actions the tool advertises.
    @MainActor
    func executeSubAgentTask(args: [String: Any],
                             toolUseId: String,
                             msgIdx: Int,
                             blockIdx: Int) async -> (output: String, success: Bool) {
        let action = Self.argString(args, "action").lowercased()
        switch action {
        case "", "delegate":
            return await executeDelegateTask(args: args, toolUseId: toolUseId, msgIdx: msgIdx, blockIdx: blockIdx)
        case "cancel":
            return cancelSubAgentTask(args: args)
        case "status":
            return subAgentStatus(args: args)
        case "steer":
            return steerSubAgentTask(args: args)
        case "resume":
            return await resumeSubAgentTask(args: args)
        default:
            let json = Self.delegateJSON([
                "ok": false, "status": "rejected", "reason": "unknown_action",
                "detail": "Unknown action '\(action)'. This build accepts: delegate (default), status, steer, cancel, resume.",
            ])
            writeDelegateBlock(msgIdx: msgIdx, blockIdx: blockIdx, json)
            return (json, false)
        }
    }

    /// `action=cancel` — stop ONE delegated run by its `job_id`.
    ///
    /// Cancelling reports back to the parent (that is how it learns the result
    /// will never come), which is the opposite of the user's own Stop, where the
    /// quiet is the point.
    @MainActor
    func cancelSubAgentTask(args: [String: Any]) -> (output: String, success: Bool) {
        let jobId = Self.argString(args, "job_id")
        guard !jobId.isEmpty else {
            return (Self.delegateJSON([
                "ok": false, "status": "rejected", "reason": "missing_job_id",
                "detail": "action=cancel needs `job_id` (it is returned by every delegate call).",
            ]), false)
        }
        let registry = AgentJobRegistry.shared
        guard let job = registry.job(id: jobId) else {
            return (Self.delegateJSON([
                "ok": false, "status": "rejected", "reason": "not_found",
                "detail": "No live delegation with job_id=\(jobId). It may have finished already; its result (or a cancellation note) is in this conversation.",
            ]), false)
        }
        guard job.state == .running || job.state == .pending else {
            return (Self.delegateJSON([
                "ok": false, "status": "rejected", "reason": "already_finished",
                "detail": "job_id=\(jobId) is already \(job.state.rawValue) — nothing to cancel.",
            ]), false)
        }
        registry.cancel(jobId: jobId, reason: "model cancel", silent: false)
        logger.info("[subagent_task] CANCEL \(jobId.prefix(8)) by model request")
        return (Self.delegateJSON([
            "ok": true, "status": "cancelled", "job_id": jobId,
            "detail": "The run was stopped and will not deliver a result beyond the cancellation notice.",
        ]), true)
    }

    /// [T-subagent-steer-continues-loop] Restarts an idle child's loop so the
    /// pending steer is delivered. Deliberately says nothing itself: the loop
    /// prepends the actual correction at the top of the turn it starts, and a
    /// second instruction here would compete with it.
    static let subAgentSteerNudgePrompt =
        "The delegating agent has sent you a course correction. Read it and continue."

    /// [T-sub-agents-resume] Sent as a resumed child's first turn.
    ///
    /// A resumed sub agent reads a transcript of work it "remembers" doing, but
    /// the RUNTIME behind those tool calls is gone: the app was killed, so the
    /// browser tabs it opened are closed and the shell processes it started are
    /// dead. Files in the shared workspace survive. Without this it happily
    /// calls browser_use on a tab that no longer exists and burns rounds
    /// rediscovering that.
    static let subAgentResumeNotice = """
    [This run was interrupted and has been resumed. The tool results above are still valid, but all live state is gone: browser tabs are closed, shell processes have ended, and anything unsaved is lost. Files in the workspace are still there. Continue from what the transcript already establishes — reopen pages or re-run commands when you need them, and do not assume anything is still open.]
    """

    /// `action=status` — look at this conversation's delegations without
    /// waiting for their completion messages. Scope: jobs whose target parent
    /// is THIS session — a conversation never reads another's agents.
    @MainActor
    func subAgentStatus(args: [String: Any]) -> (output: String, success: Bool) {
        guard let sid = sessionId else {
            return (Self.delegateJSON([
                "ok": false, "status": "rejected", "reason": "no_session",
                "detail": "This conversation has no session yet.",
            ]), false)
        }
        let registry = AgentJobRegistry.shared
        let jobIdArg = Self.argString(args, "job_id")
        var jobs = registry.list().filter {
            $0.target.isChildOfCurrent && $0.target.parentSessionId == sid
        }
        if !jobIdArg.isEmpty {
            jobs = jobs.filter { $0.id == jobIdArg || $0.id.hasPrefix(jobIdArg) }
            if jobs.isEmpty {
                return (Self.delegateJSON([
                    "ok": false, "status": "rejected", "reason": "job_not_found",
                    "job_id": jobIdArg,
                    "detail": "No delegation of this conversation has that job_id.",
                ]), false)
            }
        }
        let queuedWaiting = registry.queuedCount(parent: sid)
        let entries: [[String: Any]] = jobs.map { job in
            var d: [String: Any] = [
                "job_id": job.id,
                "title": job.title,
                "state": job.state.rawValue,
                "model_origin": job.modelOrigin ?? NSNull(),
                "agent": job.subAgentName ?? NSNull(),
                "elapsed_s": Int(job.elapsed ?? 0),
                "child_session_id": job.runSessionId ?? NSNull(),
                "delivery": job.then == .none ? "tool_result" : "new_message_when_done",
            ]
            // [T-sub-agents-steer] Only present when something went unread, so
            // its absence is not a claim that a steer landed.
            if !job.missedSteers.isEmpty {
                d["missed_steer"] = job.missedSteers
                d["missed_steer_note"] = "The run ended before reading these — the result does not reflect them."
            }
            // [T-agent-model-identity] Fold in what the child's loop is serving
            // its turns on right now, then report the identity in the same
            // one-line forms the cards use. `model_resolved` is what the
            // strategy picked, `model_effective` what has actually served a
            // turn — they differ when group fallback moved the child.
            if let cid = job.runSessionId, job.state == .running,
               let vm = ViewModelCache.shared.get(for: cid) {
                job.modelIdentity?.merge(vm.lastEffectiveModel)
            }
            if let identity = job.modelIdentity {
                d["tier_requested"] = identity.tierRequested ?? NSNull()
                d["model_resolved"] = identity.resolvedLabel ?? NSNull()
                d["model_effective"] = identity.effectiveModel ?? NSNull()
            }
            if let cid = job.runSessionId, job.state == .running,
               let info = SessionActivityTracker.shared.sessionToolInfo[cid] {
                d["current_tool"] = info.toolName
                d["current_status"] = String(info.toolStatus.prefix(120))
                d["loop_iteration"] = info.loopIteration
            }
            if job.state != .running && job.state != .pending, let r = job.resultText {
                d["result"] = String(r.prefix(2000))
            }
            return d
        }
        let out: [String: Any] = [
            "ok": true, "count": entries.count, "agents": entries,
            // [T-sub-agents-queue] Waiting for a slot, not yet a job — so they
            // have no entry above. Reported so the model can see that work it
            // delegated is still coming and must not be delegated again.
            "queued": queuedWaiting,
            "note": "Running agents deliver their final result automatically as a new message in this conversation; you do not need to poll for it."
                + (queuedWaiting > 0 ? " \(queuedWaiting) more are queued and will start as slots free — do not re-delegate them." : ""),
        ]
        return (Self.delegateJSON(out), true)
    }

    /// `action=steer` — queue a course correction into a running sub agent
    /// without stopping it. The message is read at the child's next turn, so
    /// an in-flight tool call finishes first and the work done so far is kept
    /// — the whole reason to steer rather than cancel.
    @MainActor
    func steerSubAgentTask(args: [String: Any]) -> (output: String, success: Bool) {
        let jobId = Self.argString(args, "job_id")
        let message = Self.argString(args, "message")
        guard !jobId.isEmpty else {
            return (Self.delegateJSON([
                "ok": false, "status": "rejected", "reason": "missing_job_id",
                "detail": "action=steer needs `job_id` (it is returned by every delegate call).",
            ]), false)
        }
        guard !message.isEmpty else {
            return (Self.delegateJSON([
                "ok": false, "status": "rejected", "reason": "missing_message",
                "detail": "action=steer needs `message` — the correction to give the running sub agent.",
            ]), false)
        }
        let registry = AgentJobRegistry.shared
        guard let job = registry.job(id: jobId), job.target.isChildOfCurrent,
              job.target.parentSessionId == sessionId else {
            return (Self.delegateJSON([
                "ok": false, "status": "rejected", "reason": "not_found",
                "detail": "No delegation of this conversation has job_id=\(jobId).",
            ]), false)
        }
        // Rejected rather than queued once the run is over: a steer that
        // cannot change anything must say so, not look accepted.
        guard job.state == .running || job.state == .pending else {
            return (Self.delegateJSON([
                "ok": false, "status": "rejected", "job_id": job.id,
                "reason": "already_finished", "state": job.state.rawValue,
                "detail": "That sub agent has already finished — its result stands. Delegate a new task instead.",
            ]), false)
        }
        guard let cid = job.runSessionId, let child = ViewModelCache.shared.get(for: cid) else {
            return (Self.delegateJSON([
                "ok": false, "status": "rejected", "job_id": job.id,
                "reason": "child_not_running",
                "detail": "That sub agent has no live session to steer.",
            ]), false)
        }
        child.pendingSteerMessages.append(message)
        // [T-subagent-steer-continues-loop] If the child's loop is between
        // turns right now, nothing is left to consume the steer — it would
        // sit in the queue until the run ended and then be reported as a
        // missed correction. Nudge the loop so it takes the turn that
        // delivers it, the same way a queued user prompt restarts an idle
        // conversation.
        if !child.isProcessing {
            logger.info("[subagent_task] steer arrived while child \(cid.prefix(8)) was idle — nudging its loop")
            _ = child.submitProgrammaticPrompt(Self.subAgentSteerNudgePrompt,
                                               origin: .job(jobId: job.id), silent: true)
        }
        logger.info("[subagent_task] steer queued job=\(job.id.prefix(8)) child=\(cid.prefix(8)) chars=\(message.count)")
        return (Self.delegateJSON([
            "ok": true, "status": "queued", "job_id": job.id,
            "agent": job.subAgentName ?? NSNull(),
            "detail": "Queued. The sub agent reads it at its next turn; a tool call already running is not interrupted. It may finish before consuming it.",
        ]), true)
    }

    /// `action=resume` — restart one interrupted delegation (cancelled /
    /// failed / budget-stopped) from its own transcript, in its EXISTING
    /// child session. The original job stays closed (its card and history
    /// stand); the resume registers a NEW job bound to the same session, so
    /// the loop-end observer closes it and delivers the result through the
    /// same callback channel as a fresh run.
    @MainActor
    func resumeSubAgentTask(args: [String: Any]) async -> (output: String, success: Bool) {
        let jobId = Self.argString(args, "job_id")
        guard !jobId.isEmpty else {
            return (Self.delegateJSON([
                "ok": false, "status": "rejected", "reason": "missing_job_id",
                "detail": "action=resume needs `job_id` — use action=status to list this conversation's delegations.",
            ]), false)
        }
        guard !isSubAgentChild else {
            return (Self.delegateJSON([
                "ok": false, "status": "rejected", "reason": "depth_limit",
                "detail": "Sub agents cannot resume another sub agent (the maximum depth is 1).",
            ]), false)
        }
        guard let parentSid = sessionId else {
            return (Self.delegateJSON([
                "ok": false, "status": "rejected", "reason": "no_parent_session",
                "detail": "This conversation cannot resume a sub agent (no session yet).",
            ]), false)
        }
        let registry = AgentJobRegistry.shared
        guard let job = registry.job(id: jobId), job.target.isChildOfCurrent,
              job.target.parentSessionId == parentSid else {
            return (Self.delegateJSON([
                "ok": false, "status": "rejected", "reason": "not_found",
                "detail": "No delegation of this conversation has job_id=\(jobId).",
            ]), false)
        }
        guard job.state != .running && job.state != .pending else {
            return (Self.delegateJSON([
                "ok": false, "status": "rejected", "reason": "already_running", "job_id": job.id,
                "detail": "That sub agent is \(job.state.rawValue) — it is still working; its result will arrive by itself.",
            ]), false)
        }
        guard job.state != .done else {
            return (Self.delegateJSON([
                "ok": false, "status": "rejected", "reason": "already_finished", "job_id": job.id,
                "detail": "That run completed — its result stands. Delegate a new task if there is more to do.",
            ]), false)
        }
        // Wait-mode delegations returned their result directly to the caller
        // and carry `then: .none`; a resumed run would have nowhere to report.
        if job.then == .none {
            return (Self.delegateJSON([
                "ok": false, "status": "rejected", "reason": "wait_mode_run", "job_id": job.id,
                "detail": "That delegation was a wait-mode call: it returned its result directly to the caller, so a resumed run would have nowhere to report. Delegate the task again instead.",
            ]), false)
        }
        guard registry.canStartChildJob else {
            return (Self.delegateJSON([
                "ok": false, "status": "rejected", "reason": "sub_agent_limit", "job_id": job.id,
                "detail": "All \(AgentJobRegistry.maxConcurrentChildJobs) sub agent slots are busy. Wait for one to finish, then resume this job_id again — it was NOT queued.",
            ]), false)
        }
        guard let childId = job.runSessionId, await ChatStore.shared.sessionExists(id: childId) else {
            return (Self.delegateJSON([
                "ok": false, "status": "rejected", "reason": "session_gone", "job_id": job.id,
                "detail": "That sub agent's session no longer exists, so there is no transcript to continue from.",
            ]), false)
        }

        // The definition may have been renamed or deleted while the run was
        // away; falling back to the built-in keeps the resume possible, and
        // the user is told which name went missing rather than being handed
        // a General Sub Agent with no explanation.
        let roster = SubAgentStore.shared.subAgents
        var subAgent = roster.first { $0.isBuiltIn } ?? SubAgentDefinition.makeBuiltIn()
        var namedAgentMissing: String?
        if let name = job.subAgentName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty, name != subAgent.name {
            if let named = roster.first(where: { $0.name == name }) {
                subAgent = named
            } else {
                namedAgentMissing = name
                logger.warning("[subagent_task] RESUME agent \"\(name)\" no longer exists — falling back to the built-in")
            }
        }
        guard let resolution = SubAgentModelResolver.resolve(subAgent: subAgent, parent: self) else {
            return (Self.delegateJSON([
                "ok": false, "status": "rejected", "reason": "no_model",
                "detail": "No model is configured for the sub agent to run on.",
            ]), false)
        }

        // Same child pool, same session setup as the fresh-delegation path.
        let (child, fresh) = ViewModelCache.shared.getOrCreate(for: childId)
        if fresh || child.messages.isEmpty { await child.loadSession() }
        guard !child.isProcessing else {
            return (Self.delegateJSON([
                "ok": false, "status": "rejected", "reason": "child_busy", "job_id": job.id,
                "detail": "That sub agent's session is busy with a turn right now; try again in a moment.",
            ]), false)
        }
        child.sessionSource = "helper"
        child.memoryEnabled = false
        child.suppressGeneralCompletionNotification = true
        let parentToolUseId: String
        if case .childOfCurrent(_, let tu) = job.target, let tu {
            parentToolUseId = tu
        } else {
            parentToolUseId = ""
        }
        let budgetMinutes = AIChatViewModel.helperMaxMinutes
        let newJob = registry.register(title: job.title,
                                       origin: .tool,
                                       trigger: .immediate,
                                       target: job.target,
                                       prompt: nil,
                                       then: .followUpParent(template: nil))
        newJob.subAgentName = subAgent.name
        newJob.modelOrigin = resolution.origin.rawValue
        newJob.modelIdentity = HelperModelIdentity.make(resolution: resolution)
        newJob.creatorSessionId = parentSid
        newJob.wasResumed = true

        child.subAgentBrief = SubAgentBrief(parentSessionId: parentSid,
                                            parentToolUseId: parentToolUseId,
                                            jobId: newJob.id,
                                            title: job.title,
                                            instructions: subAgent.instructions,
                                            budgetMinutes: budgetMinutes)
        ProviderConfigStore.shared.setBinding(
            SessionModelBinding(sessionId: childId, primarySource: resolution.source), for: childId)
        // A resumed run re-resolves its model, so it re-seeds the thinking
        // level too — otherwise resume silently drops it for the rest of the run.
        applySubAgentThinkingLevel(subAgent: subAgent, childSessionId: childId,
                                   parentSessionId: parentSid, entry: resolution.entry)

        let outcome = child.submitProgrammaticPrompt(Self.subAgentResumeNotice,
                                                     origin: .job(jobId: newJob.id), silent: true)
        guard outcome == .sent else {
            // Nothing started: drop the new job at once so it never lingers as
            // running, then report the failure — no follow-up is delivered.
            newJob.then = AgentJobThen.none
            registry.finish(newJob.id, state: .failed, result: nil)
            return (Self.delegateJSON([
                "ok": false, "status": "failed", "job_id": newJob.id,
                "detail": "The sub agent session did not restart (\(String(describing: outcome))).",
            ]), false)
        }
        registry.markRunning(newJob.id, sessionId: childId)
        // Budget restarts: the original one died with the process, and a fresh
        // clock is the intended behaviour.
        newJob.task = Task { @MainActor [weak child] in
            try? await Task.sleep(nanoseconds: UInt64(budgetMinutes) * 60 * 1_000_000_000)
            guard !Task.isCancelled, let child, child.isProcessing else { return }
            logger.warning("[subagent_task] budget \(budgetMinutes)min elapsed — stopping resumed child \(childId.prefix(8))")
            child.cancel()
        }
        if let missing = namedAgentMissing {
            transientNotice = String(format: AppLocalized("子代理「%@」已不存在，改用内置代理继续"), missing)
        }
        logger.info("[subagent_task] RESUME job=\(newJob.id.prefix(8)) from=\(jobId.prefix(8)) child=\(childId.prefix(8)) agent=\(subAgent.name)")
        return (Self.delegateJSON([
            "ok": true, "status": "resumed", "job_id": newJob.id, "resumed_from": job.id,
            "agent": subAgent.name,
            "detail": "The sub agent was restarted from its own transcript and is running again; its result arrives as a new message in this conversation. Do not re-delegate the task.",
        ]), true)
    }

    /// `action=delegate` — the delegation itself.
    @MainActor
    func executeDelegateTask(args: [String: Any],
                             toolUseId: String,
                             msgIdx: Int,
                             blockIdx: Int) async -> (output: String, success: Bool) {
        let title = Self.argString(args, "tool_title")
        let task = Self.argString(args, "task")
        let requestedAgentName = (args["agent"] as? String)
        let wait = (args["wait"] as? Bool) ?? false

        func reject(_ reason: String, _ detail: String) -> (output: String, success: Bool) {
            let json = Self.delegateJSON(["ok": false, "status": "rejected", "reason": reason, "detail": detail])
            logger.warning("[subagent_task] REJECTED \(reason): \(detail)")
            writeDelegateBlock(msgIdx: msgIdx, blockIdx: blockIdx, json)
            return (json, false)
        }

        guard !task.isEmpty else {
            return reject("empty_task", "`task` is required and must be the complete brief: goal, constraints and return format.")
        }
        guard !isSubAgentChild else {
            return reject("depth_limit", "Sub agents cannot delegate further (the maximum depth is 1). Do the work yourself.")
        }
        guard let parentSid = sessionId else {
            return reject("no_parent_session", "This conversation cannot start a sub agent (no session yet).")
        }

        // Which sub agent runs this. Omitted = the built-in general one.
        let roster = SubAgentStore.shared.subAgents
        guard let subAgent = SubAgentRoster.resolve(name: requestedAgentName, in: roster) else {
            let known = roster.map(\.name).joined(separator: ", ")
            return reject("unknown_agent", "No sub agent named \"\(requestedAgentName ?? "")\". Available: \(known). Omit `agent` to use the general one.")
        }

        // Slots. Overflow is QUEUED, never refused silently: the queue starts it
        // when a slot frees and its result arrives through the same callback.
        let registry = AgentJobRegistry.shared
        if !registry.canStartChildJob {
            let queued = registry.enqueueDelegation(
                .init(parentSessionId: parentSid, args: args, toolUseId: toolUseId))
            guard queued else {
                return reject("sub_agent_limit",
                              "\(AgentJobRegistry.maxConcurrentChildJobs) sub agents are already running and the queue is full (\(AgentJobRegistry.maxQueuedDelegations)). Wait for some to finish, then delegate this task again — it was NOT queued.")
            }
            let json = Self.delegateJSON([
                "ok": true, "status": "queued",
                // [batch7][AUD-B7-7] A queued DELEGATION has no child session
                // yet (it has not started), so it cannot carry
                // child_session_id — which is the marker HelperBlockInfo uses
                // to tell a delegation from a control call. Without this flag
                // it matched the "status=queued + job_id ⇒ steer" rule and was
                // rendered as a 36pt control capsule instead of a card.
                "delegation": true,
                "queued_behind": max(0, registry.runningChildJobCount + registry.queuedCount(parent: parentSid) - 1),
                "detail": "All \(AgentJobRegistry.maxConcurrentChildJobs) slots are busy. This task is QUEUED and starts automatically as soon as one frees; its result arrives as a new message like any other. Do not re-delegate it.",
            ])
            writeDelegateBlock(msgIdx: msgIdx, blockIdx: blockIdx, json)
            logger.info("[subagent_task] QUEUED tool=\(toolUseId.prefix(12)) behind \(registry.runningChildJobCount) running")
            return (json, true)
        }

        // Which model the child runs on: the definition's pinned Model Group, or
        // the parent conversation's binding. Never the delegating model's guess.
        guard let resolution = SubAgentModelResolver.resolve(subAgent: subAgent, parent: self) else {
            return reject("no_model", "This conversation has no resolvable model, so a sub agent cannot run. Pick a model for this session first.")
        }

        let budgetMinutes = AIChatViewModel.helperMaxMinutes
        let childTitle = AgentJobRegistry.childSessionTitle(
            title.isEmpty ? String(task.prefix(40)) : title,
            subAgentName: subAgent.isBuiltIn ? nil : subAgent.name)

        // A hidden child session of this conversation: same database, own
        // context window, never listed as a top-level conversation.
        let session = await ChatStore.shared.createSession(modelId: resolution.entry.model.id,
                                                     title: childTitle,
                                                     source: "helper",
                                                     parentSessionId: parentSid,
                                                     parentToolUseId: toolUseId)
        ProviderConfigStore.shared.setBinding(
            SessionModelBinding(sessionId: session.id, primarySource: resolution.source),
            for: session.id)
        applySubAgentThinkingLevel(subAgent: subAgent, childSessionId: session.id, parentSessionId: parentSid, entry: resolution.entry)

        let promptText = Self.delegationPrompt(task: task, title: title, subAgent: subAgent)
        let job = registry.register(title: childTitle,
                                    origin: .tool,
                                    trigger: .immediate,
                                    target: .childOfCurrent(parentSessionId: parentSid, parentToolUseId: toolUseId),
                                    prompt: promptText,
                                    then: wait ? AgentJobThen.none : AgentJobThen.followUpParent(template: nil))
        job.subAgentName = subAgent.name
        job.modelOrigin = resolution.origin.rawValue
        job.modelIdentity = HelperModelIdentity.make(resolution: resolution)
        job.creatorSessionId = parentSid

        let (child, _) = ViewModelCache.shared.getOrCreate(for: session.id)
        await child.loadSession()
        child.sessionSource = "helper"
        child.memoryEnabled = false
        child.suppressGeneralCompletionNotification = true

        // [batch7][AUD-B7-5] Bind the parent block to this run the moment it
        // exists — the same three fields HelperRunner set at start. Without
        // them the card has no child id (Stop, transcript and detail all go
        // dead), no live model line, and no agent badge until a reload.
        if msgIdx >= 0, msgIdx < messages.count,
           blockIdx >= 0, blockIdx < messages[msgIdx].blocks.count {
            let blk = messages[msgIdx].blocks[blockIdx]
            blk.helperChildSessionId = session.id
            blk.helperModel = job.modelIdentity
            blk.helperAgentName = subAgent.name
            if blk.toolSummary?.isEmpty ?? true { blk.toolSummary = childTitle }
        }
        child.subAgentBrief = SubAgentBrief(parentSessionId: parentSid,
                                            parentToolUseId: toolUseId,
                                            jobId: job.id,
                                            title: childTitle,
                                            instructions: subAgent.instructions,
                                            budgetMinutes: budgetMinutes)

        let outcome = child.submitProgrammaticPrompt(promptText, origin: .job(jobId: job.id), silent: true)
        guard outcome == .sent || outcome == .queued else {
            registry.finish(job.id, state: .failed, result: nil)
            return reject("child_start_failed", "The sub agent's session could not be started (\(outcome)). Nothing was delegated.")
        }
        registry.markRunning(job.id, sessionId: session.id)

        // Wall-clock budget. There is no per-run turn cap in the compiled tree
        // (the old HelperRunner cap left with that file), so the budget is the
        // one limit that can actually be enforced from here: at the deadline the
        // child's loop is stopped, which closes the job through the ordinary
        // loop-end path and delivers whatever it produced — with the
        // empty-result note when it produced nothing.
        let childSessionId = session.id
        job.task = Task { @MainActor [weak child] in
            try? await Task.sleep(nanoseconds: UInt64(budgetMinutes) * 60 * 1_000_000_000)
            guard !Task.isCancelled, let child, child.isProcessing else { return }
            logger.warning("[subagent_task] budget \(budgetMinutes)min elapsed — stopping child \(childSessionId.prefix(8))")
            child.cancel()
        }

        if wait {
            // Blocking mode: the caller's next step needs this result. The job
            // carries `then: .none`, so the result is returned HERE instead of
            // arriving as a separate callback.
            _ = await child.awaitProgrammaticTurn(queuedPromptId: nil)
            let text = (await AgentJobRegistry.lastAssistantText(sessionId: session.id) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let state: AgentJobState = child.userDidCancel ? .cancelled : .done
            job.task?.cancel()
            job.task = nil
            registry.finish(job.id, state: state, result: text)
            let result = text.isEmpty ? Self.emptyResultNote(status: state.rawValue) : text
            let json = Self.delegateJSON([
                "ok": !text.isEmpty,
                "status": state.rawValue,
                "job_id": job.id,
                "agent": subAgent.name,
                "child_session_id": session.id,
                "summary": job.summaryLine ?? "",
                "result": result,
            ])
            writeDelegateBlock(msgIdx: msgIdx, blockIdx: blockIdx, json)
            logger.info("[subagent_task] WAIT-DONE job=\(job.id.prefix(8)) state=\(state.rawValue) result=\(text.count)ch")
            return (json, !text.isEmpty)
        }

        var json: [String: Any] = [
            "ok": true,
            "status": "running",
            "job_id": job.id,
            "agent": subAgent.name,
            "child_session_id": session.id,
            "model": resolution.modelLabel,
            "model_origin": resolution.origin.rawValue,
            "detail": "The sub agent is working in the background in its own session. Its result arrives as a new message in this conversation (a completion card) — do NOT re-delegate the task, and do not wait: continue with anything else the user asked for. Stop it with action=cancel and its job_id.",
        ]
        if resolution.modelGroupUnavailable {
            json["model_group_unavailable"] = true
        }
        let out = Self.delegateJSON(json)
        writeDelegateBlock(msgIdx: msgIdx, blockIdx: blockIdx, out)

        // [batch7][AUD-B7-6] The background run's whole closing chain. The old
        // arm returned here with nothing attached: no progress line ever
        // reached the parent block (it sat on the "running" snapshot from the
        // start JSON), and when the run ended nothing wrote the final JSON
        // back, so the card stayed "running" until the app reloaded. Both
        // halves are keyed by tool_use id, which survives the parent's later
        // turns and reloads — indices do not.
        let startedAt = Date()
        let startedTitle = childTitle

        // (A) Live mirror: once a second, the child's current tool + activity.
        let mirror = Task { @MainActor [weak self] in
            while !Task.isCancelled, child.isProcessing {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                // Re-check AFTER the sleep: the completion hook cancels this
                // task and writes the final JSON while we may be asleep — a
                // write here would overwrite it with a stale progress line.
                guard !Task.isCancelled, child.isProcessing, let self else { return }
                let info = SessionActivityTracker.shared.sessionToolInfo[session.id]
                self.writeDelegateBlock(toolUseId: toolUseId,
                                        content: Self.progressLine(title: startedTitle,
                                                                   tool: info?.toolName ?? "",
                                                                   status: info?.toolStatus ?? AppLocalized("running in background"),
                                                                   elapsed: Date().timeIntervalSince(startedAt)),
                                        status: .running)
            }
        }

        // (B) Completion: one final JSON, whichever path closes the job.
        job.completionHook = { [weak self] finished in
            mirror.cancel()
            guard let self else { return }
            let result = finished.resultText ?? ""
            let loopStatus = finished.state == .done ? "completed" : finished.state.rawValue
            let reportedStatus = Self.resolvedStatus(loopStatus, result: result)
            var payload: [String: Any] = [
                "ok": reportedStatus == "completed",
                "status": reportedStatus,
                "result": result.isEmpty ? Self.emptyResultNote(status: loopStatus) : result,
                "agent": finished.subAgentName ?? subAgent.name,
                "child_session_id": session.id,
                "job_id": finished.id,
                "elapsed_s": Int(finished.elapsed ?? 0),
                "delivered_as": "new turn in this conversation",
                "summary": finished.summaryLine ?? "",
                "model_origin": resolution.origin.rawValue,
                "escalation_requested": result.contains("[ESCALATE]"),
                "error_kind": Self.errorKind(child.errorMessage) ?? NSNull(),
                "error_detail": child.errorMessage ?? NSNull(),
            ]
            if let identity = finished.modelIdentity {
                payload.merge(identity.payload()) { _, new in new }
            }
            let finalStatus: ToolBlockStatus = switch finished.state {
            case .done: .success
            case .cancelled: .cancelled
            case .timeout: .failed(message: AppLocalized("Timed out"))
            default: .failed(message: AppLocalized("Failed"))
            }
            let finalJSON = Self.delegateJSON(payload)
            self.writeDelegateBlock(toolUseId: toolUseId, content: finalJSON, status: finalStatus)
            self.persistFinalDelegateResult(toolUseId: toolUseId, content: finalJSON, status: finalStatus)
            logger.info("[subagent_task] BACKGROUND END job=\(finished.id.prefix(8)) state=\(finished.state.rawValue)")
        }

        logger.info("[subagent_task] STARTED job=\(job.id.prefix(8)) agent=\(subAgent.name) child=\(session.id.prefix(8)) model=\(resolution.modelLabel)")
        return (out, true)
    }

    /// The text a sub agent session is started with. Deliberately thin: the
    /// standing instructions travel in the child's identity section (they are
    /// behaviour, not a message), so the task text stays exactly what the
    /// parent wrote — it is what ends up in the transcript and in the model's
    /// context for the child's whole run.
    static func delegationPrompt(task: String, title: String, subAgent: SubAgentDefinition) -> String {
        guard !title.isEmpty else { return task }
        return "# \(title)\n\n\(task)"
    }

    /// Give the child session a thinking level, from where its MODEL came from.
    ///
    /// A pinned Model Group → that group's default; the definition's own
    /// override wins over both. Otherwise the parent conversation's level, so a
    /// delegation made from a high-effort conversation reasons like the
    /// conversation it came from. Clamped to what the resolved entry can do.
    @MainActor
    func applySubAgentThinkingLevel(subAgent: SubAgentDefinition,
                                    childSessionId: String,
                                    parentSessionId: String,
                                    entry: ModelEntry) {
        let store = ProviderConfigStore.shared
        let requested: ThinkingLevel? = {
            if let pinned = subAgent.thinkingLevelOverride { return pinned }
            if let gid = subAgent.modelGroupId, let group = store.group(for: gid) {
                return group.defaultThinkingLevel
            }
            return store.inferenceConfig(for: parentSessionId)?.thinkingLevel
        }()
        guard let requested, requested != .off else { return }
        let level = min(requested, entry.effectiveMaxThinkingLevel)
        var cfg = store.inferenceConfig(for: childSessionId) ?? SessionInferenceConfig()
        guard cfg.thinkingLevel != level else { return }
        cfg.thinkingLevel = level
        store.setInferenceConfig(cfg, for: childSessionId)
        logger.info("[subagent_task] thinking=\(level.rawValue) on child \(childSessionId.prefix(8))")
    }
}


// MARK: - [batch7] Resume an interrupted sub agent from its persisted block

extension AIChatViewModel {
    /// [batch7][T-sub-agents-resume-from-block] Restart a sub agent whose run
    /// was interrupted (app killed, crash) so its parent block still reads
    /// "interrupted" and no registry job exists any more.
    ///
    /// The live `resumeSubAgentTask` path needs the ORIGINAL job (its id and
    /// target); after a relaunch the registry is empty — which is exactly the
    /// state this button exists for. Everything is rebuilt from persisted
    /// facts: the child session row (parent linkage), the parent's block
    /// (tool_use id + result JSON), and the roster. The resumed run then
    /// continues through the same child pool, budget and callback channel as
    /// a fresh delegation.
    ///
    /// Returns nil on success, or a human-readable reason on refusal.
    @MainActor
    func resumeInterruptedHelper(childSessionId childId: String) async -> String? {
        guard !isSubAgentChild else { return "a sub agent cannot resume another" }
        guard let parentSid = sessionId else { return "no session" }
        guard await ChatStore.shared.sessionExists(id: childId) else {
            return "that sub agent's session no longer exists"
        }
        let registry = AgentJobRegistry.shared
        // Already running (double tap, or resumed from another surface).
        if registry.list().contains(where: { $0.runSessionId == childId
            && ($0.state == .running || $0.state == .pending) }) {
            return nil
        }

        // ── Rebuild the identity from persisted state ────────────────────
        guard let childSession = await ChatStore.shared.getSession(childId),
              let toolUseId = childSession.parentToolUseId,
              childSession.parentSessionId == parentSid else {
            return "that sub agent is not part of this conversation"
        }
        var parentBlock: AssistantBlock?
        for msg in messages {
            if let b = msg.blocks.first(where: { $0.toolUseId == toolUseId }) {
                parentBlock = b
                break
            }
        }
        var payload: [String: Any]?
        if let parentBlock {
            payload = AIChatViewModel.parseDelegateResult(parentBlock.content)
        }
        var title = AppLocalized("Agent")
        if let t = payload?["title"] as? String, !t.isEmpty {
            title = t
        } else if let t = childSession.title, !t.isEmpty {
            title = t
        }
        // The definition may have been renamed or deleted while the app was
        // away; falling back to the built-in keeps the run possible, and the
        // result records which one actually ran.
        var agentName = payload?["agent"] as? String
        if agentName?.isEmpty ?? true { agentName = parentBlock?.helperAgentName }
        let roster = SubAgentStore.shared.subAgents
        var subAgent = roster.first { $0.isBuiltIn } ?? SubAgentDefinition.makeBuiltIn()
        var namedAgentMissing: String?
        if let agentName, !agentName.isEmpty {
            if let named = roster.first(where: { $0.name == agentName }) {
                subAgent = named
            } else {
                namedAgentMissing = agentName
                logger.warning("[subagent_task] RESUME agent \(agentName) no longer exists — falling back to the built-in")
            }
        }

        guard let resolution = SubAgentModelResolver.resolve(subAgent: subAgent, parent: self) else {
            return "no model is configured to run it on"
        }

        // ── Child VM: same pool + session setup as a fresh delegation ────
        let (child, fresh) = ViewModelCache.shared.getOrCreate(for: childId)
        if fresh || child.messages.isEmpty { await child.loadSession() }
        guard !child.isProcessing else {
            return "that sub agent's session is busy with a turn right now; try again in a moment"
        }
        child.sessionSource = "helper"
        child.memoryEnabled = false
        child.suppressGeneralCompletionNotification = true

        let job = registry.register(title: title, origin: .tool, trigger: .immediate,
                                    target: .childOfCurrent(parentSessionId: parentSid,
                                                            parentToolUseId: toolUseId),
                                    prompt: nil, then: .followUpParent(template: nil))
        job.subAgentName = subAgent.name
        job.modelOrigin = resolution.origin.rawValue
        job.modelIdentity = HelperModelIdentity.make(resolution: resolution)
        job.wasResumed = true

        child.subAgentBrief = SubAgentBrief(parentSessionId: parentSid,
                                            parentToolUseId: toolUseId,
                                            jobId: job.id,
                                            title: title,
                                            instructions: subAgent.instructions,
                                            budgetMinutes: AIChatViewModel.helperMaxMinutes)
        ProviderConfigStore.shared.setBinding(
            SessionModelBinding(sessionId: childId, primarySource: resolution.source), for: childId)
        // A resumed run re-resolves its model, so it re-seeds the thinking
        // level too — otherwise resume silently drops it for the rest of the run.
        applySubAgentThinkingLevel(subAgent: subAgent, childSessionId: childId,
                                   parentSessionId: parentSid, entry: resolution.entry)

        // [T-sub-agents-resume] Re-attach the child to its parent block — the
        // same link a fresh delegation makes. Without it the block keeps a nil
        // helperChildSessionId and every surface that reaches the child
        // through it goes dead (the transcript button's JSON fallback stops
        // working the moment the resumed run overwrites `content`).
        for msg in messages where msg.role == .assistant {
            if let block = msg.blocks.first(where: { $0.toolUseId == toolUseId }) {
                block.helperChildSessionId = childId
                block.helperModel = job.modelIdentity
                block.helperAgentName = subAgent.name
                if block.toolSummary?.isEmpty ?? true { block.toolSummary = title }
                break
            }
        }

        // ── Continue the run ─────────────────────────────────────────────
        let outcome = child.submitProgrammaticPrompt(Self.subAgentResumeNotice,
                                                     origin: .job(jobId: job.id), silent: true)
        guard outcome == .sent else {
            job.then = AgentJobThen.none
            registry.finish(job.id, state: .failed, result: nil)
            return "the sub agent session did not restart (\(String(describing: outcome)))"
        }
        registry.markRunning(job.id, sessionId: childId)
        // Budget restarts: the original one died with the process.
        job.task = Task { @MainActor [weak child] in
            try? await Task.sleep(nanoseconds: UInt64(AIChatViewModel.helperMaxMinutes) * 60 * 1_000_000_000)
            guard !Task.isCancelled, let child, child.isProcessing else { return }
            logger.warning("[subagent_task] budget \(AIChatViewModel.helperMaxMinutes)min elapsed — stopping resumed child \(childId.prefix(8))")
            child.cancel()
        }
        if let missing = namedAgentMissing {
            transientNotice = String(format: AppLocalized("Sub agent \"%@\" no longer exists — resumed with the built-in agent"), missing)
        }
        logger.info("[subagent_task] RESUME-FROM-BLOCK job=\(job.id.prefix(8)) child=\(childId.prefix(8)) parent=\(parentSid.prefix(8)) agent=\(subAgent.name)")
        return nil
    }
}
