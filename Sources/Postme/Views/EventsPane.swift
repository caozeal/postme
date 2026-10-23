import SwiftUI
import AppKit

/// SSE 事件列表：每行一条已分帧事件，流式期间自动滚到底部。
///
/// 数据源是当前页签的 `stream`（运行期状态，不落盘）。事件本身已经分好帧，
/// 这里只负责展示——不做任何协议解析。
struct EventsPane: View {
    @Environment(AppState.self) private var app

    @State private var autoScroll = true
    @State private var expanded: Set<UUID> = []

    private var stream: StreamState { app.activeTab.stream }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if stream.events.isEmpty {
                VStack {
                    Spacer()
                    Text(app.t(.streamEmptyHint))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                eventList
            }
        }
    }

    // MARK: - 工具栏

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(app.t(.streamEventCount, stream.events.count))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if stream.droppedEventCount > 0 {
                Label(
                    app.t(.streamEventsDropped, stream.droppedEventCount),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            }

            Spacer()

            Toggle(app.t(.streamAutoScroll), isOn: $autoScroll)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - 列表

    private var eventList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(stream.events) { event in
                        EventRow(
                            event: event,
                            isExpanded: expanded.contains(event.id),
                            toggleExpanded: {
                                if expanded.contains(event.id) {
                                    expanded.remove(event.id)
                                } else {
                                    expanded.insert(event.id)
                                }
                            }
                        )
                        .id(event.id)
                        Divider()
                    }
                }
            }
            .onChange(of: stream.events.last?.id) { _, last in
                // 只在自动滚动开启时跟随；用户手动上翻查看历史时不抢焦点。
                guard autoScroll, let last else { return }
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }
}

/// 单条事件：序号、类型徽标、id、相对时间、数据（等宽、可选中、可展开）。
private struct EventRow: View {
    @Environment(AppState.self) private var app

    let event: SSEEvent
    let isExpanded: Bool
    let toggleExpanded: () -> Void

    /// 未展开时最多显示的行数。
    private static let collapsedLineLimit = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("\(event.sequence)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 40, alignment: .trailing)

                Badge(text: event.eventType ?? "message", tint: .accentColor)

                if let id = event.eventID {
                    Text("id: \(id)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if event.isUnterminated {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .help(app.t(.streamEventUnterminated))
                }

                Spacer()

                Text(event.receivedAt, format: .dateTime.hour().minute().second())
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)

                Button {
                    copyToClipboard(event.data)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help(app.t(.streamCopyEvent))
            }

            Text(event.data)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(isExpanded ? nil : Self.collapsedLineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 48)
                .onTapGesture(perform: toggleExpanded)

            if event.isUnterminated {
                Text(app.t(.streamEventUnterminated))
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .padding(.leading, 48)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}
