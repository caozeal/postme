import Foundation

/// 认证类型。
///
/// 只收录**静态可表达**的认证：它们都能在发送前物化成固定的 Header / Query 参数。
/// OAuth 1.0/2.0、Digest、AWS Signature 等需要握手或动态签名的类型不在其中——
/// 那类能力要引入令牌获取、缓存与时钟偏移处理，属于独立工程。
enum AuthKind: String, Codable, CaseIterable, Identifiable {
    case none
    case bearer
    case basic
    case apiKey

    var id: String { rawValue }

    func displayName(_ l10n: Localizer) -> String {
        switch self {
        case .none: return l10n(.authKindNone)
        case .bearer: return l10n(.authKindBearer)
        case .basic: return l10n(.authKindBasic)
        case .apiKey: return l10n(.authKindAPIKey)
        }
    }
}

/// API Key 的注入位置。
enum APIKeyLocation: String, Codable, CaseIterable, Identifiable {
    case header
    case query

    var id: String { rawValue }

    func displayName(_ l10n: Localizer) -> String {
        switch self {
        case .header: return l10n(.authLocationHeader)
        case .query: return l10n(.authLocationQuery)
        }
    }
}

/// 一个请求的认证配置。
///
/// **刻意不直接存成 Header**：Header 是「这一次发什么」，认证配置是「这个接口怎么鉴权」。
/// 分开存，换 token 只改一处，历史恢复、复制为 cURL、Postman 导出也都能从同一份配置
/// 推导出等价结果。真正物化发生在 `AuthApplier`，且只作用于解析后的副本。
struct RequestAuth: Codable, Hashable {
    var kind: AuthKind
    /// Bearer Token。
    var bearerToken: String
    /// Basic 用户名。
    var username: String
    /// Basic 密码。
    var password: String
    /// API Key 的键名。
    var apiKeyName: String
    /// API Key 的值。
    var apiKeyValue: String
    /// API Key 放在 Header 还是 Query。
    var apiKeyLocation: APIKeyLocation

    init(
        kind: AuthKind = .none,
        bearerToken: String = "",
        username: String = "",
        password: String = "",
        apiKeyName: String = "",
        apiKeyValue: String = "",
        apiKeyLocation: APIKeyLocation = .header
    ) {
        self.kind = kind
        self.bearerToken = bearerToken
        self.username = username
        self.password = password
        self.apiKeyName = apiKeyName
        self.apiKeyValue = apiKeyValue
        self.apiKeyLocation = apiKeyLocation
    }

    /// 是否真的配置了可发送的认证（用于页签上的状态提示）。
    ///
    /// 只选了类型、没填内容不算：那种状态发出去不会带任何凭据，页签上不该出现「已配置」的点。
    var isConfigured: Bool {
        switch kind {
        case .none:
            return false
        case .bearer:
            return !bearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .basic:
            return !username.isEmpty || !password.isEmpty
        case .apiKey:
            return !apiKeyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !apiKeyValue.isEmpty
        }
    }

    /// 容错解码：缺字段 / 未知枚举值都退回默认值，不让一个坏字段作废整份请求。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: c.tolerant(.kind, .none),
            bearerToken: c.tolerant(.bearerToken, ""),
            username: c.tolerant(.username, ""),
            password: c.tolerant(.password, ""),
            apiKeyName: c.tolerant(.apiKeyName, ""),
            apiKeyValue: c.tolerant(.apiKeyValue, ""),
            apiKeyLocation: c.tolerant(.apiKeyLocation, .header)
        )
    }
}
