package com.openminis.app.agent

import com.openminis.app.data.model.AgentContentPart
import com.openminis.app.data.model.LLMMessage

/**
 * Keeps tool_use / tool_result pairing valid when the user interrupts a tool
 * round (OpenMinis#293).
 *
 * OpenAI Chat Completions rejects histories where a `role: "tool"` message is
 * not immediately preceded by an assistant message carrying `tool_calls`
 * (or by another tool message in the same round):
 *
 *     Messages with role 'tool' must be a response to a preceding message
 *     with 'tool_calls'
 *
 * On Android the cancel path used to persist synthetic cancelled tool_results
 * to the DB **without** appending them to in-memory `agentHistory`. Continue /
 * resume then saw a trailing assistant(tool_use), injected a text
 * "continue" reminder as the next user turn, and — once the DB rows were
 * merged or a later sanitize pass emitted the orphan results after that
 * reminder — the provider received `tool` messages whose preceding wire
 * message was plain user text, not `tool_calls`.
 *
 * iOS avoids this because ConcurrentTools always finishes the round with
 * cancelled tool_results in `agentHistory` before cleanup; Case 1 then sees
 * `lastHistoryIsToolResult == true` and resume does **not** inject a continue
 * reminder. This helper is the Android equivalent of that pairing step.
 */
object InterruptToolHistory {

    /**
     * Default cancelled-tool wording. Must stay aligned with
     * `ChatViewModel.CANCELLED_MARKER` / iOS ConcurrentTools cancel content so
     * cross-platform session sync shows the same reminder to the model.
     */
    const val DEFAULT_CANCELLED_MARKER =
        "<system-reminder>The user cancelled this operation. The returned result may be incomplete.</system-reminder>"

    /**
     * Tool_use ids that appear in [history] but have no matching tool_result.
     */
    fun unansweredToolUseIds(history: List<LLMMessage>): Set<String> {
        val uses = LinkedHashSet<String>()
        val results = HashSet<String>()
        for (msg in history) {
            for (part in msg.contentParts) {
                when (part) {
                    is AgentContentPart.ToolUse -> uses.add(part.id)
                    is AgentContentPart.ToolResult -> results.add(part.id)
                    else -> {}
                }
            }
        }
        return uses.filterTo(LinkedHashSet()) { it !in results }
    }

    /**
     * True when the trailing history entry is an assistant turn that still
     * has tool_use parts without matching tool_results — the broken shape
     * Continue must close before calling the provider (#293).
     */
    fun trailingAssistantHasUnansweredToolUses(history: List<LLMMessage>): Boolean {
        val last = history.lastOrNull() ?: return false
        if (last.role != LLMMessage.Role.ASSISTANT) return false
        val uses = last.contentParts.filterIsInstance<AgentContentPart.ToolUse>()
        if (uses.isEmpty()) return false
        val unanswered = unansweredToolUseIds(history)
        return uses.any { it.id in unanswered }
    }

    /**
     * Build cancelled tool_result parts for unanswered tool_uses.
     *
     * @param history current agent history (must already contain the assistant
     *   tool_use entries — STREAMING-only UI blocks with no history entry are
     *   intentionally skipped so we never persist orphan `role:tool` rows).
     * @param candidateIds optional (id, name) pairs from the UI cancel path;
     *   when non-null, only those ids are considered (and name comes from the
     *   UI). When null, every unanswered tool_use in [history] is closed.
     * @param cancelledMarker body written into each synthetic tool_result.
     */
    fun cancelledResultsForUnanswered(
        history: List<LLMMessage>,
        candidateIds: List<Pair<String, String>>? = null,
        cancelledMarker: String = DEFAULT_CANCELLED_MARKER,
    ): List<AgentContentPart.ToolResult> {
        val unanswered = unansweredToolUseIds(history)
        if (unanswered.isEmpty()) return emptyList()

        val nameById = LinkedHashMap<String, String>()
        for (msg in history) {
            for (part in msg.contentParts) {
                if (part is AgentContentPart.ToolUse && part.id in unanswered) {
                    nameById.putIfAbsent(part.id, part.name)
                }
            }
        }

        val ids: List<String> = if (candidateIds != null) {
            for ((id, name) in candidateIds) {
                if (id in unanswered) nameById[id] = name
            }
            candidateIds.map { it.first }.filter { it in unanswered }.distinct()
        } else {
            unanswered.toList()
        }

        return ids.mapNotNull { id ->
            val name = nameById[id] ?: return@mapNotNull null
            AgentContentPart.ToolResult(
                id = id,
                name = name,
                content = cancelledMarker,
                isError = true,
            )
        }
    }

    /**
     * Append a user message of [results] onto a mutable history copy and
     * return it. No-op when [results] is empty (returns [history] unchanged).
     */
    fun withCancelledResults(
        history: List<LLMMessage>,
        results: List<AgentContentPart.ToolResult>,
    ): List<LLMMessage> {
        if (results.isEmpty()) return history
        return history + LLMMessage(
            role = LLMMessage.Role.USER,
            content = "",
            contentParts = results,
        )
    }
}
