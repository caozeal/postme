import Foundation

/// HTTP 方法。
enum HTTPMethod: String, Codable, CaseIterable, Identifiable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    case head = "HEAD"
    case options = "OPTIONS"

    var id: String { rawValue }

    /// 该方法的请求是否通常需要 body（仅用于界面提示）。
    var typicallyHasBody: Bool {
        switch self {
        case .post, .put, .patch: return true
        default: return false
        }
    }
}

/// 通用键值行。headers / query params / form fields 共用。
struct KeyValueItem: Identifiable, Codable, Hashable {
    var id: UUID
    var isEnabled: Bool
    var key: String
    var value: String

    init(id: UUID = UUID(), isEnabled: Bool = true, key: String = "", value: String = "") {
        self.id = id
        self.isEnabled = isEnabled
        self.key = key
        self.value = value
    }

    /// 容错解码：缺字段不使整份工作区作废（见 `TolerantDecoding.swift`）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: c.tolerant(.id, UUID()),
            isEnabled: c.tolerant(.isEnabled, true),
            key: c.tolerant(.key, ""),
            value: c.tolerant(.value, "")
        )
    }
}

/// 一次请求的完整描述。v1 中所有字段值在发送前由 VariableResolver 完成 {{var}} 替换。
struct APIRequest: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var method: HTTPMethod
    var url: String
    var headers: [KeyValueItem]
    var queryParams: [KeyValueItem]
    var bodyKind: BodyKind
    /// json / rawText 模式下的正文字符串。
    var bodyText: String
    /// rawText 模式下的 Content-Type（json 模式固定 application/json）。
    var rawContentType: String
    /// formURLEncoded / multipart 模式下的表单键值。
    var formFields: [KeyValueItem]
    /// multipart 模式下的文件字段。
    var fileFields: [FileField]
    /// binary 模式下的本地文件路径。
    var binaryFilePath: String
    /// binary 模式的 Content-Type。
    var binaryContentType: String
    /// 手动 Cookie 行。发送前合并成一个 `Cookie` 头。
    var cookies: [KeyValueItem]
    /// RESTful 路径参数（URL 里的 `{name}` / `:name`）。
    var pathParams: [KeyValueItem]
    /// 认证配置。发送前由 `AuthApplier` 物化成等效的 Header / Query。
    var auth: RequestAuth

    init(
        id: UUID = UUID(),
        name: String = "未命名请求",
        method: HTTPMethod = .get,
        url: String = "",
        headers: [KeyValueItem] = [],
        queryParams: [KeyValueItem] = [],
        bodyKind: BodyKind = .none,
        bodyText: String = "",
        rawContentType: String = "text/plain",
        formFields: [KeyValueItem] = [],
        fileFields: [FileField] = [],
        binaryFilePath: String = "",
        binaryContentType: String = "application/octet-stream",
        cookies: [KeyValueItem] = [],
        pathParams: [KeyValueItem] = [],
        auth: RequestAuth = RequestAuth()
    ) {
        self.id = id
        self.name = name
        self.method = method
        self.url = url
        self.headers = headers
        self.queryParams = queryParams
        self.bodyKind = bodyKind
        self.bodyText = bodyText
        self.rawContentType = rawContentType
        self.formFields = formFields
        self.fileFields = fileFields
        self.binaryFilePath = binaryFilePath
        self.binaryContentType = binaryContentType
        self.cookies = cookies
        self.pathParams = pathParams
        self.auth = auth
    }

    /// 深拷贝一份（换新 id），用于「另存为」或从集合加载到编辑器工作副本。
    func copyWithNewID() -> APIRequest {
        var c = self
        c.id = UUID()
        c.headers = headers.map { KeyValueItem(id: UUID(), isEnabled: $0.isEnabled, key: $0.key, value: $0.value) }
        c.queryParams = queryParams.map { KeyValueItem(id: UUID(), isEnabled: $0.isEnabled, key: $0.key, value: $0.value) }
        c.formFields = formFields.map { KeyValueItem(id: UUID(), isEnabled: $0.isEnabled, key: $0.key, value: $0.value) }
        c.fileFields = fileFields.map { FileField(id: UUID(), isEnabled: $0.isEnabled, name: $0.name, path: $0.path) }
        c.cookies = cookies.map { KeyValueItem(id: UUID(), isEnabled: $0.isEnabled, key: $0.key, value: $0.value) }
        c.pathParams = pathParams.map { KeyValueItem(id: UUID(), isEnabled: $0.isEnabled, key: $0.key, value: $0.value) }
        return c
    }

    /// 容错解码：字段级问题（缺失 / 类型不符 / 未知枚举）退回默认值，
    /// 不让单个脏字段作废整份工作区。见 `TolerantDecoding.swift`。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: c.tolerant(.id, UUID()),
            name: c.tolerant(.name, "未命名请求"),
            method: c.tolerant(.method, .get),
            url: c.tolerant(.url, ""),
            headers: c.tolerant(.headers, []),
            queryParams: c.tolerant(.queryParams, []),
            bodyKind: c.tolerant(.bodyKind, .none),
            bodyText: c.tolerant(.bodyText, ""),
            rawContentType: c.tolerant(.rawContentType, "text/plain"),
            formFields: c.tolerant(.formFields, []),
            fileFields: c.tolerant(.fileFields, []),
            binaryFilePath: c.tolerant(.binaryFilePath, ""),
            binaryContentType: c.tolerant(.binaryContentType, "application/octet-stream"),
            cookies: c.tolerant(.cookies, []),
            pathParams: c.tolerant(.pathParams, []),
            // 旧文件没有 auth 键：容错解码得到 `.none`，不会让请求变空。
            auth: c.tolerant(.auth, RequestAuth())
        )
    }
}
