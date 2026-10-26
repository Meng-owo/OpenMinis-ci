import Foundation

/// [S3-2][evolution] Injector — shadow-first retrieval layer.
///
/// Modes (`EvolutionSettings.mode`):
///   • `.off`    → returns "" always — the prompt is byte-identical to a
///                 build that never had this file.
///   • `.shadow` → returns "" (NEVER injects) but records what WOULD have
///                 been injected into `injections` (mode="shadow") — the
///                 promotion dataset required before `active` is allowed.
///   • `.active` → returns the rendered `<evolution-tips>` fragment, built
///                 from an async-refreshed cache (the prompt builder is
///                 synchronous, so the cache warms one step ahead).
///
/// The cache refreshes at most once per `refreshInterval`, entirely off the
/// prompt path, and can be invalidated explicitly by lesson edits (S6-2) or
/// mode switches (OPT-3).
final class EvolutionInjector: @unchecked Sendable {

    static let shared = EvolutionInjector()

    enum Constants {
        static let topK = 3
        static let refreshInterval: TimeInterval = 120
        /// Cost model from design §12: ≈3.5 chars per token.
        static let charsPerToken = 3.5
        /// Shadow-hit logging throttle — a rapid multi-turn conversation
        /// must not spam the injections table.
        static let shadowLogInterval: TimeInterval = 60
        /// OPT-1: how many most-recent actions contribute to the "active
        /// tool set" for relevance filtering (distinct tool names).
        static let activeToolWindow = 40
    }

    // MARK: - Pure surface (unit-tested)

    /// Which mode actually injects into the prompt. Shadow never does —
    /// that is the whole point of shadow.
    static func injects(mode: EvolutionMode) -> Bool {
        mode == .active
    }

    /// OPT-1: tool-relevance gate. A lesson carrying a tool tag
    /// (`taskSignature`) only passes when the current active tool set
    /// contains that tag — unrelated domains must not pollute the prompt
    /// ("无关的会干扰"). Untagged (generic) lessons always pass. A `nil`
    /// active set means "unknown" → keep everything (back-compat).
    static func filterRelevant(_ lessons: [EvolutionLesson],
                               activeTools: Set<String>?) -> [EvolutionLesson] {
        guard let activeTools else { return lessons }
        return lessons.filter { lesson in
            guard let tag = lesson.taskSignature, !tag.isEmpty else { return true }
            return activeTools.contains(tag)
        }
    }

    /// Render the would-be fragment: relevance gate first, then verified
    /// first, then injectPriority desc, capped at Top-K lines and the token
    /// budget. When the gate empties the set (宁缺毋滥) the fragment is ""
    /// rather than padding with off-domain lessons.
    static func render(lessons: [EvolutionLesson], budgetTokens: Int,
                       activeTools: Set<String>? = nil) -> String {
        let relevant = filterRelevant(lessons, activeTools: activeTools)
        let eligible = relevant.filter { $0.status == .verified || $0.status == .candidate }
        guard !eligible.isEmpty, budgetTokens > 0 else { return "" }
        let ranked = rank(eligible)
        let maxChars = max(80, Int(Double(budgetTokens) * Constants.charsPerToken))
        let header = "<evolution-tips>"
        let footer = "</evolution-tips>"
        var used = header.count + footer.count + 2
        var lines: [String] = []
        for lesson in ranked.prefix(Constants.topK) {
            let tag = lesson.status == .verified ? "已验证" : "候选"
            let line = "- [\(tag)] \(lineText(for: lesson))"
            if used + line.count + 1 > maxChars { break }
            lines.append(line)
            used += line.count + 1
        }
        guard !lines.isEmpty else { return "" }
        return header + "\n" + lines.joined(separator: "\n") + "\n" + footer
    }

    /// Shared ranking: verified outranks candidate, then priority, then id.
    static func rank(_ lessons: [EvolutionLesson]) -> [EvolutionLesson] {
        lessons.sorted { a, b in
            if a.status != b.status { return a.status == .verified }
            if a.injectPriority != b.injectPriority { return a.injectPriority > b.injectPriority }
            return a.id < b.id
        }
    }

    private static func lineText(for lesson: EvolutionLesson) -> String {
        let who = lesson.taskSignature ?? "工具"
        let body = lesson.recommendation.isEmpty ? lesson.conditions : lesson.recommendation
        return "\(who)：\(body)"
    }

    // MARK: - Cache

    private let lock = NSLock()
    private var cachedLessons: [EvolutionLesson] = []
    private var cachedFragment = ""
    private var lastRefreshAt = Date.distantPast
    private var lastShadowLogAt = Date.distantPast

    /// Called from `buildTurnSystemPrompt` (MainActor, synchronous).
    func turnFragment(sessionId: String?) -> String {
        let mode = EvolutionSettings.currentMode
        guard mode != .off else { return "" }
        refreshIfStale(sessionId: sessionId)
        let (lessons, fragment) = lockedSnapshot()
        guard !fragment.isEmpty else { return "" }
        if mode == .shadow {
            logShadowHit(lessons: lessons, fragment: fragment)
            return ""          // ★ shadow NEVER injects
        }
        // OPT-2: active mode logs every actual injection into the same
        // ledger shadow uses — lesson_id / time / session context / mode.
        logActiveHit(lessons: lessons, fragment: fragment, sessionId: sessionId)
        return fragment
    }

    /// Explicit invalidation after lesson edits (S6-2), data wipes, or mode
    /// switches (OPT-3) — next turn refreshes immediately.
    func invalidate() {
        lock.lock()
        lastRefreshAt = .distantPast
        lock.unlock()
    }

    // MARK: - Internals

    private func lockedSnapshot() -> ([EvolutionLesson], String) {
        lock.lock()
        defer { lock.unlock() }
        return (cachedLessons, cachedFragment)
    }

    private func refreshIfStale(sessionId: String?) {
        // [audit-D3] This used to guard on `recordingEnabled` too — so flipping
        // the COLLECTION switch off also froze this cache and killed injection
        // of every lesson already in the library (a cold start with the toggle
        // off: never refreshes at all). Recording governs collection only
        // (EvolutionRecorder / EvolutionExtractor); what may be INJECTED is
        // governed by `mode` alone — see the guard in `turnFragment` above.
        let budget = EvolutionSettings.budgetTokens
        lock.lock()
        let due = Date().timeIntervalSince(lastRefreshAt) > Constants.refreshInterval
        if due { lastRefreshAt = Date() }     // claim the slot before spawning
        lock.unlock()
        guard due else { return }
        Task.detached(priority: .utility) { [weak self, sessionId] in
            guard let self, let store = EvolutionStore.shared else { return }
            let candidates = await store.lessons(status: .candidate)
            let verified = await store.lessons(status: .verified)
            // OPT-1: the active tool set comes from the triggering session's
            // recent actions (zero new instrumentation) and gates the cache —
            // shadow logging below therefore reflects the filtered result too.
            let activeTools = await store.recentToolNames(sessionId: sessionId,
                                                          limit: Constants.activeToolWindow)
            let all = candidates + verified
            let fragment = Self.render(lessons: all, budgetTokens: budget,
                                       activeTools: activeTools)
            self.lock.withLock {
                self.cachedLessons = Self.filterRelevant(all, activeTools: activeTools)
                self.cachedFragment = fragment
            }
        }
    }

    private func logShadowHit(lessons: [EvolutionLesson], fragment: String) {
        lock.lock()
        let due = Date().timeIntervalSince(lastShadowLogAt) > Constants.shadowLogInterval
        if due { lastShadowLogAt = Date() }
        lock.unlock()
        guard due else { return }

        let ranked = Self.rank(lessons.filter { $0.status == .verified || $0.status == .candidate })
            .prefix(Constants.topK)
        let perLineTokens = max(1, Int(Double(fragment.count) / Constants.charsPerToken / Double(max(1, ranked.count))))
        let entries: [(String, Int)] = ranked.map { ($0.id, perLineTokens) }
        guard !entries.isEmpty else { return }
        Task.detached(priority: .utility) {
            guard let store = EvolutionStore.shared else { return }
            for entry in entries {
                await store.insert(EvolutionInjection(
                    id: UUID().uuidString,
                    runId: nil,
                    lessonId: entry.0,
                    injectedAt: Date(),
                    tokenCost: entry.1,
                    mode: EvolutionMode.shadow.rawValue,
                    outcomeLinked: nil
                ))
            }
        }
    }

    /// OPT-2: every ACTUAL injection in active mode lands in the injections
    /// ledger (unthrottled — this is the "what was really used" audit trail).
    /// The first time a candidate lesson is referenced, one lightweight
    /// notice fires (never again for that lesson).
    private func logActiveHit(lessons: [EvolutionLesson], fragment: String,
                              sessionId: String?) {
        let ranked = Self.rank(lessons.filter { $0.status == .verified || $0.status == .candidate })
            .prefix(Constants.topK)
        guard !ranked.isEmpty else { return }
        let perLineTokens = max(1, Int(Double(fragment.count) / Constants.charsPerToken / Double(max(1, ranked.count))))
        let entries: [(EvolutionLesson, Int)] = ranked.map { ($0, perLineTokens) }
        Task.detached(priority: .utility) { [sessionId] in
            guard let store = EvolutionStore.shared else { return }
            for (lesson, cost) in entries {
                await store.insert(EvolutionInjection(
                    id: UUID().uuidString,
                    runId: nil,
                    sessionId: sessionId,
                    lessonId: lesson.id,
                    injectedAt: Date(),
                    tokenCost: cost,
                    mode: EvolutionMode.active.rawValue,
                    outcomeLinked: nil
                ))
                if lesson.status == .candidate {
                    await EvolutionNoticeCenter.shared.notifyFirstReferenceIfNeeded(
                        lessonId: lesson.id)
                }
            }
        }
    }
}

// MARK: - [OPT-2][evolution] One-time first-reference notice

/// The lightest possible "someone got referenced" signal: a single banner
/// line in the evolution center, once per lesson ever. Persisted via
/// UserDefaults so "ever" survives launches; repeat injections of the same
/// lesson never re-announce.
@MainActor
final class EvolutionNoticeCenter: ObservableObject {

    static let shared = EvolutionNoticeCenter()

    /// Banner text while non-nil; the evolution center shows it and the
    /// owner clears it after a beat.
    @Published var pendingMessage: String?

    nonisolated private static let notifiedKey = "evolution.firstReferenceNotified."

    /// One-time gate (pure, injectable for tests): returns true only the
    /// first time a lesson id is seen, and atomically marks it notified.
    nonisolated static func shouldMarkFirstReference(lessonId: String,
                                                     defaults: UserDefaults = .standard) -> Bool {
        let key = notifiedKey + lessonId
        guard !defaults.bool(forKey: key) else { return false }
        defaults.set(true, forKey: key)
        return true
    }

    /// Called from the active-injection logger (any thread — hops here).
    func notifyFirstReferenceIfNeeded(lessonId: String) -> Bool {
        guard Self.shouldMarkFirstReference(lessonId: lessonId) else { return false }
        pendingMessage = "进化库：候选「\(lessonId)」首次被参考——可去经验库查看或裁决"
        return true
    }

    func clearPending() {
        pendingMessage = nil
    }
}