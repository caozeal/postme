import AppKit
import SwiftUI
import XCTest
@testable import Postme

/// `JSONHighlighter` 的行为测试。
///
/// 这些断言全部围绕**契约**而非实现细节，因为高亮最容易踩的两个坑都在契约层：
/// 1. 着色只能改属性、不能改字符——改字符会污染撤销栈并触发 `textDidChange` 重入；
/// 2. 编辑态必须可着色（旧实现用 `isEditable` 直接挡掉，导致请求体永远无色）。
///
/// 颜色按 `==` 比较即可：`systemBlue` 等语义色在无主题环境下比较的是语义标识而非 RGB
/// （已在真机验证），所以这些断言不依赖运行时的外观设置。
///
/// 整个类标 `@MainActor`：`async` 的 XCTest 用例默认跑在后台线程，
/// 在那里构造 `NSTextView` / `NSWindow` 会直接抛 `NSInternalInconsistencyException`。
@MainActor
final class JSONHighlighterTests: XCTestCase {

    private func highlighted(_ text: String, editable: Bool = true) -> NSTextView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        textView.isRichText = false
        textView.isEditable = editable
        textView.string = text
        JSONHighlighter.apply(to: textView, fontSize: 12.5)
        return textView
    }

    private func color(_ textView: NSTextView, of needle: String) -> NSColor? {
        let text = textView.textStorage!.string as NSString
        let range = text.range(of: needle)
        guard range.location != NSNotFound else { return nil }
        return textView.textStorage!.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
    }

    // MARK: - 着色正确性

    func testColorsKeysValuesNumbersAndKeywords() {
        let text = #"{"k":"v","n":1,"b":true,"z":null,"f":-1.5e3}"#
        let textView = highlighted(text)

        XCTAssertEqual(color(textView, of: "\"k\""), .systemBlue, "对象键应为 key 色")
        XCTAssertEqual(color(textView, of: "\"v\""), .systemRed, "字符串值应为 string 色")
        XCTAssertEqual(color(textView, of: "1"), .systemPurple, "数字应为 number 色")
        XCTAssertEqual(color(textView, of: "true"), .systemOrange, "true 应为关键字色")
        XCTAssertEqual(color(textView, of: "null"), .systemOrange, "null 应为关键字色")
        XCTAssertEqual(color(textView, of: "-1.5e3"), .systemPurple, "负号与指数形式的数字应整体着色")
    }

    func testEscapedQuoteDoesNotTerminateString() {
        // 转义引号若被当成结束引号，后面的键就会串成字符串值，整份正文颜色错乱。
        let text = #"{"a":"x\"y","b":1}"#
        let textView = highlighted(text)

        XCTAssertEqual(color(textView, of: "\"b\""), .systemBlue, "转义引号之后的键仍应是 key 色")
        XCTAssertEqual(color(textView, of: "\"x"), .systemRed, "含转义引号的字符串值应是 string 色")
    }

    // MARK: - 硬约束：只改属性，不改字符

    func testHighlightingDoesNotChangeText() {
        // 硬约束：着色只能改属性。高亮一旦"重写"文档，最危险的退化是顺手规范化正文
        // （解析后重新序列化 → 重排键顺序、改写数字格式），而那正是要发出去的字节。
        // 这里用「键顺序 + 字面格式」都敏感的一段正文把这条钉住。
        let text = #"{"zz":1,"a":2.50,"n":1e3,"empty":"","u":"\u00e9"}"#
        let textView = highlighted(text)

        XCTAssertEqual(textView.textStorage!.string, text, "着色不得改动任何一个字节")
    }

    // MARK: - 编辑态

    func testEditableViewIsHighlighted() {
        // 回归：旧实现对 isEditable 直接 return false，请求体永远无色。
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        textView.isEditable = true
        textView.string = #"{"a":1}"#
        XCTAssertTrue(JSONHighlighter.apply(to: textView, fontSize: 12.5))
        XCTAssertEqual(color(textView, of: "\"a\""), .systemBlue)
    }

    // MARK: - 上限

    func testTextOverLimitIsSkipped() {
        // 超大正文跳过着色，避免主线程卡顿；但字体仍需正常设置。
        let huge = "[" + String(repeating: #"{"a":1},"#, count: 200_000) + "{}]"
        XCTAssertGreaterThan(huge.utf8.count, APIResponse.highlightSizeLimit)
        let textView = highlighted(huge)

        XCTAssertNotEqual(color(textView, of: "\"a\""), .systemBlue, "超过上限不应着色")
        XCTAssertNotNil(
            textView.textStorage!.attribute(.font, at: 1, effectiveRange: nil),
            "跳过着色也应保证字体设置"
        )
    }

    func testEmptyTextIsNoOp() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        textView.string = ""
        XCTAssertFalse(JSONHighlighter.apply(to: textView, fontSize: 12.5))
    }

    // MARK: - 编辑态节流（CodeTextView 的防抖契约）

    func testEditingHighlightsOnlyAfterDebounce() async throws {
        // 编辑态的着色必须防抖：每个按键同步重扫全文会让大正文卡顿。
        // 这条把「按键当下不着色、静置后才着色」钉住。
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        textView.isRichText = false
        textView.isEditable = true
        textView.string = #"{"a":1}"#

        let coordinator = CodeTextView.Coordinator(
            text: .constant(""),
            fontSize: 12.5,
            debounce: .milliseconds(60)
        )
        coordinator.textView = textView
        coordinator.highlightsJSON = true
        coordinator.appliedText = textView.string

        // 模拟一次按键：回调里只应排程，不应立刻着色。
        textView.insertText("X", replacementRange: NSRange(location: 1, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        XCTAssertNotEqual(
            color(textView, of: "\"a\""), .systemBlue,
            "按键当下不应同步着色（O(n) 扫描会拖慢输入）"
        )

        // 静置超过防抖间隔后应着色。
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(
            color(textView, of: "\"a\""), .systemBlue,
            "静置后应完成着色"
        )
    }

    func testCancelPendingHighlightStopsScheduledWork() async throws {
        // 视图销毁时挂起的任务必须取消，否则任务会持有一个已离开视图层级的 textView。
        // 防抖间隔要短于等待时间，否则"没着色"只是因为任务还没到点，测不出取消行为。
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        textView.isRichText = false
        textView.isEditable = true
        textView.string = #"{"a":1}"#
        let coordinator = CodeTextView.Coordinator(
            text: .constant(""),
            fontSize: 12.5,
            debounce: .milliseconds(80)
        )
        coordinator.textView = textView
        coordinator.highlightsJSON = true
        coordinator.appliedText = textView.string

        textView.insertText("X", replacementRange: NSRange(location: 1, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        coordinator.cancelPendingHighlight()

        // 等待时间远超防抖间隔：若取消无效，任务会在这段时间内完成着色。
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNotEqual(color(textView, of: "\"a\""), .systemBlue, "取消后不应再着色")
    }

    // MARK: - 开关翻转（JSON ↔ Raw Text）

    func testClearRemovesHighlightingButKeepsFont() {
        let textView = highlighted(#"{"a":1}"#)
        XCTAssertEqual(color(textView, of: "\"a\""), .systemBlue)

        XCTAssertTrue(JSONHighlighter.clear(in: textView, fontSize: 12.5))
        XCTAssertNotEqual(color(textView, of: "\"a\""), .systemBlue, "清除后不应残留 JSON 配色")
        XCTAssertNotNil(textView.textStorage!.attribute(.font, at: 1, effectiveRange: nil), "字体应保留")
    }

    /// 开关翻转走**真实 SwiftUI 宿主**。
    ///
    /// 回归：从 JSON 切到 Raw Text 时正文没变，若 `updateNSView` 只在「文本变化」时处理，
    /// 就会残留上一模式的 JSON 配色。这条必须经过 `updateNSView` 才测得到——
    /// 直接调 coordinator 的方法会漏掉那个分支（实测：把分支删掉，直调版本照样通过）。
    func testTogglingHighlightOffClearsColorsThroughHostingView() {
        final class Model: ObservableObject {
            @Published var flag = true
        }
        struct Harness: View {
            @ObservedObject var model: Model
            let text: Binding<String>
            var body: some View {
                CodeTextView(text: text, highlightJSON: model.flag)
            }
        }

        let model = Model()
        let text = #"{"a":1}"#
        let hosting = NSHostingView(rootView: Harness(model: model, text: Binding.constant(text)))
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        pump()

        guard let textView = Self.firstTextView(in: hosting) else {
            return XCTFail("宿主视图里没有找到 NSTextView")
        }
        XCTAssertEqual(color(textView, of: "\"a\""), .systemBlue, "初始 JSON 模式应着色")

        model.flag = false
        pump()
        XCTAssertNotEqual(color(textView, of: "\"a\""), .systemBlue, "切到 Raw Text 后不应残留配色")

        model.flag = true
        pump()
        XCTAssertEqual(color(textView, of: "\"a\""), .systemBlue, "切回 JSON 应恢复着色")
    }

    /// 跑几轮 runloop，让 SwiftUI 完成布局与 representable 更新。
    private func pump(_ seconds: TimeInterval = 0.4) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private static func firstTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for sub in view.subviews {
            if let found = firstTextView(in: sub) { return found }
        }
        return nil
    }
}
