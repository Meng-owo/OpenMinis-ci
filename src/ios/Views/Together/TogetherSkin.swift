//
//  TogetherSkin.swift
//  MinisApp
//
//  一起听 · 皮肤层 + 文案层。
//
//  结构层定死（六屏布局、坐标、动效曲线），皮肤层全可换。
//  默认值一律从 App 主题派生：换 minis-theme 这一页跟着变，代码里没有裸色值。
//
//  额外留了一层自己的覆盖：together/skin.json。
//  我（shell 里的 together set skin.xxx）和你都能改它，改完面板不重启就变。
//  全局主题管基础色，这一层管"这一间屋子"的味道。
//

import SwiftUI

// MARK: - 皮肤

struct TogetherSkinValues: Codable, Equatable {
    /// 唱片本体：0 = 用主题主文字色，1 = 纯黑。中间值是深浅。
    var vinylDepth: Double = 0.9
    /// 唱片纹路的透明度
    var vinylRing: Double = 0.055
    /// 卡片/唱片中心圆的圆角
    var cardRadius: Double = 20
    /// 阴影强度 0–1
    var shadow: Double = 1.0
    /// 壁纸档位：warm / cool / rose（对应主题里三套背景）
    var wall: String = "warm"
    /// 壁纸压色：0 = 原图直出，越大越暗。以前写死 0.82，现在可调。
    var wallpaperShade: Double = 0.45

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vinylDepth = (try? c.decodeIfPresent(Double.self, forKey: .vinylDepth)) ?? 0.9
        vinylRing = (try? c.decodeIfPresent(Double.self, forKey: .vinylRing)) ?? 0.055
        cardRadius = (try? c.decodeIfPresent(Double.self, forKey: .cardRadius)) ?? 20
        shadow = (try? c.decodeIfPresent(Double.self, forKey: .shadow)) ?? 1.0
        wall = (try? c.decodeIfPresent(String.self, forKey: .wall)) ?? "warm"
        wallpaperShade = (try? c.decodeIfPresent(Double.self, forKey: .wallpaperShade)) ?? 0.45
    }
}

/// 颜色从主题派生，而主题的取值入口是 @MainActor 的，这里跟着标。
@MainActor
enum TogetherSkin {

    static var values: TogetherSkinValues {
        let url = TogetherStore.shared.rootURL.appendingPathComponent("skin.json")
        guard let data = try? Data(contentsOf: url),
              let v = try? JSONDecoder().decode(TogetherSkinValues.self, from: data) else {
            return TogetherSkinValues()
        }
        return v
    }

    /// 唱片色。深浅由 vinylDepth 控制，色相永远来自主题主文字色。
    static var vinyl: Color {
        let depth = min(1, max(0, values.vinylDepth))
        return CSSThemeVariables.textMain(scope: .chat).opacity(0.72 + 0.28 * depth)
    }

    static var vinylRing: Color {
        CSSThemeVariables.bg(scope: .chat).opacity(values.vinylRing)
    }

    static var shadowDeep: Color {
        .black.opacity(0.22 * values.shadow)
    }

    static var shadowSoft: Color {
        .black.opacity(0.14 * values.shadow)
    }

    static var cardRadius: CGFloat { CGFloat(values.cardRadius) }

    /// 壁纸压色。收口到一处，播放页和另外四页都读它。
    static var wallpaperShade: Double {
        min(0.9, max(0, values.wallpaperShade))
    }
}

// MARK: - 身份
//
// 头像引用只在这里取一次。AI 走通讯录当前人设（SOUL.icon 只是镜像），
// 用户走「我自己」档案。别的地方不许再各写一套取法。

@MainActor
enum TogetherIdentity {
    static var aiIcon: String? {
        let id = SoulStore.displayPersonaId(nil)
        if let p = PersonaStore.shared.personas.first(where: { $0.id == id }),
           let a = p.avatar, !a.isEmpty {
            return a
        }
        return SoulStore.cachedMetadata.icon
    }

    static var userIcon: String? {
        PersonaStore.shared.personas
            .first(where: { $0.id == PersonaStore.userProfilePersonaID })?
            .avatar
    }
}

// MARK: - 文案
//
// 一处集中，全部走本地化。改文案只改这里，不在六个视图里找。
// 名字永远是变量：出现人的地方用 ChatAddressing，不写死。

enum TogetherCopy {
    static var title: String { AppLocalized("Together", comment: "一起听 · 面板标题") }
    // 这两个要读人设名(主线程隔离),所以自己标注;其余成员保持非隔离,
    // 好让 Agent 层(非主线程)也能取到纯文案。
    @MainActor static var emptyTitle: String {
        String(format: AppLocalized("%@'s library is empty", comment: "一起听 · 空状态标题"), ChatAddressing.assistant())
    }
    @MainActor static var emptyHint: String {
        String(format: AppLocalized("Add a song, or ask %@ to add one.", comment: "一起听 · 空状态说明"), ChatAddressing.assistant())
    }
    /// 喜欢列表空了 ≠ 歌库空了,不能共用一句。
    static var likedEmpty: String { AppLocalized("Nothing liked yet", comment: "一起听 · 喜欢空态") }
    /// 单曲缺标题时的占位,与"歌库为空"不是一回事,拆开。
    static var untitledTrack: String { AppLocalized("Untitled track", comment: "一起听 · 缺标题占位") }
    static var untitledPlaylist: String { AppLocalized("Untitled", comment: "一起听 · 新歌单默认名") }
    static var newPlaylist: String { AppLocalized("New playlist", comment: "一起听 · 新建") }
    static var myPlaylists: String { AppLocalized("My playlists", comment: "一起听 · 歌单库标题") }
    static var playAll: String { AppLocalized("Play all", comment: "一起听 · 播放全部") }
    static var edit: String { AppLocalized("Edit", comment: "一起听 · 编辑") }
    static var done: String { AppLocalized("Done", comment: "一起听 · 完成") }
    static var deletePlaylist: String { AppLocalized("Delete this playlist", comment: "一起听 · 删歌单") }
    static var playlistName: String { AppLocalized("Playlist name", comment: "一起听 · 歌单名") }
    static var addSongs: String { AppLocalized("Add songs", comment: "一起听 · 加歌") }
    static var editedTogether: String { AppLocalized("edited", comment: "一起听 · 共同编辑") }
    static var importDone: String { AppLocalized("added", comment: "一起听 · 导入成功") }
    static var importFailed: String { AppLocalized("Couldn't read that file", comment: "一起听 · 导入失败") }
    static var handoff: String { AppLocalized("Hand the remote to", comment: "一起听 · 递遥控器") }
    static var noSongsYet: String { AppLocalized("Nothing here yet", comment: "一起听 · 空列表") }
    static var allSongs: String { AppLocalized("All songs", comment: "一起听 · 全部歌曲（目录直读）") }
    static var noLyrics: String { AppLocalized("No lyrics for this one", comment: "一起听 · 没有歌词") }
    static var noLyricsHint: String { AppLocalized("Leave a line and it will loop here", comment: "一起听 · 没歌词时的提示") }
    static var changeCover: String { AppLocalized("Change cover", comment: "一起听 · 换封面") }
    static var resetCover: String { AppLocalized("Reset cover", comment: "一起听 · 恢复默认封面") }
    static var oneLineOnly: String { AppLocalized("One line per listen — you've already left one", comment: "一起听 · 本轮已经刻过一句") }
    static var playlistInfo: String { AppLocalized("Playlist Info", comment: "一起听 · 歌单信息") }
    static var changeCoverTitle: String { AppLocalized("Change cover", comment: "一起听 · 更换封面") }
    static var tags: String { AppLocalized("Tags", comment: "一起听 · 标签") }
    static var noTags: String { AppLocalized("None", comment: "一起听 · 暂无") }
    static var descTitle: String { AppLocalized("Description", comment: "一起听 · 简介") }
    static var descPlaceholder: String { AppLocalized("Write a brief introduction...", comment: "一起听 · 简介占位") }
    static var removeFromPlaylist: String { AppLocalized("Remove from playlist", comment: "一起听 · 从歌单移除") }
    static var deletePermanently: String { AppLocalized("Delete file permanently", comment: "一起听 · 彻底删除") }
    /// 删歌不可逆，确认框必须把后果说清楚。
    static var deleteTrackMessage: String { AppLocalized("This permanently deletes the audio file and can't be undone.", comment: "一起听 · 删歌确认说明") }
    static var searchSongOrArtist: String { AppLocalized("Search title or artist", comment: "一起听 · 搜索歌名或歌手") }
    static var themeCenter: String { AppLocalized("Theme Center", comment: "一起听 · 装扮中心") }
    static var nowPlayingWallpaper: String { AppLocalized("Now Playing Wallpaper", comment: "一起听 · 播放页壁纸") }
    static var lyricsWallpaper: String { AppLocalized("Lyrics Cover & Wallpaper", comment: "一起听 · 歌词页背景") }
    static var libraryWallpaper: String { AppLocalized("Playlist Library Wallpaper", comment: "一起听 · 歌单库壁纸") }
    static var syncWallpaper: String { AppLocalized("Together Wallpaper", comment: "一起听 · 伴听页壁纸") }
    static var likedWallpaper: String { AppLocalized("Liked Songs Wallpaper", comment: "一起听 · 喜欢页壁纸") }
    static var sweetWallpaper: String { AppLocalized("Secret Wallpaper", comment: "一起听 · 私藏壁纸") }
    static var queueTitle: String { AppLocalized("Playing Queue", comment: "一起听 · 播放队列") }
    static var historyEchoes: String { AppLocalized("Echo Wall", comment: "一起听 · 历史回声墙") }
}
