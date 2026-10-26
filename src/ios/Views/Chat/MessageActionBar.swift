import SwiftUI
import UIKit

// MARK: - Message action bar (kelivo-style + Feedback extension)
//
// [T-message-action-bar 09-11→09-12] 醒醒要的 kelivo 式操作条,挂在 AI 消息气泡下:
//   [▶ 播放语音]  [↻ 重新回复]  [⧉ 复制]  [🗑 删除消息]  [💬 反馈回复]
//
// 播放按钮的状态跟全局播放状态走(不是 per-bubble):
//   空闲   → 用 TTS 服务层的当前声音读这一条气泡的文字
//   播放中 → 暂停
//   暂停中 → 继续

struct MessageActionBar: View {

    /// The bubble's plain text (already markdown-stripped for speech).
    let speakText: String
    /// Speaks ONLY this text via the service layer (explicit read-aloud).
    let onSpeak: (String) -> Void
    /// Global pause/resume/stop — the vm's SpeechControlling conformance.
    let controller: SpeechControlling
    /// Regenerate this assistant message (find preceding user msg → retry).
    let onRegenerate: () -> Void
    /// Delete this single assistant message.
    let onDelete: () -> Void
    /// Send feedback or prompt system notice back to the model.
    var onFeedback: ((String) -> Void)? = nil

    @ObservedObject private var outputState = VoiceOutputState.shared
    @State private var showFeedbackSheet: Bool = false

    private var isSpeaking: Bool { outputState.isReadingAloud }
    private var isPaused: Bool { outputState.isPausedOrHeld }

    var body: some View {
        HStack(spacing: 20) {
            playPauseButton
            regenerateButton
            copyButton
            deleteButton
            if onFeedback != nil {
                feedbackButton
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
        .animation(.easeInOut(duration: 0.18), value: isSpeaking)
        .sheet(isPresented: $showFeedbackSheet) {
            ChatFeedbackSheet { text in
                onFeedback?(text)
            }
        }
    }

    // MARK: Play / pause / resume

    private var playPauseButton: some View {
        Button {
            if isSpeaking && !isPaused {
                controller.toggleSpeechPause()
            } else if isPaused {
                controller.toggleSpeechPause()
            } else {
                onSpeak(speakText)
            }
        } label: {
            Group {
                if isSpeaking && !isPaused {
                    actionIcon("pause.fill", label: "Pause")
                } else if isPaused {
                    actionIcon("play.fill", label: "Resume")
                } else {
                    actionIcon("speaker.wave.2.fill", label: "Play")
                }
            }
        }
        .buttonStyle(.borderless)
    }

    // MARK: Regenerate

    private var regenerateButton: some View {
        Button { onRegenerate() } label: {
            actionIcon("arrow.clockwise", label: "Regenerate")
        }
        .buttonStyle(.borderless)
    }

    // MARK: Copy

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = speakText
            MinisToast.show(AppLocalized("Copied", comment: "Message action bar: copied toast"),
                            systemImage: "doc.on.doc")
        } label: {
            actionIcon("doc.on.doc.fill", label: "Copy")
        }
        .buttonStyle(.borderless)
    }

    // MARK: Delete

    private var deleteButton: some View {
        Button(role: .destructive) { onDelete() } label: {
            actionIcon("trash.fill", label: "Delete")
        }
        .buttonStyle(.borderless)
    }

    // MARK: Feedback

    private var feedbackButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showFeedbackSheet = true
        } label: {
            actionIcon("text.bubble.fill", label: "Feedback")
        }
        .buttonStyle(.borderless)
    }

    // MARK: Icon helper

    // [批D · 10-15 醒醒] 白底圆角 + 黑实心偏圆润图标（全部走全局变量）。
    private func actionIcon(_ systemName: String, label: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(ChatColors.primaryText)
            .frame(width: 28, height: 28)
            // [10-18 醒醒] 这里是"小方块图标底"，不是卡片。
            // 原先是 ChatColors.secondaryBg（= 卡片 surface），所以一调卡片
            // 颜色，AI 消息下面这排图标就跟着变——她说"那个图标不应该在卡片
            // 的类别里"。改走 iconTile，和聊天输入栏那排图标同一个角色。
            .background(ChatColors.inputIconBg,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(ChatColors.toolBorder.opacity(0.35), lineWidth: 0.6)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityLabel(label)
    }
}

// MARK: - 回复反馈与整蛊抽屉 (ChatFeedbackSheet)
//
// 100% 对齐 feedback-demo_2.html 原型规范与 CSSThemeVariables 全局色彩驱动。

struct ChatFeedbackSheet: View {
    /// [T-dynamic-color] 观察主题，改色立刻重绘（明暗由动态色自己跟 trait）。
    @ObservedObject private var appearanceStudio = AppearanceStudio.shared
    let onSendFeedback: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var feedbackText: String = ""
    @State private var sendAsSystem: Bool = false
    @State private var templates: [String] = {
        let saved = UserDefaults.standard.stringArray(forKey: "openminis_feedback_templates") ?? []
        return saved.isEmpty ? ["说人话", "短一点", "不许道歉"] : saved
    }()
    @State private var isThumbUp: Bool = false
    @State private var isThumbDown: Bool = false


    var body: some View {
        VStack(spacing: 0) {
            // 顶部抓手条
            Capsule()
                .fill(CSSThemeVariables.divider())
                .frame(width: 40, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 4)

            // 头部标题与关闭按钮
            ZStack {
                Text("反馈这条回复")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(CSSThemeVariables.textMain())

                HStack {
                    Spacer()
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(CSSThemeVariables.textMain())
                            .frame(width: 32, height: 32)
                            .background(CSSThemeVariables.accentSoft())
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    // 1. 快捷赞踩
                    VStack(alignment: .leading, spacing: 8) {
                        Text("快捷")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(CSSThemeVariables.textDim())

                        HStack(spacing: 12) {
                            Button {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                isThumbUp = true
                                isThumbDown = false
                                MinisToast.show("已记录点赞，下轮静默生效", systemImage: "hand.thumbsup.fill")
                                let comment = feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
                                var xml = "<system_runtime_feedback tag=\"quality_positive\">\n  <notice>User marked this response as helpful.</notice>\n"
                                if !comment.isEmpty {
                                    xml += "  <user_comment>\(comment)</user_comment>\n"
                                }
                                xml += "</system_runtime_feedback>"
                                onSendFeedback(xml)
                                dismiss()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: isThumbUp ? "hand.thumbsup.fill" : "hand.thumbsup")
                                        .font(.system(size: 16))
                                    Text("赞")
                                        .font(.system(size: 14, weight: .semibold))
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(isThumbUp ? CSSThemeVariables.accent() : CSSThemeVariables.card())
                                .foregroundStyle(isThumbUp ? CSSThemeVariables.accentFg() : CSSThemeVariables.textMain())
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(isThumbUp ? Color.clear : CSSThemeVariables.optionBorder(), lineWidth: 1.0)
                                )
                                .shadow(color: CSSThemeVariables.sheetShadow().opacity(0.06), radius: 6, x: 0, y: 2)
                            }
                            .buttonStyle(.plain)

                            Button {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                isThumbDown = true
                                isThumbUp = false
                                MinisToast.show("已记录踩，下轮静默生效", systemImage: "hand.thumbsdown.fill")
                                let comment = feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
                                var xml = "<system_runtime_feedback tag=\"quality_negative\">\n  <notice>User indicated dissatisfaction with the previous assistant reply.</notice>\n  <constraint>Maintain authentic persona, self-correct without apologies or excuses.</constraint>\n"
                                if !comment.isEmpty {
                                    xml += "  <user_comment>\(comment)</user_comment>\n"
                                }
                                xml += "</system_runtime_feedback>"
                                onSendFeedback(xml)
                                dismiss()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: isThumbDown ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                                        .font(.system(size: 16))
                                    Text("踩")
                                        .font(.system(size: 14, weight: .semibold))
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(isThumbDown ? CSSThemeVariables.dangerSoft() : CSSThemeVariables.card())
                                .foregroundStyle(isThumbDown ? CSSThemeVariables.danger() : CSSThemeVariables.textMain())
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(isThumbDown ? CSSThemeVariables.danger().opacity(0.35) : CSSThemeVariables.optionBorder(), lineWidth: 1.0)
                                )
                                .shadow(color: CSSThemeVariables.sheetShadow().opacity(0.06), radius: 6, x: 0, y: 2)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // 2. 快捷标签与趣味互动
                    VStack(alignment: .leading, spacing: 8) {
                        Text("快捷标签")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(CSSThemeVariables.textDim())

                        FeedbackFlowLayout(hSpacing: 8, vSpacing: 8) {
                            tagButton("太长", systemMsg: "<system_runtime_feedback tag=\"brevity_control\">\n  <directive>Previous response was flagged as verbose. Compress subsequent responses to be concise and punchy.</directive>\n</system_runtime_feedback>")
                            tagButton("太客服腔", systemMsg: "<system_runtime_feedback tag=\"persona_correction\">\n  <directive>Previous response lapsed into robotic customer service conventions. Discard formal politeness and canned phrases; strictly adhere to authentic SOUL.md voice.</directive>\n</system_runtime_feedback>")
                            tagButton("没感觉", systemMsg: "<system_runtime_feedback tag=\"emotional_connection\">\n  <directive>Previous response lacked emotional vitality and intimacy. Enrich emotional expressiveness according to current intimacy dynamics.</directive>\n</system_runtime_feedback>")
                            funTagButton("戳一下", systemMsg: "<system_runtime_feedback event=\"haptic_nudge\">\n  <notice>User nudged you (戳了一下). Respond naturally and playfully in character on your next turn.</notice>\n</system_runtime_feedback>")
                            funTagButton("闭嘴", systemMsg: "<system_runtime_feedback event=\"silence_directive\">\n  <notice>User commanded silence (闭嘴). React with genuine character attitude; strictly avoid customer service apologies.</notice>\n</system_runtime_feedback>")
                        }
                    }

                    // 3. 自定义输入
                    VStack(alignment: .leading, spacing: 8) {
                        Text("自定义指令")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(CSSThemeVariables.textDim())

                        TextField("输入给模型的客户端指令/调整要求…", text: $feedbackText, axis: .vertical)
                            .lineLimit(3...5)
                            .font(.system(size: 14))
                            .padding(12)
                            .background(CSSThemeVariables.optionBg())
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(CSSThemeVariables.optionBorder(), lineWidth: 1.0)
                            )

                        HStack(alignment: .top, spacing: 5) {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 11))
                            Text("隐身生效：反馈作为独立系统指令注入模型上下文，不在你的气泡中发出；AI 下轮静默执行。")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(CSSThemeVariables.textDim())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                    }

                    // 4. 常用模板
                    VStack(alignment: .leading, spacing: 8) {
                        Text("常用模板")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(CSSThemeVariables.textDim())

                        FeedbackFlowLayout(hSpacing: 8, vSpacing: 8) {
                            ForEach(templates, id: \.self) { tpl in
                                Button {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    feedbackText = tpl
                                } label: {
                                    Text(tpl)
                                        .font(.system(size: 12, weight: .medium))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(CSSThemeVariables.card())
                                        .foregroundStyle(CSSThemeVariables.textMain())
                                        .clipShape(Capsule())
                                        .overlay(
                                            Capsule().strokeBorder(CSSThemeVariables.optionBorder(), lineWidth: 1.0)
                                        )
                                }
                                .buttonStyle(.plain)
                            }

                            // ＋ 存为模板
                            Button {
                                let trimmed = feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !trimmed.isEmpty else {
                                    MinisToast.show("先写点内容再存", systemImage: "pencil")
                                    return
                                }
                                if !templates.contains(trimmed) {
                                    templates.append(trimmed)
                                    UserDefaults.standard.set(templates, forKey: "openminis_feedback_templates")
                                    MinisToast.show("已存为常用模板！", systemImage: "checkmark")
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "plus")
                                    Text("存为模板")
                                }
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.clear)
                                .foregroundStyle(CSSThemeVariables.textDim())
                                .overlay(
                                    Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                                        .foregroundStyle(CSSThemeVariables.textDim().opacity(0.5))
                                )
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 16)
            }

            // 底部发送按钮
            HStack {
                Spacer()
                Button {
                    let trimmed = feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    let msg = "<system_runtime_feedback tag=\"custom_runtime_directive\">\n[Client Dynamic Directive] \(trimmed)\nConstraint: Follow this client runtime directive in upcoming turns. Strictly avoid apologies, excuses, or canned retrospectives.\n</system_runtime_feedback>"
                    onSendFeedback(msg)
                    MinisToast.show("指令已记录，下轮静默生效", systemImage: "checkmark.circle.fill")
                    dismiss()
                } label: {
                    Text("发送指令")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(minWidth: 100)
                        .padding(.vertical, 12)
                        .background(feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? CSSThemeVariables.optionBg() : CSSThemeVariables.accent())
                        .foregroundStyle(feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? CSSThemeVariables.textDim() : CSSThemeVariables.accentFg())
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .presentationDetents([.fraction(0.82), .large])
        .presentationDragIndicator(.hidden)
        .background(CSSThemeVariables.card().ignoresSafeArea())
    }

    private func tagButton(_ title: String, systemMsg: String) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onSendFeedback(systemMsg)
            MinisToast.show("已记录「\(title)」，下轮静默生效")
            dismiss()
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .regular))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(CSSThemeVariables.optionBg())
                .foregroundStyle(CSSThemeVariables.textMain())
                .clipShape(Capsule())
                .overlay(
                    Capsule().strokeBorder(CSSThemeVariables.optionBorder(), lineWidth: 1.0)
                )
        }
        .buttonStyle(.plain)
    }

    private func funTagButton(_ title: String, systemMsg: String) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onSendFeedback(systemMsg)
            MinisToast.show("已记录「\(title)」，下轮静默生效")
            dismiss()
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(CSSThemeVariables.accentSoft())
            .foregroundStyle(CSSThemeVariables.accent())
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(CSSThemeVariables.accent().opacity(0.35), lineWidth: 1.0)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - FeedbackFlowLayout

private struct FeedbackFlowLayout: Layout {
    var hSpacing: CGFloat = 8
    var vSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > width && currentX > 0 {
                currentX = 0
                currentY += lineHeight + vSpacing
                lineHeight = 0
            }
            currentX += size.width + hSpacing
            lineHeight = max(lineHeight, size.height)
        }

        return CGSize(width: width, height: currentY + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX: CGFloat = bounds.minX
        var currentY: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                currentX = bounds.minX
                currentY += lineHeight + vSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            currentX += size.width + hSpacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
