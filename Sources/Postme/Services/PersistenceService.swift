import Foundation

/// workspace.json 的读写。
///
/// 单文件 + 防抖写盘：状态变更调用 `scheduleSave`，600ms 内的多次变更合并成一次落盘；
/// 退出前调用 `saveNow`，**同步等待写完成**后再返回。
@MainActor
final class PersistenceService {

    private let directory: URL
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    /// 串行写队列。
    /// 串行的意义是保证落盘顺序：并发队列下，「防抖写」与「立即写」可能乱序完成，
    /// 导致旧快照覆盖新快照。
    private let writeQueue = DispatchQueue(label: "dev.postme.persistence", qos: .utility)

    init(fileName: String = "workspace.json", directory: URL? = nil) {
        let base: URL
        if let directory {
            base = directory
        } else {
            let support = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
            base = support.appendingPathComponent("postme", isDirectory: true)
        }
        self.directory = base
        self.fileURL = base.appendingPathComponent(fileName)
    }

    /// 存储路径（供设置界面展示）。
    var storagePath: String { fileURL.path }

    /// 读取。文件不存在返回空工作区；解析失败则备份坏文件后返回空，避免静默丢数据。
    func load() -> Workspace {
        guard let data = try? Data(contentsOf: fileURL) else {
            return Workspace()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let workspace = try? decoder.decode(Workspace.self, from: data) {
            return workspace
        }
        let backup = fileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: fileURL, to: backup)
        print("[postme] workspace.json 解析失败，已备份为 \(backup.lastPathComponent)，以空工作区启动")
        return Workspace()
    }

    /// 防抖保存。
    func scheduleSave(_ workspace: Workspace) {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            guard let self, let data = Self.encode(workspace) else { return }
            let url = self.fileURL
            self.writeQueue.async {
                Self.performWrite(data, to: url)
            }
        }
    }

    /// 立即保存，**返回时数据已落盘**。
    ///
    /// 必须同步：`applicationWillTerminate` 返回后进程随即退出，若只把写盘丢给后台队列，
    /// 那个块不保证来得及执行，防抖窗口内的改动就会丢失。
    /// 用串行队列 `sync` 还能顺带保证：先前排队的异步写先完成，不会乱序覆盖。
    func saveNow(_ workspace: Workspace) {
        saveTask?.cancel()
        guard let data = Self.encode(workspace) else { return }
        let url = fileURL
        writeQueue.sync {
            Self.performWrite(data, to: url)
        }
    }

    // MARK: - 不依赖实例状态，声明为 nonisolated static 以便在写队列上直接调用

    nonisolated private static func encode(_ workspace: Workspace) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(workspace) else {
            print("[postme] workspace 编码失败，本次未保存")
            return nil
        }
        return data
    }

    nonisolated private static func performWrite(_ data: Data, to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            print("[postme] 保存 workspace 失败: \(error)")
        }
    }
}
