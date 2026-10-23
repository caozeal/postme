import SwiftUI

/// 保存响应示例的命名弹窗。
struct SaveExampleSheet: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 14) {
            Text(app.t(.saveAsExampleButton)).font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text(app.t(.exampleNameLabel))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField(app.t(.exampleNamePlaceholder), text: $app.saveExampleName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 360)
                    .onSubmit { app.commitSaveResponseExample() }
            }

            HStack {
                Spacer()
                Button(app.t(.cancelButton)) { app.cancelSaveResponseExample() }
                Button(app.t(.saveButton)) { app.commitSaveResponseExample() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// 只读查看一条响应示例。
struct ExampleViewerSheet: View {
    @Environment(AppState.self) private var app
    let example: ResponseExample

    private enum Section: String, CaseIterable, Identifiable {
        case body, headers
        var id: String { rawValue }
    }

    @State private var section: Section = .body
    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            sectionPicker
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 780, height: 560)
        .alert(app.t(.exampleDeleteConfirmTitle), isPresented: $showDeleteConfirm) {
            Button(app.t(.cancelButton), role: .cancel) {}
            Button(app.t(.deleteButton), role: .destructive) {
                app.deleteExample(id: example.id)
            }
        } message: {
            Text(app.t(.exampleDeleteConfirmMessage, example.name))
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Badge(text: "\(example.statusCode)", tint: tint)
            Text(example.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer()
            Text("\(app.t(.exampleSavedAtLabel)) \(DateFormatter.localizedString(from: example.savedAt, dateStyle: .short, timeStyle: .short))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if let duration = example.duration {
                Text(formatMillis(duration))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var sectionPicker: some View {
        HStack {
            Picker("", selection: $section) {
                Text(app.t(.responseTabBody)).tag(Section.body)
                Text(app.t(.responseTabHeaders)).tag(Section.headers)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .body:
            if example.isBinary {
                VStack(spacing: 8) {
                    Spacer()
                    Text(app.t(.exampleBinaryPlaceholder))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CodeTextView(
                    text: .constant(example.bodyText),
                    isEditable: false,
                    highlightJSON: JSONTools.isValid(example.bodyText)
                )
            }

        case .headers:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(example.headers) { header in
                        HStack(alignment: .top, spacing: 8) {
                            Text(header.name)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 200, alignment: .leading)
                            Text(header.value)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        Divider()
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if example.isTruncated {
                Label(app.t(.exampleTruncated), systemImage: "scissors")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            Spacer()

            Button(app.t(.deleteButton), role: .destructive) {
                showDeleteConfirm = true
            }
            .font(.system(size: 11))

            if !example.isBinary {
                Button(app.t(.copyButton)) {
                    copyToClipboard(example.bodyText)
                }
                .font(.system(size: 11))
            }

            Button(app.t(.doneButton)) {
                app.viewingExample = nil
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var tint: Color {
        switch example.statusCode {
        case 200..<300: return Color(red: 0.16, green: 0.63, blue: 0.32)
        case 300..<400: return .orange
        default: return Color(red: 0.85, green: 0.25, blue: 0.25)
        }
    }
}
