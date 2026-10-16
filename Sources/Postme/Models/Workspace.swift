import Foundation

/// 应用设置（持久化到 workspace.json）。
struct AppSettings: Codable, Hashable {
    var timeout: TimeInterval
    var followRedirects: Bool
    var allowInsecureTLS: Bool

    init(timeout: TimeInterval = 30, followRedirects: Bool = true, allowInsecureTLS: Bool = false) {
        self.timeout = timeout
        self.followRedirects = followRedirects
        self.allowInsecureTLS = allowInsecureTLS
    }

    /// 容错解码（见 `TolerantDecoding.swift`）。旧版本文件没有 settings 键时
    /// 应当取默认值，而不是让整份工作区解码失败。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            timeout: c.tolerant(.timeout, 30),
            followRedirects: c.tolerant(.followRedirects, true),
            allowInsecureTLS: c.tolerant(.allowInsecureTLS, false)
        )
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
    var collections: [CollectionNode]
    var environments: [APIEnvironment]
    var activeEnvironmentID: UUID?
    var history: [HistoryEntry]
    var settings: AppSettings
    /// 退出时未保存的编辑中请求（下次启动恢复，避免半成品丢失）。
    var draft: APIRequest?

    /// 历史条数上限，避免文件无限增长。
    static let historyLimit = 200

    /// 当前工作区格式版本。v2 起字段解码容错（缺键取默认值）。
    static let currentVersion = 2

    /// 能独立证明"这是一个工作区文件"的顶层键。
    ///
    /// 刻意**不含 `version`**：只有 `{"version": N}` 的无关 JSON 不该被当成空工作区
    /// 载入——那样它会被下一次保存直接覆盖，用户既没备份也没提示。
    /// 任何一个真正的 postme 工作区都必然带这些键之一。
    private static let identifyingKeys: [CodingKeys] = [
        .collections, .environments, .activeEnvironmentID, .history, .settings, .draft
    ]

    /// 手写 `init(from:)` 会抑制 CodingKeys 的自动合成，这里显式声明。
    enum CodingKeys: String, CodingKey {
        case version, collections, environments, activeEnvironmentID, history, settings, draft
    }

    init(
        version: Int = Workspace.currentVersion,
        collections: [CollectionNode] = [],
        environments: [APIEnvironment] = [],
        activeEnvironmentID: UUID? = nil,
        history: [HistoryEntry] = [],
        settings: AppSettings = AppSettings(),
        draft: APIRequest? = nil
    ) {
        self.version = version
        self.collections = collections
        self.environments = environments
        self.activeEnvironmentID = activeEnvironmentID
        self.history = history
        self.settings = settings
        self.draft = draft
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
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        guard Workspace.identifyingKeys.contains(where: { c.contains($0) }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: c,
                debugDescription: "文件不含任何已知工作区字段，判定为损坏"
            )
        }

        self.init(
            version: Workspace.currentVersion,
            collections: c.tolerant(.collections, []),
            environments: c.tolerant(.environments, []),
            activeEnvironmentID: c.tolerantOptional(.activeEnvironmentID),
            history: c.tolerant(.history, []),
            settings: c.tolerant(.settings, AppSettings()),
            draft: c.tolerantOptional(.draft)
        )
    }

    /// 最近的历史在前。
    mutating func pushHistory(_ entry: HistoryEntry) {
        history.insert(entry, at: 0)
        if history.count > Workspace.historyLimit {
            history.removeLast(history.count - Workspace.historyLimit)
        }
    }
}
