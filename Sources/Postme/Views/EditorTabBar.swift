import SwiftUI

/// 编辑器顶部的请求页签条：一格一个打开中的请求，最右侧是「＋」菜单（新建请求 / 导入 cURL）。
///
/// **为什么要有它**：单草稿时代打开别的请求只能覆盖编辑器内容，于是必须弹
/// 「当前请求有未保存的修改」逼用户二选一。页签让每格各自持有草稿，
/// 那条弹窗路径连同它的状态机一起消失。
struct EditorTabBar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(app.tabs) { tab in
                            tabItem(tab)
                                .id(tab.id)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
                .onChange(of: app.activeTabID, initial: true) { _, id in
                    proxy.scrollTo(id)
                }
            }
            newTabButton
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func tabItem(_ tab: EditorTab) -> some View {
        let isActive = tab.id == app.activeTabID
        let title = app.tabTitle(tab)
        return HStack(spacing: 2) {
            Button {
                app.activateTab(id: tab.id)
            } label: {
                HStack(spacing: 5) {
                    stateIcon(tab)
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                        .frame(maxWidth: 160, alignment: .leading)
                }
                .padding(.leading, 8)
                .padding(.trailing, 3)
                .frame(minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isActive ? .isSelected : [])
            .accessibilityValue(tabAccessibilityStatus(tab))
            .help(title)

            Button {
                app.requestCloseTab(id: tab.id)
            } label: {
                Image(icon: .close)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(app.t(.tabCloseNamed, title))
            .help(app.t(.tabCloseHelp))
        }
        .padding(.trailing, 2)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isActive ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.22)
                               : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(isActive ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
                .allowsHitTesting(false)
        )
        // 关闭类操作的快捷入口：右键哪一格，「关闭其他」就保留哪一格。
        .contextMenu {
            Button(app.t(.tabMenuDuplicate)) {
                app.cloneTab(id: tab.id)
            }
            Divider()
            Button(app.t(.tabMenuClose)) {
                app.requestCloseTab(id: tab.id)
            }
            Button(app.t(.tabMenuCloseOthers)) {
                app.requestCloseOtherTabs(keeping: tab.id)
            }
            .disabled(app.tabs.count <= 1)
            Button(app.t(.tabMenuCloseAll)) {
                app.requestCloseAllTabs()
            }
        }
    }

    private func tabAccessibilityStatus(_ tab: EditorTab) -> String {
        if tab.isSending { return app.t(.sendingProgress) }
        return tab.isDirty ? app.t(.tabUnsavedAccessibility) : ""
    }

    /// 运行期状态图标：在飞 > 未保存 > 无。三者互斥，同一位子上只出现一个。
    @ViewBuilder
    private func stateIcon(_ tab: EditorTab) -> some View {
        if tab.isSending {
            ProgressView().controlSize(.mini)
        } else if tab.isDirty {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)
        } else {
            Image(icon: .request)
                .font(.system(size: 10))
                .foregroundStyle(tab.id == app.activeTabID ? BrandColor.icon : Color.secondary)
        }
    }

    /// 「＋」：新增页签的入口。菜单里放两件与「打开一个新请求」同义的事——
    /// 新建空白请求，和把剪贴板里的 cURL 变成请求。两者都产出**新的页签**，
    /// 所以入口就放在页签条上，而不是侧栏的「当前项目」加号里。
    private var newTabButton: some View {
        Menu {
            Button(app.t(.tabNewMenuNewRequest)) { app.newRequest() }
            Button(app.t(.tabNewMenuImportCurl)) { app.showCurlImport = true }
        } label: {
            Image(icon: .add)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 4)
        .accessibilityLabel(app.t(.tabNewMenuHelp))
        .help(app.t(.tabNewMenuHelp))
    }
}
