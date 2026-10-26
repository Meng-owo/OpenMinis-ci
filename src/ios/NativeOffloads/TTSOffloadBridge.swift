//
//  TTSOffloadBridge.swift
//  MinisApp
//
//  Swift bridge for `minis-tts` offload.
//

import Foundation

@objc public class TTSOffloadBridge: NSObject {

    @objc public static func listServices() -> NSDictionary {
        let sem = DispatchSemaphore(value: 0)
        var out: [String: Any] = [:]

        Task.detached {
            let serviceStore = TTSServiceStore.shared
            let groupStore = TTSGroupStore.shared

            let services = serviceStore.services.map { s in
                [
                    "id": s.id,
                    "name": s.name,
                    "kind": s.kind.rawValue,
                    "voice": s.voice,
                    "enabled": s.enabled,
                    "is_current_selected": (s.id == serviceStore.selectedServiceId)
                ] as [String: Any]
            }

            let groups = groupStore.groups.map { g in
                [
                    "id": g.id,
                    "name": g.name,
                    "service_ids": g.memberServiceIds,
                    "is_default": (g.id == groupStore.defaultGroupId)
                ] as [String: Any]
            }

            out = [
                "ok": true,
                "has_configured_voice": TTSPaper.hasConfiguredVoice(),
                "default_group_id": groupStore.defaultGroupId ?? NSNull(),
                "selected_service_id": serviceStore.selectedServiceId ?? NSNull(),
                "services": services,
                "groups": groups
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
        return out as NSDictionary
    }

    @objc public static func getStatus() -> NSDictionary {
        let sem = DispatchSemaphore(value: 0)
        var out: [String: Any] = [:]

        Task.detached {
            let desc = TTSPaper.standingCapability()
            let paper = TTSPaper.paperText()
            out = [
                "ok": true,
                "configured": TTSPaper.hasConfiguredVoice(),
                "capability_statement": desc ?? "TTS not configured",
                "manual": paper ?? "No active TTS service"
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
        return out as NSDictionary
    }
}
