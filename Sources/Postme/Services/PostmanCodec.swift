import Foundation

/// Postman Collection v2.1 的导入 / 导出。
///
/// ApiPost、Postman、Insomnia 都能导出这个格式，作为互通格式足够。
/// 本类型只依赖 Foundation，便于脱离 UI 独立验证。
enum PostmanCodec {

    static let schemaURL = "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"

    /// 解码阶段（拿不到取词器）写入的占位名，出口处替换成当前语言。
    private static let unnamedPlaceholder = "\u{0}unnamed-collection"
    private static let unnamedItemPlaceholder = "\u{0}unnamed-item"

    /// 导入 / 导出失败原因。文案由调用方按当前语言取（见 `CurlCodec.CodecError` 的说明）。
    enum CodecError: Error {
        case notACollection
        case empty
        case noProject

        func message(_ l10n: Localizer) -> String {
            switch self {
            case .notACollection: return l10n(.postmanErrorNotACollection)
            case .empty: return l10n(.postmanErrorEmpty)
            case .noProject: return l10n(.postmanErrorNoProject)
            }
        }
    }

    // MARK: - Postman 数据结构

    struct Collection: Codable {
        var info: Info
        var item: [Item]
        var variable: [Variable]?
        /// 集合级认证：request 未自带 auth 时对全部请求生效。
        var auth: Auth?

        struct Info: Codable {
            var name: String
            var schema: String?
        }

        /// 顶层 `item` 同样逐元素容错：数组里混入一个非对象元素不该让整份集合
        /// 被判为"不是有效集合"（那会把用户整个集合挡在门外）。
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let info = (try? c.decodeIfPresent(Info.self, forKey: .info)) ?? nil
            // 占位名在 `decode(_:l10n:)` 出口统一本地化（解码阶段拿不到取词器）。
            self.info = info ?? Info(name: PostmanCodec.unnamedPlaceholder, schema: nil)
            self.item = c.tolerantLossyArray(.item)
            self.variable = (try? c.decodeIfPresent([Variable].self, forKey: .variable)) ?? nil
            self.auth = (try? c.decodeIfPresent(Auth.self, forKey: .auth)) ?? nil
        }

        init(info: Info, item: [Item], variable: [Variable]?, auth: Auth? = nil) {
            self.info = info
            self.item = item
            self.variable = variable
            self.auth = auth
        }

        enum CodingKeys: String, CodingKey {
            case info, item, variable, auth
        }
    }

    struct Item: Codable {
        var name: String
        /// 文件夹的子项
        var item: [Item]?
        /// 请求节点
        var request: Request?

        init(name: String, item: [Item]? = nil, request: Request? = nil) {
            self.name = name
            self.item = item
            self.request = request
        }

        /// 逐字段容错解码：Postman 允许 `item` 里混入描述性条目等形态，
        /// 单个条目畸形不该让整份文件被判为"不是有效集合"。
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // 子项数组**逐元素**容错：整数组解码时只要有一个非对象元素就会全盘失败，
            // 那会把该层所有兄弟条目一起丢掉。缺失与空数组要区分——前者是请求节点，
            // 后者是空文件夹。
            let children: [Item]? = c.contains(.item) ? c.tolerantLossyArray(.item) : nil
            self.init(
                name: (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil ?? PostmanCodec.unnamedItemPlaceholder,
                item: children,
                request: (try? c.decodeIfPresent(Request.self, forKey: .request)) ?? nil
            )
        }
    }

    /// Postman v2.1 的 `auth`：`type` 决定用哪个子对象描述参数。
    struct Auth: Codable {
        var type: String?
        var bearer: [AuthAttribute]?
        var basic: [AuthAttribute]?
        var apikey: [AuthAttribute]?

        struct AuthAttribute: Codable {
            var key: String?
            var value: String?
        }
    }

    struct Request: Codable {
        var method: String?
        var header: [Header]?
        var url: URLValue?
        var body: Body?
        var auth: Auth?

        init(method: String?, header: [Header]?, url: URLValue?, body: Body?, auth: Auth? = nil) {
            self.method = method
            self.header = header
            self.url = url
            self.body = body
            self.auth = auth
        }

        /// 手写 `init(from:)` 会抑制 CodingKeys 的自动合成，这里显式声明。
        enum CodingKeys: String, CodingKey {
            case method, header, url, body, auth
        }

        /// 容错解码：`request` 既可能是对象（schema `oneOf: object|string`），
        /// 也可能是**字符串形式的 URL**——后者曾被整份拒绝，报"不是有效集合"。
        /// `header` 同理既可能是数组，也可能是原始字符串块。
        init(from decoder: Decoder) throws {
            if let container = try? decoder.singleValueContainer(),
               let string = try? container.decode(String.self) {
                // 字符串形态：等价于一个只有 URL 的 GET 请求
                self.init(method: "GET", header: nil, url: URLValue(raw: string, query: nil), body: nil)
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                method: (try? c.decodeIfPresent(String.self, forKey: .method)) ?? nil,
                header: Self.decodeHeaders(from: c),
                url: (try? c.decodeIfPresent(URLValue.self, forKey: .url)) ?? nil,
                body: (try? c.decodeIfPresent(Body.self, forKey: .body)) ?? nil,
                auth: (try? c.decodeIfPresent(Auth.self, forKey: .auth)) ?? nil
            )
        }

        /// `header` 在 schema 里是 `oneOf: header-list | string`。
        /// 字符串形态按行 `K: V` 解析，避免整份文件被拒。
        private static func decodeHeaders(from container: KeyedDecodingContainer<CodingKeys>) -> [Header]? {
            if let list = (try? container.decodeIfPresent([Header].self, forKey: .header)) ?? nil {
                return list
            }
            guard let raw = (try? container.decodeIfPresent(String.self, forKey: .header)) ?? nil else {
                return nil
            }
            let parsed: [Header] = raw
                .split(whereSeparator: { $0.isNewline })
                .compactMap { line in
                    let text = line.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty, let colon = text.firstIndex(of: ":") else { return nil }
                    let key = String(text[text.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                    let value = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    guard !key.isEmpty else { return nil }
                    return Header(key: key, value: value)
                }
            return parsed.isEmpty ? nil : parsed
        }
    }

    struct Header: Codable {
        var key: String
        var value: String?
        var disabled: Bool?

        init(key: String, value: String? = nil, disabled: Bool? = nil) {
            self.key = key
            self.value = value
            self.disabled = disabled
        }
    }

    /// Postman 的 url 既可能是字符串，也可能是对象，这里做兼容解码。
    struct URLValue: Codable {
        var raw: String?
        var query: [Query]?

        struct Query: Codable {
            var key: String
            var value: String?
            var disabled: Bool?
        }

        init(raw: String?, query: [Query]?) {
            self.raw = raw
            self.query = query
        }

        init(from decoder: Decoder) throws {
            if let container = try? decoder.singleValueContainer(),
               let string = try? container.decode(String.self) {
                self.raw = string
                self.query = nil
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.raw = try container.decodeIfPresent(String.self, forKey: .raw)
            self.query = try container.decodeIfPresent([Query].self, forKey: .query)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(raw, forKey: .raw)
            try container.encodeIfPresent(query, forKey: .query)
        }

        enum CodingKeys: String, CodingKey { case raw, query }
    }

    struct Body: Codable {
        var mode: String?
        var raw: String?
        var urlencoded: [Header]?
        var formdata: [FormParam]?
        var graphql: GraphQL?
        var options: Options?

        struct Options: Codable {
            var raw: RawOptions?
            struct RawOptions: Codable { var language: String? }
        }

        struct GraphQL: Codable {
            var query: String?
            var variables: String?
        }
    }

    struct FormParam: Codable {
        var key: String
        var value: String?
        var disabled: Bool?
        var type: String?
    }

    struct Variable: Codable {
        var key: String
        var value: String?
    }

    // MARK: - 导入

    struct ImportResult {
        var nodes: [CollectionNode]
        /// 由集合级变量生成的环境（没有变量时为 nil）。
        var environment: APIEnvironment?
        var collectionName: String
        var requestCount: Int
        /// 无法完整转换、需要让用户知道的内容（例如无法静态表达的认证类型）。
        /// 这些信息必须浮出来，不能静默丢弃。
        var warnings: [String] = []
    }

    /// 导入过程中累积的提示。用引用类型承载，避免每个 convert 调用都要回传。
    private final class ImportNotes {
        let l10n: Localizer
        private(set) var warnings: [String] = []

        init(l10n: Localizer) { self.l10n = l10n }
        private var seen = Set<String>()

        func note(_ message: String) {
            guard seen.insert(message).inserted else { return }
            warnings.append(message)
        }
    }

    static func decode(_ data: Data, l10n: Localizer) throws -> ImportResult {
        let collection: Collection
        do {
            collection = try JSONDecoder().decode(Collection.self, from: data)
        } catch {
            throw CodecError.notACollection
        }

        // 集合名可能是解码期写入的占位符（缺 info/name），出口处替换成当前语言。
        let collectionName = collection.info.name == unnamedPlaceholder
            ? l10n(.postmanUnnamedCollection)
            : collection.info.name

        let notes = ImportNotes(l10n: l10n)
        let nodes = collection.item
            .compactMap { convert($0, collectionAuth: collection.auth, notes: notes) }
        let count = countRequests(nodes)
        if count == 0 { throw CodecError.empty }

        var environment: APIEnvironment?
        if let variables = collection.variable, !variables.isEmpty {
            let items = variables.map {
                KeyValueItem(key: $0.key, value: $0.value ?? "")
            }
            environment = APIEnvironment(name: l10n(.postmanEnvironmentSuffix, collectionName), variables: items)
        }

        return ImportResult(
            nodes: nodes,
            environment: environment,
            collectionName: collectionName,
            requestCount: count,
            warnings: notes.warnings
        )
    }

    private static func convert(_ item: Item, collectionAuth: Auth?, notes: ImportNotes) -> CollectionNode? {
        // 条目缺 name 时解码期写的是占位符，这里换成当前语言。
        let name = item.name == unnamedItemPlaceholder ? notes.l10n(.postmanUnnamedItem) : item.name
        if let children = item.item {
            let converted = children.compactMap { convert($0, collectionAuth: collectionAuth, notes: notes) }
            return .folder(.init(name: name, children: converted))
        }
        guard let request = item.request else { return nil }
        return .request(.init(name: name, request: convert(request, collectionAuth: collectionAuth, notes: notes)))
    }

    private static func convert(_ request: Request, collectionAuth: Auth?, notes: ImportNotes) -> APIRequest {
        var result = APIRequest()
        result.name = ""
        result.method = HTTPMethod(rawValue: (request.method ?? "GET").uppercased()) ?? .get

        result.headers = (request.header ?? []).map {
            KeyValueItem(isEnabled: !($0.disabled ?? false), key: $0.key, value: $0.value ?? "")
        }

        var url = request.url?.raw ?? ""
        if let query = request.url?.query, !query.isEmpty {
            if let index = url.firstIndex(of: "?") {
                url = String(url[url.startIndex..<index])
            }
            result.queryParams = query.map {
                KeyValueItem(isEnabled: !($0.disabled ?? false), key: $0.key, value: $0.value ?? "")
            }
        }
        result.url = url

        // 认证：request 级覆盖 collection 级（Postman 语义）。
        applyAuth(request.auth ?? collectionAuth, to: &result, notes: notes)

        if let body = request.body {
            switch body.mode {
            case "raw":
                let language = body.options?.raw?.language?.lowercased()
                result.bodyKind = language == "json" ? .json : .rawText
                result.bodyText = body.raw ?? ""
                if result.bodyKind == .rawText {
                    // 回填 Content-Type，保证「导出 → 导入」保真（如 application/xml）
                    if let contentType = result.headers.first(where: {
                        $0.isEnabled && $0.key.lowercased() == "content-type"
                    })?.value, !contentType.isEmpty {
                        result.rawContentType = contentType
                    }
                }
            case "urlencoded":
                result.bodyKind = .formURLEncoded
                result.formFields = (body.urlencoded ?? []).map {
                    KeyValueItem(isEnabled: !($0.disabled ?? false), key: $0.key, value: $0.value ?? "")
                }
            case "formdata":
                result.bodyKind = .multipart
                // 文件字段 v1 不支持，标记为禁用但保留可见
                result.formFields = (body.formdata ?? []).map {
                    let isFile = ($0.type ?? "text") == "file"
                    return KeyValueItem(
                        isEnabled: !($0.disabled ?? false) && !isFile,
                        key: $0.key,
                        value: isFile ? notes.l10n(.curlFileFieldPlaceholder) : ($0.value ?? "")
                    )
                }
            case "graphql":
                // Postman 的 graphql body 实际发出的就是 {"query":...,"variables":...} 的 JSON。
                // 这里还原成等效 JSON 正文，而不是静默丢弃。
                result.bodyKind = .json
                result.bodyText = Self.graphQLBodyText(body.graphql)
            case "file":
                // 文件 body v1 不支持；若带有 raw 文本则保留，避免静默丢失
                result.bodyKind = .rawText
                result.bodyText = body.raw ?? ""
            default:
                // 未知 mode：保留 raw 原文而不是静默清空
                if let raw = body.raw, !raw.isEmpty {
                    result.bodyKind = .rawText
                    result.bodyText = raw
                } else {
                    result.bodyKind = .none
                }
            }
        }

        return result
    }

    // MARK: - 认证

    /// 把 Postman 的 `auth` 物化成等效的请求内容。
    ///
    /// **为什么必须做**：v1 完全忽略 `auth`，导入带 Bearer 的集合后所有请求都会 401——
    /// 这是最常见、也最容易让人以为"工具坏了"的静默丢失。
    ///
    /// 能静态表达的类型（bearer / basic / apikey）转成 header 或 query 参数，
    /// 与 Postman 实际发出的请求等价。需要动态签名或握手的类型无法在导入时表达，
    /// 记入 `warnings` 让用户知道，**不静默丢弃**。
    private static func applyAuth(_ auth: Auth?, to request: inout APIRequest, notes: ImportNotes) {
        guard let auth, let type = auth.type?.lowercased(), type != "noauth" else { return }

        func attribute(_ list: [Auth.AuthAttribute]?, key: String) -> String? {
            list?.first { ($0.key ?? "").lowercased() == key }?.value
        }

        switch type {
        case "bearer":
            let token = attribute(auth.bearer, key: "token") ?? ""
            guard !token.isEmpty else { return }
            setHeader("Authorization", "Bearer \(token)", on: &request)

        case "basic":
            let user = attribute(auth.basic, key: "username") ?? ""
            let password = attribute(auth.basic, key: "password") ?? ""
            guard !user.isEmpty || !password.isEmpty else { return }
            let encoded = Data("\(user):\(password)".utf8).base64EncodedString()
            setHeader("Authorization", "Basic \(encoded)", on: &request)

        case "apikey":
            let key = attribute(auth.apikey, key: "key") ?? ""
            let value = attribute(auth.apikey, key: "value") ?? ""
            guard !key.isEmpty else { return }
            let location = (attribute(auth.apikey, key: "in") ?? "header").lowercased()
            if location == "query" {
                request.queryParams.append(KeyValueItem(key: key, value: value))
            } else {
                setHeader(key, value, on: &request)
            }

        default:
            // oauth1/oauth2/digest/awsv4/hawk/ntlm/edgegrid 需要动态签名或挑战应答，
            // 静态导入无法还原；如实告知，而不是让请求带着"看起来有认证"的假象发出去。
            notes.note(notes.l10n(.postmanWarningAuth, type))
        }
    }

    /// 写入 header，但**不覆盖用户已有的显式设置**。
    private static func setHeader(_ key: String, _ value: String, on request: inout APIRequest) {
        if request.headers.contains(where: { $0.key.lowercased() == key.lowercased() && $0.isEnabled }) {
            return
        }
        request.headers.append(KeyValueItem(key: key, value: value))
    }

    /// 把 Postman 的 graphql 结构还原为等效的 JSON 请求正文。
    private static func graphQLBodyText(_ graphql: Body.GraphQL?) -> String {
        guard let graphql else { return "{}" }
        var payload: [String: Any] = ["query": graphql.query ?? ""]

        if let variables = graphql.variables, !variables.isEmpty,
           let data = variables.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) {
            payload["variables"] = parsed
        }

        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "{}"
    }

    private static func countRequests(_ nodes: [CollectionNode]) -> Int {
        nodes.reduce(0) { partial, node in
            switch node {
            case .folder(let folder): return partial + countRequests(folder.children)
            case .request: return partial + 1
            }
        }
    }

    // MARK: - 导出

    /// 导出一个项目为 Postman Collection v2.1：**项目名即集合名，项目子节点即 item**。
    ///
    /// 导入侧把每个集合建成同名项目（`AppState.importPostmanCollection`），
    /// 因此「导出 → 导入」往返天然稳定：`project(N, items) → collection(N, items) → project(N, items)`。
    /// 不再需要早期那套「顶层恰好一个文件夹时以它为集合」的启发式。
    static func encode(project: Project, environment: APIEnvironment?) throws -> Data {
        let collection = Collection(
            info: .init(name: project.name, schema: schemaURL),
            item: project.children.map { convertOut($0) },
            variable: environment.map { env in
                env.variables
                    .filter { $0.isEnabled && !$0.key.isEmpty }
                    .map { Variable(key: $0.key, value: $0.value) }
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(collection)
    }

    private static func convertOut(_ node: CollectionNode) -> Item {
        switch node {
        case .folder(let folder):
            return Item(name: folder.name, item: folder.children.map { convertOut($0) }, request: nil)

        case .request(let saved):
            let request = saved.request
            var headers = request.headers.map {
                Header(key: $0.key, value: $0.value, disabled: $0.isEnabled ? nil : true)
            }

            // rawText 的自定义 Content-Type 必须以 header 形式带出去，
            // 否则导出再导入会退化成 text/plain（往返不保真）。
            let hasContentTypeHeader = request.headers.contains {
                $0.isEnabled && $0.key.lowercased() == "content-type"
            }
            if request.bodyKind == .rawText,
               !hasContentTypeHeader,
               !request.rawContentType.isEmpty,
               request.rawContentType.lowercased() != "text/plain" {
                headers.append(Header(key: "Content-Type", value: request.rawContentType, disabled: nil))
            }

            var raw = request.url
            let queries: [URLValue.Query]? = request.queryParams.isEmpty ? nil : request.queryParams.map {
                URLValue.Query(key: $0.key, value: $0.value, disabled: $0.isEnabled ? nil : true)
            }
            if let queries {
                let enabled = queries.filter { !($0.disabled ?? false) && !$0.key.isEmpty }
                if !enabled.isEmpty, !raw.contains("?") {
                    // 键与值都编码（FormEncoding 会把 `+` 编成 %2B，避免被当成空格）
                    raw += "?" + FormEncoding.queryString(enabled.map { (key: $0.key, value: $0.value ?? "") })
                }
            }

            return Item(
                name: saved.name,
                item: nil,
                request: Request(
                    method: request.method.rawValue,
                    header: headers.isEmpty ? nil : headers,
                    url: URLValue(raw: raw, query: queries),
                    body: convertBodyOut(request)
                )
            )
        }
    }

    private static func convertBodyOut(_ request: APIRequest) -> Body? {
        switch request.bodyKind {
        case .none:
            return nil
        case .json:
            return Body(
                mode: "raw",
                raw: request.bodyText,
                urlencoded: nil,
                formdata: nil,
                options: .init(raw: .init(language: "json"))
            )
        case .rawText:
            return Body(mode: "raw", raw: request.bodyText, urlencoded: nil, formdata: nil, options: nil)
        case .formURLEncoded:
            return Body(
                mode: "urlencoded",
                raw: nil,
                urlencoded: request.formFields.map {
                    Header(key: $0.key, value: $0.value, disabled: $0.isEnabled ? nil : true)
                },
                formdata: nil,
                options: nil
            )
        case .multipart:
            return Body(
                mode: "formdata",
                raw: nil,
                urlencoded: nil,
                formdata: request.formFields.map {
                    FormParam(key: $0.key, value: $0.value, disabled: $0.isEnabled ? nil : true, type: "text")
                },
                options: nil
            )
        }
    }
}
