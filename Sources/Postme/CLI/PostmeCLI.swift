import Foundation

struct CLIError: Error, CustomStringConvertible {
    let message: String
    let exitCode: Int32
    /// 机器可读的稳定标识；普通错误为 nil，保持旧行为。
    let code: String?

    init(_ message: String, exitCode: Int32 = 1, code: String? = nil) {
        self.message = message
        self.exitCode = exitCode
        self.code = code
    }

    var description: String { message }

    static func usage(_ message: String) -> CLIError {
        CLIError(message, exitCode: 2)
    }

    /// 工作区并发冲突专用退出码：脚本要能区分「重试可能成功的瞬时冲突」与「命令本身有问题」。
    static let workspaceConflictExitCode: Int32 = 3

    static func workspaceBusy(_ path: String) -> CLIError {
        CLIError(
            "Workspace is busy (another postme process is writing to \(path)); the command did not write anything — retry it.",
            exitCode: workspaceConflictExitCode,
            code: "workspace_busy"
        )
    }

    static func workspaceConflict(_ path: String, changedFiles: [String]) -> CLIError {
        CLIError(
            "Workspace changed on disk since it was read (\(changedFiles.joined(separator: ", ")) in \(path)); the command did not write anything — retry it.",
            exitCode: workspaceConflictExitCode,
            code: "workspace_conflict"
        )
    }
}

/// 全局选项与位置参数。选项可以出现在子命令前后，`--` 之后一律按字面量处理。
private struct CLIOptions {
    var dataDirectory: String?
    var json = false
    var help = false
    var version = false
    var values: [String: String] = [:]
    var flags = Set<String>()
    var positionals: [String] = []

    init(_ arguments: [String]) throws {
        let valueOptions: Set<String> = ["data-dir", "project", "new-project", "output", "limit", "name", "folder", "in"]
        let flagOptions: Set<String> = ["json", "yes"]
        var index = 0
        var literalOnly = false

        while index < arguments.count {
            let argument = arguments[index]
            if literalOnly || !argument.hasPrefix("--") {
                if !literalOnly, argument == "-h" {
                    help = true
                } else {
                    positionals.append(argument)
                }
                index += 1
                continue
            }
            if argument == "--" {
                literalOnly = true
                index += 1
                continue
            }
            let option = String(argument.dropFirst(2))
            if option == "help" {
                help = true
            } else if option == "version" {
                version = true
            } else if flagOptions.contains(option) {
                flags.insert(option)
                if option == "json" { json = true }
            } else if valueOptions.contains(option) {
                guard values[option] == nil else { throw CLIError.usage("Duplicate option: --\(option)") }
                guard index + 1 < arguments.count else { throw CLIError.usage("Missing value for --\(option)") }
                values[option] = arguments[index + 1]
                index += 1
                if option == "data-dir" { dataDirectory = arguments[index] }
            } else {
                throw CLIError.usage("Unknown option: \(argument)")
            }
            index += 1
        }
    }

    func value(_ name: String) -> String? { values[name] }
    func has(_ name: String) -> Bool { flags.contains(name) }

    func allow(values allowedValues: Set<String> = [], flags allowedFlags: Set<String> = []) throws {
        for name in values.keys where name != "data-dir" && !allowedValues.contains(name) {
            throw CLIError.usage("Option --\(name) is not valid for this command.")
        }
        for name in flags where name != "json" && !allowedFlags.contains(name) {
            throw CLIError.usage("Option --\(name) is not valid for this command.")
        }
    }

    func requireConfirmation() throws {
        guard has("yes") else {
            throw CLIError.usage("This operation is destructive; repeat it with --yes.")
        }
    }
}

/// 命令行入口。GUI 与 CLI 共用同一个二进制，无参数时仍由 `PostmeApp` 启动。
@MainActor
enum PostmeCLI {
    static func run(arguments: [String]) -> Int32 {
        let options: CLIOptions
        do {
            options = try CLIOptions(arguments)
        } catch {
            return report(error, json: arguments.contains("--json"))
        }

        if options.help || (options.positionals.isEmpty && !options.version) {
            printHelp()
            return 0
        }
        if options.version {
            print("postme 1.0.0 (workspace v\(Workspace.currentVersion))")
            return 0
        }

        do {
            let directory = try dataDirectory(options)
            let store = CLIWorkspace(directory: directory)
            try dispatch(options, store: store)
            return 0
        } catch {
            return report(error, json: options.json)
        }
    }

    private static func dataDirectory(_ options: CLIOptions) throws -> URL? {
        guard let path = options.dataDirectory ?? ProcessInfo.processInfo.environment["POSTME_DATA_DIR"],
              !path.isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), !isDirectory.boolValue {
            throw CLIError("Data directory is a file: \(expanded)")
        }
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    private static func dispatch(_ options: CLIOptions, store: CLIWorkspace) throws {
        let p = options.positionals
        switch p[0] {
        case "project": try projectCommand(Array(p.dropFirst()), options, store)
        case "request": try requestCommand(Array(p.dropFirst()), options, store)
        case "folder": try folderCommand(Array(p.dropFirst()), options, store)
        case "environment", "env": try environmentCommand(Array(p.dropFirst()), options, store)
        case "history": try historyCommand(Array(p.dropFirst()), options, store)
        case "import": try importCommand(Array(p.dropFirst()), options, store)
        case "export": try exportCommand(Array(p.dropFirst()), options, store)
        default: throw CLIError.usage("Unknown command: \(p[0]). Run 'postme --help'.")
        }
    }

    // MARK: - 项目与请求

    private static func projectCommand(_ p: [String], _ options: CLIOptions, _ store: CLIWorkspace) throws {
        guard let action = p.first else { throw CLIError.usage("Missing project action.") }
        switch action {
        case "list":
            try expect(p, count: 1, usage: "project list")
            try options.allow()
            let rows = try store.workspace.projects.map { project -> [String: Any] in
                [
                    "id": project.id.uuidString,
                    "name": project.name,
                    "active": project.id == store.workspace.activeProjectID,
                    "requestCount": try store.requests(project: project.id.uuidString).count
                ]
            }
            try emit(rows, json: options.json) {
                rows.map { row in
                    "\(row["active"] as? Bool == true ? "*" : " ")\t\(row["id"]!)\t\(row["name"]!)\t\(row["requestCount"]!) requests"
                }.joined(separator: "\n")
            }
        case "create":
            try expect(p, count: 2, usage: "project create <name>")
            try options.allow()
            let created = try store.createProject(name: p[1])
            try emit(projectObject(created), json: options.json) { "Created and activated project \(created.name) (\(created.id.uuidString))" }
        case "rename":
            try expect(p, count: 3, usage: "project rename <project> <new-name>")
            try options.allow()
            let updated = try store.renameProject(p[1], to: p[2])
            try emit(projectObject(updated), json: options.json) { "Renamed project \(updated.id.uuidString) to \(updated.name)" }
        case "use":
            try expect(p, count: 2, usage: "project use <project>")
            try options.allow()
            let selected = try store.activateProject(p[1])
            try emit(projectObject(selected), json: options.json) { "Activated project \(selected.name)" }
        case "delete":
            try expect(p, count: 2, usage: "project delete <project> --yes")
            try options.allow(flags: ["yes"])
            try options.requireConfirmation()
            let deleted = try store.deleteProject(p[1])
            try emit(projectObject(deleted), json: options.json) { "Deleted project \(deleted.name) (\(deleted.id.uuidString))" }
        default: throw CLIError.usage("Unknown project action: \(action)")
        }
    }

    private static func requestCommand(_ p: [String], _ options: CLIOptions, _ store: CLIWorkspace) throws {
        guard let action = p.first else { throw CLIError.usage("Missing request action.") }
        switch action {
        case "list":
            try expect(p, count: 1, usage: "request list [--project <project>]")
            try options.allow(values: ["project"])
            let rows = try store.requests(project: options.value("project")).map { requestObject($0) }
            try emit(rows, json: options.json) {
                rows.map { row in
                    "\(row["id"]!)\t\(row["method"]!)\t\(row["name"]!)\t\(row["url"]!)\t\(row["projectName"]!)"
                }.joined(separator: "\n")
            }
        case "show":
            try expect(p, count: 2, usage: "request show <request-uuid>")
            try options.allow()
            let ref = try store.request(id: try uuid(p[1], kind: "request"))
            try emit(requestObject(ref, includeRequest: true), json: options.json) {
                var object = requestObject(ref)
                object["request"] = try jsonObject(ref.saved.request)
                return try jsonString(object)
            }
        case "create":
            try expect(p, count: 2, usage: "request create <file|-> [--project <project>] [--name <name>] [--folder <folder-uuid>]")
            try options.allow(values: ["project", "name", "folder"])
            let spec = try decodeRequestJSON(try readInput(path: p[1]))
            let name = options.value("name") ?? spec.name ?? spec.request.name
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIError.usage("Request name cannot be empty.")
            }
            let created = try store.createRequest(name: name, request: spec.request,
                                                  project: options.value("project"),
                                                  folder: try folderTarget(options, fallback: .root))
            try emit(requestObject(created, includeRequest: true), json: options.json) {
                "Created request \(created.saved.name) (\(created.saved.id.uuidString))"
            }
        case "update":
            try expect(p, count: 3, usage: "request update <request-uuid> <file|-> [--name <name>] [--folder <folder-uuid>|root]")
            try options.allow(values: ["name", "folder"])
            let spec = try decodeRequestJSON(try readInput(path: p[2]))
            let updated = try store.updateRequest(id: try uuid(p[1], kind: "request"),
                                                  name: options.value("name") ?? spec.name,
                                                  request: spec.request,
                                                  folder: try folderTarget(options, fallback: .unchanged))
            try emit(requestObject(updated, includeRequest: true), json: options.json) {
                "Updated request \(updated.saved.name) (\(updated.saved.id.uuidString))"
            }
        case "delete":
            try expect(p, count: 2, usage: "request delete <request-uuid> --yes")
            try options.allow(flags: ["yes"])
            try options.requireConfirmation()
            let deleted = try store.deleteRequest(id: try uuid(p[1], kind: "request"))
            try emit(["deletedRequestID": deleted.saved.id.uuidString], json: options.json) {
                "Deleted request \(deleted.saved.name) (\(deleted.saved.id.uuidString))"
            }
        default: throw CLIError.usage("Unknown request action: \(action)")
        }
    }

    private static func folderCommand(_ p: [String], _ options: CLIOptions, _ store: CLIWorkspace) throws {
        guard let action = p.first else { throw CLIError.usage("Missing folder action.") }
        switch action {
        case "list":
            try expect(p, count: 1, usage: "folder list [--project <project>]")
            try options.allow(values: ["project"])
            let rows = try store.folders(project: options.value("project")).map(folderObject)
            try emit(rows, json: options.json) {
                rows.map { row in
                    "\(row["id"]!)\t\(row["path"]!)\t\(row["requestCount"]!) requests"
                }.joined(separator: "\n")
            }
        case "create":
            try expect(p, count: 2, usage: "folder create <name> [--project <project>] [--in <folder-uuid>]")
            try options.allow(values: ["project", "in"])
            let parentID = try optionalUUID(options.value("in"), kind: "folder")
            let created = try store.createFolder(name: p[1], project: options.value("project"), in: parentID)
            try emit(folderObject(created), json: options.json) {
                "Created folder \(created.folder.name) (\(created.folder.id.uuidString))"
            }
        case "rename":
            try expect(p, count: 3, usage: "folder rename <folder-uuid> <new-name>")
            try options.allow()
            let renamed = try store.renameFolder(id: try uuid(p[1], kind: "folder"), to: p[2])
            try emit(folderObject(renamed), json: options.json) {
                "Renamed folder to \(renamed.folder.name) (\(renamed.folder.id.uuidString))"
            }
        case "delete":
            try expect(p, count: 2, usage: "folder delete <folder-uuid> --yes")
            try options.allow(flags: ["yes"])
            try options.requireConfirmation()
            let deleted = try store.deleteFolder(id: try uuid(p[1], kind: "folder"))
            try emit(["deletedFolderID": deleted.folder.id.uuidString], json: options.json) {
                "Deleted folder \(deleted.folder.name) (\(deleted.folder.id.uuidString)) and its contents"
            }
        default: throw CLIError.usage("Unknown folder action: \(action)")
        }
    }

    // MARK: - 环境与历史

    private static func environmentCommand(_ p: [String], _ options: CLIOptions, _ store: CLIWorkspace) throws {
        guard let action = p.first else { throw CLIError.usage("Missing environment action.") }
        switch action {
        case "list":
            try expect(p, count: 1, usage: "environment list")
            try options.allow()
            let rows = try store.workspace.environments.map { environment -> [String: Any] in
                guard var object = try jsonObject(environment) as? [String: Any] else {
                    throw CLIError("Failed to encode environment output.")
                }
                object["active"] = environment.id == store.workspace.activeEnvironmentID
                return object
            }
            try emit(rows, json: options.json) {
                rows.map { row in
                    "\(row["active"] as? Bool == true ? "*" : " ")\t\(row["id"]!)\t\(row["name"]!)"
                }.joined(separator: "\n")
            }
        case "create":
            try expect(p, count: 2, usage: "environment create <name>")
            try options.allow()
            let created = try store.createEnvironment(name: p[1])
            try emit(jsonObject(created), json: options.json) { "Created environment \(created.name) (\(created.id.uuidString))" }
        case "use":
            try expect(p, count: 2, usage: "environment use <environment>")
            try options.allow()
            guard let selected = try store.activateEnvironment(p[1]) else {
                throw CLIError("Environment not found: \(p[1])")
            }
            try emit(jsonObject(selected), json: options.json) { "Activated environment \(selected.name)" }
        case "deactivate":
            try expect(p, count: 1, usage: "environment deactivate")
            try options.allow()
            _ = try store.activateEnvironment(nil)
            try emit(["activeEnvironmentID": NSNull()], json: options.json) { "Deactivated environment" }
        case "set":
            try expect(p, count: 4, usage: "environment set <environment> <key> <value>")
            try options.allow()
            let updated = try store.setVariable(environment: p[1], key: p[2], value: p[3])
            try emit(["environmentID": updated.id.uuidString, "key": p[2]], json: options.json) {
                "Set \(p[2]) in environment \(updated.name)"
            }
        case "unset":
            try expect(p, count: 3, usage: "environment unset <environment> <key>")
            try options.allow()
            let updated = try store.unsetVariable(environment: p[1], key: p[2])
            try emit(["environmentID": updated.id.uuidString, "key": p[2]], json: options.json) {
                "Removed \(p[2]) from environment \(updated.name)"
            }
        case "delete":
            try expect(p, count: 2, usage: "environment delete <environment> --yes")
            try options.allow(flags: ["yes"])
            try options.requireConfirmation()
            let deleted = try store.deleteEnvironment(p[1])
            try emit(jsonObject(deleted), json: options.json) { "Deleted environment \(deleted.name)" }
        default: throw CLIError.usage("Unknown environment action: \(action)")
        }
    }

    private static func historyCommand(_ p: [String], _ options: CLIOptions, _ store: CLIWorkspace) throws {
        guard let action = p.first else { throw CLIError.usage("Missing history action.") }
        switch action {
        case "list":
            try expect(p, count: 1, usage: "history list [--limit <count>]")
            try options.allow(values: ["limit"])
            let limit = try positiveLimit(options.value("limit"), defaultValue: 50)
            let rows = store.workspace.history.prefix(limit).map { entry -> [String: Any] in
                var row: [String: Any] = [
                    "id": entry.id.uuidString,
                    "name": entry.requestName,
                    "method": entry.method.rawValue,
                    "url": entry.url,
                    "succeeded": entry.succeeded,
                    "timestamp": ISO8601DateFormatter().string(from: entry.timestamp)
                ]
                row["projectID"] = entry.projectID?.uuidString ?? NSNull()
                row["statusCode"] = entry.statusCode ?? NSNull()
                row["duration"] = entry.duration ?? NSNull()
                return row
            }
            try emit(rows, json: options.json) {
                rows.map { row in
                    "\(row["timestamp"]!)\t\(row["method"]!)\t\(row["statusCode"]!)\t\(row["name"]!)\t\(row["url"]!)"
                }.joined(separator: "\n")
            }
        case "clear":
            try expect(p, count: 1, usage: "history clear --yes")
            try options.allow(flags: ["yes"])
            try options.requireConfirmation()
            let count = store.workspace.history.count
            try store.clearHistory()
            try emit(["deletedCount": count], json: options.json) { "Cleared \(count) history entries" }
        default: throw CLIError.usage("Unknown history action: \(action)")
        }
    }

    // MARK: - 导入与导出

    private static func importCommand(_ p: [String], _ options: CLIOptions, _ store: CLIWorkspace) throws {
        guard p.count == 2 else { throw CLIError.usage("Usage: import <openapi|postman|curl> <file|-> [options]") }
        let format = p[0]
        let data = try readInput(path: p[1])
        let summary: CLIImportSummary
        switch format {
        case "openapi":
            try options.allow(values: ["project", "new-project"])
            try requireMutuallyExclusiveTarget(options)
            summary = try store.importOpenAPI(data: data, project: options.value("project"),
                                             newProjectName: options.value("new-project"))
        case "postman":
            try options.allow()
            summary = try store.importPostman(data: data)
        case "curl":
            try options.allow(values: ["project", "new-project"])
            try requireMutuallyExclusiveTarget(options)
            guard let text = String(data: data, encoding: .utf8) else {
                throw CLIError("cURL input must be UTF-8 text.")
            }
            summary = try store.importCurl(text: text, project: options.value("project"),
                                           newProjectName: options.value("new-project"))
        default:
            throw CLIError.usage("Unsupported import format: \(format)")
        }
        try emit(importObject(summary, format: format), json: options.json) {
            var lines = ["Imported \(summary.requestCount) requests into \(summary.project.name) (\(summary.project.id.uuidString))"]
            lines.append(contentsOf: summary.warnings.map { "Warning: \($0)" })
            return lines.joined(separator: "\n")
        }
    }

    private static func exportCommand(_ p: [String], _ options: CLIOptions, _ store: CLIWorkspace) throws {
        guard p.count == 2, p[0] == "postman" else {
            throw CLIError.usage("Usage: export postman <project> [--output <file|->]")
        }
        try options.allow(values: ["output"])
        let data = try store.exportPostman(project: p[1])
        if let output = options.value("output"), output != "-" {
            let url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath).standardizedFileURL
            // 导出自己的结果不碰工作区，但 --output 指到受管文件就等于绕过锁直接覆盖。
            let dataDir = URL(fileURLWithPath: store.storagePath, isDirectory: true).standardizedFileURL
            let protected = Set((WorkspaceDirectory.managedFiles + [WorkspaceDirectory.lockFileName]).map {
                dataDir.appendingPathComponent($0).standardizedFileURL.path
            })
            guard !protected.contains(url.path) else {
                throw CLIError("Refusing to overwrite a managed workspace file: \(url.path)")
            }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                throw CLIError("Failed to write \(url.path): \(error.localizedDescription)")
            }
            try emit(["output": url.path, "bytes": data.count], json: options.json) {
                "Exported \(data.count) bytes to \(url.path)"
            }
        } else {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0a]))
        }
    }

    // MARK: - 输出与参数辅助

    private static func projectObject(_ project: Project) -> [String: Any] {
        ["id": project.id.uuidString, "name": project.name]
    }

    private static func requestObject(_ ref: CLIRequestRef, includeRequest: Bool = false) -> [String: Any] {
        var object: [String: Any] = [
            "id": ref.saved.id.uuidString,
            "requestID": ref.saved.request.id.uuidString,
            "name": ref.saved.name,
            "method": ref.saved.request.method.rawValue,
            "url": ref.saved.request.url,
            "projectID": ref.project.id.uuidString,
            "projectName": ref.project.name,
            "path": ref.path.joined(separator: " / "),
            "pathComponents": ref.path
        ]
        if includeRequest, let request = try? jsonObject(ref.saved.request) { object["request"] = request }
        return object
    }

    private static func folderObject(_ ref: CLIFolderRef) -> [String: Any] {
        [
            "id": ref.folder.id.uuidString,
            "name": ref.folder.name,
            "path": ref.path.joined(separator: " / "),
            "pathComponents": ref.path,
            "projectID": ref.project.id.uuidString,
            "projectName": ref.project.name,
            "requestCount": ref.requestCount
        ]
    }

    private static func importObject(_ summary: CLIImportSummary, format: String) -> [String: Any] {
        var object: [String: Any] = [
            "format": format,
            "projectID": summary.project.id.uuidString,
            "projectName": summary.project.name,
            "requestCount": summary.requestCount,
            "warnings": summary.warnings
        ]
        object["folderCount"] = summary.folderCount ?? NSNull()
        object["environmentID"] = summary.environment?.id.uuidString ?? NSNull()
        return object
    }

    private static func emit(_ value: Any, json: Bool, human: () throws -> String) throws {
        if json {
            print(try jsonString(value))
        } else {
            let text = try human()
            if !text.isEmpty { print(text) }
        }
    }

    private static func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value))
    }

    private static func jsonString(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else { throw CLIError("Failed to encode JSON output.") }
        return text
    }

    private static func readInput(path: String) throws -> Data {
        if path == "-" { return FileHandle.standardInput.readDataToEndOfFile() }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        do {
            return try Data(contentsOf: url)
        } catch {
            throw CLIError("Failed to read \(url.path): \(error.localizedDescription)")
        }
    }

    /// create / update 的输入：一份完整的 `APIRequest` JSON，或 `request show --json`
    /// 的完整输出（顶层 `request` + `name`），这样 show → 改 → update 可以直接闭环。
    ///
    /// `APIRequest` 的解码是容错的（缺字段一律退默认值），所以先做结构校验：
    /// 否则把摘要行、空对象或无关文件喂进来也会「成功」创建一条空请求。
    private static func decodeRequestJSON(_ data: Data) throws -> (name: String?, request: APIRequest) {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw CLIError.usage("Request spec must be a JSON object.")
        }
        let wrapped = dictionary["request"] as? [String: Any]
        let body = wrapped ?? dictionary
        guard body["url"] is String,
              body["method"] is String,
              body["headers"] as? [Any] != nil,
              body["bodyKind"] is String else {
            throw CLIError.usage("Request JSON must contain a full APIRequest (use 'request show <id> --json' and pass its .request object).")
        }
        let encoded = try JSONSerialization.data(withJSONObject: body)
        // 只有包装形态（`request show --json` 的完整输出）的顶层 name 是节点名；
        // 纯 APIRequest 自己也有 name 字段，那是请求名，不该拿来覆盖节点名。
        let nodeName = wrapped == nil ? nil : dictionary["name"] as? String
        do {
            return (nodeName, try JSONDecoder().decode(APIRequest.self, from: encoded))
        } catch {
            throw CLIError.usage("Invalid request JSON: \(error.localizedDescription)")
        }
    }

    private static func uuid(_ text: String, kind: String) throws -> UUID {
        guard let value = UUID(uuidString: text) else {
            throw CLIError.usage("Expected \(kind) UUID, got: \(text)")
        }
        return value
    }

    private static func optionalUUID(_ text: String?, kind: String) throws -> UUID? {
        guard let text else { return nil }
        return try uuid(text, kind: kind)
    }

    /// `--folder <uuid>` 指定文件夹；`root` / `-` 表示项目根；不传时用 fallback。
    private static func folderTarget(_ options: CLIOptions, fallback: FolderTarget) throws -> FolderTarget {
        guard let raw = options.value("folder") else { return fallback }
        if raw == "root" || raw == "-" { return .root }
        return .folder(try uuid(raw, kind: "folder"))
    }

    private static func positiveLimit(_ text: String?, defaultValue: Int) throws -> Int {
        guard let text else { return defaultValue }
        guard let value = Int(text), value > 0 else { throw CLIError.usage("--limit must be a positive integer.") }
        return value
    }

    private static func requireMutuallyExclusiveTarget(_ options: CLIOptions) throws {
        if options.value("project") != nil && options.value("new-project") != nil {
            throw CLIError.usage("--project and --new-project cannot be used together.")
        }
    }

    private static func expect(_ p: [String], count: Int, usage: String) throws {
        guard p.count == count else { throw CLIError.usage("Usage: \(usage)") }
    }

    private static func report(_ error: Error, json: Bool) -> Int32 {
        let cliError = error as? CLIError ?? CLIError(error.localizedDescription)
        if json {
            // 保留原有的 error 键（旧消费者不受影响），额外给机器消费者稳定的 code / exitCode。
            var object: [String: Any] = ["error": cliError.message, "exitCode": cliError.exitCode]
            if let code = cliError.code { object["code"] = code }
            if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                FileHandle.standardError.write(Data((text + "\n").utf8))
                return cliError.exitCode
            }
        }
        FileHandle.standardError.write(Data("error: \(cliError.message)\n".utf8))
        return cliError.exitCode
    }

    private static func printHelp() {
        print("""
        postme — GUI and command-line API workspace

        Usage:
          postme [--data-dir <dir>] [--json] <command> [options]
          postme                         Launch the macOS GUI

        Commands:
          project list|create|rename|use|delete
          request list|show|create|update|delete
          folder list|create|rename|delete
          environment list|create|use|deactivate|set|unset|delete
          history list|clear
          import openapi <file|-> [--project <project> | --new-project <name>]
          import postman <file|->
          import curl <file|-> [--project <project> | --new-project <name>]
          export postman <project> [--output <file|->]

        Options:
          --data-dir <dir>       Override ~/Library/Application Support/postme
          --json                 Emit stable, machine-readable JSON
          --project <project>    Project name or UUID (duplicate names require UUID)
          --new-project <name>   Import into a new project
          --output <file|->      Export file; stdout when omitted or '-'
          --limit <count>        History rows (default: 50)
          --name <name>          Request name for create/update (otherwise from JSON)
          --folder <uuid>|root   Place/move a request into a folder (root = project root)
          --in <folder-uuid>     Parent folder for 'folder create'
          --yes                  Confirm project/request/folder/environment delete or history clear
          --version              Print version
          -h, --help             Show this help

        Environment:
          POSTME_DATA_DIR        Same as --data-dir; the explicit option wins

        Notes:
          Import paths accept '-' for stdin. Request IDs are collection-node UUIDs,
          shown by 'request list'. 'request create <file|->' and
          'request update <uuid> <file|->' take a full APIRequest JSON; the output
          of 'request show --json' is accepted as-is (its 'request' object is used).
          'folder list|create|rename|delete' manage the collection tree; a folder
          delete removes its whole subtree and needs --yes.
          GUI and CLI take a short exclusive lock only while writing. A write command that finds the workspace busy or changed on disk
          fails with exit code 3 and writes nothing -- just retry it. Read-only
          commands are unaffected. The GUI detects external changes when reactivated
          and reloads, or asks before discarding unsaved edits.
        """)
    }
}
