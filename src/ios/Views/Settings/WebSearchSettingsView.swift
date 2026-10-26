import SwiftUI

/// 「联网搜索」设置页（GAP 第 18 条，[s2-search]）。
///
/// 形态复用仓内现成的凭据录入套路（BridgeExternalConnectionView 同款）：
/// key 只进钥匙串（WebSearchKeys），界面只显示已填/未填不回显明文；
/// 一次可粘多把 key（一行一个，也认逗号/空格分隔），自动拆开轮换。
/// 服务商固定两家（Brave / Tavily），选中的那家是 AI 实际用的。
struct WebSearchSettingsView: View {

    @State private var selectedProvider: String = WebSearchService.selectedProviderId
    /// 每家输入框里的待保存文本（只收新的，不回显钥匙串里的明文）。
    @State private var keyInputs: [String: String] = [:]
    /// 每家已存的 key 数量（只计数，不读明文）。
    @State private var keyCounts: [String: Int] = [:]

    @State private var testingId: String? = nil
    @State private var testedId: String? = nil
    @State private var testMessage: String? = nil
    @State private var testOk: Bool = false

    var body: some View {
        Form {
            Section {
                Picker(AppLocalized("AI 实际使用的服务商"), selection: $selectedProvider) {
                    ForEach(WebSearchService.providers, id: \.providerId) { p in
                        Text(p.displayName).tag(p.providerId)
                    }
                }
                .onChange(of: selectedProvider) { _, new in
                    WebSearchService.selectedProviderId = new
                }
            } header: {
                Text(AppLocalized("服务商"))
            } footer: {
                Text(AppLocalized("两家都是公开 API：Brave Search（独立索引，免费 2000 次/月）、Tavily（专为 AI 优化的搜索，免费 1000 点/月）。官网注册免费拿 key，粘进来就能用。"))
            }

            ForEach(WebSearchService.providers, id: \.providerId) { provider in
                providerSection(provider)
            }
        }
        .navigationTitle(AppLocalized("联网搜索"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reloadCounts)
    }

    // MARK: - 单家服务商

    @ViewBuilder
    private func providerSection(_ provider: any WebSearchProvider) -> some View {
        let pid = provider.providerId
        let count = keyCounts[pid] ?? 0
        Section {
            LabeledContent(AppLocalized("状态")) {
                Text(count > 0
                     ? AppLocalized("已配置（\(count) 把）")
                     : AppLocalized("未填"))
                    .foregroundStyle(MinisTheme.secondaryText)
            }
            SecureField(AppLocalized("粘贴 key（可一次粘多把）"), text: binding(for: pid))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.password)
                .submitLabel(.done)
                .onSubmit { saveKeys(for: provider) }
            if count > 0 {
                Button {
                    testProvider(provider)
                } label: {
                    if testingId == pid {
                        ProgressView()
                    } else {
                        Text(AppLocalized("测试搜一下"))
                    }
                }
                .disabled(testingId != nil)
                Button(role: .destructive) {
                    WebSearchKeys.delete(for: pid)
                    keyInputs[pid] = ""
                    reloadCounts()
                } label: {
                    Text(AppLocalized("清除 \(provider.displayName) 的 key"))
                }
            }
        } header: {
            Text(provider.displayName)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(AppLocalized("一行粘一把 key；也支持一次粘一串（按行/逗号/空格自动拆开），多把 key 会自动轮换、用坏自动换下一把。填好按回车保存。"))
                if let msg = testMessage, testedId == pid {
                    Text(msg)
                        .foregroundStyle(testOk ? .green : .red)
                }
                Text(AppLocalized("申请 key：\(provider.keySignupURL)"))
                    .foregroundStyle(MinisTheme.secondaryText)
            }
        }
    }

    // MARK: - 动作

    private func binding(for pid: String) -> Binding<String> {
        Binding(
            get: { keyInputs[pid] ?? "" },
            set: { keyInputs[pid] = $0 }
        )
    }

    private func reloadCounts() {
        var out: [String: Int] = [:]
        for p in WebSearchService.providers {
            out[p.providerId] = WebSearchKeys.keyCount(for: p.providerId)
        }
        keyCounts = out
        selectedProvider = WebSearchService.selectedProviderId
    }

    /// 输入框里的文本按行/逗号/空格拆成多把 key。
    private func splitKeys(_ raw: String) -> [String] {
        raw.components(separatedBy: CharacterSet(charactersIn: "\n,;"))
            .flatMap { $0.components(separatedBy: .whitespaces) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func saveKeys(for provider: any WebSearchProvider) {
        let pid = provider.providerId
        let keys = splitKeys(keyInputs[pid] ?? "")
        guard !keys.isEmpty else { return }
        WebSearchKeys.save(keys: keys, for: pid)
        keyInputs[pid] = ""
        reloadCounts()
        testedId = pid
        testMessage = AppLocalized("已保存 \(keys.count) 把 key。")
        testOk = true
    }

    /// 拿固定小问题真搜一次，验证 key 可用。
    private func testProvider(_ provider: any WebSearchProvider) {
        let pid = provider.providerId
        testingId = pid
        testedId = nil
        testMessage = nil
        Task {
            do {
                let outcome = try await WebSearchService.search(
                    query: "北京时间", count: 3, as: pid)
                await MainActor.run {
                    testOk = true
                    let first = outcome.results.first?.title ?? ""
                    testedId = pid
                    testMessage = AppLocalized("能用：搜到 \(outcome.results.count) 条，第一条「\(first)」。")
                    testingId = nil
                }
            } catch let err as WebSearchError {
                await MainActor.run {
                    testOk = false
                    testedId = pid
                    testMessage = err.userMessage
                    testingId = nil
                }
            } catch {
                await MainActor.run {
                    testOk = false
                    testedId = pid
                    testMessage = AppLocalized("测试失败：\(error.localizedDescription)")
                    testingId = nil
                }
            }
        }
    }
}
