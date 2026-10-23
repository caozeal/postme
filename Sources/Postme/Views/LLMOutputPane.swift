import SwiftUI

/// 「大模型输出」分页：把选定字段的增量拼成一段连续文本，其余字段折叠可查。
///
/// 只读、不做二次拼接：主区域直接渲染 `LLMFieldAccumulator.text`（归并器已经在累积时
/// 做过拼接与上限控制），视图层不再复制一份字符串。
struct LLMOutputPane: View {
    @Environment(AppState.self) private var app

    @State private var isCustomPathSheetPresented = false
    @State private var customPathInput = ""
    @State private var customPathError: String?

    private var llm: LLMStreamState { app.activeTab.stream.llm }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if llm.fields.isEmpty {
                emptyState
            } else {
                joinedArea
                if !otherFields.isEmpty {
                    Divider()
                    otherFieldsArea
                }
            }

            if let error = llm.lastError {
                Divider()
                streamErrorBanner(error)
            }
        }
        .sheet(isPresented: $isCustomPathSheetPresented) {
            customPathSheet
        }
    }

    /// 除当前选中字段之外的字段（折叠区内容）。
    private var otherFields: [LLMFieldAccumulator] {
        llm.fields.filter { $0.path != llm.selectedPath }
    }

    // MARK: - 工具栏

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(app.t(.llmFieldLabel))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            // 选择写回 `AppState.selectLLMField`：选择跟随页签，且不被自动选择覆盖。
            Picker("", selection: fieldSelection) {
                if let selected = llm.selectedPath, llm.selectedField == nil {
                    // 先选了尚未产出的自定义路径：占位一项，否则 Picker 选不中任何值。
                    Text(selected).tag(Optional(selected))
                }
                ForEach(llm.fields) { field in
                    Text(field.displayName).tag(Optional(field.path))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .help(app.t(.llmFieldPickerHelp))

            if let selected = llm.selectedField {
                Text(app.t(.llmPieceSummary, selected.pieceCount, formatBytes(selected.text.utf8.count)))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if llm.droppedFieldCount > 0 {
                Label(
                    app.t(.llmFieldsDropped, llm.droppedFieldCount),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            }

            Spacer()

            Text(formatLabel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Button(app.t(.llmCustomPathButton)) {
                customPathInput = ""
                customPathError = nil
                isCustomPathSheetPresented = true
            }
            .font(.system(size: 11))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var fieldSelection: Binding<String?> {
        Binding(
            get: { app.activeTab.stream.llm.selectedPath },
            set: { app.selectLLMField($0) }
        )
    }

    private var formatLabel: String {
        switch llm.format {
        case .openAI: return app.t(.llmFormatOpenAI)
        case .anthropic: return app.t(.llmFormatAnthropic)
        case .langGraph: return app.t(.llmFormatLangGraph)
        case .customOnly: return app.t(.llmFormatCustom)
        case .unknown: return app.t(.llmFormatUnknown)
        }
    }

    // MARK: - 主区域

    @ViewBuilder
    private var joinedArea: some View {
        if let selected = llm.selectedField {
            VStack(spacing: 0) {
                if selected.isTruncated {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                        Text(app.t(.llmFieldTruncated, formatBytes(LLMStreamMerger.maxFieldBytes)))
                            .font(.system(size: 11))
                        Spacer()
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    Divider()
                }
                // 只读、可选中、等宽，与 ResponseBodyPane 一致。
                CodeTextView(text: .constant(selected.text), isEditable: false)
            }
        } else {
            VStack {
                Spacer()
                Text(app.t(.llmSelectFieldHint))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 其他字段（折叠）

    private var otherFieldsArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(app.t(.llmOtherFieldsHeader))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(otherFields) { field in
                        DisclosureGroup {
                            CodeTextView(text: .constant(field.text), isEditable: false)
                                .frame(minHeight: 80)
                        } label: {
                            HStack(spacing: 6) {
                                Text(field.displayName)
                                    .font(.system(size: 11, design: .monospaced))
                                Spacer()
                                Text(app.t(.llmPieceSummary, field.pieceCount, formatBytes(field.text.utf8.count)))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                if field.isTruncated {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }
                }
            }
            .frame(maxHeight: 160)
        }
    }

    // MARK: - 空态与错误

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text(app.t(.llmNoJoinableFields, llm.parsedEventCount, llm.unparsedEventCount))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(app.t(.llmCustomPathButton)) {
                customPathInput = ""
                customPathError = nil
                isCustomPathSheetPresented = true
            }
            .font(.system(size: 11))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    private func streamErrorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(app.t(.llmErrorFromStream, message))
                .font(.system(size: 11))
                .textSelection(.enabled)
                .lineLimit(2)
            Spacer()
        }
        .foregroundStyle(Color(red: 0.85, green: 0.25, blue: 0.25))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - 自定义路径 sheet

    private var customPathSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(app.t(.llmCustomPathTitle))
                .font(.headline)

            HStack(spacing: 8) {
                TextField(app.t(.llmCustomPathPlaceholder), text: $customPathInput)
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submitCustomPath() }
                Button(app.t(.settingsLLMPathsAdd)) { submitCustomPath() }
            }

            if let customPathError {
                Text(customPathError)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.85, green: 0.25, blue: 0.25))
            } else {
                Text(app.t(.llmCustomPathHelp))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if !app.workspace.settings.llmFieldPaths.isEmpty {
                Divider()
                // 已加载的自定义路径逐条列出并带删除：加错了能当场删，不必去设置页。
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(app.workspace.settings.llmFieldPaths, id: \.self) { path in
                            HStack {
                                Text(path)
                                    .font(.system(size: 11, design: .monospaced))
                                Spacer()
                                Button {
                                    app.removeLLMCustomPath(path)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10))
                                }
                                .buttonStyle(.borderless)
                                .help(app.t(.llmCustomPathRemoveHelp))
                            }
                        }
                    }
                }
                .frame(maxHeight: 140)
            }

            HStack {
                Spacer()
                Button(app.t(.doneButton)) { isCustomPathSheetPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    /// 提交自定义路径：校验 → 写入设置并立即选中。非法路径留在 sheet 里报错。
    private func submitCustomPath() {
        let trimmed = customPathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard LLMStreamMerger.canonicalPath(trimmed) != nil else {
            customPathError = app.t(.llmCustomPathInvalid)
            return
        }
        guard app.addLLMCustomPath(trimmed) else {
            customPathError = app.t(.llmCustomPathLimit, LLMStreamMerger.maxCustomPaths)
            return
        }
        // 新加的自定义路径立即成为主区域字段：用户加它就是为了看它。
        if let canonical = LLMStreamMerger.canonicalPath(trimmed) {
            app.selectLLMField(canonical)
        }
        customPathError = nil
        customPathInput = ""
        isCustomPathSheetPresented = false
    }
}
