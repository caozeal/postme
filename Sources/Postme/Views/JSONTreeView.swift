import SwiftUI

/// 响应体 JSON 树：按层级折叠 / 展开。
///
/// 用扁平行 + `LazyVStack` 而不是递归视图：展开大数组时行数可达数万，
/// 递归视图会把整棵树一次性建出来，滚动和折叠都会明显卡顿。
struct JSONTreeView: View {
    let root: JSONValue
    @Binding var collapsed: Set<String>
    let l10n: Localizer

    /// 单个标量的展示上限。树形视图是浏览结构用的，超长字符串截断显示，
    /// 完整内容仍可通过工具栏「复制」拿到。
    private let scalarDisplayLimit = 240

    var body: some View {
        ScrollView([.vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    rowView(row)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var rows: [JSONTreeRow] {
        JSONTree.flatten(root, collapsed: collapsed)
    }

    private func rowView(_ row: JSONTreeRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Color.clear.frame(width: CGFloat(row.depth) * 14, height: 1)

            if row.isExpandable {
                Button {
                    toggle(row.id)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(row.isCollapsed ? 0 : 90))
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(row.isCollapsed ? l10n(.jsonTreeExpandNode) : l10n(.jsonTreeCollapseNode))
            } else {
                Color.clear.frame(width: 12, height: 12)
            }

            Text(line(for: row))
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 20)
    }

    private func line(for row: JSONTreeRow) -> AttributedString {
        var text = AttributedString()

        func append(_ string: String, _ color: Color) {
            var piece = AttributedString(string)
            piece.foregroundColor = color
            text += piece
        }

        if let index = row.index {
            append("[\(index)]", .secondary)
            append(" ", .secondary)
        }

        if let key = row.key {
            append(key, Color(nsColor: JSONHighlighter.colorKey()))
            append(": ", .secondary)
        }

        switch row.content {
        case .container(let isObject, let childCount):
            let open = isObject ? "{" : "["
            let close = isObject ? "}" : "]"
            if childCount == 0 {
                append("\(open)\(close)", .secondary)
            } else if row.isCollapsed {
                let summary = l10n(.jsonTreeItemCount, childCount)
                append("\(open) … \(summary) \(close)", .secondary)
            } else {
                append(open, .secondary)
            }
        case .scalar(let value, let kind):
            append(truncated(value), color(for: kind))
        }

        return text
    }

    private func color(for kind: JSONScalarKind) -> Color {
        switch kind {
        case .string: return Color(nsColor: JSONHighlighter.colorString())
        case .number: return Color(nsColor: JSONHighlighter.colorNumber())
        case .bool, .null: return Color(nsColor: JSONHighlighter.colorKeyword())
        }
    }

    private func truncated(_ token: String) -> String {
        guard token.count > scalarDisplayLimit else { return token }
        return String(token.prefix(scalarDisplayLimit)) + "…"
    }

    private func toggle(_ path: String) {
        if collapsed.contains(path) {
            collapsed.remove(path)
        } else {
            collapsed.insert(path)
        }
    }
}
