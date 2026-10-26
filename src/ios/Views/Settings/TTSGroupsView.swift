import SwiftUI

// MARK: - TTS 分组列表
//
// [tts-groups 2026-10-02] 对标 Providers/ModelGroupsView：TTS 服务分组列表。
// 分组 = 有序的多个 TTS 服务，合成时按顺序 fallback。默认分组由
// AIVoiceMessageComposer.synthesizeWithServiceOrGroup 优先使用。
//
// [B09-N01 2026-10-22] 这一页原来是硬编码中文，而隔壁 Voice Services 页是英文
// 走 xcstrings —— 中文界面一半英文一半中文，英文界面整页中文完全没法用。
// 全部文案改成 AppLocalized（英文源串）+ xcstrings 九语种。

struct TTSGroupsView: View {
    @ObservedObject private var appearanceStudio = AppearanceStudio.shared
    @State private var revision = 0
    @State private var showCreate = false
    @State private var newName = ""
    @State private var pendingDelete: TTSGroup?

    private var store: TTSGroupStore { TTSGroupStore.shared }

    var body: some View {
        List {
            if store.groups.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 32))
                            .foregroundStyle(.quaternary)
                        Text(AppLocalized("No voice groups yet"))
                            .font(.subheadline)
                            .foregroundStyle(MinisTheme.secondaryText)
                        Text(LocalizedStringKey(VoiceServicesCopy.routingNote))
                            .font(.caption)
                            .foregroundStyle(MinisTheme.secondaryText.opacity(0.7))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
            } else {
                Section {
                    ForEach(store.groups) { group in
                        NavigationLink {
                            TTSGroupDetailView(groupId: group.id)
                        } label: {
                            groupRow(group)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDelete = group
                            } label: {
                                Label(AppLocalized("Delete"), systemImage: "trash")
                            }
                        }
                    }
                    .onMove(perform: moveGroups)
                } header: {
                    HStack {
                        Text(AppLocalized("Voice Groups"))
                        Spacer()
                        EditButton()
                            .font(.caption)
                            .textCase(nil)
                    }
                }

                Section {
                    Picker(AppLocalized("Default group"), selection: Binding(
                        get: { store.defaultGroupId ?? "" },
                        set: { store.setDefaultGroupId($0.isEmpty ? nil : $0) }
                    )) {
                        Text(AppLocalized("None (use a single service)")).tag("")
                        ForEach(store.groups) { g in
                            Text(g.name).tag(g.id)
                        }
                    }
                } footer: {
                    Text(LocalizedStringKey(VoiceServicesCopy.routingNote))
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(AppLocalized("Voice Groups"))
        .navigationBarTitleDisplayMode(.inline)
        .appearancePage(.settings)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(AppLocalized("New voice group"))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ttsServicesChanged)) { _ in
            revision &+= 1
        }
        .alert(AppLocalized("New group"), isPresented: $showCreate) {
            TextField(AppLocalized("Group name"), text: $newName)
            Button(AppLocalized("Cancel"), role: .cancel) { newName = "" }
            Button(AppLocalized("Create")) {
                store.createGroup(name: newName)
                newName = ""
            }
        }
        .alert(AppLocalized("Delete this group?"), isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button(AppLocalized("Delete"), role: .destructive) {
                if let g = pendingDelete { store.removeGroup(id: g.id) }
                pendingDelete = nil
            }
            Button(AppLocalized("Cancel"), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(AppLocalized("The services in it are untouched — only the group is dissolved."))
        }
        .listRowBackground(appearanceStudio.color(.surface, scope: .settings))
    }

    private func groupRow(_ group: TTSGroup) -> some View {
        let isDefault = store.defaultGroupId == group.id
        let members = store.candidates(for: group)
        let usable = store.usableCandidates(for: group)
        // [B09-S02 2026-10-22] The row said "没有可用服务" only when the member
        // list was empty — a group full of keyless services looked fine and
        // then produced silence. Name the real reason.
        let subtitle: String = {
            if members.isEmpty { return AppLocalized("No services yet") }
            if usable.isEmpty { return AppLocalized("Every member is missing an API key") }
            return usable.map { $0.name }.joined(separator: " → ")
        }()
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isDefault ? MinisTheme.accent.opacity(0.15) : MinisTheme.mutedSurface)
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isDefault ? MinisTheme.accent : MinisTheme.secondaryText)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(group.name)
                        .foregroundStyle(MinisTheme.primaryText)
                    if isDefault {
                        Text(AppLocalized("Default"))
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(MinisTheme.accent.opacity(0.15)))
                            .foregroundStyle(MinisTheme.accent)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(usable.isEmpty && !members.isEmpty
                                     ? MinisTheme.destructive
                                     : MinisTheme.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    private func moveGroups(from source: IndexSet, to destination: Int) {
        store.moveGroup(from: source, to: destination)
    }
}

// MARK: - TTS 分组详情：改名＋成员管理（顺序 = fallback 顺序）

struct TTSGroupDetailView: View {
    let groupId: String

    @ObservedObject private var appearanceStudio = AppearanceStudio.shared
    @State private var revision = 0
    @State private var name = ""
    @State private var didLoadName = false

    private var store: TTSGroupStore { TTSGroupStore.shared }
    private var serviceStore: TTSServiceStore { TTSServiceStore.shared }
    private var group: TTSGroup? { store.group(id: groupId) }

    var body: some View {
        List {
            Section(AppLocalized("Name")) {
                TextField(AppLocalized("Group name"), text: $name)
                    .onSubmit { saveName() }
            }

            if let g = group {
                Section {
                    let members = memberRows(for: g)
                    if members.isEmpty {
                        Text(AppLocalized("No services yet — add some below."))
                            .font(.caption)
                            .foregroundStyle(MinisTheme.secondaryText)
                    }
                    ForEach(members, id: \.id) { row in
                        HStack(spacing: 12) {
                            Image(systemName: row.service?.kind.symbol ?? "questionmark.circle")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(MinisTheme.secondaryText)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.service?.name ?? AppLocalized("Deleted service"))
                                    .foregroundStyle(MinisTheme.primaryText)
                                Text(row.service.map { "\($0.kind.displayName) · \($0.voice)" }
                                     ?? AppLocalized("This service was deleted; its slot is kept"))
                                    .font(.caption)
                                    .foregroundStyle(MinisTheme.secondaryText)
                            }
                            Spacer()
                            if let s = row.service {
                                if !serviceStore.hasAPIKey(for: s) {
                                    Text(AppLocalized("No API key"))
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(MinisTheme.destructive)
                                } else if !s.enabled {
                                    Text(AppLocalized("Turned off"))
                                        .font(.caption2)
                                        .foregroundStyle(MinisTheme.secondaryText)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                removeMember(row.id, from: g)
                            } label: {
                                Label(AppLocalized("Remove"), systemImage: "trash")
                            }
                        }
                    }
                    .onMove { source, dest in moveMember(from: source, to: dest, in: g) }
                } header: {
                    HStack {
                        Text(AppLocalized("Members (tried in this order)"))
                        Spacer()
                        EditButton()
                            .font(.caption)
                            .textCase(nil)
                    }
                }

                // [B09-N09 2026-10-22] Turning a service off and then adding it
                // to a group used to be possible — it just never spoke, with a
                // tiny caption as the only clue. Offer only services that can
                // actually synthesize, and say why the rest are hidden.
                // [B09-V4 2026-10-22] Same predicate as playback (VoiceChain):
                // enabled + key + the vendor can actually build a provider. A
                // service whose credential shape is wrong used to be offered
                // here, added to the group, and then silently skipped.
                let available = serviceStore.services.filter { s in
                    !g.memberServiceIds.contains(s.id) && VoiceChain.canSpeak(s)
                }
                let hiddenCount = serviceStore.services.filter { s in
                    !g.memberServiceIds.contains(s.id) && !VoiceChain.canSpeak(s)
                }.count
                if !available.isEmpty || hiddenCount > 0 {
                    Section {
                        ForEach(available) { s in
                            Button {
                                var updated = g
                                updated.memberServiceIds.append(s.id)
                                store.updateGroup(updated)
                            } label: {
                                HStack {
                                    Text(s.name).foregroundStyle(MinisTheme.primaryText)
                                    Spacer()
                                    Image(systemName: "plus.circle")
                                        .foregroundStyle(MinisTheme.accent)
                                }
                            }
                        }
                    } header: {
                        Text(AppLocalized("Add a service"))
                    } footer: {
                        if hiddenCount > 0 {
                            Text(AppLocalized("Some services are hidden here because they are turned off or have no API key."))
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(AppLocalized("Edit group"))
        .navigationBarTitleDisplayMode(.inline)
        .appearancePage(.settings)
        .onReceive(NotificationCenter.default.publisher(for: .ttsServicesChanged)) { _ in
            revision &+= 1
        }
        .onAppear {
            if !didLoadName, let g = group {
                name = g.name
                didLoadName = true
            }
        }
        .onDisappear { saveName() }
        .listRowBackground(appearanceStudio.color(.surface, scope: .settings))
    }

    private struct MemberRow {
        let id: String
        let service: TTSServiceOptions?
    }

    private func memberRows(for g: TTSGroup) -> [MemberRow] {
        g.memberServiceIds.map { MemberRow(id: $0, service: serviceStore.service(id: $0)) }
    }

    /// [B09-L03 2026-10-22] An emptied name field used to be dropped silently on
    /// leave — the user thought the rename took. Put the original name back in
    /// the field so what they see is what is stored.
    private func saveName() {
        guard var g = group else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            name = g.name
            return
        }
        guard trimmed != g.name else { return }
        g.name = trimmed
        store.updateGroup(g)
    }

    private func removeMember(_ serviceId: String, from g: TTSGroup) {
        var updated = g
        updated.memberServiceIds.removeAll { $0 == serviceId }
        store.updateGroup(updated)
    }

    private func moveMember(from source: IndexSet, to destination: Int, in g: TTSGroup) {
        var updated = g
        var ids = updated.memberServiceIds
        let items = source.sorted().map { ids[$0] }
        for idx in source.sorted(by: >) { ids.remove(at: idx) }
        let dest = destination - source.filter { $0 < destination }.count
        ids.insert(contentsOf: items, at: max(0, min(dest, ids.count)))
        updated.memberServiceIds = ids
        store.updateGroup(updated)
    }
}
