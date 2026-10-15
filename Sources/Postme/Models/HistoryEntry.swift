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
}
