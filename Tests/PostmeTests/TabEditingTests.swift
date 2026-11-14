import XCTest
@testable import Postme

/// 多页签编辑：每格各自持有草稿，打开别的请求不再覆盖当前内容。
///
/// 背景（实测缺陷）：单草稿模型下 `openSavedRequest` 无条件 `draft = saved.request`，
/// 全项目没有任何脏检查，用户敲了一半再点侧栏内容直接消失。当时的补丁是弹
/// 「保存 / 放弃 / 取消」三选一——用户被迫在两个请求之间做取舍。多页签把这个问题
/// 从根上去掉：旧草稿留在自己那格里，于是这里守的规则变成「谁都不许丢」。
@MainActor
final class TabEditingTests: XCTestCase {

    private func makeApp() -> (AppState, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("postme-tabs-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = AppState(persistence: PersistenceService(fileName: "workspace.json", directory: dir), languageOverride: .zhHans)
        return (app, dir)
    }

    private func makeService(_ dir: URL) -> PersistenceService {
        PersistenceService(fileName: "workspace.json", directory: dir)
    }

    /// 在当前页签里存一条请求，返回它的节点 id。
    private func saveRequest(_ app: AppState, name: String, url: String) -> UUID {
        app.draft = APIRequest(name: name, url: url)
        app.saveAsNewRequest(name: name, intoFolder: nil)
        return app.editingNodeID!
    }

    private func node(_ app: AppState, id: UUID) -> CollectionNode {
        app.activeProject!.children.findNode(id: id)!
    }

    // MARK: - 不变量

    func testFreshAppHasExactlyOneEmptyTab() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(app.tabs.count, 1)
        XCTAssertEqual(app.activeTab.id, app.tabs[0].id)
        XCTAssertFalse(app.isDraftDirty)
    }

    func testNewRequestOpensAdditionalTabInsteadOfReplacing() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = saveRequest(app, name: "one", url: "https://one")
        app.draft.url = "https://edited"

        app.newRequest()

        XCTAssertEqual(app.tabs.count, 2, "新建请求必须是多开一格，不是覆盖当前内容")
        XCTAssertEqual(app.tabs[0].nodeID, first, "旧页签的归属不受影响")
        XCTAssertEqual(app.tabs[0].draft.url, "https://edited", "旧页签的内容必须原样留着")
        XCTAssertEqual(app.draft.url, "", "新页签应当是空的")
        XCTAssertFalse(app.isDraftDirty, "刚开的新页签不算未保存")
    }

    // MARK: - 各自独立

    func testSwitchingTabsKeepsEachDraft() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let firstID = saveRequest(app, name: "one", url: "https://one")
        let firstTab = app.activeTabID

        app.newRequest()
        app.draft.url = "https://unsaved-in-second"

        app.activateTab(id: firstTab)

        XCTAssertEqual(app.draft.url, "https://one", "切回来应看到第一格自己的内容")
        XCTAssertFalse(app.isDraftDirty, "第一格没改过，不该被判成脏")
        _ = firstID

        app.activateTab(id: app.tabs[1].id)
        XCTAssertEqual(app.draft.url, "https://unsaved-in-second")
        XCTAssertTrue(app.isDraftDirty, "第二格的未保存改动仍在")
    }

    func testDirtyStateIsPerTab() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        app.draft.url = "https://dirty"
        XCTAssertTrue(app.isDraftDirty)

        app.newRequest()
        XCTAssertFalse(app.isDraftDirty, "新页签是干净的，不能被别格的脏状态污染")
        XCTAssertTrue(app.tabs[0].isDirty, "脏标记必须留在改过的那一格上")
    }

    func testOpeningSameRequestTwiceReusesTab() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = saveRequest(app, name: "one", url: "https://one")
        app.newRequest()

        app.openSavedRequest(node(app, id: id))
        app.openSavedRequest(node(app, id: id))

        XCTAssertEqual(app.tabs.count, 2, "同一个请求不该开成两格")
        XCTAssertEqual(app.editingNodeID, id)
    }

    func testOpenSavedRequestAddsTabInsteadOfPrompting() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = saveRequest(app, name: "one", url: "https://one")
        app.newRequest()
        app.draft.url = "https://unsaved"

        app.openSavedRequest(node(app, id: id))

        XCTAssertEqual(app.tabs.count, 2)
        XCTAssertEqual(app.draft.url, "https://one")
        XCTAssertEqual(app.tabs[1].draft.url, "https://unsaved", "未保存的草稿原地留着，不弹窗也不丢")
    }

    // MARK: - 克隆

    func testCloneTabCopiesDraftIntoAdjacentUnboundTab() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceID = saveRequest(app, name: "one", url: "https://one")
        let sourceTabID = app.activeTabID
        app.draft.url = "https://edited"

        let cloneID = app.cloneTab(id: sourceTabID)

        XCTAssertEqual(app.tabs.count, 2)
        XCTAssertEqual(app.tabs[1].id, cloneID, "副本紧挨在原件右侧")
        XCTAssertEqual(app.activeTabID, cloneID, "克隆后停在副本上")
        XCTAssertEqual(app.draft.url, "https://edited", "连未保存的改动一起复制")
        XCTAssertNil(app.editingNodeID, "副本不归属已保存请求，保存时才新建")
        XCTAssertFalse(app.isDraftDirty, "刚克隆出来的页签不算未保存修改")
        XCTAssertEqual(app.tabs[0].nodeID, sourceID, "原件归属不变")
    }

    func testSavingCloneCreatesNewRequestAndLeavesSourceIntact() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceID = saveRequest(app, name: "one", url: "https://one")
        app.draft.url = "https://edited"

        app.cloneTab(id: app.activeTabID)
        app.saveAsNewRequest(name: "copy", intoFolder: nil)

        XCTAssertEqual(node(app, id: sourceID).savedRequest?.request.url, "https://one", "克隆保存不许覆盖原件")
        XCTAssertNotNil(app.editingNodeID)
        XCTAssertNotEqual(app.editingNodeID, sourceID)
    }

    // MARK: - 关闭

    func testClosingCleanTabIsImmediate() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        saveRequest(app, name: "one", url: "https://one")
        app.newRequest()
        let secondID = app.activeTabID

        app.requestCloseTab(id: secondID)

        XCTAssertFalse(app.showTabCloseConfirm, "干净的页签不该弹确认")
        XCTAssertEqual(app.tabs.count, 1)
    }

    func testClosingDirtyTabAsksAndKeepsTab() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        app.draft.url = "https://dirty"
        let id = app.activeTabID

        app.requestCloseTab(id: id)

        XCTAssertTrue(app.showTabCloseConfirm)
        XCTAssertEqual(app.pendingCloseTabID, id)
        XCTAssertEqual(app.tabs.count, 1, "还没确认，页签必须还在")
    }

    func testCancelTabCloseKeepsEverything() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        app.draft.url = "https://dirty"

        app.requestCloseTab(id: app.activeTabID)
        app.cancelTabClose()

        XCTAssertFalse(app.showTabCloseConfirm)
        XCTAssertNil(app.pendingCloseTabID)
        XCTAssertEqual(app.tabs.count, 1)
        XCTAssertEqual(app.draft.url, "https://dirty")
    }

    func testDiscardCloseDropsEdits() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        app.draft.url = "https://dirty"

        app.requestCloseTab(id: app.activeTabID)
        app.discardAndClosePendingTab()

        XCTAssertEqual(app.tabs.count, 1)
        XCTAssertEqual(app.draft.url, "", "关掉最后一格会补一个空页签")
        XCTAssertFalse(app.isDraftDirty)
    }

    func testDismissingDialogDoesNotForgetPendingTarget() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        app.draft.url = "https://dirty"
        let id = app.activeTabID

        app.requestCloseTab(id: id)
        // 弹窗收起（Esc / 点弹窗外）只该收弹窗：按钮动作先于收起发生，
        // 若在这里顺手清掉目标，「保存并关闭」保存完就找不到要关的那一格了。
        app.tabCloseDialogDismissed()
        XCTAssertFalse(app.showTabCloseConfirm)
        XCTAssertEqual(app.pendingCloseTabID, id)
    }

    func testSaveAndCloseBoundTabOverwritesThenCloses() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let firstID = saveRequest(app, name: "one", url: "https://one")
        app.newRequest()
        let secondID = saveRequest(app, name: "two", url: "https://two")
        app.draft.url = "https://two-edited"

        app.requestCloseTab(id: app.activeTabID)
        app.saveAndClosePendingTab()

        XCTAssertEqual(app.tabs.count, 1, "已归属的页签应直接覆盖保存并关掉，不必再命名")
        XCTAssertFalse(app.showSaveSheet)
        XCTAssertEqual(node(app, id: secondID).savedRequest?.request.url, "https://two-edited")
        XCTAssertEqual(node(app, id: firstID).savedRequest?.request.url, "https://one", "别格的请求不许被改")
    }

    func testSaveAndCloseUnboundTabGoesThroughSaveSheet() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        app.newRequest()
        let dirtyTabID = app.activeTabID
        app.draft.url = "https://new-one"

        app.requestCloseTab(id: dirtyTabID)
        app.saveAndClosePendingTab()

        XCTAssertTrue(app.showSaveSheet, "没归属就得先命名")
        app.saveSheetName = "留一份"
        app.commitSaveSheet()

        XCTAssertEqual(app.tabs.count, 1, "保存完必须真的关掉那一格")
        XCTAssertEqual(app.activeProject!.children.count, 1)
        XCTAssertEqual(app.activeProject!.children.first?.savedRequest?.request.url, "https://new-one")
    }

    func testCancellingSaveSheetLeavesTabOpen() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        app.newRequest()
        let tabID = app.activeTabID
        app.draft.url = "https://new-one"

        app.requestCloseTab(id: tabID)
        app.saveAndClosePendingTab()
        app.cancelSaveSheet()

        XCTAssertEqual(app.tabs.count, 2, "取消命名不该顺手把页签关掉")
        XCTAssertNil(app.pendingCloseTabID)
    }

    func testClosingLastTabLeavesOneEmptyTab() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        app.closeTab(id: app.activeTabID)

        XCTAssertEqual(app.tabs.count, 1, "编辑器恒有一格，否则没有可写对象")
        XCTAssertEqual(app.activeTab.id, app.tabs[0].id)
    }

    func testClosingActiveTabActivatesRightNeighbour() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        app.newRequest()
        let middle = app.activeTabID
        app.newRequest()
        let last = app.activeTabID
        app.activateTab(id: middle)

        app.closeTab(id: middle)

        XCTAssertEqual(app.activeTabID, last, "关掉当前格后接管右邻，像浏览器那样停在原地附近")
    }

    func testClosingLastActiveTabFallsBackToLeftNeighbour() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = app.activeTabID
        app.newRequest()
        let last = app.activeTabID

        app.closeTab(id: last)

        XCTAssertEqual(app.activeTabID, first, "没有右邻就接管左邻")
    }

    // MARK: - 保存目标

    func testSaveOverwritesActiveTabBindingOnly() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let firstID = saveRequest(app, name: "one", url: "https://one")
        let firstTab = app.activeTabID

        app.newRequest()
        let secondID = saveRequest(app, name: "two", url: "https://two")

        // 回到第一格改内容再保存：只能改到第一条请求。
        app.activateTab(id: firstTab)
        app.draft.url = "https://one-edited"
        app.beginSave()

        XCTAssertFalse(app.showSaveSheet)
        XCTAssertEqual(node(app, id: firstID).savedRequest?.request.url, "https://one-edited")
        XCTAssertEqual(node(app, id: secondID).savedRequest?.request.url, "https://two", "别格的请求不许被改")
        XCTAssertEqual(app.activeProject!.children.count, 2)
    }

    func testReopeningBoundRequestReusesTabAndKeepsDirtyMarker() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = saveRequest(app, name: "one", url: "https://one")

        app.draft.url = "https://edited"
        XCTAssertTrue(app.isDraftDirty)

        // 再点一次同一条请求：复用已有页签，未保存的修改不能被丢掉。
        app.openSavedRequest(node(app, id: id))

        XCTAssertEqual(app.tabs.count, 1, "一个请求至多占一格")
        XCTAssertEqual(app.draft.url, "https://edited")
        XCTAssertTrue(app.isDraftDirty)
    }

    func testSaveAsNewRequestBindsTheTabThatStartedIt() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        app.draft.url = "https://first"
        app.beginSave()
        let savingTab = app.activeTabID

        // 弹窗还开着时用户切到别格：保存必须落到发起保存的那一格上。
        app.newRequest()
        app.saveSheetName = "first"
        app.commitSaveSheet()

        let index = app.tabs.firstIndex { $0.id == savingTab }!
        XCTAssertEqual(app.tabs[index].nodeID, app.activeProject!.children.first?.id)
        XCTAssertFalse(app.tabs[index].isDirty)
        XCTAssertNil(app.tabs[1].nodeID, "后来打开的那格不该被误绑")
    }

    // MARK: - 与目录操作的一致性

    func testDeleteNodeUnbindsTabs() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = saveRequest(app, name: "one", url: "https://one")

        app.deleteNode(id: id)

        XCTAssertNil(app.editingNodeID, "节点没了，归属必须清掉，否则 ⌘S 静默无效")
        app.beginSave()
        XCTAssertTrue(app.showSaveSheet, "降级成新请求：⌘S 应该弹窗而不是静默不动")
    }

    func testDeleteFolderUnbindsTabsInsideIt() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        app.newFolder(name: "f", inFolder: nil)
        let folderID = app.activeProject!.children.first!.id

        app.newRequest()
        app.draft = APIRequest(name: "inside", url: "https://inside")
        app.saveAsNewRequest(name: "inside", intoFolder: folderID)
        let insideID = app.editingNodeID!

        app.deleteNode(id: folderID)

        XCTAssertNil(app.editingNodeID, "所在文件夹被删，归属必须清掉")
        XCTAssertNil(app.activeProject!.children.findNode(id: insideID))
        XCTAssertEqual(app.draft.url, "https://inside", "页签里的内容留着，可另存一份")
    }

    func testRenameNodeUpdatesTabDraftName() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = saveRequest(app, name: "one", url: "https://one")

        app.renameNode(id: id, to: "改名后")

        XCTAssertEqual(app.draft.name, "改名后", "页签里还是旧名字的话，下次保存会把旧名字写回去")
        XCTAssertFalse(app.isDraftDirty, "改名是已落盘的改动，不该留下「未保存」标记")
    }

    func testTabTitleFallsBackToURLThenPlaceholder() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        app.draft = APIRequest(name: "未命名请求", url: "https://api.demo.com/users/42")
        XCTAssertEqual(app.tabTitle(app.activeTab), "42", "占位名要退回 URL 末段")

        app.draft.url = "https://"
        XCTAssertEqual(app.tabTitle(app.activeTab), "未命名请求")
    }

    // MARK: - 发送结果落到发起的那一格

    func testResponseLandsOnTheTabThatSentIt() async throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try LocalHTTPServer(routes: [
            "/slow": .delayed(seconds: 0.8, body: Data("slow-body".utf8)),
            "/fast": .fixed(Data("fast-body".utf8), contentType: "text/plain")
        ])
        defer { server.stop() }

        let slowTab = app.activeTabID
        app.draft = APIRequest(name: "slow", url: server.url("/slow"))
        let slowSend = Task { await app.send() }
        // 等慢请求真正发出去：`send()` 读的是「执行时的当前页签」，
        // 立刻切页签的话它会把请求发到新格上，测的就不是隔离性了。
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(app.tabs[0].isSending)

        app.newRequest()
        let fastTab = app.activeTabID
        app.draft = APIRequest(name: "fast", url: server.url("/fast"))
        await app.send()

        // 第二格已经拿到响应；此时切回第一格，看到的必须是「正在发送」而不是别的请求的结果。
        XCTAssertEqual(app.tabs.first { $0.id == fastTab }?.responseBodyText, "fast-body")
        let slowIndex = app.tabs.firstIndex { $0.id == slowTab }!
        XCTAssertTrue(app.tabs[slowIndex].isSending, "慢请求还在飞，与快的那格互不影响")

        await slowSend.value

        XCTAssertEqual(app.tabs[slowIndex].responseBodyText, "slow-body", "结果必须回写到发起它的那一格")
        XCTAssertFalse(app.tabs[slowIndex].isSending)
        XCTAssertEqual(app.tabs.first { $0.id == fastTab }?.responseBodyText, "fast-body", "先完成的响应不能被后到的覆盖")
    }

    func testCancelSendsOnlyToTheActiveTab() async throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try LocalHTTPServer(routes: [
            "/slow": .delayed(seconds: 30, body: Data("late".utf8))
        ])
        defer { server.stop() }

        let firstTab = app.activeTabID
        app.draft = APIRequest(name: "slow-1", url: server.url("/slow"))
        let firstSend = Task { await app.send() }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(app.tabs[0].isSending)

        app.newRequest()
        app.draft = APIRequest(name: "slow-2", url: server.url("/slow"))
        let secondSend = Task { await app.send() }
        try await Task.sleep(nanoseconds: 500_000_000)

        // 眼前是第二格：取消只能打断它，第一格的在飞请求不受影响。
        app.cancelSend()
        await secondSend.value

        XCTAssertFalse(app.isSending, "取消后当前页签回到空闲")
        XCTAssertNil(app.errorMessage, "取消不是失败，不该报错")
        XCTAssertNil(app.response)
        XCTAssertTrue(app.tabs[0].isSending, "只取消当前格：别的页签还在飞")
        _ = firstTab

        // 收尾：把第一格也取消掉，避免测试结束时还挂着连接。
        app.activateTab(id: app.tabs[0].id)
        app.cancelSend()
        await firstSend.value
    }

    // MARK: - 持久化

    func testTabsSurviveRelaunch() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("postme-tabs-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = AppState(persistence: makeService(dir), languageOverride: .zhHans)
        let id = saveRequest(first, name: "one", url: "https://one")
        first.newRequest()
        first.draft.url = "https://unsaved-second"
        let secondTab = first.activeTabID
        first.saveImmediately()

        let relaunched = AppState(persistence: makeService(dir), languageOverride: .zhHans)
        XCTAssertEqual(relaunched.tabs.count, 2)
        XCTAssertEqual(relaunched.activeTabID, secondTab)
        XCTAssertEqual(relaunched.draft.url, "https://unsaved-second", "未保存的草稿也要恢复")
        XCTAssertTrue(relaunched.isDraftDirty, "恢复后仍是未保存状态")
        XCTAssertEqual(relaunched.tabs[0].nodeID, id, "归属必须和草稿一起恢复，否则重启后 ⌘S 会复制一份")
    }

    func testRelaunchDropsBindingForVanishedNode() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("postme-tabs-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let project = Project(name: "P")
        makeService(dir).saveNow(Workspace(
            projects: [project],
            activeProjectID: project.id,
            tabs: [EditorTab(draft: APIRequest(name: "r", url: "https://one"), nodeID: UUID())]
        ))

        let app = AppState(persistence: makeService(dir), languageOverride: .zhHans)
        XCTAssertNil(app.editingNodeID, "悬空归属必须丢弃，否则 ⌘S 静默无效")
        app.beginSave()
        XCTAssertTrue(app.showSaveSheet)
    }

    func testLegacySingleDraftMigratesToOneTab() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("postme-tabs-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // v3 文件：没有 tabs，只有 draft + draftNodeID。
        let project = Project(name: "P")
        let request = APIRequest(name: "旧草稿", url: "https://legacy")
        let nodeID = UUID()
        let json = """
        {"version":3,"projects":[{"id":"\(project.id.uuidString)","name":"P","children":[]}],
         "activeProjectID":"\(project.id.uuidString)",
         "draft":{"name":"旧草稿","method":"GET","url":"https://legacy","headers":[],"queryParams":[],"formFields":[],"bodyKind":"none","bodyText":"","rawContentType":"text/plain"},
         "draftNodeID":"\(nodeID.uuidString)"}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("workspace.json"))

        let app = AppState(persistence: makeService(dir), languageOverride: .zhHans)
        XCTAssertEqual(app.tabs.count, 1)
        XCTAssertEqual(app.draft.name, "旧草稿")
        XCTAssertNil(app.editingNodeID, "归属指向的节点不存在，迁移后必须丢弃")
        _ = request
    }

    func testRelaunchFallsBackToFirstTabWhenActiveTabIDDangling() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("postme-tabs-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let project = Project(name: "P")
        let tab = EditorTab(draft: APIRequest(name: "r", url: "https://one"))
        makeService(dir).saveNow(Workspace(
            projects: [project],
            activeProjectID: project.id,
            tabs: [tab],
            activeTabID: UUID()
        ))

        let app = AppState(persistence: makeService(dir), languageOverride: .zhHans)
        XCTAssertEqual(app.activeTabID, tab.id, "悬空的当前页签要兜底到第一格，而不是让编辑器没内容")
    }
}
