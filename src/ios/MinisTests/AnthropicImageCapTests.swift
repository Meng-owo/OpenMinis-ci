import XCTest

@testable import Minis

/// [IMG-5] Anthropic's per-model long-edge cap: standard tier 1568,
/// high-resolution tier (Opus/Sonnet 4.5+, 5-series) 2576, anything
/// unrecognized falls back to the standard cap (smaller is safe,
/// larger risks a rejected request).
final class AnthropicImageCapTests: XCTestCase {

    private func cap(_ id: String) -> CGFloat {
        ImagePayloadPrep.anthropicLongEdgeCap(forModelId: id)
    }

    func testStandardTier() {
        XCTAssertEqual(cap("claude-sonnet-4-20250514"), 1568)
        XCTAssertEqual(cap("claude-opus-4-1"), 1568)
        XCTAssertEqual(cap("claude-3-5-sonnet-20241022"), 1568)
        XCTAssertEqual(cap("claude-3-7-sonnet"), 1568)
        XCTAssertEqual(cap("claude-haiku-4-5"), 1568)  // not in the hi-res set — standard is the safe side
        XCTAssertEqual(cap("some-unknown-model"), 1568)
    }

    func testHighResolutionTier() {
        XCTAssertEqual(cap("claude-sonnet-4-5"), 2576)
        XCTAssertEqual(cap("claude-sonnet-4-5-20250929"), 2576)
        XCTAssertEqual(cap("claude-opus-4-5"), 2576)
        XCTAssertEqual(cap("claude-opus-4-6"), 2576)
        XCTAssertEqual(cap("claude-sonnet-4.5"), 2576)  // dotted shape
        XCTAssertEqual(cap("claude-opus-5"), 2576)
        XCTAssertEqual(cap("claude-sonnet-5-20260101"), 2576)
    }

    func testNonAnthropicIdsStayStandard() {
        XCTAssertEqual(cap("gpt-5"), 1568)
        XCTAssertEqual(cap("gemini-3-pro-preview"), 1568)
    }
}
