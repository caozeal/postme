import Foundation
import UniformTypeIdentifiers

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
    /// 选了文件 Body / 文件字段，但路径为空。
    case fileMissing
    /// 文件不存在或不可读。参数是用户填的路径。
    case fileUnreadable(String)
    /// 文件超过上传上限。参数是路径与上限字节数。
    case fileTooLarge(String, Int)
    /// multipart 的 boundary 必须与实际正文一致。
    case multipartContentTypeConflict

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
        case .fileMissing:
            return l10n(.failureFileMissing)
        case .fileUnreadable(let path):
            return l10n(.failureFileUnreadable, path)
        case .fileTooLarge(let path, let limit):
            return l10n(.failureFileTooLarge, ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file), path)
        case .multipartContentTypeConflict:
            return l10n(.failureMultipartContentTypeConflict)
        }
    }
}

/// 响应头快照：`.head` 在第一个正文字节之前发出，只发一次。
///
/// 单独成类型而不是直接给 `APIResponse`：头到达时 body 还不存在，也没有 timing
/// （metrics 要等 task 结束才有）。SSE 的识别只依赖这里的 `mimeType`。
struct ResponseHead: Sendable, Equatable {
    let statusCode: Int
    let headers: [HTTPHeader]
    /// `HTTPURLResponse.mimeType`——已去掉 `; charset=...` 等参数。
    let mimeType: String?
    /// 跟随重定向后的最终 URL。
    let finalURL: URL?

    init(statusCode: Int, headers: [HTTPHeader], mimeType: String?, finalURL: URL?) {
        self.statusCode = statusCode
        self.headers = headers
        self.mimeType = mimeType
        self.finalURL = finalURL
    }

    init(http: HTTPURLResponse) {
        self.init(
            statusCode: http.statusCode,
            headers: APIResponse.headers(from: http),
            mimeType: http.mimeType,
            finalURL: http.url
        )
    }

    /// 是否为 `text/event-stream`。
    ///
    /// 先看 `mimeType`（URLSession 已去参数并小写化），为空时回退解析 `Content-Type` 头。
    /// 不要求请求带 `Accept: text/event-stream`：真实世界里很多服务端照样返回 SSE。
    var isEventStream: Bool {
        if let mimeType, !mimeType.isEmpty {
            return Self.isEventStreamMIME(mimeType)
        }
        guard let raw = headers.first(where: { $0.name.lowercased() == "content-type" })?.value else {
            return false
        }
        return Self.isEventStreamMIME(raw)
    }

    /// MIME 部分（去参数、trim、小写）等于 `text/event-stream`。
    static func isEventStreamMIME(_ raw: String) -> Bool {
        let mime = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
        return mime.trimmingCharacters(in: .whitespaces).lowercased() == "text/event-stream"
    }
}

/// 一次请求在传输层的增量更新。
enum RequestUpdate: Sendable {
    /// 响应头到达（body 之前，只发一次）。
    case head(ResponseHead)
    /// 增量正文字节（原始字节，未解码）。
    case chunk(Data)
    /// 终态；body 为累积内容（可能已截断）。
    case finished(APIResponse)
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
    private var streamContinuations: [Int: AsyncThrowingStream<RequestUpdate, Error>.Continuation] = [:]
    private var startDates: [Int: Date] = [:]
    private var liveTasks: [Int: URLSessionTask] = [:]
    /// 已经发出过 `.head` 的 task：`didReceive response:` 对 multipart 等情形可能多次回调，
    /// 而契约是「只发一次」。
    private var headSentTasks: Set<Int> = []
    /// 因超过 `maxResponseBytes` 被主动取消的 task：完成回调里要把这种取消
    /// 转成"部分响应 + 截断标记"，而不是报错。
    private var truncatedTasks: Set<Int> = []
    /// 被用户主动取消的 task。
    private var userCancelledTasks: Set<Int> = []
    /// task → 发起方的 token（页签 id）。
    ///
    /// **为什么需要**：多页签下可能有多个请求同时在飞，而「取消」只该作用于
    /// 用户眼前的那一格。没有 token 就只能全取消，等于两个页签一起被打断。
    private var taskTokens: [Int: UUID] = [:]

    init(options: RequestExecutorOptions = RequestExecutorOptions()) {
        self.options = options
        super.init()

        let config = URLSessionConfiguration.ephemeral
        // 只设**空闲**超时：`timeoutIntervalForRequest` 在每次收到数据后重置，
        // 服务端沉默超过 options.timeout 秒才算超时。
        config.timeoutIntervalForRequest = options.timeout
        // 刻意不设 `timeoutIntervalForResource`：它保持 URLSession 默认值（7 天）。
        // 曾经的 `max(options.timeout, 300)` 会在 300 秒硬切任何响应——SSE 因此完全不可用，
        // 缓慢但持续有数据的普通下载也会被截断。内存已由 `maxResponseBytes` 硬约束，
        // 「总时长」对调试工具没有意义，「无数据」才是真正的挂死。
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

    // MARK: - 超时语义（供测试断言）

    /// URLSession 对 `timeoutIntervalForResource` 的默认值（7 天）。
    static let defaultResourceTimeout: TimeInterval = 60 * 60 * 24 * 7

    /// 实际生效的 session 配置副本。
    ///
    /// 「资源总时长上限已移除」是这一轮的关键决定，但不可能真等 5 分钟去证明它。
    /// 所以把配置暴露出来，让测试断言我们没有覆盖默认值。
    var sessionConfiguration: URLSessionConfiguration { session.configuration }

    /// 资源总时长是否已回到 URLSession 默认（即没有硬上限）。
    var resourceTimeoutIsUnlimited: Bool {
        session.configuration.timeoutIntervalForResource >= Self.defaultResourceTimeout
    }

    /// 空闲超时（服务端沉默多久算挂死）。等于 `options.timeout`。
    var idleTimeout: TimeInterval { session.configuration.timeoutIntervalForRequest }

    // MARK: - 发送

    /// 组装并发送请求，返回**一次性**结果。
    ///
    /// 实现为 `sendStreaming` 的薄封装：只有一条传输路径，取消/截断/传输错误的分类
    /// 全部在 delegate 侧收口，不会因为两套状态机而分叉。
    ///
    /// `token` 是发起方（页签）的 id：`cancel(token:)` 只打断同一 token 的在飞请求。
    func send(_ request: APIRequest, token: UUID? = nil) async throws -> APIResponse {
        for try await update in sendStreaming(request, token: token) {
            if case .finished(let response) = update { return response }
        }
        // 流以正常方式结束却没有终态：不该发生，如实报错而不是编一个响应。
        throw RequestFailure.unexpected
    }

    /// 流式发送：`.head` → 若干 `.chunk` → `.finished`。
    ///
    /// 终止语义：
    /// - 正常结束：`.finished(APIResponse)` 后流结束。
    /// - 用户取消：流以 `RequestFailure.cancelled` 结束（与 `send()` 历史行为一致）。
    /// - 传输错误：以 `RequestFailure.transport` 结束；`.head` 可能已经发出。
    /// - 超过 `maxResponseBytes`：`finished` + `isBodyTruncated`，**不是**错误。
    ///
    /// 流的 `bufferingPolicy` 保持默认无界：delegate 队列 `maxConcurrentOperationCount = 1`，
    /// 若在这里等消费者就会把整个 URLSession 的 delegate 回调堵死（见设计 §6.1 第 3 条）。
    /// 内存上界由 `maxResponseBytes` 与消费者的节流发布共同保证。
    func sendStreaming(_ request: APIRequest, token: UUID? = nil) -> AsyncThrowingStream<RequestUpdate, Error> {
        let urlRequest: URLRequest
        do {
            urlRequest = try Self.buildURLRequest(request, options: options)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }

        return AsyncThrowingStream { continuation in
            let task = self.session.dataTask(with: urlRequest)
            let identifier = task.taskIdentifier

            self.lock.lock()
            self.streamContinuations[identifier] = continuation
            self.startDates[identifier] = Date()
            self.liveTasks[identifier] = task
            if let token { self.taskTokens[identifier] = token }
            self.lock.unlock()

            // 消费者提前终止（`for await` 被 break、任务被取消）时停掉 task，
            // 否则连接会一直挂着等超时。
            continuation.onTermination = { [weak self] termination in
                guard let self else { return }
                if case .cancelled = termination {
                    self.lock.lock()
                    let task = self.liveTasks[identifier]
                    self.lock.unlock()
                    task?.cancel()
                }
            }

            task.resume()
        }
    }

    /// 取消在飞请求（用户点「取消」或按 ⌘.）。
    ///
    /// 取消是**用户意图**，不是失败：完成回调会以 `RequestFailure.cancelled` 结束，
    /// 由调用方静默处理。`token` 为 nil 时取消全部在飞请求。
    /// 返回被取消的 task 数量（0 表示没有符合条件的在飞请求）。
    @discardableResult
    func cancel(token: UUID? = nil) -> Int {
        lock.lock()
        // 先清掉"上一次取消时标记、但那之后已完成"的 task id。
        // 这类条目不会自然消失：标记与完成回调可能交错，留下一个永不匹配的 id。
        // 只清已完成（已从 liveTasks 移除）的，绝不碰仍在飞的——否则完成回调
        // 会把用户取消误判成传输错误。
        userCancelledTasks.formIntersection(liveTasks.keys)

        let identifiers = liveTasks.keys.filter { identifier in
            guard let token else { return true }
            return taskTokens[identifier] == token
        }
        let tasks = identifiers.compactMap { liveTasks[$0] }
        for identifier in identifiers {
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

    /// 单个上传文件的大小上限。
    ///
    /// 文件是**整份读进内存**再交给 URLSession 的（这样 Content-Length、重定向与
    /// 取消行为都可预测）。调试工具不该因为选错一个几百 MB 的镜像把内存打满，
    /// 所以这里设硬上限并明确报错，而不是静默截断——截断的文件发出去更难排查。
    static let maxUploadFileBytes = 64 * 1024 * 1024

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
            guard !userProvidedContentType else { throw RequestFailure.multipartContentTypeConflict }
            let items = source.formFields.filter { $0.isEnabled && !$0.key.isEmpty }
            let files = source.fileFields.filter { $0.isEnabled && !$0.name.isEmpty }
            let boundary = "----postmeBoundary\(UUID().uuidString)"
            request.httpBody = try multipartBody(fields: items, files: files, boundary: boundary)
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        case .binary:
            let path = source.binaryFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { throw RequestFailure.fileMissing }
            request.httpBody = try readUploadFile(path)
            if !userProvidedContentType {
                let type = source.binaryContentType.trimmingCharacters(in: .whitespacesAndNewlines)
                request.setValue(type.isEmpty ? "application/octet-stream" : type,
                                 forHTTPHeaderField: "Content-Type")
            }
        }
    }

    /// 读取上传文件：先看大小再读，避免为了报错先把几百 MB 拉进内存。
    static func readUploadFile(_ rawPath: String) throws -> Data {
        let path = (rawPath as NSString).expandingTildeInPath
        guard !path.isEmpty else { throw RequestFailure.fileMissing }

        let manager = FileManager.default
        guard let attrs = try? manager.attributesOfItem(atPath: path),
              (attrs[.type] as? FileAttributeType) == .typeRegular else {
            throw RequestFailure.fileUnreadable(rawPath)
        }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        guard size <= maxUploadFileBytes else {
            throw RequestFailure.fileTooLarge(rawPath, maxUploadFileBytes)
        }

        do {
            // mappedIfSafe：大文件尽量走 mmap，避免多一份完整拷贝。
            return try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        } catch {
            throw RequestFailure.fileUnreadable(rawPath)
        }
    }

    /// 按扩展名推断 MIME。推断不出来时用 `application/octet-stream`（RFC 2046 的默认值）。
    static func mimeType(for path: String) -> String {
        let ext = URL(fileURLWithPath: path).pathExtension
        guard !ext.isEmpty,
              let type = UTType(filenameExtension: ext),
              let mime = type.preferredMIMEType else {
            return "application/octet-stream"
        }
        return mime
    }

    /// 组装 multipart/form-data：文本字段 + 文件字段。
    /// 关键：必须用 CRLF，且以 `--boundary--` 收尾。
    private static func multipartBody(fields: [KeyValueItem], files: [FileField], boundary: String) throws -> Data {
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

        for file in files {
            let path = file.resolvedPath
            guard !path.isEmpty else { throw RequestFailure.fileMissing }
            let fileData = try readUploadFile(path)
            let fileName = URL(fileURLWithPath: path).lastPathComponent

            append("--\(boundary)\(crlf)")
            append("Content-Disposition: form-data; name=\"\(escapeDispositionName(file.name))\"; filename=\"\(escapeDispositionName(fileName))\"\(crlf)")
            append("Content-Type: \(mimeType(for: path))\(crlf)\(crlf)")
            data.append(fileData)
            append(crlf)
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

    /// 响应头到达。**必须无条件调用 completionHandler**——漏调会让任务永久挂起。
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let identifier = dataTask.taskIdentifier
        var continuation: AsyncThrowingStream<RequestUpdate, Error>.Continuation?
        if let http = response as? HTTPURLResponse {
            lock.lock()
            let shouldEmit = headSentTasks.insert(identifier).inserted
            if shouldEmit { continuation = streamContinuations[identifier] }
            lock.unlock()
            if shouldEmit {
                continuation?.yield(.head(ResponseHead(http: http)))
            }
        }
        completionHandler(.allow)
    }

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
            let continuation = streamContinuations[identifier]
            lock.unlock()
            // 截断点之前的字节仍是真实收到的内容，照常 yield；
            // 被丢掉的尾部不 yield（消费者不该看到没进 body 的字节）。
            continuation?.yield(.chunk(Data(data.prefix(remaining))))
            if shouldCancel { task?.cancel() }
            return
        }

        buffers[identifier] = existing + data
        let continuation = streamContinuations[identifier]
        lock.unlock()
        continuation?.yield(.chunk(data))
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
        let continuation = streamContinuations.removeValue(forKey: identifier)
        let wasTruncated = truncatedTasks.remove(identifier) != nil
        let wasUserCancelled = userCancelledTasks.remove(identifier) != nil
        headSentTasks.remove(identifier)
        liveTasks.removeValue(forKey: identifier)
        taskTokens.removeValue(forKey: identifier)
        lock.unlock()

        guard let continuation else { return }

        // 用户主动取消：静默结束，不是错误。
        if wasUserCancelled, error != nil {
            continuation.finish(throwing: RequestFailure.cancelled)
            return
        }

        // 超上限是我们自己取消的：若已拿到 HTTP 响应，就返回**部分响应**并标记截断；
        // 没有响应头（还在连接阶段）才按传输错误处理。
        if wasTruncated, let http = task.response as? HTTPURLResponse {
            let wallClock = Date().timeIntervalSince(start)
            var response = APIResponse(http: http, body: buffer, metrics: metrics, wallClock: wallClock)
            response.isBodyTruncated = true
            response.bodyLimitBytes = options.maxResponseBytes
            continuation.yield(.finished(response))
            continuation.finish()
            return
        }

        if let error {
            continuation.finish(throwing: RequestFailure.transport(error))
            return
        }

        guard let http = task.response as? HTTPURLResponse else {
            continuation.finish(throwing: RequestFailure.unexpected)
            return
        }

        let wallClock = Date().timeIntervalSince(start)
        let response = APIResponse(http: http, body: buffer, metrics: metrics, wallClock: wallClock)
        continuation.yield(.finished(response))
        continuation.finish()
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
