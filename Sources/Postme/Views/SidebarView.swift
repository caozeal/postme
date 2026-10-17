import SwiftUI

/// 侧边栏：项目切换器 + 当前项目的目录树 + 搜索 + 历史。
struct SidebarView: View {
    @Environment(AppState.self) private var app

    @State private var renameNodeID: UUID?
    @State private var renameText: String = ""
    @State private var showRenameSheet = false

    @State private var newFolderParentID: UUID?
    @State private var newFolderName: String = ""
    @State private var showNewFolderSheet = false

    @State private var newProjectName: String = ""
    @State private var showNewProjectSheet = false

    @State private var renameProjectText: String = ""
    @State private var showRenameProjectSheet = false

    /// 待确认删除的项目 id（用 id 而非 Project，避免删除后视图还持着旧值）。
    @State private var projectToDeleteID: UUID?

    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            header
            Divider()
            projectPicker
            Divider()
            searchBar
            Divider()
            tree
        }
        .sheet(isPresented: $showRenameSheet) { renameSheet }
        .sheet(isPresented: $showNewFolderSheet) { newFolderSheet }
        .sheet(isPresented: $showNewProjectSheet) { newProjectSheet }
        .sheet(isPresented: $showRenameProjectSheet) { renameProjectSheet }
        .confirmationDialog(
            app.t(.draftConflictTitle),
            isPresented: $app.showDraftConflict,
            titleVisibility: .visible
        ) {
            Button(app.t(.draftConflictSaveAndContinue)) { app.saveDraftAndContinue() }
            Button(app.t(.draftConflictDiscard), role: .destructive) { app.discardDraftAndContinue() }
            Button(app.t(.cancelButton), role: .cancel) { app.cancelDraftConflict() }
        } message: {
            Text(app.t(.draftConflictMessage))
        }
        .confirmationDialog(
            app.t(.deleteProjectTitle),
            isPresented: deleteProjectDialogPresented,
            titleVisibility: .visible
        ) {
            Button(app.t(.deleteProjectTitle), role: .destructive) {
                if let id = projectToDeleteID { app.deleteProject(id: id) }
                projectToDeleteID = nil
            }
            Button(app.t(.cancelButton), role: .cancel) { projectToDeleteID = nil }
        } message: {
            Text(app.t(.deleteProjectMessage, projectToDeleteName))
        }
        .onChange(of: app.selectedNodeID) { _, newValue in
            app.handleSidebarSelection(newValue)
        }
        .onChange(of: app.focusSearchTick) { _, _ in
            searchFocused = true
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack {
            Text(app.t(.sidebarProjectsTitle))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button(app.t(.sidebarNewProject)) { beginNewProject() }
                Button(app.t(.sidebarNewRequest)) { app.newRequest() }
                Button(app.t(.sidebarNewFolder)) { beginNewFolder(parentID: nil) }
                Divider()
                Button(app.t(.sidebarImportCurlCommand)) { app.showCurlImport = true }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(app.t(.sidebarNewHelp))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - 项目切换器（参考 ApiPost：侧栏顶部下拉，目录树只显示当前项目）

    private var projectPicker: some View {
        @Bindable var app = app
        return Menu {
            ForEach(app.projects) { project in
                Button {
                    app.selectProject(id: project.id)
                } label: {
                    Text(app.workspace.activeProjectID == project.id ? "✓ \(project.name)" : project.name)
                }
            }
            Divider()
            Button(app.t(.sidebarNewProjectEllipsis)) { beginNewProject() }
            Button(app.t(.sidebarRenameProjectEllipsis)) { beginRenameProject() }
            Button(app.t(.sidebarDeleteProjectEllipsis), role: .destructive) {
                projectToDeleteID = app.activeProject?.id
            }
            .disabled(app.projects.count <= 1)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(.secondary)
                Text(app.activeProject?.name ?? app.t(.sidebarNoProject))
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .help(app.t(.sidebarSwitchProjectHelp))
    }

    private var searchBar: some View {
        @Bindable var app = app
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField(app.t(.sidebarSearchPlaceholder), text: $app.searchKeyword)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
            if !app.searchKeyword.isEmpty {
                Button {
                    app.searchKeyword = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - 树

    private var tree: some View {
        @Bindable var app = app
        return List(selection: $app.selectedNodeID) {
            if app.isSearching {
                Section(app.t(.sidebarSearchResultsSection, app.searchResults.count)) {
                    if app.searchResults.isEmpty {
                        emptyHint(app.t(.sidebarNoSearchResults))
                    }
                    ForEach(app.searchResults) { node in
                        row(for: node)
                    }
                }
            } else {
                Section(app.t(.sidebarTreeSection)) {
                    let children = app.activeProject?.children ?? []
                    if children.isEmpty {
                        emptyHint(app.t(.sidebarEmptyProject))
                    }
                    OutlineGroup(children, children: \.children) { node in
                        row(for: node)
                    }
                }

                Section(app.t(.sidebarHistorySection)) {
                    if app.history.isEmpty {
                        emptyHint(app.t(.sidebarEmptyHistory))
                    }
                    ForEach(app.history.prefix(50)) { entry in
                        historyRow(entry)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func row(for node: CollectionNode) -> some View {
        if case .folder(let folder) = node {
            Label(folder.name, systemImage: "folder")
                .contextMenu { folderMenu(folder) }
        } else if let saved = node.savedRequest {
            HStack(spacing: 6) {
                methodBadge(saved.request.method)
                Text(saved.name)
                    .lineLimit(1)
            }
            .contextMenu { requestMenu(saved) }
        }
    }

    private func methodBadge(_ method: HTTPMethod) -> some View {
        Text(method.rawValue)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(method.tint)
            .frame(width: 36, alignment: .leading)
    }

    private func historyRow(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 6) {
            methodBadge(entry.method)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.requestName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(entry.url)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let code = entry.statusCode {
                Text("\(code)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(statusTint(for: code))
            } else {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundStyle(Color(red: 0.85, green: 0.25, blue: 0.25))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { app.restoreFromHistory(entry) }
        .contextMenu {
            Button(app.t(.sidebarRestoreToEditor)) { app.restoreFromHistory(entry) }
            Button(app.t(.copyURLButton)) { copyToClipboard(entry.url) }
            Divider()
            Button(app.t(.sidebarDeleteRecord), role: .destructive) { app.deleteHistoryEntry(id: entry.id) }
        }
    }

    // MARK: - 右键菜单

    @ViewBuilder
    private func folderMenu(_ folder: CollectionNode.Folder) -> some View {
        Button(app.t(.sidebarNewRequestHere)) { app.newRequest(inFolder: folder.id) }
        Button(app.t(.sidebarNewSubfolder)) { beginNewFolder(parentID: folder.id) }
        // 仅顶层文件夹可「提为项目」——嵌套文件夹提出来会打乱项目内的目录层级
        if app.activeProject?.children.contains(where: { $0.id == folder.id }) == true {
            Button(app.t(.sidebarPromoteToProject)) { app.promoteFolderToProject(id: folder.id) }
        }
        Divider()
        Button(app.t(.renameButton)) { beginRename(id: folder.id, current: folder.name) }
        Button(app.t(.sidebarDeleteFolder), role: .destructive) { app.deleteNode(id: folder.id) }
    }

    @ViewBuilder
    private func requestMenu(_ saved: CollectionNode.SavedRequest) -> some View {
        Button(app.t(.sidebarOpen)) { app.openSavedRequest(.request(saved)) }
        Button(app.t(.sidebarOverwriteWithEditor)) {
            app.overwriteSavedRequest(id: saved.id, with: app.draft)
        }
        Divider()
        Button(app.t(.copyURLButton)) { copyToClipboard(saved.request.url) }
        Button(app.t(.renameButton)) { beginRename(id: saved.id, current: saved.name) }
        Button(app.t(.deleteButton), role: .destructive) { app.deleteNode(id: saved.id) }
    }

    // MARK: - 弹窗

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(app.t(.renameButton)).font(.headline)
            TextField(app.t(.nameLabel), text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { commitRename() }
            HStack {
                Spacer()
                Button(app.t(.cancelButton)) { showRenameSheet = false }
                Button(app.t(.okButton)) { commitRename() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }

    private var newFolderSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(app.t(.newFolderTitle)).font(.headline)
            TextField(app.t(.newFolderNamePlaceholder), text: $newFolderName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { commitNewFolder() }
            HStack {
                Spacer()
                Button(app.t(.cancelButton)) { showNewFolderSheet = false }
                Button(app.t(.okButton)) { commitNewFolder() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }

    private var newProjectSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(app.t(.newProjectTitle)).font(.headline)
            TextField(app.t(.projectNamePlaceholder), text: $newProjectName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { commitNewProject() }
            HStack {
                Spacer()
                Button(app.t(.cancelButton)) { showNewProjectSheet = false }
                Button(app.t(.okButton)) { commitNewProject() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }

    private var renameProjectSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(app.t(.renameProjectTitle)).font(.headline)
            TextField(app.t(.projectNamePlaceholder), text: $renameProjectText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { commitRenameProject() }
            HStack {
                Spacer()
                Button(app.t(.cancelButton)) { showRenameProjectSheet = false }
                Button(app.t(.okButton)) { commitRenameProject() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(renameProjectText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }

    private func beginRename(id: UUID, current: String) {
        renameNodeID = id
        renameText = current
        showRenameSheet = true
    }

    private func commitRename() {
        if let id = renameNodeID {
            app.renameNode(id: id, to: renameText)
        }
        renameNodeID = nil
        showRenameSheet = false
    }

    private func beginNewFolder(parentID: UUID?) {
        newFolderParentID = parentID
        newFolderName = ""
        showNewFolderSheet = true
    }

    private func commitNewFolder() {
        app.newFolder(name: newFolderName, inFolder: newFolderParentID)
        newFolderParentID = nil
        showNewFolderSheet = false
    }

    private func beginNewProject() {
        newProjectName = ""
        showNewProjectSheet = true
    }

    private func commitNewProject() {
        app.newProject(name: newProjectName)
        showNewProjectSheet = false
    }

    private func beginRenameProject() {
        renameProjectText = app.activeProject?.name ?? ""
        showRenameProjectSheet = true
    }

    private func commitRenameProject() {
        if let project = app.activeProject {
            app.renameProject(id: project.id, to: renameProjectText)
        }
        showRenameProjectSheet = false
    }

    // MARK: - 删除项目确认框

    private var deleteProjectDialogPresented: Binding<Bool> {
        Binding(
            get: { projectToDeleteID != nil },
            set: { if !$0 { projectToDeleteID = nil } }
        )
    }

    private var projectToDeleteName: String {
        guard let id = projectToDeleteID else { return "" }
        return app.projects.first { $0.id == id }?.name ?? ""
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
