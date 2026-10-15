import AppKit

/// 只读 JSON 语法高亮。
///
/// 仅用于响应体展示（只读，一次性着色，无输入性能压力）。
/// 超过 `APIResponse.highlightSizeLimit` 的文本直接跳过，避免主线程卡顿。
enum JSONHighlighter {

    private enum Char {
        static let quote: unichar = 34      // "
        static let backslash: unichar = 92  // \
        static let colon: unichar = 58      // :
        static let minus: unichar = 45      // -
        static let plus: unichar = 43       // +
        static let dot: unichar = 46        // .
    }

    static func colorKey() -> NSColor { .systemBlue }
    static func colorString() -> NSColor { .systemRed }
    static func colorNumber() -> NSColor { .systemPurple }
    static func colorKeyword() -> NSColor { .systemOrange }

    /// 对 textView 的文本整体着色。返回是否实际执行。
    @discardableResult
    static func apply(to textView: NSTextView, fontSize: CGFloat) -> Bool {
        guard textView.isEditable == false else { return false }
        guard let storage = textView.textStorage else { return false }

        let text = storage.string
        guard !text.isEmpty, text.utf8.count <= APIResponse.highlightSizeLimit else { return false }

        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let nsText = text as NSString
        let length = nsText.length

        storage.beginEditing()
        storage.setAttributes(
            [.font: font, .foregroundColor: NSColor.labelColor],
            range: NSRange(location: 0, length: length)
        )

        var index = 0
        while index < length {
            let ch = nsText.character(at: index)

            if ch == Char.quote {
                let end = scanString(nsText, from: index, length: length)
                let range = NSRange(location: index, length: end - index + 1)
                let isKey = nextNonWhitespace(nsText, from: end + 1, length: length) == Char.colon
                storage.addAttribute(.foregroundColor, value: isKey ? colorKey() : colorString(), range: range)
                index = end + 1
                continue
            }

            if isNumberStart(ch) {
                let end = scanNumber(nsText, from: index, length: length)
                storage.addAttribute(
                    .foregroundColor, value: colorNumber(),
                    range: NSRange(location: index, length: end - index)
                )
                index = end
                continue
            }

            if isIdentifierStart(ch) {
                let end = scanIdentifier(nsText, from: index, length: length)
                let word = nsText.substring(with: NSRange(location: index, length: end - index))
                if word == "true" || word == "false" || word == "null" {
                    storage.addAttribute(
                        .foregroundColor, value: colorKeyword(),
                        range: NSRange(location: index, length: end - index)
                    )
                }
                index = end
                continue
            }

            index += 1
        }

        storage.endEditing()
        return true
    }

    // MARK: - 扫描辅助

    /// 返回字符串结束引号的下标（无结束引号则返回末尾）。
    private static func scanString(_ text: NSString, from start: Int, length: Int) -> Int {
        var i = start + 1
        while i < length {
            let ch = text.character(at: i)
            if ch == Char.backslash {
                i += 2
                continue
            }
            if ch == Char.quote {
                return i
            }
            i += 1
        }
        return length - 1
    }

    private static func scanNumber(_ text: NSString, from start: Int, length: Int) -> Int {
        var i = start
        while i < length {
            let ch = text.character(at: i)
            let isNumeric = (ch >= 48 && ch <= 57)
                || ch == Char.minus || ch == Char.plus || ch == Char.dot
                || ch == 101 || ch == 69  // e / E
            if !isNumeric { break }
            i += 1
        }
        return i
    }

    private static func scanIdentifier(_ text: NSString, from start: Int, length: Int) -> Int {
        var i = start
        while i < length {
            let ch = text.character(at: i)
            let isLetter = (ch >= 97 && ch <= 122) || (ch >= 65 && ch <= 90)
            if !isLetter { break }
            i += 1
        }
        return i
    }

    private static func nextNonWhitespace(_ text: NSString, from start: Int, length: Int) -> unichar? {
        var i = start
        while i < length {
            let ch = text.character(at: i)
            if ch != 32 && ch != 9 && ch != 10 && ch != 13 {
                return ch
            }
            i += 1
        }
        return nil
    }

    private static func isNumberStart(_ ch: unichar) -> Bool {
        (ch >= 48 && ch <= 57) || ch == Char.minus
    }

    private static func isIdentifierStart(_ ch: unichar) -> Bool {
        (ch >= 97 && ch <= 122) || (ch >= 65 && ch <= 90)
    }
}
