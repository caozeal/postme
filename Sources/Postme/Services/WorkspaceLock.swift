import Foundation
import Darwin

/// 数据目录的统一定义。锁文件与四个数据文件必须解析到同一个 URL，
/// 否则「锁在 A、数据在 B」等于没有保护。
enum WorkspaceDirectory {
    static let lockFileName = ".postme.lock"
    static let managedFiles = ["workspace.json", "tabs.json", "history.json", "examples.json"]

    static func defaultURL() -> URL {
        // GUI 的 Foundation 不跟随 HOME 环境变量（NSHomeDirectory 返回登录用户的真实目录），
        // 所以隔离验证必须走显式的数据目录变量；CLI 早已支持同名变量，这里让 GUI 一致。
        if let override = ProcessInfo.processInfo.environment["POSTME_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appendingPathComponent("postme", isDirectory: true)
    }
}

enum WorkspaceLockError: Error {
    case busy
    case unavailable(String)
}

/// 跨进程的短时排他锁。
///
/// 为什么锁独立文件而不是 `workspace.json`：`Data.write(options: .atomic)` 会
/// `rename()` 换 inode，flock 绑的是旧 inode，另一进程打开的是新 inode，锁不住。
/// 为什么用 flock 而不是 PID 文件：内核在 fd 关闭 / 进程崩溃时自动释放，无陈旧锁。
/// 为什么 `LOCK_NB`：`saveNow` 在 @MainActor 上同步等写队列，阻塞式加锁会冻结退出流程。
enum WorkspaceLock {
    /// flock 是 per-open-file-description：同一进程对同一路径两次 open 会互相冲突。
    /// 这把进程内锁保证任一时刻本进程对该目录只有一个 fd。
    private static var inProcessLocks: [String: NSLock] = [:]
    private static let registryLock = NSLock()

    private static func inProcessLock(for directory: URL) -> NSLock {
        let key = directory.standardizedFileURL.path
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = inProcessLocks[key] { return existing }
        let lock = NSLock()
        inProcessLocks[key] = lock
        return lock
    }

    /// 在锁内执行 `body`。锁被别的进程占着抛 `.busy`；
    /// 目录本身不可写（只读卷、故障注入的 chmod 0o500）时降级为不加锁继续——
    /// 那种目录本来就写不进去，降级不会放宽任何实际保护。
    static func withExclusiveLock<T>(directory: URL, _ body: () -> T) throws -> T {
        let processLock = inProcessLock(for: directory)
        processLock.lock()
        defer { processLock.unlock() }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(WorkspaceDirectory.lockFileName, isDirectory: false)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            let err = errno
            if Self.canDegrade(err) {
                print("[postme] 无法创建工作区锁（\(String(cString: strerror(err)))），本次不加锁继续")
                return body()
            }
            throw WorkspaceLockError.unavailable(String(cString: strerror(err)))
        }
        defer { close(fd) }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let err = errno
            if err == EWOULDBLOCK || err == EAGAIN { throw WorkspaceLockError.busy }
            if Self.canDegrade(err) {
                print("[postme] 无法加工作区锁（\(String(cString: strerror(err)))），本次不加锁继续")
                return body()
            }
            throw WorkspaceLockError.unavailable(String(cString: strerror(err)))
        }
        defer { flock(fd, LOCK_UN) }
        return body()
    }

    private static func canDegrade(_ err: Int32) -> Bool {
        err == EACCES || err == EPERM || err == EROFS || err == ENOENT
    }
}
