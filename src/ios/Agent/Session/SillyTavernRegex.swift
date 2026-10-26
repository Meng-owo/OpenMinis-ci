import Foundation

// MARK: - ST 正则包互通
//
// [10-18 醒醒] 「还有一个东西叫"正则"哦。利用一下，是不是不闭环了？」
//
// ## ST 那边长什么样
//
// 拆 ST 源码（`public/scripts/extensions/regex/engine.js`）拿到的结构：
//
// ```js
// export const regex_placement = {
//     USER_INPUT: 1, AI_OUTPUT: 2, SLASH_COMMAND: 3,
//     WORLD_INFO: 5, REASONING: 6,
// };
// ```
//
// 每个脚本：
// - `scriptName`       名字
// - `findRegex`        正则（带 /g 之类的修饰符）
// - `replaceString`    替换，支持 `{{match}}` 和 `$1` / `$<name>`
// - `placement`        数组，上面那些数字
// - `disabled`         是否禁用
// - `markdownOnly`     只改显示
// - `promptOnly`       只改发给模型
// - `runOnEdit`        编辑时也跑
// - `minDepth` / `maxDepth`  深度限制
// - `trimStrings`      替换后要再裁掉的串
//
// ## 我们这边
//
// `PersonaRegexRule` 的字段已经对齐了大部分：
// `pattern` / `replacement` / `scopes` / `visualOnly` / `replaceOnly` /
// `enabled` / `minDepth` / `maxDepth`。
//
// 差一个 `trimStrings`，这一版先不接（用得少）。
//
// ## 一个说明
//
// 我们的规则挂在**人设**上，ST 的是**全局**。导入时按"当前人设"落；
// 导出时也只出当前人设那套。要全局共享得等下一步架构调整。

enum SillyTavernRegex {

    // MARK: - 从 ST 读

    /// ST 的 `placement` 数字 → 我们的 `scopes` 字符串。
    ///
    /// 我们的 role 只有 user / assistant / reasoning 三种，ST 的
    /// SLASH_COMMAND 和 WORLD_INFO 没有对应概念，直接丢掉。
    private static func scopes(from placements: [Int]) -> [String] {
        var out: Set<String> = []
        for p in placements {
            switch p {
            case 1: out.insert("user")        // USER_INPUT
            case 2: out.insert("assistant")   // AI_OUTPUT
            case 6: out.insert("reasoning")   // REASONING
            default: break                     // 3 斜杠命令 / 5 世界书：没有对应
            }
        }
        // ST 没给 placement 时按"两边都改"处理，跟它的默认行为一致
        if out.isEmpty { out = ["user", "assistant"] }
        return Array(out).sorted()
    }

    /// 解析一份 ST 正则包（单个脚本或脚本数组都吃）。
    static func parse(_ data: Data) throws -> [PersonaRegexRule] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw ImportError.notJSON
        }
        // 数组 / 单个对象 / {"scripts": [...]} 三种形态都试
        let rawList: [[String: Any]]
        if let arr = obj as? [[String: Any]] {
            rawList = arr
        } else if let single = obj as? [String: Any] {
            if let inner = single["scripts"] as? [[String: Any]] {
                rawList = inner
            } else if single["findRegex"] != nil {
                rawList = [single]
            } else {
                throw ImportError.notARegexPack
            }
        } else {
            throw ImportError.notARegexPack
        }

        var out: [PersonaRegexRule] = []
        for raw in rawList {
            guard let find = raw["findRegex"] as? String, !find.isEmpty else { continue }
            let name = (raw["scriptName"] as? String) ?? "未命名规则"
            let replace = (raw["replaceString"] as? String) ?? ""
            let placements = (raw["placement"] as? [Int]) ?? []
            let disabled = (raw["disabled"] as? Bool) ?? false
            let markdownOnly = (raw["markdownOnly"] as? Bool) ?? false
            let promptOnly = (raw["promptOnly"] as? Bool) ?? false

            var rule = PersonaRegexRule(
                name: name,
                pattern: stripDelimiters(find),
                replacement: replace,
                scopes: scopes(from: placements),
                visualOnly: markdownOnly,
                replaceOnly: promptOnly,
                enabled: !disabled
            )
            // 深度：ST 的 -1 / null 表示不限
            if let maxD = raw["maxDepth"] as? Int, maxD >= 0 { rule.maxDepth = maxD }
            if let minD = raw["minDepth"] as? Int, minD >= 0 { rule.minDepth = minD }
            out.append(rule)
        }
        guard !out.isEmpty else { throw ImportError.noRules }
        return out
    }

    /// ST 的 `findRegex` 可能带 `/pattern/gimsuy` 这种壳，剥掉。
    ///
    /// 但**不能乱剥**：`/a/b/` 这种真带斜杠的 pattern 剥完就坏了。
    /// 只在"开头是 /、末尾是 /flags 形式"时才剥。
    static func stripDelimiters(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("/"), s.count >= 2 else { return s }
        // 找最后一个 /
        guard let lastSlash = s.lastIndex(of: "/"), lastSlash > s.startIndex else { return s }
        let body = String(s[s.index(after: s.startIndex)..<lastSlash])
        let flags = String(s[s.index(after: lastSlash)...])
        // flags 只能是 i g m s u y 这些
        guard flags.allSatisfy({ "gimsuy".contains($0) }) else { return s }
        // 里面还带未转义的 / 就说明剥错了
        guard !body.contains("/") || body.contains("\\/") else { return s }
        return body
    }

    // MARK: - 写成 ST

    /// 把我们的规则导出成 ST 能读的格式。
    ///
    /// 导出后可以在 ST 里直接导入，也能发给别人。
    static func export(_ rules: [PersonaRegexRule]) -> [[String: Any]] {
        rules.map { rule in
            var placements: [Int] = []
            if rule.scopes.contains("user") || rule.scopes.contains("all") { placements.append(1) }
            if rule.scopes.contains("assistant") || rule.scopes.contains("all") { placements.append(2) }
            if rule.scopes.contains("reasoning") { placements.append(6) }

            var obj: [String: Any] = [
                "id": rule.id,
                "scriptName": rule.name.isEmpty ? "未命名规则" : rule.name,
                "findRegex": rule.pattern,
                "replaceString": rule.replacement,
                "placement": placements,
                "disabled": !rule.enabled,
                "markdownOnly": rule.visualOnly,
                "promptOnly": rule.replaceOnly,
                "runOnEdit": true,
                "trimStrings": [] as [String],
            ]
            if let maxD = rule.maxDepth { obj["maxDepth"] = maxD }
            if let minD = rule.minDepth { obj["minDepth"] = minD }
            return obj
        }
    }

    /// 导出成可直接落盘的 JSON。
    static func exportJSON(_ rules: [PersonaRegexRule]) -> Data? {
        try? JSONSerialization.data(withJSONObject: export(rules),
                                    options: [.prettyPrinted, .sortedKeys])
    }

    enum ImportError: LocalizedError {
        case notJSON
        case notARegexPack
        case noRules

        var errorDescription: String? {
            switch self {
            case .notJSON:
                return "这个文件不是 JSON。"
            case .notARegexPack:
                return "不像 ST 的正则包：里面没有 findRegex 或 scripts。"
            case .noRules:
                return "这个包里一条能用的规则都没有。"
            }
        }
    }
}
