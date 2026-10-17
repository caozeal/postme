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

    func testImportKeepsUnsavedDraft() throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        app.draft = APIRequest(name: "草稿", url: "https://draft.local/edited")
        XCTAssertTrue(app.isDraftDirty)

        app.importCurlRequests(try requests(from: "curl 'https://api.demo.com/a'"), target: .newProject(name: "p"))

        XCTAssertEqual(app.draft.url, "https://draft.local/edited", "导入不该动编辑器里的草稿")
        XCTAssertTrue(app.isDraftDirty)
    }

    func testImportIntoCurrentProjectDoesNotCancelPendingDraftConflict() throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 并入当前项目不换侧栏内容，挂起的草稿冲突与它无关，不该被静默吞掉
        app.draft = APIRequest(name: "草稿", url: "https://draft.local/x")
        app.openSavedRequest(.request(.init(name: "别的请求", request: APIRequest(url: "https://other.local/x"))))
        XCTAssertTrue(app.showDraftConflict)

        app.importCurlRequests(try requests(from: "curl 'https://api.demo.com/a'"), target: .currentProject)
        XCTAssertTrue(app.showDraftConflict, "并入当前项目不该取消挂起的草稿冲突")
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
