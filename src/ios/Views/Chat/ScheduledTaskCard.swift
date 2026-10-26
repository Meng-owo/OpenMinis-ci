//
//  ScheduledTaskCard.swift
//  MinisApp
//
//  Elegant in-chat scheduled task / proactive pulse card.
//  Driven 100% by CSSThemeVariables.
//

import SwiftUI

// MARK: - [AUD-17] 定时任务的人话文案
//
// The list and the detail sheet printed the machine shapes straight at the user:
// `loop(3600s×∞)`, `cron(9:0 days=[2, 3, 4, 5, 6])`, raw ISO timestamps, and an
// English delivery paragraph. Nothing here is new data — it is the same job
// fields, said the way a person would say them.

enum ScheduledTimeText {
    /// "即将触发" / "约 5 分钟后" / "约 2 小时后" / "明天 09:00" / "10-15 08:30"
    static func upcoming(_ date: Date) -> String {
        let diff = date.timeIntervalSinceNow
        if diff < 60 { return "即将触发" }
        if diff < 3600 { return "约 \(Int(diff / 60)) 分钟后" }
        if diff < 86400 { return "约 \(Int(diff / 3600)) 小时后" }
        if Calendar.current.isDateInTomorrow(date) { return "明天 " + clockText(date) }
        if Calendar.current.isDateInToday(date) { return "今天 " + clockText(date) }
        return absoluteText(date)
    }

    /// "刚刚" / "5 分钟前" / "2 小时前" / "昨天 09:00" / "10-15 08:30"
    static func past(_ date: Date) -> String {
        let diff = Date().timeIntervalSince(date)
        if diff < 60 { return "刚刚" }
        if diff < 3600 { return "\(Int(diff / 60)) 分钟前" }
        if diff < 86400 { return "\(Int(diff / 3600)) 小时前" }
        if Calendar.current.isDateInYesterday(date) { return "昨天 " + clockText(date) }
        return absoluteText(date)
    }

    /// "14:03"
    static func clockText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// "10-15 08:30"
    static func absoluteText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }
}

extension AgentJobTrigger {
    /// "立即执行" / "30 分钟后执行一次" / "每 1 小时，共 3 次" / "工作日 09:00" /
    /// "上一个任务完成后". The `logLabel` form stays for logs and the CLI.
    var humanLabel: String {
        switch self {
        case .immediate:
            return "立即执行"
        case .once(let after):
            return Self.durationText(after) + "后执行一次"
        case .loop(let interval, let count):
            let every = "每 " + Self.durationText(interval)
            guard let count else { return every + "重复" }
            return every + "，共 \(count) 次"
        case .cron(let hour, let minute, let days, let start, let end):
            let time = String(format: "%02d:%02d", hour, minute)
            let allowed = days.isEmpty ? Set(1...7) : days
            var text: String
            if allowed == Set(1...7) {
                text = "每天 " + time
            } else if allowed == Set(2...6) {
                text = "工作日 " + time
            } else {
                let names = ["日", "一", "二", "三", "四", "五", "六"]
                let list = allowed.sorted().map { names[($0 - 1) % 7] }.joined(separator: "、")
                text = "每周" + list + " " + time
            }
            if start != nil || end != nil { text += "（限定时段）" }
            return text
        case .onCompletion:
            return "上一个任务完成后"
        }
    }

    /// "90 秒" / "30 分钟" / "2 小时" / "1 天"
    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total >= 86400, total % 86400 == 0 { return "\(total / 86400) 天" }
        if total >= 3600, total % 3600 == 0 { return "\(total / 3600) 小时" }
        if total >= 60, total % 60 == 0 { return "\(total / 60) 分钟" }
        return "\(total) 秒"
    }
}

extension AgentJob {
    /// [AUD-17] Where a fire lands, in plain Chinese. The stored
    /// `deliverySentence` stays the CLI receipt's machine-shaped wording; a
    /// person should not have to read that to know where the result goes.
    var deliverySentenceHuman: String {
        switch target {
        case .new:
            return "每次触发都会新开一个会话运行，结果不会出现在这里。"
        case .followUp:
            return "每次触发都会在目标会话里接着往下运行，结果出现在那个会话里。"
        case .rerun:
            return "每次触发都会重跑那条历史消息。"
        case .childOfCurrent:
            return "每次触发都会在本会话下开一个隐藏的子任务，跑完把结果发回这里。"
        }
    }
}

// [AUD-10] One wording for the two delete entry points (the list swipe and the
// detail sheet's trash button), because they delete the same thing.
extension AgentJob {
    /// The question the delete confirmation asks, including what else dies with it.
    var deleteConfirmMessage: String {
        if hasRunningChild {
            return "「\(title)」的子任务还在运行。删除会把这次运行一并停掉，它的结果不会再回到会话里。"
        }
        if state == .running || state == .pending {
            return "「\(title)」还在等待触发，删除后不会再运行，历史记录也会一起消失。"
        }
        return "「\(title)」的运行记录会一起消失，删除后无法恢复。"
    }
}

// MARK: - [audit-B2] 任务状态徽章（列表行与详情页共用）

/// [audit-B2] ONE honest label per state — the list row and the detail sheet
/// share it so the two cannot drift (the AUD-17 lesson). Before this the badge
/// knew only paused/running/done/pending: a cancelled, failed or timed-out
/// task all rendered "等待中", indistinguishable from a live schedule.
@MainActor
enum ScheduledJobStatusText {
    static func label(for job: AgentJob) -> String {
        switch job.state {
        case .cancelled: return "已取消"
        case .failed:    return "失败"
        case .timeout:   return "已超时"
        case .done:      return "已完成"
        case .running:   return job.isEnabled ? "运行中" : "已暂停"
        case .pending:   return job.isEnabled ? "等待中" : "已暂停"
        }
    }

    static func style(for job: AgentJob) -> (label: String, color: Color) {
        let color: Color
        switch job.state {
        case .failed:    color = CSSThemeVariables.danger()
        case .timeout:   color = CSSThemeVariables.warning()
        case .cancelled: color = CSSThemeVariables.textDim()
        case .done:      color = CSSThemeVariables.accent()
        case .running:   color = job.isEnabled ? CSSThemeVariables.success()
                                               : CSSThemeVariables.warning()
        case .pending:   color = job.isEnabled ? CSSThemeVariables.accent()
                                               : CSSThemeVariables.warning()
        }
        return (label(for: job), color)
    }
}

/// Shared capsule badge (list row + detail header).
struct ScheduledJobStatusBadge: View {
    let job: AgentJob

    /// [T-dynamic-color] 观察主题，改色立刻重绘（明暗由动态色自己跟 trait）。
    @ObservedObject private var appearanceStudio = AppearanceStudio.shared
    @ObservedObject private var fontSettings = FontSettings.shared

    var body: some View {
        let styled = ScheduledJobStatusText.style(for: job)
        // [T-dynamic-color] String 直接进 Text 不查表，切英文后状态标签还是中文。
        Text(LocalizedStringKey(styled.label))
            .font(.system(size: fontSettings.scaledApp(11), weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(styled.color.opacity(0.12))
            .foregroundStyle(styled.color)
            .clipShape(Capsule())
    }
}

/// The full card for an ordinary scheduled task.
///
/// [AUD-19] Currently unreferenced — and that is the consequence of a decision,
/// not an oversight: an ordinary firing is 隐身 by the user's own rule (the chat
/// must not fill up with them), so a `.scheduled` callback renders as
/// `EmptyView` (ChatMessageViews) and the visible card belongs to pulses
/// (`ScheduledPulseCardView` above). The card is left in place as the ready
/// surface for the day ordinary tasks get a visible body; the alternatives are
/// to wire it somewhere (the tasks list draws its own rows) or to delete it, and
/// removing a surface the user asked for is her call, not a cleanup pass's.
struct ScheduledTaskCard: View {
    /// [T-dynamic-color] 观察主题，改色立刻重绘（明暗由动态色自己跟 trait）。
    @ObservedObject private var appearanceStudio = AppearanceStudio.shared
    @ObservedObject var registry = AgentJobRegistry.shared

    let jobId: String
    @State private var showingDetail = false

    @ObservedObject private var fontSettings = FontSettings.shared
    private var job: AgentJob? { registry.job(id: jobId) }

    var body: some View {
        if let job = job {
            Button {
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                showingDetail = true
            } label: {
                HStack(spacing: 12) {
                    // Left Icon
                    ZStack {
                        Circle()
                            .fill(CSSThemeVariables.accentSoft())
                            .frame(width: 38, height: 38)

                        Image(systemName: job.isPulse ? "waveform.path.ecg" : "clock.arrow.circlepath")
                            .font(.system(size: fontSettings.scaledApp(17), weight: .semibold))
                            .foregroundStyle(CSSThemeVariables.accent())
                    }

                    // Middle Info
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(job.title)
                                .font(.system(size: fontSettings.scaledApp(14), weight: .semibold))
                                .foregroundStyle(CSSThemeVariables.textMain())
                                .lineLimit(1)

                            Text(job.isPulse ? "脉搏" : "定时")
                                .font(.system(size: fontSettings.scaledApp(10), weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(CSSThemeVariables.accentSoft())
                                .foregroundStyle(CSSThemeVariables.accent())
                                .clipShape(Capsule())
                        }

                        HStack(spacing: 8) {
                            Text(job.trigger.humanLabel)
                                .font(.system(size: fontSettings.scaledApp(12)))
                                .foregroundStyle(CSSThemeVariables.textDim())

                            if let next = job.nextFireAt {
                                Text("下次: \(formatNext(next))")
                                    .font(.system(size: fontSettings.scaledApp(11)))
                                    .foregroundStyle(CSSThemeVariables.textDim().opacity(0.8))
                            }
                        }
                    }

                    Spacer()

                    // Right Status & Chevron
                    HStack(spacing: 6) {
                        Circle()
                            .fill(job.isEnabled ? CSSThemeVariables.success()
                                : CSSThemeVariables.warning())
                            .frame(width: 7, height: 7)

                        Image(systemName: "chevron.right")
                            .font(.system(size: fontSettings.scaledApp(12), weight: .semibold))
                            .foregroundStyle(CSSThemeVariables.textDim())
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(CSSThemeVariables.card())
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(CSSThemeVariables.optionBorder(), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: CSSThemeVariables.sheetShadow().opacity(0.04), radius: 4, x: 0, y: 2)
            }
            .buttonStyle(PlainButtonStyle())
            .sheet(isPresented: $showingDetail) {
                ScheduledTaskDetailSheet(jobId: job.id)
            }
        }
    }

    /// [AUD-17] Third copy of the same phrasing — now the shared one, so the card,
    /// the list and the detail sheet cannot tell the user three different things.
    private func formatNext(_ date: Date) -> String { ScheduledTimeText.upcoming(date) }
}

// MARK: - 自主脉搏触发卡片（聊天流内，仅脉搏类任务渲染）

/// [T-scheduled-prefill-and-pulse] 小梦被自主脉搏唤醒时在会话里留下的一张轻声卡片。
/// 普通定时任务仍然完全隐身（不打扰），只有「脉搏」——小梦主动想找醒醒——
/// 才会留下这个痕迹，且体积小、无边框噪音。点一下即可看到完整详情与运行记录。
struct ScheduledPulseCardView: View {
    /// [T-dynamic-color] 观察主题，改色立刻重绘（明暗由动态色自己跟 trait）。
    @ObservedObject private var appearanceStudio = AppearanceStudio.shared
    @ObservedObject var registry = AgentJobRegistry.shared
    let jobId: String
    let title: String
    var fireIndex: Int?
    var remaining: Int?

    /// [audit-C2] Fixed geometry so the message list can precompute this row's
    /// height exactly — the estimator cannot measure a SwiftUI card, and a
    /// mismatch is the "wrong offset near the card" scroll correction. The
    /// frame caps the card content; `rowHeight` adds the card's own outer
    /// `.padding(.vertical, 3)` for the list.
    static let cardHeight: CGFloat = 56
    static let rowHeight: CGFloat = cardHeight + 6

    @State private var showingDetail = false

    @ObservedObject private var fontSettings = FontSettings.shared

    /// [AUD-16] Whose pulse this is — the persona's own name from SOUL,
    /// not a literal. Falls back to the plain noun when nothing is set.
    private var pulseHeadline: String {
        let name = SoulStore.cachedMetadata.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? AppLocalized("自主脉搏") : "\(name) · " + AppLocalized("自主脉搏")
    }

    var body: some View {
        // [AUD-05] The card is split into two siblings on purpose: the body
        // opens the detail sheet, and the trailing control pauses/resumes the
        // task. A control nested inside the body's own Button label would never
        // receive the tap (the outer button swallows it) — and "the cancel
        // entry is unreachable" is exactly what the audit found. This is the
        // one card a scheduled task actually renders (see ChatMessageViews: the
        // 隐身 rule hides ordinary firings), so the entry lives here.
        HStack(spacing: 8) {
            Button {
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                showingDetail = true
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(CSSThemeVariables.accentSoft())
                            .frame(width: 30, height: 30)
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: fontSettings.scaledApp(13), weight: .semibold))
                            .foregroundStyle(CSSThemeVariables.accent())
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(pulseHeadline)
                            .font(.system(size: fontSettings.scaledApp(13), weight: .semibold))
                            .foregroundStyle(CSSThemeVariables.textMain())
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            Text(title)
                                .font(.system(size: fontSettings.scaledApp(11)))
                                .foregroundStyle(CSSThemeVariables.textDim())
                                .lineLimit(1)
                            if let f = fireIndex {
                                Text("· 第\(f)次")
                                    .font(.system(size: fontSettings.scaledApp(11)))
                                    .foregroundStyle(CSSThemeVariables.textDim().opacity(0.8))
                            }
                            if let r = remaining, r > 0 {
                                Text("· 剩\(r)")
                                    .font(.system(size: fontSettings.scaledApp(11)))
                                    .foregroundStyle(CSSThemeVariables.textDim().opacity(0.8))
                            }
                        }
                    }

                    Spacer(minLength: 4)

                    Image(systemName: "chevron.right")
                        .font(.system(size: fontSettings.scaledApp(11), weight: .semibold))
                        .foregroundStyle(CSSThemeVariables.textDim().opacity(0.8))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Pause / resume in place. Deliberately reversible (the task stays
            // in the list and comes back with one more tap) rather than a
            // destructive cancel: this control sits on a card that appears
            // while the user is doing something else. Cancelling or deleting
            // remains a confirmed action in the detail sheet (AUD-10).
            if let job = registry.job(id: jobId),
               job.trigger != .immediate,
               job.state == .pending || job.state == .running {
                let isLive = registry.isLiveScheduled(jobId: jobId)
                Button {
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                    registry.setEnabled(jobId: jobId, enabled: !isLive)
                } label: {
                    Image(systemName: isLive ? "pause.circle" : "play.circle")
                        .font(.system(size: fontSettings.scaledApp(16), weight: .regular))
                        .foregroundStyle(CSSThemeVariables.textDim())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isLive ? AppLocalized("Pause") : AppLocalized("Resume"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(height: Self.cardHeight)
        .background(CSSThemeVariables.card())
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(CSSThemeVariables.optionBorder(), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: CSSThemeVariables.sheetShadow().opacity(0.05), radius: 4, x: 0, y: 2)
        .padding(.vertical, 3)
        .sheet(isPresented: $showingDetail) {
            ScheduledTaskDetailSheet(jobId: jobId)
        }
    }
}
