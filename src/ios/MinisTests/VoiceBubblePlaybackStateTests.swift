import XCTest

@testable import Minis

/// [TTS-13] Bubble playback state: progress recording (seconds/finished)
/// and rate memory.
final class VoiceBubblePlaybackStateTests: XCTestCase {

    private let file = "tts-test-\(UUID().uuidString.prefix(6))"

    override func tearDown() {
        VoiceBubblePlaybackState.clearProgress(for: file)
        super.tearDown()
    }

    func testProgressRoundTrip() {
        XCTAssertNil(VoiceBubblePlaybackState.progress(for: file))
        VoiceBubblePlaybackState.recordProgress(fileName: file, position: 12.5, duration: 60)
        let p = VoiceBubblePlaybackState.progress(for: file)
        XCTAssertEqual(p?.position ?? -1, 12.5, accuracy: 0.001)
        XCTAssertEqual(p?.duration ?? -1, 60, accuracy: 0.001)
        XCTAssertFalse(p?.finished ?? true)
    }

    func testFinishedFlag() {
        VoiceBubblePlaybackState.recordProgress(fileName: file, position: 59.8, duration: 60)
        XCTAssertTrue(VoiceBubblePlaybackState.progress(for: file)?.finished ?? false)
        VoiceBubblePlaybackState.recordProgress(fileName: file, position: 10, duration: 60)
        XCTAssertFalse(VoiceBubblePlaybackState.progress(for: file)?.finished ?? true)
    }

    func testEmptyFileNameIgnored() {
        VoiceBubblePlaybackState.recordProgress(fileName: "", position: 5, duration: 10)
        XCTAssertNil(VoiceBubblePlaybackState.progress(for: ""))
    }

    func testRateMemory() {
        let before = VoiceBubblePlaybackState.rememberedRate
        VoiceBubblePlaybackState.rememberRate(1.5)
        XCTAssertEqual(VoiceBubblePlaybackState.rememberedRate, 1.5, accuracy: 0.001)
        // Restore the pre-test value so tests don't leak state.
        VoiceBubblePlaybackState.rememberRate(before)
    }
}
