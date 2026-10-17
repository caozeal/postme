import AppKit
import UniformTypeIdentifiers

/// 文件级操作：导入 / 导出 Postman 集合。
enum FileActions {

    @MainActor
    static func importPostman(into app: AppState) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = app.t(.postmanOpenPanelMessage)

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let result = try app.importPostmanCollection(data: data)
            var message = app.t(.postmanImported, result.collectionName, result.requestCount)
            if result.environment != nil {
                message += app.t(.postmanImportedWithEnvironment)
            }
            if !result.warnings.isEmpty {
                message += "\n\n" + app.t(.notesHeader) + "\n"
                    + result.warnings.map { "• \($0)" }.joined(separator: "\n")
            }
            app.alertMessage = .init(text: message)
        } catch {
            app.alertMessage = .init(text: app.t(.postmanImportFailed, message(for: error, app: app)))
        }
    }

    @MainActor
    static func exportPostman(from app: AppState) {
        guard let project = app.activeProject else {
            app.alertMessage = .init(text: app.t(.exportNoProject))
            return
        }
        guard !project.children.isEmpty else {
            app.alertMessage = .init(text: app.t(.exportEmptyProject, project.name))
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = Self.safeFileName(project.name) + ".json"
        panel.message = app.t(.postmanSavePanelMessage, project.name)

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try app.postmanExportData()
            try data.write(to: url)
            app.alertMessage = .init(text: app.t(.exported, project.name, url.lastPathComponent))
        } catch {
            app.alertMessage = .init(text: app.t(.exportFailed, message(for: error, app: app)))
        }
    }

    /// 已知 `CodecError` 按当前语言取文案；未知错误保留系统的 `localizedDescription`。
    @MainActor
    private static func message(for error: Error, app: AppState) -> String {
        if let codecError = error as? PostmanCodec.CodecError {
            return codecError.message(app.t)
        }
        return error.localizedDescription
    }

    /// 项目名用作默认文件名：滤掉路径非法字符（macOS 文件名里 `/` 与 `:` 都不可用）。
    private static func safeFileName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-")
                           .replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "postme-project" : cleaned
    }
}
