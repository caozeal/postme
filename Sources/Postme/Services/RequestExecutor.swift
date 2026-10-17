import Foundation

/// 请求执行失败。
///
/// 不再实现 `LocalizedError.errorDescription`：那会返回硬编码中文串，
/// 在英文界面下泄漏出去。调用方用 `message(_:)` 按当前语言取文案。
enum RequestFailure: Error {
    case invalidURL(String)
    case transport(Error)
    /// 用户主动取消。**不是错误**：调用方应静默回到空闲，不报错、不记历史。
    case cancelled
    case unexpected

    /// 面向用户的说明。`.transport` 保留系统给的 `localizedDescription`
    /// （那是系统语言，跟着用户走）。
    func message(_ l10n: Localizer) -> String {
        switch self {
        case .invalidURL(let raw):
            return raw.isEmpty ? l10n(.failureEmptyURL) : l10n(.failureInvalidURL, raw)
        case .transport(let error):
            return error.localizedDescription
        case .cancelled:
            return l10n(.failureCancelled)
        case .unexpected:
            return l10n(.failureUnexpected)
        }
    }
}

/// 执行器配置。
struct RequestExecutorOptions: Equatable {
    var timeout: TimeInterval
    var followRedirects: Bool
    var allowInsecureTLS: Bool
    /// 单个响应体最多驻留的字节数。
    ///
    /// 展示层的截断阈值（`APIResponse.displayTruncationThreshold`）只影响**显示文本**，
    /// 不影响内存——实测一个 120 MB 的响应会让 phys_footprint 从 2 MB 涨到 147 MB，
    /// 与"省内存"这个立身之本直接冲突。所以这里在**传输层**设硬上限：
    /// 超出即停止累积、取消该 task，并如实标记截断。
    var maxResponseBytes: Int

    init(
        timeout: TimeInterval = 30,
        followRedirects: Bool = true,
        allowInsecureTLS: Bool = false,
        maxResponseBytes: Int = RequestExecutorOptions.defaultMaxResponseBytes
    ) {
        self.timeout = timeout
        self.followRedirects = followRedirects
        self.allowInsecureTLS = allowInsecureTLS
        self.maxResponseBytes = maxResponseBytes
    }

    static let defaultMaxResponseBytes = 16 * 1024 * 1024
}

/// 基于 URLSession 的请求执行器。
///
/// 刻意不用 `URLSession.data(for:)`——那个 API 拿不到 `URLSessionTaskMetrics`，
/// 也就无法给出 DNS/TCP/TLS/TTFB 各阶段耗时。这里走 delegate 路径，在
/// `didFinishCollecting` 里捕获 metrics。
///
/// 注意：本类只依赖 Foundation，不 import SwiftUI，保持 Services 层与 UI 解耦，
/// 也便于独立编译做网络层验证。
final class RequestExecutor: NSObject, URLSessionDataDelegate {

    private let options: RequestExecutorOptions
    private let lock = NSLock()
    private var session: URLSession!

    // 以下状态均由 lock 保护（delegate 队列与调用方线程都会访问）
    private var buffers: [Int: Data] = [:]
    private var taskMetrics: [Int: URLSessionTaskMetrics] = [:]
    private var continuations: [Int: CheckedContinuation<APIResponse, Error>] = [:]
    private var startDates: [Int: Date] = [:]
    private var liveTasks: [Int: URLSessionTask] = [:]
    /// 因超过 `maxResponseBytes` 被主动取消的 task：完成回调里要把这种取消
    /// 转成"部分响应 + 截断标记"，而不是报错。
    private var truncatedTasks: Set<Int> = []
    /// 被用户主动取消的 task。
    private var userCancelledTasks: Set<Int> = []

    init(options: RequestExecutorOptions = RequestExecutorOptions()) {
        self.options = options
        super.init()

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = options.timeout
        config.timeoutIntervalForResource = max(options.timeout, 300)
        // 调试器应展示"你实际发出的请求"：不携带 cookie、不读本地缓存。
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "dev.postme.executor.delegate"
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// 显式失效。
    ///
    /// URLSession 会**强引用**其 delegate,而 delegate 就是本对象,构成
    /// `executor → session → executor` 的循环引用——只要不 invalidate,
    /// 旧执行器就永远不会走到 deinit。切换设置（超时/重定向/证书开关）重建执行器时,
    /// 调用方必须显式调用本方法,否则每次切换都会泄漏一个 URLSession。
    func invalidate() {
        session.invalidateAndCancel()
    }

    // MARK: - 发送

    /// 组装并发送请求。request 中的变量应已由调用方完成替换。
    func send(_ request: APIRequest) async throws -> APIResponse {
        let urlRequest = try Self.buildURLRequest(request, options: options)

        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: urlRequest)
            let identifier = task.taskIdentifier

            lock.lock()
            continuations[identifier] = continuation
            startDates[identifier] = Date()
            liveTasks[identifier] = task
            lock.unlock()

            task.resume()
        }
    }

    /// 取消当前在飞请求（用户点「取消」或按 ⌘.）。
    ///
    /// 取消是**用户意图**，不是失败：完成回调会以 `RequestFailure.cancelled` 结束，
    /// 由调用方静默处理。返回被取消的 task 数量（0 表示没有在飞请求）。
    @discardableResult
    func cancel() -> Int {
        lock.lock()
        // 先清掉"上一次取消时标记、但那之后已完成"的 task id。
        // 这类条目不会自然消失：标记与完成回调可能交错，留下一个永不匹配的 id。
        // 只清已完成（已从 liveTasks 移除）的，绝不碰仍在飞的——否则完成回调
        // 会把用户取消误判成传输错误。
        userCancelledTasks.formIntersection(liveTasks.keys)

        let tasks = Array(liveTasks.values)
        for identifier in liveTasks.keys {
            userCancelledTasks.insert(identifier)
        }
        lock.unlock()

        for task in tasks { task.cancel() }
        return tasks.count
    }

    // MARK: - URLRequest 组装

    static func buildURLRequest(_ source: APIRequest, options: RequestExecutorOptions) throws -> URLRequest {
        let trimmed = source.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              comps.host?.isEmpty == false
        else {
            throw RequestFailure.invalidURL(trimmed)
        }

        Self.appendQuery(to: &comps, params: source.queryParams)

        guard let url = comps.url else { throw RequestFailure.invalidURL(trimmed) }

        var request = URLRequest(url: url)
        request.httpMethod = source.method.rawValue
        request.timeoutInterval = options.timeout

        var userProvidedContentType = false
        for header in source.headers where header.isEnabled && !header.key.isEmpty {
            if header.key.lowercased() == "content-type" { userProvidedContentType = true }
            request.setValue(header.value, forHTTPHeaderField: header.key)
        }

        try Self.applyBody(to: &request, source: source, userProvidedContentType: userProvidedContentType)
        return request
    }

    /// 界面上「最终 URL」预览用的最终 URL 字符串。
    ///
    /// **刻意与 `buildURLRequest` 共用 `appendQuery`**：否则预览会与实际发送分叉。
    /// 曾出现过这个分叉——预览走 `URLComponents.queryItems`（不编码 `+`），
    /// 而发送走 `FormEncoding`（编码为 `%2B`），于是预览显示 `phone=+86…`
    /// 而服务端实际收到 `phone=%2B86…`，对调试工具是误导。
    static func previewURL(_ source: APIRequest) -> String {
        let trimmed = source.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var comps = URLComponents(string: trimmed) else { return trimmed }
        Self.appendQuery(to: &comps, params: source.queryParams)
        return comps.url?.absoluteString ?? trimmed
    }

    /// 把启用的 query 参数合并进 URLComponents（发送与预览的唯一实现）。
    private static func appendQuery(to comps: inout URLComponents, params: [KeyValueItem]) {
        let enabled = params.filter { $0.isEnabled && !$0.key.isEmpty }
        guard !enabled.isEmpty else { return }

        let appended = FormEncoding.queryString(enabled.map { (key: $0.key, value: $0.value) })
        // 用 percentEncodedQuery 拼接而非 queryItems——后者会把 URL 里已有的 query
        // 解码再编码，且不编码 `+`（见 FormEncoding 的说明）。
        if let existing = comps.percentEncodedQuery, !existing.isEmpty {
            comps.percentEncodedQuery = existing + "&" + appended
        } else {
            comps.percentEncodedQuery = appended
        }
    }

    private static func applyBody(to request: inout URLRequest, source: APIRequest, userProvidedContentType: Bool) throws {
        switch source.bodyKind {
        case .none:
            return

        case .json, .rawText:
            // 即使正文为空也要带上 Content-Type：空 body 的 JSON POST 是真实存在的请求，
            // 少了这个头无法复现。
            if source.bodyText.isEmpty {
                request.httpBody = Data()
            } else {
                guard let data = source.bodyText.data(using: .utf8) else {
                    throw RequestFailure.unexpected
                }
                request.httpBody = data
            }
            if !userProvidedContentType {
                let contentType = source.bodyKind == .json
                    ? "application/json"
                    : (source.rawContentType.isEmpty ? "text/plain" : source.rawContentType)
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }

        case .formURLEncoded:
            let items = source.formFields.filter { $0.isEnabled && !$0.key.isEmpty }
            // 用 FormEncoding 而非 URLComponents：后者不编码 `+`，
            // 会让值里的 `+` 被服务端当成空格（见 FormEncoding 说明）。
            let encoded = FormEncoding.queryString(items.map { (key: $0.key, value: $0.value) })
            request.httpBody = Data(encoded.utf8)
            if !userProvidedContentType {
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }

        case .multipart:
            let items = source.formFields.filter { $0.isEnabled && !$0.key.isEmpty }
            let boundary = "----postmeBoundary\(UUID().uuidString)"
            request.httpBody = multipartBody(fields: items, boundary: boundary)
            if !userProvidedContentType {
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            }
        }
    }

    /// 组装 multipart/form-data（v1 仅文本字段，不含文件）。
    /// 关键：必须用 CRLF，且以 `--boundary--` 收尾。
    private static func multipartBody(fields: [KeyValueItem], boundary: String) -> Data {
        let crlf = "\r\n"
        var data = Data()

        func append(_ string: String) {
            data.append(Data(string.utf8))
        }

        for field in fields {
            append("--\(boundary)\(crlf)")
            append("Content-Disposition: form-data; name=\"\(escapeDispositionName(field.key))\"\(crlf)\(crlf)")
            append("\(field.value)\(crlf)")
        }
        append("--\(boundary)--\(crlf)")
        return data
    }

    /// multipart 的 name 是 quoted-string，含 `"` 或 CR/LF 会破坏 part 结构。
    /// 按 RFC 2183：`\` 与 `"` 用反斜杠转义；CR/LF 直接剔除。
    private static func escapeDispositionName(_ name: String) -> String {
        var result = ""
        result.reserveCapacity(name.count)
        for character in name {
            switch character {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\r", "\n": break
            default: result.append(character)
            }
        }
        return result
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let identifier = dataTask.taskIdentifier

        lock.lock()
        let existing = buffers[identifier] ?? Data()
        let remaining = options.maxResponseBytes - existing.count

        if remaining <= 0 {
            // 已达上限：不再累积，标记截断并取消下载（省带宽与时间）。
            let shouldCancel = truncatedTasks.insert(identifier).inserted
            let task = liveTasks[identifier]
            lock.unlock()
            if shouldCancel { task?.cancel() }
            return
        }

        if data.count > remaining {
            // 这一批超出上限：只保留到上限，标记截断并取消。
            buffers[identifier] = existing + data.prefix(remaining)
            let shouldCancel = truncatedTasks.insert(identifier).inserted
            let task = liveTasks[identifier]
            lock.unlock()
            if shouldCancel { task?.cancel() }
            return
        }

        buffers[identifier] = existing + data
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock()
        taskMetrics[task.taskIdentifier] = metrics
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let identifier = task.taskIdentifier

        lock.lock()
        let buffer = buffers.removeValue(forKey: identifier) ?? Data()
        let metrics = taskMetrics.removeValue(forKey: identifier)
        let start = startDates.removeValue(forKey: identifier) ?? Date()
        let continuation = continuations.removeValue(forKey: identifier)
        let wasTruncated = truncatedTasks.remove(identifier) != nil
        let wasUserCancelled = userCancelledTasks.remove(identifier) != nil
        liveTasks.removeValue(forKey: identifier)
        lock.unlock()

        guard let continuation else { return }

        // 用户主动取消：静默结束，不是错误。
        if wasUserCancelled, error != nil {
            continuation.resume(throwing: RequestFailure.cancelled)
            return
        }

        // 超上限是我们自己取消的：若已拿到 HTTP 响应，就返回**部分响应**并标记截断；
        // 没有响应头（还在连接阶段）才按传输错误处理。
        if wasTruncated, let http = task.response as? HTTPURLResponse {
            let wallClock = Date().timeIntervalSince(start)
            var response = APIResponse(http: http, body: buffer, metrics: metrics, wallClock: wallClock)
            response.isBodyTruncated = true
            response.bodyLimitBytes = options.maxResponseBytes
            continuation.resume(returning: response)
            return
        }

        if let error {
            continuation.resume(throwing: RequestFailure.transport(error))
            return
        }

        guard let http = task.response as? HTTPURLResponse else {
            continuation.resume(throwing: RequestFailure.unexpected)
            return
        }

        let wallClock = Date().timeIntervalSince(start)
        let response = APIResponse(http: http, body: buffer, metrics: metrics, wallClock: wallClock)
        continuation.resume(returning: response)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        resolve(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        resolve(challenge, completionHandler: completionHandler)
    }

    /// 自签证书处理：仅在「忽略证书校验」开关打开时信任服务端证书挑战。
    private func resolve(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if options.allowInsecureTLS,
           challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // 返回 nil 表示不跟随，任务会以该 3xx 响应结束。
        completionHandler(options.followRedirects ? request : nil)
    }
}
