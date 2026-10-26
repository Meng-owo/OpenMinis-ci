import XCTest

/// [S2-2][evolution] Recorder tests — pure surface only. No UserDefaults
/// writes and no store I/O: the run tracker is exercised as a standalone
/// instance so the test process can not touch the app's preferences domain
/// or a real evolution.db.
final class EvolutionRecorderTests: XCTestCase {

    func testStatusMapping() {
        XCTAssertEqual(EvolutionRecorder.mapStatus(cancelled: false, isError: false), .success)
        XCTAssertEqual(EvolutionRecorder.mapStatus(cancelled: false, isError: true), .fail)
        XCTAssertEqual(EvolutionRecorder.mapStatus(cancelled: true, isError: false), .cancelled)
        // Cancelled outranks failure: a cancelled call is not a tool defect.
        XCTAssertEqual(EvolutionRecorder.mapStatus(cancelled: true, isError: true), .cancelled)
    }

    func testRunTrackerSeqAndCount() async {
        let tracker = EvolutionRunTracker()
        await tracker.begin(runId: "r1", startedAt: Date(), sessionId: "s1", source: "chat")
        let s1 = await tracker.nextSeq(runId: "r1")
        let s2 = await tracker.nextSeq(runId: "r1")
        XCTAssertEqual([s1, s2], [1, 2])
        let stats = await tracker.finish(runId: "r1")
        XCTAssertEqual(stats?.actionCount, 2)
        XCTAssertEqual(stats?.sessionId, "s1")
        XCTAssertEqual(stats?.source, "chat")
        let again = await tracker.finish(runId: "r1")
        XCTAssertNil(again)
    }

    func testRunTrackerIsolatesRuns() async {
        let tracker = EvolutionRunTracker()
        await tracker.begin(runId: "a", startedAt: Date(), sessionId: nil, source: "chat")
        await tracker.begin(runId: "b", startedAt: Date(), sessionId: nil, source: "scheduled")
        _ = await tracker.nextSeq(runId: "a")
        let sb = await tracker.nextSeq(runId: "b")
        XCTAssertEqual(sb, 1)
        let fa = await tracker.finish(runId: "a")
        XCTAssertEqual(fa?.actionCount, 1)
        let fb = await tracker.finish(runId: "b")
        XCTAssertEqual(fb?.source, "scheduled")
    }

    func testTrackerUnknownRunDegrades() async {
        let tracker = EvolutionRunTracker()
        // nextSeq for an unknown run must not crash and must start at 1.
        let seq = await tracker.nextSeq(runId: "ghost")
        XCTAssertEqual(seq, 1)
        let stats = await tracker.finish(runId: "ghost")
        XCTAssertEqual(stats?.actionCount, 1)
    }
}
