import Foundation

/// 界面语言。
///
/// 只支持简体中文与英文；`rawValue` 直接写成 BCP-47 标签，便于与系统偏好比较。
enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case zhHans = "zh-Hans"
    case en = "en"

    var id: String { rawValue }

    /// 语言自称，**永不翻译**：菜单里必须始终显示「简体中文」和「English」，
    /// 否则英文界面下用户看不懂哪个选项是中文。
    var displayName: String {
        switch self {
        case .zhHans: return "简体中文"
        case .en: return "English"
        }
    }

    /// 从系统语言偏好里挑一个可识别的语言。
    ///
    /// 纯函数（便于测试）：取第一个能识别的标签；繁体中文未支持，按「中文优先于英文
    /// 回退」落到简体；全都识别不了时落到简体中文（产品的主要语言）。
    static func preferred(from tags: [String]) -> AppLanguage {
        for tag in tags {
            let normalized = tag.lowercased().replacingOccurrences(of: "_", with: "-")
            if normalized.hasPrefix("zh") { return .zhHans }
            if normalized.hasPrefix("en") { return .en }
        }
        return .zhHans
    }

    /// 系统当前默认语言。
    static var systemDefault: AppLanguage { preferred(from: Locale.preferredLanguages) }
}
