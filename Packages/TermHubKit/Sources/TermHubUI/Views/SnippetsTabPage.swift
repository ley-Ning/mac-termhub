import SwiftUI
import TermHubCore

/// 命令片段面板：搜索 + 分组列表 + 编辑 sheet，点击发送到当前终端
public struct SnippetsTabPage: View {
    @ObservedObject private var hostSession: HostSession
    @ObservedObject private var store: SnippetStore

    @State private var searchText = ""
    @State private var editingSnippet: Snippet?
    @State private var showingNewSnippet = false
    @State private var deleteTarget: Snippet?

    public init(hostSession: HostSession) {
        self.hostSession = hostSession
        _store = ObservedObject(wrappedValue: SnippetStore.shared)
    }

    /// 当前选中的终端（发送目标；取法与终端工作区一致）
    private var currentTerminal: TerminalSession? {
        hostSession.terminals.first { $0.id == hostSession.selectedTerminalID }
            ?? hostSession.terminals.last
    }

    private var terminalReady: Bool {
        if case .running = currentTerminal?.phase { return true }
        return false
    }

    private var visible: [Snippet] {
        store.search(searchText, hostID: hostSession.ssh.host.id)
    }

    private var grouped: [(name: String, snippets: [Snippet])] {
        Dictionary(grouping: visible, by: { $0.groupName.isEmpty ? "默认" : $0.groupName })
            .map { (name: $0.key, snippets: $0.value.sorted { $0.title < $1.title }) }
            .sorted { $0.name < $1.name }
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            list
        }
        .sheet(isPresented: $showingNewSnippet) {
            SnippetEditView(
                snippet: nil,
                hostID: hostSession.ssh.host.id,
                hostAlias: hostSession.ssh.host.alias
            ) { store.add($0) }
        }
        .sheet(item: $editingSnippet) { snippet in
            SnippetEditView(
                snippet: snippet,
                hostID: hostSession.ssh.host.id,
                hostAlias: hostSession.ssh.host.alias
            ) { store.update($0) }
        }
        .alert("删除片段", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let target = deleteTarget {
                    store.delete(target)
                }
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("删除「\(deleteTarget?.title ?? "")」？")
        }
    }

    // MARK: - 工具条

    private var toolbar: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索片段", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("清空搜索")
            }
            Divider().frame(height: 14)
            Button {
                showingNewSnippet = true
            } label: {
                Image(systemName: "plus")
            }
            .help("新建片段")
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - 列表

    private var list: some View {
        Group {
            if visible.isEmpty {
                ContentUnavailableView(
                    "没有片段",
                    systemImage: "text.badge.plus",
                    description: Text("保存高频命令（重启服务、查日志、清缓存…），点一下即发送到终端")
                )
            } else {
                List {
                    ForEach(grouped, id: \.name) { group in
                        Section(group.name) {
                            ForEach(group.snippets) { snippet in
                                row(snippet)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func row(_ snippet: Snippet) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(snippet.title)
                        .font(.callout)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if !snippet.hostIDs.isEmpty {
                        Text("仅本机")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
                            .help("仅对部分主机可见")
                    }
                }
                Text(snippet.body)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            Spacer()
            Button {
                send(snippet)
            } label: {
                Image(systemName: "paperplane")
            }
            .buttonStyle(.borderless)
            .disabled(!terminalReady)
            .help(terminalReady ? "发送到当前终端（回车执行）" : "终端未运行，无法发送")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { send(snippet) }
        .contextMenu {
            Button("发送到终端") { send(snippet) }
                .disabled(!terminalReady)
            Button("复制内容") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(snippet.body, forType: .string)
            }
            Divider()
            Button("编辑…") { editingSnippet = snippet }
            Button("删除…", role: .destructive) { deleteTarget = snippet }
        }
    }

    /// 发送片段到当前终端（内容 + 回车；多行原文发送，由远端 shell 处理）
    private func send(_ snippet: Snippet) {
        guard terminalReady, let terminal = currentTerminal else { return }
        var bytes = Array(snippet.body.utf8)
        bytes.append(0x0A)   // \n
        terminal.sendToRemote(bytes[...])
    }
}

/// 片段新增/编辑表单
public struct SnippetEditView: View {
    /// nil=新增
    let snippet: Snippet?
    let hostID: UUID
    let hostAlias: String
    let onSave: (Snippet) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var commandText = ""
    @State private var groupName = "默认"
    @State private var onlyThisHost = false

    public init(
        snippet: Snippet?,
        hostID: UUID,
        hostAlias: String,
        onSave: @escaping (Snippet) -> Void
    ) {
        self.snippet = snippet
        self.hostID = hostID
        self.hostAlias = hostAlias
        self.onSave = onSave
    }

    private var formValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("片段") {
                    TextField("标题（如：重启 nginx）", text: $title)
                    TextField("分组", text: $groupName)
                    TextField(
                        "命令内容（可多行）",
                        text: $commandText,
                        axis: .vertical
                    )
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(4...10)
                }
                Section {
                    Toggle("仅当前主机可见（\(hostAlias)）", isOn: $onlyThisHost)
                } footer: {
                    Text("关闭则为全局片段，所有主机的片段面板都可见。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(snippet == nil ? "添加" : "保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!formValid)
            }
            .padding()
        }
        .frame(width: 440, height: 420)
        .onAppear(perform: load)
    }

    private func load() {
        guard let snippet else { return }
        title = snippet.title
        commandText = snippet.body
        groupName = snippet.groupName
        onlyThisHost = snippet.hostIDs.contains(hostID)
    }

    private func save() {
        var hostIDs: [UUID] = []
        if onlyThisHost {
            // 保留已有的其他主机作用域（编辑别的主机面板上看到的共享片段时）
            if let snippet {
                hostIDs = Array(Set(snippet.hostIDs + [hostID]))
            } else {
                hostIDs = [hostID]
            }
        }
        let saved = Snippet(
            id: snippet?.id ?? UUID(),
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            body: commandText,
            groupName: groupName,
            hostIDs: hostIDs
        )
        onSave(saved)
        dismiss()
    }
}
