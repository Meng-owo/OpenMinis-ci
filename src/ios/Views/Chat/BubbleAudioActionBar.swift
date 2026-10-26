import SwiftUI
import Combine

// MARK: - [T-action-bar-play-bubble 09-13] Voice-bubble action bar
//
// 醒醒 5: AI Voice Replies 的回复自带 wx 式语音气泡，气泡里的音频文件就是
// 这条回复的"语音形态"。操作条的播放键对这种回复播放气泡文件本身——
//   空闲   → GlobalAudioPlayer.play(气泡文件)（同一个播放器气泡 tap 也走它，
//            两处入口共享进度/暂停态，点操作条再点气泡不会重头播）
//   播放中 → 暂停（AVAudioPlayer.pause，保留进度）
//   暂停中 → 继续（从暂停处接着播）
// 不走 TTS 重合成：气泡已经用她配置的声音合成过一次，重合成=第二次厂商
// 调用+时长对不上气泡上的秒数。
//
// 其他三个键（重新回答/复制/删除）与 MessageActionBar 完全同款。

struct BubbleAudioActionBar: View {

    /// The voice bubble's audio file (already synthesized with the configured voice).
    let fileURL: URL
    let onRegenerate: () -> Void
    let onDelete: () -> Void
    /// Text fallback (bubble file missing on disk) + the copy button source.
    let speakText: String
    let onSpeak: (String) -> Void
    var onFeedback: ((String) -> Void)? = nil

    @ObservedObject private var player = GlobalAudioPlayer.shared
    @State private var showFeedbackSheet: Bool = false

    private var isThisFilePlaying: Bool {
        player.isPlaying && player.activeFileURL == fileURL
    }
    private var isThisFilePaused: Bool {
        !player.isPlaying && player.isLoaded && player.activeFileURL == fileURL
    }

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
        .animation(.easeInOut(duration: 0.18), value: isThisFilePlaying)
        .sheet(isPresented: $showFeedbackSheet) {
            ChatFeedbackSheet { text in
                onFeedback?(text)
            }
        }
    }

    // MARK: Play / pause / resume

    private var playPauseButton: some View {
        Button {
            if isThisFilePlaying {
                // 播放中 → 暂停
                player.togglePlayPause()
            } else if isThisFilePaused {
                // 暂停中 → 继续（GlobalAudioPlayer.play 同 URL = resume）
                player.togglePlayPause()
            } else if FileManager.default.fileExists(atPath: fileURL.path) {
                // 空闲 → 播气泡自己的文件
                player.play(url: fileURL)
            } else {
                // 气泡文件不在了（清理过缓存）——退回文字 TTS，总比哑了强
                onSpeak(speakText)
            }
        } label: {
            Group {
                if isThisFilePlaying {
                    actionIcon("pause.fill", label: "Pause")
                } else if isThisFilePaused {
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
