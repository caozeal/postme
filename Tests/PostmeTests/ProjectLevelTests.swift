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

    private func importResult() -> OpenAPIImportResult {
        OpenAPIImportResult(title: "Imported", versionLabel: "3", nodes: [],
                            environment: APIEnvironment(name: "Imported", variables: [KeyValueItem(key: "baseUrl", value: "https://new")]),
                            requestCount: 1, folderCount: 0, warnings: [])
    }

    func testOpenAPIImportKeepsEnvironmentUntilProjectSwitchConfirmed() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = app.addEnvironment(name: "Original")
        let project = app.activeProject!.id
        app.draft.url = "https://dirty"
        app.beginOpenAPIImport(result: importResult(), fileName: "spec.json")
        app.commitOpenAPIImport()
        XCTAssertTrue(app.showProjectSwitchConfirm)
        XCTAssertEqual(app.workspace.activeEnvironmentID, old)
        app.cancelProjectSwitch()
        XCTAssertEqual(app.workspace.activeProjectID, project)
        XCTAssertEqual(app.workspace.activeEnvironmentID, old)
        XCTAssertEqual(app.draft.url, "https://dirty")
    }

    func testOpenAPIImportActivatesEnvironmentAfterConfirmedSwitch() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = app.addEnvironment(name: "Original")
        app.draft.url = "https://dirty"
        app.beginOpenAPIImport(result: importResult(), fileName: "spec.json")
        app.commitOpenAPIImport()
        app.discardAndConfirmProjectSwitch()
        XCTAssertEqual(app.activeProject?.name, "Imported")
        XCTAssertNotEqual(app.workspace.activeEnvironmentID, old)
        XCTAssertEqual(app.activeEnvironment?.name, "Imported")
    }

    func testOpenAPIImportSaveAndSwitchPreservesDraftAndActivatesEnvironment() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = app.addEnvironment(name: "Original")
        let oldProject = app.activeProject!.id
        app.draft.url = "https://dirty"
        app.beginOpenAPIImport(result: importResult(), fileName: "spec.json")
        app.commitOpenAPIImport()
        app.saveAndConfirmProjectSwitch()
        XCTAssertEqual(app.activeProject?.name, "Imported")
        XCTAssertNotEqual(app.workspace.activeEnvironmentID, old)
        XCTAssertTrue(app.projects.first(where: { $0.id == oldProject })?.children.contains(where: {
            $0.savedRequest?.request.url == "https://dirty"
        }) == true)
    }

    func testOpenAPIImportIntoCurrentProjectKeepsActiveEnvironment() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = app.addEnvironment(name: "Original")
        app.beginOpenAPIImport(result: importResult(), fileName: "spec.json")
        app.openAPIImportTarget = .currentProject
        app.commitOpenAPIImport()
        XCTAssertEqual(app.workspace.activeEnvironmentID, old)
        XCTAssertEqual(app.environments.count, 2)
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

    func testDeleteProjectUnbindsTabsPointingIntoIt() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = app.newProject(name: "B")
        let nodeID = saveRequest(app, name: "one", url: "https://one")
        XCTAssertEqual(app.editingNodeID, nodeID)

        app.deleteProject(id: app.projects.first { $0.name == "B" }!.id)

        // B 整个消失：指向 B 里节点的页签必须降级成「新请求」，
        // 否则 ⌘S 在 findNode 里找不到节点、静默什么都不做。
        XCTAssertNil(app.editingNodeID)
        XCTAssertEqual(app.draft.url, "https://one", "页签里的内容留着，用户还能另存")
        app.beginSave()
        XCTAssertTrue(app.showSaveSheet)
    }

    // MARK: - 切换项目：瞬态引用必须跟着清

    func testSelectProjectClearsStaleNodeReferences() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = app.newProject(name: "B")
        let nodeID = saveRequest(app, name: "r", url: "https://one")   // 建在 B 里

        app.selectProject(id: app.projects.first!.id)   // 切回默认项目
        XCTAssertEqual(app.activeProject?.name, "默认项目")
        XCTAssertNil(app.selectedNodeID, "选中的节点不在当前项目的树里，不能继续高亮")
        // 编辑器与侧栏同属一个项目上下文：切走后右侧重置——B 的页签关闭，
        // 换成一个空页签。否则会出现「侧栏是 A 项目、编辑器里是 B 项目的请求」，
        // 发送/保存都对着看不见的目录树操作。
        XCTAssertEqual(app.tabs.count, 1)
        XCTAssertNil(app.editingNodeID)
        XCTAssertTrue(app.draft.url.isEmpty, "右侧应清空，不残留上一个项目的请求")
        app.beginSave()
        XCTAssertTrue(app.showSaveSheet, "空页签没有归属，⌘S 应弹窗命名")
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
