import Foundation

// MARK: - AI voice-message composer
//
// [T-ai-voice-messages 09-12] 醒醒 2：「我想要里面的ai自己也能发语音，发出来就是
// 自动播放的。有气泡UI像wx那样会动的，有动态效果。」
//
// Flow (driven by the `send_voice` tool when per-session "AI Voice Replies" is
// ON; the old StreamEnd auto-compose fallback was removed in batch9-voice/5 —
// bubbles are sent only when the model ASKS to，想发才发):
//   1. Sanitize the model-supplied text (strip markdown, keep plain text).
//   2. Synthesize via the candidate chain (default TTS group → selected
//      service → model group; System only when "Allow System voice" is on).
//   3. Write the WAV/MP3 bytes to the session's attachments dir (+ a .txt
//      transcript sidecar for the bubble's 转文字).
//   4. Return a minis-clone:// URL + duration for the caller to embed into a
//      markdown audio link. The link renders as a WX-style voice bubble via
//      AudioAttachment (detects `voice_bubble=1` query param).

@MainActor
enum AIVoiceMessageComposer {

    private static let logger = AppLogger(category: "AIVoiceComposer")

    /// Result: (minis-clone URL String, duration in seconds).
    struct Result {
        let url: String
        let duration: Double
        /// 实际合成出音频的服务名（默认链路兜底时为 nil）。
        /// [voice-bubble-tool 2026-10-02] send_voice 点名 voice/group 时回给模型，
        /// 让它知道到底是哪个声音发出去的。
        let serviceName: String?
    }

    /// [voice-bubble-tool 2026-10-02] send_voice 点名 voice/group 时的错误。
    /// description 直接是给模型的中文交代（含可用选项），调用方原样回即可。
    enum VoiceComposeError: LocalizedError {
        case emptyText
        case groupNotFound(name: String, available: [String])
        case groupEmpty(name: String)
        case voiceNotFound(name: String, available: [String])
        case serviceDisabled(name: String)
        /// [B09-V4 2026-10-22] Enabled + key present, but the credential cannot
        /// build a provider (e.g. iFlytek saved as one segment instead of
        /// `appId;apiKey;apiSecret`). Previously this surfaced as a generic
        /// "synthesis failed" after a wasted round trip.
        case serviceNotUsable(name: String)
        case synthesisFailed(detail: String)

        var errorDescription: String? {
            switch self {
            case .emptyText:
                return "没有可说的话（文本为空）。"
            case .groupNotFound(let name, let available):
                let opts = available.isEmpty ? "（还没有建任何分组）" : "可用分组：" + available.joined(separator: "、")
                return "没有这个 TTS 分组「\(name)」。\(opts)不传 group 就用默认分组。"
            case .groupEmpty(let name):
                return "TTS 分组「\(name)」里没有可用的服务（成员都被删了或停用了）。换个分组，或不传 group 用默认的。"
            case .voiceNotFound(let name, let available):
                let opts = available.isEmpty ? "（还没有配任何 TTS 服务）" : "可用服务：" + available.joined(separator: "、")
                return "没有这个 TTS 服务「\(name)」。\(opts)不传 voice 就用默认分组。"
            case .serviceDisabled(let name):
                return "TTS 服务「\(name)」已停用。让主人去「设置 > Voice Services」里启用，或换个服务。"
            case .serviceNotUsable(let name):
                return "TTS 服务「\(name)」的凭证不完整，合成不了。让主人去「设置 > Voice Services」里重新填一遍密钥（讯飞要 appId;apiKey;apiSecret 三段），或换个服务。"
            case .synthesisFailed(let detail):
                return "语音合成失败（\(detail)）。如实告诉主人这条语音没发出去，不要谎称已发送；可以建议她检查 TTS 服务配置。"
            }
        }
    }

    private static func prefKey(_ sid: String) -> String { "ai.voiceReplies.\(sid)" }

    static func voiceRepliesEnabled(sessionId: String) -> Bool {
        UserDefaults.standard.bool(forKey: prefKey(sessionId))
    }

    static func setVoiceReplies(enabled: Bool, sessionId: String) {
        UserDefaults.standard.set(enabled, forKey: prefKey(sessionId))
    }

    /// [T-voice-bubble-context-clean 09-12] True when an assistant text part is
    /// ONLY a wx-style voice bubble this app composed. Such rows are DB/UI-only:
    /// loadSession keeps them OUT of agentHistory so the model never sees (and
    /// never imitates) its own bubble markdown. Shape-anchored, not
    /// substring-anchored: a normal reply that merely MENTIONS "voice_bubble=1"
    /// must never be stripped (unit-tested boundary: a 29-char reply mentioning
    /// the param stays; only an actual `![voice](…voice_bubble=1…)` link part
    /// goes).
    nonisolated static func isVoiceBubbleOnlyText(_ s: String) -> Bool {
        guard s.hasPrefix("![voice](") else { return false }
        guard s.contains("voice_bubble=1") else { return false }
        return s.count < 200
    }

    /// [batch9-voice/2] 统一语音卡片链接构造——send_voice 工具的发声路径
    ///（StreamEnd 自动气泡已拆）。格式：`![voice](<url>?voice_bubble=1&dur=<秒>)`
    /// [batch1-A4] auto_play=true 参数已删：全仓没有消费方（triggerAutoPlayAudio
    /// 只认 voice_bubble=1），旧消息里带的它同样不生效，删掉不影响历史消息。
    static func voiceBubbleLink(url: String, duration: Double) -> String {
        let durParam = duration > 0 ? Int(duration.rounded()) : 0
        return "![voice](\(url)?voice_bubble=1&dur=\(durParam))"
    }

    // MARK: - [B09-S05 2026-10-22] On-disk voice bubbles

    /// Every voice bubble writes `tts-<uuid>.wav|mp3` (+ a `.txt` transcript)
    /// into the session's attachments folder and NOTHING ever removed them —
    /// no cap, no cleanup, and they ride along in iCloud backups. This scans
    /// them so Storage can show a real number and reclaim the old ones.
    /// A voice file is any attachment whose name starts with "tts-".
    nonisolated static func voiceFileStats(olderThanDays days: Int? = nil) -> (count: Int, bytes: Int64) {
        let fm = FileManager.default
        let base = AIChatViewModel.minisPersistentBase
        var count = 0
        var bytes: Int64 = 0
        let cutoff = days.map { Date().addingTimeInterval(-Double($0) * 86_400) }
        guard let sessions = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else {
            return (0, 0)
        }
        for sessionDir in sessions {
            let attach = sessionDir.appendingPathComponent("attachments", isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(
                at: attach, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
            ) else { continue }
            for f in files where f.lastPathComponent.hasPrefix("tts-")
            && f.pathExtension.lowercased() != "txt" {
                let vals = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                if let cutoff, let m = vals?.contentModificationDate, m > cutoff { continue }
                count += 1
                bytes += Int64(vals?.fileSize ?? 0)
            }
        }
        return (count, bytes)
    }

    /// Delete voice-bubble files older than `days`. The bubble's text survives
    /// (the message row keeps its text part); only the audio goes, and tapping
    /// an emptied bubble just shows nothing to play.
    @discardableResult
    nonisolated static func clearVoiceFiles(olderThanDays days: Int) -> (count: Int, bytes: Int64) {
        let fm = FileManager.default
        let base = AIChatViewModel.minisPersistentBase
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var count = 0
        var bytes: Int64 = 0
        guard let sessions = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else {
            return (0, 0)
        }
        for sessionDir in sessions {
            let attach = sessionDir.appendingPathComponent("attachments", isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(
                at: attach, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
            ) else { continue }
            // [B09-R5 2026-10-22] Keep the .txt sidecar. The bubble's 转文字 reads
            // that file, so deleting it along with the audio made the transcript
            // button go blank — while the storage copy promised "their text stays".
            for f in files where f.lastPathComponent.hasPrefix("tts-")
            && f.pathExtension.lowercased() != "txt" {
                let vals = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                guard let m = vals?.contentModificationDate, m < cutoff else { continue }
                let size = Int64(vals?.fileSize ?? 0)
                if (try? fm.removeItem(at: f)) != nil {
                    count += 1
                    bytes += size
                }
            }
        }
        // [B09-R7 2026-10-22] This function is `nonisolated` and runs off the main
        // actor; the shared `logger` belongs to the @MainActor enum. Route the
        // line through VoiceLog.problem, which owns its own logger and is the
        // Release-visible channel anyway.
        VoiceLog.problem("cleared \(count) voice file(s), \(bytes) bytes, older than \(days)d")
        pruneProgressForRemainingFiles()
        return (count, bytes)
    }

    /// [B09-V12 2026-10-22] Voice-bubble listen-progress is keyed by file name
    /// and capped at 200 entries. Deleting the audio left the record behind, so
    /// cleaned-up files kept occupying slots until live ones were pushed out.
    /// `nonisolated` + UserDefaults-only, safe off the main actor.
    nonisolated static func pruneProgressForRemainingFiles() {
        let fm = FileManager.default
        let base = AIChatViewModel.minisPersistentBase
        var names = Set<String>()
        if let sessions = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) {
            for sessionDir in sessions {
                let attach = sessionDir.appendingPathComponent("attachments", isDirectory: true)
                guard let files = try? fm.contentsOfDirectory(at: attach, includingPropertiesForKeys: nil)
                else { continue }
                for f in files where f.lastPathComponent.hasPrefix("tts-") {
                    names.insert(f.deletingPathExtension().lastPathComponent)
                }
            }
        }
        VoiceBubblePlaybackState.pruneMissing(existingFileNames: names)
    }

    /// [voice-bubble-tool 2026-10-02] send_voice 专用：voice/group 点名版。
    /// - voice: TTS 服务名（服务的 id 也行），用该服务的音色合成。
    /// - group: TTS 分组名（分组 id 也行），按分组成员顺序 fallback。
    /// 都不传 = 走默认链路（选中服务 → 默认 TTS 分组 → 模型分组，见 VoiceChain）。
    /// 点名时是严格语义：只试点名的候选，死透了就抛错，不会悄悄用别的声音顶。
    static func compose(for text: String, sessionId: String, voice: String?, group: String?) async throws -> Result {
        let sanitized = VoiceTextSanitizer.sanitize(text)
        guard !sanitized.isEmpty else { throw VoiceComposeError.emptyText }

        let data: Data
        let dur: Double
        let usedService: String?
        do {
            (data, dur, usedService) = try await synthesizeFull(sanitized, voice: voice, group: group)
        } catch let e as VoiceComposeError {
            throw e
        } catch is CancellationError {
            // 取消必须透传，不能吞成"合成失败"（外层 dispatch 的取消分支负责收）。
            throw CancellationError()
        } catch {
            logger.warning("voice message synthesis failed: \(error.localizedDescription)")
            throw VoiceComposeError.synthesisFailed(detail: "TTS 服务不可用或未配置")
        }
        guard !data.isEmpty else { throw VoiceComposeError.synthesisFailed(detail: "合成返回空音频") }

        let ext = Self.isWAVData(data) ? "wav" : "mp3"
        let fname = "tts-\(UUID().uuidString.prefix(8)).\(ext)"
        let hostDir = AIChatViewModel.minisAttachmentsPersistentDir(for: sessionId)
        try? FileManager.default.createDirectory(at: hostDir, withIntermediateDirectories: true)
        let dest = hostDir.appendingPathComponent(fname)
        do {
            try data.write(to: dest, options: .atomic)
        } catch {
            logger.warning("voice message write failed: \(error.localizedDescription)")
            throw VoiceComposeError.synthesisFailed(detail: "音频写盘失败")
        }
        // [P1-6] 转文字 sidecar: persist the sanitized source text next to the
        // audio so the bubble's 转文字 reads it with zero STT cost.
        // Best-effort — a missing sidecar just means no 转文字 for old bubbles.
        let txtDest = dest.deletingPathExtension().appendingPathExtension("txt")
        try? sanitized.write(to: txtDest, atomically: true, encoding: .utf8)
        let linuxPath = "/var/minis/attachments/\(fname)"
        let minisURL = "minis-clone://attachments/\(fname.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fname)"
        logger.info("voice message composed: \(linuxPath) dur=\(String(format: "%.1f", dur))s size=\(data.count) service=\(usedService ?? "default-chain")")
        return Result(url: minisURL, duration: dur, serviceName: usedService)
    }

    /// Walk the candidate chain exactly like read-aloud: selected service →
    /// model group. [T-system-voice-off 09-12] 醒醒 3: System voice is an
    /// EXPLICIT fallback, not a silent one — when nothing user-configured is
    /// usable we throw instead of falling to AVSpeechSynthesizer, so the turn
    /// reads as text-only and the log names the gap. The old always-System
    /// tail made every misconfigured session sound like the robotic system
    /// voice 醒醒 hates.
    private static func synthesizeFull(_ text: String, voice: String?, group: String?) async throws -> (Data, Double, String?) {
        // [voice-bubble-tool 2026-10-02] 点名了就走严格语义：只试点名的候选
        //（分组按成员顺序 fallback），死透了抛错，不悄悄用别的声音顶。
        if let explicit = try resolveExplicitServices(voice: voice, group: group) {
            for service in explicit {
                if let (data, _) = try await synthesizeWithService(service, text) {
                    return (data, VoiceOutputPlayer.wavDurationOf(data), service.name)
                }
            }
            throw VoiceComposeError.synthesisFailed(detail: "点名的 TTS 候选都失败了")
        }
        // 默认链路：选中服务 → 默认 TTS 分组 → 模型分组（VoiceChain.serviceCandidates）。
        // 取消透传（不能 try? 吞掉），其他失败才落到下面的 synthesisFailed。
        do {
            let (data, _) = try await synthesizeWithServiceOrGroup(text)
            return (data, VoiceOutputPlayer.wavDurationOf(data), nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 普通失败：继续抛 synthesisFailed
        }
        throw VoiceComposeError.synthesisFailed(detail: "没有可用的 TTS 目标——先选个 TTS 服务或语音分组")
    }

    /// [voice-bubble-tool 2026-10-02] 把模型传的 voice/group 解析成候选服务列表。
    /// 都不传返回 nil（调用方走默认链路）。匹配顺序：id 精确 → 名字精确 →
    /// 名字忽略大小写。找不到/不可用就抛 VoiceComposeError（description 直接
    /// 是给模型的中文交代，含可用选项）。
    private static func resolveExplicitServices(voice: String?, group: String?) throws -> [TTSServiceOptions]? {
        if let g = group?.trimmingCharacters(in: .whitespacesAndNewlines), !g.isEmpty {
            let store = TTSGroupStore.shared
            let matched = store.group(id: g)
                ?? store.groups.first { $0.name == g }
                ?? store.groups.first { $0.name.lowercased() == g.lowercased() }
            guard let grp = matched else {
                throw VoiceComposeError.groupNotFound(name: g, available: store.groups.map { $0.name })
            }
            let cands = store.usableCandidates(for: grp)
            guard !cands.isEmpty else {
                throw VoiceComposeError.groupEmpty(name: grp.name)
            }
            logger.info("[AIVoice] explicit group '\(grp.name)' → \(cands.count) candidate(s)")
            return cands
        }
        if let v = voice?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
            let store = TTSServiceStore.shared
            let matched = store.service(id: v)
                ?? store.services.first { $0.name == v }
                ?? store.services.first { $0.name.lowercased() == v.lowercased() }
            guard let svc = matched else {
                throw VoiceComposeError.voiceNotFound(
                    name: v, available: store.services.filter { $0.enabled }.map { $0.name })
            }
            guard svc.enabled else {
                throw VoiceComposeError.serviceDisabled(name: svc.name)
            }
            // [B09-V4 2026-10-22] A service that passes `enabled` but whose
            // credential cannot build a provider (iFlytek missing the secret
            // segment) used to be returned here and then fail at synthesis with
            // a generic error. Refuse it up front with the same predicate the
            // rest of the chain uses.
            guard VoiceChain.canSpeak(svc) else {
                throw VoiceComposeError.serviceNotUsable(name: svc.name)
            }
            logger.info("[AIVoice] explicit voice service '\(svc.name)'")
            return [svc]
        }
        return nil
    }

    /// [P1-6] Sidecar transcript for a composed voice file: the .txt written
    /// next to the audio at compose time (zero-STT 转文字 source).
    /// Returns the text, or nil when the sidecar is absent (old bubbles).
    ///
    /// [B09-V3 2026-10-22] Takes the SOURCE LINK, not a resolved audio URL.
    /// The storage page deletes old `tts-*.wav` but deliberately keeps the
    /// `.txt` ("those bubbles lose their audio, their text stays") — except the
    /// caller only got a URL after the audio file was found on disk, so once the
    /// audio was gone `resolvedURL` was nil and the transcript could never be
    /// read. The text stayed on disk and stayed invisible.
    ///
    /// Resolving from the link means the sidecar is found whether or not the
    /// audio still exists. `audioURL` is still accepted for the normal path
    /// (already-resolved file), and is used only as a fast hint.
    nonisolated static func transcript(forLink link: String) -> String? {
        guard let txt = sidecarURL(forLink: link) else { return nil }
        return try? String(contentsOf: txt, encoding: .utf8)
    }

    /// The `.txt` sidecar path implied by a `minis-clone://` link, whether or
    /// not the audio itself still exists. nil when the link is not a session
    /// attachment (nothing to look for).
    nonisolated static func sidecarURL(forLink link: String) -> URL? {
        // Strip the query (voice_bubble=1 / dur=… are metadata).
        let clean: String
        if let u = URL(string: link), var c = URLComponents(url: u, resolvingAgainstBaseURL: false) {
            c.queryItems = nil
            clean = c.url?.absoluteString ?? link
        } else {
            clean = link
        }
        guard let url = URL(string: clean), url.scheme == "minis-clone" else { return nil }
        guard let host = url.host, host == "attachments" else { return nil }
        // `URL` has no `percentEncodedPath` (that lives on `URLComponents`).
        // `path` is already percent-decoded, so no second decode pass here —
        // decoding twice would turn a literal "%20" in a filename into a space
        // and point at a file that does not exist.
        let sub = url.path.isEmpty ? "" : String(url.path.dropFirst())
        guard !sub.isEmpty else { return nil }
        let name = (sub as NSString).deletingPathExtension
        let txtName = name + ".txt"
        guard let sid = AIChatViewModel.activeSessionId, !sid.isEmpty else { return nil }
        return AIChatViewModel.minisAttachmentsPersistentDir(for: sid)
            .appendingPathComponent(txtName)
    }

    /// Kept for callers that already hold a resolved audio URL.
    nonisolated static func transcriptForAudioFile(_ audioURL: URL) -> String? {
        let txtURL = audioURL.deletingPathExtension().appendingPathExtension("txt")
        guard FileManager.default.fileExists(atPath: txtURL.path) else { return nil }
        return try? String(contentsOf: txtURL, encoding: .utf8)
    }

    /// linuxPathFor(url:) — turn the minis-clone URL back into the /var/minis
    /// path (used by the auto-play trigger's resolvePathForDirectRead).
    nonisolated static func linuxPathFor(url: String) -> String {
        guard let comps = URLComponents(string: url), let host = comps.host else { return "" }
        let sub = comps.percentEncodedPath.isEmpty ? "" : "/" + (comps.percentEncodedPath.dropFirst().removingPercentEncoding ?? String(comps.percentEncodedPath.dropFirst()))
        return "/var/minis/\(host)\(sub)"
    }

    /// [TTS-11] RIFF/WAVE magic check — the saved bubble's extension must
    /// describe the actual bytes (the old code guessed from whether a
    /// WAV duration could be read, which mislabels any vendor that
    /// returns WAV where MP3 was requested and vice versa).
    nonisolated static func isWAVData(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        return data.subdata(in: 0..<4) == Data("RIFF".utf8)
            && data.subdata(in: 8..<12) == Data("WAVE".utf8)
    }

    /// [TTS-11] Synthesize `text` through `synth`, splitting UP FRONT at
    /// `limit` characters on sentence boundaries when the text exceeds
    /// it, then joining the pieces into one blob with the read-aloud
    /// path's concat rules. A long reply used to go out as ONE request:
    /// past the vendor's per-request cap (Doubao 1024, OpenAI 4096, …)
    /// the whole bubble failed and the reply stayed text-only. Any
    /// chunk failing fails the whole bubble, same as before.
    /// [AI-P2-4] Each chunk now goes through `synthWithRetry` below —
    /// same-text retries with backoff, then split-smaller — mirroring
    /// read-aloud's `VoiceOutputPlayer.synthWithRetry` instead of the old
    /// single attempt per chunk (one network hiccup used to kill the
    /// whole long-reply bubble).
    private static func synthesizeChunked(
        _ text: String, limit: Int,
        _ synth: (String) async throws -> Data
    ) async throws -> Data {
        let chunks = VoiceOutputPlayer.splitText(text, maxChars: limit)
        guard chunks.count > 1 else { return try await synthWithRetry(text, synth) }
        // [tts-prefetch 2026-10-09] Pipelined synthesis: up to 2 chunks in
        // flight at once (mirrors VoiceOutputPlayer.maxPrefetch = 2). async-let
        // inherits this @MainActor enum's isolation, so synthWithRetry stays
        // actor-confined and no Sendable dance is needed. Order is preserved;
        // one chunk failing fails the whole bubble, same as before.
        // NOTE: true "play chunk 0 while the rest synthesizes" would require
        // breaking the single-file bubble contract (AVAudioPlayer loads the
        // whole file at init) — out of scope; the prefetch cuts time-to-audio
        // roughly in half for multi-chunk replies.
        var pieces: [Data] = []
        pieces.reserveCapacity(chunks.count)
        var i = 0
        while i < chunks.count {
            if Task.isCancelled { throw CancellationError() }
            if i + 1 < chunks.count {
                let idx = i
                async let d0 = synthWithRetry(chunks[idx], synth)
                async let d1 = synthWithRetry(chunks[idx + 1], synth)
                let (a, b) = try await (d0, d1)
                guard !a.isEmpty, !b.isEmpty else { throw VoiceProviderError.noAudioData }
                pieces.append(a)
                pieces.append(b)
                i += 2
            } else {
                let d = try await synthWithRetry(chunks[i], synth)
                guard !d.isEmpty else { throw VoiceProviderError.noAudioData }
                pieces.append(d)
                i += 1
            }
        }
        logger.info("[AIVoice] long reply synthesized in \(chunks.count) chunks (limit \(limit), pipelined x2)")
        return VoiceOutputPlayer.concatPieces(pieces)
    }

    /// [AI-P2-4] Two-phase resilience for one chunk, mirroring read-aloud's
    /// `VoiceOutputPlayer.synthWithRetry` (same retry counts/backoff/split
    /// size, shared constants): Phase 1 retries the SAME text with backoff;
    /// Phase 2 splits into smaller pieces and synthesizes those. Empty audio
    /// counts as a failed attempt. Throws only when both phases fail.
    private static func synthWithRetry(
        _ text: String,
        _ synth: (String) async throws -> Data
    ) async throws -> Data {
        let maxAttempts = VoiceOutputPlayer.synthRetriesSameText
        var lastError: Error?
        // Phase 1: retry the same text.
        for attempt in 0...maxAttempts {
            if Task.isCancelled { throw CancellationError() }
            do {
                let d = try await synth(text)
                if !d.isEmpty { return d }
                lastError = VoiceProviderError.noAudioData
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
            logger.warning("[AIVoice] chunk synth attempt \(attempt + 1)/\(maxAttempts + 1) failed: \(lastError?.localizedDescription ?? "?")")
            let backoff = VoiceOutputPlayer.synthRetryBackoff * Double(attempt + 1)
            // 不加 try?：backoff 睡眠期间被取消要直接抛出，不能吞掉继续重试。
            try await Task.sleep(nanoseconds: UInt64(backoff * 1e9))
        }
        // Phase 2: split smaller and synthesize each piece.
        let small = VoiceOutputPlayer.splitText(text, maxChars: VoiceOutputPlayer.synthSplitChunkChars)
        guard small.count > 1 else { throw lastError ?? VoiceProviderError.parseError("chunk synth failed") }
        logger.info("[AIVoice] chunk still failing — retrying as \(small.count) smaller pieces")
        var pieces: [Data] = []
        for piece in small {
            if Task.isCancelled { throw CancellationError() }
            var ok = false
            for _ in 0...maxAttempts {
                do {
                    let d = try await synth(piece)
                    if !d.isEmpty { pieces.append(d); ok = true; break }
                    lastError = VoiceProviderError.noAudioData
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                }
                // 不加 try?：睡眠期间被取消要直接抛出，不能吞掉继续试下一个 piece。
                try await Task.sleep(nanoseconds: UInt64(VoiceOutputPlayer.synthRetryBackoff * 1e9))
            }
            guard ok else { throw lastError ?? VoiceProviderError.parseError("small-piece synth failed") }
        }
        return VoiceOutputPlayer.concatPieces(pieces)
    }

    /// [tts-groups 2026-10-02] 候选链：服务层（选中服务 → 默认 TTS 分组成员，
    /// 见 VoiceChain）→ Voice Output 模型分组。
    /// [B09-V11 2026-10-22] 上面那句原文写的是"默认分组成员 → 之前选中的单个
    /// 服务"，与实际顺序相反（R-2 之后是选中优先）。改代码不改注释，下一个接手
    /// 的人会照注释再改错一次。
    /// [B09-L01 2026-10-22] Returns `(audio, container)` — the second value is
    /// the file CONTAINER ("wav"/"mp3"), which is what every return statement
    /// here already put in it. It used to be typed/read as a service name
    /// (`serviceName`), so the one place that consumed it would have shown
    /// "wav" as the voice name. Naming it honestly; callers ignore it today.
    private static func synthesizeWithServiceOrGroup(_ text: String) async throws -> (Data, container: String) {
        for service in ttsServiceCandidates() {
            if let result = try await synthesizeWithService(service, text) {
                return result
            }
        }
        for entry in VoiceProviderResolver.resolvedOutputCandidates() {
            guard let provider = VoiceProviderResolver.outputProvider(for: entry) else { continue }
            // [TTS-11] Group entries carry no vendor kind here — split at
            // the conservative shared limit (safe for every vendor).
            // 取消透传（不能 try? 吞掉），普通失败才 continue 试下一个。
            do {
                let data = try await synthesizeChunked(text, limit: 1000, { chunk in
                    // [audit-F8] 分块兜底也是真实发声路径——voice/resolvedModel
                    // 同补，否则长回复一旦触发分块就又在默认音色上复发。
                    try await provider.synthesize(VoiceOutputRequest(input: chunk,
                                                                    model: entry.model.id,
                                                                    voice: entry.model.id,
                                                                    resolvedModel: entry.model))
                })
                if !data.isEmpty {
                    logger.info("[AIVoice] synthesized via model-group entry \(entry.model.displayName)")
                    return (data, VoiceProviderResolver.isSystemEntry(entry.providerInstanceId) ? "wav" : "mp3")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        throw VoiceProviderError.parseError("all voice candidates failed")
    }

    /// 有序去重的 TTS 服务候选。
    ///
    /// [B09-V1 2026-10-22] Delegates to VoiceChain: this used to be a second,
    /// hand-maintained copy of the same order (and it silently drifted every
    /// time the player's copy changed — that is what made the bubble path and
    /// the read-aloud path disagree about which service speaks).
    private static func ttsServiceCandidates() -> [TTSServiceOptions] {
        VoiceChain.serviceCandidates()
    }

    /// 单个 TTS 服务合成一次。普通失败记 LOUD 日志并返回 nil（调用方继续下
    /// 一个候选）。[T-tts-key-status 09-13] 语义保留：选中的服务自己的失败必须
    /// 大声记原因（之前"有声但显示没 key"就是这里静默跳过导致的）。
    /// 取消是例外：CancellationError 直接抛出，不转 nil（否则调用方会继续试
    /// 下一个候选，最终报"合成失败"而非"已取消"，停止按钮形同虚设）。
    private static func synthesizeWithService(_ service: TTSServiceOptions, _ text: String) async throws -> (Data, String)? {
        let svcStore = TTSServiceStore.shared
        if !svcStore.hasAPIKey(for: service) {
            logger.warning("[AIVoice] TTS service '\(service.name)' has NO stored key — skipping (check the Keychain save in the service editor)")
            return nil
        }
        guard let provider = TTSProviderBridge.provider(for: service) else {
            logger.warning("[AIVoice] TTS service '\(service.name)' (\(service.kind.rawValue)) cannot synthesize — skipping")
            return nil
        }
        do {
            // [TTS-11] Split at THIS vendor's per-request limit before sending,
            // not after a failure.
            let data = try await synthesizeChunked(text, limit: service.kind.bubbleSynthesisCharLimit) { chunk in
                try await provider.synthesize(TTSProviderBridge.request(for: service, text: chunk))
            }
            if !data.isEmpty {
                logger.info("[AIVoice] synthesized via service '\(service.name)' (\(service.kind.rawValue))")
                return (data, service.kind == .azure ? "mp3" : "wav")
            }
            logger.warning("[AIVoice] service '\(service.name)' returned empty audio — trying next candidate")
        } catch is CancellationError {
            // 取消必须透传，不能吞成 nil（调用方靠 nil 决定"试下一个候选"，
            // 吞掉会导致"点了停止停不下来"，最后报"合成失败"而非"已取消"）。
            throw CancellationError()
        } catch {
            logger.warning("[AIVoice] service '\(service.name)' synth failed: \(error.localizedDescription) — trying next candidate")
        }
        return nil
    }
}
