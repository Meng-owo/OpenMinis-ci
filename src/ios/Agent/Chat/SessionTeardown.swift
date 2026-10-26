import Foundation

// MARK: - SessionTeardown
//
// [batch9c / 调研 E2] 会话删除的**统一运行时收尾**。
//
// 背景：手动删除（ContentView.deleteSession / deleteSelectedSessions）会做一整套
// 运行时收尾；但级联删除（删人设 → ChatStore.deleteSessions(forPersonaId:)）
// 历史上只删 DB 行、绕过了这套收尾 —— 后果是"会话从库里没了，但定时任务还在
// 触发、子 agent 还在烧 token、浏览器池与每会话文件不回收"（audit E2）。
//
// 现在两条链都走这里。今后任何"删除会话"的新路径也必须走这里。
//
// - Note: `selectedSessionId` 的清理是 UI 职责（ContentView 自己处理），
//   不在本函数范围内。

@MainActor
enum SessionTeardown {

    /// 运行时收尾：VM 缓存、浏览器池、定时任务/排队委托/子 agent、会话文件。
    static func tearDownRuntime(sessionId: String, reason: String = "session deleted") {
        ViewModelCache.shared.remove(sessionId: sessionId)
        BrowserUseOffloadBridge.releasePool(forSession: sessionId)

        // [AUD2-03] Tear down the work this session owns before it leaves the
        // store: its scheduled jobs would otherwise keep firing against a
        // deleted session (recordFire(ok:false) forever), and any running sub
        // agent would keep burning tokens until it naturally finished.
        AgentJobRegistry.shared.cancelScheduled(createdBy: sessionId, reason: reason)
        AgentJobRegistry.shared.dropQueuedDelegations(parent: sessionId, reason: reason)
        AgentJobRegistry.shared.cancelAll(parent: sessionId, reason: reason, silent: true)

        deleteSessionFiles(sessionId)
    }

    /// 删除会话的持久化文件：每会话 minis 目录（Library/MinisChat/minis/<sid>/）
    /// + 浏览器快照持久数据。
    static func deleteSessionFiles(_ sessionId: String) {
        let fm = FileManager.default
        let base = fm.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MinisChat/minis", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
        try? fm.removeItem(at: base)
        BrowserTabPool.deletePersistedData(for: sessionId)
    }
}
