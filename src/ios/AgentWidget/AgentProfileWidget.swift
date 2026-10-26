import WidgetKit
import SwiftUI
import Foundation

/// [B28 R13] 主屏小组件：把「她是谁 / AI 叫什么」摊在桌面上。
///
/// 数据来自 App Group 容器里的 profile-widget.json（主 App 写，见
/// WidgetProfileBridge）。小组件不读主 App 沙盒，也不自己解析 SOUL.md——
/// 那一层逻辑留在主 App，这里只负责显示。
struct AgentProfileEntry: TimelineEntry {
    let date: Date
    let assistantName: String
    let userName: String
    let line: String
    let accentHex: String
}

struct AgentProfileProvider: TimelineProvider {
    private let appGroup = "group.com.openminis.clone"

    private func payload() -> (String, String, String, String) {
        let fallback = ("小助手", "你", "今天还没聊", "#D4778B")
        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("profile-widget.json"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return fallback }
        return (obj["assistant"] ?? fallback.0,
                obj["user"] ?? fallback.1,
                obj["line"] ?? fallback.2,
                obj["accent"] ?? fallback.3)
    }

    func placeholder(in context: Context) -> AgentProfileEntry {
        AgentProfileEntry(date: Date(), assistantName: "小助手", userName: "你",
                          line: "今天还没聊", accentHex: "#D4778B")
    }

    func getSnapshot(in context: Context, completion: @escaping (AgentProfileEntry) -> Void) {
        let p = payload()
        completion(AgentProfileEntry(date: Date(), assistantName: p.0, userName: p.1,
                                     line: p.2, accentHex: p.3))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AgentProfileEntry>) -> Void) {
        let p = payload()
        let entry = AgentProfileEntry(date: Date(), assistantName: p.0, userName: p.1,
                                      line: p.2, accentHex: p.3)
        // 半小时一刷：主 App 改档案时会主动 reload，这里是兜底。
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct AgentProfileWidget: Widget {
    let kind = "AgentProfileWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AgentProfileProvider()) { entry in
            AgentProfileWidgetView(entry: entry)
        }
        .configurationDisplayName("她和我")
        .description("把称呼和最近一句摊在桌面上")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct AgentProfileWidgetView: View {
    let entry: AgentProfileEntry
    @Environment(\.widgetFamily) private var family

    private var accent: Color { Color(hex: entry.accentHex) }

    var body: some View {
        Group {
            if family == .systemSmall {
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.assistantName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(entry.userName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(entry.line)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    Circle()
                        .fill(accent.opacity(0.18))
                        .frame(width: 34, height: 34)
                        .overlay(
                            Image(systemName: "sparkles")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(accent)
                        )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.assistantName)
                            .font(.system(size: 16, weight: .bold))
                            .lineLimit(1)
                        Text(entry.userName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(accent)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(entry.line)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(14)
        .modifier(WidgetBackgroundCompat())
    }
}

/// iOS 17 的 containerBackground 必须加，否则桌面显示"无法加载"；
/// 16.x 上退回普通背景。
private struct WidgetBackgroundCompat: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            content.containerBackground(for: .widget) {
                Color(uiColor: .secondarySystemGroupedBackground)
            }
        } else {
            content.background(Color(uiColor: .secondarySystemGroupedBackground))
        }
    }
}

private extension Color {
    /// #RRGGBB → Color。小组件里没有主 App 那套主题对象，自己解一下。
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
