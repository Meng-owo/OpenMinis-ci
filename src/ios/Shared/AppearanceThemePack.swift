import Foundation
import SwiftUI
import UIKit

extension Notification.Name {
    /// [10-20 醒醒] 代码块换行/折叠阈值变了，渲染层要重排。
    static let codeBlockLayoutSettingsChanged = Notification.Name("codeBlockLayoutSettingsChanged")
}

/// Shape + thinking chrome that a theme pack can swap.
/// Colors stay in AppearanceStudio; this file owns radii, bubble style,
/// thinking card image, pack identity.
struct AppearanceThemePack: Equatable, Codable, Identifiable {
    var id: String
    var name: String
    var userBubbleRadius: Double
    var assistantBubbleRadius: Double
    var thinkingRadius: Double
    var thinkingFillHex: String
    var thinkingStrokeHex: String
    var thinkingAccentHex: String
    var userBubbleStyle: String
    var assistantBubbleStyle: String
    var thinkingCardJPEGBase64: String?
    var thinkingCardImageOpacity: Double
    var listRowFillHex: String?
    var listIconShape: String
    var categoryIcons: [String: String]
    var categoryColors: [String: String]
    var categoryImages: [String: String]
    var inputBarRadius: Double
    var inputBarStyle: String
    var inputBarJPEGBase64: String?
    var inputBarImageOpacity: Double
    var thinkingTitleSize: Double
    var thinkingBodySize: Double
    var fontFamily: String
    var wallpaperShade: Double?
    var surfaceOpacity: Double?
    var colorsLight: [String: String]
    var colorsDark: [String: String]
    var wallpaperJPEGBase64: String?
    // [10-18 醒醒 第五轮] 五个新的可调维度，补的是"结构"自由度，
    // 之前只有颜色和圆角。
    /// 头像形状：圆 / 方 / 圆角方 / 竖矩形
    var avatarShape: String
    /// 消息形态：平铺 / 气泡 / 文稿
    var chatDisplay: String
    /// 正文行高倍数。1.0 = 系统默认。
    var lineHeight: Double
    /// 正文字距，单位 pt。可以是负数。
    var letterSpacing: Double
    /// 选项行背景。nil = 跟随 surface。
    var rowBackgroundHex: String?
    /// [10-19 醒醒] 视觉小说模式：关 / 立绘 / 对话框。
    var novelMode: String
    /// 立绘模式用的角色全身图（base64 JPEG）。nil = 退回头像放大。
    var characterArtBase64: String?
    /// 代码块超过多少行自动折叠。默认 12。
    var codeBlockCollapseLines: Int

    static let currentKey = "appearanceStudio.themePack.v1"
    static let schemaVersion = 5
    static let categoryKeys = [
        "code", "writing", "research", "analysis", "creative", "chat", "math",
        "translation", "health", "finance", "travel", "education", "design",
        "productivity", "support", "other",
    ]

    /// 行高倍数的安全取值。越界就夹回 0.9...2.2。
    static func parseLineHeight(_ raw: Double) -> Double {
        min(2.2, max(0.9, raw))
    }

    /// 从 UserDefaults 直接读行高，**不经过 MainActor**。
    ///
    /// `SelectableMarkdownView` 的排版类不是 MainActor，调
    /// `AppearanceStudio.shared.currentThemePack()` 会报
    /// "main actor-isolated instance method in a synchronous nonisolated context"。
    /// 主题包本来就是 JSON 存在 UserDefaults 里的，这里直接解一下就好。
    nonisolated static func storedLineHeight() -> Double {
        guard let data = UserDefaults.standard.data(forKey: currentKey),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["lineHeight"] as? Double else {
            return 1.0
        }
        return parseLineHeight(raw)
    }

    /// 同上，读字距。
    nonisolated static func storedLetterSpacing() -> Double {
        guard let data = UserDefaults.standard.data(forKey: currentKey),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["letterSpacing"] as? Double else {
            return 0
        }
        return parseLetterSpacing(raw)
    }

    /// 字距的安全取值，单位 pt。
    static func parseLetterSpacing(_ raw: Double) -> Double {
        min(3, max(-1, raw))
    }


    static let `default` = AppearanceThemePack(
        id: "warm-paper",
        name: "暖纸",
        userBubbleRadius: 18,
        assistantBubbleRadius: 16,
        thinkingRadius: 12,
        // [B28 B-3] 空串 = "没设过，跟 accent 走"。老版本这三个字段是 accent
        // 的副本；写死一个 hex 会把新装用户钉在旧主色上（D4778B 是 10-18
        // 改配色之前的主色）。
        thinkingFillHex: "",
        thinkingStrokeHex: "",
        thinkingAccentHex: "",
        userBubbleStyle: AppearanceBubbleStyle.rounded.rawValue,
        assistantBubbleStyle: AppearanceBubbleStyle.rounded.rawValue,
        thinkingCardJPEGBase64: nil,
        thinkingCardImageOpacity: 0.28,
        listRowFillHex: nil,
        listIconShape: AppearanceListIconShape.circle.rawValue,
        categoryIcons: [:],
        categoryColors: [:],
        categoryImages: [:],
        inputBarRadius: 20,
        inputBarStyle: AppearanceBubbleStyle.rounded.rawValue,
        inputBarJPEGBase64: nil,
        inputBarImageOpacity: 0.28,
        thinkingTitleSize: 13,
        thinkingBodySize: 13,
        fontFamily: AppearanceFontFamily.system.rawValue,
        wallpaperShade: 0.08,
        surfaceOpacity: 0.88,
        colorsLight: [:],
        colorsDark: [:],
        wallpaperJPEGBase64: nil,
        avatarShape: AppearanceAvatarShape.circle.rawValue,
        chatDisplay: AppearanceChatDisplay.bubbles.rawValue,
        lineHeight: 1.0,
        letterSpacing: 0,
        rowBackgroundHex: nil,
        novelMode: AppearanceNovelMode.off.rawValue,
        characterArtBase64: nil,
        codeBlockCollapseLines: 12
    )

    var userStyle: AppearanceBubbleStyle { AppearanceBubbleStyle.parse(userBubbleStyle) }
    var assistantStyle: AppearanceBubbleStyle { AppearanceBubbleStyle.parse(assistantBubbleStyle) }

    func radius(_ kind: AppearanceShapeKind) -> CGFloat {
        switch kind {
        case .userBubble: return CGFloat(clampRadius(userBubbleRadius))
        case .assistantBubble: return CGFloat(clampRadius(assistantBubbleRadius))
        case .thinking: return CGFloat(clampRadius(thinkingRadius))
        }
    }

    func thinkingFill(opacity: Double) -> Color {
        Color(hex: thinkingFillHex).opacity(opacity)
    }

    var thinkingStroke: Color { Color(hex: thinkingStrokeHex).opacity(0.15) }
    var thinkingAccent: Color { Color(hex: thinkingAccentHex) }

    func asJSONObject() -> [String: Any] {
        var obj: [String: Any] = [
            "schema": Self.schemaVersion,
            "id": id,
            "name": name,
            "userBubbleRadius": userBubbleRadius,
            "assistantBubbleRadius": assistantBubbleRadius,
            "thinkingRadius": thinkingRadius,
            "thinkingFillHex": thinkingFillHex,
            "thinkingStrokeHex": thinkingStrokeHex,
            "thinkingAccentHex": thinkingAccentHex,
            "userBubbleStyle": userStyle.rawValue,
            "assistantBubbleStyle": assistantStyle.rawValue,
            "thinkingCardImageOpacity": thinkingCardImageOpacity,
            "listIconShape": AppearanceListIconShape.parse(listIconShape).rawValue,
            "categoryIcons": categoryIcons,
            "categoryColors": categoryColors,
            "categoryImages": categoryImages,
            "inputBarRadius": inputBarRadius,
            "inputBarStyle": AppearanceBubbleStyle.parse(inputBarStyle).rawValue,
            "inputBarImageOpacity": inputBarImageOpacity,
            "thinkingTitleSize": thinkingTitleSize,
            "thinkingBodySize": thinkingBodySize,
            "fontFamily": AppearanceFontFamily.parse(fontFamily).rawValue,
            "colorsLight": colorsLight,
            "colorsDark": colorsDark,
            "avatarShape": AppearanceAvatarShape.parse(avatarShape).rawValue,
            "chatDisplay": AppearanceChatDisplay.parse(chatDisplay).rawValue,
            "lineHeight": lineHeight,
            "letterSpacing": letterSpacing,
            "codeBlockCollapseLines": codeBlockCollapseLines,
        ]
        if let rowBackgroundHex { obj["rowBackgroundHex"] = rowBackgroundHex }
        obj["novelMode"] = AppearanceNovelMode.parse(novelMode).rawValue
        if let characterArtBase64 { obj["characterArtBase64"] = characterArtBase64 }
        if let listRowFillHex { obj["listRowFillHex"] = listRowFillHex }
        if let wallpaperShade { obj["wallpaperShade"] = wallpaperShade }
        if let surfaceOpacity { obj["surfaceOpacity"] = surfaceOpacity }
        if let wallpaperJPEGBase64 { obj["wallpaperJPEGBase64"] = wallpaperJPEGBase64 }
        if let thinkingCardJPEGBase64 { obj["thinkingCardJPEGBase64"] = thinkingCardJPEGBase64 }
        if let inputBarJPEGBase64 { obj["inputBarJPEGBase64"] = inputBarJPEGBase64 }
        return obj
    }

    /// Keys that mark JSON as an Appearance theme pack (partial / legacy OK).
    private static let themePackSignalKeys: Set<String> = [
        "schema",
        "userBubbleRadius", "assistantBubbleRadius", "thinkingRadius",
        "thinkingFillHex", "thinkingStrokeHex", "thinkingAccentHex",
        "userBubbleStyle", "assistantBubbleStyle",
        "thinkingCardJPEGBase64", "thinkingCardImageOpacity",
        "listRowFillHex", "listIconShape",
        "categoryIcons", "categoryColors", "categoryImages",
        "inputBarRadius", "inputBarStyle", "inputBarJPEGBase64", "inputBarImageOpacity",
        "thinkingTitleSize", "thinkingBodySize", "fontFamily",
        "wallpaperShade", "surfaceOpacity",
        "colorsLight", "colorsDark", "wallpaperJPEGBase64",
        "avatarShape", "chatDisplay", "lineHeight", "letterSpacing", "rowBackgroundHex",
        "novelMode", "characterArtBase64",
    ]

    /// True when `raw` carries at least one known theme-pack field.
    /// Missing fields are filled from `.default` during decode (migrate / upgrade path).
    static func looksLikeThemePack(_ raw: [String: Any]) -> Bool {
        raw.keys.contains { themePackSignalKeys.contains($0) }
    }

    /// - Parameter base: Pack supplying every key `raw` does not carry.
    ///   Pass the pack currently on screen for partial updates (AI `minis-theme
    ///   apply`, clipboard import) so untouched fields — the category image
    ///   markers in particular — survive. Keep `.default` when decoding a
    ///   complete snapshot: a stored pack, or a saved theme in the library.
    static func decode(_ raw: [String: Any],
                       merging base: AppearanceThemePack = .default) throws -> AppearanceThemePack {
        // Old / partial packs: fill missing keys from `base` and treat as schema 5.
        // Reject only JSON that does not look like a theme pack at all.
        guard looksLikeThemePack(raw) else {
            throw AppearanceThemePackError.notAThemePack
        }
        func str(_ k: String, fallback: String) -> String {
            (raw[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? (raw[k] as! String) : fallback
        }
        func num(_ k: String, fallback: Double) -> Double {
            if let d = raw[k] as? Double { return d }
            if let i = raw[k] as? Int { return Double(i) }
            if let s = raw[k] as? String, let d = Double(s) { return d }
            return fallback
        }
        func map(_ k: String, fallback: [String: String]) -> [String: String] {
            if let typed = raw[k] as? [String: String] { return typed }
            guard let anyMap = raw[k] as? [String: Any] else { return fallback }
            var out: [String: String] = [:]
            for (key, val) in anyMap {
                if let s = val as? String { out[key] = s }
            }
            return out
        }
        var pack = AppearanceThemePack(
            id: str("id", fallback: base.id),
            name: str("name", fallback: base.name),
            userBubbleRadius: clampRadius(num("userBubbleRadius", fallback: base.userBubbleRadius)),
            assistantBubbleRadius: clampRadius(num("assistantBubbleRadius", fallback: base.assistantBubbleRadius)),
            thinkingRadius: clampRadius(num("thinkingRadius", fallback: base.thinkingRadius)),
            thinkingFillHex: normalizeOptionalHex(str("thinkingFillHex", fallback: base.thinkingFillHex)),
            thinkingStrokeHex: normalizeOptionalHex(str("thinkingStrokeHex", fallback: base.thinkingStrokeHex)),
            thinkingAccentHex: normalizeOptionalHex(str("thinkingAccentHex", fallback: base.thinkingAccentHex)),
            userBubbleStyle: AppearanceBubbleStyle.parse(str("userBubbleStyle", fallback: base.userBubbleStyle)).rawValue,
            assistantBubbleStyle: AppearanceBubbleStyle.parse(str("assistantBubbleStyle", fallback: base.assistantBubbleStyle)).rawValue,
            thinkingCardJPEGBase64: raw["thinkingCardJPEGBase64"] as? String,
            thinkingCardImageOpacity: min(1, max(0.05, num("thinkingCardImageOpacity", fallback: base.thinkingCardImageOpacity))),
            listRowFillHex: (raw["listRowFillHex"] as? String).map(normalizeHex),
            listIconShape: AppearanceListIconShape.parse(str("listIconShape", fallback: base.listIconShape)).rawValue,
            categoryIcons: filterCategoryMap(map("categoryIcons", fallback: base.categoryIcons), symbols: true),
            categoryColors: filterCategoryMap(map("categoryColors", fallback: base.categoryColors), symbols: false),
            categoryImages: filterCategoryMap(map("categoryImages", fallback: base.categoryImages), symbols: true),
            inputBarRadius: clampRadius(num("inputBarRadius", fallback: base.inputBarRadius)),
            inputBarStyle: AppearanceBubbleStyle.parse(str("inputBarStyle", fallback: base.inputBarStyle)).rawValue,
            inputBarJPEGBase64: raw["inputBarJPEGBase64"] as? String,
            inputBarImageOpacity: min(1, max(0.05, num("inputBarImageOpacity", fallback: base.inputBarImageOpacity))),
            thinkingTitleSize: min(22, max(10, num("thinkingTitleSize", fallback: base.thinkingTitleSize))),
            thinkingBodySize: min(22, max(10, num("thinkingBodySize", fallback: base.thinkingBodySize))),
            fontFamily: AppearanceFontFamily.parse(str("fontFamily", fallback: base.fontFamily)).rawValue,
            wallpaperShade: raw["wallpaperShade"] == nil ? nil : min(0.65, max(0, num("wallpaperShade", fallback: 0.08))),
            surfaceOpacity: raw["surfaceOpacity"] == nil ? nil : min(1, max(0.35, num("surfaceOpacity", fallback: 0.88))),
            colorsLight: normalizeHexMap(map("colorsLight", fallback: base.colorsLight)),
            colorsDark: normalizeHexMap(map("colorsDark", fallback: base.colorsDark)),
            wallpaperJPEGBase64: raw["wallpaperJPEGBase64"] as? String,
            avatarShape: AppearanceAvatarShape.parse(str("avatarShape", fallback: base.avatarShape)).rawValue,
            chatDisplay: AppearanceChatDisplay.parse(str("chatDisplay", fallback: base.chatDisplay)).rawValue,
            lineHeight: min(2.2, max(0.9, num("lineHeight", fallback: base.lineHeight))),
            letterSpacing: min(3, max(-1, num("letterSpacing", fallback: base.letterSpacing))),
            rowBackgroundHex: (raw["rowBackgroundHex"] as? String).map(normalizeHex),
            novelMode: AppearanceNovelMode.parse(str("novelMode", fallback: base.novelMode)).rawValue,
            characterArtBase64: raw["characterArtBase64"] as? String,
            codeBlockCollapseLines: min(40, max(4, Int(num("codeBlockCollapseLines", fallback: Double(base.codeBlockCollapseLines)))))
        )
        if pack.id.isEmpty { pack.id = base.id }
        if pack.name.isEmpty { pack.name = pack.id }
        return pack
    }
}

enum AppearanceThemePackError: LocalizedError {
    case notAThemePack

    var errorDescription: String? {
        switch self {
        case .notAThemePack:
            return "Not a theme pack."
        }
    }
}

enum AppearanceShapeKind {
    case userBubble, assistantBubble, thinking
}

enum AppearanceListIconShape: String, CaseIterable, Identifiable {
    case circle, squircle, rounded
    var id: String { rawValue }
    var title: String {
        switch self {
        case .circle: return AppLocalized("圆")
        case .squircle: return AppLocalized("方圆")
        case .rounded: return AppLocalized("圆角方")
        }
    }
    static func parse(_ raw: String) -> AppearanceListIconShape {
        AppearanceListIconShape(rawValue: raw) ?? .circle
    }
}

fileprivate func filterCategoryMap(_ map: [String: String], symbols: Bool) -> [String: String] {
    let allowed = Set(AppearanceThemePack.categoryKeys)
    var out: [String: String] = [:]
    for (k, v) in map {
        guard allowed.contains(k) else { continue }
        let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        out[k] = symbols ? trimmed : normalizeHex(trimmed)
    }
    return out
}

enum AppearanceFontFamily: String, CaseIterable, Identifiable {
    case system, rounded, serif, mono
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return AppLocalized("系统")
        case .rounded: return AppLocalized("圆体")
        case .serif: return AppLocalized("衬线")
        case .mono: return AppLocalized("等宽")
        }
    }
    var design: Font.Design {
        switch self {
        case .system: return .default
        case .rounded: return .rounded
        case .serif: return .serif
        case .mono: return .monospaced
        }
    }
    var uiDesign: UIFontDescriptor.SystemDesign {
        switch self {
        case .system: return .default
        case .rounded: return .rounded
        case .serif: return .serif
        case .mono: return .monospaced
        }
    }
    static func parse(_ raw: String) -> AppearanceFontFamily {
        AppearanceFontFamily(rawValue: raw) ?? .system
    }

    func uiFont(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = base.fontDescriptor.withDesign(uiDesign) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return base
    }

    func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: design)
    }

    static func resolved() -> AppearanceFontFamily {
        guard let data = UserDefaults.standard.data(forKey: AppearanceThemePack.currentKey),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["fontFamily"] as? String else {
            return .system
        }
        return parse(raw)
    }
}

enum AppearanceBubbleStyle: String, CaseIterable, Identifiable {
    case rounded, squircle, pill, tail, sharp
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rounded: return AppLocalized("圆角")
        case .squircle: return AppLocalized("连续圆角")
        case .pill: return AppLocalized("胶囊")
        case .tail: return AppLocalized("小尾巴")
        case .sharp: return AppLocalized("方一点")
        }
    }
    static func parse(_ raw: String) -> AppearanceBubbleStyle {
        AppearanceBubbleStyle(rawValue: raw) ?? .rounded
    }
}

fileprivate func clampRadius(_ value: Double) -> Double {
    min(32, max(4, value))
}

/// [B28 B-3] 三个 thinking 字段允许空串，表示"跟 accent 走"。
/// `normalizeHex("")` 会回落到 808080 灰，所以这几个字段单独走这里。
fileprivate func normalizeOptionalHex(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "" : normalizeHex(trimmed)
}

fileprivate func normalizeHex(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).uppercased()
    guard trimmed.count == 6 || trimmed.count == 8 else { return "808080" }
    // Length alone let "ZZZZZZ" through, which scanned to 0 and painted
    // black. Require actual hex digits so a typo lands on neutral grey.
    guard trimmed.allSatisfy({ $0.isHexDigit }) else { return "808080" }
    return trimmed
}

fileprivate func normalizeHexMap(_ map: [String: String]) -> [String: String] {
    var out: [String: String] = [:]
    let allowed = Set(AppearanceColorRole.allCases.map(\.rawValue))
    for (k, v) in map {
        guard allowed.contains(k) else { continue }
        out[k] = normalizeHex(v)
    }
    return out
}

/// Chat bubble / thinking card clip. Tail sits on the outer side
/// (user = trailing, assistant = leading).
struct MinisBubbleShape: Shape {
    var style: AppearanceBubbleStyle
    var radius: CGFloat
    var tailOnTrailing: Bool

    func path(in rect: CGRect) -> Path {
        let r = min(max(radius, 4), min(rect.width, rect.height) / 2)
        switch style {
        case .rounded:
            return rounded(rect, r, continuous: false)
        case .squircle:
            return rounded(rect, r, continuous: true)
        case .pill:
            return rounded(rect, min(rect.height, rect.width) / 2, continuous: true)
        case .sharp:
            return rounded(rect, min(6, r * 0.35), continuous: false)
        case .tail:
            return tailedPath(in: rect, corner: r)
        }
    }

    private func rounded(_ rect: CGRect, _ r: CGFloat, continuous: Bool) -> Path {
        Path(RoundedRectangle(cornerRadius: r, style: continuous ? .continuous : .circular).path(in: rect).cgPath)
    }

    private func tailedPath(in rect: CGRect, corner: CGFloat) -> Path {
        let tail: CGFloat = 7
        let body = tailOnTrailing
            ? CGRect(x: rect.minX, y: rect.minY, width: max(1, rect.width - tail), height: rect.height)
            : CGRect(x: rect.minX + tail, y: rect.minY, width: max(1, rect.width - tail), height: rect.height)
        var path = rounded(body, corner, continuous: true)
        let baseY = body.maxY - max(10, corner)
        if tailOnTrailing {
            path.move(to: CGPoint(x: body.maxX - 1, y: baseY - 7))
            path.addLine(to: CGPoint(x: rect.maxX, y: baseY))
            path.addLine(to: CGPoint(x: body.maxX - 1, y: baseY + 5))
            path.closeSubpath()
        } else {
            path.move(to: CGPoint(x: body.minX + 1, y: baseY - 7))
            path.addLine(to: CGPoint(x: rect.minX, y: baseY))
            path.addLine(to: CGPoint(x: body.minX + 1, y: baseY + 5))
            path.closeSubpath()
        }
        return path
    }
}

extension AppearanceStudio {
    private static let packKey = AppearanceThemePack.currentKey

    func loadStoredPack() -> AppearanceThemePack {
        currentThemePack()
    }

    func currentThemePack() -> AppearanceThemePack {
        themePackLock.lock()
        defer { themePackLock.unlock() }
        if !themePackLoaded {
            cachedThemePack = loadStoredPackUnlocked()
            themePackLoaded = true
        }
        return cachedThemePack
    }

    func loadStoredPackUnlocked() -> AppearanceThemePack {
        guard let data = UserDefaults.standard.data(forKey: Self.packKey),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pack = try? AppearanceThemePack.decode(obj) else {
            return .default
        }
        // Persist upgraded schema 5 when stored JSON had missing/old schema.
        // Direct UserDefaults set — avoid persistPack (would re-enter themePackLock).
        let storedSchema: Int? = {
            guard let raw = obj["schema"] else { return nil }
            if let i = raw as? Int { return i }
            if let d = raw as? Double { return Int(d) }
            if let s = raw as? String {
                return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return nil
        }()
        if storedSchema != AppearanceThemePack.schemaVersion,
           let upgraded = try? JSONSerialization.data(withJSONObject: pack.asJSONObject()) {
            UserDefaults.standard.set(upgraded, forKey: Self.packKey)
        }
        // [B28 A-1] 老 pack 把立绘整张 base64 存在这里。搬到文件、字段置 nil，
        // 顺手把 defaults 里那份也重写掉 —— 否则每次读还是把几百 KB 搬进内存。
        // 只在字段非空时跑一次，之后永远为 nil。
        if let inline = pack.characterArtBase64, !inline.isEmpty,
           let art = Data(base64Encoded: inline) {
            writeEncodedImage(art, to: characterArtURL(), maxEdge: 1600, quality: 0.82)
            var cleaned = pack
            cleaned.characterArtBase64 = nil
            if let data = try? JSONSerialization.data(withJSONObject: cleaned.asJSONObject()) {
                UserDefaults.standard.set(data, forKey: Self.packKey)
            }
            return cleaned
        }
        return pack
    }

    func persistPack(_ pack: AppearanceThemePack) {
        guard let data = try? JSONSerialization.data(withJSONObject: pack.asJSONObject()) else { return }
        UserDefaults.standard.set(data, forKey: Self.packKey)
        // [10-20 醒醒] 代码块的换行/折叠阈值要给 UIKit 侧读。那条链路不能碰
        // @MainActor 的 AppearanceStudio，所以额外写一份扁平快照。
        UserDefaults.standard.set([
                                   "collapseLines": pack.codeBlockCollapseLines],
                                  forKey: "appearanceStudio.codeBlock.v1")
        themePackLock.lock()
        cachedThemePack = pack
        themePackLoaded = true
        themePackLock.unlock()
        themePackRevision += 1
        objectWillChange.send()
    }

    /// Applies a pack to the live studio.
    ///
    /// Image payloads are optional: a nil base64 means "this call does not
    /// carry that image", so the file on disk stays. Callers that mean to
    /// remove an image call `removeWallpaper` / `removeThinkingCardImage` /
    /// `removeInputBarImage` instead of relying on an omission.
    /// [B28 R3-5 / F-2] 图吃不下以前也照样应用成功 —— 应用方（UI/CLI/AI）
    /// 需要知道哪些字段没落住，返回值就是那份实话。
    @discardableResult
    func applyThemePack(_ pack: AppearanceThemePack, wallpaper: UIImage? = nil) -> [String] {
        var warnings: [String] = []
        var stored = pack
        stored.wallpaperJPEGBase64 = nil
        stored.thinkingCardJPEGBase64 = nil
        stored.inputBarJPEGBase64 = nil
        // [B28 A-1] 立绘也不再进 defaults：落成文件，字段置 nil。
        if let b64 = pack.characterArtBase64 {
            if let data = Data(base64Encoded: b64) {
                if !writeEncodedImage(data, to: characterArtURL(), maxEdge: 1600, quality: 0.82) {
                    warnings.append("characterArt")
                }
            } else { warnings.append("characterArt") }
        }
        stored.characterArtBase64 = nil
        // Keep markers for category images the caller did not mention.
        // applyCategoryImages below reconciles the rest against disk.
        let mentioned = Set(pack.categoryImages.keys)
        var markers = currentThemePack().categoryImages
        for key in mentioned { markers[key] = pack.categoryImages[key] }
        stored.categoryImages = markers
        persistPack(stored)
        if !pack.colorsLight.isEmpty || !pack.colorsDark.isEmpty {
            applyPackColors(light: pack.colorsLight, dark: pack.colorsDark)
        }
        if let opacity = pack.surfaceOpacity { surfaceOpacity = opacity }
        if let shade = pack.wallpaperShade { wallpaperShade = shade }
        if let wallpaper {
            if !setWallpaper(wallpaper, for: .global) { warnings.append("wallpaper") }
        } else if let b64 = pack.wallpaperJPEGBase64 {
            if let data = Data(base64Encoded: b64) {
                if !setWallpaperEncoded(data, for: .global) { warnings.append("wallpaper") }
            } else { warnings.append("wallpaper") }
        }
        if let b64 = pack.thinkingCardJPEGBase64 {
            if let data = Data(base64Encoded: b64) {
                if !setThinkingCardImageEncoded(data) { warnings.append("thinkingCard") }
            } else { warnings.append("thinkingCard") }
        }
        if let b64 = pack.inputBarJPEGBase64 {
            if let data = Data(base64Encoded: b64) {
                if !setInputBarImageEncoded(data) { warnings.append("inputBar") }
            } else { warnings.append("inputBar") }
        }
        applyCategoryImages(pack.categoryImages)
        configureUIKitSurfaces()
        return warnings
    }

    func exportThemePack(includeWallpaper: Bool) -> AppearanceThemePack {
        var pack = loadStoredPack()
        pack.colorsLight = exportColors(variant: .light)
        pack.colorsDark = exportColors(variant: .dark)
        pack.surfaceOpacity = surfaceOpacity
        pack.wallpaperShade = wallpaperShade
        // [B28 B-3] 三个字段以前被硬写成 accent 的副本 —— 导出一次，用户
        // 自己设的 thinking 颜色就被抹平，而且导出/应用来回一趟就把「跟 accent
        // 走」永久钉死成当时那个 hex。现在不写：空串就是「跟 accent 走」，
        // 设过的原样带出去。
        // [T-theme-reexport-inflate] Export used to re-encode every image from
        // its decoded UIImage at a fixed quality. A pack that went
        // export → apply → export came back ~3x larger (340B → 1005B, and
        // 964B → 2156B for the wallpaper) and lost detail on every pass, even
        // though apply had stored the bytes verbatim.
        //
        // The file on disk IS the original bytes — `writeEncodedImage` writes
        // them untouched when no downscale is needed — so read those instead
        // of round-tripping through UIImage. The UIImage path stays as the
        // fallback for anything not backed by a file.
        if includeWallpaper, let data = originalImageData(fileName: "wallpaper-\(AppearanceScope.global.rawValue).jpg") {
            pack.wallpaperJPEGBase64 = data.base64EncodedString()
        } else if includeWallpaper, let image = wallpaper(for: .global),
                  let data = image.jpegData(compressionQuality: 0.82) {
            pack.wallpaperJPEGBase64 = data.base64EncodedString()
        } else {
            pack.wallpaperJPEGBase64 = nil
        }
        if includeWallpaper {
            if let data = originalImageData(fileName: "thinking-card.jpg") {
                pack.thinkingCardJPEGBase64 = data.base64EncodedString()
            } else if let image = thinkingCardImage(),
                      let data = image.jpegData(compressionQuality: 0.82) {
                pack.thinkingCardJPEGBase64 = data.base64EncodedString()
            }
        }
        if includeWallpaper {
            if let data = originalImageData(fileName: "input-bar.jpg") {
                pack.inputBarJPEGBase64 = data.base64EncodedString()
            } else if let image = inputBarImage(),
                      let data = image.jpegData(compressionQuality: 0.82) {
                pack.inputBarJPEGBase64 = data.base64EncodedString()
            }
        }
        // [B28 A-1] 立绘跟壁纸同一条路：`includeWallpaper: true` 才带整张图，
        // 平时（`minis-theme get`）字段是 nil，AI 不会吃进几百 KB base64。
        if includeWallpaper, let data = originalImageData(fileName: "character-art.jpg") {
            pack.characterArtBase64 = data.base64EncodedString()
        } else {
            pack.characterArtBase64 = nil
        }
        if includeWallpaper {
            var images: [String: String] = [:]
            for key in AppearanceThemePack.categoryKeys {
                // Category icons are rendered tiles, not user files, so the
                // original-bytes path only applies to a real file on disk.
                if let data = originalImageData(fileName: "category-\(key).jpg") {
                    images[key] = data.base64EncodedString()
                } else if let image = categoryImage(for: key),
                          let data = image.jpegData(compressionQuality: 0.86) {
                    images[key] = data.base64EncodedString()
                }
            }
            pack.categoryImages = images
        }
        return pack
    }

    /// Bytes of an image file exactly as stored, or nil when there is no file.
    ///
    /// Deliberately not `UIImage(contentsOfFile:)`: decoding and re-encoding is
    /// what inflated exported packs.
    private func originalImageData(fileName: String) -> Data? {
        let url = appearanceDirectory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return data
    }

    /// Snapshot directory for the most recent destructive theme operation.
    ///
    /// `reset` deletes every user image and the whole pack. It used to be a
    /// one-way door, and `minis-theme reset` put that door behind an AI
    /// command. Everything wiped here is first copied aside so `undoReset`
    /// can put it back.
    var themeUndoDirectory: URL {
        // Dot-prefixed on purpose: the backup tree exporter walks this
        // directory with `.skipsHiddenFiles`, so a snapshot never doubles the
        // size of an appearance backup.
        let dir = appearanceDirectory.appendingPathComponent(".undo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Files a reset would destroy: pack JSON plus every image the pack owns.
    ///
    /// Built in a scratch directory and swapped in at the end, so a capture
    /// that fails halfway cannot leave the previous undo snapshot destroyed
    /// and the new one empty.
    private func captureThemeUndoSnapshot() -> URL? {
        let dir = themeUndoDirectory
        let scratch = dir.deletingLastPathComponent()
            .appendingPathComponent(".undo-staging", isDirectory: true)
        try? FileManager.default.removeItem(at: scratch)
        guard (try? FileManager.default.createDirectory(at: scratch,
                                                        withIntermediateDirectories: true)) != nil else {
            return nil
        }
        if let data = UserDefaults.standard.data(forKey: Self.packKey) {
            try? data.write(to: scratch.appendingPathComponent("pack.json"), options: .atomic)
        }
        let overrides: [String: String] = exportColorOverrides()
        if let colors = try? JSONEncoder().encode(overrides) {
            try? colors.write(to: scratch.appendingPathComponent("colors.json"), options: .atomic)
        }
        // [B28 R2-12] resetColors 顺手重置 surface/bubble/shade 三个滑杆，
        // 但快照原来只存 pack.json + colors.json —— 「撤销」救不回这三个值，
        // 撤销条就成了谎言。bubbleOpacity 是独立 UserDefaults 键，尤其容易漏。
        let opacity: [String: Double] = [
            "surface": surfaceOpacity,
            "bubble": bubbleOpacity,
            "shade": wallpaperShade,
        ]
        if let data = try? JSONEncoder().encode(opacity) {
            try? data.write(to: scratch.appendingPathComponent("opacity.json"), options: .atomic)
        }
        for key in AppearanceThemePack.categoryKeys {
            let src = categoryImageURL(key)
            if FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.copyItem(at: src, to: scratch.appendingPathComponent("category-\(key).jpg"))
            }
        }
        for (name, src) in [("thinking-card.jpg", thinkingCardURL()),
                            ("input-bar.jpg", inputBarImageURL()),
                            ("character-art.jpg", characterArtURL())] {
            if FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.copyItem(at: src, to: scratch.appendingPathComponent(name))
            }
        }
        // Only replace the live snapshot once the new one is complete.
        guard FileManager.default.fileExists(atPath: scratch.appendingPathComponent("pack.json").path) else {
            try? FileManager.default.removeItem(at: scratch)
            return nil
        }
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.moveItem(at: scratch, to: dir)
        return dir
    }

    /// True when a reset snapshot is on disk and can be restored.
    var canUndoThemeReset: Bool {
        let dir = themeUndoDirectory
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("pack.json").path)
    }

    /// Restores the pack and images captured by the last `resetThemePack`.
    @discardableResult
    func undoThemeReset() -> Bool {
        let dir = themeUndoDirectory
        let packURL = dir.appendingPathComponent("pack.json")
        guard let data = try? Data(contentsOf: packURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let restored = try? AppearanceThemePack.decode(obj) else {
            return false
        }
        UserDefaults.standard.set(data, forKey: Self.packKey)
        themePackLock.lock()
        cachedThemePack = restored
        themePackLoaded = true
        themePackLock.unlock()
        themePackRevision += 1

        if let colors = try? Data(contentsOf: dir.appendingPathComponent("colors.json")),
           let decoded = try? JSONDecoder().decode([String: String].self, from: colors) {
            restoreColorOverrides(decoded)
        }
        // [B28 R2-12] 配套：快照里有 opacity.json 就如实恢复三个滑杆。
        // 旧快照没这个文件时保持现值 —— 不假装恢复到没记录过的状态。
        if let data = try? Data(contentsOf: dir.appendingPathComponent("opacity.json")),
           let op = try? JSONDecoder().decode([String: Double].self, from: data) {
            if let v = op["surface"] { surfaceOpacity = v }
            if let v = op["bubble"] { bubbleOpacity = v }
            if let v = op["shade"] { wallpaperShade = v }
        }
        for key in AppearanceThemePack.categoryKeys {
            let src = dir.appendingPathComponent("category-\(key).jpg")
            if FileManager.default.fileExists(atPath: src.path) {
                let dst = categoryImageURL(key)
                try? FileManager.default.removeItem(at: dst)
                try? FileManager.default.copyItem(at: src, to: dst)
                ThumbnailCache.shared.removeThumbnail(for: dst.path)
            }
        }
        for (name, dst) in [("thinking-card.jpg", thinkingCardURL()),
                            ("input-bar.jpg", inputBarImageURL()),
                            ("character-art.jpg", characterArtURL())] {
            let src = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.removeItem(at: dst)
                try? FileManager.default.copyItem(at: src, to: dst)
                ThumbnailCache.shared.removeThumbnail(for: dst.path)
            }
        }
        objectWillChange.send()
        return true
    }

    /// [B28 R2-1] 「恢复默认色盘」先抓快照再清 —— 和整包重置同一套撤销机制，
    /// 撤销条承诺「撤销上一次恢复」时，色盘重置也要真的能撤。
    func resetPaletteWithUndo() {
        _ = captureThemeUndoSnapshot()
        resetColors()
    }

    func resetThemePack() {
        _ = captureThemeUndoSnapshot()
        UserDefaults.standard.removeObject(forKey: Self.packKey)
        try? FileManager.default.removeItem(at: thinkingCardURL())
        try? FileManager.default.removeItem(at: inputBarImageURL())
        // [B28 A-1] 立绘也是 pack 里的图，跟 thinking 卡片/输入栏一样回默认。
        try? FileManager.default.removeItem(at: characterArtURL())
        ThumbnailCache.shared.removeThumbnail(for: characterArtURL().path)
        wipeCategoryImageFiles()
        themePackLock.lock()
        cachedThemePack = .default
        themePackLoaded = true
        themePackLock.unlock()
        themePackRevision += 1
        resetColors()
        objectWillChange.send()
    }

    func setBubbleStyle(_ style: AppearanceBubbleStyle, user: Bool) {
        var pack = currentThemePack()
        if user { pack.userBubbleStyle = style.rawValue }
        else { pack.assistantBubbleStyle = style.rawValue }
        persistPack(pack)
    }

    func setListIconShape(_ shape: AppearanceListIconShape) {
        var pack = currentThemePack()
        pack.listIconShape = shape.rawValue
        persistPack(pack)
    }

    func setInputBarRadius(_ value: Double) {
        var pack = currentThemePack()
        pack.inputBarRadius = min(32, max(4, value))
        persistPack(pack)
    }

    func setInputBarStyle(_ style: AppearanceBubbleStyle) {
        var pack = currentThemePack()
        pack.inputBarStyle = style.rawValue
        persistPack(pack)
    }

    func setFontFamily(_ family: AppearanceFontFamily) {
        var pack = currentThemePack()
        pack.fontFamily = family.rawValue
        persistPack(pack)
    }

    // MARK: - 第五轮新增的维度

    func setAvatarShape(_ shape: AppearanceAvatarShape) {
        var pack = currentThemePack()
        pack.avatarShape = shape.rawValue
        persistPack(pack)
    }

    func setChatDisplay(_ display: AppearanceChatDisplay) {
        var pack = currentThemePack()
        pack.chatDisplay = display.rawValue
        persistPack(pack)
    }

    // MARK: [10-19 醒醒] 视觉小说模式

    func setNovelMode(_ mode: AppearanceNovelMode) {
        var pack = currentThemePack()
        pack.novelMode = mode.rawValue
        persistPack(pack)
    }

    /// 立绘图。传 nil 清掉。
    ///
    /// [B28 A-1] 立绘以前是唯一一张"图片却当普通字段存"的资源：整张
    /// base64（1600px JPEG，几百 KB）进 pack JSON → UserDefaults → 每次拖
    /// 任何滑杆都重写一遍 → 还进备份。其余三张图早就走"落文件、字段置 nil"。
    ///
    /// 现在立绘也落文件（`character-art.jpg`）。pack 里的字段只作为
    /// 一次性的搬运工存在：apply 时解码落盘，然后立刻置 nil。
    func setCharacterArt(_ base64: String?) {
        var pack = currentThemePack()
        pack.characterArtBase64 = base64
        if let base64, let data = Data(base64Encoded: base64) {
            writeEncodedImage(data, to: characterArtURL(), maxEdge: 1600, quality: 0.82)
            pack.characterArtBase64 = nil
        } else if base64 == nil {
            removeCharacterArt()
            return
        }
        persistPack(pack)
    }

    /// [B28 A-1] 直接从 UIImage 落盘。UI 走这条，不经过 base64。
    func setCharacterArtImage(_ image: UIImage) {
        writeDownscaledJPEG(image, to: characterArtURL(), maxEdge: 1600, quality: 0.82)
        var pack = currentThemePack()
        pack.characterArtBase64 = nil
        persistPack(pack)
    }

    private func characterArtURL() -> URL {
        appearanceDirectory.appendingPathComponent("character-art.jpg")
    }

    /// 立绘原图。没有就返回 nil（渲染层会退回"头像放大"占位）。
    func characterArtImage() -> UIImage? {
        let path = characterArtURL().path
        if let hit = ThumbnailCache.shared.cachedThumbnail(for: path) { return hit }
        guard let image = UIImage(contentsOfFile: path) else { return nil }
        ThumbnailCache.shared.store(image, for: path)
        return image
    }

    /// 有没有立绘。UI 和 CLI 都该看这个，而不是看 pack 字段。
    var hasCharacterArt: Bool {
        FileManager.default.fileExists(atPath: characterArtURL().path)
    }

    func removeCharacterArt() {
        try? FileManager.default.removeItem(at: characterArtURL())
        ThumbnailCache.shared.removeThumbnail(for: characterArtURL().path)
        var pack = currentThemePack()
        pack.characterArtBase64 = nil
        persistPack(pack)
    }

    func setLineHeight(_ value: Double) {
        var pack = currentThemePack()
        pack.lineHeight = min(2.2, max(0.9, value))
        persistPack(pack)
    }

    func setLetterSpacing(_ value: Double) {
        var pack = currentThemePack()
        pack.letterSpacing = min(3, max(-1, value))
        persistPack(pack)
    }

    // MARK: [10-20 醒醒] 代码块

    func setCodeBlockCollapseLines(_ lines: Int) {
        var pack = currentThemePack()
        pack.codeBlockCollapseLines = min(40, max(4, lines))
        persistPack(pack)
        NotificationCenter.default.post(name: .codeBlockLayoutSettingsChanged, object: nil)
    }

    func setRowBackground(_ hex: String?) {
        var pack = currentThemePack()
        pack.rowBackgroundHex = hex.map { $0.uppercased() }
        persistPack(pack)
    }

    /// 一次把 ST 主题包解析出来的东西全应用上。
    /// 颜色走 `applyThemePack`，几何走这里。
    func applySillyTavern(_ imported: SillyTavernTheme.Imported) {
        var pack = currentThemePack()
        pack.name = imported.name
        pack.avatarShape = imported.avatarShape.rawValue
        pack.chatDisplay = imported.chatDisplay.rawValue
        // [10-19 醒醒] waifuMode → 立绘模式
        pack.novelMode = imported.novelMode.rawValue
        if let lh = imported.lineHeight { pack.lineHeight = min(2.2, max(0.9, lh)) }
        if let ls = imported.letterSpacing { pack.letterSpacing = min(3, max(-1, ls)) }
        if let r = imported.bubbleRadius {
            // ST 的 border-radius 是 px，我们的圆角是 pt，比例大致 1:1
            pack.userBubbleRadius = min(32, max(0, r))
            pack.assistantBubbleRadius = min(32, max(0, r))
            pack.inputBarRadius = min(32, max(4, r))
        }
        persistPack(pack)

        // 颜色走 `setColor` —— 真正生效的是 `customColors`，不是 pack 里的
        // `colorsLight`/`colorsDark` 那两张表（那两张是导出用的快照）。
        // 上一版写错了地方，导入完颜色不变，这里修正。
        //
        // [10-18 醒醒 第五轮] 导入时**也过一遍对比度**。
        // 实测她那六个真实包里，有三个的文字对比度不够：
        //   小猫文件夹 4.12、给你的信 3.01、面包狗 3.22，都低于 WCAG 的 4.5。
        // ST 是网页，作者用 CSS 调位置和装饰，文字偏淡是常态。我们不照抄
        // 看不清的组合——推到达标为止，色相不变只动明度。
        for (role, hex) in imported.light {
            setColor(Color(hex: hex), role: role, scope: .global, variant: .light)
        }
        for (role, hex) in imported.dark {
            setColor(Color(hex: hex), role: role, scope: .global, variant: .dark)
        }

        for variant in [AppearanceVariant.light, .dark] {
            let bgRole = AppearanceColorRole.canvas
            let bg = hex(bgRole, scope: .global, variant: variant)
            let surface = hex(.surface, scope: .global, variant: variant)
            for role in [AppearanceColorRole.primaryText, .secondaryText] {
                var fg = hex(role, scope: .global, variant: variant)
                fg = AppearanceContrast.enforce(fg, on: bg, level: .body)
                fg = AppearanceContrast.enforce(fg, on: surface, level: .body)
                if fg != hex(role, scope: .global, variant: variant) {
                    setColor(Color(hex: fg), role: role, scope: .global, variant: variant)
                }
            }
        }
    }

    func setThinkingFont(title: Double? = nil, body: Double? = nil) {
        var pack = currentThemePack()
        if let title { pack.thinkingTitleSize = min(22, max(10, title)) }
        if let body { pack.thinkingBodySize = min(22, max(10, body)) }
        persistPack(pack)
    }

    func setCategorySymbol(_ symbol: String, for key: String) {
        guard AppearanceThemePack.categoryKeys.contains(key) else { return }
        var pack = currentThemePack()
        let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            pack.categoryIcons.removeValue(forKey: key)
        } else {
            pack.categoryIcons[key] = trimmed
        }
        persistPack(pack)
    }

    func setCategoryColor(_ color: Color, for key: String) {
        guard AppearanceThemePack.categoryKeys.contains(key) else { return }
        var pack = currentThemePack()
        pack.categoryColors[key] = UIColor(color).hexRGB
        persistPack(pack)
    }

    func clearCategoryChrome(for key: String) {
        guard AppearanceThemePack.categoryKeys.contains(key) else { return }
        var pack = currentThemePack()
        pack.categoryIcons.removeValue(forKey: key)
        pack.categoryColors.removeValue(forKey: key)
        persistPack(pack)
    }

    private func categoryImageURL(_ key: String) -> URL {
        appearanceDirectory.appendingPathComponent("category-\(key).jpg")
    }

    func categoryImage(for key: String) -> UIImage? {
        // [PIC-1] Memory-cached read; the key already embeds size+mtime,
        // so replacing the file invalidates without an explicit clear —
        // the explicit clear in setCategoryImage covers the same-tick
        // re-read before the filesystem settles.
        let path = categoryImageURL(key).path
        if let hit = ThumbnailCache.shared.cachedThumbnail(for: path) { return hit }
        guard let image = UIImage(contentsOfFile: path) else { return nil }
        ThumbnailCache.shared.store(image, for: path)
        return image
    }

    @discardableResult
    func setCategoryImage(_ image: UIImage, for key: String) -> Bool {
        guard AppearanceThemePack.categoryKeys.contains(key) else { return false }
        guard writeDownscaledJPEG(image, to: categoryImageURL(key), maxEdge: 256, quality: 0.86) else {
            return false
        }
        var pack = currentThemePack()
        pack.categoryImages[key] = "file"
        persistPack(pack)
        return true
    }

    func removeCategoryImage(for key: String) {
        try? FileManager.default.removeItem(at: categoryImageURL(key))
        var pack = currentThemePack()
        pack.categoryImages.removeValue(forKey: key)
        persistPack(pack)
    }

    private func wipeCategoryImageFiles() {
        for key in AppearanceThemePack.categoryKeys {
            try? FileManager.default.removeItem(at: categoryImageURL(key))
        }
    }

    /// Applies the pack's category-image map.
    ///
    /// Missing key = "not mentioned" → leave the file and its marker alone.
    /// This used to treat a missing key as a delete request, so any partial
    /// pack (an AI call carrying colors only, a legacy JSON without the map)
    /// wiped every user-supplied category image. Explicit removal has to say
    /// so: an empty string for that key.
    private func applyCategoryImages(_ map: [String: String]) {
        var pack = currentThemePack()
        for key in AppearanceThemePack.categoryKeys {
            guard let value = map[key] else { continue }
            if value.isEmpty {
                try? FileManager.default.removeItem(at: categoryImageURL(key))
                ThumbnailCache.shared.removeThumbnail(for: categoryImageURL(key).path)
                pack.categoryImages.removeValue(forKey: key)
                continue
            }
            if value == "file" {
                if FileManager.default.fileExists(atPath: categoryImageURL(key).path) {
                    pack.categoryImages[key] = "file"
                } else {
                    pack.categoryImages.removeValue(forKey: key)
                }
                continue
            }
            guard let data = Data(base64Encoded: value), UIImage(data: data) != nil else {
                // Undecodable payload: keep whatever is already on disk
                // rather than silently dropping the user's image.
                continue
            }
            writeEncodedImage(data, to: categoryImageURL(key), maxEdge: 256, quality: 0.86)
            pack.categoryImages[key] = "file"
        }
        persistPack(pack)
    }

    /// Writes a downscaled JPEG and drops the cached thumbnail for that path.
    @discardableResult
    private func writeDownscaledJPEG(_ image: UIImage, to url: URL,
                                    maxEdge: CGFloat, quality: CGFloat) -> Bool {
        let size = image.size
        let scale = min(1, maxEdge / max(size.width, size.height, 1))
        let target = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        // [B28 R2-2] 编码失败 / 写盘失败以前全是静默的。现在如实上抛。
        guard let data = rendered.jpegData(compressionQuality: quality) else {
            appearanceLog.warning("jpeg encode failed for \(url.lastPathComponent)")
            return false
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            appearanceLog.warning("image write failed \(url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
        ThumbnailCache.shared.removeThumbnail(for: url.path)
        return true
    }

    /// Stores an image payload that already arrived as encoded bytes.
    ///
    /// Round-tripping through UIImage and re-encoding a second time cost
    /// roughly 3x the bytes and a visible generation loss on every apply.
    /// The bytes are only re-encoded when they exceed the target edge, which
    /// is the one case where re-encoding actually buys something.
    @discardableResult
    private func writeEncodedImage(_ data: Data, to url: URL,
                                   maxEdge: CGFloat, quality: CGFloat) -> Bool {
        if let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 {
            let longest = max(image.size.width, image.size.height)
            if longest > maxEdge {
                return writeDownscaledJPEG(image, to: url, maxEdge: maxEdge, quality: quality)
            }
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            appearanceLog.warning("image write failed \(url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
        ThumbnailCache.shared.removeThumbnail(for: url.path)
        return true
    }

    private func thinkingCardURL() -> URL {
        appearanceDirectory.appendingPathComponent("thinking-card.jpg")
    }

    func thinkingCardImage() -> UIImage? {
        // [PIC-1] Same cached-read pattern as categoryImage above.
        let path = thinkingCardURL().path
        if let hit = ThumbnailCache.shared.cachedThumbnail(for: path) { return hit }
        guard let image = UIImage(contentsOfFile: path) else { return nil }
        ThumbnailCache.shared.store(image, for: path)
        return image
    }

    func hasThinkingCardImage() -> Bool {
        FileManager.default.fileExists(atPath: thinkingCardURL().path)
    }

    @discardableResult
    func setThinkingCardImage(_ image: UIImage) -> Bool {
        guard writeDownscaledJPEG(image, to: thinkingCardURL(), maxEdge: 1400, quality: 0.82) else { return false }
        var pack = currentThemePack()
        pack.thinkingCardJPEGBase64 = nil
        persistPack(pack)
        return true
    }

    /// Stores an already-encoded thinking-card image without a re-encode round trip.
    @discardableResult
    func setThinkingCardImageEncoded(_ data: Data) -> Bool {
        guard writeEncodedImage(data, to: thinkingCardURL(), maxEdge: 1400, quality: 0.82) else { return false }
        var pack = currentThemePack()
        pack.thinkingCardJPEGBase64 = nil
        persistPack(pack)
        return true
    }

    func removeThinkingCardImage() {
        try? FileManager.default.removeItem(at: thinkingCardURL())
        ThumbnailCache.shared.removeThumbnail(for: thinkingCardURL().path)
        var pack = currentThemePack()
        pack.thinkingCardJPEGBase64 = nil
        persistPack(pack)
    }

    func setThinkingCardImageOpacity(_ value: Double) {
        var pack = currentThemePack()
        pack.thinkingCardImageOpacity = min(1, max(0.05, value))
        persistPack(pack)
    }

    private func inputBarImageURL() -> URL {
        appearanceDirectory.appendingPathComponent("input-bar.jpg")
    }

    func inputBarImage() -> UIImage? {
        // [PIC-1] Same cached-read pattern as categoryImage above.
        let path = inputBarImageURL().path
        if let hit = ThumbnailCache.shared.cachedThumbnail(for: path) { return hit }
        guard let image = UIImage(contentsOfFile: path) else { return nil }
        ThumbnailCache.shared.store(image, for: path)
        return image
    }

    func hasInputBarImage() -> Bool {
        FileManager.default.fileExists(atPath: inputBarImageURL().path)
    }

    @discardableResult
    func setInputBarImage(_ image: UIImage) -> Bool {
        guard writeDownscaledJPEG(image, to: inputBarImageURL(), maxEdge: 1400, quality: 0.82) else { return false }
        var pack = currentThemePack()
        pack.inputBarJPEGBase64 = nil
        persistPack(pack)
        return true
    }

    /// Stores an already-encoded input-bar image without a re-encode round trip.
    @discardableResult
    func setInputBarImageEncoded(_ data: Data) -> Bool {
        guard writeEncodedImage(data, to: inputBarImageURL(), maxEdge: 1400, quality: 0.82) else { return false }
        var pack = currentThemePack()
        pack.inputBarJPEGBase64 = nil
        persistPack(pack)
        return true
    }

    func removeInputBarImage() {
        try? FileManager.default.removeItem(at: inputBarImageURL())
        ThumbnailCache.shared.removeThumbnail(for: inputBarImageURL().path)
        var pack = currentThemePack()
        pack.inputBarJPEGBase64 = nil
        persistPack(pack)
    }

    func setInputBarImageOpacity(_ value: Double) {
        var pack = currentThemePack()
        pack.inputBarImageOpacity = min(1, max(0.05, value))
        persistPack(pack)
    }

    fileprivate func applyPackColors(light: [String: String], dark: [String: String]) {
        func paint(_ map: [String: String], variant: AppearanceVariant) {
            for (raw, hex) in map {
                guard let role = AppearanceColorRole(rawValue: raw) else { continue }
                setColor(Color(hex: hex), role: role, scope: .global, variant: variant)
            }
        }
        paint(light, variant: .light)
        paint(dark, variant: .dark)
    }

    fileprivate func exportColors(variant: AppearanceVariant) -> [String: String] {
        var out: [String: String] = [:]
        for role in AppearanceColorRole.allCases {
            out[role.rawValue] = hex(role, scope: .global, variant: variant)
        }
        return out
    }
}

@MainActor
enum MinisThemeShape {
    static var pack: AppearanceThemePack { AppearanceStudio.shared.loadStoredPack() }
    static var userBubbleRadius: CGFloat { pack.radius(.userBubble) }
    static var assistantBubbleRadius: CGFloat { pack.radius(.assistantBubble) }
    static var thinkingRadius: CGFloat { pack.radius(.thinking) }
    /// [B28 B-3] 三个 thinking 颜色字段原来写了不生效：`MinisThemeShape`
    /// 直接取 `AppearanceStudio.color(.accent, scope: .chat)`，而 pack 里的
    /// `thinkingFillHex / thinkingStrokeHex / thinkingAccentHex` 只有序列化，
    /// 零读取。导出还把三个都硬写成 accent，AI 写这三个字段会以为生效了。
    ///
    /// 现在真读。空串回落到 accent —— 老 pack 里这三个字段是 accent 的副本，
    /// 行为不变；`resetThemePack` 清掉 defaults 后 `.default` 带的是暖色值，
    /// 也和内置配色对得上。
    static var thinkingFill: Color {
        let hex = pack.thinkingFillHex
        guard !hex.isEmpty else {
            return AppearanceStudio.shared.color(.accent, scope: .chat).opacity(0.06)
        }
        return Color(hex: hex).opacity(0.06)
    }
    static var thinkingStroke: Color {
        let hex = pack.thinkingStrokeHex
        guard !hex.isEmpty else {
            return AppearanceStudio.shared.color(.accent, scope: .chat).opacity(0.15)
        }
        return Color(hex: hex).opacity(0.15)
    }
    static var thinkingAccent: Color {
        let hex = pack.thinkingAccentHex
        guard !hex.isEmpty else {
            return AppearanceStudio.shared.color(.accent, scope: .chat)
        }
        return Color(hex: hex)
    }
    static var userStyle: AppearanceBubbleStyle { pack.userStyle }
    static var assistantStyle: AppearanceBubbleStyle { pack.assistantStyle }
    static var thinkingCardOpacity: Double { pack.thinkingCardImageOpacity }
    static var inputBarStyle: AppearanceBubbleStyle { AppearanceBubbleStyle.parse(pack.inputBarStyle) }
    static var inputBarImageOpacity: Double { pack.inputBarImageOpacity }
    static var fontFamily: AppearanceFontFamily { AppearanceFontFamily.parse(pack.fontFamily) }

    static var userBubble: MinisBubbleShape {
        MinisBubbleShape(style: userStyle, radius: userBubbleRadius, tailOnTrailing: true)
    }
    static var assistantBubble: MinisBubbleShape {
        MinisBubbleShape(style: assistantStyle, radius: assistantBubbleRadius, tailOnTrailing: false)
    }
    static var thinkingCard: MinisBubbleShape {
        MinisBubbleShape(style: .squircle, radius: thinkingRadius, tailOnTrailing: false)
    }
    static var inputBar: MinisBubbleShape {
        MinisBubbleShape(style: inputBarStyle, radius: inputBarRadius, tailOnTrailing: false)
    }
    static var thinkingTitleSize: CGFloat {
        CGFloat(min(22, max(10, pack.thinkingTitleSize)))
    }
    static var thinkingBodySize: CGFloat {
        CGFloat(min(22, max(10, pack.thinkingBodySize)))
    }
    static var inputBarRadius: CGFloat {
        CGFloat(min(32, max(4, pack.inputBarRadius)))
    }
}

@MainActor
enum MinisThemeList {
    static var pack: AppearanceThemePack { AppearanceStudio.shared.loadStoredPack() }

    static var title: Color { AppearanceStudio.shared.color(.primaryText, scope: .home) }
    static var subtitle: Color { AppearanceStudio.shared.color(.secondaryText, scope: .home) }
    static var meta: Color { AppearanceStudio.shared.color(.secondaryText, scope: .home).opacity(0.72) }
    static var accent: Color { AppearanceStudio.shared.color(.accent, scope: .home) }
    static var rowFill: Color {
        if let hex = pack.listRowFillHex {
            return Color(hex: hex).opacity(AppearanceStudio.shared.surfaceOpacity)
        }
        return AppearanceStudio.shared.color(.surface, scope: .home)
            .opacity(AppearanceStudio.shared.surfaceOpacity)
    }
    static var iconShape: AppearanceListIconShape {
        AppearanceListIconShape.parse(pack.listIconShape)
    }

    static func categoryIcon(for category: String?) -> (systemName: String, color: Color) {
        // [batch8d / W1B2-06] Category colors retired app-wide: the glyph name
        // still resolves per category, but the color is the theme accent now —
        // imported or legacy `categoryColors` no longer reach rendering.
        let fallback = sessionCategoryIconBuiltin(for: category)
        let key = category ?? "other"
        let name = pack.categoryIcons[key] ?? fallback.systemName
        return (name, accent)
    }
}
