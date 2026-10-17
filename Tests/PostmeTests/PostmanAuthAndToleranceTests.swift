import XCTest
@testable import Postme

/// Postman v2.1 的认证导入与容错导入。
///
/// 背景（实测缺陷）：
/// 1. `auth` 被完全忽略 → 带 Bearer 的集合导入后所有请求 401（静默丢失）。
/// 2. `item.request` 为字符串（schema 明确允许 `oneOf: object|string`）→ 整份文件被拒。
/// 3. `header` 为字符串（schema `oneOf: header-list|string`）→ 同样整份失败。
final class PostmanAuthAndToleranceTests: XCTestCase {

    private func decode(_ json: String) throws -> PostmanCodec.ImportResult {
        try PostmanCodec.decode(Data(json.utf8), l10n: .zhHans)
    }

    private func collection(_ body: String) -> String {
        """
        {"info":{"name":"A","schema":"https://schema.getpostman.com/json/collection/v2.1.0/collection.json"},
         "item":[\(body)]}
        """
    }

    // MARK: - D4 认证

    func testBearerAuthBecomesAuthorizationHeader() throws {
        let json = collection("""
        {"name":"r","request":{"method":"GET","url":{"raw":"https://x.dev/a"},
         "auth":{"type":"bearer","bearer":[{"key":"token","value":"SECRET"}]}}}
        """)
        let req = try decode(json).nodes.first?.savedRequest?.request
        let auth = req?.headers.first { $0.key.lowercased() == "authorization" }
        XCTAssertEqual(auth?.value, "Bearer SECRET")
        XCTAssertEqual(auth?.isEnabled, true)
    }

    func testBasicAuthBecomesBase64Header() throws {
        let json = collection("""
        {"name":"r","request":{"method":"GET","url":{"raw":"https://x.dev/a"},
         "auth":{"type":"basic","basic":[{"key":"username","value":"u"},{"key":"password","value":"p"}]}}}
        """)
        let req = try decode(json).nodes.first?.savedRequest?.request
        let auth = req?.headers.first { $0.key.lowercased() == "authorization" }
        let expected = "Basic " + Data("u:p".utf8).base64EncodedString()
        XCTAssertEqual(auth?.value, expected)
    }

    func testAPIKeyAuthInHeader() throws {
        let json = collection("""
        {"name":"r","request":{"method":"GET","url":{"raw":"https://x.dev/a"},
         "auth":{"type":"apikey","apikey":[{"key":"key","value":"X-Api-Key"},{"key":"value","value":"k123"}]}}}
        """)
        let req = try decode(json).nodes.first?.savedRequest?.request
        XCTAssertEqual(req?.headers.first { $0.key == "X-Api-Key" }?.value, "k123")
    }

    func testAPIKeyAuthInQuery() throws {
        let json = collection("""
        {"name":"r","request":{"method":"GET","url":{"raw":"https://x.dev/a"},
         "auth":{"type":"apikey","apikey":[{"key":"key","value":"api_key"},{"key":"value","value":"k123"},{"key":"in","value":"query"}]}}}
        """)
        let req = try decode(json).nodes.first?.savedRequest?.request
        XCTAssertEqual(req?.queryParams.first { $0.key == "api_key" }?.value, "k123")
        XCTAssertNil(req?.headers.first { $0.key == "api_key" })
    }

    func testCollectionLevelAuthAppliesToRequests() throws {
        let json = """
        {"info":{"name":"A"},
         "auth":{"type":"bearer","bearer":[{"key":"token","value":"COLL"}]},
         "item":[{"name":"r","request":{"method":"GET","url":{"raw":"https://x.dev/a"}}}]}
        """
        let req = try decode(json).nodes.first?.savedRequest?.request
        XCTAssertEqual(req?.headers.first { $0.key.lowercased() == "authorization" }?.value, "Bearer COLL")
    }

    func testRequestLevelAuthOverridesCollectionLevel() throws {
        let json = """
        {"info":{"name":"A"},
         "auth":{"type":"bearer","bearer":[{"key":"token","value":"COLL"}]},
         "item":[{"name":"r","request":{"method":"GET","url":{"raw":"https://x.dev/a"},
           "auth":{"type":"bearer","bearer":[{"key":"token","value":"REQ"}]}}}]}
        """
        let req = try decode(json).nodes.first?.savedRequest?.request
        XCTAssertEqual(req?.headers.first { $0.key.lowercased() == "authorization" }?.value, "Bearer REQ")
        XCTAssertEqual(req?.headers.filter { $0.key.lowercased() == "authorization" }.count, 1)
    }

    func testExplicitAuthorizationHeaderIsNotOverwritten() throws {
        let json = collection("""
        {"name":"r","request":{"method":"GET","url":{"raw":"https://x.dev/a"},
         "header":[{"key":"Authorization","value":"Bearer MINE"}],
         "auth":{"type":"bearer","bearer":[{"key":"token","value":"OTHER"}]}}}
        """)
        let req = try decode(json).nodes.first?.savedRequest?.request
        let values = req?.headers.filter { $0.key.lowercased() == "authorization" }.map(\.value)
        XCTAssertEqual(values, ["Bearer MINE"])
    }

    func testNoAuthTypeProducesNothing() throws {
        let json = collection("""
        {"name":"r","request":{"method":"GET","url":{"raw":"https://x.dev/a"},"auth":{"type":"noauth"}}}
        """)
        let result = try decode(json)
        XCTAssertNil(result.nodes.first?.savedRequest?.request.headers.first {
            $0.key.lowercased() == "authorization"
        })
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testUnsupportedAuthTypeIsReportedNotSilentlyDropped() throws {
        for type in ["oauth2", "awsv4", "digest", "ntlm"] {
            let json = collection("""
            {"name":"r","request":{"method":"GET","url":{"raw":"https://x.dev/a"},"auth":{"type":"\(type)"}}}
            """)
            let result = try decode(json)
            XCTAssertEqual(result.warnings.count, 1, "\(type) 应产生一条提示")
            XCTAssertTrue(result.warnings.first?.contains(type) == true)
        }
    }

    func testBearerWithEmptyTokenIsIgnored() throws {
        let json = collection("""
        {"name":"r","request":{"method":"GET","url":{"raw":"https://x.dev/a"},
         "auth":{"type":"bearer","bearer":[{"key":"token","value":""}]}}}
        """)
        let req = try decode(json).nodes.first?.savedRequest?.request
        XCTAssertNil(req?.headers.first { $0.key.lowercased() == "authorization" })
    }

    // MARK: - D5 容错导入

    func testStringRequestIsImportedAsGetURL() throws {
        // schema 允许 item.request 是字符串（等价于只有 URL 的 GET）
        let json = collection(#"{"name":"r","request":"https://api.example.com/v1/users"}"#)
        let result = try decode(json)
        let req = result.nodes.first?.savedRequest?.request
        XCTAssertEqual(req?.method, .get)
        XCTAssertEqual(req?.url, "https://api.example.com/v1/users")
        XCTAssertEqual(result.requestCount, 1)
    }

    func testStringHeaderBlockIsParsed() throws {
        let json = collection("""
        {"name":"r","request":{"method":"GET","header":"X-A: 1\\nX-B: two\\n\\nBroken line",
         "url":{"raw":"https://x.dev/a"}}}
        """)
        let req = try decode(json).nodes.first?.savedRequest?.request
        XCTAssertEqual(req?.headers.count, 2)
        XCTAssertEqual(req?.headers.first?.key, "X-A")
        XCTAssertEqual(req?.headers.first?.value, "1")
        XCTAssertEqual(req?.headers.last?.key, "X-B")
        XCTAssertEqual(req?.headers.last?.value, "two")
    }

    func testMalformedItemDoesNotRejectWholeCollection() throws {
        let json = collection("""
        {"name":"good","request":{"method":"GET","url":{"raw":"https://ok.dev"}}},
        {"name":"weird","request":{"method":12345,"url":true,"header":{"not":"a list"}}},
        {"name":"also-good","request":{"method":"POST","url":{"raw":"https://ok2.dev"}}}
        """)
        let result = try decode(json)
        // 畸形条目最多退化为默认值，但其余条目必须都在
        XCTAssertGreaterThanOrEqual(result.requestCount, 2)
        let names = result.nodes.map(\.name)
        XCTAssertTrue(names.contains("good"))
        XCTAssertTrue(names.contains("also-good"))
    }

    func testFolderWithMixedChildrenKeepsValidRequests() throws {
        let json = collection("""
        {"name":"组","item":[
          {"name":"a","request":{"method":"GET","url":{"raw":"https://a.dev"}}},
          {"name":"b"},
          {"name":"c","request":{"method":"GET","url":{"raw":"https://c.dev"}}}
        ]}
        """)
        let result = try decode(json)
        let folder = result.nodes.first
        XCTAssertEqual(folder?.isFolder, true)
        XCTAssertEqual(folder?.children?.count, 2)
        XCTAssertEqual(folder?.children?.map(\.name), ["a", "c"])
    }

    func testNonObjectElementInItemArrayDoesNotDropSiblings() throws {
        // schema 之外的畸形：item 数组里混入非对象元素。
        // 整数组解码会因一个元素失败而全盘失败，把该层所有兄弟条目一起丢掉。
        let json = collection("""
        {"name":"a","request":{"method":"GET","url":{"raw":"https://a.dev"}}},
        123,
        "just a string",
        {"name":"c","request":{"method":"GET","url":{"raw":"https://c.dev"}}}
        """)
        let result = try decode(json)
        XCTAssertEqual(result.requestCount, 2, "兄弟条目必须保留")
        XCTAssertEqual(result.nodes.map(\.name), ["a", "c"])
    }

    func testEmptyItemArrayIsFolderNotRequest() throws {
        // item 存在但为空 → 空文件夹；item 缺失 → 请求节点。二者必须区分。
        // （整份集合一个请求都没有时按既有约定报 empty，所以这里配一个真实请求。）
        let json = collection("""
        {"name":"空组","item":[]},
        {"name":"r","request":{"method":"GET","url":{"raw":"https://x.dev"}}}
        """)
        let result = try decode(json)
        XCTAssertEqual(result.nodes.first?.isFolder, true)
        XCTAssertEqual(result.nodes.first?.children?.count, 0)
        XCTAssertEqual(result.nodes.last?.savedRequest?.request.url, "https://x.dev")
    }

    func testMissingURLProducesEmptyURLNotCrash() throws {
        let json = collection(#"{"name":"r","request":{"method":"GET"}}"#)
        let result = try decode(json)
        XCTAssertEqual(result.nodes.first?.savedRequest?.request.url, "")
    }

    func testStillRejectsUnrelatedJSON() {
        XCTAssertThrowsError(try decode(#"{"foo":1}"#))
        XCTAssertThrowsError(try decode("not json at all"))
        XCTAssertThrowsError(try decode(#"{"info":{"name":"空"},"item":[]}"#))
    }

    // MARK: - 导出的认证保真

    func testExportedAuthHeaderSurvivesRoundTrip() throws {
        var req = APIRequest(name: "r", method: .get, url: "https://x.dev/a")
        req.headers = [KeyValueItem(key: "Authorization", value: "Bearer RT")]
        let data = try PostmanCodec.encode(
            project: Project(name: "认证项目", children: [.request(.init(name: "r", request: req))]),
            environment: nil
        )
        let back = try PostmanCodec.decode(data, l10n: .zhHans)
        XCTAssertEqual(
            back.nodes.first?.savedRequest?.request.headers.first {
                $0.key.lowercased() == "authorization"
            }?.value,
            "Bearer RT"
        )
    }
}
