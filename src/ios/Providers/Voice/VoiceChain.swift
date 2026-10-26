import Foundation

// MARK: - 谁在发声（唯一口径）
//
// [B09-V1 2026-10-22] 锐评第三轮：这一轮之前，"能不能出声"这件事在代码里有
// FIVE 份各自独立的实现——
//
//   1. VoiceOutputPlayer.resolvedServiceCandidates()   2 档：选中 → 分组
//   2. VoiceServicesView.summarySection.broken          3 档（多了"第一个启用服务"）
//   3. AIChatView.voiceSummary / voiceSummaryIsBroken   3 档
//   4. TTSPaper.standingCapability / paperText          3 档
//   5. AIChatViewModel.resolvedCloudTTSSelection        2 档 + 模型组
//
// 每次只改一处，其余四处立刻变成"界面说能发声、实际不出声"或"说明书说分组
// 优先、实际服务优先"。S-01 因此复发了三次（分组不读 → 分组压过选中 → 第一个
// 启用服务），每次都是同一个根因换了张皮。
//
// 现在只有一个函数回答这个问题。五处调用点全部改成调它，不许再各写一份。
//
// 顺序（三层，逐层让位）：
//   ① 用户在列表里点选的服务（打勾 = 就用这个）
//   ② 默认 TTS 分组里"真能出声"的成员，按分组顺序
//   ③ Voice Output 模型分组（VoiceProviderResolver 负责）
//   ④ 内建 System 语音（只在开关打开时）
//
// "真能出声" = 存在 + 启用 + 存了 key + 厂商能合成 + key 形状对（讯飞三段）。
// 缺任何一条都不算——算进去就会在播放时静默跳过，界面上的数字和标签全是假的。

enum VoiceChain {

    // MARK: - 单个服务：现在能不能出声

    /// 这个服务此刻能不能真的合成出音频。播放链、分组计数、摘要、标签、
    /// 纸条全部用这一个判定——不许再出现"列表说可用、播放时跳过"。
    static func canSpeak(_ service: TTSServiceOptions) -> Bool {
        TTSProviderBridge.canSynthesize(service)
    }

    // MARK: - 服务层候选（①②档）

    /// 显式点选的服务，且此刻真能出声；否则 nil。
    static func selectedService() -> TTSServiceOptions? {
        let store = TTSServiceStore.shared
        guard let s = store.selectedService() else { return nil }
        return canSpeak(s) ? s : nil
    }

    /// 默认分组的可用成员（按分组顺序，已过滤到"真能出声"）。
    static func defaultGroupMembers() -> [TTSServiceOptions] {
        TTSGroupStore.shared.usableDefaultGroupCandidates()
    }

    /// 有序去重的服务候选：选中服务 → 默认分组成员。
    /// 播放器、语音气泡、纸条、摘要、标签、引擎选择全部调这一个。
    static func serviceCandidates() -> [TTSServiceOptions] {
        var out: [TTSServiceOptions] = []
        var seen = Set<String>()
        if let s = selectedService(), seen.insert(s.id).inserted {
            out.append(s)
        }
        for s in defaultGroupMembers() where seen.insert(s.id).inserted {
            out.append(s)
        }
        return out
    }

    /// 服务层是否有任何能出声的目标。false 时播放器才该考虑模型分组 / System。
    static func hasServiceTarget() -> Bool {
        !serviceCandidates().isEmpty
    }

    /// 已配置的语音服务里（不限于选中/默认分组）第一个能出声的。
    /// 只用于给用户看"你还有一个能用但没选上的服务"这类提示，不进播放链。
    static func firstUsableServiceAnywhere() -> TTSServiceOptions? {
        TTSServiceStore.shared.services.first { canSpeak($0) }
    }

    // MARK: - 说明文案（给界面/纸条共用的一句"为什么没声音"）

    /// nil = 有东西能发声。非 nil = 不能发声的原因，已经本地化。
    ///
    /// [B09-V1 2026-10-22] 注意这里**故意不认**"随便哪个启用服务"。曾经有一版
    /// 在摘要/弹窗里加了这一档（"第一个启用服务"），播放链却没有 → 界面说
    /// "能发声"、点朗读静默。凡是播放链没有的档，判定里也不能有。
    ///
    /// `@MainActor` 因为要问模型分组那一档（VoiceProviderResolver 是主线程域）。
    /// 视图调用点本来就在主线程。
    @MainActor
    static func silenceReason() -> String? {
        let svcStore = TTSServiceStore.shared
        if let sel = svcStore.selectedService() {
            if !sel.enabled { return AppLocalized("Selected service \(sel.name) is turned off") }
            if !svcStore.hasAPIKey(for: sel) {
                return AppLocalized("Selected service \(sel.name) has no API key")
            }
            if !canSpeak(sel) {
                return AppLocalized("Selected service \(sel.name) cannot synthesize with the saved credentials")
            }
            return nil
        }
        if !defaultGroupMembers().isEmpty { return nil }
        // 第三档：Voice Output 模型分组。播放器在服务层零候选时会走到这里，
        // 所以判定里也必须认它，否则"模型分组配了声音"会被误报成没声音。
        if !VoiceProviderResolver.resolvedOutputCandidates().isEmpty { return nil }
        if VoiceOutputPreferences.systemVoiceAllowed { return nil }
        let groupStore = TTSGroupStore.shared
        if let gid = groupStore.defaultGroupId, let g = groupStore.group(id: gid) {
            let members = groupStore.candidates(for: g)
            if !members.isEmpty {
                return AppLocalized("Group \(g.name): all \(members.count) services are missing an API key")
            }
        }
        if svcStore.services.isEmpty { return AppLocalized("No voice service yet — add one below.") }
        // 有服务、但一个都没被选中、默认分组也没有 —— 这是"配了但没接线"，
        // 不是"配好了"。说清楚，别让人以为点了朗读会响。
        if let s = firstUsableServiceAnywhere() {
            return AppLocalized("Nothing selected: tap a service above (or set a default group) to make \(s.name) speak.")
        }
        return AppLocalized("Nothing can speak: every service is off or missing its API key, and System voice is muted.")
    }
}
