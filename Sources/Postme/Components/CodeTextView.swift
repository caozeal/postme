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
    /// 只读响应体开启 JSON 语法高亮（编辑态的请求体不开，避开输入性能问题）。
    var highlightJSON: Bool = false

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
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
        if highlightJSON {
            JSONHighlighter.apply(to: textView, fontSize: fontSize)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.text = $text
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
            if highlightJSON {
                JSONHighlighter.apply(to: textView, fontSize: fontSize)
            }
        }
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
        weak var textView: NSTextView?
        /// 最近一次写入 textView 的内容，用于廉价地判断是否需要回写。
        var appliedText: String?

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            appliedText = textView.string
            text.wrappedValue = textView.string
        }
    }
}
