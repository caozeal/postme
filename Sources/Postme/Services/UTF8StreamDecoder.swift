import Foundation

/// 把逐 chunk 到来的字节解码成字符串，**不产生 U+FFFD**。
///
/// **为什么需要**：网络 chunk 的边界与 UTF-8 字符边界无关。若对每个 chunk 独立
/// `String(decoding:as:)`，一个 3 字节汉字被切成 1+2 两块就会解码出两个替换字符——
/// 流式期间 Body 分页上看到的就是乱码（终态后 Body 取自完整 body 会自愈，但「边收边显示」
/// 恰恰是这一段在显示）。
///
/// 做法：保留未构成完整序列的尾部字节，等下一块补齐再解码。判定只看每段的首字节
/// 声明的长度——非法首字节按单字节处理，不阻塞后续内容。
struct UTF8StreamDecoder {

    /// 尚未凑成完整 UTF-8 序列的尾部字节。
    private var pending: [UInt8] = []

    /// 已解码输出的字符数（测试与调试用）。
    private(set) var decodedScalarCount = 0

    init() {}

    /// 喂入一段字节，返回这次能安全解码出来的文本（可能为空串）。
    mutating func consume(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        pending.append(contentsOf: data)
        let cut = Self.completePrefixLength(pending)
        guard cut > 0 else { return "" }
        let slice = pending[0..<cut]
        pending.removeFirst(cut)
        decodedScalarCount += slice.count
        return String(decoding: slice, as: UTF8.self)
    }

    /// 流结束：把残留字节也交出来。
    ///
    /// 残留若不是完整序列（流被截断在一个字符中间），这里只能按替换字符解码——
    /// 但那是**流真的缺字节**，不是解码器切错边界。
    mutating func finish() -> String {
        guard !pending.isEmpty else { return "" }
        let slice = pending
        pending.removeAll(keepingCapacity: true)
        decodedScalarCount += slice.count
        return String(decoding: slice, as: UTF8.self)
    }

    /// `bytes` 里「以完整 UTF-8 序列结尾」的前缀长度。
    static func completePrefixLength(_ bytes: [UInt8]) -> Int {
        var index = 0
        while index < bytes.count {
            let lead = bytes[index]
            let length: Int
            if lead < 0x80 {
                length = 1
            } else if lead & 0xE0 == 0xC0 {
                length = 2
            } else if lead & 0xF0 == 0xE0 {
                length = 3
            } else if lead & 0xF8 == 0xF0 {
                length = 4
            } else {
                // 非法首字节（含孤立续字节）：当单字节吃掉，不把后面全堵住。
                length = 1
            }
            if index + length > bytes.count { return index }
            index += length
        }
        return bytes.count
    }
}
