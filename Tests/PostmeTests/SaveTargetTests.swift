import XCTest
@testable import Postme

/// 保存目标：覆盖保存的归属、重启后的归属恢复、弹窗默认项目。
///
/// 背景（实测缺陷）：`editingNodeID` 只存在于内存，重启后草稿仍在编辑器里、
/// 归属却是 nil，⌘S 于是每次都弹窗新建——同一份请求被反复复制。
/// 另一处缺陷：保存弹窗只能存到当前项目，且不显示目标项目。
@MainActor
final class SaveTargetTests: XCTestCase {

    private func makeApp() -> (AppState, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("postme-save-target-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = AppState(persistence: PersistenceService(fileName: "workspace.json", directory: dir))
        return (app, dir)
    }

    private func saveRequest(_ app: AppState, name: String, url: String, intoFolder folderID: UUID? = nil) -> UUID {
        app.draft = APIRequest(name: name, url: url)
        app.saveAsNewRequest(name: name, intoFolder: folderID)
        return app.editingNodeID!
    }

    // MARK: - 覆盖保存

    func testBeginSaveOverwritesBoundRequestInsteadOfCreatingNew() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = saveRequest(app, name: "r", url: "https://one")

        app.draft.url = "https://two"
        app.beginSave()

        XCTAssertFalse(app.showSaveSheet, "有归属时 ⌘S 应直接覆盖，不该弹窗")
        XCTAssertEqual(app.activeProject!.children.count, 1, "不得新建重复请求")
        XCTAssertEqual(app.activeProject!.children.first?.id, id)
        XCTAssertEqual(app.activeProject!.children.first?.savedRequest?.request.url, "https://two")
    }

    func testBeginSaveAfterRelaunchOverwritesInsteadOfDuplicating() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("postme-save-target-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = AppState(persistence: PersistenceService(fileName: "workspace.json", directory: dir))
        let id = saveRequest(first, name: "r", url: "https://one")
        first.saveImmediately()

        let relaunched = AppState(persistence: PersistenceService(fileName: "workspace.json", directory: dir))
        XCTAssertEqual(relaunched.editingNodeID, id, "草稿归属必须和草稿一起恢复")
        XCTAssertEqual(relaunched.selectedNodeID, id)

        relaunched.draft.url = "https://two"
        relaunched.beginSave()

        XCTAssertFalse(relaunched.showSaveSheet)
        XCTAssertEqual(relaunched.activeProject!.children.count, 1, "重启后保存不得再复制一份")
        XCTAssertEqual(relaunched.activeProject!.children.first?.savedRequest?.request.url, "https://two")
    }

    func testRelaunchDropsBindingWhenNodeNoLongerExists() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("postme-save-target-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 直接写一份「草稿 + 指向已不存在节点」的文件，模拟旧版本留下的悬空归属。
        let service = PersistenceService(fileName: "workspace.json", directory: dir)
        let project = Project(name: "P")
        service.saveNow(Workspace(
            projects: [project],
            activeProjectID: project.id,
            draft: APIRequest(name: "r", url: "https://one"),
            draftNodeID: UUID()
        ))

        let app = AppState(persistence: PersistenceService(fileName: "workspace.json", directory: dir))
        XCTAssertNil(app.editingNodeID, "悬空归属必须丢弃，否则 ⌘S 静默无效")
        app.beginSave()
        XCTAssertTrue(app.showSaveSheet, "没有归属时应弹窗，而不是静默失败")
    }

    func testOverwriteSavedRequestReportsMissingNode() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        saveRequest(app, name: "r", url: "https://one")

        XCTAssertFalse(
            app.overwriteSavedRequest(id: UUID(), with: app.draft),
            "找不到节点必须返回 false，beginSave 才能退回弹窗"
        )
    }

    // MARK: - 保存弹窗的目标项目

    func testSaveSheetDefaultsToActiveProject() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = app.newProject(name: "B")
        app.draft = APIRequest(name: "r", url: "https://one")

        app.beginSave()

        XCTAssertTrue(app.showSaveSheet)
        XCTAssertEqual(app.saveSheetProjectID, app.workspace.activeProjectID)
        XCTAssertEqual(app.saveSheetProjectID, app.activeProject?.id)
    }

    func testSaveSheetSavesIntoSelectedProjectAndActivatesIt() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaultProjectID = app.activeProject!.id
        let bID = app.newProject(name: "B")
        app.selectProject(id: defaultProjectID)

        app.draft = APIRequest(name: "r", url: "https://one")
        app.beginSave()
        app.saveSheetProjectID = bID
        app.saveSheetName = "r"
        app.commitSaveSheet()

        XCTAssertEqual(app.workspace.activeProjectID, bID, "存到别的项目后必须切过去，否则侧栏看不见")
        XCTAssertEqual(app.activeProject!.children.count, 1)
        XCTAssertEqual(app.projects.first { $0.id == defaultProjectID }!.children.count, 0)
        XCTAssertEqual(app.editingNodeID, app.activeProject!.children.first?.id)
    }

    func testSaveSheetFolderListFollowsSelectedProject() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        app.newFolder(name: "A 的文件夹", inFolder: nil)
        let aProjectID = app.activeProject!.id
        let bID = app.newProject(name: "B")
        app.newFolder(name: "B 的文件夹", inFolder: nil)
        app.selectProject(id: aProjectID)

        app.beginSave()
        XCTAssertEqual(app.saveSheetFolderOptions.map(\.path), ["A 的文件夹"])

        app.saveSheetProjectID = bID
        XCTAssertEqual(app.saveSheetFolderOptions.map(\.path), ["B 的文件夹"])
        XCTAssertNil(app.saveSheetFolderID, "旧项目的文件夹在新项目里不存在，目标必须清空")
    }

    func testSaveSheetClearsFolderWhenSwitchingToProjectWithoutIt() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        app.newFolder(name: "A 的文件夹", inFolder: nil)
        let folderID = app.activeProject!.children.first!.id
        let aProjectID = app.activeProject!.id
        let bID = app.newProject(name: "B")
        app.selectProject(id: aProjectID)

        app.beginSave()
        app.saveSheetFolderID = folderID
        app.saveSheetProjectID = bID

        XCTAssertNil(app.saveSheetFolderID)
    }
}
