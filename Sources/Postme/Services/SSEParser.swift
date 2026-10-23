import Foundation

/// 一条已分帧的 SSE 事件。
///
/// `id` 是**行内**唯一标识（给 SwiftUI 的 `ForEach` 用），与 SSE 协议里的 `id:` 字段无关；
/// 协议字段在 `eventID`。
struct SSEEvent: Identifiable, Hashable, Sendable {
    let id: UUID
    /// 从 1 开始，按派发顺序递增，跨 chunk 连续。
    let sequence: Int
    /// `event:` 字段；nil 表示规范默认的 "message"。
    let eventType: String?
    /// `id:` 字段（规范里是「last event ID buffer」，会延续到后续事件）。
    let eventID: String?
    /// 多行 `data` 以 "\n" 连接。
    let data: String
    let receivedAt: Date
    /// 流关闭时该事件没有以空行收尾（由 `finish()` 派发）。
    let isUnterminated: Bool

    init(
        id: UUID = UUID(),
        sequence: Int,
        eventType: String? = nil,
        eventID: String? = nil,
        data: String,
        receivedAt: Date = Date(),
        isUnterminated: Bool = false
    ) {
        self.id = id
        self.sequence = sequence
        self.eventType = eventType
        self.eventID = eventID
        self.data = data
        self.receivedAt = receivedAt
        self.isUnterminated = isUnterminated
    }
}

/// `text/event-stream` 的增量解析器（WHATWG HTML 的 event stream 格式）。
///
/// 三条关键约束：
///
/// 1. **按字节分帧，不按 chunk 解码**。网络 chunk 的边界与 UTF-8 字符边界、行边界都无关；
///    若在每个 chunk 上先 `String(data:encoding:)` 再按行切，多字节字符会被切成 U+FFFD，
///    一个 `\r\n` 被拆到两个 chunk 时还会被误读成两个空行（凭空多出一条事件）。
///    所以这里持有未完成行的**原始字节**，遇到行结束符才解码。
/// 2. **chunk 末尾的孤立 `\r` 要留到下一个 chunk 判断**：它是 `\r\n` 的前半还是单独的行尾，
///    只有看到下一个字节才知道（见 `pendingCarriageReturn`）。
/// 3. **`finish()` 派发未收尾事件**（偏离规范：规范要求丢弃）。调试工具里「最后一条事件
///    凭空消失」看起来就是 bug；改为派发并置 `isUnterminated`，由界面如实标注。
///
/// 纯 Foundation，无并发状态，便于脱离传输层单测。
struct SSEParser {

    private static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    // MARK: 行分帧状态

    /// 当前未完成行的原始字节（未解码）。
    private var lineBytes: [UInt8] = []
    /// 上一个字节是 `\r`，已按行尾处理；若紧跟 `\n` 则吞掉它（`\r\n` 只算一个行尾）。
    private var pendingCarriageReturn = false

    // MARK: BOM 探测状态

    /// 流开头的探测缓冲（最多 3 字节）；未决时字节先存在这里，判断完再喂给行分帧。
    private var bomProbe: [UInt8] = []
    private var bomResolved = false

    // MARK: 事件缓冲（规范里的三个 buffer）

    private var dataLines: [String] = []
    private var eventType: String?
    /// 规范的 last event ID buffer：**不**在派发时清空，会延续到后续事件。
    private var lastEventID: String?
    private var nextSequence = 1

    init() {}

    /// 喂入一段原始字节，返回本次新派发的事件（可能为空）。
    mutating func consume(_ data: Data) -> [SSEEvent] {
        guard !data.isEmpty else { return [] }
        var events: [SSEEvent] = []
        for byte in data {
            if !bomResolved {
                bomProbe.append(byte)
                if bomProbe.count >= Self.bom.count || byte != Self.bom[bomProbe.count - 1] {
                    bomResolved = true
                    let isBOM = bomProbe == Self.bom
                    let prefix = isBOM ? [] : bomProbe
                    bomProbe.removeAll(keepingCapacity: true)
                    for pending in prefix { feed(pending, into: &events) }
                }
                continue
            }
            feed(byte, into: &events)
        }
        return events
    }

    /// 流结束（正常结束、取消、传输中断都算）：冲刷残留字节并派发未收尾事件。
    ///
    /// 残留的**不完整行**也按一行处理：流若以 `data: {"x":1}`（没有换行）结束，
    /// 那条事件的内容仍然存在，丢掉它等于把最后一条数据藏起来。
    mutating func finish() -> [SSEEvent] {
        var events: [SSEEvent] = []

        if !bomResolved {
            bomResolved = true
            let prefix = bomProbe == Self.bom ? [] : bomProbe
            bomProbe.removeAll(keepingCapacity: true)
            for pending in prefix { feed(pending, into: &events) }
        }

        if !lineBytes.isEmpty {
            let line = String(decoding: lineBytes, as: UTF8.self)
            lineBytes.removeAll(keepingCapacity: true)
            process(line: line, into: &events)
        }
        pendingCarriageReturn = false

        dispatch(into: &events, unterminated: true)
        return events
    }

    // MARK: - 分帧

    private mutating func feed(_ byte: UInt8, into events: inout [SSEEvent]) {
        switch byte {
        case 0x0D:  // \r
            endLine(into: &events)
            pendingCarriageReturn = true
        case 0x0A:  // \n
            if pendingCarriageReturn {
                // `\r\n` 的后半：行已经在 \r 处结束过，不能再算一次空行。
                pendingCarriageReturn = false
            } else {
                endLine(into: &events)
            }
        default:
            pendingCarriageReturn = false
            lineBytes.append(byte)
        }
    }

    private mutating func endLine(into events: inout [SSEEvent]) {
        let line = String(decoding: lineBytes, as: UTF8.self)
        lineBytes.removeAll(keepingCapacity: true)
        process(line: line, into: &events)
    }

    // MARK: - 字段解析

    private mutating func process(line: String, into events: inout [SSEEvent]) {
        if line.isEmpty {
            dispatch(into: &events, unterminated: false)
            return
        }
        // 以 `:` 开头是注释（心跳常用的 `: ping`）。
        if line.hasPrefix(":") { return }

        let field: String
        var value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[line.startIndex..<colon])
            var remainder = line[line.index(after: colon)...]
            // 冒号后**最多**去掉一个空格：`data:  x` 的值是 " x"。
            if remainder.hasPrefix(" ") { remainder = remainder.dropFirst() }
            value = String(remainder)
        } else {
            // 没有冒号的整行是字段名，值为空。
            field = line
            value = ""
        }

        switch field {
        case "data":
            dataLines.append(value)
        case "event":
            eventType = value
        case "id":
            // 规范：值里含 U+0000 时整个字段忽略（不覆盖已有的 last event ID）。
            if !value.contains("\0") { lastEventID = value }
        default:
            // `retry:` 与未知字段都忽略：不自动重连，重试间隔对调试无意义。
            break
        }
    }

    private mutating func dispatch(into events: inout [SSEEvent], unterminated: Bool) {
        // 没有 data 行的块不产生事件（纯注释块、只有 `id:`/`event:` 的块）。
        // 注意 `data:`（值为空）算有 data 行，按规范派发一条 data 为空串的事件。
        guard !dataLines.isEmpty else {
            eventType = nil
            return
        }

        events.append(
            SSEEvent(
                sequence: nextSequence,
                eventType: eventType,
                eventID: lastEventID,
                data: dataLines.joined(separator: "\n"),
                receivedAt: Date(),
                isUnterminated: unterminated
            )
        )
        nextSequence += 1
        dataLines.removeAll(keepingCapacity: true)
        eventType = nil
    }
}
