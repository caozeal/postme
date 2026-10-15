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
            var message = "已导入「\(result.collectionName)」，共 \(result.requestCount) 个请求。"
            if result.environment != nil {
                message += "同时创建了对应的变量环境。"
            }
            app.alertMessage = .init(text: message)
        } catch {
            app.alertMessage = .init(text: "导入失败：\(error.localizedDescription)")
        }
    }

    @MainActor
    static func exportPostman(from app: AppState) {
        guard !app.collections.isEmpty else {
            app.alertMessage = .init(text: "当前没有可导出的集合。")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "postme-collection.json"
        panel.message = "导出为 Postman Collection v2.1"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try app.postmanExportData()
            try data.write(to: url)
            app.alertMessage = .init(text: "已导出到 \(url.lastPathComponent)")
        } catch {
            app.alertMessage = .init(text: "导出失败：\(error.localizedDescription)")
        }
    }
}
