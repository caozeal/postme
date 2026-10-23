import SwiftUI

/// 主界面外壳：左侧项目切换器 + 目录树，右侧「请求编辑 / 响应」上下分栏，工具栏放环境切换。
struct ContentView: View {
    @Environment(AppState.self) private var app

    /// 请求编辑区的最小高度（查询参数/请求头表格至少要能露出一行加页脚）。
    private static let requestPaneMinHeight: CGFloat = 200
    /// 响应区的绝对下限：状态栏 + 分页头 + 内容区，再小就什么也看不到了。
    private static let responsePaneMinHeight: CGFloat = 300
    /// 请求编辑区的"预算"：普通窗口下它大致占这么多，其余全归响应区。
    ///
    /// 取 320 而不是按比例分：请求区的各分页内部都是可滚动的表格，320 已经能舒服地
    /// 编辑几行；再高对调试没有额外价值，而响应区（大模型输出、事件列表）永远嫌小。
    private static let requestPaneBudget: CGFloat = 320

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
        } detail: {
            // 上下分栏：请求编辑区在上、响应区在下。
            //
            // **为什么不能只写 idealHeight**（实测过）：
            // - 请求区内部是 `ScrollView`（Headers/Params/Body 表格），对高度无限贪心；
            // - 响应区若也只声明弹性，`VSplitView` 就把剩余空间对半分——
            //   真实窗口 931 高时两栏各 472/458，响应区（大模型输出、事件列表、Body
            //   全在下半）明显不够用；
            // - `maxHeight` 也不被尊重（真实窗口下请求区照样拿到 472）。
            //
            // 有效的是给响应区一个**随窗口增长的最小高度**：请求区只按自己的下限占位，
            // 多出来的高度全部落到响应区。这样一来
            // - 小窗口：两栏各保下限，谁也不挤死；
            // - 常规窗口：请求区稳定在 ~310，响应区拿到其余全部；
            // - 大窗口：增量只给响应区（实测 800→1100 高时响应区 480→571，请求区不动）。
            // 用户仍可拖动分隔条自己调。
            GeometryReader { geo in
                VSplitView {
                    VStack(spacing: 0) {
                        EditorTabBar()
                        Divider()
                        RequestEditorView()
                    }
                    .frame(minHeight: Self.requestPaneMinHeight)
                    ResponseView()
                        .frame(minHeight: max(
                            Self.responsePaneMinHeight,
                            geo.size.height - Self.requestPaneBudget
                        ))
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                environmentPicker
            }
        }
        .sheet(isPresented: $app.showEnvironmentEditor) {
            EnvironmentEditor()
        }
        .sheet(isPresented: $app.showCurlImport) {
            CurlImportSheet()
        }
        .sheet(isPresented: $app.showOpenAPIImportSheet) {
            OpenAPIImportSheet()
        }
        .confirmationDialog(
            app.t(.tabCloseConfirmTitle),
            isPresented: Binding(
                get: { app.showTabCloseConfirm },
                // 收起时只关弹窗：按钮动作先发生，「保存并关闭」还要用待关闭目标。
                set: { if !$0 { app.tabCloseDialogDismissed() } }
            ),
            titleVisibility: .visible
        ) {
            Button(app.t(.tabCloseSaveAndClose)) { app.saveAndClosePendingTab() }
            Button(app.t(.tabCloseDiscard), role: .destructive) { app.discardAndClosePendingTab() }
            Button(app.t(.cancelButton), role: .cancel) { app.cancelTabClose() }
        } message: {
            Text(app.t(.tabCloseMessage, pendingTabTitle))
        }
        .confirmationDialog(
            app.t(.tabBatchCloseTitle, app.pendingBatchCloseIDs.count),
            isPresented: Binding(
                get: { app.showBatchCloseConfirm },
                set: { if !$0 { app.cancelBatchClose() } }
            ),
            titleVisibility: .visible
        ) {
            Button(app.t(.tabBatchCloseDiscard), role: .destructive) {
                app.confirmBatchCloseDiscardingChanges()
            }
            Button(app.t(.cancelButton), role: .cancel) { app.cancelBatchClose() }
        } message: {
            Text(app.t(.tabBatchCloseMessage, app.pendingBatchCloseDirtyCount))
        }
        .alert(
            app.t(.clearHistoryConfirmTitle),
            isPresented: $app.showClearHistoryConfirm
        ) {
            Button(app.t(.clearHistoryConfirmTitle), role: .destructive) { app.clearHistory() }
            Button(app.t(.cancelButton), role: .cancel) { app.showClearHistoryConfirm = false }
        } message: {
            Text(app.t(.clearHistoryConfirmMessage, app.visibleHistory.count))
        }
        .alert(
            app.t(.projectSwitchConfirmTitle),
            isPresented: Binding(
                get: { app.showProjectSwitchConfirm },
                set: { if !$0 { app.cancelProjectSwitch() } }
            )
        ) {
            Button(app.t(.projectSwitchSaveAndSwitch)) { app.saveAndConfirmProjectSwitch() }
            Button(app.t(.projectSwitchDiscard), role: .destructive) { app.discardAndConfirmProjectSwitch() }
            Button(app.t(.cancelButton), role: .cancel) { app.cancelProjectSwitch() }
        } message: {
            Text(app.t(.projectSwitchConfirmMessage, app.dirtyTabCount))
        }
        .alert(
            "postme",
            isPresented: Binding(
                get: { app.alertMessage != nil },
                set: { if !$0 { app.alertMessage = nil } }
            ),
            presenting: app.alertMessage
        ) { _ in
            Button(app.t(.okButton), role: .cancel) { app.alertMessage = nil }
        } message: { message in
            Text(message.text)
        }
    }

    /// 待关闭页签的标题（确认文案里带上名字，避免误关别的格）。
    private var pendingTabTitle: String {
        guard let id = app.pendingCloseTabID,
              let tab = app.tabs.first(where: { $0.id == id })
        else { return "" }
        return app.tabTitle(tab)
    }

    private var environmentPicker: some View {
        Menu {
            Button(app.t(.noEnvironment)) { app.selectEnvironment(id: nil) }

            if !app.environments.isEmpty {
                Divider()
                ForEach(app.environments) { environment in
                    let isActive = app.workspace.activeEnvironmentID == environment.id
                    Button {
                        app.selectEnvironment(id: environment.id)
                    } label: {
                        Text(isActive ? "✓ \(environment.name)" : environment.name)
                    }
                }
            }

            Divider()
            Button(app.t(.editEnvironments)) { app.showEnvironmentEditor = true }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "globe")
                Text(app.activeEnvironment?.name ?? app.t(.noEnvironment))
            }
        }
        .help(app.t(.switchEnvironmentHelp))
    }
}
