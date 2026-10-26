import SwiftUI
import PhotosUI

// MARK: - PersonaSettingsView
//
// 编辑一个人设：名字、头像、人设提示词（SOUL.md 正文）、
// skill 开关、MCP 开关。v1 最小可用，界面跟着 App 现有风格走。

struct PersonaSettingsView: View {
    @ObservedObject var store: PersonaStore
    let personaID: String

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var avatarURI: String? = nil
    @State private var soulBody: String = ""
    @State private var enabledSkillIds: Set<String> = []
    @State private var enabledMcpIds: Set<String> = []
    @State private var loaded = false

    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var iconError: String?

    private var persona: Persona? {
        store.personas.first { $0.id == personaID }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本") {
                    HStack {
                        PersonaAvatarView(iconRef: avatarURI, size: 52)
                        Button("换头像") { showPhotoPicker = true }
                            .font(.callout)
                        if avatarURI != nil {
                            Button("去掉") { avatarURI = nil; saveAvatar() }
                                .font(.callout)
                                .foregroundStyle(MinisTheme.secondaryText)
                        }
                    }
                    TextField("名字", text: $name)
                        .onSubmit { saveName() }
                }

                Section("人设提示词") {
                    Text("这就是 SOUL.md 的正文，决定它说话的性格和身份。")
                        .font(.caption)
                        .foregroundStyle(MinisTheme.secondaryText)
                    TextEditor(text: $soulBody)
                        .frame(minHeight: 220)
                        .font(.body)
                }

                Section("Skill") {
                    Text("关掉的不再进它的 system prompt。注意：这个开关只管「要不要展示」，不是安全隔离——被关掉的仍可能被直接读取或调用。")
                        .font(.caption)
                        .foregroundStyle(MinisTheme.secondaryText)
                    ForEach(SkillStore.shared.skills) { skill in
                        Toggle(skill.name, isOn: Binding(
                            get: { enabledSkillIds.contains(skill.id) },
                            set: { on in
                                if on { enabledSkillIds.insert(skill.id) }
                                else { enabledSkillIds.remove(skill.id) }
                                saveSkillWhitelist()
                            }
                        ))
                    }
                }

                Section("MCP") {
                    Text("关掉的不再进它的 system prompt。注意：这个开关只管「要不要展示」，不是安全隔离——被关掉的仍可能被直接读取或调用。")
                        .font(.caption)
                        .foregroundStyle(MinisTheme.secondaryText)
                    ForEach(MCPStore.shared.servers) { server in
                        Toggle(server.id, isOn: Binding(
                            get: { enabledMcpIds.contains(server.id) },
                            set: { on in
                                if on { enabledMcpIds.insert(server.id) }
                                else { enabledMcpIds.remove(server.id) }
                                saveMcpWhitelist()
                            }
                        ))
                    }
                }

                if persona?.isBuiltIn == true {
                    Section {
                        Text("这是内置人设，删不掉。提示词可以改，但改了之后它的 MCP 管家身份可能会变味。")
                            .font(.caption)
                            .foregroundStyle(MinisTheme.secondaryText)
                    }
                }
            }
            // [问题7b] 她原话：「这个界面与设置页面的UI尺寸距离也不符合，
            // 显得很奇怪」。
            //
            // 根因不是颜色，是外壳：这页原先手写 .scrollContentBackground
            // + .background(MinisTheme.canvas)，只把底色和色值跟上了，
            // 而行背景、tint、壁纸 backdrop、透明导航栏这些设置面共有的
            // 东西一件都没有。设置里每一页走的都是 .settingsPage()
            // （appearancePage(.settings) + SettingsListRowBackground），
            // 两套外壳并排看就是"尺寸距离不符合"。
            //
            // 直接换成同一个外壳，而不是在这里再手抄一遍——手抄就是当初
            // 走偏的原因。
            .settingsPage()
            .navigationTitle("编辑人设")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("保存") { saveAll(); dismiss() }
                }
            }
            .onAppear { loadOnce() }
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem,
                          matching: .images, photoLibrary: .shared())
            .onChange(of: photoItem) { newItem in
                guard let newItem else { return }
                Task { await applyPickedImage(newItem) }
            }
            .alert("这张图用不了", isPresented: Binding(
                get: { iconError != nil }, set: { if !$0 { iconError = nil } }
            )) {
                Button("好", role: .cancel) { iconError = nil }
            } message: {
                Text(iconError ?? "")
            }
        }
    }

    // MARK: - load / save

    private func loadOnce() {
        guard !loaded, let p = persona else { return }
        loaded = true
        name = p.name
        avatarURI = p.avatar
        if let file = SoulStore.load(for: personaID) {
            soulBody = file.body
        }
        let allSkillIds = Set(SkillStore.shared.skills.map(\.id))
        enabledSkillIds = p.skillIds.map(Set.init) ?? allSkillIds
        let allMcpIds = Set(MCPStore.shared.servers.map(\.id))
        enabledMcpIds = p.mcpServerIds.map(Set.init) ?? allMcpIds
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.renamePersona(personaID, to: trimmed)
    }

    private func saveAvatar() {
        guard var p = persona else { return }
        p.avatar = avatarURI
        store.updatePersona(p)
    }

    private func saveSoul() {
        var file = SoulStore.load(for: personaID)
            ?? SoulFile(metadata: .default, body: "")
        file.body = soulBody
        try? SoulStore.save(file, for: personaID)
    }

    private func saveSkillWhitelist() {
        guard var p = persona else { return }
        let all = Set(SkillStore.shared.skills.map(\.id))
        p.skillIds = (enabledSkillIds == all) ? nil : Array(enabledSkillIds)
        store.updatePersona(p)
    }

    private func saveMcpWhitelist() {
        guard var p = persona else { return }
        let all = Set(MCPStore.shared.servers.map(\.id))
        p.mcpServerIds = (enabledMcpIds == all) ? nil : Array(enabledMcpIds)
        store.updatePersona(p)
    }

    private func saveAll() {
        saveName()
        saveAvatar()
        saveSoul()
        saveSkillWhitelist()
        saveMcpWhitelist()
    }

    private func applyPickedImage(_ item: PhotosPickerItem) async {
        defer { photoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = ThumbnailCache.downsampledImage(from: data, maxEdge: 512) else {
            await MainActor.run { iconError = "这张图读不出来，换一张试试。" }
            return
        }
        // [avatar-file] Stored as a file reference, never inline base64.
        let name = SoulIconImage.storedName(prefix: "persona", id: personaID)
        switch SoulIconImage.store(image, named: name) {
        case .success(let path):
            await MainActor.run {
                avatarURI = path
                saveAvatar()
            }
        case .failure:
            await MainActor.run { iconError = "这张图读不出来，换一张试试。" }
        }
    }
}
