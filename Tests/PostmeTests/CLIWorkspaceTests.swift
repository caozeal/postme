import XCTest
@testable import Postme

/// CLI 数据写路径：导入持久化、项目激活与页签归属安全。
final class CLIWorkspaceTests: XCTestCase {
    private func makeTempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("postme-cli-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testImportAndEnvironmentOperationsSurviveReload() throws {
        try MainActor.assumeIsolated {
            let dir = makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = CLIWorkspace(directory: dir)
            _ = try store.createProject(name: "Base")
            _ = try store.createEnvironment(name: "Dev")
            _ = try store.setVariable(environment: "Dev", key: "token", value: "one")
            _ = try store.setVariable(environment: "Dev", key: "token", value: "two")

            let postman = """
            {"info":{"name":"Imported","schema":"https://schema.getpostman.com/json/collection/v2.1.0/collection.json"},
             "item":[{"name":"Ping","request":{"method":"GET","url":"https://example.com/ping"}}]}
            """
            let imported = try store.importPostman(data: Data(postman.utf8))
            XCTAssertEqual(imported.requestCount, 1)

            let curl = try store.importCurl(
                text: "curl -X POST https://example.com/notes -H 'Content-Type: application/json' --data-raw '{\"ok\":true}'",
                project: "Imported", newProjectName: nil
            )
            XCTAssertEqual(curl.requestCount, 1)

            let reloaded = CLIWorkspace(directory: dir)
            XCTAssertEqual(reloaded.workspace.projects.count, 2)
            XCTAssertEqual(try reloaded.requests(project: "Imported").count, 2)
            XCTAssertEqual(reloaded.workspace.environments.first?.variableMap["token"], "two")
            XCTAssertEqual(try reloaded.requests(project: "Imported").last?.saved.request.bodyText, "{\"ok\":true}")
        }
    }

    func testProjectActivationDoesNotLoseDirtyTabOrBounceBackOnGUILaunch() throws {
        try MainActor.assumeIsolated {
            let dir = makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let saved = CollectionNode.SavedRequest(
                name: "Saved", request: APIRequest(name: "Saved", url: "https://example.com")
            )
            let projectA = Project(name: "A", children: [.request(saved)])
            let projectB = Project(name: "B")
            var dirty = saved.request
            dirty.url = "https://example.com/unsaved"
            let tab = EditorTab(draft: dirty, baseline: saved.request, nodeID: saved.id)
            var workspace = Workspace(projects: [projectA, projectB], activeProjectID: projectA.id)
            workspace.tabs = [tab]
            workspace.activeTabID = tab.id
            XCTAssertTrue(PersistenceService(directory: dir).saveNow(workspace))

            let store = CLIWorkspace(directory: dir)
            _ = try store.activateProject("B")
            XCTAssertEqual(store.workspace.activeProjectID, projectB.id)
            XCTAssertEqual(store.workspace.tabs.count, 2)
            XCTAssertTrue(store.workspace.tabs.contains { $0.id == tab.id && $0.draft.url == dirty.url })

            // 真正走 AppState 启动同步：activeTab 不再属于 A，不应把 activeProject 切回 A。
            let app = AppState(persistence: PersistenceService(directory: dir))
            XCTAssertEqual(app.activeProject?.id, projectB.id)
            XCTAssertTrue(app.tabs.contains { $0.id == tab.id && $0.draft.url == dirty.url })
        }
    }

    func testDeleteRequestDetachesTabsAndLastProjectIsProtected() throws {
        try MainActor.assumeIsolated {
            let dir = makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let saved = CollectionNode.SavedRequest(name: "Delete me", request: APIRequest(name: "Delete me"))
            let project = Project(name: "Only", children: [.request(saved)])
            let tab = EditorTab(draft: saved.request, baseline: saved.request, nodeID: saved.id)
            var workspace = Workspace(projects: [project], activeProjectID: project.id)
            workspace.tabs = [tab]
            workspace.activeTabID = tab.id
            XCTAssertTrue(PersistenceService(directory: dir).saveNow(workspace))

            let store = CLIWorkspace(directory: dir)
            _ = try store.deleteRequest(id: saved.id)
            XCTAssertNil(store.workspace.tabs[0].nodeID)
            XCTAssertThrowsError(try store.deleteProject("Only")) { error in
                XCTAssertEqual((error as? CLIError)?.message, "Cannot delete the last project.")
            }

            let reloaded = CLIWorkspace(directory: dir)
            XCTAssertEqual(reloaded.workspace.projects.count, 1)
            XCTAssertTrue(try reloaded.requests().isEmpty)
            XCTAssertNil(reloaded.workspace.tabs[0].nodeID)
        }
    }

    func testCreateAndUpdateRequestSurviveReloadAndKeepIDs() throws {
        try MainActor.assumeIsolated {
            let dir = makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = CLIWorkspace(directory: dir)
            _ = try store.createProject(name: "Base")

            let source = APIRequest(name: "Get user", url: "https://example.com/users")
            let created = try store.createRequest(name: "Get user", request: source, project: nil)
            XCTAssertEqual(created.saved.name, "Get user")
            XCTAssertNotEqual(created.saved.request.id, source.id, "复制式创建必须换新的请求 UUID")
            XCTAssertEqual(created.project.id, store.workspace.activeProjectID, "未指定项目时落在活动项目")

            var edited = created.saved.request
            edited.method = .post
            edited.url = "https://example.com/users/create"
            edited.bodyText = "{\"ok\":true}"
            let updated = try store.updateRequest(id: created.saved.id, name: "Create user", request: edited)

            XCTAssertEqual(updated.saved.id, created.saved.id, "节点 UUID 不变，页签归属不失效")
            XCTAssertEqual(updated.saved.request.id, created.saved.request.id, "请求 UUID 不变")
            XCTAssertEqual(updated.saved.name, "Create user")
            XCTAssertEqual(updated.saved.request.method, .post)
            XCTAssertEqual(updated.saved.request.url, "https://example.com/users/create")

            let reloaded = CLIWorkspace(directory: dir)
            let rows = try reloaded.requests()
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows[0].saved.name, "Create user")
            XCTAssertEqual(rows[0].saved.request.bodyText, "{\"ok\":true}")
        }
    }

    func testUpdateRequestWithoutNameKeepsNameAndTabBinding() throws {
        try MainActor.assumeIsolated {
            let dir = makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let saved = CollectionNode.SavedRequest(
                name: "Original", request: APIRequest(name: "Original", url: "https://example.com")
            )
            let project = Project(name: "Only", children: [.request(saved)])
            let tab = EditorTab(draft: saved.request, baseline: saved.request, nodeID: saved.id)
            var workspace = Workspace(projects: [project], activeProjectID: project.id)
            workspace.tabs = [tab]
            workspace.activeTabID = tab.id
            XCTAssertTrue(PersistenceService(directory: dir).saveNow(workspace))

            let store = CLIWorkspace(directory: dir)
            var edited = saved.request
            edited.url = "https://example.com/v2"
            _ = try store.updateRequest(id: saved.id, name: nil, request: edited)

            let reloaded = CLIWorkspace(directory: dir)
            XCTAssertEqual(try reloaded.requests().first?.saved.name, "Original", "没给名字就保留原名")
            XCTAssertEqual(reloaded.workspace.tabs.first?.nodeID, saved.id)
            XCTAssertEqual(try reloaded.requests().first?.saved.request.url, "https://example.com/v2")
        }
    }

    func testFolderCommandsAndNestedRequestPlacementSurviveReload() throws {
        try MainActor.assumeIsolated {
            let dir = makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = CLIWorkspace(directory: dir)
            _ = try store.createProject(name: "Base")

            let api = try store.createFolder(name: "API", project: nil, in: nil)
            let nested = try store.createFolder(name: "Users", project: nil, in: api.folder.id)
            XCTAssertEqual(nested.path, ["API", "Users"])

            let renamed = try store.renameFolder(id: nested.folder.id, to: "Accounts")
            XCTAssertEqual(renamed.path, ["API", "Accounts"])

            let request = try store.createRequest(
                name: "Get user",
                request: APIRequest(name: "Get user", url: "https://example.com/users"),
                project: nil,
                folder: .folder(nested.folder.id)
            )
            XCTAssertEqual(request.path, ["API", "Accounts"])
            XCTAssertEqual(try store.folders().first { $0.folder.id == nested.folder.id }?.requestCount, 1)

            let reloaded = CLIWorkspace(directory: dir)
            XCTAssertEqual(try reloaded.folders().count, 2)
            XCTAssertEqual(try reloaded.requests().first?.path, ["API", "Accounts"])

            _ = try reloaded.deleteFolder(id: api.folder.id)
            XCTAssertTrue(try reloaded.requests().isEmpty, "删父文件夹要连带删掉子树里的请求")
            XCTAssertTrue(try reloaded.folders().isEmpty)
        }
    }

    func testUpdateRequestMovesBetweenFoldersAndBackToRoot() throws {
        try MainActor.assumeIsolated {
            let dir = makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = CLIWorkspace(directory: dir)
            _ = try store.createProject(name: "Base")
            let a = try store.createFolder(name: "A", project: nil, in: nil)
            let b = try store.createFolder(name: "B", project: nil, in: nil)
            let created = try store.createRequest(
                name: "Ping", request: APIRequest(name: "Ping"), project: nil, folder: .folder(a.folder.id)
            )
            XCTAssertEqual(created.path, ["A"])

            let moved = try store.updateRequest(id: created.saved.id, name: nil,
                                                request: created.saved.request, folder: .folder(b.folder.id))
            XCTAssertEqual(moved.path, ["B"])
            XCTAssertEqual(moved.saved.id, created.saved.id, "移动不改节点 UUID")

            let rooted = try store.updateRequest(id: created.saved.id, name: nil,
                                                 request: created.saved.request, folder: .root)
            XCTAssertTrue(rooted.path.isEmpty)
            XCTAssertEqual(try store.folders().first { $0.folder.id == b.folder.id }?.requestCount, 0)
        }
    }
}
