import Foundation
import SwiftUI

// MARK: - 全局正则替换规则
//
// [10-19 醒醒] 原来 `regexRules` 挂在 `Persona` 上（`PersonaStore.swift`），
// 换个角色就换一套规则，也没法单独导出。SillyTavern 的做法是**全局一份**，
// 换角色不变。
//
// 这里做全局存储。迁移策略：
//
//   - 首次加载时，把所有人设的 `regexRules` 合并搬进全局，按 `pattern` 去重
//     （同一条规则在三个人设里各存一份，是历史遗留的重复，不是三条规则）。
//   - 搬完**清空人设级的 `regexRules`**。
//
// 为什么不保留人设级做覆盖层：同一条规则会跑两遍。`$0` 被替换一次后再匹配
// 一次，像 `s/^\s+//` 这种幂等的还好，`s/^/> /` 会变成 `> > `。宁可先干净
// 地全搬，也不留一个会重复执行的坑。
//
// 原始数据在迁移前会整份备份到 `regex-rules.backup.json`，出问题能捞回来。

struct GlobalRegexRule: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var pattern: String
    var replacement: String
    /// ["assistant"] / ["user"] / ["reasoning"] / ["all"]
    var scopes: [String]
    var visualOnly: Bool
    var replaceOnly: Bool
    var enabled: Bool
    /// 只对最近 N 条生效。nil = 全部。0 = 最新一条（同 ST 语义）。
    var maxDepth: Int?
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

    private enum CodingKeys: String, CodingKey {
        case id, name, pattern, replacement, scopes
        case visualOnly, replaceOnly, enabled
        case maxDepth, minDepth
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
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

    /// 从人设级规则迁过来。
    init(legacy: PersonaRegexRule) {
        self.init(id: legacy.id, name: legacy.name, pattern: legacy.pattern,
                  replacement: legacy.replacement, scopes: legacy.scopes,
                  visualOnly: legacy.visualOnly, replaceOnly: legacy.replaceOnly,
                  enabled: legacy.enabled, maxDepth: legacy.maxDepth,
                  minDepth: legacy.minDepth)
    }
}

// MARK: - 存储

@MainActor
final class GlobalRegexStore: ObservableObject {

    static let shared = GlobalRegexStore()

    private static let fileName = "regex-rules.json"
    private static let backupName = "regex-rules.backup.json"
    private static let migratedKey = "regex.global.migrated.v1"

    @Published private(set) var rules: [GlobalRegexRule] = []

    private init() {
        load()
        // 迁移不能在 init 里做：`PersonaStore.shared.personas` 此时可能还是
        // 空的（`ensureDefaults()` 在 MinisApp 启动时才调）。留一个显式入口，
        // 由 MinisApp 在 `PersonaStore.ensureDefaults()` 之后调。
    }

    /// 启动时调一次。必须在 `PersonaStore.shared.ensureDefaults()` 之后。

    // MARK: 路径

    private var fileURL: URL {
        AIChatViewModel.minisConfigRoot.appendingPathComponent(Self.fileName)
    }

    private var backupURL: URL {
        AIChatViewModel.minisConfigRoot.appendingPathComponent(Self.backupName)
    }

    // MARK: 读写

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([GlobalRegexRule].self, from: data) else {
            rules = []
            return
        }
        rules = list
    }

    private func save() {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(rules) else { return }
        try? data.write(to: fileURL, options: .atomic)
        // 镜像一份到 /var/minis/personas/，跟 personas.json 一样打通 AI 数据孤岛。
        // 正则规则不含凭据，放这里安全。
        let mirror = AIChatViewModel.minisPersonasPersistentDir
            .appendingPathComponent(Self.fileName)
        try? FileManager.default.createDirectory(
            at: mirror.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: mirror, options: .atomic)
    }

    // MARK: 迁移

    /// 把各人设的 `regexRules` 合并进全局，然后清空人设级。
    ///
    /// 只跑一次：`UserDefaults` 里有个开关。就算跑一半崩了，下次启动会接着
    /// 跑（已经搬过来的人设规则已被清空，不会重复）。
    func migrateFromPersonasIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.migratedKey) else { return }

        let personas = PersonaStore.shared.personas
        let legacyPairs = personas.map { ($0.id, $0.regexRules) }
        let totalLegacy = legacyPairs.reduce(0) { $0 + $1.1.count }

        if totalLegacy > 0 {
            // 先备份整份原始数据，出问题能捞回来
            if let data = try? JSONEncoder().encode(personas) {
                try? FileManager.default.createDirectory(
                    at: backupURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try? data.write(to: backupURL, options: .atomic)
            }

            // 按 pattern 去重。同一条规则在几个人设里各存一份是历史遗留的
            // 重复，不是真的要跑多次。
            var seenPatterns = Set(rules.map { $0.pattern })
            var merged = rules
            for (_, legacyRules) in legacyPairs {
                for legacy in legacyRules {
                    let key = legacy.pattern
                    if seenPatterns.contains(key) { continue }
                    seenPatterns.insert(key)
                    merged.append(GlobalRegexRule(legacy: legacy))
                }
            }
            rules = merged
            save()

            // 清空人设级，避免同一条规则跑两遍（`$0` 会被替换两次）
            for persona in personas where !persona.regexRules.isEmpty {
                var updated = persona
                updated.regexRules = []
                PersonaStore.shared.updatePersona(updated)
            }
        }

        defaults.set(true, forKey: Self.migratedKey)
    }

    /// 备份恢复/回滚后重载。
    func reloadFromDisk() {
        load()
    }

    // MARK: 增删改

    func add(_ rule: GlobalRegexRule) {
        rules.append(rule)
        save()
    }

    func update(_ rule: GlobalRegexRule) {
        guard let idx = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[idx] = rule
        save()
    }

    func remove(id: String) {
        rules.removeAll { $0.id == id }
        save()
    }

    func setEnabled(_ enabled: Bool, id: String) {
        guard let idx = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[idx].enabled = enabled
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        rules.move(fromOffsets: source, toOffset: destination)
        save()
    }

    // MARK: 执行

    /// 跑一遍全局规则。签名跟老的 `Persona.applyRegexRules` 对齐，
    /// 调用点改一行就能换过来。
    ///
    /// - Parameters:
    ///   - text: 原文
    ///   - role: `user` / `assistant` / `reasoning`
    ///   - visual: true = 只改显示；false = 改发给模型的内容
    ///   - depth: 这条消息离最新有多远（0 = 最新）
    func apply(to text: String, role: String, visual: Bool = false,
               depth: Int? = nil) -> String {
        guard !rules.isEmpty else { return text }
        var result = text
        for rule in rules where rule.enabled {
            let applies = rule.scopes.contains(role) || rule.scopes.contains("all")
            guard applies else { continue }
            // visual = 只改显示 → 跳过"只改发给模型"的规则
            if visual && rule.replaceOnly { continue }
            // 非 visual = 要发给模型 → 跳过"只改显示"的规则
            if !visual && rule.visualOnly { continue }
            // 深度过滤。depth 为 nil 表示调用方不关心，不做限制。
            if let depth, let maxDepth = rule.maxDepth, depth > maxDepth { continue }
            if let depth, let minDepth = rule.minDepth, depth < minDepth { continue }

            guard !rule.pattern.isEmpty else { continue }
            if let regex = try? NSRegularExpression(pattern: rule.pattern,
                                                    options: [.dotMatchesLineSeparators]) {
                let range = NSRange(result.startIndex..., in: result)
                // ST 用 `{{match}}` 表示整段匹配，`$0` 是 Cocoa 的写法。
                let template = rule.replacement
                    .replacingOccurrences(of: "{{match}}", with: "$0",
                                          options: .caseInsensitive)
                result = regex.stringByReplacingMatches(in: result, options: [],
                                                        range: range, withTemplate: template)
            }
        }
        return result
    }
}
