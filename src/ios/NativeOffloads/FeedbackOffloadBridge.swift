//
//  FeedbackOffloadBridge.swift
//  MinisApp
//
//  Swift bridge for `minis-feedback` offload.
//

import Foundation

@objc public class FeedbackOffloadBridge: NSObject {

    private struct FeedbackItem {
        var sessionId: String
        var messageId: String
        var date: Date
        var tag: String
        var notice: String?
        var userComment: String?
    }

    private static func extractFeedback(from text: String, sessionId: String, messageId: String, date: Date) -> [FeedbackItem] {
        var items: [FeedbackItem] = []
        let pattern = #"<system_runtime_feedback\s+tag="([^"]+)">([\s\S]*?)</system_runtime_feedback>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }

        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))

        for m in matches {
            guard m.numberOfRanges >= 3 else { continue }
            let tag = nsText.substring(with: m.range(at: 1))
            let inner = nsText.substring(with: m.range(at: 2))

            var notice: String? = nil
            if let nRange = inner.range(of: "<notice>"), let eRange = inner.range(of: "</notice>") {
                notice = String(inner[nRange.upperBound..<eRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            var comment: String? = nil
            if let cRange = inner.range(of: "<user_comment>"), let ceRange = inner.range(of: "</user_comment>") {
                comment = String(inner[cRange.upperBound..<ceRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            items.append(FeedbackItem(
                sessionId: sessionId,
                messageId: messageId,
                date: date,
                tag: tag,
                notice: notice,
                userComment: comment
            ))
        }

        // Also fallback parse simple system reminders if no tag
        if items.isEmpty && text.contains("<system-reminder>") {
            let inner = text.replacingOccurrences(of: "<system-reminder>", with: "")
                .replacingOccurrences(of: "</system-reminder>", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !inner.isEmpty {
                items.append(FeedbackItem(
                    sessionId: sessionId,
                    messageId: messageId,
                    date: date,
                    tag: "system_reminder",
                    notice: inner,
                    userComment: nil
                ))
            }
        }

        return items
    }

    @objc public static func listFeedback(days: NSInteger, limit: NSInteger) -> NSDictionary {
        let sem = DispatchSemaphore(value: 0)
        var out: [String: Any] = [:]

        Task.detached {
            let startDate: Date? = days > 0 ? Calendar.current.date(byAdding: .day, value: -days, to: Date()) : nil
            let maxLimit = limit > 0 ? limit : 50

            let matches = await ChatStore.shared.searchMessages(
                sessionIds: nil,
                keywords: ["system_runtime_feedback"],
                limit: maxLimit * 2,
                startDate: startDate,
                endDate: nil
            )

            let dateFmt = DateFormatter()
            dateFmt.dateFormat = "yyyy-MM-dd HH:mm:ss"

            var parsedItems: [[String: Any]] = []
            for m in matches {
                let items = extractFeedback(from: m.snippet, sessionId: m.sessionId, messageId: m.messageId, date: m.createdAt)
                for item in items {
                    var dict: [String: Any] = [
                        "session_id": item.sessionId,
                        "message_id": item.messageId,
                        "timestamp": dateFmt.string(from: item.date),
                        "tag": item.tag,
                    ]
                    if let n = item.notice { dict["notice"] = n }
                    if let c = item.userComment { dict["user_comment"] = c }
                    parsedItems.append(dict)
                }
            }

            let finalSlice = parsedItems.prefix(maxLimit)
            out = [
                "ok": true,
                "count": finalSlice.count,
                "feedback": Array(finalSlice)
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

    @objc public static func summaryFeedback(days: NSInteger) -> NSDictionary {
        let sem = DispatchSemaphore(value: 0)
        var out: [String: Any] = [:]

        Task.detached {
            let startDate: Date? = days > 0 ? Calendar.current.date(byAdding: .day, value: -days, to: Date()) : nil
            let matches = await ChatStore.shared.searchMessages(
                sessionIds: nil,
                keywords: ["system_runtime_feedback"],
                limit: 200,
                startDate: startDate,
                endDate: nil
            )

            var tagCounts: [String: Int] = [:]
            var comments: [String] = []

            for m in matches {
                let items = extractFeedback(from: m.snippet, sessionId: m.sessionId, messageId: m.messageId, date: m.createdAt)
                for item in items {
                    tagCounts[item.tag, default: 0] += 1
                    if let c = item.userComment, !c.isEmpty {
                        comments.append(c)
                    }
                }
            }

            out = [
                "ok": true,
                "days": days > 0 ? days : 30,
                "total_events": matches.count,
                "tag_breakdown": tagCounts,
                "recent_comments": Array(comments.prefix(10))
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
