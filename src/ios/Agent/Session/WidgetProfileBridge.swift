import Foundation
import WidgetKit

/// [B28 R13] 主 App → 主屏小组件的桥。
///
/// 小组件跑在独立进程，读不到主 App 沙盒，所以这里把"她叫什么、AI 叫什么、
/// 最近一句"写成一份小 JSON 放进 App Group，再让 WidgetKit 刷新时间线。
/// 只写显示用的字符串，不写档案正文——小组件不需要，也不该碰。
enum WidgetProfileBridge {
    static let appGroup = "group.com.openminis.clone"
    static let fileName = "profile-widget.json"

    /// 档案/人设一变就调它。主线程读 PersonaStore，所以标 @MainActor。
    @MainActor
    static func refresh() {
        let assistant = SoulStore.displayName(for: PersonaStore.currentID())
        let user = SystemPromptBuilder.userProfileAddressingName()
        let line = SystemPromptBuilder.userProfileField(key: "正在做").isEmpty
            ? SystemPromptBuilder.userProfileField(key: "最近状态")
            : SystemPromptBuilder.userProfileField(key: "正在做")

        let payload: [String: String] = [
            "assistant": assistant,
            "user": user.isEmpty ? "你" : user,
            "line": line.isEmpty ? "点开和我说句话" : line
        ]

        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(fileName) else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: url, options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
