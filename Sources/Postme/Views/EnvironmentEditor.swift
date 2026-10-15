import SwiftUI

/// 环境编辑弹窗：左侧环境列表，右侧变量表。
struct EnvironmentEditor: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var selectedID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                environmentList
                    .frame(width: 200)
                Divider()
                detail
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(width: 760, height: 460)
        .onAppear {
            if selectedID == nil {
                selectedID = app.activeEnvironment?.id ?? app.environments.first?.id
            }
        }
    }

    private var header: some View {
        HStack {
            Text("环境与变量")
                .font(.headline)
            Spacer()
            Button("完成") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var environmentList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(app.environments) { environment in
                    HStack(spacing: 6) {
                        Image(systemName: app.workspace.activeEnvironmentID == environment.id
                              ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 10))
                            .foregroundStyle(app.workspace.activeEnvironmentID == environment.id
                                             ? Color.accentColor : Color.secondary)
                        Text(environment.name)
                            .lineLimit(1)
                    }
                    .tag(environment.id)
                    .contextMenu {
                        Button("设为当前环境") { app.selectEnvironment(id: environment.id) }
                        Button("删除", role: .destructive) {
                            app.deleteEnvironment(id: environment.id)
                            if selectedID == environment.id { selectedID = app.environments.first?.id }
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            Button {
                let id = app.addEnvironment()
                selectedID = id
            } label: {
                Label("新建环境", systemImage: "plus")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selectedID, app.environments.contains(where: { $0.id == id }) {
            let environment = app.bindingForEnvironment(id: id)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text("名称")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("环境名", text: environment.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                    Spacer()
                    if app.workspace.activeEnvironmentID == id {
                        Label("当前环境", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.accentColor)
                    } else {
                        Button("设为当前环境") { app.selectEnvironment(id: id) }
                            .font(.system(size: 11))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider()

                KeyValueEditor(
                    items: environment.variables,
                    keyPlaceholder: "变量名（不含 {{ }}）",
                    valuePlaceholder: "变量值"
                )

                Divider()
                builtinHint
            }
        } else {
            VStack {
                Spacer()
                Text(app.environments.isEmpty ? "还没有环境，点左下角新建" : "选择一个环境")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var builtinHint: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("内置动态变量（无需定义）")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("{{$timestamp}}  {{$isoTimestamp}}  {{$uuid}}  {{$randomInt}}")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
