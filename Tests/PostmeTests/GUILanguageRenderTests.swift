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

    /// Vision 读出的文字 + 归一化坐标（原点在左下角）。
    private struct OCRLine {
        var text: String
        var minY: CGFloat
    }

    private func ocrLines(_ path: String) throws -> [OCRLine] {
        guard let image = NSImage(contentsOfFile: path),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw XCTSkip("无法读取截图: \(path)")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            return OCRLine(text: text, minY: box.minY)
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

    /// SSE 事件分页：真实发一次流式请求，渲染响应区，用 OCR 证明用户看到什么。
    ///
    /// 覆盖的失败模式是「状态位对、视图不画」：`SSEStateTests` 只能证明 `stream.events`
    /// 里有什么，证明不了「事件」分页真的出现在分段控件里、事件数据真的画出来了。
    /// 同一条用例自带负控——非 SSE 请求后同一位置**不得**出现「事件」。
    func testSSEEventsPaneRendersEventsAndHidesTabForNonSSE() throws {
        try requireScreenCapture()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("postme-sse-render-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("workspace")
        let shots = root.appendingPathComponent("shots")
        for sub in [dir, shots] {
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        func shot(_ name: String) -> String { shots.appendingPathComponent(name).path }

        let chunks = [
            Data("event: delta\ndata: 第一条事件\n\n".utf8),
            Data("data: 第二条事件\n\n".utf8)
        ]
        let server = try LocalHTTPServer(routes: [
            "/sse": .stream(chunks: chunks, interval: 0, contentType: "text/event-stream", closeAfterLast: true),
            "/plain": .fixed(Data("plain".utf8), contentType: "text/plain")
        ])
        defer { server.stop() }

        let app = AppState(persistence: PersistenceService(fileName: "workspace.json", directory: dir),
                           languageOverride: .zhHans)

        // 真的发一次流式请求（不手改状态：要走真实解析与终态路径）。
        app.draft = APIRequest(name: "sse", url: server.url("/sse"))
        let send = Task { await app.send() }
        pump(1.5)
        _ = send

        XCTAssertEqual(app.activeTab.stream.events.count, 2, "前置条件：应已收到两条事件")
        XCTAssertEqual(app.responseSection, .events)

        try render(ResponseView().environment(app), size: CGSize(width: 900, height: 520), to: shot("sse-events-zh.png"))
        let sse = try ocr(shot("sse-events-zh.png"))
        XCTAssertTrue(sse.contains("事件"), "分段控件应出现「事件」分页: \(sse)")
        XCTAssertTrue(sse.contains("已结束"), "流结束后状态栏应显示「已结束」: \(sse)")
        XCTAssertTrue(sse.contains("第一条事件"), "事件数据必须真的画出来: \(sse)")
        XCTAssertTrue(sse.contains("第二条事件"), "两条事件都应可见: \(sse)")
        XCTAssertTrue(sse.contains("delta"), "event: 字段应作为类型徽标出现: \(sse)")

        // 英文界面：同一格切语言后事件仍在，文案跟着变。
        app.setLanguage(.en)
        try render(ResponseView().environment(app), size: CGSize(width: 900, height: 520), to: shot("sse-events-en.png"))
        let english = try ocr(shot("sse-events-en.png"))
        XCTAssertTrue(english.contains("Events"), "英文界面应有 Events 分页: \(english)")
        XCTAssertTrue(english.contains("Closed"), "英文界面状态应为 Closed: \(english)")
        XCTAssertFalse(english.contains("已结束"), "英文界面不应残留中文状态: \(english)")

        // 负控：非 SSE 请求后「事件」分页必须消失，事件数据也不该留在界面上。
        // 先切回中文——界面此刻是英文，不断言中文的「事件」就只是自说自话。
        app.setLanguage(.zhHans)
        app.draft = APIRequest(name: "plain", url: server.url("/plain"))
        let second = Task { await app.send() }
        pump(1.0)
        _ = second

        XCTAssertEqual(app.responseSection, .body)
        try render(ResponseView().environment(app), size: CGSize(width: 900, height: 520), to: shot("plain-zh.png"))
        let plain = try ocr(shot("plain-zh.png"))
        XCTAssertFalse(plain.contains("事件"), "非 SSE 响应不应显示「事件」分页: \(plain)")
        XCTAssertFalse(plain.contains("Events"), "非 SSE 响应不应显示 Events 分页: \(plain)")
        XCTAssertFalse(plain.contains("第一条事件"), "非 SSE 响应不应残留上一次的事件: \(plain)")
        XCTAssertTrue(plain.contains("Body"), "非 SSE 响应仍应显示 Body 分页: \(plain)")
    }

    /// B1 的像素证据：取消/中断后的状态栏。
    ///
    /// 审查原文的两个症状都必须在真实窗口里消失：
    /// 1. 「已取消」与「接收中」同屏；
    /// 2. `.failed(message)` 的消息只存在于数据里、界面上读不到。
    func testCancelledAndFailedStreamStatusBarShowsTerminalStateOnly() throws {
        try requireScreenCapture()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("postme-sse-terminal-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("workspace")
        let shots = root.appendingPathComponent("shots")
        for sub in [dir, shots] {
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        func shot(_ name: String) -> String { shots.appendingPathComponent(name).path }

        let chunk = Data("data: tick\n\n".utf8)
        let server = try LocalHTTPServer(routes: [
            "/endless": .stream(
                chunks: Array(repeating: chunk, count: 200),
                interval: 0.2,
                contentType: "text/event-stream",
                closeAfterLast: false
            ),
            "/cut": .stream(chunks: [Data("data: kept\n\n".utf8)], interval: 0, contentType: "text/event-stream", closeAfterLast: false)
        ])
        defer { server.stop() }

        let app = AppState(persistence: PersistenceService(fileName: "workspace.json", directory: dir),
                           languageOverride: .zhHans)

        // 1) 取消：状态栏只描述本次流。
        app.draft = APIRequest(name: "endless", url: server.url("/endless"))
        let send = Task { await app.send() }
        for _ in 0..<200 where app.activeTab.stream.events.isEmpty {
            pump(0.05)
        }
        XCTAssertFalse(app.activeTab.stream.events.isEmpty, "前置条件：应已收到事件")
        app.cancelSend()
        pump(1.0)
        _ = send
        XCTAssertEqual(app.activeTab.stream.status, .cancelled)

        try render(ResponseView().environment(app), size: CGSize(width: 900, height: 520), to: shot("sse-cancelled-zh.png"))
        let cancelled = try ocr(shot("sse-cancelled-zh.png"))
        XCTAssertTrue(cancelled.contains("已取消"), "取消后应显示「已取消」: \(cancelled)")
        XCTAssertFalse(cancelled.contains("接收中"), "取消后不得出现「接收中」: \(cancelled)")
        XCTAssertTrue(cancelled.contains("事件"), "事件分页仍应在: \(cancelled)")

        // 2) 中断：失败原因必须在界面上读得到（不只是 tooltip）。
        var settings = app.workspace.settings
        settings.timeout = 1
        app.updateSettings(settings)
        app.draft = APIRequest(name: "cut", url: server.url("/cut"))
        let second = Task { await app.send() }
        pump(2.5)
        _ = second

        guard case .failed(let message) = app.activeTab.stream.status else {
            XCTFail("应为 .failed，实际: \(app.activeTab.stream.status)")
            return
        }
        XCTAssertFalse(message.isEmpty)

        try render(ResponseView().environment(app), size: CGSize(width: 900, height: 520), to: shot("sse-failed-zh.png"))
        let failed = try ocr(shot("sse-failed-zh.png"))
        XCTAssertTrue(failed.contains("已中断"), "中断后应显示「已中断」: \(failed)")
        XCTAssertFalse(failed.contains("接收中"), "中断后不得出现「接收中」: \(failed)")
        // OCR 对整句英文的识别不保证逐字符一致，取消息里最有辨识度的一段子串。
        let probe = String(message.prefix(18))
        XCTAssertTrue(failed.contains(probe) || failed.lowercased().contains("timed out"),
                      "失败原因必须在界面上可见（期望含「\(probe)」）: \(failed)")
    }

    /// 请求栏的「复制为 cURL」只留图标：文字不得出现在栏里，tooltip 仍要说明它是什么。
    ///
    /// 失败模式：把 `Label(...)` 写回去——编译、功能、单测全过，只是请求栏又变挤了。
    func testCopyCurlButtonShowsIconOnly() throws {
        try requireScreenCapture()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("postme-copy-curl-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("workspace")
        let shots = root.appendingPathComponent("shots")
        for sub in [dir, shots] {
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let path = shots.appendingPathComponent("editor.png").path

        let app = AppState(persistence: PersistenceService(fileName: "workspace.json", directory: dir),
                           languageOverride: .zhHans)
        app.draft = APIRequest(name: "图标按钮", url: "https://api.example.com/v1/orders")
        try render(RequestEditorView().environment(app), size: CGSize(width: 900, height: 700), to: path)

        let text = try ocr(path)
        XCTAssertTrue(text.contains("发送"), "请求栏应仍渲染发送按钮: \(text)")
        XCTAssertFalse(text.contains("复制为 cURL"), "请求栏不应再出现「复制为 cURL」文字: \(text)")

        // 文字从可见标签挪到了 tooltip / 无障碍标签：两者都取同一份本地化文案。
        XCTAssertEqual(app.t(.copyCurlButton), "复制为 cURL")
        XCTAssertTrue(app.t(.copyCurlHelp).contains("curl"))

        // 图标本身必须真的画得出来：SF Symbol 名字写错时 SwiftUI 静默渲染空白，
        // OCR 也读不到，于是"去掉文字"就变成了"按钮消失"。
        XCTAssertNotNil(
            NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right",
                    accessibilityDescription: nil),
            "复制为 cURL 用的 SF Symbol 必须存在"
        )
    }

    /// 历史区：默认收起（只有一栏标题，记录不可见），展开后记录出现在左下角。
    ///
    /// 这条覆盖的是纯视图行为，`SidebarHistoryPanelTests` 覆盖不到：
    /// 状态位是对的、但视图仍然常驻渲染，测试照样全绿。
    func testHistoryPanelCollapsedByDefaultThenExpands() throws {
        try requireScreenCapture()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("postme-history-render-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("workspace")
        let shots = root.appendingPathComponent("shots")
        for sub in [dir, shots] {
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        func shot(_ name: String) -> String { shots.appendingPathComponent(name).path }

        // 播种一条可辨识的历史记录，再按真实载入路径构造 AppState。
        let service = PersistenceService(fileName: "workspace.json", directory: dir)
        var seeded = service.load()
        seeded.pushHistory(HistoryEntry(
            request: APIRequest(name: "历史标记记录", url: "https://history-marker.example.com/x"),
            statusCode: 200, duration: 0.1, succeeded: true
        ))
        service.saveNow(seeded)
        let app = AppState(persistence: service, languageOverride: .zhHans)
        XCTAssertEqual(app.history.count, 1)

        try render(SidebarView().environment(app), size: CGSize(width: 300, height: 700),
                   to: shot("sidebar-collapsed.png"))
        let collapsedLines = try ocrLines(shot("sidebar-collapsed.png"))
        let collapsed = collapsedLines.map(\.text).joined(separator: "\n")
        XCTAssertTrue(collapsed.contains("历史"), "收起时仍应看到历史标题: \(collapsed)")
        XCTAssertFalse(collapsed.contains("历史标记记录"), "默认收起时历史条目不得可见: \(collapsed)")

        // 「左下角」是这个需求的另一半：标题必须贴近底边（Vision 的 y 轴从下往上，0 = 底）。
        let header = try XCTUnwrap(
            collapsedLines.first { $0.text.contains("历史") },
            "没读到历史标题的位置: \(collapsedLines.map(\.text))"
        )
        XCTAssertLessThan(header.minY, 0.15, "历史标题应在侧栏底部，实际 y=\(header.minY)")

        app.setHistoryExpanded(true)
        try render(SidebarView().environment(app), size: CGSize(width: 300, height: 700),
                   to: shot("sidebar-expanded.png"))
        let expanded = try ocr(shot("sidebar-expanded.png"))
        XCTAssertTrue(expanded.contains("历史标记记录"), "展开后应看到历史条目: \(expanded)")
    }

    // MARK: - 大模型输出分页

    /// 「大模型输出」分页的像素证据：真实 SSE 请求 → 真实窗口 → Vision OCR。
    ///
    /// 覆盖的失败模式与事件分页那条同源：状态位对、视图不画。这里还必须证明两件
    /// 只有像素能证明的事——① 分页控件里出现「大模型输出」；② 拼接文本真的画在主区域
    /// （而不是只在 `stream.llm.fields` 里）。
    func testLLMOutputPaneRendersJoinedTextAndTab() throws {
        try requireScreenCapture()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("postme-llm-render-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("workspace")
        let shots = root.appendingPathComponent("shots")
        for sub in [dir, shots] {
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        func shot(_ name: String) -> String { shots.appendingPathComponent(name).path }

        // OpenAI 形状：三个 delta 拼成一句可 OCR 的完整话。
        let pieces = ["大模型", "拼接", "验证通过"]
        let chunks = pieces.map { piece in
            Data(#"data: {"choices":[{"index":0,"delta":{"content":"\#(piece)"}}]}"#.utf8 + Data("\n\n".utf8))
        }
        let server = try LocalHTTPServer(routes: [
            "/sse": .stream(chunks: chunks, interval: 0, contentType: "text/event-stream", closeAfterLast: true)
        ])
        defer { server.stop() }

        let app = AppState(persistence: PersistenceService(fileName: "workspace.json", directory: dir),
                           languageOverride: .zhHans)

        app.draft = APIRequest(name: "sse", url: server.url("/sse"))
        let send = Task { await app.send() }
        pump(1.5)
        _ = send

        // 前置条件：状态层确实拼好了。
        XCTAssertEqual(app.activeTab.stream.llm.fields.first?.text, pieces.joined(), "前置条件：拼接文本应完整")
        XCTAssertEqual(app.responseSection, .events, "默认落点仍是事件分页")

        app.responseSection = .llm
        try render(ResponseView().environment(app), size: CGSize(width: 900, height: 520), to: shot("llm-zh.png"))
        let zh = try ocr(shot("llm-zh.png"))
        XCTAssertTrue(zh.contains("大模型输出"), "分段控件应出现「大模型输出」分页: \(zh)")
        XCTAssertTrue(zh.contains("事件"), "事件分页应仍在: \(zh)")
        XCTAssertTrue(zh.contains("大模型"), "拼接文本必须真的画在主区域: \(zh)")
        XCTAssertTrue(zh.contains("验证通过"), "拼接文本尾部也应可见: \(zh)")
        XCTAssertTrue(zh.contains("OpenAI"), "格式标识应显示: \(zh)")

        // 英文界面：文案跟着变，拼接内容（用户数据）不变。
        app.setLanguage(.en)
        try render(ResponseView().environment(app), size: CGSize(width: 900, height: 520), to: shot("llm-en.png"))
        let en = try ocr(shot("llm-en.png"))
        XCTAssertTrue(en.contains("Model Output"), "英文分页标题: \(en)")
        XCTAssertFalse(en.contains("大模型输出"), "英文界面不应残留中文分页标题: \(en)")
        XCTAssertTrue(en.contains("验证通过"), "拼接内容不随界面语言改变: \(en)")

        // 负控：非 SSE 响应后该分页必须消失（控件里没有，内容区也不该按它渲染）。
        app.setLanguage(.zhHans)
        let plainServer = try LocalHTTPServer(routes: [
            "/plain": .fixed(Data("plain".utf8), contentType: "text/plain")
        ])
        defer { plainServer.stop() }
        app.draft = APIRequest(name: "plain", url: plainServer.url("/plain"))
        let second = Task { await app.send() }
        pump(1.0)
        _ = second

        XCTAssertEqual(app.responseSection, .body)
        try render(ResponseView().environment(app), size: CGSize(width: 900, height: 520), to: shot("llm-plain.png"))
        let plain = try ocr(shot("llm-plain.png"))
        XCTAssertFalse(plain.contains("大模型输出"), "非 SSE 响应不应显示该分页: \(plain)")
        XCTAssertFalse(plain.contains("验证通过"), "非 SSE 响应不应残留拼接文本: \(plain)")

        // 设置页的新分区：标题、说明与已保存路径都要画出来，且不得把既有分区挤出可视区。
        XCTAssertTrue(app.addLLMCustomPath("choices[0].delta.custom"))
        try render(SettingsView().environment(app), size: CGSize(width: 480, height: 700),
                   to: shot("settings-llm-zh.png"))
        let settingsZh = try ocr(shot("settings-llm-zh.png"))
        XCTAssertTrue(settingsZh.contains("大模型输出字段路径"), "设置页应有该分区: \(settingsZh)")
        // OCR 会把 `[0]` 读成全角括号，只断言不会被误读的那半截。
        XCTAssertTrue(settingsZh.contains("delta.custom"), "已保存路径应列出: \(settingsZh)")
        XCTAssertTrue(settingsZh.contains("超时时间"), "既有分区不得被挤掉: \(settingsZh)")
        XCTAssertTrue(settingsZh.contains("证书校验"), "既有证书开关不得被挤掉: \(settingsZh)")
    }

    /// LangGraph 形状：整份快照重复推送，界面必须显示「LangChain」格式且文本只出现一次。
    ///
    /// 为什么单独一条：这条路径的核心风险不是「画不出来」，而是**同一份答案被拼好几遍**——
    /// 那种 bug 在纯状态断言里已经钉住（`testLangGraphRepeatedSnapshotDoesNotDuplicateText`），
    /// 这里补的是「用户真的能在界面上看到它只出现一次」。
    func testLangGraphSnapshotsRenderOnceWithLangChainFormat() throws {
        try requireScreenCapture()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("postme-lg-render-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("workspace")
        let shots = root.appendingPathComponent("shots")
        for sub in [dir, shots] {
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        func shot(_ name: String) -> String { shots.appendingPathComponent(name).path }

        let answer = "LangGraph 快照只拼一次"
        let payload = #"{"response":{"role":"assistant","blocks":[{"block_type":"text","text":"\#(answer)"}]},"structured_response":null,"current_agent_name":"Default Assistant","tool_calls":[]}"#
        let event = "data: " + payload + "\n\n"
        // 同一份快照推 3 次（真实 LangGraph 每步都重推整份状态）。
        let chunks = Array(repeating: Data(event.utf8), count: 3)
        let server = try LocalHTTPServer(routes: [
            "/lg": .stream(chunks: chunks, interval: 0, contentType: "text/event-stream", closeAfterLast: true)
        ])
        defer { server.stop() }

        let app = AppState(persistence: PersistenceService(fileName: "workspace.json", directory: dir),
                           languageOverride: .zhHans)
        app.draft = APIRequest(name: "lg", url: server.url("/lg"))
        let send = Task { await app.send() }
        pump(1.5)
        _ = send

        let field = try XCTUnwrap(app.activeTab.stream.llm.fields.first)
        XCTAssertEqual(app.activeTab.stream.llm.format, .langGraph, "格式应识别为 LangChain")
        XCTAssertEqual(field.path, "response.blocks[0].text")
        XCTAssertEqual(field.text, answer, "前置条件：重复快照不得拼多遍")

        app.responseSection = .llm
        try render(ResponseView().environment(app), size: CGSize(width: 900, height: 520), to: shot("lg-zh.png"))
        let zh = try ocr(shot("lg-zh.png"))
        XCTAssertTrue(zh.contains("LangChain"), "格式标识应显示 LangChain: \(zh)")
        XCTAssertTrue(zh.contains("LangGraph 快照"), "拼接文本必须画在主区域: \(zh)")
        XCTAssertFalse(zh.contains("快照只拼一次快照只拼一次"), "界面上也不得出现重复拼接: \(zh)")
    }
}
