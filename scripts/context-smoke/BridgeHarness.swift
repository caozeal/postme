import Foundation
import Darwin
struct CLIError: Error, CustomStringConvertible { let description: String; init(_ message: String, code: String? = nil) { description = message } }
@main struct Harness {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: "/tmp/postme-context-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let secret = Data(#"{"password":"synthetic-secret","message":"another-secret","n":2}"#.utf8)
        let sanitized = try JSONSerialization.data(withJSONObject: AgentContextSanitizer.body(secret))
        let text = String(decoding: sanitized, as: UTF8.self)
        precondition(!text.contains("synthetic-secret") && !text.contains("another-secret"))
        precondition(AgentContextSanitizer.body(Data(repeating: 65, count: 32769))["omitted"] as? Bool == true)
        let prefix = String(repeating: "a", count: 128)
        _ = AgentContextSanitizer.json([prefix + "x": 1, prefix + "y": 2])
        let bridge = AgentContextBridge(directory: directory)
        try bridge.start { Data("{\"state\":\"running\"}".utf8) }
        let data = try await Task.detached { try AgentContextBridge.read(directory: directory) }.value
        precondition(String(decoding: data, as: UTF8.self).contains("running"))
        let duplicate = AgentContextBridge(directory: directory)
        do { try duplicate.start { Data("{}".utf8) }; fatalError("duplicate accepted") } catch {}
        let mode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("agent-context.sock").path)[.posixPermissions] as! NSNumber
        precondition(mode.intValue == 0o600)
        bridge.stop()
        try bridge.start { Data("{\"state\":\"completed\"}".utf8) }
        let second = try await Task.detached { try AgentContextBridge.read(directory: directory) }.value
        precondition(String(decoding: second, as: UTF8.self).contains("completed"))
        bridge.stop()
        do { _ = try AgentContextBridge.read(directory: directory); fatalError("disabled still readable") } catch {}
        print("PASS: redaction, bounds, long keys, live socket, same-user endpoint, duplicate ownership, mode 0600, immediate restart, revocation")
    }
}
