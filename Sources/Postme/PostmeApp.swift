import SwiftUI
import AppKit
import Foundation

/// 进程入口：无参数保持原生 GUI；出现任何参数则走无窗口 CLI。
/// 分成独立入口类型，才能继续调用 SwiftUI `App` 协议提供的默认 `main()`。
@main
enum PostmeEntryPoint {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.isEmpty else {
            PostmeApp.main()
            return
        }
        exit(PostmeCLI.run(arguments: arguments))
    }
}

/// 应用委托。
/// 作用:当以裸二进制方式启动(例如 `swift run` 或双击 `Contents/MacOS/postme`)时,
/// 进程默认以 accessory/prohibited 姿态启动,窗口不会置前、也没有菜单栏。
/// 这里强制切回常规 App 姿态并激活,保证开发期体验一致。
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 由 ContentView.onAppear 注入；weak 避免委托长期持有状态容器。
    @MainActor weak var appState: AppState?
    /// 「取消退出」后恢复主窗口：关最后一窗触发的退出，决策前窗口已经关了。
    @MainActor var reopenMainWindow: (() -> Void)?
    @MainActor private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // 用户从终端跑完 CLI 切回 GUI 时检测磁盘改动；保存前的 CAS 是另一条兜底路径。
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.appState?.checkForExternalChanges()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MainActor.assumeIsolated { reopenMainWindow?() }
        }
        return true
    }

    /// 退出前做一次权威落盘；失败时挂起退出，把决定权交给界面上的三按钮。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            // 连按 Cmd-Q / 重复关窗时，第二次不要再起一轮挂起。
            guard !terminationPending else { return .terminateLater }
            guard let appState else {
                // 状态容器没注入就不能假装「保存成功」放行；但此时也没有界面可弹，
                // 只能如实记录，让验证/日志能发现这条路径漏了接线。
                print("[postme] 退出时状态容器尚未注入，无法执行退出前保存")
                return .terminateNow
            }
            let result = appState.prepareForTermination()
            if result.isSuccess { return .terminateNow }
            terminationPending = true
            return .terminateLater
        }
    }

    /// 所有退出按钮的唯一出口，保证 NSApp.reply 恰好一次。
    @MainActor
    func finishTermination(_ allow: Bool) {
        guard terminationPending else { return }
        terminationPending = false
        if !allow {
            appState?.dismissSaveIssue()
            reopenMainWindow?()
        }
        NSApp.reply(toApplicationShouldTerminate: allow)
    }
}

struct PostmeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// 顶层状态容器。@Observable 配 @State(不是 @StateObject)。
    @State private var app = AppState()

    var body: some Scene {
        Window("postme", id: "main") {
            ContentView(appDelegate: appDelegate)
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

                Button(app.t(.menuImportOpenAPI)) { FileActions.importOpenAPI(into: app) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])

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

                Button(app.t(.menuFindInResponse)) { app.requestResponseFind() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView()
                .environment(app)
        }
    }
}
