import XCTest

@testable import Minis

/// [TTS-2] Save/send-time clamping of numeric TTS tuning knobs to each
/// vendor's documented range.
final class TTSKnobClampTests: XCTestCase {

    private func service(_ kind: TTSServiceKind, _ extras: [String: String]) -> TTSServiceOptions {
        TTSServiceOptions(name: "t", kind: kind, extras: extras)
    }

    func testInRangeValuesPassThroughUnchanged() {
        let r = service(.minimax, ["speed": "1.5", "pitch": "-3"]).clampedExtras()
        XCTAssertEqual(r.extras["speed"], "1.5")
        XCTAssertEqual(r.extras["pitch"], "-3")
        XCTAssertTrue(r.adjusted.isEmpty)
    }

    func testOutOfRangeValuesClampToBounds() {
        let r = service(.minimax, ["speed": "9", "volume": "0.01", "pitch": "99"]).clampedExtras()
        XCTAssertEqual(r.extras["speed"], "2")
        XCTAssertEqual(r.extras["volume"], "0.1")
        XCTAssertEqual(r.extras["pitch"], "12")
        XCTAssertEqual(Set(r.adjusted), ["speed", "volume", "pitch"])
    }

    func testNonNumericValuesAreDropped() {
        let r = service(.openai, ["speed": "fast!"]).clampedExtras()
        XCTAssertNil(r.extras["speed"])
        XCTAssertEqual(r.adjusted, ["speed"])
    }

    func testIntegerKnobsAreRounded() {
        let r = service(.minimax, ["bitrate": "96000.6", "sampleRate": "22050"]).clampedExtras()
        XCTAssertEqual(r.extras["bitrate"], "96001")
        XCTAssertEqual(r.extras["sampleRate"], "22050")
    }

    func testUnrangedKeysUntouched() {
        let r = service(.minimax, ["emotion": "happy", "format": "mp3"]).clampedExtras()
        XCTAssertEqual(r.extras["emotion"], "happy")
        XCTAssertEqual(r.extras["format"], "mp3")
        XCTAssertTrue(r.adjusted.isEmpty)
    }

    func testRangesArePerVendor() {
        // 3.0 is legal for Doubao, out of range for MiniMax.
        XCTAssertEqual(service(.doubao, ["speed": "3.0"]).clampedExtras().extras["speed"], "3.0")
        XCTAssertEqual(service(.minimax, ["speed": "3.0"]).clampedExtras().extras["speed"], "2")
        // ElevenLabs stability clamps at 1.
        XCTAssertEqual(service(.elevenlabs, ["stability": "1.4"]).clampedExtras().extras["stability"], "1")
    }

    func testEmptyValuesAreLeftAlone() {
        let r = service(.minimax, ["speed": ""]).clampedExtras()
        XCTAssertEqual(r.extras["speed"], "")
        XCTAssertTrue(r.adjusted.isEmpty)
    }
}
