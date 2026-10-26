import SwiftUI
import WebKit
import Combine
import UIKit

// MARK: - Assistant Block View (individual block — isolated invalidation)

struct AssistantBlockView: View {
    @ObservedObject var block: AssistantBlock
    @ObservedObject var message: ChatMessage
    @ObservedObject private var appearanceStudio = AppearanceStudio.shared
    let isActiveMessage: Bool
    var commandStartTime: Date?
    var onStop: (() -> Void)?
    var onTapBlank: ((CGPoint) -> Void)?
    var onCopyScreenshot: (() -> Void)?
    /// [T-selection-menu-minis-tts] Selection-menu read-aloud hooks, plumbed
    /// down to SelectableMarkdownView (nil for non-text or streaming contexts).
    var onReadAloud: (() -> Void)?
    var onSpeakText: ((String) -> Void)?
    /// [T-message-action-bar 09-11] Pause/resume/stop for the bubble action
    /// bar. nil hides the bar (streaming reply, or a bridge without a VM).
    var speechController: (any SpeechControlling)?
    /// [T-action-bar-play-bubble 09-13] 醒醒 5: when this reply carries a
    /// wx-style voice bubble (AI Voice Replies), the action bar's Play button
    /// replays THE BUBBLE'S OWN AUDIO FILE (already synthesized with the
    /// configured voice) instead of re-synthesizing the text through TTS.
    /// Pause/resume/continue then ride the GlobalAudioPlayer like any media.
    /// nil (or a text-only reply) keeps the old behavior: speak the text.
    var voiceBubbleFileURL: URL?
    /// [batch9d / W1C-08] 会话绑定人设 id——正则显示规则按它取；
    /// nil 回退全局当前人设（与模型侧 sessionPersonaId 同一语义）。
    var sessionPersonaId: String? = nil
    /// [T-action-bar 09-11] Regenerate this assistant message.
    var onRegenerate: (() -> Void)?
    /// [T-action-bar 09-11] Delete this single assistant message.
    var onDeleteMessage: (() -> Void)?
    /// [Feedback 10-12] 回复反馈与整蛊回调
    var onFeedback: ((String) -> Void)?
    var browserPool: BrowserTabPool?
    var toolSnapshots: [ToolSnapshotItem] = []
    @Binding var highlightedBlockId: UUID?
    @Binding var detailBlock: AssistantBlock?
    private var isHighlighted: Bool { highlightedBlockId == block.id }
    /// The action bar belongs to completed assistant replies only. A cell can
    /// receive speech hooks while it represents a user/system row during reuse;
    /// requiring both actions prevents controls from appearing on non-AI content.
    private var canShowActionBar: Bool {
        message.role == .assistant && onRegenerate != nil && onDeleteMessage != nil
    }

    var body: some View {
        switch block.kind {
        case .text:
            if !block.content.isEmpty {
                // [Kelivo Alignment] 助手消息渲染前应用正则替换规则 (视觉展示)
                // [10-19 醒醒] 全局正则。
                let appliedContent: String = {
                    GlobalRegexStore.shared.apply(to: block.content, role: "assistant", visual: true)
                }()
                let (cleanAppliedContent, stickerMatch) = StickerParser.parseFirst(in: appliedContent)
                let activeSticker = stickerMatch.flatMap { StickerStore.shared.sticker(for: $0.id) }
                let finalContent = (stickerMatch != nil) ? cleanAppliedContent : appliedContent

                // [B28 R9] 代码块不再塞进 NSTextAttachment。先把围栏代码从
                // 正文里拆出来，正文仍走 SelectableMarkdownView，代码块走独立
                // 的 ChatCodeBlockView；两者的高度都由 SwiftUI 自己排版，宿主
                // cell 只负责一次重测，不再维护 attachmentBounds 那套账。
                let mixedSegments = ChatMarkdownSegmenter.segments(from: finalContent)
                let hasCodeSegment = mixedSegments.contains {
                    if case .code = $0 { return true }
                    return false
                }
                if hasCodeSegment {
                    mixedTextBubble(mixedSegments,
                                    sticker: activeSticker,
                                    actionContent: finalContent)
                } else {
                    let segments = Self.splitBubbleSegments(finalContent)
                    if segments.count > 1 {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                                if !seg.isEmpty {
                                    self.singleTextBubble(seg)
                                }
                            }
                            if let activeSticker {
                                StickerThumbnailView(sticker: activeSticker)
                            }
                            // [T-message-action-bar 09-11] One action bar under the
                            // LAST bubble group of the last text block — the reply's
                            // visible tail. It reads THE WHOLE BLOCK (all segments),
                            // not just the last segment, so "播放本条" means this
                            // message's complete text.
                            if Self.isLastTextBlock(of: message, block: block),
                               canShowActionBar {
                                actionBar(forBlockContent: finalContent)
                            }
                        }
                        .id(appearanceStudio.themePackRevision)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            if !finalContent.isEmpty {
                                self.singleTextBubble(finalContent)
                            }
                            if let activeSticker {
                                StickerThumbnailView(sticker: activeSticker)
                            }
                            if Self.isLastTextBlock(of: message, block: block),
                               canShowActionBar {
                                actionBar(forBlockContent: finalContent)
                            }
                        }
                        .id(appearanceStudio.themePackRevision)
                    }
                }
            }
        case .thinking:
            ThinkingBlockView(
                block: block,
                isStreaming: isActiveMessage && message.blocks.last?.id == block.id
            )
            .padding(.vertical, 2)
        case .delegateTool:
            // [batch7][T-subagent-control-capsule] A real delegation renders
            // the sub agent's own card (status / tier / elapsed / summary) —
            // the block's raw content is a live progress line and then the
            // result JSON, which the generic capsule would print verbatim.
            // A control call (status / steer / cancel / resume) is the model
            // operating on its own agents — an ordinary tool call, so it gets
            // the ordinary tool capsule.
            if HelperBlockInfo.controlSummary(block) != nil {
                ToolCapsuleView(block: block, icon: "slider.horizontal.3", accentColor: HelperAccent.color,
                                commandStartTime: commandStartTime, onStop: onStop,
                                toolSnapshots: toolSnapshots, detailBlock: $detailBlock,
                                sessionPersonaId: sessionPersonaId)
            } else {
                HelperBlockView(block: block, detailBlock: $detailBlock)
            }
        case .shellTool, .fileReadTool, .fileWriteTool, .fileEditTool,
             .browserTool, .readImageTool, .memoryTool, .askUserTool,
             .genericTool:
            // [chat-ui] One unified tool case — icon + browserPool plumbed from
            // the shared helpers above. Identical behavior to the eight
            // per-kind cases this replaces (only shell/browser got browserPool).
            ToolCapsuleView(block: block, icon: Self.toolCapsuleIcon(for: block.kind), accentColor: ChatColors.accent,
                            commandStartTime: commandStartTime, onStop: onStop,
                            browserPool: Self.toolCapsuleNeedsBrowserPool(for: block.kind) ? browserPool : nil,
                            toolSnapshots: toolSnapshots, detailBlock: $detailBlock,
                            sessionPersonaId: sessionPersonaId)
        case .info:
            let allLines = block.content.components(separatedBy: "\n").filter { !$0.isEmpty }
            // Separate reason lines (⚠️) from the final switched line (✅)
            let reasonLines = allLines.filter { $0.hasPrefix("⚠️") }
            let switchedLine = allLines.first { !$0.hasPrefix("⚠️") && !$0.isEmpty }
            // Truncate middle if more than 9 reason lines
            let displayReasons: [String] = {
                if reasonLines.count <= 9 { return reasonLines }
                return Array(reasonLines.prefix(4)) + [AppLocalized("⋯ \(reasonLines.count - 8) more")] + Array(reasonLines.suffix(4))
            }()
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(displayReasons.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 10))
                        .foregroundStyle(ChatColors.primaryText.opacity(0.45))
                        .lineLimit(2)
                }
                if let switchedLine {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(ChatColors.warning.opacity(0.8))
                        Text(switchedLine)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(ChatColors.primaryText.opacity(0.75))
                            .lineLimit(2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(ChatColors.warning.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(ChatColors.warning.opacity(0.14), lineWidth: 0.5))
            .contextMenu {
                Button {
                    UIPasteboard.general.string = block.content
                } label: {
                    Label(AppLocalized("Copy Error"), systemImage: "doc.on.doc")
                }
            }
        }
    }

    @ViewBuilder
    private func singleTextBubble(_ content: String) -> some View {
        // [10-18 醒醒 第五轮] 平铺 / 文稿形态不要气泡底色。
        let display = AppearanceChatDisplay.parse(
            AppearanceStudio.shared.currentThemePack().chatDisplay)
        if display == .flat || display == .document {
            textBlockView(markdown: content)
                .padding(.vertical, 4)
        } else {
            textBlockView(markdown: content)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    MinisThemeShape.assistantBubble.fill(ChatColors.assistantBubble)
                )
                .overlay(
                    MinisThemeShape.assistantBubble.fill(ChatColors.accent.opacity(isHighlighted ? 0.10 : 0))
                )
                .clipShape(MinisThemeShape.assistantBubble)
        }
    }

    @ViewBuilder
    private func mixedTextBubble(_ segments: [ChatMarkdownSegment],
                                 sticker: StickerItem?,
                                 actionContent: String) -> some View {
        let display = AppearanceChatDisplay.parse(
            AppearanceStudio.shared.currentThemePack().chatDisplay)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let text):
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // [B28 R14] 正文各段自己带气泡底，不再让整条消息套一层。
                        // 这样代码卡片才能从气泡里"脱"出来，是独立的卡。
                        textBlockView(markdown: text)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                MinisThemeShape.assistantBubble.fill(ChatColors.assistantBubble)
                            )
                            .overlay(
                                MinisThemeShape.assistantBubble.fill(
                                    ChatColors.accent.opacity(isHighlighted ? 0.10 : 0))
                            )
                            .clipShape(MinisThemeShape.assistantBubble)
                    }
                case .code(let language, let code, let codeIndex):
                    // 代码是独立卡片：自己的圆角、边框、阴影，不吃气泡底。
                    ChatCodeBlockView(
                        code: code,
                        language: language,
                        sourceMarkdown: actionContent,
                        codeIndex: codeIndex,
                        messageId: message.id,
                        blockId: block.id
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                }
            }
            if let sticker {
                StickerThumbnailView(sticker: sticker)
            }
            if Self.isLastTextBlock(of: message, block: block),
               canShowActionBar {
                actionBar(forBlockContent: actionContent)
            }
        }
        .padding(.vertical, display == .flat || display == .document ? 4 : 0)
        .id(appearanceStudio.themePackRevision)
    }

    // MARK: - [T-message-action-bar 09-11] kelivo-style bubble actions

    /// True when this block is the message's LAST text block (the action bar
    /// only hangs there — earlier text blocks read as part of the flow).
    /// [chat-ui] SF Symbol per tool kind — single source of truth shared by the
    /// per-block switch below and the tool-group folding card.
    static func toolCapsuleIcon(for kind: AssistantBlockKind) -> String {
        switch kind {
        case .shellTool: return "terminal.fill"
        case .fileReadTool: return "doc.text.fill"
        case .fileWriteTool: return "doc.text.fill"
        case .fileEditTool: return "square.and.pencil"
        case .browserTool: return "globe"
        case .readImageTool: return "photo.fill"
        case .memoryTool: return "brain.head.profile"
        // [batch7] Sub agent blocks: real delegations render their own card;
        // this icon serves the CONTROL-call capsule branch.
        case .delegateTool: return "slider.horizontal.3"
        case .askUserTool: return "questionmark.circle.fill"
        case .genericTool: return "wrench.adjustable.fill"
        case .text, .thinking, .info: return "wrench.and.screwdriver.fill"
        }
    }

    /// [chat-ui] Which tool kinds need the live browser tab pool plumbed into
    /// their capsule (mirrors the per-kind call sites below).
    static func toolCapsuleNeedsBrowserPool(for kind: AssistantBlockKind) -> Bool {
        switch kind {
        case .shellTool, .browserTool: return true
        default: return false
        }
    }

    static func isLastTextBlock(of message: ChatMessage, block: AssistantBlock) -> Bool {
        let textBlocks = message.blocks.filter { if case .text = $0.kind { return true }; return false }
        guard let last = textBlocks.last else { return false }
        return last.id == block.id
    }

    /// The kelivo-style action row (copy / play-pause / stop). Uses the
    /// selection-TTS hook (`onSpeakText`) so the bubble speaks through the
    /// service-layer voice; the vm doubles as the SpeechControlling for
    /// pause/resume/stop. Nil hooks (streaming / bridging gaps) hide the bar.
    @ViewBuilder
    private func actionBar(forBlockContent content: String) -> some View {
        if let onSpeakText, let controller = speechController {
            // [T-action-bar-play-bubble 09-13] Reply with a voice bubble →
            // Play replays the bubble's audio file (its synthesized audio IS
            // this reply's voice form; re-synthesizing the text would produce
            // a second, differently-timed take and waste a vendor call).
            if let fileURL = voiceBubbleFileURL {
                BubbleAudioActionBar(fileURL: fileURL,
                                     onRegenerate: { onRegenerate?() },
                                     onDelete: { onDeleteMessage?() },
                                     speakText: content,
                                     onSpeak: onSpeakText,
                                     onFeedback: onFeedback)
            } else {
                MessageActionBar(
                    speakText: content,
                    onSpeak: onSpeakText,
                    controller: controller,
                    onRegenerate: { onRegenerate?() },
                    onDelete: { onDeleteMessage?() },
                    onFeedback: onFeedback
                )
            }
        }
    }

    /// Split assistant markdown into bubble segments on blank lines.
    /// Empty when the content should stay one bubble (no blank lines, or
    /// structural markdown that must not be shredded).
    static func splitBubbleSegments(_ content: String) -> [String] {
        // Guard: code fences / tables render wrong when split — keep whole.
        if content.contains("```") || content.contains("\n|") || content.hasPrefix("|") {
            return [content]
        }
        // Split on 2+ consecutive newlines (blank line), collapsing runs.
        let raw = content
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard raw.count > 1 else { return [content] }
        // Guard 2: a blank line INSIDE a list (indented continuation) splits
        // the list mid-structure; if any segment starts with list markup and
        // another continues it, don't shred. Cheap heuristic: if >1 segment
        // starts with a list marker, treat the whole block as list content.
        let listStarts = raw.filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") || $0.hasPrefix("1. ") }
        if listStarts.count > 1 { return [content] }
        return raw
    }

    @ViewBuilder
    private func textBlockView(markdown: String) -> some View {
        SelectableMarkdownView(
            markdown: markdown,
            cachedContent: markdown == block.content ? block.cachedMarkdown : nil,
            cachedAttributedString: markdown == block.content ? block.cachedAttributedString : nil,
            messageId: message.id,
            blockId: block.id,
            onTapBlank: onTapBlank,
            onCopyScreenshot: onCopyScreenshot,
            onReadAloud: onReadAloud,
            onSpeakText: onSpeakText
        )
        .fixedSize(horizontal: false, vertical: true)
        .modifier(MinisOpenURLHandler())
    }

    @ViewBuilder
    private var textBlockView: some View {
        textBlockView(markdown: block.content)
    }
}

// MARK: - [B28 R9] Code block segments (outside TextKit)

/// One run of a text block after fenced code has been pulled out of the
/// markdown. Prose still goes through SelectableMarkdownView; code goes
/// through ChatCodeBlockView, so no NSTextAttachment is involved.
enum ChatMarkdownSegment {
    case prose(String)
    case code(language: String?, code: String, codeIndex: Int)
}

enum ChatMarkdownSegmenter {
    private struct Fence {
        let marker: Character
        let count: Int
        let language: String?
    }

    static func hasFence(_ text: String) -> Bool {
        text.components(separatedBy: "\n").contains { parseFence($0) != nil }
    }

    /// Split on ``` / ~~~ fences. Prose keeps its blank lines; code keeps its
    /// indentation and internal blank lines. An unclosed fence (streaming)
    /// renders the rest as code instead of showing raw backticks.
    static func segments(from markdown: String) -> [ChatMarkdownSegment] {
        let lines = markdown.components(separatedBy: "\n")
        var out: [ChatMarkdownSegment] = []
        var prose: [String] = []
        var index = 0
        var codeIndex = 0

        func flushProse() {
            guard !prose.isEmpty else { return }
            let text = prose.joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(.prose(text))
            }
            prose.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            guard let fence = parseFence(line) else {
                prose.append(line)
                index += 1
                continue
            }
            flushProse()
            var codeLines: [String] = []
            index += 1
            var closed = false
            while index < lines.count {
                if isClosingFence(lines[index], marker: fence.marker, count: fence.count) {
                    closed = true
                    index += 1
                    break
                }
                codeLines.append(lines[index])
                index += 1
            }
            let code = codeLines.joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
            out.append(.code(language: fence.language, code: code, codeIndex: codeIndex))
            codeIndex += 1
            if !closed { break }
        }
        flushProse()
        return out.isEmpty ? [.prose(markdown)] : out
    }

    private static func parseFence(_ line: String) -> Fence? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let count = trimmed.prefix { $0 == first }.count
        guard count >= 3 else { return nil }
        let rest = String(trimmed.dropFirst(count)).trimmingCharacters(in: .whitespaces)
        if first == "`" && rest.contains("`") { return nil }
        let language = rest.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .first.map(String.init)
        return Fence(marker: first,
                     count: count,
                     language: (language?.isEmpty == false) ? language : nil)
    }

    private static func isClosingFence(_ line: String,
                                       marker: Character,
                                       count: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let run = trimmed.prefix { $0 == marker }.count
        guard run >= count else { return false }
        return String(trimmed.dropFirst(run))
            .trimmingCharacters(in: .whitespaces)
            .isEmpty
    }

    static func replacingNthCode(in markdown: String, index: Int, newCode: String) -> String? {
        let lines = markdown.components(separatedBy: "\n")
        var seen = -1
        var position = 0
        while position < lines.count {
            guard let fence = parseFence(lines[position]) else {
                position += 1
                continue
            }
            seen += 1
            let start = position + 1
            var closing = lines.count
            var closed = false
            var probe = start
            while probe < lines.count {
                if isClosingFence(lines[probe], marker: fence.marker, count: fence.count) {
                    closing = probe
                    closed = true
                    break
                }
                probe += 1
            }
            if seen == index {
                var result = Array(lines[0...position])
                result.append(contentsOf: newCode.components(separatedBy: "\n"))
                if closed {
                    result.append(contentsOf: lines[closing...])
                } else {
                    result.append(String(repeating: String(fence.marker), count: fence.count))
                }
                return result.joined(separator: "\n")
            }
            position = closed ? closing + 1 : lines.count
        }
        return nil
    }

    static func replacingCode(in markdown: String, oldCode: String, newCode: String) -> String? {
        segments(from: markdown).enumerated().first { _, segment in
            if case .code(_, let code, _) = segment { return code == oldCode }
            return false
        }.flatMap { offset, _ in
            replacingNthCode(in: markdown, index: offset, newCode: newCode)
        }
    }

    static func codeCount(in markdown: String) -> Int {
        segments(from: markdown).reduce(0) { count, segment in
            if case .code = segment { return count + 1 }
            return count
        }
    }
}

struct ChatCodeBlockView: View {
    let code: String
    let language: String?
    let sourceMarkdown: String
    let codeIndex: Int
    let messageId: UUID?
    let blockId: UUID?

    static let cardHeight = VoiceCatBubbleCardView.cardHeight

    @State private var copied = false

    @MainActor
    static func measuredHeight(code: String, language: String?, width: CGFloat) -> CGFloat {
        Self.cardHeight
    }

    private var theme: SelectableMarkdownTheme {
        SelectableMarkdownTheme(baseFontSize: FontSettings.shared.scaledMessage(16.5))
    }

    private var displayLanguage: String {
        guard let language, !language.isEmpty else { return "CODE" }
        return language.uppercased()
    }

    private var codeText: AttributedString {
        let ns = ChatCodeBlockHighlighter.attributed(code: code, language: language, theme: theme)
        return (try? AttributedString(ns, including: \.uiKit)) ?? AttributedString(code)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(Color(uiColor: theme.codeBlockTextColor).opacity(0.10))
                .frame(height: 0.5)
            preview
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.cardHeight, alignment: .top)
        .background(Color(uiColor: theme.codeBlockBackground))
        .clipShape(RoundedRectangle(cornerRadius: theme.codeBlockCornerRadius, style: .continuous))
        // [B28 R14] 独立卡片：给一点浮起来的阴影，跟气泡分开读。
        .shadow(color: .black.opacity(0.07), radius: 8, x: 0, y: 3)
        .overlay(
            RoundedRectangle(cornerRadius: theme.codeBlockCornerRadius, style: .continuous)
                .stroke(Color(uiColor: theme.codeBlockTextColor).opacity(0.08), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(displayLanguage)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(uiColor: theme.codeBlockTextColor).opacity(0.45))
                .accessibilityLabel("代码块语言")
            Spacer(minLength: 8)
            Button {
                UIPasteboard.general.string = code
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(uiColor: theme.codeBlockTextColor).opacity(0.55))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(copied ? "代码已复制" : "复制代码")

            Button {
                // [B28 R10] 不在 cell 里就地起全屏——把内容打包给顶层 AIChatView 展示。
                ChatCodeBlockExpandRouter.postExpand(
                    messageId: messageId,
                    blockId: blockId,
                    sourceMarkdown: sourceMarkdown,
                    codeIndex: codeIndex,
                    code: code,
                    language: language)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(uiColor: theme.codeBlockTextColor).opacity(0.55))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("放大查看代码")
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
    }

    private var preview: some View {
        Text(codeText)
            .lineSpacing(4)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: .infinity, alignment: .top)
            .clipped()
            .padding(.horizontal, 10)
            .padding(.top, 7)
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [
                        Color(uiColor: theme.codeBlockBackground).opacity(0),
                        Color(uiColor: theme.codeBlockBackground)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 16)
                .allowsHitTesting(false)
            }
    }
}

/// [B28 R10] 放大代码块的出站路由。
///
/// 为什么不让卡片自己 `.fullScreenCover`：卡片住在 UIHostingConfiguration 的
/// collection cell 里，会被复用/销毁，cover 状态跟着丢；而且一个 host 上
/// fullScreenCover 只能挂一只，会把图片/视频的全屏挤掉。
/// 所以照 `MarkdownImageTapRouter` 的既有走法：内容打包成通知，交给顶层
/// AIChatView 的全屏宿主展示。
enum ChatCodeBlockExpandRouter {
    static let expandedNotification = Notification.Name("ChatCodeBlockExpanded")

    @MainActor
    static func postExpand(messageId: UUID?, blockId: UUID?, sourceMarkdown: String,
                           codeIndex: Int, code: String, language: String?) {
        guard let messageId else { return }
        let request = ChatCodeBlockEditRequest(
            messageId: messageId,
            blockId: blockId,
            sourceMarkdown: sourceMarkdown,
            codeIndex: codeIndex,
            oldCode: code,
            newCode: code,
            language: language
        )
        NotificationCenter.default.post(name: expandedNotification, object: request)
    }
}

/// fullScreenCover(item:) 用的包装。UUID 每次新建，所以同一块代码
/// 关掉再点开也会重新给一份初始内容。
struct ChatCodeBlockCover: Identifiable {
    let id = UUID()
    let request: ChatCodeBlockEditRequest
}

struct ChatCodeBlockDetailView: View {
    let initialCode: String
    let language: String?
    let onSave: (String) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var code: String
    @State private var editing = false
    @State private var previewMode = false
    @State private var copied = false
    @State private var saved = false

    /// 全屏页直接从路由送来的请求构造；保存回同一个请求的 newCode 槽位，
    /// 交给 `ChatCodeBlockEditRouter` 落到当前会话的 VM。
    init(request: ChatCodeBlockEditRequest) {
        self.initialCode = request.oldCode
        self.language = request.language
        self.onSave = { edited in
            let out = ChatCodeBlockEditRequest(
                messageId: request.messageId,
                blockId: request.blockId,
                sourceMarkdown: request.sourceMarkdown,
                codeIndex: request.codeIndex,
                oldCode: request.oldCode,
                newCode: edited,
                language: request.language
            )
            return ChatCodeBlockEditRouter.current?.saveEditedCodeBlock(out) ?? false
        }
        _code = State(initialValue: request.oldCode)
    }

    init(initialCode: String, language: String?, onSave: @escaping (String) -> Bool) {
        self.initialCode = initialCode
        self.language = language
        self.onSave = onSave
        _code = State(initialValue: initialCode)
    }

    private var displayTitle: String {
        guard let language, !language.isEmpty else { return "代码" }
        return language
    }

    private var isHTML: Bool {
        let normalized = (language ?? "").lowercased()
        if ["html", "htm", "xhtml"].contains(normalized) { return true }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.contains("<html") && trimmed.contains("</html>")
    }

    private var canSave: Bool {
        code != initialCode
    }

    var body: some View {
        NavigationStack {
            Group {
                if editing {
                    editor
                } else if previewMode {
                    ChatCodeBlockHTMLPreview(code: code)
                } else {
                    codeReader
                }
            }
            .navigationTitle(displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .accessibilityLabel("关闭代码全屏")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // [B28 R10] 预览按钮不再只有 html 才出现：她要的是全屏里
                    // 随时能"当网页跑一下看看"。非 html 内容丢给 WKWebView
                    // 也只会当文本渲染，不会崩，所以没必要藏起来。
                    if !editing {
                        Button {
                            previewMode.toggle()
                        } label: {
                            Image(systemName: previewMode ? "chevron.left.forwardslash.chevron.right" : "globe")
                        }
                        .accessibilityLabel(previewMode ? "返回代码" : "HTML 预览")
                    }
                    Button {
                        UIPasteboard.general.string = code
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityLabel(copied ? "已复制" : "复制代码")

                    if editing {
                        Button {
                        if canSave, onSave(code) {
                            editing = false
                            saved = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { saved = false }
                        } else if !canSave {
                            editing = false
                        }
                    } label: {
                        Image(systemName: saved ? "checkmark" : "square.and.arrow.down")
                    }
                    .disabled(!canSave && !editing)
                    .accessibilityLabel("保存代码")
                    } else {
                        Button {
                            editing = true
                            previewMode = false
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .accessibilityLabel("编辑代码")
                    }
                }
            }
        }
    }

    private var editor: some View {
        TextEditor(text: $code)
            .font(.system(size: 15, weight: .regular, design: .monospaced))
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemBackground))
            .tint(.accentColor)
    }

    private var attributedCode: NSAttributedString {
        ChatCodeBlockHighlighter.attributed(
            code: code,
            language: language,
            theme: SelectableMarkdownTheme(baseFontSize: FontSettings.shared.scaledMessage(16.5))
        )
    }

    private var codeReader: some View {
        ScrollView {
            Text(AttributedString(attributedCode))
                .font(.system(size: 15, weight: .regular, design: .monospaced))
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(16)
        }
        .background(Color(uiColor: .systemBackground))
    }
}

struct ChatCodeBlockHTMLPreview: UIViewRepresentable {
    let code: String

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.navigationDelegate = context.coordinator
        webView.loadHTMLString(code, baseURL: nil)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if uiView.url == nil {
            uiView.loadHTMLString(code, baseURL: nil)
        } else if context.coordinator.lastCode != code {
            context.coordinator.lastCode = code
            uiView.loadHTMLString(code, baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastCode = ""
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated {
                if let url = navigationAction.request.url {
                    UIApplication.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

private enum ChatCodeBlockHighlighter {
    private static let cache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 120
        return cache
    }()

    static func attributed(code: String,
                           language: String?,
                           theme: SelectableMarkdownTheme) -> NSAttributedString {
        let key = "\(language ?? "")|\(theme.baseFontSize)|\(theme.codeBlockBackground.hashValue)|\(code.hashValue)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let result = CodeSyntaxHighlighter.highlight(
            code,
            language: language,
            font: theme.codeBlockFont,
            plainColor: theme.codeBlockTextColor,
            background: theme.codeBlockBackground
        )
        cache.setObject(result, forKey: key)
        return result
    }
}

private struct AssistantBubbleChrome: ViewModifier {
    let display: AppearanceChatDisplay
    let isHighlighted: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if display == .flat || display == .document {
            content.padding(.vertical, 4)
        } else {
            content
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    MinisThemeShape.assistantBubble.fill(ChatColors.assistantBubble)
                )
                .overlay(
                    MinisThemeShape.assistantBubble.fill(
                        ChatColors.accent.opacity(isHighlighted ? 0.10 : 0))
                )
                .clipShape(MinisThemeShape.assistantBubble)
        }
    }
}

// MARK: - Shimmer Overlay (continuous diagonal shine via offset animation)

/// A diagonal shimmer band that sweeps from top-leading to bottom-trailing.
/// Uses a single stable gradient with an animated offset rather than rebuilding
/// gradient stops every frame — avoids a CAGradientLayer colorspace teardown
/// race during CATransaction flush (EXC_BAD_ACCESS at encode_colorspace).
struct ShimmerOverlay: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var offsetX: CGFloat = -1.0

    private var peakOpacity: CGFloat {
        colorScheme == .light ? 0.75 : 0.25
    }

    private func bell(_ x: CGFloat) -> CGFloat {
        exp(-4.5 * x * x)
    }

    private var stableStops: [Gradient.Stop] {
        let stepCount = 12
        let bandRadius: CGFloat = 0.40
        let center: CGFloat = 0.5
        var stops: [Gradient.Stop] = []
        stops.append(.init(color: .white.opacity(0), location: 0))
        for i in 0...stepCount {
            let frac = CGFloat(i) / CGFloat(stepCount)
            let pos = center - bandRadius + frac * bandRadius * 2.0
            let dist = (pos - center) / bandRadius
            let alpha = bell(dist) * peakOpacity
            stops.append(.init(color: .white.opacity(Double(alpha)), location: pos))
        }
        stops.append(.init(color: .white.opacity(0), location: 1))
        return stops
    }

    var body: some View {
        GeometryReader { geo in
            let diag = geo.size.width + geo.size.height
            Rectangle()
                .fill(
                    LinearGradient(
                        stops: stableStops,
                        startPoint: UnitPoint(x: 0, y: 1),
                        endPoint: UnitPoint(x: 1, y: 0)
                    )
                )
                .frame(width: diag, height: geo.size.height)
                .offset(x: offsetX * geo.size.width)
                .onAppear {
                    withAnimation(
                        .linear(duration: 2.8)
                        .repeatForever(autoreverses: false)
                    ) {
                        offsetX = 1.0
                    }
                }
        }
        .clipped()
    }
}

// MARK: - Tool Capsule View (unified pill for all tool types)

struct ToolCapsuleView: View {
    @ObservedObject var block: AssistantBlock
    @ObservedObject private var appearanceStudio = AppearanceStudio.shared
    let icon: String
    let accentColor: Color
    var commandStartTime: Date?
    var onStop: (() -> Void)?
    var browserPool: BrowserTabPool?
    var toolSnapshots: [ToolSnapshotItem] = []
    @Binding var detailBlock: AssistantBlock?
    /// [audit-E6] 本行会话的人设 id——撤销记忆时按它找文件（nil 回退全局当前）。
    var sessionPersonaId: String? = nil
    @State private var dotsActive = false
    /// [T-tool-bg-suspended-hint] Drives the background-suspension info alert.
    @State private var showBgHintAlert = false
    /// [T-ios-memory-write-revoke] Confirmation + result alerts for undoing a
    /// memory_write straight from the tool capsule's long-press menu.
    @State private var showRevokeMemoryAlert = false
    @State private var revokeMemoryResult: String?
    @State private var showRevokeMemoryResultAlert = false
    @ObservedObject private var keepAlive = BackgroundKeepAliveManager.shared

    /// Show the yellow ⓘ hint only when this tool was flagged as background-
    /// suspended AND enhanced background isn't already effective (nothing to
    /// suggest if it's on). Mirrors the BackgroundInterruptionTracker gate.
    private var showBgSuspendedHint: Bool {
        block.wasBackgroundSuspended && !keepAlive.enhancedBackgroundEffective
    }
    /// [T-ios-retry-hide-when-processing] Used to suppress the "Re-run From
    /// Here" long-press menu item while the agent loop is busy — tapping it
    /// mid-run would corrupt the in-flight processing state.
    @EnvironmentObject private var vm: AIChatViewModel

    /// [T-ios-memory-write-revoke] Whether this block is a `memory_write` that
    /// carries input args at all — the cheap check that decides whether the Undo
    /// menu item is offered. Deliberately does NOT parse the JSON: this feeds
    /// `ToolMenuKey`, which is rebuilt on every eager body pass, and re-running
    /// `JSONSerialization` there is exactly the per-frame work the menu gate
    /// exists to avoid. Other tools and `memory_get` never match.
    private var isRevocableMemoryWrite: Bool {
        guard case .memoryTool(let action) = block.kind, action == "memory_write" else { return false }
        guard let args = block.toolInputArgs else { return false }
        return !args.isEmpty
    }

    /// The text this block wrote to memory. Parsed lazily — only when the menu
    /// item is actually tapped — same treatment as `toolDetailsClipboard`.
    /// Nil when the args carry no non-empty `content` (e.g. a malformed or
    /// still-streaming tool call), which the confirm action treats as a no-op.
    private var memoryWriteContent: String? {
        guard case .memoryTool(let action) = block.kind, action == "memory_write" else { return nil }
        return MemoryWriteRevoker.writtenContent(fromToolInputArgs: block.toolInputArgs)
    }

    /// Display text: prefer LLM-generated toolSummary, fall back to toolDescription.
    private var displayText: String {
        if let summary = block.toolSummary, !summary.isEmpty {
            return summary
        }
        return block.toolDescription
    }

    /// [T-ios-tool-bubble-longpress-menu] Human-readable, paste-back-able
    /// dump of this tool call + its result for the "Copy Tool Details"
    /// menu action. Pulls tool name from the block kind, the input JSON
    /// from toolInputArgs (pretty-printed when it parses), and the result
    /// text + status from the block's content / toolStatus (with the
    /// snapshot text as a fallback source).
    private var toolDetailsClipboard: String {
        // Tool name from the block kind.
        let toolName: String
        switch block.kind {
        case .shellTool:     toolName = "shell_execute"
        case .fileReadTool:  toolName = "file_read"
        case .fileWriteTool: toolName = "file_write"
        case .fileEditTool:  toolName = "file_edit"
        case .browserTool:   toolName = "browser_use"
        case .readImageTool: toolName = "read_image"
        case .memoryTool:    toolName = "memory"
        case .askUserTool:   toolName = "ask_user_input_v0"
        case .delegateTool:  toolName = SubAgentDefinition.toolName
        case .genericTool(let name): toolName = name
        case .text, .thinking, .info: toolName = "unknown"
        }

        // Pretty-print the input JSON when possible; otherwise emit raw.
        let inputBlock: String
        if let raw = block.toolInputArgs, !raw.isEmpty {
            if let data = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
               let prettyStr = String(data: pretty, encoding: .utf8) {
                inputBlock = prettyStr
            } else {
                inputBlock = raw
            }
        } else {
            inputBlock = "(no input captured)"
        }

        // Result text: prefer the live block content, fall back to the
        // snapshot text matched by toolUseId.
        var resultText = block.content
        if resultText.isEmpty, let tuId = block.toolUseId,
           let snap = toolSnapshots.first(where: { $0.id == tuId }) {
            resultText = snap.snapshot.text ?? ""
        }
        let hasScreenshot = block.imageFilePath != nil
            || (block.toolUseId.flatMap { tuId in toolSnapshots.first(where: { $0.id == tuId }) }?.snapshot.type == .image)

        // Status string.
        let statusStr: String
        switch block.toolStatus {
        case .success:   statusStr = "success"
        case .failed:    statusStr = "failed"
        case .cancelled: statusStr = "cancelled"
        case .running:   statusStr = "running"
        case .streaming: statusStr = "streaming"
        case .none:      statusStr = "unknown"
        }

        var resultMeta = "(\(resultText.count) chars, \(statusStr)"
        if hasScreenshot { resultMeta += ", screenshot" }
        resultMeta += ")"

        return """
        ## Tool Call
        name: \(toolName)
        id: \(block.toolUseId ?? "(none)")
        input:
        \(inputBlock)

        ## Tool Result
        \(resultMeta)
        \(resultText)
        """
    }

    private var isStreaming: Bool {
        if case .streaming = block.toolStatus { return true }
        return false
    }

    private var isActive: Bool {
        switch block.toolStatus {
        case .streaming, .running: return true
        default: return false
        }
    }

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                // Status indicator / icon
                statusOrIcon

                // Description text with bouncing dots during streaming
                HStack(spacing: 0) {
                    Text(displayText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ChatColors.primaryText)
                        .lineLimit(1)
                    if isStreaming {
                        ForEach(0..<3, id: \.self) { i in
                            Text(".")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(ChatColors.primaryText)
                                .offset(y: dotsActive ? -2 : 1)
                                .animation(
                                    .easeInOut(duration: 0.35)
                                        .repeatForever(autoreverses: true)
                                        .delay(Double(i) * 0.12),
                                    value: dotsActive
                                )
                        }
                    }
                }
                .lineLimit(1)

                // Execution duration (shown after completion). The HH:mm:ss
                // start time is surfaced inside the detail view's bottom bar
                // (ToolLiveSheet.bottomBar) instead of here — the inline
                // pill list stays clean.
                if let dur = durationText {
                    Text(dur)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(ChatColors.tertiaryText)
                }

                // Stop button for running commands
                if case .running = block.toolStatus {
                    Button {
                        onStop?()
                    } label: {
                        // Visual: 10×10 red square unchanged. Hit area enlarged to
                        // 24×24 via an expanded contentShape, while the negative
                        // padding pins the *layout* footprint back to 18×18 so the
                        // capsule width/height is identical to before.
                        RoundedRectangle(cornerRadius: 2)
                            .fill(ChatColors.destructive)
                            .frame(width: 10, height: 10)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                            .padding(-3)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(ChatColors.toolBg)
            .clipShape(Capsule())
            .overlay(
                Group {
                    if isActive {
                        ShimmerOverlay()
                            .clipShape(Capsule())
                            .allowsHitTesting(false)
                    }
                }
            )
            .overlay(
                Capsule()
                    .stroke(ChatColors.toolBorder, lineWidth: 0.5)
            )
            .contentShape(Capsule())
            .onTapGesture {
                detailBlock = block
            }
            .contextMenu {
                // [T-ios-msg-contextmenu-recursion-crash] Gate the eager menu
                // tree behind an Equatable key so this tool cell's body churn
                // during `gh`/shell streaming doesn't rebuild + re-diff the menu
                // subtree every frame (part of the deep ContextMenuModifier
                // recursion in incident 98E8805F). `toolDetailsClipboard` is read
                // lazily at TAP time, so the key only tracks structure: the tool
                // (blockId), whether the Re-run branch is shown (isProcessing),
                // and whether the memory-Undo branch is shown. All three are
                // cheap reads — the expensive payloads (clipboard dump, written
                // memory text) are built at tap time, never in the key.
                EquatableMenuGate(key: ToolMenuKey(
                    blockId: block.id,
                    isProcessing: vm.isProcessing,
                    canRevokeMemoryWrite: isRevocableMemoryWrite
                )) {
                    // [T-ios-tool-bubble-longpress-menu]
                    Button {
                        UIPasteboard.general.string = toolDetailsClipboard
                    } label: {
                        Label(AppLocalized("Copy Tool Details"), systemImage: "doc.on.doc")
                    }
                    // [T-ios-retry-hide-when-processing] Only expose the
                    // destructive Re-run action when the agent loop is idle.
                    // Re-running mid-stream would tear down an in-flight turn
                    // and confuse downstream state — hide both the divider and
                    // the button as a group so the menu doesn't leave a
                    // trailing separator with nothing under it.
                    if !vm.isProcessing {
                        Divider()
                        Button(role: .destructive) {
                            // Re-run the whole assistant turn that owns this
                            // tool_use. Routed via notification so we don't have
                            // to thread a vm closure through the 4-layer cell
                            // hosting chain — AIChatView's RerunFromToolBlockListener
                            // maps blockId → owning assistant msg → preceding user
                            // msg → vm.retryFromMessage.
                            NotificationCenter.default.post(
                                name: .rerunFromToolBlock,
                                object: nil,
                                userInfo: ["blockId": block.id]
                            )
                        } label: {
                            Label(AppLocalized("Re-run From Here"), systemImage: "arrow.clockwise")
                        }
                    }
                    // [T-ios-memory-write-revoke] Undo the daily-log entry this
                    // memory_write produced, without a detour through
                    // Memories in Session → detail sheet. Only appears for a
                    // memory_write that carries input args.
                    if isRevocableMemoryWrite {
                        Divider()
                        Button(role: .destructive) {
                            showRevokeMemoryAlert = true
                        } label: {
                            Label(AppLocalized("Undo This Memory Write"), systemImage: "trash.slash")
                        }
                    }
                }
                .equatable()
            }
            // [T-tool-bg-suspended-hint] Yellow ⓘ just outside the capsule's
            // trailing edge when this tool was likely suspended by the OS in the
            // background. Tapping shows an alert offering to enable enhanced
            // background (deep-links to Settings → Permissions → Background).
            if showBgSuspendedHint {
                Button {
                    showBgHintAlert = true
                } label: {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(ChatColors.warning)
                }
                .buttonStyle(.plain)
                .padding(.leading, 6)
                .accessibilityLabel(Text(AppLocalized("Background suspension info")))
            }
            Spacer(minLength: 0)
        }
        .alert(
            AppLocalized("Task may have been paused"),
            isPresented: $showBgHintAlert
        ) {
            Button(AppLocalized("Go Enable")) {
                // Deep-link to Settings → Permissions → Background, nudging the
                // recommended rows ON — they highlight only while still OFF
                // (= minis-clone://settings/background?focus=…:true,…:true). Location
                // Tracking is included so the background heartbeat that keeps the
                // task Live Activity refreshing in real time gets enabled too.
                DeepLinkCoordinator.shared.setFocus(
                    rawQueryValue: "enhancedBackgroundExecution:true,backgroundSpeakEnabled:true,locationTrackingEnabled:true")
                DeepLinkCoordinator.shared.pendingSettingsTarget = .background
            }
            Button(AppLocalized("Maybe Later"), role: .cancel) {}
        } message: {
            Text(AppLocalized("This tool may have been paused by the system while running in the background. Enable enhanced background execution to improve background task reliability."))
        }
        // [T-ios-memory-write-revoke] Mirrors the Revoke Memory confirmation in
        // SessionMemoryView: confirm, then report the outcome in place — the
        // user stays in the transcript, no navigation. The bubble itself is
        // left alone; only the underlying daily-log file changed.
        .alert(
            AppLocalized("Revoke Memory"),
            isPresented: $showRevokeMemoryAlert
        ) {
            Button(AppLocalized("Cancel"), role: .cancel) {}
            Button(AppLocalized("Revoke"), role: .destructive) {
                // The menu item is gated on the cheap enum+args check, so the
                // `content` parse can still come back empty here (malformed or
                // still-streaming args). Report that rather than failing silently.
                if let written = memoryWriteContent {
                    revokeMemoryResult = MemoryWriteRevoker.revoke(writtenContent: written,
                                                                   personaID: sessionPersonaId)
                } else {
                    revokeMemoryResult = AppLocalized("No written content to revoke.")
                }
                showRevokeMemoryResultAlert = true
            }
        } message: {
            Text(AppLocalized("Remove this memory entry from the daily log? This cannot be undone."))
        }
        .alert(revokeMemoryResult ?? "", isPresented: $showRevokeMemoryResultAlert) {
            Button(AppLocalized("OK")) {}
        }
        .onChange(of: isStreaming) { streaming in
            dotsActive = streaming
        }
        .onAppear {
            if isStreaming {
                dotsActive = true
            }
        }
    }

    // MARK: - Status / Icon

    @ViewBuilder
    private var statusOrIcon: some View {
        Image(systemName: icon)
            .font(.system(size: 13))
            .foregroundStyle(iconColor)
    }

    private var iconColor: Color {
        switch block.toolStatus {
        case .success: return ChatColors.success
        case .failed: return ChatColors.destructive
        case .cancelled: return ChatColors.secondaryText
        default: return accentColor
        }
    }

    /// Formatted execution duration (e.g. "1.2s", "45s", "2m 10s").
    private var durationText: String? {
        guard let dur = block.toolDuration else { return nil }
        if dur < 1 { return String(format: "%.1fs", dur) }
        if dur < 60 { return String(format: "%.0fs", dur) }
        let mins = Int(dur) / 60
        let secs = Int(dur) % 60
        return "\(mins)m \(secs)s"
    }

}

// MARK: - [chat-ui] Tool-Call Group Card (Kelivo-style folding)

/// Expanded/collapsed state for tool-call group cards.
///
/// Keyed by "<messageId>:<firstBlockId>" so the state survives the group
/// growing: appending a new tool block changes the item's groupKey (member
/// IDs), but the run's first block never changes — blocks are append-only.
/// Bounded (400 entries) so long sessions can't grow it without limit.
enum ToolGroupExpansion {
    private static var expandedKeys = Set<String>()
    private static let maxEntries = 400

    static func isExpanded(stateKey: String) -> Bool {
        expandedKeys.contains(stateKey)
    }

    static func toggle(stateKey: String) {
        if expandedKeys.contains(stateKey) {
            expandedKeys.remove(stateKey)
        } else {
            if expandedKeys.count >= maxEntries { expandedKeys.removeFirst() }
            expandedKeys.insert(stateKey)
        }
    }
}

/// [chat-ui] Folding card for >2 consecutive tool calls in one assistant turn.
/// Collapsed shows the header + the LAST 2 tool capsules (the running tool is
/// always the tail, so its stop button stays reachable); tap the header to
/// expand. Each row is the stock ToolCapsuleView — stop button, elapsed time,
/// tap-for-detail and the long-press menu (copy / re-run / memory undo) are
/// all preserved untouched.
struct ToolCallGroupCard: View {
    let blocks: [AssistantBlock]
    /// "<messageId>:<firstBlockId>" — see ToolGroupExpansion.
    let stateKey: String
    var commandStartTime: Date?
    var onStop: (() -> Void)?
    var browserPool: BrowserTabPool?
    var toolSnapshots: [ToolSnapshotItem] = []
    @Binding var detailBlock: AssistantBlock?
    @ObservedObject private var appearanceStudio = AppearanceStudio.shared

    private var isExpanded: Bool { ToolGroupExpansion.isExpanded(stateKey: stateKey) }

    private var visibleBlocks: [AssistantBlock] {
        isExpanded ? blocks : Array(blocks.suffix(2))
    }

    private var headerTitle: String {
        // English source keys — zh-Hans/zh-Hant live in Localizable.xcstrings.
        if isExpanded { return AppLocalized("Collapse tool calls") }
        return AppLocalized("Expand tool calls")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                ToolGroupExpansion.toggle(stateKey: stateKey)
                NotificationCenter.default.post(name: .toolGroupToggled, object: stateKey)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 12, weight: .medium))
                    Text(headerTitle)
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(blocks.count)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(ChatColors.secondaryText.opacity(0.12))
                        .clipShape(Capsule())
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(ChatColors.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(headerTitle)

            ForEach(visibleBlocks) { block in
                ToolCapsuleView(
                    block: block,
                    icon: AssistantBlockView.toolCapsuleIcon(for: block.kind),
                    accentColor: ChatColors.accent,
                    commandStartTime: commandStartTime,
                    onStop: onStop,
                    browserPool: AssistantBlockView.toolCapsuleNeedsBrowserPool(for: block.kind) ? browserPool : nil,
                    toolSnapshots: toolSnapshots,
                    detailBlock: $detailBlock
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(6)
        .background(ChatColors.secondaryBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(ChatColors.toolBorder, lineWidth: 0.5)
        )
        .id(appearanceStudio.themePackRevision)
    }
}



extension Notification.Name {
    static let thinkingBlockToggled = Notification.Name("thinkingBlockToggled")
    /// [B28 R7-3 醒醒 10-23] 用户气泡「展开全文 / 收起」变了高度，
    /// 列表要清缓存重算——object 是 ChatMessage.id。
    static let userBubbleToggled = Notification.Name("userBubbleToggled")
    /// [chat-ui] Posted when a tool-call group card's header is tapped.
    /// object is the card's state key ("<messageId>:<firstBlockId>").
    /// The message list clears that cell's cached height and reconfigures it
    /// so UIHostingConfiguration re-measures — same shape as thinkingBlockToggled.
    static let toolGroupToggled = Notification.Name("toolGroupToggled")
    /// Posted when a long-press selection menu's "Add to Chat Input" action
    /// fires. userInfo["text"] is the selected text to append. The active
    /// chat's AIChatView listens and forwards to `vm.appendToInputText`.
    static let chatInputAppendRequested = Notification.Name("chatInputAppendRequested")
    /// Posted when an inline media attachment (image / video thumbnail /
    /// audio waveform) finishes async loading and its intrinsic content
    /// size changes. The collection view listens and invalidates self-sizing
    /// caches so cells re-measure. notification.object is the source URL
    /// string (for logging only — handler invalidates all visible cells).
    /// [T-attachment-size-invalidate 2026-05-21]
    static let minisAttachmentSizeChanged = Notification.Name("minisAttachmentSizeChanged")
    /// Posted from a tool capsule's long-press menu "Re-run from here".
    /// userInfo["blockId"] is the AssistantBlock.id (UUID) of the tapped
    /// tool_use. The active AIChatView listens, maps the block to its
    /// owning assistant message, finds the preceding user message, and
    /// re-runs the agent loop from there. [T-ios-tool-bubble-longpress-menu]
    static let rerunFromToolBlock = Notification.Name("rerunFromToolBlock")
}

/// Listens for `.rerunFromToolBlock` and drives the re-run. Extracted into
/// its own ViewModifier (like ChatInputAppendListener) to keep AIChatView's
/// body within the Swift type-checker budget. [T-ios-tool-bubble-longpress-menu]
///
/// "Re-run from here" semantics (block boundary —
/// T-ios-rerun-from-tool-block-position): re-run from the exact point this
/// tool_use was about to be issued. retryFromToolBlock keeps the blocks
/// BEFORE the target tool_use within its assistant turn, drops the target
/// block + later blocks in that turn + all later messages (rewriting the
/// trimmed assistant row in the DB), then re-runs the agent loop. If the
/// target is the first block with nothing preceding it, that path degrades
/// to a preceding-user-message truncation automatically.
struct RerunFromToolBlockListener: ViewModifier {
    let vm: AIChatViewModel

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .rerunFromToolBlock)) { note in
            guard let blockId = note.userInfo?["blockId"] as? UUID else { return }
            vm.retryFromToolBlock(blockId: blockId)
            vm.forceScrollToBottom.send()
        }
    }
}

/// View-modifier wrapper around the `chatInputAppendRequested` listener.
/// Extracted out of AIChatView.body because that body sits at the Swift
/// type-checker's expression budget and inlining another `.onReceive` block
/// trips the "compiler unable to type-check this expression in reasonable
/// time" diagnostic.
/// Listens for `.dismissAllImmersivePresentations` and calls the host
/// view's clear method. Extracted into its own modifier so AIChatView's
/// body type stays demangleable — adding the onReceive directly to body
/// trips the Swift type-checker timeout (same class of issue as the
/// 2026-04-17 inputBar / 2026-05-24 attachmentMenu blow-ups).
struct DismissImmersiveCoversListener: ViewModifier {
    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .dismissAllImmersivePresentations)) { _ in
            onDismiss()
        }
    }
}

struct ChatInputAppendListener: ViewModifier {
    let vm: AIChatViewModel
    @Binding var inputFocused: Bool

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .chatInputAppendRequested)) { note in
            guard let text = note.userInfo?["text"] as? String else { return }
            vm.appendToInputText(text)
            // Focus the composer + pop the keyboard so the user can
            // immediately continue typing after a long-press → Add to Chat
            // Input. Independent of the post-reply auto-pop Settings
            // toggle (#354 / eb6d8164) — that gate is for *passive*
            // moments (reply finished, scroll, etc.); this is a direct
            // user gesture and should always focus. (T-add-to-input-focus)
            //
            // Async hop so the inputText `didSet` settles into the
            // composer's TextField before the focus binding flips —
            // without it the keyboard occasionally pops first and the
            // text appears mid-animation.
            DispatchQueue.main.async {
                inputFocused = true
            }
        }
    }
}

// MARK: - Thinking Block View

/// [T-thinkperf-release-displaylink] Retired hitch monitor.
///
/// This was a CADisplayLink that ticked at 60fps for the entire life of an
/// expanded, streaming thinking block, logging frame gaps > 100ms plus a
/// per-second frame summary. It was pure instrumentation for
/// T-thinking-stream-jank: nothing ever read it but its own log lines.
///
/// It has been removed rather than `#if DEBUG`-gated, for two reasons:
///
///  1. It shipped. The originating commit (7573e28b8) called it "cheap enough
///     to stay on in Debug" but never gated it, so every Release build ran the
///     display link in the field. A 60fps timer's cost is not its tick body
///     (85ms of main-thread CPU across a 209s Time Profiler trace, 2026-08-11)
///     but the main-thread wake-up it forces every frame, which keeps the CPU
///     out of idle. `stop()` only began a 25s grace window, so it kept ticking
///     for 18s after the stream ended — observed at 172-190s while the app was
///     otherwise idle at ~15ms/s. That is the shape of a battery complaint,
///     and a CPU-percentage view hides it.
///  2. A display link perturbs exactly what it claims to measure: holding the
///     frame pipeline active changes the frame timing being sampled.
///
/// The jank it was built to investigate was diagnosed and fixed (the follow
/// trigger moved from per-delta to flush pace). Should that work resume, prefer
/// Instruments over a permanent in-app probe on a per-frame path.
///
/// The type is kept as an inert stub so call sites stay put and no behaviour
/// depends on whether a probe happens to be compiled in.
@MainActor
final class ThinkingHitchMonitor {
    static let shared = ThinkingHitchMonitor()

    /// Retained so `ThinkingBlockView` keeps compiling; nothing reads it.
    var bodyEvalCount = 0
    var contentLenProvider: (() -> Int)?

    func start(owner: UUID) {}
    func stop(owner: UUID) {}
}

struct ThinkingBlockView: View {
    @ObservedObject var block: AssistantBlock
    @ObservedObject private var appearanceStudio = AppearanceStudio.shared
    let isStreaming: Bool

    // [T-thinking-scroll-followback GH#125] Per-view follow state. Reset on
    // cell reuse / re-entry is fine — a fresh view simply follows again.
    @State private var thinkingUserScrolledAway = false
    @State private var lastThinkingDragAt: Date = .distantPast
    @State private var frozenThinkingContent: String? = nil

    /// Bind to block.isThinkingExpanded so state survives cell reuse and triggers cell re-sizing.
    private var isExpanded: Binding<Bool> {
        Binding(
            get: { block.isThinkingExpanded },
            set: { block.isThinkingExpanded = $0 }
        )
    }

    init(block: AssistantBlock, isStreaming: Bool) {
        self.block = block
        self.isStreaming = isStreaming
        // Auto-expand-on-stream is handled in `.onAppear` (gated by block.id)
        // rather than from `init`. Mutating @Published from a SwiftUI view
        // initializer fires for every cell-reuse pass and was reaching the
        // wrong block when the cell was being recycled between an earlier
        // (frozen) thinking block and the currently-streaming one — manifesting
        // as "tap an old thinking block, see the streaming block's content."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image("ThinkingIcon")
                    .resizable()
                    .frame(width: 14, height: 14)
                    .foregroundStyle(MinisThemeShape.thinkingAccent)
                Text(AppLocalized("Deep Thinking"))
                    .font(MinisThemeShape.fontFamily.font(size: MinisThemeShape.thinkingTitleSize, weight: .semibold))
                    .foregroundStyle(MinisThemeShape.thinkingAccent)
                if isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(MinisThemeShape.thinkingAccent)
                }
                if block.content.count > 0 || block.thinkingContentBuffer.count > 0 {
                    let charCount = max(block.content.count, block.thinkingContentBuffer.count)
                    Text(charCount > 1000 ? "\(charCount / 1000)K" : "\(charCount)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(MinisThemeShape.thinkingAccent.opacity(0.6))
                }
                Spacer()
                Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MinisThemeShape.thinkingAccent.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                // Mark before flipping so any concurrent stream-end collapse
                // observer in this view sees `thinkingUserToggled = true`
                // and bails out instead of stomping the user's choice.
                // The collection view's cached height is invalidated by the
                // `onChange(of: isThinkingExpanded)` observer below — single
                // source of truth so the auto-collapse path stays in sync.
                AppLogger(category: "ThinkingCollapse").info("[ThinkingCollapse] tap block=\(block.id.uuidString.prefix(8)) wasExpanded=\(isExpanded.wrappedValue) streaming=\(isStreaming) contentLen=\(block.content.count)")
                block.thinkingUserToggled = true
                if !isExpanded.wrappedValue {
                    block.flushThinkingBuffer()
                }
                isExpanded.wrappedValue.toggle()
            }

            // Content — only visible when expanded, windowed to the tail
            // to prevent UI freeze on very long thinking (T-thinking-render-perf-ios).
            if isExpanded.wrappedValue, !block.content.isEmpty {
                // [T-thinking-stream-window] While STREAMING, shrink the tail
                // window 8000 → 2000: every flush re-lays-out the whole Text
                // on the main thread, and an 8K plain-text relayout per flush
                // is the reported "5K starts to lag, 10K unusable" jank (the
                // hitch cost scales with the WINDOW, not the total). Reading
                // the live tail only needs the recent context; the full 8K
                // window comes back the moment streaming ends.
                let windowSize = isStreaming ? 2000 : 8000
                let total = block.content.count
                let isTruncated = total > windowSize
                let displayContent: String = frozenThinkingContent ?? {
                    // [T-thinkperf-release-displaylink] The slice timing and
                    // body-eval counter that used to wrap this closure are gone.
                    // It runs on EVERY body evaluation of an expanded thinking
                    // block, so it paid two CFAbsoluteTimeGetCurrent calls per
                    // eval to feed a counter only ThinkPerf's own log lines read.
                    // The question it existed to answer — do body re-evals track
                    // per-token contentUpdateSeq rather than the flush? — was
                    // answered (they did) and fixed.
                    let windowed: String
                    if isTruncated {
                        let startIdx = block.content.index(block.content.endIndex, offsetBy: -windowSize)
                        let cleanStart = block.content[startIdx...].firstIndex(of: "\n")
                            .map { block.content.index(after: $0) } ?? startIdx
                        windowed = String(block.content[cleanStart...])
                    } else {
                        windowed = block.content
                    }
                    // [10-18 醒醒 第五轮] thinking 也能被正则改。
                    // 上一版 `scopes` 里写 "reasoning" 的规则没有落点。
                    // [10-19 醒醒] 全局正则。
                    return GlobalRegexStore.shared.apply(to: windowed, role: "reasoning", visual: true)
                }()

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if isTruncated {
                                Text("Showing last \(displayContent.count / 1000)K of \(total / 1000)K characters", comment: "Thinking window truncation hint")
                                    .font(.system(size: 11))
                                    .foregroundStyle(MinisTheme.secondaryText)
                                    .padding(.horizontal, 12)
                                    .padding(.bottom, 4)
                            }
                            // [T-thinking-stream-jank] textSelection(.enabled)
                            // makes SwiftUI Text substantially more expensive
                            // per layout; selecting text that is actively
                            // moving is useless anyway — enable it only once
                            // streaming finished.
                            let thinkingText = Text(displayContent)
                                .font(MinisThemeShape.fontFamily.font(size: MinisThemeShape.thinkingBodySize))
                                .foregroundStyle(ChatColors.tertiaryText)
                                .lineSpacing(3)
                            Group {
                                if isStreaming {
                                    thinkingText
                                } else {
                                    thinkingText.textSelection(.enabled)
                                }
                            }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 10)
                                .id("thinkingBottom")
                        }
                    }
                    .frame(maxHeight: 300)
                    // [T-thinking-scroll-followback GH#125] User-intent gate,
                    // Android parity (ChatAssistantMessageUI.kt): mark
                    // scrolled-away ONLY when a real finger drag moved the view
                    // off the bottom — programmatic scrollTo offsets must not
                    // set it, or follow would permanently disarm. Deployment
                    // target is iOS 16 (no onScrollPhaseChange), so "real drag"
                    // = a simultaneous DragGesture seen within the last 350ms.
                    // A downward drag inside the box means "show me earlier
                    // text" — that IS the scrolled-away intent, and unlike a
                    // geometry probe it cannot be spoofed by our own
                    // programmatic scrollTo (which fires no gesture). An
                    // upward drag (heading back toward the tail) re-arms
                    // following, as does the stream ending.
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 6)
                            .onEnded { value in
                                lastThinkingDragAt = Date()
                                if value.translation.height > 12 {
                                    if !thinkingUserScrolledAway {
                                        thinkingUserScrolledAway = true
                                        frozenThinkingContent = displayContent
                                        AppLogger(category: "ThinkPerf").info("[ThinkPerf] user scrolled away (dy=\(Int(value.translation.height))) — follow paused, content frozen at \(displayContent.count) chars")
                                    }
                                } else if value.translation.height < -12, thinkingUserScrolledAway {
                                    thinkingUserScrolledAway = false
                                    frozenThinkingContent = nil
                                    AppLogger(category: "ThinkPerf").info("[ThinkPerf] user scrolled back (dy=\(Int(value.translation.height))) — following resumed")
                                }
                            }
                    )
                    // [T-thinking-stream-jank] Follow the tail at FLUSH pace
                    // (content updates every 0.3s), not per token. The old
                    // trigger was the per-delta contentUpdateSeq — with it
                    // @Published, an expanded block re-ran body + an animated
                    // scrollTo for every delta (~60-105/s measured); the flush
                    // pace is ~3-4/s for the same visual result.
                    .onChange(of: block.content.count) { len in
                        guard isStreaming, !thinkingUserScrolledAway else { return }
                        // [T-thinkperf-release-displaylink] Removed: this fired on
                        // every content flush of a streaming thinking block, and
                        // building the interpolated string cost more than the log
                        // call. The two scroll-gesture lines above stay — they
                        // fire once per user drag, not per flush.
                        // Animated follow only for short content — animating a
                        // long text's scroll re-lays-out every frame of the
                        // 0.15s animation; a jump is one layout.
                        if len > 3000 {
                            proxy.scrollTo("thinkingBottom", anchor: .bottom)
                        } else {
                            withAnimation(.linear(duration: 0.15)) {
                                proxy.scrollTo("thinkingBottom", anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: isStreaming) { streaming in
                        if !streaming {
                            thinkingUserScrolledAway = false
                            frozenThinkingContent = nil
                        }
                    }
                }
            }
        }
        // [T-thinking-stream-jank] Hitch monitor runs while this block is
        // EXPANDED — streaming or static. The refined report says the jank is
        // tied to the expanded state itself (collapse instantly recovers), so
        // the monitor must also capture expanded-static interactions (list
        // scrolling, new messages arriving) to compare against collapsed.
        .task(id: isExpanded.wrappedValue) {
            if isExpanded.wrappedValue {
                ThinkingHitchMonitor.shared.contentLenProvider = { [weak block] in
                    block?.thinkingContentBuffer.count ?? -1
                }
                ThinkingHitchMonitor.shared.start(owner: block.id)
            } else {
                ThinkingHitchMonitor.shared.stop(owner: block.id)
            }
        }
        .onDisappear {
            ThinkingHitchMonitor.shared.stop(owner: block.id)
        }
        .background {
            ZStack {
                MinisThemeShape.thinkingFill
                if let image = appearanceStudio.thinkingCardImage() {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .opacity(MinisThemeShape.thinkingCardOpacity)
                }
            }
        }
        .clipShape(MinisThemeShape.thinkingCard)
        .overlay(
            MinisThemeShape.thinkingCard.stroke(MinisThemeShape.thinkingStroke, lineWidth: 0.5)
        )
        .id(appearanceStudio.themePackRevision)
        .task(id: block.id) {
            // One-shot per-block auto-expand. Runs when this cell first hosts
            // a given thinking block (block.id is stable across content
            // updates) and only flips state if the user hasn't taken control.
            // [T-thinking-auto-expand-toggle] Gated on the Appearance setting
            // (default ON = historical behavior). When the user turned it off,
            // new streaming thinking blocks stay collapsed; a manual tap still
            // expands them (and sets thinkingUserToggled, so nothing here
            // fights the user either way).
            let autoExpand = (UserDefaults.standard.object(forKey: "chat.autoExpandThinking") as? Bool) ?? true
            if autoExpand, isStreaming, !block.thinkingUserToggled, !block.isThinkingExpanded {
                block.isThinkingExpanded = true
            }
        }
        .onChange(of: isStreaming) { streaming in
            // Auto-collapse when streaming for THIS block ends, but only if
            // the user hasn't manually toggled it. Without the user-touched
            // gate, the streaming-end transition stomped a tap the user did
            // on an earlier thinking block while a later one was still live.
            if !streaming, !block.thinkingUserToggled {
                AppLogger(category: "ThinkingCollapse").info("[ThinkingCollapse] auto-collapse block=\(block.id.uuidString.prefix(8)) streaming→false userToggled=false contentLen=\(block.content.count)")
                block.isThinkingExpanded = false
                // [T-ios-thinking-autocollapse-no-post] Post the invalidation
                // HERE rather than relying on the `.onChange(of:)` below.
                //
                // Field evidence (2026-08-13 device log): `auto-collapse` fired
                // 6 times while `[ThinkingCollapse] post` fired 0 times. The
                // observer never ran, because this write happens inside another
                // `onChange` handler in the same view update — SwiftUI compares
                // `isThinkingExpanded` before and after that update as a whole,
                // and the write is not observed as a transition. A manual tap is
                // its own update, which is why tapping to collapse always worked
                // and only the stream-end auto-collapse left a gap.
                //
                // Without the post, `SelfSizingCell`'s width-keyed dedup keeps
                // answering with the EXPANDED height (the cache the
                // `.thinkingBlockToggled` receiver exists to clear), so the pill
                // draws collapsed inside a frame still sized for the expanded
                // body — the blank strip under the first thinking block.
                //
                // Posting from both places is safe: the receiver only clears
                // caches and reconfigures, and a duplicate notification
                // re-measures to the same height.
                NotificationCenter.default.post(name: .thinkingBlockToggled,
                                                object: block.id)
            } else if !streaming {
                AppLogger(category: "ThinkingCollapse").info("[ThinkingCollapse] stream-end-skip block=\(block.id.uuidString.prefix(8)) userToggled=\(block.thinkingUserToggled) currentlyExpanded=\(block.isThinkingExpanded)")
            }
        }
        .onChange(of: block.isThinkingExpanded) { newValue in
            // Single source of truth for cell-height invalidation: fires
            // for BOTH manual taps and the stream-end auto-collapse path
            // above. Previously only the tap gesture posted this, so when
            // a long thinking block auto-collapsed at stream end, the
            // UICollectionView kept the expanded cell height (~300pt) and
            // rendered a tall empty gap below the pill — see 2026-05-17
            // screenshot bug.
            AppLogger(category: "ThinkingCollapse").info("[ThinkingCollapse] post block=\(block.id.uuidString.prefix(8)) expanded=\(newValue) userToggled=\(block.thinkingUserToggled) streaming=\(isStreaming)")
            NotificationCenter.default.post(name: .thinkingBlockToggled,
                                            object: block.id)
        }
    }
}

// MARK: - Typing Indicator

struct TypingIndicator: View {
    @State private var dotOffsets: [Bool] = [false, false, false]
    /// [batch9d / W1C-08] 会话绑定人设 id（nil = 草稿态，回退全局当前人设）。
    /// 气泡名按它取——与"回答的人"一致，不再跟着全局切换漂移。
    var personaId: String? = nil
    /// Live Soul name so the indicator reads "<custom name> is thinking…" when
    /// the user has renamed the assistant in Soul settings. Updates via
    /// `.soulMdChanged` / `.personaDidChange`, plus an onAppear refresh.
    @State private var soulName: String = "嘟嘟"

    private func refreshSoulName() {
        soulName = SoulStore.displayName(for: SoulStore.displayPersonaId(personaId))
    }

    var body: some View {
        // The thinking-level badge that used to trail this indicator was
        // removed — the nav-bar title (AIChatView.thinkingLevelBadge) is now
        // the single place that shows and changes the thinking level, so a
        // duplicate here was redundant. ThinkingLevelSheetView is unchanged;
        // it's still presented from the nav-bar badge.
        HStack(spacing: 0) {
            Text("\(soulName) is thinking")
            ForEach(0..<3, id: \.self) { i in
                Text(".")
                    .offset(y: dotOffsets[i] ? -3 : 1)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .soulMdChanged)) { _ in
            refreshSoulName()
        }
        .onReceive(NotificationCenter.default.publisher(for: .personaDidChange)) { _ in
            refreshSoulName()
        }
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(ChatColors.tertiaryText)
        .padding(.top, 0)
        .onAppear {
            refreshSoulName()
            for i in 0..<3 {
                withAnimation(
                    .easeInOut(duration: 0.4)
                        .repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.15)
                ) {
                    dotOffsets[i] = true
                }
            }
        }
    }
}

// MARK: - Thinking Level Sheet

struct ThinkingLevelSheetView: View {
    let currentLevel: ThinkingLevel
    let availableLevels: [ThinkingLevel]
    let onSelect: (ThinkingLevel) -> Void

    var body: some View {
        NavigationStack {
            List {
                thinkingRow(level: .off, isSelected: !currentLevel.isEnabled)
                Section {
                    ForEach(availableLevels, id: \.self) { level in
                        thinkingRow(level: level, isSelected: currentLevel == level)
                    }
                }
            }
            .navigationTitle(AppLocalized("Thinking Intensity"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func thinkingRow(level: ThinkingLevel, isSelected: Bool) -> some View {
        Button {
            onSelect(level)
        } label: {
            HStack {
                Image("ThinkingIcon")
                    .resizable()
                    .frame(width: 16, height: 16)
                    .opacity(level == .off ? 0.4 : 1.0)
                Text(level.displayName)
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(ChatColors.accent)
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - Tool Copy Button


