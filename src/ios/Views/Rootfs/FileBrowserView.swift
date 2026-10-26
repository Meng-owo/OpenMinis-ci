//
//  FileBrowserView.swift
//  MinisApp
//
//  File browser for exploring and exporting files from the rootfs
//

import SwiftUI
import UIKit
import QuickLook
import WebKit
import FileProvider
import UniformTypeIdentifiers

enum FileSortKey: String, CaseIterable, Identifiable {
    case name
    case modified
    case size
    case kind

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .name: return "Name"
        case .modified: return "Date Modified"
        case .size: return "Size"
        case .kind: return "Kind"
        }
    }
}

struct FileBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: FileBrowserViewModel
    @AppStorage("fileBrowser.sortKey") private var sortKeyRaw: String = FileSortKey.name.rawValue
    @AppStorage("fileBrowser.sortAscending") private var sortAscending: Bool = true
    @AppStorage("fileBrowser.foldersFirst") private var foldersFirst: Bool = true
    /// Show files whose name starts with `.` (and macOS-flagged hidden
    /// items). Off by default so the listing matches typical Unix `ls`
    /// behaviour; persisted across app launches via UserDefaults.
    /// (T-hidden-files 74b70818)
    @AppStorage("fileBrowser.showHidden") private var showHidden: Bool = false
    /// [04b-2 §2] This view used to carry 4 sheets + 3 alerts on the same
    /// level. SwiftUI keeps exactly one presentation per level, so any two of
    /// them asked for in the same transaction silently lose one — the "点了没
    /// 反应" class of bug. Everything now funnels through `activeSheet` and
    /// `dialog`, the same `sheet(item:)` shape `ContentView.activeToolSheet`
    /// uses.
    @State private var activeSheet: FileBrowserSheet?
    @State private var dialog: FileBrowserDialog?
    /// [04b-2 §1] `DocumentCopyPicker` runs `onPick` before `onDone`, so the
    /// import result has to be parked here and raised after the sheet is gone.
    @State private var pendingImportFailure: String?
    /// Lightweight "Copied" toast for Copy Absolute Path. Separate from the
    /// blocking Done alert for move/copy-to; this is a self-dismissing capsule.
    /// [T-ios-copy-abs-path-copied-toast]
    @State private var copiedToast = false
    /// [T-browser-download-ux-v2] Filename to scroll to and briefly highlight
    /// after the first listing loads (downloads panel "Show in Files").
    private let highlightFileName: String?
    @State private var highlightActive = false
    @State private var didLocateHighlight = false

    enum MoveOrCopyMode { case move, copy }

    /// [04b-2 §2] One enum for every sheet this view can present.
    private enum FileBrowserSheet: Identifiable {
        case export(FileItem)
        case preview(FileItem)
        case importPicker
        case moveOrCopy(FileItem, MoveOrCopyMode)
        /// Kept as a sheet (not an alert) so the row-level "Add to Home Screen"
        /// stops being a presentation mounted on every row.
        case addToHome(FileItem)

        var id: String {
            switch self {
            case .export(let f): return "export-\(f.id)"
            case .preview(let f): return "preview-\(f.id)"
            case .importPicker: return "import"
            case .moveOrCopy(let f, let m): return "move-\(m)-\(f.id)"
            case .addToHome(let f): return "home-\(f.id)"
            }
        }
    }

    /// [04b-2 §2] One enum for every alert this view can present.
    private enum FileBrowserDialog: Identifiable {
        case error(String)
        case delete(FileItem)
        case done(String)

        var id: String {
            switch self {
            case .error: return "error"
            case .delete(let f): return "delete-\(f.id)"
            case .done: return "done"
            }
        }

        var title: LocalizedStringKey {
            switch self {
            case .error: return "Error"
            case .delete(let f): return "Delete \"\(f.name)\"?"
            case .done: return "Done"
            }
        }

        var message: String {
            switch self {
            case .error(let m): return m
            case .delete(let f): return "\(f.formattedSize) · \(AppLocalized("This action cannot be undone."))"
            case .done(let m): return m
            }
        }
    }

    init(rootPath: URL? = nil, initialPath: URL? = nil, rootLabel: String? = nil,
         highlightFileName: String? = nil) {
        let path = rootPath ?? RootfsManager.shared.rootfsPath
        self.highlightFileName = highlightFileName
        _viewModel = StateObject(wrappedValue: FileBrowserViewModel(rootPath: path, initialPath: initialPath, rootLabel: rootLabel))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Path breadcrumb
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(viewModel.pathComponents.indices, id: \.self) { index in
                        Button(action: {
                            viewModel.navigateToPathComponent(at: index)
                        }) {
                            Text(viewModel.pathComponents[index])
                                .font(.caption)
                                .foregroundColor(AppearanceStudio.shared.color(.accent, scope: .files))
                        }
                        if index < viewModel.pathComponents.count - 1 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .background(AppearanceStudio.shared.color(.surface))

            // File list
            if viewModel.isLoading {
                Spacer()
                ProgressView("Loading...")
                Spacer()
            } else if viewModel.items.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("Empty folder")
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(viewModel.items) { item in
                            FileBrowserRow(item: item, viewModel: viewModel) {
                                if item.isDirectory {
                                    viewModel.navigateTo(item)
                                } else {
                                    activeSheet = .preview(item)
                                }
                            } onExport: {
                                activeSheet = .export(item)
                            } onMove: {
                                activeSheet = .moveOrCopy(item, .move)
                            } onCopy: {
                                activeSheet = .moveOrCopy(item, .copy)
                            } onCopiedPath: {
                                showCopiedToast()
                            } onDelete: {
                                dialog = .delete(item)
                            } onAddToHome: {
                                activeSheet = .addToHome(item)
                            }
                            .id(item.id)
                            // [T-browser-download-ux-v2] Transient locate
                            // highlight (downloads panel "Show in Files").
                            .listRowBackground(
                                highlightActive && item.name == highlightFileName
                                    ? AppearanceStudio.shared.color(.accent, scope: .files).opacity(0.18)
                                    : nil
                            )
                        }
                    }
                    .listStyle(.plain)
                    .onAppear { locateHighlightTarget(proxy: proxy) }
                    .onChange(of: viewModel.items.map(\.name)) { _ in
                        locateHighlightTarget(proxy: proxy)
                    }
                }
            }
        }
        .appearancePage(.files)
        .navigationTitle("Files")
        .navigationBarTitleDisplayMode(.inline)
        // [T-ios-copy-abs-path-copied-toast] Self-dismissing "Copied" capsule.
        .overlay(alignment: .bottom) {
            if copiedToast {
                Label(AppLocalized("Copied"), systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.8), in: Capsule())
                    .padding(.bottom, 32)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3), value: copiedToast)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Close") {
                    dismiss()
                }
            }
            // T-hidden-files a3e7f1d0: trailing toolbar collapsed to a
            // single ⋯ menu. Previously surfaced Sort / Import (+) /
            // Parent-dir (up.doc) as three separate buttons; users
            // ignored the menu icon, accidentally tapped Import while
            // trying to switch sort, etc. All functional actions now live
            // under one entry point so the chrome stays consistent with
            // the rest of the app's "... overflow" pattern.
            ToolbarItem(placement: .navigationBarTrailing) {
                moreMenu
            }
        }
        // [04b-2 §2] One sheet, one alert for the whole page. Order matters
        // only in that the import picker's dismissal is what unlocks the
        // result alert.
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .export(let file):
                DocumentExportView(fileURL: file.url)
            case .preview(let file):
                FilePreviewSheet(item: file)
            case .importPicker:
                // [K-7] Copy-mode picker, not `asCopy: false`.
                //
                // SwiftUI's `.fileImporter` (and any open-in-place picker)
                // needs a FileProvider security-scoped grant. On resigned /
                // sideloaded builds iOS refuses it silently: the picker opens,
                // the user taps a file, "Open" does nothing and no error is
                // delivered — exactly "外部挂载传不了". `DocumentCopyPicker`
                // copies into tmp and hands back a plain file: URL, so no
                // grant is involved.
                //
                // [04b-2 §1] `onPick` runs BEFORE `onDone`, and `importFiles`
                // used to raise the error alert from inside `onPick` — while
                // this sheet was still on screen, where SwiftUI drops it. Now
                // the message is parked and raised from `onDone` one turn after
                // the dismissal.
                DocumentCopyPicker(contentTypes: [.data, .item],
                                   allowsMultipleSelection: true) { urls in
                    pendingImportFailure = viewModel.importFiles(urls)
                } onDone: {
                    activeSheet = nil
                    guard let message = pendingImportFailure else { return }
                    pendingImportFailure = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        dialog = .error(message)
                    }
                }
            case .moveOrCopy(let item, let mode):
                let minisPath = viewModel.rootPath.appendingPathComponent("var/minis")
                let initial = FileManager.default.fileExists(atPath: minisPath.path) ? minisPath : nil
                NavigationStack {
                    DirectoryPickerView(
                        rootPath: viewModel.rootPath,
                        rootLabel: viewModel.rootLabel,
                        initialPath: initial,
                        excludedURL: item.url,
                        title: mode == .move ? "Move to…" : "Copy to…"
                    ) { destinationDir in
                        let destName = viewModel.displayPath(for: destinationDir)
                        let moved = mode == .move
                            ? viewModel.moveItem(item, to: destinationDir)
                            : viewModel.copyItem(item, to: destinationDir)
                        activeSheet = nil
                        viewModel.loadItems()
                        guard moved else { return }
                        // Same trap as the import alert: the destination picker
                        // is still dismissing, so the confirmation has to wait.
                        let text = String(
                            format: AppLocalized(moved ? "Moved \"%@\" to %@" : "Copied \"%@\" to %@"),
                            item.name, destName
                        )
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            dialog = .done(text)
                        }
                    }
                }
            case .addToHome(let file):
                // The browser exposes already-resolved host URLs via
                // FileItem.url, so we hand the URL straight to the sheet
                // without going through minis-clone:// resolution.
                WebAppAddToHomeSheet(htmlURL: file.url, sourceSessionId: nil)
            }
        }
        .alert(dialogTitle, isPresented: Binding(
            get: { dialog != nil },
            set: { if !$0 { dialog = nil } }
        )) {
            // `dialog` is optional, so the case pattern needs the `?` — without
            // it this does not compile ("pattern of type 'FileBrowserDialog'
            // cannot match 'FileBrowserDialog?'").
            if case .delete(let item)? = dialog {
                Button("Delete", role: .destructive) {
                    dialog = nil
                    viewModel.deleteItem(item)
                }
                Button("Cancel", role: .cancel) { dialog = nil }
            } else {
                Button("OK", role: .cancel) { dialog = nil }
            }
        } message: {
            Text(dialog?.message ?? "")
        }
        // The view model still raises its own errors (delete / move / copy
        // failures). With the per-case alerts merged into `dialog`, those have
        // to be forwarded — otherwise they would now be set and never shown.
        .onChange(of: viewModel.showError) { _, presented in
            guard presented else { return }
            viewModel.showError = false
            dialog = .error(viewModel.errorMessage)
        }
        .modifier(SortSyncModifier(
            sortKeyRaw: sortKeyRaw,
            sortAscending: sortAscending,
            foldersFirst: foldersFirst,
            showHidden: showHidden,
            apply: syncSort
        ))
    }

    /// [04b-2 §2] Typed `LocalizedStringKey`: `alert(_:isPresented:)` has a
    /// `String` overload that prints verbatim without consulting the string
    /// table, and `dialog?.title ?? ""` would pick exactly that one.
    private var dialogTitle: LocalizedStringKey {
        guard let dialog else { return "" }
        return dialog.title
    }

    private var currentSortKey: FileSortKey {
        FileSortKey(rawValue: sortKeyRaw) ?? .name
    }

    /// Show the "Copied" toast and auto-dismiss it after ~1.5s.
    /// [T-ios-copy-abs-path-copied-toast]
    private func showCopiedToast() {
        copiedToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copiedToast = false
        }
    }

    /// [T-browser-download-ux-v2] Scroll to `highlightFileName` once the
    /// listing contains it, then flash the row background and let it fade.
    /// One-shot: later listing refreshes (sort changes, edits) don't re-jump.
    private func locateHighlightTarget(proxy: ScrollViewProxy) {
        guard let target = highlightFileName, !didLocateHighlight,
              let item = viewModel.items.first(where: { $0.name == target }) else { return }
        didLocateHighlight = true
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(item.id, anchor: .center)
                highlightActive = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                withAnimation(.easeOut(duration: 0.6)) { highlightActive = false }
            }
        }
    }

    private func syncSort() {
        let listingChanged = viewModel.showHidden != showHidden
        viewModel.showHidden = showHidden
        viewModel.updateSort(key: currentSortKey, ascending: sortAscending, foldersFirst: foldersFirst)
        // Toggling showHidden changes which entries appear in the listing,
        // not just the sort order — reload from disk so newly-included /
        // newly-excluded dotfiles surface immediately.
        if listingChanged {
            viewModel.loadItems()
        }
    }

    /// Trailing-toolbar `⋯` menu. Holds every functional action so the
    /// toolbar stays at one entry point. Order: navigation (go-to-parent
    /// when applicable) → create/import → display options (sort, hidden
    /// files). T-hidden-files a3e7f1d0.
    private var moreMenu: some View {
        Menu {
            if viewModel.canGoBack {
                Button {
                    viewModel.goBack()
                } label: {
                    Label("Go to Parent Folder", systemImage: "arrow.up.doc")
                }
                Divider()
            }
            // [K-7b] Let one runloop turn pass before presenting. A button
            // inside a `Menu` presents while the menu is still dismissing, and
            // iOS drops the presentation — the reported "点了没反应" on this
            // exact entry (file browser ⋯ → Import File), which is also one of
            // the ways "外部挂载传不了" shows up.
            Button {
                DispatchQueue.main.async { activeSheet = .importPicker }
            } label: {
                Label("Import File", systemImage: "plus")
            }
            Divider()
            Picker(selection: $sortKeyRaw) {
                ForEach(FileSortKey.allCases) { key in
                    Text(key.label).tag(key.rawValue)
                }
            } label: {
                Text("Sort By")
            }
            Button {
                sortAscending.toggle()
            } label: {
                Label(
                    sortAscending ? "Ascending" : "Descending",
                    systemImage: sortAscending ? "arrow.up" : "arrow.down"
                )
            }
            Toggle(isOn: $foldersFirst) {
                Label("Folders First", systemImage: "folder.fill")
            }
            Toggle(isOn: $showHidden) {
                Label(
                    showHidden ? "Hide Hidden Files" : "Show Hidden Files",
                    systemImage: showHidden ? "eye.slash" : "eye"
                )
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }
}

private struct SortSyncModifier: ViewModifier {
    let sortKeyRaw: String
    let sortAscending: Bool
    let foldersFirst: Bool
    let showHidden: Bool
    let apply: () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear(perform: apply)
            .onChange(of: sortKeyRaw) { _ in apply() }
            .onChange(of: sortAscending) { _ in apply() }
            .onChange(of: foldersFirst) { _ in apply() }
            .onChange(of: showHidden) { _ in apply() }
    }
}

// MARK: - File Preview

private enum RichPreviewKind {
    case markdown
    case html
    case text
    case quickLook
    case info
}

private func richPreviewKind(for item: FileItem) -> RichPreviewKind {
    if item.isDirectory { return .info }
    let url = item.isSymlink ? item.url.resolvingSymlinksInPath() : item.url
    let ext = url.pathExtension.lowercased()
    switch ext {
    case "md", "markdown", "mdown", "mkd":
        return .markdown
    case "html", "htm", "xhtml":
        return .html
    case "txt", "log", "json", "xml", "yaml", "yml", "toml", "ini", "conf", "cfg",
         "sh", "bash", "zsh", "fish", "py", "rb", "js", "mjs", "cjs", "ts", "tsx",
         "jsx", "swift", "c", "cc", "cpp", "cxx", "h", "hh", "hpp", "m", "mm",
         "go", "rs", "java", "kt", "kts", "gradle", "groovy", "scala", "clj",
         "php", "pl", "lua", "r", "sql", "css", "scss", "less", "vue", "svelte",
         "dart", "ex", "exs", "erl", "hs", "ml", "fs", "fsx", "csv", "tsv",
         "env", "dockerfile", "makefile", "mk", "cmake", "patch", "diff":
        return .text
    default:
        // Files with no extension often are text (Dockerfile, Makefile, README, LICENSE).
        if ext.isEmpty {
            let name = url.lastPathComponent.lowercased()
            if ["dockerfile", "makefile", "readme", "license", "licence",
                "changelog", "authors", "copying", "notice", "todo"].contains(name) {
                return .text
            }
        }
        if QLPreviewController.canPreview(url as NSURL) {
            return .quickLook
        }
        return .info
    }
}

private struct FilePreviewSheet: View {
    let item: FileItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(item.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        let resolved = item.isSymlink ? item.url.resolvingSymlinksInPath() : item.url
        switch richPreviewKind(for: item) {
        case .markdown:
            MarkdownFilePreview(url: resolved, item: item)
        case .html:
            HTMLFilePreview(url: resolved)
        case .text:
            TextFilePreview(url: resolved, item: item)
        case .quickLook:
            QuickLookPreview(url: resolved)
        case .info:
            FileInfoView(item: item)
        }
    }
}

// MARK: - Markdown preview (reuses Chat's SelectableMarkdownView)

private struct MarkdownFilePreview: View {
    let url: URL
    let item: FileItem
    @State private var loadState: LoadState = .loading
    @State private var renderMode: Mode = .rendered

    enum Mode { case rendered, source }
    enum LoadState {
        case loading
        case loaded(String)
        case failed(String)
    }

    var body: some View {
        Group {
            switch loadState {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let msg):
                FileLoadErrorView(item: item, message: msg)
            case .loaded(let text):
                ScrollView {
                    Group {
                        if renderMode == .rendered {
                            SelectableMarkdownView(markdown: text)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                        } else {
                            Text(text)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                        }
                    }
                }
            }
        }
        .toolbar {
            if case .loaded = loadState {
                ToolbarItem(placement: .topBarLeading) {
                    // Single toggle button, NOT a segmented Picker.
                    //
                    // A `.segmented` Picker asks for the width of all its
                    // segments, but a toolbar item on iOS 26's Liquid Glass
                    // bar is laid out as one round glass button. The control
                    // got squeezed into that circular slot and drew both
                    // segments on top of each other — the reported "two
                    // overlapping, distorted icons" (screenshot
                    // /tmp/md_preview_toggle_bug.jpg), not an animation stuck
                    // mid-transition.
                    //
                    // A plain Button showing ONE icon is what a toolbar slot
                    // is shaped for, and it matches the icon-swap toggles
                    // used elsewhere in the app. The icon shows the mode you
                    // will switch TO, which is the convention for a toggle
                    // that has no separate label.
                    Button {
                        renderMode = (renderMode == .rendered) ? .source : .rendered
                    } label: {
                        Image(systemName: renderMode == .rendered
                              ? "chevron.left.forwardslash.chevron.right"
                              : "doc.richtext")
                    }
                    .accessibilityLabel(renderMode == .rendered
                                        ? Text("Show Source")
                                        : Text("Show Rendered"))
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        let url = self.url
        let result: LoadState = await Task.detached(priority: .userInitiated) {
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1)
                    ?? ""
                return .loaded(text)
            } catch {
                return .failed(error.localizedDescription)
            }
        }.value
        if case .loaded(let text) = result {
            // Rough pre-render formula count so we can correlate the
            // MathRenderScheduler burst log below with a specific file
            // when triaging slow previews.
            let inlineDollars = text.reduce(0) { $0 + ($1 == "$" ? 1 : 0) }
            let blockMarkers = text.components(separatedBy: "$$").count / 2
            let inlineApprox = max(0, inlineDollars - blockMarkers * 2) / 2
            AppLogger(category: "MdFilePreview").info("[MdPreview] open file=\(url.lastPathComponent) bytes=\(text.utf8.count) ~inline=\(inlineApprox) ~block=\(blockMarkers)")
        }
        await MainActor.run { self.loadState = result }
    }
}

// MARK: - HTML preview (WKWebView loading the local file)

private struct HTMLFilePreview: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.setURLSchemeHandler(BrowserUseManager.sharedMinisSchemeHandler, forURLScheme: "minis-clone")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - Plain text / source code preview

private struct TextFilePreview: View {
    let url: URL
    let item: FileItem
    @State private var loadState: MarkdownFilePreview.LoadState = .loading

    var body: some View {
        Group {
            switch loadState {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let msg):
                FileLoadErrorView(item: item, message: msg)
            case .loaded(let text):
                ScrollView(.vertical) {
                    Text(text.isEmpty ? " " : text)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        let url = self.url
        // Cap at 2 MB for safety — large files fall through to QuickLook elsewhere.
        let result: MarkdownFilePreview.LoadState = await Task.detached(priority: .userInitiated) {
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: 2 * 1024 * 1024) ?? Data()
                let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1)
                    ?? ""
                return .loaded(text)
            } catch {
                return .failed(error.localizedDescription)
            }
        }.value
        await MainActor.run { self.loadState = result }
    }
}

private struct FileLoadErrorView: View {
    let item: FileItem
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(AppearanceStudio.shared.color(.secondaryText, scope: .files))
            Text("Could not read file")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(AppearanceStudio.shared.color(.secondaryText, scope: .files))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

private struct FileInfoView: View {
    let item: FileItem

    private var fileAttributes: [(String, String)] {
        let fm = FileManager.default
        var rows: [(String, String)] = []
        rows.append(("Name", item.name))
        rows.append(("Size", item.formattedSize))

        let ext = item.url.pathExtension
        if !ext.isEmpty {
            rows.append(("Type", ext.uppercased()))
        }

        if let attrs = try? fm.attributesOfItem(atPath: item.url.path) {
            if let created = attrs[.creationDate] as? Date {
                rows.append(("Created", Self.dateFormatter.string(from: created)))
            }
            if let modified = attrs[.modificationDate] as? Date {
                rows.append(("Modified", Self.dateFormatter.string(from: modified)))
            }
        }

        rows.append(("Path", item.url.path))
        return rows
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: item.iconName)
                        .font(.system(size: 48))
                        .foregroundStyle(AppearanceStudio.shared.color(.secondaryText, scope: .files))
                    Text("Preview not available")
                        .font(.subheadline)
                        .foregroundStyle(AppearanceStudio.shared.color(.secondaryText, scope: .files))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }

            Section("File Info") {
                ForEach(fileAttributes, id: \.0) { key, value in
                    HStack(alignment: .top) {
                        Text(key)
                            .foregroundStyle(AppearanceStudio.shared.color(.secondaryText, scope: .files))
                            .frame(width: 80, alignment: .leading)
                        Text(value)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

// MARK: - File Browser Row (with per-row delete confirmation)

private struct FileBrowserRow: View {
    let item: FileItem
    @ObservedObject var viewModel: FileBrowserViewModel
    let onTap: () -> Void
    let onExport: () -> Void
    let onMove: () -> Void
    let onCopy: () -> Void
    /// Called after the guest path is placed on the clipboard, so the parent
    /// can show the "Copied" toast. [T-ios-copy-abs-path-copied-toast]
    var onCopiedPath: () -> Void = {}
    /// [04b-2 §2] Delete confirmation and "Add to Home Screen" used to be a
    /// binding and a `@State` sheet mounted on EVERY row — with a long listing
    /// that is dozens of presentations competing with the page's own. Both are
    /// callbacks now; the page owns the single presentation.
    var onDelete: () -> Void = {}
    var onAddToHome: () -> Void = {}

    private var isHTML: Bool {
        guard !item.isDirectory else { return false }
        let ext = (item.name as NSString).pathExtension.lowercased()
        return ext == "html" || ext == "htm"
    }

    var body: some View {
        FileItemRow(item: item, onTap: onTap, onExport: onExport)
            .contextMenu {
                Button {
                    // [T-ios-file-context-copy-abs-path] Copy the file's guest
                    // absolute path (e.g. /var/minis/workspace/.../L3_0001.png)
                    // to the system clipboard. displayPath() is the same
                    // host-URL → guest-path mapping the breadcrumb uses, so we
                    // reuse it instead of reconstructing the path by hand.
                    UIPasteboard.general.string = viewModel.displayPath(for: item.url)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onCopiedPath()
                } label: {
                    Label(AppLocalized("Copy Absolute Path"), systemImage: "document.on.clipboard")
                }
                Button { onCopy() } label: {
                    Label("Copy to…", systemImage: "doc.on.doc")
                }
                Button { onMove() } label: {
                    Label("Move to…", systemImage: "folder.fill")
                }
                Divider()
                if !item.isDirectory {
                    Button { onExport() } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    if isHTML {
                        // WebApp entry point — file browser surfaces both
                        // shared and mounted folders, so this single hook
                        // covers two of the three required entry points.
                        Button { onAddToHome() } label: {
                            Label("Add to Home Screen", systemImage: "rectangle.stack.badge.plus")
                        }
                    }
                }
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
    }
}

// MARK: - File Item Row

struct FileItemRow: View {
    let item: FileItem
    let onTap: () -> Void
    let onExport: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            ZStack(alignment: .bottomLeading) {
                Image(systemName: item.iconName)
                    .font(.title2)
                    .foregroundColor(item.isDirectory ? AppearanceStudio.shared.color(.accent) : .secondary)
                if item.isSymlink {
                    Image(systemName: "arrow.turn.right.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(AppearanceStudio.shared.color(.warning, scope: .files))
                        .offset(x: -4, y: 2)
                }
            }
            .frame(width: 32)

            // Name and info
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.body)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if !item.isDirectory {
                        Text(item.formattedSize)
                    }
                    if item.modificationDate != nil {
                        if !item.isDirectory {
                            Text("·")
                        }
                        Text(item.formattedDate)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            // Export button for files
            if !item.isDirectory {
                Button(action: onExport) {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundColor(AppearanceStudio.shared.color(.accent, scope: .files))
                }
                .buttonStyle(.borderless)
            }

            // Chevron for directories
            if item.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
    }
}

// MARK: - Document Export View

/// [T-file-browser-export-share-sheet] Presents the SYSTEM share sheet for a
/// file, so the user chooses what to do (Save to Files, AirDrop, open in
/// another app, …) rather than being forced straight into the Files "save to"
/// picker. Previously this used `UIDocumentPickerViewController(forExporting:)`,
/// which can ONLY save to Files — the reported "分享按钮实际是保存" behavior.
///
/// The source lives on the rootfs/fakefs, which isn't a stable URL the share
/// extensions can read, so we stage a copy in tmp first (mirrors the old
/// export path), then hand it to `UIActivityViewController` (reusing
/// `MinisShareSheet.sanitizedShareURL` for the ShareKit UTI crash mitigation).
struct DocumentExportView: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        // Stage a stable copy in tmp so the share target can read it.
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileURL.lastPathComponent)
        try? FileManager.default.removeItem(at: staged)
        try? FileManager.default.copyItem(at: fileURL, to: staged)
        let shareURL = MinisShareSheet.sanitizedShareURL(staged) ?? staged
        return UIActivityViewController(activityItems: [shareURL], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - View Model

class FileBrowserViewModel: ObservableObject {
    @Published var items: [FileItem] = []
    @Published var isLoading = false
    @Published var showError = false
    @Published var errorMessage = ""
    @Published var pathComponents: [String] = []

    var sortKey: FileSortKey = .name
    var sortAscending: Bool = true
    var foldersFirst: Bool = true
    /// When false, entries whose name starts with `.` are hidden from the
    /// listing (Unix convention). Toggled by the Settings entry in the
    /// sort menu; persisted by the SwiftUI side via `@AppStorage`.
    var showHidden: Bool = false
    private var rawItems: [FileItem] = []
    /// Monotonic load generation — same anti-stale pattern as
    /// DirectoryPickerView.loadToken in this file.
    private var loadToken: UInt64 = 0

    let rootPath: URL
    let rootLabel: String
    private var currentPath: URL
    private var pathHistory: [URL] = []

    var canGoBack: Bool {
        currentPath.path != rootPath.path
    }

    init(rootPath: URL, initialPath: URL? = nil, rootLabel: String? = nil) {
        // Use standardized (not resolvingSymlinks) to normalize trailing slashes etc.
        self.rootPath = rootPath.standardized
        self.rootLabel = rootLabel ?? rootPath.lastPathComponent
        if let initialPath = initialPath?.standardized,
           initialPath.path.hasPrefix(self.rootPath.path) {
            self.currentPath = initialPath
        } else {
            self.currentPath = self.rootPath
        }
        updatePathComponents()
        loadItems()
    }

    func loadItems() {
        isLoading = true
        // [R3-033] Stamp this load and drop its result if a newer load has
        // started by the time it lands. Enumeration of a slow folder used
        // to unconditionally overwrite the CURRENT folder's listing, after
        // which delete/move built paths from the current path + stale
        // names and hit the wrong files.
        loadToken &+= 1
        let token = loadToken
        let pathToLoad = currentPath

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                // Resolve symlinks so contentsOfDirectory works on bind-mounted dirs
                // (e.g. /var/minis/attachments -> Library/MinisChat/...)
                let resolvedPath = pathToLoad.resolvingSymlinksInPath()
                // Note: we deliberately do NOT bulk-prefetch iCloud placeholder
                // files here. A large iCloud folder could contain thousands of
                // files, and kicking off that many simultaneous downloads just
                // to display file sizes is a bandwidth/storage hazard. Files
                // are downloaded on demand when the user opens them.
                // Drop FileManager's `.skipsHiddenFiles` option: it filters by
                // the macOS hidden flag AND dotfiles together, with no
                // user-toggleable override. The "Show Hidden Files" toggle
                // owns this decision now — we pull the full directory and
                // filter dotfiles ourselves when `showHidden == false`.
                let contents = try FileManager.default.contentsOfDirectory(
                    at: resolvedPath,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                    options: []
                )

                let showHiddenLocal = self.showHidden
                let fileItems = contents.compactMap { url -> FileItem? in
                    if !showHiddenLocal && url.lastPathComponent.hasPrefix(".") {
                        return nil
                    }
                    return FileItem(url: url)
                }

                DispatchQueue.main.async {
                    guard token == self.loadToken else { return }
                    self.rawItems = fileItems
                    self.applySort()
                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    guard token == self.loadToken else { return }
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                    self.isLoading = false
                }
            }
        }
    }

    func updateSort(key: FileSortKey, ascending: Bool, foldersFirst: Bool) {
        self.sortKey = key
        self.sortAscending = ascending
        self.foldersFirst = foldersFirst
        applySort()
    }

    func applySort() {
        let key = sortKey
        let ascending = sortAscending
        let foldersFirst = self.foldersFirst
        items = rawItems.sorted { a, b in
            if foldersFirst, a.isDirectory != b.isDirectory {
                return a.isDirectory
            }
            let order: ComparisonResult
            switch key {
            case .name:
                order = a.name.localizedCaseInsensitiveCompare(b.name)
            case .modified:
                let da = a.modificationDate ?? .distantPast
                let db = b.modificationDate ?? .distantPast
                order = da == db ? a.name.localizedCaseInsensitiveCompare(b.name)
                                 : (da < db ? .orderedAscending : .orderedDescending)
            case .size:
                if a.size == b.size {
                    order = a.name.localizedCaseInsensitiveCompare(b.name)
                } else {
                    order = a.size < b.size ? .orderedAscending : .orderedDescending
                }
            case .kind:
                let ka = a.isDirectory ? "" : a.url.pathExtension.lowercased()
                let kb = b.isDirectory ? "" : b.url.pathExtension.lowercased()
                if ka == kb {
                    order = a.name.localizedCaseInsensitiveCompare(b.name)
                } else {
                    order = ka.localizedCaseInsensitiveCompare(kb)
                }
            }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    func deleteItem(_ item: FileItem) {
        let fm = FileManager.default
        do {
            // Remove the item (or symlink) at the logical path.
            // Use the path relative to currentPath to ensure we hit the right file
            // in case the URL was resolved differently.
            let logicalURL = currentPath.resolvingSymlinksInPath().appendingPathComponent(item.name)
            let removedURL: URL
            if fm.fileExists(atPath: logicalURL.path) {
                try MountedFolderCoordinator.remove(at: logicalURL)
                removedURL = logicalURL
            } else {
                try MountedFolderCoordinator.remove(at: item.url)
                removedURL = item.url
            }
            if let linux = linuxPath(for: removedURL) {
                RootfsManager.shared.removeFakefsPath(linux)
                // If the deleted file lived under one of the FileProvider-exposed
                // trees (/var/minis/{shared,skills,memory}/...), the Files app has
                // a cached enumeration of the parent folder that is now stale.
                // The underlying storage is a bind mount into the App Group
                // container, so the file is already gone from disk — we just need
                // to tell the FileProvider to re-enumerate the parent.
                Self.signalFileProviderParent(forLinuxPath: linux)
            }
            // iCloud Sync: if the removed file lives under a session's
            // workspace tree (Library/MinisChat/minis/<sid>/...), queue
            // a SessionFile cloud-delete so peers stop seeing it.
            Self.queueSessionFileCloudDelete(forRemovedURL: removedURL)
            loadItems()
        } catch {
            errorMessage = "Cannot delete \"\(item.name)\": \(error.localizedDescription)"
            showError = true
        }
    }

    /// Maps a Linux path under `/var/minis/{shared,skills,memory}/...` to the
    /// parent-folder identifier used by the FileProvider extension, and asks the
    /// system to re-enumerate that folder so the Files app drops the stale entry.
    /// Linux paths outside those three trees are not exposed by the FileProvider
    /// and are skipped.
    private static let fileProviderExposedRoots: [String: NSFileProviderItemIdentifier] = [
        "/var/minis/shared":  NSFileProviderItemIdentifier("shared"),
        "/var/minis/skills":  NSFileProviderItemIdentifier("skills"),
        "/var/minis/memory":  NSFileProviderItemIdentifier("memory"),
    ]

    private static func signalFileProviderParent(forLinuxPath linux: String) {
        var parentID: NSFileProviderItemIdentifier? = nil
        for (linuxRoot, rootID) in fileProviderExposedRoots {
            // Exact match: deleting the top-level folder itself signals the root.
            if linux == linuxRoot {
                parentID = .rootContainer
                break
            }
            let prefix = linuxRoot + "/"
            guard linux.hasPrefix(prefix) else { continue }
            let relative = String(linux.dropFirst(prefix.count))
            // Derive the parent directory inside the exposed tree.
            let parentRelative = (relative as NSString).deletingLastPathComponent
            if parentRelative.isEmpty {
                // File sits directly under the exposed root (e.g. shared/foo.txt)
                parentID = rootID
            } else {
                // File sits in a nested folder (e.g. shared/sub/foo.txt)
                parentID = NSFileProviderItemIdentifier("\(rootID.rawValue)/\(parentRelative)")
            }
            break
        }
        guard let targetID = parentID else { return }

        let domainIdentifier = NSFileProviderDomainIdentifier("com.openminis.clone.files")
        NSFileProviderManager.getDomainsWithCompletionHandler { domains, _ in
            guard let domain = domains.first(where: { $0.identifier == domainIdentifier }) else {
                return
            }
            NSFileProviderManager(for: domain)?.signalEnumerator(for: targetID) { _ in }
        }
    }

    /// If `removedURL` lives inside a session's per-session minis directory
    /// (`Library/MinisChat/minis/<sid>/<subdir>/<rel>`), queue a SessionFile
    /// cloud-delete so peer devices stop seeing the file. Silent when the URL
    /// is outside any session tree (e.g. shared/skills/memory deletes — those
    /// are not SessionFile-scoped) or when sync isn't configured.
    private static func queueSessionFileCloudDelete(forRemovedURL removedURL: URL) {
        let baseURL = ChatStore.shared.minisBaseURL
            .resolvingSymlinksInPath().standardized
        let removed = removedURL.resolvingSymlinksInPath().standardized
        let basePath = baseURL.path
        let removedPath = removed.path
        let prefix = basePath + "/"
        guard removedPath.hasPrefix(prefix) else { return }

        let after = String(removedPath.dropFirst(prefix.count))
        // Layout: "<sid>/<subdir>/<rest>". Need at least sid + subdir + 1
        // path component to constitute a SessionFile recordId.
        let parts = after.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return }
        let sid = String(parts[0])
        let rel = String(parts[1])
        guard !sid.isEmpty, !rel.isEmpty else { return }

        // Only the session-scoped subdirs are SessionFiles. Filter early
        // so global trees (memory/skills/shared) and stray dirs don't
        // produce phantom cloud deletes.
        let firstSlash = rel.firstIndex(of: "/")
        let subdir: String = firstSlash.map { String(rel[..<$0]) } ?? rel
        let scoped: Set<String> = ["workspace", "attachments", "browser", "offloads"]
        guard scoped.contains(subdir) else { return }

        let traceLogger = AppLogger(category: "SessionFileTracker")
        traceLogger.info("[SessionFileTracker] FileBrowser delete → cloud delete queued: sid=\(sid.prefix(8)) rel=\(rel.prefix(80))")
        Task.detached(priority: .utility) {
            await ChatStore.shared.markSessionFileForCloudDeletion(
                sessionId: sid, relPath: rel)
            // Drain any tracker entry for the same path so a stale
            // upsert event recorded just before the user-driven delete
            // doesn't race the explicit op=delete row we just queued.
            _ = await SessionFileChangeTracker.shared.drainSession(sid)
            if #available(iOS 17.0, *) {
                await MainActor.run { SyncCore.shared.scheduleSend() }
            }
        }
    }

    /// Emit an `[FPSyncTrace]` line describing a host-filesystem write/copy/move
    /// that lands inside one of the three FileProvider-exposed roots
    /// (shared/skills/memory). Stays silent for writes outside those trees so
    /// the log doesn't get noisy when the user is just browsing the rootfs.
    /// Filenames are deliberately omitted — only structural info is logged.
    static func tracePotentialFPWrite(op: String, destURL: URL, srcURL: URL? = nil) {
        let fm = FileManager.default
        let dest = destURL.resolvingSymlinksInPath().standardized.path
        let roots: [(String, URL)] = [
            ("shared", AIChatViewModel.minisSharedPersistentDir),
            ("skills", AIChatViewModel.minisSkillsPersistentDir),
            ("memory", AIChatViewModel.minisMemoryPersistentDir),
        ]
        for (key, rootURL) in roots {
            let rootPath = rootURL.resolvingSymlinksInPath().standardized.path
            guard dest == rootPath || dest.hasPrefix(rootPath + "/") else { continue }
            let depth: Int = {
                if dest == rootPath { return 0 }
                let rel = String(dest.dropFirst(rootPath.count + 1))
                return rel.split(separator: "/").count
            }()
            let exists = fm.fileExists(atPath: dest)
            let size = (try? fm.attributesOfItem(atPath: dest)[.size] as? UInt64) ?? 0
            AppLogger(category: "FPSyncTrace").info("[FPSyncTrace] FileBrowser op=\(op) root=\(key) depth=\(depth) bytes=\(size) exists=\(exists)")
            return
        }
    }

    @discardableResult
    func moveItem(_ item: FileItem, to destinationDir: URL) -> Bool {
        let fm = FileManager.default
        let resolvedDest = destinationDir.resolvingSymlinksInPath()
        let destURL = resolvedDest.appendingPathComponent(item.name)
        do {
            if fm.fileExists(atPath: destURL.path) {
                errorMessage = "A file named \"\(item.name)\" already exists in the destination."
                showError = true
                return false
            }
            let srcURL = currentPath.resolvingSymlinksInPath().appendingPathComponent(item.name)
            try MountedFolderCoordinator.move(from: srcURL, to: destURL)
            if let srcLinux = linuxPath(for: srcURL) {
                RootfsManager.shared.removeFakefsPath(srcLinux)
            }
            RootfsManager.shared.registerSubtreeInMetaDB(hostRoot: destURL)
            Self.tracePotentialFPWrite(op: "move", destURL: destURL, srcURL: srcURL)
            loadItems()
            return true
        } catch {
            errorMessage = "Cannot move \"\(item.name)\": \(error.localizedDescription)"
            showError = true
            return false
        }
    }

    @discardableResult
    func copyItem(_ item: FileItem, to destinationDir: URL) -> Bool {
        let fm = FileManager.default
        let resolvedDest = destinationDir.resolvingSymlinksInPath()
        let destURL = resolvedDest.appendingPathComponent(item.name)
        do {
            if fm.fileExists(atPath: destURL.path) {
                errorMessage = "A file named \"\(item.name)\" already exists in the destination."
                showError = true
                return false
            }
            let srcURL = currentPath.resolvingSymlinksInPath().appendingPathComponent(item.name)
            try MountedFolderCoordinator.copy(from: srcURL, to: destURL)
            RootfsManager.shared.registerSubtreeInMetaDB(hostRoot: destURL)
            Self.tracePotentialFPWrite(op: "copy", destURL: destURL, srcURL: srcURL)
            loadItems()
            return true
        } catch {
            errorMessage = "Cannot copy \"\(item.name)\": \(error.localizedDescription)"
            showError = true
            return false
        }
    }

    func displayPath(for url: URL) -> String {
        // [T-ios-copy-abs-path-varminis-rooted] Primary path: reconstruct the
        // guest path from `currentPath` (the LOGICAL, un-symlink-resolved
        // directory we're browsing, e.g. `.../data/var/minis/browser`) + the
        // item's filename, relative to `rootPath`.
        //
        // Why this is the reliable source: `loadItems()` lists
        // `currentPath.resolvingSymlinksInPath()`, so each `item.url` is already
        // symlink-RESOLVED. For a bind-mounted subdir like `/var/minis/browser`
        // (an APFS symlink → `.../Library/MinisChat/minis/<sid>/browser`) the
        // resolved item URL lands OUTSIDE the rootfs `data/` tree, so BOTH the
        // resolved-prefix and raw-prefix checks below miss and the function fell
        // through to `url.lastPathComponent` — copying just the filename
        // (`0419….jpg`) instead of `/var/minis/browser/0419….jpg`.
        // `currentPath` is never symlink-resolved (init standardizes; navigateTo
        // appends names), so `currentPath` relative to `rootPath` is always the
        // true guest directory regardless of bind mounts.
        let rawRootEarly = rootPath.standardized.path
        let curStd = currentPath.standardized.path
        if curStd == rawRootEarly || curStd.hasPrefix(rawRootEarly + "/") {
            let relDir = String(curStd.dropFirst(rawRootEarly.count))   // "" or "/var/minis/browser"
            let full = join(rootLabel, relDir)
            return join(full, url.lastPathComponent)
        }
        // [T-ios-copy-abs-path-fullpath] Fallbacks (kept for any item URL not
        // under currentPath). `item.url` is symlink-RESOLVED; compare in the
        // resolved namespace so the prefix matches.
        let rootStd = rootPath.resolvingSymlinksInPath().standardized.path
        let urlStd = url.resolvingSymlinksInPath().standardized.path
        if urlStd.hasPrefix(rootStd) {
            return join(rootLabel, String(urlStd.dropFirst(rootStd.count)))
        }
        // [T-ios-copy-abs-path-fullpath] Bind-mounted subtrees (attachments →
        // MinisChat container) resolve OUTSIDE the rootfs `data/` tree, so the
        // resolved prefix check above won't match them. Fall back to the
        // UN-resolved namespace: the listing keeps the logical `/var/minis/…`
        // path on the URL before symlink resolution would diverge.
        let rawRoot = rootPath.standardized.path
        let rawURL = url.standardized.path
        if rawURL.hasPrefix(rawRoot) {
            return join(rootLabel, String(rawURL.dropFirst(rawRoot.count)))
        }
        // Last resort: at least keep the filename rather than returning an
        // empty string. This should be unreachable for files listed here.
        return url.lastPathComponent
    }

    /// [T-ios-copy-abs-path-fullpath] Join the guest `rootLabel` with a
    /// relative remainder, collapsing the slash seam so a `rootLabel` of "/"
    /// plus a rel of "/var/minis/x" yields "/var/minis/x" (not "//var/minis/x")
    /// — important now that the result is copied to the clipboard as a real
    /// path, not just shown as a cosmetic breadcrumb.
    private func join(_ label: String, _ rel: String) -> String {
        if rel.isEmpty { return label }
        if label.hasSuffix("/") && rel.hasPrefix("/") {
            return label + rel.dropFirst()
        }
        if !label.hasSuffix("/") && !rel.hasPrefix("/") {
            return label + "/" + rel
        }
        return label + rel
    }

    /// Import picked files. Returns the failure message (nil on full success)
    /// instead of raising the alert itself.
    ///
    /// [P0 04b-2] The caller presents this from inside `DocumentCopyPicker`,
    /// whose delegate runs `onPick` **before** `onDone`. Setting `showError`
    /// there fired an alert while the picker sheet was still on screen, and
    /// SwiftUI drops an alert requested during a presentation — so the import
    /// failed and nothing was ever shown, which is the same "external mount
    /// does nothing" complaint this round was meant to close. Returning the
    /// message lets the caller raise it after the sheet is gone.
    @discardableResult
    func importFiles(_ urls: [URL]) -> String? {
        let fm = FileManager.default
        let destDir = currentPath.resolvingSymlinksInPath()
        var failCount = 0
        // [K-7] "Failed to import 3 file(s)." told the user nothing they could
        // act on — the usual cause is a read-only mount or a file provider
        // that has not downloaded the item yet, and both come with a usable
        // reason. Keep the first one and show it.
        var firstFailure: String?
        for url in urls {
            // [K-7] `startAccessingSecurityScopedResource()` returns FALSE for
            // a copy-mode URL — the file is already a plain file: URL inside
            // the app's tmp, so there is no scope to enter. Treating that false
            // as "unreadable" is what turned every copy-mode pick into
            // "Could not access the file": the old guard rejected the one URL
            // shape that actually works on a sideloaded build.
            //
            // The call is kept as an OPTIONAL grant for in-place URLs that may
            // still reach here from other callers; only a failed *copy* counts
            // as a failure now.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let destURL = destDir.appendingPathComponent(url.lastPathComponent)
            // [R3-034] Preserve the file being replaced until the new copy
            // is safely in place. The old flow deleted the original first,
            // so a failed copy (full disk, source vanished mid-import)
            // destroyed BOTH the original and the import.
            var stashURL: URL?
            do {
                if fm.fileExists(atPath: destURL.path) {
                    let stash = destDir.appendingPathComponent(".minis-import-stash-\(UUID().uuidString)")
                    try MountedFolderCoordinator.move(from: destURL, to: stash)
                    stashURL = stash
                    if let destLinux = linuxPath(for: destURL) {
                        RootfsManager.shared.removeFakefsPath(destLinux)
                    }
                }
                try MountedFolderCoordinator.copy(from: url, to: destURL)
                RootfsManager.shared.registerSubtreeInMetaDB(hostRoot: destURL)
                Self.tracePotentialFPWrite(op: "import", destURL: destURL, srcURL: url)
                if let stashURL {
                    try? MountedFolderCoordinator.remove(at: stashURL)
                }
            } catch {
                failCount += 1
                if firstFailure == nil {
                    firstFailure = error.localizedDescription
                }
                // Roll back: drop any partial copy, then put the original back.
                if let stashURL {
                    if fm.fileExists(atPath: destURL.path) {
                        try? MountedFolderCoordinator.remove(at: destURL)
                        if let destLinux = linuxPath(for: destURL) {
                            RootfsManager.shared.removeFakefsPath(destLinux)
                        }
                    }
                    try? MountedFolderCoordinator.move(from: stashURL, to: destURL)
                    RootfsManager.shared.registerSubtreeInMetaDB(hostRoot: destURL)
                }
            }
        }
        if failCount > 0 {
            // [K-7] Name the reason, not just the count.
            let countText = String(format: AppLocalized("Failed to import %d file(s)."), failCount)
            let message = firstFailure.map { "\(countText)\n\($0)" } ?? countText
            loadItems()
            return message
        }
        loadItems()
        return nil
    }

    /// Convert a host-filesystem URL under `rootPath` to its corresponding Linux
    /// path inside the fakefs (e.g. `.../alpine-rootfs/data/root/foo` → `/root/foo`).
    /// Returns nil when the URL is not under the fakefs `data/` tree — callers
    /// should skip meta.db updates in that case (e.g. when browsing the rootfs
    /// container directory itself, or mounted iCloud folders).
    private func linuxPath(for hostURL: URL) -> String? {
        let dataPrefix = RootfsManager.shared.dataPath.standardized.path
        let std = hostURL.standardized.path
        if std == dataPrefix { return "/" }
        guard std.hasPrefix(dataPrefix + "/") else { return nil }
        return String(std.dropFirst(dataPrefix.count))
    }

    func navigateTo(_ item: FileItem) {
        guard item.isDirectory else { return }
        pathHistory.append(currentPath)
        // Use appendingPathComponent instead of item.url directly to preserve
        // the logical path within rootPath. Using item.url.standardizedFileURL
        // would resolve symlinks, breaking path prefix checks when bind-mounted
        // directories point outside the rootfs.
        currentPath = currentPath.appendingPathComponent(item.name)
        updatePathComponents()
        loadItems()
    }

    func goBack() {
        guard canGoBack else { return }
        currentPath = currentPath.deletingLastPathComponent()
        if currentPath.path.count < rootPath.path.count {
            currentPath = rootPath
        }
        pathHistory.removeAll { $0 == currentPath }
        updatePathComponents()
        loadItems()
    }

    func navigateToPathComponent(at index: Int) {
        guard index >= 0 else { return }

        var targetPath = rootPath
        if index > 0 {
            for i in 1...index {
                if i < pathComponents.count {
                    targetPath = targetPath.appendingPathComponent(pathComponents[i])
                }
            }
        }
        currentPath = targetPath
        updatePathComponents()
        loadItems()
    }

    private func updatePathComponents() {
        let rootStd = rootPath.path
        let currentStd = currentPath.path
        let relativePath: String
        if currentStd.hasPrefix(rootStd) {
            relativePath = String(currentStd.dropFirst(rootStd.count))
        } else {
            relativePath = ""
        }
        var components = [rootLabel]
        if !relativePath.isEmpty {
            components += relativePath.split(separator: "/").map(String.init)
        }
        pathComponents = components
    }
}

// MARK: - File Item Model

struct FileItem: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: Int64
    let modificationDate: Date?
    /// Lowercased extension of the symlink *target* (or of `url` itself when
    /// not a link). Precomputed in `init?` so `iconName` — evaluated in `body`
    /// for every visible row — never has to resolve the link again.
    let resolvedPathExtension: String

    init?(url: URL) {
        self.url = url
        self.name = url.lastPathComponent

        // Single combined resourceValues call covers both symlink detection and
        // file metadata in one syscall per entry. For directories with 10k+
        // items, halving the per-entry work noticeably speeds up listing.
        let allKeys: Set<URLResourceKey> = [
            .isSymbolicLinkKey,
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        let values = try? url.resourceValues(forKeys: allKeys)
        let isLink = values?.isSymbolicLink ?? false
        self.isSymlink = isLink

        if isLink {
            // For symlinks, `.isDirectoryKey`/`.fileSizeKey` from the link URL
            // refer to the link itself. Follow the link to get real target info.
            let resolved = url.resolvingSymlinksInPath()
            let targetValues = try? resolved.resourceValues(forKeys: [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
            ])
            self.isDirectory = targetValues?.isDirectory ?? false
            self.size = Int64(targetValues?.fileSize ?? 0)
            self.modificationDate = targetValues?.contentModificationDate
            // Capture the target's extension now, while we're already off the
            // main thread and have the resolved URL in hand. `iconName` is read
            // from `body` for every visible row; re-resolving the symlink there
            // meant a `getattrlist(2)` per row per body pass, which blocks the
            // main thread when the link points into a slow or unreachable
            // mounted volume.
            self.resolvedPathExtension = resolved.pathExtension.lowercased()
        } else {
            guard let values else { return nil }
            self.isDirectory = values.isDirectory ?? false
            self.size = Int64(values.fileSize ?? 0)
            self.modificationDate = values.contentModificationDate
            self.resolvedPathExtension = url.pathExtension.lowercased()
        }
    }

    var iconName: String {
        if isDirectory {
            return "folder.fill"
        }

        let ext = resolvedPathExtension
        switch ext {
        case "txt", "md", "json", "xml", "yaml", "yml":
            return "doc.text"
        case "sh", "bash", "zsh":
            return "terminal"
        case "py":
            return "chevron.left.forwardslash.chevron.right"
        case "js", "ts", "swift", "c", "cpp", "h", "m":
            return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "bmp", "svg":
            return "photo"
        case "mp3", "wav", "aac", "flac":
            return "music.note"
        case "mp4", "mov", "avi", "mkv":
            return "film"
        case "zip", "tar", "gz", "bz2", "xz":
            return "doc.zipper"
        case "pdf":
            return "doc.richtext"
        default:
            return "doc"
        }
    }

    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    var formattedDate: String {
        guard let date = modificationDate else { return "" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return Self.timeFormatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else if let daysAgo = calendar.dateComponents([.day], from: date, to: Date()).day, daysAgo < 7 {
            return Self.weekdayFormatter.string(from: date)
        } else {
            return Self.shortDateFormatter.string(from: date)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f
    }()

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()
}

// MARK: - File Import Picker
//
// `FileImportPicker` (a `asCopy: false` wrapper) was deleted here: the only
// caller now uses `DocumentCopyPicker`, and keeping an open-in-place picker
// around invites the same "Open does nothing" regression on the next edit.

// MARK: - Directory Picker

private struct DirectoryPickerView: View {
    let rootPath: URL
    let rootLabel: String
    let excludedURL: URL
    let title: String
    let onSelect: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var currentDir: URL
    @State private var items: [FileItem] = []
    @State private var pathComponents: [String] = []
    /// Monotonic id for the in-flight `loadDirectories` task, so a slow
    /// enumeration that finishes after the user has already navigated
    /// elsewhere doesn't overwrite the newer listing.
    @State private var loadToken: UInt64 = 0

    init(rootPath: URL, rootLabel: String, initialPath: URL? = nil, excludedURL: URL, title: String, onSelect: @escaping (URL) -> Void) {
        self.rootPath = rootPath
        self.rootLabel = rootLabel
        self.excludedURL = excludedURL
        self.title = title
        self.onSelect = onSelect
        let start: URL
        if let initialPath, initialPath.path.hasPrefix(rootPath.path) {
            start = initialPath
        } else {
            start = rootPath
        }
        _currentDir = State(initialValue: start)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Breadcrumb
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(pathComponents.indices, id: \.self) { index in
                        Button { navigateTo(index: index) } label: {
                            Text(pathComponents[index])
                                .font(.caption)
                                .foregroundColor(AppearanceStudio.shared.color(.accent, scope: .files))
                        }
                        if index < pathComponents.count - 1 {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .background(AppearanceStudio.shared.color(.surface))

            // Directory list
            if items.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("Empty folder")
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                List {
                    ForEach(items) { item in
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill")
                                .font(.title2)
                                .foregroundColor(AppearanceStudio.shared.color(.accent, scope: .files))
                            Text(item.name)
                                .font(.body)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            currentDir = currentDir.appendingPathComponent(item.name)
                            loadDirectories()
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Select") {
                    onSelect(currentDir)
                }
            }
        }
        .onAppear { loadDirectories() }
    }

    /// Enumerate `currentDir`'s subdirectories on a background queue.
    ///
    /// Every call here is a filesystem touch — `resolvingSymlinksInPath()`,
    /// `contentsOfDirectory`, and `FileItem.init?`'s per-child
    /// `resourceValues(forKeys:)` — and `currentDir` can be inside a mounted
    /// external folder backed by a network share or another app's
    /// FileProvider. On such a volume each of those is a synchronous XPC
    /// round-trip to the provider, so running this loop inline from
    /// `.onAppear` (as it used to) blocked the main thread for as long as the
    /// volume took to answer, tripping the 10s scene-update watchdog. Hop off
    /// the main actor and publish results back when done.
    private func loadDirectories() {
        updatePathComponents()
        let dir = currentDir
        let excluded = excludedURL
        loadToken &+= 1
        let token = loadToken
        Task.detached(priority: .userInitiated) {
            let resolved = dir.resolvingSymlinksInPath()
            let fm = FileManager.default
            let contents = (try? fm.contentsOfDirectory(
                at: resolved,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            // Resolve the exclusion once, not once per child.
            let excludedPath = excluded.resolvingSymlinksInPath().path
            let loaded = contents.compactMap { url -> FileItem? in
                let item = FileItem(url: url)
                guard let item, item.isDirectory else { return nil }
                // Exclude the source item's directory to prevent moving into itself
                if url.resolvingSymlinksInPath().path == excludedPath { return nil }
                return item
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            await MainActor.run {
                // Drop results from a superseded load (user navigated again
                // while a slow volume was still enumerating).
                guard token == loadToken else { return }
                items = loaded
            }
        }
    }

    private func navigateTo(index: Int) {
        var target = rootPath
        if index > 0 {
            for i in 1...index where i < pathComponents.count {
                target = target.appendingPathComponent(pathComponents[i])
            }
        }
        currentDir = target
        loadDirectories()
    }

    private func updatePathComponents() {
        let rootStd = rootPath.path
        let currentStd = currentDir.path
        var components = [rootLabel]
        if currentStd.hasPrefix(rootStd) {
            let rel = String(currentStd.dropFirst(rootStd.count))
            if !rel.isEmpty {
                components += rel.split(separator: "/").map(String.init)
            }
        }
        pathComponents = components
    }
}

#Preview {
    NavigationStack {
        FileBrowserView()
    }
}
