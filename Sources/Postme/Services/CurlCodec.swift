import Foundation

/// curl 命令 → 请求的导入器。
///
/// 主要来源是浏览器「Copy as cURL」（Chrome / Safari / Firefox）与 Postman 的 cURL
/// 代码片段，其次是终端里手写或脚本里复制的命令。
///
/// **为什么不做成"随便抠个 URL 就算导入"**：curl 命令里真正决定服务端收到什么的是
/// `-X / -H / -d / -F / -u / -b` 这一组参数，只取 URL 会把方法、认证、正文全部丢掉——
/// 导入进来的请求看着像，发出去完全不是一回事。
///
/// 本类型只依赖 Foundation，便于脱离 UI 独立验证。
enum CurlCodec {

    // MARK: - 错误

    enum CodecError: LocalizedError, Equatable {
        case emptyInput
        case noCommand
        case missingValue(command: Int, flag: String)
        case missingURL(command: Int)
        case unterminatedQuote(command: Int)

        var errorDescription: String? {
            switch self {
            case .emptyInput:
                return "没有可导入的内容"
            case .noCommand:
                return "没找到 curl 命令：文本里需要有以 curl 开头的命令"
            case .missingValue(let command, let flag):
                return "第 \(command) 条命令：\(flag) 后面缺少取值"
            case .missingURL(let command):
                return "第 \(command) 条命令：没找到请求地址"
            case .unterminatedQuote(let command):
                return "第 \(command) 条命令：引号没有闭合"
            }
        }
    }

    struct ImportResult {
        /// 解析出的请求（`name` 已按 URL 推导，便于侧栏一眼认出）。
        var requests: [APIRequest]
        /// 无法在导入时表达、必须让用户知道的内容。**不静默丢弃**。
        var warnings: [String]
    }

    // MARK: - 入口

    static func decode(_ text: String) throws -> ImportResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodecError.emptyInput
        }
        let blocks = commandBlocks(in: text)
        guard !blocks.isEmpty else { throw CodecError.noCommand }

        let notes = Notes()
        var requests: [APIRequest] = []
        for (offset, block) in blocks.enumerated() {
            let command = offset + 1
            let tokens = try tokenize(block, command: command)
            requests.append(contentsOf: try parse(tokens, command: command, notes: notes))
        }
        guard !requests.isEmpty else { throw CodecError.noCommand }
        return ImportResult(requests: requests, warnings: notes.messages)
    }

    /// 文本里是否含 curl 命令。用于「打开面板时决定要不要预填剪贴板」。
    static func looksLikeCommand(_ text: String) -> Bool {
        !commandBlocks(in: text).isEmpty
    }

    // MARK: - 提示收集

    /// 导入过程中累积的提示，去重后回传。用引用类型承载，避免层层回传。
    private final class Notes {
        private(set) var messages: [String] = []
        private var seen = Set<String>()

        func add(_ message: String) {
            guard seen.insert(message).inserted else { return }
            messages.append(message)
        }
    }

    // MARK: - 切分命令

    /// 把整段文本切成若干条 curl 命令。
    ///
    /// Chrome 的「Copy all as cURL」就是把多条命令逐行罗列，所以按「行首出现 curl」
    /// 切分；续行（bash `\`、cmd `^`、PowerShell 反引号）先合并，行首提示符与注释行丢弃。
    private static func commandBlocks(in text: String) -> [String] {
        var blocks: [String] = []
        var current: String?

        for rawLine in joinedContinuations(text).split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(rawLine)

            // 引号内的换行是正文本身（`-d 'line1<换行>line2'` 发出的就是带换行的内容），
            // 必须原样保留：换成空格、或把缩进 trim 掉，服务端收到的字节就变了。
            if let open = current, isInsideQuote(open) {
                current = open + "\n" + raw
                continue
            }

            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            line = stripPrompt(line)

            if isCurlInvocation(line) {
                if let current { blocks.append(current) }
                current = line
            } else if current != nil {
                // 续行已被合并，走到这里的多半是被拆成多行的参数，用空格接上
                current! += " " + line
            }
        }
        if let current { blocks.append(current) }
        return blocks
    }

    /// 文本末尾是否停在未闭合的引号里。
    private static func isInsideQuote(_ text: String) -> Bool {
        enum Quote { case none, single, double }
        var quote = Quote.none
        var escaped = false

        for character in text {
            if escaped {
                escaped = false
                continue
            }
            switch quote {
            case .none:
                if character == "\\" { escaped = true }
                else if character == "'" { quote = .single }
                else if character == "\"" { quote = .double }
            case .single:
                // 单引号内没有转义，`\` 就是普通字符
                if character == "'" { quote = .none }
            case .double:
                if character == "\\" { escaped = true }
                else if character == "\"" { quote = .none }
            }
        }
        return quote != .none
    }

    /// 合并 shell 续行符：bash `\`、cmd `^`、PowerShell 反引号。
    ///
    /// 只在**后面紧跟换行**时才当续行处理——否则正文里正常的 `^` 或反引号会被吃掉。
    private static func joinedContinuations(_ text: String) -> String {
        let characters = Array(text)
        var result = ""
        result.reserveCapacity(characters.count)

        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\r" {
                index += 1
                continue
            }
            if character == "\\" || character == "^" || character == "`" {
                let next = index + 1
                let afterNext = index + 2
                let endsLine = next < characters.count && (characters[next] == "\n"
                    || (characters[next] == "\r" && afterNext < characters.count && characters[afterNext] == "\n"))
                if endsLine {
                    result.append(" ")
                    index = next + 1
                    continue
                }
            }
            result.append(character)
            index += 1
        }
        return result
    }

    /// 去掉常见提示符 / 提权前缀，让「从终端里复制」的文本也能导入。
    private static func stripPrompt(_ line: String) -> String {
        for prefix in ["sudo ", "$ ", "> ", "% ", "PS> "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return line
    }

    private static func isCurlInvocation(_ line: String) -> Bool {
        guard let first = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else { return false }
        return isCurlBinary(String(first))
    }

    /// `curl` / `curl.exe` / `/usr/bin/curl` 都算。
    private static func isCurlBinary(_ token: String) -> Bool {
        let name = (token as NSString).lastPathComponent.lowercased()
        return name == "curl" || name == "curl.exe"
    }

    // MARK: - 切词

    /// 按 shell 引号规则切词。
    ///
    /// - 单引号内是字面量（bash 语义）。`'\''` 这种拼接也正确：引号外的 `\'` 本就是转义。
    /// - 双引号内 `\` 只对 `"` `\` `$` 反引号有转义含义，其余原样保留——所以
    ///   `-d '{"a":"\n"}'` 里的 `\n` 不会被吃掉（吃掉就会改变发给服务端的内容）。
    private static func tokenize(_ block: String, command: Int) throws -> [String] {
        let characters = Array(block)
        var tokens: [String] = []
        var current = ""
        var hasCurrent = false
        var quote: Character?

        var index = 0
        while index < characters.count {
            let character = characters[index]

            switch quote {
            case "'":
                if character == "'" { quote = nil } else { current.append(character) }
                index += 1

            case "\"":
                if character == "\"" {
                    quote = nil
                    index += 1
                } else if character == "\\", index + 1 < characters.count,
                          "\"\\$`".contains(characters[index + 1]) {
                    current.append(characters[index + 1])
                    index += 2
                } else {
                    current.append(character)
                    index += 1
                }

            default:
                if character == "$", !hasCurrent, index + 1 < characters.count,
                   characters[index + 1] == "'" {
                    // bash 的 ANSI-C 引用 `$'...'`：`\n` 这类转义在这里生效，
                    // 不还原就会把两个字面字符发给服务端。
                    index += 2
                    hasCurrent = true
                    var terminated = false
                    while index < characters.count {
                        if characters[index] == "'" {
                            index += 1
                            terminated = true
                            break
                        }
                        if characters[index] == "\\", index + 1 < characters.count {
                            switch characters[index + 1] {
                            case "n": current.append("\n")
                            case "t": current.append("\t")
                            case "r": current.append("\r")
                            case "0": current.append("\0")
                            case "e": current.append("\u{1B}")
                            case "\\": current.append("\\")
                            case "'": current.append("'")
                            case "\"": current.append("\"")
                            case let other: current.append("\\"); current.append(other)
                            }
                            index += 2
                        } else {
                            current.append(characters[index])
                            index += 1
                        }
                    }
                    if !terminated { throw CodecError.unterminatedQuote(command: command) }
                } else if character == "$", !hasCurrent, index + 1 < characters.count,
                          characters[index + 1] == "\"" {
                    // `$"..."` 是本地化翻译语法，`$` 不是内容
                    index += 1
                } else if character == "'" || character == "\"" {
                    quote = character
                    hasCurrent = true
                    index += 1
                } else if character == "\\", index + 1 < characters.count {
                    current.append(characters[index + 1])
                    hasCurrent = true
                    index += 2
                } else if character == " " || character == "\t" || character == "\n" {
                    if hasCurrent {
                        tokens.append(current)
                        current = ""
                        hasCurrent = false
                    }
                    index += 1
                } else {
                    current.append(character)
                    hasCurrent = true
                    index += 1
                }
            }
        }

        if quote != nil { throw CodecError.unterminatedQuote(command: command) }
        if hasCurrent { tokens.append(current) }
        return tokens
    }

    // MARK: - 选项展开

    /// 取值的短选项。列全一点是必要的：漏一个就会把它的取值当成请求地址。
    private static let valueShortFlags: Set<Character> = [
        "A", "b", "c", "C", "d", "D", "e", "E", "F", "H", "K", "m",
        "o", "P", "Q", "r", "t", "T", "u", "w", "x", "X", "y", "Y", "z",
    ]

    /// 取值的长选项（同样：漏一个就会把它的取值误认成地址）。
    private static let valueLongFlags: Set<String> = [
        "--request", "--header", "--data", "--data-raw", "--data-binary", "--data-ascii",
        "--data-urlencode", "--form", "--form-string", "--user", "--url", "--cookie",
        "--user-agent", "--referer", "--max-time", "--connect-timeout", "--proxy",
        "--output", "--write-out", "--upload-file", "--cert", "--key", "--cacert",
        "--capath", "--retry", "--resolve", "--connect-to", "--interface", "--limit-rate",
        "--range", "--json", "--oauth2-bearer", "--aws-sigv4", "--cookie-jar", "--dump-header",
        "--continue-at", "--time-cond", "--speed-limit", "--speed-time", "--telnet-option",
    ]

    /// 把 token 流展开成 `(flag, value)` 列表，统一处理三种写法：
    /// `--flag=value`、`-XPOST`（取值粘连）、`-sSL`（布尔选项簇）。
    /// 位置参数（非 `-` 开头）原样保留，value 为 nil。
    private static func expand(_ tokens: [String]) -> [(flag: String, value: String?)] {
        var result: [(String, String?)] = []
        var index = 0

        while index < tokens.count {
            let raw = tokens[index]
            index += 1

            guard raw.hasPrefix("-"), raw != "-", raw != "--" else {
                result.append((raw, nil))
                continue
            }

            if raw.hasPrefix("--") {
                if let equals = raw.firstIndex(of: "=") {
                    result.append((String(raw[raw.startIndex..<equals]), String(raw[raw.index(after: equals)...])))
                } else if valueLongFlags.contains(raw) {
                    result.append((raw, index < tokens.count ? tokens[index] : nil))
                    if index < tokens.count { index += 1 }
                } else {
                    result.append((raw, nil))
                }
                continue
            }

            let characters = Array(raw.dropFirst())
            var offset = 0
            while offset < characters.count {
                let flag = "-" + String(characters[offset])
                if valueShortFlags.contains(characters[offset]) {
                    let attached = String(characters[(offset + 1)...])
                    if !attached.isEmpty {
                        result.append((flag, attached))
                    } else if index < tokens.count {
                        result.append((flag, tokens[index]))
                        index += 1
                    } else {
                        result.append((flag, nil))
                    }
                    break
                }
                result.append((flag, nil))
                offset += 1
            }
        }
        return result
    }

    // MARK: - 解析

    /// 一条 curl 命令累积出来的内容。
    private struct CommandState {
        var method: String?
        var url: String?
        var headers: [(String, String)] = []
        var dataParts: [String] = []
        var urlEncoded: [(String, String)] = []
        var forms: [(key: String, value: String, isFile: Bool)] = []
        var user: String?
        var bearer: String?
        var cookies: String?
        var isGet = false
        var isHead = false
        var jsonPayload: String?
    }

    private static func parse(_ tokens: [String], command: Int, notes: Notes) throws -> [APIRequest] {
        let expanded = expand(tokens)

        var index = 0
        // 跳过 `curl` 本体
        if let first = expanded.first, first.value == nil, isCurlBinary(first.flag) { index = 1 }

        func requireValue(_ flag: String, _ raw: String?) throws -> String {
            guard let raw else { throw CodecError.missingValue(command: command, flag: flag) }
            return raw
        }

        var states: [CommandState] = []
        var state = CommandState()

        while index < expanded.count {
            let (flag, value) = expanded[index]
            index += 1

            guard flag.hasPrefix("-") else {
                if state.url == nil, looksLikeURL(flag) {
                    state.url = flag
                } else if state.url == nil {
                    notes.add("无法识别的参数「\(flag)」已忽略。")
                } else {
                    notes.add("多余的地址「\(flag)」已忽略。")
                }
                continue
            }

            switch flag {
            // 方法 / 地址
            case "-X", "--request":
                state.method = try requireValue(flag, value)
            case "--url":
                state.url = try requireValue(flag, value)
            case "-G", "--get":
                state.isGet = true
            case "-I", "--head":
                state.isHead = true

            // 头
            case "-H", "--header":
                let raw = try requireValue(flag, value)
                if let header = parseHeader(raw) {
                    // 逐条追加而不是去重：curl 允许同名头出现多次
                    state.headers.append(header)
                } else {
                    notes.add("请求头「\(raw)」缺少冒号，已忽略。")
                }
            case "-b", "--cookie":
                let raw = try requireValue(flag, value)
                if raw.contains("=") {
                    state.cookies = raw
                } else {
                    notes.add("从文件读 cookie（-b \(raw)）暂不支持，请手动补 Cookie 头。")
                }
            case "-A", "--user-agent":
                state.headers.append(("User-Agent", try requireValue(flag, value)))
            case "-e", "--referer":
                state.headers.append(("Referer", try requireValue(flag, value)))
            case "-u", "--user":
                state.user = try requireValue(flag, value)
            case "--oauth2-bearer":
                state.bearer = try requireValue(flag, value)

            // 正文
            case "-d", "--data", "--data-raw", "--data-ascii", "--data-binary":
                let raw = try requireValue(flag, value)
                if raw.hasPrefix("@") {
                    notes.add("\(flag) \(raw) 表示从文件读正文，postme 无法读该文件，已按字面文本导入。")
                }
                state.dataParts.append(raw)
            case "--data-urlencode":
                let raw = try requireValue(flag, value)
                if let field = parseURLEncoded(raw) {
                    state.urlEncoded.append(field)
                } else {
                    notes.add("--data-urlencode「\(raw)」不是 key=value 形态，已忽略。")
                }
            case "--json":
                state.jsonPayload = try requireValue(flag, value)
            case "-F", "--form":
                state.forms.append(parseFormField(try requireValue(flag, value), allowFile: true))
            case "--form-string":
                state.forms.append(parseFormField(try requireValue(flag, value), allowFile: false))

            // 一个 curl 调用里的分段：各自成一个请求
            case "--next":
                states.append(state)
                state = CommandState()

            // 能识别但无法随请求带走 / 与请求内容无关
            case "--compressed":
                // postme 走 URLSession，压缩与解压默认就是开的，不需要（也不该）显式加头：
                // 手工设 Accept-Encoding 反而可能让自动解压失效，正文会变成乱码。
                break
            case "-k", "--insecure":
                notes.add("curl 的 -k（跳过证书校验）是全局设置，无法随请求导入；需要时请在 设置 → 允许自签名证书 里开启。")
            case "-L", "--location":
                notes.add("curl 的 -L（跟随重定向）是全局设置，postme 默认就跟随，无需额外配置。")
            case "-m", "--max-time", "--connect-timeout":
                notes.add("超时（\(flag)）是全局设置，不会随导入带过来。")
            case "-x", "--proxy":
                notes.add("代理（\(flag)）无法随请求导入，请在网络层配置。")
            case "-E", "--cert", "--key", "--cacert", "--capath":
                notes.add("客户端证书（\(flag)）暂不支持导入。")
            case "--digest", "--ntlm", "--negotiate", "--anyauth":
                notes.add("认证方式 \(flag) 需要动态握手，无法在导入时还原，请手动配置。")
            case "-T", "--upload-file":
                notes.add("上传文件（-T）暂不支持，已忽略。")
            case "--resolve", "--connect-to":
                notes.add("\(flag) 无法随请求导入，请改用能直接解析的地址。")

            case "-i", "--include", "-s", "--silent", "-S", "--show-error",
                 "-v", "--verbose", "-o", "--output", "-O", "--remote-name",
                 "-w", "--write-out", "-D", "--dump-header", "-c", "--cookie-jar",
                 "-C", "--continue-at", "-r", "--range", "-z", "--time-cond",
                 "--retry", "--limit-rate", "--http1.0", "--http1.1", "--http2",
                 "--http2-prior-knowledge", "--tlsv1", "--tlsv1.0", "--tlsv1.1",
                 "--tlsv1.2", "--tlsv1.3", "-4", "--ipv4", "-6", "--ipv6",
                 "-N", "--no-buffer", "-f", "--fail", "-#", "--progress-bar",
                 "--no-progress-meter", "--no-keepalive", "--keepalive-time":
                // 输出形态 / 传输协商 / 进度显示，与「服务端收到什么」无关
                break

            default:
                notes.add("未识别的参数「\(flag)」已忽略。")
            }
        }
        states.append(state)

        return try states.map { try buildRequest($0, command: command, notes: notes) }
    }

    /// 位置参数是否像请求地址。用于挡住「未知选项的取值」被误当成 URL。
    private static func looksLikeURL(_ token: String) -> Bool {
        if token.contains("://") { return true }
        if token.hasPrefix("{{") { return true }
        guard !token.isEmpty, !token.contains(" ") else { return false }
        let head = token.split(separator: "/").first.map(String.init) ?? token
        if head.contains(":") { return true }
        return head.contains(".") && !head.hasSuffix(".")
    }

    // MARK: - 组装请求

    private static func buildRequest(_ state: CommandState, command: Int, notes: Notes) throws -> APIRequest {
        var rawURL = (state.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawURL.isEmpty else { throw CodecError.missingURL(command: command) }

        if !rawURL.contains("://"), !rawURL.hasPrefix("{{") {
            // curl 对 `curl localhost:8080/x` 就是按 http 发的，这里保持一致
            rawURL = "http://" + rawURL
            notes.add("地址缺少协议头，已按 http:// 补全。")
        }

        var request = APIRequest()

        // 片段（#frag）不进 query 解析，原样留在地址里
        var fragment = ""
        if let hash = rawURL.firstIndex(of: "#") {
            fragment = String(rawURL[hash...])
            rawURL = String(rawURL[rawURL.startIndex..<hash])
        }
        if let mark = rawURL.firstIndex(of: "?") {
            let query = String(rawURL[rawURL.index(after: mark)...])
            rawURL = String(rawURL[rawURL.startIndex..<mark])
            request.queryParams = queryItems(from: query)
        }
        request.url = rawURL + fragment

        for header in state.headers {
            request.headers.append(KeyValueItem(key: header.0, value: header.1))
        }
        if let cookies = state.cookies {
            setHeader("Cookie", cookies, on: &request)
        }
        if let user = state.user {
            if !user.contains(":") {
                notes.add("curl 的 -u 只给了用户名（curl 会交互式索要密码），导入时按空密码处理。")
            }
            setHeader("Authorization", "Basic \(Data(user.utf8).base64EncodedString())", on: &request)
        }
        if let bearer = state.bearer {
            setHeader("Authorization", "Bearer \(bearer)", on: &request)
        }

        let hasBody = !state.dataParts.isEmpty || !state.urlEncoded.isEmpty
            || !state.forms.isEmpty || state.jsonPayload != nil
        let fallback: HTTPMethod = hasBody ? .post : .get
        let explicit = state.method?.trimmingCharacters(in: .whitespaces).uppercased()
        // `-F` 与 `-G` 同现时 curl 忽略 `-G`（见 applyBody 说明），方法不能定成 GET。
        let isGet = state.isGet && state.forms.isEmpty
        let methodText = explicit ?? (state.isHead ? "HEAD" : (isGet ? "GET" : fallback.rawValue))
        if let method = HTTPMethod(rawValue: methodText) {
            request.method = method
        } else {
            request.method = fallback
            notes.add("请求方法「\(methodText)」不在支持范围（GET / POST / PUT / PATCH / DELETE / HEAD / OPTIONS），已按 \(fallback.rawValue) 导入。")
        }

        applyBody(state, to: &request, notes: notes)
        request.name = name(for: request)
        return request
    }

    private static func applyBody(_ state: CommandState, to request: inout APIRequest, notes: Notes) {
        var dataText = state.dataParts.joined(separator: "&")
        if let json = state.jsonPayload, dataText.isEmpty { dataText = json }

        // 是否出现过显式正文参数。**空取值也算**：curl 对 `-d ''` / `--json ''` 仍会发
        // POST + 对应 Content-Type（Content-Length: 0），静默丢掉类型会让服务端换解析器。
        let hasExplicitBody = !state.dataParts.isEmpty || state.jsonPayload != nil

        var urlEncodedFields = state.urlEncoded.map { KeyValueItem(key: $0.0, value: $0.1) }
        var movedToQuery = false

        // `-G` 只在「正文来自 -d / --data-urlencode」时把正文改走 query。
        // `-F` 存在时 curl 直接忽略 `-G`（实测：`-G -F 'k=v'` 发的是 POST multipart，
        // `-G -F ... -d ...` 直接报错退出），所以此时不能把方法定成 GET 却仍带 multipart 正文。
        if state.isGet, state.forms.isEmpty {
            if hasExplicitBody || !urlEncodedFields.isEmpty {
                request.queryParams.append(contentsOf: queryItems(from: dataText))
                request.queryParams.append(contentsOf: urlEncodedFields)
                dataText = ""
                urlEncodedFields = []
                movedToQuery = true
            }
        }

        if !state.forms.isEmpty {
            request.bodyKind = .multipart
            var fields: [KeyValueItem] = []
            var warnedFile = false
            for form in state.forms {
                if form.isFile {
                    if !warnedFile {
                        notes.add("文件上传字段（-F key=@file）暂不支持，已保留为禁用字段。")
                        warnedFile = true
                    }
                    fields.append(KeyValueItem(isEnabled: false, key: form.key, value: "（文件字段，v1 不支持）"))
                } else {
                    fields.append(KeyValueItem(key: form.key, value: form.value))
                }
            }
            request.formFields = fields
            if !dataText.isEmpty {
                notes.add("同时出现 -F 与 -d：curl 只会发送 -F，导入时以 -F 为准。")
            }
            return
        }

        guard !dataText.isEmpty || !urlEncodedFields.isEmpty || (hasExplicitBody && !movedToQuery) else { return }

        let contentType = request.headers.first {
            $0.key.lowercased() == "content-type"
        }?.value.trimmingCharacters(in: .whitespaces).lowercased()

        let isFormType = contentType == nil || contentType == "application/x-www-form-urlencoded"

        if !urlEncodedFields.isEmpty, dataText.isEmpty {
            // 只有 --data-urlencode（无 -d）：curl 把它们编成表单正文
            request.bodyKind = .formURLEncoded
            request.formFields = urlEncodedFields
            return
        }

        if dataText.isEmpty {
            // 空正文：curl 照样带 Content-Type 发出（`--json ''` → application/json + Accept）。
            if state.jsonPayload != nil {
                request.bodyKind = .json
                request.bodyText = ""
                request.rawContentType = "application/json"
                setHeader("Accept", "application/json", on: &request)
                setHeader("Content-Type", "application/json", on: &request)
            } else {
                request.bodyKind = .rawText
                request.bodyText = ""
                request.rawContentType = contentType ?? "application/x-www-form-urlencoded"
            }
            return
        }

        if !urlEncodedFields.isEmpty {
            if let parsed = formFields(from: dataText), isFormType {
                request.bodyKind = .formURLEncoded
                request.formFields = parsed + urlEncodedFields
                return
            }
            notes.add("--data-urlencode 与其它形态的正文混用，无法合并，已只保留正文。")
        }

        // 只有「curl 明确要求 JSON」才算 JSON：`--json` 会自己设头，显式 `Content-Type` 是用户意图。
        // **不能靠内容长得像 JSON 就改类型**：`-d '{"x":1}'` 时 curl 发的是
        // `application/x-www-form-urlencoded`（服务端换解析器），字节一致性优先于"字段好看"。
        let isJSON = state.jsonPayload != nil
            || contentType?.contains("json") == true

        if isJSON {
            request.bodyKind = .json
            request.bodyText = dataText
            request.rawContentType = "application/json"
            if state.jsonPayload != nil { setHeader("Accept", "application/json", on: &request) }
            setHeader("Content-Type", "application/json", on: &request)
            return
        }

        if isFormType, let parsed = formFields(from: dataText) {
            request.bodyKind = .formURLEncoded
            request.formFields = parsed
            return
        }

        if isFormType {
            // 形状不像表单（多行文本、裸 JSON…）：curl 原样发出这段字节，
            // 但 Content-Type 仍然是表单类型——照抄这个事实，否则服务端解析方式会变。
            request.bodyKind = .rawText
            request.bodyText = dataText
            request.rawContentType = "application/x-www-form-urlencoded"
            return
        }

        request.bodyKind = .rawText
        request.bodyText = dataText
        request.rawContentType = contentType ?? "text/plain"
    }

    /// 写入头，但**不覆盖 curl 命令里显式给过的同名头**。
    private static func setHeader(_ key: String, _ value: String, on request: inout APIRequest) {
        if request.headers.contains(where: { $0.key.lowercased() == key.lowercased() }) { return }
        request.headers.append(KeyValueItem(key: key, value: value))
    }

    /// `K: V`。空值（`-H 'Accept:'`）是 curl 用来「删掉默认头」的写法，
    /// postme 本来就不补默认头，等价于什么都不做，故返回 nil。
    private static func parseHeader(_ raw: String) -> (String, String)? {
        guard let colon = raw.firstIndex(of: ":") else { return nil }
        let key = String(raw[raw.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
        let value = String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !value.isEmpty else { return nil }
        return (key, value)
    }

    /// `--data-urlencode`：`k=v` 里的 v 是**字面文本**，由 curl 负责编码。
    ///
    /// **不能先 percent-decode**：curl 把 `%` 也一并编码（`msg=a%20b` 实际发出
    /// `msg=a%2520b`），先解码再交给 FormEncoding 会少一层转义，服务端收到的值就变了。
    private static func parseURLEncoded(_ raw: String) -> (String, String)? {
        // curl 还支持 `name@file` / `@file`（读文件）与 `=content`（无键），本版不支持
        guard let equals = raw.firstIndex(of: "="), equals != raw.startIndex else { return nil }
        let key = String(raw[raw.startIndex..<equals])
        let value = String(raw[raw.index(after: equals)...])
        return (key, value)
    }

    /// `-F 'key=value'`。`@` / `<` 前缀表示读文件；`;type=...` 是 curl 的 part 选项，
    /// postme 的 multipart 不写 part 级 Content-Type，故丢弃。
    private static func parseFormField(_ raw: String, allowFile: Bool) -> (key: String, value: String, isFile: Bool) {
        let parts = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let key = String(parts.first ?? "")
        var value = parts.count > 1 ? String(parts[1]) : ""
        if let semicolon = value.firstIndex(of: ";") {
            value = String(value[value.startIndex..<semicolon])
        }
        let isFile = allowFile && (value.hasPrefix("@") || value.hasPrefix("<"))
        return (key, value, isFile)
    }

    /// 解析 `k=v&k2=v2`。`+` 按 form-urlencoded 约定还原成空格——
    /// 编码侧（FormEncoding）把空格写成 `%20`、把 `+` 写成 `%2B`，
    /// 因此「先解码再编码」不改变服务端最终收到的值。
    private static func queryItems(from raw: String) -> [KeyValueItem] {
        raw.split(separator: "&", omittingEmptySubsequences: true).compactMap { segment in
            let parts = segment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = decodeComponent(String(parts[0]))
            guard !key.isEmpty else { return nil }
            let value = parts.count > 1 ? decodeComponent(String(parts[1])) : ""
            return KeyValueItem(key: key, value: value)
        }
    }

    /// 判断一段正文是否是表单数据。要求每段都有非空键，且不含 JSON 的结构字符——
    /// 否则宁可当原文保留（把 JSON 拆成表单字段会静默改变发出的内容）。
    private static func formFields(from raw: String) -> [KeyValueItem]? {
        guard !raw.isEmpty, !raw.contains("{"), !raw.contains("}"), !raw.contains("\n") else { return nil }
        let segments = raw.split(separator: "&", omittingEmptySubsequences: true)
        guard !segments.isEmpty else { return nil }

        var items: [KeyValueItem] = []
        for segment in segments {
            guard let equals = segment.firstIndex(of: "=") else { return nil }
            let key = decodeComponent(String(segment[segment.startIndex..<equals]))
            guard !key.isEmpty else { return nil }
            let value = decodeComponent(String(segment[segment.index(after: equals)...]))
            items.append(KeyValueItem(key: key, value: value))
        }
        return items
    }

    private static func decodeComponent(_ text: String) -> String {
        text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? text
    }

    /// 用地址最后一段命名；没有路径段就用主机名。
    private static func name(for request: APIRequest) -> String {
        var rest = request.url
        var host = ""
        if let range = rest.range(of: "://") {
            rest = String(rest[range.upperBound...])
            if let slash = rest.firstIndex(of: "/") {
                host = String(rest[rest.startIndex..<slash])
                rest = String(rest[slash...])
            } else {
                host = rest
                rest = ""
            }
        }
        if let last = rest.split(separator: "/").last, !last.isEmpty { return String(last) }
        if !host.isEmpty { return host }
        return "cURL 导入"
    }
}
