import SwiftUI

// MARK: - View Model

class StorageManagementViewModel: ObservableObject {
    struct SessionStorage: Identifiable {
        let id: String
        let title: String?
        var minisSize: Int64 = 0
        var totalSize: Int64 { minisSize }
    }

    @Published var shellContainerSize: Int64 = 0
    @Published var chatDatabaseSize: Int64 = 0
    @Published var sessions: [SessionStorage] = []
    @Published var isLoading = true
    /// [MSC-4] Cache-category sizes: TTS disk cache + URL response cache.
    @Published var ttsCacheSize: Int64 = 0
    @Published var networkCacheSize: Int64 = 0
    /// [B09-S05 2026-10-22] AI voice bubbles live in each session's attachments
    /// folder as tts-*.wav/.mp3 and were never counted or cleanable anywhere.
    @Published var voiceFileCount: Int = 0
    @Published var voiceFileSize: Int64 = 0
    var totalCacheSize: Int64 { ttsCacheSize + networkCacheSize }

    private let fm = FileManager.default
    private let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        f.countStyle = .file
        return f
    }()

    func format(_ bytes: Int64) -> String {
        formatter.string(fromByteCount: bytes)
    }

    var totalSessionSize: Int64 {
        sessions.reduce(0) { $0 + $1.totalSize }
    }

    func load() {
        isLoading = true
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            let libraryURL = self.fm.urls(for: .libraryDirectory, in: .userDomainMask).first!
            let documentsURL = self.fm.urls(for: .documentDirectory, in: .userDomainMask).first!

            // Shell container
            let rootfsURL = documentsURL.appendingPathComponent("alpine-rootfs", isDirectory: true)
            let shellSize = self.directorySize(at: rootfsURL)

            // Chat database
            let dbURL = libraryURL.appendingPathComponent("MinisChat/minis.db")
            let dbSize = self.fileSize(at: dbURL)

            // [MSC-4] Caches
            let ttsSize = Int64(TTSDiskCache.totalBytes())
            let netSize = Int64(URLCache.shared.currentDiskUsage)
            // [B09-S05 2026-10-22] AI voice bubbles on disk (never counted before).
            let voiceStats = AIVoiceMessageComposer.voiceFileStats()

            // Per-session minis files: Library/MinisChat/minis/<sessionId>/
            let minisBaseURL = libraryURL.appendingPathComponent("MinisChat/minis", isDirectory: true)
            // Get all chat sessions
            let chatSessions = await ChatStore.shared.listSessions().filter { !$0.isChild }

            // Build a set of session IDs
            let sessionIds = Set(chatSessions.map(\.id))

            // Enumerate minis directories
            var minisSizes: [String: Int64] = [:]
            if let contents = try? self.fm.contentsOfDirectory(at: minisBaseURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                for dir in contents {
                    let sid = dir.lastPathComponent
                    if sessionIds.contains(sid) {
                        minisSizes[sid] = self.directorySize(at: dir)
                    }
                }
            }

            // Build session storage entries
            let sorted: [SessionStorage] = chatSessions.map { session in
                SessionStorage(
                    id: session.id,
                    title: session.title,
                    minisSize: minisSizes[session.id] ?? 0
                )
            }.sorted { $0.totalSize > $1.totalSize }

            await MainActor.run {
                self.shellContainerSize = shellSize
                self.chatDatabaseSize = dbSize
                self.sessions = sorted
                self.ttsCacheSize = ttsSize
                self.networkCacheSize = netSize
                self.voiceFileCount = voiceStats.count
                self.voiceFileSize = voiceStats.bytes
                self.isLoading = false
            }
        }
    }

    /// [MSC-4] One-tap cache clear: every regenerable cache in one place.
    func clearCaches() {
        Task.detached(priority: .userInitiated) { [weak self] in
            TTSDiskCache.clearAll()
            // [B09-N12 2026-10-22] The 64-entry memory layer lives in the player
            // and outlived a disk clear — replaying a sentence right after
            // still hit memory, so "cleared" looked like a lie until restart.
            await MainActor.run { VoiceOutputPlayer.shared.clearSynthCache() }
            URLCache.shared.removeAllCachedResponses()
            ThumbnailCache.shared.removeAll()
            self?.load()
        }
    }

    private func directorySize(at url: URL) -> Int64 {
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if values?.isDirectory == false {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    private func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}

// MARK: - Storage Management View

struct StorageManagementView: View {
    @StateObject private var vm = StorageManagementViewModel()
    @State private var showClearCachesConfirmation = false
    @State private var showClearVoiceFilesConfirmation = false

    var body: some View {
        List {
            Section("Overview") {
                storageRow(icon: "terminal", color: .gray, label: "Shell Container", value: vm.format(vm.shellContainerSize))
                storageRow(icon: "cylinder", color: .blue, label: "Chat Database", value: vm.format(vm.chatDatabaseSize))
                storageRow(icon: "doc", color: .indigo, label: "Session Files", value: vm.format(vm.totalSessionSize))
            }

            // [MSC-4] Unified cache category + one-tap clear.
            Section(AppLocalized("Caches")) {
                storageRow(icon: "waveform", color: .orange, label: AppLocalized("Voice cache"),
                           value: vm.format(vm.ttsCacheSize))
                storageRow(icon: "network", color: .teal, label: AppLocalized("Network cache"),
                           value: vm.format(vm.networkCacheSize))
                Button(role: .destructive) {
                    showClearCachesConfirmation = true
                } label: {
                    Text(AppLocalized("Clear all caches"))
                }
                .disabled(vm.totalCacheSize == 0)
            }

            // [B09-S05 2026-10-22] AI voice bubbles: real files in each
            // session's attachments folder, never listed or reclaimable before.
            if vm.voiceFileCount > 0 {
                Section {
                    storageRow(icon: "waveform.circle", color: .pink,
                               label: AppLocalized("AI voice messages"),
                               value: "\(vm.voiceFileCount) · \(vm.format(vm.voiceFileSize))")
                    Button(role: .destructive) {
                        showClearVoiceFilesConfirmation = true
                    } label: {
                        Text(AppLocalized("Delete voice files older than 30 days"))
                    }
                } header: {
                    Text(AppLocalized("Voice files"))
                } footer: {
                    Text(AppLocalized("Voice messages are stored as audio files in each chat. Deleting old ones frees space; those bubbles lose their audio, their text stays."))
                }
            }

            Section("Sessions") {
                if vm.isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if vm.sessions.isEmpty {
                    Text("No sessions")
                        .foregroundStyle(MinisTheme.secondaryText)
                } else {
                    ForEach(vm.sessions) { session in
                        NavigationLink {
                            SessionStorageDetailView(session: session, onFilesCleared: { vm.load() })
                        } label: {
                            HStack {
                                Text(session.title ?? "Untitled")
                                    .lineLimit(1)
                                Spacer()
                                Text(vm.format(session.totalSize))
                                    .foregroundStyle(MinisTheme.secondaryText)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { vm.load() }
        .confirmationDialog(AppLocalized("Delete old voice files?"),
                            isPresented: $showClearVoiceFilesConfirmation,
                            titleVisibility: .visible) {
            Button(AppLocalized("Delete"), role: .destructive) {
                Task.detached(priority: .userInitiated) {
                    _ = AIVoiceMessageComposer.clearVoiceFiles(olderThanDays: 30)
                    await MainActor.run { vm.load() }
                }
            }
            Button(AppLocalized("Cancel"), role: .cancel) {}
        } message: {
            Text(AppLocalized("Voice messages older than 30 days lose their audio. Their text stays in the chat."))
        }
        .confirmationDialog(AppLocalized("Clear all caches?"),
                            isPresented: $showClearCachesConfirmation,
                            titleVisibility: .visible) {
            Button(AppLocalized("Clear"), role: .destructive) { vm.clearCaches() }
            Button(AppLocalized("Cancel"), role: .cancel) {}
        } message: {
            Text(AppLocalized("Cached voice audio and network responses will be removed. They are downloaded again when needed."))
        }
        .settingsPage()
    }

    private func storageRow(icon: String, color: Color, label: String, value: String) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppearanceStudio.shared.color(.primaryText))
                .frame(width: 22, height: 22)
                .background(AppearanceStudio.shared.color(.surface), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(AppearanceStudio.shared.color(.border).opacity(0.4), lineWidth: 0.6)
                )
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(MinisTheme.secondaryText)
        }
    }
}

// MARK: - Session Storage Detail View

struct SessionStorageDetailView: View {
    let session: StorageManagementViewModel.SessionStorage
    var onFilesCleared: (() -> Void)?

    @State private var showClearConfirmation = false
    @State private var isClearing = false
    @State private var currentMinisSize: Int64

    init(session: StorageManagementViewModel.SessionStorage, onFilesCleared: (() -> Void)? = nil) {
        self.session = session
        self.onFilesCleared = onFilesCleared
        _currentMinisSize = State(initialValue: session.minisSize)
    }

    private let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        f.countStyle = .file
        return f
    }()

    private var minisURL: URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return lib.appendingPathComponent("MinisChat/minis/\(session.id)", isDirectory: true)
    }

    private var totalFileSize: Int64 { currentMinisSize }
    private var hasFiles: Bool { totalFileSize > 0 }

    var body: some View {
        List {
            Section("嘟嘟 Files") {
                if currentMinisSize > 0 {
                    NavigationLink {
                        FileBrowserView(rootPath: minisURL)
                    } label: {
                        HStack {
                            Label("Browse Files", systemImage: "folder.fill")
                            Spacer()
                            Text(formatter.string(fromByteCount: currentMinisSize))
                                .foregroundStyle(MinisTheme.secondaryText)
                        }
                    }
                } else {
                    Text("No minis files")
                        .foregroundStyle(MinisTheme.secondaryText)
                }
            }

            Section {
                Button(role: .destructive) {
                    showClearConfirmation = true
                } label: {
                    HStack {
                        if isClearing {
                            ProgressView()
                                .controlSize(.small)
                            Text("Clearing…")
                        } else {
                            Label("Clear Session Files", systemImage: "trash")
                        }
                        Spacer()
                        if !isClearing {
                            Text(formatter.string(fromByteCount: totalFileSize))
                                .foregroundStyle(MinisTheme.secondaryText)
                        }
                    }
                }
                .disabled(!hasFiles || isClearing)
            } footer: {
                Text("Removes all files generated by this session. The conversation itself will be preserved.")
            }
        }
        .navigationTitle(session.title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Clear Session Files?", isPresented: $showClearConfirmation) {
            Button("Clear \(formatter.string(fromByteCount: totalFileSize))", role: .destructive) {
                clearFiles()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will delete \(formatter.string(fromByteCount: totalFileSize)) of files. This action cannot be undone.")
        }
    }

    private func clearFiles() {
        isClearing = true
        let sessionId = session.id
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let lib = fm.urls(for: .libraryDirectory, in: .userDomainMask).first!
            let minisDir = lib.appendingPathComponent("MinisChat/minis/\(sessionId)", isDirectory: true)
            try? fm.removeItem(at: minisDir)

            await MainActor.run {
                currentMinisSize = 0
                isClearing = false
                onFilesCleared?()
            }
        }
    }
}
