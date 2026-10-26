import XCTest

/// [S3-1][evolution] Extractor tests — pure rules over synthetic actions,
/// plus one integration pass against a temporary store. Nothing here touches
/// UserDefaults or the real evolution.db.
final class EvolutionExtractorTests: XCTestCase {

    private func action(_ id: String, run: String, seq: Int, tool: String,
                        status: EvolutionActionStatus,
                        errorClass: String? = nil,
                        profile: String = "") -> EvolutionAction {
        EvolutionAction(id: id, runId: run, seq: seq, toolName: tool, profile: profile,
                        status: status, errorClass: errorClass, errorDigest: nil,
                        durationMs: 1, retryCount: 0, resultDigest: nil)
    }

    // MARK: - Rules

    func testFailureClusterBelowThresholdIsSilent() {
        let two = [
            action("a1", run: "r1", seq: 1, tool: "shell_execute", status: .fail, errorClass: "tool_error"),
            action("a2", run: "r2", seq: 1, tool: "shell_execute", status: .fail, errorClass: "tool_error"),
        ]
        XCTAssertTrue(EvolutionExtractor.lessons(from: two).isEmpty)
    }

    func testFailureClusterAtThresholdMakesCandidate() {
        let three = [
            action("a1", run: "r1", seq: 1, tool: "shell_execute", status: .fail, errorClass: "tool_error"),
            action("a2", run: "r2", seq: 1, tool: "shell_execute", status: .fail, errorClass: "tool_error"),
            action("a3", run: "r3", seq: 1, tool: "shell_execute", status: .fail, errorClass: "tool_error"),
        ]
        let lessons = EvolutionExtractor.lessons(from: three)
        XCTAssertEqual(lessons.count, 1)
        let lesson = lessons.first
        XCTAssertEqual(lesson?.id, "evo-tool-shell_execute")
        XCTAssertEqual(lesson?.status, .candidate)
        XCTAssertEqual(lesson?.failureCount, 3)
        XCTAssertEqual(lesson?.injectPriority, 5)
        XCTAssertTrue(lesson?.evidenceActions.contains("a1") ?? false)
    }

    func testRecoveryNeedsTwoWitnesses() {
        let onePair = [
            action("f1", run: "r1", seq: 1, tool: "web_fetch", status: .fail, errorClass: "tool_error"),
            action("s1", run: "r1", seq: 2, tool: "web_fetch", status: .success, profile: "adjusted"),
        ]
        XCTAssertTrue(EvolutionExtractor.lessons(from: onePair).isEmpty)

        let twoPairs = onePair + [
            action("f2", run: "r2", seq: 1, tool: "web_fetch", status: .fail, errorClass: "tool_error"),
            action("s2", run: "r2", seq: 2, tool: "web_fetch", status: .success, profile: "adjusted"),
        ]
        let lessons = EvolutionExtractor.lessons(from: twoPairs)
        XCTAssertEqual(lessons.count, 1)
        XCTAssertEqual(lessons.first?.status, .candidate)
        XCTAssertEqual(lessons.first?.successCount, 2)
    }

    func testSameProfileRetryIsNotRecovery() {
        // P6-5: identical params that happen to succeed must NOT count as
        // "调整后成功" — only adjusted retries feed recovery lessons.
        let sameParamPairs = [
            action("f1", run: "r1", seq: 1, tool: "web_fetch", status: .fail, errorClass: "tool_error", profile: "same"),
            action("s1", run: "r1", seq: 2, tool: "web_fetch", status: .success, profile: "same"),
            action("f2", run: "r2", seq: 1, tool: "web_fetch", status: .fail, errorClass: "tool_error", profile: "same"),
            action("s2", run: "r2", seq: 2, tool: "web_fetch", status: .success, profile: "same"),
        ]
        XCTAssertTrue(EvolutionExtractor.lessons(from: sameParamPairs).isEmpty)

        // Mixed: one adjusted pair is not enough (needs >= 2 witnesses).
        let oneAdjusted = sameParamPairs + [
            action("f3", run: "r3", seq: 1, tool: "web_fetch", status: .fail, errorClass: "tool_error"),
            action("s3", run: "r3", seq: 2, tool: "web_fetch", status: .success, profile: "adjusted"),
        ]
        XCTAssertTrue(EvolutionExtractor.lessons(from: oneAdjusted).isEmpty)
    }

    func testRecoveryWindowIsRespected() {
        // Fail at seq 1, success 8 actions later (> 6-step window) → no pair.
        var actions = [
            action("f1", run: "r1", seq: 1, tool: "web_fetch", status: .fail, errorClass: "tool_error"),
        ]
        for i in 2...8 {
            actions.append(action("x\(i)", run: "r1", seq: i, tool: "other_tool", status: .success))
        }
        actions.append(action("s9", run: "r1", seq: 9, tool: "web_fetch", status: .success))
        XCTAssertTrue(EvolutionExtractor.lessons(from: actions).isEmpty)
    }

    func testCancelledIsNotAFailure() {
        let cancelled = [
            action("c1", run: "r1", seq: 1, tool: "shell_execute", status: .cancelled, errorClass: "cancelled"),
            action("c2", run: "r2", seq: 1, tool: "shell_execute", status: .cancelled, errorClass: "cancelled"),
            action("c3", run: "r3", seq: 1, tool: "shell_execute", status: .cancelled, errorClass: "cancelled"),
        ]
        XCTAssertTrue(EvolutionExtractor.lessons(from: cancelled).isEmpty)
    }

    func testConflictingSignalsFreezeLesson() {
        let mixed = [
            action("f1", run: "r1", seq: 1, tool: "shell_execute", status: .fail, errorClass: "tool_error"),
            action("f2", run: "r2", seq: 1, tool: "shell_execute", status: .fail, errorClass: "tool_error"),
            action("f3", run: "r3", seq: 1, tool: "shell_execute", status: .fail, errorClass: "tool_error"),
            action("f4", run: "r4", seq: 1, tool: "shell_execute", status: .fail, errorClass: "tool_error"),
            action("s4", run: "r4", seq: 2, tool: "shell_execute", status: .success),
            action("f5", run: "r5", seq: 1, tool: "shell_execute", status: .fail, errorClass: "tool_error"),
            action("s5", run: "r5", seq: 2, tool: "shell_execute", status: .success),
        ]
        let lessons = EvolutionExtractor.lessons(from: mixed)
        XCTAssertEqual(lessons.count, 1)
        XCTAssertEqual(lessons.first?.status, .conflicts)
        XCTAssertEqual(lessons.first?.failureCount, 5)
        XCTAssertEqual(lessons.first?.successCount, 2)
    }

    func testDeterministicIDsAcrossRuns() {
        let input = [
            action("a1", run: "r1", seq: 1, tool: "Shell Execute.v2", status: .fail, errorClass: "tool_error"),
            action("a2", run: "r2", seq: 1, tool: "Shell Execute.v2", status: .fail, errorClass: "tool_error"),
            action("a3", run: "r3", seq: 1, tool: "Shell Execute.v2", status: .fail, errorClass: "tool_error"),
        ]
        let first = EvolutionExtractor.lessons(from: input)
        let second = EvolutionExtractor.lessons(from: input)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(first.first?.id, "evo-tool-shell-execute-v2")
    }

    // MARK: - Queue integration (temp store)

    private func makeStore() throws -> (EvolutionStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("evo-ex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try EvolutionStore(url: dir.appendingPathComponent("evolution.db"))
        return (store, dir)
    }

    func testQueuePassWritesLessonsAndBumpsVersion() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<3 {
            await store.insert(EvolutionAction(
                id: "f\(i)", runId: "r\(i)", seq: 1, toolName: "shell_execute", profile: "",
                status: .fail, errorClass: "tool_error", errorDigest: nil,
                durationMs: 1, retryCount: 0, resultDigest: nil
            ), createdAt: Date().addingTimeInterval(Double(i)))
        }
        let recent = await store.recentActions(limit: 10)
        XCTAssertEqual(recent.count, 3)
        XCTAssertEqual(recent.first?.toolName, "shell_execute")
        XCTAssertEqual(recent.first?.status, .fail)
        XCTAssertEqual(recent.first?.errorClass, "tool_error")

        let queue = EvolutionExtractionQueue()
        await queue.runPass(on: store)
        var candidates = await store.lessons(status: .candidate)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.version, 1)
        var states = await store.lessonStateMap()
        XCTAssertEqual(states["evo-tool-shell_execute"]?.status, "candidate")

        await queue.runPass(on: store)   // idempotent merge → version bump
        candidates = await store.lessons(status: .candidate)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.version, 2)
        states = await store.lessonStateMap()
        XCTAssertEqual(states["evo-tool-shell_execute"]?.version, 2)
    }

    func testVerifiedLessonIsNeverClobbered() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<3 {
            await store.insert(EvolutionAction(
                id: "f\(i)", runId: "r\(i)", seq: 1, toolName: "shell_execute", profile: "",
                status: .fail, errorClass: "tool_error", errorDigest: nil,
                durationMs: 1, retryCount: 0, resultDigest: nil
            ), createdAt: Date().addingTimeInterval(Double(i)))
        }
        let queue = EvolutionExtractionQueue()
        await queue.runPass(on: store)

        // Simulate the human审核: mark verified (same id, INSERT OR REPLACE).
        let candidateRows = await store.lessons(status: .candidate)
        var lesson = try XCTUnwrap(candidateRows.first)
        lesson.status = .verified
        await store.insert(lesson)

        await queue.runPass(on: store)   // must NOT clobber the verified row

        let verified = await store.lessons(status: .verified)
        XCTAssertEqual(verified.count, 1)
        XCTAssertEqual(verified.first?.version, 1)
        let candidates = await store.lessons(status: .candidate)
        XCTAssertTrue(candidates.isEmpty)
    }

    func testUpdateLessonStatusBumpsVersionAndReportsMiss() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<3 {
            await store.insert(EvolutionAction(
                id: "f\(i)", runId: "r\(i)", seq: 1, toolName: "shell_execute", profile: "",
                status: .fail, errorClass: "tool_error", errorDigest: nil,
                durationMs: 1, retryCount: 0, resultDigest: nil
            ), createdAt: Date().addingTimeInterval(Double(i)))
        }
        let queue = EvolutionExtractionQueue()
        await queue.runPass(on: store)

        let ok = await store.updateLessonStatus(id: "evo-tool-shell_execute", status: .verified)
        XCTAssertTrue(ok)
        let verified = await store.lessons(status: .verified)
        XCTAssertEqual(verified.count, 1)
        XCTAssertEqual(verified.first?.version, 2)

        // 回滚 = 状态指针切回 + version 再 +1（只增不改）。
        let rollback = await store.updateLessonStatus(id: "evo-tool-shell_execute", status: .candidate)
        XCTAssertTrue(rollback)
        let candidates = await store.lessons(status: .candidate)
        XCTAssertEqual(candidates.first?.version, 3)

        let miss = await store.updateLessonStatus(id: "does-not-exist", status: .deprecated)
        XCTAssertFalse(miss)
    }
}
