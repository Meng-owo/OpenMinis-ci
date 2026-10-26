//
//  AudioPlayback.swift
//  MinisApp
//
//  Global audio player singleton + floating PiP capsule + inline audio
//  bubble. Extracted from AIChatView.swift.
//

import AVFoundation
import Combine
import SwiftUI
import UIKit

private let logger = AppLogger(category: "AudioPlayback")

// MARK: - Global Audio Player (Singleton)

@MainActor
class GlobalAudioPlayer: ObservableObject {
    static let shared = GlobalAudioPlayer()
    private init() {
        // Observe AVAudioSession interruptions so we can log when playback
        // is paused by an external audio source (call, Siri, another media
        // app). The actual decision to resume lives elsewhere — this is a
        // diagnostic hook for the silent-audio keep-alive investigation.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                .contains(.shouldResume)
            let label = type == .began ? "began" : "ended"
            let isPlaying = self?.isPlaying ?? false
            logger.info("[AudioPlayback] interruption: type=\(label) shouldResume=\(shouldResume) wasPlaying=\(isPlaying)")
            // [AUD8-08] This observer used to be diagnostic-only ("the decision
            // lives elsewhere" — nothing was elsewhere). Handle it here, per
            // system semantics: remember the pre-interruption intent on .began,
            // and on .ended put the loaded file back when the system says
            // resume.
            if type == .began {
                self?.wasPlayingBeforeInterruption = isPlaying
            } else if shouldResume {
                self?.resumeAfterInterruption()
            } else {
                self?.wasPlayingBeforeInterruption = false
            }
        }
        // [T-ios-live-activity-audio-toggle] The Live Activity play/pause toggle
        // is handled by VoiceOutputState (read-aloud engine), NOT here — see
        // VoiceOutputState.registerLiveActivityToggleObserver (b0f3f884 fix).
    }

    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var rate: Float = 1.0
    @Published var isLoaded = false
    @Published var activeFileURL: URL?
    @Published var fileName: String = ""
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var seekWorkItem: DispatchWorkItem?

    /// Generation counter for in-flight loads. `play` loads off-thread and
    /// the detached task cannot be cancelled, so completion instead checks
    /// that its request is still the current one: bumped by every new
    /// `play` and by `stopInternal` (i.e. stop()).
    private var playRequestId = 0

    /// [AUD8-08] Whether this player was actively playing when a system
    /// interruption (call/Siri) began, so its end can restore playback.
    private var wasPlayingBeforeInterruption = false

    /// Whether the given URL is the currently active audio file.
    func isActive(url: URL) -> Bool {
        activeFileURL == url
    }

    /// Load and play a URL. If already playing this URL, just ensures playback. If a different URL, stops current and loads new.
    func play(url: URL) {
        if activeFileURL == url {
            // Same file — restart from beginning if finished, otherwise resume
            if !isPlaying {
                if duration > 0 && currentTime >= duration - 0.1 {
                    seek(to: 0)
                }
                togglePlayPause()
            }
            return
        }
        // Stop any current playback
        stopInternal()
        // Claim a new load generation (stopInternal bumped it, staling any
        // load still in flight from a previous play).
        playRequestId += 1
        let requestId = playRequestId
        // [AUD8-09] Snapshot whether read-aloud was live at REQUEST time: a
        // reader that appears only later (during the load gap) belongs to a
        // newer explicit intent and must not be preempted; a reader already
        // live now is being deliberately replaced by this tap.
        let readerWasLiveAtRequest = VoiceOutputPlayer.shared.hasLivePlayer
        // Suspend silent audio so media gets full volume
        let preCount = BackgroundKeepAliveManager.shared.silentAudioSuspendCount
        logger.info("[AudioPlayback] play: url=\(url.lastPathComponent) suspendSilentAudio → count will be \(preCount + 1)")
        BackgroundKeepAliveManager.shared.suspendSilentAudioForMedia()
        // Load new file
        let loadURL = url
        Task.detached(priority: .userInitiated) {
            guard let p = try? AVAudioPlayer(contentsOf: loadURL) else {
                await MainActor.run {
                    BackgroundKeepAliveManager.shared.resumeSilentAudioForMedia()
                }
                return
            }
            p.prepareToPlay()
            p.enableRate = true
            let dur = p.duration
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.playRequestId == requestId else {
                    // Superseded by a newer play() or cancelled by stop()
                    // while this load was in flight. Do NOT install/play —
                    // and hand back the silent-audio suspension THIS request
                    // took: stopInternal can never return it, because this
                    // load never became `isLoaded`. (Without this, rapid
                    // play→play leaves the keep-alive suspend count +1
                    // forever, and the stale player starts playing anyway.)
                    BackgroundKeepAliveManager.shared.resumeSilentAudioForMedia()
                    return
                }
                self.player = p
                self.activeFileURL = loadURL
                self.fileName = loadURL.deletingPathExtension().lastPathComponent
                self.duration = dur
                self.currentTime = 0
                self.isLoaded = true
                // [TTS-13] Don't reset to 1.0 — reuse the last rate the
                // user picked in the audio preview.
                self.rate = VoiceBubblePlaybackState.rememberedRate
                // [AUD8-09] A read-aloud that started DURING this load is the
                // newer explicit intent: install the player as loaded but do
                // not auto-play — previously the completion unconditionally
                // began mediaAttachment and hard-preempted the just-started
                // reading (its text dropped, no remainder).
                if !readerWasLiveAtRequest && VoiceOutputPlayer.shared.hasLivePlayer {
                    logger.info("[AudioPlayback] load finished while a read-aloud owns the session — autoplay deferred")
                    VoiceNowPlaying.shared.refresh()
                    return
                }
                // [audit-A8] 续听：这条上次没听完的话，从停的位置接着放
                //（播完的/贴着结尾的不续，避免每回都从头再来）。
                if let resume = VoiceBubblePlaybackState.resumePosition(
                    for: loadURL.deletingPathExtension().lastPathComponent, duration: dur) {
                    p.currentTime = resume
                    self.currentTime = resume
                    logger.info("[AudioPlayback] 续听 \(loadURL.lastPathComponent) @ \(String(format: "%.1f", resume))s")
                }
                // Start playing immediately. Declaring `.mediaAttachment` preempts
                // reply TTS (mutually exclusive) and applies the playback profile.
                AudioSessionCoordinator.shared.begin(.mediaAttachment)
                p.rate = self.rate
                p.play()
                self.isPlaying = true
                self.startTimer()
                VoiceNowPlaying.shared.refresh()
            }
        }
    }

    func togglePlayPause() {
        guard let p = player else { return }
        if p.isPlaying {
            p.pause()
            isPlaying = false
            timer?.invalidate()
        } else {
            AudioSessionCoordinator.shared.begin(.mediaAttachment)
            p.play()
            p.rate = rate
            isPlaying = true
            startTimer()
        }
        VoiceNowPlaying.shared.refresh()
    }

    func seek(to time: TimeInterval) {
        player?.currentTime = time
        currentTime = time
    }

    /// Debounced seek — updates the displayed time immediately but delays the actual
    /// AVAudioPlayer seek by 100 ms, coalescing rapid slider/drag movements.
    func debouncedSeek(to time: TimeInterval) {
        currentTime = time
        seekWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.player?.currentTime = time
        }
        seekWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
    }

    func setRate(_ r: Float) {
        rate = r
        // [TTS-13] Remember the user's pick for the next bubble/file.
        VoiceBubblePlaybackState.rememberRate(r)
        if let p = player, p.isPlaying {
            p.rate = r
        }
    }

    func skip(by seconds: TimeInterval) {
        let newTime = max(0, min(currentTime + seconds, duration))
        seek(to: newTime)
    }

    /// Deprecated: capsule visibility is now derived from `isLoaded`. Kept as a
    /// no-op so existing callers that minimize the full preview into PiP keep
    /// compiling — minimization now happens by simply dismissing the sheet.
    func activatePiP() {}

    /// Stop all playback and reset state. This is the only way to hide the
    /// PiP capsule (driven by `isLoaded` flipping to false in `stopInternal`).
    func stop() {
        stopInternal()
    }

    private func stopInternal() {
        // Stale any load still in flight: its completion now drops itself
        // (and returns its own silent-audio suspension) instead of
        // starting playback after the user already stopped.
        playRequestId += 1
        let wasLoaded = isLoaded
        // [TTS-13] Record where this file stopped for resume/unlistened
        // state (only when something was actually loaded).
        if wasLoaded {
            VoiceBubblePlaybackState.recordProgress(
                fileName: fileName, position: currentTime, duration: duration)
        }
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        activeFileURL = nil
        fileName = ""
        isPlaying = false
        currentTime = 0
        duration = 0
        isLoaded = false
        // End the media-attachment intent — coordinator re-applies the next intent
        // or deactivates. Note: TTS is NOT auto-resumed (per plan scenario 1).
        AudioSessionCoordinator.shared.end(.mediaAttachment)
        VoiceNowPlaying.shared.refresh()
        // Resume silent audio keep-alive if we had suspended it
        if wasLoaded {
            let preCount = BackgroundKeepAliveManager.shared.silentAudioSuspendCount
            logger.info("[AudioPlayback] stopInternal: resumeSilentAudio → count will be \(max(0, preCount - 1))")
            BackgroundKeepAliveManager.shared.resumeSilentAudioForMedia()
        }
    }

    /// [AUD8-08] The system stopped our player for an interruption and now says
    /// it has ended. The old code only logged the notification — the player
    /// stayed stopped (and the old tick path even recorded the takeover as
    /// "finished"). Put the loaded file back if it was playing when the
    /// interruption began.
    private func resumeAfterInterruption() {
        guard wasPlayingBeforeInterruption, let p = player, !p.isPlaying else {
            wasPlayingBeforeInterruption = false
            return
        }
        wasPlayingBeforeInterruption = false
        AudioSessionCoordinator.shared.begin(.mediaAttachment)
        p.play()
        p.rate = rate
        isPlaying = true
        startTimer()
        VoiceNowPlaying.shared.refresh()
        logger.info("[AudioPlayback] resumed after interruption")
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let p = self.player else { return }
            DispatchQueue.main.async {
                self.currentTime = p.currentTime
                if !p.isPlaying {
                    // [AUD8-05] `!p.isPlaying` alone is NOT "finished": it is
                    // also true for a user pause and for an external audio
                    // takeover — both used to be recorded as fully listened
                    // (duration written as position) and released the session
                    // early. Only an end-of-media stop counts as finished;
                    // otherwise keep the real position.
                    let reachedEnd = self.duration > 0 && p.currentTime >= self.duration - 0.05
                    self.isPlaying = false
                    self.timer?.invalidate()
                    // Player stopped (natural end / pause / external stop) →
                    // release the media-attachment intent.
                    AudioSessionCoordinator.shared.end(.mediaAttachment)
                    // [TTS-13] Record finish vs partial stop for unlistened state.
                    VoiceBubblePlaybackState.recordProgress(
                        fileName: self.fileName,
                        position: reachedEnd ? self.duration : p.currentTime,
                        duration: self.duration)
                    VoiceNowPlaying.shared.refresh()
                }
            }
        }
    }
}

// MARK: - Inline Audio Bubble

struct MinisAudioPlayerView: View {
    let url: URL
    let fileURL: URL
    @ObservedObject private var player = GlobalAudioPlayer.shared
    @State private var fileReady = false
    @State private var showPreview = false
    /// [T-kelivo-voice 09-10] Static waveform of the file (sampled once on
    /// appear, background queue). Idle state draws this instead of a dead
    /// slider — the bubble reads as a voice message at a glance, like kelivo.
    @State private var waveformLevels: [Float]? = nil

    /// Fixed height for both placeholder and controls to prevent layout jumps.
    private let controlsHeight: CGFloat = 70

    /// Whether this file is the one currently active in the global player.
    private var isActive: Bool { player.isActive(url: fileURL) }

    var body: some View {
        if fileReady {
            audioControls
                .task(id: fileURL) {
                    // Sample once per file; failure quietly leaves the old look.
                    if waveformLevels == nil {
                        waveformLevels = await AudioWaveformSampler.sampleLevels(from: fileURL)
                    }
                }
        } else {
            placeholder
                .task { await waitForFile() }
        }
    }

    /// Waveform strip for the bubble (static levels, tinted by state).
    @ViewBuilder private var waveformStrip: some View {
        if let levels = waveformLevels {
            AudioWaveformView(levels: levels)
                .frame(height: 26)
                .frame(maxWidth: .infinity)
        }
    }

    private var audioControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "waveform")
                    .font(.caption2)
                Text(url.lastPathComponent)
                    .lineLimit(1)
                    .font(.caption)
                Spacer()
                Button {
                    showPreview = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2)
                        .foregroundColor(ChatColors.secondaryText)
                }
                .buttonStyle(.plain)
            }
            .foregroundColor(ChatColors.secondaryText)

            HStack(spacing: 10) {
                Button {
                    if isActive {
                        player.togglePlayPause()
                    } else {
                        player.play(url: fileURL)
                    }
                } label: {
                    Image(systemName: isActive && player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title2)
                        .foregroundColor(MinisTheme.accent)
                }
                .buttonStyle(.plain)

                if isActive && player.isLoaded {
                    Slider(
                        value: Binding(
                            get: { player.currentTime },
                            set: { player.debouncedSeek(to: $0) }
                        ),
                        in: 0...max(player.duration, 0.01)
                    )
                    .tint(MinisTheme.accent)

                    Text(formatTime(player.duration))
                        .font(.caption2)
                        .foregroundColor(ChatColors.secondaryText)
                        .monospacedDigit()
                } else if waveformLevels != nil {
                    // [T-kelivo-voice] Idle: real static waveform — reads as
                    // a voice message, not a disabled control.
                    waveformStrip
                } else {
                    // Waveform still sampling — keep the (disabled) slider so
                    // the bubble doesn't jump height when it lands.
                    Slider(value: .constant(0), in: 0...1)
                        .tint(MinisTheme.accent)
                        .disabled(true)

                    Text(formatTime(0))
                        .font(.caption2)
                        .foregroundColor(ChatColors.secondaryText)
                        .monospacedDigit()
                }
            }
        }
        .padding(10)
        .frame(maxWidth: 320, minHeight: controlsHeight)
        .background(ChatColors.secondaryBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: $showPreview) {
            MinisAudioPreviewView(fileURL: fileURL)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
        }
    }

    private var placeholder: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(url.lastPathComponent).lineLimit(1)
        }
        .font(.caption)
        .foregroundColor(ChatColors.secondaryText)
        .padding(10)
        .frame(maxWidth: 320, minHeight: controlsHeight)
        .background(ChatColors.secondaryBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func waitForFile() async {
        for _ in 0..<12 {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                fileReady = true
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        fileReady = true
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}
// MARK: - Voice Cat Art
//
// [T-voice-cat-card 10-16] 猫的矢量数据（由 voice_player_cat_back_minimal_opt.html
// 的 SVG 原样移植）。坐标全是 viewBox 坐标；canvasTransform() 负责
// 等比缩放 + 水平翻转（等价 HTML 的 scaleX(-1)）。

enum VoiceCatArt {
    static let box = CGSize(width: 1202, height: 848)
    static let renderSize = CGSize(width: 80, height: 56)

    /// viewBox 坐标 → 卡片画布坐标（水平翻转 + 等比缩放）。
    static func canvasTransform() -> CGAffineTransform {
        let s = renderSize.width / box.width
        return CGAffineTransform(a: -s, b: 0, c: 0, d: s, tx: renderSize.width, ty: 0)
    }

    /// 猫身（背影）：viewBox 坐标
    static func body() -> UIBezierPath {
        let p = UIBezierPath()
        p.move(to: CGPoint(x: 222, y: 101))
        p.addLine(to: CGPoint(x: 221, y: 195))
        p.addLine(to: CGPoint(x: 198, y: 264))
        p.addLine(to: CGPoint(x: 134, y: 272))
        p.addLine(to: CGPoint(x: 101, y: 303))
        p.addLine(to: CGPoint(x: 119, y: 310))
        p.addLine(to: CGPoint(x: 170, y: 292))
        p.addLine(to: CGPoint(x: 198, y: 296))
        p.addLine(to: CGPoint(x: 213, y: 382))
        p.addLine(to: CGPoint(x: 295, y: 536))
        p.addLine(to: CGPoint(x: 319, y: 639))
        p.addLine(to: CGPoint(x: 311, y: 711))
        p.addLine(to: CGPoint(x: 322, y: 735))
        p.addLine(to: CGPoint(x: 378, y: 744))
        p.addLine(to: CGPoint(x: 403, y: 726))
        p.addLine(to: CGPoint(x: 441, y: 660))
        p.addLine(to: CGPoint(x: 453, y: 725))
        p.addLine(to: CGPoint(x: 473, y: 744))
        p.addLine(to: CGPoint(x: 506, y: 744))
        p.addLine(to: CGPoint(x: 532, y: 723))
        p.addLine(to: CGPoint(x: 574, y: 628))
        p.addLine(to: CGPoint(x: 666, y: 637))
        p.addLine(to: CGPoint(x: 729, y: 629))
        p.addLine(to: CGPoint(x: 737, y: 720))
        p.addLine(to: CGPoint(x: 762, y: 744))
        p.addLine(to: CGPoint(x: 792, y: 745))
        p.addLine(to: CGPoint(x: 817, y: 728))
        p.addLine(to: CGPoint(x: 850, y: 665))
        p.addLine(to: CGPoint(x: 861, y: 683))
        p.addLine(to: CGPoint(x: 855, y: 714))
        p.addLine(to: CGPoint(x: 874, y: 745))
        p.addLine(to: CGPoint(x: 925, y: 747))
        p.addLine(to: CGPoint(x: 970, y: 696))
        p.addLine(to: CGPoint(x: 984, y: 600))
        p.addLine(to: CGPoint(x: 1012, y: 527))
        p.addLine(to: CGPoint(x: 1018, y: 384))
        p.addLine(to: CGPoint(x: 1056, y: 349))
        p.addLine(to: CGPoint(x: 1081, y: 294))
        p.addLine(to: CGPoint(x: 956, y: 294))
        p.addLine(to: CGPoint(x: 941, y: 252))
        p.addLine(to: CGPoint(x: 810, y: 215))
        p.addLine(to: CGPoint(x: 669, y: 216))
        p.addLine(to: CGPoint(x: 589, y: 237))
        p.addLine(to: CGPoint(x: 559, y: 186))
        p.addLine(to: CGPoint(x: 568, y: 98))
        p.addLine(to: CGPoint(x: 557, y: 87))
        p.addLine(to: CGPoint(x: 466, y: 127))
        p.addLine(to: CGPoint(x: 428, y: 118))
        p.addLine(to: CGPoint(x: 312, y: 126))
        p.addLine(to: CGPoint(x: 249, y: 90))
        p.close()
        return p
    }

    static func tick0() -> UIBezierPath {
        let p = UIBezierPath()
        p.move(to: CGPoint(x: 663, y: 175))
        p.addLine(to: CGPoint(x: 660, y: 173))
        p.addLine(to: CGPoint(x: 652, y: 171))
        p.addLine(to: CGPoint(x: 645, y: 171))
        p.addLine(to: CGPoint(x: 644, y: 172))
        p.addLine(to: CGPoint(x: 615, y: 174))
        p.addLine(to: CGPoint(x: 608, y: 176))
        p.addLine(to: CGPoint(x: 601, y: 185))
        p.addLine(to: CGPoint(x: 600, y: 189))
        p.addLine(to: CGPoint(x: 597, y: 192))
        p.addLine(to: CGPoint(x: 594, y: 192))
        p.addLine(to: CGPoint(x: 590, y: 197))
        p.addLine(to: CGPoint(x: 590, y: 205))
        p.addLine(to: CGPoint(x: 592, y: 213))
        p.addLine(to: CGPoint(x: 594, y: 214))
        p.addLine(to: CGPoint(x: 610, y: 213))
        p.addLine(to: CGPoint(x: 612, y: 211))
        p.addLine(to: CGPoint(x: 612, y: 208))
        p.addLine(to: CGPoint(x: 615, y: 205))
        p.addLine(to: CGPoint(x: 621, y: 204))
        p.addLine(to: CGPoint(x: 623, y: 199))
        p.addLine(to: CGPoint(x: 627, y: 196))
        p.addLine(to: CGPoint(x: 639, y: 196))
        p.addLine(to: CGPoint(x: 652, y: 192))
        p.addLine(to: CGPoint(x: 661, y: 192))
        p.addLine(to: CGPoint(x: 664, y: 188))
        p.addLine(to: CGPoint(x: 664, y: 177))
        p.close()
        return p
    }

    static func tick1() -> UIBezierPath {
        let p = UIBezierPath()
        p.move(to: CGPoint(x: 122, y: 218))
        p.addLine(to: CGPoint(x: 122, y: 231))
        p.addLine(to: CGPoint(x: 125, y: 235))
        p.addLine(to: CGPoint(x: 132, y: 236))
        p.addLine(to: CGPoint(x: 136, y: 240))
        p.addLine(to: CGPoint(x: 151, y: 240))
        p.addLine(to: CGPoint(x: 152, y: 241))
        p.addLine(to: CGPoint(x: 161, y: 242))
        p.addLine(to: CGPoint(x: 164, y: 244))
        p.addLine(to: CGPoint(x: 174, y: 244))
        p.addLine(to: CGPoint(x: 177, y: 246))
        p.addLine(to: CGPoint(x: 183, y: 246))
        p.addLine(to: CGPoint(x: 187, y: 244))
        p.addLine(to: CGPoint(x: 188, y: 242))
        p.addLine(to: CGPoint(x: 189, y: 230))
        p.addLine(to: CGPoint(x: 188, y: 229))
        p.addLine(to: CGPoint(x: 187, y: 220))
        p.addLine(to: CGPoint(x: 185, y: 219))
        p.addLine(to: CGPoint(x: 178, y: 218))
        p.addLine(to: CGPoint(x: 173, y: 215))
        p.addLine(to: CGPoint(x: 167, y: 215))
        p.addLine(to: CGPoint(x: 162, y: 213))
        p.addLine(to: CGPoint(x: 136, y: 213))
        p.addLine(to: CGPoint(x: 135, y: 214))
        p.addLine(to: CGPoint(x: 126, y: 215))
        p.close()
        return p
    }

    /// 眼睛椭圆：(cx, cy, rx, ry) viewBox 坐标
    static let eyes: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (339, 253, 20, 19),
        (486, 253, 16, 18),
    ]

    /// 双眼合成一个路径（一次眨眼动画作用两只眼）。
    static func eyesPath() -> UIBezierPath {
        let p = UIBezierPath()
        for (cx, cy, rx, ry) in eyes {
            p.append(UIBezierPath(ovalIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)))
        }
        return p
    }

    /// 尾巴中线 x（y 从 310 起逐点 -1）
    static let tailCX: [CGFloat] = [
        1019,1019.2,1019.4,1019.6,1019.8,1020,1020.3,1020.7,1021,1021.4,1021.8,1022.2,
        1022.6,1023,1023.5,1024,1024.4,1024.8,1025.2,1025.6,1025.9,1026.2,1026.5,1026.9,
        1027.2,1027.5,1027.8,1028.1,1028.3,1028.6,1028.8,1029.1,1029.5,1029.8,1030.1,1030.4,
        1030.8,1031.1,1031.5,1031.9,1032.3,1032.7,1033.2,1033.6,1034.1,1034.5,1035,1035.4,
        1035.9,1036.3,1036.7,1037.1,1037.4,1037.8,1038.1,1038.6,1039.1,1039.6,1040.1,1040.6,
        1041.1,1041.5,1042,1042.5,1042.9,1043.4,1043.8,1044.3,1044.7,1045.2,1045.6,1046.1,
        1046.6,1047,1047.5,1047.9,1048.2,1048.4,1048.7,1048.9,1049.2,1049.4,1049.6,1049.8,
        1050,1050.3,1050.5,1050.7,1050.9,1051.1,1051.3,1051.5,1051.8,1052,1052.2,1052.5,
        1052.7,1052.9,1053.2,1053.4,1053.6,1053.8,1054,1054.3,1054.5,1054.8,1055,1055.3,
        1055.6,1055.9,1056.2,1056.5,1056.7,1057,1057.2,1057.4,1057.6,1057.9,1058,1058.2,
        1058.4,1058.6,1058.8,1058.9,1059.1,1059.2,1059.4,1059.5,1059.5,1059.6,1059.6,1059.7,
        1059.7,1059.8,1059.8,1059.9,1059.9,1060,1060,1060.1,1060.1,1060.2,1060.2,1060.3,
        1060.4,1060.5,1060.5,1060.6,1060.7,1060.7,1060.8,1060.9,1061,1061,1061,1061.1,
        1061.1,1061.2,1061.2,1061.2,1061.3,1061.3,1061.3,1061.3,1061.3,1061.3,1061.3,1061.3,
        1061.2,1061.2,1061.1,1061.1,1061,1061,1060.9,1060.8,1060.7,1060.6,1060.5,1060.5,
        1060.4,1060.3,1060.2,1060.1,1060,1059.8,1059.7,1059.5,1059.3,1059.1,1058.9,1058.6,
        1058.4,1058.1,1057.9,1057.6,1057.3,1057.1,1056.9,1056.7,1056.5,1056.3,1056.1,1056,
        1055.8,1055.6,1055.5,1055.3,1055.2,1055,1054.8,1054.7,1054.5,1054.4,1054.2,1054.1,
        1054,1053.8,1053.6,1053.4,1053.1,1052.9,1052.7,1052.4,1052.1,1051.9,1051.6,1051.4,
        1051.1,1050.9,1050.8,1050.6,1050.5,1050.3,1050.1,1049.9,1049.7,1049.4,1049.1,1048.9,
        1048.6,1048.3,1048,1047.8,1047.5,1047.2,1046.9,1046.5,1046.2,1045.8,1045.3,1044.9,
        1044.4,1044,1043.5,1043,1042.4,1041.8,1041,1040.2,1039.4,1038.5,1037.7,1036.9,
        1036.1,1035.3,1034.5,1033.7,1032.9,1032.1,1031.4,1030.6,1029.9,1029.1,1028.4,1027.6,
        1027,1026.4,1026,1025.7,1025.4,1025,1024.7,1024.3,1024,1023.6,1023.2,1022.9,
        1022.5,1022.2,1021.9,1021.5,1021.3,1021,1020.6,1020.4,1020,1019.7,1019.5,1019.2,
        1018.9,1018.6,1018.5,1018.3,1018.1,1018,1017.9,1017.8,1017.7,1017.6,1017.5,
    ]

    /// 尾巴路径：dx 为摆动偏移（HTML 同款公式 x = cx + dx·f²）。
    static func tail(dx: CGFloat) -> UIBezierPath {
        let p = UIBezierPath()
        let n = tailCX.count
        for i in 0..<n {
            let y = 310 - CGFloat(i)
            let f = CGFloat(i) / CGFloat(n - 1)
            let x = tailCX[i] + dx * f * f
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        return p
    }
}

// MARK: - Voice Cat Bubble Card

/// [T-voice-cat-card 10-16 醒醒] 语音播放卡片：占满消息列宽，复刻
/// voice_player_cat_back_minimal_opt.html —— 小猫背影（固定黑）+ 状态点 +
/// 人设名标题 + 跑马灯文案（AI 实际 TTS 文案，来自侧车 txt）+ 圆播放键 +
/// 波形进度（可拖动）+ 时间（点按切已播/剩余）+ 倍速。
/// 颜色全部取 AppearanceStudio 主题快照；播放控制全部对接 GlobalAudioPlayer。
final class VoiceCatBubbleCardView: UIView, UIGestureRecognizerDelegate {

    static let cardHeight: CGFloat = 110

    // MARK: - Metrics

    private enum M {
        static let padH: CGFloat = 16
        static let padTop: CGFloat = 12
        static let upperH: CGFloat = 56
        static let midGap: CGFloat = 6
        static let lowerH: CGFloat = 26
        static let catW: CGFloat = 62
        static let canvasW: CGFloat = 80
        static let canvasH: CGFloat = 56
        static let metaGap: CGFloat = 13
        static let playSize: CGFloat = 36
        static let playTrail: CGFloat = 10
        static let timeW: CGFloat = 38
        static let speedW: CGFloat = 52
        static let rowGap: CGFloat = 10
        static let barGap: CGFloat = 2.5
        static let marqueeUnitGap: CGFloat = 80
        static let marqueeSpeed: CGFloat = 26
        static let livelySpan = 12
    }

    /// 倍速档位（与 HTML 稿一致）。[B09-N05 2026-10-22] 与朗读档位同一条梯子
    /// （VoiceOutputPreferences.speedSteps），两处别再各写一套。
    static let rates: [Float] = VoiceOutputPreferences.speedSteps

    // MARK: - Palette（主题快照；小猫固定黑）

    private let cardBg = AppearanceStudio.uiColorSnapshot(.surface, scope: .chat)
    private let lineColor = AppearanceStudio.uiColorSnapshot(.border, scope: .chat)
    private let textColor = AppearanceStudio.uiColorSnapshot(.primaryText, scope: .chat)
    private let subTextColor = AppearanceStudio.uiColorSnapshot(.secondaryText, scope: .chat)
    private let playIconColor = AppearanceStudio.uiColorSnapshot(.surface, scope: .chat)
    private static let catInk = UIColor(red: 0x1D / 255.0, green: 0x1B / 255.0, blue: 0x19 / 255.0, alpha: 1)

    // MARK: - Inputs

    private let fileURL: URL?
    private let soulName: String
    private let voiceText: String
    /// [B09-V3 2026-10-22] Shown when the audio file is gone but the transcript
    /// sidecar survived (the storage cleanup promises "their text stays"). The
    /// card used to be completely inert in that state: no marquee, and the play
    /// button's first line was `guard let url = fileURL else { return }`.
    private let missingAudioText: String?
    private var knownDuration: Double

    // MARK: - Runtime state

    private var isPlayingFile = false
    private var showRemaining = false
    private var passedCount = 0
    private var lastPaintedPassed = -1
    private var lastLivelyRange: Range<Int>? = nil
    private var lastWaveWidth: CGFloat = -1
    private var lastTime: Double = 0
    private var lastDuration: Double = 0
    private var lastActiveURL: URL?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Subviews

    private let cardView = UIView()
    private let catHost = UIView()
    private let breatheLayer = CALayer()
    private let swayLayer = CALayer()
    private var eyesLayer: CAShapeLayer?
    private var tailLayer: CAShapeLayer?
    private var noteLabels: [UILabel] = []
    private let kickerDot = UIView()
    private let kickerLabel = UILabel()
    private let titleLabel = UILabel()
    private let marqueeClip = UIView()
    private let marqueeTrack = UIView()
    private var marqueeUnits: [UILabel] = []
    private let playButton = UIButton(type: .custom)
    private let currentLabel = UILabel()
    private let totalLabel = UILabel()
    private let speedButton = UIButton(type: .custom)
    private let waveHost = UIView()
    private var barLayers: [CALayer] = []

    /// [audit-A8] 续听徽章（kicker 行右侧小胶囊："续听 mm:ss"）。
    private let resumeBadge = UIView()
    private let resumeLabel = UILabel()
    private var resumeBadgeWidth: CGFloat = 62

    // MARK: - Init

    init(frame: CGRect, fileURL: URL?, duration: Double, soulName: String, voiceText: String,
         missingAudioText: String? = nil) {
        self.fileURL = fileURL
        self.soulName = soulName
        self.voiceText = voiceText
        self.missingAudioText = missingAudioText
        self.knownDuration = duration
        super.init(frame: frame)
        backgroundColor = .clear
        buildUI()
        bindPlayer()
        refreshResumeBadge()
        applyMissingAudioState()
        if knownDuration <= 0 { probeDuration() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Build

    private func buildUI() {
        cardView.backgroundColor = cardBg
        cardView.layer.cornerRadius = 20
        cardView.layer.cornerCurve = .continuous
        cardView.layer.borderWidth = 0.6
        cardView.layer.borderColor = lineColor.withAlphaComponent(0.9).cgColor
        addSubview(cardView)

        buildCat()
        buildMeta()
        buildLower()

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleWavePan(_:)))
        pan.delegate = self
        waveHost.addGestureRecognizer(pan)

        startBreathing()
        startBlinking()
    }

    private func buildCat() {
        catHost.clipsToBounds = false
        cardView.addSubview(catHost)

        let canvas = CGRect(x: 0, y: 0, width: M.canvasW, height: M.canvasH)
        // 画布 80x56 在 62 宽的猫区里水平居中（x 起点 -9），锚点取画布底部中心
        breatheLayer.bounds = canvas
        breatheLayer.anchorPoint = CGPoint(x: 0.5, y: 0.92)
        breatheLayer.position = CGPoint(x: M.catW / 2, y: canvas.height * 0.92)
        catHost.layer.addSublayer(breatheLayer)

        swayLayer.bounds = canvas
        swayLayer.anchorPoint = CGPoint(x: 0.5, y: 0.92)
        swayLayer.position = CGPoint(x: M.catW / 2, y: canvas.height * 0.92)
        breatheLayer.addSublayer(swayLayer)

        var t = VoiceCatArt.canvasTransform()

        let bodyLayer = CAShapeLayer()
        bodyLayer.path = VoiceCatArt.body().cgPath.copy(using: &t)
        bodyLayer.fillColor = Self.catInk.cgColor
        swayLayer.addSublayer(bodyLayer)

        let ticks = UIBezierPath()
        ticks.append(VoiceCatArt.tick0())
        ticks.append(VoiceCatArt.tick1())
        let tickLayer = CAShapeLayer()
        tickLayer.path = ticks.cgPath.copy(using: &t)
        tickLayer.fillColor = Self.catInk.cgColor
        swayLayer.addSublayer(tickLayer)

        let eyes = CAShapeLayer()
        eyes.path = VoiceCatArt.eyesPath().cgPath.copy(using: &t)
        eyes.fillColor = UIColor.white.cgColor
        eyes.bounds = canvas
        eyes.anchorPoint = CGPoint(x: 0.657, y: 0.30)
        eyes.position = CGPoint(x: canvas.width * 0.657, y: canvas.height * 0.30)
        swayLayer.addSublayer(eyes)
        eyesLayer = eyes

        let tail = CAShapeLayer()
        tail.path = VoiceCatArt.tail(dx: 0).cgPath.copy(using: &t)
        tail.fillColor = nil
        tail.strokeColor = Self.catInk.cgColor
        tail.lineWidth = 150 * (M.canvasW / VoiceCatArt.box.width)
        tail.lineCap = .round
        tail.lineJoin = .round
        swayLayer.addSublayer(tail)
        tailLayer = tail

        let topY = M.canvasH - 0.72 * M.canvasH - 16
        for (i, symbol) in ["♪", "♫"].enumerated() {
            let label = UILabel()
            label.text = symbol
            label.font = .systemFont(ofSize: 13)
            label.textColor = Self.catInk
            label.frame = CGRect(x: (i == 0 ? 0.30 : 0.62) * M.catW, y: topY, width: 16, height: 16)
            label.layer.opacity = 0
            catHost.addSubview(label)
            noteLabels.append(label)
        }
    }

    private func buildMeta() {
        kickerDot.backgroundColor = textColor
        kickerDot.layer.cornerRadius = 3
        cardView.addSubview(kickerDot)

        kickerLabel.font = Self.serifFont(size: 10, weight: .semibold)
        kickerLabel.textColor = subTextColor
        setKicker("VOICE MESSAGE")
        cardView.addSubview(kickerLabel)

        titleLabel.font = Self.serifFont(size: 18, weight: .bold)
        titleLabel.textColor = textColor
        titleLabel.attributedText = NSAttributedString(
            string: "\(soulName)给你留了言",
            attributes: [
                .font: Self.serifFont(size: 18, weight: .bold),
                .foregroundColor: textColor,
                .kern: 1.4,
            ])
        titleLabel.lineBreakMode = .byTruncatingTail
        cardView.addSubview(titleLabel)

        marqueeClip.clipsToBounds = true
        cardView.addSubview(marqueeClip)
        marqueeTrack.backgroundColor = .clear
        marqueeClip.addSubview(marqueeTrack)
        buildMarquee()

        // [audit-A8] 续听徽章：这条语音上次没听完时，kicker 行右侧亮"续听 mm:ss"。
        resumeBadge.backgroundColor = textColor.withAlphaComponent(0.06)
        resumeBadge.layer.cornerRadius = 7
        resumeBadge.isHidden = true
        cardView.addSubview(resumeBadge)
        resumeLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        resumeLabel.textColor = subTextColor
        resumeLabel.textAlignment = .center
        resumeBadge.addSubview(resumeLabel)
    }

    private func setKicker(_ text: String) {
        kickerLabel.attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: Self.serifFont(size: 10, weight: .semibold),
                .foregroundColor: subTextColor,
                .kern: 3.0,
            ])
    }

    private func buildMarquee() {
        guard !voiceText.isEmpty else { return }
        let font = Self.serifFont(size: 11.5, weight: .regular)
        for _ in 0..<2 {
            let unit = UILabel()
            unit.font = font
            unit.textColor = subTextColor
            unit.text = voiceText
            unit.sizeToFit()
            marqueeTrack.addSubview(unit)
            marqueeUnits.append(unit)
        }
        guard let first = marqueeUnits.first else { return }
        let unitW = first.bounds.width + M.marqueeUnitGap
        for (i, unit) in marqueeUnits.enumerated() {
            unit.frame = CGRect(x: CGFloat(i) * unitW, y: 0, width: unit.bounds.width, height: unit.bounds.height)
        }
        marqueeTrack.frame = CGRect(x: 0, y: 0, width: unitW + first.bounds.width, height: first.bounds.height)
        let anim = CABasicAnimation(keyPath: "transform.translation.x")
        anim.fromValue = -unitW
        anim.toValue = 0
        anim.duration = CFTimeInterval(unitW / M.marqueeSpeed)
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        marqueeTrack.layer.add(anim, forKey: "marqueeScroll")
    }

    private func buildLower() {
        currentLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        currentLabel.textColor = subTextColor
        currentLabel.text = Self.format(0)
        currentLabel.isUserInteractionEnabled = true
        currentLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTimeTap)))
        cardView.addSubview(currentLabel)

        totalLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        totalLabel.textColor = subTextColor
        totalLabel.textAlignment = .right
        totalLabel.text = Self.formatUnknownAware(knownDuration)
        cardView.addSubview(totalLabel)

        speedButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        speedButton.setTitleColor(subTextColor, for: .normal)
        speedButton.setTitle(Self.rateLabel(GlobalAudioPlayer.shared.rate), for: .normal)
        speedButton.backgroundColor = textColor.withAlphaComponent(0.06)
        speedButton.layer.cornerRadius = M.lowerH / 2
        speedButton.addTarget(self, action: #selector(handleSpeedTap), for: .touchUpInside)
        cardView.addSubview(speedButton)

        waveHost.backgroundColor = .clear
        cardView.addSubview(waveHost)

        playButton.backgroundColor = textColor
        playButton.layer.cornerRadius = M.playSize / 2
        playButton.clipsToBounds = true
        playButton.tintColor = playIconColor
        playButton.setImage(Self.iconImage("play.fill"), for: .normal)
        playButton.addTarget(self, action: #selector(handlePlayTap), for: .touchUpInside)
        playButton.addTarget(self, action: #selector(playButtonDown), for: [.touchDown, .touchDragEnter])
        playButton.addTarget(self, action: #selector(playButtonUp), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        cardView.addSubview(playButton)
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let W = bounds.width
        guard W > 40 else { return }
        cardView.frame = bounds

        catHost.frame = CGRect(x: M.padH, y: M.padTop, width: M.catW, height: M.upperH)
        let playX = W - M.padH - M.playSize
        playButton.frame = CGRect(x: playX, y: M.padTop + (M.upperH - M.playSize) / 2, width: M.playSize, height: M.playSize)

        let metaX = M.padH + M.catW + M.metaGap
        let metaW = max(60, playX - M.playTrail - metaX)
        kickerDot.frame = CGRect(x: metaX, y: M.padTop + 3, width: 6, height: 6)
        // [audit-A8] 续听徽章占 kicker 行右侧；亮出时收窄 kicker 防撞。
        let badgeX = playX - M.playTrail - resumeBadgeWidth
        resumeBadge.frame = CGRect(x: badgeX, y: M.padTop + 1, width: resumeBadgeWidth, height: 14)
        resumeLabel.frame = resumeBadge.bounds
        let kickerW = resumeBadge.isHidden
            ? max(40, metaW - 13)
            : max(40, min(metaW - 13, badgeX - 6 - (metaX + 13)))
        kickerLabel.frame = CGRect(x: metaX + 13, y: M.padTop, width: kickerW, height: 13)
        titleLabel.frame = CGRect(x: metaX, y: M.padTop + 15, width: metaW, height: 22)
        marqueeClip.frame = CGRect(x: metaX, y: M.padTop + 39, width: metaW, height: 15)
        if let unit = marqueeUnits.first {
            marqueeTrack.frame.origin = CGPoint(x: 0, y: (15 - unit.bounds.height) / 2)
        }

        let lowerY = M.padTop + M.upperH + M.midGap
        currentLabel.frame = CGRect(x: M.padH, y: lowerY, width: M.timeW, height: M.lowerH)
        let speedX = W - M.padH - M.speedW
        speedButton.frame = CGRect(x: speedX, y: lowerY, width: M.speedW, height: M.lowerH)
        let totalX = speedX - M.rowGap - M.timeW
        totalLabel.frame = CGRect(x: totalX, y: lowerY, width: M.timeW, height: M.lowerH)
        let waveX = M.padH + M.timeW + M.rowGap
        let waveW = max(20, totalX - M.rowGap - waveX)
        waveHost.frame = CGRect(x: waveX, y: lowerY, width: waveW, height: M.lowerH)

        if abs(waveW - lastWaveWidth) > 0.5 {
            lastWaveWidth = waveW
            rebuildWave(waveW: waveW)
        }
    }

    private func rebuildWave(waveW: CGFloat) {
        for bar in barLayers { bar.removeFromSuperlayer() }
        barLayers.removeAll()
        lastPaintedPassed = -1
        lastLivelyRange = nil

        let gap = M.barGap
        let n = max(18, min(64, Int((waveW + gap) / (2.0 + gap))))
        guard n > 1 else { return }
        let barW = max(1.5, (waveW - gap * CGFloat(n - 1)) / CGFloat(n))
        for i in 0..<n {
            let raw = abs(sin(Double(i) * 0.77) * 0.44 + cos(Double(i) * 0.29) * 0.31 + sin(Double(i) * 0.13) * 0.25)
            let h = 4 + CGFloat((raw * 20).rounded())
            let bar = CALayer()
            bar.frame = CGRect(x: CGFloat(i) * (barW + gap), y: (M.lowerH - h) / 2, width: barW, height: h)
            bar.cornerRadius = barW / 2
            bar.backgroundColor = textColor.withAlphaComponent(0.12).cgColor
            waveHost.layer.addSublayer(bar)
            barLayers.append(bar)
        }
    }

    // MARK: - Player binding

    private func bindPlayer() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let gp = GlobalAudioPlayer.shared
            gp.$isPlaying
                .combineLatest(gp.$activeFileURL, gp.$duration)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] playing, active, dur in
                    self?.applyPlaybackState(playing: playing, activeURL: active, duration: dur)
                }
                .store(in: &self.cancellables)
            gp.$currentTime
                .combineLatest(gp.$activeFileURL, gp.$duration)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] time, active, dur in
                    self?.applyProgress(time: time, activeURL: active, duration: dur)
                }
                .store(in: &self.cancellables)
            gp.$rate
                .receive(on: DispatchQueue.main)
                .sink { [weak self] rate in
                    self?.applyRate(rate)
                }
                .store(in: &self.cancellables)
            self.applyPlaybackState(playing: gp.isPlaying, activeURL: gp.activeFileURL, duration: gp.duration)
            self.applyProgress(time: gp.currentTime, activeURL: gp.activeFileURL, duration: gp.duration)
            self.applyRate(gp.rate)
        }
    }

    private func applyPlaybackState(playing: Bool, activeURL: URL?, duration: Double) {
        let active = fileURL != nil && activeURL == fileURL
        isPlayingFile = playing && active
        playButton.setImage(Self.iconImage(isPlayingFile ? "pause.fill" : "play.fill"), for: .normal)
        // [B09-V3 2026-10-22] Keep the "audio removed" note: the global player
        // re-publishes state on every tick, and this line used to stomp the
        // note back to "VOICE MESSAGE" one frame after it was set.
        if fileURL != nil {
            setKicker(isPlayingFile ? "NOW PLAYING" : "VOICE MESSAGE")
        }
        setDotBlinking(isPlayingFile)
        setCatGroove(isPlayingFile)
        setNotesFloating(isPlayingFile)
        if active, duration > 0, abs(duration - knownDuration) > 0.05 {
            knownDuration = duration
        }
        totalLabel.text = Self.formatUnknownAware(knownDuration)
        if isPlayingFile {
            updateLively(passed: passedCount, playing: true)
        } else {
            updateLively(passed: 0, playing: false)
        }
        refreshResumeBadge()
    }

    private func applyProgress(time: Double, activeURL: URL?, duration: Double) {
        let active = fileURL != nil && activeURL == fileURL
        lastTime = time
        lastActiveURL = activeURL
        let dur = active ? max(duration, knownDuration) : knownDuration
        let frac = (active && dur > 0) ? min(max(time / dur, 0), 1) : 0
        let count = barLayers.count
        let passed = count > 0 ? min(count, Int((Double(count) * frac).rounded(.down))) : 0
        passedCount = passed
        if passed != lastPaintedPassed {
            lastPaintedPassed = passed
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (i, bar) in barLayers.enumerated() {
                bar.backgroundColor = (i < passed ? textColor : textColor.withAlphaComponent(0.12)).cgColor
            }
            CATransaction.commit()
            updateLively(passed: passed, playing: isPlayingFile)
        }
        lastDuration = dur
        refreshCurrentLabel()
    }

    private func refreshCurrentLabel() {
        let active = fileURL != nil && lastActiveURL == fileURL
        let dur = active ? max(lastDuration, knownDuration) : knownDuration
        if active {
            currentLabel.text = showRemaining
                ? "-" + Self.format(max(dur - lastTime, 0))
                : Self.format(lastTime)
        } else {
            currentLabel.text = showRemaining ? "-" + Self.format(knownDuration) : Self.format(0)
        }
    }

    /// [audit-A8] 续听徽章显隐 + 文案（"续听 mm:ss"）。与 resumePosition 同判据，
    /// 保证"有徽章 = 点播放真能续"。
    private func refreshResumeBadge() {
        guard !isPlayingFile, let url = fileURL else {
            resumeBadge.isHidden = true
            setNeedsLayout()
            return
        }
        let key = url.deletingPathExtension().lastPathComponent
        if let pos = VoiceBubblePlaybackState.resumePosition(for: key, duration: knownDuration) {
            resumeLabel.text = AppLocalized("Resume \(Self.format(pos))")
            let w = resumeLabel.sizeThatFits(CGSize(width: 120, height: 14)).width + 14
            resumeBadgeWidth = max(44, w.rounded())
            resumeBadge.isHidden = false
        } else {
            resumeBadge.isHidden = true
        }
        setNeedsLayout()
    }

    private func applyRate(_ rate: Float) {
        speedButton.setTitle(Self.rateLabel(rate), for: .normal)
    }

    private func probeDuration() {
        guard let url = fileURL else { return }
        Task.detached(priority: .utility) {
            guard let p = try? AVAudioPlayer(contentsOf: url), p.duration > 0 else { return }
            let d = p.duration
            await MainActor.run { [weak self] in
                guard let self, self.knownDuration <= 0 else { return }
                self.knownDuration = d
                self.totalLabel.text = Self.format(d)
                self.refreshResumeBadge()
            }
        }
    }

    // MARK: - Lively bars

    private func updateLively(passed: Int, playing: Bool) {
        guard playing else {
            if lastLivelyRange != nil {
                lastLivelyRange = nil
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for bar in barLayers {
                    bar.removeAnimation(forKey: "lively")
                    bar.transform = CATransform3DIdentity
                }
                CATransaction.commit()
            }
            return
        }
        let count = barLayers.count
        let start = min(passed, count)
        let end = min(passed + M.livelySpan, count)
        let range = start..<end
        if range == lastLivelyRange { return }
        let old = lastLivelyRange
        lastLivelyRange = range
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let old = old {
            for i in old where !range.contains(i) { stopLively(barLayers[i]) }
        }
        for i in range where old?.contains(i) != true { startLively(barLayers[i], index: i) }
        CATransaction.commit()
    }

    private func startLively(_ bar: CALayer, index: Int) {
        guard bar.animation(forKey: "lively") == nil else { return }
        let a = CABasicAnimation(keyPath: "transform.scale.y")
        a.fromValue = 0.58
        a.toValue = 1.08
        a.duration = 0.32 + Double(index % 6) * 0.075
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timeOffset = -Double(index % 11) * 0.065
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        bar.add(a, forKey: "lively")
    }

    private func stopLively(_ bar: CALayer) {
        bar.removeAnimation(forKey: "lively")
        bar.transform = CATransform3DIdentity
    }

    // MARK: - Cat animations

    private func startBreathing() {
        let a = CAKeyframeAnimation(keyPath: "transform")
        var up = CATransform3DMakeScale(1.012, 1.012, 1)
        up = CATransform3DTranslate(up, 0, -1, 0)
        a.values = [NSValue(caTransform3D: CATransform3DIdentity), NSValue(caTransform3D: up), NSValue(caTransform3D: CATransform3DIdentity)]
        a.keyTimes = [0, 0.5, 1]
        a.duration = 3.4
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breatheLayer.add(a, forKey: "breathe")
    }

    private func startBlinking() {
        guard let eyes = eyesLayer else { return }
        let a = CAKeyframeAnimation(keyPath: "transform")
        let squint = CATransform3DMakeScale(1, 0.08, 1)
        a.values = [NSValue(caTransform3D: CATransform3DIdentity), NSValue(caTransform3D: CATransform3DIdentity), NSValue(caTransform3D: squint), NSValue(caTransform3D: squint), NSValue(caTransform3D: CATransform3DIdentity), NSValue(caTransform3D: CATransform3DIdentity)]
        a.keyTimes = [0, 0.91, 0.94, 0.945, 0.95, 1]
        a.duration = 4.6
        a.repeatCount = .infinity
        eyes.add(a, forKey: "blink")
    }

    private func setCatGroove(_ on: Bool) {
        if on {
            if swayLayer.animation(forKey: "groove") == nil {
                var left = CATransform3DMakeRotation(-1 * CGFloat.pi / 180, 0, 0, 1)
                left = CATransform3DTranslate(left, -1.6, 0, 0)
                var right = CATransform3DMakeRotation(1 * CGFloat.pi / 180, 0, 0, 1)
                right = CATransform3DTranslate(right, 1.6, 0, 0)
                let a = CAKeyframeAnimation(keyPath: "transform")
                a.values = [NSValue(caTransform3D: left), NSValue(caTransform3D: right), NSValue(caTransform3D: left)]
                a.keyTimes = [0, 0.5, 1]
                a.duration = 1.1
                a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                swayLayer.add(a, forKey: "groove")
            }
            startTailWag()
        } else {
            swayLayer.removeAnimation(forKey: "groove")
            swayLayer.transform = CATransform3DIdentity
            tailLayer?.removeAnimation(forKey: "wag")
        }
    }

    private func startTailWag() {
        guard let tail = tailLayer, tail.animation(forKey: "wag") == nil else { return }
        var t = VoiceCatArt.canvasTransform()
        let offsets: [CGFloat] = [0, 34, 0, -34, 0]
        var paths: [CGPath] = []
        for dx in offsets {
            if let p = VoiceCatArt.tail(dx: dx).cgPath.copy(using: &t) {
                paths.append(p)
            }
        }
        guard paths.count == offsets.count else { return }
        let a = CAKeyframeAnimation(keyPath: "path")
        a.values = paths.map { $0 as Any }
        a.keyTimes = [0, 0.25, 0.5, 0.75, 1]
        a.duration = 1.15
        a.repeatCount = .infinity
        tail.add(a, forKey: "wag")
    }

    private func setNotesFloating(_ on: Bool) {
        for (i, label) in noteLabels.enumerated() {
            if on {
                guard label.layer.animation(forKey: "noteFloat") == nil else { continue }
                let move = CAKeyframeAnimation(keyPath: "transform.translation.y")
                move.values = [NSNumber(value: 6.0), NSNumber(value: -26.0)]
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [NSNumber(value: 0.0), NSNumber(value: 0.9), NSNumber(value: 0.0)]
                fade.keyTimes = [0, 0.25, 1]
                let spin = CAKeyframeAnimation(keyPath: "transform.rotation.z")
                spin.values = [NSNumber(value: -8 * Double.pi / 180), NSNumber(value: 10 * Double.pi / 180)]
                let scale = CAKeyframeAnimation(keyPath: "transform.scale")
                scale.values = [NSNumber(value: 0.7), NSNumber(value: 1.05)]
                let group = CAAnimationGroup()
                group.animations = [move, fade, spin, scale]
                group.duration = 1.9
                group.repeatCount = .infinity
                group.timingFunction = CAMediaTimingFunction(name: .easeOut)
                group.beginTime = CACurrentMediaTime() + (i == 1 ? 0.65 : 0)
                label.layer.add(group, forKey: "noteFloat")
            } else {
                label.layer.removeAnimation(forKey: "noteFloat")
            }
        }
    }

    private func setDotBlinking(_ on: Bool) {
        if on {
            guard kickerDot.layer.animation(forKey: "dotblink") == nil else { return }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.35
            fade.toValue = 1.0
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.85
            scale.toValue = 1.15
            let group = CAAnimationGroup()
            group.animations = [fade, scale]
            group.duration = 0.7
            group.autoreverses = true
            group.repeatCount = .infinity
            kickerDot.layer.add(group, forKey: "dotblink")
        } else {
            kickerDot.layer.removeAnimation(forKey: "dotblink")
        }
    }

    // MARK: - Interactions

    /// [B09-V3 2026-10-22] Audio deleted, transcript still here: keep the card
    /// readable and say why it cannot play, instead of a play button that does
    /// nothing when tapped.
    private func applyMissingAudioState() {
        guard fileURL == nil else { return }
        if let note = missingAudioText {
            setKicker(note)
        }
        playButton.isEnabled = false
        playButton.alpha = 0.35
        speedButton.isEnabled = false
        speedButton.alpha = 0.35
        totalLabel.text = Self.formatUnknownAware(0)
    }

    @objc private func handlePlayTap() {
        guard let url = fileURL else { return }
        let player = GlobalAudioPlayer.shared
        if player.isActive(url: url) {
            player.togglePlayPause()
        } else {
            player.play(url: url)
        }
    }

    @objc private func playButtonDown() {
        UIView.animate(withDuration: 0.14) { self.playButton.transform = CGAffineTransform(scaleX: 0.92, y: 0.92) }
    }

    @objc private func playButtonUp() {
        UIView.animate(withDuration: 0.18) { self.playButton.transform = .identity }
    }

    @objc private func handleTimeTap() {
        showRemaining.toggle()
        refreshCurrentLabel()
    }

    @objc private func handleSpeedTap() {
        let current = GlobalAudioPlayer.shared.rate
        let index = Self.rates.firstIndex(where: { abs($0 - current) < 0.001 }) ?? 1
        let next = Self.rates[(index + 1) % Self.rates.count]
        GlobalAudioPlayer.shared.setRate(next)
    }

    @objc private func handleWavePan(_ gesture: UIPanGestureRecognizer) {
        guard let url = fileURL else { return }
        let player = GlobalAudioPlayer.shared
        let active = player.isActive(url: url)
        let dur = active && player.duration > 0 ? player.duration : knownDuration
        guard dur > 0 else { return }
        let x = gesture.location(in: waveHost).x
        let frac = min(max(x / max(waveHost.bounds.width, 1), 0), 1)
        let target = dur * frac
        switch gesture.state {
        case .began:
            if !active { player.play(url: url) }
            player.currentTime = target
        case .changed:
            player.currentTime = target
        default:
            player.seek(to: target)
        }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: pan.view)
        return abs(velocity.x) > abs(velocity.y)
    }

    // MARK: - Helpers

    /// [B09-L02 2026-10-22] Unknown duration (an MP3 whose length the composer
    /// couldn't measure) rendered as "0:00", i.e. the card claimed the message
    /// was zero seconds long until the async probe landed. Show a placeholder
    /// instead so "not known yet" reads differently from "empty".
    static func formatUnknownAware(_ t: Double) -> String {
        guard t.isFinite, t > 0 else { return "--:--" }
        return format(t)
    }

    static func format(_ t: Double) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        let total = Int(t.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func rateLabel(_ rate: Float) -> String {
        if rate == rate.rounded() { return "\(Int(rate))×" }
        return String(format: "%g×", Double(rate))
    }

    private static func serifFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = base.fontDescriptor.withDesign(.serif) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return base
    }

    private static func iconImage(_ name: String) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
    }
}
