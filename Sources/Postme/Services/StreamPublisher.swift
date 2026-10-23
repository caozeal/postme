import Foundation

/// 一次待发布的流式内容（节流窗口里累积的东西）。
struct StreamBatch: Equatable {
    var events: [SSEEvent] = []
    var text: String = ""
    var bytes: Int = 0
    /// 本窗口内归并出的「大模型输出」快照。与事件同窗口落地，界面不会看到
    /// 「事件已到、拼接还差一批」的中间态。
    var llm: LLMStreamState?

    var isEmpty: Bool { events.isEmpty && text.isEmpty && bytes == 0 && llm == nil }
}

/// 流式发布的节流器。
///
/// **为什么需要**：SSE 可能每秒上百个事件。每来一个 chunk 就改一次 `@Observable` 状态，
/// SwiftUI 会把整棵响应区（含事件列表的 LazyVStack 重排）重建上百次。
/// 解析照旧逐 chunk 做——那是纯 CPU、不放大分配；只有**发布**被合并。
///
/// 三条落地点：
/// - 攒够 `byteThreshold` 字节 → 立即发布（大块数据不该等满一个窗口）；
/// - 距上次发布满 `interval` → 定时发布；
/// - 终态/取消/错误 → 调用方 `takePending()` 取出剩余内容，与终态写在同一次状态写入里
///   （若先发布再写终态，两者之间会闪一帧，且窗口内最后一批事件有被覆盖的风险）。
///
/// 全部方法都在 `@MainActor`（`send()` 的执行上下文）上调用，不需要额外加锁。
@MainActor
final class StreamPublisher {

    private let interval: TimeInterval
    private let byteThreshold: Int
    private let emit: (StreamBatch) -> Void

    private var pending = StreamBatch()
    private var timerTask: Task<Void, Never>?
    private var closed = false

    /// `interval <= 0` 表示不节流（每个 chunk 立即发布，测试用）。
    init(interval: TimeInterval, byteThreshold: Int, emit: @escaping (StreamBatch) -> Void) {
        self.interval = interval
        self.byteThreshold = byteThreshold
        self.emit = emit
    }

    deinit {
        timerTask?.cancel()
    }

    func add(events: [SSEEvent], text: String, bytes: Int, llm: LLMStreamState? = nil) {
        guard !closed else { return }
        pending.events.append(contentsOf: events)
        pending.text += text
        pending.bytes += bytes
        // 快照覆盖而不是累加：归并器持有的是全量状态，增量合并需要另造一层协议。
        if let llm { pending.llm = llm }

        if byteThreshold > 0, pending.bytes >= byteThreshold {
            flush()
        } else {
            scheduleFlush()
        }
    }

    /// 立即发布窗口里的内容。
    func flush() {
        cancelTimer()
        guard !pending.isEmpty else { return }
        let batch = pending
        pending = StreamBatch()
        emit(batch)
    }

    /// 取出窗口里的内容并清空，**不**发布。
    ///
    /// 终态路径用这个而不是 `flush()`：终态要一次写入（§6.1-2），分两次写会闪一帧。
    func takePending() -> StreamBatch {
        cancelTimer()
        let batch = pending
        pending = StreamBatch()
        return batch
    }

    /// 停止接受新内容（终态已到）。
    func close() {
        closed = true
        cancelTimer()
    }

    private func scheduleFlush() {
        if interval <= 0 {
            flush()
            return
        }
        guard timerTask == nil else { return }
        let interval = self.interval
        timerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.timerTask = nil
            self.flush()
        }
    }

    private func cancelTimer() {
        timerTask?.cancel()
        timerTask = nil
    }
}
