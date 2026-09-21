import SwiftUI
import Observation
import Combine
import TermHubCore

public extension Notification.Name {
    /// 菜单“新增主机”命令 -> 侧边栏弹新增表单
    public static let termHubNewHost = Notification.Name("termHubNewHost")
    /// 菜单“快速切换主机”命令（Cmd+K）-> 主窗口弹命令面板
    public static let termHubQuickSwitch = Notification.Name("termHubQuickSwitch")
}

/// 首次指纹确认弹窗的数据
public struct HostKeyPrompt: Identifiable {
    public let id = UUID()
    public let facts: TOFUHostKeyValidator.HostKeyFacts
    public let continuation: CheckedContinuation<Bool, Never>
}

/// 一台主机的界面会话：SSH 连接 + 终端标签页集合
@MainActor
public final class HostSession: ObservableObject {
    /// 右侧工具面板（终端是主工作区，工具是伴随面板）
    public enum ToolPanel: String, CaseIterable, Identifiable {
        case docker
        case files
        case stats
        case process
        case snippets

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .docker: return "容器"
            case .files: return "文件"
            case .stats: return "资源"
            case .process: return "进程"
            case .snippets: return "片段"
            }
        }

        public var icon: String {
            switch self {
            case .docker: return "cube.box"
            case .files: return "folder"
            case .stats: return "gauge.with.dots.needle.bottom.50percent"
            case .process: return "list.bullet.rectangle"
            case .snippets: return "text.badge.plus"
            }
        }
    }

    public let ssh: SSHSession

    @Published private(set) var terminals: [TerminalSession] = []
    @Published var selectedTerminalID: UUID?
    @Published public var activeTool: ToolPanel?

    private var sshCancellable: AnyCancellable?

    public init(host: HostSnapshot) {
        self.ssh = SSHSession(host: host)
        // 嵌套 ObservableObject 不会自动传导：SSHSession.phase 变化必须转发，
        // 否则观察 HostSession 的视图（头部徽章/按钮）收不到刷新，会一直停在"连接中"
        sshCancellable = ssh.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// 首次进入终端页时自动开一个终端
    public func ensureTerminal() {
        if terminals.isEmpty {
            addTerminal()
        }
    }

    @discardableResult
    public func addTerminal() -> TerminalSession {
        let terminal = TerminalSession(ssh: ssh)
        terminals.append(terminal)
        selectedTerminalID = terminal.id
        return terminal
    }

    public func closeTerminal(_ terminal: TerminalSession) {
        terminal.stop()
        terminals.removeAll { $0.id == terminal.id }
        if selectedTerminalID == terminal.id {
            selectedTerminalID = terminals.last?.id
        }
    }
}

/// 全局应用状态：选中主机、活动会话、指纹确认弹窗
@MainActor
@Observable
public final class AppState {
    public init() {}

    public var selectedHostID: UUID?
    public private(set) var sessions: [UUID: HostSession] = [:]
    public var hostKeyPrompt: HostKeyPrompt?

    private var hostKeyHandler: (@Sendable (TOFUHostKeyValidator.HostKeyFacts) async -> Bool)?

    /// 主机目录提供者：连接时现查 SwiftData，解析跳板链用（由主窗口注入，
    /// 主机目录快照（MainWindowView 在渲染时更新；跳板链解析用它）。
    /// 不用闭包即时 fetch：在 List 选中恢复等 SwiftUI 更新回调里同步查 SwiftData 会触发 trap 崩溃。
    public private(set) var hostCatalog: [HostSnapshot] = []

    public func updateHostCatalog(_ snapshots: [HostSnapshot]) {
        hostCatalog = snapshots
    }

    /// 沿 jumpHostID 解析跳板链（第一跳在前，不含目标）。
    /// 环/断链在途经处截断（表单保存处已做环校验，这里兜底防死循环）。
    public func resolveJumpChain(for snapshot: HostSnapshot) -> [HostSnapshot] {
        let catalog = hostCatalog
        guard !catalog.isEmpty else { return [] }
        var byID: [UUID: HostSnapshot] = [:]
        for host in catalog { byID[host.id] = host }

        var chain: [HostSnapshot] = []
        var visited: Set<UUID> = [snapshot.id]
        var cursor = snapshot.jumpHostID
        while let jumpID = cursor {
            guard !visited.contains(jumpID), let hop = byID[jumpID] else { break }
            chain.append(hop)
            visited.insert(jumpID)
            cursor = hop.jumpHostID
        }
        return chain
    }

    /// 选中即连接（不存在会话则建立；已存在且断了则重连）
    @discardableResult
    public func openSession(for snapshot: HostSnapshot) -> HostSession {
        let chain = resolveJumpChain(for: snapshot)
        if let existing = sessions[snapshot.id] {
            if !existing.ssh.phase.isAlive {
                existing.ssh.open(hostKeyCallback: sendableHostKeyHandler, jumpHosts: chain)
            }
            return existing
        }
        let session = HostSession(host: snapshot)
        sessions[snapshot.id] = session
        session.ssh.open(hostKeyCallback: sendableHostKeyHandler, jumpHosts: chain)
        return session
    }

    /// 详情页“连接/重连”按钮走这里（带指纹弹窗）
    func reconnect(_ session: HostSession) {
        session.ssh.open(hostKeyCallback: sendableHostKeyHandler, jumpHosts: resolveJumpChain(for: session.ssh.host))
    }

    func disconnect(_ session: HostSession) {
        session.ssh.close()
    }

    func closeSession(hostID: UUID) {
        sessions[hostID]?.ssh.close()
        sessions[hostID] = nil
        if selectedHostID == hostID {
            selectedHostID = nil
        }
    }

    func sessionState(hostID: UUID) -> SSHSession.Phase? {
        sessions[hostID]?.ssh.phase
    }

    // MARK: - 指纹确认（TOFU）

    /// 供 SSHSession 使用的 @Sendable 包装：进入主线程展示弹窗
    private var sendableHostKeyHandler: @Sendable (TOFUHostKeyValidator.HostKeyFacts) async -> Bool {
        if let handler = hostKeyHandler {
            return handler
        }
        let handler: @Sendable (TOFUHostKeyValidator.HostKeyFacts) async -> Bool = { [weak self] facts in
            guard let self else { return false }
            return await self.promptHostKey(facts)
        }
        hostKeyHandler = handler
        return handler
    }

    private func promptHostKey(_ facts: TOFUHostKeyValidator.HostKeyFacts) async -> Bool {
        await withCheckedContinuation { continuation in
            hostKeyPrompt = HostKeyPrompt(facts: facts, continuation: continuation)
        }
    }

    /// 弹窗按钮回调
    public func resolveHostKeyPrompt(accepted: Bool) {
        guard let prompt = hostKeyPrompt else { return }
        hostKeyPrompt = nil
        prompt.continuation.resume(returning: accepted)
    }
}
