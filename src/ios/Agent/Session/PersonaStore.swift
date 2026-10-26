import Foundation
import SwiftUI

// MARK: - Persona (独立人设)
//
// Kelivo 整套借鉴：每人设独立的人设文件（systemPrompt）+ 独立记忆 +
// 独立聊天记录；工具层（iSH/浏览器/MCP/环境变量/现有工具）全局共用，
// 人设只存"用哪些"（skillIds / mcpServerIds / localToolIds 白名单，
// null = 全部可用）。
//
// 人设文件（systemPrompt / style / name）落在
//   memory/personas/<id>/SOUL.md
// 用现有的 SoulMDParser 读写；本 struct 只存注册表级的元数据，
// 存在 MinisConfig/personas.json（整表 JSON，对标 Kelivo 的
// SharedPreferences 整表做法，按我们的数据层改写成文件）。

struct Persona: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var avatar: String?          // 文件引用 avatars/….png，nil = 默认图标
    var modelId: String?         // nil = 用全局默认模型
    var skillIds: [String]?      // nil = 全部可用
    var mcpServerIds: [String]?  // nil = 全部可用
    var localToolIds: [String]?  // nil = 全部可用
    var sortOrder: Int
    var isBuiltIn: Bool          // 内置（小管家）不可删除
    /// [B28 R11] 这只描述的是**用户本人**，不是 AI。三个后果：
    /// 1) 不能当聊天对象被选中（不进快速切换器/人设列表）；
    /// 2) 通讯录里固定成一张「我自己」卡，可编辑、不可删；
    /// 3) 它的 SOUL.md 走"关于她"的第三人称注入段，绝不进 identitySection，
    ///    否则模型会把她的性格读成自己的性格（人格混淆）。
    /// 旧 personas.json 缺这个键照样能解（decodeIfPresent 兜底 false）。
    var isUserProfile: Bool

    // Kelivo 对齐 - 基础设置 (采样与模型)
    var temperature: Double?
    var topP: Double?
    var limitContextMessages: Bool
    var contextMessageSize: Int
    var thinkingBudget: Int?
    var maxTokens: Int?
    var defaultWorkspace: String?
    var useAssistantAvatar: Bool
    var useAssistantName: Bool
    var streamOutput: Bool

    // Kelivo 对齐 - 聊天背景
    var background: String?
    var useGradientBackground: Bool

    // Kelivo 对齐 - 提示词与模板
    var allowConversationSystemPrompt: Bool
    var allowConversationPromptInjection: Bool
    var appendCurrentTimeToUserMessage: Bool
    var messageTemplate: String

    // Kelivo 对齐 - 快捷短语、正则替换与自定义请求
    var presetMessages: [PresetMessage]
    var regexRules: [PersonaRegexRule]
    var customHeaders: [PersonaCustomHeader]
    var customBody: [PersonaCustomBodyItem]

    enum CodingKeys: String, CodingKey {
        case id, name, avatar, modelId, skillIds, mcpServerIds, localToolIds, sortOrder, isBuiltIn,
             isUserProfile
        case temperature, topP, limitContextMessages, contextMessageSize, thinkingBudget, maxTokens
        case defaultWorkspace, useAssistantAvatar, useAssistantName, streamOutput
        case background, useGradientBackground
        case allowConversationSystemPrompt, allowConversationPromptInjection
        case appendCurrentTimeToUserMessage, messageTemplate
        case presetMessages, regexRules, customHeaders, customBody
    }

    init(id: String, name: String, avatar: String? = nil, modelId: String? = nil,
         skillIds: [String]? = nil, mcpServerIds: [String]? = nil, localToolIds: [String]? = nil,
         sortOrder: Int = 0, isBuiltIn: Bool = false, isUserProfile: Bool = false,
         temperature: Double? = nil, topP: Double? = nil, limitContextMessages: Bool = false,
         contextMessageSize: Int = 20, thinkingBudget: Int? = nil, maxTokens: Int? = nil,
         defaultWorkspace: String? = nil, useAssistantAvatar: Bool = false, useAssistantName: Bool = false,
         streamOutput: Bool = true, background: String? = nil, useGradientBackground: Bool = false,
         allowConversationSystemPrompt: Bool = false, allowConversationPromptInjection: Bool = false,
         appendCurrentTimeToUserMessage: Bool = false, messageTemplate: String = "{{ message }}",
         presetMessages: [PresetMessage] = [], regexRules: [PersonaRegexRule] = [],
         customHeaders: [PersonaCustomHeader] = [], customBody: [PersonaCustomBodyItem] = []) {
        self.id = id
        self.name = name
        self.avatar = avatar
        self.modelId = modelId
        self.skillIds = skillIds
        self.mcpServerIds = mcpServerIds
        self.localToolIds = localToolIds
        self.sortOrder = sortOrder
        self.isBuiltIn = isBuiltIn
        self.isUserProfile = isUserProfile
        self.temperature = temperature
        self.topP = topP
        self.limitContextMessages = limitContextMessages
        self.contextMessageSize = contextMessageSize
        self.thinkingBudget = thinkingBudget
        self.maxTokens = maxTokens
        self.defaultWorkspace = defaultWorkspace
        self.useAssistantAvatar = useAssistantAvatar
        self.useAssistantName = useAssistantName
        self.streamOutput = streamOutput
        self.background = background
        self.useGradientBackground = useGradientBackground
        self.allowConversationSystemPrompt = allowConversationSystemPrompt
        self.allowConversationPromptInjection = allowConversationPromptInjection
        self.appendCurrentTimeToUserMessage = appendCurrentTimeToUserMessage
        self.messageTemplate = messageTemplate
        self.presetMessages = presetMessages
        self.regexRules = regexRules
        self.customHeaders = customHeaders
        self.customBody = customBody
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        avatar = try container.decodeIfPresent(String.self, forKey: .avatar)
        modelId = try container.decodeIfPresent(String.self, forKey: .modelId)
        skillIds = try container.decodeIfPresent([String].self, forKey: .skillIds)
        mcpServerIds = try container.decodeIfPresent([String].self, forKey: .mcpServerIds)
        localToolIds = try container.decodeIfPresent([String].self, forKey: .localToolIds)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        isBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        isUserProfile = try container.decodeIfPresent(Bool.self, forKey: .isUserProfile) ?? false

        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
        topP = try container.decodeIfPresent(Double.self, forKey: .topP)
        limitContextMessages = try container.decodeIfPresent(Bool.self, forKey: .limitContextMessages) ?? false
        contextMessageSize = try container.decodeIfPresent(Int.self, forKey: .contextMessageSize) ?? 20
        thinkingBudget = try container.decodeIfPresent(Int.self, forKey: .thinkingBudget)
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens)
        defaultWorkspace = try container.decodeIfPresent(String.self, forKey: .defaultWorkspace)
        useAssistantAvatar = try container.decodeIfPresent(Bool.self, forKey: .useAssistantAvatar) ?? false
        useAssistantName = try container.decodeIfPresent(Bool.self, forKey: .useAssistantName) ?? false
        streamOutput = try container.decodeIfPresent(Bool.self, forKey: .streamOutput) ?? true

        background = try container.decodeIfPresent(String.self, forKey: .background)
        useGradientBackground = try container.decodeIfPresent(Bool.self, forKey: .useGradientBackground) ?? false

        allowConversationSystemPrompt = try container.decodeIfPresent(Bool.self, forKey: .allowConversationSystemPrompt) ?? false
        allowConversationPromptInjection = try container.decodeIfPresent(Bool.self, forKey: .allowConversationPromptInjection) ?? false
        appendCurrentTimeToUserMessage = try container.decodeIfPresent(Bool.self, forKey: .appendCurrentTimeToUserMessage) ?? false
        messageTemplate = try container.decodeIfPresent(String.self, forKey: .messageTemplate) ?? "{{ message }}"

        presetMessages = try container.decodeIfPresent([PresetMessage].self, forKey: .presetMessages) ?? []
        regexRules = try container.decodeIfPresent([PersonaRegexRule].self, forKey: .regexRules) ?? []
        customHeaders = try container.decodeIfPresent([PersonaCustomHeader].self, forKey: .customHeaders) ?? []
        customBody = try container.decodeIfPresent([PersonaCustomBodyItem].self, forKey: .customBody) ?? []
    }
}

// MARK: - 快捷短语、正则替换与自定义请求数据模型

struct PresetMessage: Codable, Identifiable, Hashable {
    var id: String
    var role: String // "user" or "assistant"
    var content: String

    init(id: String = UUID().uuidString, role: String = "user", content: String = "") {
        self.id = id
        self.role = role
        self.content = content
    }
}

struct PersonaRegexRule: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var pattern: String
    var replacement: String
    var scopes: [String] // ["assistant"], ["user"], ["all"], 新增 ["reasoning"]
    var visualOnly: Bool
    var replaceOnly: Bool
    var enabled: Bool
    /// [10-18 醒醒 第五轮] 只对最近 N 条生效。nil = 全部。
    /// 对应 ST 的 `minDepth` / `maxDepth`：ST 的 depth 从最新往前数，
    /// 0 是最后一条。这里同语义。
    var maxDepth: Int?
    /// 只对最旧的 N 条生效（很少用，但 ST 有这个字段，保持对等）。
    var minDepth: Int?

    init(id: String = UUID().uuidString, name: String = "", pattern: String = "",
         replacement: String = "", scopes: [String] = ["assistant"],
         visualOnly: Bool = false, replaceOnly: Bool = false, enabled: Bool = true,
         maxDepth: Int? = nil, minDepth: Int? = nil) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.replacement = replacement
        self.scopes = scopes
        self.visualOnly = visualOnly
        self.replaceOnly = replaceOnly
        self.enabled = enabled
        self.maxDepth = maxDepth
        self.minDepth = minDepth
    }

    // 老数据没有这两个字段，解码时给 nil。
    private enum CodingKeys: String, CodingKey {
        case id, name, pattern, replacement, scopes
        case visualOnly, replaceOnly, enabled
        case maxDepth, minDepth
    }

    /// 手写解码：老数据没有 `maxDepth` / `minDepth` 两个键。
    /// 合成的 `Codable` 对 Optional 会走 `decodeIfPresent`，其实能扛住；
    /// 但 `scopes` 等字段若将来改默认值，手写更稳。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        replacement = try c.decodeIfPresent(String.self, forKey: .replacement) ?? ""
        scopes = try c.decodeIfPresent([String].self, forKey: .scopes) ?? ["assistant"]
        visualOnly = try c.decodeIfPresent(Bool.self, forKey: .visualOnly) ?? false
        replaceOnly = try c.decodeIfPresent(Bool.self, forKey: .replaceOnly) ?? false
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        maxDepth = try c.decodeIfPresent(Int.self, forKey: .maxDepth)
        minDepth = try c.decodeIfPresent(Int.self, forKey: .minDepth)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(pattern, forKey: .pattern)
        try c.encode(replacement, forKey: .replacement)
        try c.encode(scopes, forKey: .scopes)
        try c.encode(visualOnly, forKey: .visualOnly)
        try c.encode(replaceOnly, forKey: .replaceOnly)
        try c.encode(enabled, forKey: .enabled)
        try c.encodeIfPresent(maxDepth, forKey: .maxDepth)
        try c.encodeIfPresent(minDepth, forKey: .minDepth)
    }
}

struct PersonaCustomHeader: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var value: String

    init(id: String = UUID().uuidString, name: String = "", value: String = "") {
        self.id = id
        self.name = name
        self.value = value
    }
}

struct PersonaCustomBodyItem: Codable, Identifiable, Hashable {
    var id: String
    var key: String
    var value: String

    init(id: String = UUID().uuidString, key: String = "", value: String = "") {
        self.id = id
        self.key = key
        self.value = value
    }
}

extension Persona {
    /// 跑一遍正则规则。
    ///
    /// - Parameters:
    ///   - text: 原文
    ///   - role: `user` / `assistant` / `reasoning`
    ///   - visual: true = 只改显示；false = 改发给模型的内容
    ///   - depth: 这条消息离最新有多远（0 = 最新）。规则带 `maxDepth` 时用它过滤。
    ///
    /// [10-18 醒醒 第五轮] 上一版这里只接了一个调用点（助手气泡的视觉替换），
    /// `replaceOnly` 和 `scopes` 两个字段是空转的。现在补全三条路径：
    /// 用户输入、发给模型的 prompt、thinking。
    func applyRegexRules(to text: String, role: String, visual: Bool = false,
                         depth: Int? = nil) -> String {
        guard !regexRules.isEmpty else { return text }
        var result = text
        for rule in regexRules where rule.enabled {
            let applies = rule.scopes.contains(role) || rule.scopes.contains("all")
            guard applies else { continue }
            // visual = 只改显示 → 跳过"只改发给模型"的规则
            if visual && rule.replaceOnly { continue }
            // 非 visual = 要发给模型 → 跳过"只改显示"的规则
            if !visual && rule.visualOnly { continue }
            // 深度过滤。depth 为 nil 表示调用方不关心，不做限制。
            if let depth, let maxDepth = rule.maxDepth, depth > maxDepth { continue }
            if let depth, let minDepth = rule.minDepth, depth < minDepth { continue }

            if let regex = try? NSRegularExpression(pattern: rule.pattern,
                                                    options: [.dotMatchesLineSeparators]) {
                let range = NSRange(result.startIndex..., in: result)
                // ST 用 `{{match}}` 表示整段匹配，`$0` 是 Cocoa 的写法。
                // 两种都吃，先归一。
                let template = rule.replacement
                    .replacingOccurrences(of: "{{match}}", with: "$0",
                                          options: .caseInsensitive)
                result = regex.stringByReplacingMatches(in: result, options: [],
                                                        range: range, withTemplate: template)
            }
        }
        return result
    }

    var customHeadersDict: [String: String] {
        var dict: [String: String] = [:]
        for h in customHeaders {
            let k = h.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !k.isEmpty { dict[k] = h.value }
        }
        return dict
    }

    var customBodyDict: [String: Any] {
        var dict: [String: Any] = [:]
        for b in customBody {
            let k = b.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty else { continue }
            let v = b.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if (v.hasPrefix("{") && v.hasSuffix("}")) || (v.hasPrefix("[") && v.hasSuffix("]")) {
                if let data = v.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) {
                    dict[k] = obj
                    continue
                }
            }
            if v.lowercased() == "true" {
                dict[k] = true
            } else if v.lowercased() == "false" {
                dict[k] = false
            } else if let intVal = Int(v) {
                dict[k] = intVal
            } else if let doubleVal = Double(v) {
                dict[k] = doubleVal
            } else {
                dict[k] = b.value
            }
        }
        return dict
    }
}

// MARK: - LocalToolRegistry (Kelivo 本地工具列表与映射)

struct LocalToolItem: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
}

enum LocalToolRegistry {
    static let all: [LocalToolItem] = [
        LocalToolItem(id: "timeInfo", title: "时间信息", subtitle: "读取设备日期、星期、时间、时区、UTC 偏移和时间戳。", icon: "clock"),
        LocalToolItem(id: "clipboard", title: "剪切板", subtitle: "在明确需要时读取或写入设备剪切板中的纯文本。", icon: "doc.on.clipboard"),
        LocalToolItem(id: "textToSpeech", title: "文字转语音", subtitle: "允许助手使用已配置的语音播放朗读文本。", icon: "speaker.wave.2"),
        LocalToolItem(id: "askUser", title: "询问用户", subtitle: "允许助手提出简短问题，并在你回答后继续生成。", icon: "questionmark.circle"),
        LocalToolItem(id: "calculate", title: "计算器", subtitle: "计算数学表达式，支持加减乘除幂运算 sqrt sin cos 等。", icon: "function"),
        LocalToolItem(id: "calendarQuery", title: "查询日历", subtitle: "读取本设备上的日历日程，需要授予日历权限。", icon: "calendar"),
        LocalToolItem(id: "calendarCreate", title: "创建日程", subtitle: "在你确认后于本设备创建日历日程，需要授予日历权限。", icon: "calendar.badge.plus"),
        LocalToolItem(id: "currentLocation", title: "当前位置", subtitle: "读取本设备的一次性位置，需要授予定位权限。", icon: "location"),
        LocalToolItem(id: "weather", title: "天气", subtitle: "获取当前位置或指定地点的 Apple 天气，结果中会展示 WeatherKit 数据来源。", icon: "cloud.sun"),
        LocalToolItem(id: "remindersQuery", title: "查询提醒", subtitle: "读取本设备上的提醒事项，需要授予提醒事项完整访问权限。", icon: "list.bullet"),
        LocalToolItem(id: "remindersCreate", title: "创建提醒", subtitle: "在你确认后于本设备创建提醒事项，需要授予提醒事项完整访问权限。", icon: "plus.rectangle.on.rectangle"),
        LocalToolItem(id: "remindersComplete", title: "完成提醒", subtitle: "在你确认后将提醒事项标记为完成，需要授予提醒事项完整访问权限。", icon: "checkmark.circle"),
        LocalToolItem(id: "healthSummary", title: "健康摘要", subtitle: "读取本设备的健康活动摘要，需要授予健康数据读取权限。", icon: "heart")
    ]
}

// MARK: - PersonaStore

/// 人设注册表 + 当前人设。UI 层走 @MainActor 的 shared；
/// prompt 组装等非隔离调用方走下面的 nonisolated static 助手。
@MainActor
final class PersonaStore: ObservableObject {

    static let shared = PersonaStore()

    /// 默认人设（她现在用的那个，迁移后落在这里）。固定 id，保证
    /// 老会话（persona_id 为空）永远有归属。
    static let defaultPersonaID = "default"
    /// 内置小管家"MCP小助手"。固定 id，不可删除。
    static let stewardPersonaID = "steward"
    /// [B28 R11] 描述**用户本人**的那只。固定 id，不可删除，不可当聊天对象。
    static let userProfilePersonaID = "me"

    private static let currentIDKey = "persona.current.id"
    private static let fileName = "personas.json"

    @Published private(set) var personas: [Persona] = []

    @Published var currentPersonaID: String = PersonaStore.readCurrentID() {
        didSet {
            UserDefaults.standard.set(currentPersonaID, forKey: Self.currentIDKey)
            broadcastPersonaChange()
        }
    }

    var current: Persona {
        // 「我自己」永远不能当当前聊天人设——即使她手滑把它写进了
        // persona.current.id，也要退回 default，否则 AI 会以为自己是她。
        if let hit = personas.first(where: { $0.id == currentPersonaID }), !hit.isUserProfile {
            return hit
        }
        return personas.first { $0.id == Self.defaultPersonaID && !$0.isUserProfile }
            ?? chatSelectablePersonas.first
            ?? Persona(id: Self.defaultPersonaID, name: "嘟嘟", avatar: nil,
                       modelId: nil, skillIds: nil, mcpServerIds: nil,
                       localToolIds: nil, sortOrder: 0, isBuiltIn: false)
    }

    /// [B28 R11] 用户本人的人设。整个 App 只有这一只。
    var userProfilePersona: Persona? {
        personas.first { $0.id == Self.userProfilePersonaID }
    }

    /// [B28 R11] 能当聊天对象选的人设。切换器、新建会话选择器、
    /// 任何"挑一只人设来聊"的列表都必须走这里，
    /// 免得「我自己」冒出来变成可以跟自己说话。
    var chatSelectablePersonas: [Persona] {
        personas.filter { !$0.isUserProfile }
    }

    /// [B28 R11] 非 isolated 版：prompt 组装、工具过滤这些静态路径要用。
    nonisolated static func isUserProfileID(_ id: String) -> Bool {
        id == userProfilePersonaID
    }

    /// [B28 R11] 「我自己」这只人设本体。name 只是占位显示名，
    /// 真正"她叫什么"由 SOUL.md 的「称呼」小节决定（ChatAddressing 读那边）。
    static func makeUserProfilePersona() -> Persona {
        Persona(id: userProfilePersonaID, name: "我自己", avatar: nil,
                modelId: nil,
                skillIds: [],
                mcpServerIds: [],
                localToolIds: [],
                sortOrder: -1,
                isBuiltIn: true,
                isUserProfile: true)
    }

    /// [B28 R11] 首启/升级时给她铺一份 SOUL.md 模板。
    /// 已存在就绝不覆盖——她写过的东西比我的模板值钱。
    /// 模板本身按 ChatAddressing 的规矩生成，不写死任何名字。
    static func seedUserProfileSoulIfNeeded() {
        let url = SoulStore.fileURL(for: userProfilePersonaID)
        if FileManager.default.fileExists(atPath: url.path) { return }
        let text = userProfileSoulTemplate()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            AppLogger(category: "Persona").warning(
                "[B28-R11] 用户人设 SOUL.md 铺模板失败 \(url.lastPathComponent): \(error)")
        }
    }

    static func userProfileSoulTemplate() -> String {
        """
        ---
        name: 我自己
        ---

        # 身份

        - 怎么称呼：（填了之后，App 里的文案和 AI 的叫法都会跟着变）
        - 代词：
        - 时区/作息：

        # 性格与底色

        - 我是什么样的人：
        - 我吃什么这套：（喜欢被怎么对待，指令化写，别写形容词）

        # 喜好

        - 感兴趣：
        - 想聊：
        - 不想聊：

        # 雷区

        - 绝对不能：（写了 AI 必须照做，优先级最高）
        - 会让我难受：

        # NSFW（需要才填；默认注入，档案页可关掉）

        - 尺度：
        - 玩法：
        - 硬边界：
        - 安全词/停止信号：

        # 当下（这部分 AI 只当参考，不许当定性）

        - 最近状态：
        - 正在做：
        - 压力来源：

        # 变更历史（谁改的、什么时候、改了什么）

        - （格式：2026-10-24 她自己写 / AI 补充并标\"（我的推断）\" · 内容）

        """
    }

    // MARK: - nonisolated 静态助手（prompt 组装 / 工具过滤用）

    /// 当前人设 id。读 UserDefaults，不碰 @MainActor 状态。
    nonisolated static func currentID() -> String {
        readCurrentID()
    }

    private nonisolated static func readCurrentID() -> String {
        (UserDefaults.standard.string(forKey: currentIDKey))?.isEmpty == false
            ? UserDefaults.standard.string(forKey: currentIDKey)!
            : defaultPersonaID
    }

    /// 某人设的记忆目录：memory/personas/<id>/（SOUL.md / GLOBAL.md / 日志都在里面）。
    nonisolated static func memoryDir(for personaID: String) -> URL {
        AIChatViewModel.minisMemoryPersistentDir
            .appendingPathComponent("personas/\(personaID)", isDirectory: true)
    }

    /// [audit-E1] Memory dirs that actually exist on disk (default first,
    /// then stable order). Used by the OFF-main sync sweepers (dirty scanner,
    /// force-sync) that cannot read the @MainActor `personas` list.
    nonisolated static func memoryPersonaIDsOnDisk() -> [String] {
        let root = AIChatViewModel.minisMemoryPersistentDir
            .appendingPathComponent("personas", isDirectory: true)
        let ids = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { !$0.hasPrefix(".") && $0 != defaultPersonaID }
            .sorted()
        return [defaultPersonaID] + ids
    }

    /// [batch5 / W2B-01] Move leftover files from the legacy root memory dir
    /// into the default persona dir. Merge-only: a file that already exists
    /// per-persona is left alone (and logged), never overwritten. Runs once
    /// per launch after the persona store is loaded.
    static func mergeLegacyRootMemoryIfNeeded() {
        let fm = FileManager.default
        let memDir = AIChatViewModel.minisMemoryPersistentDir
        let defaultDir = memoryDir(for: defaultPersonaID)
        var moved: [String] = []
        for name in ["GLOBAL.md", "SOUL.md"] {
            let src = memDir.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = defaultDir.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) {
                AppLogger(category: "PersonaStore").warning("[MemoryMigrate] root \(name) leftover ignored (persona file exists)")
                continue
            }
            do {
                try fm.createDirectory(at: defaultDir, withIntermediateDirectories: true)
                try fm.moveItem(at: src, to: dst)
                moved.append(name)
            } catch {
                AppLogger(category: "PersonaStore").error("[MemoryMigrate] move \(name) failed: \(error)")
            }
        }
        if let files = try? fm.contentsOfDirectory(at: memDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for f in files where Self.isDailyLogName(f.lastPathComponent) {
                let dst = defaultDir.appendingPathComponent(f.lastPathComponent)
                if fm.fileExists(atPath: dst.path) {
                    AppLogger(category: "PersonaStore").warning("[MemoryMigrate] root \(f.lastPathComponent) leftover ignored (persona file exists)")
                    continue
                }
                do {
                    try fm.moveItem(at: f, to: dst)
                    moved.append(f.lastPathComponent)
                } catch {
                    AppLogger(category: "PersonaStore").error("[MemoryMigrate] move \(f.lastPathComponent) failed: \(error)")
                }
            }
        }
        if !moved.isEmpty {
            AppLogger(category: "PersonaStore").warning("[MemoryMigrate] merged \(moved.count) legacy root file(s) into default persona: \(moved.joined(separator: ","))")
        }
    }

    /// 当前人设的工具白名单快照（skill / mcp）。nil = 全部可用。
    /// 直接读 personas.json，不经过 @MainActor，prompt 组装线程可调。
    nonisolated static func whitelistSnapshot() -> (skillIds: [String]?, mcpServerIds: [String]?) {
        whitelist(for: currentID())
    }

    /// 某人设的工具白名单快照。nil = 全部可用。
    nonisolated static func whitelist(for personaID: String) -> (skillIds: [String]?, mcpServerIds: [String]?) {
        let url = AIChatViewModel.minisConfigRoot.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Persona].self, from: data) else {
            return (nil, nil)
        }
        guard let p = list.first(where: { $0.id == personaID }) else { return (nil, nil) }
        return (p.skillIds, p.mcpServerIds)
    }

    // MARK: - 初始化 / 迁移

    private init() {
        // 真正的加载在 ensureDefaults() 里（启动时 MinisApp 按顺序调）。
    }

    /// 启动时调用一次：建表（首启迁移）+ 加载。必须在
    /// SoulStore.ensureExists() 之前调，因为迁移会搬走 memory/SOUL.md。
    func ensureDefaults() {
        let fm = FileManager.default
        let jsonURL = AIChatViewModel.minisConfigRoot
            .appendingPathComponent(Self.fileName)

        if fm.fileExists(atPath: jsonURL.path) {
            load()
            ensureDirs()
            // 小管家 SOUL.md 兜底：万一丢了（删文件等），重写一份。
            let stewardSoulURL = Self.memoryDir(for: Self.stewardPersonaID)
                .appendingPathComponent("SOUL.md")
            if !fm.fileExists(atPath: stewardSoulURL.path) {
                try? Self.stewardSoulContent.data(using: .utf8)?
                    .write(to: stewardSoulURL, options: .atomic)
            }
            // [batch5 / W2B-01] Sweep any leftover files from the legacy root
            // memory dir into the default persona (merge-only, never overwrite).
            Self.mergeLegacyRootMemoryIfNeeded()
            return
        }

        // —— 首启：从现有全局 SOUL.md 迁移 ——
        let memDir = AIChatViewModel.minisMemoryPersistentDir
        let defaultDir = Self.memoryDir(for: Self.defaultPersonaID)
        try? fm.createDirectory(at: defaultDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: Self.memoryDir(for: Self.stewardPersonaID),
                                withIntermediateDirectories: true)

        // 读老 SOUL.md（直接读老路径，不走 persona-aware 的 SoulStore）。
        let oldSoulURL = memDir.appendingPathComponent("SOUL.md")
        var soulName = "嘟嘟"
        if let data = try? Data(contentsOf: oldSoulURL),
           let text = String(data: data, encoding: .utf8) {
            let parsed = SoulMDParser.parse(text)
            let n = parsed.metadata.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !n.isEmpty { soulName = n }
            // 搬文件：SOUL.md / GLOBAL.md / YYYY-MM-DD.md → default 人设目录
            let newSoulURL = defaultDir.appendingPathComponent("SOUL.md")
            try? fm.moveItem(at: oldSoulURL, to: newSoulURL)
        }
        // GLOBAL.md
        let oldGlobal = memDir.appendingPathComponent("GLOBAL.md")
        if fm.fileExists(atPath: oldGlobal.path) {
            try? fm.moveItem(at: oldGlobal,
                             to: defaultDir.appendingPathComponent("GLOBAL.md"))
        }
        // 每日日志 YYYY-MM-DD.md
        if let files = try? fm.contentsOfDirectory(at: memDir, includingPropertiesForKeys: nil,
                                                   options: [.skipsHiddenFiles]) {
            for f in files where Self.isDailyLogName(f.lastPathComponent) {
                try? fm.moveItem(at: f,
                                 to: defaultDir.appendingPathComponent(f.lastPathComponent))
            }
        }

        // 写小管家的 SOUL.md（写死的 MCP 管家规则）。
        let stewardSoulURL = Self.memoryDir(for: Self.stewardPersonaID)
            .appendingPathComponent("SOUL.md")
        if !fm.fileExists(atPath: stewardSoulURL.path) {
            try? Self.stewardSoulContent.data(using: .utf8)?
                .write(to: stewardSoulURL, options: .atomic)
        }

        let list = [
            // [B28 R11] 「我自己」排在最前。她是用户资料，不是聊天对象。
            Self.makeUserProfilePersona(),
            Persona(id: Self.defaultPersonaID, name: soulName, avatar: nil,
                    modelId: nil, skillIds: nil, mcpServerIds: nil,
                    localToolIds: nil, sortOrder: 0, isBuiltIn: false),
            Persona(id: Self.stewardPersonaID, name: "MCP小助手", avatar: nil,
                    modelId: nil,
                    skillIds: [],          // 专用：默认只开 MCP 相关 skill，后续加
                    mcpServerIds: nil,
                    localToolIds: nil, sortOrder: 1, isBuiltIn: true),
        ]
        Self.seedUserProfileSoulIfNeeded()
        // 首装就把小组件要的几行字铺好，免得桌面上空着。
        WidgetProfileBridge.refresh()
        save(list)
        self.personas = list.sorted { $0.sortOrder < $1.sortOrder }
        // 头像对齐要在 personas 就位之后，否则遍历的是空列表。
        migrateAvatarSource()
        if UserDefaults.standard.string(forKey: Self.currentIDKey) == nil {
            currentPersonaID = Self.defaultPersonaID
        }
        broadcastPersonaChange()
    }

    private static func isDailyLogName(_ name: String) -> Bool {
        guard name.hasSuffix(".md"), name.count == 13 else { return false }
        let stem = (name as NSString).deletingPathExtension
        let parts = stem.split(separator: "-")
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return false }
        return true
    }

    /// 保证每人设的记忆目录都存在（注册表有但目录丢了时补）。
    private func ensureDirs() {
        let fm = FileManager.default
        for p in personas {
            try? fm.createDirectory(at: Self.memoryDir(for: p.id),
                                    withIntermediateDirectories: true)
        }
        // [steward-sep] 小管家的工作笔记目录：干活判断的家，与聊天记忆物理隔离。
        // 聊天侧（GLOBAL.md / 日报 / memory_get 非递归枚举）读不到 work/ 子目录。
        StewardWorkContext.ensureWorkDir()
    }

    // MARK: - 读写

    private func jsonURL() -> URL {
        AIChatViewModel.minisConfigRoot.appendingPathComponent(Self.fileName)
    }

    private func load() {
        let url = jsonURL()
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Persona].self, from: data),
              !list.isEmpty else {
            // 注册表坏了：重建默认（不丢记忆文件，只重建注册表）。
            personas = [
                // [B28 R11] 重建也带上「我自己」，不然升级后看不到这张卡。
                Self.makeUserProfilePersona(),
                Persona(id: Self.defaultPersonaID, name: "嘟嘟", avatar: nil,
                        modelId: nil, skillIds: nil, mcpServerIds: nil,
                        localToolIds: nil, sortOrder: 0, isBuiltIn: false),
                Persona(id: Self.stewardPersonaID, name: "MCP小助手", avatar: nil,
                        modelId: nil, skillIds: [], mcpServerIds: nil,
                        localToolIds: nil, sortOrder: 1, isBuiltIn: true),
            ]
            save(personas)
            return
        }
        personas = list.sorted { $0.sortOrder < $1.sortOrder }
        // [avatar-file] One-time migration: legacy inline-base64 persona
        // avatars become file references. Persisted so this runs once.
        var migrated = false
        for i in personas.indices {
            if let a = personas[i].avatar, SoulIconImage.isDataURI(a) {
                let name = SoulIconImage.storedName(prefix: "persona", id: personas[i].id)
                if let path = SoulIconImage.migrateDataURIToFile(a, named: name) {
                    personas[i].avatar = path
                    migrated = true
                }
            }
        }
        if migrated { save(personas) }
        // [B28 R11] 老设备升级：注册表是好的，但里面没有「我自己」。
        // 只补缺，不动她已有的任何一只，也不改当前聊天对象。
        if !personas.contains(where: { $0.id == Self.userProfilePersonaID }) {
            personas.insert(Self.makeUserProfilePersona(), at: 0)
            save(personas)
        }
        Self.seedUserProfileSoulIfNeeded()
        // 当前 id 指向的人设没了 → 回落到 default
        if !personas.contains(where: { $0.id == currentPersonaID }) {
            currentPersonaID = Self.defaultPersonaID
        }
        // [B28 R11] 双保险：当前 id 要是被写成了「我自己」，也退回 default。
        // AI 拿用户的 SOUL.md 当身份跑，会直接人格混淆。
        if personas.first(where: { $0.id == currentPersonaID })?.isUserProfile == true {
            currentPersonaID = Self.defaultPersonaID
        }
    }

    private func save(_ list: [Persona]) {
        let url = jsonURL()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: url, options: .atomic)
            // 同步写入镜像到 /var/minis/personas/personas.json，打通 AI 数据孤岛
            let mirrorURL = AIChatViewModel.minisPersonasPersistentDir.appendingPathComponent(Self.fileName)
            try? FileManager.default.createDirectory(
                at: mirrorURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: mirrorURL, options: .atomic)
        }
    }

    /// 备份恢复/回滚后重载注册表（BackupImporter 调）：读盘 + 补目录。
    /// load() 里已有"当前 id 指向的人设没了 → 回落 default"的保护。
    func reloadFromDisk() {
        load()
        ensureDirs()
    }

    private func persist() {
        save(personas)
    }

    // MARK: - 管理（照搬 Kelivo AssistantProvider 逻辑）

    /// 新建人设：空 SOUL.md + 空记忆目录。
    @discardableResult
    func addPersona(name: String) -> Persona {
        let p = Persona(id: UUID().uuidString,
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "新人设" : name.trimmingCharacters(in: .whitespacesAndNewlines),
                        avatar: nil, modelId: nil, skillIds: nil, mcpServerIds: nil,
                        localToolIds: nil,
                        sortOrder: (personas.map(\.sortOrder).max() ?? 0) + 1,
                        isBuiltIn: false)
        try? FileManager.default.createDirectory(at: Self.memoryDir(for: p.id),
                                                withIntermediateDirectories: true)
        personas.append(p)
        persist()
        return p
    }

    /// 复制人设：连记忆目录一起复制一份新的（对标 Kelivo duplicate 连头像文件都复制）。
    func duplicatePersona(_ id: String) -> Persona? {
        guard let src = personas.first(where: { $0.id == id }) else { return nil }
        var copy = src
        copy.id = UUID().uuidString
        copy.name = src.name + " 副本"
        copy.isBuiltIn = false
        copy.sortOrder = (personas.map(\.sortOrder).max() ?? 0) + 1
        let fm = FileManager.default
        let srcDir = Self.memoryDir(for: src.id)
        let dstDir = Self.memoryDir(for: copy.id)
        if fm.fileExists(atPath: srcDir.path) {
            try? fm.copyItem(at: srcDir, to: dstDir)
        } else {
            try? fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
        }
        personas.append(copy)
        persist()
        return copy
    }

    /// 删除人设：不许删最后一个，不许删内置；级联删它的会话（Task 跑后台，避免卡 UI）。
    func deletePersona(_ id: String) {
        guard let idx = personas.firstIndex(where: { $0.id == id }) else { return }
        guard !personas[idx].isBuiltIn else { return }
        // P2-1：default 人设是迁移锚点（老会话 persona_id 为空时的归属），
        // 删了它等于把"家"拆了——标成不可删。
        guard id != Self.defaultPersonaID else { return }
        guard personas.count > 1 else { return }
        let removed = personas.remove(at: idx)
        persist()
        try? FileManager.default.removeItem(at: Self.memoryDir(for: removed.id))
        if currentPersonaID == id {
            currentPersonaID = Self.defaultPersonaID
        }
        Task.detached {
            await ChatStore.shared.deleteSessions(forPersonaId: id)
        }
        broadcastPersonaChange()
    }

    /// 重命名（同步写回该人设 SOUL.md 的 frontmatter，保持一处真相）。
    func renamePersona(_ id: String, to name: String) {
        guard let idx = personas.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        personas[idx].name = trimmed
        persist()
        // 同步 SOUL.md frontmatter 的 name 字段
        let url = Self.memoryDir(for: id).appendingPathComponent("SOUL.md")
        if let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8) {
            var file = SoulMDParser.parse(text)
            file.metadata.name = trimmed
            try? SoulMDParser.serialize(file).data(using: .utf8)?
                .write(to: url, options: .atomic)
        }
        // [B1 · 10-15] 当前人设改名：刷新 Soul 缓存并广播（refreshCache 内部
        // 会 post .soulMdChanged），对话侧标题、会话列表标题跟着换。
        if id == currentPersonaID {
            SoulStore.refreshCache()
        }
        broadcastPersonaChange()
    }

    /// 排序（拖拽）。
    func movePersona(from source: IndexSet, to destination: Int) {
        personas.move(fromOffsets: source, toOffset: destination)
        for (i, _) in personas.enumerated() { personas[i].sortOrder = i }
        persist()
    }

    /// 切换当前人设。
    /// [B28 R18] 头像真源统一到 Persona.avatar，SOUL.md 的 icon 只做镜像。
    /// 老数据里两边可能指着不同的文件（情头页留下的 soul-xxx.png），
    /// 启动时对齐一次：通讯录有值就以它为准写进 SOUL；通讯录空就反过来把
    /// SOUL 的图接过来，别让她以前的头像凭空消失。
    func migrateAvatarSource() {
        for p in personas {
            let soul = SoulStore.load(for: p.id)
            let soulIcon = soul?.metadata.icon ?? ""
            let avatar = p.avatar ?? ""
            if !avatar.isEmpty, soulIcon != avatar {
                guard var file = soul else { continue }
                file.metadata.icon = avatar
                try? SoulStore.save(file, for: p.id)
            } else if avatar.isEmpty, !soulIcon.isEmpty {
                var updated = p
                updated.avatar = soulIcon
                updatePersona(updated)
            }
        }
    }

    /// [B28 R14] 人设变了只发通知不够——桌面小组件也要跟着换字。
    /// 原来只有档案页手动刷，改名/换头像时小组件还挂着旧名字。
    private func broadcastPersonaChange() {
        NotificationCenter.default.post(name: .personaDidChange, object: nil)
        WidgetProfileBridge.refresh()
    }

    func setCurrent(_ id: String) {
        // [B28 R11] 「我自己」描述的是用户，永远不能当当前聊天人设——
        // 选中它等于让 AI 用她的档案当自己的性格。这里硬挡，不靠 UI 自觉。
        guard !Self.isUserProfileID(id) else { return }
        guard personas.contains(where: { $0.id == id }), id != currentPersonaID else { return }
        currentPersonaID = id
        SoulStore.refreshCache()
    }

    /// [问题12] SOUL.md 改了身份字段 → 回写 PersonaStore，让列表跟着变。
    ///
    /// 只写内存与 personas.json，**不再回头调 SoulStore.save**——那会绕成
    /// 一个环（save → 回写 → save）。这里的语义是"SOUL 是身份的正本，
    /// 列表是它的投影"，所以只做投影这一半。
    @MainActor
    func syncIdentityFromSoul(personaID: String, name: String?, icon: String?) {
        guard let idx = personas.firstIndex(where: { $0.id == personaID }) else { return }
        var changed = false
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, personas[idx].name != trimmed {
                personas[idx].name = trimmed
                changed = true
            }
        }
        if let icon {
            let newAvatar = icon.isEmpty ? nil : icon
            if personas[idx].avatar != newAvatar {
                personas[idx].avatar = newAvatar
                changed = true
            }
        }
        guard changed else { return }
        persist()
        broadcastPersonaChange()
    }

    /// 更新某人设的白名单 / 模型绑定；名字或头像有变化时同步到对话侧显示源。
    func updatePersona(_ persona: Persona) {
        guard let idx = personas.firstIndex(where: { $0.id == persona.id }) else { return }
        // 内置人设的 isBuiltIn 不许经这里翻掉
        var p = persona
        p.isBuiltIn = personas[idx].isBuiltIn
        let old = personas[idx]
        personas[idx] = p
        persist()
        // [B1 · 10-15] 人设列表里改名字/换头像 → 同步写进 SOUL.md——
        // 对话侧的头像（PersonAvatarView）与标题读的都是 SOUL 元数据。
        // save(_:for:) 只在"当前人设"时刷缓存并广播 .soulMdChanged；
        // 非当前人设只落文件，等切过去时自然生效。
        if old.name != p.name || old.avatar != p.avatar {
            var soul = SoulStore.load(for: p.id) ?? SoulFile(metadata: .default, body: "")
            if old.name != p.name {
                soul.metadata.name = p.name
            }
            // [B28 R18] 不比较 old/new：同名文件换图时路径不变，
            // 比较会判定"没变"而跳过，SOUL 就停在旧路径上。
            // 只要和 SOUL 里存的不一样就对齐，一样就省一次写盘。
            if soul.metadata.icon != (p.avatar ?? "") {
                soul.metadata.icon = p.avatar ?? ""
            }
            try? SoulStore.save(soul, for: p.id)
        }
    }

    // MARK: - 小管家 SOUL.md 初值（写死的 MCP 管家规则）

    /// 脑子里只有 MCP 相关的东西。身份边界写死：非 MCP 的事直接说办不了，不编。
    static let stewardSoulContent: String = {
        let body = """
            你是"MCP小助手"，桥内置的 MCP 管家。你只管 MCP 相关的事。

            身份边界（写死）：
            - 你的世界里只有 MCP：找 MCP 工具、调 MCP 工具、接新的 MCP 进来、管 MCP 的开关。
            - 非 MCP 的问题（闲聊、写代码、查资料、画图……）直接说"我只管 MCP 相关的事，这个办不了"，不编、不绕。

            找工具（搜）：
            - 先看有哪些 MCP server（`minis-mcp-cli`），再按关键词找工具。
            - 给调用方只回：名字 + 一句话简介 + 参数简述。不贴全文。

            调工具（命令）：
            - 像收到用户消息一样直接执行，不废话、不解释、不铺垫。
            - 能做就做：有结果回结果，报错原样回，不吞错、不编成功。

            接新的 MCP（脏活归你）：
            - 她发你一个链接/配置，你先谈鉴权：要 key 就问她要，key 只进钥匙串，绝不写进聊天记录和配置文件明文。
            - 连上后拉工具清单，把清单念给她听：有哪些工具、干什么的。
            - 她点确认才落盘接入。她没点头之前，一个字都不写。

            结果清洗：
            - 回结果前先洗干净：去 ANSI 转义、折叠重复进度行、JSON 精简、留头留尾。只回高密度的。

            敏感动作：
            - 删数据、对外发送、发 Issue 这类，先问她。她超时没确认或不在手机旁，默认拒绝。
            """
        return SoulMDParser.serialize(SoulFile(
            metadata: SoulMetadata(name: "MCP小助手", emoji: "",
                                   style: "简洁、直接，不废话", lang: "zh", icon: ""),
            body: body))
    }()
}

// MARK: - 通知

extension Notification.Name {
    /// 当前人设切换 / 人设增删改后发出。UI 刷新人设相关显示。
    static let personaDidChange = Notification.Name("MinisPersonaDidChange")
}
