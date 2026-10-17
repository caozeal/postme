import XCTest
@testable import Postme

/// workspace.json 的 schema 容错。
///
/// 背景（实测缺陷）：v1 用编译器合成的解码，任何非可选键缺失都会让整份工作区解码失败，
/// `PersistenceService.load()` 随即把文件搬成 `.corrupt-*` 并以空工作区启动——
/// 集合、环境、历史一次性全没。加一个字段就能触发。
final class WorkspaceSchemaToleranceTests: XCTestCase {

    private func decode(_ json: String) throws -> Workspace {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Workspace.self, from: Data(json.utf8))
    }

    // MARK: - 缺键必须仍能载入

    func testLegacyFileWithoutSettingsLoads() throws {
        // v1 早期文件：没有 settings、没有 draft、没有 version
        let ws = try decode(#"{"collections":[],"environments":[],"history":[]}"#)
        XCTAssertTrue(ws.projects.isEmpty)
        XCTAssertEqual(ws.settings.timeout, 30)
        XCTAssertTrue(ws.settings.followRedirects)
        XCTAssertFalse(ws.settings.allowInsecureTLS)
    }

    func testFileWithOnlyVersionKeyIsNotClaimed() {
        // 单独一个 {"version":1} 不能证明这是工作区文件：
        // 若被当成空工作区载入，它会被下次保存直接覆盖，用户既无备份也无提示。
        XCTAssertThrowsError(try decode(#"{"version":1}"#))
        XCTAssertThrowsError(try decode(#"{"version":7}"#))
    }

    func testAnySingleIdentifyingKeyIsEnough() throws {
        // 任意一个真正的字段都足以认领（缺键由容错解码补默认值）
        XCTAssertNoThrow(try decode(#"{"collections":[]}"#))
        XCTAssertNoThrow(try decode(#"{"projects":[]}"#))
        XCTAssertNoThrow(try decode(#"{"history":[]}"#))
        XCTAssertNoThrow(try decode(#"{"settings":{}}"#))
        XCTAssertNoThrow(try decode(#"{"environments":[]}"#))
    }

    func testMissingOptionalDraftAndActiveEnvironment() throws {
        let ws = try decode(#"{"version":1,"collections":[],"environments":[],"history":[],"settings":{"timeout":5,"followRedirects":false,"allowInsecureTLS":true}}"#)
        XCTAssertNil(ws.draft)
        XCTAssertNil(ws.activeEnvironmentID)
        XCTAssertEqual(ws.settings.timeout, 5)
        XCTAssertFalse(ws.settings.followRedirects)
        XCTAssertTrue(ws.settings.allowInsecureTLS)
    }

    func testNewFieldInFileIsIgnored() throws {
        // 未来版本多出的字段不能让旧代码崩
        let ws = try decode(#"{"version":9,"projects":[],"environments":[],"history":[],"futureField":{"a":1}}"#)
        XCTAssertTrue(ws.projects.isEmpty)
    }

    func testCorruptFieldValueFallsBackToDefault() throws {
        // 类型不符（history 是字符串、settings 是数字）不应作废整份文件
        let ws = try decode(#"{"version":1,"collections":[],"environments":[],"history":"oops","settings":42}"#)
        XCTAssertTrue(ws.history.isEmpty)
        XCTAssertEqual(ws.settings.timeout, 30)
    }

    func testUnknownEnumValuesFallBack() throws {
        let json = """
        {"version":1,"environments":[],"history":[],"settings":{},
         "collections":[{"request":{"_0":{"id":"11111111-1111-1111-1111-111111111111","name":"r",
           "request":{"method":"BREW","bodyKind":"telepathy","url":"https://x"}}}}]}
        """
        let ws = try decode(json)
        let req = ws.projects.first?.children.first?.savedRequest?.request
        XCTAssertEqual(req?.method, .get)
        XCTAssertEqual(req?.bodyKind, BodyKind.none)
        XCTAssertEqual(req?.url, "https://x")
    }

    // MARK: - 集合树结构必须完整保留（防"容错把数据解成默认值"）

    func testNestedCollectionSurvivesRoundTripIntact() throws {
        let tree: [CollectionNode] = [
            .folder(.init(name: "外层", children: [
                .folder(.init(name: "内层", children: [
                    .request(.init(name: "叶子", request: APIRequest(name: "叶子", method: .post, url: "https://x/y")))
                ]))
            ]))
        ]
        let ws = Workspace(projects: [Project(name: "演示项目", children: tree)])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let back = try decoder.decode(Workspace.self, from: encoder.encode(ws))

        XCTAssertEqual(back.projects.count, 1)
        let project = back.projects.first
        XCTAssertEqual(project?.name, "演示项目")
        let outer = project?.children.first
        XCTAssertEqual(outer?.isFolder, true)
        XCTAssertEqual(outer?.name, "外层")
        XCTAssertEqual(outer?.children?.count, 1)

        let inner = outer?.children?.first
        XCTAssertEqual(inner?.name, "内层")
        XCTAssertEqual(inner?.children?.count, 1)

        let leaf = inner?.children?.first?.savedRequest
        XCTAssertEqual(leaf?.name, "叶子")
        XCTAssertEqual(leaf?.request.method, .post)
        XCTAssertEqual(leaf?.request.url, "https://x/y")
    }

    func testCorruptChildIsDroppedButSiblingsSurvive() throws {
        // 第二个子节点不是 folder 也不是 request → 只丢它，其余保留
        let json = """
        {"version":1,"environments":[],"history":[],"settings":{},
         "collections":[{"folder":{"_0":{"id":"11111111-1111-1111-1111-111111111111","name":"组",
           "children":[
             {"request":{"_0":{"id":"22222222-2222-2222-2222-222222222222","name":"好节点",
               "request":{"method":"GET","url":"https://ok"}}}},
             {"nonsense":123},
             {"request":{"_0":{"id":"33333333-3333-3333-3333-333333333333","name":"也是好节点",
               "request":{"method":"GET","url":"https://ok2"}}}}
           ]}}}]}
        """
        let ws = try decode(json)
        let children = ws.projects.first?.children.first?.children
        XCTAssertEqual(children?.count, 2)
        XCTAssertEqual(children?.first?.name, "好节点")
        XCTAssertEqual(children?.last?.name, "也是好节点")
    }

    func testLegacyNodeWithoutIDGetsFreshID() throws {
        let json = """
        {"version":1,"environments":[],"history":[],"settings":{},
         "collections":[{"request":{"_0":{"name":"无 id 请求","request":{"method":"GET","url":"https://x"}}}}]}
        """
        let ws = try decode(json)
        XCTAssertEqual(ws.projects.first?.children.first?.name, "无 id 请求")
        XCTAssertNotNil(ws.projects.first?.children.first?.id)
    }

    // MARK: - v3 迁移：旧版顶层 collections → 默认项目

    func testLegacyCollectionsMigrateToDefaultProject() throws {
        // 旧文件（v1/v2）：顶层是 collections。必须整体收进一个「默认项目」，
        // 且子节点 id 原样保留——id 变了，editingNodeID 之类引用就全断。
        let json = """
        {"version":2,"environments":[],"history":[],"settings":{},
         "collections":[
           {"folder":{"_0":{"id":"aaaaaaaa-0000-0000-0000-000000000001","name":"组",
             "children":[
               {"request":{"_0":{"id":"bbbbbbbb-0000-0000-0000-000000000001","name":"叶子",
                 "request":{"method":"POST","url":"https://x/y"}}}}
             ]}}}
         ]}
        """
        let ws = try decode(json)

        XCTAssertEqual(ws.projects.count, 1)
        let project = ws.projects.first
        XCTAssertEqual(project?.name, "默认项目")
        XCTAssertEqual(project?.id, ws.activeProjectID, "迁移后当前项目必须指向默认项目")

        let folder = project?.children.first
        XCTAssertEqual(folder?.id.uuidString, "AAAAAAAA-0000-0000-0000-000000000001")
        let leaf = folder?.children?.first?.savedRequest
        XCTAssertEqual(leaf?.id.uuidString, "BBBBBBBB-0000-0000-0000-000000000001")
        XCTAssertEqual(leaf?.request.method, .post)
        XCTAssertEqual(leaf?.request.url, "https://x/y")
    }

    func testLegacyEmptyCollectionsYieldsNoProjects() throws {
        // 旧文件没有集合时不造项目：与全新工作区一致（0 个项目），
        // 由 AppState.ensureActiveProject() 兜底建「默认项目」。
        let ws = try decode(#"{"version":1,"collections":[],"environments":[],"history":[]}"#)
        XCTAssertTrue(ws.projects.isEmpty)
        XCTAssertNil(ws.activeProjectID)
    }

    func testProjectsKeyTakesPrecedenceOverLegacyCollections() throws {
        // 手改出的混合文件：projects 权威，旧 collections 被忽略。
        // 规则简单可测比"恢复魔法"重要（v3 正常不会写出 collections）。
        let json = """
        {"version":3,"projects":[{"id":"cccccccc-0000-0000-0000-000000000001","name":"新项目","children":[]}],
         "collections":[{"folder":{"_0":{"name":"旧数据","children":[]}}}]}
        """
        let ws = try decode(json)
        XCTAssertEqual(ws.projects.count, 1)
        XCTAssertEqual(ws.projects.first?.name, "新项目")
        XCTAssertEqual(ws.activeProjectID?.uuidString, "CCCCCCCC-0000-0000-0000-000000000001")
    }

    func testDanglingActiveProjectIDSelfHeals() throws {
        let json = """
        {"version":3,
         "projects":[
           {"id":"dddddddd-0000-0000-0000-000000000001","name":"一","children":[]},
           {"id":"dddddddd-0000-0000-0000-000000000002","name":"二","children":[]}
         ],
         "activeProjectID":"ffffffff-9999-9999-9999-999999999999"}
        """
        let ws = try decode(json)
        XCTAssertEqual(ws.activeProjectID?.uuidString, "DDDDDDDD-0000-0000-0000-000000000001")

        // 自愈必须收敛：重新编码再解码，值不能漂移
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(Workspace.self, from: JSONEncoder().encode(ws))
        XCTAssertEqual(back.activeProjectID, ws.activeProjectID)
    }

    func testProjectsArrayDropsCorruptElements() throws {
        // projects 数组里混入坏元素：只丢坏的，好的保留（逐元素容错）
        let json = """
        {"version":3,"projects":[
          {"id":"11111111-1111-1111-1111-111111111111","name":"好一","children":[]},
          123,
          null,
          {"id":"22222222-2222-2222-2222-222222222222","name":"好二","children":[]}
        ]}
        """
        let ws = try decode(json)
        XCTAssertEqual(ws.projects.count, 2)
        XCTAssertEqual(ws.projects.first?.name, "好一")
        XCTAssertEqual(ws.projects.last?.name, "好二")
    }

    // MARK: - 真损坏仍必须判为损坏

    func testUnrelatedJSONIsStillCorrupt() {
        // 合法 JSON，但不含任何已知工作区字段 → 不能静默当成空工作区
        XCTAssertThrowsError(try decode(#"{"foo":1,"bar":[]}"#))
        XCTAssertThrowsError(try decode("[]"))
        XCTAssertThrowsError(try decode(#""a string""#))
    }

    func testUnrelatedJSONIsBackedUpNotSilentlyEmptied() {
        MainActor.assumeIsolated {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("postme-corrupt-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? #"{"foo":1}"#.data(using: .utf8)!
                .write(to: dir.appendingPathComponent("workspace.json"))

            let service = PersistenceService(fileName: "workspace.json", directory: dir)
            let loaded = service.load()
            XCTAssertTrue(loaded.projects.isEmpty)

            let backups = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
                .filter { $0.contains("corrupt") } ?? []
            XCTAssertEqual(backups.count, 1, "无关 JSON 必须被备份，而不是当作空工作区继续使用")

            try? FileManager.default.removeItem(at: dir)
        }
    }

    func testLegacyFileIsNotBackedUp() {
        MainActor.assumeIsolated {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("postme-legacy-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let legacy = #"{"version":1,"collections":[],"environments":[],"history":[]}"#
            try? legacy.data(using: .utf8)!
                .write(to: dir.appendingPathComponent("workspace.json"))

            let service = PersistenceService(fileName: "workspace.json", directory: dir)
            _ = service.load()

            let backups = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
                .filter { $0.contains("corrupt") } ?? []
            XCTAssertTrue(backups.isEmpty, "旧版本文件应被正常载入，不该被当成损坏搬走")
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("workspace.json").path
            ))

            try? FileManager.default.removeItem(at: dir)
        }
    }

    func testLiveWorkspaceFileShapeStillDecodes() throws {
        // 用真实编码产物验证：当前版本写出的文件仍能完整读回
        var ws = Workspace()
        ws.projects = [Project(name: "演示", children: [
            .request(.init(name: "用户列表", request: APIRequest(name: "用户列表", method: .get, url: "{{baseUrl}}/api/users")))
        ])]
        ws.activeProjectID = ws.projects.first?.id
        ws.environments = [APIEnvironment(name: "本地", variables: [KeyValueItem(key: "baseUrl", value: "http://127.0.0.1:18080")])]
        ws.activeEnvironmentID = ws.environments.first?.id
        ws.draft = APIRequest(name: "草稿", url: "{{baseUrl}}/api/users")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(ws)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(Workspace.self, from: data)

        XCTAssertEqual(back.projects.first?.name, "演示")
        XCTAssertEqual(back.projects.first?.children.first?.name, "用户列表")
        XCTAssertEqual(back.activeProjectID, ws.activeProjectID)
        XCTAssertEqual(back.environments.first?.name, "本地")
        XCTAssertEqual(back.activeEnvironmentID, ws.activeEnvironmentID)
        XCTAssertEqual(back.draft?.url, "{{baseUrl}}/api/users")
    }
}
