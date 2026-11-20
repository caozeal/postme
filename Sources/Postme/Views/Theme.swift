import SwiftUI
import AppKit

/// 请求方法对应的强调色（列表与编辑区共用）。
extension HTTPMethod {
    var tint: Color {
        switch self {
        case .get: return HTTPColor.green
        case .post: return HTTPColor.amber
        case .put: return HTTPColor.blue
        case .patch: return HTTPColor.purple
        case .delete: return HTTPColor.red
        case .head: return HTTPColor.teal
        case .options: return Color.secondary
        }
    }
}

/// HTTP 状态码对应的语义色。
func statusTint(for statusCode: Int) -> Color {
    switch statusCode {
    case 200..<300: return HTTPColor.green
    case 300..<400: return HTTPColor.amber
    case 400..<500: return HTTPColor.orange
    case 500..<600: return HTTPColor.red
    default: return .secondary
    }
}

private enum HTTPColor {
    static let green = adaptive(light: 0x176537, dark: 0x72D794)
    static let amber = adaptive(light: 0x8A4900, dark: 0xFFBE62)
    static let blue = adaptive(light: 0x1D55B6, dark: 0x90BAFF)
    static let purple = adaptive(light: 0x6835B1, dark: 0xC6A4FE)
    static let red = adaptive(light: 0xA82C3B, dark: 0xFF9AA3)
    static let teal = adaptive(light: 0x00676F, dark: 0x6BD8D6)
    static let orange = adaptive(light: 0xA64016, dark: 0xFFA27C)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: 1
            )
        })
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

