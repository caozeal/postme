import XCTest
@testable import Postme

/// Postman Collection v2.1 导入 / 导出与往返保真。
final class PostmanCodecTests: XCTestCase {

    // MARK: - 导入

    private let importJSON = """
    {
      "info": { "name": "示例集合", "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json" },
      "variable": [
        { "key": "baseUrl", "value": "https://api.demo.com" },
        { "key": "token", "value": "t0ken" }
      ],
      "item": [
        {
          "name": "用户",
          "item": [
            {
              "name": "列表",
              "request": {
                "method": "GET",
                "header": [ { "key": "Accept", "value": "application/json" }, { "key": "X-Off", "value": "1", "disabled": true } ],
                "url": {
                  "raw": "{{baseUrl}}/users?page=1&size=20",
                  "query": [ { "key": "page", "value": "1" }, { "key": "size", "value": "20" } ]
                }
              }
            },
            {
              "name": "创建",
              "request": {
                "method": "POST",
                "header": [ { "key": "Content-Type", "value": "application/json" } ],
                "url": "{{baseUrl}}/users",
                "body": { "mode": "raw", "raw": "{\\"name\\":\\"x\\"}", "options": { "raw": { "language": "json" } } }
              }
            }
          ]
        },
        {
          "name": "登录",
          "request": {
            "method": "POST",
            "url": "https://api.demo.com/login",
            "body": {
              "mode": "urlencoded",
              "urlencoded": [ { "key": "user", "value": "a" }, { "key": "pwd", "value": "b" } ]
            }
          }
        },
        {
          "name": "上传",
          "request": {
            "method": "POST",
            "url": "https://api.demo.com/upload",
            "body": {
              "mode": "formdata",
              "formdata": [ { "key": "note", "value": "hi", "type": "text" }, { "key": "file", "value": "", "type": "file" } ]
            }
          }
        }
      ]
    }
    """

    func testImportBasicStructure() throws {
        let result = try PostmanCodec.decode(Data(importJSON.utf8), l10n: .zhHans)
        XCTAssertEqual(result.collectionName, "示例集合")
        XCTAssertEqual(result.requestCount, 4)
        XCTAssertEqual(result.nodes.count, 3)
        XCTAssertNotNil(result.environment)
        XCTAssertEqual(result.environment?.variables.count, 2)
    }

    func testImportFolderAndRequestFields() throws {
        let result = try PostmanCodec.decode(Data(importJSON.utf8), l10n: .zhHans)

        let folder = result.nodes.first
        XCTAssertEqual(folder?.isFolder, true)
        XCTAssertEqual(folder?.name, "用户")
        XCTAssertEqual(folder?.children?.count, 2)

        let list = folder?.children?.first?.savedRequest
        XCTAssertEqual(list?.request.method, .get)
        XCTAssertEqual(list?.request.url, "{{baseUrl}}/users")
        XCTAssertEqual(list?.request.queryParams.count, 2)
        XCTAssertEqual(list?.request.headers.last?.isEnabled, false)
    }

    func testImportBodyKinds() throws {
        let result = try PostmanCodec.decode(Data(importJSON.utf8), l10n: .zhHans)

        let create = result.nodes.first?.children?.last?.savedRequest
        XCTAssertEqual(create?.request.bodyKind, .json)
        XCTAssertEqual(create?.request.bodyText, #"{"name":"x"}"#)

        let login = result.nodes[1].savedRequest
        XCTAssertEqual(login?.request.bodyKind, .formURLEncoded)
        XCTAssertEqual(login?.request.formFields.count, 2)

        let upload = result.nodes[2].savedRequest
        XCTAssertEqual(upload?.request.bodyKind, .multipart)
        XCTAssertEqual(upload?.request.formFields.last?.isEnabled, false)
    }

    func testImportRejectsNonCollectionAndEmpty() {
        XCTAssertThrowsError(try PostmanCodec.decode(Data(#"{"foo":1}"#.utf8), l10n: .zhHans))
        XCTAssertThrowsError(try PostmanCodec.decode(Data("不是 json".utf8), l10n: .zhHans))
        XCTAssertThrowsError(try PostmanCodec.decode(Data(#"{"info":{"name":"空"},"item":[]}"#.utf8), l10n: .zhHans))
    }

    func testGraphQLBodyIsNotSilentlyDropped() throws {
        let payload: [String: Any] = [
            "info": ["name": "gql集合"],
            "item": [[
                "name": "GQL",
                "request": [
                    "method": "POST",
                    "url": "https://x/gql",
                    "body": [
                        "mode": "graphql",
                        "graphql": ["query": "query { a }", "variables": "{\"id\":1}"]
                    ]
                ]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let result = try PostmanCodec.decode(data, l10n: .zhHans)
        let req = result.nodes.first?.savedRequest?.request
        XCTAssertEqual(req?.bodyKind, .json)
        XCTAssertTrue(req?.bodyText.contains("query { a }") == true)
        XCTAssertTrue(req?.bodyText.contains("1") == true)
    }

    // MARK: - 导出与往返

    func testExportIsValidCollectionWithSchema() throws {
        var outReq = APIRequest()
        outReq.name = "导出请求"
        outReq.method = .post
        outReq.url = "https://api.demo.com/things"
        outReq.queryParams = [KeyValueItem(key: "q", value: "a b"), KeyValueItem(isEnabled: false, key: "off", value: "1")]
        outReq.headers = [KeyValueItem(key: "X-Token", value: "tt")]
        outReq.bodyKind = .json
        outReq.bodyText = #"{"k":1}"#

        let nodes: [CollectionNode] = [.folder(.init(name: "分组", children: [
            .request(.init(name: "导出请求", request: outReq))
        ]))]

        let data = try PostmanCodec.encode(
            project: Project(name: "导出项目", children: nodes),
            environment: APIEnvironment(name: "env", variables: [KeyValueItem(key: "baseUrl", value: "https://api.demo.com")])
        )
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(JSONTools.isValid(text))
        XCTAssertTrue(text.contains("schema.getpostman.com"))
        XCTAssertTrue(text.contains("a%20b"))
    }

    func testExportImportRoundTrip() throws {
        var outReq = APIRequest()
        outReq.name = "导出请求"
        outReq.method = .post
        outReq.url = "https://api.demo.com/things"
        outReq.queryParams = [KeyValueItem(key: "q", value: "a b"), KeyValueItem(isEnabled: false, key: "off", value: "1")]
        outReq.headers = [KeyValueItem(key: "X-Token", value: "tt")]
        outReq.bodyKind = .json
        outReq.bodyText = #"{"k":1}"#

        let nodes: [CollectionNode] = [.folder(.init(name: "分组", children: [
            .request(.init(name: "导出请求", request: outReq))
        ]))]

        let data = try PostmanCodec.encode(
            project: Project(name: "导出项目", children: nodes),
            environment: APIEnvironment(name: "env", variables: [KeyValueItem(key: "baseUrl", value: "https://api.demo.com")])
        )
        let back = try PostmanCodec.decode(data, l10n: .zhHans)

        XCTAssertEqual(back.collectionName, "导出项目")
        XCTAssertEqual(back.requestCount, 1)
        // 项目内的文件夹层级原样往返：项目 → 文件夹「分组」→ 请求
        let backReq = back.nodes.first?.children?.first?.savedRequest?.request
        XCTAssertEqual(backReq?.method, .post)
        XCTAssertEqual(backReq?.url, "https://api.demo.com/things")
        XCTAssertEqual(backReq?.queryParams.count, 2)
        XCTAssertEqual(backReq?.queryParams.last?.isEnabled, false)
        XCTAssertEqual(backReq?.bodyKind, .json)
        XCTAssertEqual(backReq?.bodyText, #"{"k":1}"#)
        XCTAssertEqual(back.environment?.variables.first?.key, "baseUrl")
    }

    func testRawTextContentTypeSurvivesRoundTrip() throws {
        let rawReq = APIRequest(name: "xml", method: .post, url: "https://x/y",
                                bodyKind: .rawText, bodyText: "<a/>", rawContentType: "application/xml")
        let data = try PostmanCodec.encode(
            project: Project(name: "xml 项目", children: [.request(.init(name: "xml", request: rawReq))]),
            environment: nil
        )
        let back = try PostmanCodec.decode(data, l10n: .zhHans)
        let backReq = back.nodes.first?.savedRequest?.request
        XCTAssertEqual(backReq?.rawContentType, "application/xml")
        XCTAssertEqual(backReq?.bodyText, "<a/>")
    }

    func testExportUsesProjectNameAsCollectionName() throws {
        // 项目即集合：集合名 = 项目名，item = 项目子节点。
        // 导入侧把集合建成同名项目，因此往返结构稳定。
        let single: [CollectionNode] = [.folder(.init(name: "子目录", children: [
            .request(.init(name: "r", request: APIRequest(name: "r", url: "https://x")))
        ]))]
        let data = try PostmanCodec.encode(
            project: Project(name: "我的项目", children: single),
            environment: nil
        )
        let root = (try JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let info = root?["info"] as? [String: Any]
        XCTAssertEqual(info?["name"] as? String, "我的项目")

        let back = try PostmanCodec.decode(data, l10n: .zhHans)
        // 包一层同名文件夹是 AppState.importPostmanCollection 的职责（现在是建同名项目），往返结构因此稳定。
        let project = Project(name: back.collectionName, children: back.nodes)
        XCTAssertEqual(project.name, "我的项目")
        XCTAssertEqual(project.children.first?.name, "子目录")
        XCTAssertTrue(project.children.first?.isFolder ?? false)
    }

    func testExportEncodesPlusInQuery() throws {
        let plusReq = APIRequest(name: "p", url: "https://x/y",
                                 queryParams: [KeyValueItem(key: "k", value: "a+b")])
        let data = try PostmanCodec.encode(
            project: Project(name: "p", children: [.request(.init(name: "p", request: plusReq))]),
            environment: nil
        )
        XCTAssertTrue((String(data: data, encoding: .utf8) ?? "").contains("a%2Bb"))
    }

    func testExportDoesNotDuplicateQueryAlreadyInRawURL() throws {
        let req = APIRequest(name: "p", url: "https://x/y?inline=1",
                             queryParams: [KeyValueItem(key: "k", value: "v")])
        let data = try PostmanCodec.encode(
            project: Project(name: "p", children: [.request(.init(name: "p", request: req))]),
            environment: nil
        )
        let root = (try JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let items = root?["item"] as? [[String: Any]]
        let url = items?.first?["request"] as? [String: Any]
        let raw = (url?["url"] as? [String: Any])?["raw"] as? String
        XCTAssertEqual(raw, "https://x/y?inline=1")
    }
}
