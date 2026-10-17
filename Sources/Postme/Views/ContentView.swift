import SwiftUI

/// 主界面外壳：左侧项目切换器 + 目录树，右侧「请求编辑 / 响应」上下分栏，工具栏放环境切换。
struct ContentView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
        } detail: {
            VSplitView {
                RequestEditorView()
                    .frame(minHeight: 240, idealHeight: 320)
                ResponseView()
                    .frame(minHeight: 180)
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
