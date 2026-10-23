import XCTest
@testable import Postme

/// cURL 导入落到工作区后的行为：项目归属、草稿保护、落盘。
@MainActor
final class CurlImportTests: XCTestCase {

    /// 用独立目录构造 AppState，避免碰到真实 workspace.json。
    private func makeApp() -> (AppState, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("postme-curl-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = AppState(persistence: PersistenceService(fileName: "workspace.json", directory: dir), languageOverride: .zhHans)
        return (app, dir)
    }

    private func requests(from command: String) throws -> [APIRequest] {
        try CurlCodec.decode(command, l10n: .zhHans).requests
    }

    // MARK: - 新建项目

    func testNewProjectImportBecomesActiveAndPersists() throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let before = app.projects.count
        let imported = app.importCurlRequests(
            try requests(from: "curl 'https://api.demo.com/users' -H 'X-A: 1'\ncurl 'https://api.demo.com/orders'"),
            target: .newProject(name: "api.demo.com")
        )
        XCTAssertEqual(imported, 2)
        XCTAssertEqual(app.projects.count, before + 1)
        XCTAssertEqual(app.activeProject?.name, "api.demo.com")
        XCTAssertEqual(app.activeProject?.children.count, 2)
        XCTAssertEqual(app.activeProject?.children.compactMap { $0.savedRequest?.request.url },
                       ["https://api.demo.com/users", "https://api.demo.com/orders"])

        // 落盘后重新读出来还在（导入是"已保存"的请求，不是编辑器草稿）
        app.saveImmediately()
        let reloaded = AppState(persistence: PersistenceService(fileName: "workspace.json", directory: dir), languageOverride: .zhHans)
        XCTAssertEqual(reloaded.projects.count, before + 1)
        XCTAssertEqual(reloaded.activeProject?.children.count, 2)
        XCTAssertEqual(reloaded.activeProject?.children.first?.savedRequest?.request.headers.first?.key, "X-A")
    }

    func testBlankProjectNameFallsBack() throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        app.importCurlRequests(try requests(from: "curl 'https://api.demo.com/a'"), target: .newProject(name: "   "))
        XCTAssertEqual(app.activeProject?.name, "cURL 导入")
    }

    // MARK: - 并入当前项目

    func testCurrentProjectImportAppendsWithoutNewProject() throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let projectCount = app.projects.count
        let projectName = app.activeProject?.name
        app.importCurlRequests(try requests(from: "curl 'https://api.demo.com/a'"), target: .currentProject)

        XCTAssertEqual(app.projects.count, projectCount)
        XCTAssertEqual(app.activeProject?.name, projectName)
        XCTAssertEqual(app.activeProject?.children.count, 1)
    }

    // MARK: - 草稿保护

    func testImportKeepsUnsavedDraftInItsOwnTab() throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        app.draft = APIRequest(name: "草稿", url: "https://draft.local/edited")
        let draftTab = app.activeTabID
        XCTAssertTrue(app.isDraftDirty)

        app.importCurlRequests(try requests(from: "curl 'https://api.demo.com/a'"), target: .newProject(name: "p"))

        // 自动打开导入的请求，但草稿没被丢：它还在自己那一格里，仍然标着未保存。
        let kept = app.tabs.first { $0.id == draftTab }!
        XCTAssertEqual(kept.draft.url, "https://draft.local/edited")
        XCTAssertTrue(kept.isDirty)
        XCTAssertEqual(app.draft.url, "https://api.demo.com/a", "导入后应停在导入的请求上")
        XCTAssertNotEqual(app.activeTabID, draftTab)
    }

    /// 导入的请求自动打开，并且侧栏选中它（否则导入完还要自己在树里找一遍）。
    func testImportOpensFirstImportedRequest() throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        app.importCurlRequests(
            try requests(from: "curl 'https://api.demo.com/users' -H 'X-A: 1'\ncurl 'https://api.demo.com/orders'"),
            target: .currentProject
        )

        guard let node = app.activeProject?.children.first else { return XCTFail("没导入进去") }
        XCTAssertEqual(app.activeTab.nodeID, node.id, "当前页签应绑定到导入的请求")
        XCTAssertEqual(app.draft.url, "https://api.demo.com/users")
        XCTAssertEqual(app.draft.headers.first?.key, "X-A")
        XCTAssertEqual(app.selectedNodeID, node.id, "侧栏应选中导入的请求")

        // 再打开同一个请求应复用页签，而不是越开越多。
        let tabsBefore = app.tabs.count
        app.openSavedRequest(node)
        XCTAssertEqual(app.tabs.count, tabsBefore)
    }

    /// 面板默认并入当前项目：默认新建项目会每次多出一个项目，请求还得手动挪。
    func testImportSheetDefaultsToCurrentProject() {
        XCTAssertEqual(CurlImportSheet.Target.initial, .currentProject)
        XCTAssertEqual(CurlImportSheet.Target.allCases.first, .newProject)
    }

    func testImportIntoCurrentProjectKeepsOpenTabs() throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 并入当前项目不换侧栏内容：原有页签（含未保存的草稿与归属）都不该被动过，
        // 导入的请求另开一格并成为当前页签。
        app.draft = APIRequest(name: "草稿", url: "https://draft.local/x")
        let tabID = app.activeTabID
        app.newRequest()
        app.draft = APIRequest(name: "第二格", url: "https://second.local/x")
        let secondTabID = app.activeTabID

        app.importCurlRequests(try requests(from: "curl 'https://api.demo.com/a'"), target: .currentProject)

        XCTAssertEqual(app.tabs.count, 3)
        let first = app.tabs.first { $0.id == tabID }!
        XCTAssertEqual(first.draft.url, "https://draft.local/x")
        let second = app.tabs.first { $0.id == secondTabID }!
        XCTAssertEqual(second.draft.url, "https://second.local/x", "导入不该动原有页签的草稿")
        XCTAssertEqual(app.draft.url, "https://api.demo.com/a", "导入后自动打开导入的请求")
    }

    // MARK: - 边界

    func testEmptyImportIsNoop() throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let projects = app.projects.count
        XCTAssertEqual(app.importCurlRequests([], target: .newProject(name: "x")), 0)
        XCTAssertEqual(app.projects.count, projects)
    }

    func testRequestNameIsPreserved() throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        app.importCurlRequests(try requests(from: "curl 'https://api.demo.com/users/42?x=1'"),
                               target: .newProject(name: "p"))
        XCTAssertEqual(app.activeProject?.children.first?.savedRequest?.name, "42")
    }
}
