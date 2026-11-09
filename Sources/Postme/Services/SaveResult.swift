import Foundation

/// 「别人正在写」与「别人已经写完、磁盘和我们内存不一致」要分开：
/// 前者通常几毫秒，短延迟重试即可；后者必须重载，不能弹窗骚扰用户。
enum ConflictReason: Sendable, Equatable {
    case busy
    case fingerprintMismatch([String])
}

/// 一次落盘的结果。原来只有 `Bool`，失败原因和「过期被当成成功」都吞掉了。
enum SaveResult: Sendable, Equatable {
    case succeeded
    /// 未能落盘的文件名；`WriteState` 只更新成功的节，重试是幂等的。
    case failed([String])
    /// 更旧的调度已被新一次保存取代，本次没有读盘也没有写盘。
    case stale
    /// 磁盘上有我们不知道的内容，本次一个字节都没写。
    case conflict(ConflictReason)

    var isSuccess: Bool {
        if case .succeeded = self { return true }
        return false
    }
}
