//
//  ScheduledTaskDetailSheet.swift
//  MinisApp
//
//  Beautiful detail & control sheet for scheduled tasks and proactive pulses.
//  Driven 100% by CSSThemeVariables.
//

import SwiftUI

struct ScheduledTaskDetailSheet: View {
    /// [T-dynamic-color] 观察主题，改色立刻重绘（明暗由动态色自己跟 trait）。
    @ObservedObject private var appearanceStudio = AppearanceStudio.shared
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var registry = AgentJobRegistry.shared

    let jobId: String
    @State private var runsList: [ScheduledRun] = []
    @State private var isRunningNow = false
    @State private var confirmDelete = false

    @ObservedObject private var fontSettings = FontSettings.shared
    private var job: AgentJob? { registry.job(id: jobId) }

    var body: some View {
        VStack(spacing: 0) {
            // Drag grabber
            Capsule()
                .fill(CSSThemeVariables.divider())
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 14)

            if let job = job {
                // Header
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: job.isPulse ? "waveform.path.ecg" : "clock.arrow.circlepath")
                        .font(.system(size: fontSettings.scaledApp(22), weight: .semibold))
                        .foregroundStyle(CSSThemeVariables.accent())
                        .frame(width: 44, height: 44)
                        .background(CSSThemeVariables.accentSoft())
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text(job.title)
                            .font(.system(size: fontSettings.scaledApp(17), weight: .bold))
                            .foregroundStyle(CSSThemeVariables.textMain())
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            Text(job.isPulse ? "自主脉搏" : "定时任务")
                                .font(.system(size: fontSettings.scaledApp(11), weight: .medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(CSSThemeVariables.accentSoft())
                                .foregroundStyle(CSSThemeVariables.accent())
                                .clipShape(Capsule())

                            statusBadge(for: job)
                        }
                    }

                    Spacer()

                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: fontSettings.scaledApp(13), weight: .semibold))
                            .foregroundStyle(CSSThemeVariables.textDim())
                            .frame(width: 30, height: 30)
                            .background(CSSThemeVariables.optionBg())
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

                Divider()
                    .overlay(CSSThemeVariables.divider())

                // Scrollable Content
                ScrollView {
                    VStack(spacing: 16) {
                        // Action buttons row
                        HStack(spacing: 10) {
                            // Run Now Button
                            Button {
                                triggerRunNow(job)
                            } label: {
                                HStack(spacing: 6) {
                                    if isRunningNow {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: CSSThemeVariables.accentFg()))
                                            .scaleEffect(0.8)
                                    } else {
                                        Image(systemName: job.isPulse ? "hand.tap.fill" : "play.fill")
                                            .font(.system(size: fontSettings.scaledApp(12)))
                                    }
                                    Text(job.isPulse ? "戳一下" : "立即运行")
                                        .font(.system(size: fontSettings.scaledApp(14), weight: .semibold))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(CSSThemeVariables.accent())
                                .foregroundStyle(CSSThemeVariables.accentFg())
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .disabled(isRunningNow)

                            // Enable / Disable Toggle
                            // [audit-B1] On a TERMINAL task this is a reactivation
                            // (registry resets the state and re-arms the trigger),
                            // not a resume — label and toast say so.
                            Button {
                                let impact = UIImpactFeedbackGenerator(style: .light)
                                impact.impactOccurred()
                                let reactivating = !job.isEnabled && job.state.isTerminal
                                registry.setEnabled(jobId: job.id, enabled: !job.isEnabled)
                                if reactivating {
                                    MinisToast.show("已重新激活，等待下次触发", systemImage: "arrow.clockwise")
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: job.isEnabled ? "pause.fill" : "play.fill")
                                        .font(.system(size: fontSettings.scaledApp(12)))
                                    Text(job.isEnabled ? "暂停" : (job.state.isTerminal ? "重新激活" : "恢复"))
                                        .font(.system(size: fontSettings.scaledApp(14), weight: .medium))
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .background(CSSThemeVariables.optionBg())
                                .foregroundStyle(CSSThemeVariables.textMain())
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(CSSThemeVariables.optionBorder(), lineWidth: 1)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }

                            // Delete Button
                            Button {
                                let impact = UINotificationFeedbackGenerator()
                                impact.notificationOccurred(.warning)
                                confirmDelete = true
                            } label: {
                                Image(systemName: "trash.fill")
                                    .font(.system(size: fontSettings.scaledApp(14)))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                                    .background(CSSThemeVariables.optionBg())
                                    .foregroundStyle(CSSThemeVariables.danger())
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .strokeBorder(CSSThemeVariables.optionBorder(), lineWidth: 1)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                        .padding(.top, 4)

                        // Properties Card
                        VStack(spacing: 12) {
                            detailRow(label: "触发规则", value: job.trigger.humanLabel, icon: "repeat")
                            if let next = job.nextFireAt {
                                detailRow(label: "下次触发", value: ScheduledTimeText.upcoming(next), icon: "timer")
                            }
                            detailRow(label: "已触发次数", value: "\(job.firedCount) 次", icon: "number")
                            if let r = job.remaining {
                                detailRow(label: "剩余次数", value: "\(r) 次", icon: "hourglass")
                            }
                            detailRow(label: "递送说明", value: job.deliverySentenceHuman, icon: "paperplane")
                            if let cmd = job.prefilledTool?.shellCommand {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "terminal.fill")
                                            .font(.system(size: fontSettings.scaledApp(12)))
                                            .foregroundStyle(CSSThemeVariables.accent())
                                        Text("预填命令")
                                            .font(.system(size: fontSettings.scaledApp(12), weight: .semibold))
                                            .foregroundStyle(CSSThemeVariables.textDim())
                                    }
                                    Text(cmd)
                                        .font(.system(size: fontSettings.scaledApp(12), design: .monospaced))
                                        .foregroundStyle(CSSThemeVariables.textMain())
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(CSSThemeVariables.optionBg())
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                            }
                            if let p = job.prompt, !p.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "text.bubble")
                                            .font(.system(size: fontSettings.scaledApp(12)))
                                            .foregroundStyle(CSSThemeVariables.accent())
                                        Text("提示词内容")
                                            .font(.system(size: fontSettings.scaledApp(12), weight: .semibold))
                                            .foregroundStyle(CSSThemeVariables.textDim())
                                    }
                                    Text(p)
                                        .font(.system(size: fontSettings.scaledApp(13)))
                                        .foregroundStyle(CSSThemeVariables.textMain())
                                        .padding(10)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(CSSThemeVariables.optionBg())
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                            }
                        }
                        .padding(16)
                        .background(CSSThemeVariables.card())
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(CSSThemeVariables.optionBorder(), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                        // Runs History Section
                        VStack(alignment: .leading, spacing: 10) {
                            Text("运行记录 (最新 \(runsList.count) 条)")
                                .font(.system(size: fontSettings.scaledApp(14), weight: .semibold))
                                .foregroundStyle(CSSThemeVariables.textDim())

                            if runsList.isEmpty {
                                Text("暂无触发记录")
                                    .font(.system(size: fontSettings.scaledApp(13)))
                                    .foregroundStyle(CSSThemeVariables.textDim().opacity(0.7))
                                    .padding(.vertical, 12)
                                    .frame(maxWidth: .infinity, alignment: .center)
                            } else {
                                ForEach(runsList) { run in
                                    HStack(spacing: 10) {
                                        Image(systemName: run.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                            .font(.system(size: fontSettings.scaledApp(14)))
                                            .foregroundStyle(run.ok ? CSSThemeVariables.success()
                                                : CSSThemeVariables.danger())

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(ScheduledTimeText.past(run.firedAt) + " · " + ScheduledTimeText.clockText(run.firedAt))
                                                .font(.system(size: fontSettings.scaledApp(12), weight: .medium))
                                                .foregroundStyle(CSSThemeVariables.textMain())
                                            if let prev = run.preview {
                                                Text(prev)
                                                    .font(.system(size: fontSettings.scaledApp(11)))
                                                    .foregroundStyle(CSSThemeVariables.textDim())
                                                    .lineLimit(1)
                                            }
                                        }

                                        Spacer()

                                        if let sid = run.sessionId {
                                            Text(String(sid.prefix(6)))
                                                .font(.system(size: fontSettings.scaledApp(10), design: .monospaced))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(CSSThemeVariables.optionBg())
                                                .foregroundStyle(CSSThemeVariables.textDim())
                                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                        }
                                    }
                                    .padding(10)
                                    .background(CSSThemeVariables.optionBg())
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                            }
                        }
                        .padding(16)
                        .background(CSSThemeVariables.card())
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(CSSThemeVariables.optionBorder(), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 30)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: fontSettings.scaledApp(32)))
                        .foregroundStyle(CSSThemeVariables.textDim())
                    Text("未找到该任务或任务已结束")
                        .font(.system(size: fontSettings.scaledApp(14)))
                        .foregroundStyle(CSSThemeVariables.textDim())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
        .background(CSSThemeVariables.bg())
        .alert("删除这个任务？", isPresented: $confirmDelete) {
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) { deleteJob() }
        } message: {
            Text(job?.deleteConfirmMessage ?? "删除后无法恢复。")
        }
        .onAppear {
            if let j = job {
                runsList = registry.runs(jobId: j.id)
            }
        }
    }

    /// [AUD-10] Delete = cancel + remove, the same pair the CLI uses. `remove`
    /// alone dropped the timer and left a running child session working for a
    /// result nobody would ever receive.
    private func deleteJob() {
        guard let job else { return }
        registry.cancel(jobId: job.id, reason: "ui delete")
        registry.remove(jobId: job.id)
        dismiss()
    }

    /// [audit-B2] Was a four-state badge that rendered cancelled / failed /
    /// timed-out tasks as "等待中". Now the shared badge covers every state
    /// (and the list row draws the same one).
    private func statusBadge(for job: AgentJob) -> some View {
        ScheduledJobStatusBadge(job: job)
    }

    private func detailRow(label: String, value: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: fontSettings.scaledApp(12)))
                .foregroundStyle(CSSThemeVariables.accent())
                .frame(width: 16, alignment: .leading)
                .padding(.top, 2)

            Text(label)
                .font(.system(size: fontSettings.scaledApp(13), weight: .medium))
                .foregroundStyle(CSSThemeVariables.textDim())

            Spacer()

            Text(value)
                .font(.system(size: fontSettings.scaledApp(13)))
                .foregroundStyle(CSSThemeVariables.textMain())
                .multilineTextAlignment(.trailing)
        }
    }

    private func triggerRunNow(_ job: AgentJob) {
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        isRunningNow = true
        Task {
            _ = await ScheduledJobRunner.fireNow(job)
            await MainActor.run {
                isRunningNow = false
                runsList = registry.runs(jobId: job.id)
            }
        }
    }
}
