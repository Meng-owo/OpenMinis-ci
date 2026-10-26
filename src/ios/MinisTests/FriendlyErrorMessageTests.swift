import XCTest

@testable import Minis

/// [API-10] Plain-language triage in `friendlyErrorMessage`: each common
/// provider failure must get its guidance line prepended (raw text kept
/// below it), unknown errors must pass through untouched, and token counts
/// in context-length errors must not false-positive other categories.
@MainActor
final class FriendlyErrorMessageTests: XCTestCase {

    private func assertGuidance(_ raw: String, contains needle: String) {
        let out = AIChatViewModel.friendlyErrorMessage(raw)
        XCTAssertTrue(out.contains(needle), "expected guidance '\(needle)' in: \(out)")
        XCTAssertTrue(out.hasSuffix(raw), "raw text must be preserved at the end: \(out)")
    }

    func testAuth_guidance() {
        assertGuidance("Provider error: 401 Unauthorized — invalid x-api-key",
                       contains: "rejected the API key")
    }

    func testBalance_guidance() {
        assertGuidance("Provider error: insufficient_quota: You exceeded your current quota",
                       contains: "balance or quota")
    }

    func testModelMissing_guidance() {
        assertGuidance("Provider error: The model `gpt-x` does not exist (model not found)",
                       contains: "doesn't exist")
    }

    func testContextTooLong_guidance_andNoAuthFalsePositive() {
        // "140123" contains the digits "401"/"403"/"429" — must still be
        // classified as context length, never as an auth failure.
        let raw = "Provider error: This model's maximum context length is 200000 tokens. However, you requested 140123 tokens."
        let out = AIChatViewModel.friendlyErrorMessage(raw)
        XCTAssertTrue(out.contains("too long for this model"), out)
        XCTAssertFalse(out.contains("rejected the API key"), out)
    }

    func testRateLimit_guidance() {
        assertGuidance("Rate limited — please try again later", contains: "rate limiting")
    }

    func testServerTrouble_guidance() {
        assertGuidance("Service temporarily unavailable: 502 Bad Gateway",
                       contains: "having trouble")
    }

    func testUnknownParam_guidance() {
        assertGuidance("Provider error: Unknown parameter: 'enable_thinking'",
                       contains: "doesn't recognize a parameter")
    }

    func testUnknownParam_nonThinking_noThinkingAdvice() {
        // A bare unknown-parameter error must not suggest turning thinking off.
        let out = AIChatViewModel.friendlyErrorMessage("Provider error: Unknown parameter: 'temperature'")
        XCTAssertTrue(out.contains("doesn't recognize a parameter"), out)
        XCTAssertFalse(out.contains("Turn thinking off"), out)
    }

    func testPolicy_guidance() {
        assertGuidance("Provider error: Your request was rejected by the content policy",
                       contains: "safety filter blocked")
    }

    func testNetwork_guidance() {
        assertGuidance("Network error: The Internet connection appears to be offline.",
                       contains: "network connection failed")
    }

    func testUnknownError_passesThrough() {
        let raw = "Provider error: something entirely novel happened"
        XCTAssertEqual(AIChatViewModel.friendlyErrorMessage(raw), raw)
    }

    func testExistingImageGuidance_stillFirst() {
        let out = AIChatViewModel.friendlyErrorMessage("Downloaded image content cannot exceed 30MB")
        XCTAssertTrue(out.contains("Image too large for the provider"), out)
    }
}
