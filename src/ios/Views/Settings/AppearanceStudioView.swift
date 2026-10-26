import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

// MARK: - 外观
//
// [10-18 醒醒] 「把它装进我们的"装扮"里面，外观点进去，直接就是装扮页的效果，
// 什么功能都在里面配置，然后把装扮语言统一，不分那么多页面了，死掉的就删掉。
// 没死掉的就统一。」
//
// ## 这一版做了什么
//
// 原来有两个页面各管一摊：
//   - ContentView.swift 里的 `AppearanceSettingsView`（12 个分区，行为类）
//   - 这个 `AppearanceStudioView`（6 个分区，视觉类）
//
// 现在合成一页。**「外观」这个词保留**，但点进去直接是这一页。
//
// ## 删掉的
//
// - **Theme 跟随系统/浅色/深色** —— 跟这里的明暗切换重复，只留这里的
// - **工具预览窗口** —— `toolPreviewEnabled` 全仓零消费，是个死开关
//
// ## 搬进来的
//
// 启动会话 / 自动分组 / 回车键 / 屏幕常亮 / 回复后自动聚焦 /
// 流式展开思考 / 字号三条滑杆 / App 图标 / 语言
//
// ## 语言统一
//
// 原来混着三种：`Text("装扮")` 硬编码中文、`Text("Theme")` 英文、
// `AppLocalized("...")` 本地化键。现在全部走 `AppLocalized`，中文兜底。

struct AppearanceStudioView: View {
    @ObservedObject private var studio = AppearanceStudio.shared
    @ObservedObject private var fontSettings = FontSettings.shared

    @State private var variant: AppearanceVariant = .light
    /// [B28 E-2] `variant` 原来写死 `.light`，全文件没有一处从
    /// `studio.activeVariant` 同步 —— 深色用户一进来看到白底预览、浅色
    /// hex 值、按浅色算的对比度结论，而真机界面是深色。
    ///
    /// 这个标记管住"用户自己点过浅/深"：点过之后就不再用系统明暗覆盖他。
    @State private var variantPinnedByUser = false
    @State private var page: AppearanceStudioPage = .palette

    // 行为设置
    @AppStorage("appearanceMode") private var appearanceMode: Int = 0
    @AppStorage("appIconMode") private var appIconMode: Int = 0
    @AppStorage("appLanguage") private var appLanguage: String = ""
    @AppStorage("launchScreen") private var launchScreen: Int = 0
    @AppStorage("returnKeyBehavior") private var returnKeyBehavior: Int = 0
    @AppStorage("keepScreenAwakeDuringTasks") private var keepScreenAwakeDuringTasks: Bool = false
    @AppStorage("chat.autoFocusAfterReply") private var autoFocusAfterReply: Bool = true
    @AppStorage("chat.autoExpandThinking") private var autoExpandThinking: Bool = true

    // 图片
    /// [K-4] Every image picker in this page goes through ONE
    /// `.photosPicker` modifier attached to the page root, dispatched by this
    /// enum.
    ///
    /// Why: the seven `PhotosPicker` *components* used to sit inside the
    /// sub-page content, which lives inside a `ScrollView` that the navigation
    /// stack recycles. A presentation host inside scrolling content is not
    /// stable on iOS 17+ — the picker opened in the middle of the screen or
    /// not at all, which is the "上传文件出 bug" the user reported. Seven
    /// separate modifiers at one level would hit the same
    /// one-presentation-per-level limit that killed K-3, so it is one
    /// modifier plus a switch.
    private enum AppearancePicker: String, Identifiable {
        case wallpaper, userAvatar, assistantAvatar, thinkingCard, inputBar, icon, categoryImage, characterArt
        var id: String { rawValue }
    }

    /// [K-4] What the next picked image is for. Kept SEPARATE from the
    /// presentation flag: SwiftUI writes the `isPresented` binding back to
    /// false when the picker closes, which can land before `onChange` reads
    /// the item — sharing one variable loses the destination.
    @State private var pickerTarget: AppearancePicker?
    @State private var isPickerPresented = false
    @State private var pickedPhoto: PhotosPickerItem?
    /// [04b-2 §5] Which light/dark slot the wallpaper belongs in, captured when
    /// the picker is opened — NOT when the image finishes loading.
    ///
    /// `activeVariant` falls back to `UITraitCollection.current` when the app
    /// follows the system, and Apple only guarantees that value during a
    /// draw/layout pass. `applyPickedPhoto` runs after `await
    /// loadTransferable(...)`, in a plain async continuation, where the trait
    /// collection reads a stale (often `.unspecified` → light) value. So a dark
    /// system plus "follow system" could save the wallpaper into the light slot.
    /// The button's action does run in a real layout pass, so capture it there.
    @State private var pickedWallpaperIsDark = false
    @State private var wallpaperScope: AppearanceScope = .global
    @State private var iconPickSlot: QuietIconSlot?
    @State private var categoryImageKey: String?

    // 高级
    @State private var showAdvanced = false
    @State private var paletteScope: AppearanceScope = .global

    // 杂项
    /// [B28 B-2] 待删的那一套。非 nil 就弹确认框。
    @State private var pendingDeleteTheme: AppearanceSavedTheme?
    /// [B28 R2-1] 「恢复默认色盘」原来是裸调用：红字按钮一点，16 角色 ×
    /// 2 明暗 × 8 页面的手工配色瞬间清空，没确认、没撤销。现在先问，
    /// 清完撤销条就在按钮底下等着。
    @State private var pendingPaletteReset = false
    /// [B28 R5 试点] 样张数据就一行：kind + 文本。AssistantBlock 的其余
    /// 状态全默认，真实组件吃什么假数据，就还你什么真效果。
    /// [B28 R7 醒醒实拍] 聊天里 thinking 早不是「折叠卡片」了：真身是
    /// TurnSummaryRow 合并行，点开弹 TurnDetailSheet 抽屉（2/3 高度）。
    /// 所以样张数据从「一条 thinking block」升级成「一整条假消息」。
    @State private var previewTurnMessage = ChatMessage(
        role: .assistant,
        content: AppLocalized("今晚月色真美呀"),
        blocks: [
            AssistantBlock(
                kind: .thinking,
                content: AppLocalized("这张不是画的样张，是聊天里那张真卡——同一份代码，换主题一起换。")),
            AssistantBlock(kind: .text, content: AppLocalized("今晚月色真美呀")),
        ])
    @State private var showTurnDetailSheet = false
    @State private var showBackdropTurnSheet = false
    /// [B28 R5] AI 侧样张 = AssistantBlockView 真卡：一条 .text block 的假消息。
    @State private var previewAssistantMessage = ChatMessage(
        role: .assistant,
        content: AppLocalized("今晚月色真美呀"),
        blocks: [AssistantBlock(kind: .text, content: AppLocalized("今晚月色真美呀"))])
    @State private var previewAssistantBlock: AssistantBlock?
    @State private var previewHighlightedBlock: UUID?
    /// [B28 R2-8/11] 命名弹窗：顶栏「存」和长按「重命名」共用一套。
    /// 和确认框同层 —— 这页只许一个 alert（K-4 的教训），靠状态分支。
    enum StudioInputDialog: Equatable {
        case save
        case rename(AppearanceSavedTheme)
    }
    @State private var inputDialog: StudioInputDialog?
    @State private var inputName = ""
    /// [B28 B-2] 删完还能撤销：pack 文件进回收站，整条元数据留在内存里。
    @State private var deletedThemeUndo: AppearanceSavedTheme?
    @State private var errorText: String?
    @State private var showError = false
    @State private var showResetConfirm = false
    @State private var shuffleName: String?
    // [10-19 醒醒] 预览默认收起，别一进来就吃掉半屏
    @State private var showSTImporter = false
    /// [04b-2 §1] `importSillyTavern` runs from inside the picker sheet, where a
    /// result alert would be dropped. Park it, raise it after `onDone`.
    @State private var pendingSTOutcome: STImportOutcome?

    enum STImportOutcome {
        case success([String])
        case failure(String)
    }
    @State private var stWarnings: [String] = []
    @State private var showSTWarnings = false
    /// [B28 R10] 自定义称呼的输入缓冲。提交时才落盘，边打字边写会一直存。
    @State private var userDisplayNameDraft = ""

    @MainActor private var aiName: String {
        let n = SoulStore.cachedMetadata.name
        return n.isEmpty ? "AI" : n
    }

    var body: some View {
        // [10-19 醒醒] 改成 iOS 原生结构：根页是 `List`，每个分区用
        // `NavigationLink` 进子页。原来底部挤七个 tab、内容用
        // `ScrollView` + 自绘卡片堆，那是安卓的做法。
        List {
            Section {
                ForEach([AppearanceStudioPage.palette, .bubbles, .backdrop, .icons]) { item in
                    NavigationLink {
                        pageContent(item)
                    } label: {
                        studioRow(item)
                    }
                }
            } header: {
                Text(AppLocalized("Appearance"))
            } footer: {
                Text(AppLocalized("改完立刻生效，聊天页、列表、设置页都跟着变。"))
            }

            Section {
                ForEach([AppearanceStudioPage.library, .behaviour]) { item in
                    NavigationLink {
                        pageContent(item)
                    } label: {
                        studioRow(item)
                    }
                }
            } header: {
                Text(AppLocalized("主题与行为"))
            }
        }
        .listStyle(.insetGrouped)
        .appearancePage(.settings)
        .onAppear { syncVariantFromSystem() }
        .onChange(of: appearanceMode) { _ in
            applyAppearanceMode()
            // [B28 E-2] 明暗设置变了，预览的浅/深也得跟着换 —— 但用户自己
            // 点过就尊重他，不再覆盖。
            syncVariantFromSystem()
        }
        // [K-4] The ONE image picker for this page.
        //
        // Eight `PhotosPicker` components used to live inside the sub-page
        // content, which sits inside a `ScrollView` the navigation stack
        // recycles — an unstable presentation host, so the picker opened in
        // the middle of the screen or not at all ("装扮页上传出 bug"). Here it
        // hangs off the page root, which stays mounted whichever sub-page is
        // open, and the trigger only records WHAT is being picked.
        //
        // The ST theme-pack picker stays on the sub-page (`pageContent`)
        // instead of joining this one: it was moved there on 10-19 because
        // cross-layer presentation is unreliable, and that part was right — it
        // only needed to get out of the ScrollView's content. [04b-2 §3] It is
        // now a `DocumentCopyPicker` sheet rather than `.fileImporter`.
        .photosPicker(isPresented: $isPickerPresented,
                      selection: $pickedPhoto, matching: .images)
        .onChange(of: pickedPhoto) { item in
            guard let item, let picker = pickerTarget else { return }
            Task { await applyPickedPhoto(item, for: picker) }
        }
    }

    /// [K-4] One flag for the shared alert.
    private var isAlertPresented: Binding<Bool> {
        Binding(
            get: { showError || showResetConfirm || showSTWarnings || pendingDeleteTheme != nil
                || pendingPaletteReset || inputDialog != nil },
            set: { presented in
                guard !presented else { return }
                showError = false
                showResetConfirm = false
                showSTWarnings = false
                pendingDeleteTheme = nil
                pendingPaletteReset = false
                inputDialog = nil
            }
        )
    }

    /// [K-3b] `LocalizedStringKey`, not `String`. The `String` overload of
    /// `alert(_:isPresented:)` prints the value verbatim and never consults
    /// the string table — and these three titles plus their bodies were also
    /// missing from `Localizable.xcstrings` entirely, so every non-Chinese
    /// locale showed raw Chinese. Both halves are fixed: the type here, the
    /// five keys in the catalog.
    private var alertTitle: LocalizedStringKey {
        if showResetConfirm { return "Reset appearance?" }
        if pendingPaletteReset { return "Reset the color palette?" }
        if inputDialog == .save { return "Save as new theme" }
        if case .rename? = inputDialog { return "Rename theme" }
        if showSTWarnings { return "Import finished" }
        // [B28 B-2] 删主题现在要二次确认。原来点一下行就没了，没确认、
        // 没撤销、也没说删的是不是正在用的那套。
        if pendingDeleteTheme != nil { return "Delete this theme?" }
        return "Something went wrong"
    }

    private var alertMessage: String {
        if let pending = pendingDeleteTheme {
            return String(format: AppLocalized("“%@” will be removed from the library."), pending.name)
        }
        if pendingPaletteReset {
            return AppLocalized("Clear every palette tweak. You can undo right after.")
        }
        if case .rename(let target)? = inputDialog {
            return target.name
        }
        if inputDialog == .save {
            return AppLocalized("另存一份，不会冲掉正在用的。")
        }
        if showResetConfirm {
            // [B28 R2-4] 旧文案没提三个透明度滑杆 —— 点完才发现压色、
            // 卡片透明度也被清了。功能必须诚实具备它描述的样子（醒醒 10-23）。
            return AppLocalized("Colors, bubble shapes, stickers, and the three opacity sliders go back to default. Wallpaper and avatars stay.")
        }
        if showSTWarnings {
            return stWarnings.joined(separator: "\n")
        }
        return errorText ?? ""
    }

    /// [K-4] Load one picked image and route it to whichever row asked for it.
    @MainActor
    private func applyPickedPhoto(_ item: PhotosPickerItem, for picker: AppearancePicker) async {
        let maxEdge: CGFloat
        switch picker {
        case .wallpaper: maxEdge = 2200
        case .userAvatar, .assistantAvatar, .icon: maxEdge = 512
        case .thinkingCard, .inputBar: maxEdge = 1400
        case .categoryImage: maxEdge = 256
        case .characterArt: maxEdge = 1600
        }
        // Read the row identity BEFORE clearing it: `iconPickSlot` /
        // `categoryImageKey` say which row was tapped.
        let slot = iconPickSlot
        let categoryKey = categoryImageKey
        defer {
            pickedPhoto = nil
            pickerTarget = nil
            iconPickSlot = nil
            categoryImageKey = nil
        }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = ThumbnailCache.downsampledImage(from: data, maxEdge: maxEdge) else {
            fail(AppLocalized("选中的图读不出来。"))
            return
        }
        switch picker {
        case .wallpaper:
            // [04b-2 §5] Use the variant captured when the picker opened, not
            // one read here: this runs after `await loadTransferable`, outside
            // any layout pass, where `UITraitCollection.current` is stale.
            // [B28 R2-2] 写失败以前静默 —— 点了、转完了、什么也没发生。
            if !studio.setWallpaper(image, for: wallpaperScope, dark: pickedWallpaperIsDark) {
                fail(AppLocalized("选中的图读不出来。"))
            }
        case .userAvatar:
            studio.setUserAvatar(image)
        case .assistantAvatar:
            do { try studio.setAssistantAvatar(image) }
            catch { fail(error.localizedDescription) }
        case .icon:
            guard let slot else { return }
            if !studio.setIcon(image, for: slot.id) { fail(AppLocalized("选中的图读不出来。")) }
        case .thinkingCard:
            if !studio.setThinkingCardImage(image) { fail(AppLocalized("选中的图读不出来。")) }
        case .inputBar:
            if !studio.setInputBarImage(image) { fail(AppLocalized("选中的图读不出来。")) }
        case .categoryImage:
            guard let categoryKey else { return }
            if !studio.setCategoryImage(image, for: categoryKey) { fail(AppLocalized("选中的图读不出来。")) }
        case .characterArt:
            // [B28 A-1] 直接落文件，不再绕 base64 进 defaults。
            studio.setCharacterArtImage(image)
        }
    }
    /// [B28 R2-11] 存当前这套。名字来自弹窗，可改。满 40 套如实拒绝 ——
    /// 以前会悄悄删掉你最旧的一套腾地方，你没点过任何删除。
    private func commitSaveToLibrary() {
        let label = inputName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = AppLocalized("Untitled")
        if let item = studio.saveCurrentTheme(name: label.isEmpty ? fallback : label) {
            MinisToast.show(String(format: AppLocalized("Saved “%@”"), item.name))
        } else {
            MinisToast.show(AppLocalized("The library is full (40). Delete one theme first."),
                            systemImage: "exclamationmark.triangle.fill")
        }
        inputDialog = nil
    }

    /// [B28 R2-8] 名字打错不必删了重存。CLI 早就有 rename，UI 补上。
    private func commitRenameTheme(_ target: AppearanceSavedTheme) {
        let label = inputName.trimmingCharacters(in: .whitespacesAndNewlines)
        if studio.renameSavedTheme(id: target.id, name: label) {
            MinisToast.show(String(format: AppLocalized("Renamed “%@”"), label))
        } else {
            MinisToast.show(AppLocalized("名字不能是空的。"),
                            systemImage: "exclamationmark.triangle.fill")
        }
        inputDialog = nil
    }

    /// [B28 R2-9] 壁纸三选一的状态：有本页图 / 没图且没掐继承 / 没图且掐了
    /// 继承。切到「本页图」且当前没图时拉起选图器 —— 取消就回到原状态，
    /// 不做没发生的事。
    private var wallpaperSourceBinding: Binding<Int> {
        Binding(
            get: {
                if studio.hasOwnWallpaper(wallpaperScope) { return 0 }
                return studio.wallpaperClearsGlobal(wallpaperScope) ? 2 : 1
            },
            set: { target in
                switch target {
                case 0:
                    guard !studio.hasOwnWallpaper(wallpaperScope) else { return }
                    pickerTarget = .wallpaper
                    pickedWallpaperIsDark = studio.activeVariant == .dark
                    isPickerPresented = true
                case 1:
                    studio.removeWallpaper(wallpaperScope)
                case 2:
                    studio.clearWallpaper(wallpaperScope)
                default: break
                }
            }
        )
    }

    /// [B28 R3-5] apply 的 warnings 字段名 → 给用户看的词（查九语种表，
    /// 不硬塞中文）。
    private static func themeImageName(_ field: String) -> String {
        let labels: [String: String] = [
            "wallpaper": "壁纸", "thinkingCard": "thinking 卡片",
            "inputBar": "输入栏", "characterArt": "立绘",
        ]
        guard let label = labels[field] else { return field }
        return String(localized: String.LocalizationValue(label), bundle: AppBundle.current)
    }

    /// [B28 R5/R6] 「在哪改在哪看」的落点：真聊天组件的共享样张卡。
    /// 气泡页挂它、配色页挂它 —— 一处实现，两处诚实。
    @ViewBuilder
    /// [B28 R7 醒醒分类] 样张按页分开，不再三页共用一张：
    /// 每页只长它自己管的那几样东西。浅/深切换跟着样张走。
    private var sampleHeader: some View {
        HStack {
            sectionTitle(AppLocalized("样张 · 实时"))
            Spacer()
            Picker("", selection: variantBinding) {
                ForEach(AppearanceVariant.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 104)
        }
    }

    /// 真输入栏皮肤：ComposerSurface 就是聊天页那一个。
    private var inputBarSample: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(studio.color(.secondaryText, variant: variant))
            // 用聊天页同一个占位键，别自己造一条新的。
            Text(String(format: AppLocalized("Message %@ (@ to mention files)"), aiName))
                .font(.system(size: 14))
                .foregroundStyle(studio.color(.secondaryText, variant: variant).opacity(0.7))
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "mic")
                .font(.system(size: 14))
                .foregroundStyle(studio.color(.secondaryText, variant: variant))
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 28, height: 28)
                .background(studio.color(.accent, variant: variant), in: Circle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .modifier(ComposerSurface())
    }

    /// 背景页样张：它管的是「贴在卡片上的图」—— thinking 卡片 + 输入栏。
    private var backdropSampleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sampleHeader
            // [B28 R7-3 醒醒 10-23] 不自己画 thinking 卡片了——真身是
            // TurnSummaryRow 合并行，点开弹 TurnDetailSheet 抽屉，卡片背景
            // （fill + 卡片图 + 浓度）就长在那个抽屉里。样张点开=同一个抽屉。
            Text(AppLocalized("点这一行看 thinking 卡片的真身，卡片图就贴在那上面。"))
                .font(.system(size: 11.5))
                .lineSpacing(2)
                .foregroundStyle(studio.color(.secondaryText, variant: variant))
            TurnSummaryRow(
                message: previewTurnMessage,
                memberIDs: previewTurnMessage.blocks.filter { $0.kind == .thinking }.map(\.id),
                isWorking: false
            ) { showBackdropTurnSheet = true }
            inputBarSample
        }
        .modifier(StudioCard(variant: variant))
        .sheet(isPresented: $showBackdropTurnSheet) {
            TurnDetailSheet(message: previewTurnMessage)
                .presentationDetents([.fraction(2/3), .large])
        }
    }

    /// 配色页样张：它管的是颜色 —— 气泡底色、主次文字色。
    private var paletteSampleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sampleHeader
            AssistantBlockView(block: previewAssistantMessage.blocks[0],
                               message: previewAssistantMessage,
                               isActiveMessage: false,
                               highlightedBlockId: $previewHighlightedBlock,
                               detailBlock: $previewAssistantBlock)
            HStack {
                Spacer(minLength: 0)
                Text(AppLocalized("也真的想你"))
                    .font(MinisThemeShape.fontFamily.font(size: FontSettings.shared.scaledMessage(16.5)))
                    .foregroundStyle(ChatColors.primaryText)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .modifier(UserBubbleSurface(isQueued: false))
            }
            Text(AppLocalized("主文字看看我"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(studio.color(.primaryText, variant: variant))
            Text(AppLocalized("次文字也看看我"))
                .font(.system(size: 11.5))
                .foregroundStyle(studio.color(.secondaryText, variant: variant))
        }
        .modifier(StudioCard(variant: variant))
    }

    /// 气泡页样张：形状 / 消息形态 / 代码块 / 字体 —— 所以摆 AI 气泡、
    /// 用户气泡、输入栏、thinking 合并行。输入栏用的是真 ComposerSurface，
    /// 不是画的（醒醒 10-23 点名：有输入栏的调节却没有输入栏的预览）。
    private var bubblesSampleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sampleHeader
            AssistantBlockView(block: previewAssistantMessage.blocks[0],
                               message: previewAssistantMessage,
                               isActiveMessage: false,
                               highlightedBlockId: $previewHighlightedBlock,
                               detailBlock: $previewAssistantBlock)
            HStack {
                Spacer(minLength: 0)
                Text(AppLocalized("也真的想你"))
                    .font(MinisThemeShape.fontFamily.font(size: FontSettings.shared.scaledMessage(16.5)))
                    .foregroundStyle(ChatColors.primaryText)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .modifier(UserBubbleSurface(isQueued: false))
            }
            inputBarSample
            TurnSummaryRow(
                message: previewTurnMessage,
                memberIDs: previewTurnMessage.blocks.filter { $0.kind == .thinking }.map(\.id),
                isWorking: false
            ) { showTurnDetailSheet = true }
        }
        .modifier(StudioCard(variant: variant))
        .sheet(isPresented: $showTurnDetailSheet) {
            TurnDetailSheet(message: previewTurnMessage)
                .presentationDetents([.fraction(2/3), .large])
        }
    }


    private func fail(_ message: String) {
        errorText = message
        showError = true
    }

    /// [B28 E-2] 用户手动点浅/深时用这个绑定，顺手打上"别自动覆盖我"的标记。
    /// 自动同步走 `variant` 本身，不经过这里。
    private var variantBinding: Binding<AppearanceVariant> {
        Binding(
            get: { variant },
            set: { newValue in
                variantPinnedByUser = true
                variant = newValue
            }
        )
    }

    /// [B28 E-2] 没被用户手动钉住时，跟着系统/设置的明暗走。
    private func syncVariantFromSystem() {
        guard !variantPinnedByUser else { return }
        variant = studio.activeVariant
    }

    /// [B28 B-2 / D-3] 删一套主题。pack 文件进回收站，撤销条在列表顶部停着，
    /// 直到用户点撤销、点了别的主题、或者离开这一页。
    private func deleteTheme(_ item: AppearanceSavedTheme) {
        guard studio.deleteSavedTheme(id: item.id) else {
            MinisToast.show(AppLocalized("Couldn't delete this theme."),
                            systemImage: "exclamationmark.triangle.fill")
            return
        }
        deletedThemeUndo = item
    }

    /// [B28 B-2] 撤销条。删除不是不可逆的 —— 主题库里的东西是用户自己
    /// 攒的，点错一下不该没。
    @ViewBuilder
    private var undoDeleteBanner: some View {
        if let undo = deletedThemeUndo {
            HStack(spacing: 10) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                Text(String(format: AppLocalized("Deleted “%@”"), undo.name))
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer()
                Button(AppLocalized("Undo")) {
                    // [B28 R2-3] 库满时撤销不进来 —— 不许静默丢弃，
                    // 撤销条留着，并说清楚为什么。
                    if studio.restoreSavedTheme(undo) {
                        deletedThemeUndo = nil
                    } else {
                        MinisToast.show(AppLocalized("The library is full (40). Delete one theme first."),
                                        systemImage: "exclamationmark.triangle.fill")
                    }
                }
                .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(studio.color(.primaryText, variant: variant))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(studio.color(.raised, variant: variant))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    /// 明暗覆盖。原来在外观页里，逻辑没动，只是搬过来。
    private func applyAppearanceMode() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.windows.forEach { window in
            window.overrideUserInterfaceStyle =
                appearanceMode == 1 ? .light : appearanceMode == 2 ? .dark : .unspecified
        }
    }

    // MARK: - 预览
    //
    // 用真组件：真头像（PersonAvatarView）、真壁纸（AppearanceBackdrop）、
    // 真气泡（MinisBubbleShape）。上一版是重画的一套简化 UI，所以换了头像
    // 和壁纸这里不动——现在跟着动。
    //
    // [10-19 醒醒] 改成可折叠，默认收起。原来整块常驻 372pt，占掉半屏，
    // 她要看设置得往下滚很久。

    /// 根页的分区行。
    private func studioRow(_ item: AppearanceStudioPage) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(MinisTheme.secondaryText)
            }
        } icon: {
            Image(systemName: item.symbol)
                .foregroundStyle(studio.color(.accent, variant: variant))
        }
    }

    /// 子页内容分发。七个页原来是 tab 直接切，现在按 `NavigationLink` 渲染。
    @ViewBuilder
    private func pageContent(_ item: AppearanceStudioPage) -> some View {
        // [10-19 醒醒] 子页内容原来是纯 VStack，塞进 NavigationLink 后
        // 没有滚动容器会挤成一坨。统一包一层 ScrollView，卡片视觉保留。
        ScrollView {
            VStack(spacing: 16) {
                switch item {
                case .palette:   palettePage
                case .bubbles:   bubblesPage
                case .backdrop:  backdropPage
                case .icons:     iconsPage
                case .library:   libraryPage
                case .behaviour: behaviourPage
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        // [B28 R2-11] 顶栏「存」。调色调到一半想留住现状，不用退回主题库
        // 找入口。点了弹名字框 —— 不自动起名，名字是你给这套样子的身份。
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(AppLocalized("Save")) {
                    inputName = ""
                    inputDialog = .save
                }
                .font(.system(size: 13))
            }
        }
        // [K-4] The ST theme-pack importer used to hang off `libraryPage`,
        // which lives INSIDE this ScrollView's content. A presentation
        // modifier attached to a view that the scroll container recycles has
        // no stable hosting controller, and on iOS 17+ the importer simply
        // never appears ("点了没反应"). One level out — on the ScrollView
        // itself, still inside the NavigationLink destination — is a stable
        // host. The 10-19 note moved it from the root List into this page
        // because cross-layer presentation was unreliable; this keeps it in
        // the page, just outside the scrolling content.
        // [04b-2 §3] Copy-mode picker, not `.fileImporter`. Open-in-place never
        // receives its FileProvider grant on a resigned build, so picking a
        // theme pack did nothing and said nothing.
        //
        // The result has to be raised after this sheet is gone — `importSillyTavern`
        // runs from `onPick`, while the sheet is still on screen, and an alert
        // requested then is dropped. `pendingSTOutcome` carries it across.
        // [B28 R3-1 · 真机 bug] alert 原来挂在根页 List 上：在主题库子页点
        // 「删」，弹框被压在导航栈下面，要退回上一页才冒出来。所有触发者都在
        // 子页里，所以宿主也搬到子页链（和可用的 sheet/picker 同层）。
        // [K-4] 本页只许一个 alert —— 多实例被 iOS 吞，靠状态分支。
        .alert(alertTitle, isPresented: isAlertPresented) {
            if showResetConfirm {
                Button("Cancel", role: .cancel) { showResetConfirm = false }
                Button("Reset", role: .destructive) {
                    studio.resetThemePack()
                    showResetConfirm = false
                }
            } else if pendingPaletteReset {
                Button("Cancel", role: .cancel) { pendingPaletteReset = false }
                Button("Reset", role: .destructive) {
                    studio.resetPaletteWithUndo()
                    pendingPaletteReset = false
                    MinisToast.show(AppLocalized("色盘已恢复默认，点下面可以撤销。"))
                }
            } else if let dialog = inputDialog {
                TextField(AppLocalized("Name it"), text: $inputName)
                    .textInputAutocapitalization(.never)
                switch dialog {
                case .save:
                    Button(AppLocalized("Save")) { commitSaveToLibrary() }
                case .rename(let target):
                    Button(AppLocalized("Rename")) { commitRenameTheme(target) }
                }
                Button("Cancel", role: .cancel) { inputDialog = nil }
            } else if let pending = pendingDeleteTheme {
                Button("Cancel", role: .cancel) { pendingDeleteTheme = nil }
                Button("Delete", role: .destructive) {
                    deleteTheme(pending)
                    pendingDeleteTheme = nil
                }
            } else {
                Button("OK", role: .cancel) {
                    showError = false
                    showSTWarnings = false
                }
            }
        } message: {
            Text(alertMessage)
        }
        .sheet(isPresented: $showSTImporter) {
            DocumentCopyPicker(contentTypes: [.json, .plainText, .data, .item],
                               allowsMultipleSelection: false) { urls in
                guard let url = urls.first else { return }
                importSillyTavern(url)
            } onDone: {
                showSTImporter = false
                guard let outcome = pendingSTOutcome else { return }
                pendingSTOutcome = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    switch outcome {
                    case .success(let notes):
                        stWarnings = notes
                        showSTWarnings = true
                    case .failure(let message):
                        fail(message)
                    }
                }
            }
        }
        .background(MinisTheme.color(.canvas, scope: .settings))
    }

    // MARK: - 配色

    private var palettePage: some View {
        VStack(spacing: 16) {
            paletteSampleCard
            shuffleCard
            presetsCard
            contrastCard
            bubbleColorCard
            ForEach(AppearanceColorRoleGroup.allCases) { group in
                paletteGroupCard(group)
            }
            advancedCard
        }
    }

    private var shuffleCard: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppLocalized("摇一套"))
                        .font(.system(size: 16, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(studio.color(.primaryText, variant: variant))
                    Text(AppLocalized("先定一个主色，其余按莫兰迪规则推导。同一个档每次都不一样。"))
                        .font(.system(size: 11.5))
                        .lineSpacing(1.5)
                        .foregroundStyle(studio.color(.secondaryText, variant: variant))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    roll()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "dice")
                            .font(.system(size: 13, weight: .semibold))
                        Text(AppLocalized("摇"))
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(studio.color(.accent, variant: variant))
                    .padding(.horizontal, 15)
                    .padding(.vertical, 9)
                    .background(studio.color(.chip, variant: variant).opacity(studio.surfaceOpacity),
                                in: Capsule())
                    .overlay(
                        Capsule().stroke(studio.color(.border, variant: variant).opacity(0.4), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 0) {
                ForEach([AppearanceColorRole.canvas, .surface, .iconTile, .chip,
                         .userBubble, .accent, .primaryText], id: \.self) { role in
                    Rectangle()
                        .fill(studio.color(role, variant: variant))
                        .frame(height: 30)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(studio.color(.border, variant: variant).opacity(0.35), lineWidth: 0.5)
            )

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(AppearanceThemeShuffle.Mood.allCases) { mood in
                        Button {
                            roll(mood: mood)
                        } label: {
                            Text(mood.title)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(studio.color(.secondaryText, variant: variant))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(studio.color(.iconTile, variant: variant).opacity(studio.surfaceOpacity),
                                            in: Capsule())
                                .overlay(
                                    Capsule().stroke(studio.color(.border, variant: variant).opacity(0.32), lineWidth: 0.5)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .modifier(StudioCard(variant: variant))
    }

    private func roll(mood: AppearanceThemeShuffle.Mood? = nil) {
        let name = studio.shuffleTheme(mood: mood)
        withAnimation(.easeOut(duration: 0.18)) { shuffleName = name }
        Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            withAnimation(.easeIn(duration: 0.3)) { shuffleName = nil }
        }
    }

    private var presetsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(AppLocalized("预设"))
            HStack(spacing: 8) {
                ForEach(AppearancePreset.allCases) { preset in
                    Button {
                        studio.applyPreset(preset)
                    } label: {
                        VStack(spacing: 7) {
                            HStack(spacing: 0) {
                                ForEach(Array(presetSwatchColors(preset).enumerated()), id: \.offset) { _, hex in
                                    Rectangle().fill(Color(hex: hex))
                                }
                            }
                            .frame(height: 24)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(studio.color(.border, variant: variant).opacity(0.3), lineWidth: 0.5)
                            )
                            Text(preset.title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(studio.color(.secondaryText, variant: variant))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(9)
                        .background(studio.color(.iconTile, variant: variant).opacity(studio.surfaceOpacity),
                                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(studio.color(.border, variant: variant).opacity(0.3), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .modifier(StudioCard(variant: variant))
    }

    private func presetSwatchColors(_ preset: AppearancePreset) -> [String] {
        let map = variant == .light ? preset.colors.light : preset.colors.dark
        return [AppearanceColorRole.canvas, .surface, .accent, .primaryText].compactMap { map[$0] }
    }

    private func paletteGroupCard(_ group: AppearanceColorRoleGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                sectionTitle(group.title)
                Text(group.hint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(studio.color(.secondaryText, variant: variant).opacity(0.85))
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ForEach(Array(group.roles.enumerated()), id: \.element) { index, role in
                if index > 0 {
                    hairline
                }
                paletteRow(role)
            }
        }
        .modifier(StudioCard(variant: variant))
    }

    private var hairline: some View {
        Rectangle()
            .fill(studio.color(.border, variant: variant).opacity(0.22))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }

    private func paletteRow(_ role: AppearanceColorRole) -> some View {
        HStack(spacing: 13) {
            ColorPicker("", selection: studio.colorBinding(role, scope: .global, variant: variant),
                        supportsOpacity: false)
                .labelsHidden()
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(role.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(studio.color(.primaryText, variant: variant))
                Text(role.hint)
                    .font(.system(size: 10))
                    .foregroundStyle(studio.color(.secondaryText, variant: variant).opacity(0.72))
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Text("#\(studio.hex(role, scope: .global, variant: variant))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(studio.color(.secondaryText, variant: variant).opacity(0.55))

            if studio.hasOverride(role, scope: .global, variant: variant) {
                Button {
                    studio.clearOverride(role, scope: .global, variant: variant)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(studio.color(.secondaryText, variant: variant))
                        .frame(width: 20, height: 20)
                        .background(studio.color(.iconTile, variant: variant).opacity(studio.surfaceOpacity),
                                    in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    /// 对比度体检。摇骰子生成的一定过，但手动调完可能不过——
    /// 这里列出来让她自己判断，不硬改她的选择。
    private var contrastCard: some View {
        let colors = studio.allColors(variant: variant)
        let issues = AppearanceContrast.audit(colors)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: issues.isEmpty ? "checkmark.seal" : "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(issues.isEmpty
                                     ? studio.color(.success, variant: variant)
                                     : studio.color(.warning, variant: variant))
                sectionTitle(AppLocalized("对比度"))
                Spacer()
                if !issues.isEmpty {
                    Text("\(issues.count)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(studio.color(.warning, variant: variant), in: Capsule())
                }
            }
            if issues.isEmpty {
                Text(AppLocalized("文字和底都看得清。正文 4.5:1 以上，其余 3:1 以上。"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(studio.color(.secondaryText, variant: variant).opacity(0.8))
            } else {
                ForEach(issues, id: \.self) { issue in
                    Text(issue)
                        .font(.system(size: 10.5))
                        .foregroundStyle(studio.color(.secondaryText, variant: variant))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .modifier(StudioCard(variant: variant))
    }

    private var advancedCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) { showAdvanced.toggle() }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .medium))
                    Text(AppLocalized("Advanced"))
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(showAdvanced ? 180 : 0))
                }
                .foregroundStyle(studio.color(.secondaryText, variant: variant))
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showAdvanced {
                hairline
                VStack(alignment: .leading, spacing: 12) {
                    Text(AppLocalized("给单独某一页换色。没单独调过的页跟随「全部页面」。"))
                        .font(.system(size: 11))
                        .foregroundStyle(studio.color(.secondaryText, variant: variant))

                    Picker(AppLocalized("改哪一页"), selection: $paletteScope) {
                        // 底部栏只能挂壁纸，不能调色，所以配色页不列它。
                        ForEach(AppearanceScope.allCases.filter { $0.supportsColour }) {
                            Text($0.title).tag($0)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(studio.color(.accent, variant: variant))

                    if paletteScope != .global {
                        let count = studio.overrideCount(scope: paletteScope, variant: variant)
                        HStack(spacing: 8) {
                            Text(count == 0
                                 ? AppLocalized("这一页还没有单独调过任何颜色。")
                                 : String(format: AppLocalized("这一页有 %d 项和全局不一样。"), count))
                                .font(.system(size: 11))
                                .foregroundStyle(studio.color(.secondaryText, variant: variant))
                            Spacer()
                            if count > 0 {
                                Button(AppLocalized("全部还原")) {
                                    studio.clearOverrides(scope: paletteScope, variant: variant)
                                }
                                .font(.system(size: 11))
                                .foregroundStyle(studio.color(.destructive, variant: variant))
                            }
                        }

                        ForEach(AppearanceColorRoleGroup.allCases) { group in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(group.title)
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(studio.color(.secondaryText, variant: variant).opacity(0.8))
                                    .padding(.top, 8)
                                    .padding(.bottom, 3)
                                ForEach(group.roles, id: \.self) { role in
                                    scopedRow(role)
                                }
                            }
                        }
                    }

                    hairline.padding(.leading, 0).padding(.vertical, 4)

                    Button {
                        // [B28 R2-1] 先确认，清完给撤销。见 alert 的
                        // pendingPaletteReset 分支。
                        pendingPaletteReset = true
                    } label: {
                        Text(AppLocalized("恢复默认色盘"))
                            .font(.system(size: 12))
                            .foregroundStyle(studio.color(.destructive, variant: variant))
                    }
                    .buttonStyle(.plain)
                    if studio.canUndoThemeReset {
                        Button(AppLocalized("撤销上一次恢复")) {
                            if studio.undoThemeReset() {
                                MinisToast.show(AppLocalized("已撤销。"))
                            }
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(studio.color(.secondaryText, variant: variant))
                    }
                }
                .padding(16)
            }
        }
        .modifier(StudioCard(variant: variant))
    }

    private func scopedRow(_ role: AppearanceColorRole) -> some View {
        let overridden = studio.hasOverride(role, scope: paletteScope, variant: variant)
        return HStack(spacing: 11) {
            ColorPicker("", selection: studio.colorBinding(role, scope: paletteScope, variant: variant),
                        supportsOpacity: false)
                .labelsHidden()
                .frame(width: 24, height: 24)
            Text(role.title)
                .font(.system(size: 12))
                .foregroundStyle(studio.color(.primaryText, variant: variant))
            Spacer()
            if overridden {
                Text(AppLocalized("已单独调"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(studio.color(.accent, variant: variant))
                Button {
                    studio.clearOverride(role, scope: paletteScope, variant: variant)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(studio.color(.secondaryText, variant: variant))
                }
                .buttonStyle(.plain)
            } else {
                Text("#\(studio.hex(role, scope: .global, variant: variant))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(studio.color(.secondaryText, variant: variant).opacity(0.45))
            }
        }
        .padding(.vertical, 5)
    }

    // MARK: - 气泡

    /// [B28 R7 醒醒分类] 「气泡颜色」原来是气泡页的第一张卡——那是调色，
    /// 归配色页。抽成一张卡，挂哪儿由页面决定，别让控件和语义走散。
    private var bubbleColorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(AppLocalized("气泡颜色"))
            ForEach([AppearanceColorRole.userBubble, .assistantBubble], id: \.self) { role in
                HStack(spacing: 13) {
                    ColorPicker("", selection: studio.colorBinding(role, scope: .global, variant: variant),
                                supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 32, height: 32)
                    Text(role.title)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(studio.color(.primaryText, variant: variant))
                    Spacer()
                    Text("#\(studio.hex(role, scope: .global, variant: variant))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(studio.color(.secondaryText, variant: variant).opacity(0.55))
                }
                .padding(.vertical, 6)
            }
            sliderRow(AppLocalized("气泡透明度"), value: $studio.bubbleOpacity, range: 0.15...1)
        }
        .modifier(StudioCard(variant: variant))
    }

    private var bubblesPage: some View {
        VStack(spacing: 16) {
            bubblesSampleCard

            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(AppLocalized("形状"))
                Picker(AppLocalized("我的气泡"), selection: userStyleBinding) {
                    ForEach(AppearanceBubbleStyle.allCases) { Text($0.title).tag($0) }
                }
                .tint(studio.color(.accent, variant: variant))
                Picker(String(format: AppLocalized("%@气泡"), aiName), selection: assistantStyleBinding) {
                    ForEach(AppearanceBubbleStyle.allCases) { Text($0.title).tag($0) }
                }
                .tint(studio.color(.accent, variant: variant))
                Picker(AppLocalized("输入栏形状"), selection: inputBarStyleBinding) {
                    ForEach(AppearanceBubbleStyle.allCases) { Text($0.title).tag($0) }
                }
                .tint(studio.color(.accent, variant: variant))
                Picker(AppLocalized("列表图标"), selection: listIconShapeBinding) {
                    ForEach(AppearanceListIconShape.allCases) { Text($0.title).tag($0) }
                }
                .tint(studio.color(.accent, variant: variant))
                sliderRow(AppLocalized("输入栏圆角"), value: inputBarRadiusBinding, range: 4...32, unit: "")
                Picker(AppLocalized("头像形状"), selection: avatarShapeBinding) {
                    ForEach(AppearanceAvatarShape.allCases) { Text($0.title).tag($0) }
                }
                .tint(studio.color(.accent, variant: variant))
                Text(AppLocalized("头像形状同时作用于聊天、列表和通讯录。"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(studio.color(.secondaryText, variant: variant).opacity(0.8))
            }
            .modifier(StudioCard(variant: variant))

            // 消息形态 + 行高 + 字距。这三个是 ST 主题包里能接住的部分。
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(AppLocalized("消息形态"))
                Picker("", selection: chatDisplayBinding) {
                    ForEach(AppearanceChatDisplay.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(AppearanceChatDisplay.parse(studio.currentThemePack().chatDisplay).hint)
                    .font(.system(size: 10.5))
                    .lineSpacing(1.5)
                    .foregroundStyle(studio.color(.secondaryText, variant: variant).opacity(0.8))

                hairline.padding(.leading, 0).padding(.vertical, 4)

                sliderRow(AppLocalized("行高"), value: lineHeightBinding, range: 0.9...2.2, unit: "x")
                sliderRow(AppLocalized("字距"), value: letterSpacingBinding, range: -1...3, unit: "pt")
            }
            .modifier(StudioCard(variant: variant))

            // [10-20 醒醒] 代码块
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(AppLocalized("代码块"))
                Stepper(value: codeBlockCollapseLinesBinding, in: 4...40, step: 1) {
                    HStack {
                        Text(AppLocalized("超过多少行折叠"))
                            .font(.system(size: 13.5))
                            .foregroundStyle(studio.color(.primaryText, variant: variant))
                        Spacer()
                        Text("\(studio.currentThemePack().codeBlockCollapseLines)")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(studio.color(.secondaryText, variant: variant))
                    }
                }
                Text(AppLocalized("超出的部分收起来，点一下展开，看完能再收起。"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(studio.color(.secondaryText, variant: variant).opacity(0.8))
            }
            .modifier(StudioCard(variant: variant))

            // [10-19 醒醒] 视觉小说模式。立绘照 ST 的 waifuMode 做，
            // 对话框是 Galgame 那种。
            novelModeCard(variant: variant)

            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(AppLocalized("正文字体"))
                Picker(AppLocalized("正文字体"), selection: fontFamilyBinding) {
                    ForEach(AppearanceFontFamily.allCases) { Text($0.title).tag($0) }
                }
                .tint(studio.color(.accent, variant: variant))
                Text(AppLocalized("字体只作用于聊天正文、输入框和 thinking 卡片。"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(studio.color(.secondaryText, variant: variant).opacity(0.8))
            }
            .modifier(StudioCard(variant: variant))
        }
    }

    // MARK: - 背景

    /// [B28 R7 醒醒分类] 卡片贴图（thinking 卡片图 + 输入栏图）原来挂在
    /// 「图标」页——那是卡片背景，归背景页。抽成一张卡，挂哪儿由页面决定。
    private var cardImageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(AppLocalized("贴图"))

            // [K-4] Was a `PhotosPicker` component inside this scrolling
            // content. Component-style pickers present from the middle of
            // the screen and need a stable host, which scrolling content
            // does not give them. Button + the page-level modifier.
            Button {
                pickerTarget = .thinkingCard
                isPickerPresented = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 13))
                        .foregroundStyle(studio.color(.accent, variant: variant))
                        .frame(width: 22)
                    Text(studio.hasThinkingCardImage()
                         ? AppLocalized("换 thinking 卡片图")
                         : AppLocalized("给 thinking 卡片贴图"))
                        .font(.system(size: 13.5))
                        .foregroundStyle(studio.color(.primaryText, variant: variant))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if studio.hasThinkingCardImage() {
                sliderRow(AppLocalized("卡片图浓度"), value: thinkingCardOpacityBinding, range: 0.05...1)
                Button {
                    studio.removeThinkingCardImage()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .frame(width: 22)
                        Text(AppLocalized("去掉 thinking 卡片图"))
                            .font(.system(size: 13))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(studio.color(.destructive, variant: variant))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            hairline

            Button {
                pickerTarget = .inputBar
                isPickerPresented = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 13))
                        .foregroundStyle(studio.color(.accent, variant: variant))
                        .frame(width: 22)
                    Text(studio.hasInputBarImage()
                         ? AppLocalized("换输入栏图")
                         : AppLocalized("给输入栏贴图"))
                        .font(.system(size: 13.5))
                        .foregroundStyle(studio.color(.primaryText, variant: variant))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if studio.hasInputBarImage() {
                sliderRow(AppLocalized("输入栏图浓度"), value: inputBarOpacityBinding, range: 0.05...1)
                Button {
                    studio.removeInputBarImage()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .frame(width: 22)
                        Text(AppLocalized("去掉输入栏图"))
                            .font(.system(size: 13))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(studio.color(.destructive, variant: variant))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .modifier(StudioCard(variant: variant))
    }

    private var backdropPage: some View {
        VStack(spacing: 16) {
            backdropSampleCard
            cardImageCard
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(AppLocalized("壁纸"))
                Picker(AppLocalized("用于"), selection: $wallpaperScope) {
                    ForEach(AppearanceScope.allCases) { Text($0.title).tag($0) }
                }
                .tint(studio.color(.accent, variant: variant))

                ZStack(alignment: .bottomTrailing) {
                    AppearanceBackdrop(scope: wallpaperScope)
                    Text(studio.hasWallpaper(wallpaperScope)
                         ? AppLocalized("壁纸预览") : AppLocalized("纯色背景"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(studio.color(.primaryText, scope: wallpaperScope))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(studio.color(.raised, scope: wallpaperScope).opacity(0.85), in: Capsule())
                        .padding(10)
                }
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(studio.color(.border, scope: wallpaperScope).opacity(0.4), lineWidth: 0.5)
                )

                // [K-4] Component → Button + one shared picker modifier.
                Button {
                    pickerTarget = .wallpaper
                    // [04b-2 §5] Read the effective variant HERE: a button
                    // action runs inside a real layout pass, where
                    // `UITraitCollection.current` is valid. `applyPickedPhoto`
                    // runs after an await, where it is not.
                    pickedWallpaperIsDark = studio.activeVariant == .dark
                    isPickerPresented = true
                } label: {
                    Label(studio.hasOwnWallpaper(wallpaperScope)
                          ? AppLocalized("换这张") : AppLocalized("选一张"),
                          systemImage: "photo")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)

                if wallpaperScope == .global {
                    // 全局自己谈不上"继承"，只有有图/没图两态。
                    if studio.hasWallpaper(.global) {
                        Button(AppLocalized("清除壁纸")) { studio.removeWallpaper(.global) }
                            .font(.system(size: 12))
                            .foregroundStyle(studio.color(.destructive, variant: variant))
                    }
                } else {
                    // [B28 R2-9] 「改用继承的背景」和「清除当前背景」是编程的
                    // 话，两个红按钮并排没人点得明白。改成三选一：状态一眼
                    // 可见，点哪个就变成哪个，不用猜"按了 A 对 B 做了什么"。
                    sectionTitle(AppLocalized("壁纸来源"))
                    Picker(AppLocalized("壁纸来源"), selection: wallpaperSourceBinding) {
                        Text(AppLocalized("本页图")).tag(0)
                        Text(AppLocalized("跟随全局")).tag(1)
                        Text(AppLocalized("无背景")).tag(2)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            .modifier(StudioCard(variant: variant))

            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(AppLocalized("透明度"))
                sliderRow(AppLocalized("壁纸压色"), value: $studio.wallpaperShade, range: 0...0.65)
                sliderRow(AppLocalized("卡片透明度"), value: $studio.surfaceOpacity, range: 0.35...1)
            }
            .modifier(StudioCard(variant: variant))
        }
    }

    // MARK: - 图标

    /// [B28 R7 醒醒分类] App 图标原来在行为页——图标归图标页。
    private var appIconCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(AppLocalized("App 图标"))
            if UIApplication.shared.supportsAlternateIcons {
                ForEach(studioIconOptions) { option in
                    Button {
                        guard appIconMode != option.id else { return }
                        let previous = appIconMode
                        appIconMode = option.id
                        // [B28 R2-5] completion 以前整个忽略 —— 系统拒了、
                        // 资源缺失，界面照样打勾，用户以为换了。失败就
                        // 把勾退回去并说一声。
                        UIApplication.shared.setAlternateIconName(option.iconName) { error in
                            DispatchQueue.main.async {
                                guard let error else { return }
                                appIconMode = previous
                                appearanceLog.warning("setAlternateIconName failed: \(error.localizedDescription)")
                                MinisToast.show(AppLocalized("Couldn't change the app icon."),
                                                systemImage: "exclamationmark.triangle.fill")
                            }
                        }
                    } label: {
                        HStack(spacing: 14) {
                            if let img = UIImage(named: option.imageName) {
                                Image(uiImage: img)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 52, height: 52)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(studio.color(.border, variant: variant).opacity(0.4),
                                                    lineWidth: 0.5)
                                    )
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(LocalizedStringKey(option.title))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(studio.color(.primaryText, variant: variant))
                                Text(LocalizedStringKey(option.subtitle))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(studio.color(.secondaryText, variant: variant))
                            }
                            Spacer()
                            if appIconMode == option.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(studio.color(.accent, variant: variant))
                                    .font(.system(size: 16))
                            }
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text(AppLocalized("这台设备不支持换图标。"))
                    .font(.system(size: 11))
                    .foregroundStyle(studio.color(.secondaryText, variant: variant))
            }
        }
        .modifier(StudioCard(variant: variant))
    }

    private var iconsPage: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(AppLocalized("设置行图标"))
                ForEach(QuietIconSlot.allCases) { slot in
                    HStack(spacing: 13) {
                        QuietAppIcon(id: slot.id, systemName: slot.systemName, size: 27)
                        Text(slot.title)
                            .font(.system(size: 13))
                            .foregroundStyle(studio.color(.primaryText, variant: variant))
                        Spacer()
                        Button {
                            // [K-4] Which row was tapped has to be remembered
                            // BEFORE the picker opens: the binding the old
                            // component used wrote it on selection, which is
                            // the reason a cancelled picker left a stale slot.
                            iconPickSlot = slot
                            pickerTarget = .icon
                            isPickerPresented = true
                        } label: {
                            Text(studio.customIcon(for: slot.id) == nil
                                 ? AppLocalized("上传") : AppLocalized("更换"))
                                .font(.system(size: 12))
                                .foregroundStyle(studio.color(.accent, variant: variant))
                        }
                        .buttonStyle(.plain)
                        if studio.customIcon(for: slot.id) != nil {
                            Button(AppLocalized("Revert")) { studio.removeIcon(for: slot.id) }
                                .font(.system(size: 11))
                                .foregroundStyle(studio.color(.destructive, variant: variant))
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .modifier(StudioCard(variant: variant))

            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(AppLocalized("分类图标"))
                ForEach(AppearanceThemePack.categoryKeys, id: \.self) { key in
                    categoryRow(key)
                }
            }
            .modifier(StudioCard(variant: variant))

            appIconCard
        }
    }

    /// [B28 R2-6] 「分类图标」原来把 `code`/`writing` 这种内部 key 直接印
    /// 给用户看。词表在九语种表里；查不到的 key 原样显示，不编。
    private func categoryDisplayName(_ key: String) -> String {
        let labels: [String: String] = [
            "code": "编程", "writing": "写作", "research": "调研", "analysis": "分析",
            "creative": "创作", "chat": "闲聊", "math": "数学", "translation": "翻译",
            "health": "健康", "finance": "金融", "travel": "旅行", "education": "教育",
            "design": "设计", "productivity": "效率", "support": "客服", "other": "其他",
        ]
        guard let label = labels[key] else { return key }
        // AppLocalized 只吃编译期字面量（String.LocalizationValue 宏）；
        // 运行时 key 查表走 String(localized:)，同一个 bundle、同一张表。
        return String(localized: String.LocalizationValue(label), bundle: AppBundle.current)
    }

    private func categoryRow(_ key: String) -> some View {
        let themedSymbol = MinisThemeList.categoryIcon(for: key).systemName
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 11) {
                Image(systemName: QuietAppIcon.filledSymbolName(themedSymbol))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.black)
                    .frame(width: 23, height: 23)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 6.5, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                            .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
                    )
                Text(categoryDisplayName(key))
                    .font(.system(size: 12.5))
                    .foregroundStyle(studio.color(.primaryText, variant: variant))
                Spacer()
                Button {
                    categoryImageKey = key
                    pickerTarget = .categoryImage
                    isPickerPresented = true
                } label: {
                    Text(studio.categoryImage(for: key) == nil
                         ? AppLocalized("贴图") : AppLocalized("换图"))
                        .font(.system(size: 11))
                        .foregroundStyle(studio.color(.accent, variant: variant))
                }
                .buttonStyle(.plain)
                if studio.categoryImage(for: key) != nil {
                    Button(AppLocalized("Revert")) { studio.removeCategoryImage(for: key) }
                        .font(.system(size: 10))
                        .foregroundStyle(studio.color(.destructive, variant: variant))
                }
            }
            HStack(spacing: 9) {
                TextField(AppLocalized("SF 名，空着就是默认"), text: categorySymbolBinding(key))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(studio.color(.secondaryText, variant: variant))
                // [B28 R6] 原来这里摆着 disabled 的 ColorPicker —— 看着能点、
                // 点了没反应、也不说为什么：假控件。categoryColors 字段已废
                // （B-5），废字段的界面一并摘掉，不留僵尸。
            }
        }
        .padding(.vertical, 5)
    }

    // MARK: - 主题库

    private var libraryPage: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(AppLocalized("存这一套"))
                Button {
                    // [B28 R2-11] 和顶栏「存」同一个弹窗。
                    inputName = ""
                    inputDialog = .save
                } label: {
                    Text(AppLocalized("存进主题库"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(studio.color(.accent, variant: variant))
                }
                .buttonStyle(.plain)
                // [B28 R2-3] 以前存满 40 会静默删最旧 —— footer 有义务说清。
                Text(AppLocalized("另存一份，不会冲掉正在用的。存满四十套会先要你删一套。"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(studio.color(.secondaryText, variant: variant).opacity(0.75))
            }
            .modifier(StudioCard(variant: variant))

            undoDeleteBanner

            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(AppLocalized("主题库"))
                let saved = studio.savedThemes()
                if saved.isEmpty {
                    Text(AppLocalized("还没有存过的主题。"))
                        .font(.system(size: 12))
                        .foregroundStyle(studio.color(.secondaryText, variant: variant))
                } else {
                    ForEach(saved) { item in
                        HStack(spacing: 11) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(item.name)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(studio.color(.primaryText, variant: variant))
                                    // [B28 R2-10] 「现在用的是哪套」以前模型里
                                    // 没有这个状态。三态全部由真实状态推导：
                                    // 是它且没动过 = 使用中；动过 = 明说已改。
                                    let match = studio.savedThemeMatch(id: item.id)
                                    if match == .inUse {
                                        Text(AppLocalized("In use"))
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(studio.color(.accent, variant: variant))
                                    } else if match == .modifiedSince {
                                        Text(AppLocalized("In use · modified"))
                                            .font(.system(size: 10))
                                            .foregroundStyle(studio.color(.secondaryText, variant: variant))
                                    }
                                }
                                Text(item.userStyleTitle + " · " + item.assistantStyleTitle)
                                    .font(.system(size: 10))
                                    .foregroundStyle(studio.color(.secondaryText, variant: variant).opacity(0.75))
                            }
                            Spacer()
                            Button(AppLocalized("Apply")) {
                                // [B28 D-3] 点了「应用」原来什么都不发生，用户
                                // 以为没生效。现在成功/失败都有一句话。
                                if let warnings = studio.applySavedTheme(id: item.id) {
                                    MinisToast.show(String(format: AppLocalized("Applied “%@”"), item.name))
                                    // [B28 R3-5] 图没落住就明说哪张，不装全好。
                                    if !warnings.isEmpty {
                                        MinisToast.show(String(format: AppLocalized("没接住：%@"),
                                        warnings.map { Self.themeImageName($0) }
                                                .joined(separator: "、")),
                                        systemImage: "exclamationmark.triangle.fill")
                                    }
                                } else {
                                    MinisToast.show(AppLocalized("Couldn't apply this theme."),
                                                    systemImage: "exclamationmark.triangle.fill")
                                }
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(studio.color(.accent, variant: variant))
                            // [B28 B-2] 删改成先弹确认，确认后还能撤销。
                            Button(AppLocalized("删")) { pendingDeleteTheme = item }
                                .font(.system(size: 11))
                                .foregroundStyle(studio.color(.destructive, variant: variant))
                        }
                        .padding(.vertical, 5)
                        // [B28 R2-8] 长按出菜单：重命名不用再删了重存。
                        // 行上不加第三个按钮 —— 两个已经够挤，重命名是低频操作。
                        .contextMenu {
                            Button {
                                inputName = item.name
                                inputDialog = .rename(item)
                            } label: {
                                Label(AppLocalized("Rename"), systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                pendingDeleteTheme = item
                            } label: {
                                Label(AppLocalized("删"), systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .modifier(StudioCard(variant: variant))

            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(AppLocalized("导出导入"))

                // [10-18 醒醒 第五轮] 吃 ST 小酒馆的主题包。
                //
                // 能吃的：39 个颜色字段、头像形状、消息形态、行高、字距、
                // 圆角（从 custom_css 抽众数）。
                // 吃不了的：CSS 里的伪元素、外链装饰图、按钮换图——那些是
                // 网页的能力，原生视图接不住。
                Button {
                    showSTImporter = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 12, weight: .medium))
                        Text(AppLocalized("导入 ST 小酒馆主题包"))
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(studio.color(.accent, variant: variant))
                }
                .buttonStyle(.plain)
                Text(AppLocalized("选一个 ST 的主题 JSON。颜色、头像形状、消息形态、行高、字距会一起换掉。CSS 里的装饰图接不了。"))
                    .font(.system(size: 10.5))
                    .lineSpacing(1.5)
                    .foregroundStyle(studio.color(.secondaryText, variant: variant).opacity(0.8))

                hairline.padding(.leading, 0).padding(.vertical, 4)

                Button(AppLocalized("导出到剪贴板")) { exportPackToClipboard() }
                    .font(.system(size: 13))
                    .foregroundStyle(studio.color(.accent, variant: variant))
                Button(AppLocalized("从剪贴板贴上")) { importPackFromClipboard() }
                    .font(.system(size: 13))
                    .foregroundStyle(studio.color(.accent, variant: variant))
                Button(AppLocalized("恢复默认主题包")) { showResetConfirm = true }
                    .font(.system(size: 12))
                    .foregroundStyle(studio.color(.destructive, variant: variant))
                if studio.canUndoThemeReset {
                    Button(AppLocalized("撤销上一次恢复")) { _ = studio.undoThemeReset() }
                        .font(.system(size: 12))
                        .foregroundStyle(studio.color(.secondaryText, variant: variant))
                }
            }
            .modifier(StudioCard(variant: variant))
        }
    }

    // MARK: - 行为
    //
    // 这些原来在 `AppearanceSettingsView` 里。搬过来之后那一页只留一个入口。
    // 语言统一走 AppLocalized。

    /// [B28 R7 醒醒分类] thinking 字号原来挂在「图标」页——字号归字号。
    /// 现在跟着正文/App 字号一起住在行为页的字号区。
    private var thinkingFontCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(AppLocalized("thinking 字号"))
            sliderRow(AppLocalized("标题字"), value: thinkingTitleSizeBinding, range: 10...22, unit: "")
            sliderRow(AppLocalized("正文字"), value: thinkingBodySizeBinding, range: 10...22, unit: "")
        }
        .modifier(StudioCard(variant: variant))
    }

    private var behaviourPage: some View {
        VStack(spacing: 16) {
            // 明暗：原来在外观页有一份「跟随系统/浅色/深色」，跟这里的重复，删了那份。
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(AppLocalized("明暗"))
                Picker("", selection: $appearanceMode) {
                    Text(AppLocalized("Follows system")).tag(0)
                    Text(AppLocalized("Light")).tag(1)
                    Text(AppLocalized("Dark")).tag(2)
                }
                .pickerStyle(.segmented)
                Text(AppLocalized("覆盖系统外观。选「跟随系统」就跟着手机走。"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(studio.color(.secondaryText, variant: variant).opacity(0.8))
            }
            .modifier(StudioCard(variant: variant))

            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(AppLocalized("Launch Session"))
                Picker("", selection: $launchScreen) {
                    Text(AppLocalized("Auto")).tag(0)
                    Text(AppLocalized("Last Session")).tag(1)
                    Text(AppLocalized("新会话")).tag(2)
                    Text(AppLocalized("首页")).tag(3)
                }
                .pickerStyle(.menu)
                .tint(studio.color(.accent, variant: variant))
                Text(AppLocalized("打开 App 时显示什么。「自动」会在上次会话超过 15 分钟时开新会话。"))
                    .font(.system(size: 10.5))
                    .lineSpacing(1.5)
                    .foregroundStyle(studio.color(.secondaryText, variant: variant).opacity(0.8))
            }
            .modifier(StudioCard(variant: variant))

            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(AppLocalized("字号"))
                FontScaleRow(label: AppLocalized("Chat Input"), level: $fontSettings.chatInputScale)
                FontScaleRow(label: AppLocalized("Message Text"), level: $fontSettings.messageBaseScale)
                FontScaleRow(label: AppLocalized("App Base"), level: $fontSettings.appBaseScale)
                if fontSettings.isModified {
                    Button(AppLocalized("恢复默认字号")) { fontSettings.resetToDefaults() }
                        .font(.system(size: 12))
                        .foregroundStyle(studio.color(.destructive, variant: variant))
                }
                Text(AppLocalized("分别缩放聊天输入框、消息正文、以及其余界面文字。改完立刻生效。"))
                    .font(.system(size: 10.5))
                    .lineSpacing(1.5)
                    .foregroundStyle(studio.color(.secondaryText, variant: variant).opacity(0.8))
            }
            .modifier(StudioCard(variant: variant))

            thinkingFontCard

            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(AppLocalized("Input"))
                Picker(AppLocalized("Return Key"), selection: $returnKeyBehavior) {
                    Text(AppLocalized("Newline")).tag(0)
                    Text(AppLocalized("发送")).tag(1)
                }
                .pickerStyle(.segmented)
                Text(AppLocalized("回车是换行还是发送。硬件键盘的 Shift+回车 永远是换行。"))
                    .font(.system(size: 10.5))
                    .lineSpacing(1.5)
                    .foregroundStyle(studio.color(.secondaryText, variant: variant).opacity(0.8))

                hairline.padding(.leading, 0).padding(.vertical, 4)

                Toggle(AppLocalized("Auto-Focus Input After Reply"), isOn: $autoFocusAfterReply)
                    .tint(studio.color(.accent, variant: variant))
                Text(AppLocalized("模型回复完自动弹出键盘，方便接着问。不想被键盘打断就关掉。"))
                    .font(.system(size: 10.5))
                    .lineSpacing(1.5)
                    .foregroundStyle(studio.color(.secondaryText, variant: variant).opacity(0.8))
            }
            .modifier(StudioCard(variant: variant))

            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(AppLocalized("聊天行为"))
                Toggle(AppLocalized("Expand Thinking While Streaming"), isOn: $autoExpandThinking)
                    .tint(studio.color(.accent, variant: variant))
                Text(AppLocalized("开着时，模型推理中的思考块自动展开，完成后收起。关掉就保持折叠，点一下才看。"))
                    .font(.system(size: 10.5))
                    .lineSpacing(1.5)
                    .foregroundStyle(studio.color(.secondaryText, variant: variant).opacity(0.8))

                hairline.padding(.leading, 0).padding(.vertical, 4)

                Toggle(AppLocalized("Auto-Grouping"), isOn: autoGroupingBinding)
                    .tint(studio.color(.accent, variant: variant))
                Text(AppLocalized("首次生成会话标题时，顺便归进匹配的分组。每个会话只做一次，只用你已经建好的分组。"))
                    .font(.system(size: 10.5))
                    .lineSpacing(1.5)
                    .foregroundStyle(studio.color(.secondaryText, variant: variant).opacity(0.8))

                hairline.padding(.leading, 0).padding(.vertical, 4)

                Toggle(AppLocalized("Keep Screen Awake"), isOn: $keepScreenAwakeDuringTasks)
                    .tint(studio.color(.accent, variant: variant))
                Text(AppLocalized("有会话在跑任务时不熄屏。会更费电。"))
                    .font(.system(size: 10.5))
                    .lineSpacing(1.5)
                    .foregroundStyle(studio.color(.secondaryText, variant: variant).opacity(0.8))
            }
            .modifier(StudioCard(variant: variant))

            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(AppLocalized("选项背景"))
                HStack(spacing: 13) {
                    ColorPicker("", selection: rowBackgroundBinding, supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(studio.currentThemePack().rowBackgroundHex == nil
                             ? AppLocalized("跟随卡片色") : AppLocalized("Custom"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(studio.color(.primaryText, variant: variant))
                        Text(AppLocalized("设置页每一行的底色。不选就跟卡片走。"))
                            .font(.system(size: 10))
                            .foregroundStyle(studio.color(.secondaryText, variant: variant).opacity(0.75))
                    }
                    Spacer()
                    if studio.currentThemePack().rowBackgroundHex != nil {
                        Button(AppLocalized("Revert")) { studio.setRowBackground(nil) }
                            .font(.system(size: 11))
                            .foregroundStyle(studio.color(.destructive, variant: variant))
                    }
                }
            }
            .modifier(StudioCard(variant: variant))


            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(AppLocalized("Language"))
                ForEach(studioLanguages) { lang in
                    Button {
                        // 写 reopen 标记再翻语言——根视图会因 .id(appLanguage)
                        // 整个重建，不记下来就会掉回设置首页。
                        UserDefaults.standard.set("appearance", forKey: "pendingSettingsReopen")
                        ViewModelCache.shared.suspendAllForTreeRemount()
                        appLanguage = lang.id
                        Bundle.setLanguage(lang.id.isEmpty ? nil : lang.id)
                    } label: {
                        HStack(spacing: 12) {
                            if !lang.flag.isEmpty {
                                Text(lang.flag).font(.system(size: 17))
                            } else {
                                Image(systemName: "globe")
                                    .font(.system(size: 14))
                                    .foregroundStyle(studio.color(.secondaryText, variant: variant))
                                    .frame(width: 26)
                            }
                            Text(lang.name)
                                .font(.system(size: 13))
                                .foregroundStyle(studio.color(.primaryText, variant: variant))
                            Spacer()
                            if appLanguage == lang.id {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(studio.color(.accent, variant: variant))
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .modifier(StudioCard(variant: variant))
        }
    }

    private var autoGroupingBinding: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: "autoGroupingEnabled") },
            set: { UserDefaults.standard.set($0, forKey: "autoGroupingEnabled") }
        )
    }

    // MARK: - 底部导航

    // MARK: - 零件

    private func sectionTitle(_ text: String) -> some View {
        // [B28 R3] 外面 List 的组头是灰字小标，里面原来是黑粗体 —— 同一页
        // 两套话。统一成外层那种。
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .tracking(0.2)
            .foregroundStyle(studio.color(.secondaryText, variant: variant))
    }

    private func sliderRow(_ title: String, value: Binding<Double>,
                           range: ClosedRange<Double>, unit: String = "%") -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(studio.color(.primaryText, variant: variant))
                Spacer()
                Text(unit == "%" ? "\(Int(value.wrappedValue * 100))%" : "\(Int(value.wrappedValue))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(studio.color(.secondaryText, variant: variant).opacity(0.8))
            }
            Slider(value: value, in: range)
                .tint(studio.color(.accent, variant: variant))
        }
    }

    // MARK: - Binding

    private var userStyleBinding: Binding<AppearanceBubbleStyle> {
        Binding(get: { studio.currentThemePack().userStyle },
                set: { studio.setBubbleStyle($0, user: true) })
    }
    private var assistantStyleBinding: Binding<AppearanceBubbleStyle> {
        Binding(get: { studio.currentThemePack().assistantStyle },
                set: { studio.setBubbleStyle($0, user: false) })
    }
    private var inputBarStyleBinding: Binding<AppearanceBubbleStyle> {
        Binding(get: { AppearanceBubbleStyle.parse(studio.currentThemePack().inputBarStyle) },
                set: { studio.setInputBarStyle($0) })
    }
    private var fontFamilyBinding: Binding<AppearanceFontFamily> {
        Binding(get: { AppearanceFontFamily.parse(studio.currentThemePack().fontFamily) },
                set: { studio.setFontFamily($0) })
    }
    private var listIconShapeBinding: Binding<AppearanceListIconShape> {
        Binding(get: { AppearanceListIconShape.parse(studio.currentThemePack().listIconShape) },
                set: { studio.setListIconShape($0) })
    }
    private var inputBarRadiusBinding: Binding<Double> {
        Binding(get: { studio.currentThemePack().inputBarRadius },
                set: { studio.setInputBarRadius($0) })
    }
    private var thinkingCardOpacityBinding: Binding<Double> {
        Binding(get: { studio.currentThemePack().thinkingCardImageOpacity },
                set: { studio.setThinkingCardImageOpacity($0) })
    }
    private var inputBarOpacityBinding: Binding<Double> {
        Binding(get: { studio.currentThemePack().inputBarImageOpacity },
                set: { studio.setInputBarImageOpacity($0) })
    }
    private var thinkingTitleSizeBinding: Binding<Double> {
        Binding(get: { studio.currentThemePack().thinkingTitleSize },
                set: { studio.setThinkingFont(title: $0) })
    }
    private var thinkingBodySizeBinding: Binding<Double> {
        Binding(get: { studio.currentThemePack().thinkingBodySize },
                set: { studio.setThinkingFont(body: $0) })
    }
    private var avatarShapeBinding: Binding<AppearanceAvatarShape> {
        Binding(get: { AppearanceAvatarShape.parse(studio.currentThemePack().avatarShape) },
                set: { studio.setAvatarShape($0) })
    }
    private var chatDisplayBinding: Binding<AppearanceChatDisplay> {
        Binding(get: { AppearanceChatDisplay.parse(studio.currentThemePack().chatDisplay) },
                set: { studio.setChatDisplay($0) })
    }
    private var lineHeightBinding: Binding<Double> {
        Binding(get: { studio.currentThemePack().lineHeight },
                set: { studio.setLineHeight($0) })
    }
    private var letterSpacingBinding: Binding<Double> {
        Binding(get: { studio.currentThemePack().letterSpacing },
                set: { studio.setLetterSpacing($0) })
    }

    // MARK: [10-20 醒醒] 代码块

    private var codeBlockCollapseLinesBinding: Binding<Int> {
        Binding(get: { studio.currentThemePack().codeBlockCollapseLines },
                set: { studio.setCodeBlockCollapseLines($0) })
    }

    // MARK: [10-19 醒醒] 视觉小说模式

    private var novelModeBinding: Binding<AppearanceNovelMode> {
        Binding(get: { AppearanceNovelMode.parse(studio.currentThemePack().novelMode) },
                set: { studio.setNovelMode($0) })
    }

    /// 视觉小说模式卡。
    ///
    /// 立绘是照 ST 的 `waifuMode` 做的：全屏角色图 + 聊天窗压底部。
    /// 对话框是 Galgame 那种：底部半透明框，一次一句，点一下往下推。
    @ViewBuilder
    private func novelModeCard(variant: AppearanceVariant) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(AppLocalized("视觉小说"))
            Picker("", selection: novelModeBinding) {
                ForEach(AppearanceNovelMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Text(AppearanceNovelMode.parse(studio.currentThemePack().novelMode).hint)
                .font(.system(size: 10.5))
                .lineSpacing(1.5)
                .foregroundStyle(studio.color(.secondaryText, variant: variant).opacity(0.8))

            // 只有立绘和对话框模式才用得上角色图
            if novelModeBinding.wrappedValue != .off {
                hairline.padding(.leading, 0).padding(.vertical, 2)

                HStack(spacing: 12) {
                    if let img = studio.characterArtImage() {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 52, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(studio.color(.mutedSurface, variant: variant))
                            .frame(width: 52, height: 72)
                            .overlay {
                                Image(systemName: "person.crop.rectangle")
                                    .font(.system(size: 20))
                                    .foregroundStyle(studio.color(.secondaryText, variant: variant).opacity(0.6))
                            }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("人设立绘")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(studio.color(.primaryText, variant: variant))
                        Text("竖图最好，底部对齐铺满。不传就用头像放大。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(studio.color(.secondaryText, variant: variant).opacity(0.8))
                    }

                    Spacer()

                    Button {
                        pickerTarget = .characterArt
                        isPickerPresented = true
                    } label: {
                        Text(studio.hasCharacterArt ? AppLocalized("Change") : AppLocalized("Select"))
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                }

                if studio.hasCharacterArt {
                    Button(role: .destructive) {
                        studio.removeCharacterArt()
                    } label: {
                        Text(AppLocalized("移除立绘"))
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .modifier(StudioCard(variant: variant))
    }
    private var rowBackgroundBinding: Binding<Color> {
        Binding(
            get: {
                let hex = studio.currentThemePack().rowBackgroundHex
                return hex.map { Color(hex: $0) } ?? studio.color(.surface, scope: .settings)
            },
            set: { studio.setRowBackground($0.hexString) }
        )
    }
    private func categorySymbolBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { studio.currentThemePack().categoryIcons[key] ?? "" },
            set: { studio.setCategorySymbol($0, for: key) }
        )
    }
    private func categoryColorBinding(_ key: String) -> Binding<Color> {
        Binding(
            get: {
                let hex = studio.currentThemePack().categoryColors[key]
                return hex.map { Color(hex: $0) } ?? studio.color(.accent, variant: variant)
            },
            set: { studio.setCategoryColor($0, for: key) }
        )
    }

    // MARK: - 导入导出

    private func exportPackToClipboard() {
        let pack = studio.exportThemePack(includeWallpaper: true)
        guard let data = try? JSONSerialization.data(withJSONObject: pack.asJSONObject(),
                                                    options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            fail(AppLocalized("主题包写不出来。"))
            return
        }
        UIPasteboard.general.string = text
    }

    private func importPackFromClipboard() {
        guard let text = UIPasteboard.general.string,
              let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fail(AppLocalized("剪贴板里没有能用的主题包。"))
            return
        }
        do {
            let pack = try AppearanceThemePack.decode(obj, merging: studio.currentThemePack())
            studio.applyThemePack(pack)
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// 吃 ST 小酒馆的主题包。
    ///
    /// 流程：读文件 → 解析 39 字段 + 从 custom_css 抽几何 → 应用 → 报告
    /// 哪些东西没接住。**不静默吞警告**——她得知道装饰图没进来。
    private func importSillyTavern(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            pendingSTOutcome = .failure(AppLocalized("这个文件读不出来。"))
            return
        }
        do {
            let imported = try SillyTavernTheme.parse(data)
            studio.applySillyTavern(imported)

            var notes: [String] = [String(format: AppLocalized("已应用「%@」。"), imported.name)]
            if !imported.warnings.isEmpty {
                notes.append(contentsOf: imported.warnings)
            }
            notes.append(AppLocalized("CSS 里的装饰图、伪元素、按钮换图原生接不了，这些没有导入。"))
            pendingSTOutcome = .success(notes)
        } catch {
            pendingSTOutcome = .failure(error.localizedDescription)
        }
    }
}

// MARK: - 底部导航项

// MARK: - 页面
//
// [10-19 醒醒] 原来底部挤了七个 tab（截图里 9pt 字挤成一排），页内容又是
// `ScrollView` + 自绘卡片堆出来的，看着像安卓。改成 iOS 设置页的做法：
// 根页是一个 `List`，每个分区用 `NavigationLink` 进子页。
enum AppearanceStudioPage: String, CaseIterable, Identifiable {
    case palette, bubbles, backdrop, icons, library, behaviour
    var id: String { rawValue }
    var title: String {
        switch self {
        case .palette: return AppLocalized("配色")
        case .bubbles: return AppLocalized("气泡与文字")
        case .backdrop: return AppLocalized("背景")
        case .icons: return AppLocalized("图标")
        case .library: return AppLocalized("主题库")
        case .behaviour: return AppLocalized("行为")
        }
    }
    var symbol: String {
        switch self {
        case .palette: return "paintpalette.fill"
        case .bubbles: return "bubble.left.and.bubble.right.fill"
        case .backdrop: return "photo.fill"
        case .icons: return "square.grid.2x2.fill"
        case .library: return "books.vertical.fill"
        case .behaviour: return "switch.2"
        }
    }
    /// 子页标题下的一句话说明，跟系统设置里那些 footer 一个用法。
    ///
    /// [B28 E-1] 这里原来返回裸中文，而调用点是 `Text(item.subtitle)` ——
    /// `Text(String)` 不查表，所以这七条在九语种里只有 en/zh-Hans 两条有键、
    /// 其他语言全显示中文。现在走 AppLocalized，键是英文。
    var subtitle: String {
        switch self {
        case .palette: return AppLocalized("Colors, contrast, roll a palette")
        case .bubbles: return AppLocalized("Bubble shape, message style, visual novel")
        case .backdrop: return AppLocalized("Wallpaper & shade")
        case .icons: return AppLocalized("App icon and list icons")
        case .library: return AppLocalized("Save, import and export themes")
        case .behaviour: return AppLocalized("Language, text size, input")
        }
    }
}

// MARK: - 卡片样式
//
// 统一一处：18pt 圆角 + surface 底 + 0.5pt 发丝线 + 软阴影。
// 上一版这四行在 12 个地方重复。

private struct StudioCard: ViewModifier {
    let variant: AppearanceVariant
    @ObservedObject private var studio = AppearanceStudio.shared

    func body(content: Content) -> some View {
        // [10-19 醒醒] 她说"像安卓"。两个原因：
        // 1. 圆角 18pt + 软阴影 —— iOS 的分组卡片是 10-12pt 圆角、**没有**
        //    投影，靠底色和留白分层。
        // 2. 卡片之间 20pt 间距 —— iOS 的分组内是 0 间距、组与组之间才留白。
        //    这里保持卡片独立，但把圆角和阴影收成系统样子。
        content
            .padding(14)
            .background(studio.color(.surface, variant: variant).opacity(studio.surfaceOpacity),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(studio.color(.border, variant: variant).opacity(0.28), lineWidth: 0.5)
            )
    }
}

// MARK: - 字号滑杆

private struct FontScaleRow: View {
    let label: String
    @Binding var level: FontScaleLevel

    private static let cases = FontScaleLevel.allCases

    private var currentIndex: Int {
        Self.cases.firstIndex(of: level) ?? 3
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(MinisTheme.primaryText)
            HStack(spacing: 12) {
                Button {
                    let idx = currentIndex - 1
                    if idx >= 0 { level = Self.cases[idx] }
                } label: {
                    Text("A")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(MinisTheme.secondaryText)
                }
                .buttonStyle(.plain)

                SteppedSlider(value: currentIndex, steps: Self.cases.count) { newIndex in
                    if newIndex >= 0, newIndex < Self.cases.count {
                        level = Self.cases[newIndex]
                    }
                }

                Button {
                    let idx = currentIndex + 1
                    if idx < Self.cases.count { level = Self.cases[idx] }
                } label: {
                    Text("A")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(MinisTheme.secondaryText)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - App 图标 / 语言选项
//
// 这两组原来在 ContentView.swift 里，是 private 的，跟这里同名不冲突。

/// 分档滑杆。`ContentView.swift` 里那个是 private，这里用不了，重写一份。
/// 逻辑一样：拖动按档位吸附，刻度点跟着填色。
private struct SteppedSlider: View {
    let value: Int
    let steps: Int
    let onChanged: (Int) -> Void

    private let trackHeight: CGFloat = 4
    private let thumbSize: CGFloat = 22
    private let tickSize: CGFloat = 6

    @State private var dragValue: Int?

    private var displayValue: Int { dragValue ?? value }

    var body: some View {
        GeometryReader { geo in
            let totalW = geo.size.width
            let midY = geo.size.height / 2
            let maxStep = CGFloat(max(1, steps - 1))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppearanceStudio.shared.color(.mutedSurface, scope: .settings))
                    .frame(height: trackHeight)
                    .position(x: totalW / 2, y: midY)

                let fillW = totalW * CGFloat(displayValue) / maxStep
                Capsule()
                    .fill(MinisTheme.accent)
                    .frame(width: fillW, height: trackHeight)
                    .position(x: fillW / 2, y: midY)

                ForEach(0..<steps, id: \.self) { i in
                    let x = totalW * CGFloat(i) / maxStep
                    Circle()
                        .fill(i <= displayValue
                              ? MinisTheme.accent
                              : AppearanceStudio.shared.color(.mutedSurface, scope: .settings))
                        .frame(width: tickSize, height: tickSize)
                        .position(x: x, y: midY)
                }

                let thumbX = totalW * CGFloat(displayValue) / maxStep
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    .frame(width: thumbSize, height: thumbSize)
                    .position(x: thumbX, y: midY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let step = stepFromX(drag.location.x, width: totalW)
                        if step != dragValue { dragValue = step }
                    }
                    .onEnded { drag in
                        let step = stepFromX(drag.location.x, width: totalW)
                        dragValue = nil
                        onChanged(step)
                    }
            )
        }
        .frame(height: thumbSize + 8)
    }

    private func stepFromX(_ x: CGFloat, width: CGFloat) -> Int {
        guard width > 0, steps > 1 else { return 0 }
        let fraction = x / width
        let clamped = min(max(fraction, 0), 1)
        return Int((clamped * CGFloat(steps - 1)).rounded())
    }
}

private struct StudioIconOption: Identifiable {
    let id: Int
    let title: String
    let subtitle: String
    let iconName: String?
    let imageName: String
}

private let studioIconOptions: [StudioIconOption] = [
    StudioIconOption(id: 0, title: "自动", subtitle: "跟随系统",
                     iconName: nil, imageName: "AlternateIcons/AppIcon-Light"),
    StudioIconOption(id: 1, title: "浅色", subtitle: "始终浅色",
                     iconName: "AppIcon-Light", imageName: "AlternateIcons/AppIcon-Light"),
    StudioIconOption(id: 2, title: "深色", subtitle: "始终深色",
                     iconName: "AppIcon-Dark", imageName: "AlternateIcons/AppIcon-Dark"),
    StudioIconOption(id: 3, title: "浅色（旧）", subtitle: "经典浅色图标",
                     iconName: "AppIcon-LegacyLight", imageName: "AlternateIcons/AppIcon-LegacyLight"),
    StudioIconOption(id: 4, title: "深色（旧）", subtitle: "经典深色图标",
                     iconName: "AppIcon-LegacyDark", imageName: "AlternateIcons/AppIcon-LegacyDark"),
]

private struct StudioLanguageOption: Identifiable {
    let id: String
    let name: String
    let flag: String
}

private let studioLanguages: [StudioLanguageOption] = [
    StudioLanguageOption(id: "",        name: "跟随系统",  flag: ""),
    StudioLanguageOption(id: "en",      name: "English",  flag: "🇺🇸"),
    StudioLanguageOption(id: "zh-Hans", name: "简体中文",  flag: "🇨🇳"),
    StudioLanguageOption(id: "zh-Hant", name: "繁體中文",  flag: "🇭🇰"),
    StudioLanguageOption(id: "ja",      name: "日本語",    flag: "🇯🇵"),
    StudioLanguageOption(id: "ko",      name: "한국어",    flag: "🇰🇷"),
    StudioLanguageOption(id: "es",      name: "Español",  flag: "🇪🇸"),
    StudioLanguageOption(id: "fr",      name: "Français", flag: "🇫🇷"),
    StudioLanguageOption(id: "de",      name: "Deutsch",  flag: "🇩🇪"),
    StudioLanguageOption(id: "ru",      name: "Русский",  flag: "🇷🇺"),
]

// MARK: - 真组件预览
//
// 全部用真组件：PersonAvatarView 真头像、AppearanceBackdrop 真壁纸、
// MinisBubbleShape 真气泡、真输入框圆角、真状态色。

