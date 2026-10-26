import XCTest

@testable import Minis

/// [API-9] The unknown-thinking-parameter recognizer that gates the
/// strip-and-retry self-heal in `streamWithGroupFallback`. It must fire on
/// real provider wordings for "we don't know that thinking parameter" and
/// must NOT fire on unrelated 400s — a false positive costs the turn its
/// thinking for no reason.
@MainActor
final class ThinkingParamSelfHealTests: XCTestCase {

    private func providerError(_ message: String) -> Error {
        LLMError.providerError(message: message)
    }

    // MARK: - Should fire

    func testFires_groqStyleUnknownParameter() {
        let e = providerError("Unknown parameter: 'enable_thinking'")
        XCTAssertTrue(AIChatViewModel.errorImplicatesUnknownThinkingParam(e))
    }

    func testFires_additionalPropertiesNotAllowed() {
        let e = providerError("Additional properties are not allowed ('enable_thinking' was unexpected)")
        XCTAssertTrue(AIChatViewModel.errorImplicatesUnknownThinkingParam(e))
    }

    func testFires_anthropicExtraInputs() {
        let e = providerError("thinking: Extra inputs are not permitted")
        XCTAssertTrue(AIChatViewModel.errorImplicatesUnknownThinkingParam(e))
    }

    func testFires_unsupportedReasoningEffort() {
        let e = providerError("Unsupported parameter: reasoning_effort")
        XCTAssertTrue(AIChatViewModel.errorImplicatesUnknownThinkingParam(e))
    }

    func testFires_geminiUnknownNameThinkingConfig() {
        let e = providerError("Invalid JSON payload received. Unknown name \"thinkingConfig\" at 'generation_config'")
        XCTAssertTrue(AIChatViewModel.errorImplicatesUnknownThinkingParam(e))
    }

    func testFires_unrecognizedThinkingBudget() {
        let e = providerError("Unrecognized request argument: thinking_budget")
        XCTAssertTrue(AIChatViewModel.errorImplicatesUnknownThinkingParam(e))
    }

    // MARK: - Must NOT fire

    func testDoesNotFire_contextLength() {
        let e = providerError("This model's maximum context length is 128000 tokens")
        XCTAssertFalse(AIChatViewModel.errorImplicatesUnknownThinkingParam(e))
    }

    func testDoesNotFire_thinkingValueComplaint() {
        // A complaint about the thinking VALUE (budget too large) is not an
        // unknown-parameter rejection — stripping would not fix it.
        let e = providerError("thinking.budget_tokens must be less than max_tokens")
        XCTAssertFalse(AIChatViewModel.errorImplicatesUnknownThinkingParam(e))
    }

    func testDoesNotFire_rateLimitText() {
        let e = providerError("Rate limit exceeded, please retry")
        XCTAssertFalse(AIChatViewModel.errorImplicatesUnknownThinkingParam(e))
    }

    func testDoesNotFire_authError() {
        let e = LLMError.invalidAPIKey(detail: "invalid x-api-key")
        XCTAssertFalse(AIChatViewModel.errorImplicatesUnknownThinkingParam(e))
    }

    func testDoesNotFire_unknownModel() {
        // "unknown" alone (about the model, not a thinking parameter) must
        // not strip thinking.
        let e = providerError("The model `gpt-x` is unknown")
        XCTAssertFalse(AIChatViewModel.errorImplicatesUnknownThinkingParam(e))
    }
}
