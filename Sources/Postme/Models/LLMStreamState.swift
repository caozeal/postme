import Foundation

/// 内置可识别的流来源格式。按**事件形状**判定，不看请求头（真实服务端常不按文档来）。
enum LLMFormat: String, Equatable, Sendable {
    case openAI
    case anthropic
    /// LangGraph / LangChain agent 的流式块：`{"response":{"blocks":[…]}}` 这类**完整快照**。
    ///
    /// 与前两者最关键的差别：它推的是整份状态（同一段文本会在多个事件里重复出现），
    /// 而不是增量 delta。所以累积规则是「新值是旧值的前缀延展就替换，否则追加」，
    /// 不能像 delta 那样无条件拼接——否则同一份答案会被拼成好几遍。
    case langGraph
    /// 形状不认识，但用户自定义路径命中了内容。
    case customOnly
    case unknown
}

/// 字段的语义分类（界面用来区分正文 / 思维链 / 工具参数 / 自定义）。
enum FieldKind: String, Equatable, Sendable {
    case text
    case reasoning
    case toolArguments
    case custom
}

/// 一个字段的拼接累积结果。
///
/// `path` 是字段身份：内置规则与用户自定义路径共用同一命名空间，
/// 只靠字符串相等判定「是不是同一个字段」。
struct LLMFieldAccumulator: Equatable, Sendable, Identifiable {
    /// 规范化后的字段路径，如 `choices[0].delta.content`。
    var path: String
    /// 界面显示用的短名，如 `content`。
    var displayName: String
    var kind: FieldKind
    /// 已拼接文本（上限见 `LLMStreamMerger.maxFieldBytes`）。
    var text: String
    /// 贡献过内容的 delta 片数（空串增量不计）。
    var pieceCount: Int
    var lastPieceAt: Date?
    /// 因单字段上限停止追加。已有内容保留。
    var isTruncated: Bool

    var id: String { path }

    init(
        path: String,
        displayName: String,
        kind: FieldKind,
        text: String = "",
        pieceCount: Int = 0,
        lastPieceAt: Date? = nil,
        isTruncated: Bool = false
    ) {
        self.path = path
        self.displayName = displayName
        self.kind = kind
        self.text = text
        self.pieceCount = pieceCount
        self.lastPieceAt = lastPieceAt
        self.isTruncated = isTruncated
    }
}

/// SSE 响应里「按字段拼接」的运行期状态。与 `stream.events` 一样不落盘。
struct LLMStreamState: Equatable, Sendable {
    var format: LLMFormat = .unknown
    /// 按首次出现顺序排列。
    var fields: [LLMFieldAccumulator] = []
    /// `data` 能解成 JSON 的事件数（无论形状是否识别）。
    var parsedEventCount: Int = 0
    /// `data` 不是 JSON 的事件数（`[DONE]`、纯文本、空串）。
    var unparsedEventCount: Int = 0
    /// 主区域拼接的字段；nil = 尚未选择（自动选第一个有内容的字段）。
    var selectedPath: String?
    /// 用户自定义路径（规范化、去重、保序）。
    var customPaths: [String] = []
    /// 因 `maxFields` 上限被忽略的字段数。
    var droppedFieldCount: Int = 0
    /// 流内 `error` 事件的消息（Anthropic）。
    var lastError: String?

    /// 主区域当前字段；`selectedPath` 指向尚未产出的字段时为 nil。
    var selectedField: LLMFieldAccumulator? {
        guard let selectedPath else { return nil }
        return fields.first { $0.path == selectedPath }
    }
}
