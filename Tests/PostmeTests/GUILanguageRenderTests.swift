import XCTest
import SwiftUI
import AppKit
import Vision
@testable import Postme

/// GUI 语言切换验证:把真实视图放进真实窗口渲染，用 Vision 读像素里的文字。
///
/// 为什么不能用 `app.t(.key)` 断言代替：那只证明字符串表对，不证明**界面真的重画了**。
/// 这里覆盖的失败模式是「@Observable 没触发重算」「某个视图读了静态字符串」——
/// 单元测试全绿而用户看到的还是旧语言。
///
/// 需要窗口截屏权限（屏幕录制）。默认跳过，用
/// `POSTME_GUI_VERIFY=1 swift test --filter GUILanguageRenderTests` 显式运行。
@MainActor
final class GUILanguageRenderTests: XCTestCase {
    /// 保活到进程结束：测试中途关闭窗口会让 SwiftUI 在拆解阶段访问已释放的 layer（signal 11）。
    private var retainedWindows: [NSWindow] = []

    private func pump(_ seconds: TimeInterval = 0.5) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// 把 SwiftUI 视图放进真实窗口，用 `screencapture -l <windowNumber>` 抓窗口像素。
    ///
    /// 不用 `ImageRenderer`：它不跑 AppKit 的表单/列表布局，Form、Picker、OutlineGroup
    /// 会渲染成空白——那样的"没文字"是测量工具的问题，不是界面的问题。
    /// 也不用 `cacheDisplay`：它只画进 backing store，跨进程合成的内容（Picker 弹出层、
    /// 侧栏材质）抓不到。窗口级截屏才是用户真正看到的东西。
    private func render<V: View>(_ view: V, size: CGSize, to path: String) throws {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        pump(1.0)

        let shot = Process()
        shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        shot.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
        try shot.run()
        shot.waitUntilExit()
        window.orderOut(nil)
        retainedWindows.append(window)
        pump(0.2)

        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("窗口截屏失败: \(path)")
        }
    }

    /// 用 Vision 读渲染结果里的文字——这是"用户实际看到什么"的机器可读版本。
    private func ocr(_ path: String) throws -> String {
        guard let image = NSImage(contentsOfFile: path),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw XCTSkip("无法读取截图: \(path)")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// 截屏需要「屏幕录制」权限；没有权限时抓出来是空白，宁可跳过也不误报。
    /// 因此默认跳过，必须显式设 `POSTME_GUI_VERIFY=1` 才运行。
    private func requireScreenCapture() throws {
        guard ProcessInfo.processInfo.environment["POSTME_GUI_VERIFY"] == "1" else {
            throw XCTSkip("GUI 渲染验证需显式开启: POSTME_GUI_VERIFY=1 swift test --filter GUILanguageRenderTests")
        }
    }

    func testRenderedViewsFollowLanguage() throws {
        try requireScreenCapture()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("postme-render-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("workspace")
        let shots = root.appendingPathComponent("shots")
        for sub in [dir, shots] {
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        func shot(_ name: String) -> String { shots.appendingPathComponent(name).path }
        let app = AppState(persistence: PersistenceService(fileName: "workspace.json", directory: dir),
                           languageOverride: .zhHans)

        // 1) 中文渲染
        try render(SettingsView().environment(app), size: CGSize(width: 480, height: 620),
                   to: shot("settings-zh.png"))
        try render(RequestEditorView().environment(app), size: CGSize(width: 900, height: 700),
                   to: shot("editor-zh.png"))
        try render(SidebarView().environment(app), size: CGSize(width: 300, height: 700),
                   to: shot("sidebar-zh.png"))

        let settingsZh = try ocr(shot("settings-zh.png"))
        XCTAssertTrue(settingsZh.contains("界面语言"), "设置面板中文: \(settingsZh)")
        // Picker 收起时只显示当前选中值(选项在弹出层里),所以断言可见的选中值。
        XCTAssertTrue(settingsZh.contains("简体中文"), "中文界面选中值应为简体中文: \(settingsZh)")
        XCTAssertTrue(settingsZh.contains("超时时间"), "其它分区也应中文: \(settingsZh)")

        let editorZh = try ocr(shot("editor-zh.png"))
        XCTAssertTrue(editorZh.contains("发送"), "编辑区中文按钮: \(editorZh)")
        XCTAssertTrue(editorZh.contains("保存"), "编辑区中文保存按钮: \(editorZh)")
        XCTAssertTrue(editorZh.contains("参数名"), "中文占位符: \(editorZh)")

        let sidebarZh = try ocr(shot("sidebar-zh.png"))
        XCTAssertTrue(sidebarZh.contains("搜索请求"), "侧栏中文搜索占位符: \(sidebarZh)")
        XCTAssertTrue(sidebarZh.contains("历史"), "侧栏中文历史标题: \(sidebarZh)")

        // 2) 切到英文（同一 app 实例，不重建视图）
        app.setLanguage(.en)
        try render(SettingsView().environment(app), size: CGSize(width: 480, height: 620),
                   to: shot("settings-en.png"))
        try render(RequestEditorView().environment(app), size: CGSize(width: 900, height: 700),
                   to: shot("editor-en.png"))
        try render(SidebarView().environment(app), size: CGSize(width: 300, height: 700),
                   to: shot("sidebar-en.png"))

        let settingsEn = try ocr(shot("settings-en.png"))
        XCTAssertTrue(settingsEn.contains("Interface language"), "设置面板英文: \(settingsEn)")
        XCTAssertTrue(settingsEn.contains("English"), "英文界面选中值应为 English: \(settingsEn)")
        XCTAssertTrue(settingsEn.contains("Timeout"), "其它分区也应英文: \(settingsEn)")
        XCTAssertTrue(settingsEn.contains("Skip HTTPS certificate validation"),
                      "README 引用的设置项文案必须与界面一致: \(settingsEn)")
        XCTAssertFalse(settingsEn.contains("界面语言"), "英文界面不应残留中文标签")
        XCTAssertFalse(settingsEn.contains("超时时间"), "英文界面不应残留中文标签")

        let editorEn = try ocr(shot("editor-en.png"))
        XCTAssertTrue(editorEn.contains("Send"), "英文按钮: \(editorEn)")
        XCTAssertTrue(editorEn.contains("Save"), "英文保存按钮: \(editorEn)")
        XCTAssertTrue(editorEn.contains("Parameter name"), "英文占位符: \(editorEn)")
        XCTAssertFalse(editorEn.contains("参数名"), "不应残留中文占位符: \(editorEn)")
        XCTAssertFalse(editorEn.contains("发送"), "不应残留中文按钮: \(editorEn)")

        let sidebarEn = try ocr(shot("sidebar-en.png"))
        XCTAssertTrue(sidebarEn.contains("Search requests"), "侧栏英文搜索占位符: \(sidebarEn)")
        XCTAssertTrue(sidebarEn.contains("History"), "侧栏英文历史标题: \(sidebarEn)")
        XCTAssertFalse(sidebarEn.contains("搜索请求"), "侧栏不应残留中文: \(sidebarEn)")
        // 项目名是用户数据,不随界面语言改变——这条同时证明"只翻界面,不翻数据"。
        XCTAssertTrue(sidebarEn.contains("默认项目"), "旧数据里的项目名不应被改写: \(sidebarEn)")

        // 3) 切回中文
        app.setLanguage(.zhHans)
        try render(RequestEditorView().environment(app), size: CGSize(width: 900, height: 700),
                   to: shot("editor-zh2.png"))
        XCTAssertTrue(try ocr(shot("editor-zh2.png")).contains("发送"), "切回中文应恢复")
    }
}
