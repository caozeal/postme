import SwiftUI
import AppKit

/// `NSTextView` 封装，用于请求体 / 响应体这类代码文本编辑。
///
/// 必须关闭全部「智能替换」：macOS 默认的智能引号会把 JSON 里的半角 `"` 换成
/// 弯引号 `”`，静默损坏请求体且极难排查。
struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool = true
    var fontSize: CGFloat = 12.5
    /// 开启 JSON 语法高亮。
    ///
    /// 编辑态走防抖（`highlightDebounce`），避免每次按键都做一遍 O(n) 扫描；
    /// 只读态在内容变化时立即着色。
    var highlightJSON: Bool = false
    /// 编辑态着色的防抖间隔。高亮是"锦上添花"，宁可晚一点也不能拖慢输入。
    var highlightDebounce: Duration = .milliseconds(150)

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, fontSize: fontSize, debounce: highlightDebounce)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        Self.configure(textView, isEditable: isEditable, fontSize: fontSize)
        textView.delegate = context.coordinator
        textView.string = text
        context.coordinator.textView = textView
        context.coordinator.appliedText = text
        context.coordinator.highlightsJSON = highlightJSON
        if highlightJSON {
            JSONHighlighter.apply(to: textView, fontSize: fontSize)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        context.coordinator.fontSize = fontSize
        let highlightingChanged = context.coordinator.highlightsJSON != highlightJSON
        context.coordinator.highlightsJSON = highlightJSON
        textView.isEditable = isEditable

        // 只在内容确实变化时回写。
        // 注意：这里和 coordinator.appliedText 比较，**不要**用 textView.string——
        // 那个访问器每次都会把整个 NSTextStorage 物化成新字符串，几 MB 的响应体下
        // 每次界面刷新都会退化成 O(n) 全量对比。与缓存值比较可走字符串缓冲的快速路径。
        if context.coordinator.appliedText != text {
            let previousSelection = textView.selectedRange()
            textView.string = text
            context.coordinator.appliedText = text
            let length = (text as NSString).length
            let location = min(previousSelection.location, length)
            textView.setSelectedRange(NSRange(location: location, length: 0))
            context.coordinator.applyHighlightNow()
        } else if highlightingChanged {
            // 内容没变但开关翻转：必须显式处理，否则切到 Raw Text 会残留 JSON 配色。
            context.coordinator.applyHighlightNow()
        }
    }

    static func destroyNSView(_ scrollView: NSScrollView, context: Context) {
        // 视图销毁前取消挂起的着色，避免防抖任务持有已销毁的 textView。
        context.coordinator.cancelPendingHighlight()
    }

    static func configure(_ textView: NSTextView, isEditable: Bool, fontSize: CGFloat) {
        textView.isRichText = false
        textView.isEditable = isEditable
        textView.isSelectable = true

        // 关闭智能替换（关键）
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false

        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor

        // 宽度跟随容器、高度自由增长的换行布局
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var fontSize: CGFloat
        weak var textView: NSTextView?
        /// 最近一次写入 textView 的内容，用于廉价地判断是否需要回写。
        var appliedText: String?
        /// 是否着色。由 updateNSView 同步，编辑回调里要用最新值。
        var highlightsJSON = false

        private let debounce: Duration
        private var pendingHighlight: Task<Void, Never>?

        init(text: Binding<String>, fontSize: CGFloat, debounce: Duration) {
            self.text = text
            self.fontSize = fontSize
            self.debounce = debounce
        }

        deinit {
            pendingHighlight?.cancel()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            appliedText = textView.string
            text.wrappedValue = textView.string
            scheduleHighlight(for: textView)
        }

        /// 立即按当前开关着色（或清除）。
        ///
        /// 内容变化与开关翻转都要走这里，保证「开关状态」与「实际配色」永远一致。
        func applyHighlightNow() {
            guard let textView else { return }
            if highlightsJSON {
                JSONHighlighter.apply(to: textView, fontSize: fontSize)
            } else {
                JSONHighlighter.clear(in: textView, fontSize: fontSize)
            }
        }

        /// 编辑后防抖着色。
        ///
        /// 直接同步调用的话，每敲一个字符都要重扫全文（200 KB ≈ 10 ms），
        /// 大正文会明显拖慢输入；而着色本身只是属性写入，晚 150 ms 无感。
        private func scheduleHighlight(for textView: NSTextView) {
            guard highlightsJSON else { return }
            pendingHighlight?.cancel()
            let fontSize = fontSize
            let debounce = debounce
            pendingHighlight = Task { @MainActor [weak self, weak textView] in
                try? await Task.sleep(for: debounce)
                guard !Task.isCancelled, let self, let textView else { return }
                guard self.highlightsJSON else { return }
                // 体积上限由 JSONHighlighter 自己把关（那里用的是 UTF-8 字节数），
                // 这里不再重复判断，免得两处口径不一致。
                JSONHighlighter.apply(to: textView, fontSize: fontSize)
            }
        }

        func cancelPendingHighlight() {
            pendingHighlight?.cancel()
            pendingHighlight = nil
        }
    }
}
