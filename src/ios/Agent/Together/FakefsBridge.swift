//
//  FakefsBridge.swift
//  MinisApp
//
//  往 iSH 的 fakefs 里写东西，光写完文件不够：还得在 alpine-rootfs/meta.db
//  的 paths/stats 里登记一条，否则 Linux 侧看不见这个文件。
//  （SkillStore 里的 ensureFakefsMetadata 干的是同一件事，这里提出来公用。）
//
//  读取不需要登记——iSH 写的东西走 POSIX 就能读到，问题只会出在路径算错。
//

import Foundation
import SQLite3

enum FakefsBridge {

    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static var documentsPath: String {
        NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
            ?? NSHomeDirectory()
    }

    /// fakefs 的数据根：Documents/alpine-rootfs/data
    static var dataRootPath: String {
        (documentsPath as NSString).appendingPathComponent("alpine-rootfs/data")
    }

    static var metaDBPath: String {
        (documentsPath as NSString).appendingPathComponent("alpine-rootfs/meta.db")
    }

    /// `/var/minis/shared/x` → `<Documents>/alpine-rootfs/data/var/minis/shared/x`
    static func hostURL(forLinuxPath linuxPath: String) -> URL {
        var relative = linuxPath
        while relative.hasPrefix("/") { relative = String(relative.dropFirst()) }
        return URL(fileURLWithPath: (dataRootPath as NSString).appendingPathComponent(relative))
    }

    // MARK: meta.db 登记

    static func register(linuxPath: String, isDirectory: Bool) {
        guard FileManager.default.fileExists(atPath: metaDBPath) else { return }
        var db: OpaquePointer?
        guard sqlite3_open_v2(metaDBPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db else { return }
        defer { sqlite3_close(db) }
        register(linuxPath: linuxPath, isDirectory: isDirectory, db: db)
    }

    private static func register(linuxPath: String, isDirectory: Bool, db: OpaquePointer) {
        var check: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT inode FROM paths WHERE path = ?", -1, &check, nil) == SQLITE_OK,
              let check else { return }
        defer { sqlite3_finalize(check) }
        sqlite3_bind_blob(check, 1, Array(linuxPath.utf8), Int32(linuxPath.utf8.count), transientDestructor)
        if sqlite3_step(check) == SQLITE_ROW { return }

        let mode: UInt32 = isDirectory ? 0o040755 : 0o100644
        var statBytes = [UInt8](repeating: 0, count: 16)
        let leMode = mode.littleEndian
        withUnsafeBytes(of: leMode) { src in
            for i in 0..<4 { statBytes[i] = src[i] }
        }

        var insertStat: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO stats (stat) VALUES (?)", -1, &insertStat, nil) == SQLITE_OK,
              let insertStat else { return }
        defer { sqlite3_finalize(insertStat) }
        sqlite3_bind_blob(insertStat, 1, statBytes, Int32(statBytes.count), transientDestructor)
        guard sqlite3_step(insertStat) == SQLITE_DONE else { return }

        var insertPath: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO paths (path, inode) VALUES (?, last_insert_rowid())",
                                 -1, &insertPath, nil) == SQLITE_OK,
              let insertPath else { return }
        defer { sqlite3_finalize(insertPath) }
        sqlite3_bind_blob(insertPath, 1, Array(linuxPath.utf8), Int32(linuxPath.utf8.count), transientDestructor)
        sqlite3_step(insertPath)
    }

    /// 把某一级以上的父目录全登记上，否则文件建了但父目录在 Linux 侧不存在。
    static func registerParents(of linuxPath: String) {
        guard FileManager.default.fileExists(atPath: metaDBPath) else { return }
        var db: OpaquePointer?
        guard sqlite3_open_v2(metaDBPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db else { return }
        defer { sqlite3_close(db) }

        var current = (linuxPath as NSString).deletingLastPathComponent
        var dirs: [String] = []
        while current != "/" && !current.isEmpty {
            dirs.append(current)
            current = (current as NSString).deletingLastPathComponent
        }
        for dir in dirs.reversed() {
            register(linuxPath: dir, isDirectory: true, db: db)
        }
    }

    // MARK: 一步写完

    /// 写到 fakefs 并登记。`linuxPath` 是 Linux 侧看到的绝对路径。
    @discardableResult
    static func write(_ data: Data, toLinuxPath linuxPath: String) -> Bool {
        let url = hostURL(forLinuxPath: linuxPath)
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return false
        }
        registerParents(of: linuxPath)
        register(linuxPath: linuxPath, isDirectory: false)
        return true
    }
}