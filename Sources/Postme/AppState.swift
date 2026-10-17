import SwiftUI
import AppKit
import Observation

/// 请求编辑区的分页。
enum RequestTab: String, CaseIterable, Identifiable {
    case params, headers, body
    var id: String { rawValue }

    func title(_ l10n: Localizer) -> String {
        switch self {
        case .params: return l10n(.requestTabParams)
        case .headers: return l10n(.requestTabHeaders)
        case .body: return l10n(.requestTabBody)
        }
    }
}

/// 响应区的分页。
enum ResponseTab: String, CaseIterable, Identifiable {
    case body, headers, timing
    var id: String { rawValue }

    func title(_ l10n: Localizer) -> String {
        switch self {
        case .body: return l10n(.responseTabBody)
        case .headers: return l10n(.responseTabHeaders)
        case .timing: return l10n(.responseTabTiming)
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
    ///
    /// `save()` 会把它同步到 `workspace.draftNodeID`：归属必须和草稿一起落盘，
    /// 否则重启后草稿还在、归属丢了，⌘S 会把它当成新请求再存一份。
    var editingNodeID: UUID?

    /// 编辑器草稿的基线：最近一次「载入/保存」时的内容。
    /// `draft != draftBaseline` 即表示有未保存修改——切换请求前必须问清楚，
    /// 否则 `draft = saved.request` 会静默抹掉用户刚敲进去的内容。
    private var draftBaseline: APIRequest = APIRequest()

    /// 是否有未保存的修改。
    var isDraftDirty: Bool { draft != draftBaseline }

    /// 切换请求时若草稿是脏的，挂起待确认的动作。
    enum PendingDraftAction: Equatable {
        /// 切到某个已保存请求
        case openNode(UUID)
        /// 从某条历史恢复
        case restoreHistory(HistoryEntry)
        /// 新建请求
        case newRequest(folderID: UUID?)
    }

    private(set) var pendingDraftAction: PendingDraftAction?
    /// 需要用户先决定「保存 / 放弃 / 取消」。
    var showDraftConflict: Bool = false
    /// 「保存并继续」选了但当前草稿还没归属节点时，先走保存弹窗，保存完成后再执行挂起动作。
    private var switchAfterSave = false

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

    /// 「保存到项目」弹窗状态。
    var showSaveSheet: Bool = false
    var saveSheetName: String = ""
    /// 保存目标项目。打开弹窗时默认当前项目。
    var saveSheetProjectID: UUID? {
        didSet {
            // 换项目后，旧项目里的文件夹在新项目里不存在 → 目标会静默落空。
            guard saveSheetProjectID != oldValue, let folder = saveSheetFolderID else { return }
            if workspace.projects.first(where: { $0.id == saveSheetProjectID })?
                .children.findNode(id: folder) == nil {
                saveSheetFolderID = nil
            }
        }
    }
    /// 保存目标文件夹（属于 `saveSheetProjectID`；nil 表示项目根）。
    var saveSheetFolderID: UUID?
    /// 新建请求时的默认保存目标文件夹（右键「在此新建请求」用）。
    var defaultSaveFolderID: UUID?

    // MARK: - 私有

    private var cachedExecutor: RequestExecutor?
    private var cachedOptions: RequestExecutorOptions?

    // MARK: - 初始化

    convenience init() {
        self.init(persistence: PersistenceService())
    }

    /// 可注入持久化服务的初始化，供测试用独立目录构造实例。
    ///
    /// `languageOverride` 只在测试里用：在 `ensureActiveProject()` **之前**写进 settings，
    /// 让断言中文默认名的用例不依赖宿主系统语言。生产路径传 nil，行为不变。
    init(persistence: PersistenceService, languageOverride: AppLanguage? = nil) {
        var loaded = persistence.load()
        if let languageOverride {
            loaded.settings.language = languageOverride
        }
        self.persistence = persistence
        self.workspace = loaded
        self.draft = loaded.draft ?? APIRequest()
        // 上次退出时恢复的草稿就是基线：它是"已落盘的内容"，不算未保存修改。
        self.draftBaseline = self.draft

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

        // 「至少一个项目 + 当前项目有效」的生命周期不变量：
        // 全新工作区、旧文件迁移出 0 个项目、activeProjectID 悬空，都在这里兜底。
        // 只改内存不落盘——下一次 save() 会自然带上。
        ensureActiveProject()

        // 草稿归属随草稿一起恢复。不恢复的话，重启后编辑器里明明还是同一条请求，
        // ⌘S 却当成新请求弹窗——每重启一次就多一条重复。
        if loaded.draft != nil,
           let id = loaded.draftNodeID,
           activeProject?.children.findNode(id: id)?.savedRequest != nil {
            editingNodeID = id
            selectedNodeID = id
        }
    }

    // MARK: - 语言

    /// 当前生效语言：settings 里选了就用它，没选（nil）跟随系统。
    var effectiveLanguage: AppLanguage { workspace.settings.language ?? .systemDefault }

    /// 当前语言的取词器。视图一律 `app.t(.key)`，服务层接收 `Localizer`。
    var t: Localizer { Localizer(language: effectiveLanguage) }

    /// 切换界面语言（nil = 跟随系统）。
    ///
    /// **为什么立即落盘**：语言是用户显式选择，重启后必须保持；防抖窗口内的崩溃
    /// 不该把它丢掉。
    ///
    /// **为什么重算 `responseBodyText`**：它是收到响应时算好的字符串，里面含截断说明；
    /// 不重算的话切到英文后那段说明仍是中文。
    ///
    /// **为什么清空 `errorMessage` / `alertMessage`**：二者是已生成的字符串，无法就地重译；
    /// 留着旧语言的文本比清掉更误导。
    func setLanguage(_ language: AppLanguage?) {
        workspace.settings.language = language
        refreshResponseBodyText()
        errorMessage = nil
        alertMessage = nil
        saveImmediately()
    }

    // MARK: - 便捷访问

    var projects: [Project] { workspace.projects }
    var history: [HistoryEntry] { workspace.history }
    var environments: [APIEnvironment] { workspace.environments }

    /// 当前项目。由 `ensureActiveProject()` 保证非 nil（防御性 Optional）。
    var activeProject: Project? {
        workspace.projects.first { $0.id == workspace.activeProjectID }
    }

    /// 当前项目在数组中的下标（节点操作的写入口）。
    private var activeProjectIndex: Int? {
        workspace.projects.firstIndex(where: { $0.id == workspace.activeProjectID })
    }

    var activeEnvironment: APIEnvironment? {
        guard let id = workspace.activeEnvironmentID else { return nil }
        return workspace.environments.first { $0.id == id }
    }

    /// 搜索命中当前项目内的请求（扁平列表）。
    var searchResults: [CollectionNode] {
        activeProject?.children.requestsMatching(searchKeyword) ?? []
    }

    var isSearching: Bool {
        !searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var executorOptions: RequestExecutorOptions { workspace.settings.executorOptions }

    /// 当前编辑请求做变量替换后的副本。
    ///
    /// 预览与发送**共用这一个入口**：否则「最终 URL」会在两处出现分歧
    /// （曾经就发生过——预览没做替换，`{{baseUrl}}` 被 URLComponents 编码成
    /// `%7B%7BbaseUrl%7D%7D`，而实发的是替换后的地址，用户会以为 URL 被弄坏了）。
    private func resolveDraft() -> (request: APIRequest, unresolved: [String]) {
        VariableResolver.resolve(draft, variables: activeEnvironment?.variableMap ?? [:])
    }

    /// 预览用：变量替换后的请求。
    var resolvedDraft: APIRequest { resolveDraft().request }

    // MARK: - 发送

    func send() async {
        guard !isSending else { return }
        isSending = true
        errorMessage = nil
        defer { isSending = false }

        let resolved = resolveDraft()
        unresolvedVariables = resolved.unresolved
        let outgoing = resolved.request

        do {
            let result = try await executor().send(outgoing)
            response = result
            refreshResponseBodyText()
            responseTab = .body
            // 历史记录保留**未替换**的模板（含 {{var}}），便于复用且不落盘明文密钥
            recordHistory(for: draft, statusCode: result.statusCode, duration: result.timing.total, succeeded: result.isSuccess)
        } catch RequestFailure.cancelled {
            // 用户主动取消：不是失败。清掉在途状态即可，不报错、不记历史。
            response = nil
            responseBodyText = ""
            errorMessage = nil
        } catch {
            response = nil
            responseBodyText = ""
            errorMessage = localizedErrorMessage(for: error)
            recordHistory(for: draft, statusCode: nil, duration: nil, succeeded: false)
        }
    }

    /// 已知错误按当前语言取文案；未知错误保留系统的 `localizedDescription`
    /// （那是系统语言，硬翻成应用语言反而更怪）。
    private func localizedErrorMessage(for error: Error) -> String {
        if let failure = error as? RequestFailure {
            return failure.message(t)
        }
        return error.localizedDescription
    }

    /// 按当前语言重算并缓存响应体展示文本。
    ///
    /// `send()` 收到响应后调用；`setLanguage` 切换语言后也要调用——
    /// 缓存的是成品字符串，含截断说明，不重算就会残留旧语言。
    private func refreshResponseBodyText() {
        responseBodyText = response?.displayBodyText(l10n: t) ?? ""
    }

    /// 取消在飞请求（发送按钮 / ⌘.）。
    func cancelSend() {
        guard isSending else { return }
        executor().cancel()
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

    /// 内部可见：与 `suggestedName()` 同构，测试成对覆盖。
    func requestNameForHistory(_ request: APIRequest) -> String {
        let trimmed = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !Self.isPlaceholderRequestName(trimmed) { return trimmed }
        // 用 URL 的最后一段兜底命名
        if let url = URL(string: request.url), !url.lastPathComponent.isEmpty {
            return url.lastPathComponent
        }
        return request.url.isEmpty ? t(.untitledRequest) : request.url
    }

    /// 名字是否是「未命名请求」这一类的占位名。
    ///
    /// **必须两种语言都认**：默认名是创建时按当时语言落盘的，用户切到英文后，
    /// 中文界面创建的草稿仍叫「未命名请求」。只认当前语言的字面量，会把占位名当成
    /// 用户起的名字，历史里就出现一堆「未命名请求」而不回退到 URL。
    static func isPlaceholderRequestName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == Localizer.zhHans(.untitledRequest)
            || trimmed == Localizer.en(.untitledRequest)
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

    /// 切换到新草稿的唯一入口：负责脏检查、基线重置与落盘。
    ///
    /// **为什么必须集中**：原先 `openSavedRequest` / `newRequest` / `restoreFromHistory`
    /// 各自直接写 `draft`，谁都没检查未保存修改，用户敲了一半再点侧栏就全丢了。
    private func adoptDraft(_ request: APIRequest, editingNodeID: UUID?, selectedNodeID: UUID?) {
        draft = request
        draftBaseline = request
        self.editingNodeID = editingNodeID
        self.selectedNodeID = selectedNodeID
        clearResponse()
        requestTab = .params
        persistDraft()
    }

    /// 把当前草稿写进 workspace 并防抖落盘。
    /// 草稿此前只在退出时落盘，异常退出（崩溃 / 强杀）就会丢掉整个编辑中的请求。
    func persistDraft() {
        save()
    }

    /// 需要用户先决定草稿去留时，记下待执行的动作并弹提示。
    private func deferAction(_ action: PendingDraftAction, fallbackSelection: UUID?) {
        // **已经在等用户决定时，不再接受新的挂起动作。**
        //
        // 下面回滚 selectedNodeID 会再触发一次侧栏的 onChange → openSavedRequest，
        // 而草稿此刻仍是脏的，于是会第二次调用本函数。若不拦住，第二次会用
        // "回滚后的节点"（也就是当前正在编辑的那个）覆盖掉用户真正点击的目标——
        // 用户选「保存并继续 / 放弃修改」后会停在原地，永远到不了想去的节点。
        // 这恰好是 D3 要消灭的那类"静默偏离用户意图"。
        guard pendingDraftAction == nil else { return }

        pendingDraftAction = action
        showDraftConflict = true
        // 侧栏的选中项已经被用户点了，先回滚到当前编辑的节点，避免高亮与编辑器不一致。
        // 回滚触发的 onChange 由上面的守卫吞掉。
        selectedNodeID = fallbackSelection
    }

    /// 侧栏选中项变化的**唯一入口**（`SidebarView.onChange` 调用）。
    ///
    /// 放在这里而不是视图里，是为了让"回滚选中项会再触发一次 onChange"这条真实链路
    /// 可以被测试直接驱动——否则测试只能绕过 SwiftUI 直调 `openSavedRequest`，
    /// 正是这一点让 B1 这类重入缺陷在单测里完全隐形。
    func handleSidebarSelection(_ id: UUID?) {
        // 侧栏只渲染当前项目的目录树，选中的节点按构造属于当前项目。
        guard let id,
              let node = activeProject?.children.findNode(id: id),
              !node.isFolder
        else { return }
        openSavedRequest(node)
    }

    func newRequest(inFolder folderID: UUID? = nil) {
        if isDraftDirty {
            deferAction(.newRequest(folderID: folderID), fallbackSelection: editingNodeID)
            return
        }
        defaultSaveFolderID = folderID
        adoptDraft(APIRequest(), editingNodeID: nil, selectedNodeID: nil)
    }

    /// 打开一个已保存的请求到编辑器。
    func openSavedRequest(_ node: CollectionNode) {
        guard let saved = node.savedRequest else { return }
        if isDraftDirty {
            deferAction(.openNode(node.id), fallbackSelection: editingNodeID)
            return
        }
        adoptDraft(saved.request, editingNodeID: node.id, selectedNodeID: node.id)
    }

    /// 从历史恢复请求到编辑器（作为副本，不绑定已保存节点）。
    func restoreFromHistory(_ entry: HistoryEntry) {
        if isDraftDirty {
            deferAction(.restoreHistory(entry), fallbackSelection: editingNodeID)
            return
        }
        adoptDraft(entry.request, editingNodeID: nil, selectedNodeID: nil)
    }

    // MARK: - 草稿冲突的处理

    /// 冲突提示里的「保存并继续」。
    ///
    /// 已绑定节点的草稿直接覆盖保存；没有归属的草稿需要先命名，于是挂起动作会
    /// 等保存弹窗提交后由 `commitSaveSheet` 继续执行。
    func saveDraftAndContinue() {
        guard let action = pendingDraftAction else {
            showDraftConflict = false
            return
        }
        showDraftConflict = false
        pendingDraftAction = nil

        if overwriteCurrentRequest() {
            perform(action)
        } else {
            switchAfterSave = true
            pendingDraftAction = action
            presentSaveSheet()
        }
    }

    /// 冲突提示里的「放弃修改」。
    func discardDraftAndContinue() {
        guard let action = pendingDraftAction else {
            showDraftConflict = false
            return
        }
        showDraftConflict = false
        pendingDraftAction = nil
        perform(action)
    }

    /// 取消挂起的草稿冲突：冲突提示里的「取消」，也用于侧栏内容整体更换时
    /// （切项目 / 删项目 / 导入）作废挂起动作——那些动作针对的节点刚被换掉，
    /// 继续挂着只会让「保存并继续」打开一个用户看不见的节点。草稿本身不动。
    func cancelDraftConflict() {
        pendingDraftAction = nil
        showDraftConflict = false
        switchAfterSave = false
    }

    /// 保存弹窗被取消。
    func cancelSaveSheet() {
        showSaveSheet = false
        switchAfterSave = false
        pendingDraftAction = nil
    }

    /// 执行先前挂起的切换动作。
    private func perform(_ action: PendingDraftAction) {
        switch action {
        case .newRequest(let folderID):
            defaultSaveFolderID = folderID
            adoptDraft(APIRequest(), editingNodeID: nil, selectedNodeID: nil)

        case .openNode(let id):
            // 跨项目查找：挂起期间极端情况下项目可能已被删/换，找不到就安静不动，
            // 绝不去打开一个用户看不见的节点。
            if let node = workspace.projects.findNode(id: id), let saved = node.savedRequest {
                adoptDraft(saved.request, editingNodeID: node.id, selectedNodeID: node.id)
            }

        case .restoreHistory(let entry):
            adoptDraft(entry.request, editingNodeID: nil, selectedNodeID: nil)
        }
    }

    /// 保存为新请求。
    ///
    /// `projectID` 为 nil 时落到当前项目；指定其他项目时会把当前项目切过去——
    /// 否则新请求在侧栏里根本看不见，`selectedNodeID` 还会悬空。
    func saveAsNewRequest(name: String, intoProject projectID: UUID? = nil, intoFolder folderID: UUID?) {
        let targetID = projectID.flatMap { id in
            workspace.projects.contains { $0.id == id } ? id : nil
        } ?? workspace.activeProjectID
        guard let index = workspace.projects.firstIndex(where: { $0.id == targetID }) else { return }

        var request = draft
        let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? t(.untitledRequest) : name
        request.name = finalName
        let node = CollectionNode.request(.init(name: finalName, request: request))

        workspace.activeProjectID = targetID
        // 换项目后，指向旧项目的保存目标 / 选中项都要作废，免得插进不存在的文件夹。
        dropStaleNodeReferences()
        insert(node, intoProject: index, intoFolder: folderID)
        editingNodeID = node.id
        selectedNodeID = node.id
        draft = request
        // 保存后草稿就是"已落盘内容"，基线随之推进。
        draftBaseline = request
        save()
    }

    /// 覆盖当前正编辑的已保存请求。返回是否真的写入了（归属失效时为 false）。
    @discardableResult
    func overwriteCurrentRequest() -> Bool {
        guard let id = editingNodeID else { return false }
        return overwriteSavedRequest(id: id, with: draft)
    }

    /// 用给定请求覆盖指定的已保存节点（原地替换，保留位置与 id）。
    ///
    /// 跨项目查找：编辑归属理论上总在当前项目里，但归属是持久化的，
    /// 一旦它指向别的项目，只在当前项目里找会让 ⌘S 静默失效。
    @discardableResult
    func overwriteSavedRequest(id: UUID, with request: APIRequest) -> Bool {
        guard let index = workspace.projects.firstIndex(where: {
            $0.children.findNode(id: id)?.savedRequest != nil
        }) else { return false }
        var updated = request
        if let saved = workspace.projects[index].children.findNode(id: id)?.savedRequest {
            updated.name = saved.name
        }
        guard workspace.projects[index].children.replaceSavedRequest(id: id, with: updated) else { return false }
        if editingNodeID == id {
            draft = updated
            draftBaseline = updated
        }
        save()
        return true
    }

    // MARK: - 目录操作（当前项目内）

    func newFolder(name: String, inFolder folderID: UUID?) {
        let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? t(.sidebarNewFolder) : name
        let folder = CollectionNode.folder(.init(name: finalName))
        guard let index = activeProjectIndex else { return }
        insert(folder, intoProject: index, intoFolder: folderID)
        save()
    }

    func renameNode(id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = activeProjectIndex,
              workspace.projects[index].children.renameNode(id: id, to: trimmed) else { return }
        if editingNodeID == id {
            draft.name = trimmed
        }
        save()
    }

    func deleteNode(id: UUID) {
        guard let index = activeProjectIndex,
              workspace.projects[index].children.removeNode(id: id) else { return }
        // 被删的可能是「正在编辑请求」所在的文件夹。删除后若 editingNodeID 已不在树里，
        // 必须清掉——否则 ⌘S 会静默无效（overwriteCurrentRequest 找不到节点直接 return）。
        if let editing = editingNodeID, workspace.projects.findNode(id: editing) == nil {
            editingNodeID = nil
        }
        if let selected = selectedNodeID, workspace.projects.findNode(id: selected) == nil {
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

    /// 保存弹窗里所选项目的文件夹列表（含层级路径）。
    var saveSheetFolderOptions: [(id: UUID, path: String)] {
        let id = saveSheetProjectID ?? workspace.activeProjectID
        return workspace.projects.first { $0.id == id }?.children.folderPaths() ?? []
    }

    /// 点「保存」：已绑定当前项目中的节点则原地覆盖，否则弹窗命名。
    ///
    /// 归属失效（节点被删、或指向别的项目）时不能静默不动，也不能覆盖到别处：
    /// 退回弹窗让用户明确落点。
    func beginSave() {
        if editingNodeID != nil, overwriteCurrentRequest() {
            return
        }
        presentSaveSheet()
    }

    /// 打开保存弹窗，目标项目默认当前项目。
    private func presentSaveSheet() {
        saveSheetName = suggestedName()
        saveSheetProjectID = workspace.activeProjectID
        saveSheetFolderID = defaultSaveFolderID
        showSaveSheet = true
    }

    /// 弹窗确认：保存为新请求。
    func commitSaveSheet() {
        saveAsNewRequest(
            name: saveSheetName,
            intoProject: saveSheetProjectID,
            intoFolder: saveSheetFolderID
        )
        showSaveSheet = false

        // 「保存并继续」的路径：草稿已落盘，接着执行先前挂起的切换动作。
        if switchAfterSave, let action = pendingDraftAction {
            switchAfterSave = false
            pendingDraftAction = nil
            perform(action)
        }
    }

    /// 根据 URL 推测一个默认名称。占位名判定与 `requestNameForHistory` 同构（双语）。
    /// 内部可见：占位名判定是语义陷阱，测试直接覆盖（见 LocalizationTests 第 8 项）。
    func suggestedName() -> String {
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !Self.isPlaceholderRequestName(trimmed) { return trimmed }
        if let url = URL(string: draft.url), !url.lastPathComponent.isEmpty {
            return url.lastPathComponent
        }
        return t(.untitledRequest)
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
    func addEnvironment(name: String? = nil) -> UUID {
        let environment = APIEnvironment(name: name ?? t(.newEnvironmentDefaultName))
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
    ///
    /// **每个集合成为一个同名项目**（集合 ≈ 项目）：不与现有内容混合，
    /// 重复导入就是多个可删的项目，与导出侧（导出当前项目）对称。
    @discardableResult
    func importPostmanCollection(data: Data) throws -> PostmanCodec.ImportResult {
        let result = try PostmanCodec.decode(data, l10n: t)
        // 导入会整体更换侧栏内容：挂起的草稿切换动作与陈旧的节点引用一并作废
        // （否则「保存并继续」会去打开一个刚被替换掉的节点）。
        cancelDraftConflict()
        let project = Project(name: result.collectionName, children: result.nodes)
        workspace.projects.append(project)
        workspace.activeProjectID = project.id
        dropStaleNodeReferences()
        if let environment = result.environment {
            workspace.environments.append(environment)
            if workspace.activeEnvironmentID == nil {
                workspace.activeEnvironmentID = environment.id
            }
        }
        save()
        return result
    }

    // MARK: - cURL 导入

    /// cURL 导入面板是否展示。
    var showCurlImport: Bool = false

    /// cURL 请求导入到哪里。
    enum CurlImportTarget: Equatable {
        /// 新建项目（名字由调用方给出，空则兜底）
        case newProject(name: String)
        /// 并入当前项目的根目录
        case currentProject
    }

    /// 把解析好的 curl 请求落进工作区，返回实际导入的条数。
    ///
    /// 与 Postman 导入的差别：curl 命令没有"集合"这一层，所以既能新建项目，
    /// 也能直接并进当前项目（前者对应「从一段命令起个新项目」，后者对应
    /// 「往手头的项目里补一个请求」）。两条路径都要走同一套收尾：
    /// 取消挂起的草稿冲突、清理悬空节点引用。
    @discardableResult
    func importCurlRequests(_ requests: [APIRequest], target: CurlImportTarget) -> Int {
        guard !requests.isEmpty else { return 0 }

        let nodes = requests.map { request -> CollectionNode in
            let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
            var stored = request
            stored.name = name.isEmpty ? t(.curlRequestDefaultName) : name
            return .request(.init(name: stored.name, request: stored))
        }

        switch target {
        case .newProject(let name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let project = Project(name: trimmed.isEmpty ? t(.curlImportDefaultName) : trimmed, children: nodes)
            workspace.projects.append(project)
            workspace.activeProjectID = project.id
            // 只有换项目才会让侧栏内容整体更换，此时才需要取消挂起的草稿冲突
            cancelDraftConflict()

        case .currentProject:
            guard let index = activeProjectIndex else { return 0 }
            workspace.projects[index].children.append(contentsOf: nodes)
        }

        dropStaleNodeReferences()
        save()
        return nodes.count
    }

    /// 导出当前项目为 Postman Collection v2.1（其他项目不会被导出）。
    func postmanExportData() throws -> Data {
        guard let project = activeProject else { throw PostmanCodec.CodecError.noProject }
        return try PostmanCodec.encode(project: project, environment: activeEnvironment)
    }

    // MARK: - 项目操作

    /// 保证「至少一个项目 + 当前项目有效」的不变量。
    /// 在 `init` 调用；`deleteProject` 有「至少保留一个」的守卫，不变量不会被打穿。
    private func ensureActiveProject() {
        if workspace.projects.isEmpty {
            let project = Project(name: t(.defaultProjectName))
            workspace.projects.append(project)
            workspace.activeProjectID = project.id
        } else if workspace.activeProjectID == nil
            || !workspace.projects.contains(where: { $0.id == workspace.activeProjectID }) {
            workspace.activeProjectID = workspace.projects.first?.id
        }
    }

    /// 侧栏内容整体更换（切项目 / 删项目 / 导入）后，清掉指向「新当前项目里不存在」的瞬态引用。
    ///
    /// 不清的后果是静默失效：`editingNodeID` 悬空 → ⌘S 静默无效；
    /// `defaultSaveFolderID` / `saveSheetFolderID` 悬空 → 保存弹窗把节点
    /// 插进一个不存在的文件夹（`insert` 找不到目标只返回 false）。
    private func dropStaleNodeReferences() {
        if let editing = editingNodeID, activeProject?.children.findNode(id: editing) == nil {
            editingNodeID = nil
        }
        if let selected = selectedNodeID, activeProject?.children.findNode(id: selected) == nil {
            selectedNodeID = nil
        }
        if let folder = defaultSaveFolderID, activeProject?.children.findNode(id: folder) == nil {
            defaultSaveFolderID = nil
        }
        // 弹窗的文件夹属于弹窗选中的项目，不是「当前项目」。
        let sheetProjectID = saveSheetProjectID ?? workspace.activeProjectID
        if let folder = saveSheetFolderID,
           workspace.projects.first(where: { $0.id == sheetProjectID })?
               .children.findNode(id: folder) == nil {
            saveSheetFolderID = nil
        }
    }

    /// 切换当前项目。侧栏内容随之整体更换，故清理瞬态引用并取消挂起的草稿冲突
    /// （草稿本身不动——它留在编辑器里，只是不再绑定旧项目的节点）。
    func selectProject(id: UUID) {
        guard id != workspace.activeProjectID,
              workspace.projects.contains(where: { $0.id == id }) else { return }
        workspace.activeProjectID = id
        dropStaleNodeReferences()
        cancelDraftConflict()
        save()
    }

    /// 新建项目并设为当前。空名兜底「新建项目」。
    @discardableResult
    func newProject(name: String) -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = Project(name: trimmed.isEmpty ? t(.newProjectDefaultName) : trimmed)
        workspace.projects.append(project)
        workspace.activeProjectID = project.id
        dropStaleNodeReferences()
        cancelDraftConflict()
        save()
        return project.id
    }

    func renameProject(id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard workspace.projects.renameProject(id: id, to: trimmed) else { return }
        save()
    }

    /// 删除项目（含其全部目录和请求）。
    ///
    /// 至少保留一个项目——「没有项目」会让新建/保存都失去落点，
    /// 空态对调试工具没有意义；UI 层也会在只剩一个时禁用删除。
    func deleteProject(id: UUID) {
        guard workspace.projects.count > 1,
              workspace.projects.removeProject(id: id) else { return }
        if workspace.activeProjectID == id {
            workspace.activeProjectID = workspace.projects.first?.id
        }
        // 正在编辑/选中的节点可能就在被删的项目里
        if let editing = editingNodeID, workspace.projects.findNode(id: editing) == nil {
            editingNodeID = nil
        }
        if let selected = selectedNodeID, workspace.projects.findNode(id: selected) == nil {
            selectedNodeID = nil
        }
        if let folder = defaultSaveFolderID, workspace.projects.findNode(id: folder) == nil {
            defaultSaveFolderID = nil
        }
        if let folder = saveSheetFolderID, workspace.projects.findNode(id: folder) == nil {
            saveSheetFolderID = nil
        }
        cancelDraftConflict()
        save()
    }

    /// 把当前项目的顶层文件夹提为独立项目（子节点原样成为新项目的 children）。
    ///
    /// 旧数据迁移后用户会想把原来的顶层文件夹整理成项目，这是唯一需要的方向；
    /// 通用的跨项目移动 / 拖拽 v1 明确不做。
    func promoteFolderToProject(id: UUID) {
        guard let index = activeProjectIndex,
              let folderIndex = workspace.projects[index].children.firstIndex(where: { $0.id == id }),
              case .folder(let folder) = workspace.projects[index].children[folderIndex] else { return }
        workspace.projects[index].children.remove(at: folderIndex)
        let project = Project(name: folder.name, children: folder.children)
        workspace.projects.append(project)
        workspace.activeProjectID = project.id
        dropStaleNodeReferences()
        cancelDraftConflict()
        save()
    }

    /// 向指定项目插入节点。`folderID` 为 nil 时追加到项目根。
    ///
    /// **兜底 append**：`insert` 找不到目标文件夹时只返回 false，
    /// 忽略返回值会让节点被静默吞掉、而 `editingNodeID` 却指向这个不存在的节点。
    private func insert(_ node: CollectionNode, intoProject index: Int, intoFolder folderID: UUID?) {
        guard workspace.projects.indices.contains(index) else { return }
        if !workspace.projects[index].children.insert(node, intoFolder: folderID) {
            workspace.projects[index].children.append(node)
        }
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
        workspace.draftNodeID = editingNodeID
        persistence.scheduleSave(workspace)
    }

    /// 立即落盘(退出前)。
    func saveImmediately() {
        workspace.draft = draft
        workspace.draftNodeID = editingNodeID
        persistence.saveNow(workspace)
    }
}
