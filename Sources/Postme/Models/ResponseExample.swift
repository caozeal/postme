import Foundation

/// 一条保存下来的响应示例。
///
/// **为什么单独存**：响应体动辄几百 KB 到几 MB，塞进 `workspace.json` 会让每次
/// 项目/环境变更都重写这些正文。示例放在 `examples.json`，只在用户显式保存/删除时写。
struct ResponseExample: Identifiable, Codable, Hashable {
    var id: UUID
    /// 归属的已保存请求节点 id。只有已保存的请求才能存示例——否则请求一关，
    /// 示例就成了没有主人的孤儿。
    var requestNodeID: UUID
    var name: String
    var savedAt: Date
    var statusCode: Int
    var headers: [HTTPHeader]
    /// UTF-8 文本正文；二进制响应为空，`isBinary == true`。
    var bodyText: String
    var isBinary: Bool
    /// 原文超过示例上限，或响应本身被截断。
    var isTruncated: Bool
    var mimeType: String?
    var duration: TimeInterval?

    /// 单条示例正文上限。超过就截断并标注，不静默丢内容。
    static let bodyLimitBytes = 2 * 1024 * 1024

    init(
        id: UUID = UUID(),
        requestNodeID: UUID,
        name: String,
        savedAt: Date = Date(),
        statusCode: Int,
        headers: [HTTPHeader],
        bodyText: String,
        isBinary: Bool = false,
        isTruncated: Bool = false,
        mimeType: String? = nil,
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.requestNodeID = requestNodeID
        self.name = name
        self.savedAt = savedAt
        self.statusCode = statusCode
        self.headers = headers
        self.bodyText = bodyText
        self.isBinary = isBinary
        self.isTruncated = isTruncated
        self.mimeType = mimeType
        self.duration = duration
    }

    /// 从一次响应构造。正文按 UTF-8 解码；解不出来就标记为二进制。
    init?(response: APIResponse, requestNodeID: UUID, name: String, savedAt: Date = Date()) {
        guard let text = String(data: response.body, encoding: .utf8) else {
            self.init(
                requestNodeID: requestNodeID,
                name: name,
                savedAt: savedAt,
                statusCode: response.statusCode,
                headers: response.headers,
                bodyText: "",
                isBinary: true,
                isTruncated: response.isBodyTruncated,
                mimeType: response.mimeType,
                duration: response.timing.total
            )
            return
        }

        let bytes = text.utf8.count
        let truncated = response.isBodyTruncated || bytes > Self.bodyLimitBytes
        let stored: String
        if bytes > Self.bodyLimitBytes {
            stored = String(decoding: Array(text.utf8.prefix(Self.bodyLimitBytes)), as: UTF8.self)
        } else {
            stored = text
        }

        self.init(
            requestNodeID: requestNodeID,
            name: name,
            savedAt: savedAt,
            statusCode: response.statusCode,
            headers: response.headers,
            bodyText: stored,
            isBinary: false,
            isTruncated: truncated,
            mimeType: response.mimeType,
            duration: response.timing.total
        )
    }

    /// 容错解码（见 `TolerantDecoding.swift`）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: c.tolerant(.id, UUID()),
            requestNodeID: c.tolerant(.requestNodeID, UUID()),
            name: c.tolerant(.name, ""),
            savedAt: c.tolerant(.savedAt, Date()),
            statusCode: c.tolerant(.statusCode, 0),
            headers: c.tolerant(.headers, []),
            bodyText: c.tolerant(.bodyText, ""),
            isBinary: c.tolerant(.isBinary, false),
            isTruncated: c.tolerant(.isTruncated, false),
            mimeType: c.tolerantOptional(.mimeType),
            duration: c.tolerantOptional(.duration)
        )
    }
}

/// `examples.json` 的读写。
///
/// 只做整份读写：示例是用户显式保存的低频数据，不需要像页签那样防抖。
struct ResponseExampleStore {
    let url: URL

    init(directory: URL) {
        self.url = directory.appendingPathComponent("examples.json")
    }

    func load() -> [ResponseExample] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(LossyExampleList.self, from: data).examples) ?? []
    }

    @discardableResult
    func save(_ examples: [ResponseExample]) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(examples) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            print("[postme] 保存响应示例失败: \(error)")
            return false
        }
    }
}

/// 顶层数组的逐元素容错解码：单条坏示例只丢自己，不连坐整份文件。
private struct LossyExampleList: Decodable {
    var examples: [ResponseExample] = []

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            if let example = try? container.decode(ResponseExample.self) {
                examples.append(example)
            } else if (try? container.decode(SkippedElement.self)) == nil {
                break
            }
        }
    }

    private struct SkippedElement: Decodable {
        init(from decoder: Decoder) throws {}
    }
}
