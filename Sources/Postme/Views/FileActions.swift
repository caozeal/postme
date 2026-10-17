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
        panel.message = "选择 ApiPost / Postman 导出的 Collection v2.1 JSON 文件"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let result = try app.importPostmanCollection(data: data)
            var message = "已导入为项目「\(result.collectionName)」，共 \(result.requestCount) 个请求。"
            if result.environment != nil {
                message += "同时创建了对应的变量环境。"
            }
            if !result.warnings.isEmpty {
                message += "\n\n需要注意：\n" + result.warnings.map { "• \($0)" }.joined(separator: "\n")
            }
            app.alertMessage = .init(text: message)
        } catch {
            app.alertMessage = .init(text: "导入失败：\(error.localizedDescription)")
        }
    }

    @MainActor
    static func exportPostman(from app: AppState) {
        guard let project = app.activeProject else {
            app.alertMessage = .init(text: "当前没有项目，没有可导出的内容。")
            return
        }
        guard !project.children.isEmpty else {
            app.alertMessage = .init(text: "当前项目「\(project.name)」还是空的，没有可导出的内容。")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = Self.safeFileName(project.name) + ".json"
        panel.message = "将当前项目「\(project.name)」导出为 Postman Collection v2.1（其他项目不会导出）"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try app.postmanExportData()
            try data.write(to: url)
            app.alertMessage = .init(text: "已导出项目「\(project.name)」到 \(url.lastPathComponent)")
        } catch {
            app.alertMessage = .init(text: "导出失败：\(error.localizedDescription)")
        }
    }

    /// 项目名用作默认文件名：滤掉路径非法字符（macOS 文件名里 `/` 与 `:` 都不可用）。
    private static func safeFileName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-")
                           .replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "postme-project" : cleaned
    }
}
