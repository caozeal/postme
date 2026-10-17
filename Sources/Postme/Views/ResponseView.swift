import SwiftUI
import AppKit

/// 响应区：状态栏 + Body / Headers / 耗时 分页。
struct ResponseView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Group {
            if app.isSending {
                centered {
                    ProgressView(app.t(.sendingProgress)).controlSize(.small)
                }
            } else if let error = app.errorMessage {
                errorState(error)
            } else if let response = app.response {
                loaded(response)
            } else {
                centered {
                    Text(app.t(.responseEmptyHint))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 已加载

    private func loaded(_ response: APIResponse) -> some View {
        @Bindable var app = app
        return VStack(spacing: 0) {
            statusBar(response)
            Divider()
            HStack(spacing: 10) {
                Picker("", selection: $app.responseTab) {
                    ForEach(ResponseTab.allCases) { tab in
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

            switch app.responseTab {
            case .body:
                ResponseBodyPane(response: response, displayText: app.responseBodyText)
            case .headers:
                headersPane(response)
            case .timing:
                timingPane(response)
            }
        }
    }

    private func statusBar(_ response: APIResponse) -> some View {
        HStack(spacing: 10) {
            Badge(text: "\(response.statusCode)", tint: statusTint(for: response.statusCode))
            Text(response.statusText)
                .font(.system(size: 12, weight: .semibold))

            Divider().frame(height: 12)

            Label(formatMillis(response.timing.total), systemImage: "clock")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Label(formatBytes(response.bodySize), systemImage: "arrow.down.doc")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
    let response: APIResponse
    let displayText: String

    @State private var minified = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            CodeTextView(
                text: .constant(currentText),
                isEditable: false,
                highlightJSON: response.looksLikeJSON
            )
        }
    }

    private var currentText: String {
        if minified, let compact = JSONTools.minify(displayText) {
            return compact
        }
        return displayText
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            if response.looksLikeJSON {
                Picker("", selection: $minified) {
                    Text(app.t(.formatButton)).tag(false)
                    Text(app.t(.minifyButton)).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            if response.isBodyTruncated {
                Label(app.t(.bodyTruncatedByLimit), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            } else if response.bodySize > APIResponse.displayTruncationThreshold {
                Label(app.t(.bodyTruncatedForDisplay), systemImage: "scissors")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            Spacer()

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
