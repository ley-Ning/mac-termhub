import SwiftUI
import SwiftData
import TermHubCore

/// 详情区：终端主工作区 + 右侧可开关工具面板（容器/文件/资源）
public struct HostDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var session: HostSession

    @State private var editingHost: TermHubCore.SSHHost?

    public init(session: HostSession) {
        self.session = session
    }

    /// 密码认证但钥匙串里没有密码（如从 HexHub 迁移、密码无法导出的主机）
    private var needsPassword: Bool {
        session.ssh.host.authMethod == .password
            && KeychainStore.read(kind: .password, hostID: session.ssh.host.id) == nil
    }

    public var body: some View {
        // 响应式：可用宽度不足时自动收起右侧工具面板（终端优先），并收纳头部按钮
        GeometryReader { proxy in
            let compact = proxy.size.width < 780
            VStack(spacing: 0) {
                header(compact: compact)
                Divider()
                HSplitView {
                    TerminalWorkspace(hostSession: session)
                        .frame(minWidth: 380, idealWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                    if let tool = session.activeTool, !compact {
                        toolPanel(tool)
                            .frame(
                                minWidth: 340,
                                idealWidth: 440,
                                maxWidth: 520,
                                maxHeight: .infinity
                            )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onChange(of: proxy.size.width) { _, newWidth in
                if newWidth < 640, session.activeTool != nil {
                    session.activeTool = nil
                }
            }
            .sheet(item: $editingHost) { host in
                HostEditView(host: host)
            }
            .overlay(alignment: .bottomTrailing) {
                // 窄空间面板不并排显示时，右下角常驻工具面板入口
                // （无论 activeTool 是否已选——否则 compact 下菜单选了面板会无任何反馈）
                if compact, session.ssh.phase == .connected {
                    Menu {
                        ForEach(HostSession.ToolPanel.allCases) { tool in
                            Button("\(session.activeTool == tool ? "✓ " : "")\(tool.label)") {
                                session.activeTool = tool
                            }
                        }
                    } label: {
                        Label("工具面板", systemImage: "sidebar.right")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.bar, in: Capsule())
                    }
                    .menuStyle(.borderlessButton)
                    .padding(10)
                }
            }
        }
    }

    @ViewBuilder
    private func toolPanel(_ tool: HostSession.ToolPanel) -> some View {
        // 不加面板标题条：详情页头部已有工具开关，面板内容自带各自工具栏
        switch tool {
        case .docker:
            DockerTabPage(hostSession: session)
        case .files:
            FilesTabPage(hostSession: session)
        case .stats:
            SystemStatsTabPage(hostSession: session)
        case .process:
            ProcessTabPage(hostSession: session)
        case .snippets:
            SnippetsTabPage(hostSession: session)
        }
    }

    private func header(compact: Bool) -> some View {
        HStack(spacing: 10) {
            // 只在失败时给出说明文字；常态保持干净（主机名看侧栏即可）
            if case .failed(let message) = session.ssh.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(message)
            }
            // 缺密码引导：密码认证且钥匙串无密码 —— 一键打开编辑表单补填（只进钥匙串）
            if needsPassword, session.ssh.phase != .connected {
                Button {
                    let hostID = session.ssh.host.id
                    editingHost = try? modelContext.fetch(
                        FetchDescriptor<TermHubCore.SSHHost>(predicate: #Predicate { $0.id == hostID })
                    ).first
                } label: {
                    Label("设置密码后连接", systemImage: "key.slash")
                        .font(.caption)
                }
                .controlSize(.small)
                .tint(.orange)
                .help("该主机是密码认证但尚未保存密码（迁移导入的主机密码无法自动带来）。点击填写，保存后自动进钥匙串。")
            }
            // 自动重连状态徽章
            if let attempt = session.ssh.autoReconnectAttempt {
                Label("重连中…（第 \(attempt) 次）", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("连接已意外断开，正在自动重连（指数退避，最多 5 次）")
            }
            if session.ssh.didAutoReconnect {
                Label("已重连（新 shell）", systemImage: "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("连接由自动重连恢复，终端是新的 shell（工作目录/前台进程不保留）")
            }
            Spacer()
            switch session.ssh.phase {
            case .connected:
                Button("断开") { appState.disconnect(session) }
            case .connecting:
                Button("取消") { appState.disconnect(session) }
            case .failed, .closed:
                Button("重新连接") { appState.reconnect(session) }
            default:
                Button("连接") { appState.reconnect(session) }
            }
            Divider().frame(height: 16)
            // 会话设置：保活/自动重连/粘贴保护
            sessionSettingsMenu
            // 工具面板开关：与终端并排显示；窄空间收进单一菜单防溢出
            if compact {
                Menu {
                    ForEach(HostSession.ToolPanel.allCases) { tool in
                        Button("\(session.activeTool == tool ? "✓ " : "")\(tool.label)") {
                            session.activeTool = session.activeTool == tool ? nil : tool
                        }
                    }
                } label: {
                    Image(systemName: "sidebar.right")
                        .frame(width: 26, height: 22)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("工具面板（窄窗口收起，点开选择）")
            } else {
                ForEach(HostSession.ToolPanel.allCases) { tool in
                    Button {
                        session.activeTool = session.activeTool == tool ? nil : tool
                    } label: {
                        Image(systemName: tool.icon)
                            .frame(width: 26, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .background(
                        session.activeTool == tool
                            ? Color.accentColor.opacity(0.22)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .help("\(tool.label)面板（与终端并排显示）")
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    /// 会话设置菜单（UserDefaults 持久化，对所有会话生效）
    private var sessionSettingsMenu: some View {
        Menu {
            Toggle(
                "意外掉线自动重连",
                isOn: Binding(
                    get: { SSHSessionSettings.reconnectEnabled },
                    set: { SSHSessionSettings.reconnectEnabled = $0 }
                )
            )
            Toggle(
                "心跳保活（防空闲断开）",
                isOn: Binding(
                    get: { SSHSessionSettings.keepaliveEnabled },
                    set: { SSHSessionSettings.keepaliveEnabled = $0 }
                )
            )
            Picker(
                "心跳间隔",
                selection: Binding(
                    get: { SSHSessionSettings.keepaliveInterval },
                    set: { SSHSessionSettings.keepaliveInterval = $0 }
                )
            ) {
                ForEach([15.0, 30.0, 60.0], id: \.self) { seconds in
                    Text("\(Int(seconds)) 秒").tag(seconds)
                }
            }
            Divider()
            Toggle(
                "多行粘贴前确认",
                isOn: Binding(
                    get: { PasteProtectSettings.enabled },
                    set: { PasteProtectSettings.enabled = $0 }
                )
            )
        } label: {
            Image(systemName: "gearshape")
                .frame(width: 26, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("会话设置（保活 / 自动重连 / 粘贴保护）")
    }
}

// MARK: - 终端页（多标签终端）

struct TerminalWorkspace: View {
    @ObservedObject var hostSession: HostSession

    public var body: some View {
        VStack(spacing: 0) {
            terminalTabStrip
            Divider()
            if let terminal = currentTerminal {
                TerminalContainer(terminal: terminal)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "terminal")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("没有打开的终端")
                        .foregroundStyle(.secondary)
                    Button("新建终端") { hostSession.addTerminal() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { hostSession.ensureTerminal() }
    }

    private var currentTerminal: TerminalSession? {
        hostSession.terminals.first { $0.id == hostSession.selectedTerminalID }
            ?? hostSession.terminals.last
    }

    private var terminalTabStrip: some View {
        HStack(spacing: 4) {
            ForEach(hostSession.terminals) { terminal in
                TerminalPill(
                    title: pillTitle(for: terminal),
                    isActive: terminal.id == hostSession.selectedTerminalID,
                    onSelect: { hostSession.selectedTerminalID = terminal.id },
                    onClose: { hostSession.closeTerminal(terminal) }
                )
            }
            Button {
                hostSession.addTerminal()
            } label: {
                Image(systemName: "plus")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("新建终端（同一连接多开 shell）")
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func pillTitle(for terminal: TerminalSession) -> String {
        let index = hostSession.terminals.firstIndex(where: { $0.id == terminal.id }).map { $0 + 1 } ?? 0
        let title = terminal.title
        return title == "终端" ? "终端 \(index)" : title
    }
}

private struct TerminalPill: View {
    let title: String
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    public var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(isActive ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

/// 终端内容容器：按连接状态切换占位/终端视图
private struct TerminalContainer: View {
    @ObservedObject var terminal: TerminalSession

    public var body: some View {
        ZStack {
            SSHTerminalView(terminal: terminal)
                .opacity(terminal.phase == .running ? 1 : 0)

            if terminal.phase != .running {
                overlay
            }
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch terminal.phase {
        case .waitingConnect:
            connectingOverlay
        case .starting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在启动 shell…").foregroundStyle(.secondary)
            }
        case .failed(let message):
            placeholder(icon: "exclamationmark.triangle", text: message, color: .red)
        case .closed:
            VStack(spacing: 8) {
                Text("终端已关闭").foregroundStyle(.secondary)
                Button("重新打开") { terminal.restart() }
                    .disabled(!terminal.ssh.phase.isAlive)
            }
        case .running:
            EmptyView()
        }
    }

    /// 连接中 overlay：旋转指示 + 实时秒表（让用户看到"它在动"，可判断卡没卡）
    private var connectingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                let elapsed = terminal.ssh.connectingSince.map {
                    context.date.timeIntervalSince($0)
                } ?? 0
                Text("正在连接 \(terminal.ssh.host.displayAddress)…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(String(format: "%.1f s", min(elapsed, 999)))
                    .font(.system(size: 13, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func placeholder(icon: String, text: String, color: Color = .secondary) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(color)
            Text(text).font(.caption).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
