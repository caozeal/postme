import Foundation

/// 工作区的读写：**三个文件，按节落盘**。
///
/// - `workspace.json`：项目、环境、设置等「低频」数据；
/// - `tabs.json`：打开中的页签（编辑器里每敲一个键都会变）；
/// - `history.json`：发送历史（每次发送才变，单条最大，含请求正文快照）。
///
/// **为什么拆**：原先单文件每次保存都要把整份工作区（含 200 条带正文的历史）
/// 重新编码一遍。实测 50 MB 的 workspace.json 单次 encode 132 ms、原子写 87 ms，
/// 而编辑器是**每次按键**触发保存的——文件一大，打字就卡在主线程上。
/// 拆开之后，敲键盘只重写 `tabs.json`（KB 级），历史只在发送后才写。
///
/// **不只拆，还要跳过没变的节**：`WriteState` 记住上一次写出的快照，
/// 内容相同就不重写。启动后第一次保存仍会强制重写一次核心文件——那正是
/// v4 单文件迁移成 v5 三文件的时机（旧文件里的 `tabs`/`history` 键随之消失）。
///
/// 防抖与串行队列的语义保持不变：600 ms 内多次变更合并；串行队列保证
/// 「防抖写」与「退出前的立即写」不会乱序覆盖；`saveNow` 返回时数据已落盘。
@MainActor
final class PersistenceService {

    private let directory: URL
    private let workspaceURL: URL
    private let tabsURL: URL
    private let historyURL: URL
    private let examplesURL: URL
    private var saveTask: Task<Void, Never>?

    /// 保存序号。每次 `scheduleSave` / `saveNow` 自增，写盘时用它丢弃过期的快照。
    /// 单靠 `Task.cancel()` 不够：任务可能已经越过取消检查、正排队等写队列，
    /// 那样一个更旧的快照会在 `saveNow` 之后落盘，把新数据盖回去。
    private var saveGeneration = 0

    /// 最近一次「全部落盘成功」的序号。与 `saveGeneration` 的差值就是「还有没有
    /// 改动没写到磁盘」，比 `EditorTab.isDirty`（草稿 vs 已保存请求）更贴近这里的语义。
    private(set) var lastCommittedGeneration = 0
    var hasUnflushedChanges: Bool { saveGeneration > lastCommittedGeneration }

    /// 每次落盘（防抖或立即）都把结果送回主线程，由 AppState 决定界面怎么显示。
    /// 存闭包而不是反向依赖 AppState，持久化层保持可独立测试。
    var onSaveResult: ((SaveResult, Int) -> Void)?

    /// 串行写队列。
    /// 串行的意义是保证落盘顺序：并发队列下，「防抖写」与「立即写」可能乱序完成，
    /// 导致旧快照覆盖新快照。编码也放在这个队列上——它随文件大小变慢，
    /// 不该占用主线程。
    private let writeQueue = DispatchQueue(label: "dev.postme.persistence", qos: .utility)

    /// 上一次写出的各节内容。**只在 `writeQueue` 上读写**（`load()` 除外，
    /// 那时还没有任何写操作）。
    private let writeState = WriteState()

    init(fileName: String = "workspace.json", directory: URL? = nil) {
        let base = directory ?? WorkspaceDirectory.defaultURL()
        self.directory = base
        self.workspaceURL = base.appendingPathComponent(fileName)
        self.tabsURL = base.appendingPathComponent("tabs.json")
        self.historyURL = base.appendingPathComponent("history.json")
        self.examplesURL = base.appendingPathComponent("examples.json")
        // 基准取构造时的磁盘状态：不少用例不调 load() 就直接 saveNow，
        // 空基准会让第一次保存被误判成冲突。
        self.writeState.fingerprint = DiskFingerprint.capture(directory: base)
    }

    /// 存储目录（供设置界面展示）。三个文件都在这个目录里。
    var storagePath: String { directory.path }

    /// 存储目录（供其他侧车文件使用，例如 `examples.json`）。
    var directoryURL: URL { directory }

    /// 读取并合并三份文件。
    ///
    /// - 核心文件不存在 → 空工作区；
    /// - 核心文件损坏 → 备份后以空工作区启动（绝不静默覆盖原文件）；
    /// - 侧车（`tabs.json` / `history.json`）缺失 → 回落到核心文件里的旧键
    ///   （v4 及更早的单文件格式），并在下一次保存时写成独立的侧车；
    /// - 侧车损坏 → 备份该侧车，对应那一节为空（核心文件仍可用）。
    func load() -> Workspace {
        // load() 会连读多份文件，且 corrupt 备份会 moveItem；在锁内读可避免读到
        // 别的进程写了一半的跨文件快照。抢不到锁时仍要读（读不该因别人正在写而
        // 失败），只是这一次的一致性没有额外保证。
        do {
            return try WorkspaceLock.withExclusiveLock(directory: directory) { loadUnlocked() }
        } catch {
            return loadUnlocked()
        }
    }

    /// 不加锁的载入主体，供 `load()` 与 `reloadFromDisk()` 复用。
    /// 重载路径已经持锁，绝不能在这里再套一层（flock 同进程重复 open 会自冲突）。
    private func loadUnlocked() -> Workspace {
        var workspace = loadWorkspaceCore()

        // 侧车存在就以它为准（哪怕它是空数组）；不存在才回落到 v4 单文件里的旧键。
        var tabsBaseline: TabsSnapshot?
        if let file = loadSidecar(TabsFile.self, url: tabsURL, name: "tabs.json") {
            tabsBaseline = TabsSnapshot(activeTabID: file.activeTabID, tabs: file.tabs)
            let tabs = file.tabs.map(\.editorTab)
            workspace.tabs = tabs
            workspace.activeTabID = file.activeTabID.flatMap { id in
                tabs.contains { $0.id == id } ? id : nil
            } ?? tabs.first?.id
        }

        var historyBaseline: [HistoryEntry]?
        if let file = loadSidecar(HistoryFile.self, url: historyURL, name: "history.json") {
            historyBaseline = file.history
            workspace.history = file.history
        }

        // 首次保存的基准：
        // - 核心一律重写一次（v4 → v5 迁移要把旧 tabs/history 键从核心文件里去掉）；
        // - 侧车真读到过才记成"已落盘"，缺失/损坏时留 nil，下次保存补写。
        writeState.core = nil
        writeState.tabs = tabsBaseline
        writeState.history = historyBaseline
        // 基准必须在备份副作用之后取，否则「坏文件被搬走」会让自己下次保存误报冲突。
        writeState.fingerprint = DiskFingerprint.capture(directory: directory)
        writeState.failedSections = []
        return workspace
    }

    /// 丢弃在途的防抖写，把磁盘内容重新读进内存基准。
    ///
    /// 光 `saveTask?.cancel()` 不够：已经越过取消检查、排在 writeQueue 上的旧任务
    /// 携带的 generation 可能仍大于 `state.generation`，会把重载前的快照写回去。
    /// 所以还要把 `state.generation` 顶到最新，让所有在途旧任务一律变成 `.stale`。
    @discardableResult
    func reloadFromDisk() -> Workspace {
        saveTask?.cancel()
        saveGeneration += 1
        let generation = saveGeneration
        writeQueue.sync { writeState.generation = generation }
        let loaded: Workspace
        do {
            loaded = try WorkspaceLock.withExclusiveLock(directory: directory) { loadUnlocked() }
        } catch {
            loaded = loadUnlocked()
        }
        lastCommittedGeneration = generation
        return loaded
    }

    /// 生成不与现有文件冲突的备份路径。
    ///
    /// 原先用秒级时间戳：同一秒内两次判损坏时，第二次 `moveItem` 会因目标已存在而失败，
    /// 且失败被 `try?` 吞掉——坏文件留在原地，随即被空工作区的保存覆盖，备份也没了。
    nonisolated static func uniqueBackupURL(for fileURL: URL) -> URL {
        let stamp = Int(Date().timeIntervalSince1970)
        var candidate = fileURL.appendingPathExtension("corrupt-\(stamp)")
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = fileURL.appendingPathExtension("corrupt-\(stamp)-\(suffix)")
            suffix += 1
        }
        return candidate
    }

    /// 防抖保存。
    func scheduleSave(_ workspace: Workspace) {
        saveTask?.cancel()
        saveGeneration += 1
        let paths = persistencePaths()
        let job = FlushJob(workspace: workspace,
                           state: writeState,
                           paths: paths,
                           generation: saveGeneration)
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self else { return }
            let queue = self.writeQueue
            queue.async {
                let result = Self.flush(job.workspace, paths: job.paths, state: job.state, generation: job.generation)
                Task { @MainActor in
                    self.apply(result, generation: job.generation)
                }
            }
        }
    }

    /// 立即保存，返回完整结果。**返回时数据已落盘**。
    ///
    /// 必须同步：退出流程要在返回前知道「到底写成功没有」，若只把写盘丢给后台队列，
    /// 那个块不保证来得及执行，防抖窗口内的改动就会丢失。
    /// 用串行队列 `sync` 还能顺带保证：先前排队的异步写先完成，不会乱序覆盖。
    @discardableResult
    func flushNow(_ workspace: Workspace) -> SaveResult {
        saveTask?.cancel()
        saveGeneration += 1
        let generation = saveGeneration
        let paths = persistencePaths()
        let result = writeQueue.sync {
            Self.flush(workspace, paths: paths, state: writeState, generation: generation)
        }
        apply(result, generation: generation)
        return result
    }

    /// 保留旧的 Bool 入口：既有测试与调用点依赖它，详细结果走 `onSaveResult` 旁路。
    @discardableResult
    func saveNow(_ workspace: Workspace) -> Bool {
        flushNow(workspace).isSuccess
    }

    /// 把一次落盘结果送回主线程。过期结果也要送（调用方要能观察 `.stale`），
    /// 但只有成功且序号更新时才推进「已提交」水位。
    private func apply(_ result: SaveResult, generation: Int) {
        if case .succeeded = result, generation > lastCommittedGeneration {
            lastCommittedGeneration = generation
        }
        onSaveResult?(result, generation)
    }

    /// `examples.json` 的写入同样要经过 CAS 与同一把锁，否则它会绕过基准、
    /// 与三文件写入抢改指纹，形成第二处静默覆盖。
    @discardableResult
    func saveExamples(_ examples: [ResponseExample]) -> SaveResult {
        let paths = persistencePaths()
        let result = writeQueue.sync {
            Self.flushExamples(examples, paths: paths, state: writeState)
        }
        onSaveResult?(result, saveGeneration)
        return result
    }

    private func persistencePaths() -> PersistencePaths {
        PersistencePaths(directory: directory,
                         workspace: workspaceURL,
                         tabs: tabsURL,
                         history: historyURL,
                         examples: examplesURL)
    }

    /// UI 检测用：当前磁盘与基准相比哪些文件变了。
    /// 写前的权威检查仍在 `flush` 的 CAS 临界区里，这里只给界面一个提前提示。
    func externalChangedFiles() -> [String] {
        let baseline = writeQueue.sync { writeState.fingerprint }
        return DiskFingerprint.capture(directory: directory).differingFiles(from: baseline)
    }

    // MARK: - 读取

    private func loadWorkspaceCore() -> Workspace {
        guard let data = try? Data(contentsOf: workspaceURL) else {
            return Workspace()
        }
        if let workspace = Self.decode(Workspace.self, from: data) {
            return workspace
        }
        backupAndReportCorrupt(workspaceURL, name: "workspace.json", data: data)
        return Workspace()
    }

    /// 读一个侧车文件。不存在 → nil（交给核心文件里的旧键兜底）；
    /// 存在但解析失败 → 备份后 nil，让调用方把那一节当空并重写。
    private func loadSidecar<T: Decodable>(_ type: T.Type, url: URL, name: String) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let value = Self.decode(type, from: data) else {
            backupAndReportCorrupt(url, name: name, data: data)
            return nil
        }
        return value
    }

    /// 把坏文件搬成 `.corrupt-*`；搬不动就把坏内容另存一份，原文件保持原地不动——
    /// 那才是真正的静默丢数据。
    private func backupAndReportCorrupt(_ url: URL, name: String, data: Data) {
        let backup = Self.uniqueBackupURL(for: url)
        do {
            try FileManager.default.moveItem(at: url, to: backup)
            print("[postme] \(name) 解析失败，已备份为 \(backup.lastPathComponent)")
        } catch {
            print("[postme] \(name) 解析失败，且备份失败（\(error)）；原文件保持不变")
            try? data.write(to: backup, options: .atomic)
        }
    }

    // MARK: - 写出（只在 writeQueue 上调用）

    /// 一次落盘的完整临界区：读指纹 → 比对基准 → 写 → 重算基准，全程持短锁。
    /// 比对全四个文件，不能按「本次只写哪节」裁剪——否则 CLI 改了 history、
    /// GUI 只写 tabs 时会漏检，之后整份旧 history 会盖回去。
    nonisolated private static func flush(_ workspace: Workspace,
                                          paths: PersistencePaths,
                                          state: WriteState,
                                          generation: Int) -> SaveResult {
        // 比队列里更旧的快照直接丢弃：它来自一次已经被后一次保存取代的调度。
        // 注意返回 .stale 而不是「成功」，否则过期结果会把真实失败标记清掉。
        guard generation > state.generation else { return .stale }
        state.generation = generation

        do {
            return try WorkspaceLock.withExclusiveLock(directory: paths.directory) {
                let current = DiskFingerprint.capture(directory: paths.directory)
                let changed = current.differingFiles(from: state.fingerprint)
                    .filter { !state.failedSections.contains($0) }
                if !changed.isEmpty {
                    return SaveResult.conflict(.fingerprintMismatch(changed))
                }

                var failedNames: [String] = []
                let tabs = TabsSnapshot(activeTabID: workspace.activeTabID,
                                        tabs: workspace.tabs.map(TabRecord.init))
                if state.tabs != tabs {
                    if let data = encode(TabsFile(version: Workspace.currentVersion,
                                                  activeTabID: tabs.activeTabID,
                                                  tabs: tabs.tabs)),
                       performWrite(data, to: paths.tabs, directory: paths.directory, name: "tabs.json") {
                        state.tabs = tabs
                    } else {
                        failedNames.append("tabs.json")
                    }
                }

                // 历史按上限裁剪后再落盘：读入的旧文件可能超限，编码时顺手收敛。
                // 比较用裁剪后的结果，否则每次保存都会因为"原始数组没变、落盘数组被裁"而重写。
                let cappedHistory = Array(workspace.history.prefix(Workspace.historyLimit))
                if state.history != cappedHistory {
                    if let data = encode(HistoryFile(version: Workspace.currentVersion, history: cappedHistory)),
                       performWrite(data, to: paths.history, directory: paths.directory, name: "history.json") {
                        state.history = cappedHistory
                    } else {
                        failedNames.append("history.json")
                    }
                }
                // v4 的核心文件仍含页签和历史。只有两个侧车都已成功落盘，才可移除旧键；
                // 否则一次写入失败或进程中断会让尚未迁出的数据失去唯一副本。
                let core = CoreSnapshot(workspace)
                if failedNames.isEmpty && state.core != core {
                    if let data = encode(workspace),
                       performWrite(data, to: paths.workspace, directory: paths.directory, name: "workspace.json") {
                        state.core = core
                    } else {
                        failedNames.append("workspace.json")
                    }
                }

                // 即使部分失败也要重算基准：tabs 已经换了 inode，若仍留旧基准，
                // 下一次重试会把自己刚写的内容判成外部改动，形成死循环。
                state.fingerprint = DiskFingerprint.capture(directory: paths.directory)
                state.failedSections = Set(failedNames)
                return failedNames.isEmpty ? .succeeded : .failed(failedNames)
            }
        } catch WorkspaceLockError.busy {
            return .conflict(.busy)
        } catch {
            return .failed([paths.workspace.lastPathComponent])
        }
    }

    /// examples.json 与三文件共用同一套 CAS：先比对全目录指纹，再整份写，最后重算基准。
    nonisolated private static func flushExamples(_ examples: [ResponseExample],
                                                  paths: PersistencePaths,
                                                  state: WriteState) -> SaveResult {
        do {
            return try WorkspaceLock.withExclusiveLock(directory: paths.directory) {
                let current = DiskFingerprint.capture(directory: paths.directory)
                let changed = current.differingFiles(from: state.fingerprint)
                    .filter { !state.failedSections.contains($0) }
                if !changed.isEmpty {
                    return SaveResult.conflict(.fingerprintMismatch(changed))
                }
                guard let data = encode(examples),
                      performWrite(data, to: paths.examples, directory: paths.directory, name: "examples.json") else {
                    state.fingerprint = DiskFingerprint.capture(directory: paths.directory)
                    state.failedSections = ["examples.json"]
                    return .failed(["examples.json"])
                }
                state.fingerprint = DiskFingerprint.capture(directory: paths.directory)
                state.failedSections = []
                return .succeeded
            }
        } catch WorkspaceLockError.busy {
            return .conflict(.busy)
        } catch {
            return .failed(["examples.json"])
        }
    }

    nonisolated private static func encode<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            return try encoder.encode(value)
        } catch {
            print("[postme] 编码失败，本次未保存: \(error)")
            return nil
        }
    }

    nonisolated private static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    /// 写一个文件。返回是否成功——失败时**不更新 `WriteState`**，
    /// 下一次保存会重试同一份内容，而不是因为"内容没变"把失败永久跳过去。
    @discardableResult
    nonisolated private static func performWrite(_ data: Data, to url: URL, directory: URL, name: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            print("[postme] 保存 \(name) 失败: \(error)")
            return false
        }
    }
}

// MARK: - 写盘负载

/// 一次待落盘的快照。
///
/// 包一层的唯一目的是绕开 Swift 6 的 `@Sendable` 捕获检查：`Workspace` 与 `WriteState`
/// 都不是 `Sendable`，但它们只会在这个串行写队列上被读写，不存在跨线程重叠。
private struct FlushJob: @unchecked Sendable {
    var workspace: Workspace
    var state: WriteState
    var paths: PersistencePaths
    var generation: Int
}

/// 四个文件的路径。值类型，方便把 nonisolated static 的写盘逻辑与实例解耦。
private struct PersistencePaths: Sendable {
    var directory: URL
    var workspace: URL
    var tabs: URL
    var history: URL
    var examples: URL
}

/// 一次写入的各节内容。内容没变就跳过整份编码与写盘。
///
/// 用结构体相等做比较而不是比较文件字节：`Data` 比较要遍历全部字节，
/// 而这些结构体里的大字符串/数组是引用类型（COW），相等判断通常很快命中。
private final class WriteState {
    /// 已落盘的最新保存序号（只在写队列上读写）。
    var generation = 0
    var core: CoreSnapshot?
    var tabs: TabsSnapshot?
    var history: [HistoryEntry]?
    /// 上次 flush 未能落盘的文件。修复故障（删掉挡路的目录、恢复权限）本身就是磁盘
    /// 变化，这些文件的变化不该被 CAS 当成「别的进程写过」，否则重试永远报冲突。
    var failedSections: Set<String> = []
    /// 上次成功落盘（或 load/reload）后四个文件的磁盘状态，CAS 的基准。
    /// 与 core/tabs/history 一样只在写队列上读写。
    var fingerprint = DiskFingerprint(entries: [:])
}

/// 核心文件的持久化内容。与 `Workspace` 的区别：不含页签与历史。
private struct CoreSnapshot: Equatable {
    var version: Int
    var projects: [Project]
    var activeProjectID: UUID?
    var environments: [APIEnvironment]
    var activeEnvironmentID: UUID?
    var settings: AppSettings

    init(_ workspace: Workspace) {
        version = Workspace.currentVersion
        projects = workspace.projects
        activeProjectID = workspace.activeProjectID
        environments = workspace.environments
        activeEnvironmentID = workspace.activeEnvironmentID
        settings = workspace.settings
    }
}

/// 页签里真正落盘的部分。运行期状态（响应、是否在发、分页）不参与比较，
/// 它们本来就不落盘，也不该触发重写。
private struct TabRecord: Codable, Equatable {
    var id: UUID
    var draft: APIRequest
    var baseline: APIRequest
    var nodeID: UUID?

    init(_ tab: EditorTab) {
        id = tab.id
        draft = tab.draft
        baseline = tab.baseline
        nodeID = tab.nodeID
    }

    init(id: UUID, draft: APIRequest, baseline: APIRequest, nodeID: UUID?) {
        self.id = id
        self.draft = draft
        self.baseline = baseline
        self.nodeID = nodeID
    }

    var editorTab: EditorTab {
        EditorTab(id: id, draft: draft, baseline: baseline, nodeID: nodeID)
    }

    /// 容错解码：单个页签解不出来由父级的 `tolerantLossyArray` 丢弃。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let draft: APIRequest = c.tolerant(.draft, APIRequest())
        self.init(
            id: c.tolerant(.id, UUID()),
            draft: draft,
            baseline: c.tolerant(.baseline, draft),
            nodeID: c.tolerantOptional(.nodeID)
        )
    }
}

private struct TabsSnapshot: Equatable {
    var activeTabID: UUID?
    var tabs: [TabRecord]
}

private struct TabsFile: Codable {
    var version: Int
    var activeTabID: UUID?
    var tabs: [TabRecord]

    init(version: Int, activeTabID: UUID?, tabs: [TabRecord]) {
        self.version = version
        self.activeTabID = activeTabID
        self.tabs = tabs
    }

    enum CodingKeys: String, CodingKey { case version, activeTabID, tabs }

    /// 手写解码以复用逐元素容错：单个坏页签不该让整份页签列表作废。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.tolerant(.version, Workspace.currentVersion)
        activeTabID = c.tolerantOptional(.activeTabID)
        tabs = c.tolerantLossyArray(.tabs)
    }
}

private struct HistoryFile: Codable {
    var version: Int
    var history: [HistoryEntry]

    init(version: Int, history: [HistoryEntry]) {
        self.version = version
        self.history = history
    }

    enum CodingKeys: String, CodingKey { case version, history }

    /// 容错解码：缺键取空数组，单条坏记录只丢自己（与核心文件里的 `history` 同一条纪律）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.tolerant(.version, Workspace.currentVersion)
        history = c.tolerantLossyArray(.history)
    }
}
