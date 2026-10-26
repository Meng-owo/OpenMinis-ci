import SwiftUI

/// [S6-2][evolution] 经验库：候选/已验证/冲突/已弃用的查看与人工裁决。
/// 裁决只改状态指针 + version+1（§6 只增不改），从不物理删除；
/// 裁决后立刻让注入器缓存失效，下一轮影子/注入按新状态走。
struct EvolutionLessonsView: View {

    @State private var candidate: [EvolutionLesson] = []
    @State private var verified: [EvolutionLesson] = []
    @State private var conflicts: [EvolutionLesson] = []
    @State private var deprecated: [EvolutionLesson] = []
    @State private var busy = false

    var body: some View {
        List {
            section(title: "待审候选", items: candidate,
                    emptyHint: "暂无候选。系统整理出经验后会出现在这里。")
            section(title: "已验证", items: verified, emptyHint: nil)
            section(title: "冲突冻结（待你裁决）", items: conflicts,
                    emptyHint: "两种信号打架的条目会冻结在这里，永不自动使用。")
            section(title: "已弃用", items: deprecated, emptyHint: nil)
        }
        .navigationTitle("经验库")
        .task { await reload() }
        .overlay {
            if busy { ProgressView() }
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private func section(title: String, items: [EvolutionLesson], emptyHint: String?) -> some View {
        if !items.isEmpty || emptyHint != nil {
            Section(title) {
                if items.isEmpty, let hint = emptyHint {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(MinisTheme.secondaryText)
                }
                ForEach(items, id: \.id) { lesson in
                    lessonRow(lesson)
                }
            }
        }
    }

    private func lessonRow(_ lesson: EvolutionLesson) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(lesson.taskSignature ?? lesson.id)
                    .font(.callout.bold())
                Spacer()
                Text("v\(lesson.version)")
                    .font(.caption2)
                    .foregroundStyle(MinisTheme.secondaryText.opacity(0.7))
            }
            Text(lesson.recommendation.isEmpty ? lesson.conditions : lesson.recommendation)
                .font(.footnote)
            if lesson.failureCount > 0 || lesson.successCount > 0 {
                Text("见证：成功 \(lesson.successCount) · 失败 \(lesson.failureCount)")
                    .font(.caption2)
                    .foregroundStyle(MinisTheme.secondaryText)
            }
            HStack(spacing: 10) {
                if lesson.status != .verified {
                    Button("通过") { Task { await set(lesson, .verified) } }
                        .buttonStyle(.borderless)
                }
                if lesson.status != .deprecated {
                    Button("弃用") { Task { await set(lesson, .deprecated) } }
                        .buttonStyle(.borderless)
                        .tint(.secondary)
                }
                if lesson.status != .candidate {
                    Button("回到候选") { Task { await set(lesson, .candidate) } }
                        .buttonStyle(.borderless)
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Actions

    private func set(_ lesson: EvolutionLesson, _ status: EvolutionLessonStatus) async {
        busy = true
        defer { busy = false }
        guard let store = EvolutionStore.shared else { return }
        _ = await store.updateLessonStatus(id: lesson.id, status: status)
        EvolutionInjector.shared.invalidate()   // 下一轮按新状态检索
        await reload()
    }

    private func reload() async {
        guard let store = EvolutionStore.shared else { return }
        candidate = await store.lessons(status: .candidate)
        verified = await store.lessons(status: .verified)
        conflicts = await store.lessons(status: .conflicts)
        deprecated = await store.lessons(status: .deprecated)
    }
}
