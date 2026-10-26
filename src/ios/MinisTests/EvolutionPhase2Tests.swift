import XCTest

/// [S2-1][evolution] Foundation tests: redaction rules + `evolution.db`
/// round-trips. No app-flow side effects — the store under test runs against
/// a temp-directory database, never the real Library/MinisChat/evolution.db,
/// and nothing here touches UserDefaults (settings-value assertions are
/// deliberately read-free: the test process must not write into the app's
/// preferences domain).
final class EvolutionPhase2Tests: XCTestCase {

    // MARK: - Redactor: key blacklist

    func testSensitiveKeysAreBlacklisted() {
        XCTAssertTrue(EvolutionRedactor.isSensitive(argumentKey: "api_key"))
        XCTAssertTrue(EvolutionRedactor.isSensitive(argumentKey: "Authorization"))
        XCTAssertTrue(EvolutionRedactor.isSensitive(argumentKey: "x-auth-token"))
        XCTAssertTrue(EvolutionRedactor.isSensitive(argumentKey: "clientSecret"))
        XCTAssertTrue(EvolutionRedactor.isSensitive(argumentKey: "OPENAI_API_KEY"))
        XCTAssertFalse(EvolutionRedactor.isSensitive(argumentKey: "text"))
        XCTAssertFalse(EvolutionRedactor.isSensitive(argumentKey: "path"))
        XCTAssertFalse(EvolutionRedactor.isSensitive(argumentKey: "query"))
        XCTAssertFalse(EvolutionRedactor.isSensitive(argumentKey: "model"))
    }

    func testSensitiveArgumentValuesNeverReachProfile() {
        let profile = EvolutionRedactor.profile([
            "api_key": "sk-live-abcdef1234567890abcdef",
            "text": "hello world",
        ])
        XCTAssertFalse(profile.contains("sk-live"))
        XCTAssertTrue(profile.contains("<redacted:String>"))
        XCTAssertTrue(profile.contains("text=hello world"))
    }

    // MARK: - Redactor: value scrubbing

    func testPrefixedKeysAreScrubbed() {
        let scrubbed = EvolutionRedactor.scrub("use sk-abc123def456ghi789 then done")
        XCTAssertFalse(scrubbed.contains("sk-abc123def456ghi789"))
        XCTAssertTrue(scrubbed.contains("[redacted-key]"))
    }

    func testBearerTokensAreScrubbed() {
        let scrubbed = EvolutionRedactor.scrub("Authorization: Bearer abcDEF123456.xyz-_")
        XCTAssertFalse(scrubbed.contains("abcDEF123456"))
    }

    func testNameValuePairsAreScrubbed() {
        let scrubbed = EvolutionRedactor.scrub("token=abcd1234efgh & password: hunter2xx")
        XCTAssertFalse(scrubbed.contains("abcd1234efgh"))
        XCTAssertFalse(scrubbed.contains("hunter2xx"))
        XCTAssertTrue(scrubbed.contains("token=[redacted]"))
    }

    func testJWTsAreScrubbed() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        let scrubbed = EvolutionRedactor.scrub("here \(jwt) end")
        XCTAssertFalse(scrubbed.contains("eyJhbGci"))
        XCTAssertTrue(scrubbed.contains("[redacted-jwt]"))
    }

    func testLongBlobsAreScrubbedButPathsSurvive() {
        let scrubbed = EvolutionRedactor.scrub("blob aB3dE5fG7hI9jK1lM3nO5pQ7rS9tU1vW3xY5zA7bC9dE1fG3hI5 end")
        XCTAssertTrue(scrubbed.contains("[redacted-blob]"))
        let path = "/var/minis/attachments/uploads/photo_AB12CD34EF56GH78.png"
        XCTAssertEqual(EvolutionRedactor.scrub(path), path)
    }

    func testURLUserinfoIsScrubbed() {
        let scrubbed = EvolutionRedactor.scrub("https://admin:s3cretpw@example.com/path")
        XCTAssertFalse(scrubbed.contains("s3cretpw"))
        XCTAssertTrue(scrubbed.contains("://[redacted]@"))
    }

    func testDigestTruncatesAndStaysWithinLimit() {
        let long = String(repeating: "a", count: 5000)
        let out = EvolutionRedactor.digest(long)
        XCTAssertLessThanOrEqual(out.count, EvolutionRedactor.maxDigestLength)
        XCTAssertTrue(out.contains("…[+"))
        XCTAssertEqual(EvolutionRedactor.digest("fine"), "fine")
    }

    // MARK: - Enum surface (settings must not be poked in tests)

    func testModeSurface() {
        XCTAssertEqual(EvolutionMode.allCases.count, 3)
        XCTAssertEqual(EvolutionMode.shadow.rawValue, "shadow")
        XCTAssertEqual(EvolutionLessonStatus.candidate.rawValue, "candidate")
        XCTAssertEqual(EvolutionActionStatus.timeout.rawValue, "timeout")
    }

    // MARK: - Store round-trips (temp dir)

    private func makeStore() throws -> (EvolutionStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("evo-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try EvolutionStore(url: dir.appendingPathComponent("evolution.db"))
        return (store, dir)
    }

    private func makeLesson(id: String, status: EvolutionLessonStatus) -> EvolutionLesson {
        EvolutionLesson(id: id, scope: "global", personaId: nil, taskSignature: "shell",
                        conditions: "", recommendation: "test recommendation",
                        antiPattern: nil, evidenceActions: "[]", status: status,
                        successCount: 0, failureCount: 0, version: 1, parentId: nil,
                        lastVerifiedAt: nil, injectPriority: 0)
    }

    func testStoreInsertAndFetchRunWithActions() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let run = EvolutionRun(id: "run-1", sessionId: "s1", personaId: nil,
                               taskSignature: "shell", startedAt: Date(), endedAt: Date(),
                               status: .ok, turnCount: 3, toolCallCount: 2, retryCount: 0,
                               tokensEst: 123, modelId: "m", source: "chat")
        await store.insert(run)
        await store.insert(EvolutionAction(id: "a1", runId: "run-1", seq: 1,
                                           toolName: "shell_execute", profile: "cmd=ls",
                                           status: .success, errorClass: nil, errorDigest: nil,
                                           durationMs: 42, retryCount: 0, resultDigest: "ok"))
        let runs = await store.recentRuns()
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.id, "run-1")
        XCTAssertEqual(runs.first?.status, .ok)
        // Regression (off-by-one reads): every mapped field must round-trip.
        XCTAssertEqual(runs.first?.toolCallCount, 2)
        XCTAssertEqual(runs.first?.source, "chat")
        XCTAssertNotNil(runs.first?.endedAt)
        if let started = runs.first?.startedAt {
            XCTAssertLessThan(abs(started.timeIntervalSinceNow), 10)
        } else {
            XCTFail("startedAt missing")
        }
        let actions = await store.actions(forRun: "run-1")
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions.first?.toolName, "shell_execute")
        XCTAssertEqual(actions.first?.durationMs, 42)
        XCTAssertEqual(actions.first?.runId, "run-1")
        XCTAssertEqual(actions.first?.status, .success)
        XCTAssertNil(actions.first?.errorClass)
    }

    func testStorePersistsAcrossReopen() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        await store.insert(makeLesson(id: "L1", status: .candidate))
        let reopened = try EvolutionStore(url: dir.appendingPathComponent("evolution.db"))
        let found = await reopened.lessons(status: .candidate)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.id, "L1")
        XCTAssertEqual(found.first?.recommendation, "test recommendation")
    }

    func testPruneEnforcesRowCap() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<5 {
            await store.insert(EvolutionAction(id: "a\(i)", runId: "r", seq: i, toolName: "t",
                                               profile: "", status: .success, errorClass: nil,
                                               errorDigest: nil, durationMs: 1, retryCount: 0,
                                               resultDigest: nil),
                               createdAt: Date().addingTimeInterval(Double(i)))
        }
        await store.prune(maxActionRows: 3, maxRunRows: 100, maxInjectionRows: 100, ttlDays: 3650)
        let counts = await store.counts()
        XCTAssertEqual(counts["actions"], 3)
    }

    func testClearAllWipesTables() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        await store.insert(makeLesson(id: "L2", status: .verified))
        var counts = await store.counts()
        XCTAssertEqual(counts["lessons"], 1)
        await store.clearAll()
        counts = await store.counts()
        XCTAssertEqual(counts["lessons"], 0)
    }

    // MARK: - OPT-2 injection ledger round-trips

    func testInjectionSessionIdRoundTripsThroughLedger() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        await store.insert(EvolutionInjection(
            id: "inj-active", runId: "run-9", sessionId: "sess-42",
            lessonId: "L1", injectedAt: Date(), tokenCost: 12,
            mode: EvolutionMode.active.rawValue, outcomeLinked: nil))
        // Shadow rows keep session_id nil — must survive the column round-trip.
        await store.insert(EvolutionInjection(
            id: "inj-shadow", runId: nil, sessionId: nil,
            lessonId: "L2", injectedAt: Date(), tokenCost: 8,
            mode: EvolutionMode.shadow.rawValue, outcomeLinked: nil))
        let rows = await store.recentInjections()
        XCTAssertEqual(rows.count, 2)
        let active = rows.first { $0.id == "inj-active" }
        XCTAssertEqual(active?.sessionId, "sess-42")
        XCTAssertEqual(active?.runId, "run-9")
        XCTAssertEqual(active?.lessonId, "L1")
        XCTAssertEqual(active?.tokenCost, 12)
        XCTAssertEqual(active?.mode, EvolutionMode.active.rawValue)
        let shadow = rows.first { $0.id == "inj-shadow" }
        XCTAssertNil(shadow?.sessionId)
        XCTAssertEqual(shadow?.mode, EvolutionMode.shadow.rawValue)
    }
}
