import XCTest
@testable import Postme

/// SSE 解析器（AC1）。
///
/// 这里的用例不是"覆盖 API"，而是把真实世界里会让 SSE 显示错位的几种边界钉死：
/// chunk 边界切开的 `\r\n`、切在多字节 UTF-8 中间、冒号后的空格数量、BOM、
/// 以及流关闭时未收尾的事件。
final class SSEParserTests: XCTestCase {

    private func parse(_ chunks: [String]) -> [SSEEvent] {
        var parser = SSEParser()
        var events: [SSEEvent] = []
        for chunk in chunks {
            events += parser.consume(Data(chunk.utf8))
        }
        events += parser.finish()
        return events
    }

    private func parseBytes(_ chunks: [[UInt8]]) -> [SSEEvent] {
        var parser = SSEParser()
        var events: [SSEEvent] = []
        for chunk in chunks {
            events += parser.consume(Data(chunk))
        }
        events += parser.finish()
        return events
    }

    // MARK: - 基本分帧

    func testSingleEventWithBlankLineTerminator() {
        let events = parse(["data: hello\n\n"])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "hello")
        XCTAssertNil(events[0].eventType)
        XCTAssertNil(events[0].eventID)
        XCTAssertEqual(events[0].sequence, 1)
        XCTAssertFalse(events[0].isUnterminated)
    }

    func testMultipleEventsInOneChunk() {
        let events = parse(["data: one\n\ndata: two\n\n"])
        XCTAssertEqual(events.map(\.data), ["one", "two"])
        XCTAssertEqual(events.map(\.sequence), [1, 2])
    }

    func testMultiLineDataJoinedWithNewline() {
        let events = parse(["data: line1\ndata: line2\ndata: line3\n\n"])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "line1\nline2\nline3")
    }

    func testEventAndIDFields() {
        let events = parse(["event: delta\nid: 42\ndata: payload\n\n"])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].eventType, "delta")
        XCTAssertEqual(events[0].eventID, "42")
        XCTAssertEqual(events[0].data, "payload")
    }

    func testEventTypeAppliesOnlyToItsOwnBlock() {
        let events = parse(["event: delta\ndata: a\n\ndata: b\n\n"])
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].eventType, "delta")
        XCTAssertNil(events[1].eventType, "event: 只影响当前块，不延续")
    }

    func testLastEventIDPersistsAcrossBlocks() {
        // 规范的 last event ID buffer 不在派发时清空：后续没有 id: 的事件沿用上一个 id。
        let events = parse(["id: 7\ndata: a\n\ndata: b\n\n"])
        XCTAssertEqual(events.map(\.eventID), ["7", "7"])
    }

    // MARK: - 行尾

    func testCarriageReturnLineFeed() {
        let events = parse(["data: a\r\ndata: b\r\n\r\n"])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "a\nb")
    }

    func testBareCarriageReturnLineEndings() {
        let events = parse(["data: a\rdata: b\r\r"])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "a\nb")
    }

    func testMixedLineEndings() {
        let events = parse(["data: a\r\ndata: b\rdata: c\n\n"])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "a\nb\nc")
    }

    func testCarriageReturnSplitAcrossChunksIsOneLineEnding() {
        // 若把 chunk 末尾的孤立 \r 立即当作行尾，下一 chunk 的 \n 会被当成空行 →
        // 凭空多派发一条事件，并且 data 被切成两条。
        let events = parse(["data: a\r", "\ndata: b\r\n\r\n"])
        XCTAssertEqual(events.count, 1, "\\r\\n 被切开仍只算一个行尾")
        XCTAssertEqual(events[0].data, "a\nb")
    }

    func testCarriageReturnAtChunkEndWithBareLFNextChunk() {
        // \r 与 \n 分属两个 chunk，且 \n 后面紧跟新的 data 行：仍是一个行尾 + 一行数据。
        let events = parse(["data: a\r", "\n", "\ndata: b\n\n"])
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map(\.data), ["a", "b"])
    }

    // MARK: - 多字节 UTF-8 跨 chunk

    func testMultiByteUTF8SplitAcrossChunks() {
        let full = Array("data: 你好，世界\n\n".utf8)
        // 每个字节单独喂一次：任何一次"按 chunk 解码"的实现都会在这里产出 U+FFFD。
        let events = parseBytes(full.map { [$0] })
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "你好，世界")
        XCTAssertFalse(events[0].data.contains("\u{FFFD}"))
    }

    func testMultiByteUTF8SplitInsideCharacter() {
        let bytes = Array("data: émoji 😀\n\n".utf8)
        // 切在第 3 个字节上（é 的续字节与 😀 的中间）。
        let cut = 8
        let events = parseBytes([Array(bytes[..<cut]), Array(bytes[cut...])])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "émoji 😀")
    }

    // MARK: - 字段值与冒号

    func testOnlyOneLeadingSpaceAfterColonIsRemoved() {
        let events = parse(["data:  two spaces\n\n"])
        XCTAssertEqual(events[0].data, " two spaces")
    }

    func testNoSpaceAfterColon() {
        let events = parse(["data:x\n\n"])
        XCTAssertEqual(events[0].data, "x")
    }

    func testColonInsideValueIsPreserved() {
        let events = parse(["data: {\"url\":\"http://a\"}\n\n"])
        XCTAssertEqual(events[0].data, "{\"url\":\"http://a\"}")
    }

    func testLineWithoutColonIsFieldWithEmptyValue() {
        let events = parse(["data\n\n"])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "")
    }

    func testUnknownFieldWithoutColonIsIgnored() {
        let events = parse(["foo\n\n"])
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - 不派发的情形

    func testCommentOnlyBlockDoesNotDispatch() {
        let events = parse([": keep-alive\n\n"])
        XCTAssertTrue(events.isEmpty)
    }

    func testIDOnlyBlockDoesNotDispatch() {
        let events = parse(["id: 9\n\n"])
        XCTAssertTrue(events.isEmpty, "只有 id: 的块不产生事件")
    }

    func testEventTypeOnlyBlockDoesNotDispatch() {
        let events = parse(["event: ping\n\n"])
        XCTAssertTrue(events.isEmpty)
    }

    func testCommentInsideBlockIsIgnored() {
        let events = parse(["data: a\n: comment\ndata: b\n\n"])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "a\nb")
    }

    func testBlankLineAloneDoesNotDispatch() {
        let events = parse(["\n\n\n"])
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - 忽略的字段

    func testRetryIsIgnored() {
        let events = parse(["retry: 3000\ndata: a\n\n"])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "a")
        XCTAssertEqual(events[0].sequence, 1, "retry 不应产生额外事件或影响编号")
    }

    func testUnknownFieldIsIgnored() {
        let events = parse(["x-custom: v\ndata: a\n\n"])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "a")
    }

    func testIDWithNULIsIgnored() {
        // 规范：id 值含 U+0000 时整个字段忽略，last event ID buffer 保持原值。
        let events = parse(["id: ok\ndata: a\n\n", "id: bad\u{0}id\ndata: b\n\n"])
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].eventID, "ok")
        XCTAssertEqual(events[1].eventID, "ok")
    }

    // MARK: - BOM

    func testLeadingBOMIsStripped() {
        var parser = SSEParser()
        var bytes = Array("\u{FEFF}".utf8)
        bytes += Array("data: x\n\n".utf8)
        let events = parser.consume(Data(bytes)) + parser.finish()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "x", "BOM 不能被当作字段名的一部分")
    }

    func testBOMSplitAcrossChunks() {
        var parser = SSEParser()
        var bytes = Array("\u{FEFF}".utf8)
        bytes += Array("data: x\n\n".utf8)
        var events: [SSEEvent] = []
        events += parser.consume(Data(bytes[0..<1]))
        events += parser.consume(Data(bytes[1..<2]))
        events += parser.consume(Data(bytes[2...]))
        events += parser.finish()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "x")
    }

    func testNonBOMPrefixIsNotSwallowed() {
        // 前两个字节恰好是 BOM 前缀、第三个不是：三个字节都必须照常处理。
        var parser = SSEParser()
        let bytes = Array("data: x\n\n".utf8)
        let events = parser.consume(Data(bytes)) + parser.finish()
        XCTAssertEqual(events[0].data, "x")
    }

    func testBOMInsideStreamIsNotStripped() {
        // BOM 只可能在流开头剥除：出现在值里就是普通字符，不能被吞掉。
        var parser = SSEParser()
        var bytes = Array("data: a\n\ndata: ".utf8)
        bytes += [0xEF, 0xBB, 0xBF]
        bytes += Array("b\n\n".utf8)
        let events = parser.consume(Data(bytes)) + parser.finish()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[1].data, "\u{FEFF}b")
    }

    func testBOMInsideStreamBeforeFieldNameIsNotStripped() {
        // 行首的 BOM 字节不剥除 → 字段名变成未知字段 → 该块不派发（不是被吞成 data）。
        var parser = SSEParser()
        var bytes = Array("data: a\n\n".utf8)
        bytes += [0xEF, 0xBB, 0xBF]
        bytes += Array("data: b\n\n".utf8)
        let events = parser.consume(Data(bytes)) + parser.finish()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "a")
    }

    // MARK: - finish()

    func testFinishDispatchesUnterminatedEvent() {
        var parser = SSEParser()
        var events = parser.consume(Data("data: tail\n".utf8))
        XCTAssertTrue(events.isEmpty, "没有空行就不该派发")
        events = parser.finish()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "tail")
        XCTAssertTrue(events[0].isUnterminated)
    }

    func testFinishDispatchesEventWithoutTrailingNewline() {
        var parser = SSEParser()
        var events = parser.consume(Data("data: tail".utf8))
        events += parser.finish()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "tail", "残留的不完整行也是数据")
        XCTAssertTrue(events[0].isUnterminated)
    }

    func testFinishWithNothingPendingProducesNothing() {
        var parser = SSEParser()
        _ = parser.consume(Data("data: a\n\n".utf8))
        XCTAssertTrue(parser.finish().isEmpty)
        XCTAssertTrue(parser.finish().isEmpty, "finish 可重复调用且幂等")
    }

    func testFinishOnEmptyStreamProducesNothing() {
        var parser = SSEParser()
        XCTAssertTrue(parser.finish().isEmpty)
    }

    func testFinishAfterUnterminatedEmptyDataLineDispatches() {
        var parser = SSEParser()
        _ = parser.consume(Data("data:".utf8))
        let events = parser.finish()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "")
        XCTAssertTrue(events[0].isUnterminated)
    }

    // MARK: - sequence

    func testSequenceIncrementsFromOneAcrossChunks() {
        var parser = SSEParser()
        var events: [SSEEvent] = []
        events += parser.consume(Data("data: a\n\ndata: b\n".utf8))
        events += parser.consume(Data("\ndata: c\n\n".utf8))
        events += parser.finish()
        XCTAssertEqual(events.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(events.map(\.data), ["a", "b", "c"])
    }

    func testSequenceSkipsNothingForUndispatchedBlocks() {
        var parser = SSEParser()
        var events: [SSEEvent] = []
        events += parser.consume(Data(": comment\n\ndata: a\n\nid: 3\n\ndata: b\n\n".utf8))
        events += parser.finish()
        XCTAssertEqual(events.map(\.sequence), [1, 2])
    }

    // MARK: - 逐字节喂入（最坏情况）

    func testByteByByteFeedingMatchesWholeChunk() {
        let payload = "event: delta\r\nid: 1\r\ndata: {\"a\":1}\r\n\r\ndata: done\n\n"
        var whole = SSEParser()
        let expected = whole.consume(Data(payload.utf8)) + whole.finish()

        var drip = SSEParser()
        var actual: [SSEEvent] = []
        for byte in Array(payload.utf8) {
            actual += drip.consume(Data([byte]))
        }
        actual += drip.finish()

        XCTAssertEqual(actual.count, expected.count)
        XCTAssertEqual(actual.map(\.data), expected.map(\.data))
        XCTAssertEqual(actual.map(\.sequence), expected.map(\.sequence))
        XCTAssertEqual(actual.map(\.eventType), expected.map(\.eventType))
        XCTAssertEqual(actual.map(\.eventID), expected.map(\.eventID))
    }
}
