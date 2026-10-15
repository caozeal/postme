import SwiftUI

/// 通用键值表编辑器，headers / query params / form fields 共用。
/// 支持每行启用开关、增删行。
struct KeyValueEditor: View {
    @Binding var items: [KeyValueItem]
    var keyPlaceholder: String = "键"
    var valuePlaceholder: String = "值"

    private let controlWidth: CGFloat = 26
    private let spacing: CGFloat = 8

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach($items) { $item in
                        row(item: $item)
                        Divider()
                    }
                    addRow
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: spacing) {
            Text("启用").frame(width: controlWidth, alignment: .leading)
            Text(keyPlaceholder).frame(maxWidth: .infinity, alignment: .leading)
            Text(valuePlaceholder).frame(maxWidth: .infinity, alignment: .leading)
            Text("").frame(width: controlWidth)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func row(item: Binding<KeyValueItem>) -> some View {
        let id = item.wrappedValue.id
        return HStack(spacing: spacing) {
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
            .help("删除此行")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var addRow: some View {
        Button {
            items.append(KeyValueItem())
        } label: {
            Label("添加一行", systemImage: "plus")
                .font(.system(size: 12))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
