import Foundation
import SwiftUI

// MARK: - 吃 ST 小酒馆的主题包
//
// [10-18 醒醒] 「我想要的自由度就和 st 小酒馆那样的，自己上传个 json 全局都变了，
// 不变的只有页面布局什么的。」
//
// ## 先说清楚 ST 到底是什么
//
// 拆了六个真实包（仿微博主页 / 小猫文件夹 / 水星纯白梦 / 给你的信 / 面包狗 / 仿日志），
// 每个都是 39 个键，但**颜色字段大部分 alpha 是 0**——真正的外观全在 `custom_css`，
// 2.8 万到 3.5 万字符、97 到 137 个选择器。所以：
//
// - ST 能改**每一个像素**，因为它是网页，CSS 随便写
// - 我们的是原生视图，接不了 `.mes::before` 那种伪元素和外链装饰图
//
// 能接的是**设计参数**：颜色、圆角、行高、字距、字号、模糊、头像形状、消息形态。
// 这份适配器就吃这些。CSS 里能解析的几何参数也一并抽出来。
//
// ## 字段对照（按 ST 源码 power-user.js 的 getThemeObject 核过）
//
// | ST 字段                     | 我们                      |
// |-----------------------------|---------------------------|
// | blur_tint_color             | canvas（页面底色）        |
// | chat_tint_color             | canvas 上再压一层          |
// | user_mes_blur_tint_color    | userBubble                |
// | bot_mes_blur_tint_color     | assistantBubble           |
// | main_text_color             | primaryText               |
// | italics / underline / quote | secondaryText（合并取一档）|
// | border_color                | border                    |
// | shadow_color / shadow_width | 阴影色与强度              |
// | blur_strength               | 卡片毛玻璃浓度            |
// | font_scale                  | 全局字号缩放              |
// | avatar_style (0-3)          | 头像形状 圆/方/圆角方/矩形 |
// | chat_display (0/1/2)        | 消息形态 平铺/气泡/文稿    |
// | custom_css                  | 抽 border-radius / line-height / letter-spacing |

enum SillyTavernTheme {

    /// 从一份 ST 主题 JSON 转成我们的色板 + 参数。
    struct Imported {
        var name: String
        var light: [AppearanceColorRole: String]
        var dark: [AppearanceColorRole: String]
        var fontScale: Double
        var avatarShape: AppearanceAvatarShape
        var chatDisplay: AppearanceChatDisplay
        var blurStrength: Double
        var shadowWidth: Double
        var lineHeight: Double?
        var letterSpacing: Double?
        var bubbleRadius: Double?
        /// [10-19 醒醒] ST 的 waifuMode → 我们的立绘模式。
        var novelMode: AppearanceNovelMode
        var warnings: [String]
    }

    enum ImportError: LocalizedError {
        case notJSON
        case notATheme(String)
        case noColours
        var errorDescription: String? {
            switch self {
            case .notJSON:
                return "这个文件不是 JSON。"
            case .notATheme(let detail):
                return "不像 ST 主题包：\(detail)"
            case .noColours:
                return "这个包里一个颜色都没读到。"
            }
        }
    }

    /// ST 的必备键。少一半以上就不是主题包。
    private static let knownKeys: Set<String> = [
        "name", "blur_strength", "main_text_color", "italics_text_color",
        "underline_text_color", "quote_text_color", "blur_tint_color",
        "chat_tint_color", "user_mes_blur_tint_color", "bot_mes_blur_tint_color",
        "shadow_color", "shadow_width", "border_color", "font_scale",
        "fast_ui_mode", "waifuMode", "avatar_style", "chat_display",
        "toastr_position", "noShadows", "chat_width", "timer_enabled",
        "timestamps_enabled", "timestamp_model_icon", "mesIDDisplay_enabled",
        "hideChatAvatars_enabled", "message_token_count_enabled",
        "expand_message_actions", "enableZenSliders", "enableLabMode",
        "hotswap_enabled", "custom_css", "bogus_folders",
        "zoomed_avatar_magnification", "reduced_motion", "compact_input_area",
        "show_swipe_num_all_messages", "click_to_edit", "media_display",
    ]

    static func parse(_ data: Data) throws -> Imported {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImportError.notJSON
        }
        let hit = knownKeys.filter { obj[$0] != nil }.count
        guard hit >= 6 else {
            throw ImportError.notATheme("39 个标准字段里只认出 \(hit) 个。")
        }
        var warnings: [String] = []

        // ---- 颜色 ----
        // ST 用 rgba(r,g,b,a)，我们内部是 8 位 hex。alpha 不是 1 的要么叠到
        // 底色上算等效色，要么直接丢——直接丢会让浅色包变成一片黑。
        func rgba(_ key: String) -> (hex: String, alpha: Double)? {
            guard let raw = obj[key] as? String else { return nil }
            return parseRGBA(raw)
        }

        let canvas = rgba("blur_tint_color")
        let chatTint = rgba("chat_tint_color")
        let userMes = rgba("user_mes_blur_tint_color")
        let botMes = rgba("bot_mes_blur_tint_color")
        let mainText = rgba("main_text_color")
        let italics = rgba("italics_text_color")
        let quote = rgba("quote_text_color")
        let border = rgba("border_color")
        let shadow = rgba("shadow_color")

        guard canvas != nil || userMes != nil || mainText != nil else {
            throw ImportError.noColours
        }

        // 底色：blur_tint 是页面底，chat_tint 是压在它上面的第二层。
        // 两者都半透明时，按 alpha 合成一个等效色。
        let canvasBase = canvas?.hex ?? "FFFFFF"
        let canvasAlpha = canvas?.alpha ?? 1
        let tintAlpha = chatTint?.alpha ?? 0
        let canvasHex: String
        if let tint = chatTint, tintAlpha > 0.01 {
            // 底色半透明时，先按白底合成，避免整页变透
            canvasHex = blend(canvasBase, over: "FFFFFF", alpha: canvasAlpha)
            _ = tint
        } else {
            canvasHex = blend(canvasBase, over: "FFFFFF", alpha: canvasAlpha)
        }

        // 气泡：alpha 0 表示"完全透明 = 不要底色"。这时用一个很淡的派生色，
        // 否则气泡会消失看不见。
        func bubbleHex(_ c: (hex: String, alpha: Double)?, fallback: String) -> String {
            guard let c else { return fallback }
            if c.alpha < 0.04 {
                // 全透明：给它一个比底色略深/略浅的派生色，保证还看得见
                return shade(canvasHex, by: isDark(canvasHex) ? 0.10 : -0.035)
            }
            return blend(c.hex, over: canvasHex, alpha: c.alpha)
        }

        let userBubble = bubbleHex(userMes, fallback: shade(canvasHex, by: -0.06))
        let assistantBubble = bubbleHex(botMes, fallback: shade(canvasHex, by: -0.03))

        let textHex = mainText.map { blend($0.hex, over: canvasHex, alpha: max(0.35, $0.alpha)) }
            ?? (isDark(canvasHex) ? "EDE8E4" : "3A322E")

        // 次要文字：ST 把斜体/下划线/引用分成三个色，我们只有一档 secondaryText。
        // 取三者里对比度最高的那个（最接近正文的那个反而不像"次要"）。
        let secondaryCandidates = [italics, quote].compactMap { $0 }
        let secondaryHex: String
        if let pick = secondaryCandidates.max(by: {
            abs(luminance($0.hex) - luminance(textHex)) < abs(luminance($1.hex) - luminance(textHex))
        }) {
            secondaryHex = blend(pick.hex, over: canvasHex, alpha: max(0.5, pick.alpha))
        } else {
            secondaryHex = isDark(canvasHex) ? "A79A93" : "8A7B74"
        }

        // 强调色：ST 主题包里没有 accent 字段，用引用色或文字色派生。
        let accentHex = (quote?.hex).map { blend($0, over: canvasHex, alpha: max(0.85, quote?.alpha ?? 1)) }
            ?? (isDark(canvasHex) ? "C9A6AE" : "B98591")

        // 边框：alpha 0 就是"不要边框"，我们用一个极淡的派生线。
        let borderHex: String
        if let b = border, b.alpha > 0.04 {
            borderHex = blend(b.hex, over: canvasHex, alpha: b.alpha)
        } else {
            borderHex = shade(canvasHex, by: isDark(canvasHex) ? 0.12 : -0.10)
        }

        let isDarkCanvas = isDark(canvasHex)
        let surfaceHex = isDarkCanvas ? shade(canvasHex, by: 0.055) : lighten(canvasHex, 0.022)
        let raisedHex = isDarkCanvas ? shade(canvasHex, by: 0.085) : lighten(canvasHex, 0.040)

        let light: [AppearanceColorRole: String] = [
            .canvas: canvasHex,
            .surface: surfaceHex,
            .raised: raisedHex,
            .mutedSurface: shade(canvasHex, by: isDarkCanvas ? 0.07 : -0.035),
            .iconTile: shade(canvasHex, by: isDarkCanvas ? 0.08 : -0.025),
            .chip: shade(canvasHex, by: isDarkCanvas ? 0.10 : -0.050),
            .field: isDarkCanvas ? shade(canvasHex, by: 0.06) : lighten(canvasHex, 0.014),
            .border: borderHex,
            .primaryText: textHex,
            .secondaryText: secondaryHex,
            .accent: accentHex,
            .userBubble: userBubble,
            .assistantBubble: assistantBubble,
            .success: isDarkCanvas ? "93B09A" : "6E8F76",
            .warning: isDarkCanvas ? "CDB183" : "B8935F",
            .destructive: isDarkCanvas ? "CB9292" : "B27070",
        ]

        // 深色版：如果原包本身就是深色，直接用同一套；否则按反相推导。
        let dark: [AppearanceColorRole: String]
        if isDarkCanvas {
            dark = light
        } else {
            let dc = shade(canvasHex, by: -0.78)
            dark = [
                .canvas: dc,
                .surface: shade(dc, by: 0.06),
                .raised: shade(dc, by: 0.10),
                .mutedSurface: shade(dc, by: 0.09),
                .iconTile: shade(dc, by: 0.10),
                .chip: shade(dc, by: 0.13),
                .field: shade(dc, by: 0.07),
                .border: shade(dc, by: 0.17),
                .primaryText: lighten(textHex, 0.70),
                .secondaryText: lighten(secondaryHex, 0.30),
                .accent: lighten(accentHex, 0.12),
                .userBubble: shade(userBubble, by: -0.62),
                .assistantBubble: shade(dc, by: 0.06),
                .success: "93B09A",
                .warning: "CDB183",
                .destructive: "CB9292",
            ]
        }

        // ---- 几何：从 custom_css 抽 ----
        let css = (obj["custom_css"] as? String) ?? ""
        let lineHeight = mostCommon(css, pattern: #"line-height:\s*([0-9.]+)"#).flatMap { Double($0) }
        let letterSpacing = mostCommon(css, pattern: #"letter-spacing:\s*(-?[0-9.]+)px"#).flatMap { Double($0) }
        let cssRadius = mostCommon(css, pattern: #"border-radius:\s*([0-9.]+)px"#).flatMap { Double($0) }
        if css.isEmpty {
            warnings.append("这个包没有 custom_css，外观只按颜色映射。")
        }

        // ---- 开关 ----
        let fontScale = clamp((obj["font_scale"] as? Double) ?? 1.0, 0.7, 1.35)
        let blurStrength = clamp((obj["blur_strength"] as? Double) ?? 0, 0, 30)
        let shadowWidth = clamp((obj["shadow_width"] as? Double) ?? 0, 0, 5)

        let avatarRaw = (obj["avatar_style"] as? Int) ?? 0
        let avatarShape: AppearanceAvatarShape = {
            switch avatarRaw {
            case 1: return .roundedSquare
            case 2: return .square
            case 3: return .roundedSquare
            default: return .circle
            }
        }()

        let displayRaw = (obj["chat_display"] as? Int) ?? 0
        let chatDisplay: AppearanceChatDisplay = {
            switch displayRaw {
            case 1: return .bubbles
            case 2: return .document
            default: return .flat
            }
        }()

        // [10-19 醒醒] waifuMode 现在真做了——照 ST 的行为：全屏立绘 +
        // 聊天窗压到底部 40%（mobile-styles.css:447）。
        let waifu = (obj["waifuMode"] as? Bool) == true
        if waifu {
            warnings.append("已开启立绘模式。记得在装扮页传一张角色立绘。")
        }

        return Imported(
            name: (obj["name"] as? String) ?? "ST 主题",
            light: light,
            dark: dark,
            fontScale: fontScale,
            avatarShape: avatarShape,
            chatDisplay: chatDisplay,
            blurStrength: blurStrength,
            shadowWidth: shadowWidth,
            lineHeight: lineHeight,
            letterSpacing: letterSpacing,
            bubbleRadius: cssRadius,
            novelMode: waifu ? .stage : .off,
            warnings: warnings
        )
    }

    // MARK: - 颜色工具

    /// `rgba(50, 50, 50, 1)` / `#RGB` / `rgb(...)` 都吃。
    static func parseRGBA(_ raw: String) -> (hex: String, alpha: Double)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("rgba(") || s.hasPrefix("rgb(") {
            let inner = s.drop(while: { $0 != "(" }).dropFirst().prefix(while: { $0 != ")" })
            let parts = inner.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count >= 3,
                  let r = Double(parts[0]), let g = Double(parts[1]), let b = Double(parts[2]) else {
                return nil
            }
            let a = parts.count >= 4 ? (Double(parts[3]) ?? 1) : 1
            func byte(_ v: Double) -> Int { Int(min(255, max(0, v.rounded()))) }
            return (String(format: "%02X%02X%02X", byte(r), byte(g), byte(b)), min(1, max(0, a)))
        }
        if s.hasPrefix("#") {
            let h = String(s.dropFirst())
            if h.count == 6, h.allSatisfy({ $0.isHexDigit }) { return (h.uppercased(), 1) }
            if h.count == 8, h.allSatisfy({ $0.isHexDigit }) {
                return (String(h.prefix(6)).uppercased(), 1)
            }
            if h.count == 3 {
                let d = h.map { "\($0)\($0)" }.joined()
                return (d.uppercased(), 1)
            }
        }
        return nil
    }

    /// `src` 按 alpha 压到 `dst` 上，返回等效实色。
    static func blend(_ src: String, over dst: String, alpha: Double) -> String {
        guard let s = rgb(src), let d = rgb(dst) else { return src }
        let a = min(1, max(0, alpha))
        func mix(_ x: Double, _ y: Double) -> Int { Int((x * a + y * (1 - a)).rounded()) }
        return String(format: "%02X%02X%02X",
                      mix(s.0, d.0), mix(s.1, d.1), mix(s.2, d.2))
    }

    /// 明度加减。负数是变暗，正数是变亮。
    static func shade(_ hex: String, by delta: Double) -> String {
        guard let c = rgb(hex) else { return hex }
        func adj(_ v: Double) -> Int {
            let target = delta >= 0 ? v + (255 - v) * delta : v * (1 + delta)
            return Int(min(255, max(0, target.rounded())))
        }
        return String(format: "%02X%02X%02X", adj(c.0), adj(c.1), adj(c.2))
    }

    /// 只往亮里推，用来做"底色加一点点白"。
    static func lighten(_ hex: String, _ amount: Double) -> String {
        shade(hex, by: max(0, amount))
    }

    static func rgb(_ hex: String) -> (Double, Double, Double)? {
        var h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF), Double((v >> 8) & 0xFF), Double(v & 0xFF))
    }

    static func luminance(_ hex: String) -> Double {
        guard let c = rgb(hex) else { return 0.5 }
        return (0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2) / 255
    }

    static func isDark(_ hex: String) -> Bool { luminance(hex) < 0.45 }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(hi, max(lo, v))
    }

    /// CSS 里某个属性出现最多的那个值——主题作者通常只用一个基准。
    private static func mostCommon(_ css: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = css as NSString
        let matches = re.matches(in: css, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for m in matches where m.numberOfRanges > 1 {
            let v = ns.substring(with: m.range(at: 1))
            counts[v, default: 0] += 1
        }
        return counts.max(by: { $0.value < $1.value })?.key
    }
}
