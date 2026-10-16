import Foundation

/// 容错解码辅助。
///
/// 动机（实测缺陷）：`Workspace` 原先用编译器合成的 `init(from:)`，任何**非可选键缺失**
/// 都会让整份 workspace.json 解码失败——`PersistenceService.load()` 随即把文件搬成
/// `.corrupt-*` 并以空工作区启动，用户的集合、环境、历史一次性全部消失。
/// 只要将来给模型加一个字段，所有现存用户的文件都会命中这条路径。
///
/// 因此持久化模型统一改为显式 `init(from:)`：缺键取默认值，**类型不匹配或未知枚举值
/// 也退回默认值**，而不是让整份文件作废。
///
/// 注意分寸：容错只针对"字段级"问题。文件根本不是 JSON、或顶层不是对象、
/// 或对象里连一个已知键都没有，仍判定为损坏（由 `Workspace.init(from:)` 把关），
/// 否则真损坏的文件会被静默当成空工作区，比原来的行为更糟。
extension KeyedDecodingContainer {

    /// 解码一个值，缺失 / 类型不符 / 未知枚举值都退回 `fallback`。
    func tolerant<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }

    /// 可空字段：缺失或解码失败都得到 nil（不区分二者）。
    func tolerantOptional<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }

    /// 解一个数组，**逐元素容错**：单个元素解不出来就丢弃它，保留其余元素。
    ///
    /// 用于集合树的 children。JSONDecoder 的 unkeyed 容器在解码失败时不会前移游标，
    /// 直接重试会死循环，所以失败后必须用一个"什么字段都不读"的类型消费掉该元素。
    func tolerantLossyArray<T: Decodable>(_ key: Key) -> [T] {
        guard var container = try? nestedUnkeyedContainer(forKey: key) else { return [] }
        var result: [T] = []
        while !container.isAtEnd {
            if let value = try? container.decode(T.self) {
                result.append(value)
            } else if (try? container.decode(SkippedElement.self)) == nil {
                break  // 连消费都失败：退出，避免死循环
            }
        }
        return result
    }
}

/// 只用于在 unkeyed 容器里"跳过"一个解不出来的元素：不读任何字段，必定成功。
private struct SkippedElement: Decodable {
    init(from decoder: Decoder) throws {}
}
