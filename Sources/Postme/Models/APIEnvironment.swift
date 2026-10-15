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
}
