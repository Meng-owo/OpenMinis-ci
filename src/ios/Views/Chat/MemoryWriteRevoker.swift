import Foundation

// MARK: - [audit-E7] 记忆文件日历日期共享助手

/// [audit-E7] Single source of truth for "recent daily-log date strings
/// (YYYY-MM-DD)".
///
/// Anchors at the start of `today` and steps by CALENDAR days (`byAdding: .day`).
/// Stepping by `-86400s` from `Date()` lands on the wrong date around DST
/// transitions (a 23/25-hour day shifts the result into the day before
/// yesterday in the early hours), skipping a daily log and skewing labels
/// and lookups. The injection path already knew this (AIChatViewModel+MemoryTools:29);
/// this helper shares the exact same rule with UI and revoke.
enum MemoryLogDates {
    static let dateFormat = "yyyy-MM-dd"

    /// Date strings for `today`, `today - 1 day`, ... up to `count` calendar days.
    static func recentDays(count: Int, from now: Date = Date()) -> [String] {
        guard count > 0 else { return [] }
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: now)
        let fmt = DateFormatter()
        fmt.dateFormat = dateFormat
        return (0..<count).map { dayOffset in
            let date = cal.date(byAdding: .day, value: -dayOffset, to: todayStart) ?? todayStart
            return fmt.string(from: date)
        }
    }
}

// MARK: - Memory write revocation

/// [T-ios-memory-write-revoke] Shared undo for a `memory_write` tool call:
/// locates the daily-log entry whose body matches what the tool wrote and
/// deletes the whole entry (its `<!-- timestamp -->` marker included).
///
/// Two call sites need this — the Memories-in-Session detail sheet
/// (`MemoryWriteDetailView`) and the tool capsule's long-press menu in the chat
/// transcript (`ToolCapsuleView`) — so the logic lives here once rather than
/// being duplicated per entry point.
enum MemoryWriteRevoker {

    /// Remove the daily-log entry whose body equals `writtenContent`.
    ///
    /// Only today's and yesterday's logs are searched: a memory write is undone
    /// from the conversation that produced it, so the entry is always recent,
    /// and scanning the full archive to find a stale match would risk deleting
    /// an older identical note.
    ///
    /// Returns a user-facing result string — `"Removed from <date>.md"` on
    /// success, otherwise a not-found / write-error message. Callers surface it
    /// directly in an alert or toast.
    ///
    /// [audit-E6] `personaID` names whose memory dir the entry lives in — the
    /// WRITING session's persona, not whatever persona happens to be globally
    /// current right now (they differ whenever the user switches persona after
    /// the write, and the entry then lives in a dir this lookup never visited).
    /// nil falls back to the current persona for legacy callers.
    static func revoke(writtenContent: String, personaID: String? = nil) -> String {
        let written = writtenContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !written.isEmpty else {
            return AppLocalized("No written content to revoke.")
        }

        let fm = FileManager.default
        // [batch5 / W2B-01/W2B-05] The daily log lives in the persona dir —
        // the legacy root path made revoke fail for every non-default persona
        // (and silently no-op for the default one).
        // [audit-E6] …and it is the SESSION's persona (passed by the caller),
        // not the globally-current one.
        let memDir = PersonaStore.memoryDir(for: personaID ?? PersonaStore.currentID())

        // [audit-E7] Calendar days (shared with injection and UI), not -86400s.
        let candidates = MemoryLogDates.recentDays(count: 2)

        for dateStr in candidates {
            let fileURL = memDir.appendingPathComponent("\(dateStr).md")
            guard fm.fileExists(atPath: fileURL.path),
                  let fileContent = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }

            // Entry format: "<!-- YYYY-MM-DD HH:mm:ss -->\n{content}\n\n".
            // Each entry runs from its comment marker to the next marker (or EOF).
            let pattern = "<!-- \\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2} -->\n"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }

            let nsContent = fileContent as NSString
            let matches = regex.matches(in: fileContent, range: NSRange(location: 0, length: nsContent.length))

            for (i, match) in matches.enumerated() {
                let entryStart = match.range.location
                let contentStart = match.range.location + match.range.length
                let entryEnd = (i + 1 < matches.count) ? matches[i + 1].range.location : nsContent.length

                let bodyRange = NSRange(location: contentStart, length: entryEnd - contentStart)
                let body = nsContent.substring(with: bodyRange)

                guard body.trimmingCharacters(in: .whitespacesAndNewlines) == written else { continue }

                // Drop the whole entry: marker + body + trailing blank lines.
                let removeRange = NSRange(location: entryStart, length: entryEnd - entryStart)
                let newFileContent = nsContent.replacingCharacters(in: removeRange, with: "")
                do {
                    try newFileContent.write(to: fileURL, atomically: true, encoding: .utf8)
                    return AppLocalized("Removed from \(dateStr).md")
                } catch {
                    return AppLocalized("Error writing file: \(error.localizedDescription)")
                }
            }
        }

        return AppLocalized("Entry not found in recent daily logs.")
    }

    /// Pull the `content` argument out of a `memory_write` tool call's input
    /// JSON — the text that landed in the daily log, and the key the revoke
    /// matches on. Mirrors `SessionMemoryView.toolMemories`' parse.
    static func writtenContent(fromToolInputArgs argsJson: String?) -> String? {
        guard let argsJson, !argsJson.isEmpty,
              let data = argsJson.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = dict["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return content
    }
}
