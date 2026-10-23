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
    case copyCurlButton
    case copyCurlHelp
    case importButton
    case notesHeader

    // MARK: - 侧栏

    case sidebarProjectsTitle
    case sidebarNewFolder
    case sidebarImportExport
    case sidebarImportExportHelp
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
    case sidebarHistoryExpand
    case sidebarHistoryCollapse
    case sidebarClearHistory
    case clearHistoryConfirmTitle
    case clearHistoryConfirmMessage
    case sidebarEmptyHistory
    case sidebarRestoreToEditor
    case sidebarDeleteRecord
    case sidebarNewRequestHere
    case sidebarNewSubfolder
    case sidebarPromoteToProject
    case sidebarDeleteFolder
    case sidebarOpen
    case sidebarOverwriteWithEditor
    case tabCloseConfirmTitle
    case tabCloseSaveAndClose
    case tabCloseDiscard
    case tabCloseMessage
    case tabCloseHelp
    case tabMenuClose
    case tabMenuCloseOthers
    case tabMenuCloseAll
    case tabBatchCloseTitle
    case tabBatchCloseMessage
    case tabBatchCloseDiscard
    case projectSwitchConfirmTitle
    case projectSwitchSaveAndSwitch
    case projectSwitchDiscard
    case projectSwitchConfirmMessage
    case tabNewMenuHelp
    case tabNewMenuNewRequest
    case tabNewMenuImportCurl
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
    case pathParamsHeader
    case pathParamsHint
    case pathParamsCount
    case pathParamValuePlaceholder
    case pathParamEmptyHelp
    case unresolvedPathParamsBanner
    case finalURLLabel
    case validJSON
    case invalidJSON
    case emptyBodyHint
    case multipartHint
    case formFieldKeyPlaceholder
    case formFieldValuePlaceholder
    case chooseFileButton
    case binaryFileMissing
    case binaryHint
    case fileUnreadableHint
    case multipartFilesHeader
    case fileFieldNamePlaceholder
    case filePathPlaceholder
    case addFileButton
    case fileFieldMissing

    // MARK: - 分页

    case requestTabParams
    case requestTabHeaders
    case requestTabBody
    case requestTabAuth
    case requestTabCookies
    case cookieJarEnabledLabel
    case cookieJarHint
    case cookieManualHeader
    case cookieNamePlaceholder
    case cookieValuePlaceholder
    case cookieSessionHeader
    case cookieSessionEmpty
    case cookieSessionClear
    case cookieSessionCount
    case cookieSessionMatching
    case cookieDomainLabel
    case cookiePathLabel
    case cookieExpiresLabel
    case cookieExpiresSession
    case cookieJarSettingsHint
    case authKindLabel
    case authKindNone
    case authKindBearer
    case authKindBasic
    case authKindAPIKey
    case authBearerTokenLabel
    case authBearerTokenPlaceholder
    case authUsernameLabel
    case authUsernamePlaceholder
    case authPasswordLabel
    case authPasswordPlaceholder
    case authAPIKeyNameLabel
    case authAPIKeyNamePlaceholder
    case authAPIKeyValueLabel
    case authAPIKeyValuePlaceholder
    case authAPIKeyLocationLabel
    case authLocationHeader
    case authLocationQuery
    case authHint
    case authNoneHint
    case authShowSecretHelp
    case authHideSecretHelp
    case responseTabBody
    case responseTabLLMOutput
    case responseTabEvents
    case responseTabHeaders
    case responseTabTiming
    case findInResponseHelp
    case saveAsExampleButton
    case saveAsExampleHelp
    case saveAsExampleNeedsSavedRequest
    case examplesMenu
    case exampleNameLabel
    case exampleNamePlaceholder
    case exampleSavedAtLabel
    case exampleTruncated
    case exampleBinaryPlaceholder
    case exampleDeleteConfirmTitle
    case exampleDeleteConfirmMessage
    case menuFindInResponse

    // MARK: - 请求体类型

    case bodyKindNone
    case bodyKindJSON
    case bodyKindRawText
    case bodyKindFormURLEncoded
    case bodyKindMultipart
    case bodyKindBinary

    // MARK: - 键值表编辑器

    case keyValueEnabled
    case deleteRowHelp
    case addRowButton

    // MARK: - 响应区

    case sendingProgress
    case responseEmptyHint
    case streamStatusStreaming
    case streamStatusClosed
    case streamStatusCancelled
    case streamStatusFailed
    case streamEventCount
    case streamEventsDropped
    case streamEventUnterminated
    case streamAutoScroll
    case streamCopyEvent
    case streamEmptyHint
    case llmFieldLabel
    case llmFieldPickerHelp
    case llmPieceSummary
    case llmFormatOpenAI
    case llmFormatLangGraph
    case llmFormatAnthropic
    case llmFormatCustom
    case llmFormatUnknown
    case llmOtherFieldsHeader
    case llmNoJoinableFields
    case llmCustomPathButton
    case llmCustomPathTitle
    case llmCustomPathPlaceholder
    case llmCustomPathHelp
    case llmCustomPathInvalid
    case llmCustomPathLimit
    case llmFieldsDropped
    case llmCustomPathRemoveHelp
    case llmFieldTruncated
    case llmErrorFromStream
    case llmSelectFieldHint
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
    case jsonTreeExpandAll
    case jsonTreeCollapseAll
    case jsonTreeExpandNode
    case jsonTreeCollapseNode
    case jsonTreeItemCount
    case jsonTreeUnavailable

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
    case curlSummaryFileFields
    case curlSummaryBinaryBody
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
    case settingsLLMPathsSection
    case settingsLLMPathsHint
    case settingsLLMPathsEmpty
    case settingsLLMPathsAdd
    case settingsLLMPathsPlaceholder

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
    case curlWarningFormAndData
    case curlWarningMixedBody

    // MARK: - OpenAPI / Swagger 导入

    case openAPIErrorInvalidJSON
    case openAPIErrorNotASpec
    case openAPIErrorUnsupportedVersion
    case openAPIErrorNoOperations
    case openAPIVersionSwagger2
    case openAPIVersionOpenAPI3
    case openAPIDefaultTitle
    case openAPIUntitledFolder
    case openAPIEnvironmentSuffix
    case openAPIWarningUnsupportedMethod
    case openAPIWarningParamContent
    case openAPIWarningParamLocation
    case openAPIWarningParamStyle
    case openAPIWarningCollectionFormat
    case openAPIWarningBodyAndForm
    case openAPIWarningSkippedContentType
    case openAPIWarningSecurityAnd
    case openAPIWarningAuthMissingName
    case openAPIWarningAuthNeedsValue
    case openAPIWarningAuthUnsupported
    case openAPIWarningNoHost
    case openAPIWarningDefaultScheme
    case openAPIWarningMultipleSchemes
    case openAPIWarningNoServers
    case openAPIWarningMultipleServers
    case openAPIWarningServerVariable
    case openAPIWarningServerUnresolved
    case openAPIWarningRelativeServer
    case openAPIWarningExternalRef
    case openAPIWarningSkippedResponses
    case openAPIWarningSchemaBudget
    case menuImportOpenAPI
    case openAPIOpenPanelMessage
    case openAPIImportTitle
    case openAPIImportFailed
    case openAPITargetNewProject
    case openAPITargetCurrentProject
    case openAPIProjectNameLabel
    case openAPIFolderNameLabel
    case openAPIProjectNamePlaceholder
    case openAPIImportSummary
    case openAPIWarningsHeader
    case openAPIWarningsNone
    case openAPIImportedNewProject
    case openAPIImportedCurrentProject
    case openAPIImportNewHint
    case openAPIImportCurrentHint
    case openAPIImportEnvironmentHint
    case openAPIImportFileLabel
    case openAPIImportTargetLabel

    // MARK: - 服务层：请求失败 / 响应体

    case failureEmptyURL
    case failureInvalidURL
    case failureCancelled
    case failureUnexpected
    case failureFileMissing
    case failureFileUnreadable
    case failureFileTooLarge
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
        .copyCurlButton: "复制为 cURL",
        .copyCurlHelp: "把当前请求复制成 curl 命令（变量按当前环境替换，与发送完全一致）",
        .importButton: "导入",
        .notesHeader: "需要注意：",

        .sidebarProjectsTitle: "项目",
        .sidebarNewFolder: "新建文件夹",
        .sidebarImportExport: "导入",
        .sidebarImportExportHelp: "导入项目或请求，或导出当前项目",
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
        .sidebarHistoryExpand: "展开历史",
        .sidebarHistoryCollapse: "收起历史",
        .sidebarClearHistory: "清空",
        .clearHistoryConfirmTitle: "清空历史",
        .clearHistoryConfirmMessage: "将删除当前项目的全部 %d 条发送记录，且无法撤销。",
        .sidebarEmptyHistory: "发送请求后会出现在这里",
        .sidebarRestoreToEditor: "恢复到编辑器",
        .sidebarDeleteRecord: "删除记录",
        .sidebarNewRequestHere: "在此新建请求",
        .sidebarNewSubfolder: "新建子文件夹",
        .sidebarPromoteToProject: "提为项目",
        .sidebarDeleteFolder: "删除文件夹",
        .sidebarOpen: "打开",
        .sidebarOverwriteWithEditor: "用当前编辑器内容覆盖",
        .tabCloseConfirmTitle: "关闭前先保存吗？",
        .tabCloseSaveAndClose: "保存并关闭",
        .tabCloseDiscard: "放弃修改",
        .tabCloseMessage: "「%@」的修改还没保存，关闭后就会丢失。",
        .tabCloseHelp: "关闭页签",
        .tabMenuClose: "关闭页签",
        .tabMenuCloseOthers: "关闭其他页签",
        .tabMenuCloseAll: "关闭全部页签",
        .tabBatchCloseTitle: "关闭 %d 个页签？",
        .tabBatchCloseMessage: "其中 %d 个页签的修改尚未保存，关闭后将丢失。",
        .tabBatchCloseDiscard: "丢弃修改并关闭",
        .projectSwitchConfirmTitle: "切换项目",
        .projectSwitchSaveAndSwitch: "保存并切换",
        .projectSwitchDiscard: "放弃修改",
        .projectSwitchConfirmMessage: "当前有 %d 个页签存在未保存的修改，切换项目前要保存吗？",
        .tabNewMenuHelp: "新建请求 / 导入 cURL (⌘T)",
        .tabNewMenuNewRequest: "新建请求",
        .tabNewMenuImportCurl: "导入 cURL 命令…",
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
        .pathParamsHeader: "路径参数",
        .pathParamsHint: "URL 路径里的 {name} / :name 会自动出现在这里；值按单个路径段编码，可写 {{变量}}。",
        .pathParamsCount: "共 %d 个",
        .pathParamValuePlaceholder: "路径参数值，或 {{变量名}}",
        .pathParamEmptyHelp: "路径参数为空，发送时会保留占位符",
        .unresolvedPathParamsBanner: "以下路径参数未填写，已按原文发出：",
        .finalURLLabel: "最终 URL",
        .validJSON: "合法 JSON",
        .invalidJSON: "JSON 语法有误",
        .emptyBodyHint: "该请求不带请求体。",
        .multipartHint: "文本字段与文件字段会一起编码为 multipart/form-data。",
        .formFieldKeyPlaceholder: "字段名",
        .formFieldValuePlaceholder: "字段值",
        .chooseFileButton: "选择文件…",
        .binaryFileMissing: "尚未选择文件，发送会失败。",
        .binaryHint: "文件会原样作为请求正文发送；单个文件上限 64 MB。",
        .fileUnreadableHint: "文件不存在或不可读",
        .multipartFilesHeader: "文件字段",
        .fileFieldNamePlaceholder: "字段名",
        .filePathPlaceholder: "文件路径",
        .addFileButton: "添加文件",
        .fileFieldMissing: "路径为空，发送会失败。",

        .requestTabParams: "Params",
        .requestTabHeaders: "Headers",
        .requestTabBody: "Body",
        .requestTabAuth: "认证",
        .authKindLabel: "认证方式",
        .authKindNone: "无认证",
        .authKindBearer: "Bearer Token",
        .authKindBasic: "Basic Auth",
        .authKindAPIKey: "API Key",
        .authBearerTokenLabel: "Token",
        .authBearerTokenPlaceholder: "输入 Token，或 {{变量名}}",
        .authUsernameLabel: "用户名",
        .authUsernamePlaceholder: "用户名，或 {{变量名}}",
        .authPasswordLabel: "密码",
        .authPasswordPlaceholder: "密码，或 {{变量名}}",
        .authAPIKeyNameLabel: "Key 名",
        .authAPIKeyNamePlaceholder: "例如 X-API-Key",
        .authAPIKeyValueLabel: "Key 值",
        .authAPIKeyValuePlaceholder: "Key 值，或 {{变量名}}",
        .authAPIKeyLocationLabel: "添加到",
        .authLocationHeader: "Header",
        .authLocationQuery: "Query",
        .authHint: "认证在发送前注入，支持 {{变量}}；已有启用的同名 Header 或参数时，以手写的那一条为准。",
        .authNoneHint: "该请求不带认证。",
        .authShowSecretHelp: "显示",
        .authHideSecretHelp: "隐藏",
        .requestTabCookies: "Cookie",
        .cookieJarEnabledLabel: "会话内自动保存响应 Cookie",
        .cookieJarHint: "默认不携带任何 Cookie。开启后，响应的 Set-Cookie 会保存在本次运行内，并在后续匹配域 / 路径的请求里回带；退出应用即清空。",
        .cookieManualHeader: "手动 Cookie",
        .cookieNamePlaceholder: "Cookie 名",
        .cookieValuePlaceholder: "Cookie 值",
        .cookieSessionHeader: "会话 Cookie",
        .cookieSessionEmpty: "本次运行还没有收到 Cookie。",
        .cookieSessionClear: "清空会话 Cookie",
        .cookieSessionCount: "共 %d 条",
        .cookieSessionMatching: "当前请求会带上 %d 条",
        .cookieDomainLabel: "域",
        .cookiePathLabel: "路径",
        .cookieExpiresLabel: "过期",
        .cookieExpiresSession: "会话结束",
        .cookieJarSettingsHint: "只在内存中保存，退出即清空。",
        .responseTabBody: "Body",
        .responseTabLLMOutput: "大模型输出",
        .responseTabEvents: "事件",
        .responseTabHeaders: "Headers",
        .responseTabTiming: "耗时",
        .findInResponseHelp: "在响应正文中查找（⌥⌘F）",
        .saveAsExampleButton: "存为示例",
        .saveAsExampleHelp: "把这次响应保存为该请求的示例",
        .saveAsExampleNeedsSavedRequest: "先保存请求，才能保存响应示例。",
        .examplesMenu: "示例",
        .exampleNameLabel: "示例名称",
        .exampleNamePlaceholder: "例如 正常返回",
        .exampleSavedAtLabel: "保存于",
        .exampleTruncated: "示例正文超过上限，已截断。",
        .exampleBinaryPlaceholder: "（二进制响应，示例中不保存正文）",
        .exampleDeleteConfirmTitle: "删除示例",
        .exampleDeleteConfirmMessage: "确定删除「%@」？此操作不可撤销。",
        .menuFindInResponse: "在响应中查找",

        .bodyKindNone: "无",
        .bodyKindJSON: "JSON",
        .bodyKindRawText: "Raw Text",
        .bodyKindFormURLEncoded: "Form URL Encoded",
        .bodyKindMultipart: "Multipart Form",
        .bodyKindBinary: "Binary File",

        .keyValueEnabled: "启用",
        .deleteRowHelp: "删除此行",
        .addRowButton: "添加一行",

        .sendingProgress: "请求中…",
        .responseEmptyHint: "发送请求后，响应会显示在这里",
        .streamStatusStreaming: "接收中",
        .streamStatusClosed: "已结束",
        .streamStatusCancelled: "已取消",
        .streamStatusFailed: "已中断",
        .streamEventCount: "事件: %d",
        .streamEventsDropped: "已丢弃较早的 %d 个事件",
        .streamEventUnterminated: "流结束时该事件未以空行收尾",
        .streamAutoScroll: "自动滚动",
        .streamCopyEvent: "复制事件数据",
        .streamEmptyHint: "尚未收到事件",
        .llmFieldLabel: "字段",
        .llmFieldPickerHelp: "选择要拼接的字段",
        .llmPieceSummary: "%d 片 · %@",
        .llmFormatOpenAI: "格式: OpenAI",
        .llmFormatLangGraph: "格式: LangChain",
        .llmFormatAnthropic: "格式: Anthropic",
        .llmFormatCustom: "格式: 自定义路径",
        .llmFormatUnknown: "格式: 未识别",
        .llmOtherFieldsHeader: "其他字段",
        .llmNoJoinableFields: "这些事件里没有可拼接的字段（解析 %d，未解析 %d）",
        .llmCustomPathButton: "自定义路径…",
        .llmCustomPathTitle: "自定义字段路径",
        .llmCustomPathPlaceholder: "choices[0].delta.content",
        .llmCustomPathHelp: "只支持 键 与 [下标]，例如 choices[0].delta.content",
        .llmCustomPathInvalid: "路径格式不合法",
        .llmCustomPathLimit: "自定义路径最多 %d 条",
        .llmFieldsDropped: "另有 %d 个字段因上限未显示",
        .llmCustomPathRemoveHelp: "删除该路径",
        .llmFieldTruncated: "该字段超过 %@，已停止拼接",
        .llmErrorFromStream: "流内错误: %@",
        .llmSelectFieldHint: "选择一个字段以查看拼接结果",
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
        .jsonTreeExpandAll: "展开全部",
        .jsonTreeCollapseAll: "收起全部",
        .jsonTreeExpandNode: "展开",
        .jsonTreeCollapseNode: "收起",
        .jsonTreeItemCount: "%d 项",
        .jsonTreeUnavailable: "无法以树形展示：响应被截断，或内容不是完整合法的 JSON。",

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
        .curlSummaryFileFields: "%d 个文件字段",
        .curlSummaryBinaryBody: "二进制正文",
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
        .settingsWorkspaceFile: "存储目录",
        .settingsWorkspaceFileHint: "项目与环境在 workspace.json，页签在 tabs.json，历史在 history.json，响应示例在 examples.json；都在这个目录里，可直接用 git 备份。",
        .settingsShortcutsSection: "快捷键",
        .settingsShortcutSend: "发送请求",
        .settingsShortcutSave: "保存到项目",
        .settingsShortcutNewRequest: "新建请求",
        .settingsShortcutSearch: "搜索请求",
        .settingsShortcutImport: "导入 Postman / ApiPost 集合",
        .settingsShortcutExport: "导出项目",
        .settingsLanguageSection: "语言",
        .settingsLanguageLabel: "界面语言",
        .settingsLanguageSystem: "跟随系统",
        .settingsLanguageHint: "切换后界面立即变化；新建的请求、文件夹与项目用当前语言命名。",
        .settingsLLMPathsSection: "大模型输出字段路径",
        .settingsLLMPathsHint: "这些路径会出现在「大模型输出」的字段列表里。只支持 键 与 [下标]，最多 16 条。",
        .settingsLLMPathsEmpty: "还没有自定义路径",
        .settingsLLMPathsAdd: "添加",
        .settingsLLMPathsPlaceholder: "例如 choices[0].delta.content",

        .menuNewRequest: "新建请求",
        .menuImportCurl: "导入 cURL…",
        .menuImportPostman: "导入 Postman / ApiPost 集合（新项目）…",
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
        .curlWarningFileField: "无法导入文件字段 %@：stdin 或空路径不受支持。",
        .curlWarningFormAndData: "同时出现 -F 与 -d：curl 只会发送 -F，导入时以 -F 为准。",
        .curlWarningMixedBody: "--data-urlencode 与其它形态的正文混用，无法合并，已只保留正文。",

        .openAPIErrorInvalidJSON: "文件不是合法的 JSON。",
        .openAPIErrorNotASpec: "文件不是 OpenAPI / Swagger 文档。",
        .openAPIErrorUnsupportedVersion: "暂不支持该版本：%@（支持 Swagger 2.0 / OpenAPI 3.x）。",
        .openAPIErrorNoOperations: "文档里没有可导入的接口。",
        .openAPIVersionSwagger2: "Swagger 2.0",
        .openAPIVersionOpenAPI3: "OpenAPI 3.x",
        .openAPIDefaultTitle: "OpenAPI 导入",
        .openAPIUntitledFolder: "未分组",
        .openAPIEnvironmentSuffix: "%@ 变量",
        .openAPIWarningUnsupportedMethod: "HTTP 方法 %@ 暂不支持，已跳过该接口。",
        .openAPIWarningParamContent: "参数「%@」使用 content 定义，暂不支持，已跳过。",
        .openAPIWarningParamLocation: "参数位置 %@ 暂不支持，已跳过。",
        .openAPIWarningParamStyle: "参数序列化方式 %@ 暂不支持，值可能不准确。",
        .openAPIWarningCollectionFormat: "数组参数格式 %@ 暂不支持，已按逗号拼接。",
        .openAPIWarningBodyAndForm: "同一接口同时定义了 body 与 formData，已以 body 为准。",
        .openAPIWarningSkippedContentType: "请求体类型 %@ 暂不支持，已跳过。",
        .openAPIWarningSecurityAnd: "同一认证要求包含多个方案，当前只映射第一个。",
        .openAPIWarningAuthMissingName: "ApiKey 认证缺少名称，已跳过。",
        .openAPIWarningAuthNeedsValue: "认证「%@」已映射，凭据为空，请到认证页签填写。",
        .openAPIWarningAuthUnsupported: "认证类型 %@ 暂不支持，已跳过；请手动配置。",
        .openAPIWarningNoHost: "Swagger 2.0 缺少 host，无法生成 baseUrl 环境。",
        .openAPIWarningDefaultScheme: "Swagger 2.0 未定义 schemes，baseUrl 已按 https 生成。",
        .openAPIWarningMultipleSchemes: "Swagger 2.0 定义了 %d 个 scheme，已使用第一个。",
        .openAPIWarningNoServers: "OpenAPI 未定义 servers，无法生成 baseUrl 环境。",
        .openAPIWarningMultipleServers: "OpenAPI 定义了 %d 个 servers，已使用第一个。",
        .openAPIWarningServerVariable: "server 变量 %@ 没有默认值，已保留占位符。",
        .openAPIWarningServerUnresolved: "server URL 仍有未解析变量：%@",
        .openAPIWarningRelativeServer: "server URL 不是绝对地址（%@），无法生成 baseUrl 环境。",
        .openAPIWarningExternalRef: "外部或无法解析的 $ref：%@，已跳过。",
        .openAPIWarningSkippedResponses: "已跳过 %d 个响应定义（本版只导入请求）。",
        .openAPIWarningSchemaBudget: "Schema 过大，生成的示例正文已截断。",
        .menuImportOpenAPI: "导入 OpenAPI / Swagger…",
        .openAPIOpenPanelMessage: "选择 Swagger 2.0 / OpenAPI 3.x 的 JSON 文件",
        .openAPIImportTitle: "导入 OpenAPI / Swagger",
        .openAPIImportFailed: "导入失败：%@",
        .openAPITargetNewProject: "新建项目",
        .openAPITargetCurrentProject: "并入当前项目",
        .openAPIProjectNameLabel: "项目名称",
        .openAPIFolderNameLabel: "文件夹名称",
        .openAPIProjectNamePlaceholder: "导入名称",
        .openAPIImportSummary: "%d 个接口 · %d 个目录",
        .openAPIWarningsHeader: "导入提示（%d）",
        .openAPIWarningsNone: "没有需要注意的问题。",
        .openAPIImportedNewProject: "已导入 %d 个接口，新项目「%@」。",
        .openAPIImportedCurrentProject: "已导入 %d 个接口 到当前项目「%@」。",
        .openAPIImportNewHint: "将新建项目并切换过去。",
        .openAPIImportCurrentHint: "将在当前项目「%@」根目录新建一个文件夹。",
        .openAPIImportEnvironmentHint: "将创建并启用环境「%@」。",
        .openAPIImportFileLabel: "文件",
        .openAPIImportTargetLabel: "导入到",

        .failureEmptyURL: "URL 为空",
        .failureInvalidURL: "URL 无效：%@",
        .failureCancelled: "请求已取消",
        .failureUnexpected: "未收到有效的 HTTP 响应",
        .failureFileMissing: "未选择文件",
        .failureFileUnreadable: "无法读取文件：%@",
        .failureFileTooLarge: "文件超过 %@ 上限：%@",
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
        .copyCurlButton: "Copy as cURL",
        .copyCurlHelp: "Copy the request as a curl command (variables substituted from the active environment, exactly as it is sent)",
        .importButton: "Import",
        .notesHeader: "Notes:",

        .sidebarProjectsTitle: "Projects",
        .sidebarNewFolder: "New Folder",
        .sidebarImportExport: "Import",
        .sidebarImportExportHelp: "Import projects or requests, or export the current project",
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
        .sidebarHistoryExpand: "Expand history",
        .sidebarHistoryCollapse: "Collapse history",
        .sidebarClearHistory: "Clear",
        .clearHistoryConfirmTitle: "Clear history",
        .clearHistoryConfirmMessage: "This deletes all %d recorded sends and cannot be undone.",
        .sidebarEmptyHistory: "Sent requests show up here",
        .sidebarRestoreToEditor: "Restore to Editor",
        .sidebarDeleteRecord: "Delete Record",
        .sidebarNewRequestHere: "New Request Here",
        .sidebarNewSubfolder: "New Subfolder",
        .sidebarPromoteToProject: "Promote to Project",
        .sidebarDeleteFolder: "Delete Folder",
        .sidebarOpen: "Open",
        .sidebarOverwriteWithEditor: "Overwrite with Editor Content",
        .tabCloseConfirmTitle: "Save before closing?",
        .tabCloseSaveAndClose: "Save and Close",
        .tabCloseDiscard: "Discard Changes",
        .tabCloseMessage: "\"%@\" has unsaved changes that will be lost.",
        .tabCloseHelp: "Close Tab",
        .tabMenuClose: "Close Tab",
        .tabMenuCloseOthers: "Close Other Tabs",
        .tabMenuCloseAll: "Close All Tabs",
        .tabBatchCloseTitle: "Close %d tabs?",
        .tabBatchCloseMessage: "%d of them have unsaved changes that will be lost.",
        .tabBatchCloseDiscard: "Discard Changes and Close",
        .projectSwitchConfirmTitle: "Switch Project",
        .projectSwitchSaveAndSwitch: "Save and Switch",
        .projectSwitchDiscard: "Discard Changes",
        .projectSwitchConfirmMessage: "%d tab(s) have unsaved changes. Save before switching?",
        .tabNewMenuHelp: "New Request / Import cURL (⌘T)",
        .tabNewMenuNewRequest: "New Request",
        .tabNewMenuImportCurl: "Import cURL Command…",
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
        .pathParamsHeader: "Path Parameters",
        .pathParamsHint: "Placeholders like {name} / :name in the URL path appear here; values are encoded as a single path segment and may use {{variables}}.",
        .pathParamsCount: "%d total",
        .pathParamValuePlaceholder: "Path value, or {{variable}}",
        .pathParamEmptyHelp: "Empty path parameter; the placeholder is sent as written",
        .unresolvedPathParamsBanner: "These path parameters are empty and were sent as written:",
        .finalURLLabel: "Final URL",
        .validJSON: "Valid JSON",
        .invalidJSON: "Invalid JSON syntax",
        .emptyBodyHint: "This request has no body.",
        .multipartHint: "Text fields and file fields are encoded together as multipart/form-data.",
        .formFieldKeyPlaceholder: "Field name",
        .formFieldValuePlaceholder: "Field value",
        .chooseFileButton: "Choose File…",
        .binaryFileMissing: "No file selected; sending will fail.",
        .binaryHint: "The file is sent as the raw request body; the limit is 64 MB per file.",
        .fileUnreadableHint: "File does not exist or is not readable",
        .multipartFilesHeader: "File Fields",
        .fileFieldNamePlaceholder: "Field name",
        .filePathPlaceholder: "File path",
        .addFileButton: "Add File",
        .fileFieldMissing: "Path is empty; sending will fail.",

        .requestTabParams: "Params",
        .requestTabHeaders: "Headers",
        .requestTabBody: "Body",
        .requestTabAuth: "Auth",
        .authKindLabel: "Auth Type",
        .authKindNone: "No Auth",
        .authKindBearer: "Bearer Token",
        .authKindBasic: "Basic Auth",
        .authKindAPIKey: "API Key",
        .authBearerTokenLabel: "Token",
        .authBearerTokenPlaceholder: "Token, or {{variable}}",
        .authUsernameLabel: "Username",
        .authUsernamePlaceholder: "Username, or {{variable}}",
        .authPasswordLabel: "Password",
        .authPasswordPlaceholder: "Password, or {{variable}}",
        .authAPIKeyNameLabel: "Key Name",
        .authAPIKeyNamePlaceholder: "e.g. X-API-Key",
        .authAPIKeyValueLabel: "Key Value",
        .authAPIKeyValuePlaceholder: "Key value, or {{variable}}",
        .authAPIKeyLocationLabel: "Add To",
        .authLocationHeader: "Header",
        .authLocationQuery: "Query",
        .authHint: "Auth is applied before sending and supports {{variables}}. If an enabled header or parameter with the same name already exists, your explicit row wins.",
        .authNoneHint: "This request has no auth.",
        .authShowSecretHelp: "Show",
        .authHideSecretHelp: "Hide",
        .requestTabCookies: "Cookies",
        .cookieJarEnabledLabel: "Keep response cookies for this session",
        .cookieJarHint: "No cookies are sent by default. When enabled, Set-Cookie values are kept in memory for this run and sent back to matching domain/path requests; quitting clears them.",
        .cookieManualHeader: "Manual Cookies",
        .cookieNamePlaceholder: "Cookie name",
        .cookieValuePlaceholder: "Cookie value",
        .cookieSessionHeader: "Session Cookies",
        .cookieSessionEmpty: "No cookies received in this run yet.",
        .cookieSessionClear: "Clear Session Cookies",
        .cookieSessionCount: "%d cookies",
        .cookieSessionMatching: "%d will be sent with this request",
        .cookieDomainLabel: "Domain",
        .cookiePathLabel: "Path",
        .cookieExpiresLabel: "Expires",
        .cookieExpiresSession: "Session end",
        .cookieJarSettingsHint: "Kept in memory only; cleared when the app quits.",
        .responseTabBody: "Body",
        .responseTabLLMOutput: "Model Output",
        .responseTabEvents: "Events",
        .responseTabHeaders: "Headers",
        .responseTabTiming: "Timing",
        .findInResponseHelp: "Find in the response body (⌥⌘F)",
        .saveAsExampleButton: "Save as Example",
        .saveAsExampleHelp: "Save this response as an example of the request",
        .saveAsExampleNeedsSavedRequest: "Save the request first to keep response examples.",
        .examplesMenu: "Examples",
        .exampleNameLabel: "Example Name",
        .exampleNamePlaceholder: "e.g. Normal response",
        .exampleSavedAtLabel: "Saved",
        .exampleTruncated: "The example body exceeded the limit and was truncated.",
        .exampleBinaryPlaceholder: "(Binary response; the body is not stored in examples.)",
        .exampleDeleteConfirmTitle: "Delete Example",
        .exampleDeleteConfirmMessage: "Delete “%@”? This cannot be undone.",
        .menuFindInResponse: "Find in Response",

        .bodyKindNone: "None",
        .bodyKindJSON: "JSON",
        .bodyKindRawText: "Raw Text",
        .bodyKindFormURLEncoded: "Form URL Encoded",
        .bodyKindMultipart: "Multipart Form",
        .bodyKindBinary: "Binary File",

        .keyValueEnabled: "Enabled",
        .deleteRowHelp: "Delete this row",
        .addRowButton: "Add Row",

        .sendingProgress: "Sending…",
        .responseEmptyHint: "Send a request to see the response here",
        .streamStatusStreaming: "Streaming",
        .streamStatusClosed: "Closed",
        .streamStatusCancelled: "Cancelled",
        .streamStatusFailed: "Interrupted",
        .streamEventCount: "Events: %d",
        .streamEventsDropped: "dropped %d earlier events",
        .streamEventUnterminated: "Event not terminated by a blank line before the stream closed",
        .streamAutoScroll: "Auto-scroll",
        .streamCopyEvent: "Copy event data",
        .streamEmptyHint: "No events received yet",
        .llmFieldLabel: "Field",
        .llmFieldPickerHelp: "Choose the field to join",
        .llmPieceSummary: "%d pieces · %@",
        .llmFormatOpenAI: "Format: OpenAI",
        .llmFormatLangGraph: "Format: LangChain",
        .llmFormatAnthropic: "Format: Anthropic",
        .llmFormatCustom: "Format: custom paths",
        .llmFormatUnknown: "Format: unrecognized",
        .llmOtherFieldsHeader: "Other fields",
        .llmNoJoinableFields: "No joinable fields in these events (parsed %d, unparsed %d)",
        .llmCustomPathButton: "Custom path…",
        .llmCustomPathTitle: "Custom field path",
        .llmCustomPathPlaceholder: "choices[0].delta.content",
        .llmCustomPathHelp: "Only keys and [index], e.g. choices[0].delta.content",
        .llmCustomPathInvalid: "Invalid path syntax",
        .llmCustomPathLimit: "At most %d custom paths",
        .llmFieldsDropped: "dropped %d fields (field limit reached)",
        .llmCustomPathRemoveHelp: "Remove this path",
        .llmFieldTruncated: "field exceeded %@; joining stopped",
        .llmErrorFromStream: "Stream error: %@",
        .llmSelectFieldHint: "Select a field to see the joined text",
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
        .jsonTreeExpandAll: "Expand All",
        .jsonTreeCollapseAll: "Collapse All",
        .jsonTreeExpandNode: "Expand",
        .jsonTreeCollapseNode: "Collapse",
        .jsonTreeItemCount: "%d items",
        .jsonTreeUnavailable: "Cannot show a tree: the response was truncated or is not complete, valid JSON.",

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
        .curlSummaryFileFields: "File fields: %d",
        .curlSummaryBinaryBody: "Binary body",
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
        .settingsWorkspaceFile: "Storage directory",
        .settingsWorkspaceFileHint: "Projects and environments in workspace.json, tabs in tabs.json, history in history.json, response examples in examples.json — all in this directory, which you can back up with git.",
        .settingsShortcutsSection: "Shortcuts",
        .settingsShortcutSend: "Send request",
        .settingsShortcutSave: "Save to project",
        .settingsShortcutNewRequest: "New request",
        .settingsShortcutSearch: "Search requests",
        .settingsShortcutImport: "Import Postman / ApiPost collection",
        .settingsShortcutExport: "Export project",
        .settingsLanguageSection: "Language",
        .settingsLanguageLabel: "Interface language",
        .settingsLanguageSystem: "Follow System",
        .settingsLanguageHint: "The interface updates immediately. New requests, folders and projects are named in the current language.",
        .settingsLLMPathsSection: "Model output field paths",
        .settingsLLMPathsHint: "These paths appear in the Model Output field list. Only keys and [index] are supported, at most 16 paths.",
        .settingsLLMPathsEmpty: "No custom paths yet",
        .settingsLLMPathsAdd: "Add",
        .settingsLLMPathsPlaceholder: "e.g. choices[0].delta.content",

        .menuNewRequest: "New Request",
        .menuImportCurl: "Import cURL…",
        .menuImportPostman: "Import Postman / ApiPost Collection (New Project)…",
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
        .curlWarningFileField: "Cannot import file field %@: stdin or an empty path is not supported.",
        .curlWarningFormAndData: "-F and -d both present: curl only sends -F, so the import follows -F.",
        .curlWarningMixedBody: "--data-urlencoded was mixed with another body form and cannot be merged; only the body was kept.",

        .openAPIErrorInvalidJSON: "The file is not valid JSON.",
        .openAPIErrorNotASpec: "The file is not an OpenAPI / Swagger document.",
        .openAPIErrorUnsupportedVersion: "Unsupported version: %@ (Swagger 2.0 / OpenAPI 3.x are supported).",
        .openAPIErrorNoOperations: "The document contains no importable operations.",
        .openAPIVersionSwagger2: "Swagger 2.0",
        .openAPIVersionOpenAPI3: "OpenAPI 3.x",
        .openAPIDefaultTitle: "OpenAPI Import",
        .openAPIUntitledFolder: "Ungrouped",
        .openAPIEnvironmentSuffix: "%@ Variables",
        .openAPIWarningUnsupportedMethod: "HTTP method %@ is not supported; the operation was skipped.",
        .openAPIWarningParamContent: "Parameter “%@” uses a content definition, which is not supported; it was skipped.",
        .openAPIWarningParamLocation: "Parameter location %@ is not supported; it was skipped.",
        .openAPIWarningParamStyle: "Parameter style %@ is not supported; the value may be inaccurate.",
        .openAPIWarningCollectionFormat: "Array format %@ is not supported; values were joined with commas.",
        .openAPIWarningBodyAndForm: "This operation defines both body and formData; body was used.",
        .openAPIWarningSkippedContentType: "Request body type %@ is not supported; it was skipped.",
        .openAPIWarningSecurityAnd: "The security requirement contains multiple schemes; only the first was mapped.",
        .openAPIWarningAuthMissingName: "An ApiKey security scheme has no name; it was skipped.",
        .openAPIWarningAuthNeedsValue: "Auth “%@” was mapped with empty credentials; fill them in the Auth tab.",
        .openAPIWarningAuthUnsupported: "Auth type %@ is not supported; it was skipped. Configure it manually.",
        .openAPIWarningNoHost: "Swagger 2.0 has no host; no baseUrl environment was created.",
        .openAPIWarningDefaultScheme: "Swagger 2.0 defines no schemes; baseUrl uses https.",
        .openAPIWarningMultipleSchemes: "Swagger 2.0 defines %d schemes; the first was used.",
        .openAPIWarningNoServers: "OpenAPI defines no servers; no baseUrl environment was created.",
        .openAPIWarningMultipleServers: "OpenAPI defines %d servers; the first was used.",
        .openAPIWarningServerVariable: "Server variable %@ has no default; the placeholder was kept.",
        .openAPIWarningServerUnresolved: "Server URL still has unresolved variables: %@",
        .openAPIWarningRelativeServer: "Server URL is not absolute (%@); no baseUrl environment was created.",
        .openAPIWarningExternalRef: "External or unresolved $ref: %@; it was skipped.",
        .openAPIWarningSkippedResponses: "Skipped %d response definitions (this version imports requests only).",
        .openAPIWarningSchemaBudget: "The schema is very large; generated example bodies were truncated.",
        .menuImportOpenAPI: "Import OpenAPI / Swagger…",
        .openAPIOpenPanelMessage: "Choose a Swagger 2.0 / OpenAPI 3.x JSON file",
        .openAPIImportTitle: "Import OpenAPI / Swagger",
        .openAPIImportFailed: "Import failed: %@",
        .openAPITargetNewProject: "New Project",
        .openAPITargetCurrentProject: "Current Project",
        .openAPIProjectNameLabel: "Project Name",
        .openAPIFolderNameLabel: "Folder Name",
        .openAPIProjectNamePlaceholder: "Import name",
        .openAPIImportSummary: "%d requests · %d folders",
        .openAPIWarningsHeader: "Import notes (%d)",
        .openAPIWarningsNone: "Nothing needs attention.",
        .openAPIImportedNewProject: "Imported %d requests into new project “%@”.",
        .openAPIImportedCurrentProject: "Imported %d requests into the current project “%@”.",
        .openAPIImportNewHint: "Creates and activates a new project.",
        .openAPIImportCurrentHint: "Creates a folder at the root of the current project “%@”.",
        .openAPIImportEnvironmentHint: "Creates and activates environment “%@”.",
        .openAPIImportFileLabel: "File",
        .openAPIImportTargetLabel: "Import to",

        .failureEmptyURL: "URL is empty",
        .failureInvalidURL: "Invalid URL: %@",
        .failureCancelled: "Request cancelled",
        .failureUnexpected: "No valid HTTP response received",
        .failureFileMissing: "No file selected",
        .failureFileUnreadable: "Cannot read file: %@",
        .failureFileTooLarge: "File exceeds the %@ limit: %@",
        .responseBinaryPlaceholder: "(binary response, %.1f KB, cannot be shown as text)",
        .responseLimitConfigured: "configured",
        .responseTruncatedByLimit: "… (response body exceeded the %@ limit; receiving stopped. Showing the first %@)",
        .responseTruncatedForDisplay: "… (response body is %@; truncated for display)",
    ]
}
