import XCTest
@testable import Postme

/// 「大模型输出」的接线与分页（AC4）。
///
/// 全部走真实本地 socket + 真实 `AppState.send()`：要验证的正是「归并结果有没有
/// 和事件一起落到页签状态里」，用假流替换掉它就等于自己证明自己。
@MainActor
final class LLMOutputPaneTests: XCTestCase {

    private func makeApp() -> (AppState, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("postme-llm-pane-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = AppState(
            persistence: PersistenceService(fileName: "workspace.json", directory: dir),
            languageOverride: .zhHans
        )
        return (app, dir)
    }

    /// OpenAI 形状的 SSE chunk。
    private func openAIChunks(_ pieces: [String]) -> [Data] {
        pieces.map { piece in
            Data(#"data: {"choices":[{"index":0,"delta":{"content":"\#(piece)"}}]}"#.utf8 + Data("\n\n".utf8))
        }
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - 分页可用性

    func testSSESectionsIncludeLLMBetweenBodyAndEvents() async throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let server = try LocalHTTPServer(routes: [
            "/sse": .stream(chunks: openAIChunks(["a"]), interval: 0, contentType: "text/event-stream", closeAfterLast: true)
        ])
        defer { server.stop() }

        app.draft = APIRequest(name: "sse", url: server.url("/sse"))
        await app.send()

        XCTAssertTrue(app.activeTab.stream.isEventStream)
        XCTAssertEqual(app.availableResponseSections, [.body, .llm, .events, .headers, .timing])
    }

    func testDefaultSectionStaysEventsAfterSSEFinishes() async throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let server = try LocalHTTPServer(routes: [
            "/sse": .stream(chunks: openAIChunks(["a", "b"]), interval: 0, contentType: "text/event-stream", closeAfterLast: true)
        ])
        defer { server.stop() }

        app.draft = APIRequest(name: "sse", url: server.url("/sse"))
        await app.send()

        XCTAssertEqual(app.responseSection, .events, "默认落点不得改变")
        XCTAssertNotEqual(app.responseSection, .llm)
    }

    func testNonSSEProducesNoLLMFieldsAndThreeSections() async throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let server = try LocalHTTPServer(routes: [
            "/json": .fixed(Data(#"{"choices":[{"delta":{"content":"x"}}]}"#.utf8), contentType: "application/json")
        ])
        defer { server.stop() }

        app.draft = APIRequest(name: "json", url: server.url("/json"))
        await app.send()

        XCTAssertEqual(app.availableResponseSections, [.body, .headers, .timing])
        XCTAssertTrue(app.activeTab.stream.llm.fields.isEmpty)
        XCTAssertEqual(app.responseSection, .body)
    }

    // MARK: - .llm 不残留（设计审查 B2）

    func testLLMTabResetsWhenNonSSERequestStarts() async throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let server = try LocalHTTPServer(routes: [
            "/sse": .stream(chunks: openAIChunks(["a"]), interval: 0, contentType: "text/event-stream", closeAfterLast: true),
            "/json": .fixed(Data(#"{"a":1}"#.utf8), contentType: "application/json")
        ])
        defer { server.stop() }

        app.draft = APIRequest(name: "sse", url: server.url("/sse"))
        await app.send()
        app.responseSection = .llm
        XCTAssertEqual(app.responseSection, .llm)

        app.draft = APIRequest(name: "json", url: server.url("/json"))
        await app.send()

        XCTAssertEqual(app.responseSection, .body, "停在 .llm 时发非 SSE 请求必须复位")
        XCTAssertTrue(app.activeTab.stream.llm.fields.isEmpty)
    }

    /// `send()` 起点的复位必须**在流式期间**就生效：非 SSE 请求在 `applyFinished`
    /// 之前一直不发终态，若起点不复位，这一段里分段控件没有 `.llm`、内容区却仍按它渲染。
    func testLLMTabResetsWhileNonSSERequestIsInFlight() async throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let server = try LocalHTTPServer(routes: [
            "/sse": .stream(chunks: openAIChunks(["a"]), interval: 0, contentType: "text/event-stream", closeAfterLast: true),
            "/slow": .delayed(seconds: 1.5, body: Data(#"{"a":1}"#.utf8))
        ])
        defer { server.stop() }

        app.draft = APIRequest(name: "sse", url: server.url("/sse"))
        await app.send()
        app.responseSection = .llm

        app.draft = APIRequest(name: "slow", url: server.url("/slow"))
        let send = Task { await app.send() }

        await waitUntil { self.sawInFlight(app) }
        XCTAssertTrue(app.isSending, "请求仍在飞")
        XCTAssertEqual(app.responseSection, .body, "起点就复位，不等终态")
        XCTAssertFalse(app.availableResponseSections.contains(.llm))

        await send.value
        XCTAssertEqual(app.responseSection, .body)
    }

    /// 在飞判定：请求已发出但终态还没到（`response` 是上一条的 SSE 终态，不算）。
    private func sawInFlight(_ app: AppState) -> Bool {
        app.isSending && app.availableResponseSections == [.body, .headers, .timing]
    }

    func testClearResponseResetsLLMTab() async throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let server = try LocalHTTPServer(routes: [
            "/sse": .stream(chunks: openAIChunks(["a"]), interval: 0, contentType: "text/event-stream", closeAfterLast: true)
        ])
        defer { server.stop() }

        app.draft = APIRequest(name: "sse", url: server.url("/sse"))
        await app.send()
        app.responseSection = .llm

        app.clearResponse()

        XCTAssertEqual(app.responseSection, .body)
        XCTAssertTrue(app.activeTab.stream.llm.fields.isEmpty)
    }

    // MARK: - 归并结果落到状态

    func testFieldsLandOnTheTabWithEvents() async throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let server = try LocalHTTPServer(routes: [
            "/sse": .stream(
                chunks: openAIChunks(["Hel", "lo", ", ", "world"]),
                interval: 0,
                contentType: "text/event-stream",
                closeAfterLast: true
            )
        ])
        defer { server.stop() }

        app.draft = APIRequest(name: "sse", url: server.url("/sse"))
        await app.send()

        let llm = app.activeTab.stream.llm
        XCTAssertEqual(llm.format, .openAI)
        XCTAssertEqual(llm.fields.count, 1)
        XCTAssertEqual(llm.fields.first?.text, "Hello, world")
        XCTAssertEqual(llm.fields.first?.pieceCount, 4)
        XCTAssertEqual(llm.selectedPath, "choices[0].delta.content", "未选定且已有字段时自动选中第一个")
        XCTAssertEqual(llm.parsedEventCount, 4)
        XCTAssertEqual(app.activeTab.stream.events.count, 4)
    }

    func testCancelKeepsJoinedText() async throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let chunks = openAIChunks(Array(repeating: "x", count: 200))
        let server = try LocalHTTPServer(routes: [
            "/endless": .stream(chunks: chunks, interval: 0.2, contentType: "text/event-stream", closeAfterLast: false)
        ])
        defer { server.stop() }

        app.draft = APIRequest(name: "endless", url: server.url("/endless"))
        let send = Task { await app.send() }

        await waitUntil { !app.activeTab.stream.llm.fields.isEmpty }
        app.cancelSend()
        await send.value

        XCTAssertEqual(app.activeTab.stream.status, .cancelled)
        let text = app.activeTab.stream.llm.fields.first?.text ?? ""
        XCTAssertFalse(text.isEmpty, "取消后已拼接内容必须保留")
        XCTAssertTrue(app.activeTab.stream.llm.parsedEventCount > 0)
    }

    // MARK: - 选择语义

    func testSelectedPathFollowsTab() async throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let server = try LocalHTTPServer(routes: [
            "/sse": .stream(
                chunks: [Data(#"data: {"choices":[{"delta":{"content":"ans","reasoning_content":"why"}}]}"#.utf8) + Data("\n\n".utf8)],
                interval: 0,
                contentType: "text/event-stream",
                closeAfterLast: true
            )
        ])
        defer { server.stop() }

        app.draft = APIRequest(name: "sse", url: server.url("/sse"))
        await app.send()
        let firstTab = app.activeTabID
        app.selectLLMField("choices[0].delta.reasoning_content")
        XCTAssertEqual(app.activeTab.stream.llm.selectedPath, "choices[0].delta.reasoning_content")

        let secondTab = app.newRequest()
        XCTAssertEqual(app.activeTab.stream.llm.selectedPath, nil, "新页签没有选择")

        app.activateTab(id: firstTab)
        XCTAssertEqual(app.activeTab.stream.llm.selectedPath, "choices[0].delta.reasoning_content",
                       "切回页签选择仍在")

        app.activateTab(id: secondTab)
        XCTAssertNil(app.activeTab.stream.llm.selectedPath)
    }

    /// 流式期间显式选一个尚无内容的自定义路径，后续到达的其它字段不得抢走选择。
    ///
    /// 选择必须发生在**同一条流**里：新请求开始时 `stream = StreamState()` 会把
    /// `llm` 一起重置（§3.7），选择本来就不该跨请求保留。
    func testExplicitSelectionIsNeverOverriddenByAutoSelect() async throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let chunks = openAIChunks(Array(repeating: "x", count: 120))
        let server = try LocalHTTPServer(routes: [
            "/endless": .stream(chunks: chunks, interval: 0.05, contentType: "text/event-stream", closeAfterLast: false)
        ])
        defer { server.stop() }

        app.draft = APIRequest(name: "endless", url: server.url("/endless"))
        let send = Task { await app.send() }

        await waitUntil { !app.activeTab.stream.llm.fields.isEmpty }
        XCTAssertEqual(app.activeTab.stream.llm.selectedPath, "choices[0].delta.content",
                       "未显式选择时自动落在第一个有内容的字段")

        XCTAssertTrue(app.addLLMCustomPath("choices[0].delta.custom"))
        app.selectLLMField("choices[0].delta.custom")

        // 等更多片段到达：自动选择若在每次 consume 里重新执行，这里就会被抢回去。
        let piecesBefore = app.activeTab.stream.llm.fields.first?.pieceCount ?? 0
        await waitUntil { (app.activeTab.stream.llm.fields.first?.pieceCount ?? 0) > piecesBefore }
        XCTAssertEqual(app.activeTab.stream.llm.selectedPath, "choices[0].delta.custom",
                       "显式选择不被自动选择覆盖")

        app.cancelSend()
        await send.value
        XCTAssertEqual(app.activeTab.stream.llm.selectedPath, "choices[0].delta.custom")
    }

    // MARK: - 自定义路径配置

    func testLLMFieldPathsRoundTripAndFilterInvalid() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("postme-llm-paths-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let persistence = PersistenceService(fileName: "workspace.json", directory: dir)
        var workspace = Workspace()
        workspace.settings.llmFieldPaths = ["choices[0].delta.content", "custom.path"]
        persistence.saveNow(workspace)

        let reloaded = PersistenceService(fileName: "workspace.json", directory: dir).load()
        XCTAssertEqual(reloaded.settings.llmFieldPaths, ["choices[0].delta.content", "custom.path"])
    }

    func testInvalidPathsAreFilteredOnRead() {
        let sanitized = AppSettings.sanitizedPaths([
            "choices[0].delta.content",
            "a..b",
            "a[*]",
            "",
            "choices[0].delta.content",
            "  custom.path  "
        ])
        XCTAssertEqual(sanitized, ["choices[0].delta.content", "custom.path"])
    }

    func testMissingKeyDecodesToEmptyPaths() throws {
        let json = Data(#"{"timeout":30,"followRedirects":true,"allowInsecureTLS":false}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertTrue(settings.llmFieldPaths.isEmpty)
    }

    func testAddAndRemoveCustomPathKeepSettingsInSync() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertTrue(app.addLLMCustomPath("choices[0].delta.custom"))
        XCTAssertEqual(app.workspace.settings.llmFieldPaths, ["choices[0].delta.custom"])

        XCTAssertFalse(app.addLLMCustomPath("a..b"), "非法路径被拒绝")
        XCTAssertEqual(app.workspace.settings.llmFieldPaths, ["choices[0].delta.custom"])

        app.removeLLMCustomPath("choices[0].delta.custom")
        XCTAssertTrue(app.workspace.settings.llmFieldPaths.isEmpty)
    }

    func testCustomPathLimitIsEnforcedForNewPaths() {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        for index in 0..<LLMStreamMerger.maxCustomPaths {
            XCTAssertTrue(app.addLLMCustomPath("path\(index)"))
        }
        XCTAssertFalse(app.addLLMCustomPath("overflow"), "超出上限被拒绝")
        XCTAssertEqual(app.workspace.settings.llmFieldPaths.count, LLMStreamMerger.maxCustomPaths)
    }

    // MARK: - StreamBatch 同窗口落地

    func testBatchCarriesLLMSnapshot() {
        // interval 必须很大：`interval <= 0` 表示「每个 add 立即发布」，
        // 那样窗口在 takePending 之前就已经被 flush 掉了。
        let publisher = StreamPublisher(interval: 60, byteThreshold: 0) { _ in }
        var merger = LLMStreamMerger()
        let event = SSEEvent(sequence: 1, data: #"{"choices":[{"delta":{"content":"x"}}]}"#)
        _ = merger.consume([event])
        publisher.add(events: [event], text: "", bytes: 1, llm: merger.state)

        let batch = publisher.takePending()
        XCTAssertEqual(batch.events.count, 1)
        XCTAssertEqual(batch.llm?.fields.first?.text, "x")
        publisher.close()
    }
}

// MARK: - 归并器随页签释放（T3）

extension LLMOutputPaneTests {

    /// 关闭跑过 SSE 的页签后，归并器不得再被 AppState 持有。
    ///
    /// 归并器里是拼接文本（单字段上限 512 KB × 64 字段）。页签关闭是高频操作，
    /// 漏掉清理就随关闭次数线性累积、无上界——违反 §3.4「上界按存活页签设计」。
    func testClosingTabReleasesItsMerger() async throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let server = try LocalHTTPServer(routes: [
            "/sse": .stream(chunks: openAIChunks(["a", "b"]), interval: 0, contentType: "text/event-stream", closeAfterLast: true)
        ])
        defer { server.stop() }

        app.draft = APIRequest(name: "sse", url: server.url("/sse"))
        await app.send()
        let tabID = app.activeTabID

        // 前置条件：这条流确实建了归并器，且流结束后仍留着（切字段要用）。
        XCTAssertEqual(app.activeTab.stream.llm.fields.first?.text, "ab")
        XCTAssertTrue(app.liveMergerTabIDs.contains(tabID), "流结束后归并器应仍在（设计如此）")

        app.closeTab(id: tabID)

        XCTAssertFalse(app.liveMergerTabIDs.contains(tabID), "关页签后必须释放归并器")
        XCTAssertTrue(app.liveMergerTabIDs.isEmpty, "关掉唯一的页签后表应为空")
        // 补出来的空格是另一个 id，也不能被残留项命中。
        XCTAssertFalse(app.liveMergerTabIDs.contains(app.activeTabID))
    }

    /// 多页签：只释放被关掉的那一格，其它页签的归并器不受影响。
    func testClosingOneTabKeepsOtherMergers() async throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let server = try LocalHTTPServer(routes: [
            "/sse": .stream(chunks: openAIChunks(["x"]), interval: 0, contentType: "text/event-stream", closeAfterLast: true)
        ])
        defer { server.stop() }

        app.draft = APIRequest(name: "first", url: server.url("/sse"))
        await app.send()
        let first = app.activeTabID

        let second = app.newRequest()
        app.activateTab(id: second)
        app.draft = APIRequest(name: "second", url: server.url("/sse"))
        await app.send()
        XCTAssertEqual(app.liveMergerTabIDs, [first, second])

        app.closeTab(id: first)
        XCTAssertEqual(app.liveMergerTabIDs, [second], "只释放被关掉的那一格")
        XCTAssertEqual(app.activeTab.stream.llm.fields.first?.text, "x", "另一格的拼接结果不受影响")

        app.closeTab(id: second)
        XCTAssertTrue(app.liveMergerTabIDs.isEmpty)
    }

    /// 在飞期间关页签：取消 + 释放，且收尾路径不得把归并器重新挂回去。
    func testClosingTabDuringStreamReleasesMerger() async throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let chunks = openAIChunks(Array(repeating: "x", count: 200))
        let server = try LocalHTTPServer(routes: [
            "/endless": .stream(chunks: chunks, interval: 0.2, contentType: "text/event-stream", closeAfterLast: false)
        ])
        defer { server.stop() }

        app.draft = APIRequest(name: "endless", url: server.url("/endless"))
        let send = Task { await app.send() }

        await waitUntil { !app.activeTab.stream.llm.fields.isEmpty }
        let tabID = app.activeTabID
        XCTAssertTrue(app.liveMergerTabIDs.contains(tabID))

        app.closeTab(id: tabID)
        XCTAssertFalse(app.liveMergerTabIDs.contains(tabID), "关闭后立即释放")

        await send.value
        XCTAssertFalse(app.liveMergerTabIDs.contains(tabID), "取消收尾路径不得把归并器挂回去")
        XCTAssertFalse(app.liveMergerTabIDs.contains(app.activeTabID))
    }
}
