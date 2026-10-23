import SwiftUI

/// OpenAPI / Swagger 导入预览：先看清楚接口数、目录数和提示，再决定落点。
struct OpenAPIImportSheet: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        return Group {
            if let preview = app.openAPIImportPreview {
                VStack(alignment: .leading, spacing: 0) {
                    header(preview)
                    Divider()
                    options(preview, app: app)
                    Divider()
                    warnings(preview)
                    Divider()
                    footer
                }
                .frame(width: 640, height: 500)
            }
        }
    }

    private func header(_ preview: AppState.OpenAPIImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(app.t(.openAPIImportTitle))
                    .font(.headline)
                Badge(text: preview.result.versionLabel, tint: .accentColor)
                Spacer()
                Text(app.t(.openAPIImportSummary, preview.result.requestCount, preview.result.folderCount))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(preview.fileName)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func options(_ preview: AppState.OpenAPIImportPreview, app: AppState) -> some View {
        @Bindable var app = app
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(app.t(.openAPIImportTargetLabel))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Picker("", selection: $app.openAPIImportTarget) {
                    Text(app.t(.openAPITargetNewProject))
                        .tag(AppState.OpenAPIImportTarget.newProject)
                    Text(app.t(.openAPITargetCurrentProject))
                        .tag(AppState.OpenAPIImportTarget.currentProject)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(app.openAPIImportTarget == .newProject
                     ? app.t(.openAPIProjectNameLabel)
                     : app.t(.openAPIFolderNameLabel))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField(app.t(.openAPIProjectNamePlaceholder), text: $app.openAPIImportName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 380)
            }

            VStack(alignment: .leading, spacing: 3) {
                if app.openAPIImportTarget == .newProject {
                    hint(app.t(.openAPIImportNewHint))
                } else {
                    hint(app.t(.openAPIImportCurrentHint, app.activeProject?.name ?? ""))
                }
                if let environment = preview.result.environment {
                    hint(app.t(.openAPIImportEnvironmentHint, environment.name))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func hint(_ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "info.circle")
                .font(.system(size: 9))
            Text(text)
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private func warnings(_ preview: AppState.OpenAPIImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(app.t(.openAPIWarningsHeader, preview.result.warnings.count))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            if preview.result.warnings.isEmpty {
                Text(app.t(.openAPIWarningsNone))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(preview.result.warnings.enumerated()), id: \.offset) { _, warning in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Text(warning)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(app.t(.cancelButton)) {
                app.cancelOpenAPIImport()
            }
            .keyboardShortcut(.cancelAction)

            Button(app.t(.importButton)) {
                app.commitOpenAPIImport()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(app.openAPIImportName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
