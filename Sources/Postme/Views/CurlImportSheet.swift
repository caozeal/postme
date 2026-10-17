import SwiftUI
import AppKit

/// cURL 导入面板：粘贴命令 → 预览解析结果 → 选导入位置。
///
/// **为什么要预览**：curl 命令是"照抄"来的，用户看不见 postme 把它理解成了什么。
/// 先列出「方法 + 地址 + 头数量 + 正文类型」，解析错了一眼就能看出来，
/// 而不是导入之后发出去才发现不对。
struct CurlImportSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var text: String = ""
    @State private var target: Target = .newProject

    enum Target: String, CaseIterable, Identifiable {
        case newProject
        case currentProject

        var id: String { rawValue }

        func title(_ l10n: Localizer) -> String {
            switch self {
            case .newProject: return l10n(.curlTargetNewProject)
            case .currentProject: return l10n(.curlTargetCurrentProject)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(app.t(.curlImportTitle))
                .font(.headline)

            Text(app.t(.curlImportHelp))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 170)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("curl 'https://api.example.com/users' -H 'Authorization: Bearer …'")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }

            status

            footer
        }
        .padding(20)
        .frame(width: 560)
        .onAppear(perform: prefillFromClipboard)
    }

    // MARK: - 解析状态

    private var parsed: Result<CurlCodec.ImportResult, Error>? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            return .success(try CurlCodec.decode(text, l10n: app.t))
        } catch {
            return .failure(error)
        }
    }

    private var requests: [APIRequest] {
        if case .success(let result) = parsed { return result.requests }
        return []
    }

    @ViewBuilder
    private var status: some View {
        switch parsed {
        case .none:
            Text(app.t(.curlWaiting))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

        case .failure(let error):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(localizedMessage(for: error))
                    .font(.system(size: 11))
            }

        case .success(let result):
            VStack(alignment: .leading, spacing: 4) {
                Text(app.t(.curlParsedCount, result.requests.count))
                    .font(.system(size: 11, weight: .semibold))
                ForEach(Array(result.requests.prefix(5).enumerated()), id: \.offset) { _, request in
                    Text(summary(of: request))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if result.requests.count > 5 {
                    Text(app.t(.curlMoreCount, result.requests.count - 5))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func summary(of request: APIRequest) -> String {
        var parts = [request.method.rawValue, request.url]
        if !request.headers.isEmpty { parts.append(app.t(.curlSummaryHeaders, request.headers.count)) }
        switch request.bodyKind {
        case .none: break
        case .json: parts.append(app.t(.curlSummaryJSONBody))
        case .rawText: parts.append(app.t(.curlSummaryTextBody))
        case .formURLEncoded: parts.append(app.t(.curlSummaryFormFields, request.formFields.count))
        case .multipart: parts.append(app.t(.curlSummaryMultipartFields, request.formFields.count))
        }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: - 底部

    private var footer: some View {
        HStack {
            Picker(app.t(.curlImportTo), selection: $target) {
                ForEach(Target.allCases) { option in
                    Text(option.title(app.t)).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(requests.isEmpty)

            Spacer()

            Button(app.t(.cancelButton)) { dismiss() }
            Button(app.t(.importButton)) { performImport() }
                .keyboardShortcut(.defaultAction)
                .disabled(requests.isEmpty)
        }
    }

    private func performImport() {
        guard case .success(let result) = parsed, !result.requests.isEmpty else { return }

        let target: AppState.CurlImportTarget = self.target == .currentProject
            ? .currentProject
            : .newProject(name: defaultProjectName(for: result.requests))

        let imported = app.importCurlRequests(result.requests, target: target)
        dismiss()

        var message: String
        switch target {
        case .newProject(let name):
            message = app.t(.alertImportedIntoNewProject, imported, name)
        case .currentProject:
            message = app.t(.alertImportedIntoCurrentProject, imported, app.activeProject?.name ?? "")
        }
        if !result.warnings.isEmpty {
            message += "\n\n" + app.t(.notesHeader) + "\n" + result.warnings.map { "• \($0)" }.joined(separator: "\n")
        }
        app.alertMessage = .init(text: message)
    }

    /// 新项目用首个请求的主机名命名，比「cURL 导入」有信息量。
    private func defaultProjectName(for requests: [APIRequest]) -> String {
        guard let first = requests.first,
              let host = URL(string: first.url)?.host,
              !host.isEmpty
        else { return app.t(.curlImportDefaultName) }
        return host
    }

    /// 解析错误的展示文本。
    ///
    /// 已知的 `CodecError` 走 `message(_:)` 按当前语言取文案；
    /// 未知错误保留系统的 `localizedDescription`（那是系统语言）。
    private func localizedMessage(for error: Error) -> String {
        if let codecError = error as? CurlCodec.CodecError {
            return codecError.message(app.t)
        }
        return error.localizedDescription
    }

    /// 打开面板时若剪贴板里就是 curl 命令，直接预填——这是最高频的用法。
    private func prefillFromClipboard() {
        guard text.isEmpty,
              let pasted = NSPasteboard.general.string(forType: .string),
              CurlCodec.looksLikeCommand(pasted)
        else { return }
        text = pasted
    }
}
