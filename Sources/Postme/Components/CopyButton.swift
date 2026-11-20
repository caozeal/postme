import Accessibility
import SwiftUI

struct CopyButton: View {
    @Environment(AppState.self) private var app
    @State private var lastCopy: UUID?

    let title: String
    var icon: AppIcon = .copy
    var help: String? = nil
    let text: () -> String

    var body: some View {
        let copyID = lastCopy
        let copied = copyID != nil
        let confirmation = app.t(.copySucceeded)

        Button {
            guard FileActions.copyToPasteboard(text()) else { return }
            lastCopy = UUID()
            AccessibilityNotification.Announcement(confirmation).post()
        } label: {
            // 两种状态共用宽度，避免反馈出现时挤动工具栏或切换布局。
            ZStack {
                Label(title, icon: icon).opacity(copied ? 0 : 1)
                Label {
                    Text(confirmation)
                } icon: {
                    Image(icon: .completed).foregroundStyle(statusTint(for: 200))
                }
                .opacity(copied ? 1 : 0)
            }
        }
        .help(copied ? confirmation : help ?? title)
        .accessibilityLabel(title)
        .accessibilityValue(copied ? confirmation : "")
        .task(id: copyID) {
            guard copyID != nil else { return }
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled, lastCopy == copyID else { return }
            lastCopy = nil
        }
        .onDisappear { lastCopy = nil }
    }
}
