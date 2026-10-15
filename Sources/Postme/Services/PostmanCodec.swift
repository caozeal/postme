import Foundation

/// Postman Collection v2.1 的导入 / 导出。
///
/// ApiPost、Postman、Insomnia 都能导出这个格式，作为互通格式足够。
/// 本类型只依赖 Foundation，便于脱离 UI 独立验证。
enum PostmanCodec {

    static let schemaURL = "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"

    enum CodecError: LocalizedError {
        case notACollection
        case empty

        var errorDescription: String? {
            switch self {
            case .notACollection: return "该文件不是有效的 Postman Collection v2.x 格式"
            case .empty: return "集合中没有可导入的请求"
            }
        }
    }

    // MARK: - Postman 数据结构

    struct Collection: Codable {
        var info: Info
        var item: [Item]
        var variable: [Variable]?

        struct Info: Codable {
            var name: String
            var schema: String?
        }
    }

    struct Item: Codable {
        var name: String
        /// 文件夹的子项
        var item: [Item]?
        /// 请求节点
        var request: Request?
    }

    struct Request: Codable {
        var method: String?
        var header: [Header]?
        var url: URLValue?
        var body: Body?
    }

    struct Header: Codable {
        var key: String
        var value: String?
        var disabled: Bool?
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
    }

    static func decode(_ data: Data) throws -> ImportResult {
        let collection: Collection
        do {
            collection = try JSONDecoder().decode(Collection.self, from: data)
        } catch {
            throw CodecError.notACollection
        }

        let nodes = collection.item.map { convert($0) }.filter { $0 != nil }.map { $0! }
        let count = countRequests(nodes)
        if count == 0 { throw CodecError.empty }

        var environment: APIEnvironment?
        if let variables = collection.variable, !variables.isEmpty {
            let items = variables.map {
                KeyValueItem(key: $0.key, value: $0.value ?? "")
            }
            environment = APIEnvironment(name: "\(collection.info.name) 变量", variables: items)
        }

        return ImportResult(
            nodes: nodes,
            environment: environment,
            collectionName: collection.info.name,
            requestCount: count
        )
    }

    private static func convert(_ item: Item) -> CollectionNode? {
        if let children = item.item {
            let converted = children.compactMap { convert($0) }
            return .folder(.init(name: item.name, children: converted))
        }
        guard let request = item.request else { return nil }
        return .request(.init(name: item.name, request: convert(request)))
    }

    private static func convert(_ request: Request) -> APIRequest {
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
                        value: isFile ? "（文件字段，v1 不支持）" : ($0.value ?? "")
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

    /// 导出全部顶层节点为一个 Postman 集合。
    ///
    /// 命名规则（目的是让「导出 → 导入」往返稳定，且多次导入不互相混淆）：
    /// - 顶层**恰好只有一个文件夹**时，以该文件夹作为集合本身（名称为集合名，其子节点为 item）；
    /// - 否则集合名用「postme 导出」，全部顶层节点作为 item。
    ///
    /// 导入侧会把每个集合包一层同名文件夹，因此两条路径互相对齐：
    /// `export([folder(N,[...])]) → import → [folder(N,[...])]`，往返后结构不变。
    static func encode(collections: [CollectionNode], environment: APIEnvironment?) throws -> Data {
        let name: String
        let items: [CollectionNode]
        if collections.count == 1, case .folder(let folder) = collections[0] {
            name = folder.name
            items = folder.children
        } else {
            name = "postme 导出"
            items = collections
        }

        let collection = Collection(
            info: .init(name: name, schema: schemaURL),
            item: items.map { convertOut($0) },
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
