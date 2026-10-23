import Foundation

/// 保序 JSON 值模型。
///
/// **为什么不复用 `JSONSerialization`**：树形浏览时键顺序必须与响应原文一致。
/// `JSONSerialization` 返回的 `NSDictionary` 不保序，用它建树会让「格式化」和
/// 「树形」两个视图的字段顺序对不上，用户会以为响应变了。
///
/// 标量一律保留**原始 token 文本**（字符串含引号与转义、数字不重排格式）：
/// 树形视图是只读展示，改写数字（如 `1e3` → `1000`）反而让人怀疑数据被篡改。
enum JSONValue: Sendable, Equatable {
    case object([JSONMember])
    case array([JSONValue])
    /// 原始 token，含首尾引号与内部转义。
    case string(String)
    /// 原始 token（不做数值归一）。
    case number(String)
    case bool(Bool)
    case null

    var isContainer: Bool {
        switch self {
        case .object, .array: return true
        default: return false
        }
    }

    var childCount: Int {
        switch self {
        case .object(let members): return members.count
        case .array(let items): return items.count
        default: return 0
        }
    }
}

struct JSONMember: Sendable, Equatable {
    /// 原始 token，含首尾引号。
    let key: String
    let value: JSONValue
}

/// JSON 树的解析与扁平化。
enum JSONTree {

    /// 单次解析允许的最大节点数。
    ///
    /// 2 MB 响应通常几万节点；超过 20 万说明文档异常巨大，建树后每帧遍历也吃不消，
    /// 直接放弃树形（回落到文本），比卡住主线程好。
    static let maxNodes = 200_000

    /// 默认展开到第几层：根（0）与一级容器（1）展开，更深的容器先收起。
    ///
    /// 常见响应是「根对象 + 若干叶子」，这样默认看起来就是全展开；
    /// 大数组套对象时又不会一上来铺满几十万行。
    static let defaultExpandDepth = 2

    static func parse(_ text: String) -> JSONValue? {
        var scanner = Scanner(bytes: Array(text.utf8))
        return scanner.parseDocument()
    }

    // MARK: - 扁平化

    /// 当前折叠状态下应展示的行（深度优先，父行紧跟子行）。
    static func flatten(_ root: JSONValue, collapsed: Set<String>) -> [JSONTreeRow] {
        var rows: [JSONTreeRow] = []
        append(root, path: "$", depth: 0, key: nil, index: nil, collapsed: collapsed, into: &rows)
        return rows
    }

    /// 默认折叠集合（按 `defaultExpandDepth`）。
    static func defaultCollapsed(_ root: JSONValue, expandDepth: Int = defaultExpandDepth) -> Set<String> {
        var result: Set<String> = []
        func visit(_ value: JSONValue, path: String, depth: Int) {
            guard value.isContainer else { return }
            guard depth < expandDepth else {
                result.insert(path)
                return
            }
            switch value {
            case .object(let members):
                for (offset, member) in members.enumerated() {
                    visit(member.value, path: "\(path)/\(offset)", depth: depth + 1)
                }
            case .array(let items):
                for (offset, item) in items.enumerated() {
                    visit(item, path: "\(path)/\(offset)", depth: depth + 1)
                }
            default:
                break
            }
        }
        visit(root, path: "$", depth: 0)
        return result
    }

    /// 全部容器路径（用于「收起全部」）。
    static func allContainerPaths(_ root: JSONValue) -> Set<String> {
        var result: Set<String> = []
        func visit(_ value: JSONValue, path: String) {
            guard value.isContainer else { return }
            result.insert(path)
            switch value {
            case .object(let members):
                for (offset, member) in members.enumerated() {
                    visit(member.value, path: "\(path)/\(offset)")
                }
            case .array(let items):
                for (offset, item) in items.enumerated() {
                    visit(item, path: "\(path)/\(offset)")
                }
            default:
                break
            }
        }
        visit(root, path: "$")
        return result
    }

    private static func append(
        _ value: JSONValue,
        path: String,
        depth: Int,
        key: String?,
        index: Int?,
        collapsed: Set<String>,
        into rows: inout [JSONTreeRow]
    ) {
        let isCollapsed = value.isContainer && collapsed.contains(path)

        switch value {
        case .object(let members):
            rows.append(JSONTreeRow(
                id: path,
                depth: depth,
                key: key,
                index: index,
                content: .container(isObject: true, childCount: members.count),
                isCollapsed: isCollapsed
            ))
            guard !isCollapsed else { return }
            for (offset, member) in members.enumerated() {
                append(
                    member.value,
                    path: "\(path)/\(offset)",
                    depth: depth + 1,
                    key: member.key,
                    index: nil,
                    collapsed: collapsed,
                    into: &rows
                )
            }
        case .array(let items):
            rows.append(JSONTreeRow(
                id: path,
                depth: depth,
                key: key,
                index: index,
                content: .container(isObject: false, childCount: items.count),
                isCollapsed: isCollapsed
            ))
            guard !isCollapsed else { return }
            for (offset, item) in items.enumerated() {
                append(
                    item,
                    path: "\(path)/\(offset)",
                    depth: depth + 1,
                    key: nil,
                    index: offset,
                    collapsed: collapsed,
                    into: &rows
                )
            }
        case .string(let token):
            rows.append(scalarRow(value: token, kind: .string, path: path, depth: depth, key: key, index: index))
        case .number(let token):
            rows.append(scalarRow(value: token, kind: .number, path: path, depth: depth, key: key, index: index))
        case .bool(let flag):
            rows.append(scalarRow(value: flag ? "true" : "false", kind: .bool, path: path, depth: depth, key: key, index: index))
        case .null:
            rows.append(scalarRow(value: "null", kind: .null, path: path, depth: depth, key: key, index: index))
        }
    }

    private static func scalarRow(
        value: String,
        kind: JSONScalarKind,
        path: String,
        depth: Int,
        key: String?,
        index: Int?
    ) -> JSONTreeRow {
        JSONTreeRow(
            id: path,
            depth: depth,
            key: key,
            index: index,
            content: .scalar(value, kind),
            isCollapsed: false
        )
    }

    // MARK: - 扫描器

    /// 单遍递归下降扫描器：只认结构，不做语义校验（数字合法性等交给展示层）。
    private struct Scanner {
        let bytes: [UInt8]
        var index = 0
        var nodes = 0

        mutating func parseDocument() -> JSONValue? {
            skipWhitespace()
            guard let value = parseValue(depth: 0) else { return nil }
            skipWhitespace()
            guard index == bytes.count else { return nil }
            return value
        }

        mutating func parseValue(depth: Int) -> JSONValue? {
            guard depth <= 512, nodes < JSONTree.maxNodes else { return nil }
            skipWhitespace()
            guard index < bytes.count else { return nil }
            nodes += 1

            switch bytes[index] {
            case UInt8(ascii: "{"):
                return parseObject(depth: depth)
            case UInt8(ascii: "["):
                return parseArray(depth: depth)
            case UInt8(ascii: "\""):
                guard let token = parseString() else { return nil }
                return .string(token)
            case UInt8(ascii: "t"):
                guard match("true") else { return nil }
                return .bool(true)
            case UInt8(ascii: "f"):
                guard match("false") else { return nil }
                return .bool(false)
            case UInt8(ascii: "n"):
                guard match("null") else { return nil }
                return .null
            default:
                guard let token = parseNumber() else { return nil }
                return .number(token)
            }
        }

        mutating func parseObject(depth: Int) -> JSONValue? {
            index += 1
            skipWhitespace()
            var members: [JSONMember] = []
            if consume(UInt8(ascii: "}")) { return .object(members) }

            while true {
                skipWhitespace()
                guard let key = parseString() else { return nil }
                skipWhitespace()
                guard consume(UInt8(ascii: ":")) else { return nil }
                guard let value = parseValue(depth: depth + 1) else { return nil }
                members.append(JSONMember(key: key, value: value))
                skipWhitespace()
                if consume(UInt8(ascii: "}")) { return .object(members) }
                guard consume(UInt8(ascii: ",")) else { return nil }
            }
        }

        mutating func parseArray(depth: Int) -> JSONValue? {
            index += 1
            skipWhitespace()
            var items: [JSONValue] = []
            if consume(UInt8(ascii: "]")) { return .array(items) }

            while true {
                guard let value = parseValue(depth: depth + 1) else { return nil }
                items.append(value)
                skipWhitespace()
                if consume(UInt8(ascii: "]")) { return .array(items) }
                guard consume(UInt8(ascii: ",")) else { return nil }
            }
        }

        /// 返回含引号的原始 token。
        mutating func parseString() -> String? {
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { return nil }
            let start = index
            index += 1
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\\"):
                    // 跳过转义字符本身；`\uXXXX` 的后续 hex 不含 `"` / `\`，无需特殊处理。
                    index += 2
                case UInt8(ascii: "\""):
                    index += 1
                    return String(decoding: bytes[start..<index], as: UTF8.self)
                default:
                    index += 1
                }
            }
            return nil
        }

        mutating func parseNumber() -> String? {
            let start = index
            loop: while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "-"), UInt8(ascii: "+"), UInt8(ascii: "."),
                     UInt8(ascii: "e"), UInt8(ascii: "E"),
                     UInt8(ascii: "0")...UInt8(ascii: "9"):
                    index += 1
                default:
                    break loop
                }
            }
            guard index > start else { return nil }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }

        mutating func match(_ literal: String) -> Bool {
            let literalBytes = Array(literal.utf8)
            guard index + literalBytes.count <= bytes.count else { return false }
            for offset in 0..<literalBytes.count where bytes[index + offset] != literalBytes[offset] {
                return false
            }
            index += literalBytes.count
            return true
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        mutating func skipWhitespace() {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D:
                    index += 1
                default:
                    return
                }
            }
        }
    }
}

// MARK: - 行模型

/// 树形视图的一行（一个 JSON 节点）。
struct JSONTreeRow: Identifiable, Equatable {
    enum Content: Equatable {
        case container(isObject: Bool, childCount: Int)
        case scalar(String, JSONScalarKind)
    }

    /// 节点路径（`$/0/1`），只用于折叠状态与 ForEach 标识。
    let id: String
    let depth: Int
    /// 原始键 token（含引号），根与数组元素为 nil。
    let key: String?
    /// 数组下标，对象成员与根为 nil。
    let index: Int?
    let content: Content
    let isCollapsed: Bool

    var isContainer: Bool {
        if case .container = content { return true }
        return false
    }

    /// 空对象 / 空数组没有可展开内容，不显示折叠箭头。
    var isExpandable: Bool {
        if case .container(_, let childCount) = content { return childCount > 0 }
        return false
    }
}

enum JSONScalarKind: Equatable {
    case string, number, bool, null
}
