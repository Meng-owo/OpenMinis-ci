import XCTest

@testable import Minis

/// [TTS-11] The shared sentence-boundary splitter the voice-bubble
/// composer uses to stay under each vendor's per-request limit, and the
/// bubble format sniff.
final class VoiceBubbleChunkingTests: XCTestCase {

    func testShortTextStaysOneChunk() {
        let chunks = VoiceOutputPlayer.splitText("你好，这是一句短话。", maxChars: 1000)
        XCTAssertEqual(chunks, ["你好，这是一句短话。"])
    }

    func testLongTextSplitsOnSentenceBoundaries() {
        let sentence = "这是一个句子，用来测试切分行为是否正确。"
        let text = String(repeating: sentence, count: 10)  // 19 chars × 10 = 190
        let chunks = VoiceOutputPlayer.splitText(text, maxChars: 60)
        XCTAssertGreaterThan(chunks.count, 1)
        // No content lost or reordered.
        XCTAssertEqual(chunks.joined(), text)
        // Every chunk ends at a boundary punctuation (except possibly the last).
        for chunk in chunks.dropLast() {
            XCTAssertTrue("。！？".contains(chunk.last!), "chunk should end on a sentence boundary: \(chunk)")
        }
    }

    func testNoBoundaryTextFallsBackToWhole() {
        // No punctuation at all — the splitter cannot cut, returns the
        // whole text as one chunk (caller then sends it as-is, as before).
        let text = String(repeating: "啊", count: 500)
        let chunks = VoiceOutputPlayer.splitText(text, maxChars: 100)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first, text)
    }

    func testWAVSniff() {
        var wav = Data("RIFF".utf8)
        wav.append(Data([0, 0, 0, 0]))
        wav.append(Data("WAVE".utf8))
        wav.append(Data(count: 40))
        XCTAssertTrue(AIVoiceMessageComposer.isWAVData(wav))
        XCTAssertFalse(AIVoiceMessageComposer.isWAVData(Data("ID3\u{03}\u{00}".utf8)))
        XCTAssertFalse(AIVoiceMessageComposer.isWAVData(Data()))
    }

    func testBubbleLimits() {
        XCTAssertEqual(TTSServiceKind.doubao.bubbleSynthesisCharLimit, 1024)
        XCTAssertEqual(TTSServiceKind.openai.bubbleSynthesisCharLimit, 4096)
        XCTAssertEqual(TTSServiceKind.minimax.bubbleSynthesisCharLimit, 5000)
        XCTAssertEqual(TTSServiceKind.gemini.bubbleSynthesisCharLimit, 1000)  // conservative default
    }
}
