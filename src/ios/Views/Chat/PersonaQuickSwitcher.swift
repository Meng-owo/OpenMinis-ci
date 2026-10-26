import SwiftUI

// MARK: - PersonaQuickSwitcher
//
// [batch9b · 一击切换] 顶部标题点开的人设快捷浮层：标题正下方浮出人设
// 列表，点谁切谁；底部一行「管理人设…」进完整管理页（新建/编辑/删除/复制）。
//
// 为什么自绘而不是 .popover：
//  ① iPhone 上 popover 默认被系统适配成 sheet（正是要去的形态），必须
//    逆着系统默认走，且本仓零 .popover 先例；
//  ② 浮层挂在稳定列表层（本仓已有同范式的 folderMiniBarOverlay），
//    不挂 toolbar principal——那个区域是本仓两次事故（丢通知 / UAF）的现场；
//  ③ 「管理人设…」要开 sheet，popover 内嵌套 present 易碎。
//
// 交互：点行 = 切换（当前项则仅收起）；点空白 = 收起；切换不等 DB 往返，
// 列表刷新由既有 .personaDidChange 链在后台完成。
//
// [batch9b+] 视觉规范化（醒醒反馈：材质灰底与主题不适配、卡片高度不跟
// 数量走、观感不高级）：
//  ① 底色从 .regularMaterial 材质改为主题「浮层」角色 .raised——浅色主题
//    即纯白（FFFFFF）、暗色主题自动跟随（2E2621），天然主题适配；
//  ② 卡片高度按人设数量自适应：行高固定 48pt 精确预计算，≤6 人不滚动
//    （高度=内容高），超过 300pt 封顶滚动；不再用"撑满 maxHeight"的
//    固定观感；
//  ③ 观感收敛：圆角 16→20、大柔阴影、0.5pt 细描边、发丝分隔线（对齐
//    名字缩进）、隐藏滚动指示器、管理行图标与头像轴心对齐。

struct PersonaQuickSwitcher: View {
    @ObservedObject var store: PersonaStore

    /// 点「管理人设…」：宿主先收浮层、动画完成后开管理 sheet。
    var onManage: () -> Void
    /// 点空白处收起。
    var onDismiss: () -> Void

    // MARK: - Metrics
    // 行高固定值：自适应高度 = 行数 × 行高 + 分隔线，精确可算，不依赖
    // ScrollView 的自撑行为（它默认会撑满可用高度——旧观感的来源）。
    private let rowHeight: CGFloat = 48
    private let manageRowHeight: CGFloat = 48
    private let hairlineWidth: CGFloat = 0.5
    private let maxListHeight: CGFloat = 300

    private var listHeight: CGFloat {
        let count = store.chatSelectablePersonas.count
        guard count > 0 else { return rowHeight }
        let dividers = CGFloat(count - 1) * hairlineWidth
        return min(CGFloat(count) * rowHeight + dividers, maxListHeight)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // 点任何空白处收起。浅遮罩：下方会话列表仍可见（切换后立刻能看到列表变化）。
            Color.black.opacity(0.10)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            card
                .padding(.horizontal, 20)
                .padding(.top, 4)
        }
        .transition(.opacity)
    }

    // MARK: - Card

    private var card: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(store.chatSelectablePersonas) { p in
                        personaRow(p)
                        if p.id != store.chatSelectablePersonas.last?.id {
                            hairline(inset: true)
                        }
                    }
                }
            }
            .frame(height: listHeight)
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)

            hairline(inset: false)

            manageRow
        }
        .frame(maxWidth: 340)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(AppearanceStudio.shared.color(.raised))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AppearanceStudio.shared.color(.border).opacity(0.45), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.14), radius: 24, y: 10)
    }

    /// 发丝分隔线。inset = 对齐名字文字（头像 30 + spacing 12 + 左内边 14 = 56）。
    private func hairline(inset: Bool) -> some View {
        Rectangle()
            .fill(AppearanceStudio.shared.color(.border).opacity(0.55))
            .frame(height: hairlineWidth)
            .padding(.leading, inset ? 56 : 0)
    }

    // MARK: - Row

    private func personaRow(_ p: Persona) -> some View {
        Button {
            // 点当前项 = 只想收起，不做无谓的 setCurrent（其自带同值 guard）。
            if p.id != store.currentPersonaID {
                store.setCurrent(p.id)
            }
            onDismiss()
        } label: {
            HStack(spacing: 12) {
                PersonaAvatarView(iconRef: p.avatar, size: 30)

                Text(p.name)
                    .font(.body)
                    .foregroundStyle(AppearanceStudio.shared.color(.primaryText))
                    .lineLimit(1)

                if p.isBuiltIn {
                    Text("内置")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(AppearanceStudio.shared.color(.mutedSurface)))
                        .foregroundStyle(AppearanceStudio.shared.color(.secondaryText))
                }

                Spacer()

                if p.id == store.currentPersonaID {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppearanceStudio.shared.color(.accent))
                }
            }
            .padding(.horizontal, 14)
            .frame(height: rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Manage Row

    private var manageRow: some View {
        Button {
            onManage()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.2.crop.square.stack")
                    .font(.system(size: 15))
                    .foregroundStyle(AppearanceStudio.shared.color(.secondaryText))
                    .frame(width: 30)
                Text("管理人设…")
                    .font(.subheadline)
                    .foregroundStyle(AppearanceStudio.shared.color(.primaryText))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppearanceStudio.shared.color(.secondaryText))
            }
            .padding(.horizontal, 14)
            .frame(height: manageRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
