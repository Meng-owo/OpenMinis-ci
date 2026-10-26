import Foundation
import UIKit
import UserNotifications

/// [T-agent-job-completion-notice] 子代理（delegate_task）跑完了，得让醒醒知道。
///
/// 为什么需要这个文件：`AgentJobRegistry.finish` 一直在发 `.agentJobDidFinish`
/// 通知，但全仓只有 `ScheduledJobRunner` 拿它当「上一个任务结束」的信号，
/// **没有任何 UI 收它**。于是子代理在后台把活干完了，会话里多了一张回调卡，
/// 人却完全不知道 —— 尤其是她当时在看别的会话、或者 App 在后台的时候。
///
/// 三条出口，按场景选：
/// 1. 前台 + 正在看这个会话 → 什么都不做。回调卡就落在眼前，再弹一次是噪音。
/// 2. 前台 + 不在看这个会话 → 给那个会话打未读点 + 一条 toast。未读点她一点就
///    进会话，toast 只是让她知道「刚有东西回来」。
/// 3. App 在后台 → 发本地通知，带 `sessionId`。点通知会走
///    `ShortcutNotificationDelegate.didReceive` 的既有路由直接进会话。
///
/// 只管 `origin == .tool` 的任务。定时任务是另一套：普通触发按她定的规则是
/// **隐身**的（会话不能被打扰填满），要提醒也轮不到这里。
@MainActor
final class AgentJobCompletionNotice {
    static let shared = AgentJobCompletionNotice()

    /// 通知分类。没有 action —— 点一下就是「打开这个会话」。
    private static let categoryId = "AGENT_JOB_DONE"

    private var observer: NSObjectProtocol?
    /// 同一个 job 只提醒一次。`finish` 有 guard 保证单次，这里是第二道。
    ///
    /// 只记最近的若干个：`finish` 已经保证单次，这个集合只是防御性去重，
    /// 没必要随运行时长无限长下去。
    private var announced: Set<String> = []
    private var announcedOrder: [String] = []
    private static let announcedLimit = 64

    private init() {}

    /// 在 App 启动时调一次。重复调安全。
    func start() {
        guard observer == nil else { return }
        registerCategory()
        observer = NotificationCenter.default.addObserver(
            forName: .agentJobDidFinish,
            object: nil,
            queue: .main
        ) { note in
            // 观察闭包不在 main actor 隔离域内，跳回来再读 registry。
            Task { @MainActor in
                AgentJobCompletionNotice.shared.handle(note)
            }
        }
    }

    private func registerCategory() {
        let category = UNNotificationCategory(
            identifier: Self.categoryId,
            actions: [],
            intentIdentifiers: []
        )
        NotificationCategoryRegistry.register(category)
    }

    // MARK: - Handling

    private func handle(_ note: Notification) {
        guard let jobId = note.object as? String else { return }
        guard !announced.contains(jobId) else { return }
        // `finish` 已经把这个 job 从 running/pending 挪走了，registry 里还在
        // （终态任务保留到父会话消失），所以这里能查到。
        guard let job = AgentJobRegistry.shared.job(id: jobId) else { return }
        guard job.origin == .tool else { return }

        let state = (note.userInfo?["state"] as? String).flatMap(AgentJobState.init(rawValue:))
            ?? job.state
        // 用户自己按的停止，不该再被提醒一遍。
        guard state != .cancelled else { return }
        guard let sessionId = targetSessionId(for: job), !sessionId.isEmpty else { return }

        announced.insert(jobId)
        announcedOrder.append(jobId)
        if announcedOrder.count > Self.announcedLimit {
            let dropped = announcedOrder.removeFirst()
            announced.remove(dropped)
        }

        let title = job.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title.isEmpty ? AppLocalized("后台任务") : title

        let isActive = UIApplication.shared.applicationState == .active
        let isViewing = AIChatViewModel.activeSessionId == sessionId

        if isActive {
            // 正在看：回调卡就在眼前，别再弹。
            guard !isViewing else { return }
            SessionBadgeStore.shared.pushFront(.unread, for: sessionId)
            MinisToast.show(
                Self.toastText(name: name, state: state),
                duration: 2.4,
                systemImage: state == .failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
            )
        } else {
            SessionBadgeStore.shared.pushFront(.unread, for: sessionId)
            postNotification(name: name, state: state, sessionId: sessionId)
        }
    }

    /// 提醒应该落到哪个会话上 —— 必须是用户点一下就能看到结果的那个。
    ///
    /// `childOfCurrent` 是隐藏的子会话，用户点不进去；结果是以回调卡的形式
    /// 落在**父会话**里的，所以指父会话。
    private func targetSessionId(for job: AgentJob) -> String? {
        switch job.target {
        case .childOfCurrent(let parent, _): return parent
        case .followUp(let sid): return sid
        case .rerun(let sid, _): return sid
        case .new: return job.runSessionId
        }
    }

    private static func toastText(name: String, state: AgentJobState) -> String {
        switch state {
        case .done: return String(format: AppLocalized("「%@」完成了"), name)
        case .failed: return String(format: AppLocalized("「%@」失败了"), name)
        case .timeout: return String(format: AppLocalized("「%@」超时了"), name)
        case .cancelled, .pending, .running: return name
        }
    }

    private func postNotification(name: String, state: AgentJobState, sessionId: String) {
        // 和别处一致：这个键不存在时默认开，显式关掉才不发。
        if let enabled = UserDefaults.standard.object(forKey: "backgroundNotificationsEnabled") as? Bool,
           !enabled { return }

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            // 只在从没问过的时候问。已经在跑的任务不该把系统弹窗甩到用户脸上。
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }

        let content = UNMutableNotificationContent()
        content.title = Self.notificationTitle(name: name, state: state)
        content.body = AppLocalized("点一下查看结果")
        content.sound = .default
        content.categoryIdentifier = Self.categoryId
        content.userInfo = ["sessionId": sessionId]

        let request = UNNotificationRequest(
            identifier: "agent-job-\(sessionId)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil   // 立即投递
        )
        center.add(request) { error in
            if let error {
                NSLog("[AgentJobNotice] notification not delivered: %@", error.localizedDescription)
            }
        }
    }

    private static func notificationTitle(name: String, state: AgentJobState) -> String {
        switch state {
        case .done: return "✅ " + name
        case .failed: return "❌ " + name
        case .timeout: return "⏱ " + name
        case .cancelled, .pending, .running: return name
        }
    }
}
