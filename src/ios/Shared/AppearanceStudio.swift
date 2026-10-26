import PhotosUI
import SwiftUI
import UIKit

/// [B28 R2-2] 图片写失败不再静默：留一条可查的日志。
let appearanceLog = AppLogger(category: "Appearance")

// MARK: - Semantic appearance system

enum AppearanceScope: String, CaseIterable, Identifiable {
    // [10-18 醒醒 第五轮] `terminal` 保留。
    //
    // 我一度以为它是死的，因为七个 `Terminal*.swift` 里没有主题引用——
    // 但 `ISHTerminalView.swift:95` 确实挂了
    // `AppearanceBackdrop(scope: .terminal)`。所以它能改**壁纸**，
    // 只是终端文字是 ANSI 16 色，role 对它无效。
    //
    // 结论：`terminal` 能挂壁纸、不能调色，跟 `bottomBar` 同一类。
    // [B28 R4 · 醒醒拍板 B] `persona` 通讯录独立槽位：能单独挂壁纸、
    // 能调色。之前这页压根没接进主题系统，换什么背景都不动 ——
    // 「冷冰冰」的根在这，不在圆角和标签。
    case global, home, chat, settings, browser, files, terminal, bottomBar, persona

    var id: String { rawValue }
    var title: String {
        switch self {
        case .global: return AppLocalized("全部页面")
        case .home: return AppLocalized("首页")
        case .bottomBar: return AppLocalized("底部栏")
        case .chat: return AppLocalized("聊天")
        case .settings: return AppLocalized("Settings")
        case .browser: return AppLocalized("浏览器")
        case .files: return AppLocalized("文件")
        case .terminal: return AppLocalized("终端")
        case .persona: return AppLocalized("通讯录")
        }
    }

    /// 这个 scope 能不能调颜色。
    ///
    /// `bottomBar` 和 `terminal` 只承载壁纸：底部栏图标走
    /// `MinisThemeList.accent`，终端是 ANSI 16 色渲染，role 对它们没意义。
    var supportsColour: Bool { self != .bottomBar && self != .terminal }

    /// 能挂壁纸的 scope（全部都能）。
    var supportsWallpaper: Bool { true }
}

enum AppearanceVariant: String, CaseIterable, Identifiable {
    case light, dark
    var id: String { rawValue }
    var title: String {
        // [B28 E-1] 三元里的裸中文 Text() 也查不到表。
        self == .light ? AppLocalized("Light") : AppLocalized("Dark")
    }
}

enum AppearanceColorRole: String, CaseIterable, Identifiable {
    // [10-18 醒醒] 「卡片换颜色，AI 消息下面的图标也换颜色了」。
    //
    // 根因不是分组名字起错，是**同一个控件用了两个角色**：消息操作栏的
    // 小图标底走 surface（卡片），聊天输入栏的图标底走 mutedSurface（浅底）。
    // 两个都是"小方块图标底"，却挂在不同的角色上，所以无论怎么调都只能
    // 对一半。
    //
    // 为什么会有这种事：老的十六个角色是按"它是什么层"分的（底 / 卡 /
    // 浮层 / 浅底），不是按"它是什么控件"分的。于是"一个图标底到底算卡片
    // 还是浅底"没有答案，全看当初谁写的。Apple HIG 原话就禁止这个：
    // "Avoid using the same color to mean different things."
    //
    // 补三个控件级角色（iconTile / chip / field），并把 searchField 并进
    // field、把死角色 toolCard 删掉。见下方 legacy 映射。
    case canvas, surface, raised, mutedSurface
    case primaryText, secondaryText
    case accent, userBubble, assistantBubble, border
    /// 输入类底：输入框、搜索栏、任何单行输入面
    case field
    /// 小方块图标底：消息操作栏、输入栏图标、工具条按钮
    case iconTile
    /// 胶囊/徽章底：用量、状态、标签
    case chip
    case success, warning, destructive

    var id: String { rawValue }
    var title: String {
        switch self {
        case .canvas: return AppLocalized("页面背景")
        case .surface: return AppLocalized("卡片")
        case .raised: return AppLocalized("浮层")
        case .mutedSurface: return AppLocalized("浅底")
        case .primaryText: return AppLocalized("主文字")
        case .secondaryText: return AppLocalized("次文字")
        case .accent: return AppLocalized("强调色")
        case .userBubble: return AppLocalized("我的气泡")
        case .assistantBubble: return AppLocalized("AI 气泡")
        case .border: return AppLocalized("边线")
        case .field: return AppLocalized("输入框")
        case .iconTile: return AppLocalized("图标底")
        case .chip: return AppLocalized("胶囊底")
        case .success: return AppLocalized("Success")
        case .warning: return AppLocalized("警告")
        case .destructive: return AppLocalized("危险")
        }
    }

    /// Where this role actually paints — shown under each 色盘 row so the
    /// mapping is unambiguous ("调色的时候对应的地方准确一点").
    var hint: String {
        switch self {
        case .canvas: return AppLocalized("每页底衬，卡片间隙和空区透出")
        case .surface: return AppLocalized("大块卡片：设置卡片、会话列表、工具卡")
        case .raised: return AppLocalized("浮层：弹窗、菜单、悬浮面板")
        case .mutedSurface: return AppLocalized("浅底小组件：图片占位、次要底块")
        case .primaryText: return AppLocalized("主文字：标题、正文")
        case .secondaryText: return AppLocalized("次文字：说明、时间戳")
        case .accent: return AppLocalized("强调色：按钮、选中、开关")
        case .userBubble: return AppLocalized("你的聊天气泡")
        case .assistantBubble: return AppLocalized("AI 聊天气泡")
        case .border: return AppLocalized("分隔线、卡片描边")
        case .field: return AppLocalized("输入框、搜索栏")
        case .iconTile: return AppLocalized("小方块图标底：消息操作栏、输入栏图标")
        case .chip: return AppLocalized("胶囊底：用量、状态、标签")
        case .success: return AppLocalized("成功状态（绿）")
        case .warning: return AppLocalized("警告状态（黄）")
        case .destructive: return AppLocalized("危险操作（红）")
        }
    }
}

/// The sixteen colour roles, grouped by what they paint.
///
/// The palette used to be one flat list of sixteen rows. That is why picking a
/// colour felt like "一选一片都是那个颜色" — with no grouping, the only visible
/// structure was the order they happened to be declared in, and every row
/// wrote to the same global scope. Grouping makes the shape of the palette
/// legible before you touch anything.
/// [问题5c] 色盘分组按"这个东西是什么"来分，不按"它在哪个页面"分。
///
/// 她原话：「我想字管字的颜色，卡片管卡片的颜色，按钮管按键的。
/// 好不好就是简单一点，然后统一化，我这边换什么颜色对应的东西就全部变色。」
///
/// 10-18 再改：上一版五组里「按钮与选中」只有一个 accent，分组比内容还多；
/// 而真正的问题是角色本身缺「控件」这一层（图标底/胶囊底/输入类没有自己的
/// 位置，只好去蹭卡片和浅底）。现在按"你看到的东西"分六组，每组里装的是
/// 同一种东西。
enum AppearanceColorRoleGroup: String, CaseIterable, Identifiable {
    case text, backgrounds, controls, accentGroup, chat, status

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: return AppLocalized("文字")
        case .backgrounds: return AppLocalized("背景与卡片")
        case .controls: return AppLocalized("控件")
        case .accentGroup: return AppLocalized("强调")
        case .chat: return AppLocalized("聊天")
        case .status: return AppLocalized("Status")
        }
    }

    /// 这一组管什么，写在分组标题下面，省得再猜。
    var hint: String {
        switch self {
        case .text: return AppLocalized("标题、正文、说明、时间戳——所有字")
        case .backgrounds: return AppLocalized("页面底衬、大块卡片、弹窗浮层、次要底块")
        case .controls: return AppLocalized("图标底、胶囊底、输入框、边线——小零件")
        case .accentGroup: return AppLocalized("按钮、开关、选中态")
        case .chat: return AppLocalized("聊天气泡、工具卡")
        case .status: return AppLocalized("成功、警告、危险")
        }
    }

    var roles: [AppearanceColorRole] {
        switch self {
        case .text: return [.primaryText, .secondaryText]
        case .backgrounds: return [.canvas, .surface, .raised, .mutedSurface]
        case .controls: return [.iconTile, .chip, .field, .border]
        case .accentGroup: return [.accent]
        case .chat: return [.userBubble, .assistantBubble]
        case .status: return [.success, .warning, .destructive]
        }
    }
}

// MARK: - 旧角色兼容

extension AppearanceColorRole {
    /// 老版本存下来的角色名 → 现在该落到哪个角色。
    ///
    /// 角色是按字符串持久化的（UserDefaults 的 `colors.v1`、主题包 JSON 的
    /// `colorsLight`/`colorsDark`、云同步、备份），所以删掉的 `input` /
    /// `searchField` / `toolCard` 必须继续认，否则老主题包和老备份里这三项
    /// 的颜色会被静默丢掉。
    ///
    /// 合并方向：
    /// - `input` / `searchField` → `field`（本来就是同一类）
    /// - `toolCard` → `surface`（上一轮已经把工具卡改成走卡片了，角色是空壳）
    static func resolvingLegacy(_ raw: String) -> AppearanceColorRole? {
        switch raw {
        case "input", "searchField": return .field
        case "toolCard": return .surface
        default: return AppearanceColorRole(rawValue: raw)
        }
    }

    /// 老角色名是否还需要在读取时重定向。
    static var legacyRawValues: [String] { ["input", "searchField", "toolCard"] }
}

@MainActor
final class AppearanceStudio: ObservableObject {
    static let shared = AppearanceStudio()

    private enum Keys {
        static let colors = "appearanceStudio.colors.v1"
        static let userAvatar = "appearanceStudio.userAvatar.v1"
        /// [B28 R10] 用户自定义称呼。界面/提示里要提到"说话的人"时用它，
        /// 不写死任何具体名字——没填就回落到中性称呼。
        static let userDisplayName = "appearanceStudio.userDisplayName.v1"
        static let surfaceOpacity = "appearanceStudio.surfaceOpacity"
        static let bubbleOpacity = "appearanceStudio.bubbleOpacity"
        static let wallpaperShade = "appearanceStudio.wallpaperShade"
        static let icons = "appearanceStudio.icons.v1"
    }

    /// Custom values only. Missing values inherit from the built-in palette;
    /// page values inherit from global before falling back to built-in.
    @Published private var customColors: [String: String]
    /// Snapshot for UIKit / off-main reads. Written on persist.
    nonisolated(unsafe) static var colorSnapshot: [String: String] = [:]
    @Published private(set) var wallpaperRevision = 0
    @Published private(set) var iconRevision = 0
    @Published private(set) var userAvatar: String
    /// [B28 R10] 她自己填的称呼。空 = 没设置，调用方自己回落到中性词。
    @Published private(set) var userDisplayName: String
    @Published private var customIcons: [String: String]
    @Published var surfaceOpacity: Double {
        didSet { UserDefaults.standard.set(surfaceOpacity, forKey: Keys.surfaceOpacity) }
    }
    /// [T-bubble-opacity-slider] Bubble-only transparency, separate from the
    /// global surfaceOpacity so dialling bubbles down doesn't wash out cards,
    /// tool capsules and the input bar. User + assistant bubbles both read it.
    @Published var bubbleOpacity: Double {
        didSet { UserDefaults.standard.set(bubbleOpacity, forKey: Keys.bubbleOpacity) }
    }
    @Published var wallpaperShade: Double {
        didSet { UserDefaults.standard.set(wallpaperShade, forKey: Keys.wallpaperShade) }
    }
    @Published var themePackRevision = 0

    private var wallpaperCache: [AppearanceScope: UIImage] = [:]
    /// [T-wallpaper-clear][09-10 醒醒] Scopes whose own wallpaper was CLEARED
    /// with "清除当前背景" — they do NOT fall back to the global image, so the
    /// page returns to its plain initial canvas colour. Removing the global
    /// image clears the block list too (a global clear resets everything).
    private var wallpaperClearedFallback: Set<AppearanceScope> = []
    private static let wallpaperClearedKey = "appearanceStudio.wallpaperClearedFallback"
    var cachedThemePack: AppearanceThemePack = .default
    var themePackLoaded = false
    let themePackLock = NSLock()

    private init() {
        if let data = UserDefaults.standard.data(forKey: Keys.colors),
           let value = try? JSONDecoder().decode([String: String].self, from: data) {
            customColors = value
        } else {
            customColors = [:]
        }
        // [avatar-file] Migrate-on-read for the user avatar, inlined here:
        // Swift forbids self calls before all stored properties are
        // initialized, so init cannot call loadUserAvatar() (which stays
        // for reloadAfterRestore(), where self is complete).
        let rawAvatar = UserDefaults.standard.string(forKey: Keys.userAvatar) ?? ""
        if SoulIconImage.isDataURI(rawAvatar),
           let path = SoulIconImage.migrateDataURIToFile(rawAvatar, named: "user") {
            UserDefaults.standard.set(path, forKey: Keys.userAvatar)
            userAvatar = path
        } else {
            userAvatar = rawAvatar
        }
        userDisplayName = (UserDefaults.standard.string(forKey: Keys.userDisplayName) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // [PIC-6] Custom icons used to live in UserDefaults as one JSON blob
        // of base64 data URIs (23 slots × ~1MB of PNG = a multi-MB plist
        // the system rewrites on every sync). They now live as PNG files
        // under the appearance directory; the in-memory dictionary is kept
        // as the read cache and `customIcon(for:)`'s data-URI contract is
        // unchanged.
        Self.migrateCustomIconsFromUserDefaults()
        customIcons = Self.loadCustomIconsFromDisk()
        let storedOpacity = UserDefaults.standard.object(forKey: Keys.surfaceOpacity) as? Double
        let storedShade = UserDefaults.standard.object(forKey: Keys.wallpaperShade) as? Double
        surfaceOpacity = storedOpacity ?? 0.88
        let storedBubbleOpacity = UserDefaults.standard.object(forKey: Keys.bubbleOpacity) as? Double
        bubbleOpacity = storedBubbleOpacity ?? 1.0
        wallpaperShade = storedShade ?? 0.08
        loadWallpaperCleared()
        cachedThemePack = loadStoredPackUnlocked()
        themePackLoaded = true
        Self.colorSnapshot = customColors
        configureUIKitSurfaces()
    }

    fileprivate static let lightDefaults = AppearancePaletteBook.light
    fileprivate static let darkDefaults = AppearancePaletteBook.dark

    private func key(_ role: AppearanceColorRole, scope: AppearanceScope,
                     variant: AppearanceVariant) -> String {
        "\(scope.rawValue).\(variant.rawValue).\(role.rawValue)"
    }

    /// 老角色名的键。删掉的 `input` / `searchField` / `toolCard` 只用来读，
    /// 不再写——写的时候一律落到新角色上。
    private func keyString(_ legacyRole: String, scope: AppearanceScope,
                           variant: AppearanceVariant) -> String {
        "\(scope.rawValue).\(variant.rawValue).\(legacyRole)"
    }

    func hex(_ role: AppearanceColorRole, scope: AppearanceScope = .global,
             variant: AppearanceVariant) -> String {
        // 新角色先读自己的键，再读它继承的旧键。
        //
        // 角色是按字符串存进 UserDefaults 的（"<scope>.<variant>.<role>"），
        // 所以 `field` 必须能接住老用户存过的 `input` / `searchField`；
        // `surface` 必须能接住 `toolCard`（上一轮把工具卡并进卡片时留的壳）。
        // 顺序：自己的 → 旧键 → 全局 → 内置。
        if let value = customColors[key(role, scope: scope, variant: variant)] { return value }
        if let legacy = legacyKey(for: role, scope: scope, variant: variant),
           let value = customColors[legacy] { return value }
        if scope != .global {
            if let value = customColors[key(role, scope: .global, variant: variant)] { return value }
            if let legacy = legacyKey(for: role, scope: .global, variant: variant),
               let value = customColors[legacy] { return value }
        }
        return (variant == .light ? Self.lightDefaults : Self.darkDefaults)[role] ?? "808080"
    }

    /// 老键名，按"新角色 → 它继承的旧角色"查。
    private func legacyKey(for role: AppearanceColorRole, scope: AppearanceScope,
                           variant: AppearanceVariant) -> String? {
        switch role {
        case .field:
            // 两个旧角色都是输入类，谁有值用谁——input 更常见，先问它。
            return customColors[keyString("input", scope: scope, variant: variant)] != nil
                ? keyString("input", scope: scope, variant: variant)
                : keyString("searchField", scope: scope, variant: variant)
        case .surface:
            return keyString("toolCard", scope: scope, variant: variant)
        default:
            return nil
        }
    }

    /// 取一个语义色。
    ///
    /// [T-dynamic-color] 不传 `variant` 时返回的是**动态色**：它同时带着
    /// 浅色和深色两套值，由 UIKit 在解析时按当前 trait collection 选。
    ///
    /// 为什么要这样：原来这个函数用 `activeVariant` 自己判明暗（读
    /// `appearanceMode` + `UITraitCollection.current`），而 `CSSThemeVariables`
    /// 又让调用方传 `colorScheme == .dark` 进来 —— 两个判定源。用户在设置里
    /// 强制浅色、系统是深色时，两者给出相反的答案，同一屏的卡片和文字就分成
    /// 两种配色。
    ///
    /// 动态色只有一个判定源：`preferredColorScheme` 改的就是 trait
    /// collection，所以"跟随系统"和"强制浅/深"走的是同一条路，不可能打架。
    /// 顺带：切系统外观不用重建视图，UIKit 自己重解析。
    ///
    /// 传了 `variant` 的调用方（主题包预览、对比度体检）要的就是一个确定的
    /// 值，原样返回静态色。
    func color(_ role: AppearanceColorRole, scope: AppearanceScope = .global,
               variant: AppearanceVariant? = nil) -> Color {
        if let variant { return Color(hex: hex(role, scope: scope, variant: variant)) }
        return Color(uiColor: uiColor(role, scope: scope))
    }

    /// 一整页所有角色的当前值。对比度体检用。
    func allColors(scope: AppearanceScope = .global,
                   variant: AppearanceVariant) -> [AppearanceColorRole: String] {
        var out: [AppearanceColorRole: String] = [:]
        for role in AppearanceColorRole.allCases {
            out[role] = hex(role, scope: scope, variant: variant)
        }
        return out
    }

    /// 语义色的 UIKit 形式，同样是动态色。
    ///
    /// `UIColor(dynamicProvider:)` 的闭包在每次 trait 变化时被调用，闭包里读
    /// `trait.userInterfaceStyle` —— 这是 UIKit 唯一认可的判定源，和
    /// `preferredColorScheme` 是同一条链。
    ///
    /// 不用 `UITraitCollection.current`：它在后台线程是未定义值，动态色的
    /// 闭包恰好可能被非主线程调用。闭包给的 `trait` 永远是本次解析对应的
    /// 那一套。
    func uiColor(_ role: AppearanceColorRole, scope: AppearanceScope = .global,
                 variant: AppearanceVariant? = nil) -> UIColor {
        if let variant {
            return UIColor(hex: hex(role, scope: scope, variant: variant))
        }
        return UIColor { trait in
            let resolved: AppearanceVariant = trait.userInterfaceStyle == .dark ? .dark : .light
            // 闭包可能不在主线程跑，走快照而不是 @MainActor 的 self。
            return UIColor(hex: AppearanceStudio.snapshotHex(role, scope: scope, variant: resolved))
        }
    }

    var activeVariant: AppearanceVariant {
        let mode = UserDefaults.standard.integer(forKey: "appearanceMode")
        if mode == 1 { return .light }
        if mode == 2 { return .dark }
        return UITraitCollection.current.userInterfaceStyle == .dark ? .dark : .light
    }

    func setColor(_ color: Color, role: AppearanceColorRole,
                  scope: AppearanceScope, variant: AppearanceVariant) {
        // 底部栏只挂壁纸，不收颜色。静默忽略，不报错——旧数据或 AI 传进来
        // 也不会写出一个永远读不到的键。
        guard scope.supportsColour else { return }
        customColors[key(role, scope: scope, variant: variant)] = UIColor(color).hexRGB
        persistColors()
        configureUIKitSurfaces()
    }

    func colorBinding(_ role: AppearanceColorRole, scope: AppearanceScope,
                      variant: AppearanceVariant) -> Binding<Color> {
        Binding(
            get: { self.color(role, scope: scope, variant: variant) },
            set: { self.setColor($0, role: role, scope: scope, variant: variant) }
        )
    }

    func hasOverride(_ role: AppearanceColorRole, scope: AppearanceScope,
                     variant: AppearanceVariant) -> Bool {
        customColors[key(role, scope: scope, variant: variant)] != nil
    }

    /// 这一页有几项和全局不一样。给「高级」里的页级覆盖显示用——
    /// 不显示这个数，她永远不知道自己改过哪一层。
    func overrideCount(scope: AppearanceScope, variant: AppearanceVariant) -> Int {
        guard scope != .global else { return 0 }
        let prefix = "\(scope.rawValue).\(variant.rawValue)."
        return customColors.keys.filter { $0.hasPrefix(prefix) }.count
    }

    /// 把这一页的覆盖全部清掉，回到跟随全局。
    func clearOverrides(scope: AppearanceScope, variant: AppearanceVariant) {
        guard scope != .global else { return }
        let prefix = "\(scope.rawValue).\(variant.rawValue)."
        for key in customColors.keys where key.hasPrefix(prefix) {
            customColors.removeValue(forKey: key)
        }
        persistColors()
        configureUIKitSurfaces()
    }

    func clearOverride(_ role: AppearanceColorRole, scope: AppearanceScope,
                       variant: AppearanceVariant) {
        customColors.removeValue(forKey: key(role, scope: scope, variant: variant))
        persistColors()
    }

    /// [audit-D6] True when any page-scoped (non-global) color override exists.
    /// No current editor writes these — legacy builds' per-page editors did —
    /// but the resolver still lets them win over the global palette, and
    /// nothing in the UI can show or clear one.
    var hasNonGlobalColorOverrides: Bool {
        let prefix = AppearanceScope.global.rawValue + "."
        return customColors.keys.contains { !$0.hasPrefix(prefix) }
    }

    /// [audit-D6] Drop every non-global color override, keeping the user's
    /// global palette. Before this, the only way to clear a stray page-scope
    /// key was「恢复默认色盘」, which wipes the whole palette with it.
    func clearNonGlobalColorOverrides() {
        let prefix = AppearanceScope.global.rawValue + "."
        customColors = customColors.filter { $0.key.hasPrefix(prefix) }
        persistColors()
        configureUIKitSurfaces()
    }

    /// Replaces the whole color override map. Used by theme undo, which has
    /// to put back the exact palette a reset wiped — including its absence.
    func restoreColorOverrides(_ overrides: [String: String]) {
        customColors = overrides
        persistColors()
        configureUIKitSurfaces()
    }

    /// Read-only view of the raw override map, for the theme undo snapshot.
    /// `exportColors` cannot serve here: it resolves every role to a concrete
    /// hex, which would turn "never overridden" into a hard-coded value and
    /// make the restored palette diverge from the original.
    func exportColorOverrides() -> [String: String] {
        customColors
    }

    func applyPreset(_ preset: AppearancePreset) {
        let palettes = preset.colors
        for variant in AppearanceVariant.allCases {
            let values = variant == .light ? palettes.light : palettes.dark
            for (role, hex) in values {
                customColors[key(role, scope: .global, variant: variant)] = hex
            }
        }
        persistColors()
        configureUIKitSurfaces()
    }

    /// [10-18 醒醒] 摇一套配色。只写全局键，不碰页级覆盖——
    /// 她单独调过的某一页不该被一次"摇骰子"冲掉。
    ///
    /// `mood` 传 nil 就随机挑一个风格（连点几次每次调子都不同）。
    /// 返回这套的默认名字，页面上可以拿它当"存这套"的默认值。
    @discardableResult
    func shuffleTheme(seed: UInt64? = nil,
                      mood: AppearanceThemeShuffle.Mood? = nil) -> String {
        let rolled = AppearanceThemeShuffle.shuffle(seed: seed, mood: mood)
        for variant in AppearanceVariant.allCases {
            let values = variant == .light ? rolled.light : rolled.dark
            for (role, hex) in values {
                customColors[key(role, scope: .global, variant: variant)] = hex
            }
        }
        persistColors()
        configureUIKitSurfaces()
        return rolled.name
    }

    func resetColors() {
        customColors.removeAll()
        surfaceOpacity = 0.88
        bubbleOpacity = 1.0
        wallpaperShade = 0.08
        persistColors()
        configureUIKitSurfaces()
    }

    private func persistColors() {
        if let data = try? JSONEncoder().encode(customColors) {
            UserDefaults.standard.set(data, forKey: Keys.colors)
        }
        Self.colorSnapshot = customColors
        objectWillChange.send()
    }

    /// Safe for UIKit callbacks. Resolves chat-scoped roles without hopping the actor.
    nonisolated static func uiColorSnapshot(_ role: AppearanceColorRole,
                                            scope: AppearanceScope = .chat) -> UIColor {
        let variant: AppearanceVariant = {
            let mode = UserDefaults.standard.integer(forKey: "appearanceMode")
            if mode == 1 { return .light }
            if mode == 2 { return .dark }
            return UITraitCollection.current.userInterfaceStyle == .dark ? .dark : .light
        }()
        return UIColor(hex: snapshotHex(role, scope: scope, variant: variant))
    }

    /// 快照解析：给非主线程和 UIKit 动态色闭包用的纯函数。
    ///
    /// 和 `hex(_:scope:variant:)` 必须保持同一套回退规则（自己的键 → 老键 →
    /// 全局 → 内置），否则同一块颜色在主线程和快照路径会不一样。老键回退
    /// 那条注释就是上一轮踩出来的，别删。
    nonisolated static func snapshotHex(_ role: AppearanceColorRole,
                                        scope: AppearanceScope = .global,
                                        variant: AppearanceVariant) -> String {
        let snap = colorSnapshot
        let scoped = "\(scope.rawValue).\(variant.rawValue).\(role.rawValue)"
        let global = "\(AppearanceScope.global.rawValue).\(variant.rawValue).\(role.rawValue)"
        // 老键回退：field 接 input/searchField，surface 接 toolCard。
        func legacy(_ raw: String) -> String? {
            let s = "\(scope.rawValue).\(variant.rawValue).\(raw)"
            let g = "\(AppearanceScope.global.rawValue).\(variant.rawValue).\(raw)"
            return snap[s] ?? snap[g]
        }
        let legacyValue: String? = {
            switch role {
            case .field: return legacy("input") ?? legacy("searchField")
            case .surface: return legacy("toolCard")
            default: return nil
            }
        }()
        return snap[scoped] ?? snap[global] ?? legacyValue
            ?? (variant == .light ? AppearancePaletteBook.light : AppearancePaletteBook.dark)[role]
            ?? "808080"
    }

    // MARK: Wallpaper

    var appearanceDirectory: URL { Self.appearanceDirectoryURL }

    /// Static twin of `appearanceDirectory`: init-time helpers that run
    /// before all stored properties are initialized (the PIC-6 icon
    /// migration/load) resolve the same directory without touching `self`.
    /// `nonisolated`: the body is a pure path computation plus an
    /// idempotent directory creation, and off-main callers (the backup
    /// system) need the path without an actor hop.
    private nonisolated static var appearanceDirectoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        let dir = base.appendingPathComponent("AppearanceStudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// [PIC-2] The directory the backup system archives wholesale for the
    /// Appearance category: every wallpaper, category / card image,
    /// custom icon and saved-theme pack lives under it.
    nonisolated static var appearanceAssetsDirectory: URL { appearanceDirectoryURL }

    private func wallpaperURL(_ scope: AppearanceScope) -> URL {
        appearanceDirectory.appendingPathComponent("wallpaper-\(scope.rawValue).jpg")
    }

    func hasWallpaper(_ scope: AppearanceScope) -> Bool {
        if FileManager.default.fileExists(atPath: wallpaperURL(scope).path) { return true }
        // [batch7 用户-P2-9] 底部栏永不继承全局图：没专属图就是纯透明，
        // 否则全局图会被压成一条"邮票"小图（见 ContentView.homeBottomBarBackground
        // "默认完全透明，只有放了壁纸才出图"）。
        guard scope != .global, scope != .bottomBar,
              !wallpaperClearedFallback.contains(scope) else { return false }
        return FileManager.default.fileExists(atPath: wallpaperURL(.global).path)
    }

    func hasOwnWallpaper(_ scope: AppearanceScope) -> Bool {
        FileManager.default.fileExists(atPath: wallpaperURL(scope).path)
    }

    func wallpaper(for scope: AppearanceScope) -> UIImage? {
        if let cached = wallpaperCache[scope] { return cached }
        let own = wallpaperURL(scope)
        // [T-wallpaper-clear] A cleared page never inherits the global image.
        // [batch7 用户-P2-9] 底部栏同样永不继承：无专属图时返回 nil（纯透明），
        // 不拿全局图来凑。
        let fallbackURL = (scope == .global || scope == .bottomBar
                           || wallpaperClearedFallback.contains(scope))
            ? nil : wallpaperURL(.global)
        let url = FileManager.default.fileExists(atPath: own.path)
            ? own
            : (fallbackURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
        guard let url, let image = UIImage(contentsOfFile: url.path) else { return nil }
        wallpaperCache[scope] = image
        return image
    }

    /// [B28 R2-2] 原来解不出来就 `guard else return`——用户点了、转完了、
    /// 什么也没发生、什么也没说。撒谎的沉默。现在把失败如实报给 UI。
    @discardableResult
    func setWallpaper(_ image: UIImage, for scope: AppearanceScope, dark: Bool = false) -> Bool {
        guard let data = Self.backgroundJPEG(image, dark: dark) else { return false }
        writeWallpaperData(data, for: scope)
        return true
    }

    /// Stores wallpaper bytes that are already encoded.
    ///
    /// A pack carries a JPEG; decoding it into a UIImage and re-encoding
    /// threw away a generation and inflated the file. Re-encoding now only
    /// happens when the image is larger than the wallpaper edge limit.
    @discardableResult
    func setWallpaperEncoded(_ data: Data, for scope: AppearanceScope) -> Bool {
        if let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 {
            let longest = max(image.size.width, image.size.height)
            if longest > 2200 {
                return setWallpaper(image, for: scope)
            }
        }
        return writeWallpaperData(data, for: scope)
    }

    @discardableResult
    private func writeWallpaperData(_ data: Data, for scope: AppearanceScope) -> Bool {
        // [B28 R2-2] 写失败（磁盘满、目录异常）以前被 try? 吃掉。现在报出去。
        do {
            try data.write(to: wallpaperURL(scope), options: .atomic)
        } catch {
            appearanceLog.warning("wallpaper write failed for \(scope.rawValue): \(error.localizedDescription)")
            return false
        }
        // [T-wallpaper-clear] Choosing a new image re-enables global
        // fallback for this scope (the clear only sticks until overridden).
        wallpaperClearedFallback.remove(scope)
        persistWallpaperCleared()
        wallpaperCache.removeAll()
        wallpaperRevision += 1
        return true
    }

    func removeWallpaper(_ scope: AppearanceScope) {
        try? FileManager.default.removeItem(at: wallpaperURL(scope))
        // [B28 R2-9] 恢复继承就得把"不继承"标记一起清掉 —— 以前只删文件
        // 不清标记，用户选了"跟随全局"，全局图却不出现：状态和承诺不符。
        if scope == .global {
            wallpaperClearedFallback.removeAll()
        } else {
            wallpaperClearedFallback.remove(scope)
        }
        persistWallpaperCleared()
        wallpaperCache.removeAll()
        wallpaperRevision += 1
    }

    /// [T-wallpaper-clear] "清除当前背景" — drop this page's wallpaper AND
    /// cut the global inheritance so the page returns to its initial plain
    /// canvas. Distinct from `removeWallpaper` ("改用继承的背景"), which only
    /// drops the page's own image and lets the global one take over.
    /// [B28 R2-9] UI 三选一的状态查询：这一页是不是主动掐了继承。
    func wallpaperClearsGlobal(_ scope: AppearanceScope) -> Bool {
        wallpaperClearedFallback.contains(scope)
    }

    func clearWallpaper(_ scope: AppearanceScope) {
        try? FileManager.default.removeItem(at: wallpaperURL(scope))
        if scope != .global { wallpaperClearedFallback.insert(scope) }
        persistWallpaperCleared()
        wallpaperCache.removeAll()
        wallpaperRevision += 1
    }

    /// [batch7 用户-P2-11] 恢复对齐：清除标记为准。恢复是 merge 语义（包里
    /// 没提的文件原位保留），但清除标记恢复回来后、标记对应的本机壁纸文件
    /// 若还在，"清除"就被悄悄撤销、标记变死标记。所以：包里没带某 scope
    /// 壁纸文件、清除标记里却有它时，把本机残留的该文件删掉；包里带了的
    /// scope 不动（显式内容优先）。
    func reconcileClearedWallpapersAfterRestore(packagedScopes: Set<AppearanceScope>) {
        var removed = false
        for scope in wallpaperClearedFallback where scope != .global {
            guard !packagedScopes.contains(scope) else { continue }
            let url = wallpaperURL(scope)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
                removed = true
            }
        }
        if removed {
            wallpaperCache.removeAll()
            wallpaperRevision += 1
        }
    }

    private func persistWallpaperCleared() {
        let raw = wallpaperClearedFallback.map(\.rawValue)
        UserDefaults.standard.set(raw, forKey: Self.wallpaperClearedKey)
    }

    private func loadWallpaperCleared() {
        let raw = UserDefaults.standard.stringArray(forKey: Self.wallpaperClearedKey) ?? []
        wallpaperClearedFallback = Set(raw.compactMap(AppearanceScope.init(rawValue:)))
    }

    private static func backgroundJPEG(_ image: UIImage, dark: Bool = false) -> Data? {
        guard let cg = image.cgImage else { return nil }
        let maxEdge: CGFloat = 2200
        let source = CGSize(width: cg.width, height: cg.height)
        let scale = min(1, maxEdge / max(source.width, source.height))
        let size = CGSize(width: max(1, source.width * scale),
                          height: max(1, source.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            // [PIC-8] Matte follows the color scheme: a transparent PNG set
            // in dark mode used to be flattened onto the light canvas color,
            // leaving a pale fringe around dark content.
            let book = dark ? darkDefaults : lightDefaults
            UIColor(hex: book[.canvas] ?? (dark ? "141210" : "FFF8F4")).setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.jpegData(compressionQuality: 0.86)
    }

    // MARK: Paired avatars

    /// Load the user avatar, migrating a legacy inline data URI to a file
    /// once. After migration UserDefaults holds only the relative path.
    private func loadUserAvatar() {
        let raw = UserDefaults.standard.string(forKey: Keys.userAvatar) ?? ""
        if SoulIconImage.isDataURI(raw),
           let path = SoulIconImage.migrateDataURIToFile(raw, named: "user") {
            UserDefaults.standard.set(path, forKey: Keys.userAvatar)
            userAvatar = path
        } else {
            userAvatar = raw
        }
    }

    func setUserAvatar(_ image: UIImage) {
        if case .success(let path) = SoulIconImage.store(image, named: "user") {
            userAvatar = path
            UserDefaults.standard.set(path, forKey: Keys.userAvatar)
        }
    }

    func removeUserAvatar() {
        userAvatar = ""
        UserDefaults.standard.removeObject(forKey: Keys.userAvatar)
    }

    /// [B28 R10] 存她填的称呼。空串 = 清掉，回到"没有自定义称呼"的状态。
    func setUserDisplayName(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        userDisplayName = trimmed
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: Keys.userDisplayName)
        } else {
            UserDefaults.standard.set(trimmed, forKey: Keys.userDisplayName)
        }
    }

    func setAssistantAvatar(_ image: UIImage) throws {
        let name = SoulIconImage.storedName(prefix: "soul", id: PersonaStore.currentID())
        guard case .success(let path) = SoulIconImage.store(image, named: name) else { return }
        var soul = SoulStore.load() ?? SoulFile(metadata: .default, body: "")
        soul.metadata.icon = path
        try SoulStore.save(soul)
    }

    func removeAssistantAvatar() throws {
        var soul = SoulStore.load() ?? SoulFile(metadata: .default, body: "")
        soul.metadata.icon = ""
        try SoulStore.save(soul)
    }

    // MARK: Replaceable icons

    func customIcon(for id: String) -> String? {
        customIcons[id]
    }

    /// [B28 R2-7/A-3] 以前 encode 失败静默、删不存在的 slot 也报成功。
    /// CLI 和用户都需要知道「做了」还是「没做」。
    @discardableResult
    func setIcon(_ image: UIImage, for id: String) -> Bool {
        guard case .success(let value) = SoulIconImage.encode(image) else { return false }
        // [PIC-6] File first, memory second: the PNG file is the source
        // of truth; the dictionary is only the read cache.
        try? FileManager.default.createDirectory(at: customIconsDirectory,
                                                 withIntermediateDirectories: true)
        if let png = SoulIconImage.pngData(from: value) {
            do {
                try png.write(to: customIconURL(for: id), options: .atomic)
            } catch {
                appearanceLog.warning("icon write failed for \(id): \(error.localizedDescription)")
                return false
            }
        }
        customIcons[id] = value
        persistIcons()
        return true
    }

    /// Returns whether an icon was actually there to remove (A-3:
    /// removing a nonexistent slot used to answer "removed: true").
    @discardableResult
    func removeIcon(for id: String) -> Bool {
        let existed = customIcons[id] != nil
            || FileManager.default.fileExists(atPath: customIconURL(for: id).path)
        try? FileManager.default.removeItem(at: customIconURL(for: id))
        customIcons.removeValue(forKey: id)
        persistIcons()
        return existed
    }

    private func persistIcons() {
        // [PIC-6] The dictionary is now only the in-memory read cache; the
        // files are the source of truth (setIcon/removeIcon write them).
        iconRevision += 1
        objectWillChange.send()
    }

    // MARK: - [PIC-6] Custom icons on disk

    private var customIconsDirectory: URL { Self.customIconsDirectoryURL }

    private static var customIconsDirectoryURL: URL {
        appearanceDirectoryURL.appendingPathComponent("icons", isDirectory: true)
    }

    private func customIconURL(for id: String) -> URL {
        Self.customIconFileURL(for: id)
    }

    /// [B28 A-2] `id` 拼路径前必须消毒。
    ///
    /// 原来直接 `appendingPathComponent("\(id).png")`，而 CLI 侧
    /// `minis-theme icon --slot ../../x` 接受任意字符串 —— 能写出
    /// `Application Support/AppearanceStudio/icons/` 之外。UI 侧是枚举所以
    /// 安全，两条入口共用一个不消毒的函数，防的只有一条路。
    ///
    /// 照 `SoulStore.storedName` 的做法：只留字母数字，截断 64。
    static func sanitizedIconID(_ id: String) -> String {
        let allowed = id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        let cleaned = String(String.UnicodeScalarView(allowed))
        return String(cleaned.prefix(64))
    }

    private static func customIconFileURL(for id: String) -> URL {
        let safe = sanitizedIconID(id)
        // 全被滤掉（例如 `../../`）时不能拼出 `".png"`，那会撞到目录里的
        // 同名文件；给一个不可能来自枚举的名字。
        let name = safe.isEmpty ? "_invalid" : safe
        return customIconsDirectoryURL.appendingPathComponent(name + ".png")
    }

    private static let customIconsMigratedKey = "appearanceStudio.customIconsMigrated.v1"

    /// One-time migration: UserDefaults JSON blob → one PNG file per slot.
    /// Runs once; the UserDefaults key is removed afterwards.
    /// Static because init calls it before all stored properties are
    /// initialized; it only touches UserDefaults and the icons directory.
    ///
    /// [batch7 用户-P2-12] 原子化：全部文件写完才删旧键、打已迁移标记。
    /// 中途任何一张写失败（目录建不出来、编码失败、落盘抛错）都不删键、
    /// 不打标记，下次启动重跑——不再是"defer 无条件清掉 + try? 静默吞错"。
    private static func migrateCustomIconsFromUserDefaults() {
        guard !UserDefaults.standard.bool(forKey: Self.customIconsMigratedKey) else { return }
        guard let data = UserDefaults.standard.data(forKey: Keys.icons) else {
            // 从来没有旧 blob：无事可做，直接标记完成。
            UserDefaults.standard.set(true, forKey: Self.customIconsMigratedKey)
            return
        }
        // 旧 blob 存在但解不开：不删、不标记，留着证据等以后处理，
        // 不像以前那样 defer 一把清掉。
        guard let value = try? JSONDecoder().decode([String: String].self, from: data),
              !value.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: customIconsDirectoryURL,
                                                    withIntermediateDirectories: true)
        } catch {
            return // 目录都建不出来：下次启动重试。
        }
        var failed = false
        for (id, uri) in value {
            guard let png = SoulIconImage.pngData(from: uri) else {
                failed = true
                continue
            }
            do {
                try png.write(to: customIconFileURL(for: id), options: .atomic)
            } catch {
                failed = true
            }
        }
        // 有一张没写完就不算完：旧键和标记都留着，下次启动重跑。
        guard !failed else { return }
        UserDefaults.standard.removeObject(forKey: Keys.icons)
        UserDefaults.standard.set(true, forKey: Self.customIconsMigratedKey)
    }

    private static func loadCustomIconsFromDisk() -> [String: String] {
        var loaded: [String: String] = [:]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: customIconsDirectoryURL,
            includingPropertiesForKeys: nil) else { return loaded }
        for url in files where url.pathExtension.lowercased() == "png" {
            let id = url.deletingPathExtension().lastPathComponent
            guard !id.isEmpty, let data = try? Data(contentsOf: url) else { continue }
            loaded[id] = "data:image/png;base64," + data.base64EncodedString()
        }
        return loaded
    }

    // MARK: UIKit-backed surfaces

    func configureUIKitSurfaces() {
        UITableView.appearance().backgroundColor = .clear
        UICollectionView.appearance().backgroundColor = .clear
        let nav = UINavigationBarAppearance()
        nav.configureWithTransparentBackground()
        nav.backgroundColor = uiColor(.raised).withAlphaComponent(surfaceOpacity)
        nav.shadowColor = uiColor(.border).withAlphaComponent(0.65)
        nav.titleTextAttributes = [.foregroundColor: uiColor(.primaryText)]
        nav.largeTitleTextAttributes = [.foregroundColor: uiColor(.primaryText)]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
    }
}

struct AppearancePalette {
    let light: [AppearanceColorRole: String]
    let dark: [AppearanceColorRole: String]
}

private enum AppearancePaletteBook {
    // [10-18 醒醒] 「现在的配色有点 low」。内置这套原来主色 D4778B 饱和度
    // 到 0.44，配纯白卡片就发甜。按莫兰迪收一档：饱和度压到 0.20-0.32，
    // 底色从纯白改成带一丝暖的米白，文字用深灰而不是近黑。
    static let light: [AppearanceColorRole: String] = [
        .canvas: "F7F4F1", .surface: "FDFCFA", .raised: "FFFFFF",
        .mutedSurface: "F1EBE6", .primaryText: "3A322E", .secondaryText: "8A7B74",
        .accent: "B98591", .userBubble: "EFE0DE", .assistantBubble: "FDFCFA",
        .border: "E3DAD4",
        .field: "FCFAF7", .iconTile: "F2EAE4", .chip: "EDE2DC",
        .success: "7C9A83",
        .warning: "C0A176", .destructive: "B87C7C"
    ]
    static let dark: [AppearanceColorRole: String] = [
        .canvas: "1A1716", .surface: "242020", .raised: "2C2725",
        .mutedSurface: "2F2A28", .primaryText: "F2EDE9", .secondaryText: "B5A8A1",
        .accent: "C99BA6", .userBubble: "4A3A3B", .assistantBubble: "242020",
        .border: "403836",
        .field: "262221", .iconTile: "2F2A28", .chip: "362F2C",
        .success: "93B09A",
        .warning: "CDB183", .destructive: "CB9292"
    ]
}

enum AppearancePreset: String, CaseIterable, Identifiable {
    case warmPaper, cleanAir, nightCocoa
    var id: String { rawValue }
    var title: String {
        switch self {
        case .warmPaper: return AppLocalized("暖纸")
        case .cleanAir: return AppLocalized("清气")
        case .nightCocoa: return AppLocalized("夜可可")
        }
    }
    var colors: AppearancePalette {
        switch self {
        case .warmPaper:
            return AppearancePalette(light: AppearancePaletteBook.light, dark: AppearancePaletteBook.dark)
        case .cleanAir:
            return AppearancePalette(
                light: [.canvas:"F6F8FA",.surface:"FFFFFF",.raised:"FFFFFF",.mutedSurface:"EDF2F5",.primaryText:"26323A",.secondaryText:"6F7E87",.accent:"6F93A8",.userBubble:"DDEAF0",.assistantBubble:"FFFFFF",.field:"FFFFFF",.border:"DCE5E9",.iconTile:"FFFFFF",.chip:"EDF2F5",.success:"638F76",.warning:"C9A36A",.destructive:"BC6262"],
                dark: [.canvas:"151A1D",.surface:"20272B",.raised:"273035",.mutedSurface:"2B353A",.primaryText:"EDF3F5",.secondaryText:"AAB8BE",.accent:"8CB2C5",.userBubble:"334B57",.assistantBubble:"20272B",.field:"252D31",.border:"3B484E",.iconTile:"20272B",.chip:"2B353A",.success:"82AF91",.warning:"D4B07A",.destructive:"DA8181"])
        case .nightCocoa:
            return AppearancePalette(
                light: [.canvas:"FBF6EF",.surface:"FFFDF8",.raised:"FFFFFF",.mutedSurface:"F2E7DA",.primaryText:"44362E",.secondaryText:"8D7868",.accent:"A77965",.userBubble:"EAD8CE",.assistantBubble:"FFFDF8",.field:"FFFBF5",.border:"E5D7C9",.iconTile:"FFFDF8",.chip:"F2E7DA",.success:"728E70",.warning:"C9A36A",.destructive:"B86565"],
                dark: [.canvas:"171311",.surface:"241E1A",.raised:"2E2621",.mutedSurface:"362B25",.primaryText:"F2E9E1",.secondaryText:"B9A79B",.accent:"C99B84",.userBubble:"513B31",.assistantBubble:"241E1A",.field:"2A231F",.border:"493B33",.iconTile:"241E1A",.chip:"362B25",.success:"91AE8B",.warning:"D4B07A",.destructive:"D17A7A"])
        }
    }
}

extension Color {
    init(hex: String) {
        self.init(UIColor(hex: hex))
    }
}

extension UIColor {
    /// Parses `RRGGBB` / `RRGGBBAA` / `#RGB` style hex.
    ///
    /// The scanner used to be asked for a number and never checked whether it
    /// got one, so `"ZZZZZZ"` scanned to 0 and rendered pure black while `""`
    /// rendered grey — two different wrong answers, neither reported. A value
    /// that does not parse now falls back to the same neutral grey the pack
    /// normalizer uses, so a bad hex is visible as one consistent colour
    /// instead of silently turning text black.
    convenience init(hex: String) {
        let raw = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        let scanner = Scanner(string: raw)
        let parsed = scanner.scanHexInt64(&value)
        guard parsed, scanner.isAtEnd, raw.count == 6 || raw.count == 8 else {
            self.init(red: 0x80 / 255, green: 0x80 / 255, blue: 0x80 / 255, alpha: 1)
            return
        }
        let r, g, b, a: CGFloat
        switch raw.count {
        case 8:
            r = CGFloat((value >> 24) & 0xff) / 255
            g = CGFloat((value >> 16) & 0xff) / 255
            b = CGFloat((value >> 8) & 0xff) / 255
            a = CGFloat(value & 0xff) / 255
        default:
            r = CGFloat((value >> 16) & 0xff) / 255
            g = CGFloat((value >> 8) & 0xff) / 255
            b = CGFloat(value & 0xff) / 255
            a = 1
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }

    var hexRGB: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        let resolved = resolvedColor(with: UITraitCollection.current)
        guard resolved.getRed(&r, green: &g, blue: &b, alpha: &a) else { return "808080" }
        return String(format: "%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

// MARK: - Theme access and backgrounds

@MainActor
enum MinisTheme {
    static func color(_ role: AppearanceColorRole,
                      scope: AppearanceScope = .global) -> Color {
        AppearanceStudio.shared.color(role, scope: scope)
    }
    static var canvas: Color { color(.canvas) }
    static var surface: Color { color(.surface).opacity(AppearanceStudio.shared.surfaceOpacity) }
    static var raised: Color { color(.raised).opacity(AppearanceStudio.shared.surfaceOpacity) }
    static var mutedSurface: Color { color(.mutedSurface).opacity(AppearanceStudio.shared.surfaceOpacity) }
    /// 小方块图标底 / 胶囊底 / 输入类底。设置页与首页也走这套，
    /// 免得"卡片"一个角色被拿去画图标底。
    static var iconTile: Color { color(.iconTile).opacity(AppearanceStudio.shared.surfaceOpacity) }
    static var chip: Color { color(.chip).opacity(AppearanceStudio.shared.surfaceOpacity) }
    static var field: Color { color(.field).opacity(AppearanceStudio.shared.surfaceOpacity) }
    static var primaryText: Color { color(.primaryText) }
    static var secondaryText: Color { color(.secondaryText) }
    static var accent: Color { color(.accent) }
    static var border: Color { color(.border) }
    // [T-tokenize-all-colors] Semantic trio for settings pages, mirrors
    // ChatColors so the whole app speaks the same token vocabulary.
    static var success: Color { color(.success) }
    static var warning: Color { color(.warning) }
    static var destructive: Color { color(.destructive) }
}

struct AppearanceBackdrop: View {
    let scope: AppearanceScope
    @ObservedObject private var studio = AppearanceStudio.shared

    var body: some View {
        ZStack {
            studio.color(.canvas, scope: scope)
            if let image = studio.wallpaper(for: scope) {
                // [T-home-wallpaper-fullbleed][10-02 醒醒改口径] 底部栏预览与真机一致（24pt 条样式）。
                if scope == .bottomBar {
                    VStack(spacing: 0) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .frame(height: 24)
                            .clipped()
                            .overlay(studio.color(.canvas, scope: .bottomBar).opacity(studio.wallpaperShade))
                        Spacer(minLength: 0)
                    }
                } else {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .clipped()
                    studio.color(.canvas, scope: scope)
                        .opacity(studio.wallpaperShade)
                }
            }
        }
        .id(studio.wallpaperRevision)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct AppearancePageModifier: ViewModifier {
    let scope: AppearanceScope
    @ObservedObject private var studio = AppearanceStudio.shared

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .foregroundStyle(studio.color(.primaryText, scope: scope))
            .tint(studio.color(.accent, scope: scope))
            .background(AppearanceBackdrop(scope: scope))
            // Wallpaper-fullscreen pages: the nav bar sits transparently over
            // the backdrop instead of a material/opaque band at the top, so
            // the wallpaper runs edge to edge under the title.
            .toolbarBackground(.hidden, for: .navigationBar)
    }
}

private struct SettingsListRowBackgroundModifier: ViewModifier {
    @ObservedObject private var studio = AppearanceStudio.shared

    func body(content: Content) -> some View {
        // [10-18 醒醒 第五轮] 「连选项的背景都可以改颜色或者图片，
        // 而不是一直纯白色的那种。」
        //
        // 有自定义行背景色就用它，没有就跟随 surface——旧主题包不带这个
        // 字段，会自动走 surface，不会突然变白。
        let pack = studio.currentThemePack()
        if let hex = pack.rowBackgroundHex, !hex.isEmpty {
            content.listRowBackground(Color(hex: hex))
        } else {
            content.listRowBackground(studio.color(.surface, scope: .settings))
        }
    }
}

extension View {
    func appearancePage(_ scope: AppearanceScope) -> some View {
        modifier(AppearancePageModifier(scope: scope))
    }

    /// One-line theming for a settings-scope page: palette canvas/accent/text
    /// + transparent nav bar (via appearancePage) + List section cards that
    /// follow the palette "卡片" (surface) color instead of the system
    /// grouped background — so the 色盘 卡片 row actually controls them.
    func settingsPage() -> some View {
        self
            .appearancePage(.settings)
            .modifier(SettingsListRowBackgroundModifier())
    }
}

// MARK: - [3-4 醒醒] 统一卡片修饰器 (MinisStandardCard)
// 标准卡片：surface + 16pt (或 12pt 行内) 连续圆角 + 16x12 内距 + 0.5pt border 描边

public struct MinisStandardCard: ViewModifier {
    public var cornerRadius: CGFloat = 16
    public var paddingHorizontal: CGFloat = 16
    public var paddingVertical: CGFloat = 12
    public var strokeOpacity: Double = 0.35

    public func body(content: Content) -> some View {
        content
            .padding(.horizontal, paddingHorizontal)
            .padding(.vertical, paddingVertical)
            .background(
                AppearanceStudio.shared.color(.surface),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AppearanceStudio.shared.color(.border).opacity(strokeOpacity), lineWidth: 0.5)
            )
    }
}

public extension View {
    func minisStandardCard(cornerRadius: CGFloat = 16, hPadding: CGFloat = 16, vPadding: CGFloat = 12) -> some View {
        modifier(MinisStandardCard(cornerRadius: cornerRadius, paddingHorizontal: hPadding, paddingVertical: vPadding))
    }
}

struct PersonAvatarView: View {
    enum Kind { case user, assistant }
    let kind: Kind
    let size: CGFloat
    /// [问题12] 这个头像属于哪个人设。nil → 回落到全局当前人设。
    ///
    /// 聊天页原来固定读 `SoulStore.cachedMetadata.icon`，那是**当前人设**
    /// 的缓存——会话绑的是别人时，对话框就显示错的人，看着就是"两套"。
    /// 传进来之后按会话绑定的人设取，跟列表同源。
    var personaID: String?
    @ObservedObject private var studio = AppearanceStudio.shared
    // 人设一改（换头像）就让所有头像视图重画，不等重进页面。
    @ObservedObject private var personaStore = PersonaStore.shared
    @State private var soulIcon = SoulStore.cachedMetadata.icon

    /// [10-18 醒醒 第五轮] 头像形状跟着主题包走。
    private var avatarShape: AppearanceAvatarShape {
        AppearanceAvatarShape.parse(studio.currentThemePack().avatarShape)
    }

    private var resolvedIcon: String? {
        guard let pid = personaID else {
            return soulIcon.isEmpty ? nil : soulIcon
        }
        // [B28 R14] 通讯录改的头像存在 Persona.avatar，聊天这边原来只读 SOUL.md 的
        // icon —— 两套存储，改了头像对话框不动。现在以通讯录为准，SOUL 兜底。
        if let stored = PersonaStore.shared.personas.first(where: { $0.id == pid })?.avatar,
           !stored.isEmpty, avatarFileExists(stored) {
            return stored
        }
        let soul = SoulStore.displayIcon(for: pid)
        // 路径指向的文件可能早没了（换过图又清过缓存），当没有处理，别留白块。
        return soul.flatMap { avatarFileExists($0) ? $0 : nil }
    }

    /// 只有真能读到的图才算头像。
    private func avatarFileExists(_ value: String) -> Bool {
        guard SoulIconImage.isPathReference(value) else { return true }
        guard let url = SoulIconImage.fileURL(forReference: value) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    var body: some View {
        Group {
            // [B28 R12] 她自己的头像以通讯录「我自己」档案为准——
            // 情头页删掉后 userAvatar 没有入口了，只能回退用。
            let meAvatarRaw = PersonaStore.shared.personas
                .first { $0.id == PersonaStore.userProfilePersonaID }?.avatar ?? ""
            let meAvatar = avatarFileExists(meAvatarRaw) ? meAvatarRaw : ""
            let icon = kind == .user
                ? (meAvatar.isEmpty ? studio.userAvatar : meAvatar)
                : (resolvedIcon ?? "")
            // [avatar] Only an image counts as an avatar. A legacy
            // non-image value (an emoji stored by an older build) is
            // treated as unset and falls through to the default tile.
            if SoulIconImage.isImageReference(icon) {
                SoulIconView(icon: icon, size: size, shape: avatarShape)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * avatarShape.cornerFraction, style: .continuous)
                        .fill(kind == .user
                              ? studio.color(.userBubble, scope: .chat)
                              : studio.color(.assistantBubble, scope: .chat))
                    Image(systemName: kind == .user ? "person.fill" : "sparkles")
                        .font(.system(size: size * 0.42, weight: .medium))
                        .foregroundStyle(studio.color(.accent, scope: .chat))
                }
                .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: size * avatarShape.cornerFraction, style: .continuous)
                .stroke(studio.color(.border, scope: .chat), lineWidth: 0.7)
        )
        .onReceive(NotificationCenter.default.publisher(for: .soulMdChanged)) { _ in
            soulIcon = SoulStore.cachedMetadata.icon
        }
    }
}

struct QuietAppIcon: View {
    let id: String
    let systemName: String
    var size: CGFloat = 21
    @ObservedObject private var studio = AppearanceStudio.shared

    var body: some View {
        Group {
            if let custom = studio.customIcon(for: id) {
                SoulIconView(icon: custom, size: size)
            } else {
                // [问题6] 她定的规范：「全部白底 + 黑色图标，图标全部变成实体的
                // 稍微偏圆润感一点的，白底边框也是圆角的，色彩方面也跟着css
                // 全局变量」。
                //
                // 改了三处，都是照她的原话：
                // 1. 底色从 .surface（跟着卡片色走，深色模式下会变暗）改成真正的
                //    白色——她要的是"白底"，不是"跟主题的卡片底"。深色模式也
                //    保持白底，这是她点名要的视觉锚点。
                // 2. 图标色从 .primaryText 改成固定黑：白底上的黑，不随主题文字色
                //    漂移，否则深色模式下会变成浅灰。
                // 3. weight 从 .medium 改成 .semibold 并配合 SF Symbols 的
                //    .fill 变体——"实心"和"圆润"。
                //
                // 圆角沿用原来的 8pt（size 21 时约 0.38 倍，比 0.25 更圆润），
                // 不动，因为它本来就在她要的"圆润"一侧。
                Image(systemName: Self.filledSymbolName(systemName))
                    .font(.system(size: max(9, size * 0.44), weight: .semibold))
                    .foregroundStyle(Color.black)
                    .frame(width: size, height: size)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.black.opacity(0.08), lineWidth: 0.6)
                    )
            }
        }
        .id(studio.iconRevision)
    }

    /// [问题6] 把 SF Symbol 名换成实心变体。
    ///
    /// 不能无脑加 ".fill"：`sparkles`、`brain.head.profile`、
    /// `arrow.triangle.2.circlepath`、`magnifyingglass`、
    /// `clock.arrow.circlepath`、`antenna.radiowaves.left.and.right`
    /// 这几个本身就没有 fill 变体，加后缀会渲染成空白图标。
    /// 所以用一张显式表：表里有就用表里的，已经带 .fill 的原样返回，
    /// 其余才试加后缀。新加图标忘了进表也不会变成空白——最坏是保持线框。
    static func filledSymbolName(_ name: String) -> String {
        if let mapped = solidSymbolMap[name] { return mapped }
        if name.hasSuffix(".fill") { return name }
        return name + ".fill"
    }

    /// 例外表：这些名字不能简单加 ".fill"。
    ///
    /// 左边是要传入的名字，右边是实际该渲染的。没有 fill 变体的原样返回——
    /// 加后缀会渲染成空白图标，比线框更糟。她要的是"全部实体"，所以这几个
    /// 挑的是本身就偏实心的符号（sparkles 本身就是实心形状）。
    private static let solidSymbolMap: [String: String] = [
        "sparkles": "sparkles",
        "brain.head.profile": "brain.head.profile",
        "arrow.triangle.2.circlepath": "arrow.triangle.2.circlepath",
        "magnifyingglass": "magnifyingglass",
        "clock.arrow.circlepath": "clock.arrow.circlepath",
        "antenna.radiowaves.left.and.right": "antenna.radiowaves.left.and.right",
    ]
}

enum QuietIconSlot: String, CaseIterable, Identifiable {
    case decorate, appearance, skills, soul, memory, mcp, env, terminal, rootfs, browser
    /// [batch1] Settings → Agent Runtime 的「Agent Tools」行（工具开关页）。
    case agentTools
    case storage, shared, mounts, icloud, backup, permissions, lock
    case logs, about, privacy, feedback
    /// [merge step18a] Settings → Agent Runtime 的「桥·对外连接」行。
    case bridgeRelay
    /// [s2-search] Settings 的「联网搜索」行（第 18 条）。
    case webSearch
    /// [T-user-manual 09-11] Settings → About section's 使用手册 row.
    case manual
    /// [AUD-20] Settings → Agent Runtime 的「定时任务与脉搏」行。 Was sharing
    /// `.terminal`, so customising the terminal icon silently changed this
    /// row's icon too — two features, one slot.
    case scheduled
    /// [batch7] Settings → Agent Runtime 的「Sub Agents」行（子代理设置页）。
    case subAgents

    var id: String { rawValue }
    var title: String {
        switch self {
        case .decorate: return AppLocalized("装扮")
        case .appearance: return AppLocalized("Appearance")
        case .skills: return AppLocalized("技能")
        case .soul: return "Soul"
        case .memory: return AppLocalized("记忆")
        case .mcp: return "MCP"
        case .env: return AppLocalized("Environment Variables")
        case .storage: return AppLocalized("Storage")
        case .shared: return AppLocalized("Shared folders")
        case .mounts: return AppLocalized("外部文件夹")
        case .icloud: return AppLocalized("iCloud Sync")
        case .backup: return AppLocalized("Backup & Restore")
        case .permissions: return AppLocalized("Permissions")
        case .lock: return AppLocalized("锁定")
        case .logs: return AppLocalized("Logs")
        case .about: return AppLocalized("About")
        case .privacy: return AppLocalized("Privacy Policy")
        case .feedback: return AppLocalized("反馈")
        case .manual: return AppLocalized("手册")
        case .terminal: return AppLocalized("终端")
        case .rootfs: return AppLocalized("Rootfs Management")
        case .browser: return AppLocalized("浏览器")
        case .bridgeRelay: return AppLocalized("桥·对外连接")
        case .webSearch: return AppLocalized("联网搜索")
        case .scheduled: return AppLocalized("定时任务与脉搏")
        case .subAgents: return AppLocalized("Sub agent")
        case .agentTools: return AppLocalized("工具开关")
        }
    }
    var systemName: String {
        switch self {
        case .decorate: return "paintpalette.fill"
        case .appearance: return "paintbrush.fill"
        case .skills: return "puzzlepiece.extension.fill"
        case .soul: return "sparkles"
        case .memory: return "brain.head.profile"
        case .mcp: return "square.stack.3d.up.fill"
        case .env: return "terminal.fill"
        case .storage: return "archivebox.fill"
        case .shared: return "folder.fill"
        case .mounts: return "externaldrive.fill"
        case .icloud: return "icloud.fill"
        case .backup: return "arrow.triangle.2.circlepath"
        case .permissions: return "lock.shield.fill"
        case .lock: return "lock.fill"
        case .logs: return "doc.text.fill"
        case .about: return "info.circle.fill"
        case .privacy: return "hand.raised.fill"
        case .feedback: return "bubble.left.and.bubble.right.fill"
        case .manual: return "book.closed.fill"
        case .terminal: return "terminal.fill"
        case .rootfs: return "externaldrive.fill"
        case .browser: return "globe.fill"
        case .bridgeRelay: return "antenna.radiowaves.left.and.right"
        case .webSearch: return "magnifyingglass"
        case .scheduled: return "clock.arrow.circlepath"
        case .subAgents: return "person.2.fill"
        case .agentTools: return "wrench.and.screwdriver.fill"
        }
    }
}

// MARK: - Backup ([PIC-2])

extension AppearanceStudio {
    /// Every UserDefaults key holding appearance state. The image FILES
    /// are archived as a tree (see `appearanceAssetsDirectory`); these
    /// keys are the half that lives in defaults — custom colours, the
    /// user avatar, opacities, the wallpaper-cleared list, the
    /// theme-library list and the current theme pack. Single source of
    /// truth for both directions, and the restore side's whitelist: a
    /// package may only ever write THESE keys, never arbitrary defaults.
    static var backupDefaultsKeys: [String] {
        [Keys.colors, Keys.userAvatar, Keys.surfaceOpacity, Keys.bubbleOpacity,
         Keys.wallpaperShade, wallpaperClearedKey,
         AppearanceSavedTheme.libraryKey, AppearanceThemePack.currentKey]
    }

    /// Snapshot the keys above into the package's wire shape. Absent keys
    /// stay absent, so restoring an old or sparse package never invents
    /// values the source device didn't have.
    func collectBackupDefaults() -> [String: BackupDefaultsValue] {
        let defaults = UserDefaults.standard
        var out: [String: BackupDefaultsValue] = [:]
        for key in Self.backupDefaultsKeys {
            guard let raw = defaults.object(forKey: key) else { continue }
            if let data = raw as? Data {
                out[key] = BackupDefaultsValue(kind: "data", data: data.base64EncodedString())
            } else if let string = raw as? String {
                out[key] = BackupDefaultsValue(kind: "string", string: string)
            } else if let strings = raw as? [String] {
                out[key] = BackupDefaultsValue(kind: "strings", strings: strings)
            } else if let number = raw as? NSNumber {
                out[key] = BackupDefaultsValue(kind: "double", double: number.doubleValue)
            }
        }
        return out
    }

    /// Write a restored package's values back into UserDefaults (only the
    /// whitelisted keys; unknown kinds are skipped, not fatal), then
    /// reload the live instance so the restored look takes effect without
    /// a relaunch.
    func applyBackupDefaults(_ values: [String: BackupDefaultsValue]) {
        let defaults = UserDefaults.standard
        for key in Self.backupDefaultsKeys {
            guard let value = values[key] else { continue }
            switch value.kind {
            case "data":
                if let b64 = value.data, let data = Data(base64Encoded: b64) {
                    defaults.set(data, forKey: key)
                }
            case "string":
                if let string = value.string { defaults.set(string, forKey: key) }
            case "strings":
                if let strings = value.strings { defaults.set(strings, forKey: key) }
            case "double":
                if let double = value.double { defaults.set(double, forKey: key) }
            default:
                break
            }
        }
        reloadAfterRestore()
    }

    /// Re-read every piece of appearance state from disk / defaults after
    /// a restore rewrote it underneath the live instance: colours, avatar,
    /// opacities, cleared-wallpaper list, custom icons (files), current
    /// theme pack, and the cached wallpapers.
    func reloadAfterRestore() {
        if let data = UserDefaults.standard.data(forKey: Keys.colors),
           let value = try? JSONDecoder().decode([String: String].self, from: data) {
            customColors = value
        } else {
            customColors = [:]
        }
        Self.colorSnapshot = customColors
        loadUserAvatar()
        surfaceOpacity = UserDefaults.standard.object(forKey: Keys.surfaceOpacity) as? Double ?? 0.88
        bubbleOpacity = UserDefaults.standard.object(forKey: Keys.bubbleOpacity) as? Double ?? 1.0
        wallpaperShade = UserDefaults.standard.object(forKey: Keys.wallpaperShade) as? Double ?? 0.08
        loadWallpaperCleared()
        customIcons = Self.loadCustomIconsFromDisk()
        themePackLock.lock()
        cachedThemePack = loadStoredPackUnlocked()
        themePackLoaded = true
        themePackLock.unlock()
        themePackRevision += 1
        wallpaperCache.removeAll()
        wallpaperRevision += 1
        iconRevision += 1
        configureUIKitSurfaces()
        objectWillChange.send()
    }
}

// MARK: - [B28 R10] 称呼自适应

/// App 里任何"要提到对话双方"的文案，都从这里取称呼，不写死具体名字。
/// - AI 侧：跟着当前会话绑的人设走（SOUL.md 的 name），人设改名即生效。
/// - 用户侧：她在外观工作室里自己填的称呼；没填就回落到中性词，
///   UI 用"你"，给模型的提示词用"用户"（对模型说"你"会指错人）。
@MainActor
enum ChatAddressing {
    /// 回答的人叫什么。
    static func assistant(sessionPersonaId: String? = nil) -> String {
        SoulStore.displayName(for: SoulStore.displayPersonaId(sessionPersonaId))
    }

    /// 说话的人叫什么（界面可见文案用）。
    /// [B28 R11] 优先级：通讯录「我自己」档案里的「怎么称呼」
    /// → 外观工作室填的称呼 → 中性词。哪来的就用哪来的，绝不写死名字。
    static func user() -> String {
        let fromProfile = SystemPromptBuilder.userProfileAddressingName()
        if !fromProfile.isEmpty { return fromProfile }
        let n = AppearanceStudio.shared.userDisplayName
        return n.isEmpty ? AppLocalized("你") : n
    }

    /// 说话的人叫什么（注入给模型的提示词用）。
    static func userForModel() -> String {
        let fromProfile = SystemPromptBuilder.userProfileAddressingName()
        if !fromProfile.isEmpty { return fromProfile }
        let n = AppearanceStudio.shared.userDisplayName
        return n.isEmpty ? AppLocalized("用户") : n
    }
}
