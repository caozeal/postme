import Foundation

/// CLI 看到的一条已保存请求及其项目、目录位置。
struct CLIRequestRef {
    var project: Project
    var saved: CollectionNode.SavedRequest
    var path: [String]
}

/// 三种导入共用的结果摘要。
struct CLIImportSummary {
    var project: Project
    var requestCount: Int
    var folderCount: Int?
    var environment: APIEnvironment?
    var warnings: [String]
}

/// 无窗口的数据操作层。
///
/// 刻意不经过 `AppState`：后者会恢复/重置页签，并在有脏草稿时推迟项目切换，
/// 这些交互规则不适用于批处理。这里只复用持久化模型和 Codec，写操作立即同步落盘。
@MainActor
final class CLIWorkspace {
    private let persistence: PersistenceService
    private(set) var workspace: Workspace

    init(directory: URL? = nil) {
        persistence = PersistenceService(directory: directory)
        workspace = persistence.load()
    }

    var storagePath: String { persistence.storagePath }
    var localizer: Localizer { Localizer(language: workspace.settings.language ?? .systemDefault) }

    private func save() throws {
        switch persistence.flushNow(workspace) {
        case .succeeded:
            return
        case .failed(let names):
            throw CLIError("Failed to write workspace in \(persistence.storagePath): \(names.joined(separator: ", "))")
        case .stale:
            // flushNow 每次自增 generation，理论上不会过期；仍按操作失败处理，不静默当成功。
            throw CLIError("Failed to write workspace in \(persistence.storagePath): stale save generation")
        case .conflict(.busy):
            throw CLIError.workspaceBusy(persistence.storagePath)
        case .conflict(.fingerprintMismatch(let files)):
            // 不自动 reload 重试：批处理命令已改内存，自动重试会掩盖冲突。
            // CAS 在写任何字节之前拦截，所以「失败 = 什么都没发生」，重跑整条命令是安全的。
            throw CLIError.workspaceConflict(persistence.storagePath, changedFiles: files)
        }
    }

    // MARK: - 选择器

    func project(_ selector: String? = nil) throws -> Project {
        guard let selector else {
            if let active = workspace.projects.first(where: { $0.id == workspace.activeProjectID }) {
                return active
            }
            throw CLIError("No active project. Create one with 'project create <name>'.")
        }
        if let id = UUID(uuidString: selector), let match = workspace.projects.first(where: { $0.id == id }) {
            return match
        }
        let matches = workspace.projects.filter { $0.name == selector }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 {
            throw CLIError("Project name '\(selector)' is ambiguous; use its UUID.")
        }
        throw CLIError("Project not found: \(selector)")
    }

    private func environment(_ selector: String) throws -> APIEnvironment {
        if let id = UUID(uuidString: selector), let match = workspace.environments.first(where: { $0.id == id }) {
            return match
        }
        let matches = workspace.environments.filter { $0.name == selector }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 {
            throw CLIError("Environment name '\(selector)' is ambiguous; use its UUID.")
        }
        throw CLIError("Environment not found: \(selector)")
    }

    private func ensureActiveProject() {
        if workspace.projects.isEmpty {
            let created = Project(name: localizer(.defaultProjectName))
            workspace.projects = [created]
            activateProject(id: created.id)
        } else if !workspace.projects.contains(where: { $0.id == workspace.activeProjectID }),
                  let fallback = workspace.projects.first?.id {
            activateProject(id: fallback)
        }
    }

    /// 与 GUI 启动时的 `syncProjectToActiveTab` 保持同向：若当前页签属于旧项目，
    /// 只改 activeProjectID 会在下次启动被切回去。优先选目标项目已有页签，
    /// 没有则补一个空白页签；已有页签和未保存草稿一律保留。
    private func activateProject(id: UUID) {
        workspace.activeProjectID = id
        guard !workspace.tabs.isEmpty,
              let active = workspace.tabs.first(where: { $0.id == workspace.activeTabID }) ?? workspace.tabs.first,
              let nodeID = active.nodeID,
              let owner = workspace.projects.first(where: { $0.children.findNode(id: nodeID) != nil }),
              owner.id != id else { return }
        if let target = workspace.tabs.first(where: { tab in
            tab.nodeID.flatMap { nodeID in
                workspace.projects.first(where: { $0.id == id })?.children.findNode(id: nodeID)
            } != nil
        }) {
            workspace.activeTabID = target.id
        } else {
            let fresh = EditorTab(draft: APIRequest())
            workspace.tabs.append(fresh)
            workspace.activeTabID = fresh.id
        }
    }

    // MARK: - 项目

    func createProject(name: String) throws -> Project {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CLIError("Project name cannot be empty.") }
        let created = Project(name: trimmed)
        workspace.projects.append(created)
        activateProject(id: created.id)
        try save()
        return created
    }

    func renameProject(_ selector: String, to name: String) throws -> Project {
        let target = try project(selector)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CLIError("Project name cannot be empty.") }
        guard let index = workspace.projects.firstIndex(where: { $0.id == target.id }) else {
            throw CLIError("Project not found: \(selector)")
        }
        workspace.projects[index].name = trimmed
        try save()
        return workspace.projects[index]
    }

    func activateProject(_ selector: String) throws -> Project {
        let target = try project(selector)
        activateProject(id: target.id)
        try save()
        return target
    }

    func deleteProject(_ selector: String) throws -> Project {
        let target = try project(selector)
        guard workspace.projects.count > 1 else {
            throw CLIError("Cannot delete the last project.")
        }
        let wasActive = workspace.activeProjectID == target.id
        workspace.projects.removeProject(id: target.id)
        detachDeletedNodes(target.children)
        if wasActive, let fallback = workspace.projects.first?.id {
            activateProject(id: fallback)
        }
        try save()
        return target
    }

    // MARK: - 请求

    func requests(project selector: String? = nil) throws -> [CLIRequestRef] {
        let selected: [Project]
        if let selector {
            selected = [try project(selector)]
        } else {
            selected = workspace.projects
        }
        return selected.flatMap { project in
            Self.requests(in: project.children, project: project, path: [])
        }
    }

    private static func requests(in nodes: [CollectionNode], project: Project, path: [String]) -> [CLIRequestRef] {
        nodes.flatMap { node -> [CLIRequestRef] in
            switch node {
            case .folder(let folder):
                return requests(in: folder.children, project: project, path: path + [folder.name])
            case .request(let saved):
                return [CLIRequestRef(project: project, saved: saved, path: path)]
            }
        }
    }

    func request(id: UUID) throws -> CLIRequestRef {
        if let match = try requests().first(where: { $0.saved.id == id }) { return match }
        throw CLIError("Request not found: \(id.uuidString)")
    }

    /// 在项目根目录追加一条已保存请求。名称由调用方解析好（--name > JSON > 请求自带名）。
    func createRequest(name: String, request: APIRequest, project selector: String?) throws -> CLIRequestRef {
        if selector == nil { ensureActiveProject() }
        let target = try project(selector)
        guard let index = workspace.projects.firstIndex(where: { $0.id == target.id }) else {
            throw CLIError("Project not found: \(target.id.uuidString)")
        }
        var stored = request
        // 输入常来自 `request show --json`，沿用里面的 id 会让两条请求共享 requestID。
        stored.id = UUID()
        let saved = CollectionNode.SavedRequest(name: name, request: stored)
        workspace.projects[index].children.append(.request(saved))
        try save()
        return CLIRequestRef(project: workspace.projects[index], saved: saved, path: [])
    }

    /// 原地替换一条请求的内容，节点与请求的 UUID 都保持不变（页签归属、历史引用不失效）。
    /// name 为 nil 时保留原名称。
    func updateRequest(id: UUID, name: String?, request: APIRequest) throws -> CLIRequestRef {
        let target = try self.request(id: id)
        guard let index = workspace.projects.firstIndex(where: { $0.id == target.project.id }) else {
            throw CLIError("Project not found: \(target.project.id.uuidString)")
        }
        guard workspace.projects[index].children.replaceSavedRequest(id: id, with: request) else {
            throw CLIError("Request not found: \(id.uuidString)")
        }
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            workspace.projects[index].children.renameNode(id: id, to: name)
        }
        try save()
        return try self.request(id: id)
    }

    func deleteRequest(id: UUID) throws -> CLIRequestRef {
        let target = try request(id: id)
        guard let index = workspace.projects.firstIndex(where: { $0.id == target.project.id }) else {
            throw CLIError("Project not found: \(target.project.id.uuidString)")
        }
        workspace.projects[index].children.removeNode(id: id)
        detachDeletedNodes([.request(target.saved)])
        try save()
        return target
    }

    private func detachDeletedNodes(_ nodes: [CollectionNode]) {
        let ids = Set(nodes.flatMap(Self.allNodeIDs))
        guard !ids.isEmpty else { return }
        for index in workspace.tabs.indices {
            if let nodeID = workspace.tabs[index].nodeID, ids.contains(nodeID) {
                workspace.tabs[index].nodeID = nil
            }
        }
    }

    private static func allNodeIDs(_ node: CollectionNode) -> [UUID] {
        switch node {
        case .request(let saved): return [saved.id]
        case .folder(let folder): return [folder.id] + folder.children.flatMap(allNodeIDs)
        }
    }

    // MARK: - 环境

    func createEnvironment(name: String) throws -> APIEnvironment {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CLIError("Environment name cannot be empty.") }
        let created = APIEnvironment(name: trimmed)
        workspace.environments.append(created)
        if workspace.activeEnvironmentID == nil { workspace.activeEnvironmentID = created.id }
        try save()
        return created
    }

    func activateEnvironment(_ selector: String?) throws -> APIEnvironment? {
        if let selector {
            let target = try environment(selector)
            workspace.activeEnvironmentID = target.id
            try save()
            return target
        }
        workspace.activeEnvironmentID = nil
        try save()
        return nil
    }

    func setVariable(environment selector: String, key: String, value: String) throws -> APIEnvironment {
        let target = try environment(selector)
        guard !key.isEmpty else { throw CLIError("Variable key cannot be empty.") }
        guard let index = workspace.environments.firstIndex(where: { $0.id == target.id }) else {
            throw CLIError("Environment not found: \(selector)")
        }
        if workspace.environments[index].variables.contains(where: { $0.key == key }) {
            for variable in workspace.environments[index].variables.indices where workspace.environments[index].variables[variable].key == key {
                workspace.environments[index].variables[variable].value = value
                workspace.environments[index].variables[variable].isEnabled = true
            }
        } else {
            workspace.environments[index].variables.append(KeyValueItem(key: key, value: value))
        }
        try save()
        return workspace.environments[index]
    }

    func unsetVariable(environment selector: String, key: String) throws -> APIEnvironment {
        let target = try environment(selector)
        guard let index = workspace.environments.firstIndex(where: { $0.id == target.id }) else {
            throw CLIError("Environment not found: \(selector)")
        }
        let oldCount = workspace.environments[index].variables.count
        workspace.environments[index].variables.removeAll { $0.key == key }
        guard workspace.environments[index].variables.count != oldCount else {
            throw CLIError("Variable not found: \(key)")
        }
        try save()
        return workspace.environments[index]
    }

    func deleteEnvironment(_ selector: String) throws -> APIEnvironment {
        let target = try environment(selector)
        workspace.environments.removeAll { $0.id == target.id }
        if workspace.activeEnvironmentID == target.id {
            workspace.activeEnvironmentID = workspace.environments.first?.id
        }
        try save()
        return target
    }

    // MARK: - 历史

    func clearHistory() throws {
        workspace.history.removeAll()
        try save()
    }

    // MARK: - 导入 / 导出

    func importPostman(data: Data) throws -> CLIImportSummary {
        do {
            let result = try PostmanCodec.decode(data, l10n: localizer)
            let created = Project(name: result.collectionName, children: result.nodes)
            workspace.projects.append(created)
            activateProject(id: created.id)
            if var environment = result.environment {
                environment.name = uniqueEnvironmentName(environment.name)
                workspace.environments.append(environment)
                if workspace.activeEnvironmentID == nil { workspace.activeEnvironmentID = environment.id }
                try save()
                return CLIImportSummary(project: created, requestCount: result.requestCount,
                                        folderCount: nil, environment: environment, warnings: result.warnings)
            }
            try save()
            return CLIImportSummary(project: created, requestCount: result.requestCount,
                                    folderCount: nil, environment: nil, warnings: result.warnings)
        } catch let error as PostmanCodec.CodecError {
            throw CLIError(error.message(localizer))
        }
    }

    func importOpenAPI(data: Data, project selector: String?, newProjectName: String?) throws -> CLIImportSummary {
        do {
            let result = try OpenAPICodec.decode(data, l10n: localizer)
            let requestedName = newProjectName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let importName = requestedName.isEmpty ? result.title : requestedName
            let target: Project
            if let selector {
                let existing = try project(selector)
                guard let index = workspace.projects.firstIndex(where: { $0.id == existing.id }) else {
                    throw CLIError("Project not found: \(selector)")
                }
                workspace.projects[index].children.append(.folder(.init(
                    name: importName,
                    children: result.nodes
                )))
                target = workspace.projects[index]
            } else {
                let created = Project(name: importName, children: result.nodes)
                workspace.projects.append(created)
                activateProject(id: created.id)
                target = created
            }

            var importedEnvironment: APIEnvironment?
            if var environment = result.environment {
                environment.name = uniqueEnvironmentName(environment.name)
                workspace.environments.append(environment)
                workspace.activeEnvironmentID = environment.id
                importedEnvironment = environment
            }
            try save()
            return CLIImportSummary(project: target, requestCount: result.requestCount,
                                    folderCount: result.folderCount, environment: importedEnvironment,
                                    warnings: result.warnings)
        } catch let error as OpenAPICodec.CodecError {
            throw CLIError(error.message(localizer))
        }
    }

    func importCurl(text: String, project selector: String?, newProjectName: String?) throws -> CLIImportSummary {
        do {
            let result = try CurlCodec.decode(text, l10n: localizer)
            let nodes = result.requests.map { request -> CollectionNode in
                var stored = request
                let trimmed = stored.name.trimmingCharacters(in: .whitespacesAndNewlines)
                stored.name = trimmed.isEmpty ? localizer(.curlRequestDefaultName) : trimmed
                return .request(.init(name: stored.name, request: stored))
            }
            let target: Project
            if let newProjectName {
                let trimmed = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { throw CLIError("Project name cannot be empty.") }
                let created = Project(name: trimmed, children: nodes)
                workspace.projects.append(created)
                activateProject(id: created.id)
                target = created
            } else {
                if selector == nil { ensureActiveProject() }
                let existing = try project(selector)
                guard let index = workspace.projects.firstIndex(where: { $0.id == existing.id }) else {
                    throw CLIError("Project not found: \(selector ?? existing.id.uuidString)")
                }
                workspace.projects[index].children.append(contentsOf: nodes)
                target = workspace.projects[index]
            }
            try save()
            return CLIImportSummary(project: target, requestCount: nodes.count,
                                    folderCount: nil, environment: nil, warnings: result.warnings)
        } catch let error as CurlCodec.CodecError {
            throw CLIError(error.message(localizer))
        }
    }

    func exportPostman(project selector: String) throws -> Data {
        do {
            let selected = try project(selector)
            let environment = workspace.environments.first { $0.id == workspace.activeEnvironmentID }
            return try PostmanCodec.encode(project: selected, environment: environment)
        } catch let error as PostmanCodec.CodecError {
            throw CLIError(error.message(localizer))
        }
    }

    private func uniqueEnvironmentName(_ base: String) -> String {
        let names = Set(workspace.environments.map(\.name))
        guard names.contains(base) else { return base }
        var index = 2
        while names.contains("\(base) (\(index))") { index += 1 }
        return "\(base) (\(index))"
    }
}
