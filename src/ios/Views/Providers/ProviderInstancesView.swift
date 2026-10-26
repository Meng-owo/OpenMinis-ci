import SwiftUI
import UniformTypeIdentifiers

/// Lists all configured provider instances grouped by provider type.
/// Replaces the old ProvidersView for the new multi-instance model.
struct ProviderInstancesView: View {
    /// [K-3] One presentation modifier, dispatched by an enum.
    ///
    /// This page used to hang TWO `.sheet` modifiers on the same `List` and
    /// trigger both from a `Menu`. iOS keeps one presentation per view level,
    /// so the second one silently lost — and the trigger being inside a menu
    /// swallowed the first tap on top of that. The pattern below is the one
    /// `ContentView` already uses (`activeToolSheet`).
    private enum ProviderSheet: String, Identifiable {
        case add
        case importFile
        var id: String { rawValue }
    }

    @ObservedObject private var store = ProviderConfigStore.shared
    @State private var activeSheet: ProviderSheet?
    @State private var importMessage: String?
    @State private var showImportResult = false
    @State private var forceSyncToast: String?
    @AppStorage("cloudSync.v2.enabled") private var iCloudSyncEnabled: Bool = false
    /// [T-provider-group-swipe-actions] Swipe-to-edit target. Value-driven so
    /// the swipe opens the SAME detail screen the row's NavigationLink does,
    /// rather than a second editor that could drift from it.
    @State private var editingInstanceId: String?
    /// Swipe-to-delete target. Deletion goes through the existing confirmation
    /// alert — a provider carries API keys and every model entry under it, so
    /// it must never be a one-swipe irreversible act.
    @State private var pendingDeleteInstance: ProviderInstance?

    var body: some View {
        List {
            // [T-mimo-shadow-voice] EVERY instance appears under its providerType
            // section now (no voice-only exclusion) — a mixed vendor like MiMo
            // shows its text models here AND a shadow voice row below ("dual
            // visibility"). Pure-voice vendors (ElevenLabs etc.) still appear here
            // too; they just have no usable text models, which is expected.
            ForEach(ProviderType.allCases, id: \.self) { type in
                let instancesOfType = store.instances.filter { $0.providerType == type }
                if !instancesOfType.isEmpty {
                    Section(type.displayName) {
                        ForEach(instancesOfType) { instance in
                            NavigationLink {
                                ProviderInstanceDetailView(instanceId: instance.id)
                            } label: {
                                InstanceRow(instance: instance)
                            }
                            // [T-provider-group-swipe-actions] Swipe actions and
                            // `.onMove` coexist without extra work: UIKit routes a
                            // horizontal drag to the row's swipe actions and a
                            // vertical one to the reorder engine, and in edit mode
                            // the drag handles take over entirely. No custom
                            // gesture is introduced here precisely so that
                            // arbitration stays UIKit's.
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                // Destructive first = rightmost, the platform's
                                // position for Delete. `allowsFullSwipe: false`
                                // so a long swipe cannot delete a provider (and
                                // its keys) without the confirmation below.
                                Button(role: .destructive) {
                                    pendingDeleteInstance = instance
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    editingInstanceId = instance.id
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(MinisTheme.accent)
                            }
                        }
                        .onMove { source, destination in
                            moveInstances(in: type, from: source, to: destination)
                        }
                    }
                }
            }
            // [B09-N14 2026-10-22] The shadow voice rows moved into
            // Settings › Voice Services. Having a second, differently-behaving
            // "Voice Services" list inside the Providers page made "where do I
            // configure my voice" have two answers. The rows themselves are
            // unchanged; only their home moved.
            let shadows = store.shadowVoiceProviders()
            if !shadows.isEmpty {
                Section {
                    NavigationLink {
                        VoiceServicesView()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "waveform.circle.fill")
                                .foregroundStyle(MinisTheme.secondaryText)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Voice Services")
                                Text("From your providers")
                                    .font(.caption2)
                                    .foregroundStyle(MinisTheme.secondaryText.opacity(0.7))
                            }
                        }
                    }
                } footer: {
                    Text("Voice providers you already configured here show up in Settings › Voice Services, together with the standalone voice services.")
                }
            }

            if store.instances.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "key.slash")
                            .font(.system(size: 32))
                            .foregroundStyle(.quaternary)
                        Text("No providers configured")
                            .font(.subheadline)
                            .foregroundStyle(MinisTheme.secondaryText)
                        Text("Add a provider to get started.")
                            .font(.caption)
                            .foregroundStyle(MinisTheme.secondaryText.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
            }
        }
        .navigationTitle("Providers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !store.instances.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        // [K-3] Menu dismiss + presentation in one transaction
                        // loses the presentation on iOS. Yield one runloop.
                        DispatchQueue.main.async {
                            // Clear the previous result so a cancelled picker
                            // cannot re-show last time's message.
                            importMessage = nil
                            activeSheet = .add
                        }
                    } label: {
                        Label(AppLocalized("Add Provider"), systemImage: "plus")
                    }
                    Button {
                        DispatchQueue.main.async {
                            importMessage = nil
                            activeSheet = .importFile
                        }
                    } label: {
                        Label(AppLocalized("Import Provider"), systemImage: "square.and.arrow.down")
                    }
                    if #available(iOS 17.0, *), iCloudSyncEnabled {
                        Divider()
                        Button {
                            Task { await forceSyncProviders() }
                        } label: {
                            Label(AppLocalized("Force iCloud Sync"),
                                  systemImage: "arrow.triangle.2.circlepath.icloud")
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .add:
                NavigationStack {
                    AddProviderView()
                }
            case .importFile:
                // [T-sideload-fileimport] copy-mode picker: resigned builds
                // silently fail open-in-place security-scope grants.
                DocumentCopyPicker(contentTypes: [.json], allowsMultipleSelection: false) { urls in
                    guard let url = urls.first else { return }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    guard let data = try? Data(contentsOf: url),
                          let json = String(data: data, encoding: .utf8) else {
                        importMessage = AppLocalized("Failed to read file.")
                        return
                    }
                    if let label = store.importInstanceJSON(json) {
                        importMessage = AppLocalized("Imported provider \"\(label)\" successfully.")
                    } else {
                        importMessage = AppLocalized("Invalid provider configuration file.")
                    }
                } onDone: {
                    activeSheet = nil
                    // [K-3] The result alert has to wait for this sheet to
                    // finish dismissing — an alert presented while a sheet is
                    // still on screen is dropped, which is how "import
                    // succeeded" used to vanish.
                    guard importMessage != nil else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showImportResult = true
                    }
                }
            }
        }
        // [T-provider-group-swipe-actions] Swipe-Edit lands on the very screen
        // the row taps into, so there is one provider editor, not two.
        //
        // [audit-F1 / T-swipe-edit-white-screen] The destination is built from
        // the id captured at push time, NOT re-read from `editingInstanceId`
        // inside the closure. The previous form guarded the destination with
        // `if let id = editingInstanceId, store.instances.contains(id)`, which
        // yielded NO content whenever that read came back empty during the
        // swipe's retraction — pushing an opaque blank screen the user was
        // stuck on. See SwipeEditDestination.swift for the full mechanism.
        //
        // The deleted-while-open case that guard was aiming at is handled by
        // ProviderInstanceDetailView itself, which is reached the same way by
        // the row tap and so must already tolerate a vanishing instance.
        .swipeEditDestination(item: $editingInstanceId) { id in
            ProviderInstanceDetailView(instanceId: id)
        }
        // Same wording and same call (`store.removeInstance`) as the Delete
        // button inside ProviderInstanceDetailView — the swipe is a shortcut to
        // the existing flow, not a second deletion path with its own semantics.
        // [K-3] ONE alert for both messages. Two `.alert` modifiers on the same
        // `List` means iOS only ever honours one of them; the import result
        // ("Imported provider X successfully") would have been the dead one.
        .alert(alertTitle, isPresented: isAlertPresented) {
            if pendingDeleteInstance != nil {
                Button("Delete", role: .destructive) {
                    if let instance = pendingDeleteInstance {
                        store.removeInstance(instance.id)
                    }
                    pendingDeleteInstance = nil
                }
            }
            // [K-3b] `alert(_:isPresented:)` has two overloads: one takes a
            // `LocalizedStringKey` and consults the string table, the other
            // takes any `StringProtocol` and renders it verbatim. Passing a
            // `String` (as the first cut of this merge did) silently chose the
            // second one, so "Delete Provider" / "Import" stayed English for
            // every locale even though all nine translations exist.
            // Same trap ContentView.setupStep documents at `:4153`.
            if pendingDeleteInstance != nil {
                Button("Cancel", role: .cancel) {
                    pendingDeleteInstance = nil
                    showImportResult = false
                }
            } else {
                Button("OK", role: .cancel) {
                    pendingDeleteInstance = nil
                    showImportResult = false
                }
            }
        } message: {
            if pendingDeleteInstance != nil {
                Text("This will remove the provider and all its model entries. API keys will be deleted from the Keychain.")
            } else if let msg = importMessage {
                Text(msg)
            }
        }
        .overlay(alignment: .top) {
            if let msg = forceSyncToast {
                Text(msg)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(MinisTheme.accent, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .settingsPage()
        .animation(.spring(response: 0.3), value: forceSyncToast)
    }

    /// [K-3] Shared alert state for the two message types this page can show.
    private var isAlertPresented: Binding<Bool> {
        Binding(
            get: { pendingDeleteInstance != nil || showImportResult },
            set: { presented in
                guard !presented else { return }
                pendingDeleteInstance = nil
                showImportResult = false
            }
        )
    }

    /// [K-3b] Typed `LocalizedStringKey`, not `String`: `alert(_:isPresented:)`
    /// picks its overload by this parameter's type, and only the
    /// `LocalizedStringKey` one reads `Localizable.xcstrings`.
    private var alertTitle: LocalizedStringKey {
        pendingDeleteInstance != nil ? "Delete Provider" : "Import"
    }

    @available(iOS 17.0, *)
    private func forceSyncProviders() async {
        // [T-provider-forcesync-v3] markProvidersDirty now re-marks every v3
        // instance/entry/group/rule row (not just the v2 whole-file record that
        // v3 peers drop) and resets the pull-side full-history anchors.
        _ = await ForceSyncHelper.markProvidersDirty()
        await ForceSyncHelper.bidirectionalSync(recordTypes: [
            "ProviderConfig", "ProviderConfigV2",
            "ProviderInstanceV3", "ProviderModelEntryV3",
            "ProviderModelGroupV3", "ProviderThinkingRuleV3",
        ])
        forceSyncToast = AppLocalized("Syncing providers via iCloud")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            forceSyncToast = nil
        }
    }

    // Section .onMove hands us section-relative indices. Map them back onto the
    // global store.instances order so the new order persists to disk and flows
    // through to SessionModelPicker.
    private func moveInstances(in type: ProviderType, from source: IndexSet, to destination: Int) {
        let all = store.instances
        // [T-ios-provider-reorder] The section's ForEach renders llmInstances
        // (voice-only providers filtered OUT into their own section), so the
        // section-relative indices from onMove address THAT list. The filter
        // here must match exactly — including voice-only instances of the same
        // providerType shifted every index and made drops land on the wrong
        // element (item jumps elsewhere / bounces back).
        // [T-mimo-shadow-voice] All instances of this type are section members
        // now (voice-only exclusion removed) — the section renders the full list.
        let isSectionMember: (ProviderInstance) -> Bool = {
            $0.providerType == type
        }
        let sectionIds = all.filter(isSectionMember).map(\.id)
        var reorderedSectionIds = sectionIds
        reorderedSectionIds.move(fromOffsets: source, toOffset: destination)

        // Rebuild global order: walk `all`, and whenever we hit a member of
        // this section, emit the next id from the reordered section list.
        var sectionIter = reorderedSectionIds.makeIterator()
        let newGlobalIds: [String] = all.map { inst in
            isSectionMember(inst) ? (sectionIter.next() ?? inst.id) : inst.id
        }
        store.reorderInstances(newGlobalIds)
    }
}

// MARK: - Instance Row

/// [T-ios-provider-row-keychain-in-body] Per-row credential display state, resolved
/// ONCE per (instance, authRevision) instead of on every SwiftUI body evaluation.
///
/// `isConfigured` and `credentialSummary` were each reading Keychain directly from
/// `body`. Every `SecItemCopyMatching` is a synchronous XPC round-trip to
/// `securityd`, so one body pass over N provider rows cost 2N blocking IPCs on the
/// MAIN THREAD — a real user log shows 110 `caller=isConfigured` +
/// 110 `caller=credentialSummary` reads in a single session (655 Keychain reads
/// overall). A crash report from that same session caught the main thread parked
/// inside `SecItemCopyMatching` under `InstanceRow.body`.
///
/// This is the same hazard `ProviderCredentialCache`
/// ([T-new-session-hang-credential-cache]) already exists for; the row simply
/// bypassed it. A separate cache is used rather than `hasAnyCredential` because
/// the row needs strictly more than a Bool — it renders the MASKED KEY, and its
/// OAuth notion of "authenticated" is per-provider-manager, not the router's
/// any-credential test. Reusing `hasAnyCredential` here would silently change
/// what the row displays.
///
/// Keying on `authRevision` (bumped by `notifyAuthChanged` on every credential
/// write/delete) makes invalidation exact: the UI still updates immediately after
/// the user adds or removes a key. The TTL is only a backstop for credential
/// changes that happen outside the app (Keychain iCloud sync).
final class ProviderRowCredentialCache: @unchecked Sendable {
    static let shared = ProviderRowCredentialCache()

    struct Display {
        let isConfigured: Bool
        let summary: String
        /// [audit-F12 / T-oauth-keep-credentials] OAuth credential kept but its
        /// refresh was rejected — row renders red until the user signs in again.
        var needsReauth = false
    }

    /// Backstop only — `authRevision` is the primary invalidation signal.
    private static let ttl: TimeInterval = 15

    private let lock = NSLock()
    private var entries: [String: (value: Display, revision: UInt, at: Date)] = [:]

    private init() {}

    /// Drop everything. Called from the SAME places that clear
    /// `ProviderCredentialCache`, because those events (Keychain iCloud
    /// `view-change`, app foreground) change credentials WITHOUT bumping
    /// `authRevision` — so the revision key alone would not notice them.
    func invalidateAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    func value(for instanceId: String, revision: UInt, probe: () -> Display) -> Display {
        let now = Date()
        lock.lock()
        if let e = entries[instanceId], e.revision == revision,
           now.timeIntervalSince(e.at) < Self.ttl {
            lock.unlock()
            return e.value
        }
        lock.unlock()

        // Probe runs OUTSIDE the lock — it does Keychain XPC and must not
        // serialize concurrent probes for different instances.
        let fresh = probe()

        lock.lock()
        entries[instanceId] = (fresh, revision, now)
        lock.unlock()
        return fresh
    }
}

private struct InstanceRow: View {
    let instance: ProviderInstance
    @ObservedObject private var store = ProviderConfigStore.shared

    /// Both display properties come from one cached probe, so a body pass costs
    /// zero Keychain round-trips once warm.
    private var credentialDisplay: ProviderRowCredentialCache.Display {
        ProviderRowCredentialCache.shared.value(for: instance.id, revision: store.authRevision) {
            let configured: Bool
            let summary: String
            var needsReauth = false
            switch instance.credentialType {
            case .apiKey:
                // Single Keychain read serves BOTH the dot and the masked subtitle;
                // previously these were two independent reads of the same item.
                let key = ProviderKeychainHelper.loadAPIKey(instanceId: instance.id)
                // [T-empty-key-compat-endpoints] A keyless third-party
                // compatible endpoint is configured-by-definition; say so
                // instead of the alarming "No API key".
                if key == nil, instance.allowsEmptyAPIKey {
                    configured = true
                    summary = AppLocalized("No key required")
                } else {
                    configured = key != nil
                    summary = key.map(Self.maskKey) ?? AppLocalized("No API key")
                }
            case .oauth:
                let authed = Self.probeOAuthAuthenticated(instance)
                needsReauth = authed && ProviderKeychainHelper.oauthNeedsReauth(instanceId: instance.id)
                configured = authed && !needsReauth
                summary = needsReauth ? AppLocalized("Sign-in expired")
                    : authed ? AppLocalized("Authenticated")
                    : AppLocalized("Not authenticated")
            }
            return .init(isConfigured: configured, summary: summary, needsReauth: needsReauth)
        }
    }

    private var isConfigured: Bool { credentialDisplay.isConfigured }

    private var credentialSummary: String { credentialDisplay.summary }

    /// The uncached OAuth probe. `static` so the cache closure can call it without
    /// capturing `self` (the row is a short-lived struct; the cache outlives it).
    private static func probeOAuthAuthenticated(_ instance: ProviderInstance) -> Bool {
        // Manual OAuth token is always considered authenticated
        if ProviderKeychainHelper.loadOAuthString(instanceId: instance.id, account: "manual-oauth-token") != nil {
            return true
        }
        switch instance.providerType {
        case .anthropic: return ClaudeOAuthManager.shared.isAuthenticated(instanceId: instance.id)
        case .gemini: return GeminiOAuthManager.shared.isAuthenticated(instanceId: instance.id)
        case .openAI: return CodexOAuthManager.shared.isAuthenticated(instanceId: instance.id)
        case .antigravity: return AntigravityOAuthManager.shared.isAuthenticated(instanceId: instance.id)
        case .openRouter: return OpenRouterOAuthManager.shared.isAuthenticated(instanceId: instance.id)
        case .openAIResponses: return false // API key only
        case .xAI: return XAIOAuthManager.shared.isAuthenticated(instanceId: instance.id)
        case .kimiCode: return KimiOAuthManager.shared.isAuthenticated(instanceId: instance.id)
        case .unsupported: return false // synced from newer build
        }
    }

    private var modelCount: Int {
        store.visibleEntries(for: instance.id).count
    }

    var body: some View {
        let _ = store.authRevision  // subscribe to OAuth state changes
        HStack(spacing: 12) {
            Circle()
                .fill(credentialDisplay.needsReauth ? MinisTheme.destructive
                      : isConfigured && instance.isEnabled ? MinisTheme.success
                      : AppearanceStudio.shared.color(.secondaryText).opacity(0.4))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(instance.label)
                    .font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Text(instance.credentialType == .apiKey ? "API Key" : "OAuth")
                        .font(.caption)
                        .foregroundStyle(MinisTheme.secondaryText)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.quaternary)
                    Text(credentialSummary)
                        .font(.caption)
                        .foregroundStyle(credentialDisplay.needsReauth ? AnyShapeStyle(MinisTheme.destructive) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                if modelCount > 0 {
                    Text(AppLocalized("\(modelCount) models"))
                        .font(.caption2)
                        .foregroundStyle(MinisTheme.secondaryText.opacity(0.7))
                }
            }

            Spacer()

            if !instance.isEnabled {
                Text("Disabled")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(MinisTheme.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(AppearanceStudio.shared.color(.mutedSurface).opacity(0.6))
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 2)
    }

    /// `static` (was an instance method) so the credential-cache probe closure can
    /// call it without capturing `self`. Pure function — no behaviour change.
    private static func maskKey(_ key: String) -> String {
        guard key.count > 8 else { return "****" }
        return String(key.prefix(6)) + "..." + String(key.suffix(4))
    }
}

