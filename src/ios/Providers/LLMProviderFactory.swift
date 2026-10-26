import Foundation

/// Shared factory for creating LLMProvider instances from a ModelEntry.
/// Used by both the agent loop (AIChatViewModel) and minis-model-use offload bridge.
@MainActor
enum LLMProviderFactory {

    enum FactoryError: Error {
        case noInstance
        case noCredentials
        case voiceOnlyProvider
    }

    /// Create an LLMProvider for the given entry, looking up its ProviderInstance and credentials.
    static func makeProvider(for entry: ModelEntry) async throws -> any LLMProvider {
        let store = ProviderConfigStore.shared
        guard let instance = store.instance(for: entry.providerInstanceId) else {
            throw FactoryError.noInstance
        }
        switch instance.providerType {
        case .anthropic:
            return makeAnthropicProvider(instance: instance, model: entry.model)
        case .gemini:
            return await makeGeminiProvider(instance: instance, model: entry.model)
        case .openAI:
            return makeOpenAIProvider(instance: instance, model: entry.model)
        case .antigravity:
            return await makeAntigravityProvider(instance: instance, model: entry.model)
        case .openRouter:
            return makeOpenRouterProvider(instance: instance, model: entry.model)
        case .openAIResponses:
            return makeOpenAIResponsesProvider(instance: instance, model: entry.model)
        case .xAI:
            return makeXAIProvider(instance: instance, model: entry.model)
        case .kimiCode:
            return makeKimiProvider(instance: instance, model: entry.model)
        case .unsupported:
            throw FactoryError.voiceOnlyProvider
        }
    }

    /// Inject the instance's custom `User-Agent` into an OpenAI-family provider's
    /// `extraHeaders` (which every request builder applies — chat/responses/models/
    /// image). Only for custom-base OpenAI/Anthropic-compat instances that are NOT
    /// OAuth: Codex OAuth requires its own `codex_cli_rs/...` UA to be accepted, so
    /// we never clobber it. Merges into any existing extraHeaders (e.g. OpenRouter
    /// attribution). No-op when no custom UA is set → default UA unchanged.
    /// Called from inside each OpenAI-family builder so BOTH makeProvider() and
    /// AIChatViewModel.makeAgentProvider() (which calls the builders directly) apply it.
    /// [T-ios-azure-openai] Flip the provider into Azure mode (api-key header +
    /// Azure URL) for instances that opted in. No-op (and zero behavior change)
    /// when azureMode is off, so non-Azure OpenAI/Responses instances are unaffected.
    @discardableResult
    static func applyAzure(_ provider: OpenAIProvider, instance: ProviderInstance) -> OpenAIProvider {
        if instance.azureMode { provider.isAzure = true }
        return provider
    }

    @discardableResult
    static func applyCustomUserAgent(_ provider: OpenAIProvider, instance: ProviderInstance) -> OpenAIProvider {
        // OAuth (Codex) requires its own `codex_cli_rs/...` UA — never touch it.
        guard !provider.isOAuth else { return provider }
        // A user-set per-provider custom UA wins (only honored for
        // custom-base proxy/relay instances, per supportsCustomUserAgent).
        if instance.supportsCustomUserAgent, let ua = instance.effectiveCustomUserAgent {
            provider.extraHeaders["User-Agent"] = ua
            return provider
        }
        // Otherwise inject the app default UA so outbound requests carry the
        // marketing version (Minis/1.10 …) instead of URLSession's build-number
        // default (Minis/1 CFNetwork/… Darwin/…). Don't clobber a UA another
        // builder already set (e.g. some future provider-specific UA).
        if provider.extraHeaders["User-Agent"] == nil {
            provider.extraHeaders["User-Agent"] = MinisUserAgent.default
        }
        return provider
    }

    // MARK: - Per-Provider Builders

    /// [T-phase1-sampling] Sanitize user-defined custom headers: drop empty keys
    /// and never allow overriding Authorization / Content-Type / User-Agent /
    /// x-api-key / api-key — those are owned by the auth + identity layers of each
    /// provider.
    static func sanitizedCustomHeaders(_ headers: [String: String]) -> [String: String] {
        let protected: Set<String> = ["authorization", "content-type", "user-agent", "x-api-key", "api-key"]
        var out: [String: String] = [:]
        for (key, value) in headers {
            let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedKey.isEmpty, !protected.contains(trimmedKey.lowercased()) else { continue }
            out[trimmedKey] = value
        }
        return out
    }

    /// [T-phase1-sampling] Merge the instance's user-defined custom headers into
    /// an OpenAI-family provider's `extraHeaders` (which every request builder
    /// applies — chat/responses/models/image). User headers win over
    /// pre-existing keys (e.g. OpenRouter attribution); the protected set is
    /// stripped by `sanitizedCustomHeaders`. No-op when none are set.
    static func effectiveHeaders(instance: ProviderInstance, extraHeaders: [String: String]? = nil) -> [String: String] {
        var base = sanitizedCustomHeaders(instance.customHeaders)
        if let extra = extraHeaders {
            let sanitizedExtra = sanitizedCustomHeaders(extra)
            for (k, v) in sanitizedExtra {
                base[k] = v
            }
        }
        return base
    }

    @discardableResult
    static func applyCustomHeaders(_ provider: OpenAIProvider, instance: ProviderInstance, extraHeaders: [String: String]? = nil) -> OpenAIProvider {
        for (key, value) in effectiveHeaders(instance: instance, extraHeaders: extraHeaders) {
            provider.extraHeaders[key] = value
        }
        return provider
    }

    static func makeAnthropicProvider(instance: ProviderInstance, model: LLMModel, extraHeaders: [String: String]? = nil) -> AnthropicProvider {
        let customBase = instance.effectiveCustomBaseURL
        let appendV1 = instance.appendV1Suffix
        let headers = effectiveHeaders(instance: instance, extraHeaders: extraHeaders)
        // Only custom-base Anthropic-compat (proxy/relay) instances get a custom UA.
        // The OAuth (Claude Code) path below is deliberately excluded — its required
        // `claude-cli/...` UA is set in OAuthURLProtocol and must not be overridden.
        let ua = instance.supportsCustomUserAgent ? instance.effectiveCustomUserAgent : nil
        switch instance.credentialType {
        case .apiKey:
            let key = ProviderKeychainHelper.loadAPIKey(instanceId: instance.id) ?? ""
            // No user custom UA → send the app default (Minis/<marketing>) so the
            // SDK (which sets no UA itself) doesn't fall back to URLSession's
            // build-number default. OAuth branches below keep nil so the
            // claude-cli UA set in OAuthURLProtocol is preserved.
            // [T-phase1-sampling] Custom headers ride the HTTP client's
            // httpAdditionalHeaders; OAuth stays identity-locked (skipped).
            return AnthropicProvider(apiKey: key, model: model, basePath: customBase, appendV1Suffix: appendV1, customUserAgent: ua ?? MinisUserAgent.default, customHeaders: headers)
        case .oauth:
            if let manualToken = ProviderKeychainHelper.loadOAuthString(instanceId: instance.id, account: "manual-oauth-token") {
                return AnthropicProvider(manualToken: manualToken, model: model, basePath: customBase, appendV1Suffix: appendV1, customUserAgent: ua, customHeaders: headers)
            }
            let iid = instance.id
            return AnthropicProvider(
                oauthTokenProvider: { try await ClaudeOAuthManager.shared.validAccessToken(instanceId: iid) },
                model: model,
                basePath: customBase,
                appendV1Suffix: appendV1
            )
        }
    }

    static func makeGeminiProvider(instance: ProviderInstance, model: LLMModel, extraHeaders: [String: String]? = nil) async -> GeminiProvider {
        let customBase = instance.effectiveCustomBaseURL
        let headers = effectiveHeaders(instance: instance, extraHeaders: extraHeaders)
        switch instance.credentialType {
        case .apiKey:
            let key = ProviderKeychainHelper.loadAPIKey(instanceId: instance.id) ?? ""
            let provider = GeminiProvider(apiKey: key, model: model, customBasePath: customBase)
            provider.customHeaders = headers
            return provider
        case .oauth:
            if let manualToken = ProviderKeychainHelper.loadOAuthString(instanceId: instance.id, account: "manual-oauth-token") {
                let provider = GeminiProvider(apiKey: manualToken, model: model, customBasePath: customBase)
                provider.customHeaders = headers
                return provider
            }
            let iid = instance.id
            if GeminiOAuthManager.shared.gcpProjectID(instanceId: iid) == nil {
                await GeminiOAuthManager.shared.discoverProjectIfNeeded(instanceId: iid)
            }
            let provider = GeminiProvider(
                oauthTokenProvider: { try await GeminiOAuthManager.shared.validAccessToken(instanceId: iid) },
                model: model,
                customBasePath: customBase
            )
            provider.gcpProjectID = GeminiOAuthManager.shared.gcpProjectID(instanceId: iid)
            provider.customHeaders = headers
            return provider
        }
    }

    static func makeOpenAIProvider(instance: ProviderInstance, model: LLMModel, extraHeaders: [String: String]? = nil) -> OpenAIProvider {
        let customBase = instance.effectiveCustomBaseURL
        let appendV1 = instance.appendV1Suffix
        // Mistral's chat-completions endpoint rejects `max_completion_tokens`
        // (newer OpenAI parameter name) and `stream_options` with HTTP 422,
        // and ALSO rejects the `reasoning: {effort: …}` body. Reuse the
        // OpenRouter `max_tokens` body builder via `useOpenRouterCompat`
        // (it switches max_tokens + drops stream_options at once) but mark
        // `isMistral` so the agent loop skips the OpenRouter thinking-param
        // auto-inject.
        let isMistral = (customBase ?? "").lowercased().contains("mistral.ai")
        func configure(_ p: OpenAIProvider) -> OpenAIProvider {
            if isMistral {
                p.useOpenRouterCompat = true
                p.isMistral = true
            }
            // [T-thinking-rules-phase2] Carry the instance id so the thinking resolver can
            // load this provider's user-authored rules. Set for every OpenAI-family
            // provider, not just Mistral.
            p.providerInstanceId = instance.id
            return p
        }
        switch instance.credentialType {
        case .apiKey:
            let key = ProviderKeychainHelper.loadAPIKey(instanceId: instance.id) ?? ""
            return applyCustomHeaders(applyAzure(applyCustomUserAgent(configure(OpenAIProvider(apiKey: key, model: model, customBaseURL: customBase, appendV1Suffix: appendV1)), instance: instance), instance: instance), instance: instance, extraHeaders: extraHeaders)
        case .oauth:
            if let manualToken = ProviderKeychainHelper.loadOAuthString(instanceId: instance.id, account: "manual-oauth-token") {
                return applyCustomHeaders(applyCustomUserAgent(configure(OpenAIProvider(apiKey: manualToken, model: model, customBaseURL: customBase, appendV1Suffix: appendV1)), instance: instance), instance: instance, extraHeaders: extraHeaders)
            }
            let iid = instance.id
            let provider = OpenAIProvider(
                oauthTokenProvider: { try await CodexOAuthManager.shared.validAccessToken(instanceId: iid) },
                model: model
            )
            provider.codexAccountId = CodexOAuthManager.shared.accountId(instanceId: iid)
            // [T-thinking-rules-phase2] Same binding configure() applies on the
            // apiKey/manual-token branches — without it this instance's
            // user-authored thinking rules silently never load.
            provider.providerInstanceId = instance.id
            return provider
        }
    }

    static func makeOpenRouterProvider(instance: ProviderInstance, model: LLMModel, extraHeaders: [String: String]? = nil) -> OpenAIProvider {
        let key: String
        if instance.credentialType == .oauth,
           let manualToken = ProviderKeychainHelper.loadOAuthString(instanceId: instance.id, account: "manual-oauth-token") {
            key = manualToken
        } else {
            key = ProviderKeychainHelper.loadAPIKey(instanceId: instance.id) ?? ""
        }
        let customBase = instance.effectiveCustomBaseURL
        let provider = OpenAIProvider(apiKey: key, model: model, customBaseURL: customBase ?? "https://openrouter.ai/api", appendV1Suffix: customBase == nil)
        provider.extraHeaders = [
            "HTTP-Referer": "https://github.com/OpenMinis/OpenMinis",
            "X-Title": "嘟嘟 App",
        ]
        provider.useOpenRouterCompat = true
        provider.providerInstanceId = instance.id
        return applyCustomHeaders(applyCustomUserAgent(provider, instance: instance), instance: instance, extraHeaders: extraHeaders)
    }

    static func makeOpenAIResponsesProvider(instance: ProviderInstance, model: LLMModel, extraHeaders: [String: String]? = nil) -> OpenAIProvider {
        let customBase = instance.effectiveCustomBaseURL
        let appendV1 = instance.appendV1Suffix
        // Both credential types are valid for Responses API instances
        // (e.g. an OpenAI2 instance configured with the user's Codex
        // OAuth login). Previously this branch only loaded an API key
        // and silently produced an empty-auth request when the user had
        // OAuth-only credentials — that's the model-use "Codex model
        // call fails" case (T-model-use-codex-responses-api-34889).
        switch instance.credentialType {
        case .apiKey:
            let key = ProviderKeychainHelper.loadAPIKey(instanceId: instance.id) ?? ""
            let provider = OpenAIProvider(apiKey: key, model: model, customBaseURL: customBase, appendV1Suffix: appendV1)
            provider.forceResponsesAPI = true
            provider.providerInstanceId = instance.id
            return applyCustomHeaders(applyAzure(applyCustomUserAgent(provider, instance: instance), instance: instance), instance: instance, extraHeaders: extraHeaders)
        case .oauth:
            if let manualToken = ProviderKeychainHelper.loadOAuthString(instanceId: instance.id, account: "manual-oauth-token") {
                let provider = OpenAIProvider(apiKey: manualToken, model: model, customBaseURL: customBase, appendV1Suffix: appendV1)
                provider.forceResponsesAPI = true
                provider.providerInstanceId = instance.id
                return applyCustomHeaders(applyCustomUserAgent(provider, instance: instance), instance: instance, extraHeaders: extraHeaders)
            }
            let iid = instance.id
            let provider = OpenAIProvider(
                oauthTokenProvider: { try await CodexOAuthManager.shared.validAccessToken(instanceId: iid) },
                model: model
            )
            provider.customBaseURL = customBase
            provider.appendV1Suffix = appendV1
            provider.forceResponsesAPI = true
            provider.codexAccountId = CodexOAuthManager.shared.accountId(instanceId: iid)
            provider.providerInstanceId = instance.id
            return provider
        }
    }

    /// Kimi Code / Coding Plan — OpenAI-compatible coding upstream reached with
    /// the device-code OAuth bearer. Mirrors makeXAIProvider (custom base +
    /// OAuth bearer through OpenAIProvider). See the Kimi Code OAuth design notes.
    static func makeKimiProvider(instance: ProviderInstance, model: LLMModel, extraHeaders: [String: String]? = nil) -> OpenAIProvider {
        let customBase = instance.effectiveCustomBaseURL ?? "https://api.kimi.com/coding"
        // The default Kimi coding base is `…/coding` WITHOUT `/v1`; the real
        // endpoints are `/coding/v1/chat/completions` and `/coding/v1/models`
        // (verified: `/coding/chat/completions` 404s, `/coding/v1/…` needs auth).
        // So append `/v1` for the default base; a user-supplied custom base keeps
        // their own appendV1 preference.
        let appendV1 = instance.effectiveCustomBaseURL == nil ? true : instance.appendV1Suffix
        switch instance.credentialType {
        case .apiKey:
            let key = ProviderKeychainHelper.loadAPIKey(instanceId: instance.id) ?? ""
            let provider = OpenAIProvider(apiKey: key, model: model, customBaseURL: customBase, appendV1Suffix: appendV1)
            provider.providerInstanceId = instance.id
            return applyCustomHeaders(applyCustomUserAgent(provider, instance: instance), instance: instance, extraHeaders: extraHeaders)
        case .oauth:
            let iid = instance.id
            let provider = OpenAIProvider(
                oauthTokenProvider: { try await KimiOAuthManager.shared.validAccessToken(instanceId: iid) },
                model: model
            )
            provider.customBaseURL = customBase
            provider.appendV1Suffix = appendV1
            provider.providerInstanceId = instance.id
            return provider
        }
    }

    static func makeXAIProvider(instance: ProviderInstance, model: LLMModel, extraHeaders: [String: String]? = nil) -> OpenAIProvider {
        let customBase = instance.effectiveCustomBaseURL ?? "https://api.x.ai/v1"
        // Custom base ships with /v1 — never re-append.
        let appendV1 = instance.effectiveCustomBaseURL == nil ? false : instance.appendV1Suffix
        switch instance.credentialType {
        case .apiKey:
            let key = ProviderKeychainHelper.loadAPIKey(instanceId: instance.id) ?? ""
            let provider = OpenAIProvider(apiKey: key, model: model, customBaseURL: customBase, appendV1Suffix: appendV1)
            provider.providerInstanceId = instance.id
            return applyCustomHeaders(applyCustomUserAgent(provider, instance: instance), instance: instance, extraHeaders: extraHeaders)
        case .oauth:
            if let manualToken = ProviderKeychainHelper.loadOAuthString(instanceId: instance.id, account: "manual-oauth-token") {
                let provider = OpenAIProvider(apiKey: manualToken, model: model, customBaseURL: customBase, appendV1Suffix: appendV1)
                provider.providerInstanceId = instance.id
                return applyCustomHeaders(applyCustomUserAgent(provider, instance: instance), instance: instance, extraHeaders: extraHeaders)
            }
            let iid = instance.id
            let provider = OpenAIProvider(
                oauthTokenProvider: { try await XAIOAuthManager.shared.validAccessToken(instanceId: iid) },
                model: model
            )
            provider.customBaseURL = customBase
            provider.appendV1Suffix = appendV1
            provider.providerInstanceId = instance.id
            return provider
        }
    }

    static func makeAntigravityProvider(instance: ProviderInstance, model: LLMModel, extraHeaders: [String: String]? = nil) async -> AntigravityProvider {
        let iid = instance.id
        if AntigravityOAuthManager.shared.projectID(instanceId: iid) == nil {
            await AntigravityOAuthManager.shared.discoverProjectIfNeeded(instanceId: iid)
        }
        let provider = AntigravityProvider(
            oauthTokenProvider: { try await AntigravityOAuthManager.shared.validAccessToken(instanceId: iid) },
            model: model
        )
        provider.projectID = AntigravityOAuthManager.shared.projectID(instanceId: iid)
        if let baseURL = AntigravityOAuthManager.shared.resolvedBaseURL(instanceId: iid) {
            provider.activeBaseURL = baseURL
        }
        provider.customHeaders = effectiveHeaders(instance: instance, extraHeaders: extraHeaders)
        return provider
    }
}
