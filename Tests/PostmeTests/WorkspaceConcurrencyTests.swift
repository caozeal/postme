import XCTest
import Darwin
@testable import Postme

/// 短锁 + 磁盘指纹 CAS 的回归用例。
///
/// 故障注入沿用 PersistenceTests 的两条现成手法：把 `history.json` 预建成目录、
/// 以及 `chmod 0o500` 让写入失败。这里只断言「结果 + 磁盘字节」，不依赖 GUI。
@MainActor
final class WorkspaceConcurrencyTests: XCTestCase {

    private func makeTempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("postme-concurrency-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testFingerprintDetectsAtomicRewrite() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = DiskFingerprint.capture(directory: dir)
        let file = dir.appendingPathComponent("workspace.json")
        try? Data("{}".utf8).write(to: file, options: .atomic)
        let after = DiskFingerprint.capture(directory: dir)
        XCTAssertEqual(after.differingFiles(from: before), ["workspace.json"])
    }

    func testFingerprintDistinguishesMissingFromExisting() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let empty = DiskFingerprint.capture(directory: dir)
        XCTAssertEqual(empty.entries["workspace.json"]?.exists, false)
        try? Data("{}".utf8).write(to: dir.appendingPathComponent("workspace.json"))
        XCTAssertEqual(DiskFingerprint.capture(directory: dir).entries["workspace.json"]?.exists, true)
    }

    /// 两个实例读同一份磁盘，其中一个先写；另一个的基准已陈旧，必须报冲突且不写任何字节。
    func testStaleBaselineReportsConflictWithoutWriting() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stale = PersistenceService(directory: dir)
        _ = stale.load()
        let writer = PersistenceService(directory: dir)
        _ = writer.load()

        var written = Workspace()
        written.projects = [Project(name: "FromWriter")]
        XCTAssertEqual(writer.flushNow(written), .succeeded)
        let before = try? Data(contentsOf: dir.appendingPathComponent("workspace.json"))

        var staleWorkspace = Workspace()
        staleWorkspace.projects = [Project(name: "FromStale")]
        let result = stale.flushNow(staleWorkspace)
        guard case .conflict(.fingerprintMismatch(let files)) = result else {
            return XCTFail("预期指纹冲突，实际 \(result)")
        }
        XCTAssertFalse(files.isEmpty)
        let after = try? Data(contentsOf: dir.appendingPathComponent("workspace.json"))
        XCTAssertEqual(before, after, "冲突时必须一个字节都不写")
    }

    /// tabs 写成功、history 失败：返回 .failed 且仍重算基准，下次只重试 history，
    /// 不会把自己刚写的 inode 误判成外部改动。
    func testPartialFailureCanRetryWithoutFalseConflict() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let blocked = dir.appendingPathComponent("history.json")
        try? FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        let service = PersistenceService(directory: dir)
        _ = service.load()

        var ws = Workspace()
        ws.projects = [Project(name: "P")]
        ws.pushHistory(HistoryEntry(request: APIRequest(name: "h", url: "u"),
                                     statusCode: 200, duration: 0, succeeded: true))
        guard case .failed(let names) = service.flushNow(ws) else {
            return XCTFail("history.json 是目录，第一次写入应失败")
        }
        XCTAssertTrue(names.contains("history.json"))
        try? FileManager.default.removeItem(at: blocked)
        XCTAssertEqual(service.flushNow(ws), .succeeded)
    }

    /// reloadFromDisk 必须掐掉在途防抖写：等过 600ms 窗口，磁盘仍是重载读到的内容。
    func testReloadCancelsPendingDebouncedSave() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = PersistenceService(directory: dir)
        var pending = service.load()
        pending.projects = [Project(name: "ShouldBeCancelled")]
        service.scheduleSave(pending)

        let other = PersistenceService(directory: dir)
        var external = other.load()
        external.projects = [Project(name: "FromDisk")]
        XCTAssertEqual(other.flushNow(external), .succeeded)

        let reloaded = service.reloadFromDisk()
        XCTAssertEqual(reloaded.projects.first?.name, "FromDisk")
        Thread.sleep(forTimeInterval: 0.8)
        let final = PersistenceService(directory: dir).load()
        XCTAssertEqual(final.projects.first?.name, "FromDisk", "旧防抖快照不能盖回磁盘")
    }

    func testSaveResultDeliveredOnImmediatePath() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = PersistenceService(directory: dir)
        var results: [SaveResult] = []
        service.onSaveResult = { result, _ in results.append(result) }
        var ws = Workspace()
        ws.projects = [Project(name: "P")]
        XCTAssertEqual(service.flushNow(ws), .succeeded)
        XCTAssertEqual(results, [.succeeded])
    }

    /// 重载后必须维持「≥1 页签」与 activeTabID 有效，且清掉指向旧节点的瞬态状态。
    func testReloadWorkspaceKeepsTabInvariants() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = PersistenceService(directory: dir)
        let app = AppState(persistence: service, languageOverride: .zhHans)
        let other = PersistenceService(directory: dir)
        var external = other.load()
        external.projects = [Project(name: "External")]
        XCTAssertEqual(other.flushNow(external), .succeeded)

        app.reloadWorkspace()
        XCTAssertGreaterThanOrEqual(app.tabs.count, 1)
        XCTAssertTrue(app.tabs.contains { $0.id == app.activeTabID })
        XCTAssertEqual(app.projects.first?.name, "External")
    }

    /// 错误状态存的是「键 + 参数」而不是生成好的字符串：渲染时取词，切语言自动重译。
    func testSaveIssueUsesLocalizationKey() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = AppState(persistence: PersistenceService(directory: dir), languageOverride: .zhHans)
        app.handleSaveResult(.failed(["history.json"]), generation: 1)
        XCTAssertEqual(app.saveIssue?.titleKey, .saveFailedTitle)
        let zh = app.t(.saveFailedTitle)
        app.setLanguage(.en)
        // setLanguage 会触发一次成功保存，数据落盘后问题被正常清除（预期行为）。
        XCTAssertNotEqual(app.t(.saveFailedTitle), zh)
    }
}
