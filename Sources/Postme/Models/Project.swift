import Foundation

/// 项目：集合树的顶层容器，对应 ApiPost 的「项目」层级。
///
/// 层级为 项目 → 文件夹（可嵌套）→ 请求。旧版 workspace.json 的顶层
/// `collections` 在载入时整体收进一个「默认项目」（见 `Workspace.init(from:)`），
/// 节点 id 原样保留。
struct Project: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var children: [CollectionNode]

    init(id: UUID = UUID(), name: String, children: [CollectionNode] = []) {
        self.id = id
        self.name = name
        self.children = children
    }

    /// 手写 `init(from:)` 会抑制 CodingKeys 的自动合成，这里显式声明。
    enum CodingKeys: String, CodingKey {
        case id, name, children
    }

    /// 容错解码（见 `TolerantDecoding.swift`）。缺字段取默认值，
    /// 单个畸形子节点只丢自己，不让整份工作区作废。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: c.tolerant(.id, UUID()),
            name: c.tolerant(.name, "未命名项目"),
            children: c.tolerantLossyArray(.children)
        )
    }
}

// MARK: - 项目级树操作

extension Array where Element == Project {

    func findProject(id: UUID) -> Project? {
        first { $0.id == id }
    }

    /// 删除指定 id 的项目（含其全部目录与请求）。返回是否有删除发生。
    @discardableResult
    mutating func removeProject(id: UUID) -> Bool {
        guard let index = firstIndex(where: { $0.id == id }) else { return false }
        remove(at: index)
        return true
    }

    /// 重命名指定 id 的项目。
    @discardableResult
    mutating func renameProject(id: UUID, to newName: String) -> Bool {
        guard let index = firstIndex(where: { $0.id == id }) else { return false }
        self[index].name = newName
        return true
    }

    /// 跨项目深度优先查找节点。
    ///
    /// 用于删除项目后判断 `editingNodeID` / `selectedNodeID` 是否还存在于
    /// 剩余项目里——悬空的编辑归属会让 ⌘S 静默无效。
    func findNode(id: UUID) -> CollectionNode? {
        for project in self {
            if let found = project.children.findNode(id: id) {
                return found
            }
        }
        return nil
    }
}
