import SwiftUI

// MARK: - 全局正则替换页
//
// [10-19 醒醒] 从 `PersonaContactsView.swift` 里搬出来。
//
// 原来这个页面嵌在人设里（`PersonaRegexRulesView(personaId:)`），规则挂在
// `Persona.regexRules` 上——换个角色规则就没了，也没法单独导出。SillyTavern
// 是全局一份，换角色不变。
//
// 数据层在 `GlobalRegexStore.swift`。这个文件只管界面。

struct GlobalRegexRulesView: View {
    @ObservedObject private var store = GlobalRegexStore.shared

    @State private var showEditor = false
    @State private var editingRuleId: String?
    @State private var ruleName = ""
    @State private var rulePattern = ""
    @State private var ruleReplacement = ""
    @State private var ruleScope = "assistant"
    @State private var ruleVisualOnly = false
    @State private var ruleReplaceOnly = false
    @State private var ruleDepthLimited = false
    @State private var ruleMaxDepth = 10
    /// [04b-2 §3] Copy-mode picker as a sheet, not `.fileImporter`. The
    /// open-in-place picker never gets its FileProvider grant on a resigned
    /// build, so picking a pack did nothing and said nothing.
    @State private var showFilePicker = false
    @State private var importMessage: String?
    /// [04b-2 §1] `importPack` runs from inside the picker, so its result alert
    /// has to be raised after the sheet is gone — an alert requested while a
    /// sheet is on screen is dropped.
    @State private var pendingImportMessage: String?

    var body: some View {
        List {
            Section {
                if store.rules.isEmpty {
                    emptyState
                } else {
                    ForEach(store.rules) { rule in
                        ruleRow(rule)
                    }
                    .onDelete { indexSet in
                        for idx in indexSet {
                            store.remove(id: store.rules[idx].id)
                        }
                    }
                    .onMove { indices, newOffset in
                        store.move(from: indices, to: newOffset)
                    }
                }
            } header: {
                HStack {
                    Text("正则清洗与替换列表")
                    Spacer()
                    if !store.rules.isEmpty {
                        EditButton()
                            .font(.system(size: 13))
                    }
                }
            } footer: {
                Text("规则按顺序应用于生成的内容，对所有会话生效。可用于清洗思考标签、特定前缀或格式修正。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("正则替换")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showFilePicker) {
            DocumentCopyPicker(contentTypes: [.json, .plainText, .data],
                               allowsMultipleSelection: false) { urls in
                guard let url = urls.first else { return }
                importPack(url)
            } onDone: {
                showFilePicker = false
                guard let message = pendingImportMessage else { return }
                pendingImportMessage = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    importMessage = message
                }
            }
        }
        .alert("正则包", isPresented: Binding(
            get: { importMessage != nil },
            set: { if !$0 { importMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { importMessage = nil }
        } message: {
            Text(importMessage ?? "")
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button {
                        DispatchQueue.main.async { showFilePicker = true }
                    } label: {
                        Label("导入 ST 正则包", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        exportPack()
                    } label: {
                        Label("导出到剪贴板", systemImage: "doc.on.clipboard")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16, weight: .medium))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    startCreate()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .medium))
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            editorSheet
        }
    }

    // MARK: 列表

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "textformat")
                .font(.system(size: 28))
                .foregroundStyle(MinisTheme.secondaryText)
            Text("暂无正则替换规则")
                .font(.subheadline)
                .foregroundStyle(MinisTheme.secondaryText)
            Text("点击右上角「+」可添加清洗思考标签、特定前缀或格式修正规则。")
                .font(.caption)
                .foregroundStyle(MinisTheme.secondaryText.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func ruleRow(_ rule: GlobalRegexRule) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(isOn: Binding(
                    get: { rule.enabled },
                    set: { store.setEnabled($0, id: rule.id) }
                )) {
                    HStack(spacing: 6) {
                        Text(rule.name.isEmpty ? "未命名规则" : rule.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(ChatColors.primaryText)
                        scopeBadge(for: rule)
                    }
                }
            }

            Button {
                startEdit(rule)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("/\(rule.pattern)/")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(MinisTheme.secondaryText)
                            .lineLimit(1)
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(MinisTheme.secondaryText.opacity(0.7))
                        Text("\"\(rule.replacement)\"")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(MinisThemeList.accent)
                            .lineLimit(1)
                    }

                    HStack(spacing: 6) {
                        if rule.visualOnly {
                            badge(text: "仅显示替换", color: .purple)
                        }
                        if rule.replaceOnly {
                            badge(text: "仅实际替换", color: .teal)
                        }
                        if let d = rule.maxDepth {
                            badge(text: "最近 \(d) 条", color: .orange)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    // MARK: 编辑器

    private var editorSheet: some View {
        NavigationStack {
            Form {
                Section("规则名称") {
                    TextField("如 去除思考标签", text: $ruleName)
                }

                Section("正则表达式") {
                    TextField("如 <think>[\\s\\S]*?</think>", text: $rulePattern)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section("替换内容") {
                    TextField("替换为 (留空表示删除匹配内容)", text: $ruleReplacement)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section("作用范围") {
                    Picker("生效范围", selection: $ruleScope) {
                        Text("仅助手消息").tag("assistant")
                        Text("仅用户消息").tag("user")
                        Text("思考过程").tag("reasoning")
                        Text("全部消息").tag("all")
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Toggle("只改最近几条", isOn: $ruleDepthLimited)
                    if ruleDepthLimited {
                        Stepper("最近 \(ruleMaxDepth) 条", value: $ruleMaxDepth, in: 0...200)
                    }
                } header: {
                    Text("深度")
                } footer: {
                    Text("开启后只对最近的 N 条消息生效，更早的不动。关掉就是全部。")
                }

                Section("高级选项") {
                    Toggle("仅视觉替换 (不影响历史与上下文)", isOn: $ruleVisualOnly)
                        .onChange(of: ruleVisualOnly) { on in
                            if on { ruleReplaceOnly = false }
                        }
                    Toggle("仅发送前替换 (不影响本地展示)", isOn: $ruleReplaceOnly)
                        .onChange(of: ruleReplaceOnly) { on in
                            if on { ruleVisualOnly = false }
                        }
                }
            }
            .navigationTitle(editingRuleId == nil ? "添加正则规则" : "编辑正则规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showEditor = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveRule()
                        showEditor = false
                    }
                    .disabled(rulePattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: 辅助

    private func scopeBadge(for rule: GlobalRegexRule) -> some View {
        let isAll = rule.scopes.contains("all")
            || (rule.scopes.contains("assistant") && rule.scopes.contains("user"))
        let text: String
        if isAll {
            text = "全部"
        } else if rule.scopes.contains("reasoning") {
            text = "思考"
        } else if rule.scopes.contains("user") {
            text = "用户"
        } else {
            text = "助手"
        }
        let col: Color = isAll ? .orange
            : (rule.scopes.contains("reasoning") ? .purple
               : (rule.scopes.contains("user") ? .blue : .green))
        return badge(text: text, color: col)
    }

    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
            .foregroundStyle(color)
    }

    private func startCreate() {
        editingRuleId = nil
        ruleName = ""
        rulePattern = ""
        ruleReplacement = ""
        ruleScope = "assistant"
        ruleVisualOnly = false
        ruleReplaceOnly = false
        ruleDepthLimited = false
        ruleMaxDepth = 10
        showEditor = true
    }

    private func startEdit(_ rule: GlobalRegexRule) {
        editingRuleId = rule.id
        ruleName = rule.name
        rulePattern = rule.pattern
        ruleReplacement = rule.replacement
        if rule.scopes.contains("all") { ruleScope = "all" }
        else if rule.scopes.contains("reasoning") { ruleScope = "reasoning" }
        else if rule.scopes.contains("user") { ruleScope = "user" }
        else { ruleScope = "assistant" }
        ruleVisualOnly = rule.visualOnly
        ruleReplaceOnly = rule.replaceOnly
        ruleDepthLimited = rule.maxDepth != nil
        ruleMaxDepth = rule.maxDepth ?? 10
        showEditor = true
    }

    private func saveRule() {
        let pat = rulePattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pat.isEmpty else { return }
        let scopes: [String] = ruleScope == "all" ? ["all"] : [ruleScope]
        let item = GlobalRegexRule(
            id: editingRuleId ?? UUID().uuidString,
            name: ruleName.trimmingCharacters(in: .whitespacesAndNewlines),
            pattern: pat,
            replacement: ruleReplacement,
            scopes: scopes,
            visualOnly: ruleVisualOnly,
            replaceOnly: ruleReplaceOnly,
            enabled: true,
            maxDepth: ruleDepthLimited ? ruleMaxDepth : nil,
            minDepth: nil
        )
        if editingRuleId != nil {
            store.update(item)
        } else {
            store.add(item)
        }
    }

    // MARK: ST 正则包互通

    private func importPack(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            pendingImportMessage = "这个文件读不出来。"
            return
        }
        do {
            let rules = try SillyTavernRegex.parse(data)
            for r in rules {
                store.add(GlobalRegexRule(legacy: r))
            }
            pendingImportMessage = "导入 \(rules.count) 条规则。"
        } catch {
            pendingImportMessage = error.localizedDescription
        }
    }

    private func exportPack() {
        guard !store.rules.isEmpty else {
            importMessage = "还没有规则可导出。"
            return
        }
        // 导出走 ST 的字段名，能丢回小酒馆
        let legacy = store.rules.map { r in
            PersonaRegexRule(id: r.id, name: r.name, pattern: r.pattern,
                             replacement: r.replacement, scopes: r.scopes,
                             visualOnly: r.visualOnly, replaceOnly: r.replaceOnly,
                             enabled: r.enabled, maxDepth: r.maxDepth, minDepth: r.minDepth)
        }
        guard let data = SillyTavernRegex.exportJSON(legacy),
              let text = String(data: data, encoding: .utf8) else {
            importMessage = "导出失败。"
            return
        }
        UIPasteboard.general.string = text
        importMessage = "已复制 \(store.rules.count) 条规则到剪贴板。"
    }
}
