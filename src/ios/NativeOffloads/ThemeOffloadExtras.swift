//
//  ThemeOffloadExtras.swift
//  MinisApp
//
//  `minis-theme` coverage for the parts of the appearance system the pack
//  JSON never carried: avatars, replaceable row icons, per-page wallpapers,
//  and single colour overrides.
//
//  The pack is a fixed 26-field document. Everything below lives outside it,
//  so before this file an AI could restyle bubbles, radii and the 16 category
//  tiles and nothing else — asking it to change a settings-row icon or the
//  chat page's wallpaper was impossible, not merely undocumented.
//
//  Every setter takes an image path or hex value, never raw bytes on the
//  command line: `--file` points at a guest path the shell already has.
//

import Foundation
import SwiftUI
import UIKit

@objc public class ThemeOffloadExtras: NSObject {

    // MARK: - Shared plumbing

    /// Runs `work` on the main actor and waits, with the same 5s ceiling the
    /// rest of the theme bridge uses.
    private static func onMain(_ work: @escaping @MainActor () -> [String: Any]) -> NSDictionary {
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any] = [:]
        Task { @MainActor in
            result = work()
            sem.signal()
        }
        if sem.wait(timeout: .now() + 5) == .timedOut {
            NSLog("[CLIBridge] semaphore wait timed out - returning default value")
            return ["ok": false, "error": "timeout",
                    "message": "The appearance system did not answer in 5s."] as NSDictionary
        }
        return result as NSDictionary
    }

    private static func fail(_ code: String, _ message: String) -> [String: Any] {
        ["ok": false, "error": code, "message": message]
    }

    /// Reads an image from a path the caller already resolved.
    ///
    /// The ObjC handler maps guest paths with `noff_resolve_host_path` before
    /// calling in — the same function `minis-theme apply --file` uses — so
    /// one resolver serves both entry points.
    private static func loadImage(_ hostPath: String) -> UIImage? {
        guard !hostPath.isEmpty else { return nil }
        return UIImage(contentsOfFile: hostPath)
    }

    // MARK: - Avatars

    @objc public static func setAvatar(_ role: String, hostPath: String) -> NSDictionary {
        guard let image = loadImage(hostPath) else {
            return fail("no_image", "Cannot read an image at \(hostPath).") as NSDictionary
        }
        return onMain {
            switch role {
            case "user":
                // [B28 R16] 以前只写 studio.userAvatar，而界面读的是 Persona.avatar，
                // 所以命令回 ok、界面不动 —— 看着像空实现。现在写同一个源。
                return storeAvatar(image, personaID: PersonaStore.userProfilePersonaID,
                                   role: "user", fallback: PersonaStore.makeUserProfilePersona())
            case "assistant":
                let pid = PersonaStore.currentID()
                guard let existing = PersonaStore.shared.personas.first(where: { $0.id == pid })
                else { return fail("no_persona", "No persona \(pid).") }
                // 两边都写：SOUL.md 的 icon 是给旧读取路径的镜像，
                // Persona.avatar 是界面/聊天真正读的那一份。
                do {
                    try AppearanceStudio.shared.setAssistantAvatar(image)
                } catch {
                    return fail("save_failed", error.localizedDescription)
                }
                return storeAvatar(image, personaID: pid, role: "assistant", fallback: existing)
            default:
                return fail("bad_role", "role must be user or assistant.")
            }
        }
    }

    @objc public static func removeAvatar(_ role: String) -> NSDictionary {
        onMain {
            switch role {
            case "user":
                clearAvatar(personaID: PersonaStore.userProfilePersonaID)
                AppearanceStudio.shared.removeUserAvatar()
                return ["ok": true, "avatar": "user", "removed": true]
            case "assistant":
                let pid = PersonaStore.currentID()
                clearAvatar(personaID: pid)
                try? AppearanceStudio.shared.removeAssistantAvatar()
                return ["ok": true, "avatar": "assistant", "removed": true]
            default:
                return fail("bad_role", "role must be user or assistant.")
            }
        }
    }

    /// 把图落盘，再把路径写进 Persona.avatar —— 界面、聊天、通讯录读的都是它。
    @MainActor
    private static func storeAvatar(_ image: UIImage, personaID: String,
                                    role: String, fallback: Persona) -> [String: Any] {
        let name = SoulIconImage.storedName(prefix: "persona", id: personaID)
        guard case .success(let path) = SoulIconImage.store(image, named: name) else {
            return fail("save_failed", "Could not store the image.")
        }
        var target = PersonaStore.shared.personas.first(where: { $0.id == personaID }) ?? fallback
        target.avatar = path
        PersonaStore.shared.updatePersona(target)
        return ["ok": true, "avatar": role, "path": path]
    }

    @MainActor
    private static func clearAvatar(personaID: String) {
        guard var target = PersonaStore.shared.personas.first(where: { $0.id == personaID })
        else { return }
        target.avatar = nil
        PersonaStore.shared.updatePersona(target)
    }

    // MARK: - Replaceable row icons

    @objc public static func setIcon(_ slot: String, hostPath: String) -> NSDictionary {
        guard let image = loadImage(hostPath) else {
            return fail("no_image", "Cannot read an image at \(hostPath).") as NSDictionary
        }
        return onMain {
            // [B28 R2-7] 编码或写盘失败以前也报 ok:true。
            guard AppearanceStudio.shared.setIcon(image, for: slot) else {
                return fail("icon_write_failed", "Could not store the icon for slot \u{22}" + slot + "\u{22}.")
            }
            return ["ok": true, "slot": slot]
        }
    }

    @objc public static func removeIcon(_ slot: String) -> NSDictionary {
        onMain {
            // [B28 R2-7 / A-3] 删一个根本没有图标的 slot 以前也回
            // "removed": true —— AI 据此以为清理完成了。现在如实区分。
            let existed = AppearanceStudio.shared.removeIcon(for: slot)
            if existed { return ["ok": true, "slot": slot, "removed": true] }
            return fail("no_icon_for_slot", "Nothing was set for slot \u{22}" + slot + "\u{22}; nothing removed.")
        }
    }

    @objc public static func listIconSlots() -> NSDictionary {
        onMain {
            let slots = QuietIconSlot.allCases.map { slot -> [String: Any] in
                [
                    "slot": slot.rawValue,
                    "title": slot.title,
                    "custom": AppearanceStudio.shared.customIcon(for: slot.rawValue) != nil,
                ]
            }
            return ["ok": true, "count": slots.count, "slots": slots]
        }
    }

    // MARK: - Per-page wallpapers

    @objc public static func setWallpaper(_ scope: String, hostPath: String) -> NSDictionary {
        guard let image = loadImage(hostPath) else {
            return fail("no_image", "Cannot read an image at \(hostPath).") as NSDictionary
        }
        guard let parsed = AppearanceScope(rawValue: scope) else {
            return fail("bad_scope", "scope must be one of: \(AppearanceScope.allCases.map(\.rawValue).joined(separator: ", ")).") as NSDictionary
        }
        return onMain {
            AppearanceStudio.shared.setWallpaper(image, for: parsed)
            return ["ok": true, "scope": parsed.rawValue]
        }
    }

    @objc public static func removeWallpaper(_ scope: String) -> NSDictionary {
        guard let parsed = AppearanceScope(rawValue: scope) else {
            return fail("bad_scope", "scope must be one of: \(AppearanceScope.allCases.map(\.rawValue).joined(separator: ", ")).") as NSDictionary
        }
        return onMain {
            AppearanceStudio.shared.removeWallpaper(parsed)
            return ["ok": true, "scope": parsed.rawValue, "removed": true]
        }
    }

    // MARK: - Single colour override

    @objc public static func setColor(_ role: String, hex: String,
                                      scope: String, variant: String) -> NSDictionary {
        guard let parsedRole = AppearanceColorRole(rawValue: role) else {
            return fail("bad_role",
                        "role must be one of: \(AppearanceColorRole.allCases.map(\.rawValue).joined(separator: ", ")).") as NSDictionary
        }
        guard let parsedScope = AppearanceScope(rawValue: scope) else {
            return fail("bad_scope",
                        "scope must be one of: \(AppearanceScope.allCases.map(\.rawValue).joined(separator: ", ")).") as NSDictionary
        }
        guard let parsedVariant = AppearanceVariant(rawValue: variant) else {
            return fail("bad_variant", "variant must be light or dark.") as NSDictionary
        }
        // Reject junk before it reaches the store: an unparseable hex used to
        // land as pure black with no complaint.
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).uppercased()
        guard (cleaned.count == 6 || cleaned.count == 8),
              cleaned.allSatisfy({ $0.isHexDigit }) else {
            return fail("bad_hex", "hex must be 6 or 8 hex digits, e.g. D4778B.") as NSDictionary
        }
        return onMain {
            AppearanceStudio.shared.setColor(Color(hex: cleaned), role: parsedRole,
                                             scope: parsedScope, variant: parsedVariant)
            return [
                "ok": true, "role": parsedRole.rawValue, "hex": cleaned,
                "scope": parsedScope.rawValue, "variant": parsedVariant.rawValue,
            ]
        }
    }

    @objc public static func clearColor(_ role: String,
                                        scope: String, variant: String) -> NSDictionary {
        guard let parsedRole = AppearanceColorRole(rawValue: role),
              let parsedScope = AppearanceScope(rawValue: scope),
              let parsedVariant = AppearanceVariant(rawValue: variant) else {
            return fail("bad_args", "Unknown role, scope or variant.") as NSDictionary
        }
        return onMain {
            AppearanceStudio.shared.clearOverride(parsedRole, scope: parsedScope, variant: parsedVariant)
            return ["ok": true, "role": parsedRole.rawValue,
                    "scope": parsedScope.rawValue, "variant": parsedVariant.rawValue,
                    "cleared": true]
        }
    }

    /// [T-theme-color-read] 把每个语义角色现在的取值列出来。
    ///
    /// 在这之前 `minis-theme color` 只能写不能读：AI 想「把主文字调深一档」时
    /// 无从知道它现在是哪个值，只能先 `get` 整包再从 JSON 里翻，或者干脆猜一个
    /// 覆盖掉。`get` 回的是**主题包**（字段以返回体为准），和角色表不是
    /// 一回事，所以那条路也不通。
    ///
    /// 每个角色给三样东西：浅色值、深色值、以及有没有被用户手动覆盖过。
    /// 有覆盖才有资格 `--clear`，没覆盖说明它是内置默认值。
    /// 参数不带标签：ObjC 侧的选择器就是 `listColors:`，和同文件其它
    /// 命令（`setColor:hex:scope:variant:`）的写法一致。带标签会生成
    /// `listColorsWithScope:`，C 那边调不到。
    @objc public static func listColors(_ scope: String) -> NSDictionary {
        guard let parsedScope = AppearanceScope(rawValue: scope) else {
            return fail("bad_scope",
                        "scope must be one of: \(AppearanceScope.allCases.map(\.rawValue).joined(separator: ", ")).") as NSDictionary
        }
        return onMain {
            let studio = AppearanceStudio.shared
            let roles = AppearanceColorRole.allCases.map { role -> [String: Any] in
                [
                    "role": role.rawValue,
                    "title": role.title,
                    "hint": role.hint,
                    "light": studio.hex(role, scope: parsedScope, variant: .light),
                    "dark": studio.hex(role, scope: parsedScope, variant: .dark),
                    "customLight": studio.hasOverride(role, scope: parsedScope, variant: .light),
                    "customDark": studio.hasOverride(role, scope: parsedScope, variant: .dark),
                ]
            }
            return ["ok": true, "scope": parsedScope.rawValue,
                    "count": roles.count, "roles": roles]
        }
    }
}
