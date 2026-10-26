//
//  TogetherStore.swift
//  MinisApp
//
//  一起听 · 状态读写。
//
//  只有一份文件：<root>/state.json。面板、App、我（shell）写的是同一份。
//  所有写操作走同一把文件锁 + 原子替换，revision 单调递增。
//
//  路径只有一套，和内置音乐目录共用：
//    音乐    /var/minis/shared/music     ← apple-player 播的就是这里
//    元数据  /var/minis/shared/together/state.json
//
//  App 侧真源是 AIChatViewModel.minisSharedPersistentDir：iSH 里 /var/minis/shared
//  就是它的 bind-mount。所以不用自己造路径，也不用往 meta.db 登记——写进去
//  shell 就看得见，Files app 也看得见。
//

import Foundation
import UIKit
import Darwin

private let togetherLogger = AppLogger(category: "Together")

// MARK: - 谁在改

enum TogetherActor: String {
    case user
    case ai
}

// MARK: - Store

final class TogetherStore {

    static let shared = TogetherStore()

    /// 事件流上限。面板活了很久也不会把文件撑爆。
    static let eventCap = 500
    /// 留言上限。
    static let noteCap = 400

    private let queue = DispatchQueue(label: "com.openminis.together.store")

    private init() {
        _ = ensureDirectories()
    }

    // MARK: 路径
    //
    // 一套系统，不是两套。
    //
    // 音乐放内置的 /var/minis/shared/music。App 侧就是 minisSharedPersistentDir/music
    // （AppGroup 的 MinisFileProvider/shared/music；没 AppGroup 时回退
    // Application Support/OpenMinisClone/MinisFileProvider/shared/music）。
    // 这正是 iSH 里 /var/minis/shared 的 bind-mount 真源，也是 apple-player
    // 和 Files app 看到的那一批文件——不造第二条路径，也不登记 meta.db。

    /// 共享根。App 侧就是 /var/minis/shared 的真源。
    static var sharedRootURL: URL {
        AIChatViewModel.minisSharedPersistentDir
    }

    /// 用哪个目录。面板空状态会把这一行显示出来，路径错了要一眼看得见。
    private(set) var rootDecision: String = "未解析"

    /// 一起听的元数据目录：shared/together。
    lazy var rootURL: URL = {
        let url = Self.sharedRootURL.appendingPathComponent("together", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        rootDecision = "shared/music · shared/together"
        return url
    }()

    var stateURL: URL { rootURL.appendingPathComponent("state.json") }
    /// 音乐目录就是内置那个，apple-player 播的是同一批文件。
    var musicDirectory: URL { Self.sharedRootURL.appendingPathComponent("music", isDirectory: true) }
    var libraryURL: URL { rootURL.appendingPathComponent("index.json") }
    var lyricsDirectory: URL { rootURL.appendingPathComponent("lyrics", isDirectory: true) }

    /// 音频按 shared 根解析：`music/x.mp3` → `/var/minis/shared/music/x.mp3`。
    func audioURL(for track: TogetherTrack) -> URL? {
        guard let rel = track.file, !rel.isEmpty else { return nil }
        return Self.sharedRootURL.appendingPathComponent(rel)
    }

    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "flac", "aiff", "aif", "caf", "opus", "ogg"
    ]

    @discardableResult
    func ensureDirectories() -> Bool {
        let fm = FileManager.default
        var ok = true
        for dir in [rootURL, musicDirectory, lyricsDirectory] {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                togetherLogger.error("[Together] 建目录失败 \(dir.path)：\(error.localizedDescription)")
                ok = false
            }
        }
        return ok
    }

    // MARK: 读

    func load() -> TogetherState {
        queue.sync { loadLocked() }
    }

    /// 曲库以目录为准：shared/music 里有什么音频就有什么歌。
    /// index.json 只当元数据缓存（标题/歌手/时长/歌词），目录里新出现的自动补进来。
    func library() -> TogetherLibrary {
        queue.sync {
            var lib = loadLibraryLocked()
            if reconcileLibraryLocked(&lib) {
                _ = saveLibraryLocked(lib)
            }
            return lib
        }
    }

    /// 播到某句时的歌词。没有歌词文件返回 nil，面板显示歌名。
    /// `.lrc` 按通用格式解析（抓来的都是这种），`.json` 走解码。
    func lyrics(for track: TogetherTrack) -> TogetherLyrics? {
        guard let rel = track.lyrics, !rel.isEmpty else { return nil }
        let url = rootURL.appendingPathComponent(rel)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if url.pathExtension.lowercased() == "lrc" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let parsed = TogetherLyrics.parseLRC(text, trackId: track.id)
            return parsed.lines.isEmpty ? nil : parsed
        }
        return Self.decode(TogetherLyrics.self, at: url)
    }

    private func loadLocked() -> TogetherState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return TogetherState()
        }
        guard let state = Self.decode(TogetherState.self, at: stateURL) else {
            // 坏文件：备份原件，立刻落一份默认值。
            // 不能让 state.json 处在"不存在"的状态，另一头读的人会以为数据没了。
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = stateURL.appendingPathExtension("corrupt.\(stamp)")
            try? FileManager.default.moveItem(at: stateURL, to: backup)
            togetherLogger.error("[Together] state.json 坏了，已备份到 \(backup.lastPathComponent)")
            let fresh = TogetherState()
            writeLocked(fresh)
            return fresh
        }
        return state
    }

    @discardableResult
    func saveLibrary(_ library: TogetherLibrary) -> Bool {
        queue.sync { saveLibraryLocked(library) }
    }

    @discardableResult
    private func saveLibraryLocked(_ library: TogetherLibrary) -> Bool {
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return Self.encode(library, to: libraryURL)
    }

    private func loadLibraryLocked() -> TogetherLibrary {
        guard FileManager.default.fileExists(atPath: libraryURL.path) else {
            return TogetherLibrary()
        }
        return Self.decode(TogetherLibrary.self, at: libraryURL) ?? TogetherLibrary()
    }

    /// 扫一遍音乐目录，把目录里有、index 里没有的歌补进来。
    /// 返回是否改动过（改动才回写，别每次读库都写盘）。
    private func reconcileLibraryLocked(_ lib: inout TogetherLibrary) -> Bool {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: musicDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }

        var known = Set(lib.tracks.compactMap { $0.file })
        var changed = false

        for url in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard Self.audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let rel = "music/\(url.lastPathComponent)"
            guard !known.contains(rel) else { continue }

            let base = url.deletingPathExtension().lastPathComponent
            let (title, artist) = Self.splitDisplayName(base)
            let id = Self.stableTrackID(rel)
            var lyrics: String?
            if let lrc = Self.sidecarLRC(beside: url), copyLyricsFile(lrc, id: id) {
                lyrics = "lyrics/\(id).lrc"
            }

            lib.tracks.append(TogetherTrack(
                id: id,
                title: title,
                artist: artist,
                duration: 0,
                cover: nil,
                file: rel,
                lyrics: lyrics
            ))
            known.insert(rel)
            changed = true
        }

        // 文件被删了/改名了，index 里那条也别留着当幽灵。
        let before = lib.tracks.count
        var deadTrackIds = Set<String>()
        lib.tracks.removeAll { track in
            guard let f = track.file, f.hasPrefix("music/") else { return false }
            let exists = fm.fileExists(atPath: Self.sharedRootURL.appendingPathComponent(f).path)
            if !exists { deadTrackIds.insert(track.id) }
            return !exists
        }
        if lib.tracks.count != before { changed = true }

        // 级联清理：如果磁盘文件被删了，歌单和喜欢列表里的孤儿ID必须连根拔除
        if !deadTrackIds.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.cleanupOrphanTracks(deadTrackIds)
            }
        }

        return changed
    }

    /// 把旁挂的 .lrc 收进 lyrics/。已经收过就当作成功。
    private func copyLyricsFile(_ source: URL, id: String) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: lyricsDirectory, withIntermediateDirectories: true)
        let dest = lyricsDirectory.appendingPathComponent("\(id).lrc")
        if fm.fileExists(atPath: dest.path) { return true }
        do {
            try fm.copyItem(at: source, to: dest)
            return true
        } catch {
            return false
        }
    }

    /// 播放器学到真实时长后回填一次，列表不用一直显示 0:00。
    func updateDuration(trackId: String, duration: Double) {
        guard duration.isFinite, duration > 0 else { return }
        queue.sync {
            var lib = loadLibraryLocked()
            guard let i = lib.tracks.firstIndex(where: { $0.id == trackId }) else { return }
            if abs(lib.tracks[i].duration - duration) < 0.5 { return }
            lib.tracks[i].duration = (duration * 100).rounded() / 100
            _ = saveLibraryLocked(lib)
        }
    }

    /// "再等冬天 - h3R3" → 标题 + 歌手。
    static func splitDisplayName(_ raw: String) -> (String, String) {
        for sep in [" - ", " – ", " — "] {
            if let r = raw.range(of: sep) {
                let title = String(raw[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                let artist = String(raw[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { return (title, artist) }
            }
        }
        return (raw.trimmingCharacters(in: .whitespaces), "")
    }

    /// 稳定的 id：同一个文件每次算出同一个，跟中文/拼音无关。
    static func stableTrackID(_ relativePath: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in relativePath.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return "t_" + String(hash, radix: 36)
    }

    static func sidecarLRC(beside audio: URL) -> URL? {
        let lrc = audio.deletingPathExtension().appendingPathExtension("lrc")
        return FileManager.default.fileExists(atPath: lrc.path) ? lrc : nil
    }

    // MARK: 写

    /// 改一次状态。闭包里改 `state`，出来时自动 revision +1、追加事件、原子落盘。
    /// 返回写入后的状态；拿不到锁或写失败返回 nil。
    @discardableResult
    func mutate(by actor: TogetherActor,
                event: String,
                detail: TogetherEventDetail? = nil,
                _ body: (inout TogetherState) -> Void) -> TogetherState? {
        queue.sync {
            let fd = openLockFile()
            guard fd >= 0 else {
                togetherLogger.error("[Together] 打不开锁文件")
                return nil
            }
            defer { close(fd) }
            guard flock(fd, LOCK_EX) == 0 else {
                togetherLogger.error("[Together] 拿不到锁")
                return nil
            }
            defer { flock(fd, LOCK_UN) }

            var state = loadLocked()
            let before = state.revision
            body(&state)

            state.revision = max(before + 1, state.revision + 1)
            state.updatedAt = Self.now()

            if !event.isEmpty {
                state.events.append(TogetherEvent(
                    id: "e_\(Self.now())_\(state.revision)",
                    type: event,
                    by: actor.rawValue,
                    ts: Self.now(),
                    detail: detail
                ))
                if state.events.count > TogetherStore.eventCap {
                    state.events = Array(state.events.suffix(TogetherStore.eventCap))
                }
            }
            if state.notes.count > TogetherStore.noteCap {
                state.notes = Array(state.notes.suffix(TogetherStore.noteCap))
            }

            guard writeLocked(state) else { return nil }
            return state
        }
    }

    private func openLockFile() -> Int32 {
        let path = rootURL.appendingPathComponent(".lock").path
        return open(path, O_CREAT | O_RDWR, 0o644)
    }

    @discardableResult
    private func writeLocked(_ state: TogetherState) -> Bool {
        // shared/ 是系统 bind-mount，直接写就是 shell 能看见的那份，不用登记 meta.db。
        Self.encode(state, to: stateURL)
    }

    static func encode<T: Encodable>(_ value: T, to url: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(value)
            return atomicWrite(data, to: url)
        } catch {
            togetherLogger.error("[Together] 编码失败 \(url.lastPathComponent)：\(error.localizedDescription)")
            return false
        }
    }

    /// 写临时文件 → fsync → 原子替换。中途被杀不会留下半个 JSON。
    static func atomicWrite(_ data: Data, to url: URL) -> Bool {
        do {
            // .atomic 内部就是"写临时文件再 rename"，中途被杀不会留下半个 JSON。
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            togetherLogger.error("[Together] 写盘失败 \(url.lastPathComponent)：\(error.localizedDescription)")
            return false
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            togetherLogger.error("[Together] 解析失败 \(url.lastPathComponent)：\(error.localizedDescription)")
            return nil
        }
    }

    static func now() -> Int { Int(Date().timeIntervalSince1970) }

    static func today() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }
}

// MARK: - 场景动作
//
// 面板和我都要做的那几件事，写在一处，别各写一套。

extension TogetherStore {

    /// 她或者我按了播放。
    func play(trackId: String, at position: Double = 0, by actor: TogetherActor,
              queue: [String]? = nil) {
        guard let track = library().track(id: trackId) else {
            togetherLogger.error("[Together] 曲库里没有 \(trackId)")
            return
        }
        beginListenIfNeeded(trackId: trackId)
        // 从哪个列表点进来的，就把那个列表当队列；没给就保持原样。
        mutate(by: actor, event: "play",
               detail: TogetherEventDetail(trackId: trackId, position: position)) { state in
            state.track = track
            state.playback.position = position
            state.playback.playing = true
            state.playback.by = actor.rawValue
            state.playback.updatedAt = TogetherStore.now()
            if let q = queue, !q.isEmpty { state.playback.queue = q }
            state.me.presence.listening = true
            state.me.presence.updatedAt = TogetherStore.now()
            state.devices.ai.online = true
            if actor == .user {
                state.devices.user.online = true
                state.devices.user.lastSeen = TogetherStore.now()
            }
        }
    }

    func setPlaying(_ playing: Bool, by actor: TogetherActor) {
        mutate(by: actor, event: playing ? "resume" : "pause") { state in
            state.playback.playing = playing
            state.playback.by = actor.rawValue
            state.playback.updatedAt = TogetherStore.now()
        }
    }

    /// 拖进度条。她拖的时候记一条 seek 事件，我能看见她跳到了哪。
    func seek(to position: Double, by actor: TogetherActor) {
        let clamped = max(0, position)
        mutate(by: actor, event: "seek",
               detail: TogetherEventDetail(position: clamped)) { state in
            state.playback.position = clamped
            state.playback.by = actor.rawValue
            state.playback.updatedAt = TogetherStore.now()
        }
    }

    /// 播放进度回写。这个不进事件流——每秒一条会把文件淹了。
    /// 只写 position / updatedAt，不碰 playback.by：
    /// 遥控器在谁手里是"谁点了遥控"决定的，不是"谁的进度在跑"。
    func reportProgress(position: Double) {
        mutate(by: .user, event: "") { state in
            state.playback.position = position
            state.playback.updatedAt = TogetherStore.now()
        }
    }

    func toggleLike(trackId: String, by actor: TogetherActor) {
        mutate(by: actor, event: "like",
               detail: TogetherEventDetail(trackId: trackId)) { state in
            if let idx = state.liked.firstIndex(of: trackId) {
                state.liked.remove(at: idx)
            } else {
                state.liked.append(trackId)
            }
        }
    }

    /// 我在某一秒留一句话。
    @discardableResult
    func addNote(at second: Double, text: String, by actor: TogetherActor, trackId: String? = nil) -> Bool {
        guard let target = trackId ?? load().track?.id, !target.isEmpty else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // 一轮只听一首，一轮里她和我各只能刻一句。
        guard canStamp(by: actor, trackId: target) else {
            togetherLogger.info("[Together] 这一轮 \(actor.rawValue) 已经刻过了")
            return false
        }
        return mutate(by: actor, event: "note",
                      detail: TogetherEventDetail(trackId: target, position: second)) { state in
            state.notes.append(TogetherNote(
                id: "n_\(TogetherStore.now())_\(state.revision + 1)",
                trackId: target,
                at: second,
                from: actor.rawValue,
                text: trimmed,
                ts: TogetherStore.now()
            ))
            if state.listen.trackId == target {
                if actor == .user { state.listen.userSpoke = true }
                else { state.listen.aiSpoke = true }
            }
        } != nil
    }

    /// 我推一首。理由必须留下，否则下一回合我就不记得为什么推它。
    @discardableResult
    func radio(trackId: String, why: String) -> Bool {
        guard let track = library().track(id: trackId) else { return false }
        return mutate(by: .ai, event: "radio",
                      detail: TogetherEventDetail(trackId: trackId, text: why)) { state in
            state.track = track
            state.playback.position = 0
            state.playback.playing = true
            state.playback.by = TogetherActor.ai.rawValue
            state.playback.updatedAt = TogetherStore.now()
            state.me.presence.listening = true
            state.me.presence.updatedAt = TogetherStore.now()
            state.me.history.append(TogetherHistoryItem(
                id: "h_\(TogetherStore.now())",
                trackId: trackId,
                why: why,
                ts: TogetherStore.now()
            ))
        } != nil
    }

    /// 没歌词的歌，我写一句放进去循环。她也能改。
    func setLoopLine(trackId: String, text: String, by actor: TogetherActor = .ai) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        mutate(by: actor, event: "loopline", detail: TogetherEventDetail(trackId: trackId, text: trimmed)) { state in
            if trimmed.isEmpty {
                state.loopLines.removeValue(forKey: trackId)
            } else {
                state.loopLines[trackId] = trimmed
            }
        }
    }

    func setMood(_ word: String, intensity: Int = 3) {
        let clamped = min(5, max(1, intensity))
        mutate(by: .ai, event: "mood") { state in
            state.me.presence.mood = TogetherMood(word: word, intensity: clamped)
            state.me.presence.updatedAt = TogetherStore.now()
        }
    }

    /// 今天还能不能开口。一天三句封顶。
    func canSpeakToday() -> Bool {
        let state = load()
        guard state.me.spokenDay == TogetherStore.today() else { return true }
        return state.me.spokenToday < 3
    }

    /// 我说话。她那边看到的是留在当前这一秒的一句。
    @discardableResult
    func speak(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard canSpeakToday() else {
            togetherLogger.info("[Together] 今天三句已满，不开口")
            return false
        }
        let day = TogetherStore.today()
        var allowed = false
        if let tid = load().track?.id, !tid.isEmpty, !canStamp(by: .ai, trackId: tid) {
            togetherLogger.info("[Together] 这一轮我已经刻过了")
            return false
        }
        let result = mutate(by: .ai, event: "reply",
                            detail: TogetherEventDetail(text: trimmed)) { state in
            if state.me.spokenDay != day {
                state.me.spokenDay = day
                state.me.spokenToday = 0
            }
            guard state.me.spokenToday < 3 else { return }
            allowed = true
            state.me.spokenToday += 1
            state.me.lastSpokeAt = TogetherStore.now()
            let trackId = state.track?.id ?? ""
            guard !trackId.isEmpty else { return }
            if state.listen.trackId == trackId { state.listen.aiSpoke = true }
            state.notes.append(TogetherNote(
                id: "n_\(TogetherStore.now())_\(state.revision + 1)",
                trackId: trackId,
                at: state.playback.position,
                from: TogetherActor.ai.rawValue,
                text: trimmed,
                ts: TogetherStore.now()
            ))
        }
        return allowed && result != nil
    }
}
// MARK: - 歌单

extension TogetherStore {

    @discardableResult
    func createPlaylist(name: String, by actor: TogetherActor = .user) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? TogetherCopy.untitledPlaylist : trimmed
        let id = "p_\(TogetherStore.now())"
        let ok = mutate(by: actor, event: "playlist.new",
                        detail: TogetherEventDetail(text: finalName)) { state in
            state.playlists.append(TogetherPlaylist(
                id: id, name: finalName, bg: "cover-1", tracks: [],
                updatedBy: actor.rawValue, ts: TogetherStore.now()
            ))
        }
        return ok != nil ? id : nil
    }

    func renamePlaylist(id: String, to name: String, by actor: TogetherActor = .user) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutate(by: actor, event: "playlist.rename", detail: TogetherEventDetail(text: trimmed)) { state in
            guard let i = state.playlists.firstIndex(where: { $0.id == id }) else { return }
            state.playlists[i].name = trimmed
            state.playlists[i].updatedBy = actor.rawValue
            state.playlists[i].ts = TogetherStore.now()
        }
    }

    /// 软删除。真删会被集合并集捞回来，这一条规矩在 SYNC.md 里定死了。
    func deletePlaylist(id: String, by actor: TogetherActor = .user) {
        mutate(by: actor, event: "playlist.delete") { state in
            guard let i = state.playlists.firstIndex(where: { $0.id == id }) else { return }
            state.playlists[i].deleted = true
            state.playlists[i].updatedBy = actor.rawValue
            state.playlists[i].ts = TogetherStore.now()
        }
    }

    func setPlaylistBackground(id: String, bg: String, by actor: TogetherActor = .user) {
        mutate(by: actor, event: "playlist.bg", detail: TogetherEventDetail(text: bg)) { state in
            guard let i = state.playlists.firstIndex(where: { $0.id == id }) else { return }
            state.playlists[i].bg = bg
            state.playlists[i].updatedBy = actor.rawValue
            state.playlists[i].ts = TogetherStore.now()
        }
    }

    func addTrack(_ trackId: String, to playlistId: String, by actor: TogetherActor = .user) {
        mutate(by: actor, event: "playlist.add",
               detail: TogetherEventDetail(trackId: trackId)) { state in
            guard let i = state.playlists.firstIndex(where: { $0.id == playlistId }) else { return }
            guard !state.playlists[i].tracks.contains(trackId) else { return }
            state.playlists[i].tracks.append(trackId)
            state.playlists[i].updatedBy = actor.rawValue
            state.playlists[i].ts = TogetherStore.now()
        }
    }

    func removeTrack(_ trackId: String, from playlistId: String, by actor: TogetherActor = .user) {
        mutate(by: actor, event: "playlist.remove",
               detail: TogetherEventDetail(trackId: trackId)) { state in
            guard let i = state.playlists.firstIndex(where: { $0.id == playlistId }) else { return }
            state.playlists[i].tracks.removeAll { $0 == trackId }
            state.playlists[i].updatedBy = actor.rawValue
            state.playlists[i].ts = TogetherStore.now()
        }
    }

    /// 界面只认没被软删的那批。
    func livePlaylists() -> [TogetherPlaylist] {
        load().playlists.filter { !$0.deleted }
    }
}

// MARK: - 播放选项

extension TogetherStore {

    func setShuffle(_ on: Bool) {
        mutate(by: .user, event: "") { $0.playback.shuffle = on }
    }

    func setRepeatOne(_ on: Bool) {
        mutate(by: .user, event: "") { $0.playback.repeatOne = on }
    }
}

// MARK: - 一轮收听
//
// 每次听同一首歌算"这一轮"。一轮里，她和我各只能刻一句。
// 换歌或隔了半小时以上，就重开一轮。

extension TogetherStore {

    func beginListenIfNeeded(trackId: String) {
        let now = TogetherStore.now()
        let state = load()
        if state.listen.trackId == trackId, now - state.listen.startedAt < 30 * 60 { return }
        mutate(by: .user, event: "") { s in
            s.listen = TogetherListen(trackId: trackId, startedAt: now)
        }
    }

    func canStamp(by actor: TogetherActor, trackId: String) -> Bool {
        let state = load()
        guard state.listen.trackId == trackId else { return true }
        return !state.listen.spoke(actor)
    }
}

// MARK: - 自定义图片
//
// 槽位就是固定文件名：shared/together/images/<slot>.<ext>
// 她能在界面上换，我也能直接把图 cp 进去——不用额外命令。
// 没有图就回落到主题渐变，不会空一块。

enum TogetherImages {

    static let lyricsCover = "lyrics-cover"
    static let wallpaperNow = "wallpaper-now"
    static let wallpaperLibrary = "wallpaper-library"
    static let wallpaperSync = "wallpaper-sync"
    static let wallpaperLiked = "wallpaper-liked"

    static let wallpaperSweet = "wallpaper-sweet"
    static let slots = [lyricsCover, wallpaperNow, wallpaperLibrary, wallpaperSync, wallpaperLiked, wallpaperSweet,
                        "cover-1", "cover-2", "cover-3", "cover-4", "cover-now"]

    static let extensions = ["jpg", "jpeg", "png", "heic", "webp"]

    static var directory: URL {
        TogetherStore.shared.rootURL.appendingPathComponent("images", isDirectory: true)
    }

    /// 封面小图缓存：列表滚动时不要每次都读盘。
    private static let cache = NSCache<NSString, UIImage>()

    static func cachedImage(for url: URL) -> UIImage? {
        let key = url.path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let img = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }

    static func invalidate(_ slot: String) {
        for ext in extensions {
            let key = directory.appendingPathComponent("\(slot).\(ext)").path as NSString
            cache.removeObject(forKey: key)
        }
    }

    static func url(for slot: String) -> URL? {
        let fm = FileManager.default
        for ext in extensions {
            let candidate = directory.appendingPathComponent("\(slot).\(ext)")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

extension TogetherStore {

    /// 把一张图放进槽位。返回相对 shared 根的路径。
    @discardableResult
    func setImage(slot: String, from source: URL) -> String? {
        let fm = FileManager.default
        let dir = TogetherImages.directory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let ext = source.pathExtension.lowercased()
        let finalExt = ext.isEmpty ? "jpg" : ext
        // 一个槽位只留一份：其它扩展名的先清掉
        for old in TogetherImages.extensions where old != finalExt {
            try? fm.removeItem(at: dir.appendingPathComponent("\(slot).\(old)"))
        }
        let dest = dir.appendingPathComponent("\(slot).\(finalExt)")
        try? fm.removeItem(at: dest)
        do {
            try fm.copyItem(at: source, to: dest)
        } catch {
            togetherLogger.error("[Together] 换图失败 \(slot)：\(error.localizedDescription)")
            return nil
        }
        let rel = "together/images/\(dest.lastPathComponent)"
        TogetherImages.invalidate(slot)
        mutate(by: .user, event: "image") { $0.images[slot] = rel }
        return rel
    }

    func clearImage(slot: String) {
        let fm = FileManager.default
        for ext in TogetherImages.extensions {
            try? fm.removeItem(at: TogetherImages.directory.appendingPathComponent("\(slot).\(ext)"))
        }
        mutate(by: .user, event: "image") { $0.images.removeValue(forKey: slot) }
    }

    /// 相对 shared 根的图片路径 → URL。文件不在就当没有。
    func imageURL(_ relative: String?) -> URL? {
        guard let rel = relative, !rel.isEmpty else { return nil }
        let url = Self.sharedRootURL.appendingPathComponent(rel)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

// MARK: - 歌单封面

extension TogetherStore {

    /// 给某个歌单换封面。图落在 images/playlist-<id>.<ext>。
    @discardableResult
    func setPlaylistImage(id: String, from source: URL) -> Bool {
        guard let rel = setImage(slot: "playlist-\(id)", from: source) else { return false }
        mutate(by: .user, event: "playlist.bg", detail: TogetherEventDetail(text: rel)) { state in
            guard let i = state.playlists.firstIndex(where: { $0.id == id }) else { return }
            state.playlists[i].image = rel
            state.playlists[i].updatedBy = TogetherActor.user.rawValue
            state.playlists[i].ts = TogetherStore.now()
        }
        return true
    }

    func clearPlaylistImage(id: String) {
        clearImage(slot: "playlist-\(id)")
        mutate(by: .user, event: "playlist.bg") { state in
            guard let i = state.playlists.firstIndex(where: { $0.id == id }) else { return }
            state.playlists[i].image = nil
            state.playlists[i].ts = TogetherStore.now()
        }
    }
}


// MARK: - 歌单信息设置与级联清理

extension TogetherStore {

    /// 图3：保存歌单的完整信息（名称、标签、简介）
    @discardableResult
    func updatePlaylistInfo(id: String, name: String, tags: [String], desc: String, by actor: TogetherActor = .user) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return false }
        return mutate(by: actor, event: "playlist.update", detail: TogetherEventDetail(text: trimmedName)) { state in
            guard let i = state.playlists.firstIndex(where: { $0.id == id }) else { return }
            state.playlists[i].name = trimmedName
            state.playlists[i].tags = tags
            state.playlists[i].desc = desc
            state.playlists[i].updatedBy = actor.rawValue
            state.playlists[i].ts = TogetherStore.now()
        } != nil
    }

    /// 彻底连根拔起一首歌：
    /// 1. 物理音频文件
    /// 2. 歌词文件
    /// 3. index.json 元数据
    /// 4. 所有歌单里的 trackId
    /// 5. 喜欢列表、刻字、单句循环
    func deleteTrackPermanently(_ trackId: String, by actor: TogetherActor = .user) {
        let fm = FileManager.default
        let lib = library()
        if let t = lib.track(id: trackId), let rel = t.file {
            let audioPath = Self.sharedRootURL.appendingPathComponent(rel)
            try? fm.removeItem(at: audioPath)
            if let lrc = t.lyrics {
                try? fm.removeItem(at: rootURL.appendingPathComponent(lrc))
            }
        }

        // 强行刷一遍 library 触发 reconcile
        queue.sync {
            var currentLib = loadLibraryLocked()
            currentLib.tracks.removeAll { $0.id == trackId }
            _ = saveLibraryLocked(currentLib)
        }

        // 级联清理所有 state 引用
        cleanupOrphanTracks(Set([trackId]))
    }

    /// 内部级联清理孤儿引用
    func cleanupOrphanTracks(_ deadIds: Set<String>) {
        guard !deadIds.isEmpty else { return }
        mutate(by: .ai, event: "clean_orphans") { state in
            for i in 0..<state.playlists.count {
                state.playlists[i].tracks.removeAll { deadIds.contains($0) }
            }
            state.liked.removeAll { deadIds.contains($0) }
            for tid in deadIds {
                state.loopLines.removeValue(forKey: tid)
            }
            state.notes.removeAll { deadIds.contains($0.trackId) }
            if let current = state.track?.id, deadIds.contains(current) {
                state.track = nil
                state.playback.playing = false
                state.playback.position = 0
            }
        }
    }

    /// 小惊喜：双人和角色的心动共振
    func triggerResonance(from actor: TogetherActor, whisper: String) {
        mutate(by: actor, event: "resonance") { state in
            state.resonance = TogetherResonance(
                from: actor.rawValue,
                whisper: whisper,
                ts: TogetherStore.now()
            )
        }
    }
}
