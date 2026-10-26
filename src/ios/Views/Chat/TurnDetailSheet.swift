import SwiftUI
#if canImport(Translation)
import Translation
#endif

// MARK: - Turn Detail Sheet
//
// The turn drawer: native bottom sheet content.
// - Header: Left circle button (✕ at top level, ‹ when nested) + centered title
//   + Right circle button (Translate menu: AI model translation or iOS native translation).
// - Body:
//   * If the turn is thinking-only (no tool calls executed), it directly renders
//     the full thinking content without an extra nesting timeline tap.
//   * If there are tool calls, renders the step-by-step timeline, tapping any row navigates in.
// - Translation:
//   * AI translation using the current conversation's model with streaming update.
//   * Native iOS translation via Translation presentation.
//   * Easy toggle between original and translated text.

struct TurnDetailSheet: View {
    @ObservedObject var message: ChatMessage
    var toolSnapshots: [ToolSnapshotItem] = []
    var browserPool: BrowserTabPool?
    var onExpandBrowser: ((URL) -> Void)?
    var onBrowserTakeover: (() -> Void)?
    var onTakeoverDone: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    /// Navigation stack of detail blocks; empty = top level.
    @State private var navStack: [AssistantBlock] = []
    @State private var selectedToolIndex: Int = 0

    // Translation state
    @State private var translatedContent: [UUID: String] = [:]
    @State private var isTranslating = false
    @State private var showOriginal = false
    @State private var activeTranslatingBlockId: UUID?
    @State private var presentSystemTranslation = false
    @State private var systemTranslationText = ""
    @State private var currentTargetLanguage = "中文"

    /// Thinking/tool blocks in turn order.
    private var timelineBlocks: [AssistantBlock] {
        message.blocks.filter { $0.kind == .thinking || $0.kind.isToolKind }
    }

    /// Tool blocks in this message with a toolStatus.
    private var toolBlocks: [AssistantBlock] {
        message.blocks.filter { $0.toolStatus != nil }
    }

    /// Whether this turn only contains thinking process without any tool executions.
    private var isThinkingOnly: Bool {
        !timelineBlocks.isEmpty && timelineBlocks.allSatisfy { $0.kind == .thinking }
    }

    /// The active block currently on display.
    private var activeDisplayBlock: AssistantBlock? {
        if let block = navStack.last {
            return block
        }
        if isThinkingOnly {
            return timelineBlocks.first
        }
        return nil
    }

    private var title: String {
        if let block = activeDisplayBlock {
            return detailTitle(for: block)
        }
        return AppLocalized("Summary")
    }

    private var hasTranslationForActive: Bool {
        guard let id = activeDisplayBlock?.id ?? timelineBlocks.first(where: { $0.kind == .thinking })?.id else { return false }
        return translatedContent[id] != nil
    }

    var body: some View {
        Group {
            if let block = activeDisplayBlock {
                if block.kind == .thinking {
                    VStack(spacing: 0) {
                        header
                        ScrollView {
                            detailPage(for: block)
                        }
                    }
                } else {
                    ToolLiveSheet(
                        toolBlocks: toolBlocks,
                        initialIdx: selectedToolIndex,
                        toolSnapshots: toolSnapshots,
                        browserPool: browserPool,
                        onBrowserTakeover: onBrowserTakeover,
                        onTakeoverDone: onTakeoverDone,
                        onBack: {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                if !navStack.isEmpty {
                                    navStack.removeLast()
                                }
                            }
                        }
                    )
                }
            } else {
                VStack(spacing: 0) {
                    header
                    ScrollView {
                        timeline
                    }
                }
            }
        }
        .background(thinkingBackground)
        #if canImport(Translation)
        .translationPresentation(isPresented: $presentSystemTranslation, text: systemTranslationText)
        #endif
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button {
                if navStack.isEmpty {
                    dismiss()
                } else {
                    navStack.removeLast()
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(ChatColors.secondaryBg)
                        .frame(width: 38, height: 38)
                        .shadow(color: ChatColors.primaryText.opacity(0.08), radius: 5, x: 0, y: 1)
                    Text(navStack.isEmpty ? "✕" : "‹")
                        .font(.system(size: 21))
                        .foregroundStyle(ChatColors.primaryText)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("turnSheetHeaderButton")

            Spacer()

            Text(title)
                .font(MinisThemeShape.fontFamily.font(size: FontSettings.shared.scaledMessage(16), weight: .bold))
                .foregroundStyle(ChatColors.primaryText)
                .lineLimit(1)

            Spacer()

            if activeDisplayBlock?.kind == .thinking || timelineBlocks.contains(where: { $0.kind == .thinking }) {
                translationMenu
            } else {
                Color.clear
                    .frame(width: 38, height: 38)
            }
        }
        .padding(.init(top: 6, leading: 14, bottom: 10, trailing: 14))
    }

    private var translationMenu: some View {
        Menu {
            Section(AppLocalized("AI Translation")) {
                Button {
                    startAITranslation(targetLang: "中文")
                } label: {
                    Label("中文 (简体)", systemImage: "character.bubble")
                }
                Button {
                    startAITranslation(targetLang: "繁體中文")
                } label: {
                    Label("繁體中文", systemImage: "character.bubble")
                }
                Button {
                    startAITranslation(targetLang: "English")
                } label: {
                    Label("English", systemImage: "character.bubble")
                }
                Button {
                    startAITranslation(targetLang: "日本語")
                } label: {
                    Label("日本語", systemImage: "character.bubble")
                }
                Button {
                    startAITranslation(targetLang: "한국어")
                } label: {
                    Label("한국어", systemImage: "character.bubble")
                }
            }

            Section(AppLocalized("System Translation")) {
                Button {
                    triggerSystemTranslation()
                } label: {
                    Label(AppLocalized("iOS System Translation"), systemImage: "globe")
                }
            }

            if hasTranslationForActive {
                Divider()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showOriginal.toggle()
                    }
                } label: {
                    Label(showOriginal ? AppLocalized("Show Translation") : AppLocalized("Show Original"),
                          systemImage: showOriginal ? "text.bubble" : "doc.text")
                }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(ChatColors.secondaryBg)
                    .frame(width: 38, height: 38)
                    .shadow(color: ChatColors.primaryText.opacity(0.08), radius: 5, x: 0, y: 1)

                if isTranslating {
                    ProgressView()
                        .scaleEffect(0.7)
                } else if hasTranslationForActive && !showOriginal {
                    Image(systemName: "character.bubble.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(ChatColors.accent)
                } else {
                    Image(systemName: "translate")
                        .font(.system(size: 16))
                        .foregroundStyle(ChatColors.primaryText)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("turnSheetTranslateButton")
    }

    private var thinkingBackground: some View {
        ZStack {
            MinisThemeShape.thinkingFill
            if let image = AppearanceStudio.shared.thinkingCardImage() {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .opacity(MinisThemeShape.thinkingCardOpacity)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Timeline

    private var timeline: some View {
        VStack(spacing: 8) {
            ForEach(timelineBlocks, id: \.id) { block in
                timelineRow(for: block)
            }
        }
        .padding(.init(top: 8, leading: 16, bottom: 20, trailing: 16))
    }

    private func timelineRow(for block: AssistantBlock) -> some View {
        Button {
            if block.kind == .thinking {
                withAnimation(.easeInOut(duration: 0.18)) {
                    navStack.append(block)
                }
            } else {
                if let idx = toolBlocks.firstIndex(where: { $0.id == block.id }) {
                    selectedToolIndex = idx
                } else {
                    selectedToolIndex = 0
                }
                withAnimation(.easeInOut(duration: 0.18)) {
                    navStack.append(block)
                }
            }
        } label: {
            if block.kind == .thinking {
                thinkingPillRow(for: block)
            } else {
                toolPillRow(for: block)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("turnTimelineRow")
    }

    private func thinkingPillRow(for block: AssistantBlock) -> some View {
        HStack(spacing: 8) {
            Image("ThinkingIcon")
                .resizable()
                .renderingMode(.template)
                .frame(width: 14, height: 14)
                .foregroundStyle(MinisThemeShape.thinkingAccent)

            Text(AppLocalized("Deep Thinking"))
                .font(MinisThemeShape.fontFamily.font(size: FontSettings.shared.scaledMessage(13.5), weight: .semibold))
                .foregroundStyle(MinisThemeShape.thinkingAccent)

            Spacer()

            let count = max(block.content.count, block.thinkingContentBuffer.count)
            if count > 0 {
                Text(count > 1000 ? "\(count / 1000)K" : "\(count)")
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(MinisThemeShape.thinkingAccent.opacity(0.7))
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MinisThemeShape.thinkingAccent.opacity(0.5))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func toolPillRow(for block: AssistantBlock) -> some View {
        HStack(spacing: 8) {
            toolIcon(for: block.kind)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(MinisThemeShape.thinkingAccent)
                .frame(width: 18, alignment: .center)

            Text(timelineTitle(for: block))
                .font(MinisThemeShape.fontFamily.font(size: FontSettings.shared.scaledMessage(13.5), weight: .medium))
                .foregroundStyle(MinisThemeShape.thinkingAccent)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let dur = block.toolDuration {
                Text(MinisStepTimestampFormatter.duration(seconds: dur, stillRunning: false))
                    .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(MinisThemeShape.thinkingAccent.opacity(0.7))
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(MinisThemeShape.thinkingAccent.opacity(0.5))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func timelineTitle(for block: AssistantBlock) -> String {
        if let summary = block.toolSummary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return summary.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let desc = block.toolDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if desc.isEmpty {
            return toolKindName(for: block.kind)
        }
        let firstLine = desc.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? desc
        return firstLine.trimmingCharacters(in: .whitespaces)
    }

    private func toolColor(for block: AssistantBlock) -> Color {
        switch block.toolStatus {
        case .failed:
            return ChatColors.destructive
        case .running, .streaming:
            return ChatColors.accent
        default:
            return ChatColors.success
        }
    }

    // MARK: - Detail pages

    private func detailTitle(for block: AssistantBlock) -> String {
        switch block.kind {
        case .thinking:
            return AppLocalized("Thinking Process")
        case .browserTool:
            return AppLocalized("Browser")
        case .shellTool:
            return AppLocalized("Shell")
        default:
            return toolKindName(for: block.kind)
        }
    }

    @ViewBuilder
    private func detailPage(for block: AssistantBlock) -> some View {
        switch block.kind {
        case .browserTool:
            if let url = resolvedBrowserURL(for: block) {
                MinisLinkPreviewView(
                    url: url,
                    browserPool: browserPool,
                    onExpand: onExpandBrowser == nil ? nil : { _ in
                        let target = url
                        dismiss()
                        // Let the drawer dismiss before opening the full browser.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            onExpandBrowser?(target)
                        }
                    }
                )
            } else {
                plainDetail(label: AppLocalized("Browser"), content: block.toolDescription, blockId: block.id)
            }
        case .shellTool:
            ShellOutputView(
                block: block,
                isLive: false,
                accentColor: ChatColors.accent,
                cardMinHeight: 0
            )
            .padding(.horizontal, 8)
        case .thinking:
            plainDetail(label: AppLocalized("Full thinking"), content: block.content, blockId: block.id)
        default:
            plainDetail(label: toolKindName(for: block.kind), content: block.content, blockId: block.id)
        }
    }

    /// Plain-text detail: small gray label + content. No cards, no panels.
    private func plainDetail(label: String, content: String, blockId: UUID? = nil) -> some View {
        let isTranslated = blockId.flatMap { translatedContent[$0] } != nil && !showOriginal
        let displayContent = (blockId.flatMap { isTranslated ? translatedContent[$0] : nil }) ?? content

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(label)
                    .font(MinisThemeShape.fontFamily.font(size: FontSettings.shared.scaledMessage(12)))
                    .foregroundStyle(ChatColors.secondaryText)

                if let id = blockId, translatedContent[id] != nil {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showOriginal.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showOriginal ? "doc.text" : "character.bubble.fill")
                                .font(.system(size: 10))
                            Text(showOriginal ? AppLocalized("Show Translation") : AppLocalized("Show Original"))
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(ChatColors.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(ChatColors.accent.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            if isTranslating, let id = blockId, activeTranslatingBlockId == id {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                    Text(AppLocalized("Translating into \(currentTargetLanguage)…"))
                        .font(.system(size: 12))
                        .foregroundStyle(ChatColors.secondaryText)
                }
                .padding(.vertical, 2)
            }

            if !displayContent.isEmpty {
                Text(displayContent)
                    .font(MinisThemeShape.fontFamily.font(size: FontSettings.shared.scaledMessage(14)))
                    .foregroundStyle(ChatColors.primaryText)
                    .lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(.init(top: 10, leading: 22, bottom: 10, trailing: 22))
    }

    // MARK: - Translation Actions

    private func startAITranslation(targetLang: String) {
        guard let block = activeDisplayBlock ?? timelineBlocks.first(where: { $0.kind == .thinking }) else { return }
        let rawContent = block.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawContent.isEmpty else { return }

        currentTargetLanguage = targetLang
        activeTranslatingBlockId = block.id
        isTranslating = true
        showOriginal = false

        Task { @MainActor in
            defer {
                isTranslating = false
                activeTranslatingBlockId = nil
            }
            guard let entry = AIChatViewModel.resolveActiveSessionEntry() else {
                return
            }
            do {
                let provider = await AIChatViewModel.makeAgentProvider(for: entry)
                let prompt = """
                Translate the following text into \(targetLang). \
                Do NOT summarize, omit details, or add conversational filler. \
                Output ONLY the raw translated text.

                \(rawContent)
                """
                let messages = [AgentMessage(role: .user, parts: [.text(prompt)])]
                let stream = try await provider.streamAgentMessage(
                    messages: messages,
                    systemPrompt: "You are a professional translator. Output only the verbatim translation without extra commentary.",
                    tools: [],
                    maxTokens: 8192,
                    thinkingLevel: .off
                )
                var accumulated = ""
                for try await event in stream {
                    if case .textDelta(let delta) = event {
                        accumulated += delta
                        translatedContent[block.id] = accumulated
                    }
                }
                let trimmed = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    translatedContent[block.id] = trimmed
                }
            } catch {
                AppLogger(category: "Translation").error("AI translation error: \(error.localizedDescription)")
            }
        }
    }

    private func triggerSystemTranslation() {
        guard let block = activeDisplayBlock ?? timelineBlocks.first(where: { $0.kind == .thinking }) else { return }
        let text = block.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        systemTranslationText = text
        presentSystemTranslation = true
    }

    // MARK: - Helpers

    private func toolIcon(for kind: AssistantBlockKind) -> Image {
        switch kind {
        case .shellTool: Image(systemName: "terminal.fill")
        case .fileReadTool: Image(systemName: "doc.text.fill")
        case .fileWriteTool: Image(systemName: "doc.text.fill")
        case .fileEditTool: Image(systemName: "square.and.pencil")
        case .browserTool: Image(systemName: "globe")
        case .readImageTool: Image(systemName: "photo.fill")
        case .memoryTool: Image(systemName: "brain.head.profile")
        case .askUserTool: Image(systemName: "questionmark.circle.fill")
        case .delegateTool: Image(systemName: "person.2.fill")
        case .genericTool: Image(systemName: "wrench.adjustable.fill")
        case .thinking: Image("ThinkingIcon")
        case .text: Image(systemName: "text.alignleft")
        case .info: Image(systemName: "arrow.triangle.2.circlepath")
        }
    }

    private func toolKindName(for kind: AssistantBlockKind) -> String {
        switch kind {
        case .shellTool: return AppLocalized("Shell")
        case .fileReadTool: return AppLocalized("File read")
        case .fileWriteTool: return AppLocalized("File write")
        case .fileEditTool: return AppLocalized("File edit")
        case .browserTool: return AppLocalized("Browser")
        case .readImageTool: return AppLocalized("Image read")
        case .memoryTool: return AppLocalized("Memory")
        case .delegateTool: return AppLocalized("Sub agent")
        case .askUserTool: return AppLocalized("Question")
        case .genericTool(let name): return name
        case .thinking: return AppLocalized("Thinking")
        case .text: return AppLocalized("Text")
        case .info: return AppLocalized("Info")
        }
    }

    /// Resolve the browser URL for a block: block.browserURL, then the `url`
    /// field of toolInputArgs, then inherited from the nearest preceding
    /// browser block with a URL.
    private func resolvedBrowserURL(for block: AssistantBlock) -> URL? {
        if let s = block.browserURL, !s.isEmpty, let url = URL(string: s) { return url }
        if let url = urlFromArgs(block) { return url }
        let blocks = message.blocks
        if let idx = blocks.firstIndex(where: { $0.id == block.id }), idx > 0 {
            for prev in blocks[..<idx].reversed() {
                guard case .browserTool = prev.kind else { continue }
                if let s = prev.browserURL, !s.isEmpty, let url = URL(string: s) { return url }
                if let url = urlFromArgs(prev) { return url }
                break
            }
        }
        return nil
    }

    private func urlFromArgs(_ block: AssistantBlock) -> URL? {
        guard let json = block.toolInputArgs,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = dict["url"] as? String, !s.isEmpty,
              let url = URL(string: s) else { return nil }
        return url
    }
}
