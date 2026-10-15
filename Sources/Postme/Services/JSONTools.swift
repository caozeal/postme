import Foundation

/// JSON 文本处理工具。
///
/// 说明：基于 Foundation 的 JSONSerialization 实现，可靠、零依赖。
/// 已知取舍——它不保留键顺序（NSDictionary 语义），美化后键序可能变化。
/// 对调试用途可接受；若将来要求严格保序，再换自写扫描器。
enum JSONTools {

    /// 美化（缩进）JSON。输入非法返回 nil。
    static func pretty(_ text: String) -> String? {
        guard let object = parse(text) else { return nil }
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: options) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 压缩 JSON。输入非法返回 nil。
    static func minify(_ text: String) -> String? {
        guard let object = parse(text) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 是否为合法 JSON。
    static func isValid(_ text: String) -> Bool {
        parse(text) != nil
    }

    private static func parse(_ text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}
