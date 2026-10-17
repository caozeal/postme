import SwiftUI

/// 请求编辑区：方法 + URL + 发送，以及 Params / Headers / Body 分页。
struct RequestEditorView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            requestBar
            Divider()
            if !app.unresolvedVariables.isEmpty {
                unresolvedBanner
                Divider()
            }
            tabBar
            Divider()
            content
        }
        .sheet(isPresented: $app.showSaveSheet) { saveSheet }
        // 草稿编辑即防抖落盘（600ms 合并）。原先草稿只在退出时落盘，
        // 崩溃或强杀就会丢掉整个编辑中的请求。
        .onChange(of: app.draft) { _, _ in
            app.persistDraft()
        }
    }

    /// 上一次发送中存在未解析变量时的提示。
    private var unresolvedBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("以下变量未定义，已按原文发出：")
            Text(app.unresolvedVariables.map { "{{\($0)}}" }.joined(separator: "  "))
                .font(.system(size: 11, design: .monospaced))
            Spacer()
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - 顶部请求栏

    private var requestBar: some View {
        @Bindable var app = app
        return HStack(spacing: 8) {
            methodMenu

            TextField("https://api.example.com/path", text: $app.draft.url)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .onSubmit { Task { await app.send() } }

            saveButton
            sendButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var saveButton: some View {
        Button {
            app.beginSave()
        } label: {
            Label("保存", systemImage: "square.and.arrow.down")
        }
        .help(app.editingNodeID != nil ? "覆盖保存到当前项目 (⌘S)" : "保存到当前项目 (⌘S)")
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
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 84, alignment: .leading)
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
                    Image(systemName: "paperplane.fill")
                }
                Text(app.isSending ? "取消" : "发送")
            }
            .frame(minWidth: 64)
        }
        .buttonStyle(.borderedProminent)
        .tint(app.isSending ? .red : nil)
        .disabled(!app.isSending && app.draft.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .help(app.isSending ? "取消请求 (⌘.)" : "发送请求 (⌘↩)")
    }

    // MARK: - 分页

    private var tabBar: some View {
        @Bindable var app = app
        return HStack(spacing: 10) {
            Picker("", selection: $app.requestTab) {
                ForEach(RequestTab.allCases) { tab in
                    Text(tabLabel(tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func tabLabel(_ tab: RequestTab) -> String {
        switch tab {
        case .params:
            let n = app.draft.queryParams.filter { $0.isEnabled && !$0.key.isEmpty }.count
            return n > 0 ? "Params (\(n))" : "Params"
        case .headers:
            let n = app.draft.headers.filter { $0.isEnabled && !$0.key.isEmpty }.count
            return n > 0 ? "Headers (\(n))" : "Headers"
        case .body:
            return "Body"
        }
    }

    @ViewBuilder
    private var content: some View {
        @Bindable var app = app
        switch app.requestTab {
        case .params:
            ParamsPane(queryParams: $app.draft.queryParams, previewURL: effectiveURLPreview)
        case .headers:
            KeyValueEditor(
                items: $app.draft.headers,
                keyPlaceholder: "Header 名",
                valuePlaceholder: "Header 值"
            )
        case .body:
            BodyEditor(draft: $app.draft)
        }
    }

    /// Params 页脚展示合并后的最终 URL。
    ///
    /// 完整走一遍发送前的处理：**先变量替换**（与 `AppState.resolveDraft` 同源），
    /// 再交给 `RequestExecutor.previewURL` 做 query 合并与编码。
    /// 目标是让这一栏真的等于「将要发出的 URL」——不然它就是在误导人。
    private var effectiveURLPreview: String {
        RequestExecutor.previewURL(app.resolvedDraft)
    }

    // MARK: - 保存弹窗

    private var saveSheet: some View {
        @Bindable var app = app
        return VStack(alignment: .leading, spacing: 14) {
            Text("保存请求").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("名称").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("请求名称", text: $app.saveSheetName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 340)
                    .onSubmit { app.commitSaveSheet() }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("保存到项目").font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("", selection: $app.saveSheetProjectID) {
                    ForEach(app.projects) { project in
                        Text(project.name).tag(UUID?.some(project.id))
                    }
                }
                .labelsHidden()
                .frame(width: 340)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("文件夹").font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("", selection: $app.saveSheetFolderID) {
                    Text("项目根目录").tag(UUID?.none)
                    ForEach(app.saveSheetFolderOptions, id: \.id) { option in
                        Text(option.path).tag(UUID?.some(option.id))
                    }
                }
                .labelsHidden()
                .frame(width: 340)
            }

            HStack {
                Spacer()
                Button("取消") { app.cancelSaveSheet() }
                Button("保存") { app.commitSaveSheet() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(app.saveSheetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }
}

// MARK: - Params 面板

private struct ParamsPane: View {
    @Binding var queryParams: [KeyValueItem]
    let previewURL: String

    var body: some View {
        VStack(spacing: 0) {
            KeyValueEditor(items: $queryParams, keyPlaceholder: "参数名", valuePlaceholder: "参数值")
            if !previewURL.isEmpty {
                Divider()
                HStack(alignment: .top, spacing: 8) {
                    Text("最终 URL")
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
    @Binding var draft: APIRequest

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $draft.bodyKind) {
                ForEach(BodyKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .labelsHidden()
            .frame(width: 210)

            Spacer()

            if draft.bodyKind == .rawText {
                TextField("Content-Type", text: $draft.rawContentType)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 200)
            }

            if draft.bodyKind == .json {
                jsonStatus
                Button("格式化") {
                    if let pretty = JSONTools.pretty(draft.bodyText) { draft.bodyText = pretty }
                }
                .disabled(draft.bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("压缩") {
                    if let minified = JSONTools.minify(draft.bodyText) { draft.bodyText = minified }
                }
                .disabled(draft.bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var jsonStatus: some View {
        let text = draft.bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            if JSONTools.isValid(text) {
                Label("合法 JSON", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.16, green: 0.63, blue: 0.32))
            } else {
                Label("JSON 语法有误", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.85, green: 0.35, blue: 0.15))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch draft.bodyKind {
        case .none:
            emptyHint("该请求不带请求体。")
        case .json, .rawText:
            // 仅 JSON 模式着色：Raw Text 是任意文本，套 JSON 规则会误染。
            CodeTextView(text: $draft.bodyText, highlightJSON: draft.bodyKind == .json)
        case .formURLEncoded, .multipart:
            VStack(spacing: 0) {
                if draft.bodyKind == .multipart {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                        Text("v1 仅支持文本字段，暂不支持文件上传。")
                        Spacer()
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    Divider()
                }
                KeyValueEditor(items: $draft.formFields, keyPlaceholder: "字段名", valuePlaceholder: "字段值")
            }
        }
    }

    private func emptyHint(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
