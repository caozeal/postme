import SwiftUI

/// 通用键值表编辑器，headers / query params / form fields 共用。
/// 支持每行启用开关、增删行。
struct KeyValueEditor: View {
    @Environment(AppState.self) private var app
    @Binding var items: [KeyValueItem]
    /// 占位符由调用方本地化后传入（不设中文默认值，否则英文界面会漏出中文）。
    var keyPlaceholder: String
    var valuePlaceholder: String

    private let controlWidth: CGFloat = 26
    private let spacing: CGFloat = 8

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        row(item: binding(for: item.id), id: item.id)
                        Divider()
                    }
                    addRow
                }
            }
        }
    }

    /// 按 **id** 取行绑定，不按下标。
    ///
    /// 崩溃现场（`Fatal error: Index out of range`，栈顶 `Binding.subscript` →
    /// `Array._checkSubscript` ← `PlatformTextFieldCoordinator.controlTextDidEndEditing`）：
    /// 正在编辑某行输入框时切页签，编辑器绑定的数组被换成另一格的（可能更短），
    /// SwiftUI 在结束编辑时仍按**旧下标**写回 → 越界 SIGTRAP。
    /// `ForEach($items)` 生成的就是这种下标绑定，所以这里换成逐行按 id 构造：
    /// 行已经不在数组里就退化成 no-op——既不崩，也不会把 A 格的内容写进 B 格。
    private func binding(for id: UUID) -> Binding<KeyValueItem> {
        Binding(
            get: { items.first { $0.id == id } ?? KeyValueItem(id: id) },
            set: { updated in
                guard let index = items.firstIndex(where: { $0.id == id }) else { return }
                items[index] = updated
            }
        )
    }

    private func row(item: Binding<KeyValueItem>, id: UUID) -> some View {
        HStack(spacing: spacing) {
            Toggle("", isOn: item.isEnabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .frame(width: controlWidth, alignment: .leading)

            TextField(keyPlaceholder, text: item.key)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)

            TextField(valuePlaceholder, text: item.value)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                items.removeAll { $0.id == id }
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .frame(width: controlWidth)
            .help(app.t(.deleteRowHelp))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var header: some View {
        HStack(spacing: spacing) {
            Text(app.t(.keyValueEnabled)).frame(width: controlWidth, alignment: .leading)
            Text(keyPlaceholder).frame(maxWidth: .infinity, alignment: .leading)
            Text(valuePlaceholder).frame(maxWidth: .infinity, alignment: .leading)
            Text("").frame(width: controlWidth)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var addRow: some View {
        Button {
            items.append(KeyValueItem())
        } label: {
            Label(app.t(.addRowButton), systemImage: "plus")
                .font(.system(size: 12))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
