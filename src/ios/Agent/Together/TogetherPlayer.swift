//
//  TogetherPlayer.swift
//  MinisApp
//
//  一起听 · 音频引擎。
//
//  为什么不复用 GlobalAudioPlayer：那是语音气泡的引擎，逻辑绑在
//  "tts-xxx" 文件名和续听上，音乐需要的是换歌从头、长播、精确 seek。
//  两个引擎各管各的，锁屏那一层（VoiceNowPlaying）统一路由。
//
//  后台播放不靠这里：AudioSessionCoordinator 管 session，
//  Info.plist 的 audio background mode 已经在。这里只负责"声音从哪出"。
//

import Foundation
import AVFoundation
import Combine

@MainActor
final class TogetherPlayer: ObservableObject {

    static let shared = TogetherPlayer()
    private init() {
        // 一启动就跟：面板关着的时候我换歌，她那边也该听见。
        startFollowing()
    }

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var track: TogetherTrack?

    /// 真有一个播放器活着（暂停也算）。锁屏那一层靠这个判断该听谁的。
    var isActive: Bool { player != nil }

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endToken: NSObjectProtocol?
    private var lastReportedSecond: Double = -1
    private var didSuspendSilentAudio = false
    /// 跟随：上一次处理过的事件 id。
    /// 不能用 revision——播放进度回写也会涨 revision，会把同一条 play 反复触发。
    private var seenEventId = ""
    private var followTimer: Timer?
    /// 语音播报让过路：记下"是我暂停的"，说完才敢自动接着放。
    private var duckedForVoice = false
    private var voiceObservers: [NSObjectProtocol] = []
    private var didStartFollow = false
    private let store = TogetherStore.shared
    private let logger = AppLogger(category: "TogetherPlayer")

    // MARK: 播放

    /// 换一首。position 是起始秒数。
    /// autoplay 为 false 时只装载不发声——恢复"上次是暂停"的状态要用它，
    /// 否则先播一下再暂停，杀进程重开会听到"响一下"，暂停就没粘住。
    func load(_ newTrack: TogetherTrack, from position: Double = 0, autoplay: Bool = true) {
        guard let url = store.audioURL(for: newTrack) else {
            logger.error("[Together] \(newTrack.title) 没有音频文件")
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.error("[Together] 文件不存在：\(url.path)")
            return
        }

        teardown()
        track = newTrack
        duration = newTrack.duration > 0 ? newTrack.duration : 0

        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.actionAtItemEnd = .pause
        player = p

        // 后台被系统续命靠这条静音轨；开始播才拿，停就还回去。
        if !didSuspendSilentAudio {
            BackgroundKeepAliveManager.shared.suspendSilentAudioForMedia()
            didSuspendSilentAudio = true
        }
        AudioSessionCoordinator.shared.begin(.mediaAttachment)

        addPeriodicObserver()
        addEndObserver()

        if position > 0 {
            p.seek(to: CMTime(seconds: position, preferredTimescale: 600),
                   toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = position
        } else {
            currentTime = 0
        }
        if autoplay {
            p.play()
            isPlaying = true
        } else {
            isPlaying = false
        }
        VoiceNowPlaying.shared.refresh()

        // 扫目录进来的歌没有时长，读一次回填，列表就不会一直显示 0:00。
        let trackId = newTrack.id
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let d = try? await item.asset.load(.duration) {
                let secs = d.seconds
                if secs.isFinite, secs > 0 {
                    if self.duration < secs { self.duration = secs }
                    self.store.updateDuration(trackId: trackId, duration: secs)
                }
            }
        }
    }

    func play() {
        guard let p = player else { return }
        if let d = p.currentItem?.duration.seconds, !d.isNaN, d > 0 {
            duration = d
        }
        // 播完了再点播放，从头开始
        if duration > 0, currentTime >= duration - 0.2 {
            p.seek(to: .zero)
            currentTime = 0
        }
        p.play()
        isPlaying = true
        VoiceNowPlaying.shared.refresh()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        reportProgress(force: true)
        VoiceNowPlaying.shared.refresh()
    }

    func toggle() {
        if isPlaying { pause() } else { play() }
    }

    /// 用户亲手按的播放/暂停：本地状态和 state.json 一起改，重启后还是她按的那一下。
    /// AI 派来的 pause / resume 也走 stop 或 followTick，不经过这里，免得把控制权记成用户。
    /// 面板、微控条、同步页、锁屏、控制中心、耳机都走这一个入口，暂停才会真的粘住。
    func userToggle() {
        if isPlaying { userPause() } else { userPlay() }
    }

    /// 用户亲手按的播放（锁屏 play / 耳机播放键）。
    func userPlay() {
        play()
        if isPlaying, !store.load().playback.playing {
            store.setPlaying(true, by: .user)
        }
    }

    /// 用户亲手按的暂停（锁屏 pause / 耳机暂停键）。没在放就不写，免得平白把 by 改成 user。
    func userPause() {
        guard isPlaying else { return }
        pause()
        store.setPlaying(false, by: .user)
    }

    func seek(to seconds: Double) {
        guard let p = player else { return }
        let maxTime = duration > 0 ? min(seconds, duration) : seconds
        let clamped = max(0, maxTime)
        p.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
               toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
        reportProgress(force: true)
        VoiceNowPlaying.shared.refresh()
    }

    /// 锁屏 / 控制中心切歌。和面板、微控条用同一套队列规则。
    func nextTrack() { skipTrack(+1) }
    func previousTrack() { skipTrack(-1) }

    private func skipTrack(_ delta: Int) {
        let lib = store.library()
        guard !lib.tracks.isEmpty else { return }

        let state = store.load()
        let ids = state.playback.queue.isEmpty ? lib.tracks.map { $0.id } : state.playback.queue
        let currentId = track?.id ?? ""

        // 按原队列顺序留下还活着的歌。
        let livePool = ids.compactMap { lib.track(id: $0) }
        guard !livePool.isEmpty else { return }

        if state.playback.shuffle {
            let next = livePool.filter { $0.id != currentId }.randomElement() ?? livePool[0]
            // 只剩当前这一首有效歌：停住，别从头重放。
            if next.id == currentId { return }
            load(next, from: 0)
            store.play(trackId: next.id, at: 0, by: .user)
            return
        }

        // 顺序 / 单曲：从当前在原始队列里的位置出发，按方向逐格走，
        // 跳过已删的孤儿 ID，直到踩到下一首有效歌。
        // 以前用过滤前的下标取歌，取到已删的歌就回落第一首，原地重复当前这首；
        // 删歌后点下一首等于没反应。现在只在整圈走完都没有别的有效歌时，才停在当前这首。
        var picked: TogetherTrack?
        if let start = ids.firstIndex(of: currentId) {
            var step = 1
            while step <= ids.count {
                let pos = ((start + delta * step) % ids.count + ids.count) % ids.count
                if let t = lib.track(id: ids[pos]), t.id != currentId {
                    picked = t
                    break
                }
                step += 1
            }
        } else {
            // 当前歌不在队列里（比如队列刚被清过）：往后取第一首有效，往前取最后一首有效。
            picked = delta >= 0 ? livePool.first : livePool.last
        }

        guard let next = picked else { return }
        load(next, from: 0)
        store.play(trackId: next.id, at: 0, by: .user)
    }

    func stop() {
        teardown()
        track = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        VoiceNowPlaying.shared.refresh()
    }

    /// App 重开时把上次那首装回来。
    /// 只有 state 记着"在放"才真的响——记着暂停就装好不响，别自己冒出来。
    func restoreIfNeeded() {
        guard !isActive else { return }
        let state = store.load()
        guard let t = state.track, t.file != nil else { return }
        // 恢复时按上次记的状态装载：记着在放才出声，记着暂停就只装载不响。
        load(t, from: state.playback.position, autoplay: state.playback.playing)
    }

    // MARK: 跟随 AI
    //
    // 我把遥控器递过去之后，她那边得真的换歌——面板关着也要跟。
    // 不轮询进度（进度是本机播出来的事实，反过来写会把播放器拽回去），
    // 只跟三个动作：换歌 / 播停 / 拖动。这三个的 by == "ai" 才动。

    func startFollowing() {
        observeVoice()
        guard !didStartFollow else { return }
        didStartFollow = true
        seenEventId = store.load().events.last?.id ?? ""
        followTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.followTick() }
        }
    }

    func stopFollowing() {
        followTimer?.invalidate()
        followTimer = nil
        didStartFollow = false
    }

    private func followTick() {
        let state = store.load()
        guard let last = state.events.last else { return }
        guard last.id != seenEventId else { return }
        seenEventId = last.id

        // 遥控器在谁手里，就听谁的。
        // 之前只看事件是谁发的，递给我之后她那边还会被 AI 的事件拽走。
        let controller = state.playback.by

        // 递遥控器本身就是一条事件：谁接手，本机就归谁。
        if last.type == "handoff" { return }

        guard controller == "ai", last.by == "ai" else { return }

        switch last.type {
        case "play", "radio":
            guard let t = state.track else { return }
            let target = state.playback.position
            if track?.id != t.id {
                load(t, from: target)
            } else if abs(currentTime - target) > 2 {
                seek(to: target)
            }
            if !isPlaying { play() }

        case "pause":
            if isPlaying { pause() }

        case "resume":
            if !isPlaying { play() }

        case "seek":
            if let pos = last.detail?.position, abs(currentTime - pos) > 1.5 {
                seek(to: pos)
            }

        default:
            break
        }
    }

    // MARK: 内部

    private func addPeriodicObserver() {
        guard let p = player else { return }
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let seconds = time.seconds
                guard !seconds.isNaN else { return }
                self.currentTime = seconds
                if let d = p.currentItem?.duration.seconds, !d.isNaN, d > 0 {
                    self.duration = d
                }
                // 每跨过一整秒才往盘上写一次：面板要的是"歌还在放、进度还在"，
                // 不是每秒一条。
                if abs(seconds - self.lastReportedSecond) >= 3 {
                    self.lastReportedSecond = seconds
                    self.reportProgress()
                }
            }
        }
    }

    // MARK: 语音让路
    //
    // 语音播报和音乐抢同一个 AVAudioSession：不处理就是语音一响音乐乱跳，
    // 说完了也回不来。规矩是——语音开始我暂停，语音结束我接着放，
    // 只在我本来是"在放"的时候才恢复，她手动停的不要自己响。

    private func observeVoice() {
        guard voiceObservers.isEmpty else { return }
        let center = NotificationCenter.default
        voiceObservers.append(center.addObserver(
            forName: AudioSessionCoordinator.replyTTSStartedNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.duckedForVoice = true
                self.pause()
            }
        })
        voiceObservers.append(center.addObserver(
            forName: AudioSessionCoordinator.replyTTSEndedNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.duckedForVoice else { return }
                self.duckedForVoice = false
                self.play()
            }
        })
    }

    private func addEndObserver() {
        guard let item = player?.currentItem else { return }
        endToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleTrackEnd()
            }
        }
    }

    /// 一首放完：单曲循环就重放；否则顺序（或随机）接着下一首。
    /// 跟音乐 App 一样，别停在最后一句等人点。
    private func handleTrackEnd() {
        let state = store.load()

        if state.playback.repeatOne {
            seek(to: 0)
            play()
            store.reportProgress(position: 0)
            return
        }

        let lib = store.library()
        guard !lib.tracks.isEmpty else {
            isPlaying = false
            currentTime = duration
            reportProgress(force: true)
            VoiceNowPlaying.shared.refresh()
            return
        }

        let currentId = track?.id ?? ""
        let next: TogetherTrack
        if state.playback.shuffle {
            let pool = lib.tracks.filter { $0.id != currentId }
            next = pool.randomElement() ?? lib.tracks[0]
        } else if let i = lib.tracks.firstIndex(where: { $0.id == currentId }) {
            next = lib.tracks[(i + 1) % lib.tracks.count]
        } else {
            next = lib.tracks[0]
        }

        load(next, from: 0)
        store.play(trackId: next.id, at: 0, by: .user)
    }

    private func reportProgress(force: Bool = false) {
        // 面板关着、App 在后台的时候也要把进度落盘，冷启动才能接着放
        guard force || lastReportedSecond >= 0 else { return }
        store.reportProgress(position: currentTime)
    }

    private func teardown() {
        // 换歌不能把语音让路的监听一起摘掉：这两个通知只认"播放器还在不在放"，
        // 和具体某一首歌无关。以前每 load 一次就清空，第一首之后监听就永久没了，
        // 语音一响音乐不暂停、说完也不续播。观察者跟 App 同寿命,由 startFollowing()
        // 幂等装一次(observeVoice 里有 isEmpty 守卫),不再随换歌清理。
        if let token = endToken {
            NotificationCenter.default.removeObserver(token)
            endToken = nil
        }
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        player?.pause()
        player = nil
        if didSuspendSilentAudio {
            BackgroundKeepAliveManager.shared.resumeSilentAudioForMedia()
            didSuspendSilentAudio = false
        }
    }
}

// MARK: - 锁屏用的标题

extension TogetherPlayer {
    var nowPlayingTitle: String {
        let t = track?.title ?? ""
        return t.isEmpty ? TogetherCopy.title : t
    }

    var nowPlayingArtist: String {
        let a = track?.artist ?? ""
        return a.isEmpty ? TogetherCopy.title : a
    }
}