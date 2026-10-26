import SwiftUI

/// [S6-1][evolution] 进化中心：数据总览 + 最近轨迹 + 子页入口。
/// 数据与库直接一致（打开即读、下拉即刷）。
struct EvolutionCenterView: View {

    /// [playhub-rebuild] 嵌进「播放」页时，不再自设导航标题（避免和父页抢标题）。
    var embedded: Bool = false

    @State private var counts: [String: Int] = [:]
    @State private var runs: [EvolutionRun] = []
    @State private var loading = false
    /// [E05] 注入台账：影子/启用每次参考的记账（recentInjections 的首个业务消费者）。
    @State private var injections: [EvolutionInjection] = []
    /// [audit-D4] 维护/清空的就地回执。
    @State private var maintenanceNote: String?
    @State private var confirmClear = false

    /// [P6-2][evolution] 订阅首次参考通知：候选被注入参考时，顶部横幅可见。
    @ObservedObject private var noticeCenter = EvolutionNoticeCenter.shared

    var body: some View {
        VStack(spacing: 0) {
            if let message = noticeCenter.pendingMessage {
                noticeBanner(message)
            }
            List {
                Section {
                    LazyVGrid(columns: [
                        GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()),
                    ], spacing: 10) {
                        statCard("轨迹", counts["runs"] ?? 0)
                        statCard("动作", counts["actions"] ?? 0)
                        statCard("经验", counts["lessons"] ?? 0)
                        statCard("技能", counts["skills"] ?? 0)
                        statCard("影子命中", counts["injections"] ?? 0)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("数据总览")
                }

                Section {
                    NavigationLink {
                        EvolutionLessonsView()
                    } label: {
                        Label("经验库", systemImage: "text.badge.checkmark")
                    }
                    NavigationLink {
                        EvolutionSettingsView()
                    } label: {
                        Label("开关与预算", systemImage: "switch.2")
                    }
                } footer: {
                    Text("默认「影子」：只记录、不使用——攒够对比数据、你审过之后，再考虑开「启用」。")
                }

                // [E05] 把影子模式"记录「本来会参考哪几条」给你看"的承诺兑现：
                // 台账此前只有写侧（insert）和读 API（recentInjections，零消费者）。
                Section {
                    if injections.isEmpty {
                        Text("还没有注入记账。开「影子」用一会儿，这里会记下每次「本来会参考」的条目。")
                            .foregroundStyle(MinisTheme.secondaryText)
                            .font(.footnote)
                    } else {
                        ForEach(injections, id: \.id) { inj in
                            injectionRow(inj)
                        }
                    }
                } header: {
                    Text("最近注入")
                } footer: {
                    Text("影子与启用都会记账：影子记「本来会参考哪几条」，启用记「真的注入了哪几条」；上面的「影子命中」是总数。")
                }

                // [audit-D4] 维护入口：此前 prune() / clearAll() 全仓零调用，
                // 页上只有注释在承诺"会出现在进化中心"。
                Section {
                    Button {
                        runMaintenance()
                    } label: {
                        Label("立即维护（清理过期/超限）", systemImage: "wrench.and.screwdriver")
                    }
                    Button(role: .destructive) {
                        confirmClear = true
                    } label: {
                        Label("清空进化库", systemImage: "trash")
                    }
                    if let note = maintenanceNote {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(MinisTheme.secondaryText)
                    }
                } header: {
                    Text("维护")
                } footer: {
                    Text("维护只删过期 / 超限的轨迹与注入记账（经验条目永不物理删除）；清空会抹掉全部进化数据，不可恢复。")
                }

                Section {
                    if runs.isEmpty {
                        Text("还没有轨迹。用一会儿，任务收尾后这里就有账了。")
                            .foregroundStyle(MinisTheme.secondaryText)
                            .font(.footnote)
                    } else {
                        ForEach(runs, id: \.id) { run in
                            runRow(run)
                        }
                    }
                } header: {
                    HStack {
                        Text("最近轨迹")
                        Spacer()
                        if loading { ProgressView() }
                    }
                }
            }
            .modifier(EvolutionCenterEmbeddedTitle(embedded: embedded))
            .refreshable { await reload() }
            .confirmationDialog("清空进化库？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清空", role: .destructive) {
                    Task {
                        guard let store = EvolutionStore.shared else { return }
                        await store.clearAll()
                        // 注入器可能还留着清空前的缓存片段——失效，下一轮重读。
                        EvolutionInjector.shared.invalidate()
                        maintenanceNote = "进化库已清空"
                        await reload()
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("所有经验、轨迹与注入记账都会被删除，无法恢复。")
            }
            .task { await reload() }
        }
    }

    // MARK: - Pieces

    /// [P6-2][evolution] 首次参考横幅：文案即 pendingMessage，手动关闭或 3 秒自动消失。
    private func noticeBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(MinisTheme.accent)
            Text(message)
                .font(.footnote)
                .foregroundStyle(MinisTheme.primaryText)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button {
                EvolutionNoticeCenter.shared.clearPending()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .foregroundStyle(MinisTheme.secondaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(MinisTheme.raised, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(MinisTheme.border, lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .task(id: message) {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            EvolutionNoticeCenter.shared.clearPending()
        }
    }

    private func statCard(_ title: String, _ value: Int) -> some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.title3.bold())
                .monospacedDigit()
            Text(title)
                .font(.caption2)
                .foregroundStyle(MinisTheme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func runRow(_ run: EvolutionRun) -> some View {
        HStack(spacing: 10) {
            Image(systemName: statusSymbol(run.status))
                .foregroundStyle(statusColor(run.status))
            VStack(alignment: .leading, spacing: 2) {
                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.callout)
                Text(detailLine(run))
                    .font(.caption2)
                    .foregroundStyle(MinisTheme.secondaryText)
            }
        }
        .padding(.vertical, 1)
    }

    /// [E05] 单条注入记账：影子=eye（"本来会参考"）、启用=下箭头（真的注入了）。
    private func injectionRow(_ inj: EvolutionInjection) -> some View {
        let isShadow = inj.mode == EvolutionMode.shadow.rawValue
        return HStack(spacing: 10) {
            Image(systemName: isShadow ? "eye" : "arrow.down.circle.fill")
                .foregroundStyle(isShadow ? Color.secondary : Color.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(inj.injectedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.callout)
                // [T-dynamic-color] 原来整串塞在一个 Text 里，含 `.map` 闭包，
                // 没法静态化成 key，切英文后这一行还是中文。拆成「固定部分走
                // 查表 + 可选后缀单独拼」。
                Text(
                    "\(AppLocalized("经验")) \(inj.lessonId.prefix(8)) · \(inj.tokenCost) token"
                    + (inj.sessionId.map { " · " + AppLocalized("会话") + " \($0.prefix(6))" } ?? "")
                )
                    .font(.caption2)
                    .foregroundStyle(MinisTheme.secondaryText)
            }
        }
        .padding(.vertical, 1)
    }

    private func statusSymbol(_ status: EvolutionRunStatus) -> String {
        switch status {
        case .ok: return "checkmark.circle"
        case .cancelled: return "slash.circle"
        case .error: return "exclamationmark.circle"
        case .limit: return "gauge.with.needle"
        }
    }

    private func statusColor(_ status: EvolutionRunStatus) -> Color {
        switch status {
        case .ok: return .green
        case .cancelled: return .orange
        case .error: return .red
        case .limit: return .yellow
        }
    }

    private func detailLine(_ run: EvolutionRun) -> String {
        var parts: [String] = ["\(run.toolCallCount) 次工具", run.source]
        if let sid = run.sessionId, !sid.isEmpty {
            parts.append("会话 \(sid.prefix(6))")
        }
        return parts.joined(separator: " · ")
    }

    /// [audit-D4] Bounded-growth pass, on demand — `prune()` had no caller.
    private func runMaintenance() {
        Task {
            guard let store = EvolutionStore.shared else { return }
            await store.prune()
            maintenanceNote = "已清理过期与超限的轨迹 / 注入记录"
            await reload()
        }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        guard let store = EvolutionStore.shared else { return }
        counts = await store.counts()
        runs = await store.recentRuns(limit: 30)
        injections = await store.recentInjections(limit: 12)
    }
}


/// [playhub-rebuild] 允许进化中心被「播放」页内嵌：内嵌时不抢父页标题。
private struct EvolutionCenterEmbeddedTitle: ViewModifier {
    let embedded: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if embedded {
            content
        } else {
            content.navigationTitle("进化中心")
        }
    }
}
