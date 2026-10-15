import SwiftUI
import AppKit
import Observation

/// 请求编辑区的分页。
enum RequestTab: String, CaseIterable, Identifiable {
    case params, headers, body
    var id: String { rawValue }
    var title: String {
        switch self {
        case .params: return "Params"
        case .headers: return "Headers"
        case .body: return "Body"
        }
    }
}

/// 响应区的分页。
enum ResponseTab: String, CaseIterable, Identifiable {
    case body, headers, timing
    var id: String { rawValue }
    var title: String {
        switch self {
        case .body: return "Body"
        case .headers: return "Headers"
        case .timing: return "耗时"
        }
    }
}

/// 应用顶层状态容器。
/// 全程 @MainActor：UI 状态变更都在主线程；网络等待期间 await 让出。
@MainActor
@Observable
final class AppState {

    // MARK: - 持久化

    /// 全部持久化数据。修改后调用 `save()`。
    private(set) var workspace: Workspace

    private let persistence: PersistenceService

    /// 存储文件路径（设置界面展示用）。
    var storagePath: String { persistence.storagePath }

    // MARK: - 编辑态

    /// 当前编辑中的请求（工作副本）。
    var draft: APIRequest

    /// 若 draft 来自某个已保存请求，记录其节点 id，用于「保存」覆盖。
    var editingNodeID: UUID?

    var response: APIResponse?
    /// 响应体展示文本（已美化/截断），收到响应时算一次并缓存。
    private(set) var responseBodyText: String = ""
    var isSending = false
    var errorMessage: String?

    /// 上一次发送中未能解析的变量名，用于界面提示。
    private(set) var unresolvedVariables: [String] = []

    /// 环境编辑弹窗是否展示。
    var showEnvironmentEditor: Bool = false

    /// 一次性提示（导入/导出结果等）。
    var alertMessage: AlertMessage?

    struct AlertMessage: Identifiable {
        let id = UUID()
        var text: String
    }

    var requestTab: RequestTab = .params
    var responseTab: ResponseTab = .body

    // MARK: - 侧栏态

    var searchKeyword: String = ""
    var selectedNodeID: UUID?

    /// ⌘F 触发搜索框聚焦（自增即触发，侧栏 onChange 监听）。
    var focusSearchTick: Int = 0

    func requestSearchFocus() {
        focusSearchTick += 1
    }

    /// 「保存到集合」弹窗状态。
    var showSaveSheet: Bool = false
    var saveSheetName: String = ""
    var saveSheetFolderID: UUID?
    /// 新建请求时的默认保存目标文件夹（右键「在此新建请求」用）。
    var defaultSaveFolderID: UUID?

    // MARK: - 私有

    private var cachedExecutor: RequestExecutor?
    private var cachedOptions: RequestExecutorOptions?

    // MARK: - 初始化

    init() {
        let persistence = PersistenceService()
        let loaded = persistence.load()
        self.persistence = persistence
        self.workspace = loaded
        self.draft = loaded.draft ?? APIRequest()

        // 退出前强制落盘，避免防抖窗口内的改动丢失。
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveImmediately()
            }
        }
    }

    // MARK: - 便捷访问

    var collections: [CollectionNode] { workspace.collections }
    var history: [HistoryEntry] { workspace.history }
    var environments: [APIEnvironment] { workspace.environments }

    var activeEnvironment: APIEnvironment? {
        guard let id = workspace.activeEnvironmentID else { return nil }
        return workspace.environments.first { $0.id == id }
    }

    /// 搜索命中的请求（扁平列表）。
    var searchResults: [CollectionNode] {
        workspace.collections.requestsMatching(searchKeyword)
    }

    var isSearching: Bool {
        !searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var executorOptions: RequestExecutorOptions { workspace.settings.executorOptions }

    // MARK: - 发送

    func send() async {
        guard !isSending else { return }
        isSending = true
        errorMessage = nil
        defer { isSending = false }

        // 变量替换（{{var}} → 环境变量 / 内置动态变量）
        let variables = activeEnvironment?.variableMap ?? [:]
        let resolved = VariableResolver.resolve(draft, variables: variables)
        unresolvedVariables = resolved.unresolved
        let outgoing = resolved.request

        do {
            let result = try await executor().send(outgoing)
            response = result
            responseBodyText = result.displayBodyText()
            responseTab = .body
            // 历史记录保留**未替换**的模板（含 {{var}}），便于复用且不落盘明文密钥
            recordHistory(for: draft, statusCode: result.statusCode, duration: result.timing.total, succeeded: result.isSuccess)
        } catch {
            response = nil
            responseBodyText = ""
            errorMessage = error.localizedDescription
            recordHistory(for: draft, statusCode: nil, duration: nil, succeeded: false)
        }
    }

    private func recordHistory(for request: APIRequest, statusCode: Int?, duration: TimeInterval?, succeeded: Bool) {
        var snapshot = request
        // 历史里的 url 为空时不记录，避免噪音
        guard !snapshot.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        snapshot.name = requestNameForHistory(request)
        workspace.pushHistory(HistoryEntry(
            request: snapshot,
            statusCode: statusCode,
            duration: duration,
            succeeded: succeeded
        ))
        save()
    }

    private func requestNameForHistory(_ request: APIRequest) -> String {
        let trimmed = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != "未命名请求" { return trimmed }
        // 用 URL 的最后一段兜底命名
        if let url = URL(string: request.url), !url.lastPathComponent.isEmpty {
            return url.lastPathComponent
        }
        return request.url.isEmpty ? "未命名请求" : request.url
    }

    func clearResponse() {
        response = nil
        responseBodyText = ""
        errorMessage = nil
        unresolvedVariables = []
    }

    private func executor() -> RequestExecutor {
        if let cachedExecutor, cachedOptions == executorOptions {
            return cachedExecutor
        }
        // URLSession 强引用 delegate（即 executor 自身），不显式失效会泄漏。
        cachedExecutor?.invalidate()
        let fresh = RequestExecutor(options: executorOptions)
        cachedExecutor = fresh
        cachedOptions = executorOptions
        return fresh
    }

    // MARK: - 草稿操作

    func newRequest(inFolder folderID: UUID? = nil) {
        draft = APIRequest()
        editingNodeID = nil
        clearResponse()
        requestTab = .params
        selectedNodeID = nil
        defaultSaveFolderID = folderID
        save()
    }

    /// 打开一个已保存的请求到编辑器。
    func openSavedRequest(_ node: CollectionNode) {
        guard let saved = node.savedRequest else { return }
        draft = saved.request
        editingNodeID = node.id
        clearResponse()
        requestTab = .params
        selectedNodeID = node.id
    }

    /// 从历史恢复请求到编辑器（作为副本，不绑定已保存节点）。
    func restoreFromHistory(_ entry: HistoryEntry) {
        draft = entry.request
        editingNodeID = nil
        clearResponse()
        requestTab = .params
    }

    /// 保存为新请求。
    func saveAsNewRequest(name: String, intoFolder folderID: UUID?) {
        var request = draft
        let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名请求" : name
        request.name = finalName
        let node = CollectionNode.request(.init(name: finalName, request: request))
        workspace.collections.insert(node, intoFolder: folderID)
        editingNodeID = node.id
        draft = request
        save()
    }

    /// 覆盖当前正编辑的已保存请求。
    func overwriteCurrentRequest() {
        guard let id = editingNodeID else { return }
        overwriteSavedRequest(id: id, with: draft)
    }

    /// 用给定请求覆盖指定的已保存节点（原地替换，保留位置与 id）。
    func overwriteSavedRequest(id: UUID, with request: APIRequest) {
        var updated = request
        if let node = workspace.collections.findNode(id: id),
           let saved = node.savedRequest {
            updated.name = saved.name
        }
        guard workspace.collections.replaceSavedRequest(id: id, with: updated) else { return }
        if editingNodeID == id { draft = updated }
        save()
    }

    // MARK: - 集合操作

    func newFolder(name: String, inFolder folderID: UUID?) {
        let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "新建文件夹" : name
        let folder = CollectionNode.folder(.init(name: finalName))
        workspace.collections.insert(folder, intoFolder: folderID)
        save()
    }

    func renameNode(id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard workspace.collections.renameNode(id: id, to: trimmed) else { return }
        if editingNodeID == id {
            draft.name = trimmed
        }
        save()
    }

    func deleteNode(id: UUID) {
        guard workspace.collections.removeNode(id: id) else { return }
        // 被删的可能是「正在编辑请求」所在的文件夹。删除后若 editingNodeID 已不在树里，
        // 必须清掉——否则 ⌘S 会静默无效（overwriteCurrentRequest 找不到节点直接 return）。
        if let editing = editingNodeID, workspace.collections.findNode(id: editing) == nil {
            editingNodeID = nil
        }
        if let selected = selectedNodeID, workspace.collections.findNode(id: selected) == nil {
            selectedNodeID = nil
        }
        save()
    }

    func clearHistory() {
        workspace.history.removeAll()
        save()
    }

    func deleteHistoryEntry(id: UUID) {
        workspace.history.removeAll { $0.id == id }
        save()
    }

    // MARK: - 保存动作（工具栏「保存」）

    /// 可选的文件夹列表（含层级路径）。
    var folderOptions: [(id: UUID, path: String)] {
        workspace.collections.folderPaths()
    }

    /// 点「保存」：已在集合中则原地覆盖，否则弹窗命名。
    func beginSave() {
        if editingNodeID != nil {
            overwriteCurrentRequest()
        } else {
            saveSheetName = suggestedName()
            saveSheetFolderID = defaultSaveFolderID
            showSaveSheet = true
        }
    }

    /// 弹窗确认：保存为新请求。
    func commitSaveSheet() {
        saveAsNewRequest(name: saveSheetName, intoFolder: saveSheetFolderID)
        showSaveSheet = false
    }

    /// 根据 URL 推测一个默认名称。
    private func suggestedName() -> String {
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != "未命名请求" { return trimmed }
        if let url = URL(string: draft.url), !url.lastPathComponent.isEmpty {
            return url.lastPathComponent
        }
        return "未命名请求"
    }

    // MARK: - 环境操作

    /// 供环境编辑界面直接双向绑定的 Binding。
    func bindingForEnvironment(id: UUID) -> Binding<APIEnvironment> {
        Binding(
            get: { [weak self] in
                self?.workspace.environments.first { $0.id == id } ?? APIEnvironment(id: id, name: "")
            },
            set: { [weak self] updated in
                self?.updateEnvironment(updated)
            }
        )
    }

    @discardableResult
    func addEnvironment(name: String = "新环境") -> UUID {
        let environment = APIEnvironment(name: name)
        workspace.environments.append(environment)
        if workspace.activeEnvironmentID == nil {
            workspace.activeEnvironmentID = environment.id
        }
        save()
        return environment.id
    }

    func updateEnvironment(_ environment: APIEnvironment) {
        guard let index = workspace.environments.firstIndex(where: { $0.id == environment.id }) else { return }
        workspace.environments[index] = environment
        save()
    }

    func deleteEnvironment(id: UUID) {
        workspace.environments.removeAll { $0.id == id }
        if workspace.activeEnvironmentID == id {
            workspace.activeEnvironmentID = workspace.environments.first?.id
        }
        save()
    }

    func selectEnvironment(id: UUID?) {
        workspace.activeEnvironmentID = id
        save()
    }

    func renameEnvironment(id: UUID, to name: String) {
        guard let index = workspace.environments.firstIndex(where: { $0.id == id }) else { return }
        workspace.environments[index].name = name
        save()
    }

    // MARK: - 导入 / 导出

    /// 导入 Postman / ApiPost 导出的 Collection v2.1。
    @discardableResult
    func importPostmanCollection(data: Data) throws -> PostmanCodec.ImportResult {
        let result = try PostmanCodec.decode(data)
        // 包一层同名文件夹。两个作用:
        // 1. 多次导入不同集合时，顶层不会混在一起无法区分；
        // 2. 与导出侧对齐——导出时「顶层只有一个文件夹」会被当作集合本身，往返后结构不变。
        let wrapper = CollectionNode.folder(.init(name: result.collectionName, children: result.nodes))
        workspace.collections.append(wrapper)
        if let environment = result.environment {
            workspace.environments.append(environment)
            if workspace.activeEnvironmentID == nil {
                workspace.activeEnvironmentID = environment.id
            }
        }
        save()
        return result
    }

    /// 导出全部集合为 Postman Collection v2.1。
    func postmanExportData() throws -> Data {
        try PostmanCodec.encode(collections: workspace.collections, environment: activeEnvironment)
    }

    // MARK: - 设置

    /// 供设置界面双向绑定。
    func bindingForSettings() -> Binding<AppSettings> {
        Binding(
            get: { [weak self] in self?.workspace.settings ?? AppSettings() },
            set: { [weak self] in self?.updateSettings($0) }
        )
    }

    func updateSettings(_ settings: AppSettings) {
        workspace.settings = settings
        save()
    }

    // MARK: - 保存

    /// 记录当前草稿并防抖落盘。
    func save() {
        workspace.draft = draft
        persistence.scheduleSave(workspace)
    }

    /// 立即落盘（退出前）。
    func saveImmediately() {
        workspace.draft = draft
        persistence.saveNow(workspace)
    }
}
