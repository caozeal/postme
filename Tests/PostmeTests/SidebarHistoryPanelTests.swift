import XCTest
@testable import Postme

/// 侧栏历史区：默认收起、状态持久化、清空需确认。
///
/// 背景（用户要求）：历史原先作为 List 的一个 Section 常驻在目录树下方，
/// 有记录时会把目录树挤到半屏以下；而目录树是每次都要看的，历史只在回查时用。
/// 改成左下角固定的一行标题，默认收起，点开向上展开。
@MainActor
final class SidebarHistoryPanelTests: XCTestCase {

    private func makeDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("postme-history-panel-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeApp(_ dir: URL) -> AppState {
        AppState(persistence: PersistenceService(fileName: "workspace.json", directory: dir),
                 languageOverride: .zhHans)
    }

    /// 新装用户默认收起（不是"读到 nil 才收起"）。
    func testHistoryCollapsedByDefault() {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let app = makeApp(dir)
        XCTAssertFalse(app.workspace.settings.historyExpanded)
    }

    /// 展开状态必须落盘并在重启后保持——否则每次启动都要重新点开。
    func testExpandedStateSurvivesRelaunch() {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = makeApp(dir)
        first.setHistoryExpanded(true)
        first.saveImmediately()
        XCTAssertTrue(first.workspace.settings.historyExpanded)

        let relaunched = makeApp(dir)
        XCTAssertTrue(relaunched.workspace.settings.historyExpanded, "展开状态应随 settings 落盘")

        relaunched.setHistoryExpanded(false)
        relaunched.saveImmediately()
        let third = makeApp(dir)
        XCTAssertFalse(third.workspace.settings.historyExpanded, "收起状态同样要落盘")
    }

    /// 旧文件没有 historyExpanded 键 → 取 Default（收起），不能让整份工作区作废。
    func testLegacySettingsWithoutKeyFallBackToCollapsed() throws {
        let json = #"{"timeout":10,"followRedirects":true,"allowInsecureTLS":false}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertFalse(settings.historyExpanded)
        XCTAssertEqual(settings.timeout, 10, "其余字段照常解码")
    }

    /// 清空是不可撤销的：必须先进确认态，而不是按下就删。
    func testClearHistoryRequiresConfirmation() {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 先播种两条历史（保存后再构造 AppState，走真实载入路径）。
        let service = PersistenceService(fileName: "workspace.json", directory: dir)
        var seeded = service.load()
        for url in ["https://a.example.com/x", "https://b.example.com/y"] {
            seeded.pushHistory(HistoryEntry(request: APIRequest(name: "h", url: url),
                                            statusCode: 200, duration: 0.1, succeeded: true))
        }
        service.saveNow(seeded)

        let app = AppState(persistence: service, languageOverride: .zhHans)
        XCTAssertEqual(app.history.count, 2)

        app.requestClearHistory()
        XCTAssertTrue(app.showClearHistoryConfirm, "应进入确认态")
        XCTAssertEqual(app.history.count, 2, "确认前不得删除任何记录")

        app.clearHistory()
        app.saveImmediately()
        XCTAssertFalse(app.showClearHistoryConfirm, "确认后关闭确认态")
        XCTAssertTrue(app.history.isEmpty)

        // 清空也要落盘，否则重启后被删的记录会回来。
        let relaunched = makeApp(dir)
        XCTAssertTrue(relaunched.history.isEmpty)
    }

    /// 历史为空时点「清空」不弹框。
    func testClearHistoryOnEmptyDoesNothing() {
        let dir = makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let app = makeApp(dir)
        app.requestClearHistory()
        XCTAssertFalse(app.showClearHistoryConfirm)
    }
}
