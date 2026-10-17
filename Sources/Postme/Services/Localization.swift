import Foundation

/// 界面文案的键。
///
/// **为什么用 enum + 字典而不是 `.xcstrings`**：SwiftPM 可执行目标的本地化资源要在运行时
/// 按 `.lproj` 取 bundle，`swift run` 与打包后的 `.app` 行为容易分叉；键也没有编译期检查。
/// 单仓库、两种语言，字典的确定性更重要（见 DESIGN.md「方案选择」）。
///
/// 命名：lowerCamelCase，以用途结尾（`saveButton` / `untitledRequest` / `curlWarningUnknownFlag`）。
enum L10nKey: String, CaseIterable, Sendable {

    // MARK: - 通用按钮 / 标签

    case cancelButton
    case saveButton
    case okButton
    case doneButton
    case deleteButton
    case renameButton
    case nameLabel
    case formatButton
    case minifyButton
    case copyButton
    case copyAllButton
    case copyURLButton
    case importButton
    case notesHeader

    // MARK: - 侧栏

    case sidebarProjectsTitle
    case sidebarNewRequest
    case sidebarNewFolder
    case sidebarImportCurlCommand
    case sidebarNewHelp
    case sidebarNewProjectEllipsis
    case sidebarRenameProjectEllipsis
    case sidebarDeleteProjectEllipsis
    case sidebarNoProject
    case sidebarSwitchProjectHelp
    case sidebarSearchPlaceholder
    case sidebarSearchResultsSection
    case sidebarNoSearchResults
    case sidebarTreeSection
    case sidebarEmptyProject
    case sidebarHistorySection
    case sidebarEmptyHistory
    case sidebarRestoreToEditor
    case sidebarDeleteRecord
    case sidebarNewRequestHere
    case sidebarNewSubfolder
    case sidebarPromoteToProject
    case sidebarDeleteFolder
    case sidebarOpen
    case sidebarOverwriteWithEditor
    case draftConflictTitle
    case draftConflictSaveAndContinue
    case draftConflictDiscard
    case draftConflictMessage
    case deleteProjectTitle
    case deleteProjectMessage
    case newFolderTitle
    case newFolderNamePlaceholder
    case newProjectTitle
    case projectNamePlaceholder
    case renameProjectTitle

    // MARK: - 请求编辑区

    case unresolvedVariablesBanner
    case saveHelpOverwrite
    case saveHelpNew
    case sendButton
    case cancelSendHelp
    case sendHelp
    case headerKeyPlaceholder
    case headerValuePlaceholder
    case saveRequestTitle
    case requestNamePlaceholder
    case saveToProjectLabel
    case folderLabel
    case projectRootOption
    case paramsKeyPlaceholder
    case paramsValuePlaceholder
    case finalURLLabel
    case validJSON
    case invalidJSON
    case emptyBodyHint
    case multipartHint
    case formFieldKeyPlaceholder
    case formFieldValuePlaceholder

    // MARK: - 分页

    case requestTabParams
    case requestTabHeaders
    case requestTabBody
    case responseTabBody
    case responseTabHeaders
    case responseTabTiming

    // MARK: - 请求体类型

    case bodyKindNone
    case bodyKindJSON
    case bodyKindRawText
    case bodyKindFormURLEncoded
    case bodyKindMultipart

    // MARK: - 键值表编辑器

    case keyValueEnabled
    case deleteRowHelp
    case addRowButton

    // MARK: - 响应区

    case sendingProgress
    case responseEmptyHint
    case responseHeadersCount
    case timingDNS
    case timingTCP
    case timingTLS
    case timingTTFB
    case timingTransfer
    case timingTotal
    case timingNote
    case requestFailedTitle
    case bodyTruncatedByLimit
    case bodyTruncatedForDisplay

    // MARK: - cURL 导入面板

    case curlTargetNewProject
    case curlTargetCurrentProject
    case curlImportTitle
    case curlImportHelp
    case curlWaiting
    case curlParsedCount
    case curlMoreCount
    case curlSummaryHeaders
    case curlSummaryJSONBody
    case curlSummaryTextBody
    case curlSummaryFormFields
    case curlSummaryMultipartFields
    case curlImportTo
    case alertImportedIntoNewProject
    case alertImportedIntoCurrentProject
    case curlImportDefaultName

    // MARK: - 环境

    case environmentsTitle
    case setAsActiveEnvironment
    case newEnvironment
    case environmentNamePlaceholder
    case currentEnvironment
    case envKeyPlaceholder
    case envValuePlaceholder
    case noEnvironmentsHint
    case selectEnvironmentHint
    case builtinVariablesHint
    case noEnvironment
    case editEnvironments
    case switchEnvironmentHelp

    // MARK: - Postman 导入 / 导出

    case postmanOpenPanelMessage
    case postmanSavePanelMessage
    case postmanImported
    case postmanImportedWithEnvironment
    case postmanImportFailed
    case exportNoProject
    case exportEmptyProject
    case exported
    case exportFailed
    case postmanUnnamedCollection
    case postmanUnnamedItem
    case postmanEnvironmentSuffix
    case postmanFileFieldPlaceholder
    case postmanWarningAuth
    case postmanErrorNotACollection
    case postmanErrorEmpty
    case postmanErrorNoProject

    // MARK: - 设置

    case settingsRequestsSection
    case settingsTimeout
    case settingsSeconds
    case settingsFollowRedirects
    case settingsAllowInsecureTLS
    case settingsAllowInsecureTLSHint
    case settingsStorageSection
    case settingsWorkspaceFile
    case settingsWorkspaceFileHint
    case settingsShortcutsSection
    case settingsShortcutSend
    case settingsShortcutSave
    case settingsShortcutNewRequest
    case settingsShortcutSearch
    case settingsShortcutImport
    case settingsShortcutExport
    case settingsLanguageSection
    case settingsLanguageLabel
    case settingsLanguageSystem
    case settingsLanguageHint

    // MARK: - 菜单

    case menuNewRequest
    case menuImportCurl
    case menuImportPostman
    case menuExportPostman
    case menuSaveToProject
    case menuSendRequest
    case menuCancelRequest
    case menuSearchRequests

    // MARK: - 新建数据的默认名（落盘数据，创建时按当前语言生成）

    case untitledRequest
    case defaultProjectName
    case newProjectDefaultName
    case newEnvironmentDefaultName
    case curlRequestDefaultName

    // MARK: - 服务层：cURL

    case curlErrorEmptyInput
    case curlErrorNoCommand
    case curlErrorMissingValue
    case curlErrorMissingURL
    case curlErrorUnterminatedQuote
    case curlWarningUnknownArg
    case curlWarningExtraURL
    case curlWarningHeaderNoColon
    case curlWarningCookieFile
    case curlWarningDataFromFile
    case curlWarningURLEncodedShape
    case curlWarningInsecure
    case curlWarningLocation
    case curlWarningTimeout
    case curlWarningProxy
    case curlWarningCert
    case curlWarningAuth
    case curlWarningUpload
    case curlWarningResolve
    case curlWarningUnsupportedMethod
    case curlWarningUnknownFlag
    case curlWarningMissingScheme
    case curlWarningUserNoPassword
    case curlWarningFileField
    case curlFileFieldPlaceholder
    case curlWarningFormAndData
    case curlWarningMixedBody

    // MARK: - 服务层：请求失败 / 响应体

    case failureEmptyURL
    case failureInvalidURL
    case failureCancelled
    case failureUnexpected
    case responseBinaryPlaceholder
    case responseLimitConfigured
    case responseTruncatedByLimit
    case responseTruncatedForDisplay
}

/// 一套语言的取词器。
///
/// `Sendable` 值类型：服务层只依赖它，不依赖 UI；切换语言就是换一个实例。
struct Localizer: Sendable, Equatable {
    let language: AppLanguage

    static let zhHans = Localizer(language: .zhHans)
    static let en = Localizer(language: .en)

    /// 无参数取词。
    func callAsFunction(_ key: L10nKey) -> String {
        L10nTable.string(for: key, language: language)
    }

    /// 带格式参数取词，走 `String(format:)`。
    func callAsFunction(_ key: L10nKey, _ args: CVarArg...) -> String {
        String(format: callAsFunction(key), arguments: args)
    }
}

/// 两张文案表。
enum L10nTable {

    static func string(for key: L10nKey, language: AppLanguage) -> String {
        let table = language == .zhHans ? zhHans : en
        return table[key] ?? zhHans[key] ?? key.rawValue
    }

    // MARK: - 简体中文

    static let zhHans: [L10nKey: String] = [
        .cancelButton: "取消",
        .saveButton: "保存",
        .okButton: "确定",
        .doneButton: "完成",
        .deleteButton: "删除",
        .renameButton: "重命名",
        .nameLabel: "名称",
        .formatButton: "格式化",
        .minifyButton: "压缩",
        .copyButton: "复制",
        .copyAllButton: "复制全部",
        .copyURLButton: "复制 URL",
        .importButton: "导入",
        .notesHeader: "需要注意：",

        .sidebarProjectsTitle: "项目",
        .sidebarNewRequest: "新建请求",
        .sidebarNewFolder: "新建文件夹",
        .sidebarImportCurlCommand: "导入 cURL 命令…",
        .sidebarNewHelp: "新建",
        .sidebarNewProjectEllipsis: "新建项目…",
        .sidebarRenameProjectEllipsis: "重命名项目…",
        .sidebarDeleteProjectEllipsis: "删除项目…",
        .sidebarNoProject: "无项目",
        .sidebarSwitchProjectHelp: "切换项目",
        .sidebarSearchPlaceholder: "搜索请求",
        .sidebarSearchResultsSection: "搜索结果（%d）",
        .sidebarNoSearchResults: "没有匹配的请求",
        .sidebarTreeSection: "目录",
        .sidebarEmptyProject: "当前项目还是空的，点右上角 ＋ 新建",
        .sidebarHistorySection: "历史",
        .sidebarEmptyHistory: "发送请求后会出现在这里",
        .sidebarRestoreToEditor: "恢复到编辑器",
        .sidebarDeleteRecord: "删除记录",
        .sidebarNewRequestHere: "在此新建请求",
        .sidebarNewSubfolder: "新建子文件夹",
        .sidebarPromoteToProject: "提为项目",
        .sidebarDeleteFolder: "删除文件夹",
        .sidebarOpen: "打开",
        .sidebarOverwriteWithEditor: "用当前编辑器内容覆盖",
        .draftConflictTitle: "当前请求有未保存的修改",
        .draftConflictSaveAndContinue: "保存并继续",
        .draftConflictDiscard: "放弃修改",
        .draftConflictMessage: "切换后当前编辑内容会被替换。",
        .deleteProjectTitle: "删除项目",
        .deleteProjectMessage: "将删除项目「%@」及其全部目录和请求，且不可恢复。",
        .newFolderTitle: "新建文件夹",
        .newFolderNamePlaceholder: "文件夹名",
        .newProjectTitle: "新建项目",
        .projectNamePlaceholder: "项目名",
        .renameProjectTitle: "重命名项目",

        .unresolvedVariablesBanner: "以下变量未定义，已按原文发出：",
        .saveHelpOverwrite: "覆盖保存到当前项目 (⌘S)",
        .saveHelpNew: "保存到当前项目 (⌘S)",
        .sendButton: "发送",
        .cancelSendHelp: "取消请求 (⌘.)",
        .sendHelp: "发送请求 (⌘↩)",
        .headerKeyPlaceholder: "Header 名",
        .headerValuePlaceholder: "Header 值",
        .saveRequestTitle: "保存请求",
        .requestNamePlaceholder: "请求名称",
        .saveToProjectLabel: "保存到项目",
        .folderLabel: "文件夹",
        .projectRootOption: "项目根目录",
        .paramsKeyPlaceholder: "参数名",
        .paramsValuePlaceholder: "参数值",
        .finalURLLabel: "最终 URL",
        .validJSON: "合法 JSON",
        .invalidJSON: "JSON 语法有误",
        .emptyBodyHint: "该请求不带请求体。",
        .multipartHint: "v1 仅支持文本字段，暂不支持文件上传。",
        .formFieldKeyPlaceholder: "字段名",
        .formFieldValuePlaceholder: "字段值",

        .requestTabParams: "Params",
        .requestTabHeaders: "Headers",
        .requestTabBody: "Body",
        .responseTabBody: "Body",
        .responseTabHeaders: "Headers",
        .responseTabTiming: "耗时",

        .bodyKindNone: "无",
        .bodyKindJSON: "JSON",
        .bodyKindRawText: "Raw Text",
        .bodyKindFormURLEncoded: "Form URL Encoded",
        .bodyKindMultipart: "Multipart Form",

        .keyValueEnabled: "启用",
        .deleteRowHelp: "删除此行",
        .addRowButton: "添加一行",

        .sendingProgress: "请求中…",
        .responseEmptyHint: "发送请求后，响应会显示在这里",
        .responseHeadersCount: "共 %d 个响应头",
        .timingDNS: "DNS 解析",
        .timingTCP: "TCP 连接",
        .timingTLS: "TLS 握手",
        .timingTTFB: "等待首字节 (TTFB)",
        .timingTransfer: "内容下载",
        .timingTotal: "总计",
        .timingNote: "各阶段取自 URLSessionTaskMetrics，存在重叠（例如 TLS 握手包含在 TCP 连接区间内），不代表可直接相加。",
        .requestFailedTitle: "请求失败",
        .bodyTruncatedByLimit: "响应体超过上限，已停止接收",
        .bodyTruncatedForDisplay: "已截断显示",

        .curlTargetNewProject: "新建项目",
        .curlTargetCurrentProject: "当前项目",
        .curlImportTitle: "导入 cURL",
        .curlImportHelp: "支持浏览器 / Postman 的 Copy as cURL，以及终端里复制的命令；多条命令会各自导入成一个请求。",
        .curlWaiting: "等待粘贴命令",
        .curlParsedCount: "解析出 %d 个请求：",
        .curlMoreCount: "…还有 %d 个",
        .curlSummaryHeaders: "%d 个头",
        .curlSummaryJSONBody: "JSON 正文",
        .curlSummaryTextBody: "文本正文",
        .curlSummaryFormFields: "%d 个表单字段",
        .curlSummaryMultipartFields: "%d 个 multipart 字段",
        .curlImportTo: "导入到",
        .alertImportedIntoNewProject: "已导入 %d 个请求，新项目「%@」。",
        .alertImportedIntoCurrentProject: "已导入 %d 个请求 到当前项目「%@」。",
        .curlImportDefaultName: "cURL 导入",

        .environmentsTitle: "环境与变量",
        .setAsActiveEnvironment: "设为当前环境",
        .newEnvironment: "新建环境",
        .environmentNamePlaceholder: "环境名",
        .currentEnvironment: "当前环境",
        .envKeyPlaceholder: "变量名（不含 {{ }}）",
        .envValuePlaceholder: "变量值",
        .noEnvironmentsHint: "还没有环境，点左下角新建",
        .selectEnvironmentHint: "选择一个环境",
        .builtinVariablesHint: "内置动态变量（无需定义）",
        .noEnvironment: "无环境",
        .editEnvironments: "编辑环境…",
        .switchEnvironmentHelp: "切换环境变量",

        .postmanOpenPanelMessage: "选择 ApiPost / Postman 导出的 Collection v2.1 JSON 文件",
        .postmanSavePanelMessage: "将当前项目「%@」导出为 Postman Collection v2.1（其他项目不会导出）",
        .postmanImported: "已导入为项目「%@」，共 %d 个请求。",
        .postmanImportedWithEnvironment: "同时创建了对应的变量环境。",
        .postmanImportFailed: "导入失败：%@",
        .exportNoProject: "当前没有项目，没有可导出的内容。",
        .exportEmptyProject: "当前项目「%@」还是空的，没有可导出的内容。",
        .exported: "已导出项目「%@」到 %@",
        .exportFailed: "导出失败：%@",
        .postmanUnnamedCollection: "未命名集合",
        .postmanUnnamedItem: "未命名",
        .postmanEnvironmentSuffix: "%@ 变量",
        .postmanFileFieldPlaceholder: "（文件字段，v1 不支持）",
        .postmanWarningAuth: "认证类型 %@ 需要动态签名，无法在导入时转换，请手动配置对应请求。",
        .postmanErrorNotACollection: "该文件不是有效的 Postman Collection v2.x 格式",
        .postmanErrorEmpty: "集合中没有可导入的请求",
        .postmanErrorNoProject: "没有可导出的项目",

        .settingsRequestsSection: "请求",
        .settingsTimeout: "超时时间",
        .settingsSeconds: "%d 秒",
        .settingsFollowRedirects: "跟随重定向",
        .settingsAllowInsecureTLS: "忽略 HTTPS 证书校验（自签证书）",
        .settingsAllowInsecureTLSHint: "仅在调试内网自签证书服务时开启。开启后 TLS 证书不再校验，存在中间人风险。",
        .settingsStorageSection: "存储",
        .settingsWorkspaceFile: "工作区文件",
        .settingsWorkspaceFileHint: "项目、环境、历史与设置都保存在这个 JSON 文件里，可直接用 git 备份。",
        .settingsShortcutsSection: "快捷键",
        .settingsShortcutSend: "发送请求",
        .settingsShortcutSave: "保存到项目",
        .settingsShortcutNewRequest: "新建请求",
        .settingsShortcutSearch: "搜索请求",
        .settingsShortcutImport: "导入为项目",
        .settingsShortcutExport: "导出项目",
        .settingsLanguageSection: "语言",
        .settingsLanguageLabel: "界面语言",
        .settingsLanguageSystem: "跟随系统",
        .settingsLanguageHint: "切换后界面立即变化；新建的请求、文件夹与项目用当前语言命名。",

        .menuNewRequest: "新建请求",
        .menuImportCurl: "导入 cURL…",
        .menuImportPostman: "导入为项目(Postman / ApiPost)…",
        .menuExportPostman: "导出项目为 Postman…",
        .menuSaveToProject: "保存到项目",
        .menuSendRequest: "发送请求",
        .menuCancelRequest: "取消请求",
        .menuSearchRequests: "搜索请求",

        .untitledRequest: "未命名请求",
        .defaultProjectName: "默认项目",
        .newProjectDefaultName: "新建项目",
        .newEnvironmentDefaultName: "新环境",
        .curlRequestDefaultName: "cURL 请求",

        .curlErrorEmptyInput: "没有可导入的内容",
        .curlErrorNoCommand: "没找到 curl 命令：文本里需要有以 curl 开头的命令",
        .curlErrorMissingValue: "第 %d 条命令：%@ 后面缺少取值",
        .curlErrorMissingURL: "第 %d 条命令：没找到请求地址",
        .curlErrorUnterminatedQuote: "第 %d 条命令：引号没有闭合",
        .curlWarningUnknownArg: "无法识别的参数「%@」已忽略。",
        .curlWarningExtraURL: "多余的地址「%@」已忽略。",
        .curlWarningHeaderNoColon: "请求头「%@」缺少冒号，已忽略。",
        .curlWarningCookieFile: "从文件读 cookie（-b %@）暂不支持，请手动补 Cookie 头。",
        .curlWarningDataFromFile: "%@ %@ 表示从文件读正文，postme 无法读该文件，已按字面文本导入。",
        .curlWarningURLEncodedShape: "--data-urlencode「%@」不是 key=value 形态，已忽略。",
        .curlWarningInsecure: "curl 的 -k（跳过证书校验）是全局设置，无法随请求导入；需要时请在 设置 → 允许自签名证书 里开启。",
        .curlWarningLocation: "curl 的 -L（跟随重定向）是全局设置，postme 默认就跟随，无需额外配置。",
        .curlWarningTimeout: "超时（%@）是全局设置，不会随导入带过来。",
        .curlWarningProxy: "代理（%@）无法随请求导入，请在网络层配置。",
        .curlWarningCert: "客户端证书（%@）暂不支持导入。",
        .curlWarningAuth: "认证方式 %@ 需要动态握手，无法在导入时还原，请手动配置。",
        .curlWarningUpload: "上传文件（-T）暂不支持，已忽略。",
        .curlWarningResolve: "%@ 无法随请求导入，请改用能直接解析的地址。",
        .curlWarningUnsupportedMethod: "请求方法「%@」不在支持范围（GET / POST / PUT / PATCH / DELETE / HEAD / OPTIONS），已按 %@ 导入。",
        .curlWarningUnknownFlag: "未识别的参数「%@」已忽略。",
        .curlWarningMissingScheme: "地址缺少协议头，已按 http:// 补全。",
        .curlWarningUserNoPassword: "curl 的 -u 只给了用户名（curl 会交互式索要密码），导入时按空密码处理。",
        .curlWarningFileField: "文件上传字段（-F key=@file）暂不支持，已保留为禁用字段。",
        .curlFileFieldPlaceholder: "（文件字段，v1 不支持）",
        .curlWarningFormAndData: "同时出现 -F 与 -d：curl 只会发送 -F，导入时以 -F 为准。",
        .curlWarningMixedBody: "--data-urlencode 与其它形态的正文混用，无法合并，已只保留正文。",

        .failureEmptyURL: "URL 为空",
        .failureInvalidURL: "URL 无效：%@",
        .failureCancelled: "请求已取消",
        .failureUnexpected: "未收到有效的 HTTP 响应",
        .responseBinaryPlaceholder: "（二进制响应，%.1f KB，无法以文本展示）",
        .responseLimitConfigured: "配置",
        .responseTruncatedByLimit: "…（响应体超过 %@ 上限，已停止接收；以上为前 %@）",
        .responseTruncatedForDisplay: "…（响应体 %@ 过大，已截断显示）",
    ]

    // MARK: - English

    static let en: [L10nKey: String] = [
        .cancelButton: "Cancel",
        .saveButton: "Save",
        .okButton: "OK",
        .doneButton: "Done",
        .deleteButton: "Delete",
        .renameButton: "Rename",
        .nameLabel: "Name",
        .formatButton: "Format",
        .minifyButton: "Minify",
        .copyButton: "Copy",
        .copyAllButton: "Copy All",
        .copyURLButton: "Copy URL",
        .importButton: "Import",
        .notesHeader: "Notes:",

        .sidebarProjectsTitle: "Projects",
        .sidebarNewRequest: "New Request",
        .sidebarNewFolder: "New Folder",
        .sidebarImportCurlCommand: "Import cURL Command…",
        .sidebarNewHelp: "New",
        .sidebarNewProjectEllipsis: "New Project…",
        .sidebarRenameProjectEllipsis: "Rename Project…",
        .sidebarDeleteProjectEllipsis: "Delete Project…",
        .sidebarNoProject: "No Project",
        .sidebarSwitchProjectHelp: "Switch project",
        .sidebarSearchPlaceholder: "Search requests",
        .sidebarSearchResultsSection: "Search results: %d",
        .sidebarNoSearchResults: "No matching requests",
        .sidebarTreeSection: "Requests",
        .sidebarEmptyProject: "This project is empty. Use ＋ in the top right to add something.",
        .sidebarHistorySection: "History",
        .sidebarEmptyHistory: "Sent requests show up here",
        .sidebarRestoreToEditor: "Restore to Editor",
        .sidebarDeleteRecord: "Delete Record",
        .sidebarNewRequestHere: "New Request Here",
        .sidebarNewSubfolder: "New Subfolder",
        .sidebarPromoteToProject: "Promote to Project",
        .sidebarDeleteFolder: "Delete Folder",
        .sidebarOpen: "Open",
        .sidebarOverwriteWithEditor: "Overwrite with Editor Content",
        .draftConflictTitle: "This request has unsaved changes",
        .draftConflictSaveAndContinue: "Save and Continue",
        .draftConflictDiscard: "Discard Changes",
        .draftConflictMessage: "The current editor content will be replaced.",
        .deleteProjectTitle: "Delete Project",
        .deleteProjectMessage: "Delete project \"%@\" with all its folders and requests? This cannot be undone.",
        .newFolderTitle: "New Folder",
        .newFolderNamePlaceholder: "Folder name",
        .newProjectTitle: "New Project",
        .projectNamePlaceholder: "Project name",
        .renameProjectTitle: "Rename Project",

        .unresolvedVariablesBanner: "Undefined variables, sent as written:",
        .saveHelpOverwrite: "Overwrite the saved request (⌘S)",
        .saveHelpNew: "Save to the current project (⌘S)",
        .sendButton: "Send",
        .cancelSendHelp: "Cancel request (⌘.)",
        .sendHelp: "Send request (⌘↩)",
        .headerKeyPlaceholder: "Header name",
        .headerValuePlaceholder: "Header value",
        .saveRequestTitle: "Save Request",
        .requestNamePlaceholder: "Request name",
        .saveToProjectLabel: "Save to Project",
        .folderLabel: "Folder",
        .projectRootOption: "Project Root",
        .paramsKeyPlaceholder: "Parameter name",
        .paramsValuePlaceholder: "Parameter value",
        .finalURLLabel: "Final URL",
        .validJSON: "Valid JSON",
        .invalidJSON: "Invalid JSON syntax",
        .emptyBodyHint: "This request has no body.",
        .multipartHint: "v1 supports text fields only; file upload is not supported.",
        .formFieldKeyPlaceholder: "Field name",
        .formFieldValuePlaceholder: "Field value",

        .requestTabParams: "Params",
        .requestTabHeaders: "Headers",
        .requestTabBody: "Body",
        .responseTabBody: "Body",
        .responseTabHeaders: "Headers",
        .responseTabTiming: "Timing",

        .bodyKindNone: "None",
        .bodyKindJSON: "JSON",
        .bodyKindRawText: "Raw Text",
        .bodyKindFormURLEncoded: "Form URL Encoded",
        .bodyKindMultipart: "Multipart Form",

        .keyValueEnabled: "Enabled",
        .deleteRowHelp: "Delete this row",
        .addRowButton: "Add Row",

        .sendingProgress: "Sending…",
        .responseEmptyHint: "Send a request to see the response here",
        .responseHeadersCount: "Response headers: %d",
        .timingDNS: "DNS lookup",
        .timingTCP: "TCP connect",
        .timingTLS: "TLS handshake",
        .timingTTFB: "Waiting for first byte (TTFB)",
        .timingTransfer: "Content download",
        .timingTotal: "Total",
        .timingNote: "Phases come from URLSessionTaskMetrics and overlap (the TLS handshake sits inside the TCP connect interval), so they do not add up.",
        .requestFailedTitle: "Request failed",
        .bodyTruncatedByLimit: "Response body exceeded the limit; receiving stopped",
        .bodyTruncatedForDisplay: "Truncated for display",

        .curlTargetNewProject: "New Project",
        .curlTargetCurrentProject: "Current Project",
        .curlImportTitle: "Import cURL",
        .curlImportHelp: "Accepts Copy as cURL from browsers and Postman, or commands copied from a terminal. Each command becomes its own request.",
        .curlWaiting: "Waiting for a command",
        .curlParsedCount: "Parsed requests: %d",
        .curlMoreCount: "…plus %d more",
        .curlSummaryHeaders: "Headers: %d",
        .curlSummaryJSONBody: "JSON body",
        .curlSummaryTextBody: "Text body",
        .curlSummaryFormFields: "Form fields: %d",
        .curlSummaryMultipartFields: "Multipart fields: %d",
        .curlImportTo: "Import to",
        .alertImportedIntoNewProject: "Imported requests: %d into new project \"%@\".",
        .alertImportedIntoCurrentProject: "Imported requests: %d into current project \"%@\".",
        .curlImportDefaultName: "cURL Import",

        .environmentsTitle: "Environments & Variables",
        .setAsActiveEnvironment: "Set as Active",
        .newEnvironment: "New Environment",
        .environmentNamePlaceholder: "Environment name",
        .currentEnvironment: "Active Environment",
        .envKeyPlaceholder: "Variable name (without {{ }})",
        .envValuePlaceholder: "Variable value",
        .noEnvironmentsHint: "No environments yet. Add one with the button in the bottom left.",
        .selectEnvironmentHint: "Select an environment",
        .builtinVariablesHint: "Built-in dynamic variables (no setup needed)",
        .noEnvironment: "No Environment",
        .editEnvironments: "Edit Environments…",
        .switchEnvironmentHelp: "Switch environment variables",

        .postmanOpenPanelMessage: "Choose a Collection v2.1 JSON file exported by ApiPost or Postman",
        .postmanSavePanelMessage: "Export project \"%@\" as a Postman Collection v2.1 (other projects are not exported)",
        .postmanImported: "Imported as project \"%@\". Requests: %d",
        .postmanImportedWithEnvironment: "A matching variable environment was also created.",
        .postmanImportFailed: "Import failed: %@",
        .exportNoProject: "There is no project, nothing to export.",
        .exportEmptyProject: "Project \"%@\" is empty, nothing to export.",
        .exported: "Exported project \"%@\" to %@",
        .exportFailed: "Export failed: %@",
        .postmanUnnamedCollection: "Untitled Collection",
        .postmanUnnamedItem: "Untitled",
        .postmanEnvironmentSuffix: "%@ variables",
        .postmanFileFieldPlaceholder: "(file field, not supported in v1)",
        .postmanWarningAuth: "Auth type %@ needs dynamic signing and cannot be converted on import; configure it manually.",
        .postmanErrorNotACollection: "The file is not a valid Postman Collection v2.x",
        .postmanErrorEmpty: "The collection has no importable requests",
        .postmanErrorNoProject: "There is no project to export",

        .settingsRequestsSection: "Requests",
        .settingsTimeout: "Timeout",
        .settingsSeconds: "%d s",
        .settingsFollowRedirects: "Follow redirects",
        .settingsAllowInsecureTLS: "Skip HTTPS certificate validation (self-signed)",
        .settingsAllowInsecureTLSHint: "Enable only when debugging an internal service with a self-signed certificate. TLS certificates are not validated and traffic can be intercepted.",
        .settingsStorageSection: "Storage",
        .settingsWorkspaceFile: "Workspace file",
        .settingsWorkspaceFileHint: "Projects, environments, history and settings all live in this JSON file, which you can back up with git.",
        .settingsShortcutsSection: "Shortcuts",
        .settingsShortcutSend: "Send request",
        .settingsShortcutSave: "Save to project",
        .settingsShortcutNewRequest: "New request",
        .settingsShortcutSearch: "Search requests",
        .settingsShortcutImport: "Import as project",
        .settingsShortcutExport: "Export project",
        .settingsLanguageSection: "Language",
        .settingsLanguageLabel: "Interface language",
        .settingsLanguageSystem: "Follow System",
        .settingsLanguageHint: "The interface updates immediately. New requests, folders and projects are named in the current language.",

        .menuNewRequest: "New Request",
        .menuImportCurl: "Import cURL…",
        .menuImportPostman: "Import as Project (Postman / ApiPost)…",
        .menuExportPostman: "Export Project as Postman…",
        .menuSaveToProject: "Save to Project",
        .menuSendRequest: "Send Request",
        .menuCancelRequest: "Cancel Request",
        .menuSearchRequests: "Search Requests",

        .untitledRequest: "Untitled Request",
        .defaultProjectName: "Default Project",
        .newProjectDefaultName: "New Project",
        .newEnvironmentDefaultName: "New Environment",
        .curlRequestDefaultName: "cURL Request",

        .curlErrorEmptyInput: "Nothing to import",
        .curlErrorNoCommand: "No curl command found: the text must contain a command starting with curl",
        .curlErrorMissingValue: "Command %d: missing value after %@",
        .curlErrorMissingURL: "Command %d: no request URL found",
        .curlErrorUnterminatedQuote: "Command %d: unterminated quote",
        .curlWarningUnknownArg: "Unrecognized argument \"%@\" ignored.",
        .curlWarningExtraURL: "Extra URL \"%@\" ignored.",
        .curlWarningHeaderNoColon: "Header \"%@\" has no colon and was ignored.",
        .curlWarningCookieFile: "Reading cookies from a file (-b %@) is not supported; add the Cookie header manually.",
        .curlWarningDataFromFile: "%@ %@ reads the body from a file, which postme cannot do; imported as literal text.",
        .curlWarningURLEncodedShape: "--data-urlencode \"%@\" is not in key=value form and was ignored.",
        .curlWarningInsecure: "curl -k (skip certificate validation) is a global setting and cannot be imported per request; enable \"Skip HTTPS certificate validation\" in Settings if needed.",
        .curlWarningLocation: "curl -L (follow redirects) is a global setting; postme follows redirects by default.",
        .curlWarningTimeout: "Timeout (%@) is a global setting and is not imported.",
        .curlWarningProxy: "Proxy (%@) cannot be imported per request; configure it in the network layer.",
        .curlWarningCert: "Client certificate (%@) cannot be imported.",
        .curlWarningAuth: "Auth type %@ needs a dynamic handshake and cannot be restored on import; configure it manually.",
        .curlWarningUpload: "File upload (-T) is not supported and was ignored.",
        .curlWarningResolve: "%@ cannot be imported per request; use a URL that resolves directly.",
        .curlWarningUnsupportedMethod: "Method \"%@\" is not supported (GET / POST / PUT / PATCH / DELETE / HEAD / OPTIONS); imported as %@.",
        .curlWarningUnknownFlag: "Unrecognized argument \"%@\" ignored.",
        .curlWarningMissingScheme: "URL had no scheme; prefixed with http://.",
        .curlWarningUserNoPassword: "curl -u provided only a username (curl would prompt for the password); imported with an empty password.",
        .curlWarningFileField: "File upload fields (-F key=@file) are not supported; kept as disabled fields.",
        .curlFileFieldPlaceholder: "(file field, not supported in v1)",
        .curlWarningFormAndData: "-F and -d both present: curl only sends -F, so the import follows -F.",
        .curlWarningMixedBody: "--data-urlencoded was mixed with another body form and cannot be merged; only the body was kept.",

        .failureEmptyURL: "URL is empty",
        .failureInvalidURL: "Invalid URL: %@",
        .failureCancelled: "Request cancelled",
        .failureUnexpected: "No valid HTTP response received",
        .responseBinaryPlaceholder: "(binary response, %.1f KB, cannot be shown as text)",
        .responseLimitConfigured: "configured",
        .responseTruncatedByLimit: "… (response body exceeded the %@ limit; receiving stopped. Showing the first %@)",
        .responseTruncatedForDisplay: "… (response body is %@; truncated for display)",
    ]
}
