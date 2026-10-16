import XCTest
@testable import Postme

/// URL / 请求体组装与「预览 == 实发」一致性。
final class RequestBuildingTests: XCTestCase {

    private let opts = RequestExecutorOptions()

    private func bodyString(_ request: URLRequest?) -> String {
        guard let data = request?.httpBody else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - FormEncoding

    func testPlusIsEncoded() {
        XCTAssertEqual(FormEncoding.encode("+8613800138000"), "%2B8613800138000")
        XCTAssertEqual(FormEncoding.queryString([(key: "a", value: "x+y")]), "a=x%2By")
    }

    func testReservedCharactersAreEncoded() {
        XCTAssertEqual(FormEncoding.queryString([(key: "a&b", value: "v")]), "a%26b=v")
        XCTAssertEqual(FormEncoding.encode("100%"), "100%25")
        XCTAssertEqual(FormEncoding.encode("a b"), "a%20b")
        XCTAssertEqual(FormEncoding.encode("a=b?c"), "a%3Db%3Fc")
        XCTAssertEqual(FormEncoding.encode("a#b"), "a%23b")
    }

    func testNonASCIINamesAreEncoded() {
        XCTAssertEqual(FormEncoding.encode("老曹"), "%E8%80%81%E6%9B%B9")
    }

    // MARK: - URLRequest 组装

    func testQueryPlusIsEncodedOnTheWire() throws {
        var req = APIRequest()
        req.url = "https://api.demo.com/x"
        req.queryParams = [KeyValueItem(key: "phone", value: "+8613800138000")]
        let built = try RequestExecutor.buildURLRequest(req, options: opts)
        let url = built.url?.absoluteString ?? ""
        XCTAssertTrue(url.contains("%2B"))
        XCTAssertFalse(url.contains("+86"))
    }

    func testFormBodyPlusIsEncoded() throws {
        var req = APIRequest()
        req.url = "https://api.demo.com/x"
        req.method = .post
        req.bodyKind = .formURLEncoded
        req.formFields = [KeyValueItem(key: "phone", value: "+8613800138000")]
        let built = try RequestExecutor.buildURLRequest(req, options: opts)
        XCTAssertEqual(bodyString(built), "phone=%2B8613800138000")
    }

    func testEmptyJSONBodyStillCarriesContentType() throws {
        var req = APIRequest()
        req.url = "https://api.demo.com/x"
        req.method = .post
        req.bodyKind = .json
        req.bodyText = ""
        let built = try RequestExecutor.buildURLRequest(req, options: opts)
        XCTAssertEqual(built.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testRawTextUsesConfiguredContentType() throws {
        var req = APIRequest()
        req.url = "https://api.demo.com/x"
        req.method = .post
        req.bodyKind = .rawText
        req.bodyText = "<a/>"
        req.rawContentType = "application/xml"
        let built = try RequestExecutor.buildURLRequest(req, options: opts)
        XCTAssertEqual(built.value(forHTTPHeaderField: "Content-Type"), "application/xml")
    }

    func testUserProvidedContentTypeWins() throws {
        var req = APIRequest()
        req.url = "https://api.demo.com/x"
        req.method = .post
        req.bodyKind = .json
        req.bodyText = #"{"k":1}"#
        req.headers = [KeyValueItem(key: "Content-Type", value: "application/vnd.custom+json")]
        let built = try RequestExecutor.buildURLRequest(req, options: opts)
        XCTAssertEqual(built.value(forHTTPHeaderField: "Content-Type"), "application/vnd.custom+json")
    }

    func testDisabledHeadersAreExcluded() throws {
        var req = APIRequest()
        req.url = "https://api.demo.com/x"
        req.headers = [
            KeyValueItem(isEnabled: false, key: "X-Off", value: "1"),
            KeyValueItem(key: "X-On", value: "1")
        ]
        let built = try RequestExecutor.buildURLRequest(req, options: opts)
        XCTAssertNil(built.value(forHTTPHeaderField: "X-Off"))
        XCTAssertEqual(built.value(forHTTPHeaderField: "X-On"), "1")
    }

    func testMultipartQuotesInFieldNameAreEscaped() throws {
        var req = APIRequest()
        req.url = "https://api.demo.com/x"
        req.method = .post
        req.bodyKind = .multipart
        req.formFields = [KeyValueItem(key: "a\"b", value: "v")]
        let built = try RequestExecutor.buildURLRequest(req, options: opts)
        XCTAssertTrue(bodyString(built).contains(#"name="a\"b""#))
    }

    func testMultipartBodyEndsWithClosingBoundary() throws {
        var req = APIRequest()
        req.url = "https://api.demo.com/x"
        req.method = .post
        req.bodyKind = .multipart
        req.formFields = [KeyValueItem(key: "f", value: "v")]
        let built = try RequestExecutor.buildURLRequest(req, options: opts)
        let body = bodyString(built)
        let contentType = built.value(forHTTPHeaderField: "Content-Type") ?? ""
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let boundary = contentType.replacingOccurrences(of: "multipart/form-data; boundary=", with: "")
        XCTAssertTrue(body.hasSuffix("--\(boundary)--\r\n"))
        XCTAssertTrue(body.contains("\r\n"))
    }

    func testInvalidURLIsRejected() {
        var req = APIRequest()
        req.url = "not a url"
        XCTAssertThrowsError(try RequestExecutor.buildURLRequest(req, options: opts))

        req.url = ""
        XCTAssertThrowsError(try RequestExecutor.buildURLRequest(req, options: opts))

        req.url = "ftp://example.com/x"
        XCTAssertThrowsError(try RequestExecutor.buildURLRequest(req, options: opts))

        req.url = "http://"
        XCTAssertThrowsError(try RequestExecutor.buildURLRequest(req, options: opts))
    }

    // MARK: - 预览与发送一致性

    func testPreviewMatchesSentURLVerbatim() throws {
        var req = APIRequest()
        req.url = "http://127.0.0.1:18080/x"
        req.queryParams = [
            KeyValueItem(key: "phone", value: "+8613800138000"),
            KeyValueItem(key: "cn", value: "老曹"),
            KeyValueItem(isEnabled: false, key: "off", value: "1")
        ]
        let preview = RequestExecutor.previewURL(req)
        XCTAssertTrue(preview.contains("%2B"))
        XCTAssertFalse(preview.contains("+86138"))
        XCTAssertTrue(preview.contains("%E8%80%81"))
        XCTAssertFalse(preview.contains("off="))

        let built = try RequestExecutor.buildURLRequest(req, options: opts)
        XCTAssertEqual(preview, built.url?.absoluteString)
    }

    func testPreviewKeepsExistingQueryAndDoesNotDoubleEncode() {
        var req = APIRequest()
        req.url = "https://x/y?a=1&b=%2B"
        XCTAssertEqual(RequestExecutor.previewURL(req), "https://x/y?a=1&b=%2B")

        req.queryParams = [KeyValueItem(key: "c", value: "d")]
        XCTAssertEqual(RequestExecutor.previewURL(req), "https://x/y?a=1&b=%2B&c=d")
    }

    func testPreviewWithoutParamsIsUnchanged() {
        var req = APIRequest()
        req.url = "https://x/y?a=1"
        XCTAssertEqual(RequestExecutor.previewURL(req), "https://x/y?a=1")
    }

    func testPreviewOfEmptyURLIsEmpty() {
        XCTAssertEqual(RequestExecutor.previewURL(APIRequest()), "")
    }

    func testPreviewAppliesVariableSubstitutionBeforeEncoding() {
        var req = APIRequest()
        req.url = "{{baseUrl}}/api/users"
        req.queryParams = [KeyValueItem(key: "phone", value: "+8613800138000")]

        // 不替换就预览，大括号会被编码——这正是必须"先替换再预览"的原因。
        XCTAssertTrue(RequestExecutor.previewURL(req).contains("%7B%7B"))

        let resolved = VariableResolver.resolve(req, variables: ["baseUrl": "http://127.0.0.1:18080"]).request
        let preview = RequestExecutor.previewURL(resolved)
        XCTAssertFalse(preview.contains("%7B"))
        XCTAssertTrue(preview.contains("127.0.0.1:18080"))
        XCTAssertEqual(preview, (try? RequestExecutor.buildURLRequest(resolved, options: opts))?.url?.absoluteString)
    }

    func testPreviewDoesNotCrashWhenVariablesAreUndefined() {
        var req = APIRequest()
        req.url = "{{baseUrl}}/x"
        let resolved = VariableResolver.resolve(req, variables: [:]).request
        XCTAssertFalse(RequestExecutor.previewURL(resolved).isEmpty)
    }
}
