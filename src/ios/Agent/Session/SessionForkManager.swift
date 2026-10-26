import Foundation
import os.log

private let logger = AppLogger(category: "SessionFork")

/// Duplicates local sessions (deep copy of messages + media + compact markers).
@MainActor
final class SessionForkManager {
    static let shared = SessionForkManager()
    private init() {}

    // MARK: - Duplicate Local Session

    /// Deep-copy a local session: messages, media tree, compact markers.
    func duplicateSession(sessionId: String) async -> ChatSession? {
        let store = ChatStore.shared

        guard let session = await store.getSession(sessionId) else {
            logger.error("[Fork] Local session not found: \(sessionId)")
            return nil
        }

        let dupTitle = (session.title ?? AppLocalized("Untitled")) + " " + AppLocalized("(Copy)")
        let newSession = await store.createSession(modelId: session.modelId, title: dupTitle)

        if let category = session.category {
            await store.updateSessionTitle(newSession.id, title: dupTitle, category: category)
        }

        // Inherit pin + folder — a duplicate of a
        // pinned, filed session should stay pinned and filed.
        if let pinnedAt = session.pinnedAt {
            await store.setSessionPinnedAt(pinnedAt, forSession: newSession.id)
        }
        if let folderId = session.folderId {
            await store.setFolder(folderId, forSessions: [newSession.id])
        }

        // [AUD2-07] Carry the rest of the session-level configuration across.
        // createSession writes the GLOBAL memory default, so a copy of a
        // session that had memory switched off silently turned it back on; and
        // the model binding (which provider/model this conversation is pinned
        // to) was never copied, so the copy fell back to the default model.
        let sourceMemoryEnabled = await store.getMemoryEnabled(sessionId: sessionId)
        await store.setMemoryEnabled(sessionId: newSession.id, enabled: sourceMemoryEnabled)
        if let binding = ProviderConfigStore.shared.binding(for: sessionId) {
            ProviderConfigStore.shared.setBinding(
                SessionModelBinding(
                    sessionId: newSession.id,
                    primarySource: binding.primarySource,
                    subModelSource: binding.subModelSource
                ),
                for: newSession.id
            )
        }

        // [AUD2-04] Copy the source's media tree into the duplicate's own
        // directory, then repoint the copied messages' MediaRefs at it (see
        // `rewritingSessionMediaPaths`). Without this the copy's images/files
        // were aliases of the original session's directory: deleting the
        // original (or an iCloud delete on another device) broke every one.
        await store.duplicateSessionMedia(from: sessionId, to: newSession.id)

        let messages = await store.loadMessages(sessionId: sessionId)
        // [T-session-duplicate-compact-marker-ios] Track old→new message id so
        // copied compact markers (which reference DB message ids) can be
        // remapped onto the freshly-minted duplicate messages. Without this the
        // markers dangle and the compact divider/shadow is lost on the copy.
        var oldToNewMessageId: [String: String] = [:]
        for msg in messages {
            let newId = UUID().uuidString
            oldToNewMessageId[msg.id] = newId
            let newMsg = RawMessage(
                id: newId,
                sessionId: newSession.id,
                role: msg.role,
                parts: ChatStore.rewritingSessionMediaPaths(
                    in: msg.parts, from: sessionId, to: newSession.id),
                createdAt: msg.createdAt,
                tokenUsage: msg.tokenUsage,
                reasoningContent: msg.reasoningContent,
                streamInterruptCount: msg.streamInterruptCount,
                errorInfo: msg.errorInfo,
                modelId: msg.modelId,
                modelDisplayName: msg.modelDisplayName,
                providerType: msg.providerType,
                providerInstanceId: msg.providerInstanceId
            )
            await store.appendMessage(newMsg)
        }

        // [T-session-duplicate-compact-marker-ios] Copy compact markers AFTER
        // all messages are appended (so the new messages' sort_orders exist).
        // Zero-marker sessions make this a no-op — the normal duplicate path is
        // untouched. Each marker is remapped independently so multi-compact
        // sessions copy all dividers, in createdAt order (compactMarkers ORDERs
        // by created_at ASC; insertCompactMarker preserves each createdAt).
        let markers = await store.compactMarkers(sessionId: sessionId)
        if !markers.isEmpty {
            // Authoritative new sort_orders, keyed by the new message id.
            let newMessages = await store.loadMessages(sessionId: newSession.id)
            let newSortOrderById = Dictionary(
                uniqueKeysWithValues: newMessages.map { ($0.id, $0.sortOrder) }
            )
            // Remap a referenced message id through the copy map. nil → nil.
            func remapId(_ id: String?) -> String? {
                guard let id else { return nil }
                return oldToNewMessageId[id]
            }
            // Resolve a legacy sort_order fallback to the NEW message's
            // sort_order via the remapped id; keep the original if the id
            // can't be resolved (legacy markers whose id field is nil).
            func remapSortOrder(messageId: String?, original: Int) -> Int {
                guard let newId = remapId(messageId),
                      let so = newSortOrderById[newId] else { return original }
                return so
            }
            var copied = 0
            for marker in markers {
                // All source messages are copied, so every non-nil id field
                // MUST resolve. If one doesn't, the marker is corrupt/dangling
                // already — skip it rather than write a dangling copy.
                let firstKeptNew = remapId(marker.firstKeptMessageId)
                let lastCompactedNew = remapId(marker.lastCompactedMessageId)
                let boundaryNew = remapId(marker.boundaryMessageId)
                if (marker.firstKeptMessageId != nil && firstKeptNew == nil)
                    || (marker.lastCompactedMessageId != nil && lastCompactedNew == nil)
                    || (marker.boundaryMessageId != nil && boundaryNew == nil) {
                    logger.error("[Fork] Skipping compact marker \(marker.id): a referenced message id is not in the copy map (dangling source marker)")
                    continue
                }
                let copy = CompactMarker(
                    id: UUID().uuidString,
                    sessionId: newSession.id,
                    summary: marker.summary,
                    firstKeptSortOrder: remapSortOrder(
                        messageId: marker.firstKeptMessageId,
                        original: marker.firstKeptSortOrder
                    ),
                    compactedCount: marker.compactedCount,
                    createdAt: marker.createdAt,
                    uiBoundarySortOrder: marker.uiBoundarySortOrder.map { _ in
                        remapSortOrder(
                            messageId: marker.boundaryMessageId,
                            original: marker.uiBoundarySortOrder ?? 0
                        )
                    },
                    boundaryMessageId: boundaryNew,
                    firstKeptMessageId: firstKeptNew,
                    lastCompactedMessageId: lastCompactedNew,
                    version: marker.version
                )
                await store.insertCompactMarker(copy)
                copied += 1
            }
            logger.info("[Fork] Copied \(copied)/\(markers.count) compact marker(s) to \(newSession.id)")
        }

        logger.info("[Fork] Duplicated session \(sessionId) → \(newSession.id) (\(messages.count) messages)")
        NotificationCenter.default.post(name: .sessionDidCreate, object: newSession.id)

        return newSession
    }
}

