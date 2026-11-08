import SwiftUI
import UniformTypeIdentifiers

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
    @State private var overwriteTargetID: UUID?
    @State private var overwriteTargetName = ""
    @State private var overwriteSourceName = ""
    @State private var overwriteSource: APIRequest?
    @State private var showOverwriteConfirm = false

    /// 当前正在拖动的节点。拖放目标据此判断「能不能放」。
    @State private var draggingNodeID: UUID?
    /// 当前拖放目标（用于画插入线 / 文件夹高亮）。
    @State private var dropTarget: NodeMoveTarget?

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
            historyPanel
        }
        .sheet(isPresented: $showRenameSheet) { renameSheet }
        .sheet(isPresented: $showNewFolderSheet) { newFolderSheet }
        .sheet(isPresented: $showNewProjectSheet) { newProjectSheet }
        .sheet(isPresented: $showRenameProjectSheet) { renameProjectSheet }
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
        .alert(app.t(.sidebarOverwriteConfirmTitle), isPresented: $showOverwriteConfirm) {
            Button(app.t(.sidebarOverwriteWithEditor), role: .destructive) {
                if let id = overwriteTargetID, let source = overwriteSource {
                    app.overwriteSavedRequest(id: id, with: source)
                }
                overwriteSource = nil
            }
            Button(app.t(.cancelButton), role: .cancel) { overwriteSource = nil }
        } message: {
            Text(app.t(.sidebarOverwriteConfirmMessage, overwriteSourceName, overwriteTargetName))
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
            // 导入 / 导出放在侧栏可见位置：系统菜单栏有快捷键，但项目级操作
            // 的入口应该在项目树旁边，而不是只藏在菜单栏里。
            importExportMenu
            // 新建项目只放在项目切换菜单里：项目是比「项目内新增」更高一层。
            // 新建请求 / 导入 cURL 已挪到编辑器页签条的「＋」——那两件事产出的都是
            // **新页签**，放在这里会让人以为它们只作用于当前项目。
            // 只剩「新建文件夹」一项，就不套菜单了：一层点开只剩一行是白加一次点击。
            Button {
                beginNewFolder(parentID: nil)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .help(app.t(.sidebarNewFolder))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var importExportMenu: some View {
        Menu {
            Button(app.t(.menuImportOpenAPI)) { FileActions.importOpenAPI(into: app) }
            Button(app.t(.menuImportPostman)) { FileActions.importPostman(into: app) }
            Button(app.t(.menuImportCurl)) { app.showCurlImport = true }
            Divider()
            Button(app.t(.menuExportPostman)) { FileActions.exportPostman(from: app) }
                .disabled(app.activeProject?.children.isEmpty ?? true)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 10))
                Text(app.t(.sidebarImportExport))
                    .font(.system(size: 11))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(app.t(.sidebarImportExportHelp))
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
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - 历史（左下角，默认收起）

    /// 历史区固定在侧栏底部：默认只留一行标题，点开才向上展开。
    ///
    /// **为什么默认收起**：历史是「回头查一条旧请求」时才用的，展开时它会把目录树
    /// 挤到半屏以下；而目录树是每次都要看的。收起状态持久化到 settings，
    /// 用户展开过一次，下次启动保持展开。
    ///
    /// **按项目隔离**：只展示当前项目发送过的记录——切换项目后，上一个项目的
    /// 请求不该继续混在列表里（用户分不清哪条属于手头的项目）。
    private var historyPanel: some View {
        let expanded = app.workspace.settings.historyExpanded
        let history = app.visibleHistory
        return VStack(spacing: 0) {
            Divider()
            historyHeader(expanded: expanded, count: history.count)
            if expanded {
                Divider()
                historyList
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func historyHeader(expanded: Bool, count: Int) -> some View {
        HStack(spacing: 6) {
            Button {
                app.setHistoryExpanded(!expanded)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Text(app.t(.sidebarHistorySection))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(app.t(expanded ? .sidebarHistoryCollapse : .sidebarHistoryExpand))

            Spacer(minLength: 4)

            if expanded && count > 0 {
                Button(app.t(.sidebarClearHistory)) {
                    app.requestClearHistory()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// 展开后的历史列表：上限 50 行（与原先一致），超出部分用「清空」管理。
    private var historyList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if app.visibleHistory.isEmpty {
                    HStack {
                        emptyHint(app.t(.sidebarEmptyHistory))
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                ForEach(app.visibleHistory.prefix(50)) { entry in
                    historyRow(entry)
                    Divider()
                }
            }
        }
        .frame(minHeight: 120, idealHeight: 200, maxHeight: 320)
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func row(for node: CollectionNode) -> some View {
        if app.isSearching {
            // 搜索结果是一次性视图，拖动没有稳定的位置语义，禁用拖放。
            requestRow(node, content: rowContent(for: node))
        } else {
            treeRow(node, content: rowContent(for: node))
                .overlay(alignment: .top) {
                    insertionLine(visible: dropTarget == .before(node.id), isTop: true)
                }
                .overlay(alignment: .bottom) {
                    insertionLine(visible: dropTarget == .after(node.id), isTop: false)
                }
                .background(insideHighlight(for: node))
                .onDrop(
                    of: [.postmeNodeID],
                    delegate: NodeDropDelegate(
                        target: node,
                        dropTarget: $dropTarget,
                        canDrop: { zone in
                            guard let draggingNodeID else { return false }
                            return app.canMoveNode(id: draggingNodeID, to: zone)
                        },
                        perform: { zone in
                            guard let id = draggingNodeID else { return }
                            draggingNodeID = nil
                            app.moveNode(id: id, to: zone)
                        }
                    )
                )
        }
    }

    /// 目录树里的一行。
    ///
    /// **拖拽只挂在内容本身**（不是整行）：拖拽源会接管落点的 mouseDown，
    /// 一旦覆盖整行，单击就传不到表格，行看起来「点不动」。
    @ViewBuilder
    private func treeRow(_ node: CollectionNode, content: some View) -> some View {
        let draggable = content
            .onDrag {
                dragProvider(for: node)
            } preview: {
                dragPreview(for: node)
            }
        if node.isFolder {
            // 文件夹保持原样：选中即高亮，展开靠左侧三角，点击本身不产生动作。
            draggable
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        } else {
            requestRow(node, content: draggable)
        }
    }

    /// 请求行：整行可点，点击即打开对应页签。
    ///
    /// **为什么不能只靠 `onChange(of: selectedNodeID)`**：打开请求原本是「选中值变了」
    /// 的副作用。行上挂了拖拽源之后，单击经常传不到表格 → 选中值不变 → 回调不触发，
    /// 表现就是「点了没反应」；而且一旦某次点击没改变选中值，再点同一行就永远沉默。
    /// 这里补一个行内显式手势（与拖拽源并行识别），`onChange` 那条继续保留，
    /// 负责键盘上下键切换选中时也能打开——两条路都走 `openSavedRequest`（已打开则
    /// 复用页签），重复触发是幂等的。
    private func requestRow(_ node: CollectionNode, content: some View) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { app.openSavedRequest(node) })
    }

    @ViewBuilder
    private func rowContent(for node: CollectionNode) -> some View {
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

    @ViewBuilder
    private func insertionLine(visible: Bool, isTop: Bool) -> some View {
        if visible {
            Rectangle()
                .fill(Color.accentColor)
                .frame(height: 2)
                .offset(y: isTop ? -1 : 1)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func insideHighlight(for node: CollectionNode) -> some View {
        if node.isFolder, dropTarget == .inside(node.id) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor.opacity(0.16))
        } else {
            Color.clear
        }
    }

    /// 拖拽载荷用自定义 UTType：只接受本 App 的节点，不会把外部拖进来的文本当成节点。
    private func dragProvider(for node: CollectionNode) -> NSItemProvider {
        draggingNodeID = node.id
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.postmeNodeID.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(Data(node.id.uuidString.utf8), nil)
            return nil
        }
        return provider
    }

    private func dragPreview(for node: CollectionNode) -> some View {
        HStack(spacing: 6) {
            Image(systemName: node.isFolder ? "folder" : "doc.text")
                .foregroundStyle(.secondary)
            Text(node.name)
                .lineLimit(1)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
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
            Button(app.t(.copyURLButton)) { FileActions.copyToPasteboard(entry.url) }
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
            overwriteTargetID = saved.id
            overwriteTargetName = saved.name
            overwriteSourceName = app.tabTitle(app.activeTab)
            overwriteSource = app.draft
            showOverwriteConfirm = true
        }
        Divider()
        Button(app.t(.copyURLButton)) { FileActions.copyToPasteboard(saved.request.url) }
        Button(app.t(.copyCurlButton)) { FileActions.copyAsCurl(from: app, request: saved.request) }
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
}


// MARK: - 拖放

private extension UTType {
    /// App 内部节点拖拽类型。`exportedAs` 不需要 Info.plist 声明，
    /// 只在进程内传递，不会和外部拖拽混淆。
    static let postmeNodeID = UTType(exportedAs: "dev.postme.node-id")
}

/// 单行的拖放判定。
///
/// 文件夹分为「上缘 / 中间 / 下缘」三段：上下插入同级，中间放入文件夹；
/// 请求只有上下两段（请求不能容纳子节点）。
private struct NodeDropDelegate: DropDelegate {
    let target: CollectionNode
    @Binding var dropTarget: NodeMoveTarget?
    let canDrop: (NodeMoveTarget) -> Bool
    let perform: (NodeMoveTarget) -> Void

    func dropEntered(info: DropInfo) {
        update(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let zone = zone(for: info), canDrop(zone) else {
            clearIfMine()
            return DropProposal(operation: .forbidden)
        }
        dropTarget = zone
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        clearIfMine()
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let zone = zone(for: info), canDrop(zone) else {
            clearIfMine()
            return false
        }
        dropTarget = nil
        perform(zone)
        return true
    }

    private func update(_ info: DropInfo) {
        guard let zone = zone(for: info), canDrop(zone) else {
            clearIfMine()
            return
        }
        dropTarget = zone
    }

    /// 只清掉属于自己的高亮：从 A 行移到 B 行时，A 的 dropExited 可能晚于
    /// B 的 dropEntered，无条件清空会把 B 刚画好的插入线抹掉。
    private func clearIfMine() {
        if dropTarget?.involves(target.id) == true { dropTarget = nil }
    }

    /// 侧栏行高约 20pt；文件夹中间留 10pt 作为「放入」区域。
    private func zone(for info: DropInfo) -> NodeMoveTarget? {
        if target.isFolder {
            if info.location.y < 6 { return .before(target.id) }
            if info.location.y > 16 { return .after(target.id) }
            return .inside(target.id)
        }
        return info.location.y < 11 ? .before(target.id) : .after(target.id)
    }
}
