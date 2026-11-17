import Foundation
import SwiftUI
@main struct ContextAppHarness {
    @MainActor static func main() async throws {
        let base = ProcessInfo.processInfo.environment["POSTME_TEST_BASE_URL"]!
        let directory = URL(fileURLWithPath: "/tmp/postme-app-context-" + UUID().uuidString.prefix(6))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = AppState(persistence: PersistenceService(directory: directory))
        func snapshot() throws -> [String: Any] { try JSONSerialization.jsonObject(with: app.agentContextData()) as! [String: Any] }
        precondition(!app.agentContextEnabled)
        app.draft = APIRequest(name: "Synthetic A", url: base + "/ok")
        precondition((try! snapshot())["requestName"] as? String == "Synthetic A")
        app.setAgentContextEnabled(true)
        precondition(app.agentContextEnabled, app.agentContextError ?? "enable failed")
        let initial = try await Task.detached { try AgentContextBridge.read(directory: directory) }.value
        precondition(String(decoding: initial, as: UTF8.self).contains("Synthetic A"))
        await app.send()
        let ok = try snapshot()
        precondition(ok["state"] as? String == "completed")
        precondition(ok["resultComplete"] as? Bool == true)
        let firstRun = ok["runID"] as! String
        precondition(!String(decoding: app.agentContextData(), as: UTF8.self).contains("synthetic-secret"))
        app.draft.url = base + "/fail"
        precondition((try! snapshot())["draftChangedSinceRun"] as? Bool == true)
        await app.send()
        let failure = try snapshot()
        precondition(failure["state"] as? String == "http_error")
        precondition(failure["runID"] as? String != firstRun)
        let previousTab = failure["tabID"] as! String
        app.newRequest()
        let new = try snapshot()
        precondition(new["tabID"] as? String != previousTab)
        precondition(new["runID"] is NSNull)
        precondition(new["state"] as? String == "not_run")
        app.draft.url = base + "/slow"
        let task = Task { await app.send() }
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition((try! snapshot())["state"] as? String == "running")
        app.cancelSend()
        await task.value
        precondition((try! snapshot())["state"] as? String == "cancelled")
        app.setAgentContextEnabled(false)
        print("PASS: live app default opt-out, selected label, socket snapshot, HTTP 200/500, stable/new run IDs, edited draft flag, tab change, running/cancelled, redaction")
    }
}
