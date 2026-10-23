import SwiftUI

/// 路径参数表：名字由 URL 决定（只读），只编辑值。
///
/// 行由 `AppState.syncPathParams()` 随 URL 同步；这里不提供增删按钮，
/// 避免出现「表里有一行、URL 里却没有占位符」的死数据。
struct PathParamEditor: View {
    @Environment(AppState.self) private var app
    @Binding var items: [KeyValueItem]
    /// URL 当前实际包含的占位符名。模型里可能还留着「刚被删掉」的行，
    /// 它们不显示，但值会保留，补回占位符时还能继续用。
    let activeNames: Set<String>

    private let nameWidth: CGFloat = 150

    private var visibleItems: [KeyValueItem] {
        items.filter { activeNames.contains($0.key) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visibleItems) { item in
                        row(item: binding(for: item.id), id: item.id)
                        Divider()
                    }
                }
            }
        }
        // 按行数收紧高度：只有两个路径参数时不该占掉半屏。
        .frame(height: min(CGFloat(visibleItems.count) * 22 + 28, 150))
    }

    /// 与 `KeyValueEditor` 同一套 id 绑定：切页签时数组可能整体换掉，
    /// 下标绑定会在结束编辑时越界。
    private func binding(for id: UUID) -> Binding<KeyValueItem> {
        Binding(
            get: { items.first { $0.id == id } ?? KeyValueItem(id: id) },
            set: { updated in
                guard let index = items.firstIndex(where: { $0.id == id }) else { return }
                items[index] = updated
            }
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(app.t(.pathParamsHeader))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .help(app.t(.pathParamsHint))

            Spacer()

            Text(app.t(.pathParamsCount, visibleItems.count))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func row(item: Binding<KeyValueItem>, id: UUID) -> some View {
        HStack(spacing: 8) {
            Text("{\(item.wrappedValue.key)}")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: nameWidth, alignment: .leading)

            TextField(app.t(.pathParamValuePlaceholder), text: item.value)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)

            if item.wrappedValue.value.isEmpty {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help(app.t(.pathParamEmptyHelp))
            } else {
                Color.clear.frame(width: 12, height: 12)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}
