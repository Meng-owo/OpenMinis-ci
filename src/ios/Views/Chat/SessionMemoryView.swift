//
//  SessionMemoryView.swift
//  MinisApp
//
//  Shows all memory used in the current session: auto-injected + tool-recalled.
//

import SwiftUI

struct SessionMemoryView: View {
    @ObservedObject var vm: AIChatViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // Section 1: Auto-injected memories
                Section {
                    ForEach(autoInjected, id: \.name) { item in
                        NavigationLink {
                            MemoryContentView(title: item.name, content: item.content, fileURL: item.fileURL)
                        } label: {
                            row(name: item.name, detail: item.detail, icon: item.icon)
                        }
                    }
                } header: {
                    Text("Auto-injected")
                } footer: {
                    Text("Loaded into system prompt at the start of each agent turn.")
                }

                // Section 2: Tool-recalled memories
                if !toolMemories.isEmpty {
                    Section {
                        ForEach(toolMemories) { item in
                            NavigationLink {
                                if item.isWrite {
                                    MemoryWriteDetailView(item: item, personaID: vm.sessionPersonaId ?? PersonaStore.currentID())
                                } else {
                                    MemoryGetDetailView(item: item)
                                }
                            } label: {
                                row(name: item.title, detail: item.detail, icon: item.isWrite ? "square.and.pencil" : "magnifyingglass")
                            }
                        }
                    } header: {
                        Text("Tool Activity")
                    } footer: {
                        Text("Memory reads and writes performed by the agent during this session.")
                    }
                }
            }
            .navigationTitle("Memories in Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Row

    private func row(name: String, detail: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(ChatColors.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(MinisTheme.secondaryText)
                        .lineLimit(2)
                }
            }
        }
    }

    // MARK: - Auto-injected

    private struct AutoItem {
        let name: String
        let detail: String
        let icon: String
        let content: String
        let fileURL: URL?
    }

    private var autoInjected: [AutoItem] {
        var items: [AutoItem] = []
        let fm = FileManager.default
        // ［persona］按本会话人设读记忆目录。
        let memDir = PersonaStore.memoryDir(for: vm.sessionPersonaId ?? PersonaStore.currentID())

        // SOUL.md — listed first because it's the identity/personality
        // layer that SystemPromptBuilder.identitySection() injects at
        // the very top of every turn's system prompt. The Memory Sheet
        // previously only surfaced GLOBAL.md + daily logs, so users had
        // no way to confirm SOUL.md was reaching the model.
        let soulURL = memDir.appendingPathComponent("SOUL.md")
        if fm.fileExists(atPath: soulURL.path),
           let content = try? String(contentsOf: soulURL, encoding: .utf8),
           !content.isEmpty {
            let lineCount = content.components(separatedBy: "\n").count
            items.append(AutoItem(
                name: "SOUL.md",
                detail: "\(lineCount) lines (full)",
                icon: "person.fill",
                content: content,
                fileURL: soulURL
            ))
        } else {
            items.append(AutoItem(name: "SOUL.md", detail: "Empty", icon: "person", content: "(empty)", fileURL: soulURL))
        }

        // GLOBAL.md
        let globalURL = memDir.appendingPathComponent("GLOBAL.md")
        if fm.fileExists(atPath: globalURL.path),
           let content = try? String(contentsOf: globalURL, encoding: .utf8),
           !content.isEmpty {
            let lineCount = content.components(separatedBy: "\n").count
            items.append(AutoItem(
                name: "GLOBAL.md",
                detail: "\(lineCount) lines (full)",
                icon: "star.fill",
                content: content,
                fileURL: globalURL
            ))
        } else {
            items.append(AutoItem(name: "GLOBAL.md", detail: "Empty", icon: "star.fill", content: "(empty)", fileURL: globalURL))
        }

        // Most recent 3 daily logs with content (matches system prompt injection logic)
        // [audit-E7] Calendar-day stepping via shared MemoryLogDates (matches
        // AIChatViewModel+MemoryTools injection logic; -86400s caused DST drift).
        var found = 0
        let dates = MemoryLogDates.recentDays(count: 30)

        for (dayOffset, dateStr) in dates.enumerated() where found < 3 {
            let fileName = "\(dateStr).md"
            let fileURL = memDir.appendingPathComponent(fileName)
            if fm.fileExists(atPath: fileURL.path),
               let content = try? String(contentsOf: fileURL, encoding: .utf8),
               !content.isEmpty {
                let lineCount = content.components(separatedBy: "\n").count
                let injected = min(lineCount, 200)
                let detail = lineCount > 200
                    ? "\(injected)/\(lineCount) lines injected"
                    : "\(lineCount) lines (full)"
                let label: String
                switch dayOffset {
                case 0: label = AppLocalized("Today")
                case 1: label = AppLocalized("Yesterday")
                default: label = dateStr
                }
                items.append(AutoItem(
                    name: "\(label) — \(fileName)",
                    detail: detail,
                    icon: "calendar",
                    content: content,
                    fileURL: fileURL
                ))
                found += 1
            }
        }

        return items
    }

    // MARK: - Tool memories

    struct ToolMemoryItem: Identifiable {
        // Identity comes from the source AssistantBlock, whose id is
        // stable for the block's lifetime. A fresh UUID() here would
        // change on every recompute of `toolMemories` (it is a computed
        // property rebuilt on each body evaluation), so any background
        // message change would swap every row's identity and tear down
        // a pushed detail view along with its editing state.
        let id: UUID
        let title: String
        let detail: String
        /// The tool result output (what the tool returned to the agent).
        let content: String
        let isWrite: Bool
        /// The original content written by memory_write, parsed from toolInputArgs.
        let writtenContent: String?
        /// Keywords used for memory_get search.
        let keywords: String?
    }

    private var toolMemories: [ToolMemoryItem] {
        var items: [ToolMemoryItem] = []
        for message in vm.messages {
            for block in message.blocks {
                guard case .memoryTool(let action) = block.kind else { continue }
                let isWrite = action == "memory_write"
                let summary = block.toolSummary ?? action

                var writtenContent: String?
                var keywords: String?

                if let argsJson = block.toolInputArgs,
                   let data = argsJson.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if isWrite {
                        writtenContent = dict["content"] as? String
                    } else {
                        keywords = dict["keywords"] as? String
                    }
                }

                // Build a meaningful detail preview
                let detail: String
                if isWrite, let written = writtenContent {
                    // Show what was written
                    let firstLine = written.components(separatedBy: "\n").first(where: { !$0.isEmpty }) ?? ""
                    detail = String(firstLine.prefix(100))
                } else if !isWrite {
                    // Show keywords + result summary
                    let resultLines = block.content.components(separatedBy: "\n").filter { !$0.isEmpty }
                    if let kw = keywords, !kw.isEmpty {
                        let matchCount = resultLines.filter { $0.hasPrefix("---") || $0.hasPrefix("## ") }.count
                        detail = "Search: \(kw)" + (matchCount > 0 ? " (\(matchCount) files)" : "")
                    } else {
                        detail = String((resultLines.first ?? "").prefix(100))
                    }
                } else {
                    detail = String(block.content.prefix(100))
                }

                items.append(ToolMemoryItem(
                    id: block.id,
                    title: summary,
                    detail: detail,
                    content: block.content,
                    isWrite: isWrite,
                    writtenContent: writtenContent,
                    keywords: keywords
                ))
            }
        }
        return items
    }
}

// MARK: - Content Detail

private struct MemoryContentView: View {
    let title: String
    let fileURL: URL?

    /// Live copy of the file's content. The `content` init parameter is
    /// only the opening snapshot: save() writes to disk, and unless the
    /// local copy advances too, the view keeps displaying — and
    /// re-seeding the editor from — the pre-edit text, so a second save
    /// silently overwrites the first edit with a draft based on the
    /// old content.
    @State private var currentContent: String
    @State private var editedContent: String = ""
    @State private var isEditing = false
    @State private var saved = false

    init(title: String, content: String, fileURL: URL?) {
        self.title = title
        self.fileURL = fileURL
        _currentContent = State(initialValue: content)
    }

    var body: some View {
        Group {
            if isEditing {
                TextEditor(text: $editedContent)
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 8)
            } else {
                ScrollView {
                    Text(currentContent)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if fileURL != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    if isEditing {
                        Button("Save") {
                            save()
                        }
                    } else {
                        Button {
                            editedContent = currentContent
                            isEditing = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if saved {
                Text("Saved")
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func save() {
        guard let url = fileURL else { return }
        do {
            try editedContent.write(to: url, atomically: true, encoding: .utf8)
            currentContent = editedContent
            // SOUL.md needs the same side effects SoulStore.save() does:
            // refresh the in-memory metadata cache (so the chat header /
            // SystemPromptBuilder pick up the new identity) and mark it
            // dirty for iCloud sync. Without these, edits in this sheet
            // would land on disk but the running app + peer devices
            // would keep using the stale identity until next launch.
            if url.lastPathComponent == "SOUL.md" {
                SoulStore.refreshCache()
                Task { await ChatStore.shared.markDirty(recordType: "SoulV2", recordId: "soul") }
            }
            isEditing = false
            withAnimation { saved = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation { saved = false }
            }
        } catch {
            // Stay in editing mode so the user's text is not lost — but say
            // why, otherwise the Save button just looks dead.
            MinisToast.show(
                String(format: AppLocalized("Save failed: %@"), error.localizedDescription),
                systemImage: "exclamationmark.triangle.fill"
            )
        }
    }
}

// MARK: - Memory Write Detail (with revoke)

private struct MemoryWriteDetailView: View {
    let item: SessionMemoryView.ToolMemoryItem
    /// ［persona］本会话人设 id，编辑回写定位该人设的记忆目录。
    let personaID: String
    @Environment(\.dismiss) private var dismiss
    /// Live copy of the entry's written content. `item` is a snapshot
    /// taken when the list was built; saveEdit replaces the log body by
    /// matching the OLD written content, so after one successful edit
    /// this copy must advance to the new content — otherwise the next
    /// edit searches the log for text that no longer exists there,
    /// finds nothing, and silently does nothing. Revoke reads it for
    /// the same reason.
    @State private var currentWrittenContent: String?
    @State private var isEditing = false
    @State private var editedContent: String = ""
    @State private var showRevokeAlert = false
    @State private var revokeResult: String?
    @State private var showResultAlert = false
    @State private var saved = false

    init(item: SessionMemoryView.ToolMemoryItem, personaID: String) {
        self.item = item
        self.personaID = personaID
        _currentWrittenContent = State(initialValue: item.writtenContent)
    }

    var body: some View {
        Group {
            if isEditing {
                TextEditor(text: $editedContent)
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let written = currentWrittenContent {
                            SectionHeader(title: "Written Content")
                            Text(written)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                                .textSelection(.enabled)
                        }

                        SectionHeader(title: "Tool Result")
                        Text(item.content)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(MinisTheme.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isEditing {
                    Button("Save") { saveEdit() }
                } else {
                    if currentWrittenContent != nil {
                        Button {
                            editedContent = currentWrittenContent ?? ""
                            isEditing = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                    }
                    Button {
                        showRevokeAlert = true
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(currentWrittenContent == nil)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if saved {
                Text("Saved")
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .alert("Revoke Memory", isPresented: $showRevokeAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Revoke", role: .destructive) {
                revokeResult = revokeEntry()
                showResultAlert = true
            }
        } message: {
            Text("Remove this memory entry from the daily log? This cannot be undone.")
        }
        .alert(revokeResult ?? "", isPresented: $showResultAlert) {
            Button("OK") {
                if revokeResult?.hasPrefix("Removed") == true {
                    dismiss()
                }
            }
        }
    }

    private func saveEdit() {
        guard let written = currentWrittenContent else { return }
        let result = replaceEntryInLog(oldContent: written, newContent: editedContent)
        if result != nil {
            currentWrittenContent = editedContent
            isEditing = false
            withAnimation { saved = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation { saved = false }
            }
        } else {
            // `replaceEntryInLog` returns nil when the entry could not be
            // located in the last two days' logs, or when the write failed.
            // Staying in edit mode without a word looks like a dead button.
            MinisToast.show(
                AppLocalized("Could not save: this memory entry was not found in the daily log."),
                systemImage: "exclamationmark.triangle.fill"
            )
        }
    }

    /// Find entry matching `oldContent` in daily logs and replace its body with `newContent`.
    /// Returns the filename on success, nil on failure.
    private func replaceEntryInLog(oldContent: String, newContent: String) -> String? {
        let fm = FileManager.default
        // ［persona］按本会话人设回写记忆目录。
        let memDir = PersonaStore.memoryDir(for: personaID)
        // [audit-E7] Calendar days via shared MemoryLogDates.
        let candidates = MemoryLogDates.recentDays(count: 2)

        for dateStr in candidates {
            let fileURL = memDir.appendingPathComponent("\(dateStr).md")
            guard fm.fileExists(atPath: fileURL.path),
                  let fileContent = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }

            let pattern = "<!-- \\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2} -->\n"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }

            let nsContent = fileContent as NSString
            let matches = regex.matches(in: fileContent, range: NSRange(location: 0, length: nsContent.length))

            for (i, match) in matches.enumerated() {
                let contentStart = match.range.location + match.range.length
                let entryEnd: Int
                if i + 1 < matches.count {
                    entryEnd = matches[i + 1].range.location
                } else {
                    entryEnd = nsContent.length
                }

                let bodyRange = NSRange(location: contentStart, length: entryEnd - contentStart)
                let body = nsContent.substring(with: bodyRange)
                let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedOld = oldContent.trimmingCharacters(in: .whitespacesAndNewlines)

                if trimmedBody == trimmedOld {
                    let replacement = newContent.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
                    let newFileContent = nsContent.replacingCharacters(in: bodyRange, with: replacement)
                    if let _ = try? newFileContent.write(to: fileURL, atomically: true, encoding: .utf8) {
                        return dateStr
                    }
                }
            }
        }
        return nil
    }

    /// [T-ios-memory-write-revoke] Delegates to the shared revoker, which the
    /// tool capsule's long-press menu uses too — the entry-deletion logic must
    /// not drift between the two entry points.
    private func revokeEntry() -> String {
        guard let written = currentWrittenContent else {
            return AppLocalized("No written content to revoke.")
        }
        // [audit-E6] The detail view carries the persona the entry was
        // written under — revoke must look THERE, not at "whoever is current".
        return MemoryWriteRevoker.revoke(writtenContent: written, personaID: personaID)
    }
}

// MARK: - Memory Get Detail

private struct MemoryGetDetailView: View {
    let item: SessionMemoryView.ToolMemoryItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let kw = item.keywords, !kw.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(MinisTheme.secondaryText)
                        Text(kw)
                            .font(.subheadline.bold())
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }

                Text(item.content)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .textSelection(.enabled)
            }
            .padding(.bottom)
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Section Header

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.caption.bold())
            .foregroundStyle(MinisTheme.secondaryText)
            .textCase(.uppercase)
            .padding(.horizontal)
    }
}
