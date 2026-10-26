import SwiftUI

/// Lists all model groups with default badges, and allows creating new groups.
struct ModelGroupsView: View {
    private enum GroupSheet: String, Identifiable {
        case addAgentModels
        case addAgentGroups
        var id: String { rawValue }
    }

    @ObservedObject private var store = ProviderConfigStore.shared
    @State private var showCreateGroup = false
    @State private var newGroupName = ""
    @State private var activeSheet: GroupSheet?
    @State private var forceSyncToast: String?
    /// [T-provider-group-swipe-actions] Swipe-to-edit target. Edit pushes the
    /// same detail screen the row taps into.
    @State private var editingGroupId: String?
    @State private var pendingDeleteGroup: ModelGroup?
    @AppStorage("cloudSync.v2.enabled") private var iCloudSyncEnabled: Bool = false

    var body: some View {
        List {
            if store.modelGroups.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 32))
                            .foregroundStyle(.quaternary)
                        Text("No model groups")
                            .font(.subheadline)
                            .foregroundStyle(MinisTheme.secondaryText)
                        Text("Groups let you combine models for fallback or load balancing.")
                            .font(.caption)
                            .foregroundStyle(MinisTheme.secondaryText.opacity(0.7))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
            }

            if !store.modelGroups.isEmpty {
                Section {
                    ForEach(store.modelGroups) { group in
                        NavigationLink {
                            ModelGroupDetailView(groupId: group.id)
                        } label: {
                            GroupRow(group: group)
                        }
                        // [T-provider-group-swipe-actions] Explicit swipe
                        // actions REPLACE the previous `.onDelete`, which gave
                        // a swipe-to-delete with NO confirmation: a group can
                        // be a default/voice/vision target and removing it
                        // silently clears those pointers (see
                        // ProviderConfigStore.removeGroup), so one careless
                        // swipe could reconfigure routing with no undo.
                        // Reordering is unaffected — `.onMove` stays, and UIKit
                        // arbitrates horizontal vs vertical drags itself.
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDeleteGroup = group
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                editingGroupId = group.id
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(MinisTheme.accent)
                        }
                    }
                    .onMove(perform: moveGroups)
                    // Retained so the EditButton's red-minus delete still
                    // exists; it now routes through `pendingDeleteGroup` and
                    // therefore asks for confirmation like the swipe does.
                    .onDelete(perform: deleteGroups)
                } header: {
                    HStack {
                        Text("Groups")
                        Spacer()
                        EditButton()
                            .font(.caption)
                            .textCase(nil)
                    }
                }
            }

            // Default assignments
            if !store.modelGroups.isEmpty {
                Section {
                    GroupSlotPicker(
                        label: "Default Primary",
                        selection: Binding(
                            get: { store.defaultPrimaryGroupId },
                            set: { store.defaultPrimaryGroupId = $0 }
                        )
                    )
                    GroupSlotPicker(
                        label: "Default Sub",
                        selection: Binding(
                            get: { store.defaultSubGroupId },
                            set: { store.defaultSubGroupId = $0 }
                        )
                    )
                    GroupSlotPicker(
                        label: "Voice Input",
                        selection: Binding(
                            get: { store.voiceInputGroupId },
                            set: { store.voiceInputGroupId = $0 }
                        ),
                        voiceDirection: .input
                    )
                    GroupSlotPicker(
                        label: "Voice Output",
                        selection: Binding(
                            get: { store.voiceOutputGroupId },
                            set: { store.voiceOutputGroupId = $0 }
                        ),
                        voiceDirection: .output
                    )
                    GroupSlotPicker(
                        label: "Vision Input",
                        selection: Binding(
                            get: { store.visionGroupId },
                            set: { store.visionGroupId = $0 }
                        ),
                        isVision: true
                    )
                    // [问题3 / G2] 她点名的五个用途槽位。逻辑与上面五行一致：
                    // 选一个组，按用途取用；不配就是没开。建组时的模态过滤
                    // 走 preferModality，Embedding 没有对应模态位（ModelModality
                    // 只描述输入输出，不描述用途），所以它不过滤。
                    GroupSlotPicker(
                        label: "Image Output",
                        selection: Binding(
                            get: { store.imageOutputGroupId },
                            set: { store.imageOutputGroupId = $0 }
                        ),
                        preferModality: .imageOutput
                    )
                    GroupSlotPicker(
                        label: "Video Output",
                        selection: Binding(
                            get: { store.videoOutputGroupId },
                            set: { store.videoOutputGroupId = $0 }
                        ),
                        preferModality: .videoOutput
                    )
                    GroupSlotPicker(
                        label: "Realtime Voice",
                        selection: Binding(
                            get: { store.realtimeVoiceGroupId },
                            set: { store.realtimeVoiceGroupId = $0 }
                        ),
                        preferModality: .audioOutput
                    )
                    GroupSlotPicker(
                        label: "Embedding",
                        selection: Binding(
                            get: { store.embeddingGroupId },
                            set: { store.embeddingGroupId = $0 }
                        )
                    )
                    GroupSlotPicker(
                        label: "Judge",
                        selection: Binding(
                            get: { store.judgeGroupId },
                            set: { store.judgeGroupId = $0 }
                        )
                    )
                } header: {
                    Text("Defaults")
                } footer: {
                    Text("Primary is used for main agent tasks. Sub is used for lightweight tasks like title generation. Voice Input/Output pick a group whose audio-capable models drive speech-to-text and text-to-speech; if none is set, the offline System voice is used. Vision Input picks a group whose image-capable models describe images when the chat model cannot see them itself; if none is set, models without vision cannot read images at all. Image/Video Output, Realtime Voice, Embedding and Judge name the group to use for those jobs; leave one empty and that job simply has no model.")
                }
            }

            // Agent Loop Models
            AgentLoopModelsSection(
                showAddModels: Binding(
                    get: { activeSheet == .addAgentModels },
                    set: { if $0 { activeSheet = .addAgentModels } }
                ),
                showAddGroups: Binding(
                    get: { activeSheet == .addAgentGroups },
                    set: { if $0 { activeSheet = .addAgentGroups } }
                )
            )
        }
        .navigationTitle("Model Groups")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .addAgentModels:
                NavigationStack {
                    UnifiedModelPicker(config: .agentLoopAddModels())
                }
            case .addAgentGroups:
                NavigationStack {
                    AddAgentLoopGroupsSheet()
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        // [K-3] Menu dismissal + alert presentation in one
                        // transaction loses the alert. Yield one runloop.
                        DispatchQueue.main.async {
                            newGroupName = ""
                            showCreateGroup = true
                        }
                    } label: {
                        Label(AppLocalized("New Group"), systemImage: "plus")
                    }
                    if #available(iOS 17.0, *), iCloudSyncEnabled {
                        Divider()
                        Button {
                            Task { await forceSyncGroups() }
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
        .animation(.spring(response: 0.3), value: forceSyncToast)
        // [T-provider-group-swipe-actions] Swipe-Edit reuses the row's own
        // destination.
        //
        // [audit-F1 / T-swipe-edit-white-screen] Value-driven: the destination
        // is built from the id captured at push time rather than re-read from
        // `editingGroupId`, which could read back empty mid-swipe-retraction
        // and push a blank, inescapable screen. See SwipeEditDestination.swift.
        .swipeEditDestination(item: $editingGroupId) { id in
            ModelGroupDetailView(groupId: id)
        }
        // [K-3] ONE alert for both actions.
        //
        // There used to be two `.alert` modifiers on this same `List`. iOS
        // honours a single presentation per view level, so one of them was
        // always dead — and the dead one was the one fired from the toolbar
        // `Menu` ("New Group"), which is exactly what the user reported as
        // "点了没反应". One modifier, branch on which state is set.
        .alert(dialogTitle, isPresented: isDialogPresented) {
            if showCreateGroup {
                TextField("Group name", text: $newGroupName)
                Button("Create") {
                    createGroup()
                    showCreateGroup = false
                }
            } else if let group = pendingDeleteGroup {
                Button("Delete", role: .destructive) {
                    store.removeGroup(group.id)
                    pendingDeleteGroup = nil
                }
            }
            Button("Cancel", role: .cancel) {
                showCreateGroup = false
                pendingDeleteGroup = nil
            }
        } message: {
            if showCreateGroup {
                Text("Enter a name for the new model group.")
            } else if let group = pendingDeleteGroup {
                Text("Delete \"\(group.name)\"? Any default, voice, or vision selection pointing at this group will be cleared. The models themselves are not deleted.")
            }
        }
        .settingsPage()
    }

    /// [K-3] One flag for the shared alert; it clears whichever action was armed.
    private var isDialogPresented: Binding<Bool> {
        Binding(
            get: { showCreateGroup || pendingDeleteGroup != nil },
            set: { presented in
                guard !presented else { return }
                showCreateGroup = false
                pendingDeleteGroup = nil
            }
        )
    }

    /// [K-3b] `LocalizedStringKey`, not `String` — the `alert` overload that
    /// takes a plain `String` renders it verbatim and never reads the string
    /// table. See `ContentView.setupStep` for the same trap.
    private var dialogTitle: LocalizedStringKey {
        showCreateGroup ? "New Group" : "Delete Group"
    }

    // MARK: - Actions

    private func createGroup() {
        let trimmed = newGroupName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let group = ModelGroup(name: trimmed, memberEntryIds: [])
        store.addGroup(group)
        // Auto-set as primary default if it's the first group
        if store.modelGroups.count == 1 {
            store.defaultPrimaryGroupId = group.id
        }
    }

    /// [T-provider-group-swipe-actions] Edit-mode (red minus) deletion.
    ///
    /// Kept wired to `.onDelete` so the EditButton path kicks off the SAME
    /// confirmation the swipe does, instead of deleting outright as it used to.
    /// Only the first offset is honoured because the alert names one group;
    /// the list has no multi-select delete, so an IndexSet here is always a
    /// single row in practice.
    private func deleteGroups(at offsets: IndexSet) {
        let groups = store.modelGroups
        guard let index = offsets.first, groups.indices.contains(index) else { return }
        pendingDeleteGroup = groups[index]
    }

    private func moveGroups(from source: IndexSet, to destination: Int) {
        var ids = store.modelGroups.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        store.reorderGroups(ids)
    }

    @available(iOS 17.0, *)
    private func forceSyncGroups() async {
        _ = await ForceSyncHelper.markProvidersDirty()
        await ForceSyncHelper.bidirectionalSync(recordTypes: ["ProviderConfig", "ProviderConfigV2"])
        forceSyncToast = AppLocalized("Syncing model groups via iCloud")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            forceSyncToast = nil
        }
    }
}

// MARK: - Group Row

private struct GroupRow: View {
    let group: ModelGroup
    @ObservedObject private var store = ProviderConfigStore.shared

    private var isPrimaryDefault: Bool {
        store.defaultPrimaryGroupId == group.id
    }

    private var isSubDefault: Bool {
        store.defaultSubGroupId == group.id
    }

    private var memberSummary: String {
        let entries = group.memberEntryIds.compactMap { store.entry(for: $0) }
        if entries.isEmpty { return AppLocalized("No models") }
        let names = entries.prefix(3).map(\.model.displayName)
        let suffix = entries.count > 3 ? " +\(entries.count - 3)" : ""
        return names.joined(separator: ", ") + suffix
    }

    /// [T-ios-modelgroup-modality-icons] The group's TOP-2 most distinctive
    /// modalities (across both inputs AND outputs), shown as icons after the
    /// title so the user can tell at a glance what the group is for (and which to
    /// avoid in a model picker). We aggregate every member model's effective
    /// modality (override else inferred) into one set, then pick the two
    /// highest-priority flags present — generation outputs and special audio/
    /// vision modalities rank above plain text, which is implied for every model.
    ///
    /// Priority (most distinctive first): video-out > image-out > audio-out(TTS)
    /// > audio-in(transcription) > video-in > image-in > pdf-in > text-out.
    /// `textInput` is never shown (universal, pure noise).
    private static let modalityPriority: [ModelModality] = [
        .videoOutput, .imageOutput, .audioOutput,
        .audioInput, .videoInput, .imageInput, .pdfInput,
        .textOutput,
    ]

    private var topModalities: [ModelModality] {
        var combined: ModelModality = []
        for entry in group.memberEntryIds.compactMap({ store.entry(for: $0) }) {
            let model = entry.model
            // Same effective-modality resolution as ProviderInstanceDetailView.
            combined.formUnion(model.modalityOverride ?? model.capabilities.supportedModalities)
        }
        return Self.modalityPriority.filter { combined.contains($0) }.prefix(2).map { $0 }
    }

    /// Icon + accessibility label + color for a single modality flag. Output
    /// (generation) modalities use the "generate"-style glyph + tint; input
    /// modalities use a muted secondary glyph — matching
    /// ProviderInstanceDetailView.modalityIcons.
    @ViewBuilder
    private func modalityIcon(_ modality: ModelModality) -> some View {
        switch modality {
        case .videoOutput:
            Image(systemName: "video.badge.plus")
                .font(.caption).foregroundStyle(.tint)
                .accessibilityLabel(AppLocalized("Video generation"))
        case .imageOutput:
            Image(systemName: "photo.badge.plus")
                .font(.caption).foregroundStyle(.tint)
                .accessibilityLabel(AppLocalized("Image generation"))
        case .audioOutput:
            Image(systemName: "speaker.wave.2.fill")
                .font(.caption).foregroundStyle(.tint)
                .accessibilityLabel(AppLocalized("Speech output"))
        case .audioInput:
            Image(systemName: "waveform.badge.mic")
                .font(.caption).foregroundStyle(MinisTheme.secondaryText)
                .accessibilityLabel(AppLocalized("Speech transcription"))
        case .videoInput:
            Image(systemName: "video")
                .font(.caption).foregroundStyle(MinisTheme.secondaryText)
                .accessibilityLabel(AppLocalized("Video input"))
        case .imageInput:
            Image(systemName: "photo.fill")
                .font(.caption).foregroundStyle(MinisTheme.secondaryText)
                .accessibilityLabel(AppLocalized("Image input"))
        case .pdfInput:
            Image(systemName: "doc")
                .font(.caption).foregroundStyle(MinisTheme.secondaryText)
                .accessibilityLabel(AppLocalized("PDF input"))
        case .textOutput:
            Image(systemName: "text.alignleft")
                .font(.caption).foregroundStyle(MinisTheme.secondaryText)
                .accessibilityLabel(AppLocalized("Text generation"))
        default:
            EmptyView()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(group.name)
                    .font(.body.weight(.medium))
                // [T-ios-modelgroup-modality-icons] Mark the group's top-2 most
                // distinctive modalities (inputs + outputs) right after the title,
                // in priority order, for at-a-glance "what is this group for".
                ForEach(topModalities, id: \.rawValue) { modality in
                    modalityIcon(modality)
                }
                Spacer()
                if isPrimaryDefault {
                    badge("Primary", color: .blue)
                }
                if isSubDefault {
                    badge("Sub", color: .orange)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: group.strategy == .fallback ? "arrow.down.circle" : "arrow.triangle.branch")
                    .font(.caption2)
                    .foregroundStyle(MinisTheme.secondaryText)
                Text(group.strategy == .fallback ? "Fallback" : "Load Balance")
                    .font(.caption)
                    .foregroundStyle(MinisTheme.secondaryText)
                if group.strategy == .fallback {
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.quaternary)
                    Text(group.fallbackStrategy == .always ? AppLocalized("Always") : AppLocalized("Default"))
                        .font(.caption)
                        .foregroundStyle(group.fallbackStrategy == .always ? .orange : .secondary)
                }
                Text("·")
                    .font(.caption)
                    .foregroundStyle(.quaternary)
                Text(AppLocalized("\(group.memberEntryIds.count) models"))
                    .font(.caption)
                    .foregroundStyle(MinisTheme.secondaryText)
            }

            Text(memberSummary)
                .font(.caption2)
                .foregroundStyle(MinisTheme.secondaryText.opacity(0.7))
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}
