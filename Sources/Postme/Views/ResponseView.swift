import SwiftUI
import AppKit

/// 响应区：状态栏 + Body / 大模型输出 / 事件 / Headers / 耗时 分页。
struct ResponseView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        return Group {
            if let response = displayResponse {
                loaded(response)
            } else if showsStreamPane {
                loaded(nil)
            } else if app.isSending {
                centered {
                    ProgressView(app.t(.sendingProgress)).controlSize(.small)
                }
            } else if let error = app.errorMessage {
                errorState(error)
            } else if app.activeTab.agentRunCancelled {
                ResponsePlaceholder(
                    icon: .cancelled,
                    title: app.t(.responseCancelledTitle),
                    hint: app.t(.responseCancelledHint)
                )
            } else {
                responseEmptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $app.showSaveExampleSheet) {
            SaveExampleSheet()
                .environment(app)
        }
        .sheet(item: $app.viewingExample) { example in
            ExampleViewerSheet(example: example)
                .environment(app)
        }
    }

    /// 该展示的已完成响应。
    ///
    /// 流在接收、被取消或中断时本次流**没有**终态响应：此时若继续展示 `app.response`，
    /// 上一条请求的状态码/正文会冒充成这次流的结果，与下方新流的事件同屏矛盾
    /// （审查 B1）。所以这些状态下一律返回 nil，由 `showsStreamPane` 走流式分支。
    private var displayResponse: APIResponse? {
        let stream = app.activeTab.stream
        if stream.isEventStream {
            switch stream.status {
            case .streaming, .cancelled, .failed:
                return nil
            case .idle, .closed:
                break
            }
        }
        return app.response
    }

    /// SSE 响应头到达即可打开事件页，终态保留已经收到的内容。
    private var showsStreamPane: Bool {
        let stream = app.activeTab.stream
        return stream.isEventStream &&
            (stream.status == .streaming || !stream.events.isEmpty || stream.receivedBytes > 0)
    }

    // MARK: - 已加载

    /// `response == nil` 表示「流式进行中，还没有终态」。
    private func loaded(_ response: APIResponse?) -> some View {
        VStack(spacing: 0) {
            responseHeader(response)
            Divider()

            switch app.responseSection {
            case .body:
                ResponseBodyPane(
                    response: response,
                    displayText: response == nil ? app.activeTab.stream.rawText : app.responseBodyText
                )
            case .llm:
                LLMOutputPane()
            case .events:
                EventsPane()
            case .headers:
                if let response {
                    headersPane(response)
                } else {
                    streamDetailPlaceholder(icon: .formattedResponse, pending: .responseHeadersPending)
                }
            case .timing:
                if let response {
                    timingPane(response)
                } else {
                    streamDetailPlaceholder(icon: .duration, pending: .responseTimingPending)
                }
            }
        }
    }

    private func streamDetailPlaceholder(icon: AppIcon, pending: L10nKey) -> some View {
        let waiting = app.activeTab.stream.status == .streaming
        return ResponsePlaceholder(
            icon: icon,
            title: app.t(waiting ? .responseDetailsWaiting : .responseDetailsUnavailable),
            hint: app.t(waiting ? pending : .responseDetailsInterrupted)
        )
    }

    private var responseSectionPicker: some View {
        @Bindable var app = app
        return Picker(app.t(.responseSectionPickerLabel), selection: $app.responseSection) {
            ForEach(app.availableResponseSections) { tab in
                Text(tab.title(app.t)).tag(tab)
            }
        }
        .labelsHidden()
    }

    private func responseHeader(_ response: APIResponse?) -> some View {
        let stream = app.activeTab.stream
        let presentation = ResponseStatusPresenter.present(
            stream: stream,
            response: response,
            isSending: app.isSending,
            l10n: app.t
        )
        return VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    responseMetrics(presentation, stream: stream, statusCode: response?.statusCode)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    responseSectionPicker.pickerStyle(.segmented).fixedSize()
                }

                VStack(alignment: .leading, spacing: 7) {
                    responseMetrics(presentation, stream: stream, statusCode: response?.statusCode)
                    ViewThatFits(in: .horizontal) {
                        responseSectionPicker.pickerStyle(.segmented).fixedSize()
                        responseSectionPicker.pickerStyle(.menu).fixedSize()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if let hint = app.responseChangeHint {
                Label(app.t(hint), icon: .info)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }

            // 失败原因必须在界面上读得到（tooltip 不算）：流式中断后事件区仍保留，
            // 但「为什么断」只有这一行能说清。
            if let failure = presentation.failureMessage {
                HStack(spacing: 6) {
                    Image(icon: .failure)
                        .font(.system(size: 10))
                    Text(failure)
                        .font(.system(size: 11))
                        .textSelection(.enabled)
                        .lineLimit(2)
                    Spacer()
                }
                .foregroundStyle(statusTint(for: 500))
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
        }
    }

    private func responseMetrics(
        _ presentation: ResponseStatusPresentation,
        stream: StreamState,
        statusCode: Int?
    ) -> some View {
        HStack(spacing: 8) {
            if let badge = presentation.badgeText, let detail = presentation.badgeDetail {
                Badge(text: badge, tint: statusTint(for: statusCode ?? 0))
                Text(detail)
                    .font(.system(size: 12, weight: .semibold))
            } else if let badge = presentation.badgeText {
                // 「接收中」这类非状态码徽标。
                Badge(text: badge, tint: .accentColor)
            }

            if let label = presentation.streamStatus, label != presentation.badgeText {
                if presentation.badgeText != nil { Divider().frame(height: 12) }
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(streamStatusTint(stream))
            }

            if let count = presentation.eventCountText {
                Text(count)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Divider().frame(height: 12)

            if presentation.showsLiveDuration {
                // 实时耗时：用 TimelineView 自己走，不往 AppState 写 tick
                // （否则每 0.1 秒一次状态变更会把整棵响应区重建）。只在真正
                // 流式接收期间出现——取消/中断后用本次流的实际时长（endedAt - startedAt）。
                TimelineView(.periodic(from: stream.startedAt, by: 0.1)) { context in
                    Label(
                        formatMillis(context.date.timeIntervalSince(stream.startedAt)),
                        icon: .duration
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
                }
            } else if let duration = presentation.durationText {
                Label(duration, icon: .duration)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
            }

            if let bytes = presentation.receivedBytesText {
                Label(bytes, icon: .responseSize)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
            }

            if presentation.isReceiving, !presentation.showsLiveDuration {
                Label(app.t(.streamStatusStreaming), icon: .receiving)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }

    private func streamStatusTint(_ stream: StreamState) -> Color {
        switch stream.status {
        case .streaming: return .accentColor
        case .closed: return statusTint(for: 200)
        case .cancelled: return .secondary
        case .failed: return statusTint(for: 500)
        case .idle: return .secondary
        }
    }

    // MARK: - Headers

    private func headersPane(_ response: APIResponse) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(app.t(.responseHeadersCount, response.headers.count))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                CopyButton(title: app.t(.copyAllButton)) {
                    response.headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
                }
                .labelStyle(.titleOnly)
                .id(response.receivedAt)
                .font(.system(size: 11))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(response.headers) { header in
                        HStack(alignment: .top, spacing: 8) {
                            Text(header.name)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 200, alignment: .leading)
                            Text(header.value)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)

                        Divider()
                    }
                }
            }
        }
    }

    // MARK: - 耗时

    private func timingPane(_ response: APIResponse) -> some View {
        let timing = response.timing
        let rows: [(String, TimeInterval?)] = [
            (app.t(.timingDNS), timing.dns),
            (app.t(.timingTCP), timing.tcp),
            (app.t(.timingTLS), timing.tls),
            (app.t(.timingTTFB), timing.ttfb),
            (app.t(.timingTransfer), timing.transfer),
            (app.t(.timingTotal), timing.total)
        ]
        let maxValue = max(timing.total, rows.compactMap { $0.1 }.max() ?? 0, 0.0001)

        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(rows, id: \.0) { label, value in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(label).font(.system(size: 12))
                            Spacer()
                            Text(formatMillis(value))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.secondary.opacity(0.12))
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.accentColor.opacity(label == app.t(.timingTotal) ? 0.9 : 0.55))
                                    .frame(width: max(2, geo.size.width * CGFloat((value ?? 0) / maxValue)))
                            }
                        }
                        .frame(height: 8)
                    }
                }

                Text(app.t(.timingNote))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .padding(14)
        }
    }

    // MARK: - 空态 / 错误态

    private var responseEmptyState: some View {
        let needsURL = app.draft.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return centered {
            VStack(spacing: 13) {
                responseEmptyArtwork
                VStack(spacing: 5) {
                    Text(app.t(.responseEmptyTitle))
                        .font(.system(size: 15, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(app.t(needsURL ? .responseEmptyURLHint : .responseEmptyHint))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            }
            .padding(.horizontal, 24)
        }
    }

    private var responseEmptyArtwork: some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(BrandColor.icon.opacity(0.09))
            .frame(width: 96, height: 72)
            .overlay(alignment: .bottomLeading) {
                let window = RoundedRectangle(cornerRadius: 8)
                window
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay { window.strokeBorder(BrandColor.icon.opacity(0.28)) }
                    .overlay(alignment: .leading) {
                        Image(icon: .code)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(BrandColor.icon)
                            .padding(.leading, 9)
                    }
                    .frame(width: 56, height: 37)
                    .padding(.leading, 13)
                    .padding(.bottom, 12)
            }
            .overlay(alignment: .topTrailing) {
                SendGlyph()
                    .fill(.linearGradient(
                        colors: [Color(red: 1, green: 0.70, blue: 0.45), BrandColor.icon],
                        startPoint: .topTrailing,
                        endPoint: .bottomLeading
                    ))
                    .frame(width: 40, height: 40)
                    .padding(.top, 8)
                    .padding(.trailing, 11)
            }
            .accessibilityHidden(true)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(icon: .failure)
                .font(.system(size: 28))
                .foregroundStyle(Color(red: 0.85, green: 0.35, blue: 0.15))
            Text(app.t(.requestFailedTitle))
                .font(.headline)
            Text(message)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .padding(.horizontal, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack {
            Spacer()
            content()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 响应体面板

private struct ResponseBodyPane: View {
    @Environment(AppState.self) private var app
    /// `nil` 表示流式在途（还没有终态响应），此时只展示已收到的原始文本。
    let response: APIResponse?
    let displayText: String

    /// 响应体的两种看法：格式化（JSON 为树形）与压缩文本。
    private enum BodyMode: Hashable {
        case formatted, minified
    }

    @State private var mode: BodyMode = .formatted

    // 树形数据按需解析（格式化分页首次出现时做一次），避免每次响应都多建一棵树。
    @State private var treeRoot: JSONValue?
    @State private var treeCollapsed: Set<String> = []
    @State private var treeFailed = false
    /// 已解析的文本，用来判断是否需要重建树。
    @State private var treeSource: String?

    /// 查找条触发序号（工具栏按钮与 ⌥⌘F 共用）。
    @State private var findRequest = 0
    /// 已处理的菜单触发序号。视图重新出现时要补处理一次，
    /// 否则在「Headers」分页按 ⌥⌘F 会只切回 Body、不弹查找条。
    @State private var handledMenuFindTick = 0

    var body: some View {
        VStack(spacing: 0) {
            if !isBodyEmpty || app.canSaveResponseExample || !app.examplesForActiveTab.isEmpty {
                toolbar
                Divider()
            }

            if isBodyEmpty {
                let waiting = response == nil && app.activeTab.stream.status == .streaming
                ResponsePlaceholder(icon: .file, title: app.t(waiting ? .responseBodyWaiting : .responseBodyEmpty))
            } else if isTreeDisplayed, let treeRoot {
                JSONTreeView(root: treeRoot, collapsed: $treeCollapsed, l10n: app.t)
            } else {
                if showsTreeFallbackBanner {
                    treeFallbackBanner
                    Divider()
                }
                CodeTextView(
                    text: .constant(currentText),
                    isEditable: false,
                    highlightJSON: response?.looksLikeJSON ?? false,
                    findRequest: findRequest
                )
            }
        }
        .onAppear {
            syncMenuFind()
            if effectiveMode == .formatted { ensureTreeLoaded() }
        }
        .onChange(of: app.responseFindTick) { _, _ in syncMenuFind() }
        .onChange(of: displayText) { _, _ in
            resetTree()
            if effectiveMode == .formatted { ensureTreeLoaded() }
        }
        .onChange(of: mode) { _, newMode in
            if newMode == .formatted { ensureTreeLoaded() }
        }
    }

    private var isBodyEmpty: Bool {
        if let response { return response.body.isEmpty && !response.isBodyTruncated }
        return displayText.isEmpty
    }

    private func syncMenuFind() {
        guard app.responseFindTick != handledMenuFindTick else { return }
        handledMenuFindTick = app.responseFindTick
        triggerFind()
    }

    private func triggerFind() {
        guard !currentText.isEmpty else { return }
        // 树形视图里没有 NSTextView；切到文本分页（压缩）再触发查找。
        if isTreeDisplayed { mode = .minified }
        findRequest += 1
    }

    /// 非 JSON 响应没有树形可选，即使 `mode` 残留为 `.formatted` 也按文本展示。
    private var effectiveMode: BodyMode {
        guard response?.looksLikeJSON == true else { return .formatted }
        return mode
    }

    /// 当前是否真的在显示树（JSON + 解析成功 + 停在格式化分页）。
    private var isTreeDisplayed: Bool {
        !isBodyEmpty && effectiveMode == .formatted && response?.looksLikeJSON == true && treeRoot != nil && !treeFailed
    }

    /// JSON 但树解析失败（截断 / 语法不完整）：回落到文本并说明原因。
    private var showsTreeFallbackBanner: Bool {
        effectiveMode == .formatted && response?.looksLikeJSON == true && treeFailed
    }

    private var currentText: String {
        if effectiveMode == .minified, let compact = JSONTools.minify(displayText) {
            return compact
        }
        return displayText
    }

    // MARK: - 树形

    private var treeFallbackBanner: some View {
        HStack(spacing: 6) {
            Image(icon: .warning)
            Text(app.t(.jsonTreeUnavailable))
                .lineLimit(2)
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func resetTree() {
        treeSource = nil
        treeRoot = nil
        treeCollapsed = []
        treeFailed = false
    }

    private func ensureTreeLoaded() {
        // 非 JSON 响应不建树：既省一次全文扫描，也避免把大段 HTML 当 JSON 解析。
        guard !isBodyEmpty, response?.looksLikeJSON == true else { return }
        let source = treeSourceText
        guard treeSource != source else { return }
        treeSource = source
        if let root = JSONTree.parse(source) {
            treeRoot = root
            treeCollapsed = JSONTree.defaultCollapsed(root)
            treeFailed = false
        } else {
            treeRoot = nil
            treeCollapsed = []
            treeFailed = true
        }
    }

    /// 建树用哪份文本。
    ///
    /// **优先用原始响应**：`displayBodyText` 会走 `JSONSerialization` 美化，
    /// 那一步不保证键顺序；树形既然承担「看结构」的职责，就应该按原文顺序。
    /// 超过展示上限或传输层已截断时退回 `displayText`（带截断说明），
    /// 解析必然失败，于是走「树不可用」的文本回落，而不是假装完整。
    private var treeSourceText: String {
        guard let response,
              !response.isBodyTruncated,
              let raw = response.textBody,
              raw.utf8.count <= APIResponse.displayTruncationThreshold else {
            return displayText
        }
        return raw
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    bodyModePicker
                    treeActions
                    Spacer(minLength: 0)
                    if !isBodyEmpty { findButton }
                    saveExampleButton
                    examplesMenu
                    if !isBodyEmpty { copyButton }
                }

                HStack(spacing: 10) {
                    bodyModePicker
                    Spacer(minLength: 0)
                    if !isBodyEmpty {
                        findButton
                        copyButton
                    }
                    Menu {
                        treeActions
                        if isTreeDisplayed { Divider() }
                        saveExampleButton
                        examplesMenu
                    } label: {
                        Image(icon: .more)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(app.t(.responseMoreActions))
                    .accessibilityLabel(app.t(.responseMoreActions))
                }
            }

            if let response, response.isBodyTruncated {
                Label(app.t(.bodyTruncatedByLimit), icon: .warning)
                    .foregroundStyle(statusTint(for: 500))
            } else if let response, response.bodySize > APIResponse.displayTruncationThreshold {
                Label(app.t(.bodyTruncatedForDisplay), icon: .truncated)
                    .foregroundStyle(statusTint(for: 400))
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var bodyModePicker: some View {
        if !isBodyEmpty, response?.looksLikeJSON == true {
            Picker("", selection: $mode) {
                Text(app.t(.formatButton)).tag(BodyMode.formatted)
                Text(app.t(.minifyButton)).tag(BodyMode.minified)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    @ViewBuilder
    private var treeActions: some View {
        if isTreeDisplayed, let treeRoot {
            Button(app.t(.jsonTreeExpandAll)) { treeCollapsed = [] }
                .fixedSize()
            Button(app.t(.jsonTreeCollapseAll)) { treeCollapsed = JSONTree.allContainerPaths(treeRoot) }
                .fixedSize()
        }
    }

    private var findButton: some View {
        Button { triggerFind() } label: {
            Image(icon: .search)
                .frame(width: 18, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(currentText.isEmpty)
        .help(app.t(.findInResponseHelp))
        .accessibilityLabel(app.t(.findInResponseHelp))
    }

    private var saveExampleButton: some View {
        Button {
            app.beginSaveResponseExample()
        } label: {
            Label(app.t(.saveAsExampleButton), icon: .bookmark)
        }
        .fixedSize()
        .disabled(!app.canSaveResponseExample)
        .help(app.canSaveResponseExample ? app.t(.saveAsExampleHelp) : app.t(.saveAsExampleNeedsSavedRequest))
    }

    @ViewBuilder
    private var examplesMenu: some View {
        if !app.examplesForActiveTab.isEmpty {
            Menu {
                ForEach(app.examplesForActiveTab) { example in
                    Button(example.name) { app.viewingExample = example }
                }
            } label: {
                Label("\(app.t(.examplesMenu)) (\(app.examplesForActiveTab.count))",
                      icon: .formattedResponse)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var copyButton: some View {
        CopyButton(title: app.t(.copyButton)) { currentText }
        .fixedSize()
        .id(response?.receivedAt)
    }
}
