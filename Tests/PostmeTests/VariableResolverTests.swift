import XCTest
@testable import Postme

/// 变量替换与 JSON 工具的回归测试。
/// 这些断言原为 `/tmp` 下的临时验证程序（109 项），v2 迁入仓库作为常驻护栏。
final class VariableResolverTests: XCTestCase {

    private let env: [String: String] = [
        "baseUrl": "https://api.example.com",
        "token": "abc123",
        "empty": ""
    ]

    func testBasicSubstitution() {
        let r = VariableResolver.resolve("{{baseUrl}}/users/{{token}}", variables: env)
        XCTAssertEqual(r.text, "https://api.example.com/users/abc123")
        XCTAssertTrue(r.unresolved.isEmpty)
    }

    func testUndefinedVariableIsPreservedVerbatim() {
        let r = VariableResolver.resolve("{{baseUrl}}/x?t={{missing}}&y=1", variables: env)
        XCTAssertEqual(r.text, "https://api.example.com/x?t={{missing}}&y=1")
        XCTAssertEqual(r.unresolved, ["missing"])
    }

    func testVariableNameToleratesSurroundingWhitespace() {
        XCTAssertEqual(VariableResolver.resolve("{{ baseUrl }}", variables: env).text,
                       "https://api.example.com")
    }

    func testEmptyValueSubstitutesToEmptyString() {
        XCTAssertEqual(VariableResolver.resolve("{{empty}}|{{token}}", variables: env).text, "|abc123")
    }

    func testTextWithoutVariablesIsUnchanged() {
        XCTAssertEqual(VariableResolver.resolve("没有变量的文本", variables: env).text, "没有变量的文本")
    }

    func testUnclosedBracesPreserved() {
        XCTAssertEqual(VariableResolver.resolve("{{未闭合", variables: env).text, "{{未闭合")
    }

    func testBuiltinDynamicVariables() {
        let ts = VariableResolver.resolve("{{$timestamp}}", variables: [:])
        XCTAssertNotNil(Int(ts.text))
        XCTAssertTrue(ts.unresolved.isEmpty)

        let uuid = VariableResolver.resolve("{{$uuid}}", variables: [:])
        XCTAssertNotNil(UUID(uuidString: uuid.text))

        let rand = VariableResolver.resolve("{{$randomInt}}", variables: [:])
        XCTAssertNotNil(Int(rand.text))

        let iso = VariableResolver.resolve("{{$isoTimestamp}}", variables: [:])
        XCTAssertNotNil(ISO8601DateFormatter().date(from: iso.text))
    }

    func testUserVariableTakesPrecedenceOverBuiltin() {
        let r = VariableResolver.resolve("{{$uuid}}", variables: ["$uuid": "fixed"])
        XCTAssertEqual(r.text, "fixed")
    }

    func testWholeRequestResolution() {
        var req = APIRequest()
        req.url = "{{baseUrl}}/v1/items"
        req.bodyKind = .json
        req.bodyText = #"{"auth":"{{token}}"}"#
        req.queryParams = [KeyValueItem(key: "page", value: "{{missing}}")]
        req.headers = [KeyValueItem(key: "Authorization", value: "Bearer {{token}}")]

        let resolved = VariableResolver.resolve(req, variables: env)
        XCTAssertEqual(resolved.request.url, "https://api.example.com/v1/items")
        XCTAssertEqual(resolved.request.bodyText, #"{"auth":"abc123"}"#)
        XCTAssertEqual(resolved.request.headers.first?.value, "Bearer abc123")
        XCTAssertEqual(resolved.request.queryParams.first?.value, "{{missing}}")
        XCTAssertEqual(resolved.unresolved, ["missing"])
    }

    func testFormFieldsAndRawContentTypeAreResolved() {
        var req = APIRequest()
        req.url = "{{baseUrl}}/f"
        req.rawContentType = "application/{{token}}"
        req.formFields = [KeyValueItem(key: "{{token}}", value: "{{token}}")]
        let resolved = VariableResolver.resolve(req, variables: env)
        XCTAssertEqual(resolved.request.rawContentType, "application/abc123")
        XCTAssertEqual(resolved.request.formFields.first?.key, "abc123")
        XCTAssertEqual(resolved.request.formFields.first?.value, "abc123")
    }
}

final class JSONToolsTests: XCTestCase {

    func testPrettyValidJSON() {
        XCTAssertTrue(JSONTools.pretty(#"{"a":1}"#)?.contains("\n") == true)
    }

    func testMinifyJSON() {
        XCTAssertEqual(JSONTools.minify("{\n  \"a\" : 1\n}"), #"{"a":1}"#)
    }

    func testInvalidJSONRejected() {
        XCTAssertFalse(JSONTools.isValid("{不是 json}"))
        XCTAssertNil(JSONTools.pretty("{不是 json}"))
        XCTAssertNil(JSONTools.minify("{不是 json}"))
    }

    func testEmptyInputRejected() {
        XCTAssertFalse(JSONTools.isValid("   "))
    }
}

final class CollectionTreeTests: XCTestCase {

    /// 构造 A > B > 叶子的三层树。
    private func makeTree() -> (tree: [CollectionNode], folderA: CollectionNode, folderB: CollectionNode, leaf: CollectionNode) {
        var tree: [CollectionNode] = []
        let folderA = CollectionNode.folder(.init(name: "A"))
        tree.insert(folderA, intoFolder: nil)
        let folderB = CollectionNode.folder(.init(name: "B"))
        tree.insert(folderB, intoFolder: folderA.id)
        let leaf = CollectionNode.request(.init(name: "叶子", request: APIRequest(name: "叶子", method: .get, url: "u1")))
        tree.insert(leaf, intoFolder: folderB.id)
        return (tree, folderA, folderB, leaf)
    }

    func testNestedInsertAndFind() {
        let (tree, _, _, leaf) = makeTree()
        XCTAssertNotNil(tree.findNode(id: leaf.id))
    }

    func testFolderPathsAreHierarchical() {
        let (tree, _, _, _) = makeTree()
        XCTAssertEqual(tree.folderPaths().map { $0.path }, ["A", "A / B"])
    }

    func testNestedRename() {
        var (tree, _, _, leaf) = makeTree()
        XCTAssertTrue(tree.renameNode(id: leaf.id, to: "叶子2"))
        XCTAssertEqual(tree.findNode(id: leaf.id)?.name, "叶子2")
    }

    func testReplaceSavedRequestKeepsPositionAndIdentity() {
        var (tree, _, folderB, leaf) = makeTree()
        var updated = APIRequest(name: "叶子2", method: .put, url: "u2")
        updated.id = (tree.findNode(id: leaf.id)?.savedRequest?.request.id)!
        XCTAssertTrue(tree.replaceSavedRequest(id: leaf.id, with: updated))
        XCTAssertEqual(tree.findNode(id: leaf.id)?.savedRequest?.request.method, .put)
        XCTAssertEqual(tree.findNode(id: folderB.id)?.children?.count, 1)
    }

    func testSearchMatchesNameUrlAndMethod() {
        let (tree, _, _, _) = makeTree()
        XCTAssertEqual(tree.requestsMatching("叶子").count, 1)
        XCTAssertEqual(tree.requestsMatching("u1").count, 1)
        XCTAssertEqual(tree.requestsMatching("get").count, 1)
        XCTAssertEqual(tree.requestsMatching("叶子".uppercased()).count, 1)
        XCTAssertTrue(tree.requestsMatching("不存在").isEmpty)
        XCTAssertTrue(tree.requestsMatching("   ").isEmpty)
    }

    func testRecursiveRemoval() {
        var (tree, _, folderB, leaf) = makeTree()
        XCTAssertTrue(tree.removeNode(id: folderB.id))
        XCTAssertNil(tree.findNode(id: leaf.id))
        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree.first?.name, "A")
    }

    func testInsertIntoMissingFolderFails() {
        var tree: [CollectionNode] = []
        XCTAssertFalse(tree.insert(.folder(.init(name: "x")), intoFolder: UUID()))
    }

    func testRemoveMissingNodeReturnsFalse() {
        var (tree, _, _, _) = makeTree()
        XCTAssertFalse(tree.removeNode(id: UUID()))
    }
}
