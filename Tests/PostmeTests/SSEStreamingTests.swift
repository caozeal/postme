import XCTest
@testable import Postme

/// 流式传输（AC2）：`.head` / `.chunk` / `.finished`、取消、截断、超时语义。
///
/// 全部走真实 socket（`LocalHTTPServer`），因为要验证的正是 delegate 时序——
/// 用 mock 把"什么时候回调什么"喂进去，就等于自己证明自己。
final class SSEStreamingTests: XCTestCase {

    // MARK: - 辅助

    private struct Timeout: Error {}

    /// 收集整条流。`sem.wait` 的上限只是防止实现挂死时测试永久卡住。
    private func collect(
        _ stream: AsyncThrowingStream<RequestUpdate, Error>,
        timeout: TimeInterval = 20
    ) -> (updates: [RequestUpdate], error: Error?) {
        let sem = DispatchSemaphore(value: 0)
        var updates: [RequestUpdate] = []
        var failure: Error?
        Task {
            do {
                for try await update in stream { updates.append(update) }
            } catch {
                failure = error
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + timeout)
        return (updates, failure)
    }

    private func chunks(of updates: [RequestUpdate]) -> [Data] {
        updates.compactMap {
            if case .chunk(let data) = $0 { return data }
            return nil
        }
    }

    private func head(of updates: [RequestUpdate]) -> ResponseHead? {
        for update in updates {
            if case .head(let head) = update { return head }
        }
        return nil
    }

    private func finished(of updates: [RequestUpdate]) -> APIResponse? {
        for update in updates.reversed() {
            if case .finished(let response) = update { return response }
        }
        return nil
    }

    // MARK: - .head / .chunk / .finished

    func testStreamingEmitsHeadThenChunksThenFinished() throws {
        let payloads = [
            Data("data: one\n\n".utf8),
            Data("data: two\n\n".utf8),
            Data("event: done\ndata: bye\n\n".utf8)
        ]
        let server = try LocalHTTPServer(routes: [
            "/sse": .stream(chunks: payloads, interval: 0.05, contentType: "text/event-stream", closeAfterLast: true)
        ])
        defer { server.stop() }

        let executor = RequestExecutor(options: RequestExecutorOptions(timeout: 30))
        let (updates, error) = collect(
            executor.sendStreaming(APIRequest(name: "sse", method: .get, url: server.url("/sse")))
        )

        XCTAssertNil(error)
        guard let first = updates.first, case .head(let head) = first else {
            XCTFail("第一个更新必须是 .head，实际: \(String(describing: updates.first))")
            return
        }
        XCTAssertEqual(head.statusCode, 200)
        XCTAssertEqual(head.mimeType, "text/event-stream")
        XCTAssertTrue(head.isEventStream)
        XCTAssertEqual(head.headers.contains { $0.name.lowercased() == "content-type" }, true)

        XCTAssertEqual(updates.filter { if case .head = $0 { return true }; return false }.count, 1, "head 只发一次")

        let received = chunks(of: updates)
        XCTAssertGreaterThanOrEqual(received.count, 2, "分块路由应当产生多个 chunk")

        guard let response = finished(of: updates) else {
            XCTFail("缺少 .finished")
            return
        }
        let expected = payloads.reduce(Data(), +)
        XCTAssertEqual(response.body, expected, "finished 的 body 必须等于全部字节")
        XCTAssertEqual(received.reduce(Data(), +), expected, "chunk 之和必须等于 body")
        XCTAssertFalse(response.isBodyTruncated)
        XCTAssertEqual(response.statusCode, 200)

        // 终态必须是最后一个更新。
        if case .finished = updates.last! {} else {
            XCTFail("最后一条更新必须是 .finished")
        }
    }

    func testHeadReflectsFinalResponseAfterRedirect() throws {
        // 跟随重定向时中间会有 3xx 响应。`.head` 必须描述**最终**响应
        // （状态码 200、mime text/event-stream），否则调用方会拿 302 判断是否 SSE。
        let payload = Data("data: a\n\n".utf8)
        let server = try LocalHTTPServer(routes: [
            "/redirect": .redirect(to: "/final"),
            "/final": .stream(chunks: [payload], interval: 0, contentType: "text/event-stream", closeAfterLast: true)
        ])
        defer { server.stop() }

        let executor = RequestExecutor(options: RequestExecutorOptions(timeout: 30, followRedirects: true))
        let (updates, error) = collect(
            executor.sendStreaming(APIRequest(name: "r", method: .get, url: server.url("/redirect")))
        )

        XCTAssertNil(error)
        let heads = updates.compactMap { update -> ResponseHead? in
            if case .head(let head) = update { return head }
            return nil
        }
        XCTAssertEqual(heads.count, 1, "head 只发一次")
        XCTAssertEqual(heads.first?.statusCode, 200)
        XCTAssertTrue(heads.first?.isEventStream == true)
        XCTAssertEqual(heads.first?.finalURL?.path, "/final")
        XCTAssertEqual(finished(of: updates)?.body, payload)
    }

    func testHeadIsEmittedBeforeAnyChunk() throws {
        let server = try LocalHTTPServer(routes: [
            "/sse": .stream(chunks: [Data("data: a\n\n".utf8)], interval: 0, contentType: "text/event-stream", closeAfterLast: true)
        ])
        defer { server.stop() }

        let executor = RequestExecutor(options: RequestExecutorOptions(timeout: 30))
        let (updates, error) = collect(
            executor.sendStreaming(APIRequest(name: "sse", method: .get, url: server.url("/sse")))
        )
        XCTAssertNil(error)

        guard let chunkIndex = updates.firstIndex(where: { if case .chunk = $0 { return true }; return false }),
              let headIndex = updates.firstIndex(where: { if case .head = $0 { return true }; return false })
        else {
            XCTFail("应同时有 head 与 chunk")
            return
        }
        XCTAssertLessThan(headIndex, chunkIndex)
    }

    // MARK: - SSE 识别

    func testIsEventStreamDetection() {
        func head(mime: String?, headers: [HTTPHeader] = []) -> ResponseHead {
            ResponseHead(statusCode: 200, headers: headers, mimeType: mime, finalURL: nil)
        }

        XCTAssertTrue(head(mime: "text/event-stream").isEventStream)
        XCTAssertTrue(head(mime: "TEXT/EVENT-STREAM").isEventStream, "大小写不敏感")
        XCTAssertTrue(head(mime: "text/event-stream; charset=utf-8").isEventStream, "参数已去掉仍命中")
        XCTAssertTrue(
            head(mime: nil, headers: [HTTPHeader(name: "Content-Type", value: "text/event-stream; charset=utf-8")]).isEventStream,
            "mimeType 为空时回退解析 Content-Type 头"
        )
        XCTAssertFalse(head(mime: nil).isEventStream)
        XCTAssertFalse(head(mime: "application/json").isEventStream)
        XCTAssertFalse(head(mime: "text/plain", headers: [HTTPHeader(name: "Content-Type", value: "text/plain")]).isEventStream)
        XCTAssertFalse(
            head(mime: nil, headers: [HTTPHeader(name: "Content-Type", value: "text/event-streamish")]).isEventStream,
            "前缀相同但不是同一 MIME"
        )
    }

    // MARK: - 非 SSE 行为不变

    func testNonSSEChunkedResponseStillWorksThroughSend() throws {
        // 分块但非 SSE：send() 仍应拿到完整 body，且不因流式改造而改变。
        let payloads = [Data("hello ".utf8), Data("world".utf8)]
        let server = try LocalHTTPServer(routes: [
            "/text": .stream(chunks: payloads, interval: 0.02, contentType: "text/plain", closeAfterLast: true)
        ])
        defer { server.stop() }

        let executor = RequestExecutor(options: RequestExecutorOptions(timeout: 30))
        let sem = DispatchSemaphore(value: 0)
        var result: Result<APIResponse, Error>?
        Task {
            do { result = .success(try await executor.send(APIRequest(name: "t", method: .get, url: server.url("/text")))) }
            catch { result = .failure(error) }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 20)

        let response = try XCTUnwrap(result).get()
        XCTAssertEqual(response.body, payloads.reduce(Data(), +))
        XCTAssertFalse(response.isBodyTruncated)
    }

    // MARK: - 取消

    func testCancelDuringStreamingEndsWithCancelledAndKeepsReceivedChunks() throws {
        let chunk = Data("data: tick\n\n".utf8)
        let server = try LocalHTTPServer(routes: [
            "/endless": .stream(chunks: Array(repeating: chunk, count: 100), interval: 0.3, contentType: "text/event-stream", closeAfterLast: false)
        ])
        defer { server.stop() }

        let executor = RequestExecutor(options: RequestExecutorOptions(timeout: 120))
        let token = UUID()

        let box = UpdateBox()
        let done = DispatchSemaphore(value: 0)
        Task {
            do {
                for try await update in executor.sendStreaming(
                    APIRequest(name: "endless", method: .get, url: server.url("/endless")),
                    token: token
                ) {
                    box.append(update)
                }
            } catch {
                box.setError(error)
            }
            done.signal()
        }

        // 等到至少收到一个 chunk 再取消，否则取消的是"还没开始"的请求。
        let deadline = Date().addingTimeInterval(10)
        while box.chunkCount == 0 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertGreaterThan(box.chunkCount, 0, "取消前应已收到 chunk")
        XCTAssertEqual(executor.cancel(token: token), 1)

        XCTAssertEqual(done.wait(timeout: .now() + 10), .success)

        guard let error = box.error else {
            XCTFail("取消应以错误结束流")
            return
        }
        guard case RequestFailure.cancelled = error else {
            XCTFail("应为 .cancelled，实际: \(error)")
            return
        }
        XCTAssertGreaterThan(box.chunkCount, 0, "已收 chunk 必须保留")
        XCTAssertNotNil(box.head, "取消前已到达的 head 应保留")
        XCTAssertNil(box.finished, "取消不应产生 finished")
    }

    // MARK: - 截断

    func testStreamingOverLimitFinishesTruncatedNotFailed() throws {
        let cap = 2500
        let block = Data(repeating: 0x61, count: 1000)
        let server = try LocalHTTPServer(routes: [
            "/big": .stream(chunks: Array(repeating: block, count: 20), interval: 0, contentType: "text/event-stream", closeAfterLast: true)
        ])
        defer { server.stop() }

        let executor = RequestExecutor(options: RequestExecutorOptions(timeout: 60, maxResponseBytes: cap))
        let (updates, error) = collect(
            executor.sendStreaming(APIRequest(name: "big", method: .get, url: server.url("/big")))
        )

        XCTAssertNil(error, "截断不是错误")
        guard let response = finished(of: updates) else {
            XCTFail("截断路径也必须给出 .finished")
            return
        }
        XCTAssertTrue(response.isBodyTruncated)
        XCTAssertEqual(response.bodyLimitBytes, cap)
        XCTAssertLessThanOrEqual(response.body.count, cap)
        XCTAssertEqual(response.body.count, cap, "恰好收到上限字节")
        XCTAssertEqual(chunks(of: updates).reduce(Data(), +), response.body, "yield 的字节必须与 body 一致")
    }

    // MARK: - 超时语义

    func testIdleTimeoutStillFiresWhenServerGoesSilent() throws {
        // 服务端发一个 chunk 后保持连接沉默 30 秒，客户端 timeout: 1 → 空闲超时。
        let server = try LocalHTTPServer(routes: [
            "/silent": .stream(chunks: [Data("data: a\n\n".utf8)], interval: 0, contentType: "text/event-stream", closeAfterLast: false)
        ])
        defer { server.stop() }

        let executor = RequestExecutor(options: RequestExecutorOptions(timeout: 1))
        let started = Date()
        let (updates, error) = collect(
            executor.sendStreaming(APIRequest(name: "silent", method: .get, url: server.url("/silent"))),
            timeout: 15
        )
        let elapsed = Date().timeIntervalSince(started)

        guard let error else {
            XCTFail("应当超时")
            return
        }
        guard case RequestFailure.transport(let underlying) = error else {
            XCTFail("应为 .transport，实际: \(error)")
            return
        }
        XCTAssertEqual((underlying as NSError).code, NSURLErrorTimedOut)
        XCTAssertLessThan(elapsed, 10, "空闲超时应按 options.timeout 生效，不是 300 秒")
        XCTAssertNotNil(head(of: updates), "超时前已收到的 head 应保留")
    }

    func testResourceTimeoutIsNotCapped() {
        // 旧实现是 `max(timeout, 300)`：任何超过 300 秒的响应都会被硬切。
        // 现在不设 timeoutIntervalForResource，保持 URLSession 默认（7 天）。
        for timeout in [1.0, 30.0, 600.0] {
            let executor = RequestExecutor(options: RequestExecutorOptions(timeout: timeout))
            defer { executor.invalidate() }

            XCTAssertEqual(executor.idleTimeout, timeout, "空闲超时仍等于设置值")
            XCTAssertTrue(executor.resourceTimeoutIsUnlimited)
            XCTAssertEqual(
                executor.sessionConfiguration.timeoutIntervalForResource,
                RequestExecutor.defaultResourceTimeout,
                "资源总时长必须回到默认值，不能再是 max(timeout, 300)"
            )
            XCTAssertGreaterThan(executor.sessionConfiguration.timeoutIntervalForResource, 300)
        }
    }

    func testStreamLongerThanOldResourceCapKeepsReceiving() throws {
        // 直接证明"没有总时长上限"：用 2 秒 timeout 的配置收一条跨 3 个静默间隔的流。
        // 旧实现在这里不会失败（300 秒没到），但它同时验证了空闲计时器在每次收到数据后重置，
        // 即"持续有数据就不会被总时长/空闲超时掐断"。
        let payloads = [
            Data("data: 1\n\n".utf8),
            Data("data: 2\n\n".utf8),
            Data("data: 3\n\n".utf8)
        ]
        let server = try LocalHTTPServer(routes: [
            "/paced": .stream(chunks: payloads, interval: 0.8, contentType: "text/event-stream", closeAfterLast: true)
        ])
        defer { server.stop() }

        let executor = RequestExecutor(options: RequestExecutorOptions(timeout: 2))
        let (updates, error) = collect(
            executor.sendStreaming(APIRequest(name: "paced", method: .get, url: server.url("/paced"))),
            timeout: 20
        )

        XCTAssertNil(error, "每 0.8 秒有数据，2 秒空闲超时不应触发")
        XCTAssertEqual(chunks(of: updates).count, 3)
        XCTAssertEqual(finished(of: updates)?.body, payloads.reduce(Data(), +))
    }
}

/// 线程安全的更新收集盒（delegate 与测试线程都会碰）。
private final class UpdateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [RequestUpdate] = []
    private var failure: Error?

    func append(_ update: RequestUpdate) {
        lock.lock()
        updates.append(update)
        lock.unlock()
    }

    func setError(_ error: Error) {
        lock.lock()
        failure = error
        lock.unlock()
    }

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    var chunkCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return updates.reduce(0) { count, update in
            if case .chunk = update { return count + 1 }
            return count
        }
    }

    var head: ResponseHead? {
        lock.lock()
        defer { lock.unlock() }
        for update in updates {
            if case .head(let head) = update { return head }
        }
        return nil
    }

    var finished: APIResponse? {
        lock.lock()
        defer { lock.unlock() }
        for update in updates.reversed() {
            if case .finished(let response) = update { return response }
        }
        return nil
    }
}
