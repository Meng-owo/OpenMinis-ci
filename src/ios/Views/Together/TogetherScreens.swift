//
//  TogetherScreens.swift
//  MinisApp
//
//  一起听 · 歌单库 / 歌单详情 / 我喜欢的音乐 / 一起听 / 编辑面板。
//
//  复用清单（不另造轮子）：
//  头像 → PersonaAvatarView     颜色 → CSSThemeVariables
//  字体 → ChatFont              文案 → TogetherCopy
//  反馈 → MinisToast            数据 → TogetherStore
//

import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

// MARK: - 共用：页面壁纸
//
// 主题中心每个壁纸槽位都得有页面真的去读，否则"换完没反应"。
// 这里统一一层：主题底色 + 选中的图（压暗到和播放页一致），
// 用 .background 挂上去，不参与布局，不改内容尺寸。

/// 壁纸压色。以前 0.82 写死在两处，两处还不一样（播放页一处、这个文件一处）。
/// 现在收成一个口子：`together/skin.json` 里的 `wallpaperShade`，0 = 原图直出，越大越暗。
@MainActor
enum TogetherWallpaperTone {
    /// 浅色照片上直接压白字看不清，所以默认留一点（0.45，见 TogetherSkinValues）。
    /// 要"换上去什么样就是什么样"，把 skin.json 里的 wallpaperShade 调成 0。
    static func opacity(for slot: String) -> Double {
        _ = slot   // 预留:以后可以按槽位给不同压色
        let v = TogetherSkin.wallpaperShade
        return min(0.9, max(0, v))
    }
}

struct TogetherWallpaperLayer: View {
    let slot: String

    var body: some View {
        // GeometryReader 只吃父给的尺寸、绝不反过来撑大父视图——这是这层不参与布局的关键。
        // 以前是裸 ZStack 套 scaledToFill，图比屏幕宽时整块会变大，
        // 塞进 body 的 ZStack 当兄弟就会把内容往右下挤（换壁纸后整页错位就是这个）。
        GeometryReader { geo in
            ZStack {
                CSSThemeVariables.bg(scope: .chat)
                // 私藏壁纸是兜底:某一页没单独挑图时,用这张。以前它只写不读,等于死槽。
                if let url = TogetherImages.url(for: slot) ?? TogetherImages.url(for: TogetherImages.wallpaperSweet),
                   let img = TogetherImages.cachedImage(for: url) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                    CSSThemeVariables.bg(scope: .chat)
                        .opacity(TogetherWallpaperTone.opacity(for: slot))
                }
            }
        }
        .ignoresSafeArea()
    }
}

extension View {
    func togetherWallpaper(_ slot: String) -> some View {
        background(TogetherWallpaperLayer(slot: slot))
    }
}

// MARK: - 共用：封面

@MainActor
enum TogetherCover {
    /// 五档灰度，明度递减。背景永远从主题里长出来，不写死色值。
    static func fill(_ key: String?) -> LinearGradient {
        let index: Int
        switch key {
        case "cover-1": index = 0
        case "cover-2": index = 1
        case "cover-3": index = 2
        case "cover-4": index = 3
        case "cover-now": index = 4
        default: index = 1
        }
        let steps: [Double] = [0.10, 0.24, 0.42, 0.62, 0.82]
        let base = CSSThemeVariables.textMain(scope: .chat)
        let top = base.opacity(steps[index] * 0.75)
        let bottom = base.opacity(min(0.95, steps[index] + 0.22))
        return LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static let keys = ["cover-1", "cover-2", "cover-3", "cover-4", "cover-now"]
}

/// 封面：槽位里有图就用图，没有才回落到主题渐变。
/// 图是 shared/together/images/<slot>.<ext>，我和她都能换。
struct TogetherCoverView: View {
    let key: String?
    var corner: CGFloat = 12
    /// 歌单自己的封面优先
    var imagePath: String? = nil

    var body: some View {
        ZStack {
            if let url = TogetherStore.shared.imageURL(imagePath),
               let img = TogetherImages.cachedImage(for: url) {
                Image(uiImage: img).resizable().scaledToFill()
            } else if let key, let url = TogetherImages.url(for: key),
                      let img = TogetherImages.cachedImage(for: url) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                TogetherCover.fill(key)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

// MARK: - 共用：一行歌

struct TogetherTrackRow: View {
    let track: TogetherTrack
    var isPlaying: Bool = false
    var noteCount: Int = 0
    var trailing: AnyView?
    var onTap: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                TogetherCoverView(key: track.cover, corner: 9)
                    .frame(width: 40, height: 40)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(ChatFont.font(13, weight: .medium))
                            .foregroundStyle(CSSThemeVariables.card(scope: .chat).opacity(0.85))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(track.title)
                            .font(ChatFont.font(14, weight: .medium))
                            .foregroundStyle(
                                isPlaying
                                    ? CSSThemeVariables.accent(scope: .chat)
                                    : CSSThemeVariables.textMain(scope: .chat)
                            )
                            .lineLimit(1)

                        if noteCount > 0 {
                            Text("\"")
                                .font(ChatFont.font(13, weight: .semibold))
                                .foregroundStyle(CSSThemeVariables.textDim(scope: .chat).opacity(0.8))
                        }
                    }

                    Text("\(track.artist) · \(mmss(track.duration))")
                        .font(ChatFont.font(11.5))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if let trailing { trailing }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func mmss(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - 歌单库

struct TogetherLibraryView: View {

    @Binding var editing: TogetherPlaylist?

    @State private var playlists: [TogetherPlaylist] = []
    @State private var showNew = false
    @State private var newName = ""
    @State private var showImporter = false
    @State private var importing = false
    /// copy 模式选择器先落到这里，等 sheet 收起再开始导入。
    @State private var pendingPicks: [URL] = []
    /// 正在换封面的那个歌单
    @State private var coverTarget: TogetherPlaylist?
    private let importer = LocalFileImporter()
    /// 一起听的状态在别的进程也会变（AI 那边改歌单），列表得自己刷，别等重进 App。
    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                    .padding(.top, 34)

                HStack {
                    Text(TogetherCopy.myPlaylists)
                        .font(ChatFont.font(15, weight: .semibold))
                        .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                    Spacer()
                    Button { showImporter = true } label: {
                        if importing {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 14)
                    // 侧载包上 .fileImporter 会「选中了但点了没反应」——那是
                    // FileProvider 的 security-scope 授权被静默拒了。
                    // DocumentCopyPicker 走 asCopy，把文件拷进 tmp 再给普通 URL。
                    .sheet(isPresented: $showImporter) {
                        DocumentCopyPicker(contentTypes: importer.allowedTypes,
                                           allowsMultipleSelection: true) { urls in
                            pendingPicks = urls
                        } onDone: {
                            showImporter = false
                            let urls = pendingPicks
                            pendingPicks = []
                            guard !urls.isEmpty else { return }
                            importing = true
                            Task {
                                let added = await importer.importFiles(urls)
                                importing = false
                                playlists = TogetherStore.shared.livePlaylists()
                                if added.isEmpty {
                                    MinisToast.show(TogetherCopy.importFailed, systemImage: "exclamationmark.circle")
                                } else {
                                    MinisToast.show("\(added.count) \(TogetherCopy.importDone)")
                                }
                            }
                        }
                    }

                    Button {
                        newName = ""
                        showNew = true
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "plus")
                            Text(TogetherCopy.newPlaylist)
                        }
                        .font(ChatFont.font(12, weight: .medium))
                        .foregroundStyle(CSSThemeVariables.accent(scope: .chat))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 22)
                .padding(.top, 22)

                allSongsEntry
                    .padding(.horizontal, 22)
                    .padding(.top, 14)

                if playlists.isEmpty {
                    emptyPlaylists
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(playlists) { playlist in
                            playlistCard(playlist)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 14)
                    .sheet(item: $coverTarget) { playlist in
                        DocumentCopyPicker(contentTypes: [.image],
                                           allowsMultipleSelection: false) { urls in
                            guard let url = urls.first else { return }
                            _ = TogetherStore.shared.setPlaylistImage(id: playlist.id, from: url)
                        } onDone: {
                            coverTarget = nil
                            playlists = TogetherStore.shared.livePlaylists()
                        }
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .onAppear { playlists = TogetherStore.shared.livePlaylists() }
        .onReceive(ticker) { _ in
            let fresh = TogetherStore.shared.livePlaylists()
            if fresh != playlists { playlists = fresh }
        }
        .navigationDestination(for: String.self) { id in
            if id == TogetherAllSongsView.routeID {
                TogetherAllSongsView()
            } else {
                TogetherPlaylistDetail(playlistId: id)
            }
        }
        .sheet(isPresented: $showNew) {
            newPlaylistSheet
                .presentationDetents([.height(220)])
                .presentationBackground(CSSThemeVariables.bg(scope: .chat))
        }
        .togetherWallpaper(TogetherImages.wallpaperLibrary)
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: -10) {
                PersonaAvatarView(iconRef: TogetherIdentity.aiIcon, size: 84)
                    .frame(width: 84, height: 84)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(CSSThemeVariables.bg(scope: .chat), lineWidth: 2.5))
                    .zIndex(1)
                PersonaAvatarView(iconRef: TogetherIdentity.userIcon, size: 84)
                    .frame(width: 84, height: 84)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(CSSThemeVariables.bg(scope: .chat), lineWidth: 2.5))
            }

            Text("\(ChatAddressing.assistant()) & \(ChatAddressing.user())")
                .font(ChatFont.font(15.5, weight: .medium))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))

            Text(summaryLine)
                .font(ChatFont.font(10.5))
                .tracking(0.5)
                .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
        }
    }

    private var summaryLine: String {
        let songs = TogetherStore.shared.library().tracks.count
        let lists = playlists.count
        return String(format: AppLocalized("%1$d songs · %2$d playlists", comment: "一起听 · 库概览"), songs, lists)
    }

    private func playlistCard(_ playlist: TogetherPlaylist) -> some View {
        NavigationLink(value: playlist.id) {
            VStack(alignment: .leading, spacing: 8) {
                TogetherCoverView(key: playlist.bg, corner: 19, imagePath: playlist.image)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(alignment: .topTrailing) {
                        if playlist.tracks.contains(TogetherPlayer.shared.track?.id ?? "") {
                            playingBars
                                .padding(10)
                        }
                    }

                Text(playlist.name)
                    .font(ChatFont.font(13, weight: .medium))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                    .lineLimit(1)

                Text(String(format: AppLocalized("%d songs", comment: "一起听 · 歌曲数"), playlist.tracks.count))
                    .font(ChatFont.font(10.5))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(TogetherCopy.changeCover) { coverTarget = playlist }
            if playlist.image != nil {
                Button(TogetherCopy.resetCover, role: .destructive) {
                    TogetherStore.shared.clearPlaylistImage(id: playlist.id)
                    playlists = TogetherStore.shared.livePlaylists()
                }
            }
        }
    }

    /// 目录里的歌都能在这儿直接播。歌单只是分类，不是唯一入口。
    private var allSongsEntry: some View {
        NavigationLink(value: TogetherAllSongsView.routeID) {
            HStack(spacing: 12) {
                TogetherCoverView(key: "cover-1", corner: 12)
                    .frame(width: 46, height: 46)
                    .overlay(
                        Image(systemName: "music.note.list")
                            .font(ChatFont.font(16, weight: .medium))
                            .foregroundStyle(CSSThemeVariables.card(scope: .chat).opacity(0.9))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(TogetherCopy.allSongs)
                        .font(ChatFont.font(14, weight: .medium))
                        .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                    Text(String(format: AppLocalized("%d songs", comment: "一起听 · 歌曲数"), TogetherStore.shared.library().tracks.count))
                        .font(ChatFont.font(11.5))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(ChatFont.font(12, weight: .semibold))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .chat).opacity(0.7))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var playingBars: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(CSSThemeVariables.card(scope: .chat).opacity(0.9))
                    .frame(width: 2.5, height: i == 1 ? 11 : 7)
            }
        }
    }

    private var emptyPlaylists: some View {
        VStack(spacing: 8) {
            Text(TogetherCopy.noSongsYet)
                .font(ChatFont.font(13))
                .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var newPlaylistSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(TogetherCopy.newPlaylist)
                .font(ChatFont.font(15, weight: .semibold))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))

            TextField(TogetherCopy.playlistName, text: $newName)
                .textFieldStyle(.plain)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(CSSThemeVariables.optionBg(scope: .chat))
                )

            HStack {
                Spacer()
                Button(TogetherCopy.done) {
                    if let id = TogetherStore.shared.createPlaylist(name: newName),
                       let created = TogetherStore.shared.livePlaylists().first(where: { $0.id == id }) {
                        playlists = TogetherStore.shared.livePlaylists()
                        editing = created
                    }
                    showNew = false
                }
                .font(ChatFont.font(14, weight: .semibold))
                .foregroundStyle(CSSThemeVariables.accentFg(scope: .chat))
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
                .background(Capsule().fill(CSSThemeVariables.accent(scope: .chat)))
            }
        }
        .padding(22)
    }
}

// MARK: - 全部歌曲

/// 直接读 shared/music：目录里有什么就列什么。
/// 歌单是分类，不是唯一入口——不然导进来的歌没地方找。
struct TogetherAllSongsView: View {

    static let routeID = "all-songs"

    @State private var tracks: [TogetherTrack] = []
    @State private var searchText = ""
    @State private var pendingDelete: TogetherTrack?
    @State private var showDeleteConfirm = false
    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var filtered: [TogetherTrack] {
        guard !searchText.isEmpty else { return tracks }
        return tracks.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.artist.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text(TogetherCopy.allSongs)
                    .font(ChatFont.font(21, weight: .semibold))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                    .padding(.top, 26)

                Text(String(format: AppLocalized("%d songs", comment: "一起听 · 歌曲数"), tracks.count))
                    .font(ChatFont.font(11.5))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                    .padding(.top, 6)

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(ChatFont.font(13))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                    TextField(TogetherCopy.searchSongOrArtist, text: $searchText)
                        .font(ChatFont.font(13))
                        .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(ChatFont.font(13))
                                .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(CSSThemeVariables.optionBg(scope: .chat)))
                .padding(.horizontal, 22)
                .padding(.top, 14)

                VStack(spacing: 0) {
                    ForEach(filtered) { track in
                        TogetherTrackRow(
                            track: track,
                            isPlaying: TogetherPlayer.shared.track?.id == track.id,
                            noteCount: 0,
                            trailing: AnyView(
                                Menu {
                                    Button(role: .destructive) {
                                        deleteTrack(track)
                                        reload()
                                    } label: {
                                        Label(TogetherCopy.deletePermanently, systemImage: "trash")
                                    }
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .font(ChatFont.font(14))
                                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                                        .frame(width: 24, height: 24)
                                }
                            ),
                            onTap: {
                                TogetherPlayer.shared.load(track)
                                TogetherStore.shared.play(trackId: track.id, at: 0, by: .user,
                                                           queue: filtered.map { $0.id })
                            }
                        )
                        .contextMenu {
                            Button(role: .destructive) {
                                deleteTrack(track)
                                reload()
                            } label: {
                                Label(TogetherCopy.deletePermanently, systemImage: "trash")
                            }
                        }
                        Divider()
                            .overlay(CSSThemeVariables.divider(scope: .chat))
                            .padding(.leading, 52)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 14)

                if tracks.isEmpty {
                    VStack(spacing: 6) {
                        Text(TogetherCopy.emptyTitle)
                            .font(ChatFont.font(13.5, weight: .semibold))
                            .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                        Text(TogetherCopy.emptyHint)
                            .font(ChatFont.font(12.5))
                            .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 40)
                }
            }
            .padding(.bottom, 24)
        }
        .onAppear { reload() }
        .onReceive(ticker) { _ in reload() }
        .alert(TogetherCopy.deletePermanently, isPresented: $showDeleteConfirm, presenting: pendingDelete) { track in
            Button(AppLocalized("Delete", comment: "删除"), role: .destructive) {
                performDelete(track)
            }
            Button(AppLocalized("Cancel", comment: "取消"), role: .cancel) {}
        } message: { _ in
            Text(TogetherCopy.deleteTrackMessage)
        }
        .togetherWallpaper(TogetherImages.wallpaperLibrary)
    }

    private func reload() {
        // 确认框还挂着时先别重排列表，否则待删的那首歌可能已经从数组里消失，确认就落空了。
        guard !showDeleteConfirm else { return }
        let fresh = TogetherStore.shared.library().tracks
        if fresh != tracks { tracks = fresh }
    }

    private func deleteTrack(_ track: TogetherTrack) {
        // 删音频文件不可逆，先问一句，确认后才真删。
        pendingDelete = track
        showDeleteConfirm = true
    }

    private func performDelete(_ track: TogetherTrack) {
        // 先把确认态收掉：reload 在确认态下会故意不重排列表。
        showDeleteConfirm = false
        pendingDelete = nil
        if TogetherPlayer.shared.track?.id == track.id {
            TogetherPlayer.shared.stop()
        }
        TogetherStore.shared.deleteTrackPermanently(track.id, by: .user)
        reload()
    }
}

// MARK: - 我喜欢的音乐

struct TogetherLikedView: View {

    @State private var liked: [TogetherTrack] = []
    @State private var state = TogetherState()
    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                cover
                    .padding(.top, 30)

                Text(AppLocalized("Liked songs", comment: "一起听 · 喜欢的音乐"))
                    .font(ChatFont.font(21, weight: .semibold))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                    .padding(.top, 18)

                HStack(spacing: 8) {
                    HStack(spacing: -8) {
                        PersonaAvatarView(iconRef: TogetherIdentity.userIcon, size: 30)
                            .frame(width: 30, height: 30)
                            .clipShape(Circle())
                            .overlay(Circle().strokeBorder(CSSThemeVariables.bg(scope: .chat), lineWidth: 2))
                            .zIndex(1)
                        PersonaAvatarView(iconRef: TogetherIdentity.aiIcon, size: 30)
                            .frame(width: 30, height: 30)
                            .clipShape(Circle())
                            .overlay(Circle().strokeBorder(CSSThemeVariables.bg(scope: .chat), lineWidth: 2))
                    }
                    Text(String(format: AppLocalized("%d liked songs", comment: "一起听 · 喜欢的音乐数量"), liked.count))
                        .font(ChatFont.font(11.5, design: .serif))
                        .italic()
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                }
                .padding(.top, 8)

                HStack(spacing: 12) {
                    Button {
                        guard let first = liked.first else { return }
                        TogetherPlayer.shared.load(first)
                        TogetherStore.shared.play(trackId: first.id, at: 0, by: .user)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                            Text(TogetherCopy.playAll)
                        }
                        .font(ChatFont.font(13, weight: .semibold))
                        .foregroundStyle(CSSThemeVariables.accentFg(scope: .chat))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(CSSThemeVariables.accent(scope: .chat)))
                    }
                    .buttonStyle(.plain)
                    .disabled(liked.isEmpty)

                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)

                VStack(spacing: 0) {
                    ForEach(liked) { track in
                        TogetherTrackRow(
                            track: track,
                            isPlaying: TogetherPlayer.shared.track?.id == track.id,
                            trailing: AnyView(
                                Button {
                                    TogetherStore.shared.toggleLike(trackId: track.id, by: .user)
                                    reload()
                                } label: {
                                    Image(systemName: "heart.fill")
                                        .font(ChatFont.font(14))
                                        .foregroundStyle(CSSThemeVariables.accent(scope: .chat))
                                }
                                .buttonStyle(.plain)
                            ),
                            onTap: {
                                TogetherPlayer.shared.load(track)
                                TogetherStore.shared.play(trackId: track.id, at: 0, by: .user,
                                                           queue: liked.map { $0.id })
                            }
                        )
                        Divider()
                            .overlay(CSSThemeVariables.divider(scope: .chat))
                            .padding(.leading, 52)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 14)

                if liked.isEmpty {
                    Text(TogetherCopy.likedEmpty)
                        .font(ChatFont.font(12.5))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                        .padding(.top, 40)
                }
            }
            .padding(.bottom, 24)
        }
        .onAppear(perform: reload)
        .onReceive(ticker) { _ in reload() }
        .togetherWallpaper(TogetherImages.wallpaperLiked)
    }

    private var cover: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(TogetherCover.fill("cover-now"))
            .frame(width: 172, height: 172)
            .overlay(
                Image(systemName: "heart.fill")
                    .font(ChatFont.font(46, weight: .regular))
                    .foregroundStyle(CSSThemeVariables.card(scope: .chat).opacity(0.92))
            )
            .shadow(color: TogetherSkin.shadowDeep, radius: 22, x: 0, y: 12)
    }

    private func reload() {
        let fresh = TogetherStore.shared.load()
        if fresh.revision != state.revision { state = fresh }
        let lib = TogetherStore.shared.library()
        let freshLiked = state.liked.compactMap { id in lib.track(id: id) }
        if freshLiked != liked { liked = freshLiked }
    }
}

// MARK: - 一起听（双人状态）

struct TogetherSyncView: View {

    @State private var state = TogetherState()
    @State private var pulse = false
    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                duo
                    .padding(.top, 34)

                Text(statusLine)
                    .font(ChatFont.font(10.5))
                    .tracking(0.6)
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                    .padding(.top, 22)

                currentCard
                    .padding(.horizontal, 22)
                    .padding(.top, 18)

                deviceList
                    .padding(.horizontal, 22)
                    .padding(.top, 22)

                if let note = latestAINote {
                    aiLine(note)
                        .padding(.horizontal, 22)
                        .padding(.top, 20)
                }

                handoffButton
                    .padding(.horizontal, 22)
                    .padding(.top, 24)
            }
            .padding(.bottom, 30)
        }
        .onAppear {
            state = TogetherStore.shared.load()
            pulse = true
        }
        .onReceive(ticker) { _ in
            let fresh = TogetherStore.shared.load()
            if fresh.revision != state.revision { state = fresh }
        }
        .togetherWallpaper(TogetherImages.wallpaperSync)
    }

    private var duo: some View {
        HStack(spacing: 26) {
            side(.user, name: ChatAddressing.user(), size: 88)
                .frame(maxWidth: .infinity)

            wave
                .frame(width: 74, height: 26)

            side(.ai, name: ChatAddressing.assistant(), size: 88)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 30)
    }

    private func side(_ role: TogetherActor, name: String, size: CGFloat) -> some View {
        VStack(spacing: 9) {
            PersonaAvatarView(
                iconRef: role == .ai ? TogetherIdentity.aiIcon : TogetherIdentity.userIcon,
                size: size
            )
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(CSSThemeVariables.bg(scope: .chat), lineWidth: 3.5))

            Text(name)
                .font(ChatFont.font(12, weight: .medium))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                .lineLimit(1)

            Text(role == .ai && state.playback.by == "ai"
                 ? AppLocalized("controlling", comment: "一起听 · 在控制")
                 : AppLocalized("following", comment: "一起听 · 跟着听"))
                .font(ChatFont.font(9.5, weight: .medium))
                .tracking(0.5)
                .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(CSSThemeVariables.optionBg(scope: .chat)))
        }
    }

    private var wave: some View {
        HStack(spacing: 4) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(CSSThemeVariables.textDim(scope: .chat).opacity(0.55))
                    .frame(width: 2.5, height: pulse ? 16 : 6)
                    .animation(
                        .easeInOut(duration: 1.1)
                        .repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.12),
                        value: pulse
                    )
            }
        }
    }

    private var statusLine: String {
        let online = state.devices.user.online && state.devices.ai.online
        return online
            ? AppLocalized("In sync", comment: "一起听 · 同步中")
            : AppLocalized("One side offline, changes are queued",
                           comment: "一起听 · 一端离线")
    }

    private var currentCard: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(TogetherCover.fill(TogetherPlayer.shared.track?.cover))
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(TogetherPlayer.shared.track?.title ?? TogetherCopy.untitledTrack)
                    .font(ChatFont.font(14, weight: .medium))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                    .lineLimit(1)
                Text(TogetherPlayer.shared.track?.artist ?? "")
                    .font(ChatFont.font(11.5))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button { TogetherPlayer.shared.userToggle(); state = TogetherStore.shared.load() } label: {
                Image(systemName: TogetherPlayer.shared.isPlaying ? "pause.fill" : "play.fill")
                    .font(ChatFont.font(14, weight: .semibold))
                    .foregroundStyle(CSSThemeVariables.accentFg(scope: .chat))
                    .frame(width: 34, height: 34)
                    .background(CSSThemeVariables.accent(scope: .chat))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(CSSThemeVariables.card(scope: .chat))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(CSSThemeVariables.optionBorder(scope: .chat), lineWidth: 0.5)
        )
    }

    private var deviceList: some View {
        VStack(spacing: 0) {
            deviceRow(
                name: "\(ChatAddressing.user())\(AppLocalized("'s iPhone", comment: "一起听 · 设备"))",
                detail: state.devices.user.online
                    ? AppLocalized("online", comment: "一起听 · 在线")
                    : AppLocalized("away", comment: "一起听 · 离线"),
                controlling: state.playback.by == "user"
            )
            Divider().overlay(CSSThemeVariables.divider(scope: .chat))
            deviceRow(
                name: ChatAddressing.assistant(),
                detail: state.me.presence.mood.map { "\($0.word)" }
                    ?? AppLocalized("quiet", comment: "一起听 · 没说话"),
                controlling: state.playback.by == "ai"
            )
        }
    }

    private func deviceRow(name: String, detail: String, controlling: Bool) -> some View {
        HStack {
            Text(name)
                .font(ChatFont.font(13, weight: controlling ? .semibold : .regular))
                .foregroundStyle(
                    controlling
                        ? CSSThemeVariables.textMain(scope: .chat)
                        : CSSThemeVariables.textDim(scope: .chat)
                )
            Spacer()
            Text(detail)
                .font(ChatFont.font(11))
                .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
            if controlling {
                Image(systemName: "checkmark")
                    .font(ChatFont.font(11, weight: .semibold))
                    .foregroundStyle(CSSThemeVariables.accent(scope: .chat))
                    .padding(.leading, 6)
            }
        }
        .padding(.vertical, 13)
    }

    private var latestAINote: TogetherNote? {
        guard let trackId = TogetherPlayer.shared.track?.id else { return nil }
        return state.notes.filter { $0.trackId == trackId }.max(by: { $0.ts < $1.ts })
    }

    private func aiLine(_ note: TogetherNote) -> some View {
        HStack(alignment: .top, spacing: 9) {
            PersonaAvatarView(iconRef: TogetherIdentity.aiIcon, size: 26)
                .frame(width: 26, height: 26)
                .clipShape(Circle())

            Text(note.text)
                .font(ChatFont.font(12.5))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(CSSThemeVariables.optionBg(scope: .chat).opacity(0.6))
        )
    }

    private var handoffButton: some View {
        Button {
            // 把遥控器递过去：谁在控制，翻转给另一方。
            let next: TogetherActor = state.playback.by == "ai" ? .user : .ai
            TogetherStore.shared.mutate(
                by: .user,
                event: "handoff",
                detail: TogetherEventDetail(text: next.rawValue)
            ) { s in
                s.playback.by = next.rawValue
                s.playback.updatedAt = TogetherStore.now()
                // 递过去那一方就是"在控制"，另一方的在线状态跟着真实
                s.devices.ai.online = true
                s.me.presence.updatedAt = TogetherStore.now()
            }
            state = TogetherStore.shared.load()
            MinisToast.show(AppLocalized("Handed over", comment: "一起听 · 递遥控器完成"))
        } label: {
            Text("\(TogetherCopy.handoff) \(state.playback.by == "ai" ? ChatAddressing.user() : ChatAddressing.assistant())")
                .font(ChatFont.font(13, weight: .medium))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(CSSThemeVariables.optionBg(scope: .chat))
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 编辑面板

struct TogetherPlaylistEditor: View {

    let playlist: TogetherPlaylist

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var tags: [String] = []
    @State private var desc: String = ""
    @State private var bg: String = "cover-1"
    @State private var showCoverPicker = false
    @State private var coverItem: PhotosPickerItem?
    @State private var showTagSheet = false
    @State private var confirmDelete = false
    @State private var pendingDelete: TogetherTrack?
    @State private var showDeleteConfirm = false
    /// 打开时的背景值：保存时和它比，改过才写盘，别每次都多发一条 playlist.bg。
    @State private var originalBg: String = "cover-1"

    /// 预设标签存"键",不存译文:译文随语言变,存进歌单后一切语言就对不上。
    /// 旧数据存的是译文,displayTag 认不出来就原样显示,不丢。
    private static let presetTagKeys = [
        "pop", "sad", "healing", "romantic", "night", "drive",
        "electronic", "light", "whiteNoise", "rock", "acg", "instrumental",
    ]

    private func displayTag(_ raw: String) -> String {
        switch raw {
        case "pop": return AppLocalized("Pop", comment: "一起听 · 标签 流行")
        case "sad": return AppLocalized("Sad", comment: "一起听 · 标签 伤感")
        case "healing": return AppLocalized("Healing", comment: "一起听 · 标签 治愈")
        case "romantic": return AppLocalized("Romantic", comment: "一起听 · 标签 浪漫")
        case "night": return AppLocalized("Night", comment: "一起听 · 标签 夜晚")
        case "drive": return AppLocalized("Drive", comment: "一起听 · 标签 车载")
        case "electronic": return AppLocalized("Electronic", comment: "一起听 · 标签 电子")
        case "light": return AppLocalized("Light music", comment: "一起听 · 标签 轻音乐")
        case "whiteNoise": return AppLocalized("White noise", comment: "一起听 · 标签 白噪音")
        case "rock": return AppLocalized("Rock", comment: "一起听 · 标签 摇滚")
        case "acg": return AppLocalized("ACG", comment: "一起听 · 标签 ACG")
        case "instrumental": return AppLocalized("Instrumental", comment: "一起听 · 标签 纯音乐")
        default: return raw
        }
    }

    private var tagsLabel: String {
        tags.isEmpty ? TogetherCopy.noTags : tags.map(displayTag).joined(separator: " · ")
    }

    private var tagsColor: Color {
        tags.isEmpty ? CSSThemeVariables.textDim(scope: .chat) : CSSThemeVariables.accent(scope: .chat)
    }

    private var descCountString: String {
        "\(desc.count)/1000"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    cardSection
                    descSection
                    deleteSection
                }
                .padding(20)
            }
            .background(CSSThemeVariables.bg(scope: .chat).ignoresSafeArea())
            .navigationTitle(TogetherCopy.playlistInfo)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppLocalized("Cancel", comment: "取消")) { dismiss() }
                        .font(ChatFont.font(14))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalized("Save", comment: "保存")) {
                        save()
                        dismiss()
                    }
                    .font(ChatFont.font(14, weight: .bold))
                    .foregroundStyle(CSSThemeVariables.accent(scope: .chat))
                }
            }
            .onAppear(perform: reload)
            .alert(TogetherCopy.deletePlaylist, isPresented: $confirmDelete) {
                Button(AppLocalized("Delete", comment: "删除"), role: .destructive) {
                    TogetherStore.shared.deletePlaylist(id: playlist.id)
                    dismiss()
                }
                Button(AppLocalized("Cancel", comment: "取消"), role: .cancel) {}
            }
            .photosPicker(isPresented: $showCoverPicker,
                          selection: $coverItem,
                          matching: .images)
            .onChange(of: coverItem) { item in
                guard let item else { return }
                Task {
                    await TogetherPhotoImport.toPlaylist(item, id: playlist.id)
                    coverItem = nil
                    reload()
                }
            }
            .sheet(isPresented: $showTagSheet) {
                tagSelectionSheet
                    .presentationDetents([.height(300)])
                    .presentationBackground(CSSThemeVariables.bg(scope: .chat))
            }
            .alert(TogetherCopy.deletePermanently, isPresented: $showDeleteConfirm, presenting: pendingDelete) { track in
                Button(AppLocalized("Delete", comment: "删除"), role: .destructive) {
                    performDelete(track)
                }
                Button(AppLocalized("Cancel", comment: "取消"), role: .cancel) {}
            } message: { _ in
                Text(TogetherCopy.deleteTrackMessage)
            }
        }
    }

    private var cardSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text(TogetherCopy.changeCoverTitle)
                    .font(ChatFont.font(14, weight: .medium))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                Spacer()
                Button {
                    showCoverPicker = true
                } label: {
                    HStack(spacing: 8) {
                        TogetherCoverView(key: bg, corner: 8, imagePath: playlist.image)
                            .frame(width: 44, height: 44)
                        Image(systemName: "chevron.right")
                            .font(ChatFont.font(12))
                            .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().overlay(CSSThemeVariables.divider(scope: .chat)).padding(.leading, 16)

            HStack {
                Text(TogetherCopy.playlistName)
                    .font(ChatFont.font(14, weight: .medium))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                Spacer()
                TextField(TogetherCopy.playlistName, text: $name)
                    .font(ChatFont.font(14))
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                    .frame(maxWidth: 180)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider().overlay(CSSThemeVariables.divider(scope: .chat)).padding(.leading, 16)

            HStack {
                Text(TogetherCopy.tags)
                    .font(ChatFont.font(14, weight: .medium))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                Spacer()
                Button {
                    showTagSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Text(tagsLabel)
                            .font(ChatFont.font(13))
                            .foregroundStyle(tagsColor)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(ChatFont.font(12))
                            .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(CSSThemeVariables.card(scope: .chat))
        )
    }

    private var descSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(TogetherCopy.descTitle)
                .font(ChatFont.font(13, weight: .semibold))
                .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))

            ZStack(alignment: .topLeading) {
                if desc.isEmpty {
                    Text(TogetherCopy.descPlaceholder)
                        .font(ChatFont.font(13.5))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat).opacity(0.6))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }

                TextEditor(text: $desc)
                    .font(ChatFont.font(13.5))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .frame(height: 110)
                    .padding(6)
                    .onChange(of: desc, perform: onDescChanged)
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(CSSThemeVariables.optionBg(scope: .chat))
            )

            HStack {
                Spacer()
                Text(descCountString)
                    .font(ChatFont.font(11))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(CSSThemeVariables.card(scope: .chat))
        )
    }

    private var deleteSection: some View {
        Button {
            confirmDelete = true
        } label: {
            Text(TogetherCopy.deletePlaylist)
                .font(ChatFont.font(14, weight: .semibold))
                .foregroundStyle(CSSThemeVariables.danger(scope: .chat))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(CSSThemeVariables.dangerSoft(scope: .chat))
                )
        }
        .buttonStyle(.plain)
        .padding(.top, 10)
    }

    private var tagSelectionSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(TogetherCopy.tags)
                .font(ChatFont.font(16, weight: .bold))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 70))], spacing: 10) {
                ForEach(Self.presetTagKeys, id: \.self) { t in
                    tagPill(t)
                }
            }

            Spacer()

            Button(TogetherCopy.done) { showTagSheet = false }
                .font(ChatFont.font(14, weight: .semibold))
                .foregroundStyle(CSSThemeVariables.accent(scope: .chat))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Capsule().fill(CSSThemeVariables.optionBg(scope: .chat)))
        }
        .padding(22)
    }

    private func tagPill(_ t: String) -> some View {
        let isSelected = tags.contains(t)
        let fgColor = isSelected ? CSSThemeVariables.accent(scope: .chat) : CSSThemeVariables.textMain(scope: .chat)
        let bgColor = isSelected ? CSSThemeVariables.accent(scope: .chat).opacity(0.15) : CSSThemeVariables.optionBg(scope: .chat)

        return Button {
            if isSelected {
                tags.removeAll { $0 == t }
            } else {
                tags.append(t)
            }
        } label: {
            Text(displayTag(t))
                .font(ChatFont.font(12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(fgColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(bgColor))
        }
        .buttonStyle(.plain)
    }

    private func onDescChanged(_ val: String) {
        if val.count > 1000 {
            desc = String(val.prefix(1000))
        }
    }

    private func deleteTrack(_ track: TogetherTrack) {
        // 删音频文件不可逆，先问一句，确认后才真删。
        pendingDelete = track
        showDeleteConfirm = true
    }

    private func performDelete(_ track: TogetherTrack) {
        // 先把确认态收掉，再删；编辑器的 reload 没有列表轮询，删完直接重读即可。
        showDeleteConfirm = false
        pendingDelete = nil
        if TogetherPlayer.shared.track?.id == track.id {
            TogetherPlayer.shared.stop()
        }
        TogetherStore.shared.deleteTrackPermanently(track.id, by: .user)
        reload()
    }

    private func reload() {
        let live = TogetherStore.shared.livePlaylists().first { $0.id == playlist.id } ?? playlist
        name = live.name
        tags = live.tags
        desc = live.desc
        bg = live.bg ?? "cover-1"
        originalBg = bg
    }

    private func save() {
        _ = TogetherStore.shared.updatePlaylistInfo(id: playlist.id, name: name, tags: tags, desc: desc, by: .user)
        // 背景不是名字的一部分，updatePlaylistInfo 不碰它；改过就单独存一次，否则退出再进会丢。
        if bg != originalBg {
            TogetherStore.shared.setPlaylistBackground(id: playlist.id, bg: bg, by: .user)
            originalBg = bg
        }
    }
}
// MARK: - 歌单详情
//
// 跟编辑面板分开：详情是"看和听"，编辑是"改"。
// 一条歌单点进来，第一件事是能播，不是能改。

struct TogetherPlaylistDetail: View {

    let playlistId: String

    @Environment(\.dismiss) private var dismiss
    @State private var playlist: TogetherPlaylist?
    @State private var tracks: [TogetherTrack] = []
    @State private var searchText = ""
    @State private var showEditor = false
    @State private var showAddSongs = false
    @State private var state = TogetherState()
    @State private var pendingDelete: TogetherTrack?
    @State private var showDeleteConfirm = false
    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var filteredTracks: [TogetherTrack] {
        if searchText.isEmpty { return tracks }
        return tracks.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.artist.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                    .padding(.top, 8)

                // 搜索栏
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(ChatFont.font(13))
                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                    TextField(TogetherCopy.searchSongOrArtist, text: $searchText)
                        .font(ChatFont.font(13))
                        .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(ChatFont.font(13))
                                .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(CSSThemeVariables.optionBg(scope: .chat)))
                .padding(.horizontal, 22)
                .padding(.top, 14)

                actionRow
                    .padding(.horizontal, 22)
                    .padding(.top, 14)

                VStack(spacing: 0) {
                    ForEach(filteredTracks) { track in
                        playlistTrackRow(track)
                        Divider()
                            .overlay(CSSThemeVariables.divider(scope: .chat))
                            .padding(.leading, 52)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)

                if tracks.isEmpty {
                    VStack(spacing: 10) {
                        Text(TogetherCopy.noSongsYet)
                            .font(ChatFont.font(13))
                            .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                        Button(TogetherCopy.addSongs) { showAddSongs = true }
                            .font(ChatFont.font(13, weight: .medium))
                            .foregroundStyle(CSSThemeVariables.accent(scope: .chat))
                    }
                    .padding(.top, 40)
                }
            }
            .padding(.bottom, 30)
        }
        .background(CSSThemeVariables.bg(scope: .chat).ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(TogetherCopy.edit) { showEditor = true }
                    .font(ChatFont.font(14, weight: .medium))
                    .foregroundStyle(CSSThemeVariables.accent(scope: .chat))
            }
        }
        .onAppear(perform: reload)
        .onReceive(ticker) { _ in reload() }
        .alert(TogetherCopy.deletePermanently, isPresented: $showDeleteConfirm, presenting: pendingDelete) { track in
            Button(AppLocalized("Delete", comment: "删除"), role: .destructive) {
                performDelete(track)
            }
            Button(AppLocalized("Cancel", comment: "取消"), role: .cancel) {}
        } message: { _ in
            Text(TogetherCopy.deleteTrackMessage)
        }
        .sheet(isPresented: $showEditor, onDismiss: reload) {
            if let playlist {
                TogetherPlaylistEditor(playlist: playlist)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(CSSThemeVariables.bg(scope: .chat))
            }
        }
        .sheet(isPresented: $showAddSongs, onDismiss: reload) {
            TogetherAddSongsSheet(playlistId: playlistId)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(CSSThemeVariables.bg(scope: .chat))
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(TogetherCover.fill(playlist?.bg))
                .frame(width: 118, height: 118)
                .shadow(color: TogetherSkin.shadowDeep, radius: 18, x: 0, y: 10)

            Text(playlist?.name ?? "")
                .font(ChatFont.font(22, weight: .semibold))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                .multilineTextAlignment(.center)

            HStack(spacing: 7) {
                HStack(spacing: -8) {
                    PersonaAvatarView(iconRef: TogetherIdentity.aiIcon, size: 30)
                        .frame(width: 30, height: 30)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(CSSThemeVariables.bg(scope: .chat), lineWidth: 2))
                        .zIndex(1)
                    PersonaAvatarView(iconRef: TogetherIdentity.userIcon, size: 30)
                        .frame(width: 30, height: 30)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(CSSThemeVariables.bg(scope: .chat), lineWidth: 2))
                }
                Text("\(ChatAddressing.assistant()) & \(ChatAddressing.user()) \(TogetherCopy.editedTogether)")
                    .font(ChatFont.font(10.5))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                guard let first = tracks.first else { return }
                TogetherPlayer.shared.load(first)
                TogetherStore.shared.play(trackId: first.id, at: 0, by: .user)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                    Text(TogetherCopy.playAll)
                }
                .font(ChatFont.font(13, weight: .semibold))
                .foregroundStyle(CSSThemeVariables.accentFg(scope: .chat))
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Capsule().fill(CSSThemeVariables.accent(scope: .chat)))
            }
            .buttonStyle(.plain)
            .disabled(tracks.isEmpty)

            Button {
                guard let pick = tracks.randomElement() else { return }
                TogetherPlayer.shared.load(pick)
                TogetherStore.shared.play(trackId: pick.id, at: 0, by: .user)
            } label: {
                Image(systemName: "shuffle")
                    .font(ChatFont.font(14, weight: .medium))
                    .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(CSSThemeVariables.optionBg(scope: .chat)))
            }
            .buttonStyle(.plain)

            Button(TogetherCopy.addSongs) { showAddSongs = true }
                .font(ChatFont.font(12.5, weight: .medium))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                .padding(.horizontal, 15)
                .padding(.vertical, 9)
                .overlay(Capsule().strokeBorder(CSSThemeVariables.optionBorder(scope: .chat), lineWidth: 0.8))

            Spacer()
        }
    }

    private func noteCount(for trackId: String) -> Int {
        state.notes.filter { $0.trackId == trackId }.count
    }

    private func playlistTrackRow(_ track: TogetherTrack) -> some View {
        TogetherTrackRow(
            track: track,
            isPlaying: TogetherPlayer.shared.track?.id == track.id,
            noteCount: noteCount(for: track.id),
            trailing: AnyView(rowTrailing(track)),
            onTap: {
                TogetherPlayer.shared.load(track)
                TogetherStore.shared.play(trackId: track.id, at: 0, by: .user, queue: tracks.map { $0.id })
            }
        )
        .contextMenu { rowContextMenu(track) }
    }

    private func rowTrailing(_ track: TogetherTrack) -> some View {
        HStack(spacing: 12) {
            Button {
                TogetherStore.shared.toggleLike(trackId: track.id, by: .user)
                state = TogetherStore.shared.load()
            } label: {
                Image(systemName: state.liked.contains(track.id) ? "heart.fill" : "heart")
                    .font(ChatFont.font(14))
                    .foregroundStyle(state.liked.contains(track.id) ? Color.red : CSSThemeVariables.textDim(scope: .chat))
            }
            .buttonStyle(.plain)

            Menu {
                Button(TogetherCopy.removeFromPlaylist, role: .destructive) {
                    TogetherStore.shared.removeTrack(track.id, from: playlistId)
                    reload()
                }
                Button(TogetherCopy.deletePermanently, role: .destructive) {
                    deleteTrack(track)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(ChatFont.font(14))
                    .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                    .frame(width: 24, height: 24)
            }
        }
    }

    @ViewBuilder
    private func rowContextMenu(_ track: TogetherTrack) -> some View {
        Button {
            TogetherPlayer.shared.load(track)
            TogetherStore.shared.play(trackId: track.id, at: 0, by: .user, queue: tracks.map { $0.id })
        } label: {
            Label(AppLocalized("Play", comment: "一起听 · 播放"), systemImage: "play.fill")
        }
        Button(role: .destructive) {
            TogetherStore.shared.removeTrack(track.id, from: playlistId)
            reload()
        } label: {
            Label(TogetherCopy.removeFromPlaylist, systemImage: "minus.circle")
        }
        Button(role: .destructive) {
            deleteTrack(track)
        } label: {
            Label(TogetherCopy.deletePermanently, systemImage: "trash")
        }
    }

    private func deleteTrack(_ track: TogetherTrack) {
        // 删音频文件不可逆，先问一句，确认后才真删。
        pendingDelete = track
        showDeleteConfirm = true
    }

    private func performDelete(_ track: TogetherTrack) {
        // 先把确认态收掉：reload 在确认态下会故意不重排列表。
        showDeleteConfirm = false
        pendingDelete = nil
        if TogetherPlayer.shared.track?.id == track.id {
            TogetherPlayer.shared.stop()
        }
        TogetherStore.shared.deleteTrackPermanently(track.id, by: .user)
        reload()
    }

    private func reload() {
        // 确认框还挂着时先别重排列表，否则待删的那首歌可能已经从数组里消失，确认就落空了。
        guard !showDeleteConfirm else { return }
        let freshState = TogetherStore.shared.load()
        if freshState.revision != state.revision { state = freshState }
        let freshPlaylist = TogetherStore.shared.livePlaylists().first { $0.id == playlistId }
        if freshPlaylist != playlist { playlist = freshPlaylist }
        let lib = TogetherStore.shared.library()
        let freshTracks = (freshPlaylist?.tracks ?? []).compactMap { lib.track(id: $0) }
        if freshTracks != tracks { tracks = freshTracks }
    }
}

// MARK: - 加歌

struct TogetherAddSongsSheet: View {

    let playlistId: String

    @Environment(\.dismiss) private var dismiss
    @State private var all: [TogetherTrack] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(TogetherCopy.addSongs)
                .font(ChatFont.font(16, weight: .semibold))
                .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(all) { track in
                        Button {
                            TogetherStore.shared.addTrack(track.id, to: playlistId)
                        } label: {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(TogetherCover.fill(track.cover))
                                    .frame(width: 36, height: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.title)
                                        .font(ChatFont.font(13.5))
                                        .foregroundStyle(CSSThemeVariables.textMain(scope: .chat))
                                    Text(track.artist)
                                        .font(ChatFont.font(11))
                                        .foregroundStyle(CSSThemeVariables.textDim(scope: .chat))
                                }
                                Spacer()
                                Image(systemName: "plus.circle")
                                    .font(ChatFont.font(16))
                                    .foregroundStyle(CSSThemeVariables.accent(scope: .chat))
                            }
                            .padding(.horizontal, 22)
                            .padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .onAppear {
            all = TogetherStore.shared.library().tracks
        }
    }
}


// MARK: - 相册选图

/// 从相册选一张，直接落到一起听的图片槽位。
/// 以前走的是文件选择器，会跳去「最近项目/文件夹」，这里改成真正的相册。
@MainActor
enum TogetherPhotoImport {

    static func data(_ item: PhotosPickerItem) async -> Data? {
        try? await item.loadTransferable(type: Data.self)
    }

    /// 落一张图到槽位。成功/失败都给一句反馈——以前全程静默，
    /// 用户看不到到底成没成，体感就是"换图失败"。
    @discardableResult
    static func toSlot(_ item: PhotosPickerItem, slot: String) async -> Bool {
        guard let bytes = await data(item) else {
            MinisToast.show(TogetherCopy.importFailed, systemImage: "exclamationmark.circle")
            return false
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("together-\(slot)-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try bytes.write(to: tmp)
            if TogetherStore.shared.setImage(slot: slot, from: tmp) != nil {
                MinisToast.show(AppLocalized("Cover updated", comment: "一起听 · 换图成功"), systemImage: "checkmark.circle")
                return true
            }
        } catch {}
        MinisToast.show(TogetherCopy.importFailed, systemImage: "exclamationmark.circle")
        return false
    }

    @discardableResult
    static func toPlaylist(_ item: PhotosPickerItem, id: String) async -> Bool {
        guard let bytes = await data(item) else {
            MinisToast.show(TogetherCopy.importFailed, systemImage: "exclamationmark.circle")
            return false
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("together-playlist-\(id)-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try bytes.write(to: tmp)
            if TogetherStore.shared.setPlaylistImage(id: id, from: tmp) {
                MinisToast.show(AppLocalized("Cover updated", comment: "一起听 · 换图成功"), systemImage: "checkmark.circle")
                return true
            }
        } catch {}
        MinisToast.show(TogetherCopy.importFailed, systemImage: "exclamationmark.circle")
        return false
    }
}
