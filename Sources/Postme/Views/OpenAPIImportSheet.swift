import SwiftUI

/// OpenAPI / Swagger 导入预览：先看清楚接口数、目录数和提示，再决定落点。
struct OpenAPIImportSheet: View {
    @Environment(AppState.self) private var app
    private static let maximumWarningHeight: CGFloat = 150

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
                .frame(width: 640)
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
                Image(icon: .apiSpecification)
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
            Image(icon: .info)
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

            let warnings = preview.result.warnings
            if warnings.isEmpty {
                Text(app.t(.openAPIWarningsNone))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else if warnings.count < 12 {
                WarningListLayout(maximumHeight: Self.maximumWarningHeight) {
                    VStack(alignment: .leading, spacing: 5) {
                        warningRows(warnings)
                    }
                    .hidden()
                    .accessibilityHidden(true)
                    scrollableWarnings(warnings)
                }
            } else {
                // 长列表直接进入滚动区，避免为测量而构建所有提示。
                scrollableWarnings(warnings)
                    .frame(height: Self.maximumWarningHeight)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func scrollableWarnings(_ warnings: [String]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 5) {
                warningRows(warnings)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func warningRows(_ warnings: [String]) -> some View {
        ForEach(warnings.indices, id: \.self) { index in
            HStack(alignment: .top, spacing: 6) {
                Text("•").accessibilityHidden(true)
                Text(warnings[index])
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
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

/// ScrollView 的理想高度与内容无关，单独测量短列表，让弹窗正确计算初始高度。
private struct WarningListLayout: Layout {
    let maximumHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let content = subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? content.width, height: min(content.height, maximumHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[1].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}
