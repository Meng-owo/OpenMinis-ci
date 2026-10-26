import SwiftUI
import UniformTypeIdentifiers
import UIKit
import PhotosUI

// MARK: - iOS Settings 统一风格图标胶囊
struct SettingsRowIcon: View {
    let icon: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppearanceStudio.shared.color(.surface))
                .frame(width: 28, height: 28)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(AppearanceStudio.shared.color(.border).opacity(0.4), lineWidth: 0.6)
                )
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppearanceStudio.shared.color(.primaryText))
        }
    }
}

// MARK: - 1. PersonaContactsView (通讯录主列表)
// 原生全屏 Navigation 页面，无弹窗抽屉，体验与系统设置及微信通讯录完全对齐。

struct PersonaContactsView: View {
    @ObservedObject var store = PersonaStore.shared
    @Environment(\.dismiss) private var dismiss
    var onSelectAndChat: ((Persona) -> Void)?

    @State private var searchText = ""
    @State private var showNewSheet = false
    @State private var newName = ""
    @State private var deleteTarget: Persona?
    @State private var appeared = false
    @State private var refreshTick = 0

    private var filteredPersonas: [Persona] {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return store.personas
        }
        return store.personas.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// 档案副标题：数一下真正填了冒号内容的条目。
    static func profileSummaryText() -> String {
        guard let soul = SoulStore.load(for: PersonaStore.userProfilePersonaID) else {
            return "还没填，点进来写"
        }
        var filled = 0
        for raw in soul.body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- ") else { continue }
            let stripped = String(line.dropFirst(2))
            guard let colon = stripped.firstIndex(of: "：") ?? stripped.firstIndex(of: ":") else { continue }
            let value = stripped[stripped.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { filled += 1 }
        }
        if filled == 0 { return "还没填，点进来写" }
        return "已填 \(filled) 项 · AI 每轮对话都看得到"
    }

    /// [B28 R11] 卡片标题：档案显示她档案里填的称呼，人设显示人设名。
    static func displayName(for persona: Persona) -> String {
        guard persona.isUserProfile else { return persona.name }
        let called = SystemPromptBuilder.userProfileAddressingName()
        return called.isEmpty ? persona.name : called
    }

    var body: some View {
        List {
            Section {
                ForEach(filteredPersonas) { persona in
                    NavigationLink {
                        // [B28 R11] 「我自己」走资料页，不给模型/工具/技能那一套——
                        // 它描述的是用户，不是会说话的谁。
                        if persona.isUserProfile {
                            UserProfileView()
                        } else {
                            PersonaDetailHomeView(personaId: persona.id, onSelectAndChat: onSelectAndChat)
                        }
                    } label: {
                        HStack(spacing: 14) {
                            PersonaAvatarView(iconRef: persona.avatar, size: 46)
                                .overlay(
                                    Circle()
                                        .stroke(persona.id == store.currentPersonaID ? MinisThemeList.accent : Color.clear, lineWidth: 2)
                                )

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(PersonaContactsView.displayName(for: persona))
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(ChatColors.primaryText)

                                    // [B28 R6 · 醒醒点名] 「内置」批删了：出身不是
                                    // 关系，防误删保护本来就在 swipeActions 里。
                                    // 「使用中」加呼吸小灯 —— 系统 symbolEffect 的
                                    // pulse，合成器驱动不烧 CPU，语义一字没改。
                                    if persona.isUserProfile {
                                        // 「我自己」不是聊天对象，标出来免得她被算进联系人。
                                        Text("我自己")
                                            .font(.system(size: 10, weight: .medium))
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2.5)
                                            .background(Capsule().fill(MinisThemeList.accent.opacity(0.12)))
                                            .foregroundStyle(MinisThemeList.accent)
                                    }
                                    if persona.id == store.currentPersonaID {
                                        HStack(spacing: 4) {
                                            Image(systemName: "circle.fill")
                                                .font(.system(size: 6))
                                                .symbolEffect(.pulse, options: .repeating)
                                            Text("使用中")
                                        }
                                        .font(.system(size: 10, weight: .medium))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2.5)
                                        .background(Capsule().fill(MinisThemeList.accent.opacity(0.15)))
                                        .foregroundStyle(MinisThemeList.accent)
                                    }
                                }

                                Text(personaBio(for: persona))
                                    .font(.system(size: 12))
                                    .foregroundStyle(ChatColors.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !persona.isBuiltIn && store.personas.count > 1 {
                            Button(role: .destructive) {
                                deleteTarget = persona
                            } label: {
                                Label("删除", systemImage: "trash.fill")
                            }
                        }
                        if !persona.isUserProfile {
                            Button {
                                _ = store.duplicatePersona(persona.id)
                            } label: {
                                Label("复制", systemImage: "doc.on.doc.fill")
                            }
                            .tint(.blue)
                        }
                    }
                }
            } header: {
                Text("所有联系人")
            } footer: {
                Text("点进去微调；左滑可复制或删除。最上面的「我自己」是你的档案，不能复制或删。")
            }
        }
        .listStyle(.insetGrouped)
        // 进场：整页淡入 + 轻微上移。跟系统设置那种"啪一下出现"不一样。
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 6)
        .animation(.easeOut(duration: 0.28), value: appeared)
        .onAppear { appeared = true }
        // 档案内容改了不会动 personas 数组，列表不会自己重画——
        // 副标题"已填 N 项"就会停在旧数字上。这里跟着通知重算一次。
        .onReceive(NotificationCenter.default.publisher(for: .personaDidChange)) { _ in
            refreshTick += 1
        }
        // [B28 R4] 接进主题系统：通讯录有独立壁纸槽位（.persona）。
        .appearancePage(.persona)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索联系人")
        .navigationTitle("通讯录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newName = ""
                    showNewSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .medium))
                }
            }
        }
        .alert("新建人设", isPresented: $showNewSheet) {
            TextField("人设名字", text: $newName)
            Button("取消", role: .cancel) {}
            Button("创建") {
                let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                _ = store.addPersona(name: trimmed)
            }
        }
        .alert("删除人设", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let target = deleteTarget {
                    store.deletePersona(target.id)
                    deleteTarget = nil
                }
            }
            Button("取消", role: .cancel) {
                deleteTarget = nil
            }
        } message: {
            if let target = deleteTarget {
                Text("确认删除人设「\(target.name)」？该人设的专属记忆目录将一并移除。")
            }
        }
    }

    /// [B28 R4] 简介行不许把 markdown 源码直接印给用户 ——
    /// `| name | ios-swift |`、`| --- |` 这些格式是写给人设本体的，
    /// 不是给人看的字。保守清洗：表格线、分隔杠、标题符、行内码、星号。
    private static func cleanBio(_ raw: String) -> String {
        var t = raw.replacingOccurrences(of: "\n", with: " ")
        t = t.replacingOccurrences(of: "[-:|]{3,}[-:| ]*", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\s*\\|\\s*", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "[#`]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\*{1,3}", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    private func personaBio(for persona: Persona) -> String {
        // 读一下 tick：档案改了、personas 没变，也要让这行重新算。
        _ = refreshTick
        // [B28 R11] 档案的正文是一堆小节标题，直接当副标题会糊成一片，
        // 所以给它单独一句：填了几项、还差什么。
        if persona.isUserProfile {
            return PersonaContactsView.profileSummaryText()
        }
        if let soul = SoulStore.load(for: persona.id) {
            let bio = soul.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !bio.isEmpty {
                return Self.cleanBio(bio)
            }
        }
        return persona.isBuiltIn ? "桥内置的 MCP 管家" : "暂无人设描述"
    }
}

// MARK: - 2. PersonaDetailHomeView (人设主页)
// 对齐系统设置主页与 Kelivo AssistantPage，彻底移除丑底框与抽屉弹窗。

struct PersonaDetailHomeView: View {
    let personaId: String
    var onSelectAndChat: ((Persona) -> Void)?

    @ObservedObject var store = PersonaStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var photoItem: PhotosPickerItem?

    private var persona: Persona? {
        store.personas.first { $0.id == personaId }
    }

    var body: some View {
        Group {
            if let p = persona {
                List {
                    // Header: 大圆头像 + 名字 + 活跃标记
                    Section {
                        VStack(spacing: 12) {
                            PhotosPicker(selection: $photoItem, matching: .images) {
                                ZStack(alignment: .bottomTrailing) {
                                    PersonaAvatarView(iconRef: p.avatar, size: 84)
                                        .clipShape(Circle())
                                        .overlay(Circle().stroke(p.id == store.currentPersonaID ? MinisThemeList.accent : Color.secondary.opacity(0.2), lineWidth: 3))
                                        .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 3)

                                    Image(systemName: "camera.fill")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(Color.white)
                                        .padding(6)
                                        .background(Circle().fill(MinisThemeList.accent))
                                        .offset(x: -2, y: -2)
                                }
                            }
                            .buttonStyle(.plain)

                            HStack(spacing: 6) {
                                Text(p.name)
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(ChatColors.primaryText)

                                Button {
                                    renameText = p.name
                                    showRenameAlert = true
                                } label: {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 14))
                                        .foregroundStyle(MinisTheme.secondaryText)
                                }
                                .buttonStyle(.plain)
                            }

                            if p.id == store.currentPersonaID {
                                Text("当前活跃人设")
                                    .font(.system(size: 11, weight: .semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(MinisThemeList.accent.opacity(0.16)))
                                    .foregroundStyle(MinisThemeList.accent)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .listRowBackground(Color.clear)

                    // 9 大核心子项 (与 Kelivo 9 个 Tab 完整对齐)
                    Section {
                        NavigationLink {
                            PersonaBasicSettingsView(personaId: p.id)
                        } label: {
                            HStack(spacing: 12) {
                                SettingsRowIcon(icon: "slider.horizontal.3")
                                Text("基础设置")
                                    .font(.body)
                                Spacer()
                                if p.temperature != nil || p.topP != nil {
                                    Text("已调优")
                                        .font(.subheadline)
                                        .foregroundStyle(MinisTheme.secondaryText)
                                }
                            }
                        }

                        NavigationLink {
                            PersonaPromptSettingsView(personaId: p.id)
                        } label: {
                            HStack(spacing: 12) {
                                SettingsRowIcon(icon: "doc.text.fill")
                                Text("提示词")
                                    .font(.body)
                            }
                        }

                        NavigationLink {
                            PersonaMemorySettingsView(personaId: p.id)
                        } label: {
                            HStack(spacing: 12) {
                                SettingsRowIcon(icon: "brain.head.profile")
                                Text("记忆")
                                    .font(.body)
                            }
                        }

                        NavigationLink {
                            PersonaLocalToolsSettingsView(personaId: p.id)
                        } label: {
                            HStack(spacing: 12) {
                                SettingsRowIcon(icon: "wrench.and.screwdriver.fill")
                                Text("本地工具")
                                    .font(.body)
                                Spacer()
                                let enabledCount = p.localToolIds?.count ?? LocalToolRegistry.all.count
                                Text("\(enabledCount)/\(LocalToolRegistry.all.count)")
                                    .font(.subheadline)
                                    .foregroundStyle(MinisTheme.secondaryText)
                            }
                        }

                        NavigationLink {
                            PersonaSkillsSettingsView(personaId: p.id)
                        } label: {
                            HStack(spacing: 12) {
                                SettingsRowIcon(icon: "sparkles")
                                Text("技能")
                                    .font(.body)
                                Spacer()
                                if let cnt = p.skillIds?.count {
                                    Text("\(cnt) 项可用")
                                        .font(.subheadline)
                                        .foregroundStyle(MinisTheme.secondaryText)
                                }
                            }
                        }

                        NavigationLink {
                            PersonaMcpSettingsView(personaId: p.id)
                        } label: {
                            HStack(spacing: 12) {
                                SettingsRowIcon(icon: "terminal.fill")
                                Text("MCP")
                                    .font(.body)
                                Spacer()
                                if let cnt = p.mcpServerIds?.count {
                                    Text("\(cnt) 个服务器")
                                        .font(.subheadline)
                                        .foregroundStyle(MinisTheme.secondaryText)
                                }
                            }
                        }

                        NavigationLink {
                            PersonaPresetMessagesView(personaId: p.id)
                        } label: {
                            HStack(spacing: 12) {
                                SettingsRowIcon(icon: "bolt.fill")
                                Text("快捷短语")
                                    .font(.body)
                                Spacer()
                                if !p.presetMessages.isEmpty {
                                    Text("\(p.presetMessages.count) 条")
                                        .font(.subheadline)
                                        .foregroundStyle(MinisTheme.secondaryText)
                                }
                            }
                        }

                        NavigationLink {
                            PersonaCustomRequestView(personaId: p.id)
                        } label: {
                            HStack(spacing: 12) {
                                SettingsRowIcon(icon: "network")
                                Text("自定义请求")
                                    .font(.body)
                                Spacer()
                                let total = p.customHeaders.count + p.customBody.count
                                if total > 0 {
                                    Text("\(total) 个字段")
                                        .font(.subheadline)
                                        .foregroundStyle(MinisTheme.secondaryText)
                                }
                            }
                        }

                        NavigationLink {
                            // [10-19 醒醒] 正则改成全局一份，不再跟着人设走。
                            // 入口还留在这里，因为她习惯从这里找。
                            GlobalRegexRulesView()
                        } label: {
                            HStack(spacing: 12) {
                                SettingsRowIcon(icon: "textformat")
                                Text("正则替换")
                                    .font(.body)
                                Spacer()
                                Text("全局")
                                    .font(.caption)
                                    .foregroundStyle(MinisTheme.secondaryText)
                                if !GlobalRegexStore.shared.rules.isEmpty {
                                    Text("\(GlobalRegexStore.shared.rules.count) 条规则")
                                        .font(.subheadline)
                                        .foregroundStyle(MinisTheme.secondaryText)
                                }
                            }
                        }
                    } header: {
                        Text("微调与能力")
                    } footer: {
                        Text("人设各参数与规则实时生效。")
                    }

                    // 对话与快捷操作
                    Section {
                        Button {
                            store.setCurrent(p.id)
                            onSelectAndChat?(p)
                        } label: {
                            HStack {
                                Spacer()
                                Image(systemName: "bubble.left.and.bubble.right.fill")
                                Text("与 Ta 对话")
                                    .font(.system(size: 16, weight: .semibold))
                                Spacer()
                            }
                            .padding(.vertical, 4)
                            .foregroundStyle(MinisThemeList.accent)
                        }

                        if p.id != store.currentPersonaID {
                            Button {
                                store.setCurrent(p.id)
                            } label: {
                                HStack {
                                    Spacer()
                                    Text("设为当前活跃人设")
                                        .font(.system(size: 15))
                                    Spacer()
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle(p.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                store.setCurrent(p.id)
                            } label: {
                                Label("设为当前活跃人设", systemImage: "checkmark.circle")
                            }

                            Button {
                                if let copy = store.duplicatePersona(p.id) {
                                    store.setCurrent(copy.id)
                                }
                            } label: {
                                Label("复制为人设副本", systemImage: "doc.on.doc")
                            }

                            if !p.isBuiltIn && store.personas.count > 1 {
                                Button(role: .destructive) {
                                    store.deletePersona(p.id)
                                    dismiss()
                                } label: {
                                    Label("删除人设", systemImage: "trash.fill")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 16))
                        }
                    }
                }
                .onChange(of: photoItem) { newItem in
                    guard let item = newItem else { return }
                    Task {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let image = ThumbnailCache.downsampledImage(from: data, maxEdge: 512) {
                            let name = SoulIconImage.storedName(prefix: "persona", id: p.id)
                            if case .success(let path) = SoulIconImage.store(image, named: name) {
                                await MainActor.run {
                                    var updated = p
                                    updated.avatar = path
                                    store.updatePersona(updated)
                                    if store.currentPersonaID == p.id {
                                        SoulStore.refreshCache()
                                    }
                                }
                            }
                        }
                    }
                }
                .alert("重命名人设", isPresented: $showRenameAlert) {
                    TextField("人设名字", text: $renameText)
                    Button("取消", role: .cancel) {}
                    Button("保存") {
                        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        store.renamePersona(p.id, to: trimmed)
                    }
                }
            } else {
                Text("人设不存在或已被删除")
                    .foregroundStyle(MinisTheme.secondaryText)
            }
        }
    }
}

// MARK: - 3. PersonaBasicSettingsView (基础设置)
// 系统设置 InsetGrouped 规范：采样参数、上下文限制、专属模型、壁纸与流式开关

struct PersonaBasicSettingsView: View {
    let personaId: String
    @ObservedObject var store = PersonaStore.shared

    @State private var tempValue: Double = 1.0
    @State private var tempEnabled: Bool = false

    @State private var topPValue: Double = 1.0
    @State private var topPEnabled: Bool = false

    @State private var maxTokensValue: Int = 4096
    @State private var maxTokensEnabled: Bool = false

    @State private var thinkingBudgetValue: Int = 4096
    @State private var thinkingBudgetEnabled: Bool = false

    @State private var contextLimitEnabled: Bool = false
    @State private var contextMessageCount: Int = 20

    @State private var defaultWorkspaceText: String = ""
    @State private var streamOutputVal: Bool = true
    @State private var useAvatarVal: Bool = false
    @State private var useNameVal: Bool = false

    @State private var backgroundPhotoItem: PhotosPickerItem?

    private var persona: Persona? {
        store.personas.first { $0.id == personaId }
    }

    var body: some View {
        Group {
            if let p = persona {
                List {
                    // MARK: 采样与推理参数
                    Section {
                        // Temperature
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Temperature")
                                    .font(.body)
                                Spacer()
                                Text(tempEnabled ? String(format: "%.2f", tempValue) : "默认")
                                    .font(.subheadline)
                                    .foregroundStyle(MinisTheme.secondaryText)
                            }
                            Toggle("自定义 Temperature", isOn: $tempEnabled)
                                .onChange(of: tempEnabled) { on in
                                    var updated = p
                                    updated.temperature = on ? tempValue : nil
                                    store.updatePersona(updated)
                                }
                            if tempEnabled {
                                Slider(value: $tempValue, in: 0.0...2.0, step: 0.05) {
                                    Text("Temperature")
                                } minimumValueLabel: {
                                    Text("0.0").font(.caption2).foregroundStyle(MinisTheme.secondaryText)
                                } maximumValueLabel: {
                                    Text("2.0").font(.caption2).foregroundStyle(MinisTheme.secondaryText)
                                }
                                .onChange(of: tempValue) { val in
                                    var updated = p
                                    updated.temperature = val
                                    store.updatePersona(updated)
                                }
                            }
                        }
                        .padding(.vertical, 4)

                        // Top P
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Top P")
                                    .font(.body)
                                Spacer()
                                Text(topPEnabled ? String(format: "%.2f", topPValue) : "默认")
                                    .font(.subheadline)
                                    .foregroundStyle(MinisTheme.secondaryText)
                            }
                            Toggle("自定义 Top P", isOn: $topPEnabled)
                                .onChange(of: topPEnabled) { on in
                                    var updated = p
                                    updated.topP = on ? topPValue : nil
                                    store.updatePersona(updated)
                                }
                            if topPEnabled {
                                Slider(value: $topPValue, in: 0.0...1.0, step: 0.05) {
                                    Text("Top P")
                                } minimumValueLabel: {
                                    Text("0.0").font(.caption2).foregroundStyle(MinisTheme.secondaryText)
                                } maximumValueLabel: {
                                    Text("1.0").font(.caption2).foregroundStyle(MinisTheme.secondaryText)
                                }
                                .onChange(of: topPValue) { val in
                                    var updated = p
                                    updated.topP = val
                                    store.updatePersona(updated)
                                }
                            }
                        }
                        .padding(.vertical, 4)

                        // 最大 Token
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("最大输出 Token")
                                    .font(.body)
                                Spacer()
                                Text(maxTokensEnabled ? "\(maxTokensValue)" : "默认")
                                    .font(.subheadline)
                                    .foregroundStyle(MinisTheme.secondaryText)
                            }
                            Toggle("限制最大 Token", isOn: $maxTokensEnabled)
                                .onChange(of: maxTokensEnabled) { on in
                                    var updated = p
                                    updated.maxTokens = on ? maxTokensValue : nil
                                    store.updatePersona(updated)
                                }
                            if maxTokensEnabled {
                                Stepper("上限: \(maxTokensValue)", value: $maxTokensValue, in: 256...65536, step: 512)
                                    .onChange(of: maxTokensValue) { val in
                                        var updated = p
                                        updated.maxTokens = val
                                        store.updatePersona(updated)
                                    }
                            }
                        }
                        .padding(.vertical, 4)

                        // 思考预算 (Thinking Budget)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("思考预算 (Tokens)")
                                    .font(.body)
                                Spacer()
                                Text(thinkingBudgetEnabled ? "\(thinkingBudgetValue)" : "默认")
                                    .font(.subheadline)
                                    .foregroundStyle(MinisTheme.secondaryText)
                            }
                            Toggle("自定义思考预算", isOn: $thinkingBudgetEnabled)
                                .onChange(of: thinkingBudgetEnabled) { on in
                                    var updated = p
                                    updated.thinkingBudget = on ? thinkingBudgetValue : nil
                                    store.updatePersona(updated)
                                }
                            if thinkingBudgetEnabled {
                                Stepper("预算: \(thinkingBudgetValue)", value: $thinkingBudgetValue, in: 1024...65536, step: 1024)
                                    .onChange(of: thinkingBudgetValue) { val in
                                        var updated = p
                                        updated.thinkingBudget = val
                                        store.updatePersona(updated)
                                    }
                            }
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text("采样与推理")
                    } footer: {
                        Text("未启用的项将自动采用底层供应商或全局默认参数。")
                    }

                    // MARK: 上下文历史限制
                    Section {
                        Toggle("限制上下文消息条数", isOn: $contextLimitEnabled)
                            .onChange(of: contextLimitEnabled) { on in
                                var updated = p
                                updated.limitContextMessages = on
                                store.updatePersona(updated)
                            }

                        if contextLimitEnabled {
                            Stepper("保留最近 \(contextMessageCount) 条消息", value: $contextMessageCount, in: 4...100, step: 2)
                                .onChange(of: contextMessageCount) { cnt in
                                    var updated = p
                                    updated.contextMessageSize = cnt
                                    store.updatePersona(updated)
                                }
                        }
                    } header: {
                        Text("上下文控制")
                    } footer: {
                        Text("开启后将自动截断更早的历史消息，避免上下文窗口过满并降低 Token 消耗。")
                    }

                    // MARK: 模型与独立绑定
                    Section {
                        let allEntries = ProviderConfigStore.shared.config.modelEntries
                        Picker("绑定模型", selection: Binding(
                            get: { p.modelId ?? "" },
                            set: { newVal in
                                var updated = p
                                updated.modelId = newVal.isEmpty ? nil : newVal
                                store.updatePersona(updated)
                            }
                        )) {
                            Text("继承全局默认模型").tag("")
                            ForEach(allEntries) { entry in
                                Text(entryTitle(for: entry)).tag(entry.id)
                            }
                        }

                        Toggle("流式输出 (Stream)", isOn: $streamOutputVal)
                            .onChange(of: streamOutputVal) { val in
                                var updated = p
                                updated.streamOutput = val
                                store.updatePersona(updated)
                            }
                    } header: {
                        Text("模型与生成")
                    } footer: {
                        Text("为人设单独指定模型后，对话该人设时将自动路由至此模型。")
                    }

                    // MARK: 外观与个性化
                    Section {
                        PhotosPicker(selection: $backgroundPhotoItem, matching: .images) {
                            HStack {
                                Text("专属聊天背景")
                                    .font(.body)
                                    .foregroundStyle(ChatColors.primaryText)
                                Spacer()
                                Text(p.background != nil ? "已设置专属壁纸" : "未设置")
                                    .font(.subheadline)
                                    .foregroundStyle(MinisTheme.secondaryText)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13))
                                    .foregroundStyle(MinisTheme.secondaryText.opacity(0.7))
                            }
                        }

                        if p.background != nil {
                            Button(role: .destructive) {
                                var updated = p
                                updated.background = nil
                                store.updatePersona(updated)
                            } label: {
                                Text("移除专属背景")
                                    .font(.subheadline)
                            }
                        }

                        Toggle("聊天中展示助手头像", isOn: $useAvatarVal)
                            .onChange(of: useAvatarVal) { val in
                                var updated = p
                                updated.useAssistantAvatar = val
                                store.updatePersona(updated)
                            }

                        Toggle("聊天中展示助手名字", isOn: $useNameVal)
                            .onChange(of: useNameVal) { val in
                                var updated = p
                                updated.useAssistantName = val
                                store.updatePersona(updated)
                            }
                    } header: {
                        Text("外观个性化")
                    }

                    // MARK: 默认工作区
                    Section {
                        TextField("工作区路径 (默认 /var/minis/workspace)", text: $defaultWorkspaceText)
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onChange(of: defaultWorkspaceText) { val in
                                var updated = p
                                let trimmed = val.trimmingCharacters(in: .whitespacesAndNewlines)
                                updated.defaultWorkspace = trimmed.isEmpty ? nil : trimmed
                                store.updatePersona(updated)
                            }
                    } header: {
                        Text("工作区")
                    } footer: {
                        Text("终端与文件操作默认以此目录为根路径。")
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle("基础设置")
                .navigationBarTitleDisplayMode(.inline)
                .onAppear {
                    loadFromPersona(p)
                }
                .onChange(of: backgroundPhotoItem) { item in
                    guard let item = item else { return }
                    Task {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let image = ThumbnailCache.downsampledImage(from: data, maxEdge: 2200) {
                            let name = SoulIconImage.storedName(prefix: "bg-\(p.id)", id: p.id)
                            if case .success(let path) = SoulIconImage.store(image, named: name) {
                                await MainActor.run {
                                    var updated = p
                                    updated.background = path
                                    store.updatePersona(updated)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func entryTitle(for entry: ModelEntry) -> String {
        entry.model.displayName
    }

    private func loadFromPersona(_ p: Persona) {
        if let t = p.temperature {
            tempEnabled = true
            tempValue = t
        } else {
            tempEnabled = false
            tempValue = 1.0
        }

        if let tp = p.topP {
            topPEnabled = true
            topPValue = tp
        } else {
            topPEnabled = false
            topPValue = 1.0
        }

        if let mt = p.maxTokens {
            maxTokensEnabled = true
            maxTokensValue = mt
        } else {
            maxTokensEnabled = false
            maxTokensValue = 4096
        }

        if let tb = p.thinkingBudget {
            thinkingBudgetEnabled = true
            thinkingBudgetValue = tb
        } else {
            thinkingBudgetEnabled = false
            thinkingBudgetValue = 4096
        }

        contextLimitEnabled = p.limitContextMessages
        contextMessageCount = p.contextMessageSize
        streamOutputVal = p.streamOutput
        useAvatarVal = p.useAssistantAvatar
        useNameVal = p.useAssistantName
        defaultWorkspaceText = p.defaultWorkspace ?? ""
    }
}

// MARK: - 4. PersonaPresetMessagesView (快捷短语)
// 管理助手的预设对话信息与快捷短语，支持增删改查与拖拽排序。

struct PersonaPresetMessagesView: View {
    let personaId: String
    @ObservedObject var store = PersonaStore.shared

    @State private var showEditor = false
    @State private var editingMessage: PresetMessage?
    @State private var editorRole = "user"
    @State private var editorContent = ""

    private var persona: Persona? {
        store.personas.first { $0.id == personaId }
    }

    var body: some View {
        Group {
            if let p = persona {
                List {
                    Section {
                        if p.presetMessages.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "bolt.slash")
                                    .font(.system(size: 28))
                                    .foregroundStyle(MinisTheme.secondaryText)
                                Text("暂无快捷短语")
                                    .font(.subheadline)
                                    .foregroundStyle(MinisTheme.secondaryText)
                                Text("点击右上角「+」可为该人设添加常用提问或预设对话轮次。")
                                    .font(.caption)
                                    .foregroundStyle(MinisTheme.secondaryText.opacity(0.7))
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                        } else {
                            ForEach(p.presetMessages) { msg in
                                Button {
                                    startEdit(msg)
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text(msg.role == "assistant" ? "助手" : "用户")
                                                .font(.system(size: 11, weight: .semibold))
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 2)
                                                .background(
                                                    Capsule().fill(presetRoleTint(msg.role, alpha: 0.15))
                                                )
                                                .foregroundStyle(presetRoleTint(msg.role, alpha: 1))
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 12))
                                                .foregroundStyle(MinisTheme.secondaryText.opacity(0.7))
                                        }

                                        Text(msg.content)
                                            .font(.system(size: 14))
                                            .foregroundStyle(ChatColors.primaryText)
                                            .lineLimit(3)
                                    }
                                    .padding(.vertical, 2)
                                }
                                .buttonStyle(.plain)
                            }
                            .onDelete { indexSet in
                                var updated = p
                                updated.presetMessages.remove(atOffsets: indexSet)
                                store.updatePersona(updated)
                            }
                            .onMove { indices, newOffset in
                                var updated = p
                                updated.presetMessages.move(fromOffsets: indices, toOffset: newOffset)
                                store.updatePersona(updated)
                            }
                        }
                    } header: {
                        HStack {
                            Text("预设短语与会话模板")
                            Spacer()
                            if !p.presetMessages.isEmpty {
                                EditButton()
                                    .font(.system(size: 13))
                            }
                        }
                    } footer: {
                        Text("预设短语可在输入栏中快速调用，或作为该人设发起会话时的示例范例。")
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle("快捷短语")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            startCreate()
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .medium))
                        }
                    }
                }
                .sheet(isPresented: $showEditor) {
                    NavigationStack {
                        Form {
                            Section("消息角色") {
                                Picker("角色", selection: $editorRole) {
                                    Text("用户 (User)").tag("user")
                                    Text("助手 (Assistant)").tag("assistant")
                                }
                                .pickerStyle(.segmented)
                            }

                            Section("消息内容") {
                                TextEditor(text: $editorContent)
                                    .frame(minHeight: 140)
                                    .font(.system(size: 15))
                            }
                        }
                        .navigationTitle(editingMessage == nil ? "添加快捷短语" : "编辑快捷短语")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("取消") { showEditor = false }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("保存") {
                                    saveMessage(for: p)
                                    showEditor = false
                                }
                                .disabled(editorContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    }
                    .presentationDetents([.medium, .large])
                }
            }
        }
    }

    private func startCreate() {
        editingMessage = nil
        editorRole = "user"
        editorContent = ""
        showEditor = true
    }

    /// 三目嵌套会拖垮类型推断（加几个 @State 之后编译就超时了），抽出来。
    private func presetRoleTint(_ role: String, alpha: Double) -> Color {
        role == "assistant" ? Color.green.opacity(alpha) : Color.blue.opacity(alpha)
    }

    private func startEdit(_ msg: PresetMessage) {
        editingMessage = msg
        editorRole = msg.role
        editorContent = msg.content
        showEditor = true
    }

    private func saveMessage(for p: Persona) {
        let content = editorContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        var updated = p
        if let target = editingMessage, let idx = updated.presetMessages.firstIndex(where: { $0.id == target.id }) {
            updated.presetMessages[idx] = PresetMessage(id: target.id, role: editorRole, content: content)
        } else {
            updated.presetMessages.append(PresetMessage(role: editorRole, content: content))
        }
        store.updatePersona(updated)
    }
}

// MARK: - 5. PersonaCustomRequestView (自定义请求)
// 为该助手注入独立的请求头 (Headers) 与请求体参数 (Body)。

struct PersonaCustomRequestView: View {
    let personaId: String
    @ObservedObject var store = PersonaStore.shared

    @State private var showHeaderSheet = false
    @State private var headerName = ""
    @State private var headerValue = ""
    @State private var editingHeaderId: String?

    @State private var showBodySheet = false
    @State private var bodyKey = ""
    @State private var bodyValue = ""
    @State private var editingBodyId: String?

    private var persona: Persona? {
        store.personas.first { $0.id == personaId }
    }

    var body: some View {
        Group {
            if let p = persona {
                List {
                    // MARK: 请求头 (Headers)
                    Section {
                        if p.customHeaders.isEmpty {
                            Text("暂无自定义请求头")
                                .font(.subheadline)
                                .foregroundStyle(MinisTheme.secondaryText)
                        } else {
                            ForEach(p.customHeaders) { h in
                                Button {
                                    editingHeaderId = h.id
                                    headerName = h.name
                                    headerValue = h.value
                                    showHeaderSheet = true
                                } label: {
                                    HStack {
                                        Text(h.name)
                                            .font(.system(.body, design: .monospaced))
                                            .foregroundStyle(ChatColors.primaryText)
                                        Spacer()
                                        Text(h.value)
                                            .font(.system(.body, design: .monospaced))
                                            .foregroundStyle(MinisTheme.secondaryText)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            .onDelete { indexSet in
                                var updated = p
                                updated.customHeaders.remove(atOffsets: indexSet)
                                store.updatePersona(updated)
                            }
                        }

                        Button {
                            editingHeaderId = nil
                            headerName = ""
                            headerValue = ""
                            showHeaderSheet = true
                        } label: {
                            Label("添加请求头", systemImage: "plus")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(MinisThemeList.accent)
                        }
                    } header: {
                        Text("自定义请求头 (Headers)")
                    } footer: {
                        Text("大模型发起网络请求时，会将上述 Header 注入到 HTTP 请求中，例如特定网关路由标签。")
                    }

                    // MARK: 请求体 (Extra Body)
                    Section {
                        if p.customBody.isEmpty {
                            Text("暂无自定义请求体参数")
                                .font(.subheadline)
                                .foregroundStyle(MinisTheme.secondaryText)
                        } else {
                            ForEach(p.customBody) { b in
                                Button {
                                    editingBodyId = b.id
                                    bodyKey = b.key
                                    bodyValue = b.value
                                    showBodySheet = true
                                } label: {
                                    HStack {
                                        Text(b.key)
                                            .font(.system(.body, design: .monospaced))
                                            .foregroundStyle(ChatColors.primaryText)
                                        Spacer()
                                        Text(b.value)
                                            .font(.system(.body, design: .monospaced))
                                            .foregroundStyle(MinisTheme.secondaryText)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            .onDelete { indexSet in
                                var updated = p
                                updated.customBody.remove(atOffsets: indexSet)
                                store.updatePersona(updated)
                            }
                        }

                        Button {
                            editingBodyId = nil
                            bodyKey = ""
                            bodyValue = ""
                            showBodySheet = true
                        } label: {
                            Label("添加请求体参数", systemImage: "plus")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(MinisThemeList.accent)
                        }
                    } header: {
                        Text("自定义请求体 (Extra Body)")
                    } footer: {
                        Text("向请求体顶层或 extra_body 注入自定义参数字段（例如供应商专用扩展）。")
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle("自定义请求")
                .navigationBarTitleDisplayMode(.inline)
                .sheet(isPresented: $showHeaderSheet) {
                    NavigationStack {
                        Form {
                            Section("Header 名称") {
                                TextField("如 X-Custom-Header", text: $headerName)
                                    .font(.system(.body, design: .monospaced))
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                            }
                            Section("Header 值") {
                                TextField("值", text: $headerValue)
                                    .font(.system(.body, design: .monospaced))
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                            }
                        }
                        .navigationTitle(editingHeaderId == nil ? "添加请求头" : "编辑请求头")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("取消") { showHeaderSheet = false }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("保存") {
                                    saveHeader(for: p)
                                    showHeaderSheet = false
                                }
                                .disabled(headerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    }
                    .presentationDetents([.medium])
                }
                .sheet(isPresented: $showBodySheet) {
                    NavigationStack {
                        Form {
                            Section("参数 Key") {
                                TextField("如 frequency_penalty", text: $bodyKey)
                                    .font(.system(.body, design: .monospaced))
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                            }
                            Section("参数 Value") {
                                TextField("值 (支持文本或数字)", text: $bodyValue)
                                    .font(.system(.body, design: .monospaced))
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                            }
                        }
                        .navigationTitle(editingBodyId == nil ? "添加请求体参数" : "编辑请求体参数")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("取消") { showBodySheet = false }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("保存") {
                                    saveBody(for: p)
                                    showBodySheet = false
                                }
                                .disabled(bodyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    }
                    .presentationDetents([.medium])
                }
            }
        }
    }

    private func saveHeader(for p: Persona) {
        let name = headerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var updated = p
        if let targetId = editingHeaderId, let idx = updated.customHeaders.firstIndex(where: { $0.id == targetId }) {
            updated.customHeaders[idx] = PersonaCustomHeader(id: targetId, name: name, value: headerValue)
        } else {
            updated.customHeaders.append(PersonaCustomHeader(name: name, value: headerValue))
        }
        store.updatePersona(updated)
    }

    private func saveBody(for p: Persona) {
        let key = bodyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        var updated = p
        if let targetId = editingBodyId, let idx = updated.customBody.firstIndex(where: { $0.id == targetId }) {
            updated.customBody[idx] = PersonaCustomBodyItem(id: targetId, key: key, value: bodyValue)
        } else {
            updated.customBody.append(PersonaCustomBodyItem(key: key, value: bodyValue))
        }
        store.updatePersona(updated)
    }
}

// MARK: - 7. PersonaPromptSettingsView (提示词)
// 独立编辑 SOUL.md 人设设定与消息模板变量

struct PersonaPromptSettingsView: View {
    let personaId: String
    @ObservedObject var store = PersonaStore.shared

    @State private var soulText = ""
    @State private var templateText = "{{ message }}"
    @State private var appendTimeVal = false
    @State private var allowSystemPromptVal = false
    @State private var allowPromptInjectionVal = false
    @State private var isSaved = false

    private var persona: Persona? {
        store.personas.first { $0.id == personaId }
    }

    var body: some View {
        Group {
            if let p = persona {
                List {
                    Section {
                        TextEditor(text: $soulText)
                            .frame(minHeight: 260)
                            .font(.system(.body, design: .monospaced))
                    } header: {
                        HStack {
                            Text("核心系统人设 (SOUL.md)")
                            Spacer()
                            Text("\(soulText.count) 字")
                                .font(.caption)
                                .foregroundStyle(MinisTheme.secondaryText)
                        }
                    } footer: {
                        Text("定义助手的核心人设、口吻、底线与思考模式。保存后立即同步到大模型对话中。")
                    }

                    Section {
                        TextField("消息模板，如 {{ message }}", text: $templateText)
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onChange(of: templateText) { val in
                                var updated = p
                                updated.messageTemplate = val
                                store.updatePersona(updated)
                            }

                        Toggle("向用户消息追加当前时间", isOn: $appendTimeVal)
                            .onChange(of: appendTimeVal) { val in
                                var updated = p
                                updated.appendCurrentTimeToUserMessage = val
                                store.updatePersona(updated)
                            }

                        Toggle("允许会话级系统提示词覆盖", isOn: $allowSystemPromptVal)
                            .onChange(of: allowSystemPromptVal) { val in
                                var updated = p
                                updated.allowConversationSystemPrompt = val
                                store.updatePersona(updated)
                            }

                        Toggle("允许会话级提示词注入", isOn: $allowPromptInjectionVal)
                            .onChange(of: allowPromptInjectionVal) { val in
                                var updated = p
                                updated.allowConversationPromptInjection = val
                                store.updatePersona(updated)
                            }
                    } header: {
                        Text("消息模板与上下文注入")
                    }

                    Section {
                        Button {
                            saveSoul(for: p)
                        } label: {
                            HStack {
                                Spacer()
                                Image(systemName: isSaved ? "checkmark" : "square.and.arrow.down")
                                Text(isSaved ? "已保存" : "保存提示词修改")
                                    .font(.system(size: 15, weight: .semibold))
                                Spacer()
                            }
                            .foregroundStyle(isSaved ? Color.green : MinisThemeList.accent)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle("提示词")
                .navigationBarTitleDisplayMode(.inline)
                .onAppear {
                    loadFromPersona(p)
                }
            }
        }
    }

    private func loadFromPersona(_ p: Persona) {
        let url = SoulStore.fileURL(for: p.id)
        if let data = try? Data(contentsOf: url),
           let str = String(data: data, encoding: .utf8) {
            soulText = str
        } else if let soul = SoulStore.load(for: p.id) {
            soulText = SoulMDParser.serialize(soul)
        } else {
            soulText = ""
        }
        templateText = p.messageTemplate
        appendTimeVal = p.appendCurrentTimeToUserMessage
        allowSystemPromptVal = p.allowConversationSystemPrompt
        allowPromptInjectionVal = p.allowConversationPromptInjection
    }

    private func saveSoul(for p: Persona) {
        let url = SoulStore.fileURL(for: p.id)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? soulText.data(using: .utf8)?.write(to: url, options: .atomic)
        if store.currentPersonaID == p.id {
            SoulStore.refreshCache()
        }
        withAnimation {
            isSaved = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                isSaved = false
            }
        }
    }
}

// MARK: - 8. PersonaLocalToolsSettingsView (本地工具)
// 13 项原生工具开关与白名单

struct PersonaLocalToolsSettingsView: View {
    let personaId: String
    @ObservedObject var store = PersonaStore.shared

    private var persona: Persona? {
        store.personas.first { $0.id == personaId }
    }

    var body: some View {
        Group {
            if let p = persona {
                let enabledSet = Set(p.localToolIds ?? LocalToolRegistry.all.map(\.id))

                List {
                    Section {
                        ForEach(LocalToolRegistry.all) { tool in
                            Toggle(isOn: Binding(
                                get: { enabledSet.contains(tool.id) },
                                set: { isOn in
                                    var currentSet = enabledSet
                                    if isOn { currentSet.insert(tool.id) }
                                    else { currentSet.remove(tool.id) }
                                    var updated = p
                                    updated.localToolIds = Array(currentSet)
                                    store.updatePersona(updated)
                                }
                            )) {
                                HStack(spacing: 12) {
                                    Image(systemName: tool.icon)
                                        .font(.system(size: 18))
                                        .frame(width: 26)
                                        .foregroundStyle(MinisThemeList.accent)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tool.title)
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(ChatColors.primaryText)
                                        Text(tool.subtitle)
                                            .font(.system(size: 11))
                                            .foregroundStyle(MinisTheme.secondaryText)
                                            .lineLimit(2)
                                    }
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    } header: {
                        HStack {
                            Text("本地工具列表")
                            Spacer()
                            Button("全选") {
                                var updated = p
                                updated.localToolIds = LocalToolRegistry.all.map(\.id)
                                store.updatePersona(updated)
                            }
                            .font(.system(size: 12))
                            Text("·")
                            Button("全关") {
                                var updated = p
                                updated.localToolIds = []
                                store.updatePersona(updated)
                            }
                            .font(.system(size: 12))
                        }
                    } footer: {
                        Text("开启的工具将被注入给模型作为 function call 工具使用。未启用的工具模型将不可见。")
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle("本地工具")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}

// MARK: - 9. PersonaMemorySettingsView (记忆)
// 独立查看与编辑该人设的 GLOBAL.md 记忆与状态

struct PersonaMemorySettingsView: View {
    let personaId: String
    @ObservedObject var store = PersonaStore.shared

    @State private var globalMemoryText = ""
    @State private var isSaved = false

    private var persona: Persona? {
        store.personas.first { $0.id == personaId }
    }

    var body: some View {
        Group {
            if let p = persona {
                List {
                    Section {
                        TextEditor(text: $globalMemoryText)
                            .frame(minHeight: 280)
                            .font(.system(.body, design: .monospaced))
                    } header: {
                        HStack {
                            Text("长期全局记忆 (GLOBAL.md)")
                            Spacer()
                            Text("\(globalMemoryText.count) 字")
                                .font(.caption)
                                .foregroundStyle(MinisTheme.secondaryText)
                        }
                    } footer: {
                        Text("该人设跨会话持久保存的核心记忆与背景知识。")
                    }

                    Section {
                        Button {
                            saveGlobalMemory(for: p)
                        } label: {
                            HStack {
                                Spacer()
                                Image(systemName: isSaved ? "checkmark" : "square.and.arrow.down")
                                Text(isSaved ? "已保存" : "保存记忆修改")
                                    .font(.system(size: 15, weight: .semibold))
                                Spacer()
                            }
                            .foregroundStyle(isSaved ? Color.green : MinisThemeList.accent)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle("记忆")
                .navigationBarTitleDisplayMode(.inline)
                .onAppear {
                    loadGlobalMemory(for: p)
                }
            }
        }
    }

    private func loadGlobalMemory(for p: Persona) {
        let file = PersonaStore.memoryDir(for: p.id).appendingPathComponent("GLOBAL.md")
        if let data = try? Data(contentsOf: file), let str = String(data: data, encoding: .utf8) {
            globalMemoryText = str
        } else {
            globalMemoryText = "# \(p.name) 的全局记忆\n\n- 在此记录永久性知识与偏好。"
        }
    }

    private func saveGlobalMemory(for p: Persona) {
        let dir = PersonaStore.memoryDir(for: p.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("GLOBAL.md")
        try? globalMemoryText.data(using: .utf8)?.write(to: file, options: .atomic)
        withAnimation { isSaved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { isSaved = false }
        }
    }
}

// MARK: - 10. PersonaSkillsSettingsView (技能)
// 技能白名单

struct PersonaSkillsSettingsView: View {
    let personaId: String
    @ObservedObject var store = PersonaStore.shared
    @ObservedObject var skillStore = SkillStore.shared

    private var persona: Persona? {
        store.personas.first { $0.id == personaId }
    }

    var body: some View {
        Group {
            if let p = persona {
                let allSkills = skillStore.skills
                let isAll = p.skillIds == nil

                List {
                    Section {
                        Toggle("使用全部技能", isOn: Binding(
                            get: { isAll },
                            set: { on in
                                var updated = p
                                updated.skillIds = on ? nil : []
                                store.updatePersona(updated)
                            }
                        ))
                    } header: {
                        Text("通用规则")
                    } footer: {
                        Text("开启后新安装的技能将自动对该人设生效。关闭后可手动勾选白名单。")
                    }

                    if !isAll {
                        Section("技能白名单") {
                            ForEach(allSkills) { skill in
                                let isEnabled = (p.skillIds ?? []).contains(skill.id)
                                Toggle(skill.name, isOn: Binding(
                                    get: { isEnabled },
                                    set: { on in
                                        toggleSkill(skill.id, enabled: on, persona: p)
                                    }
                                ))
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle("技能")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private func toggleSkill(_ skillId: String, enabled: Bool, persona: Persona) {
        var set = Set(persona.skillIds ?? [])
        if enabled { set.insert(skillId) }
        else { set.remove(skillId) }
        var updated = persona
        updated.skillIds = Array(set)
        store.updatePersona(updated)
    }
}

// MARK: - 11. PersonaMcpSettingsView (MCP)
// MCP 服务器白名单

struct PersonaMcpSettingsView: View {
    let personaId: String
    @ObservedObject var store = PersonaStore.shared
    @ObservedObject var mcpStore = MCPStore.shared

    private var persona: Persona? {
        store.personas.first { $0.id == personaId }
    }

    var body: some View {
        Group {
            if let p = persona {
                let allServers = mcpStore.servers
                let isAll = p.mcpServerIds == nil

                List {
                    Section {
                        Toggle("使用全部 MCP 服务", isOn: Binding(
                            get: { isAll },
                            set: { on in
                                var updated = p
                                updated.mcpServerIds = on ? nil : []
                                store.updatePersona(updated)
                            }
                        ))
                    } header: {
                        Text("通用规则")
                    } footer: {
                        Text("开启后所有已配置的 MCP 服务器均对该人设生效。关闭后可单独勾选可用服务器。")
                    }

                    if !isAll {
                        Section("MCP 服务器白名单") {
                            ForEach(allServers) { server in
                                let isEnabled = (p.mcpServerIds ?? []).contains(server.id)
                                Toggle(server.id, isOn: Binding(
                                    get: { isEnabled },
                                    set: { on in
                                        toggleMcp(server.id, enabled: on, persona: p)
                                    }
                                ))
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle("MCP")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private func toggleMcp(_ serverId: String, enabled: Bool, persona: Persona) {
        var set = Set(persona.mcpServerIds ?? [])
        if enabled { set.insert(serverId) }
        else { set.remove(serverId) }
        var updated = persona
        updated.mcpServerIds = Array(set)
        store.updatePersona(updated)
    }
}
