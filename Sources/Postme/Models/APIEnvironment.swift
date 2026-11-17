import Foundation

/// 环境：一组命名的变量，用于 {{var}} 替换。
/// 命名刻意避开 `Environment`——那是 SwiftUI `@Environment` 属性包装器的名字，会冲突。
struct APIEnvironment: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var variables: [KeyValueItem]

    init(id: UUID = UUID(), name: String = "新环境", variables: [KeyValueItem] = []) {
        self.id = id
        self.name = name
        self.variables = variables
    }

    /// 转为便于查表的字典（仅启用且键非空）。
    var variableMap: [String: String] {
        var map: [String: String] = [:]
        for item in variables where item.isEnabled && !item.key.isEmpty {
            map[item.key] = item.value
        }
        return map
    }

    /// 深拷贝环境及其变量行，供「克隆环境」使用。
    ///
    /// 环境与变量行都要换新 id：复制后的两组数据必须能被独立编辑，不能让 SwiftUI
    /// 列表或未来按变量 id 追踪状态的功能把它们误认为同一项。
    func copyWithNewID(name: String) -> APIEnvironment {
        APIEnvironment(
            name: name,
            variables: variables.map {
                KeyValueItem(id: UUID(), isEnabled: $0.isEnabled, key: $0.key, value: $0.value)
            }
        )
    }

    /// 容错解码（见 `TolerantDecoding.swift`）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: c.tolerant(.id, UUID()),
            name: c.tolerant(.name, "新环境"),
            variables: c.tolerant(.variables, [])
        )
    }
}
