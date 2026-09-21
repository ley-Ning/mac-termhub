import Foundation
import Citadel
import NIO

/// 会话级设置（UserDefaults 持久化，详情页头部菜单可改）
public enum SSHSessionSettings {
    /// keep-alive 心跳开关（默认开）
    public static var keepaliveEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: "ssh.keepalive.enabled") as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: "ssh.keepalive.enabled") }
    }

    /// 心跳间隔秒（默认 30）
    public static var keepaliveInterval: TimeInterval {
        get {
            let value = UserDefaults.standard.double(forKey: "ssh.keepalive.intervalSeconds")
            return value > 0 ? value : 30
        }
        set { UserDefaults.standard.set(newValue, forKey: "ssh.keepalive.intervalSeconds") }
    }

    /// 意外掉线自动重连开关（默认开）
    public static var reconnectEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: "ssh.reconnect.enabled") as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: "ssh.reconnect.enabled") }
    }
}

/// 一台主机的一条连接会话（UI 可观察状态 + SSHClient 持有者）。
/// 含 keep-alive 心跳判活与意外掉线后的自动重连（指数退避）。
@MainActor
public final class SSHSession: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case connecting
        case connected
        case failed(message: String)
        case closed

        public var isAlive: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    public let host: HostSnapshot

    @Published private(set) public var phase: Phase = .idle
    @Published private(set) public var lastConnectedAt: Date?
    /// 自动重连进行中的尝试序号（1 起）；nil=不在自动重连
    @Published private(set) public var autoReconnectAttempt: Int?
    /// 本次连接由自动重连恢复（终端是新 shell，UI 需提示）
    @Published private(set) public var didAutoReconnect = false
    /// 连接发起时刻（loading 动画计时用；连接结束置 nil）
    @Published private(set) public var connectingSince: Date?

    private var client: SSHClient?
    /// 跳板链上的中间连接（顺序：第一跳在前）
    private var jumpClients: [SSHClient] = []
    private var connectTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    /// 用户主动断开标志：主动断开绝不触发自动重连
    private var isUserInitiatedClose = false
    /// 最近一次连接使用的跳板链快照（自动重连时复用）
    private var lastJumpHosts: [HostSnapshot] = []
    /// open() 传入的指纹确认回调（自动重连时复用；正常重连时主机已信任，不会触发）
    private var storedHostKeyCallback: (@Sendable (TOFUHostKeyValidator.HostKeyFacts) async -> Bool)?

    /// 指数退避上限与最大尝试次数
    private static let reconnectMaxAttempts = 5
    private static let reconnectBaseDelay: TimeInterval = 1
    private static let reconnectMaxDelay: TimeInterval = 60

    public init(host: HostSnapshot) {
        self.host = host
    }

    /// 建立连接。hostKeyCallback 用于首次指纹确认（TOFU）；
    /// jumpHosts 为按序解析好的跳板链（不含目标主机）。
    public func open(
        hostKeyCallback: @escaping @Sendable (TOFUHostKeyValidator.HostKeyFacts) async -> Bool,
        jumpHosts: [HostSnapshot] = []
    ) {
        guard phase != .connecting, phase != .connected else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        autoReconnectAttempt = nil
        isUserInitiatedClose = false
        didAutoReconnect = false
        lastJumpHosts = jumpHosts
        storedHostKeyCallback = hostKeyCallback
        connectingSince = Date()
        phase = .connecting

        connectTask = Task { [weak self] in
            await self?.connectOnce()
        }
    }

    /// 单次连接；返回结果供重连循环判断是否继续
    private enum ConnectOutcome {
        case success
        case retryableFailure(message: String)
        /// 不可重试：指纹被拒/变化（防中间人场景反复弹窗）
        case fatalFailure(message: String)
    }

    private func connectOnce() async -> ConnectOutcome {
        do {
            let callback = storedHostKeyCallback ?? { _ in false }
            let connection = try await SSHConnectionFactory.connect(
                to: host,
                hostKeyCallback: callback,
                jumpHosts: lastJumpHosts
            )
            guard !Task.isCancelled else {
                await connection.closeAll()
                return .fatalFailure(message: "已取消")
            }
            install(connection)
            return .success
        } catch {
            let message = error.localizedDescription
            if !Task.isCancelled {
                connectingSince = nil
                phase = .failed(message: message)
            }
            switch error {
            case SSHSetupError.hostKeyChanged, SSHSetupError.hostKeyRejected:
                return .fatalFailure(message: message)
            default:
                return .retryableFailure(message: message)
            }
        }
    }

    /// 连接就绪：记录 client、挂断线回调、启动心跳
    private func install(_ connection: SSHConnection) {
        connectingSince = nil
        client = connection.client
        jumpClients = connection.jumpClients
        let client = connection.client
        client.onDisconnect { [weak self] in
            Task { @MainActor in
                guard let self, self.phase.isAlive else { return }
                self.handleUnexpectedDisconnect()
            }
        }
        lastConnectedAt = Date()
        phase = .connected
        startHeartbeat()
    }

    /// 用户主动断开（不会触发自动重连）
    public func close() {
        isUserInitiatedClose = true
        connectTask?.cancel()
        reconnectTask?.cancel()
        reconnectTask = nil
        autoReconnectAttempt = nil
        didAutoReconnect = false
        connectingSince = nil
        teardownConnection()
        phase = .closed
    }

    /// 意外掉线（断线回调/心跳判死）：按设置决定是否自动重连
    private func handleUnexpectedDisconnect() {
        teardownConnection()
        phase = .closed
        guard SSHSessionSettings.reconnectEnabled, !isUserInitiatedClose else { return }
        scheduleAutoReconnect()
    }

    /// 自动重连：指数退避 1s/2s/4s…上限 60s，最多 5 次
    private func scheduleAutoReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            var delay = Self.reconnectBaseDelay
            for attempt in 1...Self.reconnectMaxAttempts {
                guard let self, !Task.isCancelled else { return }
                self.autoReconnectAttempt = attempt
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, !self.isUserInitiatedClose else {
                    self.autoReconnectAttempt = nil
                    return
                }
                let outcome = await self.connectOnceForReconnect()
                switch outcome {
                case .success:
                    self.autoReconnectAttempt = nil
                    self.didAutoReconnect = true
                    return
                case .retryableFailure:
                    delay = min(delay * 2, Self.reconnectMaxDelay)
                case .fatalFailure:
                    self.autoReconnectAttempt = nil
                    return
                }
            }
            self?.autoReconnectAttempt = nil
        }
    }

    /// 重连路径的单次连接：重置用户断开标志（是意外掉线后的恢复）
    private func connectOnceForReconnect() async -> ConnectOutcome {
        isUserInitiatedClose = false
        connectingSince = Date()
        phase = .connecting
        return await connectOnce()
    }

    // MARK: - 心跳保活

    /// 周期轻量 exec 判活：既产生流量防 NAT/防火墙空闲超时，
    /// 又能在连接静默死亡时及时发现并触发重连。
    private func startHeartbeat() {
        stopHeartbeat()
        guard SSHSessionSettings.keepaliveEnabled else { return }
        let interval = SSHSessionSettings.keepaliveInterval
        heartbeatTask = Task { [weak self] in
            var consecutiveFailures = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { return }
                guard self.phase.isAlive, let client = self.client else { return }
                do {
                    _ = try await client.executeCommand("true")
                    consecutiveFailures = 0
                } catch {
                    consecutiveFailures += 1
                    // 连续 2 次失败判死（单次抖动不误杀）
                    if consecutiveFailures >= 2 {
                        self.handleUnexpectedDisconnect()
                        return
                    }
                }
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    /// 丢弃当前连接（含跳板链），后台关闭
    private func teardownConnection() {
        stopHeartbeat()
        let client = self.client
        let jumps = self.jumpClients
        self.client = nil
        self.jumpClients = []
        guard client != nil || !jumps.isEmpty else { return }
        Task.detached {
            try? await client?.close()
            for jumpClient in jumps.reversed() {
                try? await jumpClient.close()
            }
        }
    }

    // MARK: - 命令执行

    /// 在这条连接上执行命令，返回 stdout 字符串（stderr 合并可选）
    public func exec(_ command: String, mergeStreams: Bool = true) async throws -> String {
        guard let client else {
            throw SSHSetupError.notConnected
        }
        let buffer = try await client.executeCommand(command, mergeStreams: mergeStreams)
        return String(buffer: buffer)
    }

    /// 流式执行（docker logs -f 等），stdout/stderr 分开给
    public func execStream(_ command: String) async throws -> AsyncThrowingStream<ExecCommandOutput, Error> {
        guard let client else {
            throw SSHSetupError.notConnected
        }
        return try await client.executeCommandStream(command)
    }

    /// 供 Docker/SFTP 子模块复用的底层 client（连接态才返回）
    public var activeClient: SSHClient? { client }
}
