import SwiftUI

/// [S3-3][evolution] Settings → 自我进化：总开关与预算。
///
/// 三个开关就是全部回滚面：
///   • 模式 off = 零输出（提示词与基线 byte 级一致）
///   • 影子 = 只记录"本来会参考哪几条"，一条都不用
///   • 启用 = 每轮最多注入预算内的经验
/// 以及记录/整理两个采集开关——关掉即零采集。
struct EvolutionSettingsView: View {

    @StateObject private var settings = EvolutionSettings.shared
    @AppStorage("evolution.extractionEnabled") private var extractionEnabled: Bool = true
    @State private var passResultNote: String?

    var body: some View {
        List {
            Section {
                Picker(selection: $settings.mode) {
                    Text("关闭（off）").tag(EvolutionMode.off)
                    Text("影子（只记录，不使用）").tag(EvolutionMode.shadow)
                    Text("启用（参考经验）").tag(EvolutionMode.active)
                } label: {
                    Text("模式")
                }
            } footer: {
                Text("影子模式会照常检索、并记录「本来会参考哪几条」给你看，但一条都不会真正使用——攒够对比数据、你审过之后，再开「启用」。")
            }

            Section {
                Toggle("记录工具轨迹", isOn: $settings.isRecordingEnabled)
                Toggle("自动整理候选经验", isOn: $extractionEnabled)
            } footer: {
                Text("记录只存脱敏后的轨迹（工具名 / 耗时 / 成败 / 参数摘要），原始内容不落库；关掉即只停「采集」——库里已有的经验照常参与注入，不受影响。")
            }

            Section {
                Stepper(value: $settings.injectionBudgetTokens, in: 50...800, step: 50) {
                    Text("注入预算：约 \(settings.injectionBudgetTokens) token")
                }
            } footer: {
                Text("「启用」模式下每轮最多注入的经验长度；影子模式下只用来估算这份对比。预算最低 50——要完全停用请把上面的模式切到「关闭」。")
            }

            Section {
                Button {
                    passResultNote = "整理中…"
                    Task {
                        guard let store = EvolutionStore.shared else {
                            passResultNote = "进化库不可用"
                            return
                        }
                        await EvolutionExtractionQueue.shared.runPass(on: store)
                        let counts = await store.counts()
                        passResultNote = "完成：经验 \(counts["lessons"] ?? 0) 条 / 轨迹 \(counts["actions"] ?? 0) 条"
                    }
                } label: {
                    Label("立即整理一次", systemImage: "wand.and.stars")
                }
                if let note = passResultNote {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(MinisTheme.secondaryText)
                }
            } footer: {
                Text("平时任务收尾会自动低频整理一次；这里可以手动催它跑一趟。")
            }
        }
        .navigationTitle("自我进化")
    }
}
