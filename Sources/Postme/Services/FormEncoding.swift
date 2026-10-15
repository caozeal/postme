import Foundation

/// `application/x-www-form-urlencoded` / URL query 的组件编码。
///
/// **为什么不用 `URLComponents.queryItems`**：Foundation 在序列化 query item 时
/// 不会编码 `+`。而按 form-urlencoded 规范（以及 PHP / Java Servlet / Python
/// `parse_qs` / Rails 等大量服务端的实际行为），query 与表单里的 `+` 会被解码成空格——
/// 于是用户输入的 `+8613800138000` 会静默变成「 8613800138000」，参数值 `a+b`
/// 会变成 `a b`。对一个接口调试工具来说，静默篡改用户输入是不可接受的。
///
/// 因此这里自己编码：把 `+` 连同 `& = ? # %` 一起从允许集里剔除。
/// （`%` 虽会被 Foundation 正确编码为 `%25`，但自建编码器必须显式处理，否则
/// 手工编码过的输入会被原样放行。）
///
/// 本类型只依赖 Foundation，便于脱离 UI 独立验证。
enum FormEncoding {

    /// 需要强制百分号编码的字符。
    private static let reserved = "&=+?#%"

    private static let allowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: reserved)
        return set
    }()

    /// 编码单个组件（键或值）。
    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// 拼接为 `k1=v1&k2=v2`。空格编码为 `%20`（无歧义的写法）。
    static func queryString(_ items: [(key: String, value: String)]) -> String {
        items.map { "\(encode($0.key))=\(encode($0.value))" }.joined(separator: "&")
    }
}
