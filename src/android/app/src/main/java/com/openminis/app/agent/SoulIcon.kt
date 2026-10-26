package com.openminis.app.agent

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Base64
import java.io.ByteArrayOutputStream

/**
 * [T-android-soul-custom-icon] The Soul identity icon: a user-uploaded image
 * stored inline as a data URI. Emoji icons are no longer supported —
 * matching iOS, the emoji entry point is removed and a stored legacy emoji
 * value is never rendered as the avatar (it falls through to the default
 * sparkle).
 *
 * Port of the iOS `SoulIconImage` (`dfa7a17b5`, `68b9ceaed`). The rules here
 * are contract, not preference — the value syncs between platforms, so both
 * sides must agree on what is storable.
 */
object SoulIcon {

    /** The stored prefix. PNG specifically: it is the format we re-encode to. */
    const val DATA_URI_PREFIX = "data:image/png;base64,"

    /** Longest edge of the stored bitmap, in pixels. Matches iOS. */
    const val STORED_PIXELS = 512

    fun isDataUri(value: String): Boolean = value.startsWith(DATA_URI_PREFIX)

    /**
     * Corner radius as a fraction of the icon's edge, matching iOS.
     *
     * Rounded, deliberately NOT a circle: at 18dp in the chat header a circle
     * eats the corners of a small avatar. 22% is the platform app-icon
     * proportion.
     */
    const val CORNER_RADIUS_FRACTION = 0.22f

    /** Why a picked image was refused. */
    enum class Rejection { UNREADABLE }

    sealed class EncodeResult {
        data class Success(val dataUri: String) : EncodeResult()
        data class Failure(val reason: Rejection) : EncodeResult()
    }

    /**
     * Normalize a picked bitmap into the stored form: centre-cropped to 1:1,
     * downscaled to [STORED_PIXELS], PNG, base64 data URI.
     *
     * **Opaque images are accepted.** An earlier version refused anything
     * without an alpha channel, reasoning that an unframed opaque rectangle
     * reads as a broken tile. That reasoning was about PRESENTATION, so the
     * fix belongs in the renderer — every image is now clipped to a rounded
     * rectangle ([CORNER_RADIUS_FRACTION]) wherever it is drawn. With that in
     * place the refusal only turned away most of the images a user might pick.
     * Follows iOS `fe2f3ae8b`, which reversed the same rule for the same
     * reason; the two platforms must agree, since the value syncs.
     *
     * Alpha is still PRESERVED (PNG, never flattened) — it is simply no
     * longer required.
     */
    fun encode(source: Bitmap): EncodeResult {
        if (source.width <= 0 || source.height <= 0) {
            return EncodeResult.Failure(Rejection.UNREADABLE)
        }

        val square = squareCropped(source)
        // Never upscale: a 48px source stays 48px rather than being blown up
        // to 96 and looking soft.
        val side = minOf(STORED_PIXELS, square.width, square.height)
        val scaled = if (square.width == side && square.height == side) {
            square
        } else {
            Bitmap.createScaledBitmap(square, side, side, true)
        }

        val png = ByteArrayOutputStream().use { out ->
            // PNG is lossless and ignores the quality argument, so alpha and
            // exact pixels survive the round trip.
            if (!scaled.compress(Bitmap.CompressFormat.PNG, 100, out)) {
                return EncodeResult.Failure(Rejection.UNREADABLE)
            }
            out.toByteArray()
        }

        // NO_WRAP is mandatory: the default inserts newlines, and the
        // frontmatter parser is strictly line-oriented — a wrapped payload
        // would be truncated at the first break.
        val encoded = DATA_URI_PREFIX + Base64.encodeToString(png, Base64.NO_WRAP)
        // [PIC-9] No size refusal: matches iOS — a large photo is stored,
        // never turned away. The stored bitmap is still capped at
        // STORED_PIXELS on the long edge.
        return EncodeResult.Success(encoded)
    }

    /** Decode a stored data URI. Returns null for an emoji value or garbage. */
    fun decode(value: String): Bitmap? {
        if (!isDataUri(value)) return null
        return runCatching {
            val bytes = Base64.decode(value.removePrefix(DATA_URI_PREFIX), Base64.DEFAULT)
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        }.getOrNull()
    }

    /**
     * [T-android-soul-icon-config-images] Turn a `minis-config` value into
     * bitmap bytes.
     *
     * Mirrors iOS `fe2f3ae8b`: an address is only an IMPORT SOURCE. Whatever
     * it resolves to goes through the same [encode] the Settings picker uses,
     * and only the RESULT is stored — so the source file can be deleted
     * afterwards and the icon still survives attachment cleanup and syncing.
     *
     * Deliberately NOT supported on Android: `http(s)://`. iOS resolves those
     * in an async phase before its confirmation sheet; Android's
     * `ConfigField.write` is synchronous, and doing a network fetch inside it
     * would block the caller and hand a model-supplied URL a request from
     * inside the app — an SSRF surface that needs the same host-blocklist
     * treatment iOS built. Rather than ship a weaker version of that, remote
     * URLs are refused with a message pointing at the local forms. Everything
     * that does not need the network is supported.
     */
    sealed class Source {
        data class Bytes(val data: ByteArray) : Source() {
            // ByteArray needs structural equals for the data class to behave.
            override fun equals(other: Any?): Boolean =
                this === other || (other is Bytes && data.contentEquals(other.data))
            override fun hashCode(): Int = data.contentHashCode()
        }
        data class LinuxPath(val path: String) : Source()
        data class Unsupported(val reason: String) : Source()
    }

    /** Classify a config value that is not empty. Emoji are not accepted. */
    fun classifySource(raw: String): Source {
        val v = raw.trim()
        return when {
            v.startsWith("http://", true) || v.startsWith("https://", true) ->
                Source.Unsupported(
                    "remote URLs aren't supported on Android — download the file first, " +
                        "then pass a path like /var/minis/attachments/icon.png",
                )
            v.startsWith("minis://") -> {
                // minis://attachments/x.png -> /var/minis/attachments/x.png
                val rest = v.removePrefix("minis://").trimStart('/')
                if (rest.isEmpty()) Source.Unsupported("empty minis:// path")
                else Source.LinuxPath("/var/minis/$rest")
            }
            v.startsWith("data:") -> {
                val comma = v.indexOf(',')
                val meta = if (comma > 0) v.substring(0, comma) else ""
                if (comma < 0 || !meta.contains(";base64")) {
                    Source.Unsupported("only base64 data URIs are supported")
                } else {
                    decodeBase64(v.substring(comma + 1))
                        ?.let { Source.Bytes(it) }
                        ?: Source.Unsupported("the data URI's base64 could not be decoded")
                }
            }
            v.startsWith("/") -> Source.LinuxPath(v)
            // Bare base64 — auto-detected, matching iOS. Checked last so it
            // cannot shadow any of the addressed forms.
            looksLikeBareBase64(v) ->
                decodeBase64(v)?.let { Source.Bytes(it) }
                    ?: Source.Unsupported("that base64 could not be decoded")
            else -> Source.Unsupported(
                "not a data URI, base64, a minis:// resource or a /var/minis path " +
                    "(emoji icons are not supported)",
            )
        }
    }

    private fun decodeBase64(s: String): ByteArray? = runCatching {
        Base64.decode(s.trim(), Base64.DEFAULT)
    }.getOrNull()?.takeIf { it.isNotEmpty() }

    private fun looksLikeBareBase64(v: String): Boolean =
        v.length >= 32 && v.all { it.isLetterOrDigit() || it == '+' || it == '/' || it == '=' }

    /**
     * The linux directories a config-supplied path may read from.
     *
     * Containment resolves symlinks on BOTH sides before comparing (same
     * construction as the backup extractor), so a symlink inside an allowed
     * directory cannot point out of it. Without the canonicalisation a
     * model-supplied `/var/minis/attachments/../../../databases/x` would walk
     * straight out of the sandbox.
     */
    val ALLOWED_LINUX_ROOTS = listOf(
        "/var/minis/attachments",
        "/var/minis/workspace",
        "/var/minis/offloads",
        "/var/minis/shared",
        "/var/minis/memory",
        "/var/minis/skills",
    )

    /** True when [candidate] really sits inside [root] after both are resolved. */
    fun isContained(candidate: java.io.File, root: java.io.File): Boolean {
        val c = runCatching { candidate.canonicalFile }.getOrElse { return false }
        val r = runCatching { root.canonicalFile }.getOrElse { return false }
        // The separator matters: it stops "/a/bc" matching root "/a/b".
        return c == r || c.path.startsWith(r.path + java.io.File.separator)
    }

    /** Centre-crop to 1:1, keeping the shorter edge. */
    private fun squareCropped(bitmap: Bitmap): Bitmap {
        val w = bitmap.width
        val h = bitmap.height
        if (w == h) return bitmap
        val side = minOf(w, h)
        return Bitmap.createBitmap(bitmap, (w - side) / 2, (h - side) / 2, side, side)
    }

}
