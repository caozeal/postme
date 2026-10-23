import Foundation

/// 状态栏该显示什么——从视图里抽出来的纯函数，便于直接单测。
///
/// **为什么抽出来**：状态栏的失败模式全是「状态位对、显示错」——例如「已取消」
/// 徽标旁边挂着「接收中」，或者取消后照旧展示上一条请求的状态码。这些只能靠
/// 「给定页签状态 → 得到什么文案」的映射来钉死，而不是靠点界面。
///
/// 两条不变量：
/// 1. **终态只描述本次流**：`.cancelled` / `.failed` 时绝不回退去显示旧 `response`
///    的状态码、耗时、字节数——那会把上一条请求的结果冒充成这一条。
/// 2. **「接收中」只在真的在接收时出现**：`isSending` 为真，或 `status == .streaming`。
struct ResponseStatusPresentation: Equatable {
    /// 主徽标（状态码或「接收中」）。nil 表示不显示徽标。
    var badgeText: String?
    /// 主徽标文字（状态原因短语）。nil 表示不显示。
    var badgeDetail: String?
    /// 流式状态标签（「已取消」「已中断」等）。nil 表示不显示。
    var streamStatus: String?
    /// 失败原因（`.failed(message)` 的关联值）。必须在界面上可读，不只是 tooltip。
    var failureMessage: String?
    /// 是否显示实时耗时（只在真正流式接收期间）。
    var showsLiveDuration: Bool
    /// 已收字节数文案；nil 表示不显示。
    var receivedBytesText: String?
    /// 实际耗时文案（流终态用 `endedAt - startedAt`；已完成后用 `response.timing.total`）。
    var durationText: String?
    /// 事件数文案；nil 表示不显示。
    var eventCountText: String?
    /// 是否处于「接收中」——用于状态栏右侧的接收指示。
    var isReceiving: Bool

    /// 是否展示事件相关字段（事件数等）。
    var showsStreamFields: Bool { eventCountText != nil }
}

enum ResponseStatusPresenter {

    /// 组装状态栏内容。
    ///
    /// - Parameters:
    ///   - stream: 该页签的流式状态。
    ///   - response: 该页签已完成的响应；流式终态（取消/中断）时**不采用**它。
    ///   - isSending: 该页签是否在飞（用于非 SSE 在途窗口的「接收中」指示）。
    static func present(
        stream: StreamState,
        response: APIResponse?,
        isSending: Bool,
        l10n: Localizer
    ) -> ResponseStatusPresentation {
        var result = ResponseStatusPresentation(
            badgeText: nil,
            badgeDetail: nil,
            streamStatus: nil,
            failureMessage: nil,
            showsLiveDuration: false,
            receivedBytesText: nil,
            durationText: nil,
            eventCountText: nil,
            isReceiving: false
        )

        let isStreaming = stream.status == .streaming

        // 流终态（取消/中断）优先于旧 response：否则会把上一条请求的状态码当成
        // 这次流的结果展示。`.closed` 与 `.streaming` 都可能带 response：
        // 前者是这次流的终态响应，后者在途时 response 是旧值（不该用）。
        let usesOldResponse: Bool
        switch stream.status {
        case .cancelled, .failed:
            usesOldResponse = false
        case .streaming:
            usesOldResponse = false
        case .idle, .closed:
            usesOldResponse = true
        }

        if stream.isEventStream {
            result.eventCountText = l10n(.streamEventCount, stream.events.count)
            switch stream.status {
            case .idle:
                result.streamStatus = nil
            case .streaming:
                result.streamStatus = l10n(.streamStatusStreaming)
            case .closed:
                result.streamStatus = l10n(.streamStatusClosed)
            case .cancelled:
                result.streamStatus = l10n(.streamStatusCancelled)
            case .failed(let message):
                result.streamStatus = l10n(.streamStatusFailed)
                result.failureMessage = message
            }
        }

        if let response, usesOldResponse {
            result.badgeText = "\(response.statusCode)"
            result.badgeDetail = response.statusText
        }

        // 「接收中」只由「真的在接收」驱动，与是否 SSE 无关：
        // 非 SSE 在途窗口靠它示意（设计 §3.6），流式期间靠它 + 实时耗时。
        if isSending {
            result.isReceiving = true
            if result.badgeText == nil {
                result.badgeText = l10n(.streamStatusStreaming)
            }
        }

        if isStreaming {
            result.showsLiveDuration = true
            result.receivedBytesText = formatBytes(stream.receivedBytes)
            result.durationText = nil
        } else if stream.isEventStream {
            // 流终态（含取消/中断）：字节数照实、耗时取本次流实际经历的时长。
            result.receivedBytesText = formatBytes(stream.receivedBytes)
            if let endedAt = stream.endedAt {
                result.durationText = formatMillis(endedAt.timeIntervalSince(stream.startedAt))
            } else {
                result.durationText = formatMillis(Date().timeIntervalSince(stream.startedAt))
            }
        } else if let response, usesOldResponse {
            result.receivedBytesText = formatBytes(response.bodySize)
            result.durationText = formatMillis(response.timing.total)
        }

        return result
    }
}
