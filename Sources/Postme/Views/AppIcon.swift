import AppKit
import SwiftUI

/// 界面图标按用途命名，避免同一操作在不同位置使用不同符号。
enum AppIcon: String {
    case project = "square.stack.3d.up"
    case environment = "globe"
    case folder
    case newFolder = "folder.badge.plus"
    case request = "doc.text"
    case file = "doc"
    case apiSpecification = "doc.badge.gearshape"
    case code = "chevron.left.forwardslash.chevron.right"
    case transfer = "arrow.up.arrow.down"
    case save = "square.and.arrow.down"
    case copy = "doc.on.doc"
    case bookmark
    case search = "magnifyingglass"
    case clear = "xmark.circle.fill"
    case add = "plus"
    case remove = "minus.circle"
    case duplicate = "plus.square.on.square"
    case delete = "trash"
    case close = "xmark"
    case menu = "chevron.up.chevron.down"
    case more = "ellipsis"
    case expanded = "chevron.down"
    case collapsed = "chevron.right"
    case secure = "lock.fill"
    case insecure = "lock.open"
    case show = "eye"
    case hide = "eye.slash"
    case pending = "circle"
    case completed = "checkmark.circle.fill"
    case cancelled = "stop.circle"
    case info = "info.circle"
    case warning = "exclamationmark.triangle.fill"
    case failure = "exclamationmark.circle.fill"
    case truncated = "scissors"
    case duration = "clock"
    case responseSize = "arrow.down.doc"
    case receiving = "arrow.down.circle"
    case formattedResponse = "list.bullet.rectangle"
}

extension Image {
    init(icon: AppIcon) {
        self.init(systemName: icon.rawValue)
    }
}

extension Label where Title == Text, Icon == Image {
    init(_ title: String, icon: AppIcon) {
        self.init(title, systemImage: icon.rawValue)
    }
}

enum BrandColor {
    static let icon = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(srgbRed: 0.77, green: 0.69, blue: 1, alpha: 1)
        }
        return NSColor(srgbRed: 0.35, green: 0.26, blue: 0.65, alpha: 1)
    })

    static let action = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(srgbRed: 0.48, green: 0.36, blue: 0.86, alpha: 1)
        }
        return NSColor(srgbRed: 0.38, green: 0.27, blue: 0.75, alpha: 1)
    })
}

struct SendGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let wings = PostmePlane.wings(in: rect)
        var path = Path(wings.upper)
        path.addPath(Path(wings.lower))
        return path
    }
}
