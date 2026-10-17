import XCTest
@testable import Postme

/// 响应体上限与取消行为。
///
/// 背景（实测缺陷）：`didReceive` 只 append，响应体完整驻留内存——本地 120 MB 响应
/// 让 phys_footprint 从 2 MB 涨到 147 MB。展示层阈值只影响显示文本，管不住内存。
final class ResponseLimitTests: XCTestCase {

    private func makeTempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("postme-resplimit-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 展示层

    func testTruncatedResponseSkipsJSONPrettifying() {
        // 半截 JSON 美化必然失败；失败后回退原文会让人误以为这就是全部响应。
        let body = Data(#"{"a":1,"b":"#.utf8)
        var response = APIResponse(
            statusCode: 200,
            headers: [],
            body: body,
            mimeType: "application/json",
            timing: RequestTiming(total: 0.1)
        )
        response.isBodyTruncated = true
        response.bodyLimitBytes = 16 * 1024 * 1024

        let text = response.displayBodyText(l10n: .zhHans)
        XCTAssertTrue(text.contains("已停止接收"))
        XCTAssertTrue(text.contains("16.00 MB"))
        XCTAssertFalse(text.contains("\n  "), "截断内容不应被美化")
    }

    func testTruncationMessageStatesTheActualLimit() {
        let response0 = makeTruncated(limit: 8 * 1024 * 1024)
        XCTAssertTrue(response0.displayBodyText(l10n: .zhHans).contains("8.00 MB"))

        let response1 = makeTruncated(limit: 1024)
        XCTAssertTrue(response1.displayBodyText(l10n: .zhHans).contains("1.0 KB"))
    }

    private func makeTruncated(limit: Int) -> APIResponse {
        var response = APIResponse(
            statusCode: 200,
            headers: [],
            body: Data(repeating: 0x61, count: 512),
            mimeType: "text/plain",
            timing: RequestTiming(total: 0.1)
        )
        response.isBodyTruncated = true
        response.bodyLimitBytes = limit
        return response
    }

    func testCompleteResponseIsNotMarkedTruncated() {
        let response = APIResponse(
            statusCode: 200,
            headers: [],
            body: Data(#"{"ok":true}"#.utf8),
            mimeType: "application/json",
            timing: RequestTiming(total: 0.1)
        )
        XCTAssertFalse(response.isBodyTruncated)
        XCTAssertFalse(response.displayBodyText(l10n: .zhHans).contains("已停止接收"))
        XCTAssertTrue(response.displayBodyText(l10n: .zhHans).contains("\n"), "未截断的 JSON 应被美化")
    }

    // MARK: - 上限与取消的分类（走真实执行器）

    func testBodyOverLimitIsTruncatedNotFailed() throws {
        let server = try LocalHTTPServer(routes: [
            "/big": .bytes(count: 3 * 1024 * 1024, contentType: "text/plain")
        ])
        defer { server.stop() }

        let cap = 512 * 1024
        let response = try sendSync(
            APIRequest(name: "big", method: .get, url: server.url("/big")),
            RequestExecutorOptions(timeout: 60, maxResponseBytes: cap)
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(response.isBodyTruncated)
        XCTAssertEqual(response.bodyLimitBytes, cap)
        XCTAssertLessThanOrEqual(response.body.count, cap)
        XCTAssertFalse(response.headers.isEmpty, "截断时仍应保留响应头")
    }

    func testResponseUnderLimitIsComplete() throws {
        let payload = Data(#"{"ok":true}"#.utf8)
        let server = try LocalHTTPServer(routes: ["/small": .fixed(payload, contentType: "application/json")])
        defer { server.stop() }

        let response = try sendSync(
            APIRequest(name: "s", method: .get, url: server.url("/small")),
            RequestExecutorOptions()
        )
        XCTAssertEqual(response.body, payload)
        XCTAssertFalse(response.isBodyTruncated)
    }

    func testUserCancelThrowsCancelledNotTransportError() async throws {
        let server = try LocalHTTPServer(routes: ["/slow": .delayed(seconds: 30, body: Data("late".utf8))])
        defer { server.stop() }

        let executor = RequestExecutor(options: RequestExecutorOptions(timeout: 120))

        let task = Task { () -> Error? in
            do {
                _ = try await executor.send(APIRequest(name: "slow", method: .get, url: server.url("/slow")))
                return nil
            } catch {
                return error
            }
        }

        // 等请求真正发出去再取消，避免取消一个还没启动的 task。
        try await Task.sleep(nanoseconds: 800_000_000)
        let cancelled = executor.cancel()
        XCTAssertEqual(cancelled, 1, "应有一个在飞 task 被取消")

        let error = await task.value
        guard let error else {
            XCTFail("应当被取消")
            return
        }
        guard case RequestFailure.cancelled = error else {
            XCTFail("错误类型应为 .cancelled，实际: \(error)")
            return
        }
    }

    func testExecutorStillWorksAfterCancel() async throws {
        let payload = Data("ok".utf8)
        let server = try LocalHTTPServer(routes: [
            "/slow": .delayed(seconds: 30, body: Data("late".utf8)),
            "/small": .fixed(payload, contentType: "text/plain")
        ])
        defer { server.stop() }

        let executor = RequestExecutor(options: RequestExecutorOptions(timeout: 120))
        let slow = Task { try? await executor.send(APIRequest(name: "slow", method: .get, url: server.url("/slow"))) }

        try await Task.sleep(nanoseconds: 800_000_000)
        executor.cancel()
        _ = await slow.value

        // 取消后同一个执行器必须还能正常发请求
        let response = try await executor.send(APIRequest(name: "small", method: .get, url: server.url("/small")))
        XCTAssertEqual(response.body, payload)
    }

    func testCancelWithNoInFlightRequestIsNoop() {
        let executor = RequestExecutor(options: RequestExecutorOptions())
        XCTAssertEqual(executor.cancel(), 0)
    }

    // MARK: - 辅助

    private func sendSync(
        _ request: APIRequest,
        _ options: RequestExecutorOptions,
        executor: RequestExecutor? = nil
    ) throws -> APIResponse {
        let executor = executor ?? RequestExecutor(options: options)
        let sem = DispatchSemaphore(value: 0)
        var result: Result<APIResponse, Error>?
        Task {
            do { result = .success(try await executor.send(request)) }
            catch { result = .failure(error) }
            sem.signal()
        }
        sem.wait()
        return try result!.get()
    }
}

/// 测试用的极简 HTTP 服务：真实 socket，避免用 mock 掩盖传输层行为。
final class LocalHTTPServer {
    enum Route {
        case fixed(Data, contentType: String)
        case bytes(count: Int, contentType: String)
        case delayed(seconds: Double, body: Data)
    }

    private let listener: FileHandle
    private let port: UInt16
    private let routes: [String: Route]
    private let queue = DispatchQueue(label: "postme.test.server", attributes: .concurrent)
    private var stopped = false

    init(routes: [String: Route]) throws {
        self.routes = routes
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socket }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { close(fd); throw ServerError.bind }
        guard listen(fd, 16) == 0 else { close(fd); throw ServerError.listen }

        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        self.port = UInt16(bigEndian: actual.sin_port)
        self.listener = FileHandle(fileDescriptor: fd, closeOnDealloc: true)

        startAccepting()
    }

    enum ServerError: Error { case socket, bind, listen }

    func url(_ path: String) -> String { "http://127.0.0.1:\(port)\(path)" }

    func stop() {
        stopped = true
        try? listener.close()
    }

    private func startAccepting() {
        queue.async { [weak self] in
            guard let self else { return }
            while !self.stopped {
                var clientAddr = sockaddr()
                var len = socklen_t(MemoryLayout<sockaddr>.size)
                let client = accept(self.listener.fileDescriptor, &clientAddr, &len)
                guard client >= 0 else { return }
                self.queue.async { self.serve(client) }
            }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }

        var request = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        // 读到请求头结束即可（测试只发 GET）
        while request.range(of: Data("\r\n\r\n".utf8)) == nil {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            request.append(contentsOf: chunk[0..<n])
            if request.count > 65536 { break }
        }

        let firstLine = String(decoding: request.prefix(while: { $0 != 0x0D }), as: UTF8.self)
        let path = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let route = routes[path] ?? routes[path.split(separator: "?").first.map(String.init) ?? "/"]

        switch route {
        case .fixed(let body, let contentType):
            write(fd, headers(status: 200, length: body.count, contentType: contentType))
            write(fd, body)

        case .bytes(let count, let contentType):
            write(fd, headers(status: 200, length: count, contentType: contentType))
            let block = Data(repeating: 0x61, count: 64 * 1024)
            var sent = 0
            while sent < count {
                let n = min(block.count, count - sent)
                if write(fd, block.prefix(n)) < 0 { return }  // 客户端取消后写失败即退出
                sent += n
            }

        case .delayed(let seconds, let body):
            Thread.sleep(forTimeInterval: seconds)
            write(fd, headers(status: 200, length: body.count, contentType: "text/plain"))
            write(fd, body)

        case nil:
            write(fd, headers(status: 404, length: 0, contentType: "text/plain"))
        }
    }

    @discardableResult
    private func write(_ fd: Int32, _ data: Data) -> Int {
        data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if n <= 0 { return -1 }
                offset += n
            }
            return offset
        }
    }

    private func headers(status: Int, length: Int, contentType: String) -> Data {
        var lines = "HTTP/1.1 \(status) OK\r\n"
        lines += "Content-Type: \(contentType)\r\n"
        lines += "Content-Length: \(length)\r\n"
        lines += "Connection: close\r\n"
        lines += "\r\n"
        return Data(lines.utf8)
    }
}

private extension Optional where Wrapped == Range<Data.Index> {
    var isTrue: Bool { self != nil }
}
