import SwiftUI

// MARK: - 选声链路共享文案

/// [audit-A10] 选声链路说明——语音服务页与 TTS 分组页四处页脚共用同一段话，
/// 终结"三处三种口径"；明确含 TTS 分组一级（旧文案全漏了它）。
enum VoiceServicesCopy {
    /// [B09-N01 2026-10-22] English source string (the xcstrings key), same as
    /// every other string in this layer — the old Chinese literal was shown
    /// verbatim to every language. Call sites wrap it in LocalizedStringKey.
    static let routingNote = "Who speaks: the service you ticked, then the default voice group's services in order, then the voice model group. The built-in System voice only joins when it is allowed below."
}

// MARK: - Voice Services (kelivo-style TTS service list)
//
// [T-tts-services 09-11] The list page of the independent TTS layer. One row per
// configured service; a row's own vendor icon + name + "model · voice" summary,
// with a trailing check on the active one. Mirrors kelivo's tts_services_page:
//
//   Voice Services            [+]        ← add
//   ┌────────────────────────────────┐
//   │ ◉ System (Apple)          ⚙ ✓ │    ← built-in, always present
//   │ ◉ ElevenLabs              ▶ ⚙ ✓│    ← configured services
//   │   eleven_multilingual_v2 · Rachel│
//   └────────────────────────────────┘
//   ┌────────────────────────────────┐
//   │ TTS 分组                    ›   │    ← default group & members
//   └────────────────────────────────┘
//   ┌────────────────────────────────┐
//   │ Cache audio for replay     [●] │    ← playback settings
//   │ Allow System voice         [○] │
//   └────────────────────────────────┘
//
// The System row is NOT a TTSServiceOptions: it is the always-available offline
// engine, and selecting it means "no service" (synthesis then follows the
// normal chain — default TTS group → model group; the System voice itself only
// speaks when "Allow System voice" is on). That keeps the new layer additive.
// [audit-A9] 示意图已对齐现状：Auto-read replies / Read 范围 两行控件已删，
// 增补 TTS 分组一级。

struct VoiceServicesView: View {

    @ObservedObject private var appearanceStudio = AppearanceStudio.shared

    @State private var editing: TTSServiceOptions?
    @State private var showAddSheet = false
    @State private var showSystemEditor = false
    /// [audit-A7] 系统语音开闸确认框。
    @State private var showSystemSwitchConfirm = false
    /// [B09-N11 2026-10-22] Staged delete target (swipe → confirmation).
    @State private var pendingDelete: TTSServiceOptions?
    /// TTSServiceStore is a plain Sendable (read from the synthesis queue too),
    /// not an ObservableObject — this throws on its change notification so the
    /// list re-renders on add / edit / delete / selection.
    @State private var storeRevision = 0

    /// The shared store; read fresh on every render (it is a plain Sendable).
    private var store: TTSServiceStore { TTSServiceStore.shared }

    var body: some View {
        List {
            // [B09 2026-10-22] Answer "what will speak" at the top. The page is a
            // list of configuration; the one thing a user opening it wants is
            // the current answer, and it used to require reading three sections
            // and knowing which one wins.
            summarySection
            groupsSection
            servicesSection
            providerVoiceSection
            playbackSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Voice Services")
        .navigationBarTitleDisplayMode(.inline)
        .appearancePage(.settings)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add voice service")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ttsServicesChanged)) { _ in
            storeRevision &+= 1
        }
        .sheet(isPresented: $showAddSheet) {
            NavigationStack {
                TTSServiceEditorView(service: nil)
            }
        }
        .sheet(item: $editing) { service in
            NavigationStack {
                TTSServiceEditorView(service: service)
            }
        }
        .sheet(isPresented: $showSystemEditor) {
            NavigationStack {
                SystemVoiceEditorView()
            }
        }
        .listRowBackground(appearanceStudio.color(.surface, scope: .settings))
        // [audit-A7] 系统语音开闸确认（与 C2 同款口径：先问，再改路由）。
        .confirmationDialog("Switch the speaking voice to System?", isPresented: $showSystemSwitchConfirm, titleVisibility: .visible) {
            Button("Switch to System voice") {
                VoiceOutputPreferences.systemVoiceAllowed = true
                store.setSelectedServiceId(nil)
                // [B09-N02 2026-10-22] Was a hardcoded Chinese string shown even
                // on an English UI.
                MinisToast.show(AppLocalized("Switched to System voice"), systemImage: "waveform")
            }
            Button("Keep current setting", role: .cancel) {}
        } message: {
            Text("System voice is muted. Allowing it lets it speak for read-aloud and AI voice replies; you can turn it off here anytime.")
        }
        // [B09-N11 2026-10-22] Deleting a service also deletes its stored API
        // key from the Keychain — irreversible, and the old swipe deleted it
        // outright with no undo.
        .confirmationDialog(
            AppLocalized("Delete this voice service?"),
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(AppLocalized("Delete"), role: .destructive) {
                if let s = pendingDelete { store.remove(id: s.id) }
                pendingDelete = nil
            }
            Button(AppLocalized("Cancel"), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(AppLocalized("Its API key is deleted too. Groups that reference it keep the gap."))
        }
    }

    // MARK: Summary

    /// One line: who speaks right now, plus the reason when nothing can.
    private var summarySection: some View {
        let label = VoiceProviderResolver.effectiveVoiceLabel()
        // [B09-V1 2026-10-22] Same single chain the player uses. This block had
        // its own three-tier test, one tier wider than the player's, so it could
        // report "Speaking now" for a setup that synthesizes nothing.
        let broken = VoiceChain.silenceReason()
        return Section {
            HStack(spacing: 12) {
                rowIcon(symbol: broken == nil ? "waveform" : "speaker.slash.fill", active: broken == nil)
                VStack(alignment: .leading, spacing: 2) {
                    Text(broken == nil ? AppLocalized("Speaking now") : AppLocalized("No voice"))
                        .font(.subheadline.weight(.medium))
                    Text(broken ?? label)
                        .font(.caption)
                        .foregroundStyle(broken == nil ? MinisTheme.secondaryText : MinisTheme.destructive)
                }
                Spacer()
            }
        }
    }

    // MARK: Services

    private var servicesSection: some View {
        Section {
            systemRow

            ForEach(store.services) { service in
                serviceRow(service)
            }
            .onDelete { indexSet in
                // [B09-N11 2026-10-22] Route through the same confirmation as
                // the swipe action — one deletion path, always asks.
                if let i = indexSet.first, i < store.services.count {
                    pendingDelete = store.services[i]
                }
            }
        } header: {
            Text("Text-to-Speech")
        } footer: {
            Text(LocalizedStringKey(VoiceServicesCopy.routingNote))
        }
    }

    /// [B09-N14 2026-10-22] Voice providers borrowed from an existing provider
    /// instance (an audio-modality model on a configured provider). They used
    /// to live only under Settings › Providers as a second, differently-behaved
    /// "Voice Services" list — two answers to "where do I set up my voice".
    /// Same rows, one home now.
    @ViewBuilder
    private var providerVoiceSection: some View {
        let shadows = ProviderConfigStore.shared.shadowVoiceProviders()
        if !shadows.isEmpty {
            Section {
                ForEach(shadows) { shadow in
                    NavigationLink {
                        ShadowVoiceProviderDetailView(instanceId: shadow.instanceId)
                    } label: {
                        HStack(spacing: 12) {
                            rowIcon(symbol: "waveform", active: false)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(shadow.displayName)
                                Text(shadowSummary(shadow))
                                    .font(.caption)
                                    .foregroundStyle(MinisTheme.secondaryText)
                            }
                        }
                    }
                }
            } header: {
                Text("From your providers")
            } footer: {
                Text("Voice models you already configured on a provider. They use that provider's key and endpoint.")
            }
        }
    }

    private func shadowSummary(_ shadow: ProviderConfigStore.ShadowVoiceProvider) -> String {
        var parts: [String] = []
        // Counts are numeric, not localized prose — same shape as the shadow row
        // this replaced.
        if !shadow.inputModels.isEmpty { parts.append("\(shadow.inputModels.count) STT") }
        if !shadow.outputModels.isEmpty { parts.append("\(shadow.outputModels.count) TTS") }
        return parts.joined(separator: " · ")
    }

    /// The built-in Apple engine — selectable; the gear opens the System voice
    /// editor (voice roster + pitch/volume/speed), same as any cloud service.
    /// [T-system-voice-off 09-12] 修复审查问题7: with the "Allow System voice"
    /// switch OFF this engine never speaks, so the row must SAY so — dimmed,
    /// "muted by setting" caption.
    /// [audit-A7] 点被静音的行不再静默开闸（与 SystemVoiceEditorView 的 C2
    /// 确认口径一致）：一次点选会永久开启系统语音，先弹确认框由用户决定。
    private var systemRow: some View {
        // [audit-A6] "正在使用"不再只看"没选服务"——服务/默认分组/模型组三级
        // 逐层让位判定，与聊天语音设置弹窗的标签共用同一条解析链
        // (VoiceProviderResolver.isSystemVoiceEffectivelyActive)。
        let isActive = VoiceProviderResolver.isSystemVoiceEffectivelyActive()
        let allowed = VoiceOutputPreferences.systemVoiceAllowed
        return Button {
            if allowed {
                store.setSelectedServiceId(nil)
            } else {
                // [audit-A7] 静默开闸 → 确认框（与 C2 同一口径：改路由先确认，
                // 不能让一次点选永久开启系统语音）。
                showSystemSwitchConfirm = true
            }
        } label: {
            HStack(spacing: 12) {
                rowIcon(symbol: "apple.logo", active: isActive && allowed)
                VStack(alignment: .leading, spacing: 2) {
                    Text("System (Apple)")
                        .foregroundStyle(allowed ? MinisTheme.primaryText : MinisTheme.secondaryText)
                    Text(allowed
                         ? "Offline · on-device voice"
                         : "Muted — tap to allow System voice")
                        .font(.caption)
                        .foregroundStyle(MinisTheme.secondaryText)
                }
                Spacer()
                trailingControls(system: true, active: isActive)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: TTS Groups

    /// [tts-groups 2026-10-02] 分组入口：对标 API 的模型分组列表。
    private var groupsSection: some View {
        Section {
            NavigationLink {
                TTSGroupsView()
            } label: {
                HStack(spacing: 12) {
                    rowIcon(symbol: "square.stack.3d.up.fill",
                            active: TTSGroupStore.shared.defaultGroupId != nil)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Voice Groups")
                            .foregroundStyle(MinisTheme.primaryText)
                        Text(groupSubtitle)
                            .font(.caption)
                            .foregroundStyle(MinisTheme.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(MinisTheme.secondaryText)
                }
            }
        } header: {
            Text("Group")
        } footer: {
            Text(LocalizedStringKey(VoiceServicesCopy.routingNote))
        }
    }

    /// [B09-R6 2026-10-22] Localized at the source. These were Chinese
    /// interpolated Strings shown through `Text(String)`, which does NOT consult
    /// the String Catalog — so an English UI printed "默认：X（3 个可用服务）".
    private var groupSubtitle: String {
        let store = TTSGroupStore.shared
        if let gid = store.defaultGroupId, let g = store.group(id: gid) {
            // [B09-S02 2026-10-22] "可用"必须和合成链的口径一致：存在 + 启用
            // + 有 key。之前这里用 candidates(for:) 只算 enabled，缺 key 的
            // 也算进 N，用户看到"3 个可用"却一个都出不了声。
            let n = store.usableCandidates(for: g).count
            let total = store.candidates(for: g).count
            if n == 0 && total > 0 {
                return AppLocalized("Default: \(g.name) — all \(total) services are missing an API key")
            }
            return AppLocalized("Default: \(g.name) — \(n) usable service(s)")
        }
        return store.groups.isEmpty
            ? AppLocalized("No group yet")
            : AppLocalized("\(store.groups.count) group(s), no default set")
    }

    private func serviceRow(_ service: TTSServiceOptions) -> some View {
        let isActive = store.selectedServiceId == service.id
        // [B09-S02 2026-10-22] A service with no stored key can never speak, but
        // the row used to look perfectly healthy and could be checked — the
        // failure only surfaced as silence at read-aloud time. Show it, and
        // refuse the check with a reason instead of a silent dead end.
        let hasKey = store.hasAPIKey(for: service)
        // [B09-V4 2026-10-22] Same predicate as playback: enabled + key + the
        // vendor can build a provider. A malformed credential (iFlytek missing
        // its secret segment) used to be checkable and then silent.
        let usable = VoiceChain.canSpeak(service)
        return Button {
            guard usable else {
                let reason: String
                if !service.enabled {
                    reason = AppLocalized("This service is turned off — enable it first")
                } else if !hasKey {
                    reason = AppLocalized("No API key saved for this service — open it and add the key")
                } else {
                    // Enabled + keyed, but the credential cannot build a
                    // provider — the one case that used to look healthy.
                    reason = AppLocalized("This service's saved credentials are incomplete — open it and re-enter the key")
                }
                MinisToast.show(reason, systemImage: "exclamationmark.triangle.fill")
                return
            }
            store.setSelectedServiceId(service.id)
        } label: {
            HStack(spacing: 12) {
                rowIcon(symbol: service.kind.symbol, active: isActive)
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.name)
                        .foregroundStyle(service.enabled ? MinisTheme.primaryText : MinisTheme.secondaryText)
                    Text("\(service.model) · \(service.voice)")
                        .font(.caption)
                        .foregroundStyle(MinisTheme.secondaryText)
                        .lineLimit(1)
                    if !hasKey {
                        Text(AppLocalized("No API key — tap to add one"))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(MinisTheme.destructive)
                    } else if !service.enabled {
                        Text(AppLocalized("Turned off"))
                            .font(.caption2)
                            .foregroundStyle(MinisTheme.secondaryText)
                    }
                }
                Spacer()
                trailingControls(system: false, active: isActive, service: service)
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                // [B09-N11 2026-10-22] Deleting a service also wipes its Keychain
                // entry — irreversible. Ask first instead of deleting on a swipe.
                pendingDelete = service
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                editing = service
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(MinisTheme.accent)
        }
    }

    private func rowIcon(symbol: String, active: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(active ? MinisTheme.accent.opacity(0.15) : MinisTheme.mutedSurface)
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(active ? MinisTheme.accent : MinisTheme.secondaryText)
        }
        .frame(width: 32, height: 32)
    }

    @ViewBuilder
    private func trailingControls(system: Bool, active: Bool, service: TTSServiceOptions? = nil) -> some View {
        HStack(spacing: 18) {
            if system {
                // System engine: gear opens the system-voice editor sheet.
                Button {
                    showSystemEditor = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(MinisTheme.secondaryText)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Edit System voice")
            }
            if let service {
                // Test-listen: synthesizes a short phrase through this service
                // right from the list (uses the SAVED definition + stored key).
                Button {
                    preview(service)
                } label: {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(MinisTheme.secondaryText)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Test \(service.name)")
            }
            if !system, let service {
                Button {
                    editing = service
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(MinisTheme.secondaryText)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Edit \(service.name)")
            }
            Image(systemName: active ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17))
                .foregroundStyle(active ? MinisTheme.accent : MinisTheme.secondaryText.opacity(0.4))
        }
    }

    /// List-level test: synthesize a short phrase via the saved service and
    /// play it. Errors surface as a toast, not an inline label (the editor
    /// has the richer inline test experience).
    @State private var previewing = false
    private func preview(_ service: TTSServiceOptions) {
        guard !previewing else { return }
        // [B09-S02 2026-10-22] Say what's wrong in the user's language instead of
        // letting the vendor return a raw 401/403 that gets toasted verbatim.
        guard store.hasAPIKey(for: service) else {
            MinisToast.show(AppLocalized("No API key saved for this service — open it and add the key"),
                            systemImage: "exclamationmark.triangle.fill")
            return
        }
        previewing = true
        Task { @MainActor in
            defer { previewing = false }
            do {
                // [B09-V4 2026-10-22] Distinguish "this vendor has no TTS" from
                // "your saved credential is incomplete" — both used to say
                // "this vendor cannot synthesize speech", which sent users
                // looking for a vendor problem that did not exist.
                guard let provider = TTSProviderBridge.provider(for: service) else {
                    throw VoiceProviderError.unsupported(
                        service.kind == .xunfei
                        ? AppLocalized("iFlytek needs appId;apiKey;apiSecret in one field — re-enter the key")
                        : AppLocalized("This vendor cannot synthesize speech"))
                }
                let request = TTSProviderBridge.request(for: service, text: service.previewSentence)
                let data = try await provider.synthesize(request)
                guard !data.isEmpty else { throw VoiceProviderError.noAudioData }
                // [T-tts-vendor-fix 09-13] Play via the shared TTSPreviewPlayer:
                // it stops the previous preview (no stacking) and ENDS the
                // .replyTTS intent on finish (the old local-player leak kept
                // the audio session in .playback forever — audit #6/#11).
                try TTSPreviewPlayer.shared.play(data)
            } catch {
                MinisToast.show(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
            }
        }
    }

    // MARK: Playback

    private var playbackSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { VoiceOutputPreferences.cacheNetworkAudio },
                set: { VoiceOutputPreferences.cacheNetworkAudio = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cache audio for replay")
                    Text("Keep synthesized audio so replaying costs nothing")
                        .font(.caption)
                        .foregroundStyle(MinisTheme.secondaryText)
                }
            }

            // [T-system-voice-off 09-12] 醒醒 3: System voice is opt-in. OFF
            // (default) = the built-in Apple voice never speaks — replies use
            // your TTS service / voice group only, and stay silent when those
            // are unusable, instead of falling back to the robotic engine.
            Toggle(isOn: Binding(
                get: { VoiceOutputPreferences.systemVoiceAllowed },
                set: { VoiceOutputPreferences.systemVoiceAllowed = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow System voice")
                    Text("OFF = only your configured voices speak; never the built-in Apple voice")
                        .font(.caption)
                        .foregroundStyle(MinisTheme.secondaryText)
                }
            }

        } header: {
            Text("Playback")
        }
    }
}

