package com.openminis.app.agent

import com.openminis.app.data.model.AgentContentPart
import com.openminis.app.data.model.LLMMessage
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * OpenMinis#293 — interrupting a tool round must leave history pairable so
 * Continue does not 400 with:
 *   Messages with role 'tool' must be a response to a preceding message
 *   with 'tool_calls'
 */
class InterruptToolHistoryTest {

    private fun user(vararg parts: AgentContentPart) =
        LLMMessage(role = LLMMessage.Role.USER, content = "", contentParts = parts.toList())

    private fun assistant(vararg parts: AgentContentPart) =
        LLMMessage(role = LLMMessage.Role.ASSISTANT, content = "", contentParts = parts.toList())

    private fun toolUse(id: String, name: String = "shell_execute") =
        AgentContentPart.ToolUse(id = id, name = name, input = JSONObject())

    private fun toolResult(id: String, name: String = "shell_execute") =
        AgentContentPart.ToolResult(id = id, name = name, content = "ok")

    @Test
    fun `unanswered tool_use on trailing assistant is detected`() {
        val history = listOf(
            user(AgentContentPart.Text("run ls")),
            assistant(toolUse("call_1")),
        )
        assertTrue(InterruptToolHistory.trailingAssistantHasUnansweredToolUses(history))
        assertEquals(setOf("call_1"), InterruptToolHistory.unansweredToolUseIds(history))
    }

    @Test
    fun `paired tool round is not unanswered`() {
        val history = listOf(
            assistant(toolUse("call_1")),
            user(toolResult("call_1")),
        )
        assertFalse(InterruptToolHistory.trailingAssistantHasUnansweredToolUses(history))
        assertTrue(InterruptToolHistory.unansweredToolUseIds(history).isEmpty())
    }

    @Test
    fun `cancelledResults closes only history-backed unanswered ids`() {
        val history = listOf(assistant(toolUse("call_1"), toolUse("call_2")))
        // UI also reports a STREAMING id that never landed in agentHistory —
        // must NOT synthesise an orphan result for it (#293).
        val parts = InterruptToolHistory.cancelledResultsForUnanswered(
            history = history,
            candidateIds = listOf(
                "call_1" to "shell_execute",
                "call_ghost" to "browser_use",
            ),
        )
        assertEquals(listOf("call_1"), parts.map { it.id })
        assertTrue(parts.all { it.isError })
        assertTrue(parts.all { it.content == InterruptToolHistory.DEFAULT_CANCELLED_MARKER })
    }

    @Test
    fun `withCancelledResults makes Continue shape match iOS Case 1`() {
        val history = listOf(assistant(toolUse("call_1")))
        val parts = InterruptToolHistory.cancelledResultsForUnanswered(history)
        val fixed = InterruptToolHistory.withCancelledResults(history, parts)
        assertFalse(InterruptToolHistory.trailingAssistantHasUnansweredToolUses(fixed))
        assertEquals(LLMMessage.Role.USER, fixed.last().role)
        assertTrue(fixed.last().contentParts.all { it is AgentContentPart.ToolResult })
        // resume() must NOT inject a continue reminder when the tail is
        // already a tool_result user turn (iOS Case 1).
        assertFalse(fixed.last().role == LLMMessage.Role.ASSISTANT)
    }

    @Test
    fun `empty when candidates are only ghosts`() {
        val history = listOf(assistant(AgentContentPart.Text("thinking…")))
        val parts = InterruptToolHistory.cancelledResultsForUnanswered(
            history = history,
            candidateIds = listOf("ghost" to "shell_execute"),
        )
        assertTrue(parts.isEmpty())
    }
}
