import Foundation

// MARK: - TTS 能力纸条（AI 说明书 · 纸条版）
//
// [tts-paper 2026-10-02] 醒醒：「模型根本不知道我有这个 TTS，他不会调用，也没说明书」。
//
// 两层机制（2026-10-09 起，按她定的口径）：
//   1. 常驻能力声明（standingCapability）：只要配了 TTS 服务/分组，每轮
//      system prompt 都带一句——模型永久知道自己有声音、想发就发，不靠
//      关键词触发，不用等主人开口。这是她定的："他也要知道这个语音的
//      存在，不用谁提醒"；"模型想自己发语音了，就像人一样"。
//   2. 详细纸条（paperIfRelevant）：用户话题跟语音/TTS 相关时，才把完整
//      说明书（含当前配置、调用方法）塞进 prompt 做展开。
// 内容是活的——每次按 TTSServiceStore / TTSGroupStore 的当前配置现拼
//（有哪些分组/服务/音色），配置改了纸条自动跟着变，不用手动同步。
//
// 假设记在这里：v1 用词表匹配；如果她嫌误触发/漏触发，再换更聪明的
// 判定。纸条只在配了 TTS 服务/分组时才出现——没配就不让模型知道，免得它
// 对着空气调工具（"空调"）。

enum TTSPaper {

    /// 有没有可用的语音：服务层（选中服务或默认分组）里有能真出声的目标。
    /// 判定统一走 VoiceChain，不再自己写一份。
    ///
    /// [B09-V1 2026-10-22] Was `any enabled+keyed service`, which counted
    /// services the player skips (bad credential shape) — telling the model it
    /// had a voice and then failing every send_voice.
    ///
    /// Stays service-layer only on purpose: this enum is read from a detached
    /// task (`minis-tts` bridge), and the voice model-group resolver is
    /// main-actor bound. The model-group path has always been outside this
    /// answer; adding it here would need the bridge to hop actors first.
    static func hasConfiguredVoice() -> Bool {
        VoiceChain.hasServiceTarget()
    }

    /// 常驻能力声明：短、一句。配了 TTS 就每轮进 prompt，让模型永久知道
    /// 自己有声音——想发就发，像人一样，不用等主人开口要。
    /// 没配 TTS 时返回 nil（模型不该知道这功能）。
    ///
    /// [B09-V2 2026-10-22] Order now matches what actually plays: an explicitly
    /// selected service first, the default group second. It used to describe the
    /// group as the primary voice no matter what the user had ticked, so the
    /// model explained its voice from the wrong list.
    static func standingCapability() -> String? {
        guard hasConfiguredVoice() else { return nil }
        let groupStore = TTSGroupStore.shared
        var desc = ""
        if let s = VoiceChain.selectedService() {
            desc = "TTS 服务「\(s.name)」（音色 \(s.voice)）"
        } else if let g = groupStore.defaultGroup(), !groupStore.usableCandidates(for: g).isEmpty {
            desc = "默认 TTS 分组「\(g.name)」"
        } else if let s = VoiceChain.firstUsableServiceAnywhere() {
            desc = "TTS 服务「\(s.name)」（音色 \(s.voice)）"
        }
        let what = desc.isEmpty ? "TTS 语音" : desc
        return "你有声音：\(what)已配置。你可以用 send_voice 工具随时发语音消息——像人一样，想发就发，不用等主人开口；觉得某句话用声音说比打字更合适时（晚安、撒娇、安慰、惊喜），就直接发语音。"
    }

    /// 拼出纸条正文。没配任何可用 TTS 服务/分组时返回 nil。
    /// skipIntro = true 时跳过开头段（常驻声明已讲过，不重复）。
    static func paperText(skipIntro: Bool = false) -> String? {
        let groupStore = TTSGroupStore.shared
        let serviceStore = TTSServiceStore.shared
        // [B09 2026-10-22] Only list what can actually synthesize — a keyless
        // service in the list invites the model to name it and get rejected.
        let services = serviceStore.services.filter { VoiceChain.canSpeak($0) }
        guard hasConfiguredVoice() else { return nil }

        var lines: [String] = []
        if !skipIntro {
            lines.append("【纸条·TTS 语音】")
            lines.append("你有一个 send_voice 工具：把文字合成为语音消息发给主人（微信式语音气泡，点一下就能听，会自动播放）。主人说\"发条语音\"\"用语音说\"\"读出来\"\"念给我听\"这类话时，调这个工具——别自己去沙箱里跑命令合成音频。")
            lines.append("")
        }

        // 当前配置（活的）。[B09-V2 2026-10-22] 顺序 = 实际发声顺序：
        // 选中服务 → 默认分组。以前这里写着"默认分组优先"，而 R-2 之后
        // 播放链是"选中优先"——说明书和实际反着，模型按错的清单解释声音。
        let defaultCandidates = groupStore.usableDefaultGroupCandidates()
        if let s = VoiceChain.selectedService() {
            lines.append("当前 TTS 服务：\(s.name)（\(s.kind.displayName)·音色 \(s.voice)）。这个是主人点选的，优先于分组。")
            if !defaultCandidates.isEmpty, let g = groupStore.defaultGroup() {
                lines.append("默认 TTS 分组「\(g.name)」作为备选，顺序：\(defaultCandidates.map { $0.name }.joined(separator: " → "))。选中服务失败时按这个顺序换。")
            }
        } else if let defId = groupStore.defaultGroupId, let g = groupStore.group(id: defId) {
            if defaultCandidates.isEmpty {
                lines.append("默认 TTS 分组「\(g.name)」里没有可用的服务——先跟主人说 TTS 还没配好，让她去「设置 > Voice Services」里配。")
            } else {
                lines.append("默认 TTS 分组「\(g.name)」：")
                for (i, s) in defaultCandidates.enumerated() {
                    lines.append("  \(i + 1). \(s.name)（\(s.kind.displayName)·音色 \(s.voice)）")
                }
                lines.append("  合成时会按这个顺序自动 fallback：第一个挂了自动换下一个，你不用管。")
            }
        } else if let s = VoiceChain.firstUsableServiceAnywhere() {
            lines.append("当前 TTS 服务：\(s.name)（\(s.kind.displayName)·音色 \(s.voice)）。")
        }

        // 没进默认分组的备选服务也列出来，让模型知道还有别的声音。
        let inDefault = Set(defaultCandidates.map { $0.id })
        let others = services.filter { !inDefault.contains($0.id) }
        if !others.isEmpty {
            lines.append("备选服务（不在默认分组里）：\(others.map { "\($0.name)（音色 \($0.voice)）" }.joined(separator: "、"))。")
        }
        lines.append("")
        lines.append("调用方法：send_voice(text=要说的话，tool_title=一句话摘要)。text 写口语化的中文，直接是主人会听到的话，别带 markdown 符号；别太长，太长分段调多次。")
        lines.append("换声音：你可以用 send_voice 的 voice 参数点名这次用哪个服务、group 参数点名用哪个分组。名字只能从上面这份清单里挑，原样照抄（别自己编、别翻译）；清单外的会被拒绝。不传就用默认顺序，一般不用传。")
        lines.append("失败时：工具会明确报错。如实告诉主人这条语音没发出去，不要谎称已发送；可以建议她检查 TTS 服务配置。")
        return lines.joined(separator: "\n")
    }

    /// 用户这轮消息跟语音/TTS 相关时返回纸条，否则返回 nil。
    /// 宽松匹配：覆盖"让 AI 开口说话"这件事的各种说法，不做死关键词锁定。
    /// skipIntro = true 时跳过开头段（常驻声明已讲过，不重复）。
    static func paperIfRelevant(userMessage: String, skipIntro: Bool = false) -> String? {
        let t = userMessage.lowercased()
        // [B09-L08 2026-10-22] "声音" alone ("这个声音好听") pulled the whole
        // 300-char manual (every service, every voice id, the calling rules)
        // into the prompt for nothing — the standing capability line already
        // tells the model it has a voice. Keep only phrasings that actually ask
        // it to SPEAK.
        let triggers = [
            "发语音", "发条语音", "语音说", "用语音", "声音说", "朗读", "读出来",
            "念给我", "说给我听", "亲口", "tts", "voice", "speak", "播报", "哄睡",
        ]
        guard triggers.contains(where: { t.contains($0) }) else { return nil }
        return paperText(skipIntro: skipIntro)
    }
}
