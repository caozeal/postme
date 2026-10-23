import Foundation

/// 应用设置（持久化到 workspace.json）。
struct AppSettings: Codable, Hashable {
    var timeout: TimeInterval
    var followRedirects: Bool
    var allowInsecureTLS: Bool
    /// 界面语言。`nil` = 跟随系统。
    ///
    /// 容错解码：缺键或未知值都得到 `nil`（回到跟随系统），不让整份工作区作废——
    /// 手改过的 `language` 值不该把用户的项目和环境一起弄丢。
    var language: AppLanguage?
    /// 侧栏底部的历史区是否展开。默认收起：历史是查证用的，不该一进来就占掉半屏目录树。
    var historyExpanded: Bool
    /// 「大模型输出」的自定义字段路径（跨启动保留）。
    ///
    /// 容错解码：缺键 → 空数组；非法项**在读取时过滤掉**，不让一个手改坏的路径
    /// 把整份工作区判成损坏（那样用户的项目和环境会一起消失）。
    var llmFieldPaths: [String]
    /// 是否启用会话内 Cookie Jar（保存响应 Set-Cookie，并在后续请求回带）。
    /// 默认关闭：调试器不该悄悄携带登录态。
    var cookieJarEnabled: Bool

    init(
        timeout: TimeInterval = 30,
        followRedirects: Bool = true,
        allowInsecureTLS: Bool = false,
        language: AppLanguage? = nil,
        historyExpanded: Bool = false,
        llmFieldPaths: [String] = [],
        cookieJarEnabled: Bool = false
    ) {
        self.timeout = timeout
        self.followRedirects = followRedirects
        self.allowInsecureTLS = allowInsecureTLS
        self.language = language
        self.historyExpanded = historyExpanded
        self.llmFieldPaths = llmFieldPaths
        self.cookieJarEnabled = cookieJarEnabled
    }

    /// 容错解码（见 `TolerantDecoding.swift`）。旧版本文件没有 settings 键时
    /// 应当取默认值，而不是让整份工作区解码失败。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            timeout: c.tolerant(.timeout, 30),
            followRedirects: c.tolerant(.followRedirects, true),
            allowInsecureTLS: c.tolerant(.allowInsecureTLS, false),
            language: c.tolerantOptional(.language),
            historyExpanded: c.tolerant(.historyExpanded, false),
            llmFieldPaths: Self.sanitizedPaths(c.tolerant(.llmFieldPaths, [String]())),
            cookieJarEnabled: c.tolerant(.cookieJarEnabled, false)
        )
    }

    /// 只留下合法路径，保序去重。非法项被静默丢弃（它们是手改文件的产物，不是用户当前意图）。
    static func sanitizedPaths(_ raw: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for path in raw {
            guard let canonical = LLMStreamMerger.canonicalPath(
                path.trimmingCharacters(in: .whitespacesAndNewlines)
            ) else { continue }
            if seen.insert(canonical).inserted { result.append(canonical) }
        }
        return result
    }

    var executorOptions: RequestExecutorOptions {
        // 钳制超时：workspace.json 是明文、可手改也可 git 编辑的，
        // 脏数据（0 / 负数 / 极大值）不应让请求立即失败或长时间挂死。
        let timeout = min(max(self.timeout, 1), 3600)
        return RequestExecutorOptions(
            timeout: timeout,
            followRedirects: followRedirects,
            allowInsecureTLS: allowInsecureTLS
        )
    }
}

/// 全部持久化数据的根容器。单文件 workspace.json，简化读写与防抖。
struct Workspace: Codable {
    var version: Int
    /// 项目列表。侧栏一次只展示当前项目（`activeProjectID`）的目录树。
    var projects: [Project]
    /// 当前项目。nil 或悬空时由 `AppState.ensureActiveProject()` 兜底。
    var activeProjectID: UUID?
    var environments: [APIEnvironment]
    var activeEnvironmentID: UUID?
    var history: [HistoryEntry]
    var settings: AppSettings
    /// 打开中的请求页签（v4 起）。空数组表示「上次退出时一个页签都没有」，
    /// 由 `AppState` 补一个空页签——不变量是编辑器恒有一个可写对象。
    var tabs: [EditorTab]
    /// 当前页签 id。nil 或悬空时由 `AppState` 兜底到第一个页签。
    var activeTabID: UUID?

    /// 历史条数上限，避免文件无限增长。
    static let historyLimit = 200

    /// 当前工作区格式版本。v2 起字段解码容错（缺键取默认值）；
    /// v3 起顶层为项目层级（`projects`）；v4 起编辑器改多页签（`tabs`）；
    /// v5 起落盘拆成三个文件——`workspace.json` 只存核心（项目/环境/设置），
    /// 页签与历史分别在 `tabs.json` / `history.json`（见 `PersistenceService`）。
    /// 解码仍接受 v4 及更早的单文件形状，首次保存时完成迁移。
    static let currentVersion = 5

    /// 能独立证明"这是一个工作区文件"的顶层键。
    ///
    /// 刻意**不含 `version`**：只有 `{"version": N}` 的无关 JSON 不该被当成空工作区
    /// 载入——那样它会被下一次保存直接覆盖，用户既没备份也没提示。
    /// 任何一个真正的 postme 工作区都必然带这些键之一。
    /// `collections` 是 v3 之前的旧键、`draft`/`draftNodeID` 是 v4 之前的旧键，
    /// 保留它们旧文件才不会被误判为损坏。
    private static let identifyingKeys: [CodingKeys] = [
        .projects, .collections, .environments, .activeEnvironmentID, .history, .settings,
        .tabs, .activeTabID, .draft, .draftNodeID
    ]

    /// 手写 `init(from:)` 与 `encode(to:)` 都会抑制 CodingKeys 的自动合成，这里显式声明。
    /// `collections` / `draft` / `draftNodeID` 仅用于读取旧文件，编码时不再写出。
    enum CodingKeys: String, CodingKey {
        case version, projects, activeProjectID, collections, environments, activeEnvironmentID, history, settings
        case tabs, activeTabID
        case draft, draftNodeID
    }

    init(
        version: Int = Workspace.currentVersion,
        projects: [Project] = [],
        activeProjectID: UUID? = nil,
        environments: [APIEnvironment] = [],
        activeEnvironmentID: UUID? = nil,
        history: [HistoryEntry] = [],
        settings: AppSettings = AppSettings(),
        tabs: [EditorTab] = [],
        activeTabID: UUID? = nil
    ) {
        self.version = version
        self.projects = projects
        self.activeProjectID = activeProjectID
        self.environments = environments
        self.activeEnvironmentID = activeEnvironmentID
        self.history = history
        self.settings = settings
        self.tabs = tabs
        self.activeTabID = activeTabID
    }

    /// 容错解码。
    ///
    /// **为什么需要它**：合成解码要求所有非可选键都在，缺一个就让整份文件解码失败，
    /// 而 `PersistenceService.load()` 会把失败的文件搬成 `.corrupt-*` 并以空工作区启动——
    /// 用户的集合、环境、历史一次性全没。加一个字段就能触发这条路径，是定时炸弹。
    ///
    /// **但容错有底线**：文件必须是 JSON 对象，且至少包含一个能识别工作区的顶层键
    /// （见 `identifyingKeys`；`version` 不算，单独一个 `{"version":7}` 不该被认领）。
    /// 否则仍抛错，让 `load()` 走备份路径——把不相干的文件静默当成空工作区、
    /// 再被下次保存覆盖，比报损坏更糟。
    ///
    /// **v3 迁移**：旧文件顶层是 `collections`，整体收进一个「默认项目」，
    /// 节点 id 原样保留；`activeProjectID` 缺失或悬空时自愈到第一个项目。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        guard Workspace.identifyingKeys.contains(where: { c.contains($0) }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: c,
                debugDescription: "文件不含任何已知工作区字段，判定为损坏"
            )
        }

        // projects 与 collections 的权威规则：文件里出现 `projects` 键（哪怕空数组）
        // 就认它，忽略旧键——与 `Item` 解码「缺失与空数组必须区分」是同一种纪律。
        // v3 正常不会写出 collections，两者并存只可能来自手改，简单可测比恢复魔法重要。
        let projects: [Project]
        if c.contains(.projects) {
            projects = c.tolerantLossyArray(.projects)
        } else if c.contains(.collections) {
            let legacy: [CollectionNode] = c.tolerantLossyArray(.collections)
            // 空集合不造项目：与全新工作区一致（0 个项目），由 ensureActiveProject 兜底。
            projects = legacy.isEmpty ? [] : [Project(name: "默认项目", children: legacy)]
        } else {
            projects = []
        }

        // activeProjectID 自愈：缺失或指向不存在的项目时落到第一个项目。
        // 自愈发生在解码阶段，第一次落盘后即收敛，不会每次保存都改写。
        let storedActiveID: UUID? = c.tolerantOptional(.activeProjectID)
        let resolvedActiveID = storedActiveID.flatMap { id in
            projects.contains { $0.id == id } ? id : nil
        } ?? projects.first?.id

        // 页签与旧草稿的权威规则：文件里出现 `tabs` 键（哪怕空数组）就认它，忽略旧键。
        // v4 之前的文件只有单草稿 `draft` + 归属 `draftNodeID`，迁移成一个页签；
        // 单个畸形页签由 tolerantLossyArray 丢弃，不影响其余页签。
        let tabs: [EditorTab]
        if c.contains(.tabs) {
            tabs = c.tolerantLossyArray(.tabs)
        } else if let legacyDraft: APIRequest = c.tolerantOptional(.draft) {
            tabs = [EditorTab(draft: legacyDraft, nodeID: c.tolerantOptional(.draftNodeID))]
        } else {
            tabs = []
        }

        // 悬空的 activeTabID 落到第一个页签；一个都没有就交给 AppState 补空页签。
        let storedTabID: UUID? = c.tolerantOptional(.activeTabID)
        let resolvedTabID = storedTabID.flatMap { id in
            tabs.contains { $0.id == id } ? id : nil
        } ?? tabs.first?.id

        self.init(
            version: Workspace.currentVersion,
            projects: projects,
            activeProjectID: resolvedActiveID,
            environments: c.tolerant(.environments, []),
            activeEnvironmentID: c.tolerantOptional(.activeEnvironmentID),
            history: c.tolerant(.history, []),
            settings: c.tolerant(.settings, AppSettings()),
            tabs: tabs,
            activeTabID: resolvedTabID
        )
    }

    /// 只写核心节：`projects` + `environments` + `settings`。
    ///
    /// **为什么不写 `tabs` / `history`**：v5 起这两节各有自己的文件
    /// （`tabs.json` / `history.json`，见 `PersistenceService`）。核心文件若继续写，
    /// 每次按键都要把 200 条历史正文重新编码一遍，拆分就白做了。
    /// 旧键仍然**可读**（见 `init(from:)`），只是不再写出。
    ///
    /// **为什么必须手写**：CodingKeys 里保留了没有存储属性 backing 的键
    /// （`collections` / `draft` / `draftNodeID` / `tabs` / `activeTabID`，仅供读旧文件），
    /// Encodable 的合成实现会因此编译失败。
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(projects, forKey: .projects)
        try c.encodeIfPresent(activeProjectID, forKey: .activeProjectID)
        try c.encode(environments, forKey: .environments)
        try c.encodeIfPresent(activeEnvironmentID, forKey: .activeEnvironmentID)
        try c.encode(settings, forKey: .settings)
    }

    /// 最近的历史在前。
    mutating func pushHistory(_ entry: HistoryEntry) {
        history.insert(entry, at: 0)
        if history.count > Workspace.historyLimit {
            history.removeLast(history.count - Workspace.historyLimit)
        }
    }
}
