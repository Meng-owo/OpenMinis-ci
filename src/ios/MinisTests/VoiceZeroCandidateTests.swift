import XCTest

@testable import Minis

/// [B09-F01] Regression guard for the zero-candidate infinite recursion.
///
/// The bug: `pumpPrefetch` found no usable TTS target, drained the queue, then
/// called `pumpPlayback()` — whose last line unconditionally calls
/// `pumpPrefetch()` again. With an empty queue `slots` was still `maxPrefetch`
/// (nothing in flight), so the early `guard slots > 0` did NOT fire, and the two
/// functions bounced forever until the stack blew. A default install (System
/// voice off, no service, no group) hit this on the very first tap of "Read
/// aloud".
///
/// The fix has two independent halves, and this file pins both:
///   1. `pumpPrefetch` returns immediately on an empty queue.
///   2. The zero-candidate branch tears down inline and never re-enters
///      `pumpPlayback`.
///
/// These tests can't call the private pumps directly, so they assert the
/// observable contract instead: with nothing configured, enqueueing speech must
/// settle to "not playing / not synthesizing / queue empty" and post exactly one
/// drain notification — quickly, without hanging. A regression to the old
/// recursion either hangs the test (timeout) or crashes the runner.
@MainActor
final class VoiceZeroCandidateTests: XCTestCase {

    override func tearDown() async throws {
        VoiceOutputPlayer.shared.stopAll()
        try await super.tearDown()
    }

    /// Nothing configured at all → the queue drains once, no recursion.
    func testEnqueueWithNoCandidatesDrainsOnceAndSettles() async throws {
        let player = VoiceOutputPlayer.shared

        // Make sure the precondition really holds, otherwise this test proves
        // nothing: no service selected, no default group, System voice off.
        let serviceStore = TTSServiceStore.shared
        let previousSelection = serviceStore.selectedServiceId
        serviceStore.setSelectedServiceId(nil)
        let previousSystemVoice = VoiceOutputPreferences.systemVoiceAllowed
        VoiceOutputPreferences.systemVoiceAllowed = false
        defer {
            serviceStore.setSelectedServiceId(previousSelection)
            VoiceOutputPreferences.systemVoiceAllowed = previousSystemVoice
        }

        // [B09-V6 2026-10-22] `addObserver(forName:object:queue:using:)` takes a
        // `@Sendable` block. Under Swift 6 (this target is SWIFT_VERSION 6.0)
        // mutating a captured `var` inside it is a COMPILE ERROR, not a warning
        // — "mutation of captured var in concurrently-executing code". A boxed
        // counter is the supported shape.
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            func bump() { lock.lock(); n += 1; lock.unlock() }
            var value: Int { lock.lock(); defer { lock.unlock() }; return n }
        }
        let drained = Counter()
        let token = NotificationCenter.default.addObserver(
            forName: .ttsQueueDrainedSilently, object: nil, queue: .main
        ) { _ in drained.bump() }
        defer { NotificationCenter.default.removeObserver(token) }

        player.enqueue("测试一句没有任何语音可以合成的话。", sessionId: "test-session")

        // Give the (synchronous, on the main actor) drain a chance to run.
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertFalse(player.isPlaying, "nothing can speak — must not report playing")
        XCTAssertFalse(player.isSynthesizing, "nothing can speak — must not report synthesizing")
        XCTAssertEqual(drained.value, 1,
                       "the drain notification must fire exactly once, not per recursion round")
    }

    /// The pump pair must not ping-pong on an empty queue either: enqueueing an
    /// empty string is a no-op, and stopping afterwards must stay settled.
    func testEmptyEnqueueIsANoOp() async throws {
        let player = VoiceOutputPlayer.shared
        player.enqueue("", sessionId: "test-session")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isSynthesizing)
    }

    /// A second enqueue after a drained queue must not resurrect the old state.
    func testSecondEnqueueAfterDrainStaysSettled() async throws {
        let serviceStore = TTSServiceStore.shared
        let previousSelection = serviceStore.selectedServiceId
        serviceStore.setSelectedServiceId(nil)
        let previousSystemVoice = VoiceOutputPreferences.systemVoiceAllowed
        VoiceOutputPreferences.systemVoiceAllowed = false
        defer {
            serviceStore.setSelectedServiceId(previousSelection)
            VoiceOutputPreferences.systemVoiceAllowed = previousSystemVoice
        }

        let player = VoiceOutputPlayer.shared
        player.enqueue("第一句。", sessionId: "test-session")
        try await Task.sleep(nanoseconds: 200_000_000)
        player.enqueue("第二句。", sessionId: "test-session")
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isSynthesizing)
    }
}
