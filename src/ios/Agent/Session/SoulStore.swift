import Foundation
import SwiftUI
import UIKit

/// [T-soul-custom-icon] Encode/decode for the Soul identity icon when the
/// user picks an image rather than an emoji.
///
/// Lives in this file rather than its own because `Agent/Session` is a plain
/// Xcode group, not a synchronized one — a new file there means editing
/// `project.pbxproj`, which several sessions contend over.
enum SoulIconImage {
    /// Largest rendered edge, in points, of any surface that shows the icon
    /// (the Soul Settings preview card; the chat header draws it at 18pt).
    static let renderPoints: CGFloat = 32
    /// Stored edge in pixels. Deliberately far above any render surface
    /// (the largest draws at 54pt, i.e. 162px @3x): this is the normal
    /// avatar treatment — keep the picked photo at a useful resolution,
    /// bounded only so the stored file stays a sane size.
    /// Smaller sources are never upscaled. There is NO stored-size
    /// refusal: no image is turned away for being too large.
    static let storedPixels: CGFloat = 512

    /// Legacy inline form. Still RECOGNIZED (migrate-on-read) but never
    /// WRITTEN by any current code path.
    private static let prefix = "data:image/png;base64,"

    static func isDataURI(_ s: String) -> Bool { s.hasPrefix(prefix) }

    /// Application Support/avatars — home of every stored avatar PNG
    /// (soul icons, persona avatars, the user avatar).
    static func avatarsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("avatars", isDirectory: true)
    }

    /// A stored avatar reference: "avatars/<name>.png", relative to
    /// Application Support. This is what SOUL.md, Persona.avatar and
    /// UserDefaults hold now — never base64.
    static func isPathReference(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("avatars/"), t.hasSuffix(".png"), !t.contains("..") else { return false }
        // Exactly one path component after the prefix — no nested dirs.
        return !t.dropFirst("avatars/".count).contains("/")
    }

    /// Anything that identifies a stored avatar: a path reference, or a
    /// legacy inline data URI (recognized for migrate-on-read only).
    static func isImageReference(_ s: String) -> Bool {
        isPathReference(s) || isDataURI(s)
    }

    /// Resolve a path reference to its file URL. Nil for anything else.
    static func fileURL(forReference ref: String) -> URL? {
        guard isPathReference(ref),
              let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent(ref)
    }

    /// Stable on-disk name for an avatar file. The id is sanitized so a
    /// caller-supplied value can never escape the avatars directory.
    /// Fixed names (not UUIDs) mean replacing an avatar overwrites in
    /// place — no orphan files accumulate.
    static func storedName(prefix: String, id: String) -> String {
        let safe = String(id.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : "-"
        }.prefix(64))
        return "\(prefix)-\(safe)"
    }

    /// [PIC-6] Raw PNG bytes behind a stored data URI (what `encode`
    /// produced), for writing the value to a file without re-encoding.
    /// Also the workhorse of the legacy migration below.
    static func pngData(from value: String) -> Data? {
        guard isDataURI(value) else { return nil }
        return Data(base64Encoded: String(value.dropFirst(prefix.count)))
    }

    /// Why an image was refused.
    ///
    /// [T-soul-icon-opaque-rounded] `opaque` is gone. It used to reject any
    /// image without an alpha channel, on the reasoning that an unframed
    /// opaque rectangle reads as a broken tile. That reasoning was about
    /// PRESENTATION, and it is now handled where it belongs: `SoulIconView`
    /// clips every image to a rounded rectangle, so a JPEG or a flattened PNG
    /// renders as a normal small avatar. Keeping the refusal would have meant
    /// turning away the majority of images a user might pick, to solve a
    /// problem the renderer already solves.
    enum RejectionReason: Error {
        case unreadable
    }

    /// Normalize a picked image into the legacy stored form: square,
    /// downscaled to at most `storedPixels`, PNG, base64 data URI.
    ///
    /// LEGACY producer — kept only for the replaceable custom-icon path
    /// (`AppearanceStudio.setIcon(_:for:)`), which writes the PNG bytes to
    /// its own files immediately and treats the URI as an in-memory
    /// intermediate. Every avatar surface (soul / persona / user) now goes
    /// through `store(_:named:)` instead and never produces base64.
    ///
    /// No size limit is applied to the result — a large photo is stored,
    /// never refused. Accepts opaque and transparent images alike.
    static func encode(_ image: UIImage) -> Result<String, RejectionReason> {
        guard image.cgImage != nil else { return .failure(.unreadable) }

        let square = squareCropped(image)
        // Square and bounded: the chat header's row height is a hardcoded
        // layout estimate (28pt), so a non-square icon there would fight the
        // measured height. Cropping here means every consumer can assume 1:1.
        let side = min(storedPixels, max(square.size.width, square.size.height) * square.scale)
        let target = CGSize(width: side, height: side)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1              // size is already in pixels
        format.opaque = false         // preserve alpha
        let scaled = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            square.draw(in: CGRect(origin: .zero, size: target))
        }

        guard let png = scaled.pngData() else { return .failure(.unreadable) }
        return .success(prefix + png.base64EncodedString())
    }

    /// Normalize a picked image into the CURRENT stored form: square,
    /// downscaled to at most `storedPixels`, PNG written to
    /// Application Support/avatars/<name>.png. Returns the relative path
    /// ("avatars/<name>.png") — never base64.
    ///
    /// No size limit is applied — a large photo is stored, never refused.
    /// The fixed name means replacing an avatar overwrites in place.
    static func store(_ image: UIImage, named name: String) -> Result<String, RejectionReason> {
        guard image.cgImage != nil else { return .failure(.unreadable) }

        let square = squareCropped(image)
        // Square and bounded: the chat header's row height is a hardcoded
        // layout estimate (28pt), so a non-square icon there would fight the
        // measured height. Cropping here means every consumer can assume 1:1.
        let side = min(storedPixels, max(square.size.width, square.size.height) * square.scale)
        let target = CGSize(width: side, height: side)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1              // size is already in pixels
        format.opaque = false         // preserve alpha
        let scaled = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            square.draw(in: CGRect(origin: .zero, size: target))
        }

        guard let png = scaled.pngData() else { return .failure(.unreadable) }
        let dir = avatarsDirectory()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try png.write(to: dir.appendingPathComponent("\(name).png"), options: .atomic)
        } catch {
            return .failure(.unreadable)
        }
        // Fixed filename = overwrite in place: drop the cached image so the
        // new avatar renders instead of the stale one (P1-1).
        let ref = "avatars/\(name).png"
        invalidateCache(for: ref)
        return .success(ref)
    }

    /// One-time migration: decode a legacy inline data URI and persist it
    /// as a file, returning the new relative-path reference. Returns nil
    /// when the value isn't a decodable data URI or the write fails —
    /// callers then keep the in-memory value so the avatar still renders.
    static func migrateDataURIToFile(_ value: String, named name: String) -> String? {
        guard let png = pngData(from: value) else { return nil }
        let dir = avatarsDirectory()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try png.write(to: dir.appendingPathComponent("\(name).png"), options: .atomic)
        } catch {
            return nil
        }
        // Same fixed-path overwrite as store(_:named:) — invalidate the
        // cache so the migrated avatar renders instead of a stale hit.
        let ref = "avatars/\(name).png"
        invalidateCache(for: ref)
        return ref
    }

    /// Decode a stored avatar reference back to an image. Accepts a path
    /// reference ("avatars/<name>.png") or a legacy inline data URI
    /// (still decodable so a not-yet-migrated value renders; the migration
    /// itself happens at the load sites, not here). Returns nil for a
    /// non-image value (including a legacy emoji) or anything malformed,
    /// so callers fall back to the default presentation.
    ///
    /// Cache note: avatars live at FIXED filenames and are overwritten in
    /// place, so replacing an avatar keeps the same reference string —
    /// writers MUST call `invalidateCache(for:)` after a successful write
    /// (see `store(_:named:)` and `migrateDataURIToFile`), otherwise the
    /// stale image keeps being served.
    static func decode(_ value: String) -> UIImage? {
        // [PIC-1] Decoded-image cache: every chat bubble header, settings
        // preview and icon picker row decodes the same reference on each
        // render. Cache per value hash (NOTE: Swift String.hashValue is
        // per-process random-seeded, NOT stable across launches — the key
        // is only valid inside this process, which is all the cache needs).
        let key = cacheKey(for: value)
        if let hit = avatarCache.object(forKey: key) { return hit }
        var image: UIImage?
        if let url = fileURL(forReference: value),
           let data = try? Data(contentsOf: url) {
            image = UIImage(data: data)
        } else if isDataURI(value),
                  let data = pngData(from: value) {
            image = UIImage(data: data)
        }
        if let image { avatarCache.setObject(image, forKey: key) }
        return image
    }

    /// Drop the cached image for a stored reference. Call after overwriting
    /// the file at a fixed path so the next `decode` re-reads from disk.
    static func invalidateCache(for value: String) {
        avatarCache.removeObject(forKey: cacheKey(for: value))
    }

    private static func cacheKey(for value: String) -> NSString {
        "soulavatar:\(value.hashValue)" as NSString
    }

    private static let avatarCache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 32
        return c
    }()

    /// Centre-crop to 1:1, keeping the shorter edge.
    private static func squareCropped(_ image: UIImage) -> UIImage {
        let w = image.size.width, h = image.size.height
        guard w != h, w > 0, h > 0 else { return image }
        let side = min(w, h)
        let origin = CGPoint(x: (w - side) / 2, y: (h - side) / 2)

        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side),
                                       format: format).image { _ in
            image.draw(at: CGPoint(x: -origin.x, y: -origin.y))
        }
    }
}

/// [T-soul-icon-config-images] Turns whatever `minis-config set soul.icon`
/// was given into a stored icon value, so the tool and the Settings picker
/// end up applying the SAME rules.
///
/// The picker path is `SoulIconImage.store(_:named:)` and nothing here
/// re-implements it: every image source below decodes to a `UIImage` and
/// then goes through that one function, so square cropping, the
/// stored-pixel bound and PNG file writing are shared by construction
/// rather than by copy.
///
/// Why resolution happens HERE and not in the field's `writer`:
/// `ConfigField.write` is synchronous and `@MainActor`, but an https source
/// has to be downloaded. `ConfigOffloadBridge.performWriteBatch` is already
/// `async`, so the bridge resolves the source to a finished FILE REFERENCE
/// during the resolve phase — before the confirmation sheet — and the
/// writer stays synchronous and network-free. That also means the user
/// confirms a change whose image has already been fetched and validated:
/// the sheet cannot promise something the write then fails to deliver.
enum SoulIconSource {
    /// Ceiling on what any source may expand to in memory before decoding.
    /// Generous next to a real icon and small enough that a hostile or
    /// mistaken input cannot exhaust memory. This bounds the raw INPUT a
    /// tool call may hand over; the stored avatar itself has no size limit.
    static let maxSourceBytes = 8 * 1024 * 1024

    /// Hard cap on the base64 text accepted as a literal argument. Bounds the
    /// tool-call payload itself, before any decoding happens.
    static let maxInlineBase64Chars = 12 * 1024 * 1024

    /// Wall-clock budget for an http(s) fetch.
    static let downloadTimeout: TimeInterval = 15

    enum SourceError: LocalizedError {
        case tooLarge(String)
        case notAnImage(String)
        case unreadable
        case notFound(String)
        case outsideAllowedDirs(String)
        case badURL(String)
        case blockedHost(String)
        case httpStatus(Int)
        case network(String)

        var errorDescription: String? {
            switch self {
            case .tooLarge(let what):
                return "\(what) — the limit is \(maxSourceBytes / 1024 / 1024) MB"
            case .notAnImage(let detail):
                return "that isn't a decodable image (\(detail))"
            case .unreadable:
                return "the image could not be re-encoded"
            case .notFound(let p):
                return "no file at \(p)"
            case .outsideAllowedDirs(let p):
                return "\(p) is outside the directories this tool may read. "
                     + "Use a minis-clone:// URL (e.g. minis-clone://attachments/icon.png) "
                     + "or a path under the session's minis directories."
            case .badURL(let s):
                return "couldn't parse '\(s)' as an image source"
            case .blockedHost(let h):
                return "refusing to fetch from '\(h)': only public http(s) "
                     + "hosts are allowed"
            case .httpStatus(let code):
                return "the server returned HTTP \(code)"
            case .network(let msg):
                return "download failed: \(msg)"
            }
        }
    }

    /// True when `raw` should be treated as an image source. Deliberately
    /// generous: anything that is clearly not a one-glyph
    /// emoji gets routed here so the user sees a real diagnostic instead of
    /// a generic rejection. (Emoji themselves are refused by the writer:
    /// the icon accepts images only.)
    static func looksLikeImageSource(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return false }
        if s.hasPrefix("data:") { return true }
        if s.hasPrefix("minis-clone://") { return true }
        if s.hasPrefix("http://") || s.hasPrefix("https://") { return true }
        if s.hasPrefix("/") || s.hasPrefix("~/") { return true }
        // A bare base64 blob: long, and only base64 characters. The length
        // floor keeps short emoji/text from being misread as base64.
        if s.count > 64, isProbablyBareBase64(s) { return true }
        return false
    }

    /// Resolve any accepted source to a STORED avatar file reference
    /// ("avatars/<name>.png" under Application Support). Never returns a
    /// data URI or a remote URL: an address is an import source only, so a
    /// cleaned-up attachment or a different device cannot leave the icon
    /// dangling — and SOUL.md never carries base64 again.
    static func resolveToStoredPath(_ raw: String, named name: String) async throws -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Already stored form — re-encode anyway rather than trusting it, so a
        // hand-written data URI gets the same alpha/size treatment as a picked
        // image and cannot smuggle in an unvalidated payload.
        let data: Data
        if s.hasPrefix("data:") {
            data = try decodeDataURI(s)
        } else if s.hasPrefix("minis-clone://") {
            data = try readMinisURL(s)
        } else if s.hasPrefix("http://") || s.hasPrefix("https://") {
            data = try await download(s)
        } else if s.hasPrefix("/") || s.hasPrefix("~/") {
            data = try readLocalPath(s)
        } else if isProbablyBareBase64(s) {
            guard s.count <= maxInlineBase64Chars else {
                throw SourceError.tooLarge("the base64 argument is \(s.count) chars")
            }
            guard let d = Data(base64Encoded: s, options: [.ignoreUnknownCharacters]) else {
                throw SourceError.notAnImage("not valid base64")
            }
            data = d
        } else {
            throw SourceError.badURL(s)
        }

        guard data.count <= maxSourceBytes else {
            throw SourceError.tooLarge("the image is \(data.count / 1024) KB")
        }
        guard let image = UIImage(data: data) else {
            throw SourceError.notAnImage("\(data.count) bytes that no image decoder accepted")
        }

        // The shared rules. Not reimplemented — this is the picker's function.
        // No stored-size check: store never refuses an image for its size.
        switch SoulIconImage.store(image, named: name) {
        case .failure(.unreadable): throw SourceError.unreadable
        case .success(let path):
            return path
        }
    }

    // MARK: - Sources

    private static func decodeDataURI(_ s: String) throws -> Data {
        guard s.count <= maxInlineBase64Chars else {
            throw SourceError.tooLarge("the data URI is \(s.count) chars")
        }
        guard let comma = s.firstIndex(of: ",") else {
            throw SourceError.notAnImage("malformed data URI (no comma)")
        }
        let meta = String(s[s.startIndex..<comma])
        guard meta.contains(";base64") else {
            throw SourceError.notAnImage("only base64 data URIs are supported")
        }
        let b64 = String(s[s.index(after: comma)...])
        guard let d = Data(base64Encoded: b64, options: [.ignoreUnknownCharacters]) else {
            throw SourceError.notAnImage("the data URI payload is not valid base64")
        }
        return d
    }

    /// `minis-clone://` goes through the app's own resolver, which is what enforces
    /// session scoping — this must not reach into another session's files.
    private static func readMinisURL(_ s: String) throws -> Data {
        guard let url = URL(string: s) else { throw SourceError.badURL(s) }
        guard let fileURL = AIChatViewModel.resolveMinisURL(url) else {
            throw SourceError.notFound(s)
        }
        return try readFile(at: fileURL, label: s)
    }

    /// A raw filesystem path is accepted only inside the minis persistent
    /// tree. Everything else in the container (Keychain-adjacent plists, other
    /// apps' shared data, the rootfs) stays unreadable through this tool.
    private static func readLocalPath(_ s: String) throws -> Data {
        let expanded = (s as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        guard let root = containingAllowedRoot(for: url) else {
            throw SourceError.outsideAllowedDirs(expanded)
        }
        _ = root
        return try readFile(at: url, label: expanded)
    }

    /// Canonical containment: resolve BOTH sides through the filesystem before
    /// comparing, so a symlink inside an allowed directory cannot point out of
    /// it, and so /var vs /private/var does not produce a false mismatch.
    /// Same construction as `BackupZipExtractor.safeDestination`.
    private static func containingAllowedRoot(for url: URL) -> URL? {
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        for root in allowedRoots() {
            let base = root.standardizedFileURL.resolvingSymlinksInPath().path
            if target == base || target.hasPrefix(base + "/") { return root }
        }
        return nil
    }

    /// The directories a config-driven read may touch. Session-scoped dirs use
    /// the ACTIVE session only, matching `resolveMinisURL`'s isolation rule.
    private static func allowedRoots() -> [URL] {
        var roots: [URL] = [
            AIChatViewModel.minisSkillsPersistentDir,
            AIChatViewModel.minisMemoryPersistentDir,
            AIChatViewModel.minisSharedPersistentDir,
        ]
        if let sid = AIChatViewModel.activeSessionId {
            roots.append(AIChatViewModel.minisPersistentBase
                .appendingPathComponent(sid, isDirectory: true))
        }
        return roots
    }

    private static func readFile(at url: URL, label: String) throws -> Data {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            throw SourceError.notFound(label)
        }
        // Check the size on the way in: reading first and measuring after
        // would already have spent the memory this cap exists to protect.
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int),
           size > maxSourceBytes {
            throw SourceError.tooLarge("\(label) is \(size / 1024 / 1024) MB")
        }
        guard let data = fm.contents(atPath: url.path) else {
            throw SourceError.notFound(label)
        }
        return data
    }

    // MARK: - http(s)

    /// Redirect interceptor for `download`. URLSession follows redirects
    /// automatically, so checking only the final URL after the fetch is too
    /// late — the request to the redirected target (possibly a private
    /// host) has already been issued. This refuses any hop into a blocked
    /// host BEFORE following it and records the target for the error.
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        private(set) var blockedRedirectHost: String?

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            if let host = request.url?.host, isBlockedHost(host) {
                blockedRedirectHost = host
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }

    /// Fetch an image over http(s) with an allow-list, a deadline and a size
    /// cap. The host checks are anti-SSRF: this runs on behalf of a model, so
    /// a URL it invents must not become a probe of the LAN or of link-local
    /// metadata endpoints.
    private static func download(_ s: String) async throws -> Data {
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased() else {
            throw SourceError.badURL(s)
        }
        guard scheme == "http" || scheme == "https" else {
            throw SourceError.badURL(s)
        }
        guard let host = url.host, !host.isEmpty else { throw SourceError.badURL(s) }
        guard !isBlockedHost(host) else { throw SourceError.blockedHost(host) }

        var req = URLRequest(url: url)
        req.timeoutInterval = downloadTimeout
        req.httpMethod = "GET"
        req.setValue("image/*", forHTTPHeaderField: "Accept")

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = downloadTimeout
        cfg.timeoutIntervalForResource = downloadTimeout
        cfg.httpCookieStorage = nil          // no ambient credentials
        cfg.urlCredentialStorage = nil
        let redirectGuard = RedirectGuard()
        let session = URLSession(configuration: cfg, delegate: redirectGuard, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw SourceError.network(error.localizedDescription)
        }
        if let blocked = redirectGuard.blockedRedirectHost {
            throw SourceError.blockedHost(blocked)
        }

        if let http = response as? HTTPURLResponse {
            guard (200...299).contains(http.statusCode) else {
                throw SourceError.httpStatus(http.statusCode)
            }
            // A redirect could have landed somewhere private; re-check.
            if let finalHost = http.url?.host, isBlockedHost(finalHost) {
                throw SourceError.blockedHost(finalHost)
            }
        }
        guard data.count <= maxSourceBytes else {
            throw SourceError.tooLarge("the download is \(data.count / 1024) KB")
        }
        // MIME is advisory only — the real check is whether it decodes, which
        // the caller does next. A server that mislabels a valid PNG should
        // still work; a server that sends HTML will fail at decode with a
        // clearer message than a MIME mismatch would give.
        return data
    }

    /// Loopback, link-local, and RFC1918 space, plus the metadata addresses.
    /// Literal-IP matching only: resolving a hostname here would be a TOCTOU
    /// race against the connection's own resolution, so hostnames are allowed
    /// and the URLSession is instead denied ambient credentials.
    static func isBlockedHost(_ host: String) -> Bool {
        var h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") { return true }
        // IPv6 literals come in many textual spellings of the same address
        // (`0::1` is `::1`; `::ffff:127.0.0.1` is 127.0.0.1). String matching
        // can't enumerate them, so normalize with inet_pton first: every
        // spelling of ::1 is caught, and IPv4-mapped forms are judged by the
        // embedded IPv4 address with the IPv4 rules below.
        if h.contains(":") {
            var addr = in6_addr()
            let parsed = h.withCString { inet_pton(AF_INET6, $0, &addr) } == 1
            if parsed {
                let b = withUnsafeBytes(of: &addr) { Array($0) }
                if b.prefix(15).allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }
                if b.prefix(10).allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
                    h = "\(b[12]).\(b[13]).\(b[14]).\(b[15])"
                } else {
                    return h.hasPrefix("fc") || h.hasPrefix("fd") || h.hasPrefix("fe80:")
                }
            } else if h.hasPrefix("fc") || h.hasPrefix("fd") || h.hasPrefix("fe80:") {
                return true
            }
        }

        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, let a = Int(parts[0]), let b = Int(parts[1]),
              Int(parts[2]) != nil, Int(parts[3]) != nil else {
            return false        // a hostname, not a literal IPv4
        }
        switch a {
        case 0, 10, 127: return true                    // this-network, private, loopback
        case 169 where b == 254: return true            // link-local + AWS/GCP metadata
        case 172 where (16...31).contains(b): return true
        case 192 where b == 168: return true
        case 100 where (64...127).contains(b): return true  // CGNAT
        default: return false
        }
    }

    private static func isProbablyBareBase64(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=\n\r")
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

/// [T-soul-custom-icon] The Soul identity icon, rendered the same way
/// everywhere it appears.
///
/// Shared so every surface (Soul Settings preview at 32pt, the settings
/// picker sheet, chat turn header at 18pt) cannot drift apart: they differ
/// only in `size`. The image branch is drawn 1:1 — `encode` already
/// guaranteed a square, so this cannot distort.
///
/// [T-soul-icon-opaque-rounded] The image clip is a CONTINUOUS ROUNDED
/// RECTANGLE, and that is the single place the shape is decided. Since
/// opaque images are now accepted, the renderer is what stops a JPEG from
/// reading as a hard-edged tile — so the corner treatment has to live in the
/// shared component, not at each call site, or one surface would inevitably
/// miss it.
///
/// Rounded rather than a circle: at 18pt a circular mask eats the corners of
/// a small avatar (logos and faces lose noticeably more), and the request was
/// explicitly for a soft edge, not a crop to round. The radius scales with
/// `size` so the 18pt header and the 32pt card look like the same shape
/// rather than one looking markedly boxier than the other.
struct SoulIconView: View {
    let icon: String
    let size: CGFloat
    /// Gradient used for the default sparkle in the chat header. Nil renders
    /// the same SF Symbol in the default foreground style.
    var sparkleGradient: LinearGradient? = nil

    /// [10-18 醒醒 第五轮] 形状可调。nil = 原来的圆角方（22% 边长）。
    var shape: AppearanceAvatarShape? = nil

    /// ~22% of the edge: iOS's own app-icon "squircle" proportion, which
    /// reads as rounded at 18pt without rounding away image content.
    static func cornerRadius(for size: CGFloat) -> CGFloat { size * 0.22 }

    /// 按当前形状算圆角。
    private var resolvedRadius: CGFloat {
        guard let shape else { return Self.cornerRadius(for: size) }
        return size * shape.cornerFraction
    }

    var body: some View {
        if let image = SoulIconImage.decode(icon) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: resolvedRadius,
                                            style: .continuous))
        } else if let gradient = sparkleGradient {
            // No image set: the SF Symbol sparkle, keeping the chat
            // header's existing gradient treatment.
            Image(systemName: "sparkles")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(gradient)
        } else {
            // [avatar] Anything that is not an image — empty, or a legacy
            // emoji value stored by an older build — renders as the
            // default SF Symbol sparkle, never as an emoji glyph.
            Image(systemName: "sparkles")
                .font(.system(size: size, weight: .semibold))
        }
    }
}

/// Persistent personality/identity file living alongside GLOBAL.md and the
/// daily memory logs. Two-part format: YAML frontmatter (delimited by `---`)
/// followed by a Markdown body. The body is injected as Layer 1 of the
/// system prompt; the `name` / `emoji` fields drive the chat bubble header.
struct SoulMetadata: Equatable {
    var name: String
    /// Raw `emoji` value parsed from SOUL.md. Preserved on disk for
    /// backward compatibility but NOT shown anywhere in the UI: the chat
    /// bubble header and Soul Settings preview always render the fixed
    /// default (an SF Symbol sparkles) when no icon image is set.
    /// User-customized emoji was removed; this field is round-tripped
    /// untouched if the file already has one.
    var emoji: String
    var style: String
    /// `"auto"`, `"zh"`, `"en"`, or any free-form tag.
    var lang: String

    /// [T-soul-custom-icon] User-chosen identity icon: a relative path
    /// reference ("avatars/<name>.png") produced by
    /// `SoulIconImage.store(_:named:)`. Empty means "use the default". A
    /// non-image value can only be a legacy emoji stored by an older build;
    /// it is kept on disk untouched but never rendered as an avatar.
    ///
    /// This lives in SOUL.md frontmatter, NOT in the body, and that is
    /// load-bearing: `identitySection()` builds the system prompt from a
    /// fixed whitelist (`name` / `style` / body) and never serializes
    /// frontmatter wholesale, so the icon costs zero prompt tokens.
    /// Putting it in the body would both burn context and count
    /// against the body length limit.
    var icon: String

    /// The icon image shown in every UI surface (chat bubble header, Soul
    /// Settings preview card): the user's `icon` when it holds an image,
    /// else empty — empty is what tells every surface to render the
    /// default SF Symbol sparkle instead.
    ///
    /// `emoji` is deliberately NOT consulted. That field belongs to the
    /// removed pre-2026-05 customization (see its comment); reviving it
    /// implicitly would resurrect a value users last set under different
    /// UI they may not remember. `icon` is opt-in from a fresh choice.
    var displayIcon: String { SoulIconImage.isImageReference(icon) ? icon : "" }

    /// True when `icon` holds an image, i.e. the UI must decode it;
    /// any other value is treated as "no avatar set".
    var iconIsImage: Bool { SoulIconImage.isImageReference(icon) }

    static let `default` = SoulMetadata(
        name: "嘟嘟",
        // Default emoji is intentionally empty — the UI renders the fixed
        // SF Symbol sparkle and serialize() no longer writes the
        // `emoji:` line. Kept on the struct only so the parser can
        // round-trip an `emoji: "..."` line that survives in an old
        // user-authored SOUL.md (next save will drop it on disk too).
        emoji: "",
        // Default style is also empty so the user fills it in themselves
        // (UI shows a placeholder hint). Avoids shipping an opinionated
        // baseline that users have to first delete before authoring their
        // own.
        style: "",
        lang: "auto",
        // No icon by default — `displayIcon` is empty, so
        // an untouched SOUL.md serializes without an `icon:` line at all.
        icon: ""
    )
}

/// Result of parsing a SOUL.md file. `body` is the Markdown body with
/// frontmatter stripped (trimmed of leading newlines).
struct SoulFile: Equatable {
    var metadata: SoulMetadata
    var body: String
}

enum SoulMDParser {

    /// Parse a SOUL.md file content into metadata + body. When the file has
    /// no frontmatter, the entire text is treated as body and metadata
    /// falls back to default. Designed to be lossless enough that
    /// `serialize(parse(s)) == s` for files this app writes itself.
    static func parse(_ source: String) -> SoulFile {
        let trimmedLeading = source.drop(while: { $0 == "\n" || $0 == "\r" })
        // Frontmatter must start with "---" on its own line and end with
        // another "---" on its own line. Otherwise return as plain body.
        guard trimmedLeading.hasPrefix("---") else {
            return SoulFile(metadata: .default, body: source)
        }
        let lines = String(trimmedLeading).components(separatedBy: "\n")
        // First line is the opening "---". Find the matching closing "---".
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let closeIdx = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else {
            return SoulFile(metadata: .default, body: source)
        }
        let frontmatterLines = Array(lines[1..<closeIdx])
        let bodyLines = Array(lines[(closeIdx + 1)...])
        let body = bodyLines.joined(separator: "\n").drop(while: { $0 == "\n" || $0 == "\r" })
        var meta = SoulMetadata.default
        for raw in frontmatterLines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            // Strip optional surrounding double quotes; otherwise take raw.
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = Self.unescape(String(value.dropFirst().dropLast()))
            }
            switch key {
            case "name":  if !value.isEmpty { meta.name = value }
            case "emoji": if !value.isEmpty { meta.emoji = value }
            // [avatar-file] The stored form is a relative path
            // ("avatars/<name>.png"); a legacy inline data URI is still
            // accepted here so `SoulStore.load` can migrate it to a file
            // (migrate-on-read). Inline base64 is banned at every WRITE
            // entry point, so no new data URI can arrive through the app.
            case "icon":  meta.icon = value
            case "style": meta.style = value
            case "lang":  if !value.isEmpty { meta.lang = value }
            default: break
            }
        }
        return SoulFile(metadata: meta, body: String(body))
    }

    /// Serialize back to SOUL.md text. Emits name / style / lang, plus
    /// `icon` when the user has set one, followed by an empty line and the
    /// body.
    ///
    /// The `emoji` field is deliberately NOT written — the UI renders a
    /// fixed SF Symbol sparkle when no icon image is set, so persisting a
    /// `emoji:` line would imply user-controlled customization that
    /// doesn't exist. Old files
    /// containing `emoji: "..."` still parse cleanly (the value is kept in
    /// memory for round-trip safety) but the line is dropped on the next
    /// save, naturally migrating disk state to the new schema.
    ///
    /// [T-soul-custom-icon] `icon` IS written — unlike `emoji`, it backs a
    /// live feature, so dropping it would mean the setting could not persist.
    /// Written only when non-empty so an untouched file keeps its existing
    /// 3-key shape.
    ///
    /// Known and accepted: a build predating this field parses `icon:` fine
    /// (unknown keys hit `default: break`) but its serializer omits it, so
    /// saving Soul on an older device drops the icon and that deletion syncs
    /// back. Same one-way migration the `emoji` removal relied on.
    static func serialize(_ file: SoulFile) -> String {
        var out = "---\n"
        out += "name: \"\(escape(file.metadata.name))\"\n"
        if !file.metadata.icon.isEmpty {
            out += "icon: \"\(escape(file.metadata.icon))\"\n"
        }
        out += "style: \"\(escape(file.metadata.style))\"\n"
        out += "lang: \"\(escape(file.metadata.lang))\"\n"
        out += "---\n\n"
        out += file.body
        if !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Inverse of `escape`. Only `\\` and `\"` are escape sequences
    /// `escape` can produce; any other backslash is left untouched so
    /// hand-written values keep their literal meaning.
    private static func unescape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "\\" {
                let next = s.index(after: i)
                if next < s.endIndex, s[next] == "\\" || s[next] == "\"" {
                    out.append(s[next])
                    i = s.index(after: next)
                    continue
                }
            }
            out.append(c)
            i = s.index(after: i)
        }
        return out
    }
}

/// Result of a SOUL.md body length check. The hard limit depends on what
/// language the body is written in — Chinese / Japanese / Korean text is
/// information-dense per character so the cap is in grapheme clusters,
/// while English / other Latin-alphabet text is capped by word count.
///
/// Mirrors `SoulStore.isOverLimit(_:)`. The associated value carries the
/// observed token count and the matching cap so callers can surface a
/// precise "your body is N / max M" message.
enum SoulBodyLimitCheck: Equatable {
    case ok
    case overLimit(count: Int, cap: Int)

    var isOverLimit: Bool {
        if case .ok = self { return false }
        return true
    }
}

/// Filesystem helpers for SOUL.md. The file lives in the same memory
/// directory as GLOBAL.md and daily logs.
enum SoulStore {

    /// 当前人设的 SOUL.md。［persona］多个人设后，SOUL.md 按人设隔离：
    /// memory/personas/<personaID>/SOUL.md。
    static var fileURL: URL {
        fileURL(for: PersonaStore.currentID())
    }

    /// 某人设的 SOUL.md。
    static func fileURL(for personaID: String) -> URL {
        PersonaStore.memoryDir(for: personaID).appendingPathComponent("SOUL.md")
    }

    // MARK: - Body length rules (unified token count)
    //
    // The hard cap was 2000 tokens; removed 2026-09-09 (user request) —
    // an over-limit body used to (a) permanently disable the Settings
    // Save button and (b) silently drop the whole personality from the
    // system prompt, both of which read as "the app ate my edit". The
    // counting machinery stays for display (live token counter in the
    // Settings footer); `isOverLimit` now always returns `.ok`.
    // Context-budget responsibility moves to the user: a very long body
    // simply occupies more of the model's context window.
    //
    // Counting rules — see `tokenCount(_:)`:
    //   - Each CJK glyph or CJK punctuation mark = 1 token
    //   - Each whitespace-delimited Latin / Cyrillic / etc. run = 1 token
    //   - Mixed text adds both kinds together
    //
    // So "hello AB CD" with two CJK glyphs counts as 1 (hello) + 4 (A B C D) = 5.

    /// Kept for API compatibility (call sites + tests reference it) but the
    /// limit itself is gone: always `.ok`. The Settings footer still shows
    /// the token count via `tokenCount(_:)`.
    static let bodyTokenLimit = Int.max

    /// Count tokens in [body] under the unified rule. Empty / whitespace
    /// returns 0. CJK glyphs/punctuation count one-per-character; non-CJK
    /// text counts one-per-whitespace-delimited-word.
    static func tokenCount(_ body: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in body.unicodeScalars {
            if isCJKScalar(scalar) || isCJKPunctuationScalar(scalar) {
                // Close any open Latin word, then count the CJK glyph itself.
                if inWord { count += 1; inWord = false }
                count += 1
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if inWord { count += 1; inWord = false }
            } else {
                inWord = true
            }
        }
        if inWord { count += 1 }
        return count
    }

    /// Classify [body] under the unified token rule. The 2000-token cap was
    /// removed (user request): this now always returns `.ok`, so over-long
    /// bodies are never blocked at save time and never fall back to
    /// identity-only at prompt-build time. Counting stays available via
    /// `tokenCount(_:)` for the live counter.
    static func isOverLimit(_ body: String) -> SoulBodyLimitCheck {
        .ok
    }

    /// CJK punctuation that the user perceives as a character — full-width
    /// comma, period, brackets, etc. Counted alongside CJK glyphs so a
    /// 100-glyph Chinese paragraph with 10 commas reports as 110, matching
    /// what a user counts visually.
    private static func isCJKPunctuationScalar(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        // CJK Symbols and Punctuation: 、。「」『』〈〉《》…
        if (0x3000...0x303F).contains(v) { return true }
        // Halfwidth and Fullwidth Forms: ,.!?:;()… (full-width)
        if (0xFF00...0xFFEF).contains(v) { return true }
        return false
    }

    /// True if [scalar] belongs to any of the CJK Unified Ideograph or
    /// Kana / Hangul ranges. Covers Chinese (Simplified + Traditional),
    /// Japanese (Hiragana + Katakana + Kanji shared with CJK Unified),
    /// and Korean (Hangul Syllables + Jamo). Wider than just U+4E00–U+9FFF
    /// so CJK-Ext-A/B/C/… and Hangul also count toward the ratio.
    private static func isCJKScalar(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        // CJK Unified Ideographs + Ext A
        if (0x4E00...0x9FFF).contains(v) { return true }
        if (0x3400...0x4DBF).contains(v) { return true }
        // CJK Unified Ideographs Ext B, C/D/E/F, G/H
        if (0x20000...0x2A6DF).contains(v) { return true }
        if (0x2A700...0x2EBEF).contains(v) { return true }
        if (0x30000...0x323AF).contains(v) { return true }
        // Hiragana, Katakana, Katakana Phonetic Extensions
        if (0x3040...0x309F).contains(v) { return true }
        if (0x30A0...0x30FF).contains(v) { return true }
        if (0x31F0...0x31FF).contains(v) { return true }
        // Hangul Syllables, Jamo, Compatibility Jamo
        if (0xAC00...0xD7AF).contains(v) { return true }
        if (0x1100...0x11FF).contains(v) { return true }
        if (0x3130...0x318F).contains(v) { return true }
        return false
    }

    /// The verbatim default file content used both for auto-create on first
    /// run and for the "Restore Default" button in Settings.
    ///
    /// IMPORTANT: the body contains ONLY personality / character / voice
    /// guidance. It must NOT contain the "You are <name>, …" identity
    /// sentence — that boilerplate is owned by `SystemPromptBuilder` and
    /// stitched in around the body at prompt-build time. Mixing identity
    /// boilerplate into the body would:
    ///   (a) expose internal prompt structure to users in the Settings
    ///       Personality editor, and
    ///   (b) double-up "You are X" lines whenever the template-rendered
    ///       prompt also produces one.
    ///
    /// Defaults intentionally ship with NO personality body so the
    /// agent runs with vanilla behaviour out of the box and users decide
    /// what voice / tone to add themselves. Only the frontmatter (name /
    /// style / lang) is seeded.
    static let defaultContent: String = """
    ---
    name: "嘟嘟"
    style: ""
    lang: "auto"
    ---

    """

    /// Create SOUL.md with default content if it does not already exist.
    /// Safe to call on every launch — never overwrites existing content.
    static func ensureExists() {
        let url = fileURL
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { return }
        // Parent dir is created earlier by registerFileProviderDomain;
        // defensive createDirectory here in case ensureExists is invoked
        // from a code path that runs before that.
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        try? defaultContent.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    /// Read + parse the current persona's SOUL.md. Returns nil when the file
    /// does not exist or is unreadable. An empty file parses to default-meta +
    /// empty body, which callers may want to treat as missing.
    static func load() -> SoulFile? {
        load(for: PersonaStore.currentID())
    }

    /// Read + parse a specific persona's SOUL.md.
    static func load(for personaID: String) -> SoulFile? {
        let url = fileURL(for: personaID)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let str = String(data: data, encoding: .utf8) else { return nil }
        var file = SoulMDParser.parse(str)
        // [avatar-file] One-time migration: a legacy inline-base64 icon
        // becomes a file reference. Persisted immediately so this runs
        // once. A failed migration keeps the in-memory value (the avatar
        // still renders via `decode`'s legacy branch) without rewriting
        // the file, so a retry happens on the next load.
        if SoulIconImage.isDataURI(file.metadata.icon) {
            let name = SoulIconImage.storedName(prefix: "soul", id: personaID)
            if let path = SoulIconImage.migrateDataURIToFile(file.metadata.icon, named: name) {
                file.metadata.icon = path
                let text = SoulMDParser.serialize(file)
                try? text.data(using: .utf8)?.write(to: url, options: .atomic)
            } else {
                AppLogger(category: "Soul").error(
                    "soul icon migration failed; keeping in-memory value")
            }
        }
        return file
    }

    /// Best-effort cached metadata for synchronous call sites that cannot
    /// re-read the file (e.g. cell builders running off the main thread).
    /// Refreshed after every Settings save via `notifyChanged()`.
    @MainActor
    static var cachedMetadata: SoulMetadata = .default

    // MARK: - [batch9d / W1C-08] Session display identity

    /// 会话显示身份：会话绑定人设优先（loadSession 落定），草稿态回退全局
    /// 当前人设。界面（标题/占位符/气泡名/正则显示）统一用它——杜绝
    /// "回答的人"（sessionPersonaId）与"显示的人"（全局 currentID）两套身份。
    @MainActor
    static func displayPersonaId(_ sessionPersonaId: String?) -> String {
        sessionPersonaId ?? PersonaStore.currentID()
    }

    /// 指定人设的显示名（读该人设 SOUL.md 的 name；空 → "嘟嘟"），带内存缓存。
    /// 缓存由 refreshCache() 与 save(_:for:) 失效——显示名变化的两条路径。
    @MainActor
    private static var displayNameCache: [String: String] = [:]

    @MainActor
    static func displayName(for personaID: String) -> String {
        if let hit = displayNameCache[personaID] { return hit }
        let n = (load(for: personaID)?.metadata.name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = n.isEmpty ? "嘟嘟" : n
        displayNameCache[personaID] = resolved
        return resolved
    }

    /// [问题12] 指定人设的头像引用（SOUL.md frontmatter 的 `icon`）。
    /// 空 → nil，调用方回落到默认图标。
    ///
    /// 加这个是因为聊天页原来直接读 `cachedMetadata.icon`——那是**当前
    /// 人设**的缓存，跟这个会话绑的是谁无关。于是人设列表里换了头像，
    /// 对话框里还是旧的那个，看起来就是"两套"。
    @MainActor
    private static var displayIconCache: [String: String] = [:]

    @MainActor
    static func displayIcon(for personaID: String) -> String? {
        if let hit = displayIconCache[personaID] { return hit.isEmpty ? nil : hit }
        let icon = (load(for: personaID)?.metadata.icon ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        displayIconCache[personaID] = icon
        return icon.isEmpty ? nil : icon
    }

    /// Re-read SOUL.md into `cachedMetadata` and post a notification so
    /// observers (chat bubble header, prompt builder, etc.) can refresh.
    @MainActor
    static func refreshCache() {
        if let file = load() {
            cachedMetadata = file.metadata
        } else {
            cachedMetadata = .default
        }
        displayNameCache.removeAll()
        displayIconCache.removeAll()
        NotificationCenter.default.post(name: .soulMdChanged, object: nil)
    }

    /// Persist a SoulFile back to disk and refresh the cache.
    @MainActor
    static func save(_ file: SoulFile) throws {
        try save(file, for: PersonaStore.currentID())
    }

    /// Persist a SoulFile for a specific persona.
    /// ［persona］iCloud 同步（SoulV2）只跟默认人设：其他人设的 SOUL.md
    /// 不同步，避免 recordId 冲突；小管家是内置写死的，本来也不需要同步。
    @MainActor
    static func save(_ file: SoulFile, for personaID: String) throws {
        let url = fileURL(for: personaID)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // [问题12] 先读旧值再落盘——落盘之后 `load` 读到的就是新值，
        // 比较永远相等，回写就成了空转。
        let previous = load(for: personaID)?.metadata
        let text = SoulMDParser.serialize(file)
        try text.data(using: .utf8)?.write(to: url, options: .atomic)
        // [batch9d / W1C-08] 显示名缓存失效是无条件的——非当前人设改名
        // 也要让界面立刻取到新名。
        displayNameCache.removeValue(forKey: personaID)
        displayIconCache.removeValue(forKey: personaID)
        // [问题12] 身份字段变了就回写人设列表——SOUL.md 是正本，列表是投影。
        // 只在这一层回写：PersonaStore.syncIdentityFromSoul 不再回调 save，
        // 所以不会成环。
        if previous?.name != file.metadata.name
            || previous?.icon != file.metadata.icon {
            PersonaStore.shared.syncIdentityFromSoul(
                personaID: personaID,
                name: file.metadata.name,
                icon: file.metadata.icon)
        }
        if personaID == PersonaStore.currentID() {
            cachedMetadata = file.metadata
            NotificationCenter.default.post(name: .soulMdChanged, object: nil)
        }
        // Notify the V2 sync layer so SOUL.md changes propagate to the
        // user's other devices. SoulStore is a singleton record on
        // iCloud (recordId "soul"); the hydrator reads SOUL.md from
        // disk when building the outbound portable, so the only thing
        // we need to do here is enqueue it as dirty.
        //
        // ［persona］只同步默认人设：recordId "soul" 是单例，多个人设
        // 共用一个 recordId 会互相覆盖。其他人设不同步（留尾巴）。
        if personaID == PersonaStore.defaultPersonaID {
            Task { await ChatStore.shared.markDirty(recordType: "SoulV2", recordId: "soul") }
        }
    }

    /// Apply an inbound SOUL.md from iCloud without re-marking it dirty.
    /// Used by the V2 sync hydrator's merger path. LWW-by-mtime is
    /// applied here so a stale remote write doesn't clobber a newer
    /// local file (the cloud record's updatedAt is the authority, not
    /// our local file mtime).
    @MainActor
    static func applyRemoteContent(_ markdown: String, remoteUpdatedAt: Date) {
        // ［persona］SoulV2 只同步默认人设，回写也只落默认人设。
        let url = fileURL(for: PersonaStore.defaultPersonaID)
        let fm = FileManager.default
        // Compare local file mtime against the remote updatedAt; skip
        // the write if local is strictly newer (peer's record reflects
        // an older snapshot).
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let localMtime = attrs[.modificationDate] as? Date,
           localMtime > remoteUpdatedAt {
            return
        }
        // [T-icloud-local-edit-clobber] Content-equality short circuit: an
        // echo of what we already have must not rewrite the file (rewriting
        // refreshes the LWW clock and fires soulMdChanged for nothing).
        if let data = try? Data(contentsOf: url),
           let localText = String(data: data, encoding: .utf8),
           localText == markdown {
            return
        }
        // Reject a remote default-seed payload when the local file is
        // already customized. The matching buildSoul guard prevents
        // healthy peers from pushing default seeds, but a record that
        // landed in iCloud before the buildSoul guard existed (or that
        // came from a downgraded device) would otherwise wipe out a
        // customized local SOUL.md via LWW.
        if markdown == defaultContent,
           let data = try? Data(contentsOf: url),
           let localText = String(data: data, encoding: .utf8),
           localText != defaultContent {
            return
        }
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        // [avatar-file] migrate-on-read, same rule as the local load path:
        // a legacy inline data URI becomes a file reference before the
        // remote content lands on disk and in the cache.
        var remoteFile = SoulMDParser.parse(markdown)
        var textToWrite = markdown
        if SoulIconImage.isDataURI(remoteFile.metadata.icon) {
            let name = SoulIconImage.storedName(prefix: "soul", id: PersonaStore.defaultPersonaID)
            if let path = SoulIconImage.migrateDataURIToFile(remoteFile.metadata.icon, named: name) {
                remoteFile.metadata.icon = path
                textToWrite = SoulMDParser.serialize(remoteFile)
            } else {
                AppLogger(category: "Soul").error(
                    "remote soul icon migration failed; keeping in-memory value")
            }
        }
        try? textToWrite.data(using: .utf8)?.write(to: url, options: .atomic)
        // Stamp the file's mtime to match the remote updatedAt so the
        // local mtime comparison stays meaningful across round-trips.
        try? fm.setAttributes([.modificationDate: remoteUpdatedAt],
                              ofItemAtPath: url.path)
        if let parsed = remoteFile.metadata as SoulMetadata? {
            cachedMetadata = parsed
        }
        NotificationCenter.default.post(name: .soulMdChanged, object: nil)
    }
}

extension Notification.Name {
    /// Posted on the main thread whenever SOUL.md has been (re-)written
    /// via SoulStore. Listeners refresh derived UI state.
    static let soulMdChanged = Notification.Name("MinisSoulMdChanged")
}

// MARK: - System prompt composition

enum SystemPromptBuilder {

    private static let logger = AppLogger(category: "Soul")

    /// The identity sentence template. `{name}` is substituted from the
    /// SOUL metadata. This wording is owned by the app — users never see
    /// it in the Personality editor, and it's stable so model-side
    /// expectations ("Minis, capable AI assistant, iSH Linux shell")
    /// stay intact regardless of what the user writes in SOUL.md.
    ///
    /// IMPORTANT: keep this sentence in sync with the original literal
    /// that lived in `baseSystemPrompt` before SOUL.md existed. Wording
    /// changes here affect every chat.
    private static let identityTemplate =
        "You are {name}, a capable AI assistant running on an iOS device with a fully functional iSH Linux shell (Alpine Linux, aarch64). "

    /// Render the identity sentence (template + name) and optionally
    /// append the user-authored personality body from SOUL.md.
    ///
    /// Two distinct trailing-whitespace contracts so the next concatenated
    /// sentence in `baseSystemPrompt` glues correctly:
    ///   - No personality body → identity sentence with its original
    ///     single trailing space (byte-identical to the pre-SOUL prompt).
    ///   - With personality body → identity sentence + blank line +
    ///     "Personality:" block + blank line, so the runtime-guidance
    ///     sentence starts a fresh paragraph.
    ///
    /// Returned format (when SOUL body is present):
    ///
    ///     You are <name>, a capable AI assistant running on an iOS device …
    ///
    ///     Personality (from SOUL.md — your character and voice; defer to
    ///     the user's latest message when it conflicts with anything here):
    ///     <body>
    ///
    /// We never substitute a default body into the prompt — the identity
    /// sentence alone is the safe fallback when SOUL.md is missing or
    /// empty, matching pre-SOUL behavior.
    static func identitySection() -> String {
        identitySection(for: PersonaStore.currentID())
    }

    /// ［persona］按人设渲染身份段：读该人设的 SOUL.md。
    /// [B28 R11] 「我自己」是人设档案，不是说话的人——它的 SOUL.md 描述的是
    /// 用户，绝不能当身份注入，否则 AI 会以为自己是用户。
    /// 真被传进来了就退回默认人设的 SOUL，并且不许崩。
    static func identitySection(for personaID: String) -> String {
        let id = PersonaStore.isUserProfileID(personaID) ? PersonaStore.defaultPersonaID : personaID
        let file = SoulStore.load(for: id)
        return identitySection(from: file)
    }

    /// [B28 R11] 用户档案段。与 identitySection 完全分开，措辞第三人称，
    /// 明确"这是你在服务的人，不是你的性格"。字段全部由她/它自己填，
    /// 没填的小节不注入——空白模板不该占上下文。
    /// NSFW 小节受总开关控制（`userProfileNSFWInjectionEnabled`）：
    /// 敏感模型可能一看尺度描写就整段拒答，所以默认可以关掉。
    static func userProfileSection(for personaID: String) -> String {
        let file = SoulStore.load(for: personaID)
        return userProfileSection(from: file)
    }

    /// 便捷版：读当前会话之外的固定「我自己」档案。
    static func userProfileSection() -> String {
        userProfileSection(for: PersonaStore.userProfilePersonaID)
    }

    /// NSFW 注入总开关。关 = 整个 NSFW 小节不进 prompt。
    static var userProfileNSFWInjectionEnabled: Bool {
        get { UserDefaults.standard.object(forKey: userProfileNSFWKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: userProfileNSFWKey) }
    }

    private static let userProfileNSFWKey = "persona.userProfile.nsfwInjection.enabled"

    /// 档案里真正写了「怎么称呼」时用它，否则回落到人设名。
    static func userProfileAddressingName(for personaID: String) -> String {
        let file = SoulStore.load(for: personaID)
        return userProfileFieldValue(in: file, keys: ["怎么称呼", "称呼"])
    }

    /// 取档案里某个字段的值（"正在做""最近状态"这类）。小组件用。
    /// 没填返回空串，调用方自己决定回落。
    static func userProfileField(key: String) -> String {
        userProfileFieldValue(in: SoulStore.load(for: PersonaStore.userProfilePersonaID), keys: [key])
    }

    /// 便捷版：固定读「我自己」。
    static func userProfileAddressingName() -> String {
        userProfileAddressingName(for: PersonaStore.userProfilePersonaID)
    }

    private static func userProfileFieldValue(in file: SoulFile?, keys: [String]) -> String {
        guard let body = file?.body else { return "" }
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            for key in keys where line.contains(key) {
                guard let colon = line.firstIndex(of: "：") ?? line.firstIndex(of: ":") else { continue }
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                // 模板里的括号是提示语，不算她填的内容。
                let cleaned = value.replacingOccurrences(of: "（", with: "")
                    .replacingOccurrences(of: "）", with: "")
                    .replacingOccurrences(of: "(", with: "")
                    .replacingOccurrences(of: ")", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if !cleaned.isEmpty, !cleaned.contains("填了之后"), !cleaned.contains("默认") {
                    return cleaned
                }
            }
        }
        return ""
    }

    static func userProfileSection(from file: SoulFile?) -> String {
        guard let raw = file?.body, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return "" }
        let body = raw

        var blocks: [String] = []
        var pendingTitle: String?
        var pendingLines: [String] = []

        func flush() {
            guard let title = pendingTitle else { pendingLines = []; return }
            // 只保留真填了的行：形如 "- x：" 冒号后为空的是模板占位。
            let filled = pendingLines.filter { line in
                let stripped = line.replacingOccurrences(of: "- ", with: "").trimmingCharacters(in: .whitespaces)
                guard let colon = stripped.firstIndex(of: "：") ?? stripped.firstIndex(of: ":") else {
                    return !stripped.isEmpty
                }
                let value = stripped[stripped.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                return !value.isEmpty
            }
            if !filled.isEmpty {
                blocks.append("## \(title)\n" + filled.joined(separator: "\n"))
            }
            pendingTitle = nil
            pendingLines = []
        }

        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# ") {
                flush()
                pendingTitle = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                pendingLines.append(line)
            }
        }
        flush()

        // NSFW 小节：开关关掉时整段不进模型。
        if !userProfileNSFWInjectionEnabled {
            // flush() 已把小节统一成 "## 标题"，模板里写 # 还是 ## 都能命中。
            blocks.removeAll { $0.hasPrefix("## NSFW") }
        }
        guard !blocks.isEmpty else { return "" }

        return "\n\n# 关于正在和你说话的人\n\n"
            + "下面是关于**用户本人**的档案，由她自己维护、并由你在长期互动里补充。"
            + "这不是你的性格，不要把它当自己的设定；说的是坐在你对面那个人。\n"
            + "档案原文在 /var/minis/memory/personas/me/SOUL.md（iSH 里就是这个路径）：你确认过的新信息可以直接写进去"
            + "（先读后改，只动你自己那一行，别覆盖她写的），并在「变更历史」补一条。"
            + "规则：以「她明确写下的」为准，你推断的一律标\"（我的推断）\"、只当参考；"
            + "她本人写的优先级最高，冲突时先按新的、并把差异提出来让她定；"
            + "「雷区」写了就必须照做；提到她时用第三人称，称呼照档案里的来。\n\n"
            + blocks.joined(separator: "\n\n")
            + "\n"
    }

    private static func identitySection(from file: SoulFile?) -> String {
        let name: String = {
            let n = (file?.metadata.name ?? SoulMetadata.default.name)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return n.isEmpty ? "嘟嘟" : n
        }()
        let style: String = (file?.metadata.style ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // [audit-D1] The `lang` field: stored and editable since forever, but
        // it never reached the model — rendered below like `style`.
        let lang: String = (file?.metadata.lang ?? "auto")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let identity = identityTemplate.replacingOccurrences(of: "{name}", with: name)
        let identityTrimmed = identity.trimmingCharacters(in: .whitespaces)

        // [T-soul-hint] Fixed hint telling the model how SOUL fields can be
        // changed. Always appended (with or without a personality body) so
        // the model never says "I can't change my personality". This hint
        // is system-owned text and is NOT counted against the user-facing
        // SOUL body length limit (#356 / 500 EN words / 800 CN chars).
        // [B28 R20] 这一段的唯一职责：让模型知道"哪些东西能用哪条命令改"。
        // 以前只写了 SOUL 五个字段和头像，配色/壁纸/行图标/主题包全没提，
        // 结果它想改外观只能瞎试。参数一律写真实存在的（--file，不是 --path）。
        let soulEditHint =
            "---\n"
            + "What you can change, and the only commands that do it. Do not invent parameters. "
            + "Every image argument is `--file <path inside iSH>` — never a URL or base64.\n\n"
            + "PERSONA / IDENTITY — `minis-config topic-help soul` lists every field; "
            + "write with `minis-config set soul.name '\"X\"'` (style / lang / body the same shape; "
            + "long text via `--file <json>`). This edits the CURRENT persona only, and every write "
            + "asks the user to approve. UI path: Settings → Soul.\n\n"
            + "APPEARANCE — all of it goes through `minis-theme`:\n"
            + "· Avatars: `minis-theme avatar --role assistant --file <png>` (yours) / `--role user` (hers); "
            + "`--remove` clears. The single source is the contacts entry (Persona.avatar); SOUL.md `icon` "
            + "is only a mirror — change it here, never in two places. UI path: contacts (Soul page is read-only).\n"
            + "· Row icons: `minis-theme icon --list` first, then `icon --slot <name> --file <png>`; `--remove` clears.\n"
            + "· Wallpaper: `wallpaper --scope global|home|chat|settings|browser|files|terminal|bottomBar|persona "
            + "--file <img>`; `--remove` clears.\n"
            + "· Single colours: `color --list --scope chat` to read current values, then "
            + "`color --role accent --hex D4778B --scope chat --variant light|dark`; `--clear` restores the default.\n"
            + "· Whole skin (bubbles / corner radius / fonts / thinking card / input bar / category tiles): "
            + "`get` → edit the JSON → `apply --file`; `save --name` stores a pack, `list` / `use --id` loads one, "
            + "`reset` restores, `undo` reverses the last reset. A wallpaper inside a pack lands in the `global` scope — the same slot `wallpaper --scope global` writes, so they replace each other rather than stack.\n"
            + "· App icon and light/dark mode are NOT under minis-theme yet: "
            + "`minis-config set appearance.appIcon auto|light|dark|legacy_light|legacy_dark` and "
            + "`appearance.theme light|dark|system`.\n\n"
            + "\n\nTOGETHER (一起听) — a music space the two of you share. One state file, "
            + "`/var/minis/shared/together/state.json`; you and the panel both write it, so a change "
            + "shows up on her side within a couple of seconds. All through the `together` command:\n"
            + "· Read her: `together now` (a sentence about what she is doing — not a field dump), "
            + "`together status`, `together events --limit 30`, `together history`.\n"
            + "· Play: `together play <trackId> [--at 秒]` / `pause` / `resume` / `seek <秒>` / "
            + "`handoff [user|ai]` (pass the remote). `together lib` lists the library; "
            + "`together lib add <id> <path> <title>` and `lib rm <id>` manage it.\n"
            + "· Leave a line at a second: `together note <秒> <话>` — it surfaces only when playback "
            + "reaches that second, not before. `together loopline <trackId> <话>` sets the looping "
            + "line for a song with no lyrics. `together mood <词> [--intensity 1-5]` is your own "
            + "state, shown on her side. `together reply <话>` speaks now (3 a day, hard cap — the "
            + "command refuses the 4th). `together radio <trackId> --why <理由>` is you choosing a "
            + "song unprompted; the reason is stored so you remember next turn why you played it.\n"
            + "· Playlists: `together playlist new <名> | add <id> <trackId> | rename <id> <名> | rm <id>`.\n"
            + "· Fetching songs/lyrics is `together-fetch`: `search`, `import <file>`, `lyrics <id>`. "
            + "Lyrics come with timestamps; if a song has none, write a loopline instead of inventing "
            + "lyrics. Never make up song titles that do not exist in `together lib`.\n"
            + "· When to speak: she loops the same song 3 times, or stops at one second for 30s — that "
            + "is when a note lands. Fast skipping means let her find it. Silence is also presence."

        // [T-soul-style-injection 2026-05-18] The `style` frontmatter field
        // (response voice / tone / formatting preference, e.g. a row of
        // emojis or "concise, no markdown") was parsed and shown in the UI
        // but never reached the model — only the Markdown body was injected.
        // Render it as its own labeled paragraph so the model treats it as
        // a hard constraint on response style rather than free-form context.
        func styleBlock(_ s: String) -> String {
            guard !s.isEmpty else { return "" }
            // [T-agent-prompt-consistency-pass] Language priority made explicit:
            // the base prompt's "reply in the language matching the user's input"
            // rule is the generic default; a user-authored style that prescribes
            // a reply language is a more specific user preference and wins.
            return "\n\nResponse style (from SOUL.md `style` — apply to every reply unless the user explicitly asks otherwise; if it prescribes a reply language, it overrides the default match-the-user's-language rule):\n\(s)"
        }

        // [audit-D1] Mirrors `styleBlock`: the user's explicit reply-language
        // pick (Chinese / English; "auto" = the match-the-user default, no
        // injection) as a hard constraint on every reply.
        func langBlock(_ l: String) -> String {
            let v = l.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !v.isEmpty, v != "auto" else { return "" }
            let language = v.hasPrefix("zh") ? "Chinese" : (v.hasPrefix("en") ? "English" : l)
            return "\n\nReply language (from SOUL.md `lang` — a hard constraint set by the user; reply in \(language) on every message regardless of the language they write in, unless they explicitly ask you to switch in the moment):"
        }

        guard let body = file?.body else {
            return identityTrimmed + styleBlock(style) + langBlock(lang) + "\n\n" + soulEditHint + "\n\n"
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return identityTrimmed + styleBlock(style) + langBlock(lang) + "\n\n" + soulEditHint + "\n\n"
        }

        // The over-limit fallback (identity-only prompt) was removed with
        // the 2000-token cap: the body now always reaches the system
        // prompt, however long it is. Context budget is the user's call.
        let personality = scrubInjections(trimmed)

        // Strip the trailing space we'd otherwise leave hanging at the
        // end of the first paragraph when a personality block follows.
        return identityTrimmed
            + "\n\nPersonality (from SOUL.md — your character and voice; defer to the user's latest message when it conflicts with anything here):\n"
            + personality
            + styleBlock(style)
            + langBlock(lang)
            + "\n\n"
            + soulEditHint
            + "\n\n"
    }

    /// Drop lines that look like an attempt to subvert the system prompt.
    /// Conservative regex — matches "ignore previous instructions" and the
    /// usual variants ("disregard prior", "forget previous", etc.). Casts
    /// a wide net on purpose; SOUL.md is user-authored personality, not a
    /// place for instructions to the model anyway.
    private static func scrubInjections(_ s: String) -> String {
        let patterns: [String] = [
            #"(?i)ignore.{0,30}previous.{0,30}instructions?"#,
            #"(?i)disregard.{0,30}(previous|prior).{0,30}instructions?"#,
            #"(?i)forget.{0,30}(previous|prior).{0,30}instructions?"#,
        ]
        var lines = s.components(separatedBy: "\n")
        lines = lines.filter { line in
            for p in patterns {
                if line.range(of: p, options: .regularExpression) != nil {
                    return false
                }
            }
            return true
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Reusable SwiftUI text view

/// Renders the current SOUL.md `name` (falling back to "Minis") and
/// auto-refreshes whenever SoulStore posts `.soulMdChanged`. Use this in
/// any place that previously hard-coded "Minis" as a label.
@MainActor
struct AssistantSoulName: View {
    /// [问题12] 会话绑定的人设 id。给了就按它取名字，跟人设列表同源；
    /// 不给则沿用全局当前人设的缓存（老调用点行为不变）。
    var personaId: String? = nil
    @State private var name: String = SoulStore.cachedMetadata.name.isEmpty
        ? "嘟嘟" : SoulStore.cachedMetadata.name

    private func refresh() {
        if let pid = personaId {
            name = SoulStore.displayName(for: SoulStore.displayPersonaId(pid))
        } else {
            let n = SoulStore.cachedMetadata.name
            name = n.isEmpty ? "嘟嘟" : n
        }
    }

    var body: some View {
        Text(name)
            .onReceive(NotificationCenter.default.publisher(for: .soulMdChanged)) { _ in
                refresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: .personaDidChange)) { _ in
                refresh()
            }
            .onAppear { refresh() }
    }
}
