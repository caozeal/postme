import XCTest
@testable import Postme

/// Workspace 编解码、历史上限与落盘往返。
final class PersistenceTests: XCTestCase {

    private func makeTempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("postme-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testCoreRoundTripDoesNotWriteTabsOrHistory() throws {
        var ws = Workspace()
        ws.projects = [Project(name: "P", children: [.folder(.init(name: "A"))])]
        ws.environments = [APIEnvironment(name: "prod", variables: [KeyValueItem(key: "baseUrl", value: "https://p")])]
        ws.activeEnvironmentID = ws.environments.first?.id
        ws.pushHistory(HistoryEntry(request: APIRequest(name: "h", method: .get, url: "u"), statusCode: 200, duration: 0.1, succeeded: true))
        ws.tabs = [EditorTab(draft: APIRequest(name: "草稿", method: .post, url: "d"))]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(ws)
        let back = try decoder.decode(Workspace.self, from: data)

        XCTAssertEqual(back.projects.count, 1)
        XCTAssertEqual(back.environments.first?.variables.first?.value, "https://p")
        XCTAssertEqual(back.activeEnvironmentID, ws.activeEnvironmentID)
        XCTAssertEqual(back.settings.timeout, 30)
        XCTAssertEqual(back.settings.followRedirects, true)

        // v5 起核心文件只写核心节：页签与历史各走自己的文件。
        // 若这里又出现在核心 JSON 里，拆分就白做了（每次按键都会重写全部历史）。
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("\"tabs\""), "核心文件不得再写 tabs")
        XCTAssertFalse(json.contains("\"history\""), "核心文件不得再写 history")
        XCTAssertTrue(back.tabs.isEmpty)
        XCTAssertTrue(back.history.isEmpty)
    }

    func testHistoryIsCappedAndNewestFirst() {
        var ws = Workspace()
        for i in 0..<250 {
            ws.pushHistory(HistoryEntry(request: APIRequest(name: "h\(i)", url: "u\(i)"), statusCode: 200, duration: 0, succeeded: true))
        }
        XCTAssertEqual(ws.history.count, Workspace.historyLimit)
        XCTAssertEqual(ws.history.first?.requestName, "h249")
    }

    func testHistoryEntrySnapshotKeepsTemplateVariables() {
        var request = APIRequest(name: "t", url: "{{baseUrl}}/x")
        request.headers = [KeyValueItem(key: "Authorization", value: "Bearer {{token}}")]
        let entry = HistoryEntry(request: request, statusCode: 200, duration: 0.1, succeeded: true)
        XCTAssertEqual(entry.url, "{{baseUrl}}/x")
        XCTAssertEqual(entry.request.headers.first?.value, "Bearer {{token}}")
        XCTAssertEqual(entry.requestName, "t")
    }

    func testSaveNowWritesSynchronouslyAndRoundTrips() {
        MainActor.assumeIsolated {
            let dir = makeTempDir()
            let service = PersistenceService(fileName: "workspace.json", directory: dir)

            let empty = service.load()
            XCTAssertTrue(empty.projects.isEmpty)
            XCTAssertTrue(empty.environments.isEmpty)
            XCTAssertTrue(empty.tabs.isEmpty)

            var ws = Workspace()
            ws.projects = [Project(name: "P", children: [.request(.init(
                name: "持久化请求",
                request: APIRequest(name: "持久化请求", method: .post, url: "https://x/y")
            ))])]
            ws.environments = [APIEnvironment(name: "e", variables: [KeyValueItem(key: "k", value: "v")])]
            ws.tabs = [EditorTab(draft: APIRequest(name: "草稿2", url: "d2"))]
            service.saveNow(ws)

            // saveNow 必须同步落盘：返回后立即应能读到，不等待、不轮询。
            let loaded = service.load()
            XCTAssertEqual(loaded.projects.first?.children.first?.name, "持久化请求")
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("workspace.json").path
            ))
            XCTAssertEqual(loaded.environments.first?.variables.first?.value, "v")
            XCTAssertEqual(loaded.tabs.first?.draft.name, "草稿2")
            // 三份文件都必须落盘：核心、页签、历史各一份。
            for name in ["workspace.json", "tabs.json", "history.json"] {
                XCTAssertTrue(
                    FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path),
                    "\(name) 应已写出"
                )
            }

            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - v5 三文件

    /// v4 单文件（tabs/history 都在核心文件里）载入后必须：数据完整、
    /// 首次保存迁移成三文件、核心文件不再含旧键。
    func testLegacySingleFileMigratesToSidecars() throws {
        MainActor.assumeIsolated {
            let dir = makeTempDir()
            let legacy = """
            {"version":4,
             "projects":[{"id":"11111111-1111-1111-1111-111111111111","name":"旧项目","children":[]}],
             "activeProjectID":"11111111-1111-1111-1111-111111111111",
             "tabs":[{"id":"22222222-2222-2222-2222-222222222222",
                      "draft":{"name":"旧草稿","url":"https://old"},
                      "baseline":{"name":"旧草稿","url":"https://old"}}],
             "activeTabID":"22222222-2222-2222-2222-222222222222",
             "history":[{"id":"33333333-3333-3333-3333-333333333333","requestName":"旧历史",
                         "method":"GET","url":"https://h","succeeded":true,
                         "timestamp":"2026-01-01T00:00:00Z",
                         "request":{"name":"旧历史","url":"https://h"}}]}
            """
            let core = dir.appendingPathComponent("workspace.json")
            try? legacy.data(using: .utf8)!.write(to: core)

            let service = PersistenceService(fileName: "workspace.json", directory: dir)
            let loaded = service.load()
            XCTAssertEqual(loaded.projects.first?.name, "旧项目")
            XCTAssertEqual(loaded.tabs.first?.draft.url, "https://old")
            XCTAssertEqual(loaded.activeTabID?.uuidString, "22222222-2222-2222-2222-222222222222")
            XCTAssertEqual(loaded.history.first?.requestName, "旧历史")

            service.saveNow(loaded)

            let coreJSON = try? String(contentsOf: core, encoding: .utf8)
            XCTAssertEqual(coreJSON?.contains("\"tabs\""), false, "迁移后核心文件不得再写 tabs")
            XCTAssertEqual(coreJSON?.contains("\"history\""), false, "迁移后核心文件不得再写 history")
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("tabs.json").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("history.json").path))

            // 重新载入：侧车优先，数据不丢。
            let reloaded = PersistenceService(fileName: "workspace.json", directory: dir).load()
            XCTAssertEqual(reloaded.tabs.first?.draft.url, "https://old")
            XCTAssertEqual(reloaded.history.first?.requestName, "旧历史")

            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// 侧车存在时以它为准（哪怕核心文件里还残留旧键）——否则迁移后的第一次保存
    /// 会把旧数据又搬回去。
    func testSidecarWinsOverStaleCoreKeys() {
        MainActor.assumeIsolated {
            let dir = makeTempDir()
            let core = """
            {"version":4,"projects":[],"tabs":[{"id":"44444444-4444-4444-4444-444444444444",
              "draft":{"name":"核心里的旧草稿","url":"https://stale"}}]}
            """
            let tabs = """
            {"version":5,"tabs":[{"id":"55555555-5555-5555-5555-555555555555",
              "draft":{"name":"侧车里的新草稿","url":"https://fresh"}}]}
            """
            try? core.data(using: .utf8)!.write(to: dir.appendingPathComponent("workspace.json"))
            try? tabs.data(using: .utf8)!.write(to: dir.appendingPathComponent("tabs.json"))

            let loaded = PersistenceService(fileName: "workspace.json", directory: dir).load()
            XCTAssertEqual(loaded.tabs.count, 1)
            XCTAssertEqual(loaded.tabs.first?.draft.url, "https://fresh")

            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// 侧车损坏：单独备份它，核心文件不受影响，那一节为空。
    func testCorruptSidecarIsBackedUpWithoutTouchingCore() {
        MainActor.assumeIsolated {
            let dir = makeTempDir()
            let service = PersistenceService(fileName: "workspace.json", directory: dir)
            try? #"{"version":5,"projects":[{"name":"核心完好","children":[]}]}"#.data(using: .utf8)!
                .write(to: dir.appendingPathComponent("workspace.json"))
            try? "不是 json".data(using: .utf8)!
                .write(to: dir.appendingPathComponent("history.json"))

            let loaded = service.load()
            XCTAssertEqual(loaded.projects.first?.name, "核心完好")
            XCTAssertTrue(loaded.history.isEmpty)

            let backups = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
                .filter { $0.hasPrefix("history.json.corrupt-") } ?? []
            XCTAssertEqual(backups.count, 1, "坏的侧车应被单独备份")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: dir.appendingPathComponent("workspace.json.corrupt-\(Int(Date().timeIntervalSince1970))").path),
                "核心文件不该被当成损坏"
            )

            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// 只改页签时不得重写历史文件：这是拆分的全部意义。
    func testEditingTabsDoesNotRewriteHistoryFile() {
        MainActor.assumeIsolated {
            let dir = makeTempDir()
            let service = PersistenceService(fileName: "workspace.json", directory: dir)

            var ws = Workspace()
            ws.projects = [Project(name: "P", children: [])]
            ws.pushHistory(HistoryEntry(request: APIRequest(name: "h", url: "https://h"),
                                        statusCode: 200, duration: 0.1, succeeded: true))
            ws.tabs = [EditorTab(draft: APIRequest(name: "原始", url: "https://a"))]
            service.saveNow(ws)

            let historyURL = dir.appendingPathComponent("history.json")
            let before = (try? FileManager.default.attributesOfItem(atPath: historyURL.path))?[.modificationDate] as? Date
            XCTAssertNotNil(before)

            // 只动页签正文（模拟逐键编辑），历史原样。
            ws.tabs[0].draft.bodyText = "改了一些内容"
            Thread.sleep(forTimeInterval: 0.05)
            service.saveNow(ws)

            let after = (try? FileManager.default.attributesOfItem(atPath: historyURL.path))?[.modificationDate] as? Date
            XCTAssertEqual(before, after, "页签变化不得重写历史文件")

            // 页签文件必须确实更新了。
            let reloaded = service.load()
            XCTAssertEqual(reloaded.tabs.first?.draft.bodyText, "改了一些内容")

            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// 旧快照不得覆盖新快照：防抖任务可能已越过取消检查，排在 `saveNow` 之后才执行。
    func testStaleScheduledWriteDoesNotOverwriteNewerSave() {
        MainActor.assumeIsolated {
            let dir = makeTempDir()
            let service = PersistenceService(fileName: "workspace.json", directory: dir)

            var older = Workspace()
            older.projects = [Project(name: "旧", children: [])]
            service.scheduleSave(older)

            var newer = Workspace()
            newer.projects = [Project(name: "新", children: [])]
            service.saveNow(newer)

            // 等过防抖窗口，让已排队的那次写有机会执行。
            Thread.sleep(forTimeInterval: 0.8)
            let reloaded = PersistenceService(fileName: "workspace.json", directory: dir).load()
            XCTAssertEqual(reloaded.projects.first?.name, "新")

            try? FileManager.default.removeItem(at: dir)
        }
    }

    func testCorruptFileIsBackedUpAndDoesNotCrash() {
        MainActor.assumeIsolated {
            let dir = makeTempDir()
            let service = PersistenceService(fileName: "workspace.json", directory: dir)

            try? "这不是 json".data(using: .utf8)!
                .write(to: dir.appendingPathComponent("workspace.json"))

            let corrupt = service.load()
            XCTAssertTrue(corrupt.projects.isEmpty)

            let backups = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
                .filter { $0.contains("corrupt") } ?? []
            XCTAssertEqual(backups.count, 1)

            try? FileManager.default.removeItem(at: dir)
        }
    }

    func testCorruptBackupNamesNeverCollide() {
        MainActor.assumeIsolated {
            let dir = makeTempDir()
            let service = PersistenceService(fileName: "workspace.json", directory: dir)
            let file = dir.appendingPathComponent("workspace.json")

            // 同一秒内连续两次遇到坏文件：第二次不能因为目标已存在而备份失败，
            // 否则坏文件留在原地被空工作区覆盖，备份也没了。
            for _ in 0..<3 {
                try? "不是 json".data(using: .utf8)!.write(to: file)
                _ = service.load()
            }

            let backups = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
                .filter { $0.contains("corrupt") } ?? []
            XCTAssertEqual(backups.count, 3, "三次损坏必须留下三份备份：\(backups.sorted())")
            XCTAssertEqual(Set(backups).count, 3, "备份文件名不得重复")

            try? FileManager.default.removeItem(at: dir)
        }
    }

    func testUniqueBackupURLAppendsSuffixWhenTaken() {
        MainActor.assumeIsolated {
            let dir = makeTempDir()
            let file = dir.appendingPathComponent("workspace.json")
            try? Data("x".utf8).write(to: file)

            let first = PersistenceService.uniqueBackupURL(for: file)
            try? Data("x".utf8).write(to: first)
            let second = PersistenceService.uniqueBackupURL(for: file)

            XCTAssertNotEqual(first, second)
            XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))

            try? FileManager.default.removeItem(at: dir)
        }
    }

    func testCorruptFileSurvivesWhenBackupCannotBeWritten() {
        MainActor.assumeIsolated {
            // 真把目录设为不可写，让备份**确实**失败：此时坏文件必须原地保留，
            // 否则它会被"空工作区 + 后续保存"抹掉，用户既没备份也没提示。
            let dir = makeTempDir()
            let service = PersistenceService(fileName: "workspace.json", directory: dir)
            let file = dir.appendingPathComponent("workspace.json")
            let junk = #"{"foo":1}"#
            try? junk.data(using: .utf8)!.write(to: file)

            // 目录只读：无法在其中创建备份文件（moveItem 与 write 都会失败）
            try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
                try? FileManager.default.removeItem(at: dir)
            }

            let loaded = service.load()
            XCTAssertTrue(loaded.projects.isEmpty, "载入失败仍返回空工作区")

            // 关键断言：原文件必须还在，且内容未被改写
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: file.path),
                "备份失败时原文件不得消失"
            )
            let onDisk = try? String(contentsOf: file, encoding: .utf8)
            XCTAssertEqual(onDisk, junk, "备份失败时原文件内容不得被改写")
        }
    }

    func testSettingsTimeoutIsClamped() {
        var settings = AppSettings()
        settings.timeout = 0
        XCTAssertEqual(settings.executorOptions.timeout, 1)

        settings.timeout = -5
        XCTAssertEqual(settings.executorOptions.timeout, 1)

        settings.timeout = 999_999
        XCTAssertEqual(settings.executorOptions.timeout, 3600)

        settings.timeout = 30
        XCTAssertEqual(settings.executorOptions.timeout, 30)
    }

    func testDefaultSettingsMatchExecutorDefaults() {
        let settings = AppSettings()
        let options = settings.executorOptions
        XCTAssertEqual(options.timeout, 30)
        XCTAssertTrue(options.followRedirects)
        XCTAssertFalse(options.allowInsecureTLS)
    }
}
