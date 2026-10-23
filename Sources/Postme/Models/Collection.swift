import Foundation

/// 集合树节点（位于项目内）：文件夹或已保存的请求。
enum CollectionNode: Identifiable, Codable, Hashable {
    case folder(Folder)
    case request(SavedRequest)

    struct Folder: Codable, Hashable {
        var id: UUID
        var name: String
        var children: [CollectionNode]

        init(id: UUID = UUID(), name: String, children: [CollectionNode] = []) {
            self.id = id
            self.name = name
            self.children = children
        }

        /// 容错解码（见 `TolerantDecoding.swift`）。
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                id: c.tolerant(.id, UUID()),
                name: c.tolerant(.name, "未命名文件夹"),
                children: c.tolerantLossyArray(.children)
            )
        }
    }

    struct SavedRequest: Codable, Hashable {
        var id: UUID
        var name: String
        var request: APIRequest

        init(id: UUID = UUID(), name: String, request: APIRequest) {
            self.id = id
            self.name = name
            self.request = request
        }

        /// 容错解码（见 `TolerantDecoding.swift`）。
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let request = c.tolerant(.request, APIRequest())
            self.init(
                id: c.tolerant(.id, UUID()),
                name: c.tolerant(.name, request.name),
                request: request
            )
        }
    }

    /// 节点解码交给编译器合成的实现：它按 `folder` / `request` 键分支，正确处理
    /// Swift 为带关联值的枚举生成的 `{"folder":{"_0":…}}` 形状（手写解码极易在这里
    /// 悄悄走偏——若用容错的 Folder 去解整个节点对象，缺键会全部取默认值而"成功"，
    /// 每个节点都会变成空文件夹）。
    /// 单个节点彻底解不出来时由父级的 `tolerantLossyArray` 丢弃，不影响其余节点。

    var id: UUID {
        switch self {
        case .folder(let folder): return folder.id
        case .request(let saved): return saved.id
        }
    }

    var name: String {
        get {
            switch self {
            case .folder(let folder): return folder.name
            case .request(let saved): return saved.name
            }
        }
        set {
            switch self {
            case .folder(var folder):
                folder.name = newValue
                self = .folder(folder)
            case .request(var saved):
                saved.name = newValue
                self = .request(saved)
            }
        }
    }

    /// 文件夹的子节点；请求节点为 nil（供 OutlineGroup 使用）。
    var children: [CollectionNode]? {
        if case .folder(let folder) = self { return folder.children }
        return nil
    }

    var isFolder: Bool {
        if case .folder = self { return true }
        return false
    }

    var savedRequest: SavedRequest? {
        if case .request(let saved) = self { return saved }
        return nil
    }

    /// 当前节点（含自身）是否包含指定 id。
    ///
    /// 拖拽校验用：文件夹不能移进自己的子树，也不能插到自己后代的前后。
    func containsNode(id: UUID) -> Bool {
        if self.id == id { return true }
        guard case .folder(let folder) = self else { return false }
        return folder.children.contains { $0.containsNode(id: id) }
    }
}

/// 树节点的拖放目标。
enum NodeMoveTarget: Equatable {
    /// 放到某个节点之前（同级）。
    case before(UUID)
    /// 放到某个节点之后（同级）。
    case after(UUID)
    /// 放进某个文件夹（追加到末尾）。
    case inside(UUID)
    /// 追加到项目根目录。
    case root

    /// 这个目标是否落在某个节点上（用于清理拖放高亮）。
    func involves(_ id: UUID) -> Bool {
        switch self {
        case .before(let target), .after(let target), .inside(let target):
            return target == id
        case .root:
            return false
        }
    }
}

// MARK: - 树操作

extension Array where Element == CollectionNode {

    /// 深度优先查找节点。
    func findNode(id: UUID) -> CollectionNode? {
        for node in self {
            if node.id == id { return node }
            if let children = node.children, let found = children.findNode(id: id) {
                return found
            }
        }
        return nil
    }

    /// 删除指定 id 的节点（含递归）。返回是否有删除发生。
    @discardableResult
    mutating func removeNode(id: UUID) -> Bool {
        if let index = firstIndex(where: { $0.id == id }) {
            remove(at: index)
            return true
        }
        for index in indices {
            if case .folder(var folder) = self[index] {
                if folder.children.removeNode(id: id) {
                    self[index] = .folder(folder)
                    return true
                }
            }
        }
        return false
    }

    /// 重命名指定 id 的节点。
    @discardableResult
    mutating func renameNode(id: UUID, to newName: String) -> Bool {
        for index in indices {
            if self[index].id == id {
                self[index].name = newName
                return true
            }
            if case .folder(var folder) = self[index] {
                if folder.children.renameNode(id: id, to: newName) {
                    self[index] = .folder(folder)
                    return true
                }
            }
        }
        return false
    }

    /// 在指定文件夹下追加子节点。folderID 为 nil 时追加到根。
    @discardableResult
    mutating func insert(_ node: CollectionNode, intoFolder folderID: UUID?) -> Bool {
        guard let folderID else {
            append(node)
            return true
        }
        for index in indices {
            if case .folder(var folder) = self[index] {
                if folder.id == folderID {
                    folder.children.append(node)
                    self[index] = .folder(folder)
                    return true
                }
                if folder.children.insert(node, intoFolder: folderID) {
                    self[index] = .folder(folder)
                    return true
                }
            }
        }
        return false
    }

    /// 拖拽移动是否合法（不实际修改）。
    ///
    /// 规则：
    /// - 目标必须存在；
    /// - 不能移到自己的前面 / 后面 / 里面；
    /// - 文件夹不能移进自己的子树，也不能插到后代的前后（否则会形成环或丢失子树）。
    func canMoveNode(id: UUID, to target: NodeMoveTarget) -> Bool {
        guard let node = findNode(id: id) else { return false }

        switch target {
        case .root:
            return true

        case .inside(let folderID):
            guard let folder = findNode(id: folderID), folder.isFolder else { return false }
            return !node.containsNode(id: folderID)

        case .before(let targetID), .after(let targetID):
            guard findNode(id: targetID) != nil else { return false }
            return !node.containsNode(id: targetID)
        }
    }

    /// 把节点移动到目标位置。失败时整棵树保持原样。
    ///
    /// 先校验、再在副本上「摘除 + 插入」、最后一次性替换：任何一步失败都不会
    /// 出现「节点已经从原处删掉、却没插进新位置」的丢数据状态。
    @discardableResult
    mutating func moveNode(id: UUID, to target: NodeMoveTarget) -> Bool {
        guard canMoveNode(id: id, to: target), let node = findNode(id: id) else { return false }

        var copy = self
        guard copy.removeNode(id: id) else { return false }

        switch target {
        case .root:
            copy.append(node)
        case .inside(let folderID):
            guard copy.insert(node, intoFolder: folderID) else { return false }
        case .before(let targetID):
            guard copy.insert(node, before: targetID) else { return false }
        case .after(let targetID):
            guard copy.insert(node, after: targetID) else { return false }
        }

        self = copy
        return true
    }

    /// 在指定节点之前插入（同级）。
    @discardableResult
    mutating func insert(_ node: CollectionNode, before targetID: UUID) -> Bool {
        if let index = firstIndex(where: { $0.id == targetID }) {
            self.insert(node, at: index)
            return true
        }
        for index in indices {
            if case .folder(var folder) = self[index] {
                if folder.children.insert(node, before: targetID) {
                    self[index] = .folder(folder)
                    return true
                }
            }
        }
        return false
    }

    /// 在指定节点之后插入（同级）。
    @discardableResult
    mutating func insert(_ node: CollectionNode, after targetID: UUID) -> Bool {
        if let index = firstIndex(where: { $0.id == targetID }) {
            self.insert(node, at: index + 1)
            return true
        }
        for index in indices {
            if case .folder(var folder) = self[index] {
                if folder.children.insert(node, after: targetID) {
                    self[index] = .folder(folder)
                    return true
                }
            }
        }
        return false
    }

    /// 原地替换已保存请求的内容（保留位置与 id）。
    @discardableResult
    mutating func replaceSavedRequest(id: UUID, with request: APIRequest) -> Bool {        for index in indices {
            if case .request(var saved) = self[index], saved.id == id {
                var updated = request
                updated.id = saved.request.id
                saved.request = updated
                self[index] = .request(saved)
                return true
            }
            if case .folder(var folder) = self[index] {
                if folder.children.replaceSavedRequest(id: id, with: request) {
                    self[index] = .folder(folder)
                    return true
                }
            }
        }
        return false
    }

    /// 所有文件夹的扁平列表（含层级路径），用于「保存到文件夹」选择器。
    func folderPaths(prefix: String = "") -> [(id: UUID, path: String)] {
        var result: [(id: UUID, path: String)] = []
        for node in self {
            if case .folder(let folder) = node {
                let path = prefix.isEmpty ? folder.name : "\(prefix) / \(folder.name)"
                result.append((folder.id, path))
                result.append(contentsOf: folder.children.folderPaths(prefix: path))
            }
        }
        return result
    }

    /// 按名称模糊匹配（用于搜索），返回所有命中的请求节点。
    func requestsMatching(_ keyword: String) -> [CollectionNode] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }
        var result: [CollectionNode] = []
        for node in self {
            switch node {
            case .folder(let folder):
                result.append(contentsOf: folder.children.requestsMatching(keyword))
            case .request(let saved):
                let haystack = "\(saved.name) \(saved.request.url) \(saved.request.method.rawValue)".lowercased()
                if haystack.contains(trimmed) {
                    result.append(node)
                }
            }
        }
        return result
    }
}
