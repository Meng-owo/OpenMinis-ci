import Foundation
import SwiftUI
import UIKit

// MARK: - 色阶层
//
// [10-18 醒醒] 「计划够不够完善，目光放长远一点」。
//
// ## 为什么要有这一层
//
// 原来 17 个角色是**孤立**的：`canvas` / `surface` / `raised` / `iconTile` /
// `chip` / `field` …… 每个都得手写一个值。后果很直接——上一轮那个 bug：
// 「卡片换颜色，AI 消息下面的图标也换颜色了」。根因不是分组起错，是
// `surface` 和 `iconTile` 之间没有推导关系，只能各自写死，写的时候还容易
// 挂错。
//
// ## 学的是谁
//
// **Radix Colors** 的 12 步语义色阶。每一步绑定一种用途，不是随便排的：
//
//   1  App background          页面底
//   2  Subtle background       卡片、微弱的组件底
//   3  UI element background   组件默认态
//   4  Hovered UI element      悬停
//   5  Active / Selected       按下、选中
//   6  Subtle borders          分隔线、卡片描边
//   7  UI element border       交互组件的边框、焦点环
//   8  Hovered UI element border
//   9  Solid backgrounds       实心填充（最纯的那一步）
//   10 Hovered solid           实心填充的悬停
//   11 Low-contrast text       次要文字
//   12 High-contrast text      主文字
//
// **Material 3** 的 on- 配对：颜色不是单独存在的，是成对的。`primary` 一定
// 配一个 `on primary`。M3 原话：「Color roles ensure accessibility — these
// color pairs provide an accessible minimum 3:1 contrast.」
//
// **WCAG 2.2** 的硬数字：正文 4.5:1，大字（≥18pt 或 14pt 粗体）3:1。而且
// 明确说不能四舍五入——4.499 不算过。
//
// ## 这一层做什么
//
// 1. 把 17 个角色**映射**到 12 步（`RoleScaleSlot`）
// 2. 给一个主色，**推导**整条 12 步色阶
// 3. 生成后**校验**对比度，不达标自动校正
// 4. 老的逐角色覆盖仍然有效（她是手调的，得尊重）

// MARK: - 12 步

/// Radix 那套 12 步语义色阶。步数本身就说明用途。
enum AppearanceScaleStep: Int, CaseIterable, Identifiable {
    case appBackground = 1
    case subtleBackground = 2
    case elementBackground = 3
    case elementHover = 4
    case elementActive = 5
    case subtleBorder = 6
    case elementBorder = 7
    case elementBorderHover = 8
    case solid = 9
    case solidHover = 10
    case lowContrastText = 11
    case highContrastText = 12

    var id: Int { rawValue }

    var useCase: String {
        switch self {
        case .appBackground: return AppLocalized("页面底")
        case .subtleBackground: return AppLocalized("卡片、微弱组件底")
        case .elementBackground: return AppLocalized("组件默认态")
        case .elementHover: return AppLocalized("悬停")
        case .elementActive: return AppLocalized("按下、选中")
        case .subtleBorder: return AppLocalized("分隔线、卡片描边")
        case .elementBorder: return AppLocalized("交互组件边框、焦点环")
        case .elementBorderHover: return AppLocalized("悬停时的边框")
        case .solid: return AppLocalized("实心填充（最纯）")
        case .solidHover: return AppLocalized("实心填充悬停")
        case .lowContrastText: return AppLocalized("次要文字")
        case .highContrastText: return AppLocalized("主文字")
        }
    }
}

// MARK: - 角色 → 色阶

extension AppearanceColorRole {
    /// 这个角色落在 12 步的哪一步。
    ///
    /// 几个角色共用一个步数是故意的——Radix 也说 1 和 2 可以互换着用。
    /// 重要的是**同类东西落在同一步**，这样推导出来的关系才稳。
    var scaleSlot: AppearanceScaleStep {
        switch self {
        case .canvas:            return .appBackground      // 1
        case .surface:           return .subtleBackground   // 2
        case .raised:            return .subtleBackground   // 2（浮层比卡片再亮一档，见下面 offset）
        case .field:             return .subtleBackground   // 2
        case .mutedSurface:      return .elementBackground  // 3
        case .iconTile:          return .elementBackground  // 3
        case .chip:              return .elementHover       // 4
        case .border:            return .subtleBorder       // 6
        case .accent:            return .solid              // 9
        case .userBubble:        return .elementActive      // 5（气泡是个"选中"质感的块）
        case .assistantBubble:   return .subtleBackground   // 2
        case .secondaryText:     return .lowContrastText    // 11
        case .primaryText:       return .highContrastText   // 12
        // 状态色不参与主色推导，它们有自己的色相（绿/黄/红）。
        case .success, .warning, .destructive:
            return .solid
        }
    }

    /// 同一步里需要再挪一点的（`raised` 要比 `surface` 亮一档）。
    var scaleOffset: Int {
        switch self {
        case .raised:        return 1     // 比卡片再亮
        case .field:         return 0
        case .assistantBubble: return 0
        default:             return 0
        }
    }

    /// 状态色自己定色相，不跟主色走。
    var isStatusColor: Bool {
        self == .success || self == .warning || self == .destructive
    }
}

// MARK: - 推导

enum AppearanceScale {

    /// 从主色推导一整条 12 步色阶。
    ///
    /// - Parameters:
    ///   - seed: 主色，十六进制。这是唯一需要她定的东西。
    ///   - dark: 深色模式。深色下色阶整体反相。
    ///
    /// 推导规则来自 Radix 的实际做法：色相固定，饱和度随步数变化
    /// （1-2 最低，9 最高，12 回落到很低），明度单调变化。
    static func derive(seed: String, dark: Bool) -> [AppearanceScaleStep: String] {
        guard let hsl = HSL(hex: seed) else {
            return defaultScale(dark: dark)
        }

        // 主色是第 9 步。它的饱和度和明度就是基准。
        let baseSat = max(0.18, min(0.62, hsl.s))
        let baseLight = hsl.l

        // 深色模式下，整套明度轴要翻转过来：底色深、文字浅。
        // 但色相和饱和度关系不变——这就是为什么深色不是简单反相。
        var steps: [AppearanceScaleStep: String] = [:]

        if dark {
            // 深色：1 最深，12 最亮
            steps[.appBackground]      = HSL(h: hsl.h, s: baseSat * 0.30, l: 0.085).hex
            steps[.subtleBackground]   = HSL(h: hsl.h, s: baseSat * 0.32, l: 0.125).hex
            steps[.elementBackground]  = HSL(h: hsl.h, s: baseSat * 0.34, l: 0.170).hex
            steps[.elementHover]       = HSL(h: hsl.h, s: baseSat * 0.36, l: 0.205).hex
            steps[.elementActive]      = HSL(h: hsl.h, s: baseSat * 0.38, l: 0.245).hex
            steps[.subtleBorder]       = HSL(h: hsl.h, s: baseSat * 0.34, l: 0.255).hex
            steps[.elementBorder]      = HSL(h: hsl.h, s: baseSat * 0.36, l: 0.315).hex
            steps[.elementBorderHover] = HSL(h: hsl.h, s: baseSat * 0.38, l: 0.375).hex
            steps[.solid]              = HSL(h: hsl.h, s: baseSat * 0.85, l: 0.640).hex
            steps[.solidHover]         = HSL(h: hsl.h, s: baseSat * 0.85, l: 0.700).hex
            steps[.lowContrastText]    = HSL(h: hsl.h, s: baseSat * 0.28, l: 0.680).hex
            steps[.highContrastText]   = HSL(h: hsl.h, s: baseSat * 0.16, l: 0.940).hex
        } else {
            // 浅色：1 最浅，12 最深
            steps[.appBackground]      = HSL(h: hsl.h, s: baseSat * 0.26, l: 0.972).hex
            steps[.subtleBackground]   = HSL(h: hsl.h, s: baseSat * 0.20, l: 0.988).hex
            steps[.elementBackground]  = HSL(h: hsl.h, s: baseSat * 0.32, l: 0.945).hex
            steps[.elementHover]       = HSL(h: hsl.h, s: baseSat * 0.36, l: 0.915).hex
            steps[.elementActive]      = HSL(h: hsl.h, s: baseSat * 0.42, l: 0.885).hex
            steps[.subtleBorder]       = HSL(h: hsl.h, s: baseSat * 0.34, l: 0.870).hex
            steps[.elementBorder]      = HSL(h: hsl.h, s: baseSat * 0.38, l: 0.795).hex
            steps[.elementBorderHover] = HSL(h: hsl.h, s: baseSat * 0.40, l: 0.730).hex
            steps[.solid]              = HSL(h: hsl.h, s: baseSat, l: baseLight).hex
            steps[.solidHover]         = HSL(h: hsl.h, s: baseSat, l: min(0.86, baseLight + 0.055)).hex
            steps[.lowContrastText]    = HSL(h: hsl.h, s: baseSat * 0.34, l: 0.505).hex
            steps[.highContrastText]   = HSL(h: hsl.h, s: baseSat * 0.28, l: 0.215).hex
        }

        return steps
    }

    /// 种子无效时的兜底（就是现在内置那套暖纸）。
    static func defaultScale(dark: Bool) -> [AppearanceScaleStep: String] {
        if dark {
            return [
                .appBackground: "1A1716", .subtleBackground: "242020",
                .elementBackground: "2F2A28", .elementHover: "362F2C",
                .elementActive: "3D3532", .subtleBorder: "403836",
                .elementBorder: "4C4340", .elementBorderHover: "5A504C",
                .solid: "C99BA6", .solidHover: "D4AAB3",
                .lowContrastText: "B5A8A1", .highContrastText: "F2EDE9",
            ]
        }
        return [
            .appBackground: "F7F4F1", .subtleBackground: "FDFCFA",
            .elementBackground: "F1EBE6", .elementHover: "EDE2DC",
            .elementActive: "E8DBD4", .subtleBorder: "E3DAD4",
            .elementBorder: "CFC2BA", .elementBorderHover: "B9A9A0",
            .solid: "B98591", .solidHover: "C4939E",
            .lowContrastText: "8A7B74", .highContrastText: "3A322E",
        ]
    }

    /// 把一条色阶摊回 17 个角色。
    static func roles(from scale: [AppearanceScaleStep: String],
                      dark: Bool) -> [AppearanceColorRole: String] {
        var out: [AppearanceColorRole: String] = [:]
        for role in AppearanceColorRole.allCases where !role.isStatusColor {
            guard let base = scale[role.scaleSlot] else { continue }
            if role.scaleOffset == 0 {
                out[role] = base
            } else {
                // 同一步里再挪一档：浅色往上推，深色往下推
                out[role] = AppearanceContrast.shade(base, by: dark ? -0.02 : 0.014)
            }
        }
        // 状态色不跟主色，但也给深色版
        out[.success] = dark ? "93B09A" : "7C9A83"
        out[.warning] = dark ? "CDB183" : "C0A176"
        out[.destructive] = dark ? "CB9292" : "B87C7C"
        return out
    }
}

// MARK: - 对比度

enum AppearanceContrast {

    /// WCAG 相对亮度。
    static func luminance(_ hex: String) -> Double {
        guard let c = RGB(hex: hex) else { return 0.5 }
        func channel(_ v: Double) -> Double {
            let s = v / 255
            return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }

    /// 两个颜色的对比度。1.0 到 21.0。
    ///
    /// WCAG 明确要求不四舍五入（4.499 不算过 4.5），所以这里不做 round。
    static func ratio(_ a: String, on b: String) -> Double {
        let la = luminance(a), lb = luminance(b)
        let hi = max(la, lb), lo = min(la, lb)
        return (hi + 0.05) / (lo + 0.05)
    }

    /// 正文要求 4.5:1，大字 3:1。
    ///
    /// **故意不带 raw value**：Swift 的 `RawRepresentable` 不允许两个 case
    /// 共用同一个 raw value，而 `large` 和 `ui` 都该是 3:1。CI 报过
    /// `raw value for enum case is not unique`，就是这里。
    enum Level {
        case body
        case large
        case ui
    }

    static func threshold(_ level: Level) -> Double {
        switch level {
        case .body:  return 4.5
        case .large: return 3.0
        case .ui:    return 3.0
        }
    }

    static func passes(_ fg: String, on bg: String, level: Level) -> Bool {
        ratio(fg, on: bg) >= threshold(level)
    }

    /// 把前景色往"更容易看清"的方向推，直到达标。
    ///
    /// 这是摇骰子和导入主题包时的保险：**生成的颜色一定看得清**。
    /// 手动调色不走这里——她自己挑的，尊重她的选择。
    ///
    /// - Returns: 校正后的颜色；推到头也不达标就返回能拿到的最好那个。
    static func enforce(_ fg: String, on bg: String,
                        level: Level = .body,
                        maxIterations: Int = 24) -> String {
        if passes(fg, on: bg, level: level) { return fg }
        guard let start = HSL(hex: fg) else { return fg }

        // 背景亮就把前景压暗，背景暗就把前景提亮。
        let bgIsLight = luminance(bg) > 0.5
        let step = bgIsLight ? -0.035 : 0.035

        var best = fg
        var bestRatio = ratio(fg, on: bg)
        var current = start

        for _ in 0..<maxIterations {
            let l = current.l + step
            if l <= 0.02 || l >= 0.99 { break }
            current = HSL(h: current.h, s: current.s, l: l)
            let candidate = current.hex
            let r = ratio(candidate, on: bg)
            if r > bestRatio {
                bestRatio = r
                best = candidate
            }
            if r >= threshold(level) { return candidate }
        }
        return best
    }

    /// 明度加减。跟 `SillyTavernTheme.shade` 同语义，这里独立一份免得跨文件依赖。
    static func shade(_ hex: String, by delta: Double) -> String {
        guard let c = RGB(hex: hex) else { return hex }
        func adj(_ v: Double) -> Int {
            let target = delta >= 0 ? v + (255 - v) * delta : v * (1 + delta)
            return Int(min(255, max(0, target.rounded())))
        }
        return String(format: "%02X%02X%02X", adj(c.r), adj(c.g), adj(c.b))
    }

    /// 一组配对里哪些不达标。给装扮页显示"这组看不清"用。
    static func audit(_ colors: [AppearanceColorRole: String]) -> [String] {
        var issues: [String] = []
        let pairs: [(AppearanceColorRole, AppearanceColorRole, Level)] = [
            (.primaryText, .canvas, .body),
            (.primaryText, .surface, .body),
            (.primaryText, .raised, .body),
            (.primaryText, .userBubble, .body),
            (.primaryText, .assistantBubble, .body),
            (.primaryText, .field, .body),
            (.secondaryText, .canvas, .body),
            (.secondaryText, .surface, .body),
        ]
        for (fg, bg, level) in pairs {
            guard let f = colors[fg], let b = colors[bg] else { continue }
            let r = ratio(f, on: b)
            if r < threshold(level) {
                issues.append(String(format: "%@ 压在 %@ 上只有 %.2f:1，要 %.1f:1",
                                     fg.title, bg.title, r, threshold(level)))
            }
        }
        return issues
    }
}

// MARK: - HSL / RGB

struct HSL {
    var h: Double   // 0...360
    var s: Double   // 0...1
    var l: Double   // 0...1

    init(h: Double, s: Double, l: Double) {
        self.h = h.truncatingRemainder(dividingBy: 360)
        self.s = min(1, max(0, s))
        self.l = min(1, max(0, l))
    }

    init?(hex: String) {
        guard let c = RGB(hex: hex) else { return nil }
        let r = c.r / 255, g = c.g / 255, b = c.b / 255
        let mx = max(r, g, b), mn = min(r, g, b)
        let delta = mx - mn
        var hh: Double = 0
        if delta > 0 {
            if mx == r { hh = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6)) }
            else if mx == g { hh = 60 * (((b - r) / delta) + 2) }
            else { hh = 60 * (((r - g) / delta) + 4) }
        }
        if hh < 0 { hh += 360 }
        let ll = (mx + mn) / 2
        let ss = delta == 0 ? 0 : delta / (1 - abs(2 * ll - 1))
        self.init(h: hh, s: ss, l: ll)
    }

    var hex: String {
        let c = 1 - abs(2 * l - 1)
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        var r: Double, g: Double, b: Double
        switch h {
        case ..<60:    (r, g, b) = (c, x, 0)
        case ..<120:   (r, g, b) = (x, c, 0)
        case ..<180:   (r, g, b) = (0, c, x)
        case ..<240:   (r, g, b) = (0, x, c)
        case ..<300:   (r, g, b) = (x, 0, c)
        default:       (r, g, b) = (c, 0, x)
        }
        func byte(_ v: Double) -> Int { Int((min(1, max(0, v + m)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}

struct RGB {
    var r: Double, g: Double, b: Double

    init?(hex: String) {
        var h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.r = Double((v >> 16) & 0xFF)
        self.g = Double((v >> 8) & 0xFF)
        self.b = Double(v & 0xFF)
    }
}

extension Color {
    /// 转成六位十六进制。`ColorPicker` 选完要存成字符串，用它。
    ///
    /// 走 `UIColor` 取分量，跟 `AppearanceStudio.hex()` 的存储格式一致。
    var hexString: String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}

// MARK: - 新增的可调维度
//
// [10-18 醒醒] 「连选项的背景都可以改颜色或者图片，而不是一直纯白色的那种。」
//
// 这四样是从 ST 主题包里能抽出来、原生视图也接得住的部分：
// 行高、字距、头像形状、消息形态。ST 那套 CSS 伪元素和外链装饰图接不了。

/// 头像形状。对应 ST 的 `avatar_style`：0 圆 / 1 矩形 / 2 方 / 3 圆角方。
enum AppearanceAvatarShape: String, CaseIterable, Identifiable, Codable {
    case circle, square, roundedSquare, rectangle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .circle: return AppLocalized("圆")
        case .square: return AppLocalized("方")
        case .roundedSquare: return AppLocalized("圆角方")
        case .rectangle: return AppLocalized("竖矩形")
        }
    }

    /// 圆角占边长的比例。0.5 = 正圆。
    var cornerFraction: Double {
        switch self {
        case .circle: return 0.5
        case .square: return 0
        case .roundedSquare: return 0.22
        case .rectangle: return 0.12
        }
    }

    /// 宽高比。竖矩形窄一点。
    var aspect: Double {
        self == .rectangle ? 0.78 : 1.0
    }

    static func parse(_ raw: String) -> AppearanceAvatarShape {
        AppearanceAvatarShape(rawValue: raw) ?? .circle
    }

    /// ST 的 `avatar_style` 整数映射。
    static func fromSillyTavern(_ raw: Int) -> AppearanceAvatarShape {
        switch raw {
        case 1: return .rectangle
        case 2: return .square
        case 3: return .roundedSquare
        default: return .circle
        }
    }
}

/// 消息形态。对应 ST 的 `chat_display`：0 平铺 / 1 气泡 / 2 文稿。
enum AppearanceChatDisplay: String, CaseIterable, Identifiable, Codable {
    /// 不要气泡底色，像聊天记录一样平铺，靠留白分隔。
    case flat
    /// 左右两边的气泡。
    case bubbles
    /// 文稿：不要气泡、不要头像，正文铺满。
    case document

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flat: return AppLocalized("平铺")
        case .bubbles: return AppLocalized("气泡")
        case .document: return AppLocalized("文稿")
        }
    }

    var hint: String {
        switch self {
        case .flat: return AppLocalized("不要气泡底色，靠留白分开，像聊天记录")
        case .bubbles: return AppLocalized("左右两边的气泡")
        case .document: return AppLocalized("不要头像和气泡，正文铺满，像读信")
        }
    }

    static func parse(_ raw: String) -> AppearanceChatDisplay {
        AppearanceChatDisplay(rawValue: raw) ?? .bubbles
    }

    static func fromSillyTavern(_ raw: Int) -> AppearanceChatDisplay {
        switch raw {
        case 1: return .bubbles
        case 2: return .document
        default: return .flat
        }
    }
}

// MARK: - 视觉小说模式
//
// [10-19 醒醒] 她要"两个都做"，所以这里区分成三种。
//
// 查过 ST 源码：`waifuMode` 的真实行为是**全屏角色立绘 + 聊天窗压到底部 40%**
// （`mobile-styles.css:447` 的 `body.waifuMode #sheld { height: 40dvh;
// top: 60dvh }`，`expression-holder` 撑满 `100vh`）。**不是**半透明对话框。
//
// 她原本说的是"底部半透明对话框 + 头像挂左边 + 一句一句推台词"，那更像
// Galgame，ST 里没有这个模式。两个都实现，她自己选。
enum AppearanceNovelMode: String, CaseIterable, Identifiable, Codable {
    /// 关。正常聊天。
    case off
    /// ST 的 waifuMode：全屏立绘，聊天窗压到底部 40%，可上滑展开。
    case stage
    /// Galgame：底部半透明对话框，一次只显示一条，点一下推下一条。
    case galgame

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return AppLocalized("关")
        case .stage: return AppLocalized("立绘")
        case .galgame: return AppLocalized("对话框")
        }
    }

    var hint: String {
        switch self {
        case .off: return AppLocalized("正常聊天，不改变消息显示")
        case .stage: return AppLocalized("全屏角色立绘，聊天窗压到底部，上滑展开")
        case .galgame: return AppLocalized("底部半透明对话框，一次一句，点一下往下推")
        }
    }

    static func parse(_ raw: String) -> AppearanceNovelMode {
        AppearanceNovelMode(rawValue: raw) ?? .off
    }
}
