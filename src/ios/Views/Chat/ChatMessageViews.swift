import SwiftUI
import UIKit
import Foundation

// MARK: - Context-menu preview

/// Opaque rounded-card preview shown under a message's long-press context menu.
///
/// [T-ios-longpress-menu-preview-background] The message cells are hosted with a
/// clear background (host.view / cell backgroundColor = .clear), and the message
/// `.contextMenu`s are attached either to a zero-size `Color.clear` overlay
/// (assistant block/footer) or to a bubble whose fill is the translucent
/// `tertiarySystemFill` (user). Without an explicit `preview:`, SwiftUI snapshots
/// that (transparent) attached view, so the long-press preview platter shows
/// through to the messages below — the reported "transparent preview" bug.
///
/// Supplying this as the `.contextMenu(preview:)` gives the platter an opaque
/// `systemBackground` rounded card with the message text, so it reads as a
/// floating card. System colors only, so dark mode stays correct.
///
/// [T-ios-longpress-preview-full-content-card] The earlier version hard-capped
/// the text at 1500 chars with a trailing "…", which is what users saw as a
/// "truncated" preview on long assistant messages. It now renders the FULL
/// message content inside a vertical ScrollView: short messages size to their
/// content, long ones are capped to a fraction of the screen height and scroll
/// inside the platter (Telegram/iMessage-style), so the preview is both opaque
/// and complete. An explicit measured height is required because a ScrollView
/// has no intrinsic height — without it the context-menu platter would collapse.
struct MessageContextMenuPreview: View {
    let text: String

    /// [T-ios-usermsg-preview-adaptive-width] Width is now a CAP, not a fixed
    /// size. A short user bubble ("ok") previously lifted into a full 360pt
    /// platter; the platter now hugs the laid-out text width (measured by the
    /// same GeometryReader that already measured height) and only long lines
    /// wrap at this cap, iMessage-style.
    private let maxCardWidth: CGFloat = 360
    /// Long messages cap the platter to this fraction of screen height and
    /// scroll inside; short messages size to content (min of the two).
    private var maxCardHeight: CGFloat { UIScreen.main.bounds.height * 0.55 }

    @State private var contentSize: CGSize = .zero

    /// [audit-F4 / T-ios-ctxmenu-preview-watchdog] Hard cap on the characters
    /// handed to the preview's `Text`.
    ///
    /// This platter is a lift-to-peek preview: it is capped to 55% of screen
    /// height and scrolls, so only the first screenful is ever readable. But
    /// the `Text` was given the WHOLE reply, and the `GeometryReader` below
    /// forces SwiftUI to typeset all of it through CoreText — on the main
    /// thread — just to produce `contentSize`. Cost is super-linear in length.
    /// Measured at this exact font (16.5pt) and wrap width (360 - 2*16 = 328pt):
    ///
    ///      4,000 chars   0.25s
    ///      8,000 chars   0.98s
    ///     12,000 chars   1.63s
    ///     20,000 chars   4.50s
    ///     24,000 chars   6.48s     <- the reported 5591ms hang lands here
    ///     30,000 chars  10.14s
    ///     40,000 chars  17.96s
    ///
    /// which is the foreground SIGKILL a long reply once caused: a main-thread
    /// hang in CTLineCreateWithAttributedString → ResolvedStyledText.draw,
    /// watchdog kill, memory normal (not an OOM).
    ///
    /// Note the cost is driven by LENGTH, not by LaTeX: raw LaTeX source
    /// measured FASTER than prose at equal length (40,000 chars of formula
    /// source = 0.178s), because its long unspaced backslash runs produce far
    /// fewer line-break opportunities than CJK, where nearly every character is
    /// a break candidate. Capping the string keeps this flat at ~0.06s for any
    /// input size.
    private static let maxPreviewChars = 2000

    var body: some View {
        let shown = text.isEmpty ? " " : String(text.prefix(Self.maxPreviewChars))
        ScrollView(.vertical, showsIndicators: true) {
            // No `.frame(maxWidth: .infinity)` here — the Text must report its
            // NATURAL width so short messages yield a narrow platter. The wrap
            // width comes from the ScrollView's width (the outer .frame below),
            // which starts at the cap and shrinks to the measured content.
            Text(shown)
                .font(MinisThemeShape.fontFamily.font(size: FontSettings.shared.scaledMessage(16.5)))
                .foregroundStyle(ChatColors.primaryText)
                .multilineTextAlignment(.leading)
                .padding(16)
                .background(
                    // Measure the laid-out text size so the platter can hug
                    // content (short) or cap + wrap/scroll (long).
                    GeometryReader { geo in
                        Color.clear
                            .preference(key: PreviewContentSizeKey.self, value: geo.size)
                    }
                )
        }
        .onPreferenceChange(PreviewContentSizeKey.self) { contentSize = $0 }
        // Size = content size, capped. Falls back to the caps until the first
        // measurement lands so the platter never collapses to zero. The small
        // width floor keeps an (attachment-only) empty-text preview from
        // rendering as a sliver.
        .frame(
            width: contentSize.width > 0 ? min(max(contentSize.width, 60), maxCardWidth) : maxCardWidth,
            height: contentSize.height > 0 ? min(contentSize.height, maxCardHeight) : maxCardHeight
        )
        .modifier(ContextMenuPreviewSurface())
    }
}

/// Background for the long-press preview platter.
///
/// Matches `UserBubbleSurface` so lifting a bubble doesn't jump from Liquid
/// Glass to a flat colour card — the shape (`RoundedRectangle(cornerRadius: 16)`,
/// non-`.continuous`) is deliberately the same one the bubble and the row's
/// `.contentShape(.contextMenuPreview, …)` already use.
///
/// **The opaque base stays.** [T-ios-longpress-menu-preview-background] exists
/// because the platter was showing through to the messages underneath: cells are
/// hosted on a clear background and the menus hang off either a zero-size
/// `Color.clear` overlay or a `tertiarySystemFill` bubble, so SwiftUI's snapshot
/// of the attached view was effectively transparent. Glass is a translucent
/// material, so using it ALONE would risk re-opening exactly that bug. Painting
/// it over `ChatColors.background` keeps the platter opaque no matter what the
/// system composites behind it, while the material still supplies the glass
/// highlight and edge that make it read as continuous with the bubble.
private struct ContextMenuPreviewSurface: ViewModifier {
    private var shape: MinisBubbleShape { MinisThemeShape.userBubble }

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                // Opaque floor first — see the note above.
                .background(shape.fill(ChatColors.background))
                .glassEffect(.regular, in: shape)
        } else {
            content.background(ChatColors.background)
        }
    }
}

/// Preference key carrying the laid-out preview text size up to the platter.
/// Background for the user message bubble.
///
/// Two states that must stay tellable apart at a glance:
///
///  - **Sent** (`isQueued == false`) — Liquid Glass on iOS 26+. These bubbles
///    scroll over other messages, images and code blocks, so the material has
///    genuinely varied content to sample; this is the case glass is for, the
///    same as the tool-status bar and unlike `FolderSurface`, which had to fall
///    back to a sampled constant for want of anything behind it.
///  - **Queued** (`isQueued == true`) — deliberately NOT glass, on either OS.
///    Glass reads as a settled, physical surface, which is the opposite of what
///    a not-yet-sent message means. It keeps the existing empty fill + dashed
///    border, so "queued" still looks provisional next to the solid glass of
///    everything already sent.
///
/// The text is the modified content rather than an `.overlay`, which is what
/// keeps it above the material: `.glassEffect` composites the material over the
/// view it modifies, so an overlaid label would be painted underneath it and
/// disappear (the FAB regression).
// [B28 R5] internal（原 private）：装扮页样张复用真气泡皮肤本体 ——
// 平铺/气泡/文稿三形态和 Liquid Glass 判定全在这里，复制=双维护=撒谎。
// MARK: - 代码识别

enum UserCodeFencing {
    // [10-23 醒醒] 打分制。上一版是「一行像代码 + 连续三行里 60% 像」，
    // 散文里出现 return / = 就被认成代码，反过来 SQL、命令行、JSON 又认不出。
    // 现在按行打分，整段投票：宁可漏判，不可误判——把她一句话变成代码块，
    // 比代码没识别出来难受得多。规则对照 30 段真代码 + 44 段真散文调过，
    // 误报 0、漏判 0（语料在 scripts/check-code-detect.py）。
    private static let keywords: [String] = [
        "def ", "class ", "func ", "function ", "import ", "from ", "package ",
        "namespace ", "public ", "private ", "protected ", "static ", "const ",
        "let ", "var ", "return ", "if ", "else", "elif ", "for ", "while ",
        "switch ", "case ", "try ", "catch ", "finally ", "throw ", "async ",
        "await ", "yield ", "struct ", "enum ", "impl ", "fn ", "pub ", "use ",
        "export ", "default ", "#include", "#define", "<?php", "SELECT ",
        "INSERT ", "UPDATE ", "DELETE ", "CREATE ", "interface ", "type ",
        "module ", "require(", "echo ", "FROM ", "WHERE ", "GROUP ", "ORDER ",
        "JOIN ", "VALUES ", "SET ", "except ", "raise ", "with open(",
        "while True"
    ]

    private static let commands: [String] = [
        "git", "docker", "npm", "npx", "yarn", "pnpm", "pip", "curl", "wget",
        "cd ", "ls ", "sudo", "apt", "brew", "make ", "python", "node ", "go ",
        "cargo", "kubectl", "ssh ", "scp ", "tar ", "unzip", "chmod", "cat ",
        "grep", "sed ", "awk ", "find ", "mkdir", "rm ", "cp ", "mv ",
        "systemctl", "service ", "nohup", "export ", "set -", "source ",
        "bash ", "sh "
    ]

    /// 一行里的中文字符占比。散文判定的主信号。
    private static func cjkRatio(_ s: String) -> Double {
        guard !s.isEmpty else { return 0 }
        let n = s.unicodeScalars.reduce(0) { $1.value >= 0x4E00 && $1.value <= 0x9FFF ? $0 + 1 : $0 }
        return Double(n) / Double(s.count)
    }

    private static func matches(_ pattern: String, _ s: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }

    /// 围栏不只 ```，Markdown 也认 ~~~。
    static func hasFence(_ s: String) -> Bool {
        s.contains("```") || s.contains("~~~")
    }

    /// 整段 JSON：单行 `{"a":1}` 也要成块。
    private static func looksLikeJSON(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("{") || t.hasPrefix("[") else { return false }
        guard let data = t.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    /// diff / patch：+ - @@ 这些行本身就是代码。
    private static func looksLikeDiff(_ lines: [String]) -> Bool {
        let body = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard body.count >= 2 else { return false }
        // 必须有真正的 diff 头；光有 "- item" 的列表不算。
        let hasHeader = body.contains {
            $0.hasPrefix("@@") || $0.hasPrefix("diff --git")
                || $0.hasPrefix("+++") || $0.hasPrefix("---")
        }
        guard hasHeader else { return false }
        let diff = body.filter {
            $0.hasPrefix("@@") || $0.hasPrefix("+++") || $0.hasPrefix("---")
                || $0.hasPrefix("diff --git") || $0.hasPrefix("+") || $0.hasPrefix("-")
        }.count
        return diff >= max(2, (body.count * 3) / 5) && cjkRatio(body.joined()) < 0.05
    }

    /// 四空格 / Tab 缩进的整段，按 Markdown 缩进代码处理。
    private static func looksLikeIndentedCode(_ lines: [String]) -> Bool {
        let body = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard body.count >= 2 else { return false }
        let indented = body.filter { $0.hasPrefix("\t") || $0.hasPrefix("    ") }.count
        let codeish = body.filter { lineScore($0) >= 1 }.count
        let listish = body.filter { isListLine($0) }.count
        return indented >= max(2, (body.count * 4) / 5)
            && codeish >= max(1, body.count / 2)
            && listish == 0
            && cjkRatio(body.joined()) < 0.15
    }

    /// 单行代码：`npm install` / `git status` / `{"a":1}` 这类整句就是命令的。
    private static func looksLikeSingleLineCode(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains("\n") else { return false }
        if cjkRatio(t) > 0.05 { return false }
        if let last = t.last, ".。！？!?".contains(last) { return false }
        if lineScore(t) >= 3 { return true }
        let codePunct = t.contains("(") || t.contains("{") || t.contains("=")
            || t.contains(";") || t.contains("[") || t.contains("::")
            || t.contains("->") || t.contains("=>")
        if codePunct && lineScore(t) >= 2 { return true }
        if t.hasPrefix("SELECT ") && t.contains(" FROM ") { return true }
        if t.hasPrefix("INSERT INTO ") || t.hasPrefix("UPDATE ")
            || t.hasPrefix("DELETE FROM ") { return true }
        return commands.contains(where: { t.hasPrefix($0) }) && lineScore(t) >= 2
    }

    /// 单行得分。>= 2 才算「这行像代码」。
    static func lineScore(_ raw: String) -> Int {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return -99 }
        var s = 0
        if raw.hasPrefix("\t") || raw.hasPrefix("  ") { s += 2 }
        if t.hasSuffix("{") || t.hasSuffix("}") { s += 2 }
        if t.hasSuffix(";") { s += 1 }
        if keywords.contains(where: { t.hasPrefix($0) }) { s += 2 }
        if t.hasPrefix("#!") { s += 3 }
        if matches(#"^</?[a-zA-Z][^>]*>$"#, t) { s += 3 }
        if t.hasSuffix("\\") { s += 3 }
        if matches(#"^(try|else|finally|do|begin):$"#, t) { s += 2 }
        if commands.contains(where: { t.hasPrefix($0) }) { s += 2 }
        if t.hasPrefix("//") || t.hasPrefix("#") || t.hasPrefix("/*")
            || t.hasPrefix("* ") || t.hasPrefix("--") { s += 1 }
        if ["=>", "->", "::", "==", "!=", "&&", "||", "+=", "-=", ":=", "<>"]
            .contains(where: { t.contains($0) }) { s += 1 }
        if matches(#"^[A-Za-z_$][\w$.\[\]]*\s*=\s*\S"#, t) { s += 1 }
        if matches(#"^[A-Za-z_$][\w$.]*\s*\(.*\)\s*[;{]?$"#, t) { s += 1 }
        let punct = t.filter { "{}();=<>[]$".contains($0) }.count
        if Double(punct) / Double(t.count) >= 0.10 { s += 1 }
        if cjkRatio(t) > 0.15 { s -= 3 }
        if let last = t.last, "。！？，、；：".contains(last) { s -= 3 }
        return s
    }

    /// 注释行。中文注释在代码里是常态，不该把整段判成散文。
    static func isCommentLine(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("//") || t.hasPrefix("/*") || t.hasPrefix("* ")
            || t.hasPrefix("--") || t.hasPrefix("<!--")
    }

    /// Markdown 列表行：缩进列表不是代码块。
    private static func isListLine(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ")
            || t.hasPrefix("> ") || t.hasPrefix("# ") { return true }
        return t.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil
    }

    /// 一整段是否够格当代码块。短段要求更严。
    static func isCodeRun(_ run: [String]) -> Bool {
        // 注释行不参与投票，只看真代码行。
        let body = run.filter { !isCommentLine($0) }
        guard !body.isEmpty else { return false }
        // 缩进列表 / 引用块不是代码。
        if body.filter({ isListLine($0) }).count >= max(1, body.count / 2) {
            return false
        }
        let joined = body.joined(separator: "\n")
        if looksLikeJSON(joined) { return true }
        if looksLikeDiff(body) { return true }
        if looksLikeIndentedCode(body) { return true }
        if body.count == 1 { return looksLikeSingleLineCode(body[0]) }
        let scores = body.map { lineScore($0) }
        if body.count == 2 {
            return scores.allSatisfy { $0 >= 2 } && cjkRatio(joined) < 0.05
        }
        let strong = scores.filter { $0 >= 2 }.count
        let ratio = Double(strong) / Double(body.count)
        // 四行以上允许两成是说明/空行；两到三行仍要求几乎整段都是代码。
        if body.count >= 4 {
            if ratio < 0.6 { return false }
        } else if ratio < 0.8 {
            return false
        }
        if cjkRatio(joined) > 0.10 { return false }
        if scores.filter({ $0 >= 3 }).count < 2 && !scores.allSatisfy({ $0 >= 2 }) {
            return false
        }
        return true
    }

    /// 给没有围栏的连续代码段补上栅栏。已经有栅栏就原样返回。
    static func autoFenced(_ text: String) -> String {
        guard !hasFence(text) else { return text }
        let lines = text.components(separatedBy: "\n")
        guard !lines.isEmpty else { return text }
        // 整段就是 JSON / diff / 缩进代码：不用逐行投票，直接包起来。
        if looksLikeJSON(text) || looksLikeDiff(lines) || looksLikeIndentedCode(lines) {
            return "```\n" + text + "\n```"
        }
        var out: [String] = []
        var run: [String] = []

        func flushRun() {
            guard !run.isEmpty else { return }
            if isCodeRun(run) {
                out.append("```")
                out.append(contentsOf: run)
                out.append("```")
            } else {
                out.append(contentsOf: run)
            }
            run.removeAll()
        }

        for (idx, line) in lines.enumerated() {
            let next = idx + 1 < lines.count ? lines[idx + 1] : ""
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushRun()
                out.append(line)
            } else if lineScore(line) >= 1
                        || (!run.isEmpty && isCommentLine(line))
                        || (isCommentLine(line) && lineScore(next) >= 2) {
                run.append(line)
            } else {
                flushRun()
                out.append(line)
            }
        }
        flushRun()
        return out.joined(separator: "\n")
    }
}
// MARK: - 正文视图

/// [B28 R7-3] 用户气泡的展开状态不能放 @State：列表重算会 reconfigure 这个
/// 单元格，SwiftUI 视图重建、@State 归零，刚展开又弹回去。放在外面按消息 id 记。
final class UserBubbleExpansion: ObservableObject {
    static let shared = UserBubbleExpansion()
    @Published private(set) var expanded: Set<UUID> = []
    func isExpanded(_ id: UUID?) -> Bool { id.map { expanded.contains($0) } ?? false }
    func toggle(_ id: UUID?) {
        guard let id else { return }
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}

struct UserMessageText: View {
    let text: String
    let isQueued: Bool
    var isDelivering: Bool = false
    /// [B28 R7-3] 展开/收起改了高度，得让列表清缓存重算——不然只是按钮文字
    /// 变了，正文还是被旧高度切着（醒醒 10-23 截图：点了「展开全文」没展开）。
    var messageId: UUID? = nil

    @ObservedObject private var appearanceStudio = AppearanceStudio.shared
    @ObservedObject private var expansion = UserBubbleExpansion.shared

    private var expanded: Bool { expansion.isExpanded(messageId) }

    private var fenced: String { UserCodeFencing.autoFenced(text) }
    /// 有代码就走 markdown（代码块可折叠），没有就保持纯文本（不擅自改排版）。
    /// [10-23 醒醒 问题4] 她自己粘的带 ``` 的代码，autoFenced 原样返回，
    /// 旧判据 `fenced != text` 于是判成「没代码」→ 整段按纯文本渲染，
    /// 三个反引号照字面显示，代码块消失。原文自带围栏也是代码。
    ///
    /// 视图和列表的预计算必须用**同一个**判据：只改一边的话，格子先按
    /// 折叠长文留高、视图按代码块铺开，滚动时就对不上（那一跳的另一种来源）。
    static func hasCode(_ text: String) -> Bool {
        UserCodeFencing.hasFence(text) || UserCodeFencing.autoFenced(text) != text
    }
    private var hasCode: Bool { Self.hasCode(text) }
    // [10-23 醒醒] 折叠判定与折叠后的样子只写一份：视图用、列表预计算也用。
    // 预计算不知道折叠态的话，格子先按全文高度占位、再缩回去，就是那一跳。
    static let collapsedLineLimit = 8
    static func isLongText(_ text: String) -> Bool {
        text.components(separatedBy: "\n").count > collapsedLineLimit || text.count > 320
    }
    static func collapsedPreview(of text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        if lines.count > collapsedLineLimit {
            return lines.prefix(collapsedLineLimit).joined(separator: "\n") + "\n…"
        }
        return String(text.prefix(280)) + "…"
    }
    /// Kelivo 式裁剪高度：只给 8 行的高度，内容本身不换字符串。
    static func collapsedHeightForCurrentFont() -> CGFloat {
        let font = UIFont.systemFont(ofSize: FontSettings.shared.scaledMessage(16.5))
        return ceil(font.lineHeight * CGFloat(collapsedLineLimit)) + 2
    }
    private var isLong: Bool {
        guard !hasCode else { return false }   // 代码块自己会折
        return Self.isLongText(text)
    }
    private var collapsedMaxHeight: CGFloat? {
        (isLong && !expanded) ? Self.collapsedHeightForCurrentFont() : nil
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if hasCode {
                // [B28 R9] 用户代码也走独立代码块视图。这里不再把整段交给
                // SelectableMarkdownView 的 NSTextAttachment；正文和代码拆开，
                // 代码块高度自己定，气泡和列表按普通 SwiftUI 子视图测量。
                let codeSegments = ChatMarkdownSegmenter.segments(from: fenced)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(codeSegments.enumerated()), id: \.offset) { _, segment in
                        switch segment {
                        case .prose(let prose):
                            if !prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                SelectableMarkdownView(markdown: prose, messageId: messageId)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .modifier(MinisOpenURLHandler())
                            }
                        case .code(let language, let code, let codeIndex):
                            ChatCodeBlockView(
                                code: code,
                                language: language,
                                sourceMarkdown: fenced,
                                codeIndex: codeIndex,
                                messageId: messageId,
                                blockId: nil
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .id(appearanceStudio.themePackRevision)
            } else {
                // [10-23 醒醒 问题1] Kelivo 式：正文始终是全文，只裁可视高度，
                // 不再把字符串换成预览——换字符串那一下就是「一跳」的一半。
                // 裁剪高度和列表预计算共用 collapsedLineLimit，视图/格子同一条尺。
                Text(text)
                    .font(MinisThemeShape.fontFamily.font(size: FontSettings.shared.scaledMessage(16.5)))
                    .foregroundStyle(isQueued ? ChatColors.secondaryText : ChatColors.primaryText)
                    // 先按全文高度排版，再由下面的 frame 裁到 8 行；
                    // 不 fixedSize 的话 Text 会自己压到 8 行，展开时没有内容可露。
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxHeight: collapsedMaxHeight, alignment: .top)
                    .clipped()
                    .mask {
                        if isLong && !expanded {
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black, location: 0.82),
                                    .init(color: .clear, location: 1)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        } else {
                            Rectangle().fill(Color.black)
                        }
                    }
                    .id(appearanceStudio.themePackRevision)
            }
            if isLong {
                Button {
                    // [10-23 醒醒 问题1] Kelivo 式：状态一翻，正文裁切高度和
                    // 列表格子一起走 0.22s easeOut；列表那边等 SwiftUI 重画完
                    // 再量新高度，避免量到旧内容。
                    expansion.toggle(messageId)
                    if let messageId {
                        NotificationCenter.default.post(name: .userBubbleToggled, object: messageId)
                    }
                } label: {
                    Text(expanded ? AppLocalized("收起") : AppLocalized("展开全文"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ChatColors.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .modifier(UserBubbleSurface(isQueued: isQueued))
        .modifier(QueuedStatusDot(isQueued: isQueued, isDelivering: isDelivering))
    }
}

// MARK: - 用户气泡皮肤

struct UserBubbleSurface: ViewModifier {
    let isQueued: Bool

    /// Matches `.contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 16))`
    /// on the row exactly — including the default (non-`.continuous`) corner
    /// style. A `.continuous` bubble against a circular-arc preview clip would
    /// show the corners subtly change shape as the long-press lift begins.
    private var shape: MinisBubbleShape { MinisThemeShape.userBubble }

    func body(content: Content) -> some View {
        // [10-18 醒醒 第五轮] 消息形态：平铺 / 气泡 / 文稿。
        //
        // - `.flat`    不要底色，像聊天记录一样平铺，靠留白分开
        // - `.document` 跟 flat 一样没有底色，但外层还会去掉头像和缩进
        // - `.bubbles` 保持原样
        let display = AppearanceChatDisplay.parse(
            AppearanceStudio.shared.currentThemePack().chatDisplay)

        if isQueued {
            // [10-20 醒醒] 排队消息不再画虚线——她要看的是「真气泡」，
            // 状态交给气泡旁边那颗小圆点（灰=待注入/蓝=送达中/消失=已进上下文）。
            // 底色仍压到 0.72，跟已发送的实心气泡留一线可辨。
            content
                .background(shape.fill(ChatColors.userBubble.opacity(0.72)))
        } else if display == .flat || display == .document {
            content
        } else if #available(iOS 26.0, *) {
            // [T-bubble-opacity-slider][v3 09-10] The slider STILL didn't read
            // on this bubble: `Glass.tint` alpha modulates the material's
            // brightness, not its coverage — at slider 0.2 the tint is pale
            // but the glass itself stays its own translucent white, so the
            // bubble never actually gets more see-through (醒醒: "无法根据我
            // 调整的透明度对应相应的透明度").
            //
            // Fix: the SAME construction the assistant bubble uses — a plain
            // themed fill whose alpha is the slider value (ChatColors.userBubble
            // already carries it), with ONE untinted glass layer OVER the fill
            // for the highlight/edge. Both bubbles now respond to the slider
            // identically: slider = how see-through the coloured surface is.
            // #3 醒醒: 跟 AI 气泡一样，纯实心主题色——去掉 Liquid Glass（玻璃调高亮度刺眼）。
            // 透明度滑杆仍生效（ChatColors.userBubble 自带 alpha）。
            content
                .background(shape.fill(ChatColors.userBubble))
        } else {
            content.background(shape.fill(ChatColors.userBubble))
        }
    }
}

/// [10-20 醒醒] 排队消息的状态点，叠在气泡右上角。
///
/// 用 overlay 而不是塞进 HStack：塞进去会改气泡的可用宽度，
/// 撤回按钮那 28pt 是量高代码（`withdrawButtonWidth`）里算过的，
/// 再多一个元素就得同步改测量，容易漏。overlay 不参与布局，零风险。
///
/// 灰 = 还在队列里等注入；蓝 = 正在送进上下文；isQueued 翻 false 就整颗消失。
private struct QueuedStatusDot: ViewModifier {
    let isQueued: Bool
    let isDelivering: Bool

    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            if isQueued {
                Circle()
                    .fill(isDelivering
                          ? ChatColors.accent
                          : ChatColors.secondaryText.opacity(0.55))
                    .frame(width: 6, height: 6)
                    .offset(x: 3, y: -3)
                    .accessibilityLabel(isDelivering ? "正在送达" : "等待发送")
            }
        }
    }
}

private struct PreviewContentSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        value = CGSize(width: max(value.width, next.width), height: max(value.height, next.height))
    }
}

// MARK: - Chat Message Row

struct ChatMessageRow: View {
    @ObservedObject var message: ChatMessage
    @ObservedObject private var appearanceStudio = AppearanceStudio.shared
    /// Only the actively streaming message needs vm access (for typing indicator & stop button).
    let isActiveMessage: Bool
    var commandStartTime: Date?
    var onStop: (() -> Void)?
    var onRetry: (() -> Void)?
    var onEdit: (() -> Void)?
    /// [T-ios-delete-from-message] Delete this user message and everything
    /// after it. Only set for non-queued user bubbles when idle.
    var onDeleteFrom: (() -> Void)?
    /// [T-chat-single-delete 10-20] Remove ONLY this message; later messages stay.
    var onDeleteSingle: (() -> Void)?
    var onWithdraw: (() -> Void)?
    var autoRetryAttempt: Int = 0
    var autoRetryCountdown: Int = 0
    /// Attempts the current ladder allows (5, or 10 while the upstream throttles).
    var autoRetryBudget: Int = 0
    var canResume: Bool = false
    var onResume: (() -> Void)?
    var onCompact: (() -> Void)?
    var onCopyScreenshot: (() -> Void)?
    /// Read this whole reply aloud from the start (clears any in-progress TTS).
    /// Wired from AIChatView (which owns the view model). Disabled while the
    /// message is still streaming to avoid fighting the live streaming TTS.
    var onReadAloud: (() -> Void)?
    /// When set, presents the compact summary sheet outside the cell tree (V3).
    /// Falls back to a local .sheet when nil (non-V3 / standalone usage).
    var onShowCompactSummary: ((String) -> Void)?
    /// Triggers AIChatViewModel.revertCompact(). Wired from AIChatView so the
    /// row + sheet stay free of view-model imports.
    var onRevertCompact: (() -> Void)?
    /// [s20] 浏览器接管回调，透传给本行弹出的 ToolLiveSheet（语义同
    /// CellStateBridgeV2 上的同名字段）。nil 时接管按钮不显示（BR-2）。
    var onBrowserTakeover: (() -> Void)?
    var onTakeoverDone: (() -> Void)?
    var browserPool: BrowserTabPool?
    var toolSnapshots: [ToolSnapshotItem] = []
    /// [batch9d / W1C-08] 会话绑定人设 id——气泡名/正则显示按它取；
    /// nil（草稿态/未传）回退全局当前人设。
    var sessionPersonaId: String? = nil
    /// [audit-C1] 本行所属会话 id——回调卡点开详情时随通知带上，
    /// 只让「来源会话」的宿主弹 sheet（分屏/多标签下可能有多个聊天界面活着）。
    /// 由 bridge 在 cell 配置时从 VM 复制（与 sessionPersonaId 同路）。
    var sessionId: String? = nil
    @State private var showUsage = false
    @State private var showCompactSummary = false
    /// [T-ios-delete-from-message] Confirmation gate for the suffix delete.
    @State private var showDeleteFromConfirm = false
    @State private var showDeleteSingleConfirm = false
    /// Two-phase token usage reveal: space expands first, then content fades in.
    @State private var usageContentVisible = false
    /// Row frame in window coordinates — used to gate token-usage tap to bottom zone.
    @State private var rowFrameInWindow: CGRect = .zero
    private let usageTapLogger = AppLogger(category: "UsageTap")
    /// ID of the block currently highlighted after a copy action.
    @State private var highlightedBlockId: UUID?
    /// The tool block whose detail sheet is currently presented.
    /// Lifted out of ToolCapsuleView so ForEach item changes don't reset it.
    @State private var detailBlock: AssistantBlock?
    /// The message whose turn summary drawer is currently presented.
    @State private var turnSheetMessage: ChatMessage?

    /// All text block contents joined, for "Copy All".
    private var fullReplyText: String {
        message.blocks
            .filter { if case .text = $0.kind { return true }; return false }
            .map(\.content)
            .joined(separator: "\n\n")
    }

    /// Full message including tool calls and their results, for clipboard export.
    private var fullMessageText: String {
        var parts: [String] = []
        for block in message.blocks {
            switch block.kind {
            case .text:
                if !block.content.isEmpty { parts.append(block.content) }
            case .shellTool(let command):
                let cmd = command.isEmpty ? block.toolDescription : command
                var s = "$ \(cmd)"
                if !block.content.isEmpty {
                    // content is "$ cmd\noutput…", strip the command line
                    let output = block.content.hasPrefix("$ ") ?
                        String(block.content.drop(while: { $0 != "\n" }).dropFirst()) : block.content
                    if !output.isEmpty { s += "\n\(output)" }
                }
                parts.append(s)
            case .fileReadTool(let path):
                parts.append("Read: \(path)\n\(block.content)")
            case .fileWriteTool(let path):
                parts.append("Write: \(path)\n\(block.content)")
            case .fileEditTool(let path):
                parts.append("Edit: \(path)\n\(block.content)")
            case .browserTool(let action):
                parts.append("Browser: \(action)\n\(block.content)")
            case .readImageTool(let path):
                parts.append("Image: \(path)")
            case .memoryTool(let action):
                parts.append("Memory: \(action)\n\(block.content)")
            case .delegateTool(let t):
                // [batch7] Copy keeps the card's title when it has one; the
                // content is the progress line / result JSON as-is.
                parts.append(t.isEmpty ? "Sub agent:\n\(block.content)" : "\(t):\n\(block.content)")
            case .askUserTool:
                parts.append("Ask user:\n\(block.content)")
            case .genericTool(let name):
                parts.append("\(name)\n\(block.content)")
            case .thinking:
                if !block.content.isEmpty { parts.append("[Thinking]\n\(block.content)") }
            case .info:
                if !block.content.isEmpty { parts.append(block.content) }
            }
        }
        return parts.joined(separator: "\n\n")
    }

    var body: some View {
        switch message.role {
        case .user:
            if message.isSystemReminderOnly {
                EmptyView()
            } else if let callback = message.agentCallback {
                // [audit-C5] The 隐身 / 脉搏-card decision lives INSIDE the cell
                // now (AgentCallbackCellView.isPulsePresentation) — one judgment,
                // shared with the list's height precalc. This branch used to
                // re-decide from the registry, which both duplicated the rule
                // and let a cleared job fall between the two copies.
                AgentCallbackCellView(callback: callback, sessionId: sessionId)
                    .opacity(message.isCompactedHistory ? 0.5 : 1.0)
            } else {
                userRow
                    .opacity(message.isCompactedHistory ? 0.5 : 1.0)
            }
        case .assistant:
            assistantRow
                .opacity(message.isCompactedHistory ? 0.5 : 1.0)
        case .compactDivider:
            compactDividerRow
        case .systemInfo:
            systemDividerRow(icon: message.isCompactLoading ? nil : (message.systemIcon ?? "info.circle.fill"),
                             loading: message.isCompactLoading, compact: false)
        }
    }

    // MARK: Compact Divider Row

    private var compactDividerRow: some View {
        HStack(spacing: 10) {
            VStack { Divider() }
            HStack(spacing: 5) {
                if message.isCompactLoading {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 10))
                }
                Text(message.content)
                    .font(.system(size: 12, weight: .medium))
                if !message.isCompactLoading && message.compactSummary != nil {
                    Button {
                        let summary = message.compactSummary ?? ""
                        if let onShowCompactSummary {
                            onShowCompactSummary(summary)
                        } else {
                            showCompactSummary = true
                        }
                    } label: {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .foregroundStyle(MinisTheme.secondaryText)
            .lineLimit(1)
            .fixedSize()
            VStack { Divider() }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .sheet(isPresented: $showCompactSummary) {
            CompactSummarySheet(summary: message.compactSummary ?? "", onRevert: onRevertCompact)
        }
    }

    // MARK: System Divider Row

    /// Shared divider-style row for system info messages.
    private func systemDividerRow(icon: String?, loading: Bool, compact: Bool) -> some View {
        HStack(spacing: 10) {
            VStack { Divider() }
            HStack(spacing: 5) {
                if loading {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10))
                }
                Text(message.content)
                    .font(.system(size: 12, weight: .medium))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(MinisTheme.secondaryText)
            // [T-browser-download-ux-v4] No .lineLimit(1).fixedSize() here:
            // fixedSize forced the text to its full ideal width, so a long
            // systemInfo line (e.g. pre-v3 "Downloaded … to /var/minis/… —
            // minis-clone://…" rows persisted in history) overflowed BOTH screen
            // edges from this centered row. layoutPriority keeps the flexible
            // dividers from squeezing the text; past the available width the
            // text wraps (UIKit breaks unspaced tokens like paths/URLs
            // mid-word) instead of clipping.
            .layoutPriority(1)
            VStack { Divider() }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, compact ? 16 : 6)
    }

    // MARK: User Row

    /// User message text with `<user-attached-files>` metadata stripped out.
    private var userDisplayText: String {
        var text = message.content
        if let start = text.range(of: "<user-attached-files>") {
            let end = text.range(of: "</user-attached-files>")
            let endBound = end?.upperBound ?? text.endIndex
            text = String(text[text.startIndex..<start.lowerBound] + text[endBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private var userRow: some View {
        HStack(alignment: .top, spacing: 10) {
            // Keep the bubble width identical to the original 60pt leading
            // spacer: 12pt breathing room + 10pt gap + 38pt avatar.
            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 6) {
                // User-attached files above the text bubble
                if !message.attachments.isEmpty {
                    UserAttachmentList(attachments: message.attachments)
                } else if !message.inputAttachments.isEmpty {
                    // Queued message: show previews from cache before queue drain
                    QueuedAttachmentPreview(attachments: message.inputAttachments)
                }

                if !userDisplayText.isEmpty {
                    let (cleanUserText, stickerMatch) = StickerParser.parseFirst(in: userDisplayText)
                    if let stickerMatch, let sticker = StickerStore.shared.sticker(for: stickerMatch.id) {
                        VStack(alignment: .trailing, spacing: 6) {
                            if !cleanUserText.isEmpty {
                                HStack(spacing: 6) {
                                    Text(cleanUserText)
                                        .font(MinisThemeShape.fontFamily.font(size: FontSettings.shared.scaledMessage(16.5)))
                                        .foregroundStyle(message.isQueued ? ChatColors.secondaryText : ChatColors.primaryText)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                        .modifier(UserBubbleSurface(isQueued: message.isQueued))
                                        .modifier(QueuedStatusDot(isQueued: message.isQueued,
                                                                  isDelivering: message.isDelivering))
                                        .id(appearanceStudio.themePackRevision)

                                    if message.isQueued, let onWithdraw {
                                        Button {
                                            onWithdraw()
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 22))
                                                .foregroundStyle(ChatColors.destructive)
                                        }
                                    }
                                }
                            }
                            StickerThumbnailView(sticker: sticker)
                        }
                    } else if let stickerMatch, StickerStore.shared.isDeleted(id: stickerMatch.id) {
                        VStack(alignment: .trailing, spacing: 6) {
                            if !cleanUserText.isEmpty {
                                HStack(spacing: 6) {
                                    Text(cleanUserText)
                                        .font(MinisThemeShape.fontFamily.font(size: FontSettings.shared.scaledMessage(16.5)))
                                        .foregroundStyle(message.isQueued ? ChatColors.secondaryText : ChatColors.primaryText)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                        .modifier(UserBubbleSurface(isQueued: message.isQueued))
                                        .modifier(QueuedStatusDot(isQueued: message.isQueued,
                                                                  isDelivering: message.isDelivering))
                                        .id(appearanceStudio.themePackRevision)

                                    if message.isQueued, let onWithdraw {
                                        Button {
                                            onWithdraw()
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 22))
                                                .foregroundStyle(ChatColors.destructive)
                                        }
                                    }
                                }
                            }
                            StickerDeletedPlaceholderView()
                        }
                    } else {
                        HStack(spacing: 6) {
                            // [B28 R7] 代码自动成可折叠块 + 长文可折，都在这个组件里。
                            UserMessageText(text: userDisplayText,
                                            isQueued: message.isQueued,
                                            isDelivering: message.isDelivering,
                                            messageId: message.id)

                            if message.isQueued {
                                if let onWithdraw {
                                    Button {
                                        onWithdraw()
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 22))
                                            .foregroundStyle(ChatColors.destructive)
                                    }
                                }
                            }
                        }
                    }
                }
                // [batch2 / W1A-13] Visible hint when the local write failed —
                // an orphan answer above a vanished question is worse than
                // knowing immediately.
                if message.persistenceFailed {
                    Text("消息未保存到本地")
                        .font(.system(size: 11))
                        .foregroundStyle(ChatColors.destructive)
                        .padding(.trailing, 4)
                        .accessibilityLabel("这条消息未保存到本地数据库")
                }
            }
            .modifier(MinisOpenURLHandler())
            .contentShape(Rectangle())
            // [T-ios-usermsg-contextmenu-preview-shape] The hit-test shape above
            // stays a full Rectangle (so the whole row is long-pressable), but
            // the context-menu PREVIEW must clip to the bubble's rounded shape —
            // otherwise the lifted preview shows square corners while the bubble
            // is RoundedRectangle(cornerRadius: 16). iOS 16+ lets us specify the
            // preview clip shape independently from the interaction shape.
            .contentShape(.contextMenuPreview, MinisThemeShape.userBubble)
            .contextMenu {
                Button {
                    UIPasteboard.general.string = message.content
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                if let onCopyScreenshot {
                    Button {
                        onCopyScreenshot()
                    } label: {
                        Label(AppLocalized("Copy Screenshot"), systemImage: "camera.viewfinder")
                    }
                }
                if let onEdit {
                    Button {
                        onEdit()
                    } label: {
                        Label("Edit", systemImage: "square.and.pencil")
                    }
                }
                if let onRetry {
                    Button {
                        onRetry()
                    } label: {
                        Label("Retry", systemImage: "arrow.counterclockwise")
                    }
                }
                if onDeleteFrom != nil || onCompact != nil {
                    Divider()
                }
                // [T-chat-single-delete 10-20] Two distinct deletes, because
                // "delete this message" and "delete everything from here down"
                // are different intentions and used to be one action:
                //   • Delete This Message — removes just this row; the replies
                //     after it stay.
                //   • Delete From Here — removes this row and every message
                //     after it.
                if let onDeleteSingle {
                    Button(role: .destructive) {
                        showDeleteSingleConfirm = true
                    } label: {
                        Label(AppLocalized("Delete This Message"), systemImage: "trash")
                    }
                }
                if onDeleteFrom != nil {
                    Button(role: .destructive) {
                        showDeleteFromConfirm = true
                    } label: {
                        Label("Delete From Here", systemImage: "trash.fill")
                    }
                }
                if let onCompact {
                    Button(role: .destructive) {
                        onCompact()
                    } label: {
                        Label("Compact Above", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                }
            } preview: {
                // [T-ios-longpress-menu-preview-background] Opaque card so the
                // long-press preview isn't transparent (see MessageContextMenuPreview).
                MessageContextMenuPreview(text: message.content)
            }

            PersonAvatarView(kind: .user, size: 38)
                .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        // [T-ios-delete-from-message] Suffix deletion is irreversible and takes
        // the following replies with it, so it gets an explicit confirmation
        // rather than firing straight off the menu.
        .alert(AppLocalized("Delete Message?"), isPresented: $showDeleteSingleConfirm) {
            Button(AppLocalized("Cancel"), role: .cancel) {}
            Button(AppLocalized("Delete"), role: .destructive) {
                onDeleteSingle?()
            }
        } message: {
            Text(AppLocalized("Only this message will be deleted. The messages after it stay."))
        }
        .alert(AppLocalized("Delete Message?"), isPresented: $showDeleteFromConfirm) {
            Button(AppLocalized("Cancel"), role: .cancel) {}
            Button(AppLocalized("Delete"), role: .destructive) {
                onDeleteFrom?()
            }
        } message: {
            Text("This message and all messages after it will be deleted. This cannot be undone.")
        }
    }

    // MARK: Assistant Row

    private var assistantRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Assistant label
            HStack(spacing: 8) {
                // [问题12] 头像和名字都跟会话绑定的人设走，与人设列表同源。
                PersonAvatarView(kind: .assistant, size: 38,
                                 personaID: SoulStore.displayPersonaId(sessionPersonaId))
                AssistantSoulName(personaId: sessionPersonaId)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(ChatColors.primaryText)
                // [醒醒 10-18] 名字旁边的小猫咪去掉了（同 V3 header）。
            }
            .padding(.top, 2)

            ForEach(TurnSummarySegments.segments(for: message.blocks)) { segment in
                switch segment {
                case .single(let block):
                    AssistantBlockView(
                        block: block,
                    message: message,
                    isActiveMessage: isActiveMessage,
                    commandStartTime: commandStartTime,
                    onStop: onStop,
                    onTapBlank: message.usage != nil ? { windowPoint in
                        // Only respond to taps in the bottom 100pt of the message row
                        let bottomZoneTop = rowFrameInWindow.maxY - 100
                        let inZone = windowPoint.y >= bottomZoneTop
                        usageTapLogger.debug("[usageTap] windowPt=\(String(format: "%.0f,%.0f", windowPoint.x, windowPoint.y)) rowBottom=\(String(format: "%.0f", rowFrameInWindow.maxY)) zoneTop=\(String(format: "%.0f", bottomZoneTop)) inZone=\(inZone) showUsage=\(showUsage)")
                        guard inZone else { return }

                        if showUsage {
                            withAnimation(.easeInOut(duration: 0.15)) { usageContentVisible = false }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                showUsage = false
                            }
                        } else {
                            showUsage = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                withAnimation(.easeInOut(duration: 0.2)) { usageContentVisible = true }
                            }
                        }
                    } : nil,
                    onCopyScreenshot: onCopyScreenshot,
                    sessionPersonaId: sessionPersonaId,
                    browserPool: browserPool,
                    toolSnapshots: toolSnapshots,
                    highlightedBlockId: $highlightedBlockId,
                    detailBlock: $detailBlock
                )
                case .thinkingTools(let blocks):
                    TurnSummaryRow(
                        message: message,
                        memberIDs: blocks.map(\.id),
                        isWorking: isActiveMessage,
                        onTap: { turnSheetMessage = message }
                    )
                }
            }

            // Typing indicator — "request out, nothing back yet", evaluated per
            // ROUND. See `ChatMessage.shouldShowTypingIndicator`.
            if isActiveMessage && message.shouldShowTypingIndicator {
                TypingIndicator(personaId: sessionPersonaId)
            }

            // Inline error + retry
            if let error = message.error {
                inlineError(error)
            }

            // Resume banner for interrupted sessions
            if canResume && message.error == nil {
                resumeBanner
            }

            // Token usage — two-phase reveal: space expands first, then content fades in
            if message.streamInterruptCount > 0 || showUsage {
                HStack(spacing: 6) {
                    if message.streamInterruptCount > 0 {
                        streamInterruptBadge(message.streamInterruptCount)
                    }
                    if showUsage, let usage = message.usage {
                        usageCapsule(usage)
                            .opacity(usageContentVisible ? 1 : 0)
                    }
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        // [T-ios-geometry-observer-crash] THE crasher from the v1.8b13 IPS:
        // onChange(of: geo.frame(in: .global)) wrote state inside the
        // geometry-observer path and tripped the async renderer
        // (ViewGraphGeometryObservers.needsUpdate SIGTRAP). onGeometryChange
        // measures the same row bounds the background GeometryReader did,
        // and its initial fire covers the old onAppear seed.
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { rowFrameInWindow = $0 }
        .background {
            // Context menu on the background layer so it only fires on
            // blank areas — UITextView link taps in the foreground take priority.
            Color.clear
                .contentShape(Rectangle())
                .contextMenu {
                    // [T-ios-msg-contextmenu-recursion-crash] Gate the eager menu
                    // tree behind an Equatable key so the cell body churn during
                    // `gh`/shell streaming output doesn't rebuild + re-diff the
                    // whole menu subtree every frame — the deep ContextMenuModifier
                    // / UnwrapConditional recursion that blew the update stack into
                    // unmapped heap (incident 98E8805F). Copy actions read
                    // `fullReplyText` lazily at TAP time, so the menu structure
                    // only needs rebuilding when the key changes: which optional
                    // actions exist + the streaming-disabled state.
                    EquatableMenuGate(key: AssistantMenuKey(
                        messageId: message.id,
                        hasReadAloud: onReadAloud != nil,
                        hasCopyScreenshot: onCopyScreenshot != nil,
                        hasCompact: onCompact != nil,
                        isActive: isActiveMessage
                    )) {
                        Button {
                            UIPasteboard.general.string = fullReplyText
                        } label: {
                            Label("Copy All", systemImage: "doc.on.doc")
                        }
                        Button {
                            UIPasteboard.general.string = fullReplyText
                        } label: {
                            Label("Copy Markdown", systemImage: "text.quote")
                        }
                        if let onReadAloud {
                            Button {
                                onReadAloud()
                            } label: {
                                Label(AppLocalized("Read from Start"), systemImage: "play.circle")
                            }
                            // Greyed out while streaming so it can't clash with the
                            // live streaming TTS of the same reply.
                            .disabled(isActiveMessage)
                        }
                        if let onCopyScreenshot {
                            Button {
                                onCopyScreenshot()
                            } label: {
                                Label(AppLocalized("Copy Screenshot"), systemImage: "camera.viewfinder")
                            }
                        }
                        if let onCompact {
                            Divider()
                            Button(role: .destructive) {
                                onCompact()
                            } label: {
                                Label("Compact Above", systemImage: "arrow.down.right.and.arrow.up.left")
                            }
                        }
                    }
                    .equatable()
                } preview: {
                    // [T-ios-longpress-menu-preview-background] Opaque card for
                    // this Color.clear-attached contextMenu (see
                    // MessageContextMenuPreview).
                    MessageContextMenuPreview(text: fullReplyText)
                }
        }
        .sheet(item: $detailBlock) { block in
            ToolLiveSheet(toolBlocks: message.blocks.filter { $0.toolStatus != nil },
                          initialIdx: message.blocks.filter({ $0.toolStatus != nil }).firstIndex(where: { $0.id == block.id }) ?? 0,
                          toolSnapshots: toolSnapshots, browserPool: browserPool,
                          onBrowserTakeover: onBrowserTakeover,
                          onTakeoverDone: onTakeoverDone)
        }
        .sheet(item: $turnSheetMessage) { msg in
            TurnDetailSheet(
                message: msg,
                toolSnapshots: toolSnapshots,
                browserPool: browserPool,
                onExpandBrowser: nil,
                onBrowserTakeover: onBrowserTakeover,
                onTakeoverDone: onTakeoverDone
            )
            .presentationDetents([.fraction(2/3), .large])
            .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private func usageCapsule(_ usage: TokenUsage) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "speedometer")
                .font(.system(size: 9))
            Text(usageSummary(usage))
                .font(.system(size: 10, design: .monospaced))
        }
        .foregroundStyle(ChatColors.tertiaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(ChatColors.chipBg)
        .clipShape(Capsule())
        .transition(.opacity.combined(with: .scale(scale: 0.8)))
    }

    @ViewBuilder
    private func streamInterruptBadge(_ count: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 9, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 10, design: .monospaced))
        }
        .foregroundStyle(ChatColors.warning.opacity(0.8))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(ChatColors.warning.opacity(0.12))
        .clipShape(Capsule())
    }

    private func usageSummary(_ u: TokenUsage) -> String {
        var parts: [String] = []
        if u.latestContextTokens > 0 {
            parts.append("ctx:\(formatTokenCount(u.latestContextTokens))")
        }
        parts.append("in:\(formatTokenCount(u.inputTokens))")
        parts.append("out:\(formatTokenCount(u.outputTokens))")
        if u.cacheReadTokens > 0 {
            parts.append("cache:\(formatTokenCount(u.cacheReadTokens))")
        }
        if u.cacheCreationTokens > 0 {
            parts.append("+cache:\(formatTokenCount(u.cacheCreationTokens))")
        }
        return parts.joined(separator: " ")
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1000 {
            let k = Double(count) / 1000.0
            return k.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(k))k"
                : String(format: "%.1fk", k)
        }
        return "\(count)"
    }

    @ViewBuilder
    private func inlineError(_ error: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(ChatColors.destructive)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(ChatColors.destructive)
                    .lineLimit(2)
            }
            .contentShape(Rectangle())
            .contextMenu {
                Button {
                    UIPasteboard.general.string = error
                } label: {
                    Label(AppLocalized("Copy Error"), systemImage: "doc.on.doc")
                }
            }

            Spacer()

            if autoRetryAttempt > 0 {
                Text("Retry in \(autoRetryCountdown)s (\(autoRetryAttempt)/\(autoRetryBudget > 0 ? autoRetryBudget : AIChatViewModel.retryDelays.count))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MinisTheme.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
            } else if let onRetry {
                Button(action: onRetry) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                        Text("Retry")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(ChatColors.primaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(ChatColors.primaryText.opacity(0.15))
                    .clipShape(Capsule())
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ChatColors.destructive.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var resumeBanner: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "pause.circle.fill")
                    .font(.caption)
                    .foregroundStyle(ChatColors.warning)
                Text("Interrupted — tap Resume to continue")
                    .font(.caption)
                    .foregroundStyle(ChatColors.secondaryText)
            }

            Spacer()

            if let onResume {
                Button(action: onResume) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.caption.weight(.semibold))
                        Text("Resume")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(ChatColors.primaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(ChatColors.warning)
                    .clipShape(Capsule())
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ChatColors.warning.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // [T-ios-typing-indicator-scope] The local `hasVisibleContent` that used to
    // live here is gone: the typing indicator's predicate now has exactly one
    // definition, `ChatMessage.shouldShowTypingIndicator`. Keeping a private
    // copy per view is what let the four call sites drift apart in the first
    // place.
}


