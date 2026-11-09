import Foundation
import Darwin

/// 四个受管文件的磁盘指纹，充当乐观并发控制里的「版本号」。
///
/// 用 `lstat` 元数据而不是内容 hash：history.json 可能几 MB，每次按键哈希整份文件
/// 会抵消三文件拆分的意义。`.atomic` 写会 `rename()` 换 inode，所以 inode 是最强信号；
/// 纳秒 mtime 用来区分同一秒内的两次写；mode 用来识别「文件被换成目录」这类故障注入。
struct DiskFingerprint: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var exists: Bool
        var unreadable: Bool
        var device: Int32
        var inode: UInt64
        var mode: UInt16
        var mtimeSeconds: Int64
        var mtimeNanoseconds: Int32
        var size: Int64

        static let missing = Entry(
            exists: false, unreadable: false,
            device: 0, inode: 0, mode: 0, mtimeSeconds: 0, mtimeNanoseconds: 0, size: 0
        )
        static let unstatable = Entry(
            exists: false, unreadable: true,
            device: 0, inode: 0, mode: 0, mtimeSeconds: 0, mtimeNanoseconds: 0, size: 0
        )
    }

    var entries: [String: Entry]

    static func capture(directory: URL, files: [String] = WorkspaceDirectory.managedFiles) -> DiskFingerprint {
        var result: [String: Entry] = [:]
        for name in files {
            result[name] = entry(for: directory.appendingPathComponent(name, isDirectory: false))
        }
        return DiskFingerprint(entries: result)
    }

    private static func entry(for url: URL) -> Entry {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            return errno == ENOENT ? .missing : .unstatable
        }
        return Entry(
            exists: true,
            unreadable: false,
            device: info.st_dev,
            inode: info.st_ino,
            mode: info.st_mode,
            mtimeSeconds: Int64(info.st_mtimespec.tv_sec),
            mtimeNanoseconds: Int32(info.st_mtimespec.tv_nsec),
            size: Int64(info.st_size)
        )
    }

    /// 与基准相比哪些文件变了。顺序按 managedFiles，便于 UI / CLI 直接展示。
    func differingFiles(from baseline: DiskFingerprint) -> [String] {
        WorkspaceDirectory.managedFiles.filter { entries[$0] != baseline.entries[$0] }
    }
}
