import SwiftUI

// MARK: - Shell Output View
//
// Black-terminal shell output card, extracted VERBATIM from ToolLiveSheet
// (zero visual changes): `$ command` header, ANSI-sanitized chunked output
// with URL detection, lazy reveal for long output, live CPU/mem footer while
// streaming. ToolLiveSheet's shell section now uses this struct; the turn
// drawer embeds it for shell tool detail pages.

struct ShellOutputView: View {
    @ObservedObject var block: AssistantBlock
    var isLive: Bool
    var accentColor: Color
    var cardMinHeight: CGFloat

    @StateObject private var resourceMonitor = SystemResourceMonitor()
    @State private var revealedChunkCount: Int = 0
    /// The block id `revealedChunkCount` was last initialized for, so switching
    /// blocks re-collapses to the initial batch.
    @State private var revealedForBlockId: UUID?

    var body: some View {
        if case .shellTool(let cmd) = block.kind {
            // Shell: command header + chunked output (cap at 500 lines while streaming)
            let allChunks = isLive
                ? ToolLiveSheet.liveChunkedLines(block.content.isEmpty ? " " : block.content)
                : ToolLiveSheet.chunkedLines(block.content.isEmpty ? " " : block.content)
            // [T-ios-tool-result-lazy-render] In the detail (non-live)
            // view reveal only an initial window and grow on scroll.
            let chunks = isLive ? allChunks : Array(allChunks.prefix(max(revealedChunkCount, 1)))
            VStack(alignment: .leading, spacing: 0) {
                Text("$ \(cmd)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 14)

                ForEach(chunks, id: \.id) { chunk in
                    Text(attributedShellLine(chunk.text))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(accentColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                }

                if !isLive {
                    loadMoreFooter(totalChunks: allChunks.count)
                }

                Color.clear.frame(height: 1).id("end")
            }
            .onAppear {
                if !isLive { resetRevealWindow(for: allChunks) }
                if isLive { resourceMonitor.start() }
            }
            .onDisappear { resourceMonitor.stop() }
            .onChange(of: isLive) { live in
                if live { resourceMonitor.start() } else { resourceMonitor.stop() }
            }
            .onChange(of: block.id) { _ in
                guard !isLive else { return }
                let chunks = ToolLiveSheet.chunkedLines(block.content.isEmpty ? " " : block.content)
                revealedForBlockId = block.id
                revealedChunkCount = ToolLiveSheet.initialRevealCount(chunks)
            }
            .textSelection(.enabled)
            .padding(.bottom, isLive ? 24 : 14)
            .frame(maxWidth: .infinity, minHeight: cardMinHeight, alignment: .topLeading)
            .background(Color.black)
            .overlay(alignment: .bottom) {
                if isLive {
                    HStack(spacing: 12) {
                        Text(resourceMonitor.formattedCPU)
                            .foregroundStyle(ChatColors.success)
                        Text(resourceMonitor.formattedMem())
                            .foregroundStyle(ChatColors.success)
                    }
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(Color(white: 0.08))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(ChatColors.toolBorder, lineWidth: 0.5))
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
    }

    /// "Load more" / "Load all" footer shown under a partially-revealed result.
    /// Tapping bumps `revealedChunkCount`; the bottom sentinel also auto-bumps
    /// when it scrolls into view so reaching the end keeps loading without a tap.
    @ViewBuilder
    private func loadMoreFooter(totalChunks: Int) -> some View {
        if revealedChunkCount < totalChunks {
            let remaining = totalChunks - revealedChunkCount
            let nextBatch = min(ToolLiveSheet.lazyRenderBatchChunks, remaining)
            HStack(spacing: 16) {
                Button {
                    revealedChunkCount = min(revealedChunkCount + ToolLiveSheet.lazyRenderBatchChunks, totalChunks)
                } label: {
                    Label("Load more (\(nextBatch * ToolLiveSheet.lazyRenderChunkLines) lines)", systemImage: "chevron.down")
                        .font(.system(size: 13, weight: .medium))
                }
                Button {
                    revealedChunkCount = totalChunks
                } label: {
                    Text("Load all")
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            // Auto-load when this footer scrolls into view so the user can just
            // keep scrolling to reveal more without tapping.
            .onAppear {
                revealedChunkCount = min(revealedChunkCount + ToolLiveSheet.lazyRenderBatchChunks, totalChunks)
            }
        }
    }

    /// Reset / initialize the revealed window for the currently displayed block.
    private func resetRevealWindow(for chunks: [(id: Int, text: String)]) {
        guard revealedForBlockId != block.id else { return }
        revealedForBlockId = block.id
        revealedChunkCount = ToolLiveSheet.initialRevealCount(chunks)
    }
}
