import Foundation

/// multipart/form-data 里的一个文件字段。
///
/// **为什么不复用 `KeyValueItem`**：Header / Query / 文本表单字段的语义是「一段字符串」，
/// 文件字段的语义是「磁盘上的一个文件」。混在一起会让导入导出、cURL 生成和界面
/// 都要靠 `isFile` 之类的旁路标志去猜，最终一定会有一条路径猜错。
struct FileField: Identifiable, Codable, Hashable {
    var id: UUID
    var isEnabled: Bool
    /// 表单字段名（part 的 `name`）。
    var name: String
    /// 本地文件路径。发送时才读取，保存时只存路径。
    var path: String

    init(id: UUID = UUID(), isEnabled: Bool = true, name: String = "", path: String = "") {
        self.id = id
        self.isEnabled = isEnabled
        self.name = name
        self.path = path
    }

    /// 容错解码（见 `TolerantDecoding.swift`）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: c.tolerant(.id, UUID()),
            isEnabled: c.tolerant(.isEnabled, true),
            name: c.tolerant(.name, ""),
            path: c.tolerant(.path, "")
        )
    }

    /// 实际可读取的绝对路径（展开 `~`）。
    var resolvedPath: String {
        (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
    }

    var fileName: String {
        URL(fileURLWithPath: resolvedPath).lastPathComponent
    }
}
