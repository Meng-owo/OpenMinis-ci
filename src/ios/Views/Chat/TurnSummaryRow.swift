import SwiftUI

// MARK: - Turn Summary Segments (shared grouping logic)
//
// ONE UNIFIED PATH: both the collection-view snapshot builder
// (CollectionViewMessageListV3.applySnapshot) and the SwiftUI row
// (ChatMessageRow.assistantRow) funnel thinking/tool blocks through this
// helper. A "thinking/tool run" is a maximal run of consecutive blocks whose
// kind is .thinking or whose kind.isToolKind is true. Each run renders as
// exactly one TurnSummaryRow; every other block (text, info) renders solo.
// No renderer may invent its own grouping — divergence is a defect.

enum TurnSummarySegment: Identifiable {
    case single(AssistantBlock)
    case thinkingTools([AssistantBlock])

    var id: String {
        switch self {
        case .single(let block):
            return "s:\(block.id.uuidString)"
        case .thinkingTools(let blocks):
            return "t:" + blocks.map { $0.id.uuidString }.joined(separator: ",")
        }
    }
}

enum TurnSummarySegments {
    /// Split blocks into render segments. Thinking/tool runs become one
    /// summary row each; text/info blocks pass through individually.
    static func segments(for blocks: [AssistantBlock]) -> [TurnSummarySegment] {
        var out: [TurnSummarySegment] = []
        var i = blocks.startIndex
        while i < blocks.endIndex {
            let kind = blocks[i].kind
            if kind == .thinking || kind.isToolKind {
                var j = blocks.index(after: i)
                while j < blocks.endIndex {
                    let k = blocks[j].kind
                    guard k == .thinking || k.isToolKind else { break }
                    j = blocks.index(after: j)
                }
                out.append(.thinkingTools(Array(blocks[i..<j])))
                i = j
            } else {
                out.append(.single(blocks[i]))
                i = blocks.index(after: i)
            }
        }
        return out
    }

    /// Deterministic fallback summary for a thinking/tool run, used when no
    /// AI-generated summary is available (e.g. history reloaded from DB, or
    /// the summary LLM call failed). Verb + key parameter per block, never
    /// bare counts. Reuses each block's existing toolDescription.
    static func fallbackSummary(for blocks: [AssistantBlock]) -> String {
        let parts = blocks.map { $0.toolDescription }.filter { !$0.isEmpty }
        if parts.isEmpty {
            // Thinking-only run.
            return AppLocalized("Thought for a while")
        }
        return parts.joined(separator: "、")
    }

    /// Text shown in the summary row: AI summary when present, a working
    /// indicator while the turn is live, deterministic fallback otherwise.
    /// The turn-end hook guarantees `turnSummary` is written at turn end (AI
    /// text on success, fallback on failure), so nil + !isWorking always has
    /// a fallback — the row never sticks on the working text.
    static func rowText(message: ChatMessage, memberBlocks: [AssistantBlock], isWorking: Bool) -> String {
        if let s = message.turnSummary, !s.isEmpty { return s }
        if isWorking { return AppLocalized("Thinking…") }
        return fallbackSummary(for: memberBlocks)
    }
}

// MARK: - Turn Summary Row
//
// 1:1 from thinking-drawer-mockup.html `.summary-row`:
// floating row (no card, no border): 21pt clock icon + gray single-line
// ellipsized text + › chevron. Exactly one per thinking/tool run.

struct TurnSummaryRow: View {
    @ObservedObject var message: ChatMessage
    /// Block IDs of this run, in order. Resolved against the live
    /// message.blocks so streaming growth is picked up.
    let memberIDs: [UUID]
    /// True while this turn is still being produced.
    var isWorking: Bool
    var onTap: () -> Void

    private var memberBlocks: [AssistantBlock] {
        memberIDs.compactMap { id in message.blocks.first(where: { $0.id == id }) }
    }

    private var text: String {
        TurnSummarySegments.rowText(message: message, memberBlocks: memberBlocks, isWorking: isWorking)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                WaggingCatIcon(isWorking: isWorking, size: 20, color: ChatColors.secondaryText)
                    .frame(width: 21, height: 21)
                Text(text)
                    .font(MinisThemeShape.fontFamily.font(size: FontSettings.shared.scaledMessage(14)))
                    .foregroundStyle(ChatColors.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("›")
                    .font(.system(size: 19, weight: .light))
                    .foregroundStyle(ChatColors.secondaryText)
            }
            .padding(.init(top: 8, leading: 4, bottom: 8, trailing: 4))
        }
        .buttonStyle(.plain)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("turnSummaryRow")
    }
}

// MARK: - Wagging Cat Icon & Shapes

extension ChatMessage {
    /// True while model is actively streaming, thinking, or running tool calls.
    var isThinkingOrToolWorking: Bool {
        if isAwaitingModelResponse { return true }
        if blocks.contains(where: { $0.toolStatus == .running }) { return true }
        if usage == nil, let last = blocks.last, last.kind == .thinking || last.kind.isToolKind {
            return true
        }
        return false
    }
}

struct CatBodyShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let sx = rect.width / 24.0
        let sy = rect.height / 25.0
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx + rect.minX, y: y * sy + rect.minY) }

        p.move(to: pt(8.5, 7.0))
        p.addCurve(to: pt(6.8, 7.8), control1: pt(7.8, 7.0), control2: pt(7.2, 7.3))
        p.addLine(to: pt(5.2, 4.2))
        p.addCurve(to: pt(4.0, 4.8), control1: pt(4.8, 3.3), control2: pt(3.6, 3.8))
        p.addLine(to: pt(5.0, 8.5))
        p.addCurve(to: pt(4.2, 14.5), control1: pt(3.8, 10.2), control2: pt(3.5, 12.5))
        p.addCurve(to: pt(2.5, 20.0), control1: pt(3.2, 16.0), control2: pt(2.5, 18.0))
        p.addCurve(to: pt(10.5, 24.0), control1: pt(2.5, 23.0), control2: pt(5.5, 24.0))
        p.addCurve(to: pt(18.5, 20.0), control1: pt(15.5, 24.0), control2: pt(18.5, 23.0))
        p.addCurve(to: pt(16.8, 14.5), control1: pt(18.5, 18.0), control2: pt(17.8, 16.0))
        p.addCurve(to: pt(16.0, 8.5), control1: pt(17.5, 12.5), control2: pt(17.2, 10.2))
        p.addLine(to: pt(17.0, 4.8))
        p.addCurve(to: pt(15.8, 4.2), control1: pt(17.4, 3.8), control2: pt(16.2, 3.3))
        p.addLine(to: pt(14.2, 7.8))
        p.addCurve(to: pt(12.5, 7.0), control1: pt(13.8, 7.3), control2: pt(13.2, 7.0))
        p.addCurve(to: pt(10.5, 7.4), control1: pt(11.8, 7.0), control2: pt(11.2, 7.2))
        p.addCurve(to: pt(8.5, 7.0), control1: pt(9.8, 7.2), control2: pt(9.2, 7.0))
        p.closeSubpath()
        return p
    }
}

struct CatTailShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let sx = rect.width / 24.0
        let sy = rect.height / 25.0
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx + rect.minX, y: y * sy + rect.minY) }

        p.move(to: pt(16.0, 20.5))
        p.addCurve(to: pt(21.0, 15.0), control1: pt(18.0, 20.5), control2: pt(21.0, 18.5))
        p.addCurve(to: pt(17.8, 10.0), control1: pt(21.0, 12.5), control2: pt(19.5, 10.5))
        p.addCurve(to: pt(16.6, 11.2), control1: pt(17.0, 9.7), control2: pt(16.3, 10.4))
        p.addCurve(to: pt(18.0, 14.8), control1: pt(16.9, 12.0), control2: pt(18.0, 13.0))
        p.addCurve(to: pt(15.0, 18.2), control1: pt(18.0, 16.5), control2: pt(16.5, 18.0))
        p.closeSubpath()
        return p
    }
}

struct WaggingCatIcon: View {
    var isWorking: Bool = false
    var size: CGFloat = 18
    // [batch8b] ChatColors is @MainActor; member default values are
    // nonisolated — use the snapshot path (same resolved color).
    var color: Color = Color(AppearanceStudio.uiColorSnapshot(.primaryText, scope: .chat))

    @State private var tailAngle: Double = 0

    var body: some View {
        ZStack {
            CatBodyShape()
                .fill(color)
            CatTailShape()
                .fill(color)
                .rotationEffect(
                    .degrees(isWorking ? tailAngle : 0),
                    anchor: UnitPoint(x: 16.0 / 24.0, y: 20.0 / 25.0)
                )
        }
        .frame(width: size, height: size * (25.0 / 24.0))
        .onAppear {
            updateWagging(working: isWorking)
        }
        .onChange(of: isWorking) { working in
            updateWagging(working: working)
        }
    }

    private func updateWagging(working: Bool) {
        if working {
            withAnimation(
                .easeInOut(duration: 0.55)
                .repeatForever(autoreverses: true)
            ) {
                tailAngle = -16
            }
        } else {
            withAnimation(.easeOut(duration: 0.25)) {
                tailAngle = 0
            }
        }
    }
}
