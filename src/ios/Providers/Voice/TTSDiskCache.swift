import Foundation

// MARK: - TTS synthesis disk cache
//
// [TTS-7] The read-aloud synthesis cache used to be memory-only (last 64
// segments): quitting the app threw every paid-for synthesis away, and
// replaying a reply after relaunch re-billed every segment. This layer
// persists segments under Caches/MinisTTSCache (system-purgeable, the
// right semantics for a cache), keyed by a fingerprint the player builds
// from candidate + voice + tuning + text — see VoiceOutputPlayer.
//
// Bounds: at most `maxBytes` total and `maxEntries` files; storing past
// either bound evicts least-recently-modified files until it fits.
// `clearAll` is the single clearing entry point (storage settings /
// MSC-4 cache category call it).
enum TTSDiskCache {

    static let maxBytes = 100 * 1024 * 1024
    static let maxEntries = 500

    private static let queue = DispatchQueue(label: "minis.tts.diskcache")

    static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MinisTTSCache", isDirectory: true)
    }

    private static func fileURL(for key: String) -> URL {
        // Keys are hex fingerprints built by the caller; sanitize anyway
        // so a key can never escape the cache directory.
        let safe = key.filter { $0.isLetter || $0.isNumber }
        return directory.appendingPathComponent(safe.isEmpty ? "empty" : safe, isDirectory: false)
    }

    /// [B09-N13 2026-10-22] Non-blocking load for the read-aloud hot path.
    /// `load` uses `queue.sync`, and the caller (VoiceOutputPlayer.cachedAudio)
    /// runs on the MainActor — so every cache probe on every candidate did a
    /// synchronous disk read on the main thread before the first syllable could
    /// start. This variant hops to the cache queue instead.
    static func loadAsync(key: String) async -> Data? {
        await withCheckedContinuation { cont in
            queue.async {
                cont.resume(returning: loadLocked(key: key))
            }
        }
    }

    private static func loadLocked(key: String) -> Data? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }

    /// [B09-R9 2026-10-22] Non-blocking write for the synthesis hot path. The
    /// synchronous `store` blocks the MainActor on file IO + prune for every
    /// synthesized unit.
    static func storeAsync(key: String, data: Data) {
        guard !data.isEmpty, data.count <= maxBytes else { return }
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: fileURL(for: key), options: .atomic)
            pruneLocked()
        }
    }

    static func clearAll() {
        queue.sync {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    static func totalBytes() -> Int {
        queue.sync { entriesLocked().reduce(0) { $0 + $1.size } }
    }

    // MARK: - Internals (call on `queue`)

    private static func entriesLocked() -> [(url: URL, size: Int, mtime: Date)] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return files.compactMap { url in
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard let size = v?.fileSize else { return nil }
            return (url, size, v?.contentModificationDate ?? .distantPast)
        }
    }

    private static func pruneLocked() {
        var entries = entriesLocked().sorted { $0.mtime < $1.mtime }  // oldest first
        var total = entries.reduce(0) { $0 + $1.size }
        while (total > maxBytes || entries.count > maxEntries), let victim = entries.first {
            entries.removeFirst()
            total -= victim.size
            try? FileManager.default.removeItem(at: victim.url)
        }
    }
}
