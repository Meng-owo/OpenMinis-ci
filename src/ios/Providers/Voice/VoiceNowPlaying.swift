import Foundation
import MediaPlayer

// MARK: - Lock-screen / Control Center presence for voice playback
//
// [TTS-10] Two things in this app play voice: VoiceOutputPlayer
// (read-aloud) and GlobalAudioPlayer (voice bubbles / audio attachments).
// Neither had a Now Playing presence: on the lock screen and in Control
// Center there was no title, no progress, and no play/pause — the earphone
// button and the lock-screen controls did nothing during playback.
//
// This controller publishes MPNowPlayingInfoCenter metadata and wires the
// MPRemoteCommandCenter transport to whichever engine currently owns the
// audio session. Call `refresh()` from each engine's state transitions;
// when nothing is playing, the info is cleared.

@MainActor
final class VoiceNowPlaying {

    static let shared = VoiceNowPlaying()
    private init() {}

    private var commandsRegistered = false

    /// Recompute which engine (if any) owns playback and publish it.
    /// Read-aloud wins when it holds a live player (it and bubbles are
    /// mutually exclusive by session policy).
    func refresh() {
        let reader = VoiceOutputPlayer.shared
        let bubble = GlobalAudioPlayer.shared
        // [R24] 一起听优先：音乐是长时间播放，锁屏和控制中心该显示歌名，
        // 而不是被一条还没播完的语音消息顶掉。
        if TogetherPlayer.shared.isActive {
            let t = TogetherPlayer.shared
            publish(title: t.nowPlayingTitle,
                    artist: t.nowPlayingArtist,
                    duration: t.duration,
                    position: t.currentTime,
                    rate: t.isPlaying ? 1 : 0)
            return
        }
        if reader.hasLivePlayer {
            // [AUD8-04] `isPlaying` means "holds a live player" — it stays true
            // while paused, so the lock screen showed "playing" (with a live
            // rate) during a pause. Only a live, unpaused reader counts.
            let rate: Float = (reader.isPlaying && !reader.isPaused) ? VoiceOutputPreferences.speedMultiplier : 0
            publish(title: reader.nowPlayingTitle,
                    duration: reader.playbackDuration,
                    position: reader.playbackPosition,
                    rate: rate)
        } else if bubble.isLoaded {
            let rate: Float = bubble.isPlaying ? bubble.rate : 0
            publish(title: bubble.nowPlayingTitle,
                    duration: bubble.duration,
                    position: bubble.currentTime,
                    rate: rate)
        } else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }

    /// Called when the app is about to go away from audio entirely (both
    /// engines stopped) — convenience for call sites that already know.
    func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Publishing

    /// [AUD-16] What the lock screen / Control Center credits as the artist:
    /// the persona's own name from SOUL, read at publish time so a rename
    /// shows up on the next voice message without a relaunch.
    private static var artistCredit: String {
        let name = SoulStore.cachedMetadata.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Minis" : name
    }

    private func publish(title: String, artist: String? = nil,
                         duration: TimeInterval, position: TimeInterval, rate: Float) {
        registerCommandsIfNeeded()
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist ?? Self.artistCredit,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
        ]
        // Artwork: reuse the app's voice glyph — a real MPMediaItemArtwork
        // keeps Control Center from showing a blank tile. Skip when the
        // image can't be made (metadata still publishes).
        if let art = Self.artworkImage() {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: art.size) { _ in art }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private static func artworkImage() -> UIImage? {
        let config = UIImage.SymbolConfiguration(pointSize: 128, weight: .regular)
        return UIImage(systemName: "waveform.circle.fill", withConfiguration: config)
    }

    // MARK: - Remote commands

    private func registerCommandsIfNeeded() {
        guard !commandsRegistered else { return }
        commandsRegistered = true
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.handleToggle()
            return .success
        }
        center.playCommand.addTarget { [weak self] _ in
            self?.handlePlay()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.handlePause()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.handleSeek(to: e.positionTime)
            return .success
        }
        // [R35] 一起听锁屏切歌。以前只有 toggle/play/pause/seek，
        // 锁屏和耳机能暂停/拖进度，却切不了歌。
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.handleNextTrack()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.handlePreviousTrack()
            return .success
        }
    }

    /// Route to the engine that currently owns the session: the reader
    /// when it holds a live player, else the bubble/attachment player.
    private func targetIsReader() -> Bool {
        VoiceOutputPlayer.shared.hasLivePlayer
    }

    private func handleToggle() {
        if TogetherPlayer.shared.isActive {
            TogetherPlayer.shared.userToggle()
            refresh()
            return
        }
        if targetIsReader() {
            VoiceOutputPlayer.shared.togglePlayPause()
        } else {
            GlobalAudioPlayer.shared.togglePlayPause()
        }
        refresh()
    }

    private func handlePlay() {
        if TogetherPlayer.shared.isActive {
            TogetherPlayer.shared.userPlay()
            refresh()
            return
        }
        if targetIsReader() {
            VoiceOutputPlayer.shared.resume()
        } else {
            let g = GlobalAudioPlayer.shared
            if !g.isPlaying { g.togglePlayPause() }
        }
        refresh()
    }

    private func handlePause() {
        if TogetherPlayer.shared.isActive {
            TogetherPlayer.shared.userPause()
            refresh()
            return
        }
        if targetIsReader() {
            VoiceOutputPlayer.shared.pause()
        } else {
            let g = GlobalAudioPlayer.shared
            if g.isPlaying { g.togglePlayPause() }
        }
        refresh()
    }

    private func handleSeek(to time: TimeInterval) {
        if TogetherPlayer.shared.isActive {
            TogetherPlayer.shared.seek(to: time)
            refresh()
            return
        }
        if targetIsReader() {
            let r = VoiceOutputPlayer.shared
            let d = r.playbackDuration
            if d > 0 { r.seekCurrentUnit(to: min(1, max(0, time / d))) }
        } else {
            GlobalAudioPlayer.shared.seek(to: time)
        }
        refresh()
    }

    // [R36] 上面两个 target 之前只写了调用,没写实现,整个 target 编不过。
    // 一起听在放就按它的队列切;不在放就不接管(锁屏只对"正在放的东西"负责)。
    private func handleNextTrack() {
        guard TogetherPlayer.shared.isActive else { return }
        TogetherPlayer.shared.nextTrack()
        refresh()
    }

    private func handlePreviousTrack() {
        guard TogetherPlayer.shared.isActive else { return }
        TogetherPlayer.shared.previousTrack()
        refresh()
    }
}

// MARK: - Engine hooks

extension VoiceOutputPlayer {
    /// True while a live AVAudioPlayer exists (playing OR paused) — i.e.
    /// this engine currently owns the audio session for voice.
    var hasLivePlayer: Bool { nowPlayingHasLivePlayer }

    /// Short title for Now Playing: the current sentence, trimmed.
    var nowPlayingTitle: String {
        let text = (nowPlayingUnitText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return AppLocalized("Reading aloud", comment: "Now Playing title fallback for read-aloud")
        }
        return String(text.prefix(60))
    }

    /// Route the lock-screen toggle through the existing pause/resume.
    /// [AUD8-04] `isPlaying` stays true while paused (it means "holds a live
    /// player"), so the old `if isPlaying { pause() }` could never resume —
    /// the lock-screen / earbud button was a one-way pause. The toggle must
    /// consult BOTH flags, mirroring GlobalAudioPlayer's semantics.
    func togglePlayPause() {
        if isPlaying && !isPaused { pause() } else { resume() }
    }
}

extension GlobalAudioPlayer {
    /// Friendly title for a bubble/attachment file ("tts-a1b2c3d4" is not).
    var nowPlayingTitle: String {
        let name = fileName
        if name.hasPrefix("tts-") {
            return AppLocalized("AI voice message", comment: "Now Playing title for AI voice bubbles")
        }
        return name.isEmpty
            ? AppLocalized("Audio", comment: "Now Playing title fallback for audio files")
            : name
    }
}
