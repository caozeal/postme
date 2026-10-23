import XCTest
@testable import Postme

/// LLM 归并器（AC1 路径与取值 / AC2 内置格式 / AC3 上限）。
///
/// 用例针对的是实现期最容易写错的三处：计数口径（哪条事件算 parsed / unparsed）、
/// Anthropic 路径是拼出来的（不是下钻出来的）、以及上限到顶后"已有内容不丢"。
final class LLMStreamMergerTests: XCTestCase {

    /// §3.4 的契约数字。这里写死不引用实现常量：实现把上限改大时用例必须失败。
    private static let maxFieldBytes = 512 * 1024

    private var sequence = 0

    private func event(_ data: String) -> SSEEvent {
        sequence += 1
        return SSEEvent(sequence: sequence, data: data)
    }

    private func merger() -> LLMStreamMerger {
        sequence = 0
        return LLMStreamMerger()
    }

    private func field(_ path: String, in state: LLMStreamState) -> LLMFieldAccumulator? {
        state.fields.first { $0.path == path }
    }

    // MARK: - AC1 路径语法

    func testValidPathsAreAccepted() {
        let valid = ["a", "a.b", "a[0]", "a[0].b.c[12]", "choices[0].delta.content", "a-b_c[3].d"]
        for path in valid {
            var merger = merger()
            XCTAssertTrue(merger.addCustomPath(path), "应接受合法路径: \(path)")
            XCTAssertEqual(merger.state.customPaths, [path])
        }
    }

    func testInvalidPathsAreRejected() {
        let invalid = ["", "   ", "a..b", "a[", "a[*]", ".a", "a[0", "a[0]b", "a[0].", "a[b]", "a b", "a[0]]", "a[]"]
        for path in invalid {
            var merger = merger()
            XCTAssertFalse(merger.addCustomPath(path), "应拒绝非法路径: \(path)")
            XCTAssertTrue(merger.state.customPaths.isEmpty)
        }
    }

    func testCustomPathDeduplication() {
        var merger = merger()
        XCTAssertTrue(merger.addCustomPath("a.b"))
        XCTAssertTrue(merger.addCustomPath("a.b"), "重复添加返回 true")
        XCTAssertEqual(merger.state.customPaths, ["a.b"])
    }

    // MARK: - AC1 下钻取值

    func testObjectKeysAndArrayIndicesAreResolved() {
        var merger = merger()
        _ = merger.addCustomPath("a.b[1].c")
        _ = merger.consume([event(#"{"a":{"b":[{"c":"zero"},{"c":"one"}]}}"#)])
        XCTAssertEqual(field("a.b[1].c", in: merger.state)?.text, "one")
    }

    func testTypeMismatchProducesNothingAndDoesNotCrash() {
        var merger = merger()
        _ = merger.addCustomPath("a.b")
        let grew = merger.consume([event(#"{"a":1}"#)])
        XCTAssertFalse(grew)
        XCTAssertTrue(merger.state.fields.isEmpty)
        XCTAssertEqual(merger.state.parsedEventCount, 1, "JSON 合法即 parsed")
        XCTAssertEqual(merger.state.unparsedEventCount, 0)
    }

    func testNonStringValueAtCustomPathProducesNoPiece() {
        var merger = merger()
        _ = merger.addCustomPath("a.b")
        _ = merger.consume([event(#"{"a":{"b":42}}"#)])
        XCTAssertTrue(merger.state.fields.isEmpty)
        XCTAssertEqual(merger.state.unparsedEventCount, 0)
    }

    func testCustomPathWithoutCustomPathStillKeepsUnknownFormat() {
        var merger = merger()
        _ = merger.consume([event(#"{"a":{"b":"x"}}"#)])
        XCTAssertEqual(merger.state.format, .unknown)
        XCTAssertTrue(merger.state.fields.isEmpty)
        XCTAssertEqual(merger.state.parsedEventCount, 1)
    }

    // MARK: - AC3 单字段上限

    func testFieldStopsAtByteLimitAndKeepsExistingText() {
        var merger = merger()
        _ = merger.addCustomPath("a")

        let limit = Self.maxFieldBytes  // §3.4 写死的 512 KB
        _ = merger.consume([event(#"{"a":"first"}"#)])

        let big = String(repeating: "x", count: limit * 2)
        _ = merger.consume([event(#"{"a":"\#(big)"}"#)])

        guard let accumulator = field("a", in: merger.state) else {
            return XCTFail("字段 a 应存在")
        }
        XCTAssertEqual(accumulator.text.utf8.count, limit, "到顶后总字节数恰为上限")
        XCTAssertTrue(accumulator.isTruncated)
        XCTAssertTrue(accumulator.text.hasPrefix("first"), "已有内容不丢")

        // 到顶后再来片段：不追加、不再增片段数、文本不变。
        let before = merger.state.fields[0].text
        let piecesBefore = merger.state.fields[0].pieceCount
        _ = merger.consume([event(#"{"a":"later"}"#)])
        XCTAssertEqual(merger.state.fields[0].text, before)
        XCTAssertEqual(merger.state.fields[0].pieceCount, piecesBefore)
    }

    func testTruncationNeverSplitsAMultibyteCharacter() {
        var merger = merger()
        _ = merger.addCustomPath("a")
        let limit = Self.maxFieldBytes  // §3.4 写死的 512 KB

        // 先填到只剩 1 字节，再来一个 3 字节字符：放不下，整字丢弃且文本仍是合法 UTF-8。
        let head = String(repeating: "x", count: limit - 1)
        _ = merger.consume([event(#"{"a":"\#(head)"}"#)])
        _ = merger.consume([event(#"{"a":"汉"}"#)])

        let accumulator = merger.state.fields[0]
        XCTAssertEqual(accumulator.text.utf8.count, limit - 1)
        XCTAssertTrue(accumulator.isTruncated)
        XCTAssertEqual(accumulator.text.unicodeScalars.count, limit - 1)
        XCTAssertFalse(accumulator.text.contains("\u{FFFD}"))
    }

    // MARK: - AC3 字段数量上限

    func testFieldLimitDropsNewFieldsAndCountsThem() {
        var merger = merger()
        let choices = (0...(LLMStreamMerger.maxFields + 5)).map { index in
            #"{"delta":{"content":"\#(index)"}}"#
        }
        let payload = #"{"choices":[\#(choices.joined(separator: ","))]}"#
        _ = merger.consume([event(payload)])

        XCTAssertEqual(merger.state.fields.count, LLMStreamMerger.maxFields)
        XCTAssertEqual(merger.state.droppedFieldCount, 6)
        XCTAssertEqual(merger.state.parsedEventCount, 1)
        XCTAssertEqual(merger.state.unparsedEventCount, 0, "字段上限不是解析失败")
    }

    func testRepeatedDroppedPathCountsOnce() {
        var merger = merger()
        let choices = (0...LLMStreamMerger.maxFields).map { index in
            #"{"delta":{"content":"\#(index)"}}"#
        }
        let payload = #"{"choices":[\#(choices.joined(separator: ","))]}"#
        _ = merger.consume([event(payload), event(payload), event(payload)])
        XCTAssertEqual(merger.state.droppedFieldCount, 1, "同一路径反复被丢只计一次")
    }

    // MARK: - AC3 自定义路径上限

    func testCustomPathLimit() {
        var merger = merger()
        for index in 0..<LLMStreamMerger.maxCustomPaths {
            XCTAssertTrue(merger.addCustomPath("a\(index)"))
        }
        XCTAssertFalse(merger.addCustomPath("overflow"))
        XCTAssertEqual(merger.state.customPaths.count, LLMStreamMerger.maxCustomPaths)
        XCTAssertTrue(merger.addCustomPath("a0"), "已存在的路径在满额时仍返回 true")
    }

    func testRemoveCustomPath() {
        var merger = merger()
        _ = merger.addCustomPath("a.b")
        _ = merger.addCustomPath("a.c")
        merger.removeCustomPath("a.b")
        XCTAssertEqual(merger.state.customPaths, ["a.c"])
        XCTAssertTrue(merger.addCustomPath("a.d"))
    }

    // MARK: - 选择语义

    func testSelectRecordsPathBeforeFieldExists() {
        var merger = merger()
        merger.select("choices[0].delta.content")
        XCTAssertEqual(merger.state.selectedPath, "choices[0].delta.content")
        XCTAssertNil(merger.state.selectedField, "尚未产出内容时没有字段")

        _ = merger.consume([event(#"{"choices":[{"delta":{"content":"hi"}}]}"#)])
        XCTAssertEqual(merger.state.selectedField?.text, "hi")
        XCTAssertEqual(merger.state.fields.count, 1)
    }

    func testAutoSelectPicksFirstNonEmptyFieldButNeverOverridesExplicitChoice() {
        var merger = merger()
        _ = merger.addCustomPath("choices[0].delta.custom")
        merger.select("choices[0].delta.custom")

        _ = merger.consume([event(#"{"choices":[{"delta":{"content":"hi"}}]}"#)])
        XCTAssertEqual(merger.state.selectedPath, "choices[0].delta.custom", "显式选择不被自动选择覆盖")
        XCTAssertEqual(merger.state.selectedField?.text ?? "", "")
    }

    func testAutoSelectWhenNothingSelected() {
        var merger = merger()
        _ = merger.consume([event(#"{"choices":[{"delta":{"content":""}}]}"#)])
        XCTAssertNil(merger.state.selectedPath, "空串不产字段，也就无从自动选中")

        _ = merger.consume([event(#"{"choices":[{"delta":{"content":"hi"}}]}"#)])
        XCTAssertEqual(merger.state.selectedPath, "choices[0].delta.content")
    }

    func testResetKeepsCustomPathsAndClearsState() {
        var merger = merger()
        _ = merger.addCustomPath("a")
        _ = merger.consume([event(#"{"a":"x"}"#), event("[DONE]")])
        merger.select("a")
        merger.reset()

        XCTAssertEqual(merger.state.customPaths, ["a"])
        XCTAssertTrue(merger.state.fields.isEmpty)
        XCTAssertEqual(merger.state.parsedEventCount, 0)
        XCTAssertEqual(merger.state.unparsedEventCount, 0)
        XCTAssertNil(merger.state.selectedPath)
        XCTAssertEqual(merger.state.format, .unknown)
    }
}

// MARK: - C2 内置格式与计数口径

extension LLMStreamMergerTests {

    /// OpenAI 流：`delta.content` 的多条事件。
    private func openAIContent(_ pieces: [String]) -> [SSEEvent] {
        pieces.map { event(#"{"choices":[{"index":0,"delta":{"content":"\#($0)"}}]}"#) }
    }

    func testOpenAIContentAccumulatesAcrossEvents() {
        var merger = merger()
        let grew = merger.consume(openAIContent(["Hel", "lo", ", ", "world", "!"]))
        XCTAssertTrue(grew)

        let state = merger.state
        XCTAssertEqual(state.format, .openAI)
        XCTAssertEqual(state.fields.count, 1)
        XCTAssertEqual(state.fields[0].path, "choices[0].delta.content")
        XCTAssertEqual(state.fields[0].displayName, "content")
        XCTAssertEqual(state.fields[0].kind, .text)
        XCTAssertEqual(state.fields[0].text, "Hello, world!")
        XCTAssertEqual(state.fields[0].pieceCount, 5)
        XCTAssertEqual(state.parsedEventCount, 5)
        XCTAssertEqual(state.unparsedEventCount, 0)
    }

    func testOpenAIReasoningAndContentAreSeparateFields() {
        var merger = merger()
        _ = merger.consume([
            event(#"{"choices":[{"delta":{"reasoning_content":"think "}}]}"#),
            event(#"{"choices":[{"delta":{"content":"answer"}}]}"#),
            event(#"{"choices":[{"delta":{"reasoning":"more"}}]}"#)
        ])

        XCTAssertEqual(merger.state.fields.map(\.path), [
            "choices[0].delta.reasoning_content",
            "choices[0].delta.content",
            "choices[0].delta.reasoning"
        ])
        XCTAssertEqual(merger.state.fields[0].kind, .reasoning)
        XCTAssertEqual(merger.state.fields[1].kind, .text)
        XCTAssertEqual(merger.state.fields[2].kind, .reasoning)
        XCTAssertEqual(merger.state.fields[1].text, "answer")
    }

    func testOpenAIMultipleChoicesAreSeparateFields() {
        var merger = merger()
        _ = merger.consume([
            event(#"{"choices":[{"index":0,"delta":{"content":"a"}}]}"#),
            event(#"{"choices":[{"index":1,"delta":{"content":"b"}}]}"#),
            event(#"{"choices":[{"index":0,"delta":{"content":"c"}}]}"#)
        ])

        XCTAssertEqual(merger.state.fields.map(\.path), [
            "choices[0].delta.content",
            "choices[1].delta.content"
        ])
        XCTAssertEqual(merger.state.fields[0].text, "ac")
        XCTAssertEqual(merger.state.fields[1].text, "b")
    }

    func testOpenAIToolCallArgumentsAreTheirOwnField() {
        var merger = merger()
        _ = merger.consume([
            event(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"a\":"}}]}}]}"#),
            event(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"1}"}}]}}]}"#)
        ])

        let field = merger.state.fields.first { $0.path == "choices[0].delta.tool_calls[0].function.arguments" }
        XCTAssertNotNil(field)
        XCTAssertEqual(field?.text, "{\"a\":1}")
        XCTAssertEqual(field?.kind, .toolArguments)
        XCTAssertEqual(field?.pieceCount, 2)
    }

    func testOpenAIEmptyStringDeltaDoesNotCountAsPiece() {
        var merger = merger()
        _ = merger.consume([
            event(#"{"choices":[{"delta":{"content":"a"}}]}"#),
            event(#"{"choices":[{"delta":{"content":""}}]}"#),
            event(#"{"choices":[{"delta":{"content":""}}]}"#),
            event(#"{"choices":[{"delta":{"content":"b"}}]}"#)
        ])

        XCTAssertEqual(merger.state.fields.count, 1)
        XCTAssertEqual(merger.state.fields[0].text, "ab")
        XCTAssertEqual(merger.state.fields[0].pieceCount, 2, "空串心跳不增片段数")
        XCTAssertEqual(merger.state.parsedEventCount, 4)
        XCTAssertEqual(merger.state.unparsedEventCount, 0)
    }

    func testOpenAINonStringAndNullDeltasProduceNothingAndCountNothing() {
        var merger = merger()
        _ = merger.consume([
            event(#"{"choices":[{"delta":{"content":null}}]}"#),
            event(#"{"choices":[{"delta":{"content":42}}]}"#),
            event(#"{"choices":[{"delta":{"content":{"nested":"x"}}}]}"#),
            event(#"{"choices":[{"delta":{"content":["a"]}}]}"#)
        ])

        XCTAssertTrue(merger.state.fields.isEmpty)
        XCTAssertEqual(merger.state.parsedEventCount, 4, "JSON 合法即 parsed")
        XCTAssertEqual(merger.state.unparsedEventCount, 0, "字段级非字符串不是未解析")
    }

    func testOpenAIUnrecognizedShapeStillCountsAsParsed() {
        var merger = merger()
        _ = merger.consume([event(#"{"foo":{"bar":"baz"}}"#), event(#"{"choices":"not an array"}"#)])
        XCTAssertEqual(merger.state.parsedEventCount, 2)
        XCTAssertEqual(merger.state.unparsedEventCount, 0)
        XCTAssertTrue(merger.state.fields.isEmpty)
        XCTAssertEqual(merger.state.format, .unknown)
    }

    // MARK: Anthropic

    func testAnthropicContentBlockStartAndDeltaShareOneField() {
        var merger = merger()
        _ = merger.consume([
            event(#"{"type":"message_start","message":{"id":"m1"}}"#),
            event(#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":"Hello"}}"#),
            event(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":", "}}"#),
            event(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"world"}}"#),
            event(#"{"type":"content_block_stop","index":0}"#),
            event(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#),
            event(#"{"type":"message_stop"}"#)
        ])

        let state = merger.state
        XCTAssertEqual(state.format, .anthropic)
        XCTAssertEqual(state.fields.count, 1, "start 首段与后续 delta 必须同字段")
        XCTAssertEqual(state.fields[0].path, "content_block[0].text", "路径不含事件类型名")
        XCTAssertEqual(state.fields[0].text, "Hello, world")
        XCTAssertEqual(state.fields[0].pieceCount, 3)
        XCTAssertEqual(state.parsedEventCount, 7)
        XCTAssertEqual(state.unparsedEventCount, 0, "message_* / content_block_stop 不产字段也不计 unparsed")
    }

    func testAnthropicTextThinkingAndToolJSONAreSeparateFields() {
        var merger = merger()
        _ = merger.consume([
            event(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"plan"}}"#),
            event(#"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"answer"}}"#),
            event(#"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"x\":"}}"#),
            event(#"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"1}"}}"#)
        ])

        let paths = merger.state.fields.map(\.path)
        XCTAssertEqual(paths, [
            "content_block[0].thinking",
            "content_block[1].text",
            "content_block[2].partial_json"
        ])
        XCTAssertEqual(merger.state.fields[0].kind, .reasoning)
        XCTAssertEqual(merger.state.fields[1].kind, .text)
        XCTAssertEqual(merger.state.fields[2].kind, .toolArguments)
        XCTAssertEqual(merger.state.fields[2].text, "{\"x\":1}")
    }

    func testAnthropicSignatureDeltaAndPingProduceNothing() {
        var merger = merger()
        _ = merger.consume([
            event(#"{"type":"ping"}"#),
            event(#"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}"#),
            event(#"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"ok"}}"#)
        ])

        XCTAssertEqual(merger.state.fields.map(\.path), ["content_block[1].text"])
        XCTAssertEqual(merger.state.unparsedEventCount, 0)
        XCTAssertEqual(merger.state.parsedEventCount, 3)
    }

    func testAnthropicCustomPathHitsTheSameField() {
        var merger = merger()
        XCTAssertTrue(merger.addCustomPath("content_block[0].text"))
        _ = merger.consume([
            event(#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":"Hel"}}"#),
            event(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}"#)
        ])

        XCTAssertEqual(merger.state.fields.count, 1, "自定义同字符串命中同一字段，不新增")
        XCTAssertEqual(merger.state.fields[0].text, "Hello")
        XCTAssertEqual(merger.state.fields[0].kind, .text)
        XCTAssertEqual(merger.state.format, .anthropic)
    }

    func testAnthropicErrorWritesLastError() {
        var merger = merger()
        _ = merger.consume([
            event(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        ])
        XCTAssertEqual(merger.state.lastError, "Overloaded")
        XCTAssertTrue(merger.state.fields.isEmpty)
        XCTAssertEqual(merger.state.parsedEventCount, 1)
        XCTAssertEqual(merger.state.unparsedEventCount, 0)
    }

    // MARK: 计数口径

    func testNonJSONDataCountsAsUnparsed() {
        var merger = merger()
        _ = merger.consume([
            event("[DONE]"),
            event("plain text"),
            event(""),
            event(#"{"choices":[{"delta":{"content":"x"}}]}"#)
        ])

        XCTAssertEqual(merger.state.unparsedEventCount, 3)
        XCTAssertEqual(merger.state.parsedEventCount, 1)
        XCTAssertEqual(merger.state.fields.count, 1)
    }

    func testCustomOnlyFormatWhenNoBuiltinMatches() {
        var merger = merger()
        XCTAssertTrue(merger.addCustomPath("result.text"))
        _ = merger.consume([event(#"{"result":{"text":"hi"}}"#)])

        XCTAssertEqual(merger.state.format, .customOnly)
        XCTAssertEqual(merger.state.fields.count, 1)
        XCTAssertEqual(merger.state.fields[0].kind, .custom)
        XCTAssertEqual(merger.state.fields[0].text, "hi")
        XCTAssertEqual(merger.state.fields[0].displayName, "text")
    }

    func testCustomPathDoesNotDuplicateBuiltinText() {
        var merger = merger()
        _ = merger.addCustomPath("choices[0].delta.content")
        _ = merger.consume([event(#"{"choices":[{"delta":{"content":"hi"}}]}"#)])

        XCTAssertEqual(merger.state.fields.count, 1)
        XCTAssertEqual(merger.state.fields[0].text, "hi", "同一段文本不能被拼两遍")
        XCTAssertEqual(merger.state.fields[0].kind, .text)
    }
}

// MARK: - 与真实分帧器的交接

extension LLMStreamMergerTests {

    /// 把真实 SSE 字节流（chunk 边界刻意切在 JSON 中间与多字节字符中间）喂给归并器。
    /// 单测喂的都是成品 `SSEEvent`，这条用例保证「分帧器 → 归并器」这条真实链路上不会错位。
    func testBytesFromSSEParserLandInTheSameField() {
        let stream = """
        event: message_start
        data: {"type":"message_start","message":{"id":"m1"}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":"你好"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"，世界"}}

        event: message_stop
        data: {"type":"message_stop"}

        data: [DONE]

        """
        let chunks = [
            String(stream.prefix(60)),
            String(stream.dropFirst(60).prefix(37)),
            String(stream.dropFirst(97))
        ]

        var parser = SSEParser()
        var merger = LLMStreamMerger()
        var events: [SSEEvent] = []
        for chunk in chunks {
            events += parser.consume(Data(chunk.utf8))
        }
        events += parser.finish()
        _ = merger.consume(events)

        XCTAssertEqual(merger.state.format, .anthropic)
        XCTAssertEqual(merger.state.fields.count, 1)
        XCTAssertEqual(merger.state.fields[0].path, "content_block[0].text")
        XCTAssertEqual(merger.state.fields[0].text, "你好，世界")
        XCTAssertEqual(merger.state.unparsedEventCount, 1, "只有 [DONE] 不是 JSON")
        XCTAssertEqual(merger.state.selectedPath, "content_block[0].text", "自动选中第一个有内容的字段")
    }

    // MARK: - LangGraph / LangChain agent 块（快照语义）

    /// 用户实测的真实形状：`response.blocks[0].text` 里是整份答案。
    private func langGraphEvent(
        _ text: String,
        role: String = "assistant",
        agent: String = "Default Assistant"
    ) -> SSEEvent {
        let json = """
        {"response": {"role": "\(role)", "additional_kwargs": {},
          "blocks": [{"block_type": "text", "text": \(Self.jsonEncoded(text))}]},
         "structured_response": null, "current_agent_name": "\(agent)",
         "tool_calls": [], "retry_messages": []}
        """
        return SSEEvent(sequence: 1, data: json)
    }

    private static func jsonEncoded(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [text], options: [])
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())   // 去掉外层 []
    }

    func testLangGraphShapeIsRecognizedAndJoinsTextBlock() {
        var merger = LLMStreamMerger()
        _ = merger.consume([langGraphEvent("Hello! How can I help you today?")])

        XCTAssertEqual(merger.state.format, .langGraph)
        XCTAssertEqual(merger.state.parsedEventCount, 1)
        XCTAssertEqual(merger.state.unparsedEventCount, 0)
        XCTAssertEqual(merger.state.fields.count, 1)
        XCTAssertEqual(merger.state.fields[0].path, "response.blocks[0].text")
        XCTAssertEqual(merger.state.fields[0].kind, .text)
        XCTAssertEqual(merger.state.fields[0].text, "Hello! How can I help you today?")
        XCTAssertEqual(merger.state.selectedPath, "response.blocks[0].text")
    }

    /// 关键差异：LangGraph 推的是整份快照，同一段文本会重复出现，不能拼好几遍。
    func testLangGraphRepeatedSnapshotDoesNotDuplicateText() {
        var merger = LLMStreamMerger()
        let full = "Answer: Hello there"
        _ = merger.consume([
            langGraphEvent(full),
            langGraphEvent(full),
            langGraphEvent(full)
        ])

        XCTAssertEqual(merger.state.fields.count, 1)
        XCTAssertEqual(merger.state.fields[0].text, full, "同一份快照重推三次只能有一份")
        XCTAssertEqual(merger.state.fields[0].pieceCount, 1, "重复快照不计新片段")
    }

    /// 逐步变长的快照：新值是旧值的前缀延展 → 替换，最终等于最后一份快照。
    func testLangGraphGrowingSnapshotsReplaceInsteadOfAppending() {
        var merger = LLMStreamMerger()
        _ = merger.consume([
            langGraphEvent("Thought:"),
            langGraphEvent("Thought: I can"),
            langGraphEvent("Thought: I can answer without tools.")
        ])

        XCTAssertEqual(merger.state.fields.count, 1)
        XCTAssertEqual(merger.state.fields[0].text, "Thought: I can answer without tools.")
        XCTAssertEqual(merger.state.fields[0].pieceCount, 3, "三次到达各算一片")
    }

    /// 非前缀延展（同一条消息里换了内容）按增量追加，不丢内容。
    func testLangGraphNonPrefixSnapshotAppends() {
        var merger = LLMStreamMerger()
        _ = merger.consume([langGraphEvent("first"), langGraphEvent("second")])
        XCTAssertEqual(merger.state.fields[0].text, "firstsecond")
    }

    /// 只有 role=assistant + agent 标记才算 LangGraph；普通业务 JSON 不该被误判。
    func testLangGraphShapeRequiresAgentMarkers() {
        let plain = SSEEvent(sequence: 1, data: #"{"response": {"role": "user", "blocks": []}}"#)
        var merger = LLMStreamMerger()
        _ = merger.consume([plain])
        XCTAssertEqual(merger.state.format, .unknown, "role 不是 assistant 就不认")
        XCTAssertTrue(merger.state.fields.isEmpty)

        let noBlocks = SSEEvent(
            sequence: 2,
            data: #"{"response": {"role": "assistant", "content": "hi"}, "current_agent_name": "A"}"#
        )
        var merger2 = LLMStreamMerger()
        _ = merger2.consume([noBlocks])
        XCTAssertEqual(merger2.state.format, .langGraph, "无 blocks 但有 agent 标记也算")
        XCTAssertEqual(merger2.state.fields.first?.path, "response.content")
        XCTAssertEqual(merger2.state.fields.first?.text, "hi")
    }

    /// 工具块的 input 对象按 JSON 文本参与拼接。
    func testLangGraphToolBlockInputIsStringified() {
        let json = """
        {"response": {"role": "assistant", "blocks": [
          {"type": "tool_use", "name": "search", "input": {"q": "postme"}}
        ]}, "current_agent_name": "A"}
        """
        var merger = LLMStreamMerger()
        _ = merger.consume([SSEEvent(sequence: 1, data: json)])
        XCTAssertEqual(merger.state.fields.count, 1)
        XCTAssertEqual(merger.state.fields[0].kind, .toolArguments)
        XCTAssertEqual(merger.state.fields[0].text, #"{"q":"postme"}"#)
    }
}
