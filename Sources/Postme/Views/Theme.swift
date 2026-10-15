import SwiftUI
import AppKit

/// 复制文本到系统剪贴板。
func copyToClipboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

/// 请求方法对应的强调色（列表与编辑区共用）。
extension HTTPMethod {
    var tint: Color {
        switch self {
        case .get: return Color(red: 0.16, green: 0.63, blue: 0.32)
        case .post: return Color(red: 0.90, green: 0.55, blue: 0.10)
        case .put: return Color(red: 0.20, green: 0.48, blue: 0.90)
        case .patch: return Color(red: 0.55, green: 0.35, blue: 0.85)
        case .delete: return Color(red: 0.85, green: 0.25, blue: 0.25)
        case .head: return Color(red: 0.15, green: 0.60, blue: 0.60)
        case .options: return Color.secondary
        }
    }
}

/// HTTP 状态码对应的语义色。
func statusTint(for statusCode: Int) -> Color {
    switch statusCode {
    case 200..<300: return Color(red: 0.16, green: 0.63, blue: 0.32)
    case 300..<400: return Color(red: 0.90, green: 0.55, blue: 0.10)
    case 400..<500: return Color(red: 0.85, green: 0.35, blue: 0.15)
    case 500..<600: return Color(red: 0.85, green: 0.25, blue: 0.25)
    default: return .secondary
    }
}

/// 复用的小标签（方法徽章等）。
struct Badge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}

