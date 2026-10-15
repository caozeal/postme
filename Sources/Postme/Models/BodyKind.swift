import Foundation

/// 请求体类型。决定如何组装 httpBody 与默认 Content-Type。
enum BodyKind: String, Codable, CaseIterable, Identifiable {
    case none
    case json
    case rawText
    case formURLEncoded
    case multipart

    var id: String { rawValue }

    /// 界面展示名。
    var displayName: String {
        switch self {
        case .none: return "无"
        case .json: return "JSON"
        case .rawText: return "Raw Text"
        case .formURLEncoded: return "Form URL Encoded"
        case .multipart: return "Multipart Form"
        }
    }

    /// 默认 Content-Type。multipart 的 Content-Type 需带 boundary，运行时生成，故为 nil。
    var defaultContentType: String? {
        switch self {
        case .none: return nil
        case .json: return "application/json"
        case .rawText: return "text/plain"
        case .formURLEncoded: return "application/x-www-form-urlencoded"
        case .multipart: return nil
        }
    }

    /// 该类型是否使用「键值表」编辑（form 类），而非大文本编辑器。
    var usesFormFields: Bool {
        self == .formURLEncoded || self == .multipart
    }
}
