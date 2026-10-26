import SwiftUI

// MARK: - TTS service editor
//
// [T-tts-services 09-11] Create / edit one voice service. Sections mirror
// kelivo's _NetworkTtsEditorPage:
//
//   Vendor      — picker with every supported vendor
//   Service     — name, base URL, API key (compound formats documented),
//                 model id, voice id, enable toggle
//   Tuning      — per-vendor knobs (emotion / speed / volume / pitch /
//                 output format / language / instruction / …)
//   Test        — speak a sample sentence through the CURRENT editor state,
//                 without saving first (the key field is used verbatim)
//
// Saving writes the definition to TTSServiceStore and the key to the Keychain
// under the service's own synthetic instance id.

struct TTSServiceEditorView: View {

    /// The service being edited; nil = creating a new one.
    let service: TTSServiceOptions?

    @Environment(\.dismiss) private var dismiss

    /// Plain-Sendable store — read fresh every render (see VoiceServicesView).
    private var store: TTSServiceStore { TTSServiceStore.shared }

    // Service fields — initialized from `service` or vendor defaults.
    @State private var name: String = ""
    @State private var kind: TTSServiceKind = .openai
    @State private var enabled: Bool = true
    @State private var baseURL: String = ""
    @State private var model: String = ""
    @State private var voice: String = ""
    @State private var apiKey: String = ""
    @State private var apiKeyFromKeychain: Bool = false
    /// Vendor-specific knobs. Keyed by TTSKnob.key.
    @State private var extras: [String: String] = [:]

    // Editor state.
    @State private var testing = false
    @State private var testResult: TestOutcome?
    @State private var loaded = false

    enum TestOutcome: Identifiable {
        case success
        case failure(String)
        var id: Int {
            if case .success = self { return 0 }
            return 1
        }
    }

    var body: some View {
        Form {
            vendorSection
            serviceSection
            tuningSection
            testSection
        }
        .scrollContentBackground(.hidden)
        .background(MinisTheme.color(.canvas, scope: .settings))
        .navigationTitle(service == nil ? "New Voice Service" : "Edit Voice Service")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { save() }
                    .disabled(!canSave)
            }
        }
        .onAppear(perform: load)
    }

    // MARK: Sections

    private var vendorSection: some View {
        Section("Vendor") {
            // [B09-S04 2026-10-22] The copy already said the vendor of a saved
            // service can't change, but the picker stayed live: switching it
            // saved a service whose kind no longer matched its baseURL/model/
            // voice, and every later synthesis failed. Lock it for real.
            Picker("Vendor", selection: $kind) {
                ForEach(TTSServiceKind.allCases) { k in
                    Label(k.displayName, systemImage: k.symbol).tag(k)
                }
            }
            .disabled(service != nil)
            if service != nil {
                Text("The vendor of an existing service can't be changed — create a new service instead.")
                    .font(.caption)
                    .foregroundStyle(MinisTheme.secondaryText)
            }
        }
    }

    private var serviceSection: some View {
        Section {
            LabeledTextField(label: "Name", text: $name, placeholder: "My voice")
            LabeledTextField(label: "Base URL", text: $baseURL, placeholder: kind.defaultBaseURL)
            SecureLabeledTextField(label: "API Key", text: $apiKey,
                                   placeholder: apiKeyPlaceholder,
                                   footnote: kind.compoundCredentialFormat)
            // [B09-L04 2026-10-22] Leaving the field empty means "keep the old
            // key", so there was no way to remove one — you had to delete the
            // whole service. Explicit button instead.
            if apiKeyFromKeychain && apiKey.isEmpty {
                Button(role: .destructive) {
                    store.deleteAPIKey(for: service ?? buildDraft())
                    apiKeyFromKeychain = false
                    MinisToast.show(AppLocalized("API key removed"), systemImage: "key.slash")
                } label: {
                    Text(AppLocalized("Remove saved API key"))
                }
            }
            LabeledTextField(label: "Model", text: $model, placeholder: kind.defaultModel)
            LabeledTextField(label: "Voice ID", text: $voice, placeholder: kind.defaultVoice)
            Toggle("Enabled", isOn: $enabled)
        } header: {
            Text("Service")
        } footer: {
            Text("Voice ID is the vendor's own voice identifier — e.g. OpenAI 'alloy', Azure 'zh-CN-XiaoxiaoNeural', MiniMax 'female-shaonv'. Anything the vendor accepts can be pasted here.")
        }
    }

    private var tuningSection: some View {
        Section {
            ForEach(kind.knobs) { knob in
                LabeledTextField(label: knob.title,
                                 text: bindingFor(knob.key),
                                 placeholder: knob.placeholder)
            }
            if kind.supportsInstruction && !kind.knobs.contains(where: { $0.key == "instruction" }) {
                LabeledTextField(label: "Instruction",
                                 text: bindingFor("instruction"),
                                 placeholder: "e.g. Speak softly, like whispering")
            }
        } header: {
            Text("Tuning")
        } footer: {
            Text("Left empty, a knob is simply not sent — the vendor uses its default.")
        }
    }

    private var testSection: some View {
        Section {
            Button {
                runTest()
            } label: {
                HStack {
                    if testing {
                        ProgressView().padding(.trailing, 4)
                    }
                    Label("Play test sentence", systemImage: "speaker.wave.2")
                    Spacer()
                }
            }
            .disabled(testing)

            if let outcome = testResult {
                switch outcome {
                case .success:
                    Label("Sounds right? Save it, then pick it in the list.",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(MinisTheme.success)
                        .font(.caption)
                case .failure(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(MinisTheme.destructive)
                        .font(.caption)
                }
            }
        } header: {
            Text("Test")
        } footer: {
            Text("Plays through the CURRENT editor state — the key above, unsaved included.")
        }
    }

    // MARK: Load / save

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let s = service {
            name = s.name
            kind = s.kind
            enabled = s.enabled
            baseURL = s.baseURL
            model = s.model
            voice = s.voice
            extras = s.extras
            apiKeyFromKeychain = store.hasAPIKey(for: s)
        } else {
            name = ""
            kind = .openai
            enabled = true
            baseURL = ""
            model = ""
            voice = ""
            extras = [:]
            apiKeyFromKeychain = false
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func bindingFor(_ key: String) -> Binding<String> {
        Binding(
            get: { extras[key] ?? "" },
            set: { extras[key] = $0 }
        )
    }

    private func buildDraft() -> TTSServiceOptions {
        TTSServiceOptions(
            id: service?.id ?? UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespaces),
            kind: kind,
            enabled: enabled,
            baseURL: baseURL.trimmingCharacters(in: .whitespaces),
            model: model.trimmingCharacters(in: .whitespaces),
            voice: voice.trimmingCharacters(in: .whitespaces),
            extras: extras
        )
    }

    private func save() {
        var draft = buildDraft()
        // [TTS-2] Save-time clamp: numeric tuning values are pulled into
        // the vendor's documented range before persisting (the request
        // builder clamps again at send time for older stored values).
        // When anything changed, say so — never rewrite silently.
        let clamp = draft.clampedExtras()
        if !clamp.adjusted.isEmpty {
            draft.extras = clamp.extras
            extras = clamp.extras
            let fields = clamp.adjusted.joined(separator: ", ")
            MinisToast.show(AppLocalized("Some tuning values were outside the supported range and have been adjusted: ")
                            + fields,
                            systemImage: "exclamationmark.triangle.fill")
        }
        store.upsert(draft)
        if !apiKey.isEmpty {
            store.saveAPIKey(apiKey, for: draft)
            // [T-tts-key-status 09-13] 醒醒 7: key 保存后回读校验——SecItemAdd
            // 的状态码旧代码只写日志不报错，保存"成功"实际没落进钥匙串时，
            // 列表/选择器永远显示 no key 而合成在别处兜底，两个状态对不上。
            // 这里写完立刻读一次，读不回来说明 Keychain 出了问题（受保护
            // 数据不可用/沙盒限制），当场 toast，别让她带着假配置走。
            if store.apiKey(for: draft) != apiKey {
                MinisToast.show(AppLocalized("API key could not be saved to the Keychain — check Settings → Privacy & Security. The service still works but will keep asking."),
                               systemImage: "exclamationmark.triangle.fill")
            }
        }
        // Select the newly created service so it is immediately the voice
        // in use (mirrors kelivo's add-then-select flow).
        if service == nil {
            store.setSelectedServiceId(draft.id)
        }
        dismiss()
    }

    // MARK: Test

    private func runTest() {
        let draft = buildDraft()
        // Use the editor's key verbatim; fall back to the stored one so a
        // saved service can be tested without re-typing its key.
        let key = apiKey.isEmpty ? store.apiKey(for: draft) : apiKey
        testing = true
        testResult = nil
        Task { @MainActor in
            do {
                guard let provider = TTSProviderBridge.provider(for: draft, apiKey: key) else {
                    throw VoiceProviderError.unsupported("This vendor cannot synthesize speech")
                }
                let request = TTSProviderBridge.request(for: draft,
                                                        text: draft.previewSentence)
                let data = try await provider.synthesize(request)
                guard !data.isEmpty else {
                    throw VoiceProviderError.noAudioData
                }
                // [T-tts-vendor-fix 09-13] Shared preview player: ends the
                // .replyTTS intent on finish and stops any previous preview
                // (audit #6/#11).
                try TTSPreviewPlayer.shared.play(data)
                testing = false
                testResult = .success
            } catch {
                testing = false
                testResult = .failure(error.localizedDescription)
            }
        }
    }

    private var apiKeyPlaceholder: String {
        apiKeyFromKeychain ? "Saved — leave empty to keep" : "Paste the API key"
    }
}

// MARK: - Field helpers

/// A labeled, placeheld text field row for the editor Form.
struct LabeledTextField: View {
    let label: String
    @Binding var text: String
    let placeholder: String
    var footnote: String? = nil
    var keyboardType: UIKeyboardType = .default

    var body: some View {
        // [B09-L07 2026-10-22] Label above the field, and no duplicate placeholder
        // — it used to read "My voice / Name" stacked bottom-up, i.e. backwards.
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(MinisTheme.secondaryText)
            TextField(label, text: $text, prompt: Text(placeholder).foregroundColor(MinisTheme.secondaryText))
                .keyboardType(keyboardType)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        // [B09-N08 2026-10-22] Was a static surface color; every other voice
        // page uses the theme-scoped dynamic role, so a custom light/dark theme
        // left these rows visibly out of step with the rest of the sheet.
        .listRowBackground(MinisTheme.color(.surface, scope: .settings))
        if let footnote = footnote {
            Text(footnote)
                .font(.caption2)
                .foregroundStyle(MinisTheme.secondaryText)
        }
    }
}

/// Password-style variant with an optional footnote (compound-credential hint).
struct SecureLabeledTextField: View {
    let label: String
    @Binding var text: String
    let placeholder: String
    var footnote: String? = nil

    var body: some View {
        // [B09-L07 2026-10-22] Same fix as LabeledTextField: label first.
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(MinisTheme.secondaryText)
            SecureField(label, text: $text, prompt: Text(placeholder).foregroundColor(MinisTheme.secondaryText))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        // [B09-N08 2026-10-22] Was a static surface color; every other voice
        // page uses the theme-scoped dynamic role, so a custom light/dark theme
        // left these rows visibly out of step with the rest of the sheet.
        .listRowBackground(MinisTheme.color(.surface, scope: .settings))
        if let footnote = footnote {
            Text(footnote)
                .font(.caption2)
                .foregroundStyle(MinisTheme.secondaryText)
        }
    }
}
