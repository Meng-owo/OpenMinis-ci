//
//  ThemeOffloadBridge.swift
//  MinisApp
//
//  Swift bridge for `minis-theme`. ObjC handler parses argv / files;
//  this type applies packs on the main actor.
//

import Foundation
import UIKit

@objc public class ThemeOffloadBridge: NSObject {

    @objc public static func currentPack() -> NSDictionary {
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any] = [:]
        Task { @MainActor in
            let pack = AppearanceStudio.shared.exportThemePack(includeWallpaper: false)
            var out = pack.asJSONObject()
            // [B28 A-1] 立绘整张 base64 不再吐给 AI：几百 KB 能把上下文吃满。
            // 想看有没有，读 `hasCharacterArt`。
            out.removeValue(forKey: "characterArtBase64")
            out["hasCharacterArt"] = AppearanceStudio.shared.hasCharacterArt
            out["ok"] = true
            result = out
            sem.signal()
        }
        if sem.wait(timeout: .now() + 5) == .timedOut {
            // 超时不能当成功返回：ObjC 侧把缺 ok 视为 true，会变成
            // 「命令成功但什么都没做」。这里明确给 ok:false。
            NSLog("[CLIBridge] semaphore wait timed out")
            return ["ok": false, "error": "timeout",
                    "message": "The app did not answer within the timeout."] as NSDictionary
        }
        return result as NSDictionary
    }

    @objc public static func applyJSON(_ json: String) -> NSDictionary {
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any] = [:]
        Task { @MainActor in
            guard let data = json.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                result = [
                    "ok": false,
                    "error": "invalid_pack",
                    "message": "JSON is not a theme pack.",
                ]
                sem.signal()
                return
            }
            // [T-theme-export-roundtrip] `export` writes the tool envelope
            // (`{ok,tool,action,data,timestamp}`, NativeOffloadUtils.m:135)
            // while `apply` only ever accepted a bare pack — so the two
            // subcommands of the same CLI disagreed about what a pack looks
            // like, and `export > a.json; apply --file a.json` failed with
            // "invalid_pack". Unwrap the envelope here so anything this tool
            // emits can be fed straight back into it. A bare pack still works:
            // it has no "data" key, so the unwrap is skipped.
            let obj: [String: Any]
            if let wrapped = parsed["data"] as? [String: Any],
               parsed["tool"] != nil || parsed["action"] != nil {
                obj = wrapped
            } else {
                obj = parsed
            }
            // Merge onto the live pack: an AI call that only names colors must
            // not reset radii, fonts, images, or anything else it left out.
            let live = AppearanceStudio.shared.currentThemePack()
            guard let pack = try? AppearanceThemePack.decode(obj, merging: live) else {
                result = [
                    "ok": false,
                    "error": "invalid_pack",
                    "message": "JSON is not a theme pack.",
                ]
                sem.signal()
                return
            }
            // [B28 R3-5 / F-2] 吃不下的字段不再被吞 —— warnings 明说哪些
            // 图没落住，AI 侧能自查重试，不会拿着 ok 当全好。
            let warnings = AppearanceStudio.shared.applyThemePack(pack)
            var out = AppearanceStudio.shared.currentThemePack().asJSONObject()
            out["ok"] = true
            out["applied"] = true
            if !warnings.isEmpty { out["warnings"] = warnings }
            out.removeValue(forKey: "wallpaperJPEGBase64")
            out.removeValue(forKey: "characterArtBase64")
            out["hasCharacterArt"] = AppearanceStudio.shared.hasCharacterArt
            result = out
            sem.signal()
        }
        if sem.wait(timeout: .now() + 5) == .timedOut {
            // 超时不能当成功返回：ObjC 侧把缺 ok 视为 true，会变成
            // 「命令成功但什么都没做」。这里明确给 ok:false。
            NSLog("[CLIBridge] semaphore wait timed out")
            return ["ok": false, "error": "timeout",
                    "message": "The app did not answer within the timeout."] as NSDictionary
        }
        return result as NSDictionary
    }

    @objc public static func exportJSON(includeWallpaper: Bool) -> NSDictionary {
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any] = [:]
        Task { @MainActor in
            let pack = AppearanceStudio.shared.exportThemePack(includeWallpaper: includeWallpaper)
            var out = pack.asJSONObject()
            // [B28 A-1] 默认不吐立绘；只有 `--wallpaper` 明确要整包时才带。
            if !includeWallpaper {
                out.removeValue(forKey: "characterArtBase64")
                out["hasCharacterArt"] = AppearanceStudio.shared.hasCharacterArt
            }
            out["ok"] = true
            result = out
            sem.signal()
        }
        if sem.wait(timeout: .now() + 5) == .timedOut {
            // 超时不能当成功返回：ObjC 侧把缺 ok 视为 true，会变成
            // 「命令成功但什么都没做」。这里明确给 ok:false。
            NSLog("[CLIBridge] semaphore wait timed out")
            return ["ok": false, "error": "timeout",
                    "message": "The app did not answer within the timeout."] as NSDictionary
        }
        return result as NSDictionary
    }

    @objc public static func resetPack() -> NSDictionary {
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any] = [:]
        Task { @MainActor in
            AppearanceStudio.shared.resetThemePack()
            result = [
                "ok": true,
                "reset": true,
                "id": AppearanceThemePack.default.id,
                "name": AppearanceThemePack.default.name,
                "undoAvailable": AppearanceStudio.shared.canUndoThemeReset,
            ]
            sem.signal()
        }
        if sem.wait(timeout: .now() + 5) == .timedOut {
            // 超时不能当成功返回：ObjC 侧把缺 ok 视为 true，会变成
            // 「命令成功但什么都没做」。这里明确给 ok:false。
            NSLog("[CLIBridge] semaphore wait timed out")
            return ["ok": false, "error": "timeout",
                    "message": "The app did not answer within the timeout."] as NSDictionary
        }
        return result as NSDictionary
    }

    @objc public static func undoReset() -> NSDictionary {
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any] = [:]
        Task { @MainActor in
            let ok = AppearanceStudio.shared.undoThemeReset()
            result = ok
                ? ["ok": true, "restored": true]
                : ["ok": false, "error": "no_snapshot",
                   "message": "No theme reset to undo. The snapshot only covers the last reset."]
            sem.signal()
        }
        if sem.wait(timeout: .now() + 5) == .timedOut {
            // 超时不能当成功返回：ObjC 侧把缺 ok 视为 true，会变成
            // 「命令成功但什么都没做」。这里明确给 ok:false。
            NSLog("[CLIBridge] semaphore wait timed out")
            return ["ok": false, "error": "timeout",
                    "message": "The app did not answer within the timeout."] as NSDictionary
        }
        return result as NSDictionary
    }

    @objc public static func saveCurrent(name: String) -> NSDictionary {
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any] = [:]
        Task { @MainActor in
            // [B28 R2-3] 满 40 套时 saveCurrentTheme 现在返回 nil —— 如实
            // 报「库满，先删一套」，不再悄悄顶掉最旧的来腾地方。
            if let item = AppearanceStudio.shared.saveCurrentTheme(name: name) {
                result = [
                    "ok": true,
                    "saved": true,
                    "id": item.id,
                    "name": item.name,
                ]
            } else {
                result = [
                    "ok": false,
                    "error": "library full",
                    "message": "The theme library holds 40 themes. Delete one before saving another.",
                ]
            }
            sem.signal()
        }
        if sem.wait(timeout: .now() + 5) == .timedOut {
            // 超时不能当成功返回：ObjC 侧把缺 ok 视为 true，会变成
            // 「命令成功但什么都没做」。这里明确给 ok:false。
            NSLog("[CLIBridge] semaphore wait timed out")
            return ["ok": false, "error": "timeout",
                    "message": "The app did not answer within the timeout."] as NSDictionary
        }
        return result as NSDictionary
    }

    @objc public static func listSaved() -> NSDictionary {
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any] = [:]
        Task { @MainActor in
            let items = AppearanceStudio.shared.savedThemes().map { item -> [String: Any] in
                [
                    "id": item.id,
                    "name": item.name,
                    "savedAt": ISO8601DateFormatter().string(from: item.savedAt),
                ]
            }
            result = [
                "ok": true,
                "count": items.count,
                "themes": items,
            ]
            sem.signal()
        }
        if sem.wait(timeout: .now() + 5) == .timedOut {
            // 超时不能当成功返回：ObjC 侧把缺 ok 视为 true，会变成
            // 「命令成功但什么都没做」。这里明确给 ok:false。
            NSLog("[CLIBridge] semaphore wait timed out")
            return ["ok": false, "error": "timeout",
                    "message": "The app did not answer within the timeout."] as NSDictionary
        }
        return result as NSDictionary
    }

    @objc public static func applySaved(id: String) -> NSDictionary {
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any] = [:]
        Task { @MainActor in
            if let warnings = AppearanceStudio.shared.applySavedTheme(id: id) {
                var out: [String: Any] = ["ok": true, "applied": true, "id": id]
                if !warnings.isEmpty { out["warnings"] = warnings }
                result = out
            } else {
                result = ["ok": false, "error": "not_found", "message": "No saved theme \(id)"]
            }
            sem.signal()
        }
        if sem.wait(timeout: .now() + 5) == .timedOut {
            // 超时不能当成功返回：ObjC 侧把缺 ok 视为 true，会变成
            // 「命令成功但什么都没做」。这里明确给 ok:false。
            NSLog("[CLIBridge] semaphore wait timed out")
            return ["ok": false, "error": "timeout",
                    "message": "The app did not answer within the timeout."] as NSDictionary
        }
        return result as NSDictionary
    }

    @objc public static func deleteSaved(id: String) -> NSDictionary {
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any] = [:]
        Task { @MainActor in
            let ok = AppearanceStudio.shared.deleteSavedTheme(id: id)
            result = ok
                ? ["ok": true, "deleted": true, "id": id]
                : ["ok": false, "error": "not_found", "message": "No saved theme \(id)"]
            sem.signal()
        }
        if sem.wait(timeout: .now() + 5) == .timedOut {
            // 超时不能当成功返回：ObjC 侧把缺 ok 视为 true，会变成
            // 「命令成功但什么都没做」。这里明确给 ok:false。
            NSLog("[CLIBridge] semaphore wait timed out")
            return ["ok": false, "error": "timeout",
                    "message": "The app did not answer within the timeout."] as NSDictionary
        }
        return result as NSDictionary
    }

    @objc public static func renameSaved(id: String, name: String) -> NSDictionary {
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any] = [:]
        Task { @MainActor in
            let ok = AppearanceStudio.shared.renameSavedTheme(id: id, name: name)
            result = ok
                ? ["ok": true, "renamed": true, "id": id, "name": name]
                : ["ok": false, "error": "not_found", "message": "Rename failed"]
            sem.signal()
        }
        if sem.wait(timeout: .now() + 5) == .timedOut {
            // 超时不能当成功返回：ObjC 侧把缺 ok 视为 true，会变成
            // 「命令成功但什么都没做」。这里明确给 ok:false。
            NSLog("[CLIBridge] semaphore wait timed out")
            return ["ok": false, "error": "timeout",
                    "message": "The app did not answer within the timeout."] as NSDictionary
        }
        return result as NSDictionary
    }
}
