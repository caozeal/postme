import SwiftUI
import AppKit
import Observation

// MARK: - 落盘问题的界面状态

enum SaveIssueKind: Equatable {
    case writeFailed([String])
    case conflict(ConflictReason)
}

/// 弹窗出现的场景，决定按钮组。
enum SaveIssueContext: Equatable {
    case toolbar
    case externalChange
    case exit
}

/// 界面状态存「键 + 参数」而不是生成好的字符串：切语言时 `setLanguage` 会清
/// `alertMessage`，存译文会让提示凭空消失；渲染时取词才能自动重译。
struct SaveIssue: Identifiable, Equatable {
    let id = UUID()
    var kind: SaveIssueKind
    var context: SaveIssueContext
    var titleKey: L10nKey
    var messageKey: L10nKey
    var arguments: [String]
    var attempts: Int = 1
}

/// 请求编辑区里的分页。
///
/// **声明顺序即界面上分段控件的顺序**（`CaseIterable` 的 `allCases` 按声明顺序），
/// 所以 Headers 写在 Params 前面：调试时先看/改头，再看 query。
///
/// 名字刻意避开 "Tab"：「页签」在本项目里专指 `EditorTab`（打开中的请求），
/// 这里的「分页」只是编辑区内部的分段控件。
enum RequestSection: String, CaseIterable, Identifiable, Codable {
    case headers, params, body, auth, cookies
    var id: String { rawValue }

    func title(_ l10n: Localizer) -> String {
        switch self {
        case .params: return l10n(.requestTabParams)
        case .headers: return l10n(.requestTabHeaders)
        case .body: return l10n(.requestTabBody)
        case .auth: return l10n(.requestTabAuth)
        case .cookies: return l10n(.requestTabCookies)
        }
    }
}

/// 响应区里的分页。
///
/// 声明顺序即分段控件的顺序：`body, llm, events, headers, timing`。
/// `.llm` / `.events` 只在 SSE 响应时出现（见 `AppState.availableResponseSections`）。
///
/// 「大模型输出」排在「事件」**前面**：调试 LLM 时它是主视图，事件是证据。
/// 但默认落点仍是 `.events`（用户要求「默认现在的就行」），见 `send()` / `applyFinished`。
enum ResponseSection: String, CaseIterable, Identifiable, Codable {
    case body, llm, events, headers, timing
    var id: String { rawValue }

    func title(_ l10n: Localizer) -> String {
        switch self {
        case .body: return l10n(.responseTabBody)
        case .llm: return l10n(.responseTabLLMOutput)
        case .events: return l10n(.responseTabEvents)
        case .headers: return l10n(.responseTabHeaders)
        case .timing: return l10n(.responseTabTiming)
        }
    }
}

/// 一条在飞流响应的归并器持有者。
///
/// `send()` 里归并器必须是 `var`（`consume` 会改状态），但用户可能在流式期间
/// 添删自定义路径、切换字段——那些操作发生在别的方法里。用引用类型把它挂在
/// AppState 上，这些操作才不需要排队等下一次请求。
@MainActor
final class LLMMergerBox {
    var merger = LLMStreamMerger()
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

    /// 响应示例的侧车存储（`examples.json`）。
    private let exampleStore: ResponseExampleStore

    /// 已保存的响应示例。按请求节点 id 归属；孤儿示例在载入时清理。
    private(set) var examples: [ResponseExample] = []

    /// 会话内 Cookie Jar。只在内存里，退出即清空。
    private(set) var cookieJar = CookieJar()

    /// 存储目录（设置界面展示用）。三个 JSON 文件都在这个目录里。
    var storagePath: String { persistence.storagePath }

    // MARK: - 页签（打开中的请求）

    /// 打开中的请求页签。**不变量：至少一个**——关闭最后一个页签会立刻补一个空页签，
    /// 否则 `activeTab` 没有可写对象，编辑器与响应区都无从渲染。
    private(set) var tabs: [EditorTab]

    /// 当前页签 id。恒指向 `tabs` 中的一项（`activeIndex` 兜底到第一项）。
    private(set) var activeTabID: UUID

    /// 当前页签在 `tabs` 中的下标。
    private var activeIndex: Int { tabs.firstIndex { $0.id == activeTabID } ?? 0 }

    /// 当前页签（快照副本）。
    var activeTab: EditorTab { tabs[activeIndex] }

    /// 修改当前页签的**唯一写入口**：下面的转发属性都走它，
    /// 保证「写的是哪一格」这件事只在一个地方发生。
    private func withActiveTab(_ mutate: (inout EditorTab) -> Void) {
        let index = activeIndex
        guard tabs.indices.contains(index) else { return }
        mutate(&tabs[index])
    }

    /// 当前页签的工作副本（编辑器双向绑定的入口）。
    var draft: APIRequest {
        get { activeTab.draft }
        set { withActiveTab { $0.draft = newValue } }
    }

    /// 当前页签绑定的已保存请求节点 id，用于「保存」覆盖。
    var editingNodeID: UUID? {
        get { activeTab.nodeID }
        set { withActiveTab { $0.nodeID = newValue } }
    }

    /// 当前页签是否有未保存的修改。
    var isDraftDirty: Bool { activeTab.isDirty }

    /// 请求编辑区的分页选择（每个页签各记各的）。
    var requestSection: RequestSection {
        get { activeTab.requestSection }
        set { withActiveTab { $0.requestSection = newValue } }
    }

    /// 响应区的分页选择（每个页签各记各的）。
    var responseSection: ResponseSection {
        get { activeTab.responseSection }
        set { withActiveTab { $0.responseSection = newValue } }
    }

    var response: APIResponse? {
        get { activeTab.response }
        set { withActiveTab { $0.response = newValue } }
    }

    /// 响应体展示文本（已美化/截断），收到响应时算一次并缓存。
    var responseBodyText: String { activeTab.responseBodyText }

    var isSending: Bool { activeTab.isSending }

    var errorMessage: String? {
        get { activeTab.errorMessage }
        set { withActiveTab { $0.errorMessage = newValue } }
    }

    /// 上一次发送中未能解析的变量名，用于界面提示。
    var unresolvedVariables: [String] { activeTab.unresolvedVariables }

    /// 上一次发送中未填写的路径参数名。
    var unresolvedPathParams: [String] { activeTab.unresolvedPathParams }

    // MARK: - 关闭页签的确认

    /// 待确认关闭的脏页签（用 id 而非下标：确认期间页签可能已被别处关掉）。
    private(set) var pendingCloseTabID: UUID?
    /// 需要用户先决定「保存并关闭 / 放弃修改 / 取消」。
    var showTabCloseConfirm: Bool = false
    /// 「保存并关闭」选了但该页签还没有归属节点：先走保存弹窗，提交后再关。
    private var closeAfterSave = false

    /// 批量关闭（关闭其他 / 关闭全部）待确认的页签。
    ///
    /// 批量场景逐个弹「保存并关闭」会变成连续点击，且未归属页签每个都要命名——
    /// 所以合成一次确认，只提供「丢弃修改并关闭 / 取消」。
    private(set) var pendingBatchCloseIDs: [UUID] = []
    var showBatchCloseConfirm: Bool = false

    /// 环境编辑弹窗是否展示。
    var showEnvironmentEditor: Bool = false

    /// 「清空历史」的确认框是否展示。清空不可撤销，且旧记录里有请求快照。
    var showClearHistoryConfirm: Bool = false

    /// 待确认切换的目标项目 id（确认框开着期间用它）。
    private(set) var pendingProjectActivationID: UUID?
    /// OpenAPI 导入的环境只在项目切换确认后激活。
    private var pendingImportEnvironmentID: UUID?
    /// 切换项目会重置编辑器：页签里有未保存的修改时，先让用户确认，
    /// 不能静默丢弃——和关页签、清历史是同一条纪律。
    var showProjectSwitchConfirm: Bool = false

    /// 一次性提示（导入/导出结果等）。
    var alertMessage: AlertMessage?

    struct AlertMessage: Identifiable {
        let id = UUID()
        var text: String
    }

    /// 未解决的落盘问题。只有成功落盘、或无脏数据时成功重载才清空。
    var saveIssue: SaveIssue?
    /// 弹窗展示开关：用户点「稍后」只收起弹窗，问题仍在工具栏常驻可见。
    var showSaveIssueAlert: Bool = false
    /// 退出决策的回传目标。由 ContentView.onAppear 注入；
    /// 不能用 `NSApp.delegate as? AppDelegate`（SwiftUI 装的是转发代理，转换会失败，
    /// 那样「取消 / 仍要退出」点下去 NSApp.reply 永远不调用，进程卡在退出待决）。
    weak var appDelegate: AppDelegate?
    /// 退出准备期间的结果回传不走常规状态机，由 prepareForTermination 自己裁定。
    private var isPreparingTermination = false

    // MARK: - 侧栏态

    var searchKeyword: String = ""
    var selectedNodeID: UUID?

    /// ⌘F 触发搜索框聚焦（自增即触发，侧栏 onChange 监听）。
    var focusSearchTick: Int = 0

    func requestSearchFocus() {
        focusSearchTick += 1
    }

    // MARK: - 响应查找 / 示例

    /// 「在响应中查找」的触发序号（菜单 ⌥⌘F 用）。
    var responseFindTick: Int = 0

    func requestResponseFind() {
        guard response != nil || !activeTab.stream.rawText.isEmpty else { return }
        responseSection = .body
        responseFindTick += 1
    }

    /// 保存示例的命名弹窗。
    var showSaveExampleSheet = false
    var saveExampleName = ""

    /// 正在查看的示例（非 nil 时弹只读窗口）。
    var viewingExample: ResponseExample?

    /// 每个请求最多保留的示例数，超出时丢最旧的。
    static let exampleLimitPerRequest = 20

    /// 当前页签对应的示例，最新在前。
    var examplesForActiveTab: [ResponseExample] {
        guard let nodeID = editingNodeID else { return [] }
        return examples
            .filter { $0.requestNodeID == nodeID }
            .sorted { $0.savedAt > $1.savedAt }
    }

    /// 只有「已归属某个已保存请求」且有响应时才能存示例。
    var canSaveResponseExample: Bool {
        response != nil && editingNodeID != nil
    }

    func beginSaveResponseExample() {
        guard canSaveResponseExample else { return }
        saveExampleName = defaultExampleName
        showSaveExampleSheet = true
    }

    func cancelSaveResponseExample() {
        showSaveExampleSheet = false
        saveExampleName = ""
    }

    /// 确认保存。正文超过上限时截断并标记，不静默丢。
    func commitSaveResponseExample() {
        guard let response, let nodeID = editingNodeID,
              let example = ResponseExample(
                  response: response,
                  requestNodeID: nodeID,
                  name: saveExampleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      ? defaultExampleName
                      : saveExampleName.trimmingCharacters(in: .whitespacesAndNewlines)
              ) else {
            showSaveExampleSheet = false
            return
        }

        examples.append(example)

        // 每个请求只留最新的 N 条；示例正文可能很大，不能让单请求无限增长。
        let forNode = examples
            .filter { $0.requestNodeID == nodeID }
            .sorted { $0.savedAt > $1.savedAt }
        if forNode.count > Self.exampleLimitPerRequest {
            let keep = Set(forNode.prefix(Self.exampleLimitPerRequest).map(\.id))
            examples.removeAll { $0.requestNodeID == nodeID && !keep.contains($0.id) }
        }

        // 示例引用请求节点 id：先把工作区刷到磁盘，避免「示例已写、节点还在防抖窗口里」
        // 的瞬间崩溃导致下次启动把这条示例当成孤儿清掉。
        saveImmediately()
        _ = persistence.saveExamples(examples)
        showSaveExampleSheet = false
        saveExampleName = ""
    }

    func deleteExample(id: UUID) {
        examples.removeAll { $0.id == id }
        _ = persistence.saveExamples(examples)
        if viewingExample?.id == id { viewingExample = nil }
    }

    private var defaultExampleName: String {
        let status = response?.statusCode ?? 0
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
        return "\(status) · \(stamp)"
    }

    // MARK: - Cookie

    /// 当前草稿 URL 能带上的会话 Cookie（只读展示用）。
    ///
    /// 这里只做 URL 的变量替换，不经过 `resolve`——`resolve` 会注入 Cookie，
    /// 在 Cookie 分页里展示注入结果没有意义。
    var cookiesForCurrentDraft: [HTTPCookie] {
        let urlText = VariableResolver.resolve(
            draft.url,
            variables: activeEnvironment?.variableMap ?? [:]
        ).text
        return cookieJar.matching(for: URL(string: urlText))
    }

    var sessionCookieCount: Int { cookieJar.count }

    /// 当前请求是否手写了 Cookie 行（页签状态点用）。
    var hasManualCookies: Bool {
        draft.cookies.contains { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func clearCookieJar() {
        cookieJar.removeAll()
    }

    /// 设置页与 Cookie 分页共用的开关。
    ///
    /// 提供成 `AppState` 上的可写属性，视图可以用 `@Bindable` 直接绑定；
    /// 若在视图里临时构造 `Binding`，SwiftUI 的 Switch 在快照/非激活窗口下
    /// 可能拿不到稳定身份，显示成关闭态。
    var cookieJarEnabled: Bool {
        get { workspace.settings.cookieJarEnabled }
        set {
            guard workspace.settings.cookieJarEnabled != newValue else { return }
            workspace.settings.cookieJarEnabled = newValue
            save()
        }
    }

    /// 把一次响应的 `Set-Cookie` 收进会话 Jar。
    ///
    /// 独立成方法而不是内联在 `applyFinished`：发送完成与测试走同一条路径，
    /// 也保证「开关关闭时绝不写 Jar」只有一处判断。
    func storeSessionCookies(_ headers: [HTTPHeader], for url: URL?) {
        guard workspace.settings.cookieJarEnabled else { return }
        cookieJar.store(responseHeaders: headers, for: url)
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
    /// 保存弹窗发起时所在的页签。
    ///
    /// **保存必须落回这一格**：弹窗开着的时候「当前页签」可能已经变了
    /// （⌘T、菜单命令），按提交时的当前页签归属会把新请求绑错格子。
    private var saveSheetTabID: UUID?
    /// 新建请求时的默认保存目标文件夹（右键「在此新建请求」用）。
    var defaultSaveFolderID: UUID?

    // MARK: - 私有

    private var cachedExecutor: RequestExecutor?
    private var cachedOptions: RequestExecutorOptions?

    /// 在飞 SSE 响应的归并器（按页签）。流结束后仍留在表里：
    /// 用户此时切字段、加自定义路径仍要对**这份**结果生效，直到下次发送或清空响应。
    private var liveMergers: [UUID: LLMMergerBox] = [:]

    /// 归并器当前持有哪些页签（只读测试口）。
    ///
    /// 归并器里是拼接文本（单字段上限 512 KB × 64 字段），「它跟着页签一起消失」
    /// 是内存纪律的一部分，必须有办法从外部观察——否则这条泄漏只能靠读代码发现。
    var liveMergerTabIDs: Set<UUID> { Set(liveMergers.keys) }

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
        self.exampleStore = ResponseExampleStore(directory: persistence.directoryURL)
        // 存储属性先给初值，真正的构建统一走 applyLoadedState：init 与重载共用
        // 同一套「≥1 页签 / activeTabID 有效 / 项目不变量 / 孤儿清理」兜底规则。
        self.workspace = Workspace()
        self.examples = []
        self.tabs = []
        self.activeTabID = UUID()

        applyLoadedState(loaded, storedExamples: exampleStore.load())

        // 所有写路径（防抖 / 立即 / 示例）的结果都回到这里。
        persistence.onSaveResult = { [weak self] result, generation in
            self?.handleSaveResult(result, generation: generation)
        }
        // 退出改由 AppDelegate.applicationShouldTerminate 拦截：willTerminate 发生时
        // 已经决定退出，既拿不到落盘结果也无法弹窗或阻止退出。
    }

    /// 从一份磁盘快照重建持久化状态。
    private func applyLoadedState(_ loaded: Workspace, storedExamples: [ResponseExample]) {
        let previousTabs = tabs
        workspace = loaded
        // 请求节点被删掉后，它的示例没有主人：载入时清理，避免 examples.json 只增不减。
        examples = storedExamples.filter { example in
            loaded.projects.contains { $0.children.findNode(id: example.requestNodeID) != nil }
        }

        // 按 id 把不落盘的运行期状态搬到新页签：响应、流、分页、错误提示不该因为
        // 磁盘被别的进程改过就凭空消失。
        let oldByID = Dictionary(uniqueKeysWithValues: previousTabs.map { ($0.id, $0) })
        let restored = loaded.tabs.map { tab -> EditorTab in
            var fresh = EditorTab(id: tab.id, draft: tab.draft, baseline: tab.baseline, nodeID: tab.nodeID)
            if let old = oldByID[tab.id] { fresh.copyRuntimeState(from: old) }
            return fresh
        }
        if restored.isEmpty {
            let fresh = EditorTab(draft: APIRequest())
            tabs = [fresh]
            activeTabID = fresh.id
        } else {
            tabs = restored
            activeTabID = loaded.activeTabID.flatMap { id in
                restored.contains { $0.id == id } ? id : nil
            } ?? restored[0].id
        }

        // 磁盘上被移除的页签：取消在飞请求、释放归并器，避免它们留在内存里。
        let surviving = Set(tabs.map(\.id))
        for old in previousTabs where !surviving.contains(old.id) {
            if old.isSending { executor().cancel(token: old.id) }
            liveMergers[old.id] = nil
        }

        // 「至少一个项目 + 当前项目有效」的生命周期不变量：全新工作区、旧文件迁移
        // 出 0 个项目、activeProjectID 悬空，都在这里兜底。只改内存不落盘。
        ensureActiveProject()

        // 一次性归属：隔离改造前的历史记录没有 projectID，真实归属已不可考。
        // 统一挂到第一个项目（v3 迁移前的单集合时代，全部历史都属于那个默认项目）。
        // 不归属的后果是旧记录泄漏进每个项目；按某个当时巧合活跃的项目归属则是编造数据。
        if workspace.history.contains(where: { $0.projectID == nil }),
           let fallback = workspace.projects.first?.id {
            for index in workspace.history.indices where workspace.history[index].projectID == nil {
                workspace.history[index].projectID = fallback
            }
        }

        // 页签归属随页签一起恢复；不恢复的话重启后 ⌘S 会当成新请求弹窗。
        // 归属按**全局**查找（页签可以停留在别的项目的请求上）。
        dropStaleNodeReferences()
        // 当前页签的归属若在别的项目里，把当前项目切过去，侧栏高亮才对得上编辑器。
        syncProjectToActiveTab()
        syncSelectionToActiveTab()
        // 重载后旧的 pending id 可能指向已删除的节点，确认框点下去就是空操作。
        clearPendingTransientState()
        refreshResponseBodyText()
    }

    private func clearPendingTransientState() {
        pendingCloseTabID = nil
        showTabCloseConfirm = false
        closeAfterSave = false
        pendingBatchCloseIDs = []
        showBatchCloseConfirm = false
        showEnvironmentEditor = false
        showClearHistoryConfirm = false
        pendingProjectActivationID = nil
        pendingImportEnvironmentID = nil
        showProjectSwitchConfirm = false
        showSaveSheet = false
        saveSheetProjectID = nil
        saveSheetFolderID = nil
        saveSheetTabID = nil
        defaultSaveFolderID = nil
        showSaveExampleSheet = false
        viewingExample = nil
        showCurlImport = false
        showOpenAPIImportSheet = false
    }

    // MARK: - 落盘结果 / 外部变更 / 退出

    /// 所有写路径共用的结果处理。
    func handleSaveResult(_ result: SaveResult, generation: Int) {
        // 退出流程有自己的状态机（三按钮 + NSApp.reply），后台结果不要插手降级它。
        guard !isPreparingTermination, saveIssue?.context != .exit else { return }
        switch result {
        case .stale:
            // 过期调度既没读盘也没写盘，绝不能把真实失败清成成功。
            return
        case .succeeded:
            clearSaveIssue()
        case .failed(let files):
            mergeIssue(kind: .writeFailed(files),
                      context: .toolbar,
                      titleKey: .saveFailedTitle,
                      messageKey: .saveFailedMessage,
                      arguments: [files.joined(separator: ", ")])
        case .conflict(.busy):
            // 别人正在写的毫秒级窗口：不弹窗，短延迟重试一次，避免每 600ms 弹一次框。
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                _ = self?.flushNow()
            }
        case .conflict(.fingerprintMismatch(let files)):
            checkForExternalChanges(changedFiles: files)
        }
    }

    private func mergeIssue(kind: SaveIssueKind, context: SaveIssueContext,
                            titleKey: L10nKey, messageKey: L10nKey, arguments: [String]) {
        // 同一问题只弹一次（防抖会反复上报），后续只更新次数与参数。
        if var issue = saveIssue, issue.kind == kind {
            issue.attempts += 1
            issue.arguments = arguments
            saveIssue = issue
            // 用户主动「重新检查」或退出重试仍失败时要重新立起弹窗；
            // 后台防抖的反复上报（.toolbar）不打扰。
            if context != .toolbar { presentSaveIssue() }
            return
        }
        saveIssue = SaveIssue(kind: kind, context: context, titleKey: titleKey,
                              messageKey: messageKey, arguments: arguments)
        presentSaveIssue()
    }

    /// 让 SwiftUI 真正弹出（或切换到）当前 `saveIssue` 的弹窗。
    ///
    /// `.alert(isPresented:presenting:)` 在 `presenting` 变了、`isPresented` 仍为 true
    /// 时只会 dismiss 旧弹窗、不会重新 present——问题类型从「保存失败」切成「工作区冲突」
    /// 时会表现为弹窗直接消失。先置 false 再在下一个 runloop 置 true，才能强制重建。
    private func presentSaveIssue() {
        showSaveIssueAlert = false
        DispatchQueue.main.async { [weak self] in
            guard let self, self.saveIssue != nil else { return }
            self.showSaveIssueAlert = true
        }
    }

    private func clearSaveIssue() {
        saveIssue = nil
        showSaveIssueAlert = false
    }

    /// 立即把当前内存快照落盘并返回完整结果。
    @discardableResult
    func flushNow() -> SaveResult {
        syncTabsToWorkspace()
        return persistence.flushNow(workspace)
    }

    func retrySave() {
        guard let kind = saveIssue?.kind else { return }
        switch kind {
        case .writeFailed, .conflict(.busy):
            let result = flushNow()
            if !result.isSuccess { presentSaveIssue() }
        case .conflict(.fingerprintMismatch):
            // 冲突时重写只会覆盖磁盘，正确做法是重载到磁盘版本。
            reloadWorkspace()
        }
    }

    func dismissSaveIssue() { showSaveIssueAlert = false }

    func showSaveIssueDetails() {
        guard saveIssue != nil else { return }
        presentSaveIssue()
    }

    /// 应用重新激活时调用；保存前的 CAS 冲突也会带着文件名走进来。
    func checkForExternalChanges(changedFiles: [String]? = nil) {
        let files = changedFiles ?? persistence.externalChangedFiles()
        guard !files.isEmpty else {
            if let issue = saveIssue, case .conflict = issue.kind { clearSaveIssue() }
            return
        }
        if persistence.hasUnflushedChanges {
            // 有未落盘编辑：不能静默丢弃用户输入，交给用户二选一。
            mergeIssue(kind: .conflict(.fingerprintMismatch(files)),
                      context: .externalChange,
                      titleKey: .workspaceChangedTitle,
                      messageKey: .workspaceChangedMessage,
                      arguments: [files.joined(separator: ", ")])
        } else {
            reloadWorkspace()
        }
    }

    /// 重载入口，也是「重载并放弃我的编辑」的动作。不自动 save()：重载后
    /// 内存已等于磁盘，再写一次只会无谓换 inode 并与别的进程抢锁。
    func reloadWorkspace() {
        let loaded = persistence.reloadFromDisk()
        applyLoadedState(loaded, storedExamples: exampleStore.load())
        clearSaveIssue()
    }

    /// 退出前最后一次权威落盘。失败时把问题升级成退出场景（三按钮弹窗）。
    @discardableResult
    func prepareForTermination() -> SaveResult {
        isPreparingTermination = true
        defer { isPreparingTermination = false }
        let result = flushNow()
        if result.isSuccess {
            clearSaveIssue()
            return result
        }
        let (kind, arguments): (SaveIssueKind, [String])
        switch result {
        case .failed(let files):
            kind = .writeFailed(files)
            arguments = [files.joined(separator: ", ")]
        case .conflict(let reason):
            kind = .conflict(reason)
            arguments = [Self.describe(reason)]
        case .stale, .succeeded:
            return result
        }
        saveIssue = SaveIssue(kind: kind, context: .exit,
                              titleKey: .quitSaveFailedTitle,
                              messageKey: .saveFailedMessage,
                              arguments: arguments)
        presentSaveIssue()
        return result
    }

    /// 退出弹窗「重试」：成功或重载后放行，仍失败就留在原地。
    func retryTerminationSave() {
        let result = flushNow()
        switch result {
        case .succeeded:
            clearSaveIssue()
            resolveTermination(shouldTerminate: true)
        case .conflict(.fingerprintMismatch):
            reloadWorkspace()
            resolveTermination(shouldTerminate: true)
        default:
            // 仍失败：SwiftUI 已把弹窗收起，必须重新立起来，否则退出流程挂在
            // .terminateLater，用户看不到任何可点的出口。
            presentSaveIssue()
        }
    }

    func resolveTermination(shouldTerminate: Bool) {
        appDelegate?.finishTermination(shouldTerminate)
    }

    private static func describe(_ reason: ConflictReason) -> String {
        switch reason {
        case .busy: return "workspace is busy"
        case .fingerprintMismatch(let files): return files.joined(separator: ", ")
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
    /// **为什么只清 `errorMessage` / `alertMessage`**：二者是已生成的字符串，无法就地重译；
    /// 留着旧语言的文本比清掉更误导。每个页签各清一遍——别的页签里也可能挂着旧语言错误。
    /// `saveIssue` 存的是键 + 参数，渲染时才取词，切语言会自动重译，不能清。
    func setLanguage(_ language: AppLanguage?) {
        workspace.settings.language = language
        refreshResponseBodyText()
        for index in tabs.indices {
            tabs[index].errorMessage = nil
        }
        alertMessage = nil
        saveImmediately()
    }

    // MARK: - 便捷访问

    var projects: [Project] { workspace.projects }
    var history: [HistoryEntry] { workspace.history }

    /// 侧栏展示的历史：只含当前项目的记录。
    ///
    /// 隔离改造前历史是全局数组——切到别的项目，上一个项目发送的记录还混在列表里，
    /// 用户分不清哪条属于手头的项目。`init` 会把无归属的旧记录一次性归属到第一个
    /// 项目，所以这里按当前项目精确过滤即可，不需要给 nil 兜底。
    var visibleHistory: [HistoryEntry] {
        guard let id = workspace.activeProjectID else { return [] }
        return workspace.history.filter { $0.projectID == id }
    }
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

    /// 变量替换 + 路径参数替换 + 认证注入。
    ///
    /// 预览与发送**共用这一个入口**：否则「最终 URL」会在两处出现分歧
    /// （曾经就发生过——预览没做替换，`{{baseUrl}}` 被 URLComponents 编码成
    /// `%7B%7BbaseUrl%7D%7D`，而实发的是替换后的地址，用户会以为 URL 被弄坏了）。
    ///
    /// 顺序：环境变量 → 路径参数 → 认证 → Cookie。路径参数值本身也可以写
    /// `{{变量}}`，所以必须排在环境变量替换之后。
    private func resolve(_ request: APIRequest) -> (request: APIRequest, unresolved: [String], unresolvedPathParams: [String]) {
        var (resolved, unresolved) = VariableResolver.resolve(
            request,
            variables: activeEnvironment?.variableMap ?? [:]
        )

        var pathValues: [String: String] = [:]
        for item in resolved.pathParams where item.isEnabled {
            if pathValues[item.key] == nil { pathValues[item.key] = item.value }
        }
        let pathResult = PathParams.apply(to: resolved.url, values: pathValues)
        resolved.url = pathResult.url

        AuthApplier.apply(resolved.auth, to: &resolved)

        // Cookie 在认证之后注入：显式 Cookie 头 / 手动行 / 会话 Jar 的优先级
        // 由 `CookieApplier` 收口。
        let jarCookies: [HTTPCookie]
        if workspace.settings.cookieJarEnabled, let url = URL(string: resolved.url) {
            jarCookies = cookieJar.matching(for: url)
        } else {
            jarCookies = []
        }
        CookieApplier.apply(manual: resolved.cookies, jar: jarCookies, to: &resolved)

        return (resolved, unresolved, pathResult.unresolved)
    }

    /// 预览用：当前页签草稿做变量替换后的副本。
    var resolvedDraft: APIRequest { resolve(draft).request }

    /// 让路径参数行与 URL 里的 `{name}` / `:name` 保持一致。
    ///
    /// URL 是唯一的真相：占位符新增就补空行；`prune == true` 时删掉已移除的行，
    /// `prune == false` 时保留它们（编辑 URL 过程中的短暂缺失不该丢值）。
    /// 由请求编辑区在 URL 变化 / 切换页签 / 首次出现时调用；发送路径不依赖它
    /// （`resolve` 会按名字查值），所以即使视图还没同步，也不会发错。
    func syncPathParams(prune: Bool = true) {
        let synced = PathParams.synchronize(url: draft.url, existing: draft.pathParams, prune: prune)
        guard synced != draft.pathParams else { return }
        draft.pathParams = synced
    }

    /// 任意请求的 curl 命令（导出用）。
    ///
    /// 变量替换与执行参数都走 App 自己的那一套：复制出去的命令与 App **这一次**发出去的
    /// 是同一件事（未定义变量按原文发出，`-L` / `-k` 跟着设置走），
    /// 而不是一条看起来像、跑起来不一样的命令。
    func curlCommand(for request: APIRequest) -> String {
        CurlExport.command(
            for: resolve(request).request,
            options: CurlExport.Options(executorOptions)
        )
    }

    // MARK: - 发送

    /// 流式发布的节流间隔。SSE 每秒可能上百个事件，每个 chunk 都改一次
    /// `@Observable` 状态会让 SwiftUI 反复重建整棵响应区。
    static let streamFlushInterval: TimeInterval = 0.06
    /// 缓冲超过这个字节数也立即发布（大块数据不该等满一个窗口）。
    static let streamFlushByteThreshold = 64 * 1024

    /// 当前响应区可用的分页。
    ///
    /// 「事件」分页只在这次响应是 SSE 时出现：非 SSE 时四段里的 events 会让用户点进一个
    /// 永远空着的页面。判定用 `stream.isEventStream` 而不是 `status == .streaming`——
    /// 流结束后用户仍要能翻看刚收到的事件。
    var availableResponseSections: [ResponseSection] {
        activeTab.stream.isEventStream
            ? [.body, .llm, .events, .headers, .timing]
            : [.body, .headers, .timing]
    }

    /// 发送当前页签的请求。
    ///
    /// **结果回写到发起时的那个页签**：等待期间用户完全可能切走甚至关掉它。
    /// 按 id 回写、找不到就丢弃，是「切页签不串响应」的全部实现。
    ///
    /// 传输层只有一条路径（`sendStreaming`）：SSE 在 `.head` 时切到事件分页并边收边发布，
    /// 非 SSE 则什么都不做，等 `.finished` 一次性出结果——行为与改造前一致。
    func send() async {
        let tabID = activeTabID
        guard let index = tabIndex(tabID), !tabs[index].isSending else { return }
        tabs[index].isSending = true
        tabs[index].errorMessage = nil
        tabs[index].stream = StreamState()
        // 上一次是 SSE、用户停在事件 / 大模型输出分页：这次还没确认是 SSE，分页先回到 body，
        // 否则分段控件会选中一个当前不存在的选项（控件里没有、内容区却按它渲染）。
        if tabs[index].responseSection == .events || tabs[index].responseSection == .llm {
            tabs[index].responseSection = .body
        }

        let request = tabs[index].draft
        let resolved = resolve(request)
        if let index = tabIndex(tabID) {
            tabs[index].unresolvedVariables = resolved.unresolved
            tabs[index].unresolvedPathParams = resolved.unresolvedPathParams
        }

        var parser = SSEParser()
        var textDecoder = UTF8StreamDecoder()
        // 归并器逐事件累积；只有发布被节流（与事件、文本同一窗口）。
        //
        // 归并器挂在 `liveMergers` 而不是局部变量：用户在流式期间添加/删除自定义路径
        // 必须**立即**影响这条流，否则「加了路径却要等下次请求才生效」。
        let mergerBox = LLMMergerBox()
        liveMergers[tabID] = mergerBox
        // 自定义路径是跨启动的用户配置，每次新流开始时灌进归并器（它自己会保序去重）。
        for path in workspace.settings.llmFieldPaths {
            _ = mergerBox.merger.addCustomPath(path)
        }
        // `.head` 先于 `.chunk`（执行器保证），所以这个标志在第一个 chunk 之前就已确定。
        // 非 SSE 响应在传输期间必须**零状态写入**：不解析、不累计、不发布。
        var isEventStream = false
        let publisher = StreamPublisher(
            interval: Self.streamFlushInterval,
            byteThreshold: Self.streamFlushByteThreshold
        ) { [weak self] pending in
            self?.publish(pending, to: tabID)
        }

        do {
            for try await update in executor().sendStreaming(resolved.request, token: tabID) {
                switch update {
                case .head(let head):
                    guard head.isEventStream else { continue }
                    // 只有 SSE 才进入流式展示：非 SSE 保持旧响应/空态不动（§3.6）。
                    isEventStream = true
                    if let index = tabIndex(tabID) {
                        tabs[index].response = nil
                        tabs[index].responseBodyText = ""
                    }
                    updateStream(tabID) { stream in
                        stream.isEventStream = true
                        stream.status = .streaming
                        stream.startedAt = Date()
                    }
                    setResponseSection(.events, for: tabID)

                case .chunk(let data):
                    // 非 SSE 直接丢弃：分帧与发布都是为高频事件准备的，
                    // 摊到普通请求上就是热路径回归（设计 §3.8 明文「非 SSE 忽略」）。
                    guard isEventStream else { continue }
                    // 解析仍逐 chunk 做（纯 CPU、无分配放大）；只有**发布**被节流。
                    // 文本解码跨 chunk 持有残留字节，多字节字符被切开也不会出现 U+FFFD。
                    let events = parser.consume(data)
                    _ = mergerBox.merger.consume(events)
                    publisher.add(
                        events: events,
                        text: textDecoder.consume(data),
                        bytes: data.count,
                        llm: mergerBox.merger.state
                    )

                case .finished(let response):
                    // 终态：先把节流窗口里的内容取出，与终态在**同一次**状态写入里落地
                    // （§6.1-2），否则窗口内最后一批事件会被覆盖丢失。
                    let pending = publisher.takePending()
                    publisher.close()
                    let tailEvents = isEventStream ? parser.finish() : []
                    if isEventStream {
                        // 残留事件（流以未收尾事件结束）同样要进归并器，否则最后半截正文丢失。
                        _ = mergerBox.merger.consume(tailEvents)
                    }

                    applyFinished(
                        response,
                        pending: withLLM(pending, mergerBox.merger.state, isSSE: isEventStream),
                        tailText: isEventStream ? textDecoder.finish() : "",
                        tailEvents: tailEvents,
                        isSSE: isEventStream,
                        to: tabID,
                        request: request
                    )
                }
            }
        } catch RequestFailure.cancelled {
            // 用户主动取消：不是失败。**保留已收内容**，不报错、不记历史
            // （§6.1-6：不要走非 SSE 那套 clearResponse）。
            let pending = publisher.takePending()
            publisher.close()
            let tailText = isEventStream ? textDecoder.finish() : ""
            let tail = isEventStream ? parser.finish() : []
            if isEventStream { _ = mergerBox.merger.consume(tail) }
            finishStream(
                tabID,
                pending: withLLM(pending, mergerBox.merger.state, isSSE: isEventStream),
                tailText: tailText,
                tail: tail
            ) { stream in
                if stream.status == .streaming { stream.status = .cancelled }
                stream.endedAt = Date()
            }
        } catch {
            let pending = publisher.takePending()
            publisher.close()
            let tailText = isEventStream ? textDecoder.finish() : ""
            let tail = isEventStream ? parser.finish() : []
            if isEventStream { _ = mergerBox.merger.consume(tail) }
            let message = localizedErrorMessage(for: error)

            let hadEvents = finishStream(
                tabID,
                pending: withLLM(pending, mergerBox.merger.state, isSSE: isEventStream),
                tailText: tailText,
                tail: tail
            ) { stream in
                stream.status = .failed(message)
                stream.endedAt = Date()
            }
            finishSending(tabID) { tab in
                // 已经收到内容（SSE 且有事件）就保留，让用户看到断在哪；
                // 一个事件都没有则与改造前一致：清响应、只显示错误。
                if !hadEvents {
                    tab.response = nil
                    tab.responseBodyText = ""
                }
                tab.errorMessage = message
            }
            recordHistory(for: request, statusCode: nil, duration: nil, succeeded: false)
        }
    }

    // MARK: - 大模型输出（归并器的用户操作）

    /// 当前页签的字段拼接状态。
    var llmStreamState: LLMStreamState { activeTab.stream.llm }

    /// 当前页签的归并器（没有在飞流时为 nil）。
    private var activeMerger: LLMMergerBox? { liveMergers[activeTabID] }

    /// 切换主区域拼接的字段。选择跟随页签（`selectedPath` 是页签运行期字段）。
    func selectLLMField(_ path: String?) {
        let tabID = activeTabID
        activeMerger?.merger.select(path)
        guard let index = tabIndex(tabID) else { return }
        // 先写页签：即使归并器已释放（流早结束了），选择本身也要能被界面读回。
        if let path {
            tabs[index].stream.llm.selectedPath = path
        } else {
            tabs[index].stream.llm.selectedPath = nil
        }
        if let state = activeMerger?.merger.state {
            let selection = tabs[index].stream.llm.selectedPath
            tabs[index].stream.llm = state
            tabs[index].stream.llm.selectedPath = selection
        }
    }

    /// 添加自定义路径：**写同一份配置**（`AppSettings.llmFieldPaths`）并立即作用于当前流。
    /// 语法非法或超出条数上限返回 false（界面提示）。
    @discardableResult
    func addLLMCustomPath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        // 用归并器当校验器：路径文法只有一份实现，界面与持久化不能各写一套。
        var probe = LLMStreamMerger()
        for existing in workspace.settings.llmFieldPaths { _ = probe.addCustomPath(existing) }
        guard probe.addCustomPath(trimmed) else { return false }
        let canonical = probe.state.customPaths.last ?? trimmed

        if !workspace.settings.llmFieldPaths.contains(canonical) {
            workspace.settings.llmFieldPaths.append(canonical)
            save()
        }
        _ = activeMerger?.merger.addCustomPath(trimmed)
        let tabID = activeTabID
        if let state = liveMergers[tabID]?.merger.state, let index = tabIndex(tabID) {
            let selection = tabs[index].stream.llm.selectedPath
            tabs[index].stream.llm = state
            tabs[index].stream.llm.selectedPath = selection
        }
        return true
    }

    /// 删除自定义路径（页签内联入口与设置页共用这一处写入口）。
    func removeLLMCustomPath(_ path: String) {
        workspace.settings.llmFieldPaths.removeAll { $0 == path }
        save()
        activeMerger?.merger.removeCustomPath(path)
        let tabID = activeTabID
        if let state = liveMergers[tabID]?.merger.state, let index = tabIndex(tabID) {
            let selection = tabs[index].stream.llm.selectedPath
            tabs[index].stream.llm = state
            tabs[index].stream.llm.selectedPath = selection
        }
    }

    /// 把归并器快照挂进待发布批次。非 SSE 不碰 `llm`（保持空态）。
    private func withLLM(_ batch: StreamBatch, _ state: LLMStreamState, isSSE: Bool) -> StreamBatch {
        guard isSSE else { return batch }
        var batch = batch
        batch.llm = state
        return batch
    }

    /// 页签在 `tabs` 中的下标（页签可能已被关掉，返回 nil 表示结果无处可放）。
    private func tabIndex(_ id: UUID) -> Int? { tabs.firstIndex { $0.id == id } }

    /// 结束一次发送：写回终态并复位 `isSending`。
    private func finishSending(_ tabID: UUID, _ body: (inout EditorTab) -> Void) {
        guard let index = tabIndex(tabID) else { return }
        body(&tabs[index])
        tabs[index].isSending = false
    }

    /// 流式收尾：把待发布内容、残留事件与终态**一次性**写入。
    ///
    /// 返回收尾前页签里是否已有事件——错误路径据此决定「保留内容」还是「清空」。
    @discardableResult
    private func finishStream(
        _ tabID: UUID,
        pending: StreamBatch,
        tailText: String,
        tail: [SSEEvent],
        _ body: (inout StreamState) -> Void
    ) -> Bool {
        guard let index = tabIndex(tabID) else { return false }
        var stream = tabs[index].stream
        let hadEvents = !stream.events.isEmpty || !pending.events.isEmpty
        stream.apply(pending)
        // 解码器残留的那几个字节（流停在字符中间时）也要落地，否则 Body 分页少一截。
        stream.appendText(tailText)
        stream.append(tail)
        body(&stream)
        tabs[index].stream = stream
        tabs[index].isSending = false
        return hadEvents
    }

    /// 就地修改某页签的 `stream`。
    private func updateStream(_ tabID: UUID, _ body: (inout StreamState) -> Void) {
        guard let index = tabIndex(tabID) else { return }
        body(&tabs[index].stream)
    }

    /// 设置某页签的响应分页（按 id，不受「当前页签」影响）。
    private func setResponseSection(_ section: ResponseSection, for tabID: UUID) {
        guard let index = tabIndex(tabID) else { return }
        tabs[index].responseSection = section
    }

    /// 节流窗口的落地点（唯一的状态写入点之一）。
    private func publish(_ pending: StreamBatch, to tabID: UUID) {
        guard let index = tabIndex(tabID) else { return }
        var stream = tabs[index].stream
        stream.apply(pending)
        tabs[index].stream = stream
    }

    /// 正常结束的收尾：SSE 走流式终态，非 SSE 沿用旧的一次性结果。
    private func applyFinished(
        _ response: APIResponse,
        pending: StreamBatch,
        tailText: String,
        tailEvents: [SSEEvent],
        isSSE: Bool,
        to tabID: UUID,
        request: APIRequest
    ) {
        guard let index = tabIndex(tabID) else { return }
        tabs[index].response = response
        tabs[index].responseBodyText = response.displayBodyText(l10n: t)
        tabs[index].isSending = false

        if isSSE {
            // 一次写入：窗口内的事件 + 残留事件 + 终态，缺一都会丢内容。
            var stream = tabs[index].stream
            stream.isEventStream = true
            stream.apply(pending)
            stream.appendText(tailText)
            stream.append(tailEvents)
            stream.status = .closed
            stream.endedAt = Date()
            tabs[index].stream = stream
            tabs[index].responseSection = .events
        } else {
            tabs[index].responseSection = .body
            // 非 SSE 必须把上一次的流式状态彻底清掉：否则「事件」分页会继续出现在
            // `availableResponseSections` 里，点进去看到的是上一条请求的事件。
            tabs[index].stream = StreamState()
        }

        // 会话 Jar 只在显式开启时记录；默认不碰 Set-Cookie。
        storeSessionCookies(response.headers, for: response.finalURL)

        recordHistory(
            for: request,
            statusCode: response.statusCode,
            duration: response.timing.total,
            succeeded: response.isSuccess
        )
    }

    /// 已知错误按当前语言取文案；未知错误保留系统的 `localizedDescription`
    /// （那是系统语言，硬翻成应用语言反而更怪）。
    private func localizedErrorMessage(for error: Error) -> String {
        if let failure = error as? RequestFailure {
            return failure.message(t)
        }
        return error.localizedDescription
    }

    /// 按当前语言重算并缓存所有页签的响应体展示文本。
    ///
    /// `send()` 收到响应后调用；`setLanguage` 切换语言后也要调用——
    /// 缓存的是成品字符串，含截断说明，不重算就会残留旧语言。
    private func refreshResponseBodyText() {
        for index in tabs.indices {
            tabs[index].responseBodyText = tabs[index].response?.displayBodyText(l10n: t) ?? ""
        }
    }

    /// 取消当前页签在飞的请求（发送按钮 / ⌘.）。
    /// 只取消这一格：别的页签可能也在发，用户的「取消」只对眼前这一格有意义。
    func cancelSend() {
        let tabID = activeTabID
        guard let index = tabIndex(tabID), tabs[index].isSending else { return }
        executor().cancel(token: tabID)
    }

    private func recordHistory(for request: APIRequest, statusCode: Int?, duration: TimeInterval?, succeeded: Bool) {
        var snapshot = request
        // 历史里的 url 为空时不记录，避免噪音
        guard !snapshot.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        snapshot.name = requestNameForHistory(request)
        workspace.pushHistory(HistoryEntry(
            projectID: workspace.activeProjectID,
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

    /// 清空当前页签的响应相关状态。
    func clearResponse() {
        let tabID = activeTabID
        liveMergers[tabID] = nil
        withActiveTab { $0.clearResponse() }
    }

    private func executor() -> RequestExecutor {
        if let cachedExecutor, cachedOptions == executorOptions {
            return cachedExecutor
        }
        // URLSession 强引用 delegate（即 executor 自身），不显式失效会泄漏。
        // 重建会取消在飞请求——设置（超时/重定向/证书）变了，旧请求按旧参数跑完反而误导。
        cachedExecutor?.invalidate()
        let fresh = RequestExecutor(options: executorOptions)
        cachedExecutor = fresh
        cachedOptions = executorOptions
        return fresh
    }

    // MARK: - 页签操作

    /// 把页签写进 workspace 并防抖落盘。
    /// 页签此前只在退出时落盘，异常退出（崩溃 / 强杀）就会丢掉整个编辑中的请求。
    func persistDraft() {
        save()
    }

    /// 侧栏选中项变化的**唯一入口**（`SidebarView.onChange` 调用）。
    ///
    /// 放在这里而不是视图里，是为了让"切页签会回写选中项 → 又触发一次 onChange"
    /// 这条真实链路可以被测试直接驱动。
    func handleSidebarSelection(_ id: UUID?) {
        // 侧栏只渲染当前项目的目录树，选中的节点按构造属于当前项目。
        guard let id,
              let node = activeProject?.children.findNode(id: id),
              !node.isFolder
        else { return }
        openSavedRequest(node)
    }

    /// 新建请求页签。
    @discardableResult
    func newRequest(inFolder folderID: UUID? = nil) -> UUID {
        defaultSaveFolderID = folderID
        let tab = EditorTab(draft: APIRequest())
        tabs.append(tab)
        activeTabID = tab.id
        selectedNodeID = nil
        save()
        return tab.id
    }

    /// 打开一个已保存的请求：已经在某个页签里就切过去，否则新开一格。
    ///
    /// **不再需要脏检查**：当前页签的未保存改动留在它自己那格里，不会被替换，
    /// 所以这里既不用问用户，也不会丢内容——这就是多页签取代草稿冲突弹窗的原因。
    func openSavedRequest(_ node: CollectionNode) {
        guard let saved = node.savedRequest else { return }
        if let existing = tabs.first(where: { $0.nodeID == node.id }) {
            activateTab(id: existing.id)
            return
        }
        let tab = EditorTab(draft: saved.request, nodeID: node.id)
        tabs.append(tab)
        activeTabID = tab.id
        selectedNodeID = node.id
        save()
    }

    /// 从历史恢复请求：总是新开一个**未归属**页签（副本），不改动已保存的请求。
    @discardableResult
    func restoreFromHistory(_ entry: HistoryEntry) -> UUID {
        let tab = EditorTab(draft: entry.request)
        tabs.append(tab)
        activeTabID = tab.id
        selectedNodeID = nil
        save()
        return tab.id
    }

    /// 克隆页签：把某一格的草稿原样复制成紧挨着它的新一格。
    ///
    /// **副本不继承归属**（`nodeID` 为 nil）：否则两格指向同一个已保存请求，
    /// 在副本里 ⌘S 会覆盖原件，「克隆」就变成了「同一个请求开两格」。
    /// 未归属的副本按既有规则走保存弹窗，命名后才落成新请求。
    @discardableResult
    func cloneTab(id: UUID) -> UUID? {
        guard let index = tabIndex(id) else { return nil }
        let tab = EditorTab(draft: tabs[index].draft)
        tabs.insert(tab, at: index + 1)
        activeTabID = tab.id
        selectedNodeID = nil
        save()
        return tab.id
    }

    /// 切换页签。
    func activateTab(id: UUID) {
        guard tabIndex(id) != nil, id != activeTabID else { return }
        activeTabID = id
        // 页签可能停留在别的项目的请求上：项目和侧栏选中项一起跟过去，
        // 否则会出现「编辑器是 B 项目的请求，侧栏却显示 A 项目、什么都不高亮」。
        syncProjectToActiveTab()
        syncSelectionToActiveTab()
        save()
    }

    /// 请求关闭页签：干净的直接关，脏的先让用户决定。
    func requestCloseTab(id: UUID) {
        // 单个关闭是新的意图：之前挂着的批量确认一并作废，避免两个确认框叠加。
        cancelTabClose()
        guard let index = tabIndex(id) else { return }
        guard tabs[index].isDirty else {
            closeTab(id: id)
            return
        }
        pendingCloseTabID = id
        showTabCloseConfirm = true
    }

    /// 请求关闭多个页签（关闭其他 / 关闭全部）。
    ///
    /// 干净页签直接关；只要有脏页签就合成一次确认。批量场景不逐个走
    /// 「保存并关闭」：未归属的页签每个都要命名，N 次弹窗等于没做。
    func requestCloseTabs(ids: [UUID], keeping keptID: UUID? = nil) {
        cancelTabClose()
        let targets = ids.filter { $0 != keptID && tabIndex($0) != nil }
        guard !targets.isEmpty else { return }

        guard dirtyCount(in: targets) > 0 else {
            for id in targets { closeTab(id: id) }
            return
        }
        pendingBatchCloseIDs = targets
        showBatchCloseConfirm = true
    }

    /// 关闭除 `id` 以外的所有页签。
    func requestCloseOtherTabs(keeping id: UUID) {
        requestCloseTabs(ids: tabs.map(\.id), keeping: id)
    }

    /// 关闭全部页签（最后一个关闭后会补一个空页签，与单页签关闭一致）。
    func requestCloseAllTabs() {
        requestCloseTabs(ids: tabs.map(\.id))
    }

    /// 批量确认框里有多少页签带未保存修改（文案用）。
    var pendingBatchCloseDirtyCount: Int {
        dirtyCount(in: pendingBatchCloseIDs)
    }

    /// 批量关闭确认：确认丢弃修改后一并关闭。
    func confirmBatchCloseDiscardingChanges() {
        let ids = pendingBatchCloseIDs
        pendingBatchCloseIDs = []
        showBatchCloseConfirm = false
        for id in ids { closeTab(id: id) }
    }

    /// 批量关闭确认里的「取消」。
    func cancelBatchClose() {
        pendingBatchCloseIDs = []
        showBatchCloseConfirm = false
    }

    private func dirtyCount(in ids: [UUID]) -> Int {
        ids.reduce(0) { count, id in
            guard let index = tabIndex(id), tabs[index].isDirty else { return count }
            return count + 1
        }
    }

    /// 立即关闭页签（未保存修改一并丢弃）。关闭最后一个会补一个空页签。
    func closeTab(id: UUID) {
        clearTabCloseConfirmation()
        guard let index = tabIndex(id) else { return }
        // 在飞的请求随页签一起取消：否则结果回来时页签已经不在，连接白占着。
        if tabs[index].isSending {
            executor().cancel(token: id)
        }
        // 归并器必须跟着页签一起消失：它持有该页签的拼接文本（最多 64 × 512 KB）。
        // 页签关闭是高频操作，漏掉这一行，泄漏就随关闭次数线性累积且无上界。
        // 这是 `tabs` 里唯一的「移除」点（下面补空页签那支发生在已经移除之后），
        // 所以一行覆盖全部关闭路径。
        liveMergers[id] = nil
        tabs.remove(at: index)

        if tabs.isEmpty {
            let fresh = EditorTab(draft: APIRequest())
            tabs = [fresh]
            activeTabID = fresh.id
            selectedNodeID = nil
        } else if activeTabID == id {
            // 关掉当前页签：接管右邻（没有就左邻），像浏览器那样停在一格上。
            activeTabID = tabs[min(index, tabs.count - 1)].id
            syncProjectToActiveTab()
            syncSelectionToActiveTab()
        }
        save()
    }

    /// 关闭确认里的「保存并关闭」：已归属的直接覆盖保存并关掉；
    /// 未归属的先弹保存弹窗，提交后由 `commitSaveSheet` 收尾。
    func saveAndClosePendingTab() {
        guard let id = pendingCloseTabID, let index = tabIndex(id) else {
            cancelTabClose()
            return
        }
        showTabCloseConfirm = false

        if let nodeID = tabs[index].nodeID, overwriteSavedRequest(id: nodeID, with: tabs[index].draft) {
            closeTab(id: id)
            return
        }
        // 还没归属（或归属已失效）：切到那一格再弹保存弹窗，
        // 否则用户命名保存的可能是另一格的草稿。
        activeTabID = id
        syncProjectToActiveTab()
        syncSelectionToActiveTab()
        closeAfterSave = true
        presentSaveSheet()
    }

    /// 关闭确认里的「放弃修改」。
    func discardAndClosePendingTab() {
        guard let id = pendingCloseTabID else {
            cancelTabClose()
            return
        }
        closeTab(id: id)
    }

    /// 关闭确认弹窗被收起（Esc / 点弹窗外 / 任一按钮）。**只收弹窗**，
    /// 不动待关闭目标——「保存并关闭」的动作先于收起发生，目标后面还要用。
    func tabCloseDialogDismissed() {
        showTabCloseConfirm = false
    }

    /// 作废关闭确认（「取消」按钮、页签已被别处关掉）：待关闭目标一并清掉。
    /// 批量关闭的待办也归这里取消——两者都是「用户反悔了」。
    func cancelTabClose() {
        clearTabCloseConfirmation()
        pendingBatchCloseIDs = []
        showBatchCloseConfirm = false
    }

    /// 只清单个关闭的确认状态，不动批量队列（批量循环里 `closeTab` 会调用它）。
    private func clearTabCloseConfirmation() {
        pendingCloseTabID = nil
        showTabCloseConfirm = false
        closeAfterSave = false
    }

    /// 让当前项目跟上当前页签的归属（页签属于别的项目时切过去）。
    private func syncProjectToActiveTab() {
        guard let nodeID = activeTab.nodeID,
              let project = workspace.projects.first(where: { $0.children.findNode(id: nodeID) != nil }),
              project.id != workspace.activeProjectID
        else { return }
        workspace.activeProjectID = project.id
        dropStaleNodeReferences()
    }

    /// 让侧栏高亮与当前页签一致（页签绑定的请求在当前项目里才高亮）。
    private func syncSelectionToActiveTab() {
        if let nodeID = activeTab.nodeID, activeProject?.children.findNode(id: nodeID) != nil {
            selectedNodeID = nodeID
        } else {
            selectedNodeID = nil
        }
    }

    /// 保存弹窗被取消。
    func cancelSaveSheet() {
        showSaveSheet = false
        // 「保存并关闭」路径下取消命名：页签不该被关掉，收尾状态一并作废。
        closeAfterSave = false
        pendingCloseTabID = nil
        // 发起页签也要清：留着它会让下一次直接调 saveAsNewRequest 绑到旧格上。
        saveSheetTabID = nil
    }

    /// 保存为新请求。
    ///
    /// `projectID` 为 nil 时落到弹窗里选中的项目（未选则当前项目）；
    /// 指定其他项目时会把当前项目切过去——否则新请求在侧栏里根本看不见，
    /// `selectedNodeID` 还会悬空。
    func saveAsNewRequest(name: String, intoProject projectID: UUID? = nil, intoFolder folderID: UUID?) {
        let requested = projectID ?? saveSheetProjectID
        let targetID = requested.flatMap { id in
            workspace.projects.contains { $0.id == id } ? id : nil
        } ?? workspace.activeProjectID
        guard let index = workspace.projects.firstIndex(where: { $0.id == targetID }) else { return }

        let tabID = saveSheetTabID ?? activeTabID
        // 内容也取**发起保存那一格**的草稿：归属与内容必须来自同一格，
        // 否则弹窗期间切走会让 A 格绑上新节点、内容却是 B 格的。
        let sourceIndex = tabIndex(tabID)
        var request = sourceIndex.map { tabs[$0].draft } ?? draft
        let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? t(.untitledRequest) : name
        request.name = finalName
        let node = CollectionNode.request(.init(name: finalName, request: request))

        workspace.activeProjectID = targetID
        // 换项目后，指向旧项目的保存目标 / 选中项都要作废，免得插进不存在的文件夹。
        dropStaleNodeReferences()
        insert(node, intoProject: index, intoFolder: folderID)
        selectedNodeID = node.id
        // 归属与基线一起落到**发起保存的那格**：弹窗期间用户可能已经切走了。
        if let tabIndex = tabIndex(tabID) {
            tabs[tabIndex].draft = request
            tabs[tabIndex].nodeID = node.id
            tabs[tabIndex].baseline = request
        }
        save()
    }

    /// 覆盖当前页签绑定的已保存请求。返回是否真的写入了（归属失效时为 false）。
    @discardableResult
    func overwriteCurrentRequest() -> Bool {
        guard let id = editingNodeID else { return false }
        return overwriteSavedRequest(id: id, with: draft)
    }

    /// 用给定请求覆盖指定的已保存节点（原地替换，保留位置与 id）。
    ///
    /// 跨项目查找：页签归属理论上总在当前项目里，但归属是持久化的，
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
        // 基线推进到绑定该节点的页签。
        // 同一个已保存请求至多占一格（`openSavedRequest` 复用已有页签），所以这里
        // 只会命中一格——「一个请求开两格」不是可达状态，不为它留循环。
        if let tabIndex = tabs.firstIndex(where: { $0.nodeID == id }) {
            tabs[tabIndex].draft = updated
            tabs[tabIndex].baseline = updated
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
        // 每个打开该请求的页签都要改名：漏掉的那格标题会一直是旧名字，
        // 而且它一旦保存就把旧名字写回去。
        for tabIndex in tabs.indices where tabs[tabIndex].nodeID == id {
            tabs[tabIndex].draft.name = trimmed
            tabs[tabIndex].baseline.name = trimmed
        }
        save()
    }

    func deleteNode(id: UUID) {
        guard let index = activeProjectIndex,
              workspace.projects[index].children.removeNode(id: id) else { return }
        // 被删的可能是「正在编辑请求」所在的文件夹。删除后若某页签的归属已不在树里，
        // 必须清掉——否则 ⌘S 会静默无效（overwriteCurrentRequest 找不到节点直接 return）。
        // 清掉归属等于把那格降级成「新请求」，用户还能另存一份。
        for tabIndex in tabs.indices {
            if let nodeID = tabs[tabIndex].nodeID, workspace.projects.findNode(id: nodeID) == nil {
                tabs[tabIndex].nodeID = nil
            }
        }
        if let selected = selectedNodeID, workspace.projects.findNode(id: selected) == nil {
            selectedNodeID = nil
        }
        save()
    }

    /// 拖拽移动是否合法（侧栏在拖动时用它决定是否显示插入线 / 高亮）。
    func canMoveNode(id: UUID, to target: NodeMoveTarget) -> Bool {
        activeProject?.children.canMoveNode(id: id, to: target) ?? false
    }

    /// 把节点移动到目标位置并落盘。
    ///
    /// **不改选中项**：拖拽只改变结构，不应该顺带打开/切换编辑器。
    /// 节点 id 保持不变，所以页签归属、示例归属、默认保存文件夹都继续有效。
    @discardableResult
    func moveNode(id: UUID, to target: NodeMoveTarget) -> Bool {
        guard let index = activeProjectIndex else { return false }
        var children = workspace.projects[index].children
        guard children.moveNode(id: id, to: target) else {
            NSSound.beep()
            return false
        }
        workspace.projects[index].children = children
        save()
        return true
    }

    /// 侧栏历史区的展开状态。写进 settings 是为了重启后保持用户的选择。
    func setHistoryExpanded(_ expanded: Bool) {
        guard workspace.settings.historyExpanded != expanded else { return }
        workspace.settings.historyExpanded = expanded
        save()
    }

    func requestClearHistory() {
        guard !visibleHistory.isEmpty else { return }
        showClearHistoryConfirm = true
    }

    /// 清空**当前项目**的历史（别的项目的记录不动，与按项目隔离一致）。
    func clearHistory() {
        guard let id = workspace.activeProjectID else { return }
        workspace.history.removeAll { $0.projectID == id }
        showClearHistoryConfirm = false
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
        saveSheetTabID = activeTabID
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
        saveSheetTabID = nil

        // 「保存并关闭」的路径：页签已归属并落盘，接着把它关掉。
        if closeAfterSave, let id = pendingCloseTabID {
            closeAfterSave = false
            closeTab(id: id)
        }
    }

    /// 根据 URL 推测一个默认名称（保存弹窗的预填）。
    /// 占位名判定与 `requestNameForHistory` 同构（双语）。
    /// 内部可见：占位名判定是语义陷阱，测试直接覆盖（见 LocalizationTests 第 8 项）。
    func suggestedName() -> String { tabTitle(activeTab) }

    /// 页签标题：优先请求名，其次 URL 末段，最后「未命名请求」。
    /// 与 `suggestedName()` 同源——页签上显示什么，保存弹窗就默认什么。
    func tabTitle(_ tab: EditorTab) -> String {
        let trimmed = tab.draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !Self.isPlaceholderRequestName(trimmed) { return trimmed }
        if let url = URL(string: tab.draft.url), !url.lastPathComponent.isEmpty {
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
        let project = Project(name: result.collectionName, children: result.nodes)
        workspace.projects.append(project)
        // 导入即激活新项目（编辑器随侧重置）；有未保存修改时先进确认框。
        activateProject(project.id)
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
            activateProject(project.id)

        case .currentProject:
            guard let index = activeProjectIndex else { return 0 }
            workspace.projects[index].children.append(contentsOf: nodes)
        }

        dropStaleNodeReferences()
        save()

        // 导入后自动打开第一个导入的请求：贴一条 curl 的下一步就是发它。
        // 走的是 `openSavedRequest` 那条路（同一个请求已打开则复用页签），
        // 草稿各躺在自己的页签里，所以这一步不会覆盖任何已输入的内容。
        if let first = nodes.first {
            openSavedRequest(first)
        }
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

    /// 侧栏内容整体更换（切项目 / 删项目 / 导入）后，清掉指向「已不存在的节点」的瞬态引用。
    ///
    /// 不清的后果是静默失效：页签归属悬空 → ⌘S 静默无效；
    /// `defaultSaveFolderID` / `saveSheetFolderID` 悬空 → 保存弹窗把节点
    /// 插进一个不存在的文件夹（`insert` 找不到目标只返回 false）。
    ///
    /// **页签归属按全局判定**：切到别的项目不该让「B 项目请求」的页签丢掉归属，
    /// 只有节点真的从工作区里消失（被删 / 所在项目被删）才降级成「新请求」。
    private func dropStaleNodeReferences() {
        for index in tabs.indices {
            if let nodeID = tabs[index].nodeID, workspace.projects.findNode(id: nodeID) == nil {
                tabs[index].nodeID = nil
            }
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

    /// 切换当前项目（侧栏项目切换器）。编辑器随侧重置，见 `activateProject`。
    func selectProject(id: UUID) {
        activateProject(id)
    }

    /// 「激活一个项目」的统一入口：侧栏选择、新建、导入、文件夹提为项目都走它。
    ///
    /// **编辑器与侧栏同属一个项目上下文**：切过去之后右侧必须换成新项目的状态，
    /// 否则会出现「侧栏是 A 项目、编辑器里却是 B 项目的请求」——发送、⌘S、
    /// 保存目标全部对着看不见的目录树操作。页签（含未保存的修改）按归属去留：
    /// 归属在新项目里的保留，其余关闭（见 `resetEditorToActiveProject`）。
    ///
    /// 有未保存修改时先弹确认：切换即丢弃，与关页签/清历史同一纪律。
    private func activateProject(_ id: UUID) {
        guard id != workspace.activeProjectID,
              workspace.projects.contains(where: { $0.id == id }) else { return }
        guard !tabs.contains(where: { $0.isDirty }) else {
            pendingProjectActivationID = id
            showProjectSwitchConfirm = true
            return
        }
        performProjectActivation(id)
    }

    /// 确认框的「保存并切换」：先一键保存所有脏页签，再切换。
    ///
    /// 保存是同步完成的（`saveDirtyTabs`），所以切换后的重置不会丢任何已保存内容；
    /// 保存落在**当前项目**里——用户切走之后回来还能找到。
    func saveAndConfirmProjectSwitch() {
        guard let id = pendingProjectActivationID else { return }
        showProjectSwitchConfirm = false
        pendingProjectActivationID = nil
        saveDirtyTabs()
        performProjectActivation(id)
        activatePendingImportEnvironment()
    }

    /// 确认框的「放弃修改」：不保存，直接切换。
    func discardAndConfirmProjectSwitch() {
        guard let id = pendingProjectActivationID else { return }
        showProjectSwitchConfirm = false
        pendingProjectActivationID = nil
        performProjectActivation(id)
        activatePendingImportEnvironment()
    }

    /// 确认框的「取消」（含 Esc / 点弹窗外）：切换不发生，编辑器原地留着。
    ///
    /// 顺带清一次悬空引用：新建/导入/提为项目这几条路在确认前就已经改了工作区
    /// （项目已建、文件夹已搬），被搬走的节点可能正是当时的选中项。
    func cancelProjectSwitch() {
        pendingProjectActivationID = nil
        pendingImportEnvironmentID = nil
        showProjectSwitchConfirm = false
        dropStaleNodeReferences()
    }

    private func activatePendingImportEnvironment() {
        guard let id = pendingImportEnvironmentID else { return }
        pendingImportEnvironmentID = nil
        selectEnvironment(id: id)
    }

    /// 当前有几个页签存在未保存的修改（切换确认文案用）。
    var dirtyTabCount: Int { tabs.filter { $0.isDirty }.count }

    /// 一键保存所有脏页签（切换项目前的「保存并切换」）。
    ///
    /// - 已归属的页签：原地覆盖对应节点（与 ⌘S 同一条路）；
    /// - 未归属的页签：按页签标题（`tabTitle`，与保存弹窗预填同一套规则）存进
    ///   **当前项目**根目录。不弹命名框——「一键保存」的意义就是不打断用户，
    ///   名字之后随时能改；否则 N 个未归属页签要弹 N 次窗，等于没做。
    private func saveDirtyTabs() {
        guard let projectIndex = activeProjectIndex else { return }
        for tab in tabs where tab.isDirty {
            if let nodeID = tab.nodeID, overwriteSavedRequest(id: nodeID, with: tab.draft) {
                continue
            }
            let name = tabTitle(tab)
            var request = tab.draft
            request.name = name
            let node = CollectionNode.request(.init(name: name, request: request))
            insert(node, intoProject: projectIndex, intoFolder: nil)
            if let index = tabIndex(tab.id) {
                tabs[index].draft = request
                tabs[index].baseline = request
                tabs[index].nodeID = node.id
            }
        }
        save()
    }

    private func performProjectActivation(_ id: UUID) {
        workspace.activeProjectID = id
        resetEditorToActiveProject()
        dropStaleNodeReferences()
        save()
    }

    /// 把编辑器重置成「只属于当前项目」的状态：归属不在当前项目里的页签全部关闭
    /// （在飞请求一并取消、归并器一并释放），归属在内的保留；一格不剩就补空页签。
    ///
    /// **保留而不是一律清空**：「文件夹提为项目」时，页签归属的节点随文件夹一起
    /// 搬进新项目——那正是用户当时在编辑的东西，关掉它是白丢数据。其余路径
    /// （切项目 / 新建 / 导入）没有能留下来的归属，效果就是一个空页签。
    private func resetEditorToActiveProject() {
        for tab in tabs {
            let belongsHere = tab.nodeID.map { activeProject?.children.findNode(id: $0) != nil } ?? false
            if belongsHere { continue }
            if tab.isSending {
                // 在飞请求随页签一起取消：否则结果回来时页签已经不在，连接白占着。
                executor().cancel(token: tab.id)
            }
            // 归并器必须跟着页签一起消失：它持有该页签的拼接文本（最多 64 × 512 KB）。
            liveMergers[tab.id] = nil
        }
        tabs.removeAll { tab in
            guard let nodeID = tab.nodeID else { return true }
            return activeProject?.children.findNode(id: nodeID) == nil
        }
        if tabs.isEmpty {
            let fresh = EditorTab(draft: APIRequest())
            tabs = [fresh]
            activeTabID = fresh.id
            selectedNodeID = nil
        } else if !tabs.contains(where: { $0.id == activeTabID }) {
            activeTabID = tabs[0].id
        }
    }

    /// 新建项目并设为当前。空名兜底「新建项目」。
    @discardableResult
    func newProject(name: String) -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = Project(name: trimmed.isEmpty ? t(.newProjectDefaultName) : trimmed)
        workspace.projects.append(project)
        // 有未保存修改时项目已建成、但不激活（确认后由 saveAndConfirm/discardAndConfirm
        // 补上切换）。取消也不会删掉它——静默删用户刚建的项目比「留在列表里未激活」更糟。
        activateProject(project.id)
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
        // 被删项目里的节点全部消失：相关页签归属、选中项、保存目标一并清掉。
        dropStaleNodeReferences()
        save()
    }

    /// 把当前项目的顶层文件夹提为独立项目（子节点原样成为新项目的 children）。
    ///
    /// 旧数据迁移后用户会想把原来的顶层文件夹整理成项目，这是唯一需要的方向；
    /// 通用的跨项目移动 / 拖拽 v1 明确不做。
    ///
    /// 激活新项目走 `activateProject`：正在编辑被提走节点的那一格会保留
    /// （节点随文件夹搬进了新项目），其余归属在原项目里的页签随之关闭。
    func promoteFolderToProject(id: UUID) {
        guard let index = activeProjectIndex,
              let folderIndex = workspace.projects[index].children.firstIndex(where: { $0.id == id }),
              case .folder(let folder) = workspace.projects[index].children[folderIndex] else { return }
        workspace.projects[index].children.remove(at: folderIndex)
        let project = Project(name: folder.name, children: folder.children)
        workspace.projects.append(project)
        activateProject(project.id)
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


    // MARK: - OpenAPI / Swagger 导入

    struct OpenAPIImportPreview: Identifiable {
        let id = UUID()
        var fileName: String
        var result: OpenAPIImportResult
    }

    enum OpenAPIImportTarget: Hashable {
        case newProject
        case currentProject
    }

    var openAPIImportPreview: OpenAPIImportPreview?
    var showOpenAPIImportSheet = false
    var openAPIImportTarget: OpenAPIImportTarget = .newProject
    var openAPIImportName = ""

    func beginOpenAPIImport(result: OpenAPIImportResult, fileName: String) {
        openAPIImportPreview = OpenAPIImportPreview(fileName: fileName, result: result)
        openAPIImportName = result.title
        openAPIImportTarget = .newProject
        showOpenAPIImportSheet = true
    }

    func cancelOpenAPIImport() {
        showOpenAPIImportSheet = false
        openAPIImportPreview = nil
        openAPIImportName = ""
    }

    /// 落盘：新项目直接承载 tag 文件夹；并入当前项目时在外面再包一层同名文件夹，
    /// 避免导入的 tag 与手头已有的文件夹混在一起。
    func commitOpenAPIImport() {
        guard let preview = openAPIImportPreview else { return }
        let result = preview.result
        let trimmed = openAPIImportName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? result.title : trimmed
        let target = openAPIImportTarget
        let currentProjectName = activeProject?.name ?? ""

        showOpenAPIImportSheet = false
        openAPIImportPreview = nil
        openAPIImportName = ""

        var importedProjectID: UUID?
        switch target {
        case .newProject:
            let project = Project(name: name, children: result.nodes)
            workspace.projects.append(project)
            importedProjectID = project.id

        case .currentProject:
            guard let index = activeProjectIndex else { return }
            workspace.projects[index].children.append(
                .folder(.init(name: name, children: result.nodes))
            )
        }

        var importedEnvironmentID: UUID?
        if let environment = result.environment {
            var created = environment
            created.name = uniqueEnvironmentName(created.name)
            workspace.environments.append(created)
            importedEnvironmentID = created.id
        }

        if let projectID = importedProjectID {
            activateProject(projectID)
            if pendingProjectActivationID == projectID {
                pendingImportEnvironmentID = importedEnvironmentID
            } else if let environmentID = importedEnvironmentID {
                workspace.activeEnvironmentID = environmentID
            }
        } else if workspace.activeEnvironmentID == nil, let environmentID = importedEnvironmentID {
            // 并入现有项目时保留用户选中的环境，避免改变已有请求的目标。
            workspace.activeEnvironmentID = environmentID
        }

        dropStaleNodeReferences()
        save()

        switch target {
        case .newProject:
            alertMessage = AlertMessage(text: t(.openAPIImportedNewProject, result.requestCount, name))
        case .currentProject:
            alertMessage = AlertMessage(text: t(.openAPIImportedCurrentProject, result.requestCount, currentProjectName))
        }
    }

    private func uniqueEnvironmentName(_ base: String) -> String {
        let names = Set(workspace.environments.map(\.name))
        guard names.contains(base) else { return base }
        var index = 2
        while names.contains("\(base) (\(index))") { index += 1 }
        return "\(base) (\(index))"
    }

    // MARK: - 保存

    /// 把当前页签状态写进 workspace 并防抖落盘。
    func save() {
        syncTabsToWorkspace()
        persistence.scheduleSave(workspace)
    }

    /// 立即落盘(退出前)。
    func saveImmediately() {
        syncTabsToWorkspace()
        persistence.saveNow(workspace)
    }

    /// 把运行期的页签列表与当前页签同步进工作区（落盘前的唯一写入口）。
    private func syncTabsToWorkspace() {
        workspace.tabs = tabs
        // 当前页签 id 必须落在 tabs 里，否则下次启动的兜底逻辑会白跑一趟。
        workspace.activeTabID = tabs.contains { $0.id == activeTabID } ? activeTabID : tabs.first?.id
    }
}
