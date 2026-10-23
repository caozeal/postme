import Foundation

/// 把认证配置物化成等价的 Header / Query 参数。
///
/// **只依赖 Foundation**：发送、cURL 导出、最终 URL 预览都从这里取同一份结果，
/// 不允许任何一条链路自己再拼一遍（那正是「界面显示有、实际没发」的来源）。
///
/// 三条硬规则：
/// 1. 显式优先——已有启用的同名 Header（大小写不敏感）/ 同名 Query 时不再写入；
/// 2. 空值不注入——绝不发出 `Authorization: Bearer ` 这种看起来有认证、实际是空的请求；
/// 3. 幂等——重复调用不会产生第二行。
enum AuthApplier {

    /// 注入认证。返回是否真的写入了内容（供测试与后续状态提示使用）。
    @discardableResult
    static func apply(_ auth: RequestAuth, to request: inout APIRequest) -> Bool {
        switch auth.kind {
        case .none:
            return false

        case .bearer:
            let token = auth.bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return false }
            return setHeader("Authorization", "Bearer \(token)", on: &request)

        case .basic:
            // RFC 7617：用户名与密码以 UTF-8 拼接后整体 base64。
            guard !auth.username.isEmpty || !auth.password.isEmpty else { return false }
            let encoded = Data("\(auth.username):\(auth.password)".utf8).base64EncodedString()
            return setHeader("Authorization", "Basic \(encoded)", on: &request)

        case .apiKey:
            let name = auth.apiKeyName.trimmingCharacters(in: .whitespacesAndNewlines)
            // 空值的 API Key 是「还没填」，不是「发一个空头」。导入 spec 的认证
            // 只有类型与键名、没有凭据，必须等用户补上值才注入。
            guard !name.isEmpty, !auth.apiKeyValue.isEmpty else { return false }
            switch auth.apiKeyLocation {
            case .header:
                return setHeader(name, auth.apiKeyValue, on: &request)
            case .query:
                return setQuery(name, auth.apiKeyValue, on: &request)
            }
        }
    }

    /// 写入 Header，但**不覆盖用户手写的显式设置**。
    private static func setHeader(_ name: String, _ value: String, on request: inout APIRequest) -> Bool {
        let exists = request.headers.contains {
            $0.isEnabled && !$0.key.isEmpty && $0.key.caseInsensitiveCompare(name) == .orderedSame
        }
        guard !exists else { return false }
        request.headers.append(KeyValueItem(key: name, value: value))
        return true
    }

    /// 写入 Query 参数，同样让位于手写项。
    ///
    /// Query 键按大小写敏感比较：`api_key` 与 `API_KEY` 在服务端可能是两个参数，
    /// 这里不该替用户合并。
    private static func setQuery(_ name: String, _ value: String, on request: inout APIRequest) -> Bool {
        let exists = request.queryParams.contains {
            $0.isEnabled && !$0.key.isEmpty && $0.key == name
        }
        guard !exists else { return false }
        request.queryParams.append(KeyValueItem(key: name, value: value))
        return true
    }
}
