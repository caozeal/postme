import Foundation
import CoreFoundation

/// OpenAPI / Swagger 导入结果。
struct OpenAPIImportResult {
    var title: String
    var versionLabel: String
    var nodes: [CollectionNode]
    var environment: APIEnvironment?
    var requestCount: Int
    var folderCount: Int
    var warnings: [String]
}

/// OpenAPI 3.x / Swagger 2.0 JSON → postme 项目树。
///
/// **只做「spec → 可运行请求」**：不导入响应文档、不做 Mock / 文档 / 双向同步。
/// 解析基于 `JSONSerialization`，不引入第三方依赖；只解析文档内 `$ref`。
enum OpenAPICodec {

    enum CodecError: Error {
        case invalidJSON
        case notASpec
        case unsupportedVersion(String)
        case noOperations

        func message(_ l10n: Localizer) -> String {
            switch self {
            case .invalidJSON:
                return l10n(.openAPIErrorInvalidJSON)
            case .notASpec:
                return l10n(.openAPIErrorNotASpec)
            case .unsupportedVersion(let version):
                return l10n(.openAPIErrorUnsupportedVersion, version)
            case .noOperations:
                return l10n(.openAPIErrorNoOperations)
            }
        }
    }

    static func decode(_ data: Data, l10n: Localizer) throws -> OpenAPIImportResult {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw CodecError.invalidJSON
        }
        guard let root = object as? [String: Any] else {
            throw CodecError.notASpec
        }
        return try Builder(root: root, l10n: l10n).build()
    }

    // MARK: - Builder

    fileprivate final class Builder {
        fileprivate typealias JSON = [String: Any]

        private let root: JSON
        private let l10n: Localizer
        private let isSwagger2: Bool
        private let versionLabel: String

        private var warnings: [String] = []
        private var seenWarnings = Set<String>()
        private var tagOrder: [String] = []
        private var tagRequests: [String: [CollectionNode]] = [:]
        private var requestCount = 0
        private var skippedResponses = 0
        private var baseURL: String?
        private var globalSecurity: [[String: Any]]?
        private var securitySchemes: [String: JSON] = [:]
        private var schemaBudget = 4_000
        private var budgetWarned = false

        private static let httpMethods = ["get", "post", "put", "patch", "delete", "head", "options"]

        fileprivate init(root: JSON, l10n: Localizer) {
            self.root = root
            self.l10n = l10n

            if let swagger = root["swagger"] as? String, swagger.hasPrefix("2") {
                self.isSwagger2 = true
                self.versionLabel = l10n(.openAPIVersionSwagger2)
            } else if let openapi = root["openapi"] as? String, openapi.hasPrefix("3") {
                self.isSwagger2 = false
                self.versionLabel = l10n(.openAPIVersionOpenAPI3)
            } else {
                // `build()` 会抛 unsupportedVersion / notASpec；这里先按 3.x 占位。
                self.isSwagger2 = false
                let raw = (root["swagger"] as? String) ?? (root["openapi"] as? String) ?? ""
                self.versionLabel = raw.isEmpty ? l10n(.openAPIVersionOpenAPI3) : raw
            }
        }

        func build() throws -> OpenAPIImportResult {
            if root["swagger"] != nil, !isSwagger2 {
                throw CodecError.unsupportedVersion((root["swagger"] as? String) ?? "")
            }
            if root["openapi"] == nil, root["swagger"] == nil {
                throw CodecError.notASpec
            }
            if !isSwagger2, root["openapi"] == nil {
                throw CodecError.notASpec
            }

            let title = nonEmpty(root["info"].flatMap { ($0 as? JSON)?["title"] })
                ?? l10n(.openAPIDefaultTitle)

            readSecurity()
            baseURL = resolveBaseURL()
            readTagOrder()

            guard let paths = root["paths"] as? [String: Any], !paths.isEmpty else {
                throw CodecError.noOperations
            }

            for path in paths.keys.sorted() {
                guard let rawPathItem = paths[path], let pathItem = resolve(rawPathItem) else { continue }

                for method in Self.httpMethods {
                    guard let operation = pathItem[method] as? JSON else { continue }
                    skippedResponses += (operation["responses"] as? [String: Any])?.count ?? 0

                    guard let request = buildRequest(path: path, method: method, pathItem: pathItem, operation: operation) else {
                        continue
                    }
                    let folder = folderName(path: path, operation: operation)
                    if tagRequests[folder] == nil {
                        tagRequests[folder] = []
                        if !tagOrder.contains(folder) { tagOrder.append(folder) }
                    }
                    tagRequests[folder]?.append(.request(.init(name: request.name, request: request)))
                    requestCount += 1
                }
            }

            guard requestCount > 0 else { throw CodecError.noOperations }

            if skippedResponses > 0 {
                warn(l10n(.openAPIWarningSkippedResponses, skippedResponses))
            }
            if budgetWarned {
                warn(l10n(.openAPIWarningSchemaBudget))
            }

            let nodes: [CollectionNode] = tagOrder.compactMap { tag in
                guard let requests = tagRequests[tag], !requests.isEmpty else { return nil }
                return .folder(.init(name: tag, children: requests))
            }

            var environment: APIEnvironment?
            if let baseURL {
                environment = APIEnvironment(
                    name: l10n(.openAPIEnvironmentSuffix, title),
                    variables: [KeyValueItem(key: "baseUrl", value: baseURL)]
                )
            }

            return OpenAPIImportResult(
                title: title,
                versionLabel: versionLabel,
                nodes: nodes,
                environment: environment,
                requestCount: requestCount,
                folderCount: nodes.count,
                warnings: warnings
            )
        }

        // MARK: - 组织

        private func readTagOrder() {
            guard let tags = root["tags"] as? [Any] else { return }
            for tag in tags {
                guard let dict = tag as? JSON, let name = nonEmpty(dict["name"]) else { continue }
                if !tagOrder.contains(name) { tagOrder.append(name) }
            }
        }

        private func folderName(path: String, operation: JSON) -> String {
            if let tags = operation["tags"] as? [Any] {
                for tag in tags {
                    if let name = nonEmpty(tag) { return String(name.prefix(80)) }
                }
            }

            var segments = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            if let first = segments.first, first.lowercased() == "api" { segments.removeFirst() }
            if let first = segments.first, first.range(of: #"^v\d+$"#, options: .regularExpression) != nil {
                segments.removeFirst()
            }
            if let first = segments.first(where: { !$0.contains("{") && !$0.hasPrefix(":") }) {
                return String(first.prefix(80))
            }
            return l10n(.openAPIUntitledFolder)
        }

        private func requestName(path: String, method: String, operation: JSON) -> String {
            for candidate in [operation["summary"], operation["operationId"]] {
                if let value = nonEmpty(candidate) {
                    let firstLine = value.split(whereSeparator: \.isNewline).first.map(String.init) ?? value
                    return String(firstLine.prefix(120))
                }
            }
            return "\(method.uppercased()) \(path)"
        }

        // MARK: - 请求

        private func buildRequest(path: String, method: String, pathItem: JSON, operation: JSON) -> APIRequest? {
            guard let httpMethod = HTTPMethod(rawValue: method.uppercased()) else {
                warn(l10n(.openAPIWarningUnsupportedMethod, method.uppercased()))
                return nil
            }

            var request = APIRequest(
                name: requestName(path: path, method: method, operation: operation),
                method: httpMethod,
                url: url(for: path)
            )

            let parameters = mergedParameters(pathItem: pathItem, operation: operation)
            for parameter in parameters {
                importParameter(parameter, into: &request)
            }

            applyBody(operation: operation, parameters: parameters, into: &request)
            applyProduces(operation: operation, into: &request)
            request.auth = auth(for: operation)

            return request
        }

        private func url(for path: String) -> String {
            guard baseURL != nil else { return path }
            if path.hasPrefix("/") { return "{{baseUrl}}" + path }
            return "{{baseUrl}}/" + path
        }

        private func mergedParameters(pathItem: JSON, operation: JSON) -> [JSON] {
            var result: [JSON] = []
            var indexByKey: [String: Int] = [:]

            func add(_ raw: Any) {
                guard let parameter = resolve(raw),
                      let name = nonEmpty(parameter["name"]),
                      let location = nonEmpty(parameter["in"]) else { return }
                let key = "\(location.lowercased())|\(name)"
                if let index = indexByKey[key] {
                    result[index] = parameter
                } else {
                    indexByKey[key] = result.count
                    result.append(parameter)
                }
            }

            (pathItem["parameters"] as? [Any] ?? []).forEach(add)
            (operation["parameters"] as? [Any] ?? []).forEach(add)
            return result
        }

        private func importParameter(_ parameter: JSON, into request: inout APIRequest) {
            guard let name = nonEmpty(parameter["name"]),
                  let rawLocation = nonEmpty(parameter["in"]) else { return }
            let location = rawLocation.lowercased()

            if location == "body" || location == "formdata" { return }

            if parameter["content"] != nil {
                warn(l10n(.openAPIWarningParamContent, name))
                return
            }

            warnAboutParameterEncoding(parameter)

            let required = (parameter["required"] as? Bool) ?? false
            let value = parameterValue(parameter)

            switch location {
            case "path":
                request.pathParams.append(KeyValueItem(isEnabled: true, key: name, value: value))
            case "query":
                request.queryParams.append(KeyValueItem(isEnabled: required, key: name, value: value))
            case "header":
                if name.caseInsensitiveCompare("Content-Type") == .orderedSame { return }
                request.headers.append(KeyValueItem(isEnabled: required, key: name, value: value))
            case "cookie":
                request.cookies.append(KeyValueItem(isEnabled: required, key: name, value: value))
            default:
                warn(l10n(.openAPIWarningParamLocation, location))
            }
        }

        private func warnAboutParameterEncoding(_ parameter: JSON) {
            if let style = nonEmpty(parameter["style"]),
               !["simple", "form", "matrix", "label"].contains(style) {
                warn(l10n(.openAPIWarningParamStyle, style))
            }

            if let format = nonEmpty(parameter["collectionFormat"]), format != "csv" {
                warn(l10n(.openAPIWarningCollectionFormat, format))
            }
        }

        private func parameterValue(_ parameter: JSON) -> String {
            let separator = collectionSeparator(parameter)

            for key in ["x-example", "example"] {
                if let value = parameter[key] { return stringValue(value, separator: separator) }
            }

            if let schema = resolve(parameter["schema"]) {
                for key in ["example", "x-example", "default"] {
                    if let value = schema[key] { return stringValue(value, separator: separator) }
                }
                if let values = schema["enum"] as? [Any], let first = values.first {
                    return stringValue(first, separator: separator)
                }
            }

            for key in ["default", "x-example"] {
                if let value = parameter[key] { return stringValue(value, separator: separator) }
            }
            if let values = parameter["enum"] as? [Any], let first = values.first {
                return stringValue(first, separator: separator)
            }

            return ""
        }

        private func collectionSeparator(_ parameter: JSON) -> String {
            switch (nonEmpty(parameter["collectionFormat"]) ?? "csv").lowercased() {
            case "ssv": return " "
            case "tsv": return "\t"
            case "pipes": return "|"
            default: return ","
            }
        }

        // MARK: - 正文

        private func applyBody(operation: JSON, parameters: [JSON], into request: inout APIRequest) {
            if isSwagger2 {
                applySwaggerBody(operation: operation, parameters: parameters, into: &request)
            } else {
                applyOpenAPIBody(operation: operation, into: &request)
            }
        }

        private func applySwaggerBody(operation: JSON, parameters: [JSON], into request: inout APIRequest) {
            let consumes = stringArray(operation["consumes"]) ?? stringArray(root["consumes"]) ?? []
            let body = parameters.first { (nonEmpty($0["in"]) ?? "").lowercased() == "body" }
            let formFields = parameters.filter { (nonEmpty($0["in"]) ?? "").lowercased() == "formdata" }

            if let body {
                if !formFields.isEmpty {
                    warn(l10n(.openAPIWarningBodyAndForm))
                }
                let schema = resolve(body["schema"]) ?? [:]
                let contentType = consumes.first ?? "application/json"
                for extra in consumes.dropFirst() {
                    warn(l10n(.openAPIWarningSkippedContentType, extra))
                }
                let bodyExample = body["example"] ?? body["x-example"]

                if contentType.lowercased().contains("json") || consumes.isEmpty {
                    request.bodyKind = .json
                    request.bodyText = jsonText(schema: schema, example: bodyExample)
                } else if contentType.lowercased() == "application/x-www-form-urlencoded" {
                    request.bodyKind = .formURLEncoded
                    applyFormSchema(schema, into: &request, multipart: false)
                } else if contentType.lowercased() == "multipart/form-data" {
                    request.bodyKind = .multipart
                    applyFormSchema(schema, into: &request, multipart: true)
                } else {
                    request.bodyKind = .rawText
                    request.rawContentType = contentType
                    request.bodyText = rawText(schema: schema, example: bodyExample)
                }
                return
            }

            guard !formFields.isEmpty else { return }

            let multipart = consumes.contains { $0.lowercased() == "multipart/form-data" }
                || formFields.contains { (nonEmpty($0["type"]) ?? "").lowercased() == "file" }
            request.bodyKind = multipart ? .multipart : .formURLEncoded

            for field in formFields {
                guard let name = nonEmpty(field["name"]) else { continue }
                let required = (field["required"] as? Bool) ?? false
                let type = (nonEmpty(field["type"]) ?? "").lowercased()
                if type == "file" {
                    request.fileFields.append(FileField(isEnabled: required, name: name, path: ""))
                } else {
                    request.formFields.append(KeyValueItem(
                        isEnabled: required,
                        key: name,
                        value: parameterValue(field)
                    ))
                }
            }
        }

        private func applyOpenAPIBody(operation: JSON, into request: inout APIRequest) {
            guard let body = resolve(operation["requestBody"]),
                  let content = body["content"] as? [String: Any],
                  !content.isEmpty else { return }

            let keys = content.keys.sorted()
            let contentType = chooseContentType(keys)
            for key in keys where key != contentType {
                warn(l10n(.openAPIWarningSkippedContentType, key))
            }

            guard let media = content[contentType] as? JSON else { return }
            let schema = resolve(media["schema"]) ?? [:]
            let example = mediaExample(media)

            let lower = contentType.lowercased()
            if lower == "application/x-www-form-urlencoded" {
                request.bodyKind = .formURLEncoded
                applyFormSchema(schema, example: example, into: &request, multipart: false)
            } else if lower == "multipart/form-data" {
                request.bodyKind = .multipart
                applyFormSchema(schema, example: example, into: &request, multipart: true)
            } else if lower.contains("json") {
                request.bodyKind = .json
                request.bodyText = jsonText(schema: schema, example: example)
            } else {
                request.bodyKind = .rawText
                request.rawContentType = contentType
                request.bodyText = rawText(schema: schema, example: example)
            }
        }

        private func chooseContentType(_ keys: [String]) -> String {
            if let exact = keys.first(where: { $0.lowercased() == "application/json" }) { return exact }
            if let json = keys.first(where: { $0.lowercased().contains("json") }) { return json }
            if let form = keys.first(where: { $0.lowercased() == "application/x-www-form-urlencoded" }) { return form }
            if let multipart = keys.first(where: { $0.lowercased() == "multipart/form-data" }) { return multipart }
            return keys.first ?? "application/json"
        }

        private func mediaExample(_ media: JSON) -> Any? {
            if let example = media["example"] { return example }
            if let examples = media["examples"] as? [String: Any] {
                for key in examples.keys.sorted() {
                    if let dict = resolve(examples[key]), let value = dict["value"] { return value }
                }
            }
            return nil
        }

        private func applyFormSchema(
            _ schema: JSON,
            example: Any? = nil,
            into request: inout APIRequest,
            multipart: Bool
        ) {
            let merged = mergedSchema(schema)
            let properties = merged["properties"] as? [String: Any] ?? [:]
            let required = Set(merged["required"] as? [String] ?? [])
            let exampleObject = example as? [String: Any]

            if properties.isEmpty, let exampleObject {
                for key in exampleObject.keys.sorted() {
                    request.formFields.append(KeyValueItem(
                        isEnabled: true,
                        key: key,
                        value: stringValue(exampleObject[key] ?? "")
                    ))
                }
                return
            }

            for key in properties.keys.sorted() {
                guard let rawProperty = properties[key] else { continue }
                let property = resolve(rawProperty) ?? [:]
                let isRequired = required.contains(key)
                let isFile = (nonEmpty(property["type"]) ?? "").lowercased() == "file"
                    || (nonEmpty(property["format"]) ?? "").lowercased() == "binary"

                if multipart, isFile {
                    request.fileFields.append(FileField(isEnabled: isRequired, name: key, path: ""))
                    continue
                }

                let value: Any? = exampleObject?[key]
                    ?? property["example"]
                    ?? property["x-example"]
                    ?? property["default"]
                    ?? (property["enum"] as? [Any])?.first

                request.formFields.append(KeyValueItem(
                    isEnabled: isRequired,
                    key: key,
                    value: stringValue(value ?? "")
                ))
            }
        }

        // MARK: - Accept

        private func applyProduces(operation: JSON, into request: inout APIRequest) {
            guard isSwagger2 else { return }
            let produces = stringArray(operation["produces"]) ?? stringArray(root["produces"]) ?? []
            guard let first = produces.first, !first.isEmpty else { return }
            let hasAccept = request.headers.contains {
                $0.isEnabled && $0.key.caseInsensitiveCompare("Accept") == .orderedSame
            }
            if !hasAccept {
                request.headers.append(KeyValueItem(key: "Accept", value: first))
            }
        }

        // MARK: - 认证

        private func readSecurity() {
            globalSecurity = root["security"] as? [[String: Any]]

            if isSwagger2 {
                if let raw = root["securityDefinitions"] as? [String: Any] {
                    securitySchemes = raw.compactMapValues { $0 as? JSON }
                }
            } else if let components = root["components"] as? JSON,
                      let raw = components["securitySchemes"] as? [String: Any] {
                securitySchemes = raw.compactMapValues { $0 as? JSON }
            }
        }

        private func auth(for operation: JSON) -> RequestAuth {
            let requirements: [[String: Any]]?
            if let raw = operation["security"] as? [[String: Any]] {
                requirements = raw
            } else {
                requirements = globalSecurity
            }

            guard let first = requirements?.first, !first.isEmpty else { return RequestAuth() }
            let names = first.keys.sorted()

            for name in names {
                guard let scheme = securitySchemes[name] else { continue }
                if let auth = mapSecurityScheme(scheme) {
                    if names.count > 1 {
                        warn(l10n(.openAPIWarningSecurityAnd))
                    }
                    return auth
                }
            }
            return RequestAuth()
        }

        private func mapSecurityScheme(_ scheme: JSON) -> RequestAuth? {
            let type = (nonEmpty(scheme["type"]) ?? "").lowercased()

            switch type {
            case "basic":
                warn(l10n(.openAPIWarningAuthNeedsValue, l10n(.authKindBasic)))
                return RequestAuth(kind: .basic)

            case "apikey":
                guard let name = nonEmpty(scheme["name"]) else {
                    warn(l10n(.openAPIWarningAuthMissingName))
                    return nil
                }
                let location = (nonEmpty(scheme["in"]) ?? "header").lowercased() == "query" ? APIKeyLocation.query : .header
                warn(l10n(.openAPIWarningAuthNeedsValue, "\(l10n(.authKindAPIKey)) \(name)"))
                return RequestAuth(kind: .apiKey, apiKeyName: name, apiKeyLocation: location)

            case "http":
                let httpScheme = (nonEmpty(scheme["scheme"]) ?? "").lowercased()
                switch httpScheme {
                case "bearer":
                    warn(l10n(.openAPIWarningAuthNeedsValue, l10n(.authKindBearer)))
                    return RequestAuth(kind: .bearer)
                case "basic":
                    warn(l10n(.openAPIWarningAuthNeedsValue, l10n(.authKindBasic)))
                    return RequestAuth(kind: .basic)
                default:
                    warn(l10n(.openAPIWarningAuthUnsupported, httpScheme.isEmpty ? "http" : httpScheme))
                    return nil
                }

            case "oauth2", "openidconnect":
                warn(l10n(.openAPIWarningAuthUnsupported, type))
                return nil

            default:
                warn(l10n(.openAPIWarningAuthUnsupported, type.isEmpty ? "unknown" : type))
                return nil
            }
        }

        // MARK: - 服务地址

        private func resolveBaseURL() -> String? {
            if isSwagger2 {
                guard let host = nonEmpty(root["host"]) else {
                    if root["basePath"] != nil {
                        warn(l10n(.openAPIWarningNoHost))
                    }
                    return nil
                }
                let schemes = stringArray(root["schemes"]) ?? []
                if schemes.isEmpty {
                    warn(l10n(.openAPIWarningDefaultScheme))
                } else if schemes.count > 1 {
                    warn(l10n(.openAPIWarningMultipleSchemes, schemes.count))
                }
                let scheme = schemes.first ?? "https"
                var basePath = (root["basePath"] as? String) ?? ""
                if !basePath.isEmpty, !basePath.hasPrefix("/") {
                    basePath = "/" + basePath
                }
                return normalizedBaseURL("\(scheme)://\(host)\(basePath)")
            }

            guard let servers = root["servers"] as? [Any], !servers.isEmpty else {
                warn(l10n(.openAPIWarningNoServers))
                return nil
            }
            if servers.count > 1 {
                warn(l10n(.openAPIWarningMultipleServers, servers.count))
            }
            guard let first = servers.first as? JSON, var url = nonEmpty(first["url"]) else {
                warn(l10n(.openAPIWarningNoServers))
                return nil
            }

            if let variables = first["variables"] as? [String: Any] {
                for name in variables.keys.sorted() {
                    guard let variable = variables[name] as? JSON else { continue }
                    if let defaultValue = nonEmpty(variable["default"]) {
                        url = url.replacingOccurrences(of: "{\(name)}", with: defaultValue)
                    } else {
                        warn(l10n(.openAPIWarningServerVariable, name))
                    }
                }
            }

            if url.contains("{") {
                warn(l10n(.openAPIWarningServerUnresolved, url))
            }
            guard url.contains("://") else {
                warn(l10n(.openAPIWarningRelativeServer, url))
                return nil
            }
            return normalizedBaseURL(url)
        }

        /// 去掉末尾的 `/`：请求 URL 是 `{{baseUrl}} + /path`，环境值末尾多一个斜杠
        /// 就会拼出 `//path`，有些服务端会把它当成不同路径。
        private func normalizedBaseURL(_ url: String) -> String {
            var value = url
            while value.hasSuffix("/"), value.count > 1 {
                value.removeLast()
            }
            return value
        }

        // MARK: - Schema

        private func jsonText(schema: JSON, example: Any?) -> String {
            schemaBudget = 4_000
            let value: Any
            if let example {
                value = parseJSONString(example, schema: schema) ?? example
            } else {
                value = exampleValue(schema)
            }
            return jsonString(value) ?? "{}"
        }

        private func rawText(schema: JSON, example: Any?) -> String {
            schemaBudget = 4_000
            if let example {
                if let string = example as? String { return string }
                return jsonString(example) ?? stringValue(example)
            }
            if let type = nonEmpty(schema["type"]), type.lowercased() == "string" {
                return stringValue(exampleValue(schema))
            }
            return jsonString(exampleValue(schema)) ?? ""
        }

        private func parseJSONString(_ value: Any, schema: JSON) -> Any? {
            guard let string = value as? String else { return nil }
            let type = (nonEmpty(schema["type"]) ?? "").lowercased()
            guard type == "object" || type == "array" || schema["properties"] != nil || schema["items"] != nil else {
                return nil
            }
            guard let data = string.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        }

        private func jsonString(_ value: Any) -> String? {
            guard JSONSerialization.isValidJSONObject(value) || value is String || value is NSNumber || value is NSNull else {
                return nil
            }
            guard let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
            ) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        private func exampleValue(_ rawSchema: JSON, depth: Int = 0, refStack: Set<String> = []) -> Any {
            schemaBudget -= 1
            if schemaBudget <= 0 {
                if !budgetWarned {
                    budgetWarned = true
                }
                return NSNull()
            }
            if depth > 8 { return NSNull() }

            if let ref = nonEmpty(rawSchema["$ref"]) {
                guard !refStack.contains(ref) else { return NSNull() }
                guard let target = lookup(ref) as? JSON else {
                    warn(l10n(.openAPIWarningExternalRef, ref))
                    return NSNull()
                }
                var stack = refStack
                stack.insert(ref)
                return exampleValue(target, depth: depth + 1, refStack: stack)
            }

            let schema = mergedSchema(rawSchema)

            if let oneOf = schema["oneOf"] as? [Any], let first = oneOf.first, let sub = resolve(first) {
                return exampleValue(sub, depth: depth + 1, refStack: refStack)
            }
            if let anyOf = schema["anyOf"] as? [Any], let first = anyOf.first, let sub = resolve(first) {
                return exampleValue(sub, depth: depth + 1, refStack: refStack)
            }

            for key in ["example", "x-example", "default"] {
                if let value = schema[key] { return value }
            }
            if let values = schema["enum"] as? [Any], let first = values.first { return first }

            let type = (nonEmpty(schema["type"]) ?? "").lowercased()
            if type == "object" || schema["properties"] != nil || schema["additionalProperties"] != nil {
                var object: [String: Any] = [:]
                if let properties = schema["properties"] as? [String: Any] {
                    for key in properties.keys.sorted() {
                        guard let property = resolve(properties[key]) else { continue }
                        object[key] = exampleValue(property, depth: depth + 1, refStack: refStack)
                    }
                }
                return object
            }
            if type == "array" || schema["items"] != nil {
                guard let items = resolve(schema["items"]) else { return [] }
                return [exampleValue(items, depth: depth + 1, refStack: refStack)]
            }

            switch type {
            case "string", "file":
                return ""
            case "integer", "number":
                return 0
            case "boolean":
                return false
            default:
                return NSNull()
            }
        }

        private func mergedSchema(_ schema: JSON) -> JSON {
            guard let allOf = schema["allOf"] as? [Any] else { return schema }

            var merged = schema
            var properties = schema["properties"] as? [String: Any] ?? [:]
            var required = schema["required"] as? [String] ?? []

            for item in allOf {
                guard let sub = resolve(item) else { continue }
                let subMerged = mergedSchema(sub)
                if let subProperties = subMerged["properties"] as? [String: Any] {
                    for key in subProperties.keys {
                        properties[key] = subProperties[key]
                    }
                }
                if let subRequired = subMerged["required"] as? [String] {
                    required.append(contentsOf: subRequired)
                }
            }

            merged["properties"] = properties
            merged["required"] = Array(Set(required))
            merged.removeValue(forKey: "allOf")
            return merged
        }

        // MARK: - $ref

        private func resolve(_ raw: Any?, depth: Int = 0) -> JSON? {
            guard var dict = raw as? JSON else { return nil }
            guard let ref = nonEmpty(dict["$ref"]) else { return dict }
            guard depth < 20 else { return nil }
            guard let target = lookup(ref) else {
                warn(l10n(.openAPIWarningExternalRef, ref))
                return nil
            }
            guard let targetDict = target as? JSON else { return nil }
            dict = targetDict
            return resolve(dict, depth: depth + 1)
        }

        private func lookup(_ ref: String) -> Any? {
            guard ref.hasPrefix("#/") else {
                warn(l10n(.openAPIWarningExternalRef, ref))
                return nil
            }
            let parts = ref.dropFirst(2).split(separator: "/").map { part -> String in
                String(part)
                    .replacingOccurrences(of: "~1", with: "/")
                    .replacingOccurrences(of: "~0", with: "~")
            }
            var current: Any = root
            for part in parts {
                if let dict = current as? JSON, let next = dict[part] {
                    current = next
                } else if let array = current as? [Any], let index = Int(part), array.indices.contains(index) {
                    current = array[index]
                } else {
                    return nil
                }
            }
            return current
        }

        // MARK: - 工具

        private func nonEmpty(_ value: Any?) -> String? {
            guard let string = value as? String else { return nil }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        private func stringArray(_ value: Any?) -> [String]? {
            guard let array = value as? [Any] else { return nil }
            return array.compactMap { $0 as? String }
        }

        private func stringValue(_ value: Any, separator: String = ",") -> String {
            if value is NSNull { return "" }
            if let string = value as? String { return string }
            if let number = value as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    return number.boolValue ? "true" : "false"
                }
                return number.stringValue
            }
            if let bool = value as? Bool { return bool ? "true" : "false" }
            if let array = value as? [Any] {
                return array.map { stringValue($0, separator: separator) }.joined(separator: separator)
            }
            if let dict = value as? JSON {
                return jsonString(dict) ?? ""
            }
            return String(describing: value)
        }

        private func warn(_ message: String) {
            guard seenWarnings.insert(message).inserted else { return }
            warnings.append(message)
        }
    }
}
