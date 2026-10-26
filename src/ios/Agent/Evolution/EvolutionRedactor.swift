import Foundation

/// [S2-1][evolution] Redaction for the self-evolution store.
///
/// Everything that ever lands in `evolution.db` passes through here first.
/// Hard rule: secrets never reach the database in any form — not full, not
/// truncated, not as an opaque blob. Two layers:
///
///   1) **Key blacklist** — argument NAMES that imply credentials keep only a
///      type marker (`<redacted:String>`), never the value. Substring matching,
///      deliberately biased toward OVER-redacting: for tool-call argument keys
///      a false positive costs nothing, a false negative leaks a key.
///   2) **Value scrubbing** — free text is scanned for common secret shapes
///      (`sk-…`, `Bearer …`, `token=…`, JWTs, long base64/hex blobs, URL
///      userinfo) and those spans collapse to `[redacted…]` markers.
///
/// Plus a hard length cap so no single field can balloon the DB.
///
/// This file is pure logic — no DB, no UI, no app-flow side effects.
/// Covered by `MinisTests/EvolutionPhase2Tests.swift`.
enum EvolutionRedactor {

    /// Hard cap for any single digest field (characters).
    static let maxDigestLength = 200
    /// Cap for the serialized argument profile.
    static let maxProfileLength = 400

    // MARK: - Key blacklist

    /// Lowercased substrings that mark an argument key as sensitive.
    /// Substring (not component) matching on purpose: `clientSecret`,
    /// `x-auth-token`, `OPENAI_API_KEY` must all hit.
    private static let sensitiveKeyMarkers: [String] = [
        "key", "secret", "token", "password", "passwd", "credential",
        "authorization", "auth", "cookie", "session", "bearer", "signature",
    ]

    /// True when this argument NAME looks like a credential — its value is
    /// replaced by a type marker and never stored.
    static func isSensitive(argumentKey: String) -> Bool {
        let lowered = argumentKey.lowercased()
        return sensitiveKeyMarkers.contains { lowered.contains($0) }
    }

    // MARK: - Value scrubbing

    /// Scrubbing rules, applied in order. Replacement templates use `$1` where
    /// the match keeps its prefix (e.g. the parameter name).
    private static let rules: [(NSRegularExpression, String)] = {
        let specs: [(String, String)] = [
            // OpenAI-style / generic prefixed keys: sk-…, pk-…, rk-…
            ("(?i)\\b(sk|pk|rk)-[A-Za-z0-9_-]{8,}", "[redacted-key]"),
            // "Bearer <secret>" / "Basic <secret>"
            ("(?i)\\b(bearer|basic)\\s+[A-Za-z0-9._+/=-]{8,}", "Bearer [redacted]"),
            // name=value / name: value where the NAME is credential-shaped
            ("(?i)\\b(api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|password|passwd|authorization)\\b\\s*[:=]\\s*\\S{4,}", "$1=[redacted]"),
            // JWT triplets
            ("\\beyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+", "[redacted-jwt]"),
            // URL userinfo: scheme://user:pass@host
            ("://[^/\\s@]+@", "://[redacted]@"),
            // Long opaque blobs (base64/hex), must contain a digit so ordinary
            // long words survive. Deliberately excludes `/` and `.` so file
            // paths (which we WANT in digests) never match.
            ("(?=[A-Za-z0-9+]*[0-9])[A-Za-z0-9+]{40,}={0,2}", "[redacted-blob]"),
        ]
        var out: [(NSRegularExpression, String)] = []
        for (pattern, replacement) in specs {
            if let re = try? NSRegularExpression(pattern: pattern) {
                out.append((re, replacement))
            }
        }
        return out
    }()

    /// Scrub secret-shaped spans out of free text.
    static func scrub(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        // Rules apply once each, in order, over the whole string.
        for (re, replacement) in rules {
            result = re.stringByReplacingMatches(in: result, options: [],
                                                 range: NSRange(location: 0, length: (result as NSString).length),
                                                 withTemplate: replacement)
        }
        return result
    }

    /// Scrub + truncate to `limit` characters. The truncation marker reports
    /// how many characters were dropped (`…[+N]`) and the result is guaranteed
    /// to stay within `limit`.
    static func digest(_ text: String, limit: Int = EvolutionRedactor.maxDigestLength) -> String {
        let clean = scrub(text)
        let effectiveLimit = max(24, limit)
        guard clean.count > effectiveLimit else { return clean }
        let tailNote = "…[+\(clean.count - effectiveLimit)]"
        let headBudget = max(0, effectiveLimit - tailNote.count)
        return String(clean.prefix(headBudget)) + tailNote
    }

    // MARK: - Argument profiles

    /// Sanitized argument map: sensitive values → type markers; everything
    /// else scrubbed + length-capped per value.
    static func redactArguments(_ arguments: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in arguments {
            if isSensitive(argumentKey: key) {
                out[key] = "<redacted:\(typeName(of: value))>"
            } else {
                out[key] = digest(stringValue(of: value))
            }
        }
        return out
    }

    /// Compact, sanitized, serialized profile of a tool call's arguments —
    /// the only shape of argument data the evolution store ever keeps.
    static func profile(_ arguments: [String: Any]) -> String {
        let redacted = redactArguments(arguments)
        guard !redacted.isEmpty else { return "{}" }
        var pieces: [String] = []
        for key in redacted.keys.sorted() {
            pieces.append("\(key)=\(redacted[key] ?? "")")
        }
        let joined = pieces.joined(separator: "; ")
        return digest(joined, limit: maxProfileLength)
    }

    // MARK: - Helpers

    private static func typeName(of value: Any) -> String {
        switch value {
        case is String: return "String"
        case is Bool: return "Bool"
        case is Int, is Int64, is Double, is Float, is NSNumber: return "Number"
        case is [Any]: return "Array"
        case is [String: Any]: return "Object"
        case is NSNull: return "Null"
        default: return "Other"
        }
    }

    private static func stringValue(of value: Any) -> String {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case is NSNull: return ""
        case let a as [Any]:
            if let data = try? JSONSerialization.data(withJSONObject: a),
               let json = String(data: data, encoding: .utf8) { return json }
            return "\(a)"
        case let d as [String: Any]:
            if let data = try? JSONSerialization.data(withJSONObject: d),
               let json = String(data: data, encoding: .utf8) { return json }
            return "\(d)"
        default: return "\(value)"
        }
    }
}
