import Foundation

// MARK: - TTS Service layer (kelivo-style)
//
// [T-tts-services 09-11] 醒醒要的「像 kelivo 那样单独一层」。
//
// BEFORE: a TTS voice was modelled as an *LLM model entry* inside a Model Group
// (ElevenLabs voice_id smuggled into `LLMModel.id`, Doubao voices as mock
// entries). Selecting a voice meant editing model groups; per-vendor knobs
// (emotion / volume / pitch / format / sample rate) had nowhere to live at all,
// so the only reachable voice was the vendor's default — hence the "难听的播音腔".
//
// AFTER: this file adds an INDEPENDENT service layer, exactly like kelivo's
// TtsServicesPage. One row per configured service; each carries its own baseURL,
// key, model, voice id AND the vendor-specific tuning knobs. The legacy Model
// Group path is kept intact (Decision A: don't tear down what already works) —
// VoiceProviderResolver consults this store FIRST and only falls back to the
// group-based candidates when no service here is enabled.
//
// Storage: definitions in UserDefaults (JSON), API keys in the Keychain under a
// synthetic instance id ("tts-<uuid>"), reusing ProviderKeychainHelper so
// iCloud-Keychain sync and the existing backup/restore plumbing work unchanged.

// MARK: - Vendor kind

/// The TTS vendors the service layer can speak to. Superset of the Model-Group
/// voice providers (which is missing several endpoints kelivo supports).
enum TTSServiceKind: String, CaseIterable, Codable, Identifiable {
    case openai
    case gemini
    case azure
    case minimax
    case qwen
    case groq
    case xai
    case elevenlabs
    case deepgram
    case doubao
    case xunfei
    case mimo
    case openrouter
    // [tts-vendors-3 2026-10-09] Kelivo parity: DashScope WebSocket TTS,
    // StepFun stepaudio, Fish Audio s2.1.
    case qwenaudio
    case stepfun
    case fishaudio

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai:      return "OpenAI"
        case .gemini:      return "Gemini"
        case .azure:       return "Azure"
        case .minimax:     return "MiniMax"
        case .qwen:        return "Qwen"
        case .groq:        return "Groq"
        case .xai:         return "xAI"
        case .elevenlabs:  return "ElevenLabs"
        case .deepgram:    return "Deepgram"
        case .doubao:      return "Doubao"
        case .xunfei:      return "iFlytek"
        case .mimo:        return "Xiaomi MiMo"
        case .openrouter:  return "OpenRouter"
        case .qwenaudio:  return "Qwen Audio"
        case .stepfun:    return "StepFun"
        case .fishaudio:  return "Fish Audio"
        }
    }

    /// SF Symbol for the row avatar.
    var symbol: String {
        switch self {
        case .openai:     return "circle.hexagongrid.fill"
        case .gemini:     return "sparkles"
        case .azure:      return "cloud.fill"
        case .minimax:    return "waveform"
        case .qwen:       return "aqi.medium"
        case .groq:       return "bolt.fill"
        case .xai:        return "x.circle.fill"
        case .elevenlabs: return "waveform.circle.fill"
        case .deepgram:   return "mic.and.signal.meter.fill"
        case .doubao:     return "bubble.left.and.text.bubble.right.fill"
        case .xunfei:     return "mic.fill"
        case .mimo:       return "cpu"
        case .openrouter: return "arrow.triangle.branch"
        case .qwenaudio:  return "antenna.radiowaves.left.and.right"
        case .stepfun:    return "figure.walk"
        case .fishaudio:  return "fish.fill"
        }
    }

    /// Default base URL prefilled into the editor.
    var defaultBaseURL: String {
        switch self {
        case .openai:     return "https://api.openai.com/v1"
        case .gemini:     return "https://generativelanguage.googleapis.com/v1beta"
        case .azure:      return "https://eastasia.tts.speech.microsoft.com"
        case .minimax:    return "https://api.minimax.io"
        case .qwen:       return "https://dashscope.aliyuncs.com/api/v1"
        case .groq:       return "https://api.groq.com/openai/v1"
        case .xai:        return "https://api.x.ai/v1"
        case .elevenlabs: return "https://api.elevenlabs.io"
        case .deepgram:   return "https://api.deepgram.com"
        case .doubao:     return "https://openspeech.bytedance.com"
        case .xunfei:     return "https://tts-api.xfyun.cn"
        case .mimo:       return "https://api.xiaomimimo.com/v1"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .qwenaudio:  return "wss://dashscope.aliyuncs.com/api-ws/v1/inference"
        case .stepfun:    return "https://api.stepfun.com/v1"
        case .fishaudio:  return "https://api.fish.audio"
        }
    }

    /// Default synthesis model id. Only used when a service is CREATED —
    /// saved services keep their stored model (the decoder only falls
    /// back to this on an empty value), so bumping a default never
    /// migrates existing configurations. [TTS-6] Gemini's default moved
    /// to the current-generation TTS model on that basis.
    var defaultModel: String {
        switch self {
        case .openai:     return "gpt-4o-mini-tts"
        case .gemini:     return "gemini-3.1-flash-tts-preview"
        case .azure:      return "azure-tts"
        case .minimax:    return "speech-2.8-turbo"
        case .qwen:       return "qwen3-tts-flash"
        case .groq:       return "canopylabs/orpheus-v1-english"
        case .xai:        return "grok-tts-1"
        case .elevenlabs: return "eleven_multilingual_v2"
        case .deepgram:   return "aura-asteria-en"
        case .doubao:     return "seed-tts-2.0"
        case .xunfei:     return "xiaoyan"
        case .mimo:       return "mimo-v2.5-tts"
        case .openrouter: return "openai/gpt-4o-mini-tts"
        case .qwenaudio:  return "qwen-audio-3.0-tts-flash"
        case .stepfun:    return "stepaudio-2.5-tts"
        case .fishaudio:  return "s2.1-pro"
        }
    }

    /// Default voice id.
    var defaultVoice: String {
        switch self {
        case .openai:     return "alloy"
        case .gemini:     return "Kore"
        case .azure:      return "zh-CN-XiaoxiaoNeural"
        case .minimax:    return "female-shaonv"
        case .qwen:       return "Cherry"
        case .groq:       return "austin"
        case .xai:        return "eve"
        case .elevenlabs: return "21m00Tcm4TlvDq8ikWAM"
        case .deepgram:   return "aura-asteria-en"
        case .doubao:     return "zh_female_cancan_uranus_bigtts"
        case .xunfei:     return "xiaoyan"
        case .mimo:       return "mimo_default"
        case .openrouter: return "alloy"
        case .qwenaudio:  return "longanhuan_v3.6"
        case .stepfun:    return "cixingnansheng"
        case .fishaudio:  return ""
        }
    }

    /// [TTS-11] Per-request character limit for bubble synthesis, used to
    /// split a long reply BEFORE sending (the read-aloud path queues
    /// segments; the bubble path used to send the whole text in one
    /// request and hard-fail past the vendor's cap). Only limits that
    /// are documented are listed per-vendor; everything else gets the
    /// conservative shared default — splitting smaller than necessary
    /// costs extra requests, splitting larger costs the whole bubble.
    var bubbleSynthesisCharLimit: Int {
        switch self {
        case .minimax:    return 5000
        case .openai:     return 4096
        case .elevenlabs: return 5000
        case .doubao:     return 1024
        default:          return 1000
        }
    }

    /// Whether the vendor needs a compound credential ("appId;key;secret").
    var compoundCredentialFormat: String? {
        self == .xunfei
            ? AppLocalized("iFlytek needs App ID + API Key + API Secret — enter them as \"appId;apiKey;apiSecret\" in the API Key field.",
                           comment: "TTS compound credential note")
            : nil
    }
}

// MARK: - Tuning knobs

/// A single optional tuning field (kelivo renders these per-vendor).
struct TTSKnob: Identifiable {
    let key: String
    let title: String
    let placeholder: String
    let defaultValue: String
    var id: String { key }
}

extension TTSServiceKind {
    /// Vendor-specific tuning fields, rendered under the common section.
    var knobs: [TTSKnob] {
        switch self {
        case .minimax:
            return [
                TTSKnob(key: "emotion", title: "Emotion", placeholder: "happy / sad / angry (optional)", defaultValue: ""),
                TTSKnob(key: "speed", title: "Speed", placeholder: "0.5 – 2.0", defaultValue: "1.0"),
                TTSKnob(key: "volume", title: "Volume", placeholder: "0.1 – 10.0", defaultValue: "1.0"),
                TTSKnob(key: "pitch", title: "Pitch", placeholder: "-12 – 12", defaultValue: "0"),
                // [TTS-3] The request builder already reads these three
                // (audio_setting.format / sample_rate / bitrate) — they
                // simply had no editor entry, so the wire always carried
                // the built-in defaults.
                TTSKnob(key: "format", title: "Format", placeholder: "mp3 / wav / flac", defaultValue: "mp3"),
                TTSKnob(key: "sampleRate", title: "Sample Rate", placeholder: "8000 – 44100", defaultValue: "32000"),
                TTSKnob(key: "bitrate", title: "Bitrate", placeholder: "32000 – 256000", defaultValue: "128000"),
            ]
        case .elevenlabs:
            return [
                TTSKnob(key: "outputFormat", title: "Output Format", placeholder: "mp3_44100_128", defaultValue: "mp3_44100_128"),
                // [TTS-5] Voice-settings levers. The request builder sent
                // stability 0.5 / similarity 0.75 hard-coded; these knobs
                // feed the same fields (absent = the old constants).
                TTSKnob(key: "stability", title: "Stability", placeholder: "0 – 1", defaultValue: "0.5"),
                TTSKnob(key: "similarity", title: "Similarity Boost", placeholder: "0 – 1", defaultValue: "0.75"),
                TTSKnob(key: "style", title: "Style Exaggeration", placeholder: "0 – 1", defaultValue: "0"),
                TTSKnob(key: "speed", title: "Speed", placeholder: "0.7 – 1.2", defaultValue: "1.0"),
                TTSKnob(key: "useSpeakerBoost", title: "Speaker Boost", placeholder: "true / false", defaultValue: "false"),
            ]
        case .openai, .groq, .openrouter:
            // [TTS-3] The OpenAI-compatible request already carries a
            // typed speed — the editor just never offered the field for
            // these kinds, so it could only ever be the default.
            return [
                TTSKnob(key: "speed", title: "Speed", placeholder: "0.25 – 4.0", defaultValue: "1.0"),
            ]
        case .qwen:
            return [
                TTSKnob(key: "languageType", title: "Language Type", placeholder: "Auto", defaultValue: "Auto"),
            ]
        case .xai:
            return [
                TTSKnob(key: "language", title: "Language", placeholder: "auto", defaultValue: "auto"),
                // [TTS-3] xAI rides the OpenAI-compatible shape — same
                // speed field as the .openai case above.
                TTSKnob(key: "speed", title: "Speed", placeholder: "0.25 – 4.0", defaultValue: "1.0"),
            ]
        case .azure:
            return [
                TTSKnob(key: "language", title: "Language", placeholder: "zh-CN", defaultValue: "zh-CN"),
                TTSKnob(key: "outputFormat", title: "Output Format", placeholder: "audio-24khz-48kbitrate-mono-mp3", defaultValue: "audio-24khz-48kbitrate-mono-mp3"),
            ]
        case .mimo:
            return [
                TTSKnob(key: "instruction", title: "Instruction", placeholder: "Style hint (optional)", defaultValue: ""),
            ]
        case .qwenaudio:
            // [tts-vendors-3 2026-10-09] DashScope WebSocket TTS options (kelivo parity).
            return [
                TTSKnob(key: "workspaceId", title: "Workspace ID", placeholder: "Optional — empty uses the default endpoint", defaultValue: ""),
                TTSKnob(key: "region", title: "Region", placeholder: "cn-beijing", defaultValue: "cn-beijing"),
                TTSKnob(key: "format", title: "Format", placeholder: "mp3 / wav / pcm", defaultValue: "mp3"),
                TTSKnob(key: "sampleRate", title: "Sample Rate", placeholder: "8000 – 48000", defaultValue: "22050"),
            ]
        case .stepfun:
            // [tts-vendors-3 2026-10-09] StepFun stepaudio options (kelivo parity).
            return [
                TTSKnob(key: "format", title: "Response Format", placeholder: "mp3 / wav / pcm", defaultValue: "mp3"),
                TTSKnob(key: "speed", title: "Speed", placeholder: "0.5 – 2.0", defaultValue: "1.0"),
                TTSKnob(key: "volume", title: "Volume", placeholder: "0.1 – 10.0", defaultValue: "1.0"),
                TTSKnob(key: "sampleRate", title: "Sample Rate", placeholder: "8000 – 44100", defaultValue: "24000"),
                TTSKnob(key: "instruction", title: "Instruction", placeholder: "Style hint — only for stepaudio-2.5-tts", defaultValue: ""),
            ]
        case .fishaudio:
            // [tts-vendors-3 2026-10-09] Fish Audio options (kelivo parity).
            // The voice field carries Fish Audio's reference_id.
            return [
                TTSKnob(key: "format", title: "Format", placeholder: "mp3 / wav / pcm", defaultValue: "mp3"),
                TTSKnob(key: "temperature", title: "Temperature", placeholder: "0 – 1", defaultValue: "0.7"),
                TTSKnob(key: "topP", title: "Top P", placeholder: "0 – 1", defaultValue: "0.7"),
                TTSKnob(key: "speed", title: "Speed", placeholder: "0.5 – 2.0", defaultValue: "1.0"),
                TTSKnob(key: "sampleRate", title: "Sample Rate", placeholder: "8000 – 44100", defaultValue: "44100"),
                TTSKnob(key: "latency", title: "Latency", placeholder: "normal / balanced", defaultValue: "normal"),
            ]
        // [T-tts-vendor-fix 09-13] gemini speed removed: the Gemini TTS API
        // has no speed parameter (kelivo's Gemini options carry none either).
        case .doubao, .xunfei:
            return [
                TTSKnob(key: "speed", title: "Speed", placeholder: "1.0", defaultValue: "1.0"),
            ]
        default:
            return []
        }
    }

    /// [T-tts-vendor-fix 09-13] supportsSpeed was removed — it was defined but
    /// never referenced (speed knobs live in `knobs` above only).
    var supportsInstruction: Bool { self == .openai || self == .mimo }
}

// MARK: - Service definition

/// One configured TTS service (a row in the Voice Services list).
struct TTSServiceOptions: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var kind: TTSServiceKind
    var enabled: Bool
    var baseURL: String
    var model: String
    var voice: String
    /// Vendor-specific extras, keyed by `TTSKnob.key`. Missing key = vendor default.
    var extras: [String: String]

    init(id: String = UUID().uuidString,
         name: String,
         kind: TTSServiceKind,
         enabled: Bool = true,
         baseURL: String? = nil,
         model: String? = nil,
         voice: String? = nil,
         extras: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.kind = kind
        self.enabled = enabled
        self.baseURL = baseURL ?? kind.defaultBaseURL
        self.model = model ?? kind.defaultModel
        self.voice = voice ?? kind.defaultVoice
        self.extras = extras
    }

    /// Keychain namespace for this service's credential. Reuses the provider
    /// helper so iCloud-Keychain sync works without new schema.
    var keychainInstanceId: String { "tts-\(id)" }

    // MARK: Codable with forward-compatible defaults
    //
    // Decoding is hand-written so a definition written by a NEWER build (extra
    // extras keys, an unknown vendor) degrades instead of throwing.

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, enabled, baseURL, model, voice, extras
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = (try? c.decode(String.self, forKey: .kind)) ?? ""
        let kind = TTSServiceKind(rawValue: rawKind) ?? .openai
        let id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        self.id = id
        self.kind = kind
        self.name = (try? c.decode(String.self, forKey: .name)) ?? kind.displayName
        self.enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        let base = try? c.decode(String.self, forKey: .baseURL)
        self.baseURL = (base?.isEmpty == false) ? base! : kind.defaultBaseURL
        let model = try? c.decode(String.self, forKey: .model)
        self.model = (model?.isEmpty == false) ? model! : kind.defaultModel
        let voice = try? c.decode(String.self, forKey: .voice)
        self.voice = (voice?.isEmpty == false) ? voice! : kind.defaultVoice
        self.extras = (try? c.decode([String: String].self, forKey: .extras)) ?? [:]
    }

    /// Effective value of a tuning knob: user value if non-empty, else default.
    func knob(_ key: String) -> String? {
        let v = extras[key]?.trimmingCharacters(in: .whitespaces)
        if let v, !v.isEmpty { return v }
        return kind.knobs.first { $0.key == key }?.defaultValue.nonEmpty
    }

    /// [tts-preview-lang 2026-10-09] Preview sentence for the 试听 button:
    /// a Chinese line for Chinese voices, an English line otherwise — an
    /// English voice reading Chinese misleads voice selection.
    var previewSentence: String {
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = displayName.isEmpty ? kind.displayName : displayName
        let v = voice.lowercased()
        let cjk = v.range(of: "\\p{Han}", options: .regularExpression) != nil
        let chineseKinds: [TTSServiceKind] = [.minimax, .qwen, .qwenaudio, .doubao, .xunfei, .mimo, .stepfun]
        if v.hasPrefix("zh") || cjk || chineseKinds.contains(kind) {
            return "你好，这是\(label)的试听。"
        }
        return "Hello, this is a preview of the \(label) voice."
    }
}

// MARK: - Knob range clamping

extension TTSServiceKind {
    /// [TTS-2] Official numeric range for a tuning knob, when the vendor
    /// defines one. Keys not listed here (free text like emotion /
    /// language, booleans like useSpeakerBoost) pass through untouched.
    func knobRange(_ key: String) -> (min: Double, max: Double, integer: Bool)? {
        switch (self, key) {
        case (.minimax, "speed"):      return (0.5, 2.0, false)
        case (.minimax, "volume"):     return (0.1, 10.0, false)
        case (.minimax, "pitch"):      return (-12, 12, true)
        case (.minimax, "sampleRate"): return (8000, 44100, true)
        case (.minimax, "bitrate"):    return (32000, 256000, true)
        case (.openai, "speed"), (.groq, "speed"),
             (.xai, "speed"), (.openrouter, "speed"):
            return (0.25, 4.0, false)
        case (.doubao, "speed"):       return (0.2, 3.0, false)
        case (.xunfei, "speed"):       return (0.5, 2.0, false)
        case (.elevenlabs, "speed"):   return (0.7, 1.2, false)
        case (.elevenlabs, "stability"), (.elevenlabs, "similarity"),
             (.elevenlabs, "style"):
            return (0.0, 1.0, false)
        default:                        return nil
        }
    }
}

extension TTSServiceOptions {
    /// [TTS-2] Clamp every ranged numeric knob in `extras` to the vendor's
    /// documented range. Out-of-range values are pulled to the nearest
    /// bound; values that don't parse as numbers at all are DROPPED (the
    /// vendor default then applies — sending garbage risks a 400 that
    /// silences the whole read-aloud). Returns the list of keys that were
    /// changed so the caller can tell the user instead of adjusting
    /// silently. Applied both when the editor saves AND when a request is
    /// built, so definitions stored before this clamp existed are still
    /// safe on the wire.
    func clampedExtras() -> (extras: [String: String], adjusted: [String]) {
        var out = extras
        var adjusted: [String] = []
        for (key, raw) in extras {
            guard let range = kind.knobRange(key) else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let value = Double(trimmed) else {
                out.removeValue(forKey: key)
                adjusted.append(key)
                continue
            }
            let clamped = min(range.max, max(range.min, value))
            let formatted: String
            if range.integer {
                formatted = String(Int(clamped.rounded()))
            } else if clamped == value {
                continue  // in range — keep the user's exact text
            } else {
                formatted = String(format: "%g", clamped)
            }
            if formatted != trimmed {
                out[key] = formatted
                adjusted.append(key)
            }
        }
        return (out, adjusted)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Store

/// Persisted list of configured TTS services + which one is active.
///
/// Not `@MainActor` — mutated from settings UI (main) but read on the synthesis
/// queue too; all access goes through the serial `lock`.
final class TTSServiceStore: @unchecked Sendable {
    static let shared = TTSServiceStore()

    private static let servicesKey = "tts.services.v1"
    private static let selectedKey = "tts.selectedServiceId.v1"

    private let lock = NSLock()
    private var _services: [TTSServiceOptions]
    private var _selectedId: String?
    /// Keeps the foreground-refresh observer alive (see init). The store lives
    /// for the whole process, so it never needs removing.
    private var foregroundObserver: NSObjectProtocol?

    private init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Self.servicesKey),
           let decoded = try? JSONDecoder().decode([TTSServiceOptions].self, from: data) {
            _services = decoded
        } else {
            _services = []
        }
        let sel = d.string(forKey: Self.selectedKey)
        _selectedId = sel
        if let sel, !_services.contains(where: { $0.id == sel }) {
            _selectedId = nil
        }
        // [B09-V10 2026-10-22] Credentials can arrive from another device while
        // we are backgrounded (the keychain item is synchronizable). Without a
        // foreground refresh the "no key" answer was cached forever and the
        // service stayed unusable until the app was killed and relaunched.
        // Referenced by name so this store stays UIKit-free (it is also read
        // from non-UI callers).
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("UIApplicationDidBecomeActiveNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.invalidateCredentialCaches()
        }
    }

    // MARK: Reads

    var services: [TTSServiceOptions] {
        lock.lock(); defer { lock.unlock() }
        return _services
    }

    var selectedServiceId: String? {
        lock.lock(); defer { lock.unlock() }
        return _selectedId
    }

    /// The service the user explicitly picked (nil when "System" is selected).
    /// No implicit fall-forward to the first enabled service — the read-aloud
    /// chain decides fallback order explicitly.
    func selectedService() -> TTSServiceOptions? {
        lock.lock(); defer { lock.unlock() }
        guard let id = _selectedId else { return nil }
        return _services.first { $0.id == id }
    }

    func service(id: String) -> TTSServiceOptions? {
        lock.lock(); defer { lock.unlock() }
        return _services.first { $0.id == id }
    }

    // MARK: Writes

    func setServices(_ list: [TTSServiceOptions]) {
        lock.lock()
        _services = list
        if let id = _selectedId, !list.contains(where: { $0.id == id }) { _selectedId = nil }
        let snapshot = _services
        let sel = _selectedId
        lock.unlock()
        persist(snapshot, selected: sel)
    }

    func upsert(_ service: TTSServiceOptions) {
        var list = services
        if let i = list.firstIndex(where: { $0.id == service.id }) {
            list[i] = service
        } else {
            list.append(service)
        }
        setServices(list)
    }

    func remove(id: String) {
        // [B09-R10 2026-10-22] One write, not two. Clearing the selection via
        // setSelectedServiceId() persisted the OLD list with no selection, then
        // setServices() persisted the new list — two UserDefaults writes and two
        // change notifications for one deletion, plus a window where the service
        // still existed but nothing was selected.
        lock.lock()
        var list = _services
        list.removeAll { $0.id == id }
        let previousSelected = _selectedId
        let keepSelected = (previousSelected == id) ? nil : previousSelected
        _services = list
        _selectedId = keepSelected
        lock.unlock()
        persist(list, selected: keepSelected)
        ProviderKeychainHelper.deleteAPIKey(instanceId: "tts-\(id)", caller: "TTSServiceStore.remove")
        invalidateKeyPresence(forServiceId: id)
        // persist() already posts .ttsServicesChanged — no second post here.
    }

    func setSelectedServiceId(_ id: String?) {
        lock.lock()
        let previous = _selectedId
        _selectedId = id
        let snapshot = _services
        lock.unlock()
        persist(snapshot, selected: id)
        // [T-tts-services 09-11] A voice SWITCH mid-read restarts playback with
        // the new voice: stop current audio, collect the unread remainder, and
        // re-enqueue it. Letting the old audio finish would keep the OLD voice
        // for several more seconds after the user explicitly asked for the new
        // one. Selecting the same service again is a no-op (id == previous).
        if id != previous {
            Task { @MainActor in
                guard let rest = VoiceOutputPlayer.shared.stopAll(collectRemainder: true) else { return }
                // Drop the per-reply cloud/System snapshot so the next enqueue
                // re-resolves against the new service layer state.
                VoiceOutputState.shared.activeController?.restartReplyTTS()
                // Re-feed the remainder through the segmenter so batching
                // behaves like a fresh read (owner session preserved so a
                // concurrent chat's stop still works).
                VoiceOutputPlayer.shared.enqueueSegmented(rest.text, sessionId: rest.sessionId)
            }
        }
    }

    // MARK: Credential

    /// [B09-V5 2026-10-22] The KEY is cached too, not just its presence.
    ///
    /// `hasAPIKey` was cached (R-8) but every `TTSProviderBridge.provider(for:)`
    /// call still did a synchronous Keychain read — and `provider(for:)` is what
    /// `VoiceChain.canSpeak` runs for EVERY service on every render (settings
    /// row, group subtitle, sheet summary, the read-aloud label on the settings
    /// root). One settings refresh was a dozen Keychain IPCs on the main thread.
    ///
    /// Invalidation: save / delete / list change (local), plus app foreground
    /// (iCloud Keychain can deliver a key from another device while we are
    /// backgrounded — without that, the presence cache kept answering "no key"
    /// forever, which is V-10: an iPad-added key never showed up on the iPhone
    /// until a relaunch).
    private var keyCache: [String: String] = [:]
    private var keyMisses: Set<String> = []
    private let keyCacheLock = NSLock()

    func apiKey(for service: TTSServiceOptions) -> String? {
        let id = service.id
        keyCacheLock.lock()
        if let hit = keyCache[id] { keyCacheLock.unlock(); return hit }
        if keyMisses.contains(id) { keyCacheLock.unlock(); return nil }
        keyCacheLock.unlock()

        let key = ProviderKeychainHelper.loadAPIKey(instanceId: service.keychainInstanceId,
                                                   caller: "TTSServiceStore")
        keyCacheLock.lock()
        if let key, !key.isEmpty { keyCache[id] = key } else { keyMisses.insert(id) }
        keyCacheLock.unlock()
        return key
    }

    /// Drop every cached credential + presence flag. Called when the app comes
    /// back to the foreground (iCloud Keychain may have synced in the meantime)
    /// and whenever the local list/key changes.
    func invalidateCredentialCaches() {
        keyCacheLock.lock()
        keyCache.removeAll()
        keyMisses.removeAll()
        keyCacheLock.unlock()
        invalidateKeyPresence()
    }

    /// [B09-R8 2026-10-22] Presence cache. `hasAPIKey` is now asked on every
    /// render (list rows, group subtitle, summary, the chat sheet), and each miss
    /// was a synchronous Keychain IPC call on the main thread — a settings page
    /// refresh could do a dozen of them. Presence is cached per service id and
    /// invalidated whenever a key is saved, deleted or the service list changes;
    /// the KEY itself is still read fresh, only "is there one" is cached.
    private var keyPresence: [String: Bool] = [:]
    private let keyPresenceLock = NSLock()

    func hasAPIKey(for service: TTSServiceOptions) -> Bool {
        keyPresenceLock.lock()
        if let cached = keyPresence[service.id] {
            keyPresenceLock.unlock()
            return cached
        }
        keyPresenceLock.unlock()
        // Goes through apiKey(for:) so the key cache warms at the same time —
        // the next provider(for:) is then free.
        let present = (apiKey(for: service)?.isEmpty == false)
        keyPresenceLock.lock()
        keyPresence[service.id] = present
        keyPresenceLock.unlock()
        return present
    }

    /// Drop the cached presence for one service (or all of them).
    func invalidateKeyPresence(forServiceId id: String? = nil) {
        keyPresenceLock.lock()
        if let id { keyPresence.removeValue(forKey: id) } else { keyPresence.removeAll() }
        keyPresenceLock.unlock()
        keyCacheLock.lock()
        if let id { keyCache.removeValue(forKey: id); keyMisses.remove(id) }
        else { keyCache.removeAll(); keyMisses.removeAll() }
        keyCacheLock.unlock()
    }

    /// [T-capsule-service-picker 09-12] Id-keyed convenience for picker rows,
    /// which only carry the service id (not the full TTSServiceOptions).
    func hasAPIKey(forServiceId id: String) -> Bool {
        guard let s = service(id: id) else { return false }
        return hasAPIKey(for: s)
    }

    func saveAPIKey(_ key: String, for service: TTSServiceOptions) {
        ProviderKeychainHelper.saveAPIKey(key, instanceId: service.keychainInstanceId, caller: "TTSServiceStore")
        invalidateKeyPresence(forServiceId: service.id)
    }

    /// [B09-L04 2026-10-22] Remove just the credential, keeping the service
    /// definition (vendor/baseURL/model/voice). Before this the only way to drop
    /// a key was deleting the whole service and re-entering everything.
    func deleteAPIKey(for service: TTSServiceOptions) {
        ProviderKeychainHelper.deleteAPIKey(instanceId: service.keychainInstanceId,
                                            caller: "TTSServiceStore.deleteAPIKey")
        invalidateKeyPresence(forServiceId: service.id)
        NotificationCenter.default.post(name: .ttsServicesChanged, object: nil)
    }

    // MARK: Persistence

    private func persist(_ list: [TTSServiceOptions], selected: String?) {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(list) {
            d.set(data, forKey: Self.servicesKey)
        }
        if let selected {
            d.set(selected, forKey: Self.selectedKey)
        } else {
            d.removeObject(forKey: Self.selectedKey)
        }
        NotificationCenter.default.post(name: .ttsServicesChanged, object: nil)
    }
}

extension Notification.Name {
    /// Posted whenever the configured TTS service list / selection changes, so
    /// open settings UI and the read-aloud capsule refresh.
    static let ttsServicesChanged = Notification.Name("ttsServicesChanged")

    /// [T-system-voice-off 09-12] Fired by VoiceOutputPlayer when the whole
    /// queue drains WITHOUT producing audio (zero usable candidates — e.g.
    /// the System-voice switch is OFF and no service/group is configured).
    /// The reading VM listens and settles its isReadingAloud state so the
    /// capsule doesn't hang on "reading" with nothing playing.
    static let ttsQueueDrainedSilently = Notification.Name("ttsQueueDrainedSilently")
}
