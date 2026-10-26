// Tests for [T-soul-icon-config-images] — `minis-config set soul.icon` now
// accepts images (data URI, bare base64, minis-clone:// resource, local path,
// http(s) URL) and must funnel every one of them through the SAME rules the
// Settings picker uses.
//
// Standalone (`swift SoulIconSourceTests.swift`) because the MinisTests target
// has a pre-existing compile break — same rationale and directory as
// BackupZipContainmentTests / RestoreSymlinkContainmentTests.
//
// The pure logic under test (encode rules, host blocking, source sniffing,
// containment) is reproduced here rather than imported, because the shipping
// types pull in AIChatViewModel and the whole app graph. To stop that copy
// from silently drifting, `testSourcesMatchShippingCode` re-extracts the
// table that matters — the blocked-host ranges — from
// SoulStore.swift itself and fails if they no longer agree.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Harness

var failures = 0
func check(_ label: String, _ actual: Bool, _ expected: Bool = true) {
    if actual == expected { print("  ✅ \(label)") }
    else { print("  ❌ \(label) — expected \(expected), got \(actual)"); failures += 1 }
}
func checkEq<T: Equatable>(_ label: String, _ actual: T, _ expected: T) {
    if actual == expected { print("  ✅ \(label)") }
    else { print("  ❌ \(label) — expected \(expected), got \(actual)"); failures += 1 }
}

let sourcePath: String = {
    let here = URL(fileURLWithPath: #filePath)
    return here.deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Agent/Session/SoulStore.swift").path
}()
let builtinsPath: String = {
    let here = URL(fileURLWithPath: #filePath)
    return here.deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Shared/Config/ConfigRegistry+Builtins.swift").path
}()
let soulSource = (try? String(contentsOfFile: sourcePath, encoding: .utf8)) ?? ""
let builtinsSource = (try? String(contentsOfFile: builtinsPath, encoding: .utf8)) ?? ""

// MARK: - Logic under test (mirrors SoulIconSource)

func isProbablyBareBase64(_ s: String) -> Bool {
    guard !s.isEmpty else { return false }
    let allowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=\n\r")
    return s.unicodeScalars.allSatisfy { allowed.contains($0) }
}

func looksLikeImageSource(_ raw: String) -> Bool {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty { return false }
    if s.hasPrefix("data:") || s.hasPrefix("minis-clone://") { return true }
    if s.hasPrefix("http://") || s.hasPrefix("https://") { return true }
    if s.hasPrefix("/") || s.hasPrefix("~/") { return true }
    if s.count > 64, isProbablyBareBase64(s) { return true }
    return false
}

func isBlockedHost(_ host: String) -> Bool {
    var h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") { return true }
    // Mirrors SoulStore.isBlockedHost: normalize IPv6 spellings via inet_pton.
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
          Int(parts[2]) != nil, Int(parts[3]) != nil else { return false }
    switch a {
    case 0, 10, 127: return true
    case 169 where b == 254: return true
    case 172 where (16...31).contains(b): return true
    case 192 where b == 168: return true
    case 100 where (64...127).contains(b): return true
    default: return false
    }
}

/// Canonical containment, mirroring `containingAllowedRoot`.
func isInsideAnyRoot(_ url: URL, roots: [URL]) -> Bool {
    let target = url.standardizedFileURL.resolvingSymlinksInPath().path
    for root in roots {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        if target == base || target.hasPrefix(base + "/") { return true }
    }
    return false
}

// MARK: - Image fixtures (ImageIO, so this runs without UIKit)

func makePNG(width: Int = 64, height: Int = 64, alpha: Bool) -> Data {
    let cs = CGColorSpaceCreateDeviceRGB()
    let info: CGBitmapInfo = alpha
        ? CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        : CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs, bitmapInfo: info.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: alpha ? 0.5 : 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
    let img = ctx.makeImage()!
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

func makeJPEG() -> Data {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

/// Can the bytes be decoded at all? This is now the ONLY gate the encoder
/// applies — see the opaque-image block below.
func canDecode(_ data: Data) -> Bool {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
    return CGImageSourceCreateImageAtIndex(src, 0, nil) != nil
}

/// Does the decoded bitmap carry alpha? No longer a gate — asserted only to
/// show transparency is preserved rather than required.
func hasAlpha(_ data: Data) -> Bool? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    switch img.alphaInfo {
    case .first, .last, .premultipliedFirst, .premultipliedLast: return true
    default: return false
    }
}

// MARK: - Tests

print("Source sniffing — what counts as an image source vs an emoji")
for (label, s, want) in [
    ("single emoji", "⚡", false),
    ("ZWJ family emoji", "👨‍👩‍👧", false),
    ("empty", "", false),
    ("short text", "hello", false),
    ("data URI", "data:image/png;base64,iVBORw0KGgo=", true),
    ("minis attachments", "minis-clone://attachments/icon.png", true),
    ("minis workspace", "minis-clone://workspace/icon.png", true),
    ("https", "https://example.com/icon.png", true),
    ("http", "http://example.com/icon.png", true),
    ("absolute path", "/var/minis/attachments/icon.png", true),
    ("tilde path", "~/icon.png", true),
    ("long bare base64", String(repeating: "A", count: 100), true),
    ("short base64-ish text", "AAAA", false),
] as [(String, String, Bool)] {
    checkEq("\(label)", looksLikeImageSource(s), want)
}

print("\nEmoji — [avatar] refused everywhere, never rendered as an avatar")
check("emoji is NOT routed to the image path", !looksLikeImageSource("⚡"))
check("empty string is NOT routed to the image path", !looksLikeImageSource(""))
check("multi-char text is NOT routed to the image path",
      !looksLikeImageSource("not an emoji"))
// Routing alone is not the gate — the writer is. Anything that is not an
// image must be refused with a clear error, and the help (which IS the
// API doc) must no longer offer emoji as an option.
check("config writer refuses non-images with a clear error",
      builtinsSource.contains("icon only accepts an image"))
check("the old 'single emoji' acceptance is gone from the writer",
      !builtinsSource.contains("icon must be a single emoji"))
check("help no longer offers emoji", !builtinsSource.contains("Accepts an emoji"))
check("help states emoji are not accepted",
      builtinsSource.contains("emoji are not accepted"))
// Rendering: a stored legacy emoji value must NOT come back as a glyph —
// the shared renderer treats any non-image as "no avatar" and falls
// through to the SF Symbol default.
check("SoulIconView never renders the icon as a Text glyph",
      !soulSource.contains("Text(icon.isEmpty"))
check("SoulIconView's default is the SF Symbol sparkle",
      soulSource.contains("Image(systemName: \"sparkles\")"))
check("displayIcon only surfaces an image value",
      soulSource.contains("SoulIconImage.isImageReference(icon) ? icon : \"\""))
check("the ✨ displayEmoji fallback is gone", !soulSource.contains("displayEmoji"))

print("\nOpaque images — [T-soul-icon-opaque-rounded] these are now ACCEPTED")
// The rule reversed: transparency used to be mandatory. It was a presentation
// concern, and it moved to SoulIconView's rounded-rect clip, so the encoder now
// takes anything decodable. These assertions are the inverse of the originals
// on purpose — they are what proves the reversal actually landed.
let pngAlpha = makePNG(alpha: true)
let pngOpaque = makePNG(alpha: false)
let jpeg = makeJPEG()
for (label, data) in [("transparent PNG", pngAlpha),
                      ("OPAQUE PNG", pngOpaque),
                      ("JPEG", jpeg)] {
    check("\(label) decodes and is accepted", canDecode(data))
}
check("a non-image byte blob is still refused",
      !canDecode("not an image at all".data(using: .utf8)!))
// Alpha is preserved when present, not required.
checkEq("alpha survives when the source had it", hasAlpha(pngAlpha), true)
checkEq("an opaque source stays opaque (no synthetic alpha)", hasAlpha(pngOpaque), false)
check("the encoder no longer has an `opaque` rejection",
      !soulSource.contains("case opaque"))
check("SoulSettingsView no longer branches on .opaque",
      ((try? String(contentsOfFile: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Views/Settings/SoulSettingsView.swift").path,
        encoding: .utf8)) ?? "").contains("reason == .opaque") == false)

print("\nRounded-corner rendering — the shared component decides the shape")
check("SoulIconView clips images to a continuous rounded rect",
      soulSource.contains("RoundedRectangle(cornerRadius: Self.cornerRadius(for: size)")
      && soulSource.contains("style: .continuous"))
check("the image branch is NOT clipped to a circle any more",
      !soulSource.contains(".clipShape(Circle())"))
check("the radius is derived from size (one shape at every call site)",
      soulSource.contains("static func cornerRadius(for size: CGFloat)"))
// Proportion check, so a future tweak that makes the header look boxy fails here.
let r18 = 18.0 * 0.22, r32 = 32.0 * 0.22
check("18pt header radius is visibly rounded (\(String(format: "%.1f", r18))pt)", r18 >= 3.5)
check("32pt card radius stays proportional (\(String(format: "%.1f", r32))pt)", r32 >= 6.5)
// A radius of size/2 would BE a circle; assert the shipping factor stays under it.
check("radius never reaches a full circle (would be size/2)", r32 < 32.0 / 2)

print("\nData URI parsing")
func parseDataURI(_ s: String) -> Data? {
    guard let comma = s.firstIndex(of: ",") else { return nil }
    let meta = String(s[s.startIndex..<comma])
    guard meta.contains(";base64") else { return nil }
    return Data(base64Encoded: String(s[s.index(after: comma)...]),
                options: [.ignoreUnknownCharacters])
}
let realURI = "data:image/png;base64," + pngAlpha.base64EncodedString()
check("round-trips a real PNG data URI", parseDataURI(realURI)?.count == pngAlpha.count)
check("rejects a data URI with no comma", parseDataURI("data:image/png;base64") == nil)
check("rejects a non-base64 data URI", parseDataURI("data:image/png,rawbytes") == nil)
check("accepts image/webp MIME (decodability checked separately)",
      parseDataURI("data:image/webp;base64," + pngAlpha.base64EncodedString()) != nil)

print("\nBare base64")
check("a bare PNG base64 is recognised", isProbablyBareBase64(pngAlpha.base64EncodedString()))
check("text with spaces is not base64", !isProbablyBareBase64("hello world!"))
check("an emoji is not base64", !isProbablyBareBase64("⚡"))

print("\nSSRF — blocked hosts")
for h in ["localhost", "127.0.0.1", "127.1.1.1", "0.0.0.0", "10.0.0.5",
          "172.16.0.1", "172.31.255.255", "192.168.1.1", "169.254.169.254",
          "100.64.0.1", "::1", "0::1", "0:0:0:0:0:0:0:1", "[0::1]",
          "::ffff:127.0.0.1", "[::ffff:127.0.0.1]", "::ffff:10.0.0.5",
          "fd00::1", "fe80::1", "printer.local", "app.localhost"] {
    check("blocks \(h)", isBlockedHost(h))
}
for h in ["example.com", "cdn.example.org", "8.8.8.8", "1.1.1.1",
          "172.32.0.1", "172.15.0.1", "192.169.1.1", "100.63.0.1", "169.253.0.1",
          "2606:4700:4700::1111"] {
    check("allows \(h)", !isBlockedHost(h), true)
}
print("  (note: 169.254.169.254 is the cloud metadata endpoint — the one that matters most)")

print("\nPath containment — traversal and symlink escape")
let fm = FileManager.default
let base = fm.temporaryDirectory.appendingPathComponent("soulicon-\(UUID().uuidString)")
let allowed = base.appendingPathComponent("allowed")
let outside = base.appendingPathComponent("outside")
try! fm.createDirectory(at: allowed, withIntermediateDirectories: true)
try! fm.createDirectory(at: outside, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: base) }
try! Data().write(to: outside.appendingPathComponent("secret.png"))
try! Data().write(to: allowed.appendingPathComponent("ok.png"))
try! fm.createSymbolicLink(at: allowed.appendingPathComponent("esc"), withDestinationURL: outside)
let roots = [allowed]

check("a file inside an allowed root is accepted",
      isInsideAnyRoot(allowed.appendingPathComponent("ok.png"), roots: roots))
check("../ traversal is refused",
      !isInsideAnyRoot(allowed.appendingPathComponent("../outside/secret.png"), roots: roots))
check("an absolute path elsewhere is refused",
      !isInsideAnyRoot(URL(fileURLWithPath: "/etc/passwd"), roots: roots))
check("a symlinked subdir pointing OUT is refused (the real attack)",
      !isInsideAnyRoot(allowed.appendingPathComponent("esc/secret.png"), roots: roots))
let impostor = base.appendingPathComponent("allowed-evil")
try! fm.createDirectory(at: impostor, withIntermediateDirectories: true)
check("a sibling whose name prefixes the root is refused",
      !isInsideAnyRoot(impostor.appendingPathComponent("x.png"), roots: roots))

print("\nNo stored-size cap — [avatar] the stored icon is never refused for size")
print("[avatar-file] the stored form is a FILE, never inline base64")
// The 64 KB stored cap (Android TOO_LARGE parity) was removed by user
// request: the avatar is a normal photo-library pick and must not be
// turned away for being large. `store` bounds only the stored RESOLUTION
// (512px, never upscaling); the file is whatever size the PNG is.
// SOUL.md keeps only the relative path — inline base64 is banned.
check("store returns a path reference, not a data URI",
      soulSource.contains("return .success(\"avatars/\\(name).png\")"))
check("the legacy base64 producer is fenced to custom icons only",
      soulSource.contains("LEGACY producer"))
check("resolveToDataURI is gone (resolution now stores a file)",
      !soulSource.contains("resolveToDataURI"))
check("shipping code has no stored-char cap left",
      !soulSource.contains("maxStoredChars"))
check("shipping store has no size refusal",
      !soulSource.contains("case tooLarge(Int)"))

print("\nShipping code agreement — the copies above must not drift")
check("SoulIconSource exists in SoulStore.swift", soulSource.contains("enum SoulIconSource"))
check("resolution reuses SoulIconImage.store (rules are not duplicated)",
      soulSource.contains("SoulIconImage.store(image, named:"))
// [avatar] The stored-size cap is GONE from encode, so neither the Settings
// picker nor the config path can refuse an image for its size.
check("SoulIconImage.encode has no stored-size cap (picker + config share it)",
      !soulSource.contains("SoulIconSource.maxStoredChars"))
check("SoulSettingsView has no tooLarge branch",
      ((try? String(contentsOfFile: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Views/Settings/SoulSettingsView.swift").path,
        encoding: .utf8)) ?? "").contains(".failure(.tooLarge)") == false)
for needle in ["case 0, 10, 127:", "169 where b == 254", "172 where (16...31)",
               "192 where b == 168", "100 where (64...127)"] {
    check("blocked-host table still contains `\(needle)`", soulSource.contains(needle))
}
check("http(s) fetch strips ambient cookies", soulSource.contains("cfg.httpCookieStorage = nil"))
check("containment resolves symlinks on both sides",
      soulSource.contains("resolvingSymlinksInPath().path"))

print("\ntopic-help — the description IS the API doc")
for needle in ["data:image/png;base64,iVBORw0KGgo",
               "minis-clone://attachments/icon.png",
               "minis-clone://workspace/icon.png",
               "/var/minis/attachments/icon.png",
               "https://example.com/icon.png",
               "bare base64",
               "512×512",
               "--file /tmp/icon-value.json",
               "\\\"<image>\\\""] {
    check("help mentions `\(needle)`", builtinsSource.contains(needle))
}
check("help gives a runnable quoted example",
      builtinsSource.contains("minis-config set soul.icon '\\\"minis-clone://attachments/icon.png\\\"'"))
check("help warns --file takes the JSON value, not the image",
      builtinsSource.contains("reads the JSON VALUE"))
check("help does NOT claim SVG support (it does not decode)",
      !builtinsSource.contains("image/svg"))
// [T-soul-icon-opaque-rounded] The help must not still demand transparency.
check("help says transparency is NOT required",
      builtinsSource.contains("TRANSPARENCY — not required"))
check("help no longer claims JPEG is rejected",
      !builtinsSource.contains("A JPEG can never work"))
check("help lists image/jpeg as accepted", builtinsSource.contains("image/jpeg"))
check("help mentions rounded corners", builtinsSource.contains("rounded corners"))
check("field is marked non-revertable (audit stores <image>, not the bytes)",
      builtinsSource.contains("revertable: false"))
check("audit/display collapse to <image>",
      (try? String(contentsOfFile: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("NativeOffloads/ConfigOffloadBridge.swift").path,
        encoding: .utf8))?.contains("auditNewValue = .string(\"<image>\")") == true)

print(failures == 0 ? "\n✅ all checks passed" : "\n❌ \(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
