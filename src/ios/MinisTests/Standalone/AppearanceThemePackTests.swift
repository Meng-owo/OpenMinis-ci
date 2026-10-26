// Standalone (`swift AppearanceThemePackTests.swift`).
// Pins theme-pack decode, radius clamp, hex normalize, and shipping hooks
// without importing the app graph.

import Foundation

var failures = 0
func check(_ label: String, _ actual: Bool, _ expected: Bool = true) {
    if actual == expected { print("  OK \(label)") }
    else { print("  FAIL \(label) — expected \(expected), got \(actual)"); failures += 1 }
}
func checkEq<T: Equatable>(_ label: String, _ actual: T, _ expected: T) {
    if actual == expected { print("  OK \(label)") }
    else { print("  FAIL \(label) — expected \(expected), got \(actual)"); failures += 1 }
}

func clampRadius(_ value: Double) -> Double {
    min(32, max(4, value))
}

func normalizeHex(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).uppercased()
    if trimmed.count == 6 || trimmed.count == 8 { return trimmed }
    return "808080"
}

func read(_ url: URL) -> String {
    (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

print("AppearanceThemePack standalone")

checkEq("clamp low", clampRadius(1), 4)
checkEq("clamp high", clampRadius(99), 32)
checkEq("clamp mid", clampRadius(18), 18)
checkEq("hex hash", normalizeHex("#d4778b"), "D4778B")
checkEq("hex junk", normalizeHex("nope"), "808080")
checkEq("hex eight", normalizeHex("11223344"), "11223344")

let here = URL(fileURLWithPath: #file)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let pack = read(here.appendingPathComponent("Shared/AppearanceThemePack.swift"))
let studio = read(here.appendingPathComponent("Shared/AppearanceStudio.swift"))
let library = read(here.appendingPathComponent("Shared/AppearanceThemeLibrary.swift"))
let chat = read(here.appendingPathComponent("Views/Chat/ChatMessageViews.swift"))
let think = read(here.appendingPathComponent("Views/Chat/AssistantBlockView.swift"))
let input = read(here.appendingPathComponent("Views/Chat/AIChatView.swift"))
let list = read(here.appendingPathComponent("Views/ContentView.swift"))
let studioView = read(here.appendingPathComponent("Views/Settings/AppearanceStudioView.swift"))
let kernel = read(here.appendingPathComponent("iSH/ISHKernel.m"))
let offload = read(here.appendingPathComponent("NativeOffloads/ThemeOffload.m"))
let offloadBridge = read(here.appendingPathComponent("NativeOffloads/ThemeOffloadBridge.swift"))
let extras = read(here.appendingPathComponent("NativeOffloads/ThemeOffloadExtras.swift"))
let extrasCommands = read(here.appendingPathComponent("NativeOffloads/ThemeOffloadExtras+Commands.m"))
let skillStore = read(here.appendingPathComponent("Agent/Session/SkillStore.swift"))
let markdown = read(here.appendingPathComponent("Views/Chat/SelectableMarkdownView.swift"))
let toolLive = read(here.appendingPathComponent("Views/Chat/ToolLiveSheet.swift"))
let transport = read(here.appendingPathComponent("Agent/Sync/V2/ICloudSharedZoneTransport.swift"))
let engine = read(here.appendingPathComponent("Agent/Sync/CloudSyncEngine.swift"))
let migration = read(here.appendingPathComponent("Agent/Sync/V2/MigrationEngine.swift"))
let bootstrap = read(here.appendingPathComponent("Agent/Sync/V2/SyncV2Bootstrap.swift"))
let entitlements = read(here.appendingPathComponent("Minis.entitlements"))

check("pack file", !pack.isEmpty)
check("storage key", pack.contains("appearanceStudio.themePack.v1"))
check("applyThemePack", pack.contains("func applyThemePack"))
check("exportThemePack", pack.contains("func exportThemePack"))
check("studio cache", studio.contains("cachedThemePack"))
check("user bubble uses pack", chat.contains("MinisThemeShape.userBubble"))
check("assistant bubble uses pack", think.contains("MinisThemeShape.assistantBubble"))
check("thinking fill uses pack", think.contains("MinisThemeShape.thinkingFill"))
check("thinking card image", think.contains("thinkingCardImage()"))
check("bubble style enum", pack.contains("enum AppearanceBubbleStyle"))
// [04b-2 §7] Both of these asserted a spelling the code no longer uses, so
// they had been red since before b5595fc and made "run the tests" meaningless.
// The BEHAVIOUR is there in both cases — the assertion was just pinned to an
// older shape.
//   • `case tail` is declared inside a combined case list
//     (`case rounded, squircle, pill, tail, sharp`), so match the switch arm
//     that proves the style is handled.
//   • markdown links colour now comes from `uiColorSnapshot(.accent)`; the
//     scoped `uiColor(.accent, scope: .chat)` form was the older accessor.
check("tail style", pack.contains("case .tail:"))
check("schema 5", pack.contains("schemaVersion = 5"))
check("font family", pack.contains("enum AppearanceFontFamily"))
check("input bar style", pack.contains("inputBarStyle"))
check("input bar image", pack.contains("func setInputBarImage"))
check("composer uses pack shape", input.contains("MinisThemeShape.inputBar"))
check("studio font picker", studioView.contains("正文字体"))
check("studio input bar image", studioView.contains("给输入栏贴图"))
check("bubbles use theme font", chat.contains("MinisThemeShape.fontFamily"))
check("input bar radius", pack.contains("inputBarRadius"))
check("thinking title size", pack.contains("thinkingTitleSize"))
check("category images", pack.contains("categoryImages"))
check("apply category images", pack.contains("func applyCategoryImages"))
check("wipe category images", pack.contains("func wipeCategoryImageFiles"))
check("thinking body uses pack size", think.contains("MinisThemeShape.thinkingBodySize"))
check("thinking title uses pack size", think.contains("MinisThemeShape.thinkingTitleSize"))
check("composer observes studio", input.contains("@ObservedObject private var appearanceStudio"))
check("studio category picker", studioView.contains("setCategoryImage"))
check("category symbol setter", pack.contains("func setCategorySymbol"))
check("category color setter", pack.contains("func setCategoryColor"))
check("studio sf field", studioView.contains("SF 名，空着就是默认"))
check("studio category color", studioView.contains("categoryColorBinding"))
check("edit sheet custom icon", list.contains("categoryImage(for: cat.key)"))
check("v1 pack still decodes", pack.contains("userBubbleStyle"))
check("list row fill", pack.contains("listRowFillHex"))
check("list icon shape", pack.contains("enum AppearanceListIconShape"))
check("category overlay", pack.contains("categoryIcons"))
check("session row uses theme title", list.contains("MinisThemeList.title"))
check("builtin fallback", list.contains("sessionCategoryIconBuiltin"))
check("folder follows theme", list.contains("MinisThemeList.title"))
check("no strokeBorder on bubble", !chat.contains("strokeBorder"))
check("session row observes studio", list.contains("@ObservedObject private var appearanceStudio"))
check("theme library file", library.contains("appearanceStudio.themeLibrary.v1"))
check("save current", library.contains("func saveCurrentTheme"))
check("library files not defaults", library.contains("libraryPackURL"))
check("legacy library migrate", library.contains("func migrateLegacyLibrary"))
check("apply strips jpeg", pack.contains("stored.thinkingCardJPEGBase64 = nil"))
check("studio title binding", studioView.contains("thinkingTitleSizeBinding"))
// [K-4] The eight per-row `PhotosPicker`s collapsed into one page-level picker
// driven by `pickedPhoto` + `pickerTarget`. The old assertion pinned the now
// deleted `categoryImageItem`; pin the replacement wiring instead — a single
// `.photosPicker(isPresented:selection:)` plus the dispatch that routes the
// picked item to the row that asked for it.
check("category onChange", studioView.contains("onChange(of: pickedPhoto)")
      && studioView.contains("case .categoryImage")
      && studioView.contains("pickerTarget = .categoryImage"))
check("edit sheet observes studio", list.contains("struct SessionEditSheet"))
check("list category fill", list.contains("categoryImage(for: key)"))
check("default input radius 20", pack.contains("inputBarRadius: 20"))
check("schema not 3", !pack.contains("schemaVersion = 3"))
check("notAThemePack", pack.contains("notAThemePack"))
check("no unsupportedSchema", !pack.contains("unsupportedSchema"))
check("looksLikeThemePack gate", pack.contains("looksLikeThemePack"))
check("migrate fill missing", pack.contains("fill missing") || pack.contains("Missing fields are filled") || pack.contains("looksLikeThemePack"))
check("schema 5 asJSONObject write", pack.contains("\"schema\": Self.schemaVersion"))
check("upgrade rewrite UserDefaults", pack.contains("storedSchema != AppearanceThemePack.schemaVersion"))
check("cli save", offload.contains("cmd_save"))
check("cli use", offload.contains("cmd_use"))
check("studio library section", studioView.contains("主题库"))
check("no hardcoded thinking blue fill", !think.contains("Color.blue.opacity(0.06)"))
check("kernel registers theme", kernel.contains("theme_offload_register()"))
check("offload stub", offload.contains("noff_ensure_guest_stub(\"/usr/local/bin/minis-theme\")"))
check("offload apply", offload.contains("cmd_apply"))
check("thinking accent follows chat accent", pack.contains("AppearanceStudio.shared.color(.accent, scope: .chat)"))
// [B28 B-3] 默认包不再写死一个 hex —— 空串就是「跟 accent 走」。
// 原来这两条锁的是 D4778B 这个具体色值，B-3 之后那个值本身就不该存在了。
check("default thinking not material blue", !pack.contains("thinkingAccentHex: \"1E88E5\""))
check("default thinking defers to accent", pack.contains("thinkingAccentHex: \"\""))
check("thinking fill falls back to accent", pack.contains("return AppearanceStudio.shared.color(.accent, scope: .chat).opacity(0.06)"))
check("thinking accent falls back to accent", pack.contains("return AppearanceStudio.shared.color(.accent, scope: .chat)"))
check("tool capsules use ChatColors.accent", think.contains("accentColor: ChatColors.accent"))
check("no green tool capsule", !think.contains("accentColor: .green"))
check("tool success uses theme", think.contains("case .success: return ChatColors.success"))
check("slash thinking uses accent", input.contains("thinkingLevel.isEnabled ? ChatColors.accent"))
check("bundled minis-theme skill", skillStore.contains("name: minis-theme"))
check("bundled skill not PPT", skillStore.contains("不是 PPT"))
check("cli documents accent", offload.contains("THEME PACK:"))
check("warning color role", studio.contains("case success, warning, destructive"))
// [B28 E-1] 枚举标题改成 AppLocalized 了，断言跟着改形态。
check("warning title", studio.contains("case .warning: return AppLocalized(\"警告\")"))
check("ChatColors.warning", input.contains("static var warning: Color"))
check("errors use destructive", input.contains("ChatColors.destructive"))
check("interrupt uses warning", chat.contains("ChatColors.warning"))
check("markdown links use accent", markdown.contains("uiColorSnapshot(.accent)"))
check("no chat capsule green leftover", !think.contains("accentColor: .green"))
check("no tool live purple leftover", !toolLive.contains("return .purple"))
check("clone icloud container", transport.contains("iCloud.com.openminis.clone"))
check("no default CKContainer call", !transport.contains("CKContainer.default().privateCloudDatabase"))
check("probeAccount exists", bootstrap.contains("probeAccount()"))
check("disable sync when icloud missing", bootstrap.contains("disabling sync so launch can continue"))
check("v1 delete uses clone container", transport.contains("let db = container.privateCloudDatabase"))
check("entitlement gate exists", transport.contains("hasCloneICloudEntitlement"))
check("probe gated on entitlement", transport.contains("guard hasCloneICloudEntitlement() else"))
check("v1 gated on entitlement", engine.contains("guard ICloudSharedZoneTransport.hasCloneICloudEntitlement() else"))
check("migration shim gated ×4", migration.components(separatedBy: "hasCloneICloudEntitlement()").count > 4)
check("entitlements clone icloud", entitlements.contains("iCloud.com.openminis.clone"))
check("entitlements not official icloud", !entitlements.contains("iCloud.com.openminis.app"))

// --- Partial packs must not destroy user images (2026-10-18) ---
// A missing categoryImages key used to mean "delete that file". Any AI call
// carrying colors only wiped all 16 uploaded category images.
check("decode merges onto a base", pack.contains("merging base: AppearanceThemePack = .default"))
check("category map falls back", pack.contains("fallback: base.categoryImages"))
check("missing key keeps file", pack.contains("guard let value = map[key] else { continue }"))
check("empty string is the delete signal", pack.contains("if value.isEmpty {"))
check("apply keeps unmentioned markers", pack.contains("let mentioned = Set(pack.categoryImages.keys)"))
check("encoded bytes skip re-encode", pack.contains("func writeEncodedImage"))
check("wallpaper takes raw bytes", studio.contains("func setWallpaperEncoded"))
check("thinking card takes raw bytes", pack.contains("func setThinkingCardImageEncoded"))
check("input bar takes raw bytes", pack.contains("func setInputBarImageEncoded"))
check("ai apply merges live pack", offloadBridge.contains("merging: live"))
check("clipboard import merges live pack", studioView.contains("merging: studio.currentThemePack()"))
check("reset snapshots first", pack.contains("func captureThemeUndoSnapshot"))
check("reset is undoable", pack.contains("func undoThemeReset"))
check("reset needs force", offload.contains("--force"))
check("undo command wired", offload.contains("cmd_undo"))
check("undo bridge exists", offloadBridge.contains("func undoReset"))

// --- Extended AI surface (2026-10-18) ---
// Avatars, row icons, per-page wallpapers and single colour overrides used to
// live outside the pack JSON, so an AI could not touch them at all.
check("extras bridge file", extras.contains("class ThemeOffloadExtras"))
check("avatar command", extras.contains("func setAvatar"))
check("assistant avatar", extras.contains("setAssistantAvatar"))
check("icon command", extras.contains("func setIcon"))
check("icon slot listing", extras.contains("listIconSlots"))
check("per-page wallpaper", extras.contains("func setWallpaper"))
check("single colour", extras.contains("func setColor"))
check("colour cleared by name", extras.contains("clearOverride"))
check("extras commands registered", offload.contains("theme_extra_avatar"))
check("wallpaper scope parsed", extras.contains("AppearanceScope(rawValue: scope)"))
check("hex rejected before store", extras.contains("allSatisfy({ $0.isHexDigit })"))
check("extras emit maps ok", extrasCommands.contains("theme_extra_emit"))
check("host path resolved in objc", extrasCommands.contains("noff_resolve_host_path"))

if failures == 0 {
    print("\nALL PASS")
    exit(0)
} else {
    print("\nFAILED \(failures)")
    exit(1)
}
