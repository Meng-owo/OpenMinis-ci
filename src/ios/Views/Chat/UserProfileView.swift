import SwiftUI
import PhotosUI
import UIKit

/// [B28 R11/R13] 通讯录里「我自己」的编辑页。
///
/// 这不是聊天对象，是用户本人的档案：AI 每次开口都会读到它。
/// 存的一直是 memory/personas/me/SOUL.md 原文，不另开数据库——
/// 人和 AI 改的是同一份文件，谁后写的就以谁为准。
///
/// [R13 卡片流] 从系统 List 改成自绘卡片流：
/// 圆角、留白、淡阴影、入场动画，配色全部取主题变量（跟着装扮页走），
/// 不写死任何颜色值。
struct UserProfileView: View {
    @ObservedObject private var store = PersonaStore.shared
    @ObservedObject private var studio = AppearanceStudio.shared
    @Environment(\.dismiss) private var dismiss

    @State private var draft: String = ""
    @State private var nameDraft: String = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var loadedBody: String = ""
    @State private var appeared = false
    @State private var showBodyDrawer = false
    @State private var showPreviewDrawer = false

    private let profileId = PersonaStore.userProfilePersonaID

    /// SOUL.md 被人或 AI 改过之后，让所有读人设的地方重新拉一遍。
    @MainActor
    static func publishProfileChange() {
        NotificationCenter.default.post(name: .personaDidChange, object: nil)
        // 档案变了，桌面上的小组件也要跟着换字。
        WidgetProfileBridge.refresh()
    }

    private var persona: Persona? {
        store.personas.first { $0.id == profileId }
    }

    /// 称呼：档案里的「怎么称呼」优先，界面文案才跟着变。
    private var addressingName: String {
        let n = SystemPromptBuilder.userProfileAddressingName(for: profileId)
        return n.isEmpty ? (persona?.name ?? "我自己") : n
    }

    var hasUnsavedChanges: Bool { draft != loadedBody }

    // MARK: - 主题

    private var accent: Color { studio.color(.accent, scope: .chat) }
    private var cardFill: Color {
        studio.color(.surface, scope: .chat).opacity(max(studio.surfaceOpacity, 0.55))
    }
    private var hairline: Color { studio.color(.border, scope: .chat).opacity(0.5) }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                heroCard
                nameCard
                contentCard
                injectionCard
                previewCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
            // 入场：整页从下往上 8pt 淡进来。只跑一次，不跟滚动抢。
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 8)
            .animation(.spring(response: 0.42, dampingFraction: 0.86), value: appeared)
        }
        .scrollIndicators(.hidden)
        .background(studio.color(.canvas, scope: .chat).ignoresSafeArea())
        .navigationTitle(addressingName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            reload()
            appeared = true
        }
        .onDisappear { commitName() }
        // AI 是用 shell 直接写 SOUL.md 的，不会走 SoulStore.save，也就没有通知。
        // 回到前台就重读一次，别让她看着旧内容。
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if !hasUnsavedChanges { reload() }
        }
        // 小抽屉：从底部滑出、带拖拽条，不整页推走——她要看的是"翻开一页"，不是"离开"。
        .sheet(isPresented: $showBodyDrawer) {
            NavigationStack {
                UserProfileBodyEditor(bodyText: $draft, original: loadedBody, personaId: profileId)
                    .onAppear { reload() }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showPreviewDrawer) {
            NavigationStack {
                UserProfilePreview(personaId: profileId)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: photoItem) { item in
            guard let item else { return }
            guard let p = persona else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = ThumbnailCache.downsampledImage(from: data, maxEdge: 512) else { return }
                let name = SoulIconImage.storedName(prefix: "persona", id: profileId)
                if case .success(let path) = SoulIconImage.store(image, named: name) {
                    await MainActor.run {
                        var updated = p
                        updated.avatar = path
                        store.updatePersona(updated)
                        Self.publishProfileChange()
                    }
                }
            }
        }
    }

    // MARK: - 卡片

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    ZStack(alignment: .bottomTrailing) {
                        PersonaAvatarView(iconRef: persona?.avatar, size: 72)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(accent.opacity(0.35), lineWidth: 1.5))
                        Image(systemName: "camera.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(Circle().fill(accent))
                            .offset(x: 2, y: 2)
                    }
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    Text(addressingName)
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(ChatColors.primaryText)
                    Text(AppLocalized("点头像换图"))
                        .font(.system(size: 11))
                        .foregroundStyle(ChatColors.secondaryText)
                }
                Spacer(minLength: 0)
            }

            Text(AppLocalized("这份档案描述的是你，不是任何一只 AI。你写进去的东西，AI 每次对话都会读到；它也可以在长期互动里补充。"))
                .font(.system(size: 12))
                .lineSpacing(2)
                .foregroundStyle(ChatColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(accent.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 4)
    }

    private var nameCard: some View {
        card(title: AppLocalized("叫法"), footnote: AppLocalized("填了之后，界面里的文案和 AI 对你的叫法都跟着变。")) {
            HStack(spacing: 10) {
                Text(AppLocalized("怎么称呼你"))
                    .font(.system(size: 14))
                    .foregroundStyle(ChatColors.primaryText)
                Spacer(minLength: 8)
                TextField(AppLocalized("留空则用「你」"), text: $nameDraft)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 14))
                    .submitLabel(.done)
                    .onSubmit { commitName() }
            }
        }
    }

    private var contentCard: some View {
        card(title: AppLocalized("内容"), footnote: AppLocalized("按小节写，一行一条。冒号后面留空的条目不会进模型的上下文，所以不必删模板。")) {
            Button {
                showBodyDrawer = true
            } label: {
                row(icon: "person.text.rectangle", title: AppLocalized("档案内容"), detail: fieldSummary())
            }
            .buttonStyle(.plain)

            Divider().opacity(0.4)

            Button {
                showPreviewDrawer = true
            } label: {
                row(icon: "eye.fill", title: AppLocalized("注入预览"), detail: AppLocalized("AI 实际读到什么"))
            }
            .buttonStyle(.plain)
        }
    }

    private var injectionCard: some View {
        card(title: AppLocalized("注入范围"), footnote: AppLocalized("关掉后 NSFW 那一节完全不进模型——有些敏感模型一看尺度描写就整段拒答。其余内容照常注入。")) {
            Toggle(isOn: Binding(
                get: { SystemPromptBuilder.userProfileNSFWInjectionEnabled },
                set: { SystemPromptBuilder.userProfileNSFWInjectionEnabled = $0 }
            )) {
                Text(AppLocalized("把 NSFW 小节给 AI 看"))
                    .font(.system(size: 14))
                    .foregroundStyle(ChatColors.primaryText)
            }
            .tint(accent)
        }
    }

    private var previewCard: some View {
        card(title: AppLocalized("小节进度"), footnote: nil) {
            let stats = sectionStats()
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: Double(stats.filled), total: Double(max(stats.total, 1)))
                    .tint(accent)
                Text(String(format: AppLocalized("已填 %d / %d 节"), stats.filled, stats.total))
                    .font(.system(size: 12))
                    .foregroundStyle(ChatColors.secondaryText)
            }
        }
    }

    // MARK: - 卡片外壳

    @ViewBuilder
    private func card<Content: View>(title: String, footnote: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
                .textCase(nil)
            content()
            if let footnote {
                Text(footnote)
                    .font(.system(size: 11))
                    .lineSpacing(1.5)
                    .foregroundStyle(ChatColors.secondaryText.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(hairline, lineWidth: 0.7)
        )
    }

    private func row(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            SettingsRowIcon(icon: icon)
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(ChatColors.primaryText)
            Spacer(minLength: 8)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(ChatColors.secondaryText)
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ChatColors.secondaryText.opacity(0.6))
        }
        .contentShape(Rectangle())
    }

    // MARK: - 数据

    /// 落盘「怎么称呼」。空串也算一次有效修改（清掉叫法）。
    private func commitName() {
        let current = SystemPromptBuilder.userProfileAddressingName(for: profileId)
        guard nameDraft != current else { return }
        setFieldValue("怎么称呼", to: nameDraft.trimmingCharacters(in: .whitespaces))
    }

    private func reload() {
        let file = SoulStore.load(for: profileId)
        let text = (file?.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        draft = text.isEmpty ? PersonaStore.userProfileSoulTemplate() : text
        loadedBody = draft
        nameDraft = SystemPromptBuilder.userProfileAddressingName(for: profileId)
    }

    /// 小节填写进度。
    private func sectionStats() -> (filled: Int, total: Int) {
        guard let body = SoulStore.load(for: profileId)?.body else { return (0, 1) }
        let titles = body.components(separatedBy: "\n").filter { $0.hasPrefix("# ") }
        let total = max(titles.count, 1)
        let filled = SystemPromptBuilder.userProfileSection(for: profileId)
            .components(separatedBy: "## ")
            .filter { $0.count > 1 }
            .count
        return (filled, total)
    }

    /// 给"档案内容"那行当副标题。
    private func fieldSummary() -> String {
        let file = SoulStore.load(for: profileId)
        guard let text = file?.body, !text.isEmpty else { return AppLocalized("未填写") }
        let filled = SystemPromptBuilder.userProfileSection(from: file)
        let sections = filled.components(separatedBy: "## ").filter { $0.count > 1 }.count
        return sections > 0 ? String(format: AppLocalized("已填 %d 节"), sections) : AppLocalized("未填写")
    }

    /// 改「怎么称呼：」那一行。找不到就补在「# 身份」下面。
    private func setFieldValue(_ key: String, to value: String) {
        let file = SoulStore.load(for: profileId)
        var text = file?.body ?? PersonaStore.userProfileSoulTemplate()
        var lines = text.components(separatedBy: "\n")
        var replaced = false
        for i in lines.indices {
            if lines[i].contains(key), lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("-") {
                lines[i] = "- \(key)：\(value)"
                replaced = true
                break
            }
        }
        if !replaced, let idx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "# 身份" }) {
            lines.insert("- \(key)：\(value)", at: idx + 1)
        } else if !replaced {
            lines.append("- \(key)：\(value)")
        }
        let merged = lines.joined(separator: "\n")
        try? merged.write(to: SoulStore.fileURL(for: profileId), atomically: true, encoding: .utf8)
        loadedBody = merged
        draft = merged
        // 先落盘再广播，否则监听方读到的还是旧文件。
        Self.publishProfileChange()
    }
}

/// 档案正文编辑器。原文进原文出，不做结构化拆解——
/// 结构由小节标题约定，AI 和她写的是同一个文件。
private struct UserProfileBodyEditor: View {
    @Binding var bodyText: String
    let original: String
    let personaId: String
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var studio = AppearanceStudio.shared

    var body: some View {
        TextEditor(text: $bodyText)
            .font(.system(size: 13, design: .monospaced))
            .scrollContentBackground(.hidden)
            .background(studio.color(.canvas, scope: .chat))
            .padding(.horizontal, 12)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(bodyText == original ? AppLocalized("完成") : AppLocalized("保存")) {
                        save()
                    }
                    .disabled(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle(AppLocalized("我的档案"))
            .navigationBarTitleDisplayMode(.inline)
    }

    private func save() {
        let text = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            try text.write(to: SoulStore.fileURL(for: personaId), atomically: true, encoding: .utf8)
        } catch {
            MinisToast.show(AppLocalized("保存失败"))
            return
        }
        bodyText = text
        MinisToast.show(AppLocalized("已保存，下次对话开始生效"))
        dismiss()
    }
}

/// 注入预览：把她真正会喂给模型的那段渲染出来。
private struct UserProfilePreview: View {
    let personaId: String
    @ObservedObject private var studio = AppearanceStudio.shared

    var body: some View {
        ScrollView {
            let section = SystemPromptBuilder.userProfileSection(for: personaId)
            Text(section.isEmpty ? AppLocalized("档案还是空的，暂时不会给 AI 加任何内容。") : section)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(16)
        }
        .background(studio.color(.canvas, scope: .chat).ignoresSafeArea())
        .navigationTitle(AppLocalized("AI 实际读到什么"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
