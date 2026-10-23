import Foundation

/// 流式响应的运行期状态（`text/event-stream`）。
enum StreamStatus: Equatable, Sendable {
    case idle
    case streaming
    case closed
    /// 用户主动取消：不是错误，保留已收内容。
    case cancelled
    case failed(String)
}

/// 一条流式响应收到的内容。
///
/// **只在内存里**：事件、原始文本都是几十 KB 到 2 MB 级，落盘会让每次防抖保存
/// 都带上它们，与「省内存」直接冲突。
struct StreamState: Equatable, Sendable {
    /// 最近一次响应是否为 SSE。分页可用性靠它——流结束后 `status` 不再是 `.streaming`，
    /// 但「事件」分页必须还在，否则用户一结束就看不到刚收到的事件了。
    var isEventStream: Bool = false
    var status: StreamStatus = .idle
    /// 环形缓冲，最多 `maxRetainedEvents` 条。
    var events: [SSEEvent] = []
    /// 因环形缓冲上限被丢弃的**较早**事件数（如实计数，界面标注）。
    var droppedEventCount: Int = 0
    /// 已收到的原始文本，上限 `rawTextLimit`，只追加。
    var rawText: String = ""
    /// 已收到的字节数（不受文本上限影响）。
    var receivedBytes: Int = 0
    /// 本次流开始时间。空闲态是构造时刻，只在 `.streaming` 期间有意义。
    var startedAt: Date = Date()
    var endedAt: Date?
    /// 「大模型输出」的按字段拼接状态（运行期，不落盘）。
    ///
    /// 与事件一起按同一个节流窗口落地：`apply(_:)` 里整块接收归并器快照，
    /// 保证界面上的拼接文本与事件列表看到的是同一批字节。
    var llm: LLMStreamState = LLMStreamState()

    static let maxRetainedEvents = 2000
    static let rawTextLimit = 2 * 1024 * 1024

    /// 追加事件并按上限丢弃最旧的。
    mutating func append(_ newEvents: [SSEEvent]) {
        guard !newEvents.isEmpty else { return }
        events.append(contentsOf: newEvents)
        let overflow = events.count - Self.maxRetainedEvents
        if overflow > 0 {
            events.removeFirst(overflow)
            droppedEventCount += overflow
        }
    }

    /// 应用一批节流窗口里的内容：事件进环形缓冲、文本进 `rawText`（到上限为止）、
    /// 字节数照实累加。
    mutating func apply(_ batch: StreamBatch) {
        append(batch.events)
        receivedBytes += batch.bytes
        appendText(batch.text)
        if let llm = batch.llm {
            // 归并器的快照覆盖整个 `llm`，唯一例外是**用户的选择**：
            // 选择可能存在状态里而还没进到快照（例如刚选了一个尚未产出的路径），
            // 覆盖掉会让主区域无端跳回别的字段。
            let selection = self.llm.selectedPath
            self.llm = llm
            if let selection { self.llm.selectedPath = selection }
        }
    }

    /// 追加已解码文本到 `rawText`，最多到 `rawTextLimit`。
    ///
    /// 只在这里封顶：`receivedBytes` 照实累加，所以「文本截断了」与「没收到字节」
    /// 在界面上是可区分的。
    mutating func appendText(_ text: String) {
        guard !text.isEmpty else { return }
        let used = rawText.utf8.count
        guard used < Self.rawTextLimit else { return }
        let remaining = Self.rawTextLimit - used
        if text.utf8.count <= remaining {
            rawText += text
        } else {
            rawText += String(decoding: Array(text.utf8.prefix(remaining)), as: UTF8.self)
        }
    }
}

/// 一个打开中的请求页签（ApiPost 式的多页签编辑）。
///
/// **为什么需要它**：单草稿模型下，从侧栏打开另一个请求只能覆盖编辑器内容，
/// 于是必须弹「当前请求有未保存的修改」逼用户在保存/放弃之间选。有了页签，
/// 打开新请求只是多开一格，旧草稿原地留着——那条弹窗路径连同它的状态机一起消失。
///
/// **只持久化编辑成果**：`id` / `draft` / `nodeID`。运行期状态（响应、是否在发、
/// 分页选择）不落盘——响应体可有十几 MB，写进 workspace.json 会让每次防抖保存
/// 都带上它，与「省内存」直接冲突。
struct EditorTab: Identifiable, Codable {

    /// 页签身份。**不等同于请求 id**：同一个请求的多个副本可以各占一格。
    let id: UUID

    /// 工作副本（编辑器里的内容）。
    var draft: APIRequest

    /// 最近一次「载入 / 保存」时的内容。`draft != baseline` 即未保存修改。
    ///
    /// 与 `draft` 一起持久化：否则重启后所有页签都会被判成「干净」，
    /// 用户明明没保存的改动会被静默当成已落盘。
    var baseline: APIRequest

    /// 绑定的已保存请求节点 id。nil = 还没归属（⌘S 会弹窗命名）。
    var nodeID: UUID?

    // MARK: - 运行期状态（不落盘，每页签各一份）

    /// 请求编辑区的分页（Headers / Params / Body），每个页签各记各的。
    var requestSection: RequestSection = .params
    /// 响应区的分页（Body / 事件 / Headers / 耗时）。
    var responseSection: ResponseSection = .body

    /// 流式响应的运行期状态（SSE 才有内容）。
    var stream: StreamState = StreamState()

    var response: APIResponse?
    /// 响应体展示文本（已按语言美化/截断），收到响应或切换语言时算一次。
    var responseBodyText: String = ""
    var errorMessage: String?
    /// 上一次发送中未能解析的变量名，用于界面提示。
    var unresolvedVariables: [String] = []
    /// 上一次发送中未填写的路径参数名（URL 里的 `{name}` / `:name`）。
    var unresolvedPathParams: [String] = []
    var isSending: Bool = false

    init(id: UUID = UUID(), draft: APIRequest, baseline: APIRequest? = nil, nodeID: UUID? = nil) {
        self.id = id
        self.draft = draft
        self.baseline = baseline ?? draft
        self.nodeID = nodeID
    }

    /// 是否有未保存的修改。
    var isDirty: Bool { draft != baseline }

    /// 清掉与某个请求相关的运行期状态（换请求内容时用）。
    mutating func clearResponse() {
        response = nil
        responseBodyText = ""
        errorMessage = nil
        unresolvedVariables = []
        unresolvedPathParams = []
        // 流式内容必须一起清：否则「清空响应」后事件分页里还留着上一次的事件，
        // 看起来像是新请求收到了数据。
        stream = StreamState()
        // `.llm` 与 `.events` 一样是「只在上一条流里存在」的分页：控件里已经没有它了，
        // 若还停在上面，内容区会按它渲染出一片空白。
        if responseSection == .events || responseSection == .llm { responseSection = .body }
    }

    /// 推进基线：保存之后草稿就是「已落盘内容」。
    mutating func markSaved() {
        baseline = draft
    }

    // MARK: - 持久化

    enum CodingKeys: String, CodingKey {
        case id, draft, baseline, nodeID
    }

    /// 容错解码（见 `TolerantDecoding.swift`）：单个页签解不出来由父级的
    /// `tolerantLossyArray` 丢弃，其余页签照常载入。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: c.tolerant(.id, UUID()),
            draft: c.tolerant(.draft, APIRequest()),
            nodeID: c.tolerantOptional(.nodeID)
        )
        // 基线必须一起读回：缺它的话，重启后每一格都被判成「已保存」，
        // 用户明明没保存的改动会被当成落盘内容（下次 ⌘S 前的脏标记也没了）。
        baseline = c.tolerant(.baseline, draft)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(draft, forKey: .draft)
        try c.encode(baseline, forKey: .baseline)
        try c.encodeIfPresent(nodeID, forKey: .nodeID)
    }
}
