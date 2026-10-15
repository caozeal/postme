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

    init(
        version: Int = 1,
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

    /// 最近的历史在前。
    mutating func pushHistory(_ entry: HistoryEntry) {
        history.insert(entry, at: 0)
        if history.count > Workspace.historyLimit {
            history.removeLast(history.count - Workspace.historyLimit)
        }
    }
}
