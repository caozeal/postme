import Foundation

/// RESTful 路径参数：识别 URL 路径里的 `{name}` / `:name`，并把填写好的值替换回去。
///
/// **只处理路径部分**：query / fragment 里出现的 `{...}` 不属于路径参数，
/// 替换它们会悄悄改坏查询串。`{{env}}` 也整体跳过——那是环境变量，
/// 在 `VariableResolver` 里已经处理过；这里再把它拆成 `{env}` 就会误建一个路径参数。
///
/// 只依赖 Foundation，便于脱离 UI 独立验证。
enum PathParams {

    /// 路径参数名：字母或下划线开头，后接字母 / 数字 / 下划线 / 连字符。
    private static func isNameStart(_ character: Character) -> Bool {
        character == "_" || character.isLetter
    }

    private static func isNameChar(_ character: Character) -> Bool {
        character == "_" || character == "-" || character.isLetter || character.isNumber
    }

    /// URL 的路径区间（含开头的 `/`），query 与 fragment 之前。
    ///
    /// 返回的是原字符串的 `Range`，替换时可以直接拼回完整 URL。
    static func pathRange(in url: String) -> Range<String.Index> {
        var headEnd = url.endIndex
        if let query = url.firstIndex(of: "?") { headEnd = min(headEnd, query) }
        if let fragment = url.firstIndex(of: "#") { headEnd = min(headEnd, fragment) }

        let head = url[..<headEnd]
        if let scheme = head.range(of: "://") {
            if let slash = head[scheme.upperBound...].firstIndex(of: "/") {
                return slash..<headEnd
            }
            return headEnd..<headEnd
        }

        // 没有协议头：从第一个 `/` 开始当路径；连 `/` 都没有时整段当路径。
        if let slash = head.firstIndex(of: "/") {
            return slash..<headEnd
        }
        return head.startIndex..<headEnd
    }

    /// 按出现顺序返回路径里的参数名（去重）。
    static func placeholders(in url: String) -> [String] {
        let range = pathRange(in: url)
        var names: [String] = []
        var seen = Set<String>()

        var index = range.lowerBound
        while index < range.upperBound {
            if url[index...].hasPrefix("{{") {
                // 环境变量整体跳过（含未定义、原样保留的 {{name}}）
                if let close = url.range(of: "}}", range: index..<range.upperBound) {
                    index = close.upperBound
                } else {
                    break
                }
                continue
            }

            if url[index] == "{" {
                if let close = url[index...].firstIndex(of: "}") {
                    let name = String(url[url.index(after: index)..<close])
                    if isValid(name), seen.insert(name).inserted {
                        names.append(name)
                    }
                    index = url.index(after: close)
                    continue
                }
            }

            if url[index] == ":" , index > range.lowerBound, url[url.index(before: index)] == "/" {
                var end = url.index(after: index)
                while end < range.upperBound, isNameChar(url[end]) {
                    end = url.index(after: end)
                }
                let name = String(url[url.index(after: index)..<end])
                if !name.isEmpty, isValid(name), seen.insert(name).inserted {
                    names.append(name)
                }
                index = end
                continue
            }

            index = url.index(after: index)
        }

        return names
    }

    private static func isValid(_ name: String) -> Bool {
        guard let first = name.first, isNameStart(first) else { return false }
        return name.allSatisfy(isNameChar)
    }

    /// 按 URL 里的占位符同步参数行。
    ///
    /// - 保留已有同名行的 id 与值（SwiftUI 的绑定按 id 稳定）；
    /// - 新增占位符补空行；
    /// - `prune == true` 时移除 URL 里已经删掉的占位符行；
    /// - `prune == false` 时保留这些「暂时不在 URL 里」的行：用户编辑 URL 时
    ///   打错一个字符不该立刻把已填好的值删掉，补回来还能继续用。
    static func synchronize(url: String, existing: [KeyValueItem], prune: Bool = true) -> [KeyValueItem] {
        let names = placeholders(in: url)
        var byName: [String: KeyValueItem] = [:]
        for item in existing where byName[item.key] == nil {
            byName[item.key] = item
        }

        var result = names.map { name -> KeyValueItem in
            if var item = byName[name] {
                item.isEnabled = true
                return item
            }
            return KeyValueItem(key: name, value: "")
        }

        if !prune {
            let active = Set(names)
            result.append(contentsOf: existing.filter { !$0.key.isEmpty && !active.contains($0.key) })
        }
        return result
    }

    /// 把路径参数替换进 URL。
    ///
    /// 空值**不替换**：原样保留 `{name}` / `:name`，并把名字放进 `unresolved`，
    /// 与「未定义环境变量按原文发出」保持同一条纪律。
    static func apply(to url: String, values: [String: String]) -> (url: String, unresolved: [String]) {
        let range = pathRange(in: url)
        guard range.lowerBound < range.upperBound else { return (url, []) }

        var output = String(url[..<range.lowerBound])
        var unresolved: [String] = []
        var unresolvedSeen = Set<String>()

        func value(for name: String) -> String? {
            guard let raw = values[name], !raw.isEmpty else { return nil }
            return encode(raw)
        }

        func markUnresolved(_ name: String) {
            if unresolvedSeen.insert(name).inserted { unresolved.append(name) }
        }

        var index = range.lowerBound
        while index < range.upperBound {
            if url[index...].hasPrefix("{{") {
                if let close = url.range(of: "}}", range: index..<range.upperBound) {
                    output += url[index..<close.upperBound]
                    index = close.upperBound
                } else {
                    output += url[index..<range.upperBound]
                    index = range.upperBound
                }
                continue
            }

            if url[index] == "{" {
                if let close = url[index...].firstIndex(of: "}") {
                    let name = String(url[url.index(after: index)..<close])
                    if isValid(name) {
                        if let encoded = value(for: name) {
                            output += encoded
                        } else {
                            output += url[index...close]
                            markUnresolved(name)
                        }
                    } else {
                        output += url[index...close]
                    }
                    index = url.index(after: close)
                    continue
                }
            }

            if url[index] == ":", index > range.lowerBound, url[url.index(before: index)] == "/" {
                var end = url.index(after: index)
                while end < range.upperBound, isNameChar(url[end]) {
                    end = url.index(after: end)
                }
                let name = String(url[url.index(after: index)..<end])
                if !name.isEmpty, isValid(name) {
                    if let encoded = value(for: name) {
                        output += encoded
                    } else {
                        output += url[index..<end]
                        markUnresolved(name)
                    }
                } else {
                    output += url[index..<end]
                }
                index = end
                continue
            }

            output.append(url[index])
            index = url.index(after: index)
        }

        output += String(url[range.upperBound...])
        return (output, unresolved)
    }

    /// 值作为一个**路径段**编码：`/`、`?`、`#`、`%` 都转义，
    /// 避免一个值把 URL 拆成多段或提前结束路径。
    static func encode(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// 导出到 Postman 时把 `{id}` 转成 `:id`。
    ///
    /// Postman 的 URL 变量用冒号语法；`{}` 是 OpenAPI/ApiPost 风格，Postman 不会
    /// 自动绑定 `url.variable`。只转路径部分，`{{env}}` 与 query 原样保留。
    static func postmanStyleURL(_ url: String) -> String {
        let range = pathRange(in: url)
        guard range.lowerBound < range.upperBound else { return url }

        var output = String(url[..<range.lowerBound])
        var index = range.lowerBound
        while index < range.upperBound {
            if url[index...].hasPrefix("{{") {
                if let close = url.range(of: "}}", range: index..<range.upperBound) {
                    output += url[index..<close.upperBound]
                    index = close.upperBound
                } else {
                    output += url[index..<range.upperBound]
                    index = range.upperBound
                }
                continue
            }

            if url[index] == "{" {
                if let close = url[index...].firstIndex(of: "}") {
                    let name = String(url[url.index(after: index)..<close])
                    if isValid(name) {
                        output += ":\(name)"
                    } else {
                        output += url[index...close]
                    }
                    index = url.index(after: close)
                    continue
                }
            }

            output.append(url[index])
            index = url.index(after: index)
        }
        output += String(url[range.upperBound...])
        return output
    }
}
