import Foundation
import SQLite3
import Combine

private let evoLogger = AppLogger(category: "EvolutionStore")

/// Global SQLite destructor so every bind COPIES its bytes. The evolution
/// store is written from background actors; transient binds remove any
/// question about string-buffer lifetime between bind and step.
private let EVO_SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - [S2-1][evolution] Value types

enum EvolutionRunStatus: String, Codable {
    case ok, error, cancelled, limit
}

enum EvolutionActionStatus: String, Codable {
    case success, fail, timeout, cancelled
}

enum EvolutionLessonStatus: String, Codable {
    case candidate, verified, deprecated
    /// Both signals fired for the same target (failure cluster + recovery
    /// witnesses): frozen pending human review, never injected (S3-1 §6).
    case conflicts
}

enum EvolutionSkillStatus: String, Codable {
    case draft, active, retired
}

/// Three-position switch for the whole system (settings).
/// `shadow` = record + retrieve + log what WOULD be injected, inject nothing.
enum EvolutionMode: String, Codable, CaseIterable {
    case off, shadow, active
}

struct EvolutionRun: Codable, Equatable {
    var id: String
    var sessionId: String?
    var personaId: String?
    /// Normalized task fingerprint (keywords + tool-domain tags), may be empty
    /// until the S3 feature extractor fills it.
    var taskSignature: String?
    var startedAt: Date
    var endedAt: Date?
    var status: EvolutionRunStatus
    var turnCount: Int
    var toolCallCount: Int
    var retryCount: Int
    var tokensEst: Int
    var modelId: String?
    /// chat / subagent / scheduled / pulse
    var source: String
}

struct EvolutionAction: Codable, Equatable {
    var id: String
    var runId: String
    var seq: Int
    var toolName: String
    /// Redacted argument profile (EvolutionRedactor.profile). Never raw args.
    var profile: String
    var status: EvolutionActionStatus
    var errorClass: String?
    var errorDigest: String?
    var durationMs: Int
    var retryCount: Int
    var resultDigest: String?
}

struct EvolutionLesson: Codable, Equatable {
    var id: String
    /// global / persona / session-template
    var scope: String
    var personaId: String?
    var taskSignature: String?
    var conditions: String
    var recommendation: String
    var antiPattern: String?
    /// JSON array of evidence action ids (audit trail).
    var evidenceActions: String
    var status: EvolutionLessonStatus
    var successCount: Int
    var failureCount: Int
    var version: Int
    var parentId: String?
    var lastVerifiedAt: Date?
    var injectPriority: Int
}

struct EvolutionSkill: Codable, Equatable {
    var id: String
    var name: String
    var description: String
    var paramsJSON: String?
    var deps: String?
    var permissions: String?
    /// Where the implementation lives: SKILL.md / minis-cli script / tool-chain template.
    var implRef: String?
    var testStatus: String
    var invocations: Int
    var successRate: Double
    var version: Int
    var status: EvolutionSkillStatus
}

struct EvolutionInjection: Codable, Equatable {
    var id: String
    var runId: String?
    /// OPT-2: session context of the reference (active mode logs this;
    /// shadow rows keep it nil).
    var sessionId: String?
    var lessonId: String
    var injectedAt: Date
    var tokenCost: Int
    /// EvolutionMode.rawValue — only shadow/active actually log here.
    var mode: String
    var outcomeLinked: String?
}

enum EvolutionStoreError: Error {
    case openFailed(String)
}

// MARK: - [S2-1][evolution] Store

/// Own SQLite database (Library/MinisChat/evolution.db), deliberately NOT
/// sharing minis.db: local-only, independently wipeable, and regenerable —
/// losing it degrades to "no learned experience", it never breaks the app.
///
/// `actor`, mirroring VoiceCorrectionDB: every call is off the MainActor by
/// construction, which is what lets the S2-2 recording hooks be
/// fire-and-forget. Self-healing open: an unreadable file is deleted and
/// recreated empty rather than propagated.
///
/// Nothing in the app wires into this store yet — S2-1 ships the foundation
/// (schema + CRUD + redaction + tests) only.
actor EvolutionStore {

    // MARK: Singleton

    static let shared: EvolutionStore? = {
        do {
            return try EvolutionStore()
        } catch {
            evoLogger.error("[Evolution][DB] unrecoverable open failure (\(error)) — evolution disabled")
            return nil
        }
    }()

    // MARK: Limits (see design doc §4: bounded, auditable growth)

    enum Limits {
        static let maxActionRows = 20_000
        static let maxRunRows = 5_000
        static let maxInjectionRows = 10_000
        static let ttlDays = 90
    }

    // MARK: Storage

    private var db: OpaquePointer?
    private let dbURL: URL

    static func defaultURL() -> URL {
        let library = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let base = library.appendingPathComponent("MinisChat", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("evolution.db")
    }

    init(url: URL? = nil) throws {
        let resolvedURL = url ?? Self.defaultURL()
        self.dbURL = resolvedURL
        let dir = resolvedURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        do {
            self.db = try Self.openAndPrepare(at: resolvedURL)
        } catch {
            // Self-heal (mirrors VoiceCorrectionDB §11.3): a corrupt/partial
            // file is regenerable learning data — throw it away and come back
            // as a cold-start empty DB rather than run without a store.
            let size = (try? FileManager.default
                .attributesOfItem(atPath: resolvedURL.path)[.size] as? Int) ?? nil
            evoLogger.error("[Evolution][DB] open_failed error=\(error) action=rebuilt_empty_db previousSizeBytes=\(size.map(String.init) ?? "unknown")")
            try? FileManager.default.removeItem(at: resolvedURL)
            // A WAL DB has sidecar files; a stale -wal/-shm next to a fresh
            // main file is its own corruption source.
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: resolvedURL.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: resolvedURL.path + "-shm"))
            self.db = try Self.openAndPrepare(at: resolvedURL)   // one retry; if this throws, `shared` degrades to nil
        }
        evoLogger.info("[Evolution][DB] opened at \(resolvedURL.path)")
    }

    // No `deinit { sqlite3_close(db) }` — same reasoning as VoiceCorrectionDB:
    // under strict concurrency a nonisolated deinit may not touch the actor's
    // non-Sendable `OpaquePointer?` state, and this is a process-lifetime
    // singleton whose deinit would only run at process exit anyway.

    private static func openAndPrepare(at url: URL) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw EvolutionStoreError.openFailed("rc=\(rc) path=\(url.path)")
        }
        // auto_vacuum MUST be set before any table is created — INCREMENTAL so
        // cleanup can reclaim pages in bounded chunks (VoiceCorrectionDB §13.4).
        exec(handle, "PRAGMA auto_vacuum = INCREMENTAL")
        // WAL: readers never block on the background writer, and vice versa.
        exec(handle, "PRAGMA journal_mode = WAL")
        exec(handle, "PRAGMA synchronous = NORMAL")
        createTables(handle)
        // Schema version marker for future migrations.
        exec(handle, "PRAGMA user_version = 1")
        // Idempotent additive-column repair (mirrors VoiceCorrectionDB §11.4):
        // `session_id` ships inside the v1 CREATE TABLE above for fresh
        // installs; this repairs any DB written by a build that predated it.
        // Additive + nullable, so old builds that never SELECT it are
        // unaffected — no user_version bump (§11.4 rule 4).
        ensureIdempotentColumns(handle)
        return handle
    }

    /// Additive-only column repair for the injections table, run on every
    /// open regardless of `user_version` (VoiceCorrectionDB §11.4 pattern).
    /// Skips when the table does not exist yet — a fresh DB gets the column
    /// from the CREATE TABLE above.
    private static func ensureIdempotentColumns(_ db: OpaquePointer?) {
        guard db != nil else { return }
        var existing = Set<String>()
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(injections)", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 1) {
                    existing.insert(String(cString: c))
                }
            }
        }
        sqlite3_finalize(stmt)
        // Empty = table not created yet (fresh DB, the CREATE above includes
        // the column). Skip so we don't log a spurious "no such table".
        guard !existing.isEmpty, !existing.contains("session_id") else { return }
        exec(db, "ALTER TABLE injections ADD COLUMN session_id TEXT")
        evoLogger.info("[Evolution][DB] schema repair: added injections.session_id")
    }

    private static func createTables(_ db: OpaquePointer?) {
        exec(db, """
            CREATE TABLE IF NOT EXISTS runs (
                id             TEXT PRIMARY KEY,
                session_id     TEXT,
                persona_id     TEXT,
                task_signature TEXT,
                started_at     REAL NOT NULL,
                ended_at       REAL,
                status         TEXT NOT NULL,
                turn_count     INTEGER NOT NULL DEFAULT 0,
                tool_call_count INTEGER NOT NULL DEFAULT 0,
                retry_count    INTEGER NOT NULL DEFAULT 0,
                tokens_est     INTEGER NOT NULL DEFAULT 0,
                model_id       TEXT,
                source         TEXT NOT NULL DEFAULT 'chat'
            )
        """)
        exec(db, """
            CREATE TABLE IF NOT EXISTS actions (
                id           TEXT PRIMARY KEY,
                run_id       TEXT NOT NULL,
                seq          INTEGER NOT NULL,
                tool_name    TEXT NOT NULL,
                profile      TEXT NOT NULL DEFAULT '',
                status       TEXT NOT NULL,
                error_class  TEXT,
                error_digest TEXT,
                duration_ms  INTEGER NOT NULL DEFAULT 0,
                retry_count  INTEGER NOT NULL DEFAULT 0,
                result_digest TEXT,
                created_at   REAL NOT NULL
            )
        """)
        exec(db, """
            CREATE TABLE IF NOT EXISTS lessons (
                id              TEXT PRIMARY KEY,
                scope           TEXT NOT NULL,
                persona_id      TEXT,
                task_signature  TEXT,
                conditions      TEXT NOT NULL DEFAULT '',
                recommendation  TEXT NOT NULL DEFAULT '',
                anti_pattern    TEXT,
                evidence_actions TEXT NOT NULL DEFAULT '[]',
                status          TEXT NOT NULL,
                success_count   INTEGER NOT NULL DEFAULT 0,
                failure_count   INTEGER NOT NULL DEFAULT 0,
                version         INTEGER NOT NULL DEFAULT 1,
                parent_id       TEXT,
                last_verified_at REAL,
                inject_priority INTEGER NOT NULL DEFAULT 0,
                created_at      REAL NOT NULL,
                updated_at      REAL NOT NULL
            )
        """)
        exec(db, """
            CREATE TABLE IF NOT EXISTS skills (
                id           TEXT PRIMARY KEY,
                name         TEXT NOT NULL,
                description  TEXT NOT NULL DEFAULT '',
                params_json  TEXT,
                deps         TEXT,
                permissions  TEXT,
                impl_ref     TEXT,
                test_status  TEXT NOT NULL DEFAULT 'untested',
                invocations  INTEGER NOT NULL DEFAULT 0,
                success_rate REAL NOT NULL DEFAULT 0,
                version      INTEGER NOT NULL DEFAULT 1,
                status       TEXT NOT NULL,
                created_at   REAL NOT NULL,
                updated_at   REAL NOT NULL
            )
        """)
        exec(db, """
            CREATE TABLE IF NOT EXISTS injections (
                id             TEXT PRIMARY KEY,
                run_id         TEXT,
                session_id     TEXT,
                lesson_id      TEXT NOT NULL,
                injected_at    REAL NOT NULL,
                token_cost     INTEGER NOT NULL DEFAULT 0,
                mode           TEXT NOT NULL,
                outcome_linked TEXT
            )
        """)
        exec(db, "CREATE INDEX IF NOT EXISTS idx_actions_run ON actions(run_id, seq)")
        exec(db, "CREATE INDEX IF NOT EXISTS idx_actions_created ON actions(created_at DESC)")
        exec(db, "CREATE INDEX IF NOT EXISTS idx_runs_started ON runs(started_at DESC)")
        exec(db, "CREATE INDEX IF NOT EXISTS idx_lessons_status ON lessons(status, inject_priority DESC)")
        exec(db, "CREATE INDEX IF NOT EXISTS idx_lessons_sig ON lessons(task_signature)")
        exec(db, "CREATE INDEX IF NOT EXISTS idx_injections_at ON injections(injected_at DESC)")
    }

    // MARK: Low-level helpers

    private func exec(_ sql: String) {
        Self.exec(db, sql)
    }

    private static func exec(_ db: OpaquePointer?, _ sql: String) {
        guard db != nil else { return }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "?"
            evoLogger.error("[Evolution][DB] exec failed: \(msg) | \(sql.prefix(120))")
            sqlite3_free(err)
        }
    }

    /// Prepare + bind + step one statement. Bind closures use `bindText` /
    /// `bindDouble` / `bindInt` helpers below.
    private func write(_ sql: String, bind: (OpaquePointer?) -> Void) {
        guard db != nil else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            evoLogger.error("[Evolution][DB] prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        bind(stmt)
        if sqlite3_step(stmt) != SQLITE_DONE {
            evoLogger.error("[Evolution][DB] step failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_finalize(stmt)
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, EVO_SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindDouble(_ stmt: OpaquePointer?, _ index: Int32, _ value: Double?) {
        if let value {
            sqlite3_bind_double(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindInt(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int?) {
        if let value {
            sqlite3_bind_int64(stmt, index, Int64(value))
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    // MARK: Inserts

    func insert(_ run: EvolutionRun) {
        let sql = """
            INSERT OR REPLACE INTO runs
              (id, session_id, persona_id, task_signature, started_at, ended_at,
               status, turn_count, tool_call_count, retry_count, tokens_est, model_id, source)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        write(sql) { st in
            bindText(st, 1, run.id)
            bindText(st, 2, run.sessionId)
            bindText(st, 3, run.personaId)
            bindText(st, 4, run.taskSignature)
            bindDouble(st, 5, run.startedAt.timeIntervalSince1970)
            bindDouble(st, 6, run.endedAt?.timeIntervalSince1970)
            bindText(st, 7, run.status.rawValue)
            bindInt(st, 8, run.turnCount)
            bindInt(st, 9, run.toolCallCount)
            bindInt(st, 10, run.retryCount)
            bindInt(st, 11, run.tokensEst)
            bindText(st, 12, run.modelId)
            bindText(st, 13, run.source)
        }
    }

    func insert(_ action: EvolutionAction, createdAt: Date = Date()) {
        let sql = """
            INSERT OR REPLACE INTO actions
              (id, run_id, seq, tool_name, profile, status, error_class,
               error_digest, duration_ms, retry_count, result_digest, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        write(sql) { st in
            bindText(st, 1, action.id)
            bindText(st, 2, action.runId)
            bindInt(st, 3, action.seq)
            bindText(st, 4, action.toolName)
            bindText(st, 5, action.profile)
            bindText(st, 6, action.status.rawValue)
            bindText(st, 7, action.errorClass)
            bindText(st, 8, action.errorDigest)
            bindInt(st, 9, action.durationMs)
            bindInt(st, 10, action.retryCount)
            bindText(st, 11, action.resultDigest)
            bindDouble(st, 12, createdAt.timeIntervalSince1970)
        }
    }

    func insert(_ lesson: EvolutionLesson, now: Date = Date()) {
        let sql = """
            INSERT INTO lessons
              (id, scope, persona_id, task_signature, conditions, recommendation,
               anti_pattern, evidence_actions, status, success_count, failure_count,
               version, parent_id, last_verified_at, inject_priority, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              scope = excluded.scope,
              persona_id = excluded.persona_id,
              task_signature = excluded.task_signature,
              conditions = excluded.conditions,
              recommendation = excluded.recommendation,
              anti_pattern = excluded.anti_pattern,
              evidence_actions = excluded.evidence_actions,
              status = excluded.status,
              success_count = excluded.success_count,
              failure_count = excluded.failure_count,
              version = excluded.version,
              parent_id = excluded.parent_id,
              last_verified_at = excluded.last_verified_at,
              inject_priority = excluded.inject_priority,
              updated_at = excluded.updated_at
              -- created_at 故意不进更新集：首创时间保真（P6-4）
        """
        write(sql) { st in
            bindText(st, 1, lesson.id)
            bindText(st, 2, lesson.scope)
            bindText(st, 3, lesson.personaId)
            bindText(st, 4, lesson.taskSignature)
            bindText(st, 5, lesson.conditions)
            bindText(st, 6, lesson.recommendation)
            bindText(st, 7, lesson.antiPattern)
            bindText(st, 8, lesson.evidenceActions)
            bindText(st, 9, lesson.status.rawValue)
            bindInt(st, 10, lesson.successCount)
            bindInt(st, 11, lesson.failureCount)
            bindInt(st, 12, lesson.version)
            bindText(st, 13, lesson.parentId)
            bindDouble(st, 14, lesson.lastVerifiedAt?.timeIntervalSince1970)
            bindInt(st, 15, lesson.injectPriority)
            bindDouble(st, 16, now.timeIntervalSince1970)
            bindDouble(st, 17, now.timeIntervalSince1970)
        }
    }

    func insert(_ skill: EvolutionSkill, now: Date = Date()) {
        let sql = """
            INSERT OR REPLACE INTO skills
              (id, name, description, params_json, deps, permissions, impl_ref,
               test_status, invocations, success_rate, version, status, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        write(sql) { st in
            bindText(st, 1, skill.id)
            bindText(st, 2, skill.name)
            bindText(st, 3, skill.description)
            bindText(st, 4, skill.paramsJSON)
            bindText(st, 5, skill.deps)
            bindText(st, 6, skill.permissions)
            bindText(st, 7, skill.implRef)
            bindText(st, 8, skill.testStatus)
            bindInt(st, 9, skill.invocations)
            bindDouble(st, 10, skill.successRate)
            bindInt(st, 11, skill.version)
            bindText(st, 12, skill.status.rawValue)
            bindDouble(st, 13, now.timeIntervalSince1970)
            bindDouble(st, 14, now.timeIntervalSince1970)
        }
    }

    func insert(_ injection: EvolutionInjection) {
        let sql = """
            INSERT OR REPLACE INTO injections
              (id, run_id, session_id, lesson_id, injected_at, token_cost, mode, outcome_linked)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """
        write(sql) { st in
            bindText(st, 1, injection.id)
            bindText(st, 2, injection.runId)
            bindText(st, 3, injection.sessionId)
            bindText(st, 4, injection.lessonId)
            bindDouble(st, 5, injection.injectedAt.timeIntervalSince1970)
            bindInt(st, 6, injection.tokenCost)
            bindText(st, 7, injection.mode)
            bindText(st, 8, injection.outcomeLinked)
        }
    }

    // MARK: Queries (basic set for S2-1; richer retrieval lands in S3)

    func recentRuns(limit: Int = 50) -> [EvolutionRun] {
        guard db != nil else { return [] }
        let sql = "SELECT id, session_id, persona_id, task_signature, started_at, ended_at, status, turn_count, tool_call_count, retry_count, tokens_est, model_id, source FROM runs ORDER BY started_at DESC LIMIT ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(limit))
        var out: [EvolutionRun] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let statusRaw = columnText(stmt, 6) ?? "error"
            let run = EvolutionRun(
                id: columnText(stmt, 0) ?? "",
                sessionId: columnText(stmt, 1),
                personaId: columnText(stmt, 2),
                taskSignature: columnText(stmt, 3),
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                endedAt: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil
                    : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                status: EvolutionRunStatus(rawValue: statusRaw) ?? .error,
                turnCount: Int(sqlite3_column_int64(stmt, 7)),
                toolCallCount: Int(sqlite3_column_int64(stmt, 8)),
                retryCount: Int(sqlite3_column_int64(stmt, 9)),
                tokensEst: Int(sqlite3_column_int64(stmt, 10)),
                modelId: columnText(stmt, 11),
                source: columnText(stmt, 12) ?? "chat"
            )
            out.append(run)
        }
        return out
    }

    func actions(forRun runId: String) -> [EvolutionAction] {
        guard db != nil else { return [] }
        let sql = "SELECT id, run_id, seq, tool_name, profile, status, error_class, error_digest, duration_ms, retry_count, result_digest FROM actions WHERE run_id = ? ORDER BY seq ASC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (runId as NSString).utf8String, -1, EVO_SQLITE_TRANSIENT)
        var out: [EvolutionAction] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let statusRaw = columnText(stmt, 5) ?? "fail"
            let action = EvolutionAction(
                id: columnText(stmt, 0) ?? "",
                runId: columnText(stmt, 1) ?? "",
                seq: Int(sqlite3_column_int64(stmt, 2)),
                toolName: columnText(stmt, 3) ?? "",
                profile: columnText(stmt, 4) ?? "",
                status: EvolutionActionStatus(rawValue: statusRaw) ?? .fail,
                errorClass: columnText(stmt, 6),
                errorDigest: columnText(stmt, 7),
                durationMs: Int(sqlite3_column_int64(stmt, 8)),
                retryCount: Int(sqlite3_column_int64(stmt, 9)),
                resultDigest: columnText(stmt, 10)
            )
            out.append(action)
        }
        return out
    }

    func lessons(status: EvolutionLessonStatus) -> [EvolutionLesson] {
        guard db != nil else { return [] }
        let sql = "SELECT id, scope, persona_id, task_signature, conditions, recommendation, anti_pattern, evidence_actions, status, success_count, failure_count, version, parent_id, last_verified_at, inject_priority FROM lessons WHERE status = ? ORDER BY inject_priority DESC, updated_at DESC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (status.rawValue as NSString).utf8String, -1, EVO_SQLITE_TRANSIENT)
        var out: [EvolutionLesson] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let lesson = EvolutionLesson(
                id: columnText(stmt, 0) ?? "",
                scope: columnText(stmt, 1) ?? "global",
                personaId: columnText(stmt, 2),
                taskSignature: columnText(stmt, 3),
                conditions: columnText(stmt, 4) ?? "",
                recommendation: columnText(stmt, 5) ?? "",
                antiPattern: columnText(stmt, 6),
                evidenceActions: columnText(stmt, 7) ?? "[]",
                status: EvolutionLessonStatus(rawValue: columnText(stmt, 8) ?? "candidate") ?? .candidate,
                successCount: Int(sqlite3_column_int64(stmt, 9)),
                failureCount: Int(sqlite3_column_int64(stmt, 10)),
                version: Int(sqlite3_column_int64(stmt, 11)),
                parentId: columnText(stmt, 12),
                lastVerifiedAt: sqlite3_column_type(stmt, 13) == SQLITE_NULL ? nil
                    : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 13)),
                injectPriority: Int(sqlite3_column_int64(stmt, 14))
            )
            out.append(lesson)
        }
        return out
    }

    /// Row counts per table — the evolution-center overview reads this.
    func counts() -> [String: Int] {
        guard db != nil else { return [:] }
        let sql = "SELECT (SELECT COUNT(*) FROM runs), (SELECT COUNT(*) FROM actions), (SELECT COUNT(*) FROM lessons), (SELECT COUNT(*) FROM skills), (SELECT COUNT(*) FROM injections)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return [:] }
        return [
            "runs": Int(sqlite3_column_int64(stmt, 0)),
            "actions": Int(sqlite3_column_int64(stmt, 1)),
            "lessons": Int(sqlite3_column_int64(stmt, 2)),
            "skills": Int(sqlite3_column_int64(stmt, 3)),
            "injections": Int(sqlite3_column_int64(stmt, 4)),
        ]
    }

    /// OPT-2: the actual-injection ledger — what was really used, when, in
    /// which session and mode (shadow rows carry a nil session_id). Newest
    /// first; the evolution center renders this as the "实际注入记账" view.
    func recentInjections(limit: Int = 200) -> [EvolutionInjection] {
        guard db != nil, limit > 0 else { return [] }
        let sql = "SELECT id, run_id, session_id, lesson_id, injected_at, token_cost, mode, outcome_linked FROM injections ORDER BY injected_at DESC LIMIT ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(limit))
        var out: [EvolutionInjection] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let modeRaw = columnText(stmt, 6) ?? "shadow"
            out.append(EvolutionInjection(
                id: columnText(stmt, 0) ?? "",
                runId: columnText(stmt, 1),
                sessionId: columnText(stmt, 2),
                lessonId: columnText(stmt, 3) ?? "",
                injectedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                tokenCost: Int(sqlite3_column_int64(stmt, 5)),
                mode: modeRaw,
                outcomeLinked: columnText(stmt, 7)
            ))
        }
        return out
    }

    // MARK: S3-1 reads (extractor inputs)

    /// Chronologically-latest actions across all runs — the extractor window.
    func recentActions(limit: Int = 5000) -> [EvolutionAction] {
        guard db != nil, limit > 0 else { return [] }
        let sql = "SELECT id, run_id, seq, tool_name, profile, status, error_class, error_digest, duration_ms, retry_count, result_digest FROM actions ORDER BY created_at DESC, rowid DESC LIMIT ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(limit))
        var out: [EvolutionAction] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let statusRaw = columnText(stmt, 5) ?? "fail"
            out.append(EvolutionAction(
                id: columnText(stmt, 0) ?? "",
                runId: columnText(stmt, 1) ?? "",
                seq: Int(sqlite3_column_int64(stmt, 2)),
                toolName: columnText(stmt, 3) ?? "",
                profile: columnText(stmt, 4) ?? "",
                status: EvolutionActionStatus(rawValue: statusRaw) ?? .fail,
                errorClass: columnText(stmt, 6),
                errorDigest: columnText(stmt, 7),
                durationMs: Int(sqlite3_column_int64(stmt, 8)),
                retryCount: Int(sqlite3_column_int64(stmt, 9)),
                resultDigest: columnText(stmt, 10)
            ))
        }
        return out
    }

    /// OPT-1: the "active tool set" for relevance filtering — distinct tool
    /// names the given session actually used recently (zero new
    /// instrumentation: a plain read of the actions ledger). Without a
    /// session, the whole recent window stands in. Empty result is legal
    /// (cold start) — callers treat it as "no tools in play", not an error.
    func recentToolNames(sessionId: String?, limit: Int = 40) -> Set<String> {
        guard db != nil, limit > 0 else { return [] }
        let sql: String
        if let sessionId, !sessionId.isEmpty {
            sql = "SELECT tool_name FROM actions WHERE run_id IN (SELECT id FROM runs WHERE session_id = ?) ORDER BY created_at DESC LIMIT ?"
        } else {
            sql = "SELECT tool_name FROM actions ORDER BY created_at DESC LIMIT ?"
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        if let sessionId, !sessionId.isEmpty {
            sqlite3_bind_text(stmt, 1, (sessionId as NSString).utf8String, -1, EVO_SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, Int64(limit))
        } else {
            sqlite3_bind_int64(stmt, 1, Int64(limit))
        }
        var out: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = columnText(stmt, 0), !name.isEmpty {
                out.insert(name)
            }
        }
        return out
    }

    /// id → (status, version): extraction protection — user-owned lesson
    /// decisions (verified/deprecated) are never clobbered by a pass.
    func lessonStateMap() -> [String: (status: String, version: Int)] {
        guard db != nil else { return [:] }
        let sql = "SELECT id, status, version FROM lessons"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var out: [String: (status: String, version: Int)] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = columnText(stmt, 0) else { continue }
            out[id] = (status: columnText(stmt, 1) ?? "candidate",
                       version: Int(sqlite3_column_int64(stmt, 2)))
        }
        return out
    }

    // MARK: S6-2 lesson administration

    /// Human decision on one lesson (通过 / 弃用 / 回到候选 / 裁决冲突).
    /// Lifecycle is append-only (§6): the status pointer moves and version
    /// increments — nothing is ever deleted. Returns false when the id is
    /// unknown (and true when the row changed).
    @discardableResult
    func updateLessonStatus(id: String, status: EvolutionLessonStatus) -> Bool {
        guard db != nil else { return false }
        let sql = "UPDATE lessons SET status = ?, version = version + 1, updated_at = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, status.rawValue)
        bindDouble(stmt, 2, Date().timeIntervalSince1970)
        bindText(stmt, 3, id)
        sqlite3_step(stmt)
        return sqlite3_changes(db) > 0
    }

    // MARK: Maintenance

    /// Bounded growth: TTL first, then row caps (most-recent kept). [audit-D4]
    /// Surfaced as the evolution center's「立即维护」entry — the S3 maintenance
    /// job this comment used to reference was never built, so before that
    /// entry existed this was dead code. Never per insert (unlike the
    /// 1000-row config audit, these tables are hot).
    func prune(maxActionRows: Int = Limits.maxActionRows,
               maxRunRows: Int = Limits.maxRunRows,
               maxInjectionRows: Int = Limits.maxInjectionRows,
               ttlDays: Int = Limits.ttlDays) {
        let cutoff = Date().addingTimeInterval(-Double(ttlDays) * 86_400).timeIntervalSince1970
        exec("DELETE FROM actions WHERE created_at < \(cutoff)")
        exec("DELETE FROM runs WHERE started_at < \(cutoff)")
        exec("DELETE FROM injections WHERE injected_at < \(cutoff)")
        exec("DELETE FROM actions WHERE id NOT IN (SELECT id FROM actions ORDER BY created_at DESC LIMIT \(maxActionRows))")
        exec("DELETE FROM runs WHERE id NOT IN (SELECT id FROM runs ORDER BY started_at DESC LIMIT \(maxRunRows))")
        exec("DELETE FROM injections WHERE id NOT IN (SELECT id FROM injections ORDER BY injected_at DESC LIMIT \(maxInjectionRows))")
    }

    /// Wipe every evolution data table. Surfaced via the evolution center as a
    /// manual action (same posture as ConfigAuditLog.clearAll: never callable
    /// through agent tools).
    func clearAll() {
        exec("DELETE FROM actions")
        exec("DELETE FROM runs")
        exec("DELETE FROM lessons")
        exec("DELETE FROM skills")
        exec("DELETE FROM injections")
        evoLogger.info("[Evolution][DB] cleared by user")
    }

    /// Fold the WAL back into the main file (see ConfigAuditLog.checkpoint for
    /// the incident that motivates this). Wiring into the backup/checkpoint
    /// flow is deferred to a later step.
    func checkpoint() {
        exec("PRAGMA wal_checkpoint(TRUNCATE)")
    }
}

// MARK: - [S2-1][evolution] Settings (UserDefaults-backed)

/// Switches, mirroring VoiceCorrectionCollectionConsent: `nonisolated` static
/// reads for background writers, `@MainActor` observable instance for UI.
///
/// Defaults (per 醒醒's ruling, 2026-10-14): recording ON (shadow behavior),
/// mode `.shadow` (retrieve + log what WOULD be injected; inject nothing),
/// budget 400 tokens. Nothing in the app reads these yet — S2-2 wires the
/// recording hooks, S3 the injector.
@MainActor
final class EvolutionSettings: ObservableObject {

    static let shared = EvolutionSettings()

    nonisolated private static let modeKey = "evolution.mode"
    nonisolated private static let recordingKey = "evolution.recordingEnabled"
    nonisolated private static let budgetKey = "evolution.injectionBudgetTokens"

    /// off / shadow / active.
    @Published var mode: EvolutionMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            // OPT-3: a mode switch must take effect on the very next turn —
            // drop the injector's cached fragment/lessons so the next refresh
            // re-reads everything under the new mode (off drops to "", shadow
            // stops injecting, active starts).
            EvolutionInjector.shared.invalidate()
        }
    }

    /// Master switch for the recording hooks (S2-2). Off = nothing is written.
    @Published var isRecordingEnabled: Bool {
        didSet { UserDefaults.standard.set(isRecordingEnabled, forKey: Self.recordingKey) }
    }

    /// Token budget for the injector fragment (S3).
    @Published var injectionBudgetTokens: Int {
        didSet { UserDefaults.standard.set(injectionBudgetTokens, forKey: Self.budgetKey) }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.modeKey)
        mode = raw.flatMap(EvolutionMode.init(rawValue:)) ?? .shadow
        isRecordingEnabled = UserDefaults.standard.object(forKey: Self.recordingKey) as? Bool ?? true
        let budget = UserDefaults.standard.object(forKey: Self.budgetKey) as? Int
        // [audit-D5] 0 used to be both "unset" and "no budget" — clamp to the
        // real UI range; true OFF is the mode switch, not a zero budget.
        injectionBudgetTokens = min(800, max(50, budget ?? 400))
    }

    // MARK: Thread-safe reads for background writers (UserDefaults is itself thread-safe)

    nonisolated static var recordingEnabled: Bool {
        UserDefaults.standard.object(forKey: recordingKey) as? Bool ?? true
    }

    nonisolated static var currentMode: EvolutionMode {
        let raw = UserDefaults.standard.string(forKey: modeKey)
        return raw.flatMap(EvolutionMode.init(rawValue:)) ?? .shadow
    }

    nonisolated static var budgetTokens: Int {
        // [audit-D5] Same clamp on the background-read side, so a legacy 0
        // stored value cannot zero out the injector fragment.
        min(800, max(50, (UserDefaults.standard.object(forKey: budgetKey) as? Int) ?? 400))
    }
}
