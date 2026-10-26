import Foundation

/// [S2-2][evolution] Recording hooks — the ONLY glue between the app's tool
/// traffic and the evolution store. Additive by construction: when recording
/// is disabled every entry point returns immediately, so the hot path pays a
/// single UserDefaults bool read and nothing else. "开关关 = 零采集".
///
/// Discipline (design doc §5):
///   • arguments / result text NEVER land raw — everything passes through
///     EvolutionRedactor, and oversized inputs are pre-trimmed BEFORE
///     scrubbing so one giant file_write can not stall the recorder;
///   • all DB work happens in fire-and-forget detached Tasks (the store is an
///     actor), so a slow disk can not stall a chat turn — "聊天零卡顿";
///   • failure mode is "lost trace line", never "failed tool call".
///
/// No retrieval, no prompt injection, no UI — those are later steps (S3+).
///
/// Spool note: the "spool" is per-event detached delivery into the serialized
/// actor store (WAL) — no intermediate disk file by design. A dropped event
/// costs one trace line; nothing in the chat path depends on a write landing.
enum EvolutionRecorder {

    /// Input budget handed to the redactor: characters scanned per field.
    /// Beyond this the tail is dropped before scrubbing (it could never
    /// survive the digest cap anyway — only the first ~200 chars are kept).
    private static let scanBudget = 3_000

    // MARK: - Run lifecycle

    /// Open a run scope for one agent-loop invocation. Returns "" when
    /// recording is off — all later record calls no-op on an empty run id.
    static func beginRun(sessionId: String?, source: String) -> String {
        guard EvolutionSettings.recordingEnabled else { return "" }
        let runId = UUID().uuidString
        let startedAt = Date()
        Task.detached(priority: .utility) { [runId, sessionId, source, startedAt] in
            guard let store = EvolutionStore.shared else { return }
            await EvolutionRunTracker.shared.begin(
                runId: runId, startedAt: startedAt, sessionId: sessionId, source: source
            )
            await store.insert(EvolutionRun(
                id: runId, sessionId: sessionId, personaId: nil, taskSignature: nil,
                startedAt: startedAt, endedAt: nil, status: .ok,
                turnCount: 0, toolCallCount: 0, retryCount: 0, tokensEst: 0,
                modelId: nil, source: source
            ))
        }
        return runId
    }

    /// Close a run scope. `cancelled` outranks ok; finer error states are an
    /// S3 refinement — a `defer` can not observe the loop's throw sites.
    /// The run row is reassembled from tracker stats so the INSERT OR REPLACE
    /// in the store keeps the fields captured at `beginRun`.
    static func endRun(runId: String, cancelled: Bool, tokensEst: Int) {
        guard !runId.isEmpty, EvolutionSettings.recordingEnabled else { return }
        let endedAt = Date()
        Task.detached(priority: .utility) { [runId, cancelled, tokensEst, endedAt] in
            guard let store = EvolutionStore.shared else { return }
            let stats = await EvolutionRunTracker.shared.finish(runId: runId)
            guard let stats else { return }
            let run = EvolutionRun(
                id: runId,
                sessionId: stats.sessionId,
                personaId: nil,
                taskSignature: nil,
                startedAt: stats.startedAt,
                endedAt: endedAt,
                status: cancelled ? .cancelled : .ok,
                turnCount: 0,
                toolCallCount: stats.actionCount,
                retryCount: 0,
                tokensEst: tokensEst,
                modelId: nil,
                source: stats.source
            )
            await store.insert(run)
            // [S3-1][evolution] kick the rule extractor — throttled inside,
            // fire-and-forget, never blocks the caller.
            EvolutionExtractionQueue.schedule()
        }
    }

    // MARK: - Tool action recording

    /// Record one tool execution. Called from the dispatcher right after a
    /// tool outcome returns — primitives only, so no app types leak in here.
    /// Everything expensive (redaction, trimming) happens synchronously but
    /// off the MainActor (the dispatcher's child task), and the DB write is
    /// detached on top of that.
    static func recordAction(runId: String, toolName: String, arguments: [String: Any],
                             cancelled: Bool, isError: Bool, resultText: String,
                             startedAt: Date) {
        guard !runId.isEmpty, EvolutionSettings.recordingEnabled else { return }

        // Pre-trim oversized values before the scrubber ever sees them.
        let trimmedArgs: [String: Any] = arguments.mapValues { value -> Any in
            if let s = value as? String, s.count > scanBudget {
                return String(s.prefix(scanBudget))
            }
            return value
        }
        let profile = EvolutionRedactor.profile(trimmedArgs)
        let status = mapStatus(cancelled: cancelled, isError: isError)
        let errorDigest = isError
            ? EvolutionRedactor.digest(String(resultText.prefix(scanBudget)), limit: 160)
            : nil
        let resultDigest = (isError || cancelled)
            ? nil
            : EvolutionRedactor.digest(String(resultText.prefix(scanBudget)))
        let durationMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
        let finishedAt = Date()
        let errorClass: String? = cancelled
            ? "cancelled"
            : (isError ? Self.classifyError(resultText) : nil)

        Task.detached(priority: .utility) {
            guard let store = EvolutionStore.shared else { return }
            let seq = await EvolutionRunTracker.shared.nextSeq(runId: runId)
            let action = EvolutionAction(
                id: UUID().uuidString,
                runId: runId,
                seq: seq,
                toolName: toolName,
                profile: profile,
                status: status,
                errorClass: errorClass,
                errorDigest: errorDigest,
                durationMs: durationMs,
                retryCount: 0,
                resultDigest: resultDigest
            )
            await store.insert(action, createdAt: finishedAt)
        }
    }

    /// Outcome → status mapping (pure, unit-tested).
    static func mapStatus(cancelled: Bool, isError: Bool) -> EvolutionActionStatus {
        if cancelled { return .cancelled }
        return isError ? .fail : .success
    }

    /// Sorts a failed tool call into "the tool refused" vs "the app is broken".
    ///
    /// Everything used to be recorded as `tool_error`, and the extractor's only
    /// rule keys on exactly that string. So a failure caused by the app — a
    /// missing mount, a denied entitlement, a path the sandbox will not reach —
    /// was fed to the lesson builder as if the model had used the tool wrong.
    /// The resulting lesson tells it to retry with different arguments, which
    /// cannot work, and the next run repeats the same wall. Splitting the
    /// classes keeps those cases out of the retry lessons entirely.
    static func classifyError(_ resultText: String) -> String {
        let text = resultText.lowercased()
        let hostMarkers = [
            "no such file or directory", "permission denied", "operation not permitted",
            "not mounted", "mount table", "entitlement", "sandbox",
            "errno", "eacces", "enoent", "code=513", "-34018",
            "未授权", "没有权限", "找不到路径",
        ]
        if hostMarkers.contains(where: { text.contains($0) }) {
            return "host_error"
        }
        return "tool_error"
    }
}

// MARK: - Per-run bookkeeping

/// Seq counters and action counts per run, kept OUT of SQLite so the hot
/// path never pays a read-modify-write against the DB. Bounded: if a run
/// never finishes (process killed), its entry is dropped on the next `begin`
/// once the table exceeds `maxTrackedRuns`.
actor EvolutionRunTracker {

    static let shared = EvolutionRunTracker()

    struct RunStats {
        var startedAt: Date
        var sessionId: String?
        var source: String
        var actionCount: Int
    }

    private var runs: [String: RunStats] = [:]
    private let maxTrackedRuns = 128

    func begin(runId: String, startedAt: Date, sessionId: String?, source: String) {
        if runs.count >= maxTrackedRuns {
            // Drop the least recently begun run — it is at most a stale
            // open scope whose endRun will degrade to "nothing to finish".
            if let oldest = runs.min(by: { $0.value.startedAt < $1.value.startedAt })?.key {
                runs.removeValue(forKey: oldest)
            }
        }
        runs[runId] = RunStats(startedAt: startedAt, sessionId: sessionId,
                               source: source, actionCount: 0)
    }

    func nextSeq(runId: String) -> Int {
        var stats = runs[runId] ?? RunStats(startedAt: Date(), sessionId: nil,
                                            source: "chat", actionCount: 0)
        stats.actionCount += 1
        let seq = stats.actionCount
        runs[runId] = stats
        return seq
    }

    func finish(runId: String) -> RunStats? {
        runs.removeValue(forKey: runId)
    }
}
