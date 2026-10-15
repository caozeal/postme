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

    /// 对整个请求做替换：URL / headers / query / body / form 字段。
    static func resolve(_ request: APIRequest, variables: [String: String]) -> (request: APIRequest, unresolved: [String]) {
        var resolved = request
        var unresolved = Set<String>()

        func apply(_ text: String) -> String {
            let (out, missing) = resolve(text, variables: variables)
            unresolved.formUnion(missing)
            return out
        }

        resolved.url = apply(request.url)
        resolved.rawContentType = apply(request.rawContentType)
        resolved.bodyText = apply(request.bodyText)

        resolved.headers = request.headers.map { item in
            KeyValueItem(id: item.id, isEnabled: item.isEnabled, key: apply(item.key), value: apply(item.value))
        }
        resolved.queryParams = request.queryParams.map { item in
            KeyValueItem(id: item.id, isEnabled: item.isEnabled, key: apply(item.key), value: apply(item.value))
        }
        resolved.formFields = request.formFields.map { item in
            KeyValueItem(id: item.id, isEnabled: item.isEnabled, key: apply(item.key), value: apply(item.value))
        }

        return (resolved, unresolved.sorted())
    }
}
