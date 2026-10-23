import SwiftUI
import AppKit

/// 响应区：状态栏 + Body / 大模型输出 / 事件 / Headers / 耗时 分页。
struct ResponseView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        return Group {
            // 流式期间有内容就显示内容：只有「连响应头都还没到」才显示进度圈。
            if app.isSending, displayResponse == nil, !hasStreamContent {
                centered {
                    ProgressView(app.t(.sendingProgress)).controlSize(.small)
                }
            } else if let error = app.errorMessage, displayResponse == nil, !hasStreamContent {
                errorState(error)
            } else if let response = displayResponse {
                loaded(response)
            } else if hasStreamContent {
                loaded(nil)
            } else {
                centered {
                    Text(app.t(.responseEmptyHint))
                        .foregroundStyle(.secondary)
                }
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
    /// 流被取消或中断时本次流**没有**终态响应：此时若继续展示 `app.response`，
    /// 上一条请求的状态码/正文会冒充成这次流的结果，与下方新流的事件同屏矛盾
    /// （审查 B1）。所以这两种终态下一律返回 nil，由 `hasStreamContent` 走流式分支。
    private var displayResponse: APIResponse? {
        let stream = app.activeTab.stream
        if stream.isEventStream {
            switch stream.status {
            case .cancelled, .failed:
                return nil
            case .idle, .streaming, .closed:
                break
            }
        }
        return app.response
    }

    /// 流式状态里是否已经有可展示的东西（事件或字节）。
    private var hasStreamContent: Bool {
        let stream = app.activeTab.stream
        return stream.isEventStream && (!stream.events.isEmpty || stream.receivedBytes > 0)
    }

    // MARK: - 已加载

    /// `response == nil` 表示「流式进行中，还没有终态」。
    private func loaded(_ response: APIResponse?) -> some View {
        @Bindable var app = app
        return VStack(spacing: 0) {
            statusBar(response)
            Divider()
            HStack(spacing: 10) {
                Picker("", selection: $app.responseSection) {
                    ForEach(app.availableResponseSections) { tab in
                        Text(tab.title(app.t)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            switch app.responseSection {
            case .body:
                if let response {
                    ResponseBodyPane(response: response, displayText: app.responseBodyText)
                } else {
                    // 流式在途：Body 分页展示已收到的原始文本。
                    ResponseBodyPane(
                        response: nil,
                        displayText: app.activeTab.stream.rawText
                    )
                }
            case .llm:
                LLMOutputPane()
            case .events:
                EventsPane()
            case .headers:
                if let response {
                    headersPane(response)
                } else {
                    emptyPane
                }
            case .timing:
                if let response {
                    timingPane(response)
                } else {
                    emptyPane
                }
            }
        }
    }

    private var emptyPane: some View {
        VStack {
            Spacer()
            Text(app.t(.responseEmptyHint))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusBar(_ response: APIResponse?) -> some View {
        let stream = app.activeTab.stream
        let presentation = ResponseStatusPresenter.present(
            stream: stream,
            response: response,
            isSending: app.isSending,
            l10n: app.t
        )
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let badge = presentation.badgeText, let detail = presentation.badgeDetail {
                    Badge(text: badge, tint: statusTint(for: response?.statusCode ?? 0))
                    Text(detail)
                        .font(.system(size: 12, weight: .semibold))
                } else if let badge = presentation.badgeText {
                    // 「接收中」这类非状态码徽标。
                    Badge(text: badge, tint: .accentColor)
                }

                if let label = presentation.streamStatus, !label.isEmpty {
                    Divider().frame(height: 12)
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
                            systemImage: "clock"
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                } else if let duration = presentation.durationText {
                    Label(duration, systemImage: "clock")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                if let bytes = presentation.receivedBytesText {
                    Label(bytes, systemImage: "arrow.down.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                if presentation.isReceiving, !presentation.showsLiveDuration {
                    Label(app.t(.streamStatusStreaming), systemImage: "arrow.down.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // 失败原因必须在界面上读得到（tooltip 不算）：流式中断后事件区仍保留，
            // 但「为什么断」只有这一行能说清。
            if let failure = presentation.failureMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text(failure)
                        .font(.system(size: 11))
                        .textSelection(.enabled)
                        .lineLimit(2)
                    Spacer()
                }
                .foregroundStyle(Color(red: 0.85, green: 0.25, blue: 0.25))
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
        }
    }

    private func streamStatusTint(_ stream: StreamState) -> Color {
        switch stream.status {
        case .streaming: return .accentColor
        case .closed: return Color(red: 0.16, green: 0.63, blue: 0.32)
        case .cancelled: return .secondary
        case .failed: return Color(red: 0.85, green: 0.25, blue: 0.25)
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
                Button(app.t(.copyAllButton)) {
                    let text = response.headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
                    copyToClipboard(text)
                }
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

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
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
            toolbar
            Divider()
            if isTreeDisplayed, let treeRoot {
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
        effectiveMode == .formatted && response?.looksLikeJSON == true && treeRoot != nil && !treeFailed
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
            Image(systemName: "exclamationmark.triangle")
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
        guard response?.looksLikeJSON == true else { return }
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
        HStack(spacing: 10) {
            if response?.looksLikeJSON == true {
                Picker("", selection: $mode) {
                    Text(app.t(.formatButton)).tag(BodyMode.formatted)
                    Text(app.t(.minifyButton)).tag(BodyMode.minified)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            if isTreeDisplayed, let treeRoot {
                Button(app.t(.jsonTreeExpandAll)) {
                    treeCollapsed = []
                }
                .font(.system(size: 11))

                Button(app.t(.jsonTreeCollapseAll)) {
                    treeCollapsed = JSONTree.allContainerPaths(treeRoot)
                }
                .font(.system(size: 11))
            }

            if let response, response.isBodyTruncated {
                Label(app.t(.bodyTruncatedByLimit), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            } else if let response, response.bodySize > APIResponse.displayTruncationThreshold {
                Label(app.t(.bodyTruncatedForDisplay), systemImage: "scissors")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            Spacer()

            Button {
                triggerFind()
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .font(.system(size: 11))
            .buttonStyle(.borderless)
            .disabled(currentText.isEmpty)
            .help(app.t(.findInResponseHelp))
            .accessibilityLabel(app.t(.findInResponseHelp))

            Button {
                app.beginSaveResponseExample()
            } label: {
                Label(app.t(.saveAsExampleButton), systemImage: "bookmark")
            }
            .font(.system(size: 11))
            .disabled(!app.canSaveResponseExample)
            .help(app.canSaveResponseExample ? app.t(.saveAsExampleHelp) : app.t(.saveAsExampleNeedsSavedRequest))

            if !app.examplesForActiveTab.isEmpty {
                Menu {
                    ForEach(app.examplesForActiveTab) { example in
                        Button(example.name) { app.viewingExample = example }
                    }
                } label: {
                    Label("\(app.t(.examplesMenu)) (\(app.examplesForActiveTab.count))",
                          systemImage: "list.bullet.rectangle")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Button {
                copyToClipboard(currentText)
            } label: {
                Label(app.t(.copyButton), systemImage: "doc.on.doc")
            }
            .font(.system(size: 11))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
