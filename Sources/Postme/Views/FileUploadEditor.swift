import SwiftUI
import AppKit

/// Binary Body：选择一个本地文件作为整个请求正文。
struct BinaryBodyEditor: View {
    @Environment(AppState.self) private var app
    @Binding var draft: APIRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField(app.t(.filePathPlaceholder), text: $draft.binaryFilePath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))

                Button(app.t(.chooseFileButton)) { chooseFile() }
            }

            fileStatus

            Text(app.t(.binaryHint))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var fileStatus: some View {
        let path = draft.binaryFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty {
            Label(app.t(.binaryFileMissing), systemImage: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
        } else {
            let resolved = (path as NSString).expandingTildeInPath
            if let attrs = try? FileManager.default.attributesOfItem(atPath: resolved),
               (attrs[.type] as? FileAttributeType) == .typeRegular {
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                Label(
                    "\(URL(fileURLWithPath: resolved).lastPathComponent) · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) · \(RequestExecutor.mimeType(for: resolved))",
                    systemImage: "doc"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            } else {
                Label(app.t(.fileUnreadableHint), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            draft.binaryFilePath = url.path
        }
    }
}

/// multipart 的文件字段表。
///
/// 与 `KeyValueEditor` 一样按 **id** 构造绑定：切页签时数组可能整体换掉，
/// 下标绑定会在结束编辑时越界。
struct FileFieldEditor: View {
    @Environment(AppState.self) private var app
    @Binding var items: [FileField]

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

    private func binding(for id: UUID) -> Binding<FileField> {
        Binding(
            get: { items.first { $0.id == id } ?? FileField(id: id) },
            set: { updated in
                guard let index = items.firstIndex(where: { $0.id == id }) else { return }
                items[index] = updated
            }
        )
    }

    private func row(item: Binding<FileField>, id: UUID) -> some View {
        HStack(spacing: spacing) {
            Toggle("", isOn: item.isEnabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .frame(width: controlWidth, alignment: .leading)

            TextField(app.t(.fileFieldNamePlaceholder), text: item.name)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)

            TextField(app.t(.filePathPlaceholder), text: item.path)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)

            fileStatus(item.wrappedValue)

            Button {
                chooseFile(for: item)
            } label: {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .frame(width: controlWidth)
            .help(app.t(.chooseFileButton))

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

    @ViewBuilder
    private func fileStatus(_ field: FileField) -> some View {
        if field.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .help(app.t(.fileFieldMissing))
        } else if !FileManager.default.fileExists(atPath: field.resolvedPath) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .help(app.t(.fileUnreadableHint))
        } else {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
                .help(field.fileName)
        }
    }

    private var header: some View {
        HStack(spacing: spacing) {
            Text(app.t(.keyValueEnabled)).frame(width: controlWidth, alignment: .leading)
            Text(app.t(.fileFieldNamePlaceholder)).frame(maxWidth: .infinity, alignment: .leading)
            Text(app.t(.filePathPlaceholder)).frame(maxWidth: .infinity, alignment: .leading)
            Text("").frame(width: controlWidth * 2 + spacing)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var addRow: some View {
        Button {
            items.append(FileField())
        } label: {
            Label(app.t(.addFileButton), systemImage: "plus")
                .font(.system(size: 12))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chooseFile(for item: Binding<FileField>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            item.wrappedValue.path = url.path
            if item.wrappedValue.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                item.wrappedValue.name = url.lastPathComponent
            }
        }
    }
}
