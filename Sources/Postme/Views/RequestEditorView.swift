import SwiftUI

/// 请求编辑区：方法 + URL + 发送，以及 Params / Headers / Body 分页。
struct RequestEditorView: View {
    @Environment(AppState.self) private var app
    @State private var variableNavigation: RequestVariableNavigation?
    @FocusState private var urlFocused: Bool

    var body: some View {
        @Bindable var app = app
        let preview = app.preparedDraft
        let url = RequestExecutor.previewURL(preview.request)
        let navigation = variableNavigation.flatMap { preview.missingVariables.contains($0.variable) ? $0 : nil }
        return VStack(spacing: 0) {
            requestBar
            requestTarget(url: url, preview: preview)
            Divider()
            tabBar(authIsConfigured: preview.request.auth.isConfigured)
            Divider()
            ScrollViewReader { proxy in
                content(previewURL: url, preview: preview)
                    .task(id: navigation) {
                        guard let field = navigation?.variable.field, field.section == app.requestSection else { return }
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        proxy.scrollTo(AnyHashable(field.scrollAnchor), anchor: .center)
                    }
            }
        }
        .environment(\.requestVariableNavigation, navigation)
        .sheet(isPresented: $app.showSaveSheet) { saveSheet }
        // 草稿编辑即防抖落盘（600ms 合并）。原先草稿只在退出时落盘，
        // 崩溃或强杀就会丢掉整个编辑中的请求。
        .onChange(of: app.draft) { _, _ in
            app.persistDraft()
        }
        // URL 是路径参数的唯一真相：新增/删除占位符时同步参数行。
        .onAppear { app.syncPathParams(prune: true) }
        .onChange(of: app.draft.url) { _, _ in app.syncPathParams(prune: false) }
        .onChange(of: app.activeTabID) { _, _ in
            variableNavigation = nil
            app.syncPathParams(prune: true)
        }
    }

    private func requestTarget(url: String, preview: AppState.PreparedRequest) -> some View {
        let environment = app.activeEnvironment?.name ?? app.t(.noEnvironment)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Label(environment, icon: .environment)
                    .lineLimit(1)
                    .help(environment)
                    .frame(maxWidth: 180, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)

                if let destination = Self.destination(in: url) {
                    Divider().frame(height: 10)
                    Text(destination)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(destination)
                }

                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)

            if !preview.missingVariables.isEmpty {
                unresolvedVariablesWarning(preview)
            }
            if !preview.unresolvedPathParams.isEmpty {
                pathParameterWarning(preview.unresolvedPathParams)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func unresolvedVariablesWarning(_ preview: AppState.PreparedRequest) -> some View {
        let names = preview.unresolved.map { "{{\($0)}}" }.joined(separator: ", ")
        let message = app.t(.unresolvedVariablesBanner, names)
        if preview.missingVariables.count == 1, let variable = preview.missingVariables.first {
            Button {
                navigate(to: variable)
            } label: {
                HStack(alignment: .top, spacing: 6) {
                    requestWarning(message)
                    Image(icon: .collapsed).font(.system(size: 9, weight: .semibold)).accessibilityHidden(true)
                }
            }
            .buttonStyle(.plain)
            .help(variableLocation(variable.field))
            .accessibilityHint(variableLocation(variable.field))
        } else {
            Menu {
                ForEach(preview.missingVariables, id: \.self) { variable in
                    Button("{{\(variable.name)}} · \(variableLocation(variable.field))") { navigate(to: variable) }
                }
            } label: {
                requestWarning(message)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel(message)
        }
    }

    private func navigate(to variable: MissingRequestVariable) {
        if let section = variable.field.section {
            app.requestSection = section
        } else {
            urlFocused = true
        }
        variableNavigation = RequestVariableNavigation(variable: variable)
    }

    private func variableLocation(_ field: RequestVariableField) -> String {
        let title: L10nKey
        switch field {
        case .url: title = .requestURLField
        case .body: title = .requestTabBody
        case .rawContentType, .binaryContentType: return "Body · Content-Type"
        case .binaryPath: title = .filePathPlaceholder
        case .bearerToken: title = .authBearerTokenLabel
        case .username: title = .authUsernameLabel
        case .password: title = .authPasswordLabel
        case .apiKeyName: title = .authAPIKeyNameLabel
        case .apiKeyValue: title = .authAPIKeyValueLabel
        case .row(let table, let id, let column):
            let row: Int?
            let label: L10nKey
            switch table {
            case .headers:
                row = app.draft.headers.firstIndex { $0.id == id }
                label = column == .name ? .headerKeyPlaceholder : .headerValuePlaceholder
            case .query:
                row = app.draft.queryParams.firstIndex { $0.id == id }
                label = column == .name ? .paramsKeyPlaceholder : .paramsValuePlaceholder
            case .path:
                if let item = app.draft.pathParams.first(where: { $0.id == id }) {
                    return "\(RequestSection.params.title(app.t)) · {\(item.key)}"
                }
                row = nil
                label = .pathParamsHeader
            case .form:
                row = app.draft.formFields.firstIndex { $0.id == id }
                label = column == .name ? .formFieldKeyPlaceholder : .formFieldValuePlaceholder
            case .files:
                row = app.draft.fileFields.firstIndex { $0.id == id }
                label = column == .name ? .fileFieldNamePlaceholder : .filePathPlaceholder
            case .cookies:
                row = app.draft.cookies.firstIndex { $0.id == id }
                label = column == .name ? .cookieNamePlaceholder : .cookieValuePlaceholder
            }
            let section = field.section?.title(app.t) ?? ""
            return [section, row.map { app.t(.requestVariableRow, $0 + 1) }, app.t(label)]
                .compactMap { $0 }.joined(separator: " · ")
        }
        if let section = field.section, title != .requestTabBody {
            return "\(section.title(app.t)) · \(app.t(title))"
        }
        return app.t(title)
    }

    @ViewBuilder
    private func pathParameterWarning(_ names: [String]) -> some View {
        let message = app.t(.unresolvedPathParamsBanner, names.map { "{\($0)}" }.joined(separator: ", "))
        if PathParams.placeholders(in: app.draft.url).contains(where: names.contains) {
            Button {
                app.requestSection = .params
            } label: {
                HStack(alignment: .top, spacing: 6) {
                    requestWarning(message)
                    Image(icon: .collapsed)
                        .font(.system(size: 9, weight: .semibold))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(message)\n\(app.t(.requestEditPathParams))")
            .accessibilityHint(app.t(.requestEditPathParams))
        } else {
            requestWarning(message)
        }
    }

    private func requestWarning(_ message: String) -> some View {
        Label {
            Text(message)
                .lineLimit(2)
        } icon: {
            Image(icon: .warning)
                .foregroundStyle(statusTint(for: 400))
        }
        .help(message)
    }

    /// 只展示协议和主机，避免把 URL 中的凭据或查询参数放到常驻工具栏。
    static func destination(in url: String) -> String? {
        guard var components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty, !host.contains("{")
        else { return nil }

        components.user = nil
        components.password = nil
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.string
    }

    // MARK: - 顶部请求栏

    private var hasRequestURL: Bool {
        !app.draft.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var requestBar: some View {
        let url = urlField
        let primary = sendButton.fixedSize()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                methodMenu
                url
                copyCurlButton.fixedSize()
                saveButton.fixedSize()
                primary
            }
            HStack(spacing: 8) {
                methodMenu
                url
                requestActionsMenu
                primary
            }
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 8) {
                    methodMenu
                    url
                }
                HStack(spacing: 8) {
                    requestActionsMenu
                    primary
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var urlField: some View {
        @Bindable var app = app
        return TextField("https://api.example.com/path", text: $app.draft.url)
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            // ViewThatFits 用理想宽度选择布局，地址长度只影响编辑框内部的滚动。
            .frame(minWidth: 200, idealWidth: 200, maxWidth: .infinity)
            .accessibilityLabel(app.t(.requestURLField))
            .focused($urlFocused)
            .requestVariableField(.url)
            .onSubmit { Task { await app.send() } }
    }

    private var requestActionsMenu: some View {
        Menu {
            Button { app.beginSave() } label: { Label(app.t(.saveButton), icon: .save) }
            Button { FileActions.copyAsCurl(from: app, request: app.draft) } label: {
                Label(app.t(.copyCurlButton), icon: .code)
            }
            .disabled(!hasRequestURL)
        } label: {
            Image(icon: .more).frame(width: 24, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(app.t(.requestMoreActions))
        .accessibilityLabel(app.t(.requestMoreActions))
    }

    /// 图标按钮：请求栏已经够挤（方法、URL、保存、发送），「复制为 cURL」的文字
    /// 占的宽度比它的使用频率高得多。文字移到 tooltip / 无障碍标签里。
    private var copyCurlButton: some View {
        CopyButton(title: app.t(.copyCurlButton), icon: .code, help: app.t(.copyCurlHelp)) {
            app.curlCommand(for: app.draft)
        }
        .labelStyle(.iconOnly)
        .foregroundStyle(hasRequestURL ? BrandColor.icon : Color(nsColor: .disabledControlTextColor))
        .disabled(!hasRequestURL)
        .id(app.activeTabID)
    }

    private var saveButton: some View {
        Button {
            app.beginSave()
        } label: {
            Label(app.t(.saveButton), icon: .save)
        }
        .help(app.editingNodeID != nil ? app.t(.saveHelpOverwrite) : app.t(.saveHelpNew))
    }

    private var methodMenu: some View {
        @Bindable var app = app
        return Menu {
            ForEach(HTTPMethod.allCases) { method in
                Button(method.rawValue) { app.draft.method = method }
            }
        } label: {
            HStack(spacing: 4) {
                Text(app.draft.method.rawValue)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(app.draft.method.tint)
                Image(icon: .expanded)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 62, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var sendButton: some View {
        Button {
            if app.isSending {
                app.cancelSend()
            } else {
                Task { await app.send() }
            }
        } label: {
            HStack(spacing: 6) {
                if app.isSending {
                    ProgressView().controlSize(.small)
                } else {
                    SendGlyph()
                        .frame(width: 13, height: 13)
                        .accessibilityHidden(true)
                }
                Text(app.isSending ? app.t(.cancelButton) : app.t(.sendButton))
            }
            .frame(minWidth: 64)
        }
        .buttonStyle(.borderedProminent)
        .tint(app.isSending ? .red : BrandColor.action)
        .disabled(!app.isSending && !hasRequestURL)
        .help(app.isSending ? app.t(.cancelSendHelp) : app.t(.sendHelp))
    }

    // MARK: - 分页

    private func tabBar(authIsConfigured: Bool) -> some View {
        let picker = requestSectionPicker(authIsConfigured: authIsConfigured)
        return ViewThatFits(in: .horizontal) {
            picker.pickerStyle(.segmented).fixedSize()
            picker.pickerStyle(.menu).fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func requestSectionPicker(authIsConfigured: Bool) -> some View {
        @Bindable var app = app
        return Picker(app.t(.requestSectionPickerLabel), selection: $app.requestSection) {
            ForEach(RequestSection.allCases) { tab in
                Text(tabLabel(tab, authIsConfigured: authIsConfigured)).tag(tab)
            }
        }
        .labelsHidden()
    }

    private func tabLabel(_ tab: RequestSection, authIsConfigured: Bool) -> String {
        let title = tab.title(app.t)
        switch tab {
        case .params:
            let n = app.draft.queryParams.filter { $0.isEnabled && !$0.key.isEmpty }.count
            return n > 0 ? "\(title) (\(n))" : title
        case .headers:
            let n = app.draft.headers.filter { $0.isEnabled && !$0.key.isEmpty }.count
            return n > 0 ? "\(title) (\(n))" : title
        case .body:
            return app.draft.bodyKind != .none ? "\(title) •" : title
        case .auth:
            guard app.draft.auth.kind != .none else { return title }
            return authIsConfigured ? "\(title) •" : "\(title) !"
        case .cookies:
            return app.hasManualCookies ? "\(title) •" : title
        }
    }

    @ViewBuilder
    private func content(previewURL: String, preview: AppState.PreparedRequest) -> some View {
        @Bindable var app = app
        switch app.requestSection {
        case .params:
            ParamsPane(
                queryParams: $app.draft.queryParams,
                pathParams: $app.draft.pathParams,
                previewURL: previewURL,
                missingPathParams: Set(preview.unresolvedPathParams),
                resolvedPathParams: preview.pathParameterNames
            )
        case .headers:
            KeyValueEditor(
                items: $app.draft.headers,
                keyPlaceholder: app.t(.headerKeyPlaceholder),
                valuePlaceholder: app.t(.headerValuePlaceholder),
                variableTable: .headers
            )
        case .body:
            BodyEditor(draft: $app.draft, resolvedBodyText: preview.request.bodyText)
        case .auth:
            AuthPane(l10n: app.t, auth: $app.draft.auth, resolvedAuth: preview.request.auth)
                .id(app.activeTabID)
        case .cookies:
            CookiePane(l10n: app.t, cookies: $app.draft.cookies)
                .id(app.activeTabID)
        }
    }

    // MARK: - 保存弹窗

    private var saveSheet: some View {
        @Bindable var app = app
        return VStack(alignment: .leading, spacing: 14) {
            Text(app.t(.saveRequestTitle)).font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text(app.t(.nameLabel)).font(.system(size: 11)).foregroundStyle(.secondary)
                TextField(app.t(.requestNamePlaceholder), text: $app.saveSheetName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 340)
                    .onSubmit { app.commitSaveSheet() }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(app.t(.saveToProjectLabel)).font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("", selection: $app.saveSheetProjectID) {
                    ForEach(app.projects) { project in
                        Text(project.name).tag(UUID?.some(project.id))
                    }
                }
                .labelsHidden()
                .frame(width: 340)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(app.t(.folderLabel)).font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("", selection: $app.saveSheetFolderID) {
                    Text(app.t(.projectRootOption)).tag(UUID?.none)
                    ForEach(app.saveSheetFolderOptions, id: \.id) { option in
                        Text(option.path).tag(UUID?.some(option.id))
                    }
                }
                .labelsHidden()
                .frame(width: 340)
            }

            HStack {
                Spacer()
                Button(app.t(.cancelButton)) { app.cancelSaveSheet() }
                Button(app.t(.saveButton)) { app.commitSaveSheet() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(app.saveSheetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }
}

// MARK: - Params 面板

private struct ParamsPane: View {
    @Environment(AppState.self) private var app
    @Binding var queryParams: [KeyValueItem]
    @Binding var pathParams: [KeyValueItem]
    let previewURL: String
    let missingPathParams: Set<String>
    let resolvedPathParams: Set<String>

    var body: some View {
        VStack(spacing: 0) {
            let activeNames = resolvedPathParams.union(PathParams.placeholders(in: app.draft.url))
            if !pathParams.filter({ activeNames.contains($0.key) }).isEmpty {
                PathParamEditor(items: $pathParams, activeNames: activeNames, missingNames: missingPathParams)
                Divider()
            }
            KeyValueEditor(
                items: $queryParams,
                keyPlaceholder: app.t(.paramsKeyPlaceholder),
                valuePlaceholder: app.t(.paramsValuePlaceholder),
                variableTable: .query
            )
            if !previewURL.isEmpty {
                Divider()
                HStack(alignment: .top, spacing: 8) {
                    Text(app.t(.finalURLLabel))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(previewURL)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(3)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }
}

// MARK: - Body 面板

private struct BodyEditor: View {
    @Environment(AppState.self) private var app
    @Binding var draft: APIRequest
    let resolvedBodyText: String

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
    }

    private var toolbar: some View {
        let controls = bodyControls
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                bodyKindPicker
                Spacer(minLength: 0)
                controls
            }
            VStack(alignment: .leading, spacing: 6) {
                bodyKindPicker
                controls
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var bodyKindPicker: some View {
        Picker(app.t(.requestBodyTypeLabel), selection: $draft.bodyKind) {
            ForEach(BodyKind.allCases) { kind in
                Text(kind.displayName(app.t)).tag(kind)
            }
        }
        .labelsHidden()
        .frame(width: 210)
    }

    @ViewBuilder
    private var bodyControls: some View {
        switch draft.bodyKind {
        case .json:
            jsonControls
        case .rawText, .binary:
            let field: RequestVariableField = draft.bodyKind == .binary ? .binaryContentType : .rawContentType
            TextField("Content-Type", text: draft.bodyKind == .binary ? $draft.binaryContentType : $draft.rawContentType)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 200)
                .requestVariableField(field)
        default:
            EmptyView()
        }
    }

    private var jsonControls: some View {
        let text = draft.bodyText
        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let canFormat = JSONTools.isValid(text)
        let changedAfterResolution = text != resolvedBodyText
        let isValid = changedAfterResolution ? JSONTools.isValid(resolvedBodyText) : canFormat
        let message: L10nKey
        if isEmpty {
            message = .emptyJSONBody
        } else if changedAfterResolution {
            message = isValid ? .validResolvedJSON : .invalidResolvedJSON
        } else {
            message = isValid ? .validJSON : .invalidJSON
        }
        let icon: AppIcon = isEmpty ? .file : (isValid ? .completed : .warning)
        let tint: Color = isEmpty ? .secondary : statusTint(for: isValid ? 200 : 400)
        let status = Label(app.t(message), icon: icon)
            .font(.system(size: 11))
            .foregroundStyle(tint)
            .help(app.t(canFormat ? message : .formatRequiresValidDraftJSON))
        let actions = HStack(spacing: 8) {
            Button(app.t(.formatButton)) {
                if let pretty = JSONTools.pretty(draft.bodyText) { draft.bodyText = pretty }
            }
            Button(app.t(.minifyButton)) {
                if let minified = JSONTools.minify(draft.bodyText) { draft.bodyText = minified }
            }
        }
        .disabled(!canFormat)
        .fixedSize()

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                status.fixedSize()
                actions
            }
            VStack(alignment: .leading, spacing: 5) {
                status
                actions
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch draft.bodyKind {
        case .none:
            emptyHint(app.t(.emptyBodyHint))
        case .json, .rawText:
            // 仅 JSON 模式着色：Raw Text 是任意文本，套 JSON 规则会误染。
            CodeTextView(text: $draft.bodyText, highlightJSON: draft.bodyKind == .json)
                .requestVariableField(.body)
        case .binary:
            BinaryBodyEditor(draft: $draft)
        case .formURLEncoded, .multipart:
            VStack(spacing: 0) {
                if draft.bodyKind == .multipart {
                    HStack(spacing: 6) {
                        Image(icon: .info)
                        Text(app.t(.multipartHint))
                        Spacer()
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    Divider()
                }
                KeyValueEditor(
                    items: $draft.formFields,
                    keyPlaceholder: app.t(.formFieldKeyPlaceholder),
                    valuePlaceholder: app.t(.formFieldValuePlaceholder),
                    variableTable: .form
                )
                .frame(maxHeight: draft.bodyKind == .multipart ? 220 : nil)
                if draft.bodyKind == .multipart {
                    Divider()
                    HStack(spacing: 6) {
                        Text(app.t(.multipartFilesHeader))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    Divider()
                    FileFieldEditor(items: $draft.fileFields)
                        .frame(maxHeight: 220)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func emptyHint(_ text: String) -> some View {
        VStack {
            Spacer()
            Label(text, icon: .file)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
