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
}
