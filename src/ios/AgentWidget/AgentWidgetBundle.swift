import SwiftUI
import WidgetKit

@main
struct AgentWidgetBundle: WidgetBundle {
    var body: some Widget {
        if #available(iOSApplicationExtension 16.2, *) {
            AgentLiveActivityWidget()
        }
        // [B28 R13] 主屏小组件：称呼 + 最近一句。
        AgentProfileWidget()
    }
}
