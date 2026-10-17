import XCTest
@testable import Postme

/// 项目层级（参考 ApiPost 的「项目」）：切换器状态机、迁移整理、导入导出映射。
///
/// 背景：v3 起顶层从 `collections` 改为 `projects` + `activeProjectID`，
/// 所有节点操作收窄到当前项目。这里守住几条不容静默失效的规则：
/// 至少一个项目、当前项目恒有效、侧栏内容整体更换后瞬态引用必须清理。
@MainActor
final class ProjectLevelTests: XCTestCase {

    private func makeApp() -> (AppState, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("postme-project-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = AppState(persistence: PersistenceService(fileName: "workspace.json", directory: dir), languageOverride: .zhHans)
        return (app, dir)
    }

    private func saveRequest(_ app: AppState, name: String, url: String, intoFolder folderID: UUID? = nil) -> UUID {
        app.draft = APIRequest(name: name, url: url)
        app.saveAsNewRequest(name: name, intoFolder: folderID)
        return app.editingNodeID!
    }

    // MARK: - 不变量：至少一个项目

    func testFreshWorkspaceGetsDefaultProject() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(app.projects.count, 1)
        XCTAssertEqual(app.activeProject?.name, "默认项目")
        XCTAssertEqual(app.workspace.activeProjectID, app.projects.first?.id)
    }

    func testDeleteLastProjectIsRefused() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = app.activeProject!.id
        app.deleteProject(id: id)
        XCTAssertEqual(app.projects.count, 1, "没有项目会让新建/保存都失去落点，必须至少保留一个")
        XCTAssertEqual(app.activeProject?.id, id)
    }

    // MARK: - 项目 CRUD

    func testNewProjectBecomesActive() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = app.newProject(name: "订单服务")
        XCTAssertEqual(app.projects.count, 2)
        XCTAssertEqual(app.workspace.activeProjectID, id)
        XCTAssertEqual(app.activeProject?.name, "订单服务")
    }

    func testNewProjectEmptyNameFallsBack() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = app.newProject(name: "   ")
        XCTAssertEqual(app.projects.first { $0.id == id }?.name, "新建项目")
    }

    func testRenameProject() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = app.activeProject!.id
        app.renameProject(id: id, to: "   ")
        XCTAssertEqual(app.activeProject?.name, "默认项目", "拒空：空名字等于没改")
        app.renameProject(id: id, to: "改名了")
        XCTAssertEqual(app.activeProject?.name, "改名了")
    }

    // MARK: - 删除项目后的状态清理

    func testDeleteProjectFallsBackToFirstRemaining() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let second = app.newProject(name: "B")
        app.deleteProject(id: second)
        XCTAssertEqual(app.projects.count, 1)
        XCTAssertEqual(app.activeProject?.name, "默认项目")
    }

    func testDeleteProjectClearsEditingStateInsideIt() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = app.newProject(name: "B")
        let nodeID = saveRequest(app, name: "r", url: "https://one")   // 建在 B 里
        XCTAssertEqual(app.editingNodeID, nodeID)

        app.deleteProject(id: app.activeProject!.id)   // 删掉正在编辑的节点所在项目
        XCTAssertNil(app.editingNodeID, "悬空的编辑归属会让 ⌘S 静默无效")
        XCTAssertNil(app.selectedNodeID)
    }

    func testDeleteProjectCancelsPendingDraftConflict() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = app.newProject(name: "B")
        let firstID = saveRequest(app, name: "one", url: "https://one")
        app.draft = APIRequest()
        saveRequest(app, name: "two", url: "https://two")

        app.draft.url = "https://unsaved-work"
        app.openSavedRequest(app.activeProject!.children.first { $0.id == firstID }!)
        XCTAssertTrue(app.showDraftConflict)

        app.deleteProject(id: app.activeProject!.id)
        XCTAssertFalse(app.showDraftConflict, "挂起动作针对的节点刚被删掉，继续挂着没有意义")
        XCTAssertNil(app.pendingDraftAction)
    }

    // MARK: - 切换项目：瞬态引用必须跟着清

    func testSelectProjectClearsStaleNodeReferences() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = app.newProject(name: "B")
        let nodeID = saveRequest(app, name: "r", url: "https://one")   // 建在 B 里

        app.selectProject(id: app.projects.first!.id)   // 切回默认项目
        XCTAssertEqual(app.activeProject?.name, "默认项目")
        XCTAssertNil(app.editingNodeID, "editingNodeID 悬空 → ⌘S 静默无效")
        XCTAssertNil(app.selectedNodeID)
        // 草稿本身不被替换——它留在编辑器里，只是不再绑定旧项目的节点
        XCTAssertEqual(app.draft.url, "https://one")
        _ = nodeID
    }

    func testSelectProjectClearsStaleSaveFolderReference() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = app.newProject(name: "B")
        app.newFolder(name: "B 的文件夹", inFolder: nil)
        let staleFolderID = app.activeProject!.children.first!.id
        app.defaultSaveFolderID = staleFolderID
        app.saveSheetFolderID = staleFolderID

        app.selectProject(id: app.projects.first!.id)
        XCTAssertNil(app.defaultSaveFolderID, "保存目标指向旧项目的文件夹 → insert 会静默失败")
        XCTAssertNil(app.saveSheetFolderID)
    }

    // MARK: - 节点操作收窄到当前项目

    func testSearchScopedToActiveProject() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        saveRequest(app, name: "alpha", url: "https://a")
        _ = app.newProject(name: "B")
        saveRequest(app, name: "beta", url: "https://b")

        app.searchKeyword = "alpha"
        XCTAssertEqual(app.searchResults.count, 0, "搜索只覆盖当前项目")
        app.searchKeyword = "beta"
        XCTAssertEqual(app.searchResults.count, 1)
    }

    func testSaveAsNewRequestFallsBackToRootWhenFolderMissing() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        app.draft = APIRequest(name: "x", url: "https://x")
        app.saveAsNewRequest(name: "x", intoFolder: UUID())   // 不存在的文件夹

        XCTAssertEqual(app.activeProject!.children.count, 1, "insert 失败必须兜底落到根，绝不静默吞节点")
        XCTAssertEqual(app.editingNodeID, app.activeProject!.children.first?.id)
    }

    // MARK: - 导入 / 导出

    func testImportCreatesNamedProjectAndActivates() throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = """
        {"info":{"name":"导入的项目","schema":"https://schema.getpostman.com/json/collection/v2.1.0/collection.json"},
         "item":[{"name":"登录","request":{"method":"POST","url":"https://api.demo.com/login"}}]}
        """
        let result = try app.importPostmanCollection(data: Data(json.utf8))

        XCTAssertEqual(result.requestCount, 1)
        XCTAssertEqual(app.projects.count, 2)
        XCTAssertEqual(app.activeProject?.name, "导入的项目", "每个 Postman 集合成为一个同名项目")
        let saved = app.activeProject!.children.first?.savedRequest
        XCTAssertEqual(saved?.name, "登录")
        XCTAssertEqual(saved?.request.url, "https://api.demo.com/login")
    }

    func testExportContainsOnlyActiveProject() throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        saveRequest(app, name: "a1", url: "https://a/1")
        _ = app.newProject(name: "B")
        saveRequest(app, name: "b1", url: "https://b/1")

        app.selectProject(id: app.projects.first!.id)   // 切回默认项目
        let data = try app.postmanExportData()
        let root = (try JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let info = root?["info"] as? [String: Any]
        let items = root?["item"] as? [[String: Any]]

        XCTAssertEqual(info?["name"] as? String, "默认项目", "集合名 = 当前项目名")
        XCTAssertEqual(items?.count, 1, "只导出当前项目，其他项目不混入")
        let url = (items?.first?["request"] as? [String: Any])?["url"] as? [String: Any]
        XCTAssertEqual(url?["raw"] as? String, "https://a/1")
    }

    // MARK: - 顶层文件夹提为项目（旧数据迁移后的整理入口）

    func testPromoteFolderToProjectKeepsChildren() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        app.newFolder(name: "用户中心", inFolder: nil)
        let folderID = app.activeProject!.children.first!.id
        let requestID = saveRequest(app, name: "列表", url: "https://x/list", intoFolder: folderID)

        app.promoteFolderToProject(id: folderID)

        XCTAssertEqual(app.projects.count, 2)
        XCTAssertEqual(app.activeProject?.name, "用户中心")
        let promoted = app.activeProject!
        XCTAssertEqual(promoted.children.count, 1, "子节点原样成为新项目的 children")
        XCTAssertEqual(promoted.children.first?.savedRequest?.id, requestID, "节点 id 必须保留")
        XCTAssertTrue(app.projects.first!.children.isEmpty, "原项目里不再留下这个文件夹")
    }

    func testPromoteKeepsEditingBindingWhenNodeIsInside() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        app.newFolder(name: "用户中心", inFolder: nil)
        let folderID = app.activeProject!.children.first!.id
        let requestID = saveRequest(app, name: "列表", url: "https://x/list", intoFolder: folderID)

        app.promoteFolderToProject(id: folderID)
        // 正在编辑的节点随文件夹一起进了新项目：绑定不应被清掉
        XCTAssertEqual(app.editingNodeID, requestID)
        XCTAssertEqual(app.selectedNodeID, requestID)
    }
}
