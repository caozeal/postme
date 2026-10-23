import Foundation

/// 把已分帧的 `SSEEvent` 按字段路径累积成拼接文本（纯 Foundation，无 UI）。
///
/// 三条容易写错的规则，实现按此执行：
///
/// 1. **计数口径只有一个**：`data` 能解成 JSON → `parsedEventCount`；解不成 → `unparsedEventCount`。
///    形状不认识但 JSON 合法 → 算 parsed，不产字段，**不**计入 unparsed。
///    字段级的 `null` / 非字符串 / 空串是「本次没有增量」，**不碰任何计数器**。
/// 2. **Anthropic 的字段路径是拼出来的**，不是下钻得到的：事件 JSON 里根本没有 `content_block`
///    数组。所以内置规则不能复用「下钻取值再回头拼路径」的写法（那会拼出 `delta.text` 之类）；
///    路径直接由事件自身的 `index` 与 delta 类型拼成，与自定义路径的合并只靠字符串相等。
/// 3. **路径里的下标是具体数字**：`<i>` / `<j>` 是设计文档里的元变量，落进 `path` 的必须是
///    `0`、`1` 这样的数字（`content_block[0].text`），裸 `i` 进路径即 bug。
struct LLMStreamMerger: Sendable {

    /// 单字段拼接文本上限（UTF-8 字节）。到顶停止追加并置 `isTruncated`，已有内容保留。
    static let maxFieldBytes = 512 * 1024
    /// 字段数量上限。超出的**新**字段被忽略并计入 `droppedFieldCount`。
    static let maxFields = 64
    /// 自定义路径条数上限。
    static let maxCustomPaths = 16

    private(set) var state = LLMStreamState()

    /// 每个字段已占用的 UTF-8 字节数。放在 merger 而不是模型里：模型是契约，
    /// 且 `String.utf8.count` 每次重算是 O(n)，长流下会变成平方级。
    private var fieldByteCounts: [String: Int] = [:]
    /// 已因字段上限被丢弃的路径（去重计数，避免同一路径每来一次就 +1）。
    private var droppedPaths: Set<String> = []
    /// 自定义路径的解析结果（与 `state.customPaths` 同序）。
    private var customSteps: [(path: String, steps: [PathStep])] = []

    init() {}

    // MARK: - 对外接口

    /// 追加一批已分帧事件；返回本次是否有字段内容增长（供节流器判断要不要发布）。
    @discardableResult
    mutating func consume(_ events: [SSEEvent]) -> Bool {
        var grew = false
        for event in events {
            grew = ingest(event) || grew
        }
        autoSelectIfNeeded()
        return grew
    }

    /// 设置/切换主区域字段。`path` 不在 `fields` 里时只记录选择，
    /// 等后续事件真的产出该字段即可累积（不预建空字段，空字段会白占 `maxFields` 名额）。
    mutating func select(_ path: String?) {
        guard let path else {
            state.selectedPath = nil
            return
        }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state.selectedPath = nil
            return
        }
        state.selectedPath = Self.canonicalPath(trimmed) ?? trimmed
    }

    /// 添加自定义路径。语法非法、超出条数上限返回 false；重复添加返回 true 但不重复入列。
    mutating func addCustomPath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let steps = Self.parsePath(trimmed) else { return false }
        let canonical = Self.canonicalPath(steps)
        if state.customPaths.contains(canonical) { return true }
        guard state.customPaths.count < Self.maxCustomPaths else { return false }
        state.customPaths.append(canonical)
        customSteps.append((canonical, steps))
        return true
    }

    /// 删除自定义路径。
    mutating func removeCustomPath(_ path: String) {
        let canonical = Self.canonicalPath(path) ?? path
        state.customPaths.removeAll { $0 == canonical }
        customSteps.removeAll { $0.path == canonical }
    }

    /// 新的 SSE 响应开始时重置运行期状态。自定义路径是用户配置，保留。
    mutating func reset() {
        let customPaths = state.customPaths
        state = LLMStreamState()
        state.customPaths = customPaths
        fieldByteCounts.removeAll()
        droppedPaths.removeAll()
    }

    // MARK: - 逐事件归并

    private mutating func ingest(_ event: SSEEvent) -> Bool {
        guard let root = Self.parseJSON(event.data) else {
            state.unparsedEventCount += 1
            return false
        }
        state.parsedEventCount += 1
        return ingestJSON(root, at: event.receivedAt)
    }

    private mutating func ingestJSON(_ root: Any, at date: Date) -> Bool {
        var grew = false
        var producedHere: Set<String> = []
        var customHit = false

        if let dict = root as? [String: Any] {
            if let choices = dict["choices"] as? [Any] {
                recognize(.openAI)
                grew = applyOpenAI(choices: choices, at: date, produced: &producedHere) || grew
            } else if let type = dict["type"] as? String, Self.isAnthropicType(type) {
                recognize(.anthropic)
                grew = applyAnthropic(dict, type: type, at: date, produced: &producedHere) || grew
            } else if Self.isLangGraphShape(dict) {
                recognize(.langGraph)
                grew = applyLangGraph(dict, at: date, produced: &producedHere) || grew
            }
        }

        // 自定义路径：内置规则已经产出过的同一路径跳过，避免同一段文本被拼两遍。
        for (path, steps) in customSteps where !producedHere.contains(path) {
            guard let piece = Self.value(at: steps, in: root) as? String, !piece.isEmpty else { continue }
            customHit = true
            let appended = append(
                path: path,
                displayName: Self.shortName(for: path),
                kind: .custom,
                piece: piece,
                at: date
            )
            grew = appended || grew
        }

        if customHit, state.format == .unknown { state.format = .customOnly }
        return grew
    }

    private mutating func recognize(_ format: LLMFormat) {
        switch state.format {
        case .unknown, .customOnly:
            state.format = format
        case .openAI, .anthropic, .langGraph:
            break
        }
    }

    private static func isAnthropicType(_ type: String) -> Bool {
        // 字面的 "error" 也是 Anthropic 事件类型；漏了它会把流内错误静默吞掉。
        type == "error"
            || type.hasPrefix("content_block_")
            || type.hasPrefix("message_")
    }

    // MARK: - LangGraph / LangChain agent 块

    /// 形状判定：`{"response": {…}}` 里有 agent 消息标记。
    ///
    /// 真实形状（用户实测）：
    /// ```json
    /// {"response": {"role": "assistant", "blocks": [{"block_type": "text", "text": "…"}]},
    ///  "structured_response": null, "current_agent_name": "Default Assistant", "tool_calls": []}
    /// ```
    /// 与 OpenAI / Anthropic 的 delta 不同，它推的是**整份状态快照**：同一段文本会在多个事件里
    /// 重复出现。所以累积走 `.snapshot`（见 `Accumulation`），不能无条件拼接。
    static func isLangGraphShape(_ dict: [String: Any]) -> Bool {
        guard let response = dict["response"] as? [String: Any] else { return false }
        let isAssistant = response["role"] as? String == "assistant"
        let hasAgentMarker = dict["current_agent_name"] != nil
            || dict["structured_response"] != nil
            || response["tool_calls"] != nil
        // `blocks` 是 LangGraph 消息块的强特征；但光有 blocks 不够——
        // 任意业务 JSON 都可能有 `response: { blocks: [] }`，必须再要求
        // 「assistant 消息」或「agent 标记字段」，否则会误判成 LangGraph。
        if response["blocks"] is [Any] { return isAssistant || hasAgentMarker }
        return isAssistant && hasAgentMarker
    }

    private mutating func applyLangGraph(
        _ root: [String: Any],
        at date: Date,
        produced: inout Set<String>
    ) -> Bool {
        var grew = false
        guard let response = root["response"] as? [String: Any] else { return false }
        let prefix = "response"

        if let text = response["content"] as? String, !text.isEmpty {
            let path = "\(prefix).content"
            produced.insert(path)
            grew = append(
                path: path,
                displayName: "content",
                kind: .text,
                piece: text,
                at: date,
                mode: .snapshot
            ) || grew
        }

        // `blocks` 是 LangGraph 的结构化消息块：文本 / 思维链 / 工具调用参数各成一条路径。
        if let blocks = response["blocks"] as? [Any] {
            for (index, blockAny) in blocks.enumerated() {
                guard let block = blockAny as? [String: Any],
                      let blockType = block["type"] as? String ?? block["block_type"] as? String
                else { continue }

                let (field, kind): (String, FieldKind)
                switch blockType {
                case "text", "text_delta": (field, kind) = ("text", .text)
                case "thinking", "reasoning": (field, kind) = ("thinking", .reasoning)
                case "tool_use", "input_json_delta": (field, kind) = ("input", .toolArguments)
                default: continue
                }

                // 值可能是字符串，也可能是已解析的对象（tool_use 的 input）。
                let value: String?
                switch block[field] {
                case let s as String: value = s
                case let obj as [String: Any]:
                    value = try? Self.stringify(obj)
                case let arr as [Any]:
                    value = try? Self.stringify(arr)
                default: value = nil
                }
                guard let text = value, !text.isEmpty else { continue }

                let path = "\(prefix).blocks[\(index)].\(field)"
                produced.insert(path)
                grew = append(
                    path: path,
                    displayName: blockType == "text" || blockType == "text_delta"
                        ? "text"
                        : "\(blockType).\(field)",
                    kind: kind,
                    piece: text,
                    at: date,
                    mode: .snapshot
                ) || grew
            }
        }

        return grew
    }

    /// 把块里的对象/数组按其原始键顺序无关地序列化（展示用，不参与语义）。
    private static func stringify(_ any: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: any, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - OpenAI

    private mutating func applyOpenAI(
        choices: [Any],
        at date: Date,
        produced: inout Set<String>
    ) -> Bool {
        var grew = false
        for (position, choiceAny) in choices.enumerated() {
            guard let choice = choiceAny as? [String: Any],
                  let delta = choice["delta"] as? [String: Any] else { continue }
            // 流式响应里 `choices` 通常只有一个元素，且它自带的 `index` 才是真实 choice 下标
            // （服务端可以只推其中一路）。缺 `index` 时退回数组位置。
            let choiceIndex = choice["index"] as? Int ?? position
            let prefix = "choices[\(choiceIndex)].delta"

            for (key, kind) in Self.openAITextKeys {
                let path = "\(prefix).\(key)"
                if let piece = delta[key] as? String, !piece.isEmpty {
                    produced.insert(path)
                    grew = append(path: path, displayName: key, kind: kind, piece: piece, at: date) || grew
                }
            }

            guard let calls = delta["tool_calls"] as? [Any] else { continue }
            for (position, callAny) in calls.enumerated() {
                guard let call = callAny as? [String: Any],
                      let function = call["function"] as? [String: Any],
                      let arguments = function["arguments"] as? String,
                      !arguments.isEmpty else { continue }
                // 同 choice：流式 `tool_calls` 自带 `index`（可只推一个增量），缺省退回位置。
                let callIndex = call["index"] as? Int ?? position
                let path = "\(prefix).tool_calls[\(callIndex)].function.arguments"
                produced.insert(path)
                grew = append(
                    path: path,
                    displayName: "tool_calls[\(callIndex)].function.arguments",
                    kind: .toolArguments,
                    piece: arguments,
                    at: date
                ) || grew
            }
        }
        return grew
    }

    private static let openAITextKeys: [(String, FieldKind)] = [
        ("content", .text),
        ("reasoning_content", .reasoning),
        ("reasoning", .reasoning)
    ]

    // MARK: - Anthropic

    private mutating func applyAnthropic(
        _ root: [String: Any],
        type: String,
        at date: Date,
        produced: inout Set<String>
    ) -> Bool {
        switch type {
        case "content_block_delta":
            guard let index = root["index"] as? Int,
                  let delta = root["delta"] as? [String: Any],
                  let deltaType = delta["type"] as? String else { return false }
            switch deltaType {
            case "text_delta":
                return appendAnthropic(index: index, name: "text", kind: .text, value: delta["text"], date: date, produced: &produced)
            case "thinking_delta":
                return appendAnthropic(index: index, name: "thinking", kind: .reasoning, value: delta["thinking"], date: date, produced: &produced)
            case "input_json_delta":
                return appendAnthropic(index: index, name: "partial_json", kind: .toolArguments, value: delta["partial_json"], date: date, produced: &produced)
            default:
                // `signature_delta` 是正常事件但不是可读文本；未知 delta 类型同理。
                return false
            }

        case "content_block_start":
            // 首段文本必须落进与后续 `content_block_delta` **完全相同**的路径：
            // 用该事件自身的 `index` 拼，不做下钻。
            guard let index = root["index"] as? Int,
                  let block = root["content_block"] as? [String: Any],
                  let text = block["text"] as? String, !text.isEmpty else { return false }
            let path = "content_block[\(index)].text"
            produced.insert(path)
            return append(path: path, displayName: "text", kind: .text, piece: text, at: date)

        case "error":
            if let error = root["error"] as? [String: Any] {
                state.lastError = error["message"] as? String ?? error["type"] as? String
            } else if let message = root["error"] as? String {
                state.lastError = message
            }
            return false

        default:
            // `message_start` / `message_delta` / `message_stop` / `ping`：不产字段、不计 unparsed。
            return false
        }
    }

    private mutating func appendAnthropic(
        index: Int,
        name: String,
        kind: FieldKind,
        value: Any?,
        date: Date,
        produced: inout Set<String>
    ) -> Bool {
        guard let piece = value as? String, !piece.isEmpty else { return false }
        let path = "content_block[\(index)].\(name)"
        produced.insert(path)
        return append(path: path, displayName: name, kind: kind, piece: piece, at: date)
    }

    /// 一段内容到达时的累积语义。
    enum Accumulation: Sendable {
        /// 增量：直接拼接（OpenAI / Anthropic 的 delta、自定义路径）。
        case delta
        /// 完整快照：本次值是累积结果的前缀延展，替换；否则追加（LangGraph agent 块）。
        case snapshot
    }

    // MARK: - 累积与上限

    private mutating func append(
        path: String,
        displayName: String,
        kind: FieldKind,
        piece: String,
        at date: Date,
        mode: Accumulation = .delta
    ) -> Bool {
        guard !piece.isEmpty else { return false }

        var index: Int
        if let existing = state.fields.firstIndex(where: { $0.path == path }) {
            index = existing
        } else {
            guard state.fields.count < Self.maxFields else {
                if droppedPaths.insert(path).inserted { state.droppedFieldCount += 1 }
                return false
            }
            state.fields.append(
                LLMFieldAccumulator(path: path, displayName: displayName, kind: kind)
            )
            fieldByteCounts[path] = 0
            index = state.fields.count - 1
        }

        var field = state.fields[index]
        guard !field.isTruncated else { return false }

        // 快照语义：同一份全文重复推送时不能拼第二遍。
        // - 新值 == 现有累积 → 无变化（真实 LangGraph 每步都重推整份状态）
        // - 新值以现有累积开头 → 更长的一份快照，整体替换（等价于「增量 = 新值后缀」）
        // - 否则 → 不属于同一段内容的延续，按增量追加，不丢内容
        if mode == .snapshot, !field.text.isEmpty, piece.hasPrefix(field.text) {
            if field.text == piece { return false }
            field.text = ""
            fieldByteCounts[path] = 0
        }

        let used = fieldByteCounts[path] ?? field.text.utf8.count
        let remaining = max(0, Self.maxFieldBytes - used)
        let pieceBytes = piece.utf8.count

        if pieceBytes <= remaining {
            field.text += piece
            field.pieceCount += 1
            field.lastPieceAt = date
            fieldByteCounts[path] = used + pieceBytes
            state.fields[index] = field
            return true
        }

        // 到顶：只吃下能放下的前缀（按字符边界切，不切开 UTF-8 标量），之后不再追加。
        var prefix = ""
        var taken = 0
        for scalar in piece.unicodeScalars {
            let length = Self.utf8Length(of: scalar)
            if taken + length > remaining { break }
            prefix.unicodeScalars.append(scalar)
            taken += length
        }
        if !prefix.isEmpty {
            field.text += prefix
            field.pieceCount += 1
            field.lastPieceAt = date
        }
        field.isTruncated = true
        fieldByteCounts[path] = used + taken
        state.fields[index] = field
        return !prefix.isEmpty
    }

    private mutating func autoSelectIfNeeded() {
        guard state.selectedPath == nil else { return }
        guard let first = state.fields.first(where: { !$0.text.isEmpty }) else { return }
        state.selectedPath = first.path
    }

    // MARK: - 路径文法
    //
    // path    := segment ( "." segment )*
    // segment := name ( "[" index "]" )*
    // name    := [A-Za-z0-9_-]+
    // index   := [0-9]+
    //
    // 刻意不支持 `*` / 引号 / 过滤器：通配符会引出「多值如何拼」的语义问题。

    enum PathStep: Equatable, Sendable {
        case key(String)
        case index(Int)
    }

    /// 解析路径；非法返回 nil。
    static func parsePath(_ path: String) -> [PathStep]? {
        guard !path.isEmpty else { return nil }
        var steps: [PathStep] = []
        var cursor = path.startIndex

        while true {
            var name = ""
            while cursor < path.endIndex, isNameCharacter(path[cursor]) {
                name.append(path[cursor])
                cursor = path.index(after: cursor)
            }
            guard !name.isEmpty else { return nil }
            steps.append(.key(name))

            while cursor < path.endIndex, path[cursor] == "[" {
                cursor = path.index(after: cursor)
                var digits = ""
                while cursor < path.endIndex, path[cursor].isASCII, path[cursor].isNumber {
                    digits.append(path[cursor])
                    cursor = path.index(after: cursor)
                }
                guard !digits.isEmpty,
                      cursor < path.endIndex, path[cursor] == "]",
                      let value = Int(digits) else { return nil }
                cursor = path.index(after: cursor)
                steps.append(.index(value))
            }

            if cursor == path.endIndex { break }
            guard path[cursor] == "." else { return nil }
            cursor = path.index(after: cursor)
        }
        return steps
    }

    /// 规范化路径串（下标去掉前导零）；非法返回 nil。
    static func canonicalPath(_ path: String) -> String? {
        guard let steps = parsePath(path) else { return nil }
        return canonicalPath(steps)
    }

    static func canonicalPath(_ steps: [PathStep]) -> String {
        var result = ""
        for step in steps {
            switch step {
            case .key(let name):
                if !result.isEmpty { result += "." }
                result += name
            case .index(let value):
                result += "[\(value)]"
            }
        }
        return result
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        guard character.isASCII else { return false }
        return character.isLetter || character.isNumber || character == "_" || character == "-"
    }

    private static func utf8Length(of scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0..<0x80: return 1
        case 0x80..<0x800: return 2
        case 0x800..<0x10000: return 3
        default: return 4
        }
    }

    // MARK: - JSON 取值

    private static func parseJSON(_ text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// 逐段下钻；中途类型不符返回 nil（该事件不产片段，不崩、不计数）。
    static func value(at steps: [PathStep], in root: Any) -> Any? {
        var current: Any = root
        for step in steps {
            switch step {
            case .key(let name):
                guard let dict = current as? [String: Any], let next = dict[name] else { return nil }
                current = next
            case .index(let index):
                guard let array = current as? [Any], index >= 0, index < array.count else { return nil }
                current = array[index]
            }
        }
        return current
    }

    /// 自定义字段的短名：路径最后一段（`a.b` → `b`）。
    private static func shortName(for path: String) -> String {
        path.split(separator: ".").last.map(String.init) ?? path
    }
}
