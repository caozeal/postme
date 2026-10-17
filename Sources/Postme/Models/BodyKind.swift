import Foundation

/// 请求体类型。决定如何组装 httpBody 与默认 Content-Type。
enum BodyKind: String, Codable, CaseIterable, Identifiable {
    case none
    case json
    case rawText
    case formURLEncoded
    case multipart

    var id: String { rawValue }

    /// 界面展示名（由调用方传入当前语言的取词器）。
    func displayName(_ l10n: Localizer) -> String {
        switch self {
        case .none: return l10n(.bodyKindNone)
        case .json: return l10n(.bodyKindJSON)
        case .rawText: return l10n(.bodyKindRawText)
        case .formURLEncoded: return l10n(.bodyKindFormURLEncoded)
        case .multipart: return l10n(.bodyKindMultipart)
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
