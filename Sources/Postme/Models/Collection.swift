import Foundation

/// 集合树节点：文件夹或已保存的请求。
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
    }

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

    /// 原地替换已保存请求的内容（保留位置与 id）。
    @discardableResult
    mutating func replaceSavedRequest(id: UUID, with request: APIRequest) -> Bool {
        for index in indices {
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
