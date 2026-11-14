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
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(app.tabs) { tab in
                        tabItem(tab)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            newTabButton
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func tabItem(_ tab: EditorTab) -> some View {
        let isActive = tab.id == app.activeTabID
        return HStack(spacing: 5) {
            stateIcon(tab)
            Text(app.tabTitle(tab))
                .font(.system(size: 11.5))
                .lineLimit(1)
                // 页签宽度有上限：长名字不许把别的页签挤出可视区。
                .frame(maxWidth: 160, alignment: .leading)
            Button {
                app.requestCloseTab(id: tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(app.t(.tabCloseHelp))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isActive ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.22)
                               : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(isActive ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
        )
        // 点击整格切换；× 按钮自己吃掉点击（SwiftUI 先命中内层控件）。
        .contentShape(Rectangle())
        .onTapGesture { app.activateTab(id: tab.id) }
        .help(app.tabTitle(tab))
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
            Image(systemName: "doc.text")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
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
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 8)
        .help(app.t(.tabNewMenuHelp))
    }
}
