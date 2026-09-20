import SwiftUI
import TermHubCore

/// 详情区：终端主工作区 + 右侧可开关工具面板（容器/文件/资源）
public struct HostDetailView: View {
    @Environment(AppState.self) private var appState
    @ObservedObject var session: HostSession

    public init(session: HostSession) {
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                TerminalWorkspace(hostSession: session)
                    .frame(minWidth: 380, idealWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                if let tool = session.activeTool {
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
    }

    @ViewBuilder
    private func toolPanel(_ tool: HostSession.ToolPanel) -> some View {
        // 不加面板标题条：详情页头部已有三个工具开关，面板内容自带各自工具栏
        switch tool {
        case .docker:
            DockerTabPage(hostSession: session)
        case .files:
            FilesTabPage(hostSession: session)
        case .stats:
            SystemStatsTabPage(hostSession: session)
        }
    }

    private var header: some View {
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
            Spacer()
            switch session.ssh.phase {
            case .connected:
                Button("断开") { appState.disconnect(session) }
            case .connecting:
                Button("取消") { appState.disconnect(session) }
            default:
                Button("连接") { appState.reconnect(session) }
            }
            Divider().frame(height: 16)
            // 工具面板开关：与终端并排显示，不是切换
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
        .padding(.horizontal)
        .padding(.vertical, 6)
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
            placeholder(icon: "hourglass", text: "等待连接…")
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

    private func placeholder(icon: String, text: String, color: Color = .secondary) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(color)
            Text(text).font(.caption).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
