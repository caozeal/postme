import Foundation

/// 请求 → curl 命令的导出器，`CurlCodec`（导入器）的逆运算。
///
/// **判据与导入侧同源**：命令必须是「服务端会收到什么」的忠实复述，而不是一串看着像的字符。
/// 因此这里刻意与 `RequestExecutor.buildURLRequest` 对齐：地址走同一个 `previewURL`
/// （query 合并 + `FormEncoding` 编码），正文与隐含的 `Content-Type` 走同一张表，
/// 只导出启用且键非空的行。`CurlCodec.decode(export(r))` 应当还原出等价请求（有测试钉住）。
///
/// 几处**刻意**的选择：
/// - `--data-raw` 而不是 `-d`：curl 的 `-d '@file'` 会去读文件，正文以 `@` 开头时会被换掉。
/// - `--form-string` 而不是 `-F`：`-F` 会把取值里的 `@` / `<` / `;` 当语法，multipart 的
///   文本字段要的是字面量。
/// - multipart 不补 `Content-Type`：boundary 必须由 curl 自己生成，写死一个boundary
///   写死一个 boundary 会让头与正文对不上（这与导入侧记录的「boundary 取值差异」是同一件事）。
/// - 含控制字符的取值用 ANSI-C 引用 `$'...'`：裸换行放进单引号里 bash 也认，
///   但经剪贴板/JSON 工具中转极易被压平，转义写法在哪都是可读的一行。
///
/// 只依赖 Foundation，便于脱离 UI 独立验证。
enum CurlExport {

    /// 导出选项。默认值与 curl 自身行为一致（不跟随重定向、校验证书）。
    struct Options: Equatable {
        /// 跟随重定向（curl 需要显式 `-L`）。
        var followRedirects: Bool
        /// 忽略证书校验（curl 需要显式 `-k`）。
        var allowInsecureTLS: Bool

        init(followRedirects: Bool = false, allowInsecureTLS: Bool = false) {
            self.followRedirects = followRedirects
            self.allowInsecureTLS = allowInsecureTLS
        }

        /// 用 App 的实际执行参数构造：导出的命令复述的是 App **这一次**会发出的行为，
        /// 而不是一条理想化的命令。
        init(_ executorOptions: RequestExecutorOptions) {
            self.init(
                followRedirects: executorOptions.followRedirects,
                allowInsecureTLS: executorOptions.allowInsecureTLS
            )
        }
    }

    /// 生成一条 curl 命令（多行 + `\` 续行，和浏览器「Copy as cURL」一个形状）。
    static func command(for request: APIRequest, options: Options = Options()) -> String {
        let enabledHeaders = request.headers.filter { $0.isEnabled && !$0.key.isEmpty }
        let fields = request.formFields.filter { $0.isEnabled && !$0.key.isEmpty }
        let userContentType = enabledHeaders.contains { $0.key.lowercased() == "content-type" }
        let hasBody = request.bodyKind != .none

        var args: [String] = [quote(RequestExecutor.previewURL(request))]

        // 方法：GET 无正文交给 curl 的默认值；HEAD 无正文用 `-I`
        //（curl 用 `-X HEAD` 会一直等一个 HEAD 本来就不带的正文）。
        if request.method == .head, !hasBody {
            args.append("-I")
        } else if request.method != .get || hasBody {
            args += ["-X", request.method.rawValue]
        }

        if options.followRedirects { args.append("-L") }
        if options.allowInsecureTLS { args.append("-k") }

        for header in enabledHeaders {
            args += ["-H", quote("\(header.key): \(header.value)")]
        }

        switch request.bodyKind {
        case .none:
            break

        case .json, .rawText:
            args += ["--data-raw", quote(request.bodyText)]
            if !userContentType {
                let type = request.bodyKind == .json
                    ? "application/json"
                    : (request.rawContentType.isEmpty ? "text/plain" : request.rawContentType)
                args += ["-H", quote("Content-Type: \(type)")]
            }

        case .formURLEncoded:
            let encoded = FormEncoding.queryString(fields.map { (key: $0.key, value: $0.value) })
            args += ["--data-raw", quote(encoded)]
            if !userContentType {
                args += ["-H", quote("Content-Type: application/x-www-form-urlencoded")]
            }

        case .multipart:
            for field in fields {
                args += ["--form-string", quote("\(field.key)=\(field.value)")]
            }
            // 文件字段用 `-F`：`--form-string` 会把 `@` 当字面量，服务端收到的就是路径字符串。
            for file in request.fileFields where file.isEnabled && !file.name.isEmpty {
                args += ["-F", quote("\(file.name)=@\(file.resolvedPath)")]
            }

        case .binary:
            // `--data-binary` 保留文件原始字节；`-d` 会去掉换行，不能用来传二进制。
            // 展开 `~`：导出的是 shell 命令，单引号里的 `~` 不会被 shell 展开。
            let path = (request.binaryFilePath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)
                .expandingTildeInPath
            args += ["--data-binary", quote("@\(path)")]
            if !userContentType {
                let type = request.binaryContentType.trimmingCharacters(in: .whitespacesAndNewlines)
                args += ["-H", quote("Content-Type: \(type.isEmpty ? "application/octet-stream" : type)")]
            }
        }

        return (["curl"] + args).joined(separator: " \\\n  ")
    }

    /// 单个参数按 shell 规则引用：默认单引号，含控制字符时改用 ANSI-C 引用。
    static func quote(_ value: String) -> String {
        if value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return ansiCQuoted(value)
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `$'...'`。只转义 `CurlCodec` 认得的那些（`\n` `\t` `\r` `\\` `\'`）——
    /// 它不认 `\x41` 这类，写了就变成字面量 `\x41`；其余控制字符原样保留，
    /// bash 与解析器都按字面处理。
    private static func ansiCQuoted(_ value: String) -> String {
        var out = "$'"
        for character in value {
            switch character {
            case "\\": out += "\\\\"
            case "'": out += "\\'"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default: out.append(character)
            }
        }
        return out + "'"
    }
}
