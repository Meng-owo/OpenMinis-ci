import Foundation
import UIKit
import SwiftUI

// MARK: - VoiceProviderResolver
//
// Resolves the voice INPUT/OUTPUT provider from the configured ModelGroup
// (voiceInputGroupId / voiceOutputGroupId, parallel to Default Primary/Sub).
// Walks the group's members, keeps only audio-capable voice models for the
// direction, and returns the first usable provider. Falls back to the offline
// System provider when nothing in the group is usable (or no group is set).

/// In-memory voice model override — like an input method's current selection.
/// Set by the Voice Model Selector, takes precedence over the configured group,
/// and is NOT persisted: it resets to the configured default on cold start.
@MainActor
final class VoiceSelectionStore: ObservableObject {
    static let shared = VoiceSelectionStore()
    /// Selected ModelEntry id for ASR (nil = use configured group / System).
    @Published var inputEntryId: String?
    /// Selected ModelEntry id for TTS.
    @Published var outputEntryId: String?
    private init() {}
}

/// In-memory composer input-mode (voice vs text), shared across ALL chat
/// sessions — like an input method's current state. Switching to voice in one
/// session carries into the next; NOT persisted, so a cold start resets to text.
@MainActor
final class VoiceModePreference: ObservableObject {
    static let shared = VoiceModePreference()
    /// True = composer is in inline-voice mode; false = text mode.
    @Published var isVoiceActive = false
    /// Whether the inline voice panel is expanded (vs compact). In-memory, carried
    /// across sessions — the panel resumes whatever the user left it at. Reset to
    /// the default (expanded) only on cold start.
    @Published var expanded = true
    /// One-shot: set true when the user switches text→voice, so the panel opens
    /// expanded that one time, then resumes the remembered state afterwards.
    var enteredFromText = false
    /// True while the mic is actively capturing (VAD running). Reply TTS is
    /// SUPPRESSED while this is true — capture and playback are mutually exclusive
    /// (no echo, no AVAudioSession category fight). Set by VoiceInputViewModel
    /// around startVAD / stopListening.
    @Published var isCapturing = false
    private init() {}
}

/// The actions a chat VM exposes so the GLOBAL voice capsule (which has no
/// session vm) can drive whichever session is currently reading aloud. The active
/// controller registers itself with `VoiceOutputState` when it starts speaking.
@MainActor
protocol SpeechControlling: AnyObject {
    func toggleSpeechPause()
    func stopSpeech()
    func nextSpeechSpeed()
    /// [T-tts-services 09-11] The selected TTS voice changed mid-read: drop the
    /// per-reply engine snapshot so subsequent enqueues resolve against the new
    /// service instead of continuing on the old cloud/System decision.
    func restartReplyTTS()
}

/// GLOBAL read-replies (TTS output) state — a single source of truth shared
/// across ALL chat sessions and the home screen. Backed by persisted
/// `VoiceOutputPreferences`. It also MIRRORS the live read-aloud state
/// (reading / paused / speed) from the active session so the home-screen capsule
/// can render + control playback without owning a session vm.
@MainActor
final class VoiceOutputState: ObservableObject {
    static let shared = VoiceOutputState()

    // [batch9-voice-1b] 自动朗读与静音门控已删：isEnabled / isMuted / canPlay
    // 退役——朗读只在用户显式点读时发生，读完即止。

    // Mirrored live state (pushed by the active controller).
    @Published var isReadingAloud = false
    @Published var speechPaused = false
    @Published var speechSpeed: Float = VoiceOutputPreferences.speedMultiplier

    /// [T-message-action-bar 09-11] Unified "paused" read for UI: the mirrored
    /// VM state (System path) OR the cloud player's latch. Both UIs (capsule,
    /// bubble bar) read this so their pause icons always agree.
    var isPausedOrHeld: Bool {
        speechPaused || VoiceOutputPlayer.shared.isPaused
    }

    /// The session currently reading aloud — global capsule actions forward here.
    weak var activeController: SpeechControlling?

    /// Called by a chat VM when it becomes the one reading aloud.
    func registerActive(_ controller: SpeechControlling) {
        activeController = controller
    }

    /// Push live state up from the active controller so the capsule reflects it.
    func syncState(reading: Bool, paused: Bool, speed: Float) {
        if isReadingAloud != reading { isReadingAloud = reading }
        if speechPaused != paused { speechPaused = paused }
        if speechSpeed != speed { speechSpeed = speed }
    }

    // MARK: Global capsule actions (forward to the active controller; fall back to
    // the cloud player when no session vm is active).
    func togglePause() {
        if let c = activeController { c.toggleSpeechPause() }
        else { VoiceOutputPlayer.shared.isPaused ? VoiceOutputPlayer.shared.resume()
                                                 : VoiceOutputPlayer.shared.pause() }
    }
    func stop() {
        VoiceLog.log("[VoiceOutputState] stop()")
        if let c = activeController { c.stopSpeech() }
        else { VoiceOutputPlayer.shared.stopAll() }
        isReadingAloud = false; speechPaused = false
    }
    func nextSpeed() {
        if let c = activeController {
            c.nextSpeechSpeed()
        } else {
            // [T-capsule-speed-orphan] No session VM registered — reads started
            // from the markdown preview / selection menus outside a chat. The
            // pause/stop buttons above fall back to driving the player
            // directly; the speed chip had NO fallback and was a dead control
            // in exactly that path. Apply the same persistence + live-rate
            // semantics as the VM's setSpeechSpeed.
            let steps = VoiceOutputPreferences.speedSteps
            let cur = VoiceOutputPreferences.speedMultiplier
            let idx = steps.firstIndex(of: cur) ?? 0
            let next = steps[(idx + 1) % steps.count]
            VoiceOutputPreferences.speedMultiplier = next
            speechSpeed = next
            VoiceOutputPlayer.shared.setRate(next)
        }
    }
    private init() {
        registerLiveActivityToggleObserver()
    }

    /// [T-ios-live-activity-audio-toggle] Observe the Darwin notification the
    /// Live Activity play/pause button posts (from the widget process) and
    /// pause/resume read-aloud here in the app process. Relocated here from
    /// GlobalAudioPlayer as part of the b0f3f884 root-cause fix: the toggle
    /// drives the TTS engine (VoiceOutputState), not the chat audio-attachment
    /// player. `VoiceOutputState` is a never-deallocated singleton, so an
    /// unretained observer token is safe.
    private func registerLiveActivityToggleObserver() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center, observer,
            { _, _, _, _, _ in
                // Darwin callbacks are C function pointers (no captured context),
                // so hop back to the singleton on the main actor.
                Task { @MainActor in
                    VoiceOutputState.shared.handleLiveActivityToggle()
                }
            },
            AudioTogglePlaybackBridge.darwinNotificationName as CFString,
            nil, .deliverImmediately
        )
    }

    /// [T-ios-live-activity-audio-toggle] Pause/resume read-aloud in response to
    /// the Live Activity button, then immediately push the audio state to the
    /// Live Activity so the icon flips without waiting for the next periodic
    /// refresh. Routed via `togglePause()` → activeController (System TTS) or
    /// VoiceOutputPlayer (cloud), never `stop()`.
    func handleLiveActivityToggle() {
        VoiceLog.log("[VoiceOutputState] Live Activity toggle received — isReadingAloud=\(isReadingAloud) speechPaused=\(speechPaused)")
        guard isReadingAloud else { return }
        togglePause()
        // [T-live-activity-audio-toggle-latency] This exact source string is what
        // tells AgentLiveActivityManager the push came from a USER TAP and may skip
        // the 3s/5s throttle (so the speaker glyph flips immediately). Use the
        // shared constant — a typo here would silently reinstate the up-to-5s lag.
        BackgroundKeepAliveManager.shared.audioPlaybackStateChanged(
            source: AgentLiveActivityManager.userAudioToggleSource
        )
    }
}


@MainActor
enum VoiceProviderResolver {

    private static let logger = AppLogger(category: "VoiceResolver")

    static let systemEntryId = SystemVoiceProvider.builtinProviderId

    /// Resolved ASR entry: in-memory override first, else the configured group.
    /// Whether this entry ID refers to the built-in System voice provider.
    static func isSystemEntry(_ entryId: String?) -> Bool {
        guard let eid = entryId else { return false }
        return eid == systemEntryId || eid.hasPrefix(systemEntryId + "/")
    }

    /// The AVSpeechSynthesisVoice identifier the user picked for System TTS, if a
    /// SPECIFIC voice was chosen (composite id "<sentinel>/<voice.identifier>").
    /// Returns nil for the bare sentinel or legacy "…/system-tts" default, so the
    /// caller keeps its by-language auto-selection (no regression). The suffix is
    /// a real voice id only when it looks like one (contains a dot).
    static func selectedSystemVoiceId(_ entryId: String?) -> String? {
        guard let eid = entryId, eid.hasPrefix(systemEntryId + "/") else { return nil }
        let suffix = String(eid.dropFirst(systemEntryId.count + 1))
        return suffix.contains(".") ? suffix : nil
    }

    /// The System TTS voice identifier for the currently-resolved output selection
    /// (override → configured group member), or nil to auto-select by language.
    static func resolvedSystemOutputVoiceId() -> String? {
        if let vid = selectedSystemVoiceId(VoiceSelectionStore.shared.outputEntryId) {
            return vid
        }
        // [T-tts-services 09-11] The Voice Services page's System editor can
        // pin a voice directly (without touching the Model-Group machinery) —
        // honour that before the group-member scan so the two paths agree.
        if let pinned = SystemVoiceEditorPreferences.selectedVoiceId {
            return pinned
        }
        // Also honor a specific System voice pinned as a member of the configured
        // output group (first system member that names a concrete voice).
        guard let gid = ProviderConfigStore.shared.voiceOutputGroupId,
              let group = ProviderConfigStore.shared.group(for: gid) else { return nil }
        for mid in group.memberEntryIds {
            if let vid = selectedSystemVoiceId(mid) { return vid }
        }
        return nil
    }

    /// Which System ASR variant the user selected. Offline = on-device (privacy,
    /// no limits, language switch matters); Online = server/cloud (accuracy, more
    /// languages). `.auto` = no explicit choice → provider prefers on-device when
    /// available.
    enum SystemInputMode { case auto, online, offline }

    /// Resolve the System ASR mode from the current input selection (override id
    /// first, else a System member pinned in the configured input group). Reads the
    /// "…/system-asr-online" / "…/system-asr-offline" suffix; anything else = .auto.
    static func resolvedSystemInputMode() -> SystemInputMode {
        func mode(_ id: String?) -> SystemInputMode? {
            guard let id else { return nil }
            if id.hasSuffix("/system-asr-online")  { return .online }
            if id.hasSuffix("/system-asr-offline") { return .offline }
            return nil
        }
        if let m = mode(VoiceSelectionStore.shared.inputEntryId) { return m }
        if let gid = ProviderConfigStore.shared.voiceInputGroupId,
           let group = ProviderConfigStore.shared.group(for: gid) {
            for mid in group.memberEntryIds { if let m = mode(mid) { return m } }
        }
        return .auto
    }

    static func resolvedInputEntry() -> ModelEntry? {
        let sel = VoiceSelectionStore.shared.inputEntryId
        if isSystemEntry(sel) { return nil }
        if let direct = usableEntry(sel, direction: .input) { return direct }
        // Override didn't resolve (entry missing/disabled/no provider) → fall back
        // to the configured voice group's first usable member.
        let fallback = resolveEntry(groupId: ProviderConfigStore.shared.voiceInputGroupId, direction: .input)
        if sel != nil {
            logger.info("inputEntryId override '\(sel!)' not usable → fallback to \(fallback?.model.displayName ?? "System")")
        }
        return fallback
    }

    /// Resolved TTS entry: in-memory override first, else the configured group.
    static func resolvedOutputEntry() -> ModelEntry? {
        let sel = VoiceSelectionStore.shared.outputEntryId
        if isSystemEntry(sel) { return nil }
        return usableEntry(sel, direction: .output)
            ?? resolveEntry(groupId: ProviderConfigStore.shared.voiceOutputGroupId, direction: .output)
    }

    /// Display name of the currently-resolved ASR engine (for UI). `includeInstance`
    /// false → just the model name (used where the group name is already shown, so
    /// the chip reads "Group · Model" instead of "Group · Model · Instance").
    static func inputModelLabel(includeInstance: Bool = true) -> String {
        label(for: resolvedInputEntry(), includeInstance: includeInstance)
    }

    /// Display name of the currently-resolved TTS engine (for UI).
    static func outputModelLabel(includeInstance: Bool = true) -> String {
        label(for: resolvedOutputEntry(), includeInstance: includeInstance)
    }

    /// [audit-A6/D2] "此刻谁会发声"的唯一口径 —— 语音服务页的 System 行判定与
    /// 聊天语音设置弹窗的「朗读声音」标签共用同一条解析链，避免再出现
    /// "正在使用"与真实发声方错位。
    ///
    /// [B09-V1 2026-10-22] The ORDER and the eligibility test now both come from
    /// `VoiceChain` — this function used to carry a second copy of the chain, so
    /// fixing the player's order left the label claiming a different speaker.
    /// Order: selected service → default group → (last model that really spoke)
    /// → the configured voice model group.
    static func effectiveVoiceLabel() -> String {
        if let svc = VoiceChain.selectedService() { return svc.name }
        let groupStore = TTSGroupStore.shared
        if let g = groupStore.defaultGroup(), !groupStore.usableCandidates(for: g).isEmpty {
            // [B09-V7 2026-10-22] Was a hardcoded "分组 · \(g.name)" — the very
            // first line a user reads on the settings root, in Chinese, on every
            // language. Goes through the String Catalog now.
            return AppLocalized("Group · \(g.name)")
        }
        if let instance = VoiceOutputPlayer.shared.activeModelLabel {
            return instance
        }
        return outputModelLabel()
    }

    /// [audit-A6] System 内建引擎此刻是否真的在发声链上 —— 服务、默认 TTS 分组、
    /// 模型组三级逐层让位检查。此前只看 `selectedServiceId == nil`，把"没选服务"
    /// 错当成"就是 System"（建了默认分组/模型组时其实都不是它）。
    static func isSystemVoiceEffectivelyActive() -> Bool {
        if VoiceChain.hasServiceTarget() { return false }
        if !VoiceOutputPreferences.systemVoiceAllowed { return false }
        guard let first = resolvedOutputCandidates().first else { return false }
        return isSystemEntry(first.providerInstanceId)
    }

    /// Name of the group the resolved ASR entry belongs to (the configured voice
    /// input group), or nil when the offline System / a bare override is in use.
    static func inputGroupName() -> String? {
        let store = ProviderConfigStore.shared
        let sel = VoiceSelectionStore.shared.inputEntryId
        // Show the group name when: (1) no override (following the group), or
        // (2) the override is a member of the configured group (picked a specific
        // model within it). Don't show when the override is the System sentinel or
        // a model from a different provider.
        guard let gid = store.voiceInputGroupId,
              let g = store.group(for: gid) else { return nil }
        if sel == nil || sel == systemEntryId { return sel == nil ? g.name : nil }
        if g.memberEntryIds.contains(sel!) { return g.name }
        return nil
    }

    /// Resolve the voice INPUT (ASR) provider; offline System fallback.
    static func inputProvider() -> any VoiceInputCapable {
        provider(for: resolvedInputEntry(), capable: { $0.supportsVoiceInput }) ?? SystemVoiceProvider.shared
    }

    /// Resolve the voice OUTPUT (TTS) provider; offline System fallback.
    static func outputProvider() -> any VoiceOutputCapable {
        provider(for: resolvedOutputEntry(), capable: { $0.supportsVoiceOutput }) ?? SystemVoiceProvider.shared
    }

    // MARK: - Resolution

    private static func voiceCredentialOK(_ instance: ProviderInstance) -> Bool {
        // The built-in System engine needs no credential (offline / on-device), so
        // it's always usable; cloud instances need a stored credential.
        if instance.id == SystemVoiceProvider.builtinProviderId { return true }
        return instance.hasAnyCredential
    }

    /// Validate a directly-selected entry id (override) for the direction.
    /// Accepts both dedicated voice models (audio-only) AND multimodal models
    /// that can serve this direction (audio+text input for ASR, audio output for
    /// TTS) — the latter use chat-based transcription at runtime.
    private static func usableEntry(_ entryId: String?, direction: VoiceDirection) -> ModelEntry? {
        let store = ProviderConfigStore.shared
        guard let entryId, let entry = store.entry(for: entryId),
              canServe(entry.model, direction: direction),
              let instance = store.instance(for: entry.providerInstanceId),
              instance.isEnabled, voiceCredentialOK(instance),
              VoiceProviderFactory.make(for: instance) != nil else { return nil }
        return entry
    }

    /// Whether `model` can serve `direction`: dedicated voice model OR multimodal
    /// with the required audio modality.
    private static func canServe(_ model: LLMModel, direction: VoiceDirection) -> Bool {
        if direction.isVoiceModel(model) { return true }
        let m = model.capabilities.supportedModalities
        switch direction {
        case .input:  return m.contains(.audioInput)
        case .output: return m.contains(.audioOutput)
        }
    }

    /// The first audio-capable member of `groupId` whose instance is usable for
    /// `direction`. Returns nil → caller uses the offline System provider.
    private static func resolveEntry(groupId: String?, direction: VoiceDirection) -> ModelEntry? {
        resolveEntries(groupId: groupId, direction: direction).first
    }

    /// ALL audio-capable, usable members of `groupId` for `direction`, in group
    /// order. Used for fail-over (try the next model when one errors).
    private static func resolveEntries(groupId: String?, direction: VoiceDirection) -> [ModelEntry] {
        let store = ProviderConfigStore.shared
        guard let groupId, let group = store.group(for: groupId) else { return [] }
        return group.memberEntryIds.compactMap { entryId -> ModelEntry? in
            guard let entry = store.entry(for: entryId),
                  canServe(entry.model, direction: direction),
                  let instance = store.instance(for: entry.providerInstanceId),
                  instance.isEnabled, voiceCredentialOK(instance),
                  VoiceProviderFactory.make(for: instance) != nil else { return nil }
            return entry
        }
    }

    /// Ordered ASR fail-over candidates: the in-memory override first (if usable),
    /// then every usable member of the configured input group, ordered per the
    /// group's routing strategy — `.fallback` keeps group order, `.loadBalance`
    /// rotates the start position by `loadBalanceSeed` so separate capture
    /// sessions spread across members (mirrors ModelGroupRouter's sessionId
    /// hashing for text chat). An explicit System override returns [] — the
    /// caller uses the offline System engine directly, same as before.
    static func resolvedInputCandidates(loadBalanceSeed: Int = 0) -> [ModelEntry] {
        let sel = VoiceSelectionStore.shared.inputEntryId
        if isSystemEntry(sel) { return [] }
        var out: [ModelEntry] = []
        if let override = usableEntry(sel, direction: .input) {
            out.append(override)
        }
        let store = ProviderConfigStore.shared
        var members = resolveEntries(groupId: store.voiceInputGroupId, direction: .input)
        if let gid = store.voiceInputGroupId, let g = store.group(for: gid),
           g.strategy == .loadBalance, members.count > 1 {
            let offset = abs(loadBalanceSeed) % members.count
            members = Array(members[offset...] + members[..<offset])
        }
        for e in members where !out.contains(where: { $0.id == e.id }) {
            out.append(e)
        }
        return out
    }

    /// Build the ASR provider for a specific candidate entry (nil if not usable).
    static func inputProvider(for entry: ModelEntry) -> (any VoiceInputCapable)? {
        guard let instance = ProviderConfigStore.shared.instance(for: entry.providerInstanceId),
              let p = VoiceProviderFactory.make(for: instance), p.supportsVoiceInput else { return nil }
        return p
    }

    /// Ordered TTS fail-over candidates: the in-memory override first (if usable),
    /// then every usable member of the configured output group. The cloud player
    /// tries each in turn and only reports failure when ALL fail.
    static func resolvedOutputCandidates() -> [ModelEntry] {
        var out: [ModelEntry] = []
        if let override = usableEntry(VoiceSelectionStore.shared.outputEntryId, direction: .output) {
            out.append(override)
        }
        for e in resolveEntries(groupId: ProviderConfigStore.shared.voiceOutputGroupId, direction: .output)
        where !out.contains(where: { $0.id == e.id }) {
            out.append(e)
        }
        // [T-system-voice-off 09-12] 醒醒 3: with the System switch OFF (the
        // default), System entries never enter the read-aloud candidate chain —
        // a group whose only member is System resolves to ZERO candidates and
        // the reply stays silent, instead of quietly speaking with the robotic
        // built-in voice she hates. Opt back in via Settings → TTS Services.
        if !VoiceOutputPreferences.systemVoiceAllowed {
            out.removeAll { isSystemEntry($0.providerInstanceId) }
        }
        return out
    }

    /// Build the cloud TTS provider for a specific entry (nil if not usable / System).
    static func outputProvider(for entry: ModelEntry) -> (any VoiceOutputCapable)? {
        guard let instance = ProviderConfigStore.shared.instance(for: entry.providerInstanceId),
              let p = VoiceProviderFactory.make(for: instance), p.supportsVoiceOutput else { return nil }
        return p
    }

    private static func provider(for entry: ModelEntry?,
                                 capable: (any VoiceProviderCapable) -> Bool) -> (any VoiceProviderCapable)? {
        guard let entry,
              let instance = ProviderConfigStore.shared.instance(for: entry.providerInstanceId),
              let p = VoiceProviderFactory.make(for: instance), capable(p) else { return nil }
        logger.info("Resolved voice provider from entry \(entry.id)")
        return p
    }

    private static func label(for entry: ModelEntry?, includeInstance: Bool = true) -> String {
        guard let entry else {
            return AppLocalized("System", comment: "Built-in Apple speech engine")
        }
        // Only append the instance label when asked AND it isn't the built-in
        // System engine (whose synthetic "System" instance just duplicates the
        // model's built-in-ness — noise on the chip).
        if includeInstance,
           !isSystemEntry(entry.providerInstanceId),
           let inst = ProviderConfigStore.shared.instance(for: entry.providerInstanceId) {
            return "\(entry.model.displayName) · \(inst.label)"
        }
        return entry.model.displayName
    }
}
