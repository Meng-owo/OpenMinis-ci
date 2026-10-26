import SwiftUI

// MARK: - 视觉小说模式
//
// [10-19 醒醒] 她选了"两个都做"，所以两种模式都实现：
//
// 1. **立绘（stage）** —— 照 SillyTavern 的 `waifuMode`。查过源码：
//    `mobile-styles.css:447` 是 `body.waifuMode #sheld { height: 40dvh;
//    top: 60dvh }`，`expression-holder` 撑满 `100vh`。也就是**全屏立绘 +
//    聊天窗压到底部 40%**，上滑可展开。
//
// 2. **对话框（galgame）** —— 她原话描述的那种：底部半透明对话框，
//    头像挂左边，一句一句推台词。ST 里没有这个，是我按 Galgame 惯例做的。
//
// 两者都**不改消息数据**，只在渲染层叠一层。关掉就回到正常聊天。

// MARK: - 立绘层

/// 全屏角色立绘。铺在消息列表后面。
struct NovelStageBackdrop: View {
    let personaID: String?
    @ObservedObject private var studio = AppearanceStudio.shared

    /// [B28 A-1] 立绘改成落文件，不再从 pack 的 base64 解码。
    /// 老 pack 里的整张 base64 在 `loadStoredPackUnlocked` 里已经搬成文件了。
    private var artImage: UIImage? {
        studio.characterArtImage()
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                if let art = artImage {
                    // 有全身图：铺满宽度，底部对齐，顶部渐隐进背景
                    Image(uiImage: art)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width)
                        .frame(maxHeight: geo.size.height, alignment: .bottom)
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .black, location: 0.18),
                                    .init(color: .black, location: 1),
                                ],
                                startPoint: .top, endPoint: .bottom)
                        )
                } else {
                    // 没全身图：用头像放大当占位，比空白好看。
                    // 用 SoulIconView 而不是 PersonAvatarView —— 后者是方的，
                    // 立绘要竖的。
                    let icon = SoulStore.displayIcon(for: personaID ?? PersonaStore.currentID()) ?? ""
                    Group {
                        if SoulIconImage.isImageReference(icon) {
                            SoulIconView(icon: icon,
                                         size: geo.size.width * 0.55,
                                         shape: .rectangle)
                        } else {
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(MinisTheme.surface.opacity(0.6))
                                .frame(width: geo.size.width * 0.55,
                                       height: geo.size.height * 0.45)
                                .overlay {
                                    Image(systemName: "person.crop.rectangle")
                                        .font(.system(size: 44, weight: .light))
                                        .foregroundStyle(MinisTheme.secondaryText.opacity(0.5))
                                }
                        }
                    }
                    .blur(radius: 1.2)
                    .opacity(0.88)
                    .padding(.bottom, geo.size.height * 0.18)
                    .overlay(alignment: .bottom) {
                        Text("在「装扮 → 气泡」里换一张全身立绘")
                            .font(.caption2)
                            .foregroundStyle(MinisTheme.secondaryText)
                            .padding(.bottom, 4)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Galgame 对话框

/// 底部半透明对话框。一次显示一条助手消息，点一下推下一条。
struct NovelDialogueBox: View {
    let messages: [ChatMessage]
    let personaID: String?
    @State private var cursor: Int = 0
    @State private var appeared = false

    /// 只挑有正文的助手消息。工具块、系统提示都跳过——那些不是"台词"。
    private var lines: [ChatMessage] {
        messages.filter { msg in
            guard msg.role == .assistant else { return false }
            return msg.blocks.contains { block in
                if case .text = block.kind { return !block.content.isEmpty }
                return false
            }
        }
    }

    private var current: ChatMessage? {
        guard !lines.isEmpty else { return nil }
        return lines[min(cursor, lines.count - 1)]
    }

    private var currentText: String {
        guard let msg = current else { return "" }
        return msg.blocks.compactMap { block -> String? in
            if case .text = block.kind { return block.content }
            return nil
        }.joined(separator: "\n\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let msg = current {
                HStack(alignment: .top, spacing: 12) {
                    // 头像挂左边
                    PersonAvatarView(kind: .assistant, size: 44, personaID: personaID)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            AssistantSoulName(personaId: personaID)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(ChatColors.primaryText)
                            Spacer()
                            if lines.count > 1 {
                                Text("\(min(cursor, lines.count - 1) + 1) / \(lines.count)")
                                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                                    .foregroundStyle(ChatColors.secondaryText)
                            }
                        }

                        Text(currentText)
                            .font(MinisThemeShape.fontFamily.font(size: FontSettings.shared.scaledMessage(16)))
                            .foregroundStyle(ChatColors.primaryText)
                            .lineSpacing(4)
                            .lineLimit(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .opacity(appeared ? 1 : 0)
                            .animation(.easeOut(duration: 0.18), value: appeared)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            } else {
                Text("还没有台词")
                    .font(.system(size: 15))
                    .foregroundStyle(ChatColors.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 28)
            }

            // 底部提示条：点一下往下推
            if lines.count > 0 {
                HStack(spacing: 6) {
                    Spacer()
                    Image(systemName: cursor + 1 < lines.count ? "chevron.down" : "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                    Text(cursor + 1 < lines.count ? "点一下继续" : "已经到最后")
                        .font(.system(size: 11))
                    Spacer()
                }
                .foregroundStyle(ChatColors.secondaryText.opacity(0.7))
                .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            // 半透明底 + 材质，压在立绘上不挡人
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                MinisTheme.surface.opacity(0.72)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(MinisTheme.border.opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            advance()
        }
        .onChange(of: lines.count) { count in
            // 新消息来了就跳到最新那条
            if count > 0 { cursor = count - 1; replay() }
        }
        .onAppear {
            cursor = max(0, lines.count - 1)
            replay()
        }
    }

    private func advance() {
        guard cursor + 1 < lines.count else { return }
        cursor += 1
        replay()
    }

    private func replay() {
        appeared = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            appeared = true
        }
    }
}
