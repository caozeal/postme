import Foundation

/// `{{var}}` 变量替换。
///
/// 规则：
/// 1. 先查用户环境变量，再查内置动态变量；
/// 2. 都找不到时**原样保留** `{{name}}`，并把名字记录到 `unresolved`，供界面提示；
/// 3. 仅做整体替换，不做递归展开（避免 A→B→A 死循环）。
///
/// 本类型只依赖 Foundation，便于脱离 UI 独立验证。
enum VariableResolver {

    /// 内置动态变量。
    static func builtinValue(for name: String) -> String? {
        switch name {
        case "$timestamp":
            return String(Int(Date().timeIntervalSince1970))
        case "$isoTimestamp":
            return ISO8601DateFormatter().string(from: Date())
        case "$uuid":
            return UUID().uuidString
        case "$randomInt":
            return String(Int.random(in: 0..<1_000_000))
        default:
            return nil
        }
    }

    /// 单个值查找：用户变量优先，其次内置。
    static func value(for name: String, variables: [String: String]) -> String? {
        if let value = variables[name] { return value }
        return builtinValue(for: name)
    }

    /// 替换一段文本中的全部 {{var}}。
    static func resolve(_ text: String, variables: [String: String]) -> (text: String, unresolved: [String]) {
        guard text.contains("{{") else { return (text, []) }

        var output = ""
        var unresolved: [String] = []
        var cursor = text.startIndex

        while let open = text.range(of: "{{", range: cursor..<text.endIndex) {
            output += text[cursor..<open.lowerBound]

            guard let close = text.range(of: "}}", range: open.upperBound..<text.endIndex) else {
                // 没有闭合，剩余部分原样保留
                output += text[open.lowerBound...]
                cursor = text.endIndex
                break
            }

            let rawName = String(text[open.upperBound..<close.lowerBound])
            let name = rawName.trimmingCharacters(in: .whitespaces)

            if let resolved = value(for: name, variables: variables) {
                output += resolved
            } else {
                output += text[open.lowerBound..<close.upperBound]
                unresolved.append(name)
            }
            cursor = close.upperBound
        }

        if cursor < text.endIndex {
            output += text[cursor...]
        }
        return (output, unresolved)
    }

    struct Resolution {
        let request: APIRequest
        let missingVariables: [MissingRequestVariable]
        var unresolved: [String] { Set(missingVariables.map(\.name)).sorted() }
    }

    /// 替换请求字段，并记录这次请求会用到的未定义变量及其编辑位置。
    static func resolve(_ request: APIRequest, variables: [String: String]) -> Resolution {
        var resolved = request
        var missingVariables: [MissingRequestVariable] = []

        func apply(_ text: String, at field: RequestVariableField) -> String {
            let result = resolve(text, variables: variables)
            missingVariables += Set(result.unresolved).sorted().map { MissingRequestVariable(name: $0, field: field) }
            return result.text
        }

        func rows(_ items: [KeyValueItem], in table: RequestVariableField.Table) -> [KeyValueItem] {
            items.map { item in
                var item = item
                if table != .path {
                    item.key = apply(item.key, at: .row(table, item.id, .name))
                }
                item.value = apply(item.value, at: .row(table, item.id, .value))
                return item
            }
        }

        resolved.url = apply(request.url, at: .url)
        resolved.rawContentType = apply(request.rawContentType, at: .rawContentType)
        resolved.bodyText = apply(request.bodyText, at: .body)
        resolved.headers = rows(request.headers, in: .headers)
        resolved.queryParams = rows(request.queryParams, in: .query)
        resolved.formFields = rows(request.formFields, in: .form)
        resolved.fileFields = request.fileFields.map { field in
            var field = field
            field.name = apply(field.name, at: .row(.files, field.id, .name))
            field.path = apply(field.path, at: .row(.files, field.id, .value))
            return field
        }
        resolved.binaryFilePath = apply(request.binaryFilePath, at: .binaryPath)
        resolved.binaryContentType = apply(request.binaryContentType, at: .binaryContentType)
        resolved.cookies = rows(request.cookies, in: .cookies)
        resolved.pathParams = rows(request.pathParams, in: .path)
        resolved.auth.bearerToken = apply(request.auth.bearerToken, at: .bearerToken)
        resolved.auth.username = apply(request.auth.username, at: .username)
        resolved.auth.password = apply(request.auth.password, at: .password)
        resolved.auth.apiKeyName = apply(request.auth.apiKeyName, at: .apiKeyName)
        resolved.auth.apiKeyValue = apply(request.auth.apiKeyValue, at: .apiKeyValue)

        guard !missingVariables.isEmpty else { return Resolution(request: resolved, missingVariables: []) }
        let activeFields = activeFields(in: resolved)
        return Resolution(
            request: resolved,
            missingVariables: missingVariables.filter { activeFields.contains($0.field) }
        )
    }

    private static func activeFields(in request: APIRequest) -> Set<RequestVariableField> {
        var fields: Set<RequestVariableField> = [.url]

        func addRows(_ items: [KeyValueItem], in table: RequestVariableField.Table) {
            for item in items where item.isEnabled && !item.key.isEmpty {
                fields.insert(.row(table, item.id, .name))
                fields.insert(.row(table, item.id, .value))
            }
        }

        // URLRequest 对同名头采用最后一条启用值。路径参数则取实际使用的第一条。
        var headerNames = Set<String>()
        let headers = request.headers.reversed().filter {
            $0.isEnabled && !$0.key.isEmpty && headerNames.insert($0.key.lowercased()).inserted
        }
        addRows(headers, in: .headers)
        addRows(request.queryParams, in: .query)
        if !headerNames.contains("cookie") { addRows(request.cookies, in: .cookies) }

        let pathNames = Set(PathParams.placeholders(in: request.url))
        var seenPaths = Set<String>()
        for item in request.pathParams where item.isEnabled && pathNames.contains(item.key) && seenPaths.insert(item.key).inserted {
            fields.insert(.row(.path, item.id, .value))
        }

        switch request.bodyKind {
        case .none:
            break
        case .json, .rawText:
            fields.insert(.body)
            if request.bodyKind == .rawText && !headerNames.contains("content-type") {
                fields.insert(.rawContentType)
            }
        case .formURLEncoded, .multipart:
            addRows(request.formFields, in: .form)
            if request.bodyKind == .multipart {
                for file in request.fileFields where file.isEnabled && !file.name.isEmpty {
                    fields.insert(.row(.files, file.id, .name))
                    fields.insert(.row(.files, file.id, .value))
                }
            }
        case .binary:
            fields.insert(.binaryPath)
            if !headerNames.contains("content-type") { fields.insert(.binaryContentType) }
        }

        guard request.auth.isConfigured else { return fields }
        switch request.auth.kind {
        case .none: break
        case .bearer: fields.insert(.bearerToken)
        case .basic: fields.formUnion([.username, .password])
        case .apiKey: fields.formUnion([.apiKeyName, .apiKeyValue])
        }
        return fields
    }
}
