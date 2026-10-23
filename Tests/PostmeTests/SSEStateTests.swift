import XCTest
@testable import Postme

/// 流式状态机（AC3）：AppState 消费 `sendStreaming` 后的页签状态、节流发布、
/// 事件环形上限、分页可用性、多页签隔离。
///
/// 全部走真实本地 socket：要验证的正是「delegate 什么时候给什么」，
/// 用假流替换掉它，就等于自己证明自己。
@MainActor
final class SSEStateTests: XCTestCase {

    private func makeApp() -> (AppState, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("postme-sse-state-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = AppState(
            persistence: PersistenceService(fileName: "workspace.json", directory: dir),
            languageOverride: .zhHans
        )
        return (app, dir)
    }

    private func sseChunks(_ events: [String]) -> [Data] {
        events.map { Data(("data: \($0)\n\n").utf8) }
    }

    /// 等到条件成立或超时（轮询主线程状态，不依赖固定 sleep 猜时序）。
    private func waitUntil(
        _ timeout: TimeInterval = 10,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - 进入流式

    func testSSEResponseEntersStreamingAndSwitchesToEventsTab() async throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let chunks = sseChunks(["a", "b", "c"])
        let server = try LocalHTTPServer(routes: [
            "/sse": .stream(chunks: chunks, interval: 0.25, contentType: "text/event-stream", closeAfterLast: true)
        ])
        defer { server.stop() }

        app.draft = APIRequest(name: "sse", url: server.url("/sse"))
        let send = Task { await app.send() }

        // 流式期间（还没结束）就该看到 .streaming 与事件分页。
        await waitUntil { app.activeTab.stream.status == .streaming && !app.activeTab.stream.events.isEmpty }
        XCTAssertEqual(app.activeTab.stream.status, .streaming)
        XCTAssertEqual(app.responseSection, .events, "SSE 响应到达后应切到事件分页")
        XCTAssertTrue(app.availableResponseSections.contains(.events))
        XCTAssertTrue(app.availableResponseSections.contains(.llm))
        XCTAssertTrue(app.isSending)

        let countDuringStream = app.activeTab.stream.events.count
        XCTAssertGreaterThan(countDuringStream, 0, "事件数应随流增长")

        await send.value
        XCTAssertEqual(app.activeTab.stream.status, .closed)
        XCTAssertEqual(app.activeTab.stream.events.map(\.data), ["a", "b", "c"])
        XCTAssertFalse(app.isSending)
    }

    func testResponseTabOrderIsBodyLLMEventsHeadersTiming() {
        XCTAssertEqual(ResponseSection.allCases, [.body, .llm, .events, .headers, .timing])
    }

    func testAvailableResponseSectionsOmitsEventsForNonSSE() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(app.availableResponseSections, [.body, .headers, .timing])
        XCTAssertEqual(ResponseSection.events.title(.zhHans), "事件")
        XCTAssertEqual(ResponseSection.events.title(.en), "Events")
    }

    // MARK: - 正常结束

    func testNormalCloseSetsClosedResponseAndRecordsHistory() async throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let chunks = sseChunks(["one", "two"])
        let server = try LocalHTTPServer(routes: [
            "/sse": .stream(chunks: chunks, interval: 0, contentType: "text/event-stream", closeAfterLast: true)
        ])
        defer { server.stop() }

        let historyBefore = app.history.count
        app.draft = APIRequest(name: "sse", url: server.url("/sse"))
        await app.send()

        XCTAssertEqual(app.activeTab.stream.status, .closed)
        XCTAssertNotNil(app.response)
        XCTAssertEqual(app.response?.body, chunks.reduce(Data(), +), "body 必须是全部字节")
        XCTAssertFalse(app.isSending)
        XCTAssertNil(app.errorMessage)
        XCTAssertEqual(app.history.count, historyBefore + 1, "正常结束记一条历史")
        XCTAssertEqual(app.activeTab.stream.receivedBytes, chunks.reduce(0) { $0 + $1.count })
        XCTAssertEqual(app.responseSection, .events)
    }

    func testRawTextAndByteCountMatchReceivedBytes() async throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let chunks = sseChunks(["alpha", "beta"])
        let server = try LocalHTTPServer(routes: [
            "/sse": .stream(chunks: chunks, interval: 0, contentType: "text/event-stream", closeAfterLast: true)
        ])
        defer { server.stop() }

        app.draft = APIRequest(name: "sse", url: server.url("/sse"))
        await app.send()

        let expected = chunks.reduce(Data(), +)
        XCTAssertEqual(app.activeTab.stream.receivedBytes, expected.count)
        XCTAssertEqual(app.activeTab.stream.rawText, String(decoding: expected, as: UTF8.self))
    }

    // MARK: - 取消

    func testCancelKeepsEventsAndDoesNotRecordHistory() async throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let chunk = Data("data: tick\n\n".utf8)
        let server = try LocalHTTPServer(routes: [
            "/endless": .stream(
                chunks: Array(repeating: chunk, count: 200),
                interval: 0.2,
                contentType: "text/event-stream",
                closeAfterLast: false
            )
        ])
        defer { server.stop() }

        let historyBefore = app.history.count
        app.draft = APIRequest(name: "endless", url: server.url("/endless"))
        let send = Task { await app.send() }

        await waitUntil { !app.activeTab.stream.events.isEmpty }
        XCTAssertGreaterThan(app.activeTab.stream.events.count, 0)
        app.cancelSend()
        await send.value

        XCTAssertEqual(app.activeTab.stream.status, .cancelled)
        XCTAssertGreaterThan(app.activeTab.stream.events.count, 0, "取消后事件必须保留")
        XCTAssertNil(app.errorMessage, "取消不是失败")
        XCTAssertEqual(app.history.count, historyBefore, "取消不记历史")
        XCTAssertFalse(app.isSending)
    }

    func testCancelDispatchesUnterminatedTailEvent() async throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 最后一块不带空行收尾：取消时 finish() 应把它派发出来并标 isUnterminated。
        let server = try LocalHTTPServer(routes: [
            "/tail": .stream(
                chunks: [Data("data: complete\n\n".utf8), Data("data: dangling\n".utf8)],
                interval: 0.2,
                contentType: "text/event-stream",
                closeAfterLast: false
            )
        ])
        defer { server.stop() }

        app.draft = APIRequest(name: "tail", url: server.url("/tail"))
        let send = Task { await app.send() }

        await waitUntil { app.activeTab.stream.events.contains { $0.data == "complete" } }
        // 第二块（未以空行收尾的 `data: dangling`）要等 0.2 秒才到；此时它已在
        // 解析器的行缓冲里但**尚未派发**——正是要验证的状态。
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(app.activeTab.stream.events.contains { $0.data == "dangling" },
                       "未收尾事件在流关闭前不应派发")
        app.cancelSend()
        await send.value

        XCTAssertEqual(app.activeTab.stream.status, .cancelled)
        let dangling = app.activeTab.stream.events.first { $0.data == "dangling" }
        XCTAssertNotNil(dangling, "未收尾事件必须被派发")
        XCTAssertEqual(dangling?.isUnterminated, true)
    }

    // MARK: - 传输中断

    func testTransportFailureKeepsEventsAndRecordsFailedHistory() async throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 服务端发两块后保持沉默且不关连接，客户端 timeout 1 秒 → 传输中断。
        let server = try LocalHTTPServer(routes: [
            "/cut": .stream(
                chunks: [Data("data: first\n\n".utf8), Data("data: second\n".utf8)],
                interval: 0,
                contentType: "text/event-stream",
                closeAfterLast: false
            )
        ])
        defer { server.stop() }

        let historyBefore = app.history.count
        app.draft = APIRequest(name: "cut", url: server.url("/cut"))
        var settings = app.workspace.settings
        settings.timeout = 1
        app.updateSettings(settings)
        await app.send()

        guard case .failed = app.activeTab.stream.status else {
            XCTFail("应为 .failed，实际: \(app.activeTab.stream.status)")
            return
        }
        XCTAssertGreaterThan(app.activeTab.stream.events.count, 0, "中断后事件必须保留")
        XCTAssertNotNil(app.errorMessage)
        XCTAssertEqual(app.history.count, historyBefore + 1, "中断记一条失败历史")
        XCTAssertEqual(app.history.first?.succeeded, false)
        XCTAssertFalse(app.isSending)
    }

    // MARK: - 事件环形上限

    func testEventRingBufferDropsOldestAndKeepsSequenceContiguous() async throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 2500 个事件。分 5 块推，覆盖跨 chunk 的编号连续性。
        let total = 2500
        var chunks: [Data] = []
        var buffer = ""
        for index in 1...total {
            buffer += "data: e\(index)\n\n"
            if index % 500 == 0 {
                chunks.append(Data(buffer.utf8))
                buffer = ""
            }
        }
        let server = try LocalHTTPServer(routes: [
            "/many": .stream(chunks: chunks, interval: 0, contentType: "text/event-stream", closeAfterLast: true)
        ])
        defer { server.stop() }

        app.draft = APIRequest(name: "many", url: server.url("/many"))
        await app.send()

        let stream = app.activeTab.stream
        XCTAssertEqual(stream.status, .closed)
        XCTAssertEqual(stream.events.count, StreamState.maxRetainedEvents)
        XCTAssertEqual(stream.droppedEventCount, total - StreamState.maxRetainedEvents)

        // 保留的是**最新**的 2000 条，编号连续。
        XCTAssertEqual(stream.events.first?.data, "e\(total - StreamState.maxRetainedEvents + 1)")
        XCTAssertEqual(stream.events.last?.data, "e\(total)")
        let sequences = stream.events.map(\.sequence)
        XCTAssertEqual(sequences, Array(sequences.first!...(sequences.first! + StreamState.maxRetainedEvents - 1)),
                       "sequence 必须连续递增，丢弃旧事件不重编号")
    }

    // MARK: - 多页签隔离

    func testEventsDoNotLeakAcrossTabs() async throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let server = try LocalHTTPServer(routes: [
            "/sse": .stream(
                chunks: sseChunks(["s1", "s2", "s3", "s4"]),
                interval: 0.3,
                contentType: "text/event-stream",
                closeAfterLast: true
            ),
            "/plain": .fixed(Data("plain-body".utf8), contentType: "text/plain")
        ])
        defer { server.stop() }

        let sseTab = app.activeTabID
        app.draft = APIRequest(name: "sse", url: server.url("/sse"))
        let sseSend = Task { await app.send() }

        await waitUntil { !app.activeTab.stream.events.isEmpty }

        // A 还在流式，切到 B 发普通请求。
        app.newRequest()
        let plainTab = app.activeTabID
        app.draft = APIRequest(name: "plain", url: server.url("/plain"))
        await app.send()

        XCTAssertEqual(app.tabs.first { $0.id == plainTab }?.responseBodyText, "plain-body")
        XCTAssertTrue(app.tabs.first { $0.id == plainTab }?.stream.events.isEmpty ?? false,
                      "普通请求不该收到事件")
        XCTAssertEqual(app.tabs.first { $0.id == plainTab }?.responseSection, .body)

        await sseSend.value

        let sseState = app.tabs.first { $0.id == sseTab }!
        XCTAssertEqual(sseState.stream.status, .closed)
        XCTAssertEqual(sseState.stream.events.map(\.data), ["s1", "s2", "s3", "s4"],
                       "事件只能落在发起它的那一格")
        XCTAssertEqual(sseState.responseSection, .events)

        // B 页签在 A 结束后仍是干净的普通响应。
        XCTAssertEqual(app.tabs.first { $0.id == plainTab }?.responseBodyText, "plain-body")
        XCTAssertFalse(app.tabs.first { $0.id == plainTab }?.stream.isEventStream ?? true)
    }

    // MARK: - 非 SSE 不产生事件

    func testNonSSEResponseProducesNoEventsAndStaysOnBodyTab() async throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let payload = Data(#"{"ok":true}"#.utf8)
        let server = try LocalHTTPServer(routes: [
            "/json": .fixed(payload, contentType: "application/json")
        ])
        defer { server.stop() }

        app.draft = APIRequest(name: "json", url: server.url("/json"))
        await app.send()

        XCTAssertEqual(app.activeTab.stream.events.count, 0)
        XCTAssertFalse(app.activeTab.stream.isEventStream)
        XCTAssertEqual(app.responseSection, .body, "非 SSE 分页停在 body")
        XCTAssertEqual(app.availableResponseSections, [.body, .headers, .timing])
        XCTAssertEqual(app.response?.body, payload)
    }

    func testNonSSEAfterSSEResetsEventsTab() async throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let server = try LocalHTTPServer(routes: [
            "/sse": .stream(chunks: sseChunks(["x"]), interval: 0, contentType: "text/event-stream", closeAfterLast: true),
            "/json": .fixed(Data(#"{"a":1}"#.utf8), contentType: "application/json")
        ])
        defer { server.stop() }

        app.draft = APIRequest(name: "sse", url: server.url("/sse"))
        await app.send()
        XCTAssertEqual(app.responseSection, .events)

        // 用户停在事件分页时又发了非 SSE 请求：分页必须复位，事件必须清空。
        app.draft = APIRequest(name: "json", url: server.url("/json"))
        await app.send()

        XCTAssertEqual(app.responseSection, .body)
        XCTAssertTrue(app.activeTab.stream.events.isEmpty)
        XCTAssertFalse(app.activeTab.stream.isEventStream)
        XCTAssertEqual(app.availableResponseSections, [.body, .headers, .timing])
    }

    // MARK: - clearResponse

    func testClearResponseWipesStreamAndResetsTab() async throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let server = try LocalHTTPServer(routes: [
            "/sse": .stream(chunks: sseChunks(["a"]), interval: 0, contentType: "text/event-stream", closeAfterLast: true)
        ])
        defer { server.stop() }

        app.draft = APIRequest(name: "sse", url: server.url("/sse"))
        await app.send()
        XCTAssertFalse(app.activeTab.stream.events.isEmpty)

        app.clearResponse()

        XCTAssertTrue(app.activeTab.stream.events.isEmpty)
        XCTAssertFalse(app.activeTab.stream.isEventStream)
        XCTAssertNil(app.response)
        XCTAssertEqual(app.responseSection, .body)
    }

    // MARK: - 节流发布不丢内容

    func testThrottledPublishingKeepsEveryEventAndByte() async throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 50 个事件挤在极短时间内推送：会被节流窗口合并，但一条都不能丢。
        let names = (1...50).map { "v\($0)" }
        let chunks = sseChunks(names)
        let server = try LocalHTTPServer(routes: [
            "/burst": .stream(chunks: chunks, interval: 0, contentType: "text/event-stream", closeAfterLast: true)
        ])
        defer { server.stop() }

        app.draft = APIRequest(name: "burst", url: server.url("/burst"))
        await app.send()

        XCTAssertEqual(app.activeTab.stream.events.map(\.data), names,
                       "节流只合并发布，不丢事件")
        XCTAssertEqual(
            app.activeTab.stream.receivedBytes,
            chunks.reduce(0) { $0 + $1.count },
            "字节计数不受节流影响"
        )
    }
}
