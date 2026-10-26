import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Play Hub（播放）
//
// [T-playhub-rebuild 10-15 醒醒] v2：五格胶囊开关（图片/视频/音频/文件/进化），
// 点什么下面就换什么；数据真接——会话桶、共享夹、媒体库、rootfs 里的文件全部
// 扫进来分桶展示，不再是空占位。
//   • 头像/名字/背景仍可编辑（v1 保留）；
//   • 图标仍是统一模板：白底圆角 + 实心圆润矢量图形；
//   • 颜色全部走外观变量（canvas/surface/raised/mutedSurface/accent/border），
//     不写死任何色值。

struct PlayHubView: View {

    enum Tab: String, CaseIterable, Identifiable {
        case images, videos, audio, files, evolution
        var id: String { rawValue }
        var title: String {
            switch self {
            case .images: return "图片"
            case .videos: return "视频"
            case .audio: return "音频"
            case .files: return "文件"
            case .evolution: return "进化"
            }
        }
        var systemImage: String {
            switch self {
            case .images: return "photo.fill"
            case .videos: return "video.fill"
            case .audio: return "waveform"
            case .files: return "doc.fill"
            case .evolution: return "sparkles"
            }
        }
        var emptyText: String {
            switch self {
            case .images: return "还没有攒下图片——聊天里收发的图会聚到这里。"
            case .videos: return "还没有视频——发过的片段会聚到这里。"
            case .audio: return "还没有声音——语音和朗读会聚到这里。"
            case .files: return "还没有文件——资料和文档会聚到这里。"
            case .evolution: return ""
            }
        }
    }

    @ObservedObject private var studio = AppearanceStudio.shared
    @State private var selection: Tab = .images
    @State private var scanResult: PlayHubMediaScanner.Result?
    @State private var scanning = false

    // 预览/播放
    @State private var gallery: GalleryPresentation?
    @State private var playingVideo: URL?
    @State private var playingAudio: URL?
    @State private var previewFile: URL?

    // 头像 / 名字 / 背景（v1 保留）
    @State private var backgroundImage: UIImage?
    @State private var soulIcon: String = ""
    @State private var displayName: String = ""
    @State private var backgroundItem: PhotosPickerItem?
    @State private var avatarItem: PhotosPickerItem?
    @State private var showNameEditor = false
    @State private var nameDraft = ""

    // 上传 / 删除（P1-2 / P1-3）
    @State private var uploadPicks: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    /// [04b-2 §3] A copy-mode picker presented as a sheet, not SwiftUI's
    /// `.fileImporter`. `.fileImporter` opens in place and needs a FileProvider
    /// security-scoped grant, which a resigned build is never given: the picker
    /// opens, the user picks a file, "Open" does nothing and no error arrives.
    /// `DocumentCopyPicker` copies into tmp and returns a plain file URL.
    @State private var showFilePicker = false
    @State private var importing = false
    @State private var importError: String?
    @State private var showDeleteConfirm = false
    @State private var collapsedCategories = Set<FileCategory>()

    // 批量删除（P1-3 打回：长按勾选，多选后一次确认）
    @State private var selecting = false
    @State private var selectedIDs = Set<String>()
    // [A2 · 10-15 醒醒打回] Button 会吞外挂长按——四处改 simultaneousGesture 共存；
    // 该字段吞掉"长按当次松手"带出的按钮预览动作，防止刚预勾选就被切掉。
    @State private var suppressToggleForID: String?

    private static var backgroundURL: URL {
        AppearanceStudio.appearanceAssetsDirectory.appendingPathComponent("play-hub-background.jpg")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            selector
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(studio.color(.canvas, scope: .home).ignoresSafeArea())
        .navigationTitle(AppLocalized("Play", comment: "Play hub page title"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            reload()
            await rescan()
        }
        .onReceive(NotificationCenter.default.publisher(for: .soulMdChanged)) { _ in
            soulIcon = SoulStore.cachedMetadata.icon
            displayName = SoulStore.cachedMetadata.name
        }
        .onChange(of: backgroundItem) { item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = ThumbnailCache.downsampledImage(from: data, maxEdge: 1800),
                      let jpeg = image.jpegData(compressionQuality: 0.85) else {
                    backgroundItem = nil
                    return
                }
                try? jpeg.write(to: Self.backgroundURL, options: .atomic)
                backgroundImage = image
                backgroundItem = nil
            }
        }
        .onChange(of: avatarItem) { item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = ThumbnailCache.downsampledImage(from: data, maxEdge: 512) else {
                    avatarItem = nil
                    return
                }
                try? studio.setAssistantAvatar(image)
                soulIcon = SoulStore.cachedMetadata.icon
                // [B28 R14] 反向同步：这里只写了 SOUL.md，通讯录读的是 Persona.avatar，
                // 不补这一步就成了"Play 换了头像、通讯录还是旧的"。
                if var p = PersonaStore.shared.personas.first(where: { $0.id == PersonaStore.currentID() }),
                   p.avatar != soulIcon {
                    p.avatar = soulIcon
                    PersonaStore.shared.updatePersona(p)
                }
                avatarItem = nil
            }
        }
        .alert("改个名字", isPresented: $showNameEditor) {
            TextField("名字", text: $nameDraft)
            Button("取消", role: .cancel) {}
            Button("保存") { saveName() }
        } message: {
            Text("改的是名字本身，整个 App 都会跟着换。")
        }
        .fullScreenCover(item: $gallery) { g in
            MessageImageGallery(items: g.items, startIndex: g.startIndex)
        }
        .fullScreenCover(item: $playingVideo) { url in
            MinisVideoFullscreenPlayer(fileURL: url)
        }
        .sheet(item: $playingAudio) { url in
            MinisAudioPreviewView(fileURL: url)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
        }
        .sheet(item: $previewFile) { url in
            filePreviewView(url)
        }
        .confirmationDialog("删除选中的 \(selectedIDs.count) 项？",
                            isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                deleteSelected()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将同时删除聊天里引用的这些文件，此操作不可恢复。")
        }
        .photosPicker(isPresented: $showPhotoPicker,
                      selection: $uploadPicks,
                      maxSelectionCount: 20,
                      matching: uploadMatching)
        // [04b-2 §3] Copy-mode picker replaces `.fileImporter` (open-in-place,
        // silently refused on resigned builds).
        .sheet(isPresented: $showFilePicker) {
            DocumentCopyPicker(contentTypes: [.item],
                               allowsMultipleSelection: false) { urls in
                guard let url = urls.first else { return }
                Task { await importFile(from: url) }
            } onDone: {
                showFilePicker = false
            }
        }
        .alert("Error", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .onChange(of: uploadPicks) { _, newValue in
            guard !newValue.isEmpty else { return }
            Task { await handleUploadPicks() }
        }
        // [K-6] Importing N photos used to be completely silent — no spinner,
        // no disabled state, nothing for several seconds. `importing` was
        // written but never read anywhere.
        .overlay {
            if importing {
                ZStack {
                    Color.black.opacity(0.18).ignoresSafeArea()
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(AppLocalized("正在导入…"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(MinisThemeList.title)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(studio.color(.raised, scope: .home), in: Capsule())
                }
                .transition(.opacity)
                .allowsHitTesting(true)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: importing)
    }

    // MARK: - 头图（背景 + 头像 + 名字）

    private var header: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                PhotosPicker(selection: $backgroundItem, matching: .images) {
                    backgroundLayer
                        .frame(height: 150)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if backgroundImage != nil {
                        Button("移除背景", role: .destructive) { removeBackground() }
                    }
                }
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [Color.clear, studio.color(.canvas, scope: .home)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 46)
                        .allowsHitTesting(false)
                }

                PhotosPicker(selection: $avatarItem, matching: .images) {
                    avatar
                }
                .buttonStyle(.plain)
                .offset(y: 38)
            }

            Button {
                nameDraft = displayName
                showNameEditor = true
            } label: {
                Text(displayName.isEmpty ? "轻点起个名字" : displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(displayName.isEmpty ? MinisThemeList.subtitle : MinisThemeList.title)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(MinisThemeList.rowFill, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 44)
        }
        .overlay(alignment: .topTrailing) {
            // [T-playhub-upload][10-15 醒醒打回] 上传入口移右上角，不再贴进化格。
            // 想传什么传什么：相册收图片/视频，文件收音频/文档/任意，
            // 落盘后按扩展名自动进对应桶。
            Menu {
                Button {
                    // [K-1] A Menu button that sets a presentation flag in the
                    // same update transaction as the menu's dismissal loses the
                    // presentation on iOS — the first tap looked dead.
                    DispatchQueue.main.async { showPhotoPicker = true }
                } label: {
                    Label("从相册导入（图片/视频）", systemImage: "photo.on.rectangle")
                }
                Button {
                    DispatchQueue.main.async { showFilePicker = true }
                } label: {
                    Label("从文件导入（音频/文档/任意）", systemImage: "folder.fill")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(MinisThemeList.accent)
                    .frame(width: 34, height: 34)
                    .background(studio.color(.raised, scope: .home), in: Circle())
                    .overlay(
                        Circle().stroke(studio.color(.border, scope: .home).opacity(0.55), lineWidth: 0.6)
                    )
            }
            .padding(.top, 14)
            .padding(.trailing, 14)
        }
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        if let image = backgroundImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            LinearGradient(colors: [studio.color(.mutedSurface, scope: .home),
                                    studio.color(.canvas, scope: .home)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var avatar: some View {
        SoulIconView(icon: soulIcon, size: 76)
            .frame(width: 76, height: 76)
            .background(studio.color(.mutedSurface, scope: .home), in: Circle())
            .clipShape(Circle())
            .overlay(Circle().stroke(studio.color(.raised, scope: .home), lineWidth: 3))
            .shadow(color: studio.color(.primaryText, scope: .home).opacity(0.10), radius: 10, y: 3)
            .contentShape(Circle())
    }

    // MARK: - 五格胶囊开关

    private var selector: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { selection = tab }
                } label: {
                    Text(LocalizedStringKey(tab.title))
                        .font(.system(size: 13, weight: selection == tab ? .semibold : .regular))
                        .foregroundStyle(selection == tab ? MinisThemeList.title : MinisThemeList.subtitle)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            if selection == tab {
                                Capsule()
                                    .fill(studio.color(.raised, scope: .home))
                                    .shadow(color: studio.color(.primaryText, scope: .home).opacity(0.08),
                                            radius: 3, y: 1)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(studio.color(.mutedSurface, scope: .home).opacity(0.6)))
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            switch selection {
            case .images: imagesTab
            case .videos: videosTab
            case .audio: audioTab
            case .files: filesTab
            case .evolution: EvolutionCenterView(embedded: true)
            }
            if selecting {
                selectionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private var imagesTab: some View {
        if scanning && scanResult == nil {
            loadingView
        } else if let hits = scanResult?.images, !hits.isEmpty {
            GeometryReader { geo in
                let side = max(72, (geo.size.width - 36) / 3)
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3),
                              spacing: 6) {
                        ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                            Button {
                                if selecting {
                                    toggleSelect(hit)
                                } else {
                                    gallery = GalleryPresentation(items: imageGalleryItems(hits),
                                                                  startIndex: index)
                                }
                            } label: {
                                AsyncCacheURLImageTile(cacheURL: hit.url, tileSize: side)
                                    .overlay(alignment: .topLeading) { selectionBadge(hit) }
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in longPressSelect(hit) })
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 20)
                }
                .refreshable { await rescan() }
            }
        } else {
            emptyView("photo", Tab.images.emptyText)
        }
    }

    @ViewBuilder
    private var videosTab: some View {
        if scanning && scanResult == nil {
            loadingView
        } else if let hits = scanResult?.videos, !hits.isEmpty {
            GeometryReader { geo in
                let side = max(72, (geo.size.width - 36) / 3)
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3),
                              spacing: 6) {
                        ForEach(hits) { hit in
                            PlayHubVideoTile(fileURL: hit.url, tileSize: side) {
                                if selecting {
                                    toggleSelect(hit)
                                } else {
                                    playingVideo = hit.url
                                }
                            }
                            .overlay(alignment: .topLeading) { selectionBadge(hit) }
                            .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in longPressSelect(hit) })
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 20)
                }
                .refreshable { await rescan() }
            }
        } else {
            emptyView("video", Tab.videos.emptyText)
        }
    }

    @ViewBuilder
    private var audioTab: some View {
        if scanning && scanResult == nil {
            loadingView
        } else if let hits = scanResult?.audio, !hits.isEmpty {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(hits) { hit in
                        Button {
                            if selecting {
                                toggleSelect(hit)
                            } else {
                                playingAudio = hit.url
                            }
                        } label: {
                            mediaRow(icon: "waveform", title: hit.name,
                                     subtitle: "\(PlayHubFormat.size(hit.size)) · \(PlayHubFormat.date(hit.modified))")
                                .overlay(alignment: .topLeading) { selectionBadge(hit) }
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in longPressSelect(hit) })
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
            .refreshable { await rescan() }
        } else {
            emptyView("waveform", Tab.audio.emptyText)
        }
    }

    @ViewBuilder
    private var filesTab: some View {
        if scanning && scanResult == nil {
            loadingView
        } else if let hits = scanResult?.files, !hits.isEmpty {
            let grouped = Self.groupFiles(hits)
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(grouped, id: \.0) { category, items in
                        fileCategorySection(category: category, items: items)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
            .refreshable { await rescan() }
        } else {
            emptyView("doc", Tab.files.emptyText)
        }
    }

    // MARK: - 文件桶自动分类 + 折叠（P1-4）

    private enum FileCategory: String, CaseIterable {
        case scripts, code, config, docs, memory, other
        var label: String {
            switch self {
            case .scripts: return "脚本"
            case .code: return "代码"
            case .config: return "配置"
            case .docs: return "文档"
            case .memory: return "记忆"
            case .other: return "其他"
            }
        }
    }

    /// 扩展名优先，目录语义补充（memory/ 下的 .md 归"记忆"）。
    private static func category(of hit: PlayHubMediaScanner.Hit) -> FileCategory {
        let ext = hit.url.pathExtension.lowercased()
        let rel = hit.relative.lowercased()
        if rel.contains("memory/") && ext == "md" { return .memory }
        switch ext {
        case "py", "sh", "js", "ts", "swift", "kt", "go", "rs": return .scripts
        case "c", "h", "m", "mm", "cpp", "java": return .code
        case "json", "yml", "yaml", "plist", "xml", "toml", "ini": return .config
        case "md", "txt", "rst": return .docs
        default: return .other
        }
    }

    private static func groupFiles(_ hits: [PlayHubMediaScanner.Hit])
        -> [(FileCategory, [PlayHubMediaScanner.Hit])] {
        let dict = Dictionary(grouping: hits, by: { category(of: $0) })
        return FileCategory.allCases.compactMap { cat in
            guard let items = dict[cat], !items.isEmpty else { return nil }
            return (cat, items)
        }
    }

    /// 分组头可折叠；行保留长按删除（P1-3）。
    private func fileCategorySection(category: FileCategory,
                                     items: [PlayHubMediaScanner.Hit]) -> some View {
        let isCollapsed = collapsedCategories.contains(category)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if isCollapsed {
                        collapsedCategories.remove(category)
                    } else {
                        collapsedCategories.insert(category)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(LocalizedStringKey(category.label))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(MinisThemeList.title)
                    Text("\(items.count)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(MinisThemeList.subtitle)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1.5)
                        .background(studio.color(.raised, scope: .home), in: Capsule())
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(MinisThemeList.subtitle)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(MinisThemeList.rowFill,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                VStack(spacing: 8) {
                    ForEach(items) { hit in
                        Button {
                            if selecting {
                                toggleSelect(hit)
                            } else {
                                previewFile = hit.url
                            }
                        } label: {
                            mediaRow(icon: "doc.fill", title: hit.name,
                                     subtitle: "\(hit.relative) · \(PlayHubFormat.size(hit.size))")
                                .overlay(alignment: .topLeading) { selectionBadge(hit) }
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in longPressSelect(hit) })
                    }
                }
                .padding(.vertical, 4)
                .background(MinisThemeList.rowFill,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - 批量删除（P1-3 打回）

    /// 长按进入选择模式并预勾选该项（轻微触感）。
    private func longPressSelect(_ hit: PlayHubMediaScanner.Hit) {
        guard !selecting else { return }
        selecting = true
        selectedIDs = [hit.id]
        suppressToggleForID = hit.id
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// 选择模式下点击=勾选切换；勾选空了自动退出选择模式。
    /// 长按当次松手带来的那一次按钮动作在这里被吞掉，不切掉刚预勾选的条目。
    private func toggleSelect(_ hit: PlayHubMediaScanner.Hit) {
        if let suppressed = suppressToggleForID {
            suppressToggleForID = nil
            if suppressed == hit.id { return }
        }
        if selectedIDs.contains(hit.id) {
            selectedIDs.remove(hit.id)
        } else {
            selectedIDs.insert(hit.id)
        }
        if selectedIDs.isEmpty { selecting = false }
    }

    /// 选择圈（左上角覆盖；图片/视频上白色带阴影保证可见）。
    @ViewBuilder
    private func selectionBadge(_ hit: PlayHubMediaScanner.Hit) -> some View {
        if selecting {
            Image(systemName: selectedIDs.contains(hit.id) ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22))
                .foregroundStyle(selectedIDs.contains(hit.id) ? MinisThemeList.accent : Color.white.opacity(0.9))
                .padding(6)
                .shadow(color: .black.opacity(0.35), radius: 1.5)
        }
    }

    /// 当前桶的全部条目。
    private var currentHits: [PlayHubMediaScanner.Hit] {
        guard let result = scanResult else { return [] }
        switch selection {
        case .images: return result.images
        case .videos: return result.videos
        case .audio: return result.audio
        case .files: return result.files
        case .evolution: return []
        }
    }

    /// 批量删除已勾选项（真删文件后重扫）。
    private func deleteSelected() {
        let hits = currentHits
        for id in selectedIDs {
            if let hit = hits.first(where: { $0.id == id }) {
                try? FileManager.default.removeItem(at: hit.url)
            }
        }
        selectedIDs = []
        selecting = false
        Task { await rescan() }
    }

    /// 选择模式底部操作条。
    private var selectionBar: some View {
        HStack(spacing: 14) {
            Text("已选 \(selectedIDs.count) 项")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MinisThemeList.title)
            Spacer()
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("删除", systemImage: "trash")
                    .font(.system(size: 14, weight: .semibold))
            }
            Button("完成") { selecting = false; selectedIDs = [] }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MinisThemeList.accent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(MinisThemeList.rowFill,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    // MARK: - 行 / 空态 / 载入

    private func mediaRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MinisThemeList.accent)
                .frame(width: 36, height: 36)
                .background(studio.color(.raised, scope: .home),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(studio.color(.border, scope: .home).opacity(0.55), lineWidth: 0.6)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(MinisThemeList.title)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(MinisThemeList.subtitle)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MinisTheme.secondaryText.opacity(0.7))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(MinisThemeList.rowFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func emptyView(_ icon: String, _ text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(MinisThemeList.accent)
                .frame(width: 84, height: 84)
                .background(studio.color(.raised, scope: .home),
                            in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(studio.color(.border, scope: .home).opacity(0.55), lineWidth: 0.6)
                )
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(MinisThemeList.subtitle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingView: some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 预览分发

    @ViewBuilder
    private func filePreviewView(_ url: URL) -> some View {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "md", "markdown":
            MinisMarkdownPreviewView(fileURL: url)
        case "txt", "log", "json", "csv", "swift", "py", "sh", "js", "ts", "css",
             "xml", "yml", "yaml", "ini", "toml", "sql":
            MinisTextPreviewView(fileURL: url)
        case "html", "htm":
            MinisHTMLPreviewView(fileURL: url)
        default:
            MinisDocumentPreviewView(fileURL: url)
        }
    }

    private func imageGalleryItems(_ hits: [PlayHubMediaScanner.Hit]) -> [GalleryItem] {
        hits.map { hit in
            GalleryItem(id: hit.id, title: hit.name) {
                let url = hit.url
                return await Task.detached(priority: .userInitiated) {
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return downsampleImageData(data, maxPixelSize: 2048)
                }.value
            }
        }
    }

    // MARK: - 数据

    private func reload() {
        backgroundImage = UIImage(contentsOfFile: Self.backgroundURL.path)
        soulIcon = SoulStore.cachedMetadata.icon
        displayName = SoulStore.cachedMetadata.name
    }

    private func rescan() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        let roots = PlayHubMediaScanner.roots()
        let result = await Task.detached(priority: .userInitiated) {
            PlayHubMediaScanner.scan(roots: roots)
        }.value
        scanResult = result
    }

    private func saveName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var soul = SoulStore.load() ?? SoulFile(metadata: .default, body: "")
        soul.metadata.name = trimmed
        try? SoulStore.save(soul)
        displayName = SoulStore.cachedMetadata.name
    }

    private func removeBackground() {
        try? FileManager.default.removeItem(at: Self.backgroundURL)
        backgroundImage = nil
    }

    // MARK: - 上传（P1-2）

    /// 相册导入不限类型：图片/视频都收（音频走文件导入）。
    private var uploadMatching: PHPickerFilter {
        .any(of: [.images, .videos])
    }

    private func uploadDir() -> URL {
        let dir = AIChatViewModel.minisPersistentBase
            .appendingPathComponent("play-hub", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 重名自动追加序号（play-1.jpg），不覆盖。
    private func uniqueDest(_ dir: URL, name: String) -> URL {
        var dest = dir.appendingPathComponent(name)
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            let ext = (name as NSString).pathExtension
            let base = (name as NSString).deletingPathExtension
            dest = dir.appendingPathComponent("\(base)-\(n).\(ext)")
            n += 1
        }
        return dest
    }

    private func saveImported(_ data: Data, ext: String) {
        let dest = uniqueDest(uploadDir(), name: "play-\(Int(Date().timeIntervalSince1970)).\(ext)")
        try? data.write(to: dest)
    }

    // [K-6b] `View.body` is `@MainActor` but a custom method on the struct is
    // not. `importing` now drives an overlay, so this write really does touch
    // the UI — and `Task { await … }` from `onChange` inherits the actor only by
    // convention, not by the type system. Pin it.
    @MainActor
    private func handleUploadPicks() async {
        guard !uploadPicks.isEmpty else { return }
        importing = true
        defer { importing = false }
        for item in uploadPicks {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            // 扩展名按系统给出的实际类型推断（heic/jpg/png/mov/mp4…），
            // 落盘后扫描器按扩展名自动进对应桶。
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "bin"
            saveImported(data, ext: ext)
        }
        uploadPicks = []
        await rescan()
    }

    @MainActor
    private func importFile(from url: URL) async {
        let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension
        // [K-7] Optional grant, not a gate: a copy-mode URL has no security
        // scope to enter, so `startAccessingSecurityScopedResource()` returns
        // false and the whole import used to be skipped without a word.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // [04b-2 §8b] The failure used to be a bare `return` — she picks a file,
        // nothing lands, nothing is said.
        guard let data = try? Data(contentsOf: url) else {
            importError = AppLocalized("Couldn't read that file. Try picking it again.")
            return
        }
        saveImported(data, ext: ext)
        await rescan()
    }
}

// MARK: - 统一视频瓦片（缩略图 + 播放角标）

private struct PlayHubVideoTile: View {
    let fileURL: URL
    let tileSize: CGFloat
    let onTap: () -> Void

    @ObservedObject private var studio = AppearanceStudio.shared
    @State private var thumbnail: UIImage?

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                if let img = thumbnail {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: tileSize, height: tileSize)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(studio.color(.mutedSurface, scope: .home))
                        .frame(width: tileSize, height: tileSize)
                }
                Image(systemName: "play.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(studio.color(.raised, scope: .home))
                    .padding(4)
                    .background(studio.color(.primaryText, scope: .home).opacity(0.55))
                    .clipShape(Circle())
                    .padding(4)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(studio.color(.border, scope: .home).opacity(0.5), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .task(id: fileURL) { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        let url = fileURL
        let image: UIImage? = await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 320)
            guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
            return UIImage(cgImage: cgImage)
        }.value
        if let image { thumbnail = image }
    }
}

// MARK: - 数据扫描（一趟扫，四桶分类）

struct PlayHubMediaScanner {
    struct Hit: Identifiable {
        let id: String
        let url: URL
        let name: String
        let relative: String
        let size: Int
        let modified: Date
    }

    struct Result {
        var images: [Hit] = []
        var videos: [Hit] = []
        var audio: [Hit] = []
        var files: [Hit] = []
    }

    static let imageExts: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "tiff", "tif"]
    static let videoExts: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm"]
    static let audioExts: Set<String> = ["m4a", "mp3", "wav", "caf", "aac", "flac", "ogg", "opus", "aiff"]
    static let noiseExts: Set<String> = ["db", "sqlite", "sqlite3", "wal", "shm", "lock", "tmp",
                                         "cache", "plist", "log", "jsonl", "db-journal"]

    static let maxScanEntries = 12_000
    static let caps: (images: Int, videos: Int, audio: Int, files: Int) = (600, 200, 400, 400)

    /// 全部数据根（主线程取，避免 detached 里碰凡尘）。
    static func roots() -> [URL] {
        var list: [URL] = []
        list.append(AIChatViewModel.minisPersistentBase)
        list.append(AIChatViewModel.minisPersistentBase
            .deletingLastPathComponent()
            .appendingPathComponent("media", isDirectory: true))
        list.append(AIChatViewModel.minisSharedPersistentDir)
        list.append(RootfsManager.shared.dataPath.appendingPathComponent("var/minis", isDirectory: true))
        return list
    }

    static func scan(roots: [URL]) -> Result {
        var result = Result()
        var seen = Set<String>()
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]

        for root in roots {
            guard fm.fileExists(atPath: root.path) else { continue }
            guard let enumerator = fm.enumerator(at: root,
                                                 includingPropertiesForKeys: keys,
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            var scanned = 0
            for case let url as URL in enumerator {
                scanned += 1
                if scanned > maxScanEntries { break }
                let ext = url.pathExtension.lowercased()
                if ext.isEmpty || noiseExts.contains(ext) { continue }
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true else { continue }
                let resolved = url.resolvingSymlinksInPath().path
                guard seen.insert(resolved).inserted else { continue }
                let relative = url.path.hasPrefix(root.path + "/")
                    ? String(url.path.dropFirst(root.path.count + 1))
                    : url.lastPathComponent
                let hit = Hit(id: resolved,
                              url: url,
                              name: url.lastPathComponent,
                              relative: relative,
                              size: values.fileSize ?? 0,
                              modified: values.contentModificationDate ?? .distantPast)
                if imageExts.contains(ext) {
                    result.images.append(hit)
                } else if videoExts.contains(ext) {
                    result.videos.append(hit)
                } else if audioExts.contains(ext) {
                    result.audio.append(hit)
                } else {
                    result.files.append(hit)
                }
            }
        }

        // [B28 R22] 同一张图在磁盘上可能有多份副本（历史遗留的 UUID 压缩版）。
        // 媒体库按内容去重：一样的内容只列一次，优先列 uploads 里的原件。
        result.images = Array(Self.dedupeByContent(result.images)
            .sorted { $0.modified > $1.modified }.prefix(caps.images))
        result.videos = Array(result.videos.sorted { $0.modified > $1.modified }.prefix(caps.videos))
        result.audio = Array(result.audio.sorted { $0.modified > $1.modified }.prefix(caps.audio))
        result.files = Array(result.files.sorted { $0.modified > $1.modified }.prefix(caps.files))
        return result
    }

    // MARK: - [B28 R22] 内容去重

    /// 先按文件大小分组，只有大小相同的才真的去读字节算指纹——
    /// 600 张图里绝大多数大小都不一样，实际读盘的只有少数。
    static func dedupeByContent(_ hits: [Hit]) -> [Hit] {
        var bySize: [Int: [Hit]] = [:]
        for h in hits { bySize[h.size, default: []].append(h) }

        var kept: [Hit] = []
        for (_, group) in bySize {
            if group.count == 1 {
                kept.append(contentsOf: group)
                continue
            }
            var byFingerprint: [String: Hit] = [:]
            for h in group {
                let key = fingerprint(h) ?? "path:\(h.id)"
                if let current = byFingerprint[key] {
                    byFingerprint[key] = preferred(current, h)
                } else {
                    byFingerprint[key] = h
                }
            }
            kept.append(contentsOf: byFingerprint.values)
        }
        return kept
    }

    /// 读前 64KB + 文件大小做指纹。读不到就返回 nil（调用方按路径当独立文件）。
    static func fingerprint(_ hit: Hit) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: hit.url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 65_536)) ?? Data()
        var hash: UInt64 = 1469598103934665603
        for byte in head {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return "\(hit.size):\(hash)"
    }

    /// 两份同内容文件里选哪个：uploads 原件优先，其次文件名不像 UUID 的。
    static func preferred(_ a: Hit, _ b: Hit) -> Hit {
        func score(_ h: Hit) -> Int {
            var s = 0
            if h.url.path.contains("/uploads/") { s += 4 }
            if !isUUIDLike(h.name) { s += 2 }
            return s
        }
        return score(b) > score(a) ? b : a
    }

    /// 32 位十六进制 + 短横线那种裸 UUID 文件名。
    static func isUUIDLike(_ name: String) -> Bool {
        let stem = (name as NSString).deletingPathExtension
        let parts = stem.split(separator: "-")
        guard parts.count >= 1 else { return false }
        return stem.count >= 32 && stem.allSatisfy { $0.isHexDigit || $0 == "-" }
    }
}

// MARK: - 小格式化

enum PlayHubFormat {
    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
