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

    func testWorkspaceCodableRoundTrip() throws {
        var ws = Workspace()
        ws.projects = [Project(name: "P", children: [.folder(.init(name: "A"))])]
        ws.environments = [APIEnvironment(name: "prod", variables: [KeyValueItem(key: "baseUrl", value: "https://p")])]
        ws.activeEnvironmentID = ws.environments.first?.id
        ws.pushHistory(HistoryEntry(request: APIRequest(name: "h", method: .get, url: "u"), statusCode: 200, duration: 0.1, succeeded: true))
        ws.draft = APIRequest(name: "草稿", method: .post, url: "d")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(ws)
        let back = try decoder.decode(Workspace.self, from: data)

        XCTAssertEqual(back.projects.count, 1)
        XCTAssertEqual(back.environments.first?.variables.first?.value, "https://p")
        XCTAssertEqual(back.activeEnvironmentID, ws.activeEnvironmentID)
        XCTAssertEqual(back.history.count, 1)
        XCTAssertEqual(back.history.first?.statusCode, 200)
        XCTAssertEqual(back.draft?.name, "草稿")
        XCTAssertEqual(back.settings.timeout, 30)
        XCTAssertEqual(back.settings.followRedirects, true)
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
            XCTAssertNil(empty.draft)

            var ws = Workspace()
            ws.projects = [Project(name: "P", children: [.request(.init(
                name: "持久化请求",
                request: APIRequest(name: "持久化请求", method: .post, url: "https://x/y")
            ))])]
            ws.environments = [APIEnvironment(name: "e", variables: [KeyValueItem(key: "k", value: "v")])]
            ws.draft = APIRequest(name: "草稿2", url: "d2")
            service.saveNow(ws)

            // saveNow 必须同步落盘：返回后立即应能读到，不等待、不轮询。
            let loaded = service.load()
            XCTAssertEqual(loaded.projects.first?.children.first?.name, "持久化请求")
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("workspace.json").path
            ))
            XCTAssertEqual(loaded.environments.first?.variables.first?.value, "v")
            XCTAssertEqual(loaded.draft?.name, "草稿2")

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
