import SwiftUI

// MARK: - User manual
//
// [T-user-manual 09-11] 说明书。kid 要的「这些东西的说明书做进去」——一个
// Markdown 全文页面,点在 Settings → 「使用手册」里就能看到调用哪几个开关、
// 语音服务怎么配、怎么换声音、气泡怎么读——每次新功能之前已经散在几条
// Header note / Toast / footnote 里教过的东西,统一收来这里。

struct UserManualView: View {
    @State private var content: String = ""
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            if let err = loadError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(MinisTheme.destructive)
                    Text(err)
                        .foregroundStyle(MinisTheme.secondaryText)
                        .font(.caption)
                }
                .padding(.top, 80)
            } else if content.isEmpty {
                ProgressView()
                    .padding(.top, 120)
            } else {
                SelectableMarkdownView(markdown: content)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
        .settingsPage()
        .frame(maxWidth: .infinity)
        .background(MinisTheme.canvas.ignoresSafeArea())
        .navigationTitle("使用手册")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func load() {
        guard let url = Bundle.main.url(forResource: "user-manual", withExtension: "md") else {
            loadError = AppLocalized("User manual is missing from the bundle.", comment: "Manual load error")
            return
        }
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            loadError = error.localizedDescription
        }
    }
}
