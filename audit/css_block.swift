// MARK: - CSS 全局色彩变量定义
//
// [T-dynamic-color] 这套变量的每个成员都是**动态色**：同一份 `Color` 同时
// 携带浅色和深色的值，由 UIKit 在解析时按当前 trait collection 选。
//
// 所以这里不再收 `isDark: Bool`。以前每个函数都要调用方传
// `colorScheme == .dark`，而 `AppearanceStudio` 内部又用 `appearanceMode`
// 自己判一次 —— 两个判定源。用户在设置里强制浅色、系统是深色时，两者给出
// 相反答案，同一屏的卡片和文字就分成两套配色。现在只有 trait collection
// 一个源，`preferredColorScheme` 改的也正是它，不可能再打架。
//
// 顺带：切系统外观不用重建视图，UIKit 自己重解析；也不再需要
// `@ObservedObject var appearanceStudio` 才能刷新颜色（改色仍然需要它，
// 因为那是换值不是换明暗）。

@MainActor
/// Colours as CSS-style variables.
///
/// `internal`, not `public`: these take `AppearanceScope` as a default
/// argument, and a public signature cannot carry an internal type's case
/// there. Nothing outside the module used them anyway.
enum CSSThemeVariables {
    private static var studio: AppearanceStudio { .shared }

    /// --color-card / var(--dudu-card)
    /// [4-1 醒醒] 背景卡接入全局 surface 角色，支持壁纸透明度
    static func card(scope: AppearanceScope = .chat) -> Color {
        let surface = studio.color(.surface, scope: scope)
        if studio.hasWallpaper(scope) {
            return surface.opacity(studio.surfaceOpacity)
        }
        return surface
    }

    /// --color-bg / var(--dudu-cream)
    /// [4-1 醒醒] 背景底衬接入全局 canvas 角色
    static func bg(scope: AppearanceScope = .chat) -> Color {
        studio.color(.canvas, scope: scope)
    }

    /// --color-text-main / var(--dudu-brown)
    /// [4-1 醒醒] 主文字接入全局 primaryText 角色
    static func textMain(scope: AppearanceScope = .chat) -> Color {
        studio.color(.primaryText, scope: scope)
    }

    /// --color-text-dim / var(--dudu-text-dim)
    /// [4-1 醒醒] 次文字接入全局 secondaryText 角色
    static func textDim(scope: AppearanceScope = .chat) -> Color {
        studio.color(.secondaryText, scope: scope)
    }

    /// --color-divider / var(--dudu-divider)
    /// [4-1 醒醒] 分隔线接入全局 border 角色
    static func divider(scope: AppearanceScope = .chat) -> Color {
        studio.color(.border, scope: scope)
    }

    /// --color-accent-soft / var(--dudu-pink-soft)
    /// [4-1 醒醒] 柔和强调色由 accent 角色动态派生
    static func accentSoft(scope: AppearanceScope = .chat) -> Color {
        studio.color(.accent, scope: scope).opacity(0.18)
    }

    /// --color-accent / var(--dudu-pink)
    /// [4-1 醒醒] 强调色接入全局 accent 角色
    static func accent(scope: AppearanceScope = .chat) -> Color {
        studio.color(.accent, scope: scope)
    }

    /// --color-accent-fg / 强调色上的前景字（按钮标题、图标）
    ///
    /// [T-dynamic-color] 原来硬写 `Color.white`。强调色是用户自己挑的，
    /// 挑成浅黄、浅粉、米白时白字直接看不见。现在按 WCAG 对比度在黑白之间
    /// 选更好的那个，逐明暗各算一遍。
    static func accentFg(scope: AppearanceScope = .chat) -> Color {
        Color(uiColor: accentFgUIColor(scope: scope))
    }

    /// `accentFg` 的 UIKit 形式。动态色闭包里算对比度，所以不用调用方告诉
    /// 它现在是深还是浅。
    static func accentFgUIColor(scope: AppearanceScope = .chat) -> UIColor {
        UIColor { trait in
            let variant: AppearanceVariant = trait.userInterfaceStyle == .dark ? .dark : .light
            let accentHex = AppearanceStudio.snapshotHex(.accent, scope: scope, variant: variant)
            return UIColor(hex: Self.bestForegroundHex(on: accentHex))
        }
    }

    /// 在白和黑之间挑对比度更高的那个。同分时选白（浅色强调色上白字更常见）。
    ///
    /// 抽出来是因为它有两个调用方（SwiftUI 的 Color 和 UIKit 的 UIColor），
    /// 而对比度算法只该有一份。
    static func bestForegroundHex(on backgroundHex: String) -> String {
        let white = "FFFFFF"
        let black = "000000"
        let onWhite = AppearanceContrast.ratio(white, on: backgroundHex)
        let onBlack = AppearanceContrast.ratio(black, on: backgroundHex)
        return onWhite >= onBlack ? white : black
    }

    /// --color-option-bg (输入框/未选中胶囊底色)
    /// [10-15 1-3 醒醒] 输入框与选项底色接入全局 input 角色（同族统一，不再硬编码 hex）
    static func optionBg(scope: AppearanceScope = .chat) -> Color {
        studio.color(.field, scope: scope)
    }

    /// --color-option-border (输入框/未选中胶囊边框)
    /// [10-15 1-3 醒醒] 输入框与选项边线接入全局 border 角色
    static func optionBorder(scope: AppearanceScope = .chat) -> Color {
        studio.color(.border, scope: scope)
    }

    /// --color-scrim / 遮罩层
    ///
    /// 不是主题角色（遮罩永远是暗的，不跟用户配色），但明暗两套值不同，
    /// 所以同样做成动态色。
    static func scrim() -> Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor.black.withAlphaComponent(0.65)
                : UIColor(hex: "2A2A2E").withAlphaComponent(0.28)
        })
    }

    /// --color-sheet-shadow / 弹窗投影
    static func sheetShadow() -> Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor.black.withAlphaComponent(0.45)
                : UIColor(hex: "8B736C").withAlphaComponent(0.16)
        })
    }

    /// --color-danger
    /// [4-1 醒醒] 危险操作接入全局 destructive 角色
    static func danger(scope: AppearanceScope = .chat) -> Color {
        studio.color(.destructive, scope: scope)
    }

    /// --color-danger-soft
    static func dangerSoft(scope: AppearanceScope = .chat) -> Color {
        studio.color(.destructive, scope: scope).opacity(0.18)
    }

    /// --color-success
    ///
    /// [AUD-18] Delegates to the theme role instead of another pair of hex
    /// literals: `AppearanceStudio.color(_:)` already resolves per
    /// appearance, so this variable follows the user's theme and its dark
    /// variant for free.
    static func success(scope: AppearanceScope = .chat) -> Color {
        studio.color(.success, scope: scope)
    }

    /// --color-warning
    static func warning(scope: AppearanceScope = .chat) -> Color {
        studio.color(.warning, scope: scope)
    }
}
