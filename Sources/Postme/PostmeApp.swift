import SwiftUI
import AppKit

/// 应用委托。
/// 作用:当以裸二进制方式启动(例如 `swift run` 或双击 `Contents/MacOS/postme`)时,
/// 进程默认以 accessory/prohibited 姿态启动,窗口不会置前、也没有菜单栏。
/// 这里强制切回常规 App 姿态并激活,保证开发期体验一致。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct PostmeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// 顶层状态容器。@Observable 配 @State(不是 @StateObject)。
    @State private var app = AppState()

    var body: some Scene {
        Window("postme", id: "main") {
            ContentView()
                .environment(app)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建请求") { app.newRequest() }
                    .keyboardShortcut("n", modifiers: .command)

                Divider()

                Button("导入集合(Postman / ApiPost)…") { FileActions.importPostman(into: app) }
                    .keyboardShortcut("i", modifiers: [.command, .shift])

                Button("导出集合为 Postman…") { FileActions.exportPostman(from: app) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .saveItem) {
                Button("保存到集合") { app.beginSave() }
                    .keyboardShortcut("s", modifiers: .command)
            }

            CommandGroup(after: .toolbar) {
                Button("发送请求") { Task { await app.send() } }
                    .keyboardShortcut(.return, modifiers: .command)

                Button("取消请求") { app.cancelSend() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!app.isSending)

                Divider()

                Button("搜索请求") { app.requestSearchFocus() }
                    .keyboardShortcut("f", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environment(app)
        }
    }
}
