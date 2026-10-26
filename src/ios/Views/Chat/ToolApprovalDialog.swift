import SwiftUI

// MARK: - [s2-approve] 工具审批弹窗
//
// 与 OffloadPermissionDialog 同风格的 sheet：标题＋说明＋参数行＋
// 可选的"本次会话不再询问"开关＋允许/拒绝。消费底座 tag == "tool-approval"
// 的挂起（MCP 逐工具审批、日历/提醒写动作、工作区命令总开关）。

struct ToolApprovalDialogModifier: ViewModifier {
    @ObservedObject private var suspension = ToolSuspensionService.shared

    func body(content: Content) -> some View {
        content.sheet(item: approvalRequest) { request in
            ToolApprovalDialogContent(request: request)
                .presentationDetents([.medium, .large])
                .interactiveDismissDisabled()
        }
    }

    private var approvalRequest: Binding<SuspendedRequest?> {
        Binding(
            get: {
                guard let cur = suspension.current, cur.tag == "tool-approval" else { return nil }
                return cur
            },
            set: { _ in }
        )
    }
}

private struct ToolApprovalDialogContent: View {
    let request: SuspendedRequest
    @State private var grantSession = false

    private var payload: ApprovalPayload? {
        if case .approval(let p) = request.kind { return p }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 36))
                            .foregroundStyle(ChatColors.warning)

                        Text("需要你的确认")
                            .font(.title3.bold())

                        if let payload {
                            Text(payload.title)
                                .font(.subheadline)
                                .foregroundStyle(MinisTheme.secondaryText)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 16)

                    // Description
                    if let payload, !payload.description.isEmpty {
                        Text(payload.description)
                            .font(.footnote)
                            .foregroundStyle(MinisTheme.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)
                    }

                    // Rows
                    if let payload, !payload.rows.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(payload.rows.enumerated()), id: \.offset) { idx, row in
                                HStack(alignment: .top) {
                                    Text(row.key)
                                        .font(.footnote.bold())
                                        .foregroundStyle(MinisTheme.secondaryText)
                                        .frame(width: 64, alignment: .trailing)
                                    Text(row.value)
                                        .font(.footnote.monospaced())
                                        .lineLimit(4)
                                    Spacer()
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 8)
                                if idx < payload.rows.count - 1 {
                                    Divider().padding(.leading, 92)
                                }
                            }
                        }
                        .background(AppearanceStudio.shared.color(.surface, scope: .chat))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                    }

                    // "本次会话不再询问"开关
                    if let payload, payload.allowSessionGrant {
                        Toggle("本次会话不再询问这类操作", isOn: $grantSession)
                            .font(.footnote)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                    }
                }
            }

            // Buttons — pinned to the bottom, always tappable.
            if let payload {
                VStack(spacing: 10) {
                    Button {
                        ToolSuspensionService.shared.respond(
                            id: request.id,
                            decision: .approved(grantSession: payload.allowSessionGrant && grantSession)
                        )
                    } label: {
                        Text(payload.approveLabel)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ChatColors.accent)

                    Button {
                        ToolSuspensionService.shared.respond(id: request.id, decision: .denied)
                    } label: {
                        Text(payload.denyLabel)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ChatColors.destructive)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 30)
                .background(AppearanceStudio.shared.color(.raised, scope: .chat))
            }
        }
        .background(AppearanceStudio.shared.color(.raised, scope: .chat))
    }
}

extension View {
    func toolApprovalDialog() -> some View {
        modifier(ToolApprovalDialogModifier())
    }
}
