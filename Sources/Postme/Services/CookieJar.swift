import Foundation

/// 会话内 Cookie Jar。
///
/// **只在内存里**：退出即清空。调试器悄悄把登录态持久化到磁盘，下一次启动
/// 还带着上一次的会话，是很容易让人误判「接口怎么突然有权限了」的行为。
///
/// 只做 RFC 6265 里调试需要的子集：域、路径、Secure、过期时间。
/// 不处理 SameSite（URLSession 手动注入本来也不参与浏览器同站判断）。
struct CookieJar {
    private var storage: [String: HTTPCookie] = [:]

    /// 记录响应里的 `Set-Cookie`。
    ///
    /// 逐条解析而不是把同名头塞进字典：`Set-Cookie` 可以出现多次，
    /// 字典会只剩最后一条。
    mutating func store(responseHeaders: [HTTPHeader], for url: URL?) {
        guard let url, url.host != nil else { return }
        let now = Date()

        for header in responseHeaders where header.name.caseInsensitiveCompare("Set-Cookie") == .orderedSame {
            let parsed = HTTPCookie.cookies(
                withResponseHeaderFields: ["Set-Cookie": header.value],
                for: url
            )
            for cookie in parsed {
                let key = Self.key(for: cookie)
                if let expiry = cookie.expiresDate, expiry <= now {
                    // Max-Age=0 / 已过期：等价于删除同名 Cookie。
                    storage.removeValue(forKey: key)
                } else {
                    storage[key] = cookie
                }
            }
        }

        storage = storage.filter { _, cookie in
            guard let expiry = cookie.expiresDate else { return true }
            return expiry > now
        }
    }

    /// 当前 URL 能带上的 Cookie，按路径长度降序（RFC 6265 的发送顺序）。
    func matching(for url: URL?) -> [HTTPCookie] {
        guard let url, let host = url.host?.lowercased() else { return [] }
        let requestPath = url.path.isEmpty ? "/" : url.path
        let isHTTPS = url.scheme?.lowercased() == "https"
        let now = Date()

        return storage.values
            .filter { cookie in
                if cookie.isSecure, !isHTTPS { return false }
                if let expiry = cookie.expiresDate, expiry <= now { return false }

                let domain = cookie.domain.lowercased()
                let domainMatches: Bool
                if domain.hasPrefix(".") {
                    domainMatches = host == String(domain.dropFirst()) || host.hasSuffix(domain)
                } else {
                    domainMatches = host == domain
                }
                guard domainMatches else { return false }

                let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
                if requestPath == cookiePath { return true }
                guard requestPath.hasPrefix(cookiePath) else { return false }
                return cookiePath.hasSuffix("/") || requestPath.dropFirst(cookiePath.count).hasPrefix("/")
            }
            .sorted { $0.path.count > $1.path.count }
    }

    /// 供 Cookie 分页展示（不过滤域，让用户看见当前会话里都有什么）。
    var all: [HTTPCookie] {
        storage.values.sorted {
            if $0.domain != $1.domain { return $0.domain < $1.domain }
            if $0.path != $1.path { return $0.path < $1.path }
            return $0.name < $1.name
        }
    }

    var count: Int { storage.count }

    mutating func removeAll() {
        storage.removeAll()
    }

    private static func key(for cookie: HTTPCookie) -> String {
        "\(cookie.domain.lowercased())|\(cookie.path)|\(cookie.name)"
    }
}

/// 把「手动 Cookie 行 + 会话 Jar」物化成一条 `Cookie` 头。
///
/// 优先级：显式 `Cookie` 头 > 手动行 > Jar。手动行与 Jar 同名时手动行胜出，
/// 这样用户可以用一行显式值覆盖自动带上的旧会话。
enum CookieApplier {
    @discardableResult
    static func apply(manual: [KeyValueItem], jar: [HTTPCookie], to request: inout APIRequest) -> Bool {
        let hasExplicit = request.headers.contains {
            $0.isEnabled && !$0.key.isEmpty && $0.key.caseInsensitiveCompare("Cookie") == .orderedSame
        }
        guard !hasExplicit else { return false }

        var pairs: [String] = []
        var seen = Set<String>()

        for item in manual where item.isEnabled && !item.key.isEmpty {
            pairs.append("\(sanitize(item.key))=\(sanitize(item.value))")
            seen.insert(item.key)
        }
        for cookie in jar where !seen.contains(cookie.name) {
            pairs.append("\(sanitize(cookie.name))=\(sanitize(cookie.value))")
            seen.insert(cookie.name)
        }

        guard !pairs.isEmpty else { return false }
        request.headers.append(KeyValueItem(key: "Cookie", value: pairs.joined(separator: "; ")))
        return true
    }

    /// 头值里不允许 CR/LF；不清掉就可能被一个手改的 Cookie 值拆成两个头。
    private static func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
    }
}
