import XCTest
@testable import Postme

/// 编辑器草稿的脏检查与切换保护。
///
/// 背景（实测缺陷）：`openSavedRequest` 无条件 `draft = saved.request`，
/// 全项目没有任何 dirty 标记——用户敲了一半再点侧栏，内容直接消失且无提示。
@MainActor
final class DraftProtectionTests: XCTestCase {

    /// 用独立目录构造 AppState，避免碰到真实 workspace.json。
    private func makeApp() -> (AppState, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("postme-draft-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = AppState(persistence: PersistenceService(fileName: "workspace.json", directory: dir))
        return (app, dir)
    }

    private func saveRequest(_ app: AppState, name: String, url: String) -> UUID {
        app.draft = APIRequest(name: name, url: url)
        app.saveAsNewRequest(name: name, intoFolder: nil)
        return app.editingNodeID!
    }

    // MARK: - 脏判定

    func testFreshDraftIsClean() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(app.isDraftDirty)
    }

    func testEditingMarksDraftDirty() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        app.draft.url = "https://edited"
        XCTAssertTrue(app.isDraftDirty)
    }

    func testSavingClearsDirty() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        app.draft.url = "https://x"
        app.saveAsNewRequest(name: "r", intoFolder: nil)
        XCTAssertFalse(app.isDraftDirty, "保存后不应再算未保存修改")
    }

    func testOverwriteClearsDirty() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = saveRequest(app, name: "r", url: "https://a")
        app.draft.url = "https://b"
        XCTAssertTrue(app.isDraftDirty)

        app.overwriteSavedRequest(id: id, with: app.draft)
        XCTAssertFalse(app.isDraftDirty)
    }

    // MARK: - 切换保护

    func testSwitchingWithCleanDraftDoesNotPrompt() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = saveRequest(app, name: "one", url: "https://one")
        app.draft = APIRequest()
        app.saveAsNewRequest(name: "two", intoFolder: nil)
        XCTAssertFalse(app.isDraftDirty)

        let two = app.editingNodeID!
        let one = app.collections.first!.id
        app.openSavedRequest(app.collections.first { $0.id == one }!)
        XCTAssertFalse(app.showDraftConflict)
        XCTAssertEqual(app.editingNodeID, one)
        _ = two
    }

    func testSwitchingWithDirtyDraftPromptsAndKeepsDraft() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let firstID = saveRequest(app, name: "one", url: "https://one")
        app.draft = APIRequest()
        app.saveAsNewRequest(name: "two", intoFolder: nil)
        let secondID = app.editingNodeID!

        // 在第二个请求上编辑但不保存
        app.draft.url = "https://unsaved-work"
        XCTAssertTrue(app.isDraftDirty)

        // 点第一个请求 → 必须弹提示，且草稿不被替换
        app.openSavedRequest(app.collections.first { $0.id == firstID }!)
        XCTAssertTrue(app.showDraftConflict)
        XCTAssertEqual(app.draft.url, "https://unsaved-work", "弹提示期间草稿必须原样保留")
        XCTAssertEqual(app.editingNodeID, secondID, "还没确认，不应切换归属")
    }

    func testCancelConflictKeepsEverything() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let firstID = saveRequest(app, name: "one", url: "https://one")
        app.draft = APIRequest()
        app.saveAsNewRequest(name: "two", intoFolder: nil)

        app.draft.url = "https://unsaved-work"
        app.openSavedRequest(app.collections.first { $0.id == firstID }!)
        app.cancelDraftConflict()

        XCTAssertFalse(app.showDraftConflict)
        XCTAssertEqual(app.draft.url, "https://unsaved-work")
        XCTAssertNotEqual(app.editingNodeID, firstID)
    }

    func testDiscardConflictSwitchesAndDropsEdits() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let firstID = saveRequest(app, name: "one", url: "https://one")
        app.draft = APIRequest()
        app.saveAsNewRequest(name: "two", intoFolder: nil)

        app.draft.url = "https://unsaved-work"
        app.openSavedRequest(app.collections.first { $0.id == firstID }!)
        app.discardDraftAndContinue()

        XCTAssertFalse(app.showDraftConflict)
        XCTAssertEqual(app.editingNodeID, firstID)
        XCTAssertEqual(app.draft.url, "https://one", "放弃修改后应载入目标请求")
        XCTAssertFalse(app.isDraftDirty)
    }

    func testSaveAndContinuePersistsEditsToOwningNode() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let firstID = saveRequest(app, name: "one", url: "https://one")
        app.draft = APIRequest()
        app.saveAsNewRequest(name: "two", intoFolder: nil)
        let secondID = app.editingNodeID!

        app.draft.url = "https://saved-work"
        app.openSavedRequest(app.collections.first { $0.id == firstID }!)
        app.saveDraftAndContinue()

        // 修改应落到原来的节点上
        let secondNode = app.collections.first { $0.id == secondID }
        XCTAssertEqual(secondNode?.savedRequest?.request.url, "https://saved-work")
        // 然后才切到目标
        XCTAssertEqual(app.editingNodeID, firstID)
        XCTAssertEqual(app.draft.url, "https://one")
        XCTAssertFalse(app.showDraftConflict)
    }

    func testSaveAndContinueOnUnsavedDraftDefersToSaveSheet() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let firstID = saveRequest(app, name: "one", url: "https://one")

        // 全新未保存的草稿
        app.newRequest()
        app.draft.url = "https://brand-new"
        XCTAssertNil(app.editingNodeID)

        app.openSavedRequest(app.collections.first { $0.id == firstID }!)
        app.saveDraftAndContinue()

        // 没有归属节点 → 必须先命名保存
        XCTAssertTrue(app.showSaveSheet)
        XCTAssertNil(app.editingNodeID, "保存完成前不应切换到目标请求")

        app.saveSheetName = "新请求"
        app.commitSaveSheet()

        // 保存后再切到目标请求
        XCTAssertFalse(app.showSaveSheet)
        XCTAssertEqual(app.editingNodeID, firstID)
        XCTAssertEqual(app.collections.filter { $0.name == "新请求" }.count, 1)
    }

    func testCancelSaveSheetAbortsPendingSwitch() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let firstID = saveRequest(app, name: "one", url: "https://one")
        app.newRequest()
        app.draft.url = "https://brand-new"

        app.openSavedRequest(app.collections.first { $0.id == firstID }!)
        app.saveDraftAndContinue()
        app.cancelSaveSheet()

        // 用户放弃了整个动作：草稿留在编辑器里，没切走也没保存
        XCTAssertEqual(app.draft.url, "https://brand-new")
        XCTAssertFalse(app.showSaveSheet)
        XCTAssertTrue(app.collections.allSatisfy { $0.name != "新请求" })
    }

    // MARK: - 新建与历史恢复也受保护

    func testNewRequestPromptsWhenDirty() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        saveRequest(app, name: "one", url: "https://one")
        app.draft.url = "https://unsaved"

        app.newRequest()
        XCTAssertTrue(app.showDraftConflict)
        XCTAssertEqual(app.draft.url, "https://unsaved")

        app.discardDraftAndContinue()
        XCTAssertEqual(app.draft.url, "", "放弃后应是全新空请求")
        XCTAssertNil(app.editingNodeID)
    }

    func testRestoreFromHistoryPromptsWhenDirty() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        app.draft.url = "https://unsaved"
        let entry = HistoryEntry(
            request: APIRequest(name: "h", url: "https://history"),
            statusCode: 200, duration: 0.1, succeeded: true
        )
        app.restoreFromHistory(entry)
        XCTAssertTrue(app.showDraftConflict)
        XCTAssertEqual(app.draft.url, "https://unsaved")

        app.discardDraftAndContinue()
        XCTAssertEqual(app.draft.url, "https://history")
    }

    // MARK: - B1 回归：回滚选中项触发的二次 onChange 不得覆盖挂起动作
    //
    // 交付审查第 1 轮（REJECT）指出：`deferAction` 回滚 `selectedNodeID` 会再触发一次
    // 侧栏 onChange → `openSavedRequest` → 再次 deferAction，把用户真正点击的目标
    // 覆盖成"回滚后的节点"，导致「保存并继续 / 放弃修改」后停在原地。
    // 原先的测试直调 `openSavedRequest`，绕过了这个真实入口，因此完全漏检。
    //
    // 下面用 `handleSidebarSelection` 模拟真实链路：先点目标节点，再模拟回滚引发的第二次触发。

    /// 模拟侧栏：设置选中项会像 SwiftUI 那样回调一次 onChange。
    private func simulateSelection(_ app: AppState, _ id: UUID?) {
        app.selectedNodeID = id
        app.handleSidebarSelection(id)
    }

    func testB1_secondOnChangeDoesNotOverwritePendingTarget() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let firstID = saveRequest(app, name: "one", url: "https://one")
        app.draft = APIRequest()
        app.saveAsNewRequest(name: "two", intoFolder: nil)

        // 在第二个请求上编辑但不保存
        app.draft.url = "https://unsaved-work"

        // 用户点击第一个请求（真实入口）
        simulateSelection(app, firstID)
        XCTAssertTrue(app.showDraftConflict)

        // deferAction 回滚了选中项 → SwiftUI 会再触发一次 onChange
        simulateSelection(app, app.selectedNodeID)

        // 关键：挂起的目标必须仍是用户点的那个
        XCTAssertEqual(app.pendingDraftAction, .openNode(firstID))

        app.saveDraftAndContinue()
        XCTAssertEqual(app.editingNodeID, firstID, "保存并继续后必须到达用户点击的节点")
        XCTAssertEqual(app.draft.url, "https://one")
    }

    func testB1_discardAlsoReachesClickedTarget() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let firstID = saveRequest(app, name: "one", url: "https://one")
        app.draft = APIRequest()
        app.saveAsNewRequest(name: "two", intoFolder: nil)
        app.draft.url = "https://unsaved-work"

        simulateSelection(app, firstID)
        simulateSelection(app, app.selectedNodeID)   // 回滚引发的第二次触发
        app.discardDraftAndContinue()

        XCTAssertEqual(app.editingNodeID, firstID)
        XCTAssertEqual(app.draft.url, "https://one")
    }

    func testB1_cancelAlsoReachesClickedTarget() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let firstID = saveRequest(app, name: "one", url: "https://one")
        app.draft = APIRequest()
        app.saveAsNewRequest(name: "two", intoFolder: nil)
        let secondID = app.editingNodeID!
        app.draft.url = "https://unsaved-work"

        simulateSelection(app, firstID)
        simulateSelection(app, app.selectedNodeID)
        app.cancelDraftConflict()

        // 取消后保持原草稿与归属
        XCTAssertEqual(app.draft.url, "https://unsaved-work")
        XCTAssertEqual(app.editingNodeID, secondID)
        XCTAssertEqual(app.selectedNodeID, secondID, "选中项应回滚到当前编辑节点，不能停在目标节点")
    }

    func testB1_repeatedSelectionChurnKeepsOriginalTarget() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let firstID = saveRequest(app, name: "one", url: "https://one")
        app.draft = APIRequest()
        app.saveAsNewRequest(name: "two", intoFolder: nil)
        app.draft.url = "https://unsaved-work"

        simulateSelection(app, firstID)
        // 模拟多次回滚抖动
        for _ in 0..<5 { simulateSelection(app, app.selectedNodeID) }

        XCTAssertEqual(app.pendingDraftAction, .openNode(firstID))
        app.discardDraftAndContinue()
        XCTAssertEqual(app.editingNodeID, firstID)
    }

    func testB1_newRequestPathNotOverwrittenByRollback() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        saveRequest(app, name: "one", url: "https://one")
        app.draft.url = "https://unsaved-work"

        app.newRequest()
        XCTAssertEqual(app.pendingDraftAction, .newRequest(folderID: nil))

        // 回滚选中项引发的二次触发
        simulateSelection(app, app.selectedNodeID)
        XCTAssertEqual(app.pendingDraftAction, .newRequest(folderID: nil))

        app.discardDraftAndContinue()
        XCTAssertNil(app.editingNodeID, "应真的新建了请求")
        XCTAssertEqual(app.draft.url, "")
    }

    func testB1_historyRestorePathNotOverwrittenByRollback() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        saveRequest(app, name: "one", url: "https://one")
        app.draft.url = "https://unsaved-work"

        let entry = HistoryEntry(
            request: APIRequest(name: "h", url: "https://history"),
            statusCode: 200, duration: 0.1, succeeded: true
        )
        app.restoreFromHistory(entry)
        XCTAssertEqual(app.pendingDraftAction, .restoreHistory(entry))

        simulateSelection(app, app.selectedNodeID)
        XCTAssertEqual(app.pendingDraftAction, .restoreHistory(entry))

        app.discardDraftAndContinue()
        XCTAssertEqual(app.draft.url, "https://history")
    }

    func testB1_folderSelectionIsIgnoredByHandler() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        app.newFolder(name: "组", inFolder: nil)
        let folderID = app.collections.first!.id
        simulateSelection(app, folderID)
        // 文件夹不是请求，不应触发任何草稿逻辑
        XCTAssertFalse(app.showDraftConflict)
        XCTAssertNil(app.pendingDraftAction)
    }

    func testB1_cleanDraftSelectionSwitchesDirectly() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let firstID = saveRequest(app, name: "one", url: "https://one")
        app.draft = APIRequest()
        app.saveAsNewRequest(name: "two", intoFolder: nil)

        // 草稿干净：直接切换，不弹提示
        simulateSelection(app, firstID)
        XCTAssertFalse(app.showDraftConflict)
        XCTAssertEqual(app.editingNodeID, firstID)
        XCTAssertEqual(app.draft.url, "https://one")
    }

    // MARK: - 草稿落盘

    func testDraftIsPersistedOnEdit() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("postme-draft-persist-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let service = PersistenceService(fileName: "workspace.json", directory: dir)
        let app = AppState(persistence: service)

        app.draft.url = "https://persisted"
        app.persistDraft()
        app.saveImmediately()

        // 新实例从同一目录读回
        let reloaded = AppState(persistence: PersistenceService(fileName: "workspace.json", directory: dir))
        XCTAssertEqual(reloaded.draft.url, "https://persisted")
        XCTAssertFalse(reloaded.isDraftDirty, "恢复出来的草稿就是基线，不该一启动就显示未保存")
    }

    func testDeletedEditingNodeClearsSelection() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = saveRequest(app, name: "one", url: "https://one")
        app.deleteNode(id: id)
        XCTAssertNil(app.editingNodeID)
        XCTAssertNil(app.selectedNodeID)
    }
}
