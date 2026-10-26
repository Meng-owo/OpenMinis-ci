import Foundation

private let logger = AppLogger(category: "DeviceSyncPolicy")

/// Per-device download policy for iCloud Sync (v2).
///
/// Why this exists: v1 had a "Download (device)" toggle in its settings page
/// that wrote `cloudSync.device.<id>.enabled` — and NOTHING ever read it. The
/// switch moved, the user believed sync from that peer was off, and every
/// inbound record from it still landed. The page that held it was then replaced
/// by the v2 screen, so even the illusion disappeared.
///
/// v2 can actually honour the intent, because every record now carries the id
/// of the device that wrote it (`sourceDeviceIdKey`). One caveat drives the
/// whole design here: a record whose origin is unknown MUST NOT be blocked.
/// Old peers don't stamp the key, and records written before this change don't
/// have it — treating "unknown" as "blocked" would silently stop every older
/// device from syncing at all. So the rule is allow-by-default, and only an
/// explicit, attributed origin can be denied.
enum DeviceSyncPolicy {

    /// CloudKit field carrying the writer's device id. Deliberately NOT part of
    /// any type's `knownCloudKeys`: it rides in `PortableRecord.unknownFields`
    /// so an older build that receives it carries it back untouched on any
    /// write-back instead of dropping it.
    static let sourceDeviceIdKey = "syncSourceDeviceId"

    private static func key(_ deviceId: String) -> String {
        "cloudSync.device.\(deviceId).enabled"
    }

    /// Whether downloads FROM `deviceId` are allowed. Defaults to true: a peer
    /// that has never been touched must keep syncing exactly as before.
    static func isEnabled(_ deviceId: String) -> Bool {
        guard !deviceId.isEmpty else { return true }
        let k = key(deviceId)
        guard UserDefaults.standard.object(forKey: k) != nil else { return true }
        return UserDefaults.standard.bool(forKey: k)
    }

    static func setEnabled(_ deviceId: String, _ enabled: Bool) {
        guard !deviceId.isEmpty else { return }
        UserDefaults.standard.set(enabled, forKey: key(deviceId))
        logger.info("[DeviceSyncPolicy] device \(deviceId.prefix(8)) download enabled=\(enabled)")
    }

    /// The inbound gate. `nil` / empty origin means "unknown writer" — allowed,
    /// see the type comment. Our own device id is also allowed: echo filtering
    /// happens separately and must not be confused with a policy decision.
    static func allowsInbound(from sourceDeviceId: String?) -> Bool {
        guard let sourceDeviceId, !sourceDeviceId.isEmpty else { return true }
        return isEnabled(sourceDeviceId)
    }
}
