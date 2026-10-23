import XCTest
import Foundation
@testable import Postme

/// T3 阻断项修复的回归用例（B1 / B2）。
///
/// B1：取消/中断后的状态栏必须描述**本次流**，不能出现「接收中」、不能回退到旧 response，
///     且 `.failed(message)` 的消息要在界面上读得到。
/// B2：非 SSE 响应在传输期间零状态写入；`rawText` 跨 chunk 解码不得产生 U+FFFD。
@MainActor
final class SSETerminalDisplayTests: XCTestCase {

    private func makeApp() -> (AppState, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("postme-sse-terminal-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = AppState(
            persistence: PersistenceService(fileName: "workspace.json", directory: dir),
            languageOverride: .zhHans
        )
        return (app, dir)
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func presentation(
        _ app: AppState,
        l10n: Localizer = .zhHans,
        response: APIResponse? = nil
    ) -> ResponseStatusPresentation {
        ResponseStatusPresenter.present(
            stream: app.activeTab.stream,
            response: response,
            isSending: app.isSending,
            l10n: l10n
        )
    }

    private func makeResponse(status: Int, bodyBytes: Int, total: TimeInterval) -> APIResponse {
        APIResponse(
            statusCode: status,
            headers: [],
            body: Data(repeating: 0x61, count: bodyBytes),
            mimeType: "text/plain",
            timing: RequestTiming(total: total)
        )
    }

    // MARK: - B1：取消后的状态栏

    func testCancelledStreamShowsCancelledNotReceiving() async throws {
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

        app.draft = APIRequest(name: "endless", url: server.url("/endless"))
        let send = Task { await app.send() }
        await waitUntil { !app.activeTab.stream.events.isEmpty }
        app.cancelSend()
        await send.value

        XCTAssertEqual(app.activeTab.stream.status, .cancelled)
        let view = presentation(app)

        XCTAssertEqual(view.streamStatus, "已取消", "终态标签必须是「已取消」")
        XCTAssertNotEqual(view.streamStatus, "接收中")
        XCTAssertFalse(view.isReceiving, "取消后不得再显示「接收中」")
        XCTAssertFalse(view.showsLiveDuration, "取消后不应继续走实时计时")
        XCTAssertFalse(view.badgeText == "接收中", "徽标不得是「接收中」: \(view.badgeText ?? "nil")")
        XCTAssertNil(view.failureMessage, "取消不是失败，不该有失败消息")

        // 本次流的字节数与实际耗时可见。
        XCTAssertNotNil(view.receivedBytesText, "取消后仍应显示已收字节数")
        XCTAssertNotNil(view.durationText, "取消后应显示本次流的实际耗时")
        XCTAssertEqual(view.receivedBytesText, formatBytes(app.activeTab.stream.receivedBytes))
    }

    func testCancelledStreamDoesNotShowStaleResponse() async throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 先完成一次普通请求，页签里留下旧 response（状态码 201、耗时 9.5s、body 4096 字节）。
        let server = try LocalHTTPServer(routes: [
            "/plain": .fixed(Data(repeating: 0x62, count: 4096), contentType: "text/plain"),
            "/endless": .stream(
                chunks: Array(repeating: Data("data: x\n\n".utf8), count: 200),
                interval: 0.2,
                contentType: "text/event-stream",
                closeAfterLast: false
            )
        ])
        defer { server.stop() }

        app.draft = APIRequest(name: "plain", url: server.url("/plain"))
        await app.send()
        let stale = try XCTUnwrap(app.response)
        XCTAssertEqual(stale.statusCode, 200)

        // 再发一条会被取消的 SSE 流。
        app.draft = APIRequest(name: "endless", url: server.url("/endless"))
        let send = Task { await app.send() }
        await waitUntil { !app.activeTab.stream.events.isEmpty }
        app.cancelSend()
        await send.value

        XCTAssertEqual(app.activeTab.stream.status, .cancelled)
        // 视图层此时必须忽略旧 response —— 用一个"明显不同"的旧响应把混淆钉死。
        let oldResponse = makeResponse(status: 201, bodyBytes: 4096, total: 9.5)
        let view = presentation(app, response: oldResponse)

        XCTAssertNotEqual(view.badgeText, "201", "不得展示旧请求的状态码")
        XCTAssertNotEqual(view.durationText, formatMillis(9.5), "不得展示旧请求的耗时")
        XCTAssertNotEqual(view.receivedBytesText, formatBytes(4096), "不得展示旧请求的字节数")
        XCTAssertEqual(view.receivedBytesText, formatBytes(app.activeTab.stream.receivedBytes))
        XCTAssertEqual(view.streamStatus, "已取消")
        XCTAssertFalse(view.isReceiving)
    }

    // MARK: - B1：中断后的状态栏与失败原因

    func testFailedStreamShowsLocalizedFailureMessage() async throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let server = try LocalHTTPServer(routes: [
            "/cut": .stream(
                chunks: [Data("data: first\n\n".utf8), Data("data: second\n".utf8)],
                interval: 0,
                contentType: "text/event-stream",
                closeAfterLast: false
            )
        ])
        defer { server.stop() }

        var settings = app.workspace.settings
        settings.timeout = 1
        app.updateSettings(settings)

        app.draft = APIRequest(name: "cut", url: server.url("/cut"))
        await app.send()

        guard case .failed(let message) = app.activeTab.stream.status else {
            XCTFail("应为 .failed，实际: \(app.activeTab.stream.status)")
            return
        }
        XCTAssertFalse(message.isEmpty)

        let zh = presentation(app, l10n: .zhHans)
        XCTAssertEqual(zh.streamStatus, "已中断")
        XCTAssertEqual(zh.failureMessage, message, "失败原因必须在可见文案里，不能只留通用标签")
        XCTAssertFalse(zh.isReceiving, "中断后不得显示「接收中」")
        XCTAssertNotEqual(zh.badgeText, "接收中")

        // 英文界面用同一份已本地化消息（消息来自系统 localizedDescription，跟着系统语言走）。
        let en = presentation(app, l10n: .en)
        XCTAssertEqual(en.streamStatus, "Interrupted")
        XCTAssertEqual(en.failureMessage, message)
    }

    func testFailureMessageIsSurfacedEvenWithRetainedEvents() async throws {
        // 审查原文：`errorMessage` 被 `!hasStreamContent` 挡死，只要保留了一个事件
        // 用户就永远看不到失败原因。这里钉住「有事件也必须能看到 message」。
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let server = try LocalHTTPServer(routes: [
            "/cut": .stream(
                chunks: [Data("data: kept\n\n".utf8)],
                interval: 0,
                contentType: "text/event-stream",
                closeAfterLast: false
            )
        ])
        defer { server.stop() }

        var settings = app.workspace.settings
        settings.timeout = 1
        app.updateSettings(settings)

        app.draft = APIRequest(name: "cut", url: server.url("/cut"))
        await app.send()

        XCTAssertGreaterThan(app.activeTab.stream.events.count, 0, "应该保留已收到的事件")
        XCTAssertNotNil(app.errorMessage)
        let view = presentation(app)
        XCTAssertNotNil(view.failureMessage, "有事件时失败原因仍必须可见")
        // 事件内容与事件计数同样保留。
        XCTAssertEqual(view.eventCountText, "事件: \(app.activeTab.stream.events.count)")
    }

    // MARK: - B1：非 SSE 在途窗口的「接收中」

    func testNonSSEInFlightShowsReceivingWithoutLoadingSpinner() throws {
        // 非 SSE 在途：response 已有旧值、isSending 为真 → 状态栏必须给出「接收中」。
        // 旧实现里这条路径永远到不了（else 分支只对 SSE 终态可达）。
        let (_, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let oldResponse = makeResponse(status: 200, bodyBytes: 512, total: 0.25)
        let stream = StreamState()  // 非 SSE：isEventStream == false

        let inFlight = ResponseStatusPresenter.present(
            stream: stream,
            response: oldResponse,
            isSending: true,
            l10n: .zhHans
        )
        XCTAssertTrue(inFlight.isReceiving, "非 SSE 在途必须有接收指示")
        XCTAssertTrue(
            inFlight.badgeText == "接收中" || inFlight.isReceiving,
            "接收中必须由状态栏可见元素表达: \(inFlight)"
        )
        XCTAssertFalse(inFlight.showsLiveDuration, "非 SSE 不走实时流式计时")

        // 完成之后：接收指示消失，回到正常的状态码/耗时/字节。
        let done = ResponseStatusPresenter.present(
            stream: stream,
            response: oldResponse,
            isSending: false,
            l10n: .zhHans
        )
        XCTAssertFalse(done.isReceiving)
        XCTAssertEqual(done.badgeText, "200")
        XCTAssertEqual(done.receivedBytesText, formatBytes(512))
        XCTAssertEqual(done.durationText, formatMillis(0.25))
        XCTAssertNil(done.streamStatus, "非 SSE 不该出现流式状态标签")

        // 全新页签（无 response、在途）：进度圈接管，状态栏不参与。
        let fresh = ResponseStatusPresenter.present(
            stream: StreamState(),
            response: nil,
            isSending: true,
            l10n: .zhHans
        )
        XCTAssertTrue(fresh.isReceiving)
        XCTAssertNil(fresh.receivedBytesText)
        XCTAssertNil(fresh.durationText)
    }

    func testClosedStreamShowsClosedWithItsOwnDuration() throws {
        // 正常结束：状态来自本次流（closed），字节/耗时取本次流，而不是 response.timing 之外的东西。
        var stream = StreamState()
        stream.isEventStream = true
        stream.status = .closed
        stream.startedAt = Date().addingTimeInterval(-1.5)
        stream.endedAt = Date()
        stream.receivedBytes = 128
        stream.events = [SSEEvent(sequence: 1, data: "a")]

        let view = ResponseStatusPresenter.present(
            stream: stream,
            response: makeResponse(status: 200, bodyBytes: 128, total: 1.5),
            isSending: false,
            l10n: .zhHans
        )
        XCTAssertEqual(view.streamStatus, "已结束")
        XCTAssertEqual(view.badgeText, "200")
        XCTAssertEqual(view.receivedBytesText, formatBytes(128))
        XCTAssertEqual(view.eventCountText, "事件: 1")
        XCTAssertFalse(view.isReceiving)
        XCTAssertNil(view.failureMessage)
    }

    func testStreamingShowsReceivingAndLiveDuration() throws {
        var stream = StreamState()
        stream.isEventStream = true
        stream.status = .streaming
        stream.startedAt = Date()
        stream.receivedBytes = 64
        stream.events = [SSEEvent(sequence: 1, data: "a")]

        let view = ResponseStatusPresenter.present(
            stream: stream,
            response: nil,
            isSending: true,
            l10n: .zhHans
        )
        XCTAssertEqual(view.streamStatus, "接收中")
        XCTAssertTrue(view.isReceiving)
        XCTAssertTrue(view.showsLiveDuration)
        XCTAssertEqual(view.receivedBytesText, formatBytes(64))
        XCTAssertNil(view.durationText, "流式期间由 TimelineView 计时，不走静态耗时")
    }

    func testPresentationFollowsBothLanguages() throws {
        var failed = StreamState()
        failed.isEventStream = true
        failed.status = .failed("The request timed out.")
        failed.startedAt = Date().addingTimeInterval(-2)
        failed.endedAt = Date()

        let zh = ResponseStatusPresenter.present(stream: failed, response: nil, isSending: false, l10n: .zhHans)
        let en = ResponseStatusPresenter.present(stream: failed, response: nil, isSending: false, l10n: .en)
        XCTAssertEqual(zh.streamStatus, "已中断")
        XCTAssertEqual(en.streamStatus, "Interrupted")
        XCTAssertFalse(zh.streamStatus?.contains("Interrupted") ?? true, "中文界面不得泄漏英文标签")

        var cancelled = failed
        cancelled.status = .cancelled
        XCTAssertEqual(
            ResponseStatusPresenter.present(stream: cancelled, response: nil, isSending: false, l10n: .zhHans).streamStatus,
            "已取消"
        )
        XCTAssertEqual(
            ResponseStatusPresenter.present(stream: cancelled, response: nil, isSending: false, l10n: .en).streamStatus,
            "Cancelled"
        )
    }

    // MARK: - B2：非 SSE 零状态写入

    func testNonSSETransportWritesNothingToStream() async throws {
        let (app, dir) = makeApp()
        defer { TraceFileManager.remove(at: dir) }

        // 分块的非 SSE 响应：会走过多次 `.chunk`，每次都必须被丢弃。
        let payloads = (0..<8).map { Data("block-\($0);".utf8) }
        let server = try LocalHTTPServer(routes: [
            "/text": .stream(chunks: payloads, interval: 0.05, contentType: "text/plain", closeAfterLast: true)
        ])
        defer { server.stop() }

        app.draft = APIRequest(name: "text", url: server.url("/text"))
        await app.send()

        let stream = app.activeTab.stream
        XCTAssertFalse(stream.isEventStream)
        XCTAssertTrue(stream.events.isEmpty, "非 SSE 不得产生事件")
        XCTAssertEqual(stream.receivedBytes, 0, "非 SSE 不得累计流字节")
        XCTAssertTrue(stream.rawText.isEmpty, "非 SSE 不得累积 rawText")
        XCTAssertEqual(stream.status, .idle, "非 SSE 不得进入流式状态机")
        XCTAssertEqual(stream.droppedEventCount, 0)
        XCTAssertNil(stream.endedAt)

        // 响应本身仍然完整（分流不能把正文弄丢）。
        XCTAssertEqual(app.response?.body, payloads.reduce(Data(), +))
        XCTAssertEqual(app.responseSection, .body)
    }

    func testNonSSEChunkedResponseLeavesStreamUntouchedDuringTransfer() async throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 慢速分块：传输期间多次采样，`stream` 必须始终是初值。
        let payloads = (0..<10).map { Data("chunk-\($0)".utf8) }
        let server = try LocalHTTPServer(routes: [
            "/slow": .stream(chunks: payloads, interval: 0.15, contentType: "application/json", closeAfterLast: true)
        ])
        defer { server.stop() }

        app.draft = APIRequest(name: "slow", url: server.url("/slow"))
        let send = Task { await app.send() }

        // 先等请求真的发出去：Task 刚创建时 isSending 还是 false，
        // 直接进采样循环会一次都不采就退出（测了个寂寞）。
        await waitUntil { app.isSending }

        var samples = 0
        var violated: [String] = []
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, app.isSending {
            let stream = app.activeTab.stream
            if stream.isEventStream || !stream.events.isEmpty || stream.receivedBytes != 0 || !stream.rawText.isEmpty {
                violated.append("events=\(stream.events.count) bytes=\(stream.receivedBytes) raw=\(stream.rawText.count)")
            }
            samples += 1
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        await send.value

        XCTAssertGreaterThan(samples, 3, "采样次数太少，测不到传输期间的状态")
        XCTAssertTrue(violated.isEmpty, "非 SSE 传输期间发生了状态写入: \(violated.prefix(3))")
    }

    // MARK: - B2：rawText 跨 chunk 解码

    func testUTF8DecoderHoldsSplitMultiByteSequences() {
        var decoder = UTF8StreamDecoder()
        let text = "第一条事件 😀 中文"
        let bytes = Array(text.utf8)

        // 逐字节喂：任何一次"按 chunk 解码"的实现都会产出 U+FFFD。
        var rebuilt = ""
        for byte in bytes {
            rebuilt += decoder.consume(Data([byte]))
        }
        rebuilt += decoder.finish()

        XCTAssertEqual(rebuilt, text)
        XCTAssertFalse(rebuilt.contains("\u{FFFD}"))
    }

    func testUTF8DecoderHandlesEverySplitPoint() {
        let text = "aé中😀z"
        let bytes = Array(text.utf8)
        let expected = String(decoding: bytes, as: UTF8.self)

        for cut in 1..<bytes.count {
            var decoder = UTF8StreamDecoder()
            var rebuilt = decoder.consume(Data(bytes[0..<cut]))
            rebuilt += decoder.consume(Data(bytes[cut...]))
            rebuilt += decoder.finish()
            XCTAssertEqual(rebuilt, expected, "切点 \(cut) 处解码错误: \(rebuilt)")
            XCTAssertFalse(rebuilt.contains("\u{FFFD}"), "切点 \(cut) 产生替换字符")
        }
    }

    func testUTF8DecoderDefersIncompleteTail() {
        let text = "中"
        let bytes = Array(text.utf8)
        var decoder = UTF8StreamDecoder()

        XCTAssertEqual(decoder.consume(Data(bytes[0..<1])), "", "半个字符不该提前解码")
        XCTAssertEqual(decoder.consume(Data(bytes[1..<2])), "", "仍不完整")
        XCTAssertEqual(decoder.consume(Data(bytes[2..<3])), text, "凑齐后才输出")
        XCTAssertEqual(decoder.finish(), "")
    }

    func testUTF8DecoderRecoversFromTruncatedTail() {
        // 流停在一个字符中间：finish() 必须把残留交出来（只能按替换字符解码，
        // 但那是流真的缺字节，不是解码器切错边界）。
        var decoder = UTF8StreamDecoder()
        _ = decoder.consume(Data(Array("ok".utf8)))
        _ = decoder.consume(Data([0xE4, 0xB8]))
        XCTAssertEqual(decoder.finish(), "\u{FFFD}")
    }

    func testStreamRawTextHasNoReplacementCharacterWhenChunkSplitsMultibyte() async throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 一个事件的数据里放多字节字符，并且把这块字节**人为切在字符中间**。
        let full = Data("data: 你好世界😀\n\n".utf8)
        let cut = 8  // "data: " 之后切进 "你" 的多字节序列中间
        let server = try LocalHTTPServer(routes: [
            "/sse": .stream(
                chunks: [full.prefix(cut), full.dropFirst(cut)],
                interval: 0.05,
                contentType: "text/event-stream",
                closeAfterLast: true
            )
        ])
        defer { server.stop() }

        app.draft = APIRequest(name: "sse", url: server.url("/sse"))
        await app.send()

        let stream = app.activeTab.stream
        XCTAssertFalse(stream.rawText.contains("\u{FFFD}"), "rawText 出现替换字符: \(stream.rawText)")
        XCTAssertEqual(stream.rawText, String(decoding: full, as: UTF8.self))
        XCTAssertEqual(stream.events.map(\.data), ["你好世界😀"])
        XCTAssertEqual(stream.receivedBytes, full.count)
    }
}

/// 清临时目录的小工具（避免 `defer` 里重复写 FileManager）。
private enum TraceFileManager {
    static func remove(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
