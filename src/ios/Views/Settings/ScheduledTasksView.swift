//
//  ScheduledTasksView.swift
//  MinisApp
//
//  Complete management screen for scheduled tasks and proactive pulses.
//  Aligns with and surpasses Android's ScheduledTasksScreen.
//  Driven 100% by CSSThemeVariables.
//

import SwiftUI

struct ScheduledTasksView: View {
    /// [T-dynamic-color] 观察主题，改色立刻重绘（明暗由动态色自己跟 trait）。
    @ObservedObject private var appearanceStudio = AppearanceStudio.shared
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var registry = AgentJobRegistry.shared

    @State private var selectedJobId: String? = nil
    @State private var pendingDeleteId: String? = nil
    /// [AUD-21] Set when the system has notification permission turned off —
    /// the "insurance notification" is the only thing standing behind a task
    /// while the app is not running, so its absence has to be visible here.
    @State private var notificationsDenied = false

    @ObservedObject private var fontSettings = FontSettings.shared
    private var allJobs: [AgentJob] { registry.list() }

    /// A task that will still fire by itself: enabled and not finished.
    private var liveTimerCount: Int {
        allJobs.filter { $0.isEnabled && ($0.state == .pending || $0.state == .running) && $0.trigger != .immediate }.count
    }

    /// [AUD-10] The row waiting for its delete confirmation.
    private var pendingJob: AgentJob? { pendingDeleteId.flatMap { registry.job(id: $0) } }

    /// [AUD-10] Delete = cancel + remove, the same pair the CLI uses. `remove`
    /// on its own dropped the timer and left a running child session working
    /// for a result nobody would ever receive.
    private func performDelete() {
guard let id = pendingDeleteId else { return }
        registry.cancel(jobId: id, reason: "ui delete")
        registry.remove(jobId: id)
        pendingDeleteId = nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("定时任务与脉搏")
                    .font(.system(size: fontSettings.scaledApp(20), weight: .bold))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: fontSettings.scaledApp(13), weight: .semibold))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                        .frame(width: 32, height: 32)
                        .background(CSSThemeVariables.optionBg(scope: .settings))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            // [AUD-20] One line to tell this screen apart from the older,
            // notification-based "Scheduled Prompts" (Settings ▸ Automation):
            // the two are named similarly and behave differently in exactly the
            // way a user would want to know about before trusting either.
            Text("这些任务在应用内运行：到点由 Minis 自己触发。应用不在时不会执行——下次打开会重新挂上，并把这期间错过的触发记成一笔。")
                .font(.system(size: fontSettings.scaledApp(11)))
                .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 10)

            Divider()
                .overlay(CSSThemeVariables.divider(scope: .settings))

            // Body
            if allJobs.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "clock.badge.questionmark")
                        .font(.system(size: fontSettings.scaledApp(44)))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings).opacity(0.6))
                    Text("暂无挂载的定时任务或脉搏")
                        .font(.system(size: fontSettings.scaledApp(15), weight: .medium))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                    Text("可以在聊天里直接创建一个。")
                        .font(.system(size: fontSettings.scaledApp(12)))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings).opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    // [AUD-21] The fallback notification is off — say so, here,
                    // where the tasks that rely on it are listed.
                    if notificationsDenied && liveTimerCount > 0 {
                        Section {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "bell.slash")
                                    .font(.system(size: fontSettings.scaledApp(15)))
                                    .foregroundStyle(CSSThemeVariables.warning(scope: .settings))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("系统通知被关掉了")
                                        .font(.system(size: fontSettings.scaledApp(13), weight: .semibold))
                                        .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))
                                    Text("任务到点时应用不在前台，就没有任何提醒；打开通知可让兜底提醒恢复。")
                                        .font(.system(size: fontSettings.scaledApp(11)))
                                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    // Summary Section
                    Section {
                        HStack(spacing: 16) {
                            summaryCard(title: "总任务数", count: allJobs.count, icon: "list.bullet")
                            summaryCard(title: "活跃运行中", count: allJobs.filter { $0.isEnabled && $0.state != .done }.count, icon: "play.circle.fill")
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .padding(.vertical, 8)
                    }

                    // Task Items Section
                    Section {
                        ForEach(allJobs) { job in
                            taskRow(for: job)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedJobId = job.id
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        pendingDeleteId = job.id
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
                .listStyle(InsetGroupedListStyle())
                .alert("删除这个任务？", isPresented: Binding(
                    get: { pendingDeleteId != nil },
                    set: { if !$0 { pendingDeleteId = nil } }
                )) {
                    Button("取消", role: .cancel) { pendingDeleteId = nil }
                    Button("删除", role: .destructive) { performDelete() }
                } message: {
                    Text(pendingJob?.deleteConfirmMessage ?? "删除后无法恢复。")
                }
                .scrollContentBackground(.hidden)
                .background(CSSThemeVariables.bg(scope: .settings))
            }
        }
        .background(CSSThemeVariables.bg(scope: .settings))
        .sheet(item: Binding<IdentifiableJobId?>(
            get: { selectedJobId.map { IdentifiableJobId(id: $0) } },
            set: { selectedJobId = $0?.id }
        )) { ident in
            ScheduledTaskDetailSheet(jobId: ident.id)
        }
        .task {
            // [AUD-21] Read the permission state once when the screen appears;
            // the answer only changes from outside the app (Settings), and this
            // screen is re-created on every visit.
            notificationsDenied = await JobInsuranceNotification.notificationsDenied()
        }
    }

    private func summaryCard(title: String, count: Int, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: fontSettings.scaledApp(20)))
                .foregroundStyle(CSSThemeVariables.accent(scope: .settings))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: fontSettings.scaledApp(11)))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))
                Text("\(count)")
                    .font(.system(size: fontSettings.scaledApp(18), weight: .bold))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(CSSThemeVariables.card(scope: .settings))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(CSSThemeVariables.optionBorder(scope: .settings), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func taskRow(for job: AgentJob) -> some View {
        HStack(spacing: 12) {
            Image(systemName: job.isPulse ? "waveform.path.ecg" : "clock.arrow.circlepath")
                .font(.system(size: fontSettings.scaledApp(16), weight: .semibold))
                .foregroundStyle(CSSThemeVariables.accent(scope: .settings))
                .frame(width: 34, height: 34)
                .background(CSSThemeVariables.accentSoft(scope: .settings))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(job.title)
                        .font(.system(size: fontSettings.scaledApp(15), weight: .semibold))
                        .foregroundStyle(CSSThemeVariables.textMain(scope: .settings))
                        .lineLimit(1)

                    if job.isPulse {
                        Text("脉搏")
                            .font(.system(size: fontSettings.scaledApp(10), weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(CSSThemeVariables.accentSoft(scope: .settings))
                            .foregroundStyle(CSSThemeVariables.accent(scope: .settings))
                            .clipShape(Capsule())
                    }
                }

                HStack(spacing: 8) {
                    Text(job.trigger.humanLabel)
                        .font(.system(size: fontSettings.scaledApp(12)))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .settings))

                    if let next = job.nextFireAt {
                        Text("下次: \(formatNext(next))")
                            .font(.system(size: fontSettings.scaledApp(11)))
                            .foregroundStyle(CSSThemeVariables.textDim(scope: .settings).opacity(0.8))
                    }
                }
            }

            Spacer()

            // [audit-B2] The row used to show only a switch; a cancelled or
            // timed-out task looked exactly like a live one. Same badge as the
            // detail sheet (shared, cannot drift).
            ScheduledJobStatusBadge(job: job)

            Toggle("", isOn: Binding<Bool>(
                get: { job.isEnabled },
                set: { v in
                    // [audit-B1] Flipping the switch on a finished task now
                    // really re-activates it (registry resets state + re-arms);
                    // say so, because the row's badge changes 已完成 → 等待中.
                    let reactivating = v && job.state.isTerminal
                    registry.setEnabled(jobId: job.id, enabled: v)
                    if reactivating {
                        MinisToast.show("已重新激活「\(job.title)」，等待下次触发", systemImage: "arrow.clockwise")
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(SwitchToggleStyle(tint: CSSThemeVariables.accent(scope: .settings)))
        }
        .padding(.vertical, 4)
    }

    /// [AUD-17] Was a private "5m / 2h" shorthand; now the shared human phrasing
    /// so the list and the detail sheet cannot drift apart.
    private func formatNext(_ date: Date) -> String { ScheduledTimeText.upcoming(date) }
}

private struct IdentifiableJobId: Identifiable {
    let id: String
}
