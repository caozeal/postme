import XCTest
@testable import Postme

final class AgentContextTests: XCTestCase {
    func testSanitizerWithholdsSecretsAndFreeText() throws {
        let data = Data(#"{"token":"synthetic-token","message":"secret anywhere","ok":true,"nested":{"password":"p","count":4}}"#.utf8)
        let encoded = try JSONSerialization.data(withJSONObject: AgentContextSanitizer.body(data))
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("synthetic-token"))
        XCTAssertFalse(text.contains("secret anywhere"))
        XCTAssertTrue(text.contains("redacted"))
        XCTAssertTrue(text.contains("count"))
    }
    func testNonJSONAndOversizeAreOmitted() {
        XCTAssertEqual(AgentContextSanitizer.body(Data("secret".utf8))["omitted"] as? Bool, true)
        XCTAssertEqual(AgentContextSanitizer.body(Data(repeating: 65, count: 32769))["omitted"] as? Bool, true)
    }
    func testLongSocketPathFails() {
        XCTAssertThrowsError(try AgentContextBridge.address(String(repeating: "a", count: 110)))
    }
    @MainActor func testLaunchEnablesContextAndNoStaleRunOnRestore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = AppState(persistence: PersistenceService(directory: directory), enableAgentContextOnLaunch: true)
        defer { app.setAgentContextEnabled(false) }
        XCTAssertTrue(app.agentContextEnabled)
        let data = try await Task.detached { try AgentContextBridge.read(directory: directory) }.value
        XCTAssertEqual(try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])["state"] as? String, "not_run")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: app.agentContextData()) as? [String: Any])
        XCTAssertEqual(object["state"] as? String, "not_run")
        XCTAssertTrue(object["runID"] is NSNull)
        var tab = EditorTab(draft: APIRequest())
        tab.agentRunID = UUID()
        tab.agentRunCancelled = true
        let decoded = try JSONDecoder().decode(EditorTab.self, from: JSONEncoder().encode(tab))
        XCTAssertNil(decoded.agentRunID)
        XCTAssertFalse(decoded.agentRunCancelled)
        tab.clearResponse()
        XCTAssertNil(tab.agentRunID)
    }
    @MainActor func testSocketReadsCurrentSnapshotAndDisableRevokes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = AgentContextBridge(directory: directory)
        try bridge.start { Data("{\"state\":\"running\"}".utf8) }
        let data = try await Task.detached { try AgentContextBridge.read(directory: directory) }.value
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"state\":\"running\"}")
        bridge.stop()
        XCTAssertThrowsError(try AgentContextBridge.read(directory: directory))
        try bridge.start { Data("{\"state\":\"completed\"}".utf8) }
        let second = try await Task.detached { try AgentContextBridge.read(directory: directory) }.value
        XCTAssertTrue(String(decoding: second, as: UTF8.self).contains("completed"))
        bridge.stop()
    }
}
