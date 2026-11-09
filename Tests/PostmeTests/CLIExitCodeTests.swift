import XCTest
import Darwin
@testable import Postme

/// CLI 并发冲突的退出码契约。
///
/// 用同进程的 `open` + `flock` 模拟「另一个 postme 进程正在写」：不走
/// `WorkspaceLock`（它带进程内 NSLock，嵌套会自锁），只占住内核的那把锁。
@MainActor
final class CLIExitCodeTests: XCTestCase {

    private func makeTempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("postme-cli-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 调用方负责在持锁期间调用 `body`，返回后释放。
    private func whileBusy<R>(_ dir: URL, _ body: () -> R) -> R {
        let path = dir.appendingPathComponent(WorkspaceDirectory.lockFileName).path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        return body()
    }

    func testNormalWriteSucceeds() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(
            PostmeCLI.run(arguments: ["--data-dir", dir.path, "project", "create", "Alpha"]), 0
        )
    }

    func testBusyWriteReturnsThreeAndWritesNothing() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(
            PostmeCLI.run(arguments: ["--data-dir", dir.path, "project", "create", "Alpha"]), 0
        )
        let before = try? Data(contentsOf: dir.appendingPathComponent("workspace.json"))
        let code = whileBusy(dir) {
            PostmeCLI.run(arguments: ["--data-dir", dir.path, "--json", "project", "create", "Beta"])
        }
        XCTAssertEqual(code, 3)
        let after = try? Data(contentsOf: dir.appendingPathComponent("workspace.json"))
        XCTAssertEqual(before, after, "占用时不得写入任何文件")
    }

    func testReadOnlyCommandSucceedsWhileBusy() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(
            PostmeCLI.run(arguments: ["--data-dir", dir.path, "project", "create", "Alpha"]), 0
        )
        let code = whileBusy(dir) {
            PostmeCLI.run(arguments: ["--data-dir", dir.path, "--json", "project", "list"])
        }
        XCTAssertEqual(code, 0)
    }

    /// --json 必须保留 error 键，并额外给出稳定的 code / exitCode。
    func testBusyJSONCarriesStableCode() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(
            PostmeCLI.run(arguments: ["--data-dir", dir.path, "project", "create", "Alpha"]), 0
        )
        let capture = dir.appendingPathComponent("stderr-capture.txt")
        FileManager.default.createFile(atPath: capture.path, contents: nil)
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: capture.path))
        let saved = dup(STDERR_FILENO)
        dup2(handle.fileDescriptor, STDERR_FILENO)
        let code = whileBusy(dir) {
            PostmeCLI.run(arguments: ["--data-dir", dir.path, "--json", "project", "create", "Beta"])
        }
        dup2(saved, STDERR_FILENO)
        close(saved)
        try? handle.close()
        XCTAssertEqual(code, 3)
        let text = (try? String(contentsOf: capture, encoding: .utf8)) ?? ""
        XCTAssertTrue(text.contains("workspace_busy"), text)
        XCTAssertTrue(text.contains("\"error\""), text)
        XCTAssertTrue(text.contains("\"exitCode\""), text)
    }

    func testUnknownCommandReturnsUsageCode() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(PostmeCLI.run(arguments: ["--data-dir", dir.path, "bogus"]), 2)
    }

    func testExportRefusesManagedOutputPath() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(
            PostmeCLI.run(arguments: ["--data-dir", dir.path, "project", "create", "Alpha"]), 0
        )
        let target = dir.appendingPathComponent("workspace.json").path
        let code = PostmeCLI.run(arguments: [
            "--data-dir", dir.path, "export", "postman", "Alpha", "--output", target
        ])
        XCTAssertNotEqual(code, 0)
    }
}
