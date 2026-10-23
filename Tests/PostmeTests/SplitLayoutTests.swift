import XCTest
import SwiftUI
import AppKit
@testable import Postme

/// 上下分栏的比例（响应区不得被挤成一半）。
///
/// 背景（实测缺陷）：请求区内部是 `ScrollView`，对高度无限贪心；响应区若也只声明弹性，
/// `VSplitView` 会把剩余空间对半分——真实窗口 931 高时两栏各 472/458，响应区
/// （大模型输出、事件列表、Body 全在下半）明显不够用。
///
/// 这条用例钉的是**布局结果**，不是源码里的数字：改回去（只写 idealHeight）会红。
@MainActor
final class SplitLayoutTests: XCTestCase {
    /// 保活到进程结束：测试中途关闭窗口会让 SwiftUI 在拆解阶段访问已释放的 layer。
    private var retainedWindows: [NSWindow] = []

    private func measure(contentHeight: CGFloat) throws -> (request: CGFloat, response: CGFloat) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("postme-split-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let app = AppState(
            persistence: PersistenceService(fileName: "workspace.json", directory: dir),
            languageOverride: .zhHans
        )
        let size = CGSize(width: 1180, height: contentHeight)
        let host = NSHostingView(rootView: ContentView().environment(app))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))

        func findSplit(_ view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView, !split.isVertical { return split }
            for sub in view.subviews {
                if let found = findSplit(sub) { return found }
            }
            return nil
        }

        defer {
            window.orderOut(nil)
            retainedWindows.append(window)
        }
        guard let root = window.contentView, let split = findSplit(root) else {
            throw XCTSkip("找不到竖向分割视图")
        }
        let heights = split.arrangedSubviews.map(\.frame.height)
        guard heights.count >= 2 else { throw XCTSkip("分栏子视图不足") }
        return (heights[0], heights[1])
    }

    func testResponsePaneKeepsItsMinimumHeight() throws {
        let (request, response) = try measure(contentHeight: 800)
        XCTAssertGreaterThanOrEqual(response, 500, "响应区应保住最小高度（实测 \(Int(response))，请求区 \(Int(request))）")
        XCTAssertLessThanOrEqual(request, 320, "请求区不该抢走一半以上（实测 \(Int(request))）")
    }

    /// 请求区自己也得能看：小窗口下两栏都保住下限。
    func testBothPanesStayUsableInSmallWindow() throws {
        let (request, response) = try measure(contentHeight: 620)
        XCTAssertGreaterThanOrEqual(request, 200, "请求区下限 200")
        XCTAssertGreaterThanOrEqual(response, 200, "响应区下限 200")
    }

    /// 大窗口：多出来的高度归响应区，而不是继续对半分。
    func testTallWindowGivesExtraHeightToResponse() throws {
        let (small_request, small_response) = try measure(contentHeight: 800)
        let (tall_request, tall_response) = try measure(contentHeight: 1100)
        XCTAssertGreaterThan(tall_response, small_response, "拉高窗口应让响应区变大")
        XCTAssertLessThanOrEqual(tall_request - small_request, 20, "请求区不应跟着涨（实测涨了 \(Int(tall_request - small_request))）")
    }
}
