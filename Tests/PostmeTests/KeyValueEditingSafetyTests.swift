import XCTest
import SwiftUI
import AppKit
@testable import Postme

/// 键值编辑器（Params / Headers / 表单字段共用）的行绑定安全性。
///
/// 这里覆盖的失败模式是**输入框结束后编辑时按旧下标写回**：
/// `ForEach($items)` 生成的是下标绑定，用户在某一行的输入框里打字、
/// 此时数组被换成另一格的（切页签）或被删短（删行），
/// SwiftUI 仍在 `controlTextDidEndEditing` 里写回 `items[旧下标]` ——
/// 实测崩溃：`Fatal error: Index out of range`（`Binding.subscript.getter`
/// → `Array._checkSubscript`），整个 App SIGTRAP 掉，用户看到的就是"闪退"。
///
/// 所以行绑定必须**按 id**：行没了就退化为 no-op，而不是越界。
/// 这些断言只能在真实窗口里跑——崩溃发生在 AppKit 的焦点/结束编辑回调里，
/// 纯状态层测试碰不到那条路径。
@MainActor
final class KeyValueEditingSafetyTests: XCTestCase {
    /// 保活到进程结束：测试中途关窗会让 SwiftUI 在拆解阶段访问已释放的 layer。
    private static var retainedWindows: [NSWindow] = []

    /// 编辑器挂在真实 `$app.draft.queryParams` 上——与 `RequestEditorView` 同一绑定链。
    private struct ProbeEditor: View {
        @Environment(AppState.self) private var app
        var body: some View {
            @Bindable var app = app
            return KeyValueEditor(
                items: $app.draft.queryParams,
                keyPlaceholder: "K",
                valuePlaceholder: "V"
            )
            .frame(width: 520, height: 320)
        }
    }

    private func pump(_ seconds: TimeInterval = 0.4) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func makeApp() -> (AppState, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("postme-kv-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (AppState(
            persistence: PersistenceService(fileName: "workspace.json", directory: dir),
            languageOverride: .zhHans
        ), dir)
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        var out: [NSTextField] = []
        func walk(_ v: NSView) {
            if let field = v as? NSTextField { out.append(field) }
            for sub in v.subviews { walk(sub) }
        }
        walk(view)
        return out
    }

    /// 起一个真实窗口，聚焦 stringValue 等于 `value` 的输入框（按内容定位，不靠下标猜）。
    private func hostEditing<V: View>(
        _ view: V,
        app: AppState,
        focusing value: String,
        size: CGSize = CGSize(width: 520, height: 320)
    ) -> (NSWindow, [NSTextField]) {
        let hosting = NSHostingView(rootView: AnyView(view.environment(app)))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        pump(0.9)

        let fields = textFields(in: hosting)
        guard let target = fields.first(where: { $0.stringValue == value }) else {
            XCTFail("没有值等于 \(value) 的输入框（共 \(fields.count): \(fields.map(\.stringValue))）")
            Self.retainedWindows.append(window)
            return (window, fields)
        }
        XCTAssertTrue(window.makeFirstResponder(target), "输入框没成为第一响应者")
        pump(0.2)

        Self.retainedWindows.append(window)
        return (window, fields)
    }

    /// 正在编辑某行的输入框时切页签：数组被换成另一格的，不能崩、也不能把内容写进另一格。
    func testSwitchingTabWhileEditingRowDoesNotCrashOrLeakIntoOtherTab() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let firstTab = app.activeTabID
        app.draft.queryParams = [
            KeyValueItem(key: "a", value: "1"),
            KeyValueItem(key: "b", value: "2"),
        ]
        app.newRequest()
        let secondTab = app.activeTabID
        XCTAssertTrue(app.tabs.first { $0.id == secondTab }!.draft.queryParams.isEmpty)
        app.activateTab(id: firstTab)

        let (window, _) = hostEditing(ProbeEditor(), app: app, focusing: "1")

        app.activateTab(id: secondTab)
        pump(0.8)
        window.makeFirstResponder(nil)
        pump(0.4)

        let other = app.tabs.first { $0.id == secondTab }!.draft.queryParams
        XCTAssertTrue(other.isEmpty, "切页签后旧页签的内容写进了新页签: \(other.map(\.key))")
        XCTAssertEqual(app.tabs.first { $0.id == firstTab }!.draft.queryParams.map(\.value), ["1", "2"])
    }

    /// 端到端：真外壳（侧栏 + 页签栏 + 请求编辑器）里，编辑 Params 行的输入框切页签。
    /// 页签栏的点击就是 `app.activateTab(id:)`，这里走同一条路径。
    func testSwitchingTabInsideRealContentViewDoesNotCrash() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let firstTab = app.activeTabID
        app.draft.queryParams = [KeyValueItem(key: "a", value: "1")]
        app.newRequest()
        let secondTab = app.activeTabID
        app.activateTab(id: firstTab)

        let (window, _) = hostEditing(
            ContentView(),
            app: app,
            focusing: "1",
            size: CGSize(width: 1000, height: 700)
        )

        app.activateTab(id: secondTab)
        pump(0.9)
        window.makeFirstResponder(nil)
        pump(0.4)

        XCTAssertEqual(app.activeTabID, secondTab)
        XCTAssertTrue(app.tabs.first { $0.id == secondTab }!.draft.queryParams.isEmpty)
        XCTAssertEqual(app.tabs.first { $0.id == firstTab }!.draft.queryParams.first?.value, "1")
    }

    /// 正在编辑某行的输入框时删掉别的行：数组变短后剩下的行不能串位。
    func testDeletingRowWhileEditingKeepsRemainingRowsIntact() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        app.draft.queryParams = [
            KeyValueItem(key: "a", value: "1"),
            KeyValueItem(key: "b", value: "2"),
            KeyValueItem(key: "c", value: "3"),
        ]

        let (window, _) = hostEditing(ProbeEditor(), app: app, focusing: "3") // 第 3 行的 value

        app.draft.queryParams.removeFirst()
        pump(0.5)
        window.makeFirstResponder(nil)
        pump(0.4)

        XCTAssertEqual(app.draft.queryParams.map(\.key), ["b", "c"])
        XCTAssertEqual(app.draft.queryParams.map(\.value), ["2", "3"])
    }

    /// 反面对照：同一格里正常编辑仍要真的写回草稿——按 id 的绑定不能把写回吃掉。
    func testEditingRowStillWritesBackToDraft() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        app.draft.queryParams = [KeyValueItem(key: "a", value: "1")]

        let (window, fields) = hostEditing(ProbeEditor(), app: app, focusing: "1")
        // 直接改 `stringValue` 不会通知 SwiftUI（它监听 controlTextDidChange），
        // 所以走真正的字段编辑器，等价于用户敲键盘。
        guard let target = fields.first(where: { $0.stringValue == "1" }),
              let editor = target.currentEditor() as? NSTextView else {
            return XCTFail("输入框没有字段编辑器，无法模拟真实编辑")
        }
        editor.insertText(
            "edited",
            replacementRange: NSRange(location: 0, length: (editor.string as NSString).length)
        )
        pump(0.3)
        window.makeFirstResponder(nil)
        pump(0.4)

        XCTAssertEqual(app.draft.queryParams.first?.value, "edited")
    }
}
