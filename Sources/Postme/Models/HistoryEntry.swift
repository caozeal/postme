import Foundation

/// 一条请求历史记录：发送时的请求快照 + 结果摘要。
struct HistoryEntry: Identifiable, Codable, Hashable {
    var id: UUID
    var requestName: String
    var method: HTTPMethod
    var url: String
    var statusCode: Int?
    var duration: TimeInterval?
    var succeeded: Bool
    var timestamp: Date
    /// 完整请求快照，用于「从历史恢复」。
    var request: APIRequest

    init(
        id: UUID = UUID(),
        request: APIRequest,
        statusCode: Int?,
        duration: TimeInterval?,
        succeeded: Bool,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.requestName = request.name
        self.method = request.method
        self.url = request.url
        self.statusCode = statusCode
        self.duration = duration
        self.succeeded = succeeded
        self.timestamp = timestamp
        self.request = request
    }

    /// 容错解码（见 `TolerantDecoding.swift`）：历史是纯展示数据，
    /// 单条脏记录不该作废整个工作区。缺失的展示字段由请求快照回填。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let request = c.tolerant(.request, APIRequest())
        self.init(
            id: c.tolerant(.id, UUID()),
            request: request,
            statusCode: c.tolerantOptional(.statusCode),
            duration: c.tolerantOptional(.duration),
            succeeded: c.tolerant(.succeeded, false),
            timestamp: c.tolerant(.timestamp, Date())
        )
        // 展示字段优先取文件里的值（历史快照可能与当前请求对象不同），缺失再回填。
        self.requestName = c.tolerant(.requestName, request.name)
        self.method = c.tolerant(.method, request.method)
        self.url = c.tolerant(.url, request.url)
    }
}
