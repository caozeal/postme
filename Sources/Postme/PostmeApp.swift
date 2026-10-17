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
                Button(app.t(.menuNewRequest)) { app.newRequest() }
                    .keyboardShortcut("n", modifiers: .command)

                Divider()

                Button(app.t(.menuImportCurl)) { app.showCurlImport = true }
                    .keyboardShortcut("v", modifiers: [.command, .shift])

                Button(app.t(.menuImportPostman)) { FileActions.importPostman(into: app) }
                    .keyboardShortcut("i", modifiers: [.command, .shift])

                Button(app.t(.menuExportPostman)) { FileActions.exportPostman(from: app) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .saveItem) {
                Button(app.t(.menuSaveToProject)) { app.beginSave() }
                    .keyboardShortcut("s", modifiers: .command)
            }

            CommandGroup(after: .toolbar) {
                Button(app.t(.menuSendRequest)) { Task { await app.send() } }
                    .keyboardShortcut(.return, modifiers: .command)

                Button(app.t(.menuCancelRequest)) { app.cancelSend() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!app.isSending)

                Divider()

                Button(app.t(.menuSearchRequests)) { app.requestSearchFocus() }
                    .keyboardShortcut("f", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environment(app)
        }
    }
}
