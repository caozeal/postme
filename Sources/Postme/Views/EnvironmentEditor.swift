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
            Text(app.t(.environmentsTitle))
                .font(.headline)
            Spacer()
            Button(app.t(.doneButton)) { dismiss() }
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
                        Button(app.t(.setAsActiveEnvironment)) { app.selectEnvironment(id: environment.id) }
                        Button(app.t(.deleteButton), role: .destructive) {
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
                Label(app.t(.newEnvironment), systemImage: "plus")
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
                    Text(app.t(.nameLabel))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField(app.t(.environmentNamePlaceholder), text: environment.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                    Spacer()
                    if app.workspace.activeEnvironmentID == id {
                        Label(app.t(.currentEnvironment), systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.accentColor)
                    } else {
                        Button(app.t(.setAsActiveEnvironment)) { app.selectEnvironment(id: id) }
                            .font(.system(size: 11))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider()

                KeyValueEditor(
                    items: environment.variables,
                    keyPlaceholder: app.t(.envKeyPlaceholder),
                    valuePlaceholder: app.t(.envValuePlaceholder)
                )

                Divider()
                builtinHint
            }
        } else {
            VStack {
                Spacer()
                Text(app.environments.isEmpty ? app.t(.noEnvironmentsHint) : app.t(.selectEnvironmentHint))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var builtinHint: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(app.t(.builtinVariablesHint))
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
