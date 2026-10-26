package com.openminis.app.agent

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [T-android-soul-custom-icon][PIC-9] Frontmatter round-trip + stored-size contract.
 *
 * Emoji support is removed (matching iOS): the emoji normalization helpers
 * are gone, and these are pure-JVM assertions on the contracts that actually
 * regress — what the SOUL.md line looks like on disk, and the stored-size
 * rule. The bitmap path needs a real Android Bitmap and is covered on device
 * instead.
 */
class SoulIconTest {

    @Test
    fun `there is no opaque rejection`() {
        val names = SoulIcon.Rejection.entries.map { it.name }
        assertFalse("opaque images must be accepted", names.contains("OPAQUE"))
        assertTrue(names.contains("UNREADABLE"))
        // [PIC-9] No size refusal, matching iOS — the TOO_LARGE case is gone.
        assertFalse("large photos must be stored, never refused", names.contains("TOO_LARGE"))
    }

    /** Rounded, not circular — a circle eats the corners at 18dp. */
    @Test
    fun `corner radius matches the ios app-icon proportion`() {
        assertEquals(0.22f, SoulIcon.CORNER_RADIUS_FRACTION, 0.0001f)
    }

    /** The stored edge must match iOS (512px), since the value syncs between platforms. */
    @Test
    fun `stored edge is 512 matching ios`() {
        assertEquals(512, SoulIcon.STORED_PIXELS)
    }

    // ── Data URI detection ───────────────────────────────────────────────

    @Test
    fun `data uri is recognized`() {
        assertTrue(SoulIcon.isDataUri("data:image/png;base64,iVBORw0KGgo="))
        assertFalse(SoulIcon.isDataUri("⚡"))
        assertFalse(SoulIcon.isDataUri(""))
        assertFalse(SoulIcon.isDataUri("data:image/jpeg;base64,xxx"))
    }

    // ── Frontmatter round trip ───────────────────────────────────────────

    @Test
    fun `icon line is omitted entirely when empty`() {
        val f = SoulFile(SoulMetadata.DEFAULT, "body")
        val out = SoulMDParser.serialize(f)
        assertFalse("empty icon must not write a line", out.contains("icon:"))
        // The untouched file keeps its previous 3-key shape.
        assertTrue(out.contains("name:"))
        assertTrue(out.contains("style:"))
        assertTrue(out.contains("lang:"))
    }

    @Test
    fun `data uri icon survives the colon-bearing round trip`() {
        val uri = SoulIcon.DATA_URI_PREFIX + "iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB"
        val f = SoulFile(SoulMetadata.DEFAULT.copy(icon = uri), "body")
        val text = SoulMDParser.serialize(f)
        val back = SoulMDParser.parse(text).metadata.icon
        assertEquals(uri, back)
        assertTrue(SoulIcon.isDataUri(back))
    }

    @Test
    fun `clearing the icon removes the line from an existing file`() {
        val withIcon = SoulMDParser.serialize(
            SoulFile(SoulMetadata.DEFAULT.copy(icon = "🚀"), "body"),
        )
        assertTrue(withIcon.contains("icon:"))

        val parsed = SoulMDParser.parse(withIcon)
        val cleared = SoulMDParser.serialize(
            parsed.copy(metadata = parsed.metadata.copy(icon = "")),
        )
        assertFalse("clearing must delete the line, not write icon: \"\"",
            cleared.contains("icon:"))
        assertEquals("", SoulMDParser.parse(cleared).metadata.icon)
    }

    @Test
    fun `a file predating the icon key still parses`() {
        val old = """
            ---
            name: "我的小家"
            style: ""
            lang: "auto"
            ---

            body text
        """.trimIndent()
        val parsed = SoulMDParser.parse(old)
        assertEquals("", parsed.metadata.icon)
        assertEquals("我的小家", parsed.metadata.name)
    }

    @Test
    fun `unknown frontmatter keys remain non-fatal`() {
        val text = """
            ---
            name: "我的小家"
            icon: "⚡"
            somethingNew: "value"
            lang: "auto"
            ---

            body
        """.trimIndent()
        val parsed = SoulMDParser.parse(text)
        assertEquals("⚡", parsed.metadata.icon)
        assertEquals("我的小家", parsed.metadata.name)
    }
}
