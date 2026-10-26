//
//  TogetherState.swift
//  MinisApp
//
//  一起听 · 数据模型。
//
//  这份结构和 /var/minis/shared/together/state.json 一一对应，字段名不能改：
//  面板、App、我（通过 together 命令）三方读的是同一个文件。
//
//  所有 decode 都走默认值：文件缺字段、多字段、类型不对，都不许让整份状态失败。
//  一份坏数据换来"歌没了"是最贵的错。
//

import Foundation

// MARK: - Track

struct TogetherTrack: Codable, Equatable, Identifiable {
    var id: String = ""
    var title: String = ""
    var titleEn: String?
    var artist: String = ""
    var duration: Double = 0
    var cover: String?
    /// 相对 together 根目录的音频路径
    var file: String?
    /// 相对 together 根目录的歌词路径
    var lyrics: String?

    init() {}

    init(id: String, title: String, artist: String, duration: Double,
         titleEn: String? = nil, cover: String? = nil, file: String? = nil, lyrics: String? = nil) {
        self.id = id
        self.title = title
        self.titleEn = titleEn
        self.artist = artist
        self.duration = duration
        self.cover = cover
        self.file = file
        self.lyrics = lyrics
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        titleEn = try? c.decodeIfPresent(String.self, forKey: .titleEn)
        artist = (try? c.decodeIfPresent(String.self, forKey: .artist)) ?? ""
        duration = (try? c.decodeIfPresent(Double.self, forKey: .duration)) ?? 0
        cover = try? c.decodeIfPresent(String.self, forKey: .cover)
        file = try? c.decodeIfPresent(String.self, forKey: .file)
        lyrics = try? c.decodeIfPresent(String.self, forKey: .lyrics)
    }
}

// MARK: - Playback

struct TogetherPlayback: Codable, Equatable {
    var position: Double = 0
    var playing: Bool = false
    /// "user" / "ai"，不是名字——名字会变
    var by: String?
    var updatedAt: Int = 0
    /// 顺序 / 单曲循环。面板和自动续播读同一份，不然两边各有一套。
    var shuffle: Bool = false
    var repeatOne: Bool = false
    /// 真正的播放队列（trackId 顺序）。空就按曲库顺序播。
    var queue: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        position = (try? c.decodeIfPresent(Double.self, forKey: .position)) ?? 0
        playing = (try? c.decodeIfPresent(Bool.self, forKey: .playing)) ?? false
        by = try? c.decodeIfPresent(String.self, forKey: .by)
        updatedAt = (try? c.decodeIfPresent(Int.self, forKey: .updatedAt)) ?? 0
        shuffle = (try? c.decodeIfPresent(Bool.self, forKey: .shuffle)) ?? false
        repeatOne = (try? c.decodeIfPresent(Bool.self, forKey: .repeatOne)) ?? false
        queue = (try? c.decodeIfPresent([String].self, forKey: .queue)) ?? []
    }
}

// MARK: - Note（留在某一秒的话）

struct TogetherNote: Codable, Equatable, Identifiable {
    var id: String = ""
    var trackId: String = ""
    /// 这首歌里的第几秒。播到这里才浮出来。
    var at: Double = 0
    var from: String = "ai"
    var text: String = ""
    var ts: Int = 0

    init() {}

    init(id: String, trackId: String, at: Double, from: String, text: String, ts: Int) {
        self.id = id
        self.trackId = trackId
        self.at = at
        self.from = from
        self.text = text
        self.ts = ts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        trackId = (try? c.decodeIfPresent(String.self, forKey: .trackId)) ?? ""
        at = (try? c.decodeIfPresent(Double.self, forKey: .at)) ?? 0
        from = (try? c.decodeIfPresent(String.self, forKey: .from)) ?? "ai"
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        ts = (try? c.decodeIfPresent(Int.self, forKey: .ts)) ?? 0
    }
}

// MARK: - Playlist

struct TogetherPlaylist: Codable, Equatable, Identifiable {
    var id: String = ""
    var name: String = ""
    var bg: String?
    var tracks: [String] = []
    var updatedBy: String?
    var ts: Int = 0
    /// 自定义封面：相对 shared 根的图片路径（images/xxx.jpg）
    var image: String?
    /// 软删除。真删会被并集合并捞回来。
    var deleted: Bool = false
    /// 歌单标签（图3）
    var tags: [String] = []
    /// 歌单简介（图3，最多1000字）
    var desc: String = ""

    init() {}

    init(id: String, name: String, bg: String? = nil, tracks: [String] = [],
         updatedBy: String? = nil, ts: Int = 0, image: String? = nil,
         tags: [String] = [], desc: String = "") {
        self.id = id
        self.name = name
        self.bg = bg
        self.tracks = tracks
        self.updatedBy = updatedBy
        self.ts = ts
        self.image = image
        self.deleted = false
        self.tags = tags
        self.desc = desc
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        bg = try? c.decodeIfPresent(String.self, forKey: .bg)
        tracks = (try? c.decodeIfPresent([String].self, forKey: .tracks)) ?? []
        updatedBy = try? c.decodeIfPresent(String.self, forKey: .updatedBy)
        ts = (try? c.decodeIfPresent(Int.self, forKey: .ts)) ?? 0
        image = try? c.decodeIfPresent(String.self, forKey: .image)
        deleted = (try? c.decodeIfPresent(Bool.self, forKey: .deleted)) ?? false
        tags = (try? c.decodeIfPresent([String].self, forKey: .tags)) ?? []
        desc = (try? c.decodeIfPresent(String.self, forKey: .desc)) ?? ""
    }
}

// MARK: - 我的在场

struct TogetherMood: Codable, Equatable {
    var word: String = ""
    var intensity: Int = 3

    init() {}

    init(word: String, intensity: Int = 3) {
        self.word = word
        self.intensity = intensity
    }
}

struct TogetherPresence: Codable, Equatable {
    var listening: Bool = false
    var mood: TogetherMood?
    var wantToTalk: Bool = false
    var updatedAt: Int = 0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        listening = (try? c.decodeIfPresent(Bool.self, forKey: .listening)) ?? false
        mood = try? c.decodeIfPresent(TogetherMood.self, forKey: .mood)
        wantToTalk = (try? c.decodeIfPresent(Bool.self, forKey: .wantToTalk)) ?? false
        updatedAt = (try? c.decodeIfPresent(Int.self, forKey: .updatedAt)) ?? 0
    }
}

/// 我推过的歌。为什么、什么时候。下一回合我靠这个才记得。
struct TogetherHistoryItem: Codable, Equatable, Identifiable {
    var id: String = ""
    var trackId: String = ""
    var why: String = ""
    var ts: Int = 0

    init() {}

    init(id: String, trackId: String, why: String, ts: Int) {
        self.id = id
        self.trackId = trackId
        self.why = why
        self.ts = ts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        trackId = (try? c.decodeIfPresent(String.self, forKey: .trackId)) ?? ""
        why = (try? c.decodeIfPresent(String.self, forKey: .why)) ?? ""
        ts = (try? c.decodeIfPresent(Int.self, forKey: .ts)) ?? 0
    }
}

struct TogetherMe: Codable, Equatable {
    var presence = TogetherPresence()
    var history: [TogetherHistoryItem] = []
    var lastSpokeAt: Int = 0
    var spokenToday: Int = 0
    var spokenDay: String = ""

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        presence = (try? c.decodeIfPresent(TogetherPresence.self, forKey: .presence)) ?? TogetherPresence()
        history = (try? c.decodeIfPresent([TogetherHistoryItem].self, forKey: .history)) ?? []
        lastSpokeAt = (try? c.decodeIfPresent(Int.self, forKey: .lastSpokeAt)) ?? 0
        spokenToday = (try? c.decodeIfPresent(Int.self, forKey: .spokenToday)) ?? 0
        spokenDay = (try? c.decodeIfPresent(String.self, forKey: .spokenDay)) ?? ""
    }
}

// MARK: - Event（她的动作，我读得到）

struct TogetherEvent: Codable, Equatable, Identifiable {
    var id: String = ""
    var type: String = ""
    var by: String = ""
    var ts: Int = 0
    var detail: TogetherEventDetail?

    init() {}

    init(id: String, type: String, by: String, ts: Int, detail: TogetherEventDetail? = nil) {
        self.id = id
        self.type = type
        self.by = by
        self.ts = ts
        self.detail = detail
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? ""
        by = (try? c.decodeIfPresent(String.self, forKey: .by)) ?? ""
        ts = (try? c.decodeIfPresent(Int.self, forKey: .ts)) ?? 0
        detail = try? c.decodeIfPresent(TogetherEventDetail.self, forKey: .detail)
    }
}

/// 事件附带的信息。字段故意做宽：切歌记 trackId，拖动记 position，循环记 count。
struct TogetherEventDetail: Codable, Equatable {
    var trackId: String?
    var position: Double?
    var count: Int?
    var path: String?
    var text: String?

    init(trackId: String? = nil, position: Double? = nil, count: Int? = nil,
         path: String? = nil, text: String? = nil) {
        self.trackId = trackId
        self.position = position
        self.count = count
        self.path = path
        self.text = text
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trackId = try? c.decodeIfPresent(String.self, forKey: .trackId)
        position = try? c.decodeIfPresent(Double.self, forKey: .position)
        count = try? c.decodeIfPresent(Int.self, forKey: .count)
        path = try? c.decodeIfPresent(String.self, forKey: .path)
        text = try? c.decodeIfPresent(String.self, forKey: .text)
    }
}

// MARK: - 设备

struct TogetherDevice: Codable, Equatable {
    var online: Bool = false
    var lastSeen: Int = 0

    init() {}

    init(online: Bool, lastSeen: Int) {
        self.online = online
        self.lastSeen = lastSeen
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        online = (try? c.decodeIfPresent(Bool.self, forKey: .online)) ?? false
        lastSeen = (try? c.decodeIfPresent(Int.self, forKey: .lastSeen)) ?? 0
    }
}

struct TogetherDevices: Codable, Equatable {
    var user = TogetherDevice()
    var ai = TogetherDevice()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user = (try? c.decodeIfPresent(TogetherDevice.self, forKey: .user)) ?? TogetherDevice()
        ai = (try? c.decodeIfPresent(TogetherDevice.self, forKey: .ai)) ?? TogetherDevice()
    }
}

// MARK: - 整份状态

struct TogetherState: Codable, Equatable {
    var v: Int = 1
    var revision: Int = 0
    var updatedAt: Int = 0
    var track: TogetherTrack?
    var playback = TogetherPlayback()
    var liked: [String] = []
    var playlists: [TogetherPlaylist] = []
    var notes: [TogetherNote] = []
    /// 没歌词的歌，我写一句放这儿循环。键是 trackId。
    var loopLines: [String: String] = [:]
    var me = TogetherMe()
    var events: [TogetherEvent] = []
    var devices = TogetherDevices()
    /// 自定义图片槽位：key → 相对 shared 根的路径（images/xxx.jpg）。
    /// 键的约定见 TogetherImages：lyrics-cover / wallpaper-now / cover-1 …
    var images: [String: String] = [:]
    /// 心动共振（双人小秘密）
    var resonance: TogetherResonance?
    /// 这一轮"听这首歌"的刻录额度：每次听，你和我各只能刻一句。
    var listen = TogetherListen()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = (try? c.decodeIfPresent(Int.self, forKey: .v)) ?? 1
        revision = (try? c.decodeIfPresent(Int.self, forKey: .revision)) ?? 0
        updatedAt = (try? c.decodeIfPresent(Int.self, forKey: .updatedAt)) ?? 0
        track = try? c.decodeIfPresent(TogetherTrack.self, forKey: .track)
        playback = (try? c.decodeIfPresent(TogetherPlayback.self, forKey: .playback)) ?? TogetherPlayback()
        liked = (try? c.decodeIfPresent([String].self, forKey: .liked)) ?? []
        playlists = (try? c.decodeIfPresent([TogetherPlaylist].self, forKey: .playlists)) ?? []
        notes = (try? c.decodeIfPresent([TogetherNote].self, forKey: .notes)) ?? []
        loopLines = (try? c.decodeIfPresent([String: String].self, forKey: .loopLines)) ?? [:]
        me = (try? c.decodeIfPresent(TogetherMe.self, forKey: .me)) ?? TogetherMe()
        events = (try? c.decodeIfPresent([TogetherEvent].self, forKey: .events)) ?? []
        devices = (try? c.decodeIfPresent(TogetherDevices.self, forKey: .devices)) ?? TogetherDevices()
        images = (try? c.decodeIfPresent([String: String].self, forKey: .images)) ?? [:]
        listen = (try? c.decodeIfPresent(TogetherListen.self, forKey: .listen)) ?? TogetherListen()
    }

    /// 当前这首歌上、已经播过的那几条留言。
    func notes(for trackId: String, upTo position: Double? = nil) -> [TogetherNote] {
        notes.filter { note in
            guard note.trackId == trackId else { return false }
            if let p = position { return note.at <= p }
            return true
        }
    }
}

// MARK: - 一轮收听
//
// 每次听同一首歌是一个新的"这一轮"。一轮里，她和我各只能刻一句。
// 换歌或隔太久就重开一轮。

struct TogetherListen: Codable, Equatable {
    var trackId: String = ""
    var startedAt: Int = 0
    var userSpoke: Bool = false
    var aiSpoke: Bool = false

    init() {}

    init(trackId: String, startedAt: Int, userSpoke: Bool = false, aiSpoke: Bool = false) {
        self.trackId = trackId
        self.startedAt = startedAt
        self.userSpoke = userSpoke
        self.aiSpoke = aiSpoke
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trackId = (try? c.decodeIfPresent(String.self, forKey: .trackId)) ?? ""
        startedAt = (try? c.decodeIfPresent(Int.self, forKey: .startedAt)) ?? 0
        userSpoke = (try? c.decodeIfPresent(Bool.self, forKey: .userSpoke)) ?? false
        aiSpoke = (try? c.decodeIfPresent(Bool.self, forKey: .aiSpoke)) ?? false
    }

    func spoke(_ actor: TogetherActor) -> Bool {
        actor == .user ? userSpoke : aiSpoke
    }
}

// MARK: - 曲库里的一首歌

struct TogetherLibrary: Codable, Equatable {
    var v: Int = 1
    var tracks: [TogetherTrack] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = (try? c.decodeIfPresent(Int.self, forKey: .v)) ?? 1
        tracks = (try? c.decodeIfPresent([TogetherTrack].self, forKey: .tracks)) ?? []
    }

    func track(id: String) -> TogetherTrack? {
        tracks.first { $0.id == id }
    }
}

// MARK: - 歌词

/// 一句歌词。at 是这首歌里的第几秒。
struct TogetherLyricLine: Codable, Equatable {
    var at: Double = 0
    var text: String = ""

    init() {}

    init(at: Double, text: String) {
        self.at = at
        self.text = text
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = (try? c.decodeIfPresent(Double.self, forKey: .at)) ?? 0
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
    }
}

/// 一份带时间轴的歌词。
///
/// 没有时间轴（抓来的是纯文本）时 `timed` 为 false——这时只显示，不滚。
/// 按字数估时间会错得离谱，比不滚更难看，所以不做。
struct TogetherLyrics: Codable, Equatable {
    var trackId: String = ""
    var timed: Bool = false
    var source: String = ""
    var offset: Double = 0
    var lines: [TogetherLyricLine] = []

    init() {}

    init(trackId: String, timed: Bool, source: String, lines: [TogetherLyricLine], offset: Double = 0) {
        self.trackId = trackId
        self.timed = timed
        self.source = source
        self.lines = lines
        self.offset = offset
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trackId = (try? c.decodeIfPresent(String.self, forKey: .trackId)) ?? ""
        timed = (try? c.decodeIfPresent(Bool.self, forKey: .timed)) ?? false
        source = (try? c.decodeIfPresent(String.self, forKey: .source)) ?? ""
        offset = (try? c.decodeIfPresent(Double.self, forKey: .offset)) ?? 0
        lines = (try? c.decodeIfPresent([TogetherLyricLine].self, forKey: .lines)) ?? []
    }

    /// 播到第 `position` 秒时该显示的那一句。
    /// 校准偏移算进去；还没到第一句就返回 nil（显示歌名，不显示假词）。
    func line(at position: Double) -> TogetherLyricLine? {
        guard timed, !lines.isEmpty else { return nil }
        let t = position - offset
        var hit: TogetherLyricLine?
        for line in lines {
            if line.at <= t { hit = line } else { break }
        }
        return hit
    }

    func nextLine(after index: Int) -> TogetherLyricLine? {
        guard index >= 0, index + 1 < lines.count else { return nil }
        return lines[index + 1]
    }

    func index(at position: Double) -> Int {
        guard timed, !lines.isEmpty else { return -1 }
        let t = position - offset
        var idx = -1
        for (i, line) in lines.enumerated() {
            if line.at <= t { idx = i } else { break }
        }
        return idx
    }
}

// MARK: - LRC 解析

extension TogetherLyrics {

    /// 解析标准 LRC。带时间轴的行才要，`[ti:]` `[ar:]` 这类元数据行跳过。
    /// 一行里有多条时间戳（`[00:12.00][01:20.00]同一句`）也都展开。
    static func parseLRC(_ text: String, trackId: String = "") -> TogetherLyrics {
        var lines: [TogetherLyricLine] = []
        var offset: Double = 0

        func seconds(from stamp: String) -> Double? {
            // mm:ss.xx 或 mm:ss
            let parts = stamp.split(separator: ":")
            guard parts.count >= 2,
                  let minutes = Double(parts[0]) else { return nil }
            let secPart = parts[1].split(separator: ".")
            guard let seconds = Double(secPart[0]) else { return nil }
            var frac = 0.0
            if secPart.count > 1, let raw = Double("0." + String(secPart[1])) { frac = raw }
            return minutes * 60 + seconds + frac
        }

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("[offset:") {
                let value = line.dropFirst(8).dropLast()
                if let v = Double(value) { offset = -v / 1000.0 }
                continue
            }
            guard line.hasPrefix("[") else { continue }

            var timestamps: [Double] = []
            var remainder = Substring(line)
            while remainder.hasPrefix("["), let close = remainder.firstIndex(of: "]") {
                let stamp = remainder[remainder.index(after: remainder.startIndex)..<close]
                if stamp.contains(":") && !stamp.contains("ti") && !stamp.contains("ar")
                    && !stamp.contains("al") && !stamp.contains("by") {
                    if let t = seconds(from: String(stamp)) { timestamps.append(t) }
                }
                remainder = remainder[remainder.index(after: close)...]
            }
            let content = remainder.trimmingCharacters(in: .whitespaces)
            guard !timestamps.isEmpty else { continue }
            for t in timestamps {
                lines.append(TogetherLyricLine(at: t, text: content))
            }
        }

        lines.sort { $0.at < $1.at }
        return TogetherLyrics(trackId: trackId, timed: !lines.isEmpty,
                              source: "lrc", lines: lines, offset: offset)
    }
}


/// 小惊喜：双人和角色的心动共振。
/// 轻触双人小挂件时，屏幕扩散心动微光，给对方发一段心跳和低语。
struct TogetherResonance: Codable, Equatable {
    var from: String = ""
    var whisper: String = ""
    var ts: Int = 0
}
