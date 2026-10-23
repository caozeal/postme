import XCTest
@testable import Postme

/// 请求 → curl 导出（`CurlExport`）。
///
/// 判据不是「字符串长得像 curl」，而是两条：
/// 1. 导出的命令经 `CurlCodec` 解析回来，走 `RequestExecutor.buildURLRequest` 发出的东西
///    与原始请求**逐字节一致**（方法 / 地址 / 正文 / 有效 Content-Type / 其余声明的头）；
/// 2. 命令经**真实 bash** 切词后，参数与导出器想表达的一字不差——
///    引号写错时 curl 收到的就是另一回事，而「粘贴执行」正是用户唯一会做的事。
final class CurlExportTests: XCTestCase {

    // MARK: - 工具

    private func wire(_ request: APIRequest) throws -> URLRequest {
        try RequestExecutor.buildURLRequest(request, options: RequestExecutorOptions())
    }

    /// 「服务端看到什么」的快照。
    ///
    /// Content-Type 取**生效值**（可能是 App 自己补的），其余头取模型里启用且键非空的行——
    /// 导出会把它补成显式头，所以不能直接比模型字段。
    private func wireSnapshot(_ request: APIRequest) throws -> String {
        let built = try wire(request)
        let declared = request.headers
            .filter { $0.isEnabled && !$0.key.isEmpty }
            .filter { $0.key.lowercased() != "content-type" }
            .map { "\($0.key.lowercased()): \($0.value)" }
            .sorted()
        let body = built.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? "<nil>"
        return """
        \(built.httpMethod ?? "?") \(built.url?.absoluteString ?? "?")
        content-type: \(built.value(forHTTPHeaderField: "Content-Type") ?? "<nil>")
        headers: \(declared.joined(separator: " | "))
        body: \(body)
        """
    }

    private func assertSameWire(
        _ original: APIRequest,
        _ roundTripped: APIRequest,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(
            try wireSnapshot(original),
            try wireSnapshot(roundTripped),
            "导出再导入后发出的东西变了 \(message)",
            file: file, line: line
        )
    }

    /// 导出 → 用导入器解析回来。
    private func roundTrip(
        _ request: APIRequest,
        options: CurlExport.Options = CurlExport.Options(),
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> APIRequest {
        let command = CurlExport.command(for: request, options: options)
        let result = try CurlCodec.decode(command, l10n: .zhHans)
        XCTAssertEqual(result.requests.count, 1, "导出的命令应恰好含一个请求:\n\(command)", file: file, line: line)
        return result.requests[0]
    }

    /// 用真实 bash 跑导出的命令，但把 `curl` 换成一个只会打印 argv 的替身——
    /// 于是断言落在「bash 切词后 curl 真正收到的参数」上，而不是我们以为的样子。
    private func bashArguments(of command: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("postme-curlshim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let shim = dir.appendingPathComponent("curl")
        try "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\0' \"$a\"; done\n".write(to: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = dir.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "bash 跑不动导出的命令", file: file, line: line)

        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    // MARK: - 往返：导出的命令必须还原成等价请求

    func testJSONRequestRoundTrips() throws {
        var request = APIRequest(name: "创建订单", method: .post, url: "https://api.demo.com/orders")
        request.headers = [
            KeyValueItem(key: "Accept", value: "application/json"),
            KeyValueItem(key: "X-Trace", value: "a b"),
            KeyValueItem(isEnabled: false, key: "X-Disabled", value: "nope"),
        ]
        request.queryParams = [KeyValueItem(key: "debug", value: "true")]
        request.bodyKind = .json
        request.bodyText = "{\n  \"name\": \"张三\",\n  \"note\": \"it's ok\",\n  \"path\": \"C:\\\\tmp\"\n}"

        let back = try roundTrip(request)
        XCTAssertEqual(back.bodyKind, .json)
        XCTAssertEqual(back.bodyText, request.bodyText)
        XCTAssertFalse(back.headers.contains { $0.key == "X-Disabled" }, "停用的头不该出现在命令里")
        try assertSameWire(request, back)
    }

    /// 正文以 `@` 开头：`-d` 会把 `@file` 当读文件，必须用 `--data-raw`。
    func testBodyStartingWithAtSignStaysLiteral() throws {
        var request = APIRequest(method: .post, url: "https://api.demo.com/echo")
        request.bodyKind = .rawText
        request.rawContentType = "text/plain"
        request.bodyText = "@not-a-file"

        XCTAssertTrue(CurlExport.command(for: request).contains("--data-raw"))
        let back = try roundTrip(request)
        XCTAssertEqual(back.bodyText, "@not-a-file")
        try assertSameWire(request, back)
    }

    func testFormRequestRoundTrips() throws {
        var request = APIRequest(method: .post, url: "https://api.demo.com/login")
        request.bodyKind = .formURLEncoded
        request.formFields = [
            KeyValueItem(key: "user", value: "a&b=c"),
            KeyValueItem(key: "phone", value: "+8613800138000"),
            KeyValueItem(key: "note", value: "空 格"),
            KeyValueItem(isEnabled: false, key: "off", value: "x"),
        ]

        let back = try roundTrip(request)
        XCTAssertEqual(back.bodyKind, .formURLEncoded, "表单正文不能被降级成原文")
        XCTAssertEqual(back.formFields.map(\.key), ["user", "phone", "note"])
        XCTAssertEqual(back.formFields.map(\.value), ["a&b=c", "+8613800138000", "空 格"])
        try assertSameWire(request, back)
    }

    /// multipart 的文本字段取值可能是 `@x` / `<x` / `a;b`——`-F` 会把它们当语法，必须用 `--form-string`。
    func testMultipartFieldsStayLiteral() throws {
        var request = APIRequest(method: .post, url: "https://api.demo.com/upload")
        request.bodyKind = .multipart
        request.formFields = [
            KeyValueItem(key: "callback", value: "@home"),
            KeyValueItem(key: "note", value: "a;b=x"),
        ]

        let command = CurlExport.command(for: request)
        XCTAssertTrue(command.contains("--form-string"), "multipart 文本字段不能用 -F（取值会被当语法）:\n\(command)")
        XCTAssertFalse(command.contains("Content-Type"), "multipart 的 boundary 必须由 curl 生成，不能写死:\n\(command)")

        let back = try roundTrip(request)
        XCTAssertEqual(back.bodyKind, .multipart)
        XCTAssertEqual(back.formFields.map(\.key), ["callback", "note"])
        XCTAssertEqual(back.formFields.map(\.value), ["@home", "a;b=x"])
        XCTAssertTrue(back.formFields.allSatisfy(\.isEnabled), "字面量字段不能被当成文件占位行")
    }

    func testQueryParamsAndExistingQueryRoundTrip() throws {
        var request = APIRequest(method: .get, url: "https://api.demo.com/search?page=1&size=20")
        request.queryParams = [
            KeyValueItem(key: "q", value: "a b&c"),
            KeyValueItem(key: "phone", value: "+8613800138000"),
            KeyValueItem(key: "kw", value: "中文"),
            KeyValueItem(isEnabled: false, key: "skip", value: "x"),
        ]

        let back = try roundTrip(request)
        XCTAssertEqual(
            RequestExecutor.previewURL(back),
            RequestExecutor.previewURL(request),
            "合并后的地址变了"
        )
        XCTAssertFalse(back.queryParams.contains { $0.key == "skip" })
        try assertSameWire(request, back)
    }

    /// 把多行命令压成一行：续行会把「相邻的两个参数」拆到两行，断言前先拉平。
    private func flattened(_ command: String) -> String {
        command.replacingOccurrences(of: " \\\n  ", with: " ")
    }

    func testMethodsAreExpressedFaithfully() throws {
        var head = APIRequest(method: .head, url: "https://api.demo.com/ping")
        XCTAssertTrue(CurlExport.command(for: head).contains("-I"))
        XCTAssertEqual(try roundTrip(head).method, .head)

        var delete = APIRequest(method: .delete, url: "https://api.demo.com/orders/1")
        delete.bodyKind = .json
        delete.bodyText = "{}"
        XCTAssertEqual(try roundTrip(delete).method, .delete)

        // GET 带正文：curl 默认会把它变成 POST，必须显式 -X GET。
        var getWithBody = APIRequest(method: .get, url: "https://api.demo.com/query")
        getWithBody.bodyKind = .rawText
        getWithBody.bodyText = "raw"
        XCTAssertTrue(flattened(CurlExport.command(for: getWithBody)).contains("-X GET"))
        let back = try roundTrip(getWithBody)
        XCTAssertEqual(back.method, .get)
        try assertSameWire(getWithBody, back)

        // GET 无正文不该出现 -X（curl 的默认就是 GET）。
        var plainGet = APIRequest(method: .get, url: "https://api.demo.com/list")
        plainGet.bodyKind = .none
        XCTAssertFalse(flattened(CurlExport.command(for: plainGet)).contains("-X"))

        // HEAD 无正文用 -I，不能出现 -X HEAD（curl 会挂着等一个 HEAD 不带的正文）。
        XCTAssertFalse(flattened(CurlExport.command(for: head)).contains("-X"))
    }

    /// 空正文的 JSON POST 是真实存在的请求：少了 Content-Type 就无法复现。
    func testEmptyJSONBodyKeepsContentType() throws {
        var request = APIRequest(method: .post, url: "https://api.demo.com/touch")
        request.bodyKind = .json
        request.bodyText = ""

        let back = try roundTrip(request)
        XCTAssertEqual(back.bodyKind, .json)
        let built = try wire(back)
        XCTAssertEqual(built.value(forHTTPHeaderField: "Content-Type"), "application/json")
        try assertSameWire(request, back)
    }

    /// 用户自己写了 Content-Type 时，导出不能改写它（也不该再补一个）。
    func testUserContentTypeIsPreserved() throws {
        var request = APIRequest(method: .post, url: "https://api.demo.com/custom")
        request.headers = [KeyValueItem(key: "Content-Type", value: "application/vnd.demo+json")]
        request.bodyKind = .rawText
        request.rawContentType = "text/plain"
        request.bodyText = "{\"a\":1}"

        let command = CurlExport.command(for: request)
        XCTAssertEqual(
            command.components(separatedBy: "Content-Type").count - 1,
            1,
            "只应出现一次 Content-Type:\n\(command)"
        )
        try assertSameWire(request, try roundTrip(request))
    }

    func testExecutionOptionsBecomeCurlFlags() throws {
        var request = APIRequest(method: .get, url: "https://api.demo.com/secure")
        request.bodyKind = .none

        let plain = CurlExport.command(for: request)
        XCTAssertFalse(plain.contains(" -L"))
        XCTAssertFalse(plain.contains(" -k"))

        let appLike = CurlExport.command(
            for: request,
            options: CurlExport.Options(RequestExecutorOptions(followRedirects: true, allowInsecureTLS: true))
        )
        XCTAssertTrue(appLike.contains("-L"))
        XCTAssertTrue(appLike.contains("-k"))
        try assertSameWire(request, try roundTrip(request, options: CurlExport.Options(followRedirects: true, allowInsecureTLS: true)))
    }

    // MARK: - 引号：命令必须能被真实 bash 正确切词

    func testBashReceivesExactArguments() throws {
        var request = APIRequest(method: .post, url: "https://api.demo.com/echo")
        request.headers = [
            KeyValueItem(key: "X-Quote", value: "it's \"quoted\""),
            KeyValueItem(key: "X-Shell", value: "$HOME `whoami` !"),
        ]
        request.bodyKind = .json
        request.bodyText = "{\n  \"a\": \"it's $HOME `x` \\\\path\",\n  \"b\": \"tab\\there\"\n}"

        let command = CurlExport.command(for: request)
        let arguments = try bashArguments(of: command)

        // shim 收到的是 `"$@"`（不含 argv[0]），所以第一个就是地址。
        XCTAssertEqual(arguments.first, RequestExecutor.previewURL(request), "地址被 shell 改写了")

        // 正文：bash 交出的字节必须与模型里的一字不差（换行、单引号、$、反引号都不能被吃掉）。
        guard let bodyIndex = arguments.firstIndex(of: "--data-raw") else {
            return XCTFail("命令里没有 --data-raw:\n\(command)")
        }
        XCTAssertEqual(arguments[bodyIndex + 1], request.bodyText)

        XCTAssertTrue(arguments.contains("X-Quote: it's \"quoted\""))
        XCTAssertTrue(arguments.contains("X-Shell: $HOME `whoami` !"))
        XCTAssertTrue(arguments.contains("Content-Type: application/json"))
    }

    func testBashParsesTabAndQuoteInsideValue() throws {
        var request = APIRequest(method: .put, url: "https://api.demo.com/raw")
        request.bodyKind = .rawText
        request.rawContentType = "text/plain"
        request.bodyText = "line1\nline2\ttail' end"

        let arguments = try bashArguments(of: CurlExport.command(for: request))
        guard let index = arguments.firstIndex(of: "--data-raw") else {
            return XCTFail("命令里没有 --data-raw")
        }
        XCTAssertEqual(arguments[index + 1], "line1\nline2\ttail' end")
    }

    // MARK: - App 层：变量替换 / 剪贴板

    @MainActor
    private func makeApp() -> (AppState, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("postme-curlexport-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (AppState(
            persistence: PersistenceService(fileName: "workspace.json", directory: dir),
            languageOverride: .zhHans
        ), dir)
    }

    @MainActor
    func testAppCommandUsesActiveEnvironment() throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        let environmentID = app.addEnvironment(name: "dev")
        app.updateEnvironment(APIEnvironment(
            id: environmentID,
            name: "dev",
            variables: [
                KeyValueItem(key: "baseUrl", value: "https://dev.demo.com"),
                KeyValueItem(key: "token", value: "T-123"),
            ]
        ))
        app.selectEnvironment(id: environmentID)

        app.draft.url = "{{baseUrl}}/orders/{{missing}}"
        app.draft.headers = [KeyValueItem(key: "Authorization", value: "Bearer {{token}}")]
        app.draft.method = .get
        app.draft.bodyKind = .none

        let command = app.curlCommand(for: app.draft)
        // 未定义变量按原文发出（与发送一致）；`{{` 在地址里会被 percent-encode 成 `%7B%7B`，
        // 这也是 App 实发时的样子——导出复述的是"真正会发出去的那串"。
        XCTAssertTrue(command.contains("https://dev.demo.com/orders/%7B%7Bmissing%7D%7D"), "变量没按当前环境替换:\n\(command)")
        XCTAssertTrue(command.contains("Authorization: Bearer T-123"))
        XCTAssertFalse(command.contains("{{baseUrl}}"))
    }

    @MainActor
    func testCopyAsCurlWritesPasteboard() throws {
        let (app, dir) = makeApp()
        defer { try? FileManager.default.removeItem(at: dir) }

        app.draft.url = "https://api.demo.com/ping"
        app.draft.method = .get
        app.draft.bodyKind = .none
        app.draft.headers = []

        FileActions.copyAsCurl(from: app, request: app.draft)
        let pasted = NSPasteboard.general.string(forType: .string)
        XCTAssertEqual(pasted, app.curlCommand(for: app.draft))
        XCTAssertEqual(pasted?.hasPrefix("curl "), true)
    }
}
