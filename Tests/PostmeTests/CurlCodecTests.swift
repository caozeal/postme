import XCTest
@testable import Postme

/// cURL 命令导入。
///
/// 断言尽量落在**发送出去的请求**上（`RequestExecutor.buildURLRequest`），而不是
/// 中间模型字段——「解析出了字段」和「真的发出去了」是两件事：
/// 曾经 `-G --data-urlencode 'q=a b'` 就是解析出了字段、却既没进 query 也没进正文，
/// 只看模型的测试会全绿。
final class CurlCodecTests: XCTestCase {

    private func only(_ command: String, file: StaticString = #filePath, line: UInt = #line) throws -> APIRequest {
        let result = try CurlCodec.decode(command, l10n: .zhHans)
        XCTAssertEqual(result.requests.count, 1, "应解析出 1 个请求", file: file, line: line)
        return result.requests[0]
    }

    private func wire(_ request: APIRequest) throws -> URLRequest {
        try RequestExecutor.buildURLRequest(request, options: RequestExecutorOptions())
    }

    private func body(of request: URLRequest) -> String {
        guard let data = request.httpBody else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 浏览器「Copy as cURL」

    func testBrowserCopyIsPreserved() throws {
        let command = #"curl 'https://api.demo.com/users?page=1&size=20&phone=%2B8613800138000' -H 'accept: application/json' -H 'content-type: application/json' --data-raw '{"a":1,"b":"x&y"}'"#
        let request = try only(command)

        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.url, "https://api.demo.com/users")
        XCTAssertEqual(request.bodyKind, .json)
        XCTAssertEqual(request.bodyText, #"{"a":1,"b":"x&y"}"#)

        // 加号必须还原成 `+`，不能变成空格——签名参数错一位就废
        XCTAssertEqual(request.queryParams.map(\.key), ["page", "size", "phone"])
        XCTAssertEqual(request.queryParams.map(\.value), ["1", "20", "+8613800138000"])

        let url = try XCTUnwrap(wire(request).url?.absoluteString)
        XCTAssertTrue(url.contains("phone=%2B8613800138000"), url)
        XCTAssertTrue(url.contains("size=20"), url)
    }

    // MARK: - 正文

    func testPlainDataBecomesFormBody() throws {
        let request = try only(#"curl 'https://api.demo.com/login' -d 'user=a&pwd=b'"#)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.bodyKind, .formURLEncoded)
        XCTAssertEqual(request.formFields.map { "\($0.key)=\($0.value)" }, ["user=a", "pwd=b"])
    }

    func testDataWithNonFormShapeKeepsCurlContentType() throws {
        // curl 对 `-d` 一律发 Content-Type: application/x-www-form-urlencoded，
        // 哪怕内容是多行文本；把类型改成 text/plain 会让服务端解析方式变掉。
        let request = try only("curl 'https://api.demo.com/e' -d 'line1\nline2'")
        XCTAssertEqual(request.bodyKind, .rawText)
        XCTAssertEqual(request.bodyText, "line1\nline2")

        let built = try wire(request)
        XCTAssertEqual(built.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
    }

    func testDataURLEncodeValueIsLiteral() throws {
        // `--data-urlencode` 的 v 是字面文本，curl 连 `%` 一起编码。
        // 先 percent-decode 再交给 FormEncoding 会少一层转义。
        let request = try only(#"curl 'https://api.demo.com/e' --data-urlencode 'msg=a+b c'"#)
        XCTAssertEqual(request.formFields.map(\.value), ["a+b c"])
        // 服务端收到的键值对与 curl 一致：`+` 是字面加号，空格编码成 %20 或 + 都行
        XCTAssertEqual(body(of: try wire(request)), "msg=a%2Bb%20c")
    }

    func testANSICQuotingProducesRealNewline() throws {
        let request = try only(#"curl 'https://api.demo.com/e' -d $'line1\nline2'"#)
        XCTAssertEqual(request.bodyText, "line1\nline2")
        XCTAssertFalse(request.bodyText.contains("\\n"))
    }

    func testBareJSONDataKeepsCurlFormContentType() throws {
        // 回归（第 1 轮审查阻断项）：`-d '{"x":1}'` 时 curl 发的是
        // application/x-www-form-urlencoded，postme 曾按"内容像 JSON"改成
        // application/json，服务端会换解析器。字节一致性优先。
        let request = try only(#"curl 'https://api.demo.com/e' -d '{"x":1}'"#)
        XCTAssertEqual(request.bodyKind, .rawText)
        XCTAssertEqual(request.bodyText, #"{"x":1}"#)

        let built = try wire(request)
        XCTAssertEqual(built.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(body(of: built), #"{"x":1}"#)
    }

    func testExplicitJSONContentTypeStillBecomesJSON() throws {
        // 显式给头才是用户意图，此时仍走 JSON 分支（保留原有能力）
        let request = try only(#"curl 'https://api.demo.com/e' -H 'Content-Type: application/json' -d '{"x":1}'"#)
        XCTAssertEqual(request.bodyKind, .json)
        XCTAssertEqual(body(of: try wire(request)), #"{"x":1}"#)
    }

    func testJSONFlagStillBecomesJSON() throws {
        let request = try only(#"curl 'https://api.demo.com/e' --json '{"x":1}'"#)
        XCTAssertEqual(request.bodyKind, .json)
        XCTAssertEqual(request.headers.first { $0.key == "Content-Type" }?.value, "application/json")
        XCTAssertEqual(request.headers.first { $0.key == "Accept" }?.value, "application/json")
    }

    func testEmptyDataStillCarriesFormContentType() throws {
        // 回归（第 3 轮审查次要项）：curl 对 `-d ''` 仍发 POST +
        // application/x-www-form-urlencoded（Content-Length: 0），曾完全不带 Content-Type。
        let request = try only(#"curl 'https://api.demo.com/e' -d ''"#)
        XCTAssertEqual(request.method, .post)

        let built = try wire(request)
        XCTAssertEqual(built.httpMethod, "POST")
        XCTAssertEqual(built.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(body(of: built), "")
    }

    func testEmptyJSONFlagStillCarriesJSONHeaders() throws {
        let request = try only(#"curl 'https://api.demo.com/e' --json ''"#)
        XCTAssertEqual(request.method, .post)

        let built = try wire(request)
        XCTAssertEqual(built.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(built.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testGetFlagIsIgnoredWhenFormFieldsPresent() throws {
        // 回归：curl 在 `-G -F` 同现时忽略 -G，发的是 POST multipart；
        // 曾生成 GET + multipart 正文，URLSession 发送期报 -1103 且导入无提示。
        let request = try only(#"curl -G 'https://api.demo.com/up' -F 'k=v'"#)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.bodyKind, .multipart)
        XCTAssertTrue(request.queryParams.isEmpty)

        let built = try wire(request)
        XCTAssertEqual(built.httpMethod, "POST")
        XCTAssertTrue(try XCTUnwrap(built.value(forHTTPHeaderField: "Content-Type")).hasPrefix("multipart/form-data"))
    }

    // MARK: - -G：正文改走 query

    func testGetFlagMovesDataToQuery() throws {
        let request = try only(#"curl -G 'https://api.demo.com/search' -d 'q=hello' -d 'page=2'"#)
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.queryParams.map(\.key), ["q", "page"])
        XCTAssertEqual(request.bodyKind, .none)

        let url = try XCTUnwrap(wire(request).url?.absoluteString)
        XCTAssertTrue(url.contains("q=hello"), url)
        XCTAssertTrue(url.contains("page=2"), url)
    }

    func testGetFlagMovesDataURLEncodeToQuery() throws {
        // 回归：曾经 --data-urlencode 在 -G 下被当成 GET 的正文，参数直接消失
        let request = try only(#"curl -G 'https://api.demo.com/search' --data-urlencode 'q=hello world'"#)
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.queryParams.map(\.value), ["hello world"])
        XCTAssertEqual(request.bodyKind, .none)

        let url = try XCTUnwrap(wire(request).url?.absoluteString)
        XCTAssertFalse(url.hasSuffix("/search"), url)
        XCTAssertTrue(url.contains("q=hello"), url)
    }

    // MARK: - 认证与 Cookie

    func testBasicAuthBecomesHeader() throws {
        let request = try only(#"curl -u 'alice:s3cr3t' 'https://api.demo.com/auth'"#)
        XCTAssertEqual(request.headers.first { $0.key == "Authorization" }?.value,
                       "Basic " + Data("alice:s3cr3t".utf8).base64EncodedString())
    }

    func testBearerAndCookie() throws {
        let request = try only(#"curl 'https://api.demo.com/x' --oauth2-bearer TOK -b 'sid=abc; theme=dark'"#)
        XCTAssertEqual(request.headers.first { $0.key == "Authorization" }?.value, "Bearer TOK")
        XCTAssertEqual(request.headers.first { $0.key == "Cookie" }?.value, "sid=abc; theme=dark")
    }

    func testExplicitHeaderWinsOverDerivedOne() throws {
        let request = try only(#"curl 'https://api.demo.com/x' -H 'Authorization: Custom z' --oauth2-bearer TOK"#)
        XCTAssertEqual(request.headers.filter { $0.key == "Authorization" }.map(\.value), ["Custom z"])
    }

    // MARK: - multipart

    func testFormFieldsBecomeMultipart() throws {
        let result = try CurlCodec.decode(#"curl 'https://api.demo.com/up' -F 'note=hi there' -F 'f=@/tmp/a.png'"#, l10n: .zhHans)
        let request = try XCTUnwrap(result.requests.first)
        XCTAssertEqual(request.bodyKind, .multipart)
        XCTAssertEqual(request.formFields.first?.value, "hi there")

        // 文件字段无法导入，但要显式禁用 + 提示，不能静默丢掉
        let fileField = try XCTUnwrap(request.formFields.last)
        XCTAssertFalse(fileField.isEnabled)
        XCTAssertTrue(result.warnings.contains { $0.contains("文件") }, "\(result.warnings)")
    }

    func testHeadFlagBecomesHEADWithNoBody() throws {
        let request = try only(#"curl -I 'https://api.demo.com/h'"#)
        XCTAssertEqual(request.method, .head)
        XCTAssertEqual(request.bodyKind, .none)

        let built = try wire(request)
        XCTAssertEqual(built.httpMethod, "HEAD")
        XCTAssertNil(built.httpBody)
    }

    // MARK: - 多条命令与分段

    func testMultipleCommandsBecomeMultipleRequests() throws {
        let result = try CurlCodec.decode("""
        curl 'https://api.demo.com/a' -H 'X-1: a'
        curl 'https://api.demo.com/b' -d 'k=v'
        """, l10n: .zhHans)
        XCTAssertEqual(result.requests.count, 2)
        XCTAssertEqual(result.requests.map(\.url), ["https://api.demo.com/a", "https://api.demo.com/b"])
        XCTAssertEqual(result.requests[1].method, .post)
    }

    func testNextSplitsOneCommandIntoTwoRequests() throws {
        let result = try CurlCodec.decode("curl 'https://api.demo.com/one' --next -X POST 'https://api.demo.com/two' -d 'a=1'", l10n: .zhHans)
        XCTAssertEqual(result.requests.map(\.method), [.get, .post])
        XCTAssertEqual(result.requests.map(\.url), ["https://api.demo.com/one", "https://api.demo.com/two"])
    }

    func testContinuationLinesAreJoined() throws {
        let bash = "curl 'https://api.demo.com/a' \\\n  -H 'X-Trace: t-1' \\\n  -d 'k=v'"
        let windows = "curl \"https://api.demo.com/a\" ^\n  -H \"X-Trace: t-1\" ^\n  -d \"k=v\""
        let powershell = "curl 'https://api.demo.com/a' `\n  -H 'X-Trace: t-1'"

        for command in [bash, windows, powershell] {
            let request = try only(command)
            XCTAssertEqual(request.url, "https://api.demo.com/a")
            XCTAssertEqual(request.headers.first { $0.key == "X-Trace" }?.value, "t-1")
        }
        XCTAssertEqual(try only(bash).formFields.map(\.value), ["v"])
        XCTAssertEqual(try only(windows).formFields.map(\.value), ["v"])
    }

    func testCopyAllWithBlankLinesAndComments() throws {
        let result = try CurlCodec.decode("""
        # 第一批
        curl 'https://api.demo.com/a'

        curl 'https://api.demo.com/b'
        """, l10n: .zhHans)
        XCTAssertEqual(result.requests.count, 2)
    }

    // MARK: - 名称与地址

    func testNameIsDerivedFromURL() throws {
        XCTAssertEqual(try only("curl 'https://api.demo.com/users/42?x=1'").name, "42")
        XCTAssertEqual(try only("curl 'https://api.demo.com/api/v1/orders'").name, "orders")
        XCTAssertEqual(try only("curl 'https://api.demo.com/'").name, "api.demo.com")
        XCTAssertEqual(try only("curl 'https://api.demo.com'").name, "api.demo.com")
    }

    func testMissingSchemeFallsBackToHTTPWithWarning() throws {
        let result = try CurlCodec.decode("curl localhost:8080/ping", l10n: .zhHans)
        XCTAssertEqual(result.requests.first?.url, "http://localhost:8080/ping")
        XCTAssertTrue(result.warnings.contains { $0.contains("协议") }, "\(result.warnings)")
    }

    func testUnsupportedMethodFallsBackToPost() throws {
        let result = try CurlCodec.decode("curl -X TRACE 'https://api.demo.com/x' -d 'a=1'", l10n: .zhHans)
        XCTAssertEqual(result.requests.first?.method, .post)
        XCTAssertTrue(result.warnings.contains { $0.contains("TRACE") }, "\(result.warnings)")
    }

    // MARK: - 提示

    func testGlobalOnlyFlagsWarnInsteadOfSilentlyDropping() throws {
        let result = try CurlCodec.decode("curl -k -L -m 5 --proxy http://p:8080 'https://api.demo.com/x'", l10n: .zhHans)
        XCTAssertEqual(result.requests.count, 1)
        XCTAssertEqual(result.requests[0].url, "https://api.demo.com/x", "全局选项的取值不该被当成地址")
        XCTAssertEqual(result.warnings.count, 4, "\(result.warnings)")
    }

    func testWarningsAreDeduplicated() throws {
        let result = try CurlCodec.decode("curl -k 'https://api.demo.com/a'\ncurl -k 'https://api.demo.com/b'", l10n: .zhHans)
        XCTAssertEqual(result.requests.count, 2)
        XCTAssertEqual(result.warnings.filter { $0.contains("-k") }.count, 1, "\(result.warnings)")
    }

    func testEmptyHeaderValueIsIgnored() throws {
        // `-H 'Accept:'` 是 curl 用来删默认头的写法，postme 不补默认头，等价于什么都不做
        let request = try only(#"curl 'https://api.demo.com/x' -H 'Accept:' -H 'X-A: 1'"#)
        XCTAssertEqual(request.headers.map(\.key), ["X-A"])
    }

    // MARK: - 失败路径

    func testRejectsEmptyInput() {
        XCTAssertThrowsError(try CurlCodec.decode("   \n  ", l10n: .zhHans))
        XCTAssertFalse(CurlCodec.looksLikeCommand("   "))
    }

    func testRejectsTextWithoutCommand() {
        XCTAssertThrowsError(try CurlCodec.decode("hello world", l10n: .zhHans))
        XCTAssertFalse(CurlCodec.looksLikeCommand("wget https://api.demo.com/x"))
        XCTAssertTrue(CurlCodec.looksLikeCommand("curl 'https://api.demo.com/x'"))
    }

    func testRejectsCommandWithoutURL() {
        XCTAssertThrowsError(try CurlCodec.decode("curl -X POST -H 'X-A: 1'", l10n: .zhHans))
    }

    func testRejectsUnterminatedQuote() {
        XCTAssertThrowsError(try CurlCodec.decode("curl 'https://api.demo.com/x", l10n: .zhHans))
    }

    func testRejectsMissingFlagValue() {
        XCTAssertThrowsError(try CurlCodec.decode("curl 'https://api.demo.com/x' -H", l10n: .zhHans))
    }
}
