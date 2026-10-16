import Foundation

/// 响应头（保留名称与值，按名称排序展示）。
struct HTTPHeader: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var value: String

    init(id: UUID = UUID(), name: String, value: String) {
        self.id = id
        self.name = name
        self.value = value
    }
}

/// 请求各阶段耗时（秒）。取自 URLSessionTaskMetrics，缺失的阶段为 nil。
struct RequestTiming {
    var dns: TimeInterval?
    var tcp: TimeInterval?
    var tls: TimeInterval?
    /// 首字节时间（TTFB）：requestStart -> responseStart。
    var ttfb: TimeInterval?
    /// 响应体下载耗时：responseStart -> responseEnd。
    var transfer: TimeInterval?
    var total: TimeInterval

    init(
        dns: TimeInterval? = nil,
        tcp: TimeInterval? = nil,
        tls: TimeInterval? = nil,
        ttfb: TimeInterval? = nil,
        transfer: TimeInterval? = nil,
        total: TimeInterval = 0
    ) {
        self.dns = dns
        self.tcp = tcp
        self.tls = tls
        self.ttfb = ttfb
        self.transfer = transfer
        self.total = total
    }

    /// 从 URLSessionTaskMetrics 提取各阶段耗时。取最后一次 transaction（重定向会多次）。
    static func from(metrics: URLSessionTaskMetrics?, wallClock: TimeInterval) -> RequestTiming {
        var t = RequestTiming()
        t.total = metrics.map { $0.taskInterval.duration } ?? wallClock
        guard let tx = metrics?.transactionMetrics.last else { return t }
        t.dns = diff(tx.domainLookupStartDate, tx.domainLookupEndDate)
        t.tcp = diff(tx.connectStartDate, tx.connectEndDate)
        t.tls = diff(tx.secureConnectionStartDate, tx.secureConnectionEndDate)
        t.ttfb = diff(tx.requestStartDate, tx.responseStartDate)
        t.transfer = diff(tx.responseStartDate, tx.responseEndDate)
        return t
    }

    private static func diff(_ start: Date?, _ end: Date?) -> TimeInterval? {
        guard let start, let end else { return nil }
        let d = end.timeIntervalSince(start)
        return d >= 0 ? d : nil
    }
}

/// 一次请求的响应结果。
struct APIResponse {
    let statusCode: Int
    let headers: [HTTPHeader]
    let body: Data
    let mimeType: String?
    let timing: RequestTiming
    let receivedAt: Date
    /// 实际请求的最终 URL（跟随重定向后）。
    let finalURL: URL?
    /// 响应体因超过 `RequestExecutorOptions.maxResponseBytes` 被截断（只拿到前一段）。
    /// 与展示层的截断不同：这里数据本身就没收全，任何解析都必须当作不完整。
    var isBodyTruncated: Bool = false
    /// 截断时生效的上限，用于如实说明"超过了多少"。0 表示未截断。
    var bodyLimitBytes: Int = 0

    /// 超过该大小的响应体在界面上截断展示，避免主线程卡死。
    static let displayTruncationThreshold = 2 * 1024 * 1024
    /// 超过该大小的响应体不做 JSON 语法高亮。
    static let highlightSizeLimit = 1024 * 1024

    init(
        statusCode: Int,
        headers: [HTTPHeader],
        body: Data,
        mimeType: String?,
        timing: RequestTiming,
        receivedAt: Date = Date(),
        finalURL: URL? = nil,
        isBodyTruncated: Bool = false,
        bodyLimitBytes: Int = 0
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.mimeType = mimeType
        self.timing = timing
        self.receivedAt = receivedAt
        self.finalURL = finalURL
        self.isBodyTruncated = isBodyTruncated
        self.bodyLimitBytes = bodyLimitBytes
    }

    /// 从 HTTPURLResponse 构造。
    init(http: HTTPURLResponse, body: Data, metrics: URLSessionTaskMetrics?, wallClock: TimeInterval) {
        self.init(
            statusCode: http.statusCode,
            headers: APIResponse.headers(from: http),
            body: body,
            mimeType: http.mimeType,
            timing: RequestTiming.from(metrics: metrics, wallClock: wallClock),
            receivedAt: Date(),
            finalURL: http.url
        )
    }

    private static func headers(from http: HTTPURLResponse) -> [HTTPHeader] {
        http.allHeaderFields
            .compactMap { key, value -> HTTPHeader? in
                guard let name = key as? String else { return nil }
                return HTTPHeader(name: name, value: "\(value)")
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var bodySize: Int { body.count }

    var isSuccess: Bool { (200..<300).contains(statusCode) }

    /// 状态码的原因短语。不用 HTTPURLResponse.localizedString——它返回的是
    /// "no error" 这类系统错误串，200 会显示成 "No Error"，不适合展示。
    var statusText: String {
        switch statusCode {
        case 100: return "Continue"
        case 101: return "Switching Protocols"
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 203: return "Non-Authoritative Information"
        case 204: return "No Content"
        case 205: return "Reset Content"
        case 206: return "Partial Content"
        case 300: return "Multiple Choices"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 303: return "See Other"
        case 304: return "Not Modified"
        case 307: return "Temporary Redirect"
        case 308: return "Permanent Redirect"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 402: return "Payment Required"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 406: return "Not Acceptable"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 410: return "Gone"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 418: return "I'm a teapot"
        case 422: return "Unprocessable Entity"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return ""
        }
    }

    /// 按 MIME 类型判断是否可按文本展示。
    var isTextLike: Bool {
        if let mimeType {
            let m = mimeType.lowercased()
            return m.hasPrefix("text/")
                || m.contains("json")
                || m.contains("xml")
                || m.contains("javascript")
                || m.contains("x-www-form-urlencoded")
                || m.contains("html")
        }
        // 无 MIME 时，尝试按 UTF-8 解码判断
        return String(data: body, encoding: .utf8) != nil
    }

    /// UTF-8 文本（二进制响应为 nil）。
    var textBody: String? { String(data: body, encoding: .utf8) }

    /// 是否应按 JSON 处理（MIME 命中或正文以 { / [ 开头）。
    var looksLikeJSON: Bool {
        if let mimeType, mimeType.lowercased().contains("json") { return true }
        guard let text = textBody else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
    }

    /// 界面展示用文本：文本类返回正文，二进制返回占位说明。
    var displayText: String {
        if let s = textBody { return s }
        let kb = Double(bodySize) / 1024.0
        return "（二进制响应，\(String(format: "%.1f", kb)) KB，无法以文本展示）"
    }

    /// 响应体展示文本：尽可能美化 JSON；超过阈值则先截断再展示，避免主线程卡死。
    /// 调用方（AppState）在收到响应时计算一次并缓存，不要在视图 body 里反复调用。
    func displayBodyText() -> String {
        let limit = APIResponse.displayTruncationThreshold
        // 传输层已截断（超过 maxResponseBytes，数据本身没收全）时，无论如何都不能当完整内容处理：
        // 美化半截 JSON 必然失败，失败后回退原文又会让人以为这就是全部响应。
        var truncated = isBodyTruncated
        let raw: String

        if isBodyTruncated {
            raw = String(decoding: body.prefix(limit), as: UTF8.self)
        } else if body.count > limit {
            raw = String(decoding: body.prefix(limit), as: UTF8.self)
            truncated = true
        } else {
            raw = displayText
        }

        var text = raw
        if !truncated, looksLikeJSON, let pretty = JSONTools.pretty(raw) {
            text = pretty
        }
        if isBodyTruncated {
            let limitText = bodyLimitBytes > 0 ? formatBytes(bodyLimitBytes) : "配置"
            text += "\n\n…（响应体超过 \(limitText) 上限，已停止接收；以上为前 \(formatBytes(body.count))）"
        } else if truncated {
            text += "\n\n…（响应体 \(formatBytes(bodySize)) 过大，已截断显示）"
        }
        return text
    }
}
