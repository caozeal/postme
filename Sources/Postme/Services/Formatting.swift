import Foundation

/// 展示格式化工具（纯 Foundation，不依赖 UI 层）。

/// 字节数格式化。
func formatBytes(_ count: Int) -> String {
    if count < 1024 { return "\(count) B" }
    let kb = Double(count) / 1024
    if kb < 1024 { return String(format: "%.1f KB", kb) }
    return String(format: "%.2f MB", kb / 1024)
}

/// 耗时格式化（入参单位：秒）。
func formatMillis(_ seconds: TimeInterval?) -> String {
    guard let seconds else { return "—" }
    if seconds < 1 { return String(format: "%.0f ms", seconds * 1000) }
    return String(format: "%.2f s", seconds)
}
