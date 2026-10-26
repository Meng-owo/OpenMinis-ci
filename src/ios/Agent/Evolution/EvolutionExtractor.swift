import Foundation

/// [S3-1][evolution] Rule-based extractor — turns recorded tool traces into
/// candidate lessons. Zero model cost, deterministic, offline.
///
/// Design doc §6 (v1 rules):
///   • **failure clustering**: the same tool failing with `tool_error` at
///     least `failureClusterMin` times in the window → candidate anti-pattern
///     lesson ("check preconditions before calling; don't blind-retry").
///   • **recovery witnesses**: fail → adjusted success (same tool, same run,
///     within `recoveryWindowSteps` actions) witnessed at least `recoveryMin`
///     times → candidate lesson ("diagnose, adjust, then retry works here").
///   • **conflict freeze**: both signals for the same tool → one lesson with
///     status `.conflicts` — frozen, never injected, pending human review.
///   • **dedupe**: lesson ids are deterministic per tool (`evo-tool-<slug>`),
///     so repeated passes MERGE instead of duplicating; the queue bumps the
///     version instead of stacking rows.
///
/// The extractor itself is a pure function over `[EvolutionAction]` — no DB,
/// no clock, no UserDefaults — so every rule is unit-tested offline.
enum EvolutionExtractor {

    enum Thresholds {
        /// Same tool × tool_error ≥ this in the window → failure lesson.
        static let failureClusterMin = 3
        /// Adjusted-retry successes ≥ this → recovery lesson.
        static let recoveryMin = 2
        /// A recovery success must appear within this many actions after the
        /// failure (same run) to count as one witness.
        static let recoveryWindowSteps = 6
        /// Hard cap on evidence action ids attached to one lesson.
        static let maxEvidence = 20
    }

    // MARK: - Rules

    static func lessons(from actions: [EvolutionAction]) -> [EvolutionLesson] {
        var toolOrder: Set<String> = []
        var failuresByTool: [String: [EvolutionAction]] = [:]
        var recoveriesByTool: [String: [(fail: EvolutionAction, success: EvolutionAction)]] = [:]

        // Rule 1 inputs: tool_error failures per tool.
        //
        // `host_error` is deliberately excluded. Those failures come from the
        // app (mounts, entitlements, sandboxed paths), not from how the model
        // called the tool, so a "try different arguments" lesson is worse than
        // no lesson: it sends the next run straight back into the same wall.
        // They are still recorded and shown in the evolution centre.
        for action in actions where action.status == .fail {
            let errorClass = action.errorClass ?? "tool_error"
            guard errorClass == "tool_error" else { continue }
            toolOrder.insert(action.toolName)
            failuresByTool[action.toolName, default: []].append(action)
        }

        // Rule 2 inputs: fail → success pairs inside a single run.
        let byRun = Dictionary(grouping: actions, by: { $0.runId })
        for (_, runActions) in byRun {
            let ordered = runActions.sorted { $0.seq < $1.seq }
            guard ordered.count > 1 else { continue }
            for (index, action) in ordered.enumerated() where action.status == .fail {
                let end = min(ordered.count - 1, index + Thresholds.recoveryWindowSteps)
                guard end > index else { continue }
                for probe in (index + 1)...end {
                    let candidate = ordered[probe]
                    // P6-5: adjusted retry — same tool AND different params/profile.
                    // Identical re-invocation that happened to succeed is not
                    // "调整后成功" and must not feed recovery lessons.
                    if candidate.toolName == action.toolName, candidate.status == .success,
                       candidate.profile != action.profile {
                        toolOrder.insert(action.toolName)
                        recoveriesByTool[action.toolName, default: []].append((fail: action, success: candidate))
                        break
                    }
                }
            }
        }

        // Compose one lesson per tool where at least one rule fired.
        var lessons: [EvolutionLesson] = []
        for tool in toolOrder.sorted() {
            let failures = failuresByTool[tool] ?? []
            let recoveries = recoveriesByTool[tool] ?? []
            let hasFailureLesson = failures.count >= Thresholds.failureClusterMin
            let hasRecoveryLesson = recoveries.count >= Thresholds.recoveryMin
            guard hasFailureLesson || hasRecoveryLesson else { continue }

            let evidence = evidenceIDs(failures: failures, recoveries: recoveries)
            let lesson: EvolutionLesson
            if hasFailureLesson && hasRecoveryLesson {
                lesson = EvolutionLesson(
                    id: "evo-tool-\(slugify(tool))",
                    scope: "global", personaId: nil, taskSignature: tool,
                    conditions: "工具 \(tool)：反复失败 \(failures.count) 次，但同时有调整后重试成功 \(recoveries.count) 次——信号冲突，冻结待审",
                    recommendation: "人工审核：决定保留「先诊断再重试」还是「改用替代路径」哪一侧建议。",
                    antiPattern: nil,
                    evidenceActions: evidence,
                    status: .conflicts,
                    successCount: recoveries.count, failureCount: failures.count,
                    version: 1, parentId: nil, lastVerifiedAt: nil, injectPriority: 0
                )
            } else if hasFailureLesson {
                lesson = EvolutionLesson(
                    id: "evo-tool-\(slugify(tool))",
                    scope: "global", personaId: nil, taskSignature: tool,
                    conditions: "工具 \(tool) 近期失败 \(failures.count) 次（error_class=tool_error）",
                    recommendation: "调用 \(tool) 前先核对前置条件与参数；已失败时先换思路或询问用户，避免无调整的连续重试。",
                    antiPattern: "\(tool) 失败后不做调整的连续重试",
                    evidenceActions: evidence,
                    status: .candidate,
                    successCount: 0, failureCount: failures.count,
                    version: 1, parentId: nil, lastVerifiedAt: nil, injectPriority: 5
                )
            } else {
                lesson = EvolutionLesson(
                    id: "evo-tool-\(slugify(tool))",
                    scope: "global", personaId: nil, taskSignature: tool,
                    conditions: "工具 \(tool) 失败后调整重试成功 \(recoveries.count) 次（同 run ≤\(Thresholds.recoveryWindowSteps) 步内）",
                    recommendation: "\(tool) 失败时先诊断成因、调整参数或路径再重试——历史上这样能成功。",
                    antiPattern: nil,
                    evidenceActions: evidence,
                    status: .candidate,
                    successCount: recoveries.count, failureCount: failures.count,
                    version: 1, parentId: nil, lastVerifiedAt: nil, injectPriority: 3
                )
            }
            lessons.append(lesson)
        }
        return lessons
    }

    // MARK: - Helpers

    private static func evidenceIDs(failures: [EvolutionAction],
                                    recoveries: [(fail: EvolutionAction, success: EvolutionAction)]) -> String {
        var ids: [String] = []
        for action in failures { ids.append(action.id) }
        for pair in recoveries {
            ids.append(pair.fail.id)
            ids.append(pair.success.id)
        }
        let capped = Array(ids.prefix(Thresholds.maxEvidence))
        if let data = try? JSONSerialization.data(withJSONObject: capped),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "[]"
    }

    /// Deterministic, filesystem-safe lesson id component.
    static func slugify(_ text: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-")
        var out = ""
        for scalar in text.lowercased().unicodeScalars {
            if allowed.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else if scalar == " " || scalar == "." || scalar == "/" {
                out.append("-")
            }
        }
        let collapsed = out.split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return collapsed.isEmpty ? "unknown" : collapsed
    }
}

// MARK: - [S3-1][evolution] Extraction queue (throttled, non-blocking)

/// Kicked at run end by the recorder; runs at most one extraction pass per
/// `minInterval`. The queue never blocks the caller — `schedule()` is a
/// fire-and-forget that returns immediately.
///
/// Rollback ("停调度"): `EvolutionExtractionQueue.stop()` — or the recording
/// switch off, which also drains nothing new in. User-owned lesson decisions
/// (verified/deprecated) are never clobbered by a pass.
actor EvolutionExtractionQueue {

    static let shared = EvolutionExtractionQueue()

    /// At most one pass per 5 minutes; cheap enough, fresh enough.
    static let minInterval: TimeInterval = 300

    nonisolated private static let enabledKey = "evolution.extractionEnabled"

    /// Kill switch, default ON. Recording off also disables extraction (no
    /// new data would exist anyway).
    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Rollback path — stop scheduling without touching recorded data.
    nonisolated static func stop() {
        UserDefaults.standard.set(false, forKey: enabledKey)
    }

    nonisolated static func resume() {
        UserDefaults.standard.set(true, forKey: enabledKey)
    }

    /// Fire-and-forget kick from the recorder's run-end task.
    nonisolated static func schedule() {
        guard isEnabled, EvolutionSettings.recordingEnabled else { return }
        Task.detached(priority: .utility) {
            await EvolutionExtractionQueue.shared.runPassIfDue()
        }
    }

    private var lastPassAt: Date?
    private var inFlight = false

    /// Throttled entry: pass only if due and nothing is in flight.
    func runPassIfDue() async {
        guard Self.isEnabled, EvolutionSettings.recordingEnabled else { return }
        guard !inFlight else { return }
        if let last = lastPassAt, Date().timeIntervalSince(last) < Self.minInterval { return }
        inFlight = true
        defer { inFlight = false }
        guard let store = EvolutionStore.shared else { return }
        lastPassAt = Date()
        await performPass(store: store)
    }

    /// One pass against an explicit store — tests, and the future UI button
    /// ("立即整理一次").
    func runPass(on store: EvolutionStore) async {
        await performPass(store: store)
    }

    // MARK: Internals

    private func performPass(store: EvolutionStore) async {
        let actions = await store.recentActions(limit: 5000)
        guard !actions.isEmpty else { return }
        let lessons = EvolutionExtractor.lessons(from: actions)
        guard !lessons.isEmpty else { return }
        let states = await store.lessonStateMap()
        let managedStatuses: Set<String> = [
            EvolutionLessonStatus.candidate.rawValue,
            EvolutionLessonStatus.conflicts.rawValue,
        ]
        for lesson in lessons {
            var row = lesson
            if let existing = states[lesson.id] {
                // Never clobber a human decision.
                guard managedStatuses.contains(existing.status) else { continue }
                row.version = existing.version + 1
            }
            await store.insert(row)
        }
    }
}
