import SwiftUI

// MARK: - GroupSlotPicker
//
// A single "slot → model group" selector used for Default Primary / Default Sub
// / Voice Input / Voice Output. Shows the current group via a Menu listing all
// groups + None, plus a "Create new group from models…" action that opens the
// unified model picker in multi-select mode, builds a ModelGroup from the chosen
// entries, and assigns it to this slot.

struct GroupSlotPicker: View {
    @ObservedObject private var store = ProviderConfigStore.shared
    let label: LocalizedStringKey
    @Binding var selection: String?
    var voiceDirection: VoiceDirection? = nil
    /// [T-ios-vision-group #182] Vision slot: filter the create-group picker to
    /// image-capable models. Orthogonal to `voiceDirection` (never both set) —
    /// kept as a separate flag rather than a third VoiceDirection case so the
    /// voice resolver's exhaustive switches stay untouched.
    var isVision: Bool = false
    /// [问题3 / G2] 建组时优先筛选的模态。用于新增的图片输出/视频输出/
    /// 实时语音槽位——它们跟 isVision 是同一个用途：把候选收窄到能干的模型。
    var preferModality: ModelModality? = nil

    @State private var showCreate = false
    /// [问题3] `TTSServiceStore` 不是 ObservableObject（它用锁保护、跨线程读），
    /// 所以不能 @ObservedObject。用一个计数器在菜单打开时把最新列表拽进来。
    @State private var ttsRevision = 0

    /// [问题3] 语音输出槽能不能选独立的 TTS 服务。
    ///
    /// 她原话：「模型分组里面根本找不到我的 tts，或者能把我的 tts 放进去的
    /// 选项」。聊天内的语音选择器早就能选（UnifiedModelPicker.voiceOutput），
    /// 唯独默认设置页这一行只列模型组。这里把同一套虚拟条目接过来：
    /// 选中即写 `TTSServiceStore.selectedServiceId`，同时清掉组槽位，
    /// 让两条路由互斥——和 UnifiedModelPicker 的 onSelect 语义保持一致。
    private var showsTTSServices: Bool { voiceDirection == .output }

    private var enabledTTSServices: [TTSServiceOptions] {
        // 读一下 revision 让 SwiftUI 把它记成依赖（不能写成 `_ =`，那不算读）。
        guard ttsRevision >= 0, showsTTSServices else { return [] }
        return TTSServiceStore.shared.services.filter(\.enabled)
    }

    /// 选中的 TTS 服务 id（服务路由优先于组槽位）。
    private var selectedTTSServiceId: String? {
        guard ttsRevision >= 0, showsTTSServices else { return nil }
        let store = TTSServiceStore.shared
        guard let sid = store.selectedServiceId,
              store.service(id: sid)?.enabled == true else { return nil }
        return sid
    }

    private var selectedName: String {
        if let sid = selectedTTSServiceId,
           let s = TTSServiceStore.shared.service(id: sid) {
            return s.name
        }
        if let id = selection, let g = store.group(for: id) { return g.name }
        return AppLocalized("None", comment: "No group selected")
    }

    var body: some View {
        Menu {
            Picker(selection: Binding(
                get: { selection },
                set: { newValue in
                    // [问题3] 选了组就把 TTS 服务让位——两条路由互斥，
                    // 否则组选上了、发声的还是那个服务，看起来像没生效。
                    if newValue != nil, selectedTTSServiceId != nil {
                        TTSServiceStore.shared.setSelectedServiceId(nil)
                    }
                    selection = newValue
                }
            )) {
                Text("None", comment: "No group selected").tag(String?.none)
                ForEach(store.modelGroups) { group in
                    Text(group.name).tag(Optional(group.id))
                }
            } label: { EmptyView() }

            // [问题3] 她配置的 TTS 服务，独立成一节。选中后组槽位让位，
            // 因为合成路径只有一条，两边同时"选中"只会互相打架。
            if showsTTSServices && !enabledTTSServices.isEmpty {
                Section {
                    ForEach(enabledTTSServices) { service in
                        Button {
                            TTSServiceStore.shared.setSelectedServiceId(service.id)
                            selection = nil
                            VoiceOutputPlayer.shared.resetActiveModel()
                        } label: {
                            if selectedTTSServiceId == service.id {
                                Label("\(service.name) · \(service.voice)",
                                      systemImage: "checkmark")
                            } else {
                                Text("\(service.name) · \(service.voice)")
                            }
                        }
                    }
                } header: {
                    Text("语音服务", comment: "TTS services section in the voice output slot")
                }
            }

            Divider()
            // [K-2b] One runloop turn before presenting: a Menu item's action
            // runs while the menu is still on screen, and a sheet requested in
            // that same transaction is dropped ("从模型创建分组" dead).
            Button {
                DispatchQueue.main.async { showCreate = true }
            } label: {
                Label("Create group from models…", systemImage: "plus.rectangle.on.folder")
            }
        } label: {
            HStack {
                Text(label)
                    .foregroundStyle(AppearanceStudio.shared.color(.primaryText))
                Spacer()
                Text(selectedName)
                    .foregroundStyle(MinisTheme.secondaryText)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(MinisTheme.secondaryText.opacity(0.7))
            }
        }
        .onAppear { ttsRevision &+= 1 }
        .sheet(isPresented: $showCreate) {
            NavigationStack {
                UnifiedModelPicker(config: createGroupConfig())
            }
        }
    }

    @MainActor
    private func createGroupConfig() -> ModelPickerConfig {
        let dir = voiceDirection
        let assign: (String) -> Void = { selection = $0 }
        return ModelPickerConfig(
            title: "Create Group",
            mode: .multi,
            explicitPreferModality: preferModality.map { [$0] }
                ?? (isVision
                    ? [.imageInput]
                    : dir.map { $0 == .input ? [.audioInput] : [.audioOutput] }),
            groupScope: .none,
            headerNote: isVision
                ? AppLocalized("Showing models that can read images.", comment: "Vision group picker filter note")
                : dir?.filterNote,
            onAddMulti: { ids in
                guard !ids.isEmpty else { return }
                let name = Self.suggestedName(for: dir, isVision: isVision, store: ProviderConfigStore.shared)
                let group = ModelGroup(name: name, memberEntryIds: ids.sorted())
                ProviderConfigStore.shared.addGroup(group)
                assign(group.id)
            }
        )
    }

    private static func suggestedName(for dir: VoiceDirection?, isVision: Bool = false, store: ProviderConfigStore) -> String {
        let base: String
        if isVision {
            base = AppLocalized("Vision Input", comment: "Default vision group name")
        } else {
            switch dir {
            case .input:  base = AppLocalized("Voice Input", comment: "Default voice input group name")
            case .output: base = AppLocalized("Voice Output", comment: "Default voice output group name")
            case nil:     base = AppLocalized("New Group", comment: "Default group name")
            }
        }
        let existing = Set(store.modelGroups.map(\.name))
        if !existing.contains(base) { return base }
        var n = 2
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}
