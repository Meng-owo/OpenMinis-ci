//
//  TogetherImporter.swift
//  MinisApp
//
//  一起听 · 收歌。
//
//  这就是那个"口子"：MusicImporter 协议，本地文件是第一个实现。
//  将来要接别的来源（别的 App、网盘、流媒体），加一个实现，不动核心，
//  也不抢播放权——外部只负责把文件交进来，播还是 TogetherPlayer 播。
//

import Foundation
import AVFoundation
import UniformTypeIdentifiers

protocol MusicImporter {
    var name: String { get }
    func importFiles(_ urls: [URL]) async -> [TogetherTrack]
}

/// 本地文件：她选什么就收什么，视频抽音轨。
@MainActor
final class LocalFileImporter: MusicImporter {

    let name = "local"
    private let logger = AppLogger(category: "TogetherImport")

    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "flac", "aiff", "aif", "caf", "opus", "ogg"
    ]
    private static let videoExtensions: Set<String> = ["mp4", "m4v", "mov"]

    var allowedTypes: [UTType] {
        [.audio, .movie, .mpeg4Movie, .quickTimeMovie]
    }

    func importFiles(_ urls: [URL]) async -> [TogetherTrack] {
        var added: [TogetherTrack] = []
        for url in urls {
            if let track = await importOne(url) {
                added.append(track)
            }
        }
        return added
    }

    private func importOne(_ url: URL) async -> TogetherTrack? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()
        guard Self.audioExtensions.contains(ext) || Self.videoExtensions.contains(ext) else {
            logger.error("[TogetherImport] 不支持的类型 .\(ext)")
            return nil
        }

        let store = TogetherStore.shared
        var index = store.library()

        let baseTitle = url.deletingPathExtension().lastPathComponent
        var id = Self.slug(baseTitle)
        if index.tracks.contains(where: { $0.id == id }) {
            id = "\(id)-\(Int(Date().timeIntervalSince1970))"
        }

        // 落到内置 shared/music，扩展名按真实编码来。
        guard let dest = await writeIntoLibrary(from: url, id: id) else {
            logger.error("[TogetherImport] 落地失败 \(url.lastPathComponent)")
            return nil
        }
        let destName = dest.lastPathComponent

        let duration = await Self.duration(of: dest)
        let asset = AVURLAsset(url: url)
        let meta = (try? await asset.load(.commonMetadata)) ?? []
        let title = await Self.stringValue(meta, identifier: .commonIdentifierTitle) ?? baseTitle
        let artist = await Self.stringValue(meta, identifier: .commonIdentifierArtist) ?? ""

        let track = TogetherTrack(
            id: id,
            title: title,
            artist: artist,
            duration: duration,
            cover: "cover-\(index.tracks.count % 4 + 1)",
            file: "music/\(destName)",
            lyrics: nil
        )
        index.tracks.append(track)
        store.saveLibrary(index)

        // 收了歌就把歌词补上：同目录同名 .lrc 优先，没有就留空（抓词走 shell）。
        if let sidecar = Self.sidecarLyrics(for: url) {
            Self.copyLyrics(sidecar, for: id, store: store)
        }
        return track
    }

    // MARK: 落地

    /// 把选中的文件放进 shared/music。
    /// mp3 原样搬；其它先试抽成 m4a；抽不出来就原样搬并保留原扩展名——
    /// 不能给 m4a 的字节起个 .mp3 的名。
    private func writeIntoLibrary(from source: URL, id: String) async -> URL? {
        let fm = FileManager.default
        let dir = TogetherStore.shared.musicDirectory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let srcExt = source.pathExtension.lowercased()

        if srcExt == "mp3" {
            let dest = dir.appendingPathComponent("\(id).mp3")
            try? fm.removeItem(at: dest)
            do {
                try fm.copyItem(at: source, to: dest)
                return dest
            } catch {
                return nil
            }
        }

        let asset = AVURLAsset(url: source)
        if let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) {
            let dest = dir.appendingPathComponent("\(id).m4a")
            try? fm.removeItem(at: dest)
            session.outputURL = dest
            session.outputFileType = .m4a
            await session.export()
            if session.status == .completed, fm.fileExists(atPath: dest.path) {
                return dest
            }
        }

        let ext = srcExt.isEmpty ? "audio" : srcExt
        let dest = dir.appendingPathComponent("\(id).\(ext)")
        try? fm.removeItem(at: dest)
        do {
            try fm.copyItem(at: source, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    // MARK: 元数据

    private static func duration(of url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let d = try? await asset.load(.duration) else { return 0 }
        let seconds = CMTimeGetSeconds(d)
        return seconds.isFinite ? (seconds * 100).rounded() / 100 : 0
    }

    private static func stringValue(_ items: [AVMetadataItem],
                                    identifier: AVMetadataIdentifier) async -> String? {
        guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier).first,
              let value = try? await item.load(.stringValue) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: 歌词

    private static func sidecarLyrics(for audio: URL) -> URL? {
        let lrc = audio.deletingPathExtension().appendingPathExtension("lrc")
        return FileManager.default.fileExists(atPath: lrc.path) ? lrc : nil
    }

    private static func copyLyrics(_ source: URL, for id: String, store: TogetherStore) {
        let dest = store.lyricsDirectory.appendingPathComponent("\(id).lrc")
        try? FileManager.default.createDirectory(at: store.lyricsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: source, to: dest)

        var index = store.library()
        guard let i = index.tracks.firstIndex(where: { $0.id == id }) else { return }
        index.tracks[i].lyrics = "lyrics/\(id).lrc"
        store.saveLibrary(index)
    }

    // MARK: 命名

    private static func slug(_ text: String) -> String {
        let ascii = text.applyingTransform(.toLatin, reverse: false)?
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased() ?? ""
        let allowed = ascii.unicodeScalars.map { scalar -> Character in
            let v = scalar.value
            if (48...57).contains(v) || (97...122).contains(v) { return Character(scalar) }
            return "-"
        }
        let joined = String(allowed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        if joined.count >= 2 { return String(joined.prefix(40)) }
        return "track-\(Int(Date().timeIntervalSince1970))"
    }
}