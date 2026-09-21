import SwiftUI
import SwiftData
import TermHubCore

/// 侧边栏：按分组展示主机，搜索、新增、右键编辑/复制/删除
public struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\SSHHost.groupName), SortDescriptor(\SSHHost.alias)]) 
    private var hosts: [SSHHost]

    public init() {}

    @State private var searchText = ""
    @State private var editingHost: SSHHost?
    @State private var showingNewHost = false

    // 分组折叠状态（跨启动持久化）
    @State private var collapsedGroups: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "sidebar.collapsedGroups") ?? [])
    @State private var renamingGroup: String?
    @State private var renameGroupText = ""
    @State private var newGroupHost: SSHHost?
    @State private var newGroupText = ""

    private var filtered: [SSHHost] {
        guard !searchText.isEmpty else { return hosts }
        let q = searchText.lowercased()
        return hosts.filter {
            $0.alias.lowercased().contains(q)
                || $0.hostname.lowercased().contains(q)
                || $0.username.lowercased().contains(q)
                || $0.notes.lowercased().contains(q)
        }
    }

    private var grouped: [(name: String, hosts: [SSHHost])] {
        Dictionary(grouping: filtered, by: { $0.groupName.isEmpty ? "默认" : $0.groupName })
            .map { (name: $0.key, hosts: $0.value.sorted { $0.alias < $1.alias }) }
            .sorted { $0.name < $1.name }
    }

    public var body: some View {
        List(selection: Binding(
            get: { appState.selectedHostID },
            set: { newValue in
                appState.selectedHostID = newValue
                if let id = newValue, let host = hosts.first(where: { $0.id == id }) {
                    appState.openSession(for: host.snapshot)
                }
            }
        )) {
            ForEach(grouped, id: \.name) { group in
                Section {
                    // 搜索时无视折叠，保证结果可见
                    if !isCollapsed(group.name) {
                        ForEach(group.hosts) { host in
                            SidebarRow(host: host, session: appState.sessions[host.id])
                                .tag(host.id)
                                .contextMenu {
                                    Button("编辑…") { editingHost = host }
                                    Button("连接") { appState.openSession(for: host.snapshot) }
                                    if grouped.count > 1 {
                                        Menu("移动到分组") {
                                            ForEach(grouped.map(\.name), id: \.self) { target in
                                                if target != group.name {
                                                    Button(target) { move(host, toGroup: target) }
                                                }
                                            }
                                            Divider()
                                            Button("新建分组并移入…") {
                                                newGroupText = ""
                                                newGroupHost = host
                                            }
                                        }
                                    }
                                    Divider()
                                    Button("复制主机") { duplicate(host) }
                                    Divider()
                                    Button("删除…", role: .destructive) { delete(host) }
                                }
                        }
                    }
                } header: {
                    HStack(spacing: 4) {
                        Button {
                            toggleGroup(group.name)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .rotationEffect(.degrees(isCollapsed(group.name) ? 0 : 90))
                                Text(group.name)
                                    .font(.callout)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.secondary)
                                Text("\(group.hosts.count)")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button("重命名分组…") {
                                renameGroupText = group.name == "默认" ? "" : group.name
                                renamingGroup = group.name
                            }
                            Button("解散分组（主机移回默认）", role: .destructive) {
                                dissolveGroup(group.name)
                            }
                        }
                    }
                    .textCase(nil)
                }
            }
        }
        .listStyle(.sidebar)
        // 空白区域右键：与工具栏一致的操作（右键在主机行上时仍显示该行的菜单）
        .contextMenu {
            Button {
                showingNewHost = true
            } label: {
                Label("新增主机…", systemImage: "plus")
            }
        }
        .searchable(text: $searchText, prompt: "搜索主机")
        .frame(minWidth: 220)
        .toolbar {
            ToolbarItem {
                Button {
                    showingNewHost = true
                } label: {
                    Label("新增主机", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingNewHost) {
            HostEditView(host: nil)
        }
        .sheet(item: $editingHost) { host in
            HostEditView(host: host)
        }
        .onReceive(NotificationCenter.default.publisher(for: .termHubNewHost)) { _ in
            showingNewHost = true
        }
        .alert("重命名分组", isPresented: Binding(
            get: { renamingGroup != nil },
            set: { if !$0 { renamingGroup = nil } }
        )) {
            TextField("分组名", text: $renameGroupText)
            Button("重命名") {
                if let group = renamingGroup {
                    renameGroup(group, to: renameGroupText)
                }
                renamingGroup = nil
            }
            Button("取消", role: .cancel) { renamingGroup = nil }
        } message: {
            Text("组内所有主机都会移到新分组名下")
        }
        .alert("新建分组并移入", isPresented: Binding(
            get: { newGroupHost != nil },
            set: { if !$0 { newGroupHost = nil } }
        )) {
            TextField("分组名", text: $newGroupText)
            Button("创建并移入") {
                let name = newGroupText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty, let host = newGroupHost {
                    host.groupName = name
                    try? modelContext.save()
                }
                newGroupHost = nil
            }
            Button("取消", role: .cancel) { newGroupHost = nil }
        } message: {
            Text("主机「\(newGroupHost?.alias ?? "")」将移入新分组")
        }
    }

    // MARK: - 分组操作

    private func isCollapsed(_ name: String) -> Bool {
        searchText.isEmpty ? collapsedGroups.contains(name) : false
    }

    private func toggleGroup(_ name: String) {
        if collapsedGroups.contains(name) {
            collapsedGroups.remove(name)
        } else {
            collapsedGroups.insert(name)
        }
        UserDefaults.standard.set(Array(collapsedGroups), forKey: "sidebar.collapsedGroups")
    }

    private func move(_ host: SSHHost, toGroup target: String) {
        host.groupName = target == "默认" ? "" : target
        try? modelContext.save()
    }

    private func renameGroup(_ name: String, to newName: String) {
        let target = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, target != name else { return }
        for host in hosts where displayName(of: host) == name {
            host.groupName = target
        }
        if collapsedGroups.contains(name) {
            collapsedGroups.remove(name)
            collapsedGroups.insert(target)
            UserDefaults.standard.set(Array(collapsedGroups), forKey: "sidebar.collapsedGroups")
        }
        try? modelContext.save()
    }

    private func dissolveGroup(_ name: String) {
        for host in hosts where displayName(of: host) == name {
            host.groupName = ""
        }
        collapsedGroups.remove(name)
        UserDefaults.standard.set(Array(collapsedGroups), forKey: "sidebar.collapsedGroups")
        try? modelContext.save()
    }

    private func displayName(of host: SSHHost) -> String {
        host.groupName.isEmpty ? "默认" : host.groupName
    }

    private func duplicate(_ host: SSHHost) {
        let copy = SSHHost(
            alias: host.alias + " 副本",
            hostname: host.hostname,
            port: host.port,
            username: host.username,
            authMethod: host.authMethod,
            keyPath: host.keyPath,
            groupName: host.groupName,
            notes: host.notes
        )
        modelContext.insert(copy)
        // 副本不复制密钥（Keychain 键跟着 id 走，需重新填写密码）
    }

    private func delete(_ host: SSHHost) {
        appState.closeSession(hostID: host.id)
        KeychainStore.deleteAllSecrets(hostID: host.id)
        modelContext.delete(host)
    }
}

private struct SidebarRow: View {
    let host: SSHHost
    let session: HostSession?

    public var body: some View {
        if let session {
            // 有会话：观察 HostSession，phase 变化经转发触发状态点刷新
            SidebarLiveRow(host: host, session: session)
        } else {
            SidebarIdleRow(host: host)
        }
    }
}

private struct SidebarLiveRow: View {
    let host: SSHHost
    @ObservedObject var session: HostSession

    public var body: some View {
        row(host: host, phase: session.ssh.phase)
    }
}

private struct SidebarIdleRow: View {
    let host: SSHHost

    public var body: some View {
        row(host: host, phase: nil)
    }
}

private func row(host: SSHHost, phase: SSHSession.Phase?) -> some View {
    SidebarRowShell(host: host, phase: phase)
}

private struct SidebarRowShell: View {
    let host: SSHHost
    let phase: SSHSession.Phase?

    public var body: some View {
        HStack(spacing: 8) {
            StatusDot(phase: phase)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.alias).font(.body).fontWeight(.medium)
                Text("\(host.username)@\(host.displayAddress)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if host.proxyType == .http {
                Image(systemName: "arrowshape.turn.up.right.dotted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(host.proxyDescription ?? "HTTP 代理")
            }
            if host.jumpHostID != nil {
                Image(systemName: "arrow.turn.up.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("经由跳板机连接")
            }
            if host.authMethod == .key {
                Image(systemName: "key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
    }
}
