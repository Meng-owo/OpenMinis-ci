import Foundation

// MARK: - Turn Summary Generation (drawer-rewrite)
//
// Hidden LLM call at turn end that produces the one-line gray summary shown
// in TurnSummaryRow. Uses the sub-model with thinkingLevel=.off (same pattern
// as title generation). ALWAYS writes message.turnSummary — AI text on
// success, deterministic fallback on failure — so the row never sticks on
// the "Thinking…" working indicator.

extension AIChatViewModel {
    /// Called at the end of runAgentLoop. Spawns an async task; never blocks.
    func generateTurnSummary(for message: ChatMessage) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let blocks = message.blocks.filter { $0.kind == .thinking || $0.kind.isToolKind }
            guard !blocks.isEmpty else { return }
            let summary = await self.summarizeTurnBlocks(blocks)
                ?? TurnSummarySegments.fallbackSummary(for: blocks)
            message.turnSummary = summary
        }
    }

    /// Ask the sub-model for a one-line summary. Returns nil on any failure
    /// (no sub-model, network error, empty response) — caller falls back.
    private func summarizeTurnBlocks(_ blocks: [AssistantBlock]) async -> String? {
        guard let entry = resolveSubEntry() else { return nil }

        // Compact description of what happened this turn.
        var lines: [String] = []
        for block in blocks {
            switch block.kind {
            case .thinking:
                let text = block.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    lines.append("Thinking: \(String(text.prefix(600)))")
                }
            default:
                let desc = block.toolDescription
                if !desc.isEmpty {
                    lines.append("Tool: \(desc)")
                }
            }
        }
        guard !lines.isEmpty else { return nil }
        let activity = lines.joined(separator: "\n")

        let prompt = """
        Summarize what the AI assistant did in this turn in ONE short sentence \
        (max 20 words). Be specific: name the action and its key target. \
        Do not add quotes, prefixes, or explanations. Respond with the sentence only.

        Activity:
        \(activity)
        """

        do {
            let provider = await AIChatViewModel.makeAgentProvider(for: entry)
            let messages = [AgentMessage(role: .user, parts: [.text(prompt)])]
            let stream = try await provider.streamAgentMessage(
                messages: messages,
                systemPrompt: "You summarize AI assistant activity in one short sentence. Respond with the sentence only, no other text.",
                tools: [],
                maxTokens: 128,
                thinkingLevel: .off
            )
            var responseText = ""
            for try await event in stream {
                if case .textDelta(let delta) = event {
                    responseText += delta
                }
            }
            let summary = responseText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first.map(String.init)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
            guard let summary, !summary.isEmpty else { return nil }
            return summary
        } catch {
            return nil
        }
    }
}
