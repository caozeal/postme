import SwiftUI

/// 侧边栏：集合树 + 搜索 + 历史。
struct SidebarView: View {
    @Environment(AppState.self) private var app

    @State private var renameNodeID: UUID?
    @State private var renameText: String = ""
    @State private var showRenameSheet = false

    @State private var newFolderParentID: UUID?
    @State private var newFolderName: String = ""
    @State private var showNewFolderSheet = false

    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            header
            Divider()
            searchBar
            Divider()
            tree
        }
        .sheet(isPresented: $showRenameSheet) { renameSheet }
        .sheet(isPresented: $showNewFolderSheet) { newFolderSheet }
        .confirmationDialog(
            "当前请求有未保存的修改",
            isPresented: $app.showDraftConflict,
            titleVisibility: .visible
        ) {
            Button("保存并继续") { app.saveDraftAndContinue() }
            Button("放弃修改", role: .destructive) { app.discardDraftAndContinue() }
            Button("取消", role: .cancel) { app.cancelDraftConflict() }
        } message: {
            Text("切换后当前编辑内容会被替换。")
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
            Text("集合")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button("新建请求") { app.newRequest() }
                Button("新建文件夹") { beginNewFolder(parentID: nil) }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("新建")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var searchBar: some View {
        @Bindable var app = app
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("搜索请求", text: $app.searchKeyword)
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
                Section("搜索结果（\(app.searchResults.count)）") {
                    if app.searchResults.isEmpty {
                        emptyHint("没有匹配的请求")
                    }
                    ForEach(app.searchResults) { node in
                        row(for: node)
                    }
                }
            } else {
                Section("集合") {
                    if app.collections.isEmpty {
                        emptyHint("还没有集合，点右上角 ＋ 新建")
                    }
                    OutlineGroup(app.collections, children: \.children) { node in
                        row(for: node)
                    }
                }

                Section("历史") {
                    if app.history.isEmpty {
                        emptyHint("发送请求后会出现在这里")
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
            Button("恢复到编辑器") { app.restoreFromHistory(entry) }
            Button("复制 URL") { copyToClipboard(entry.url) }
            Divider()
            Button("删除记录", role: .destructive) { app.deleteHistoryEntry(id: entry.id) }
        }
    }

    // MARK: - 右键菜单

    @ViewBuilder
    private func folderMenu(_ folder: CollectionNode.Folder) -> some View {
        Button("在此新建请求") { app.newRequest(inFolder: folder.id) }
        Button("新建子文件夹") { beginNewFolder(parentID: folder.id) }
        Divider()
        Button("重命名") { beginRename(id: folder.id, current: folder.name) }
        Button("删除文件夹", role: .destructive) { app.deleteNode(id: folder.id) }
    }

    @ViewBuilder
    private func requestMenu(_ saved: CollectionNode.SavedRequest) -> some View {
        Button("打开") { app.openSavedRequest(.request(saved)) }
        Button("用当前编辑器内容覆盖") {
            app.overwriteSavedRequest(id: saved.id, with: app.draft)
        }
        Divider()
        Button("复制 URL") { copyToClipboard(saved.request.url) }
        Button("重命名") { beginRename(id: saved.id, current: saved.name) }
        Button("删除", role: .destructive) { app.deleteNode(id: saved.id) }
    }

    // MARK: - 弹窗

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("重命名").font(.headline)
            TextField("名称", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { commitRename() }
            HStack {
                Spacer()
                Button("取消") { showRenameSheet = false }
                Button("确定") { commitRename() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }

    private var newFolderSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("新建文件夹").font(.headline)
            TextField("文件夹名", text: $newFolderName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { commitNewFolder() }
            HStack {
                Spacer()
                Button("取消") { showNewFolderSheet = false }
                Button("确定") { commitNewFolder() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
}
