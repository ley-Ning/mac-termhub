import Foundation
import Citadel
import NIO

/// 一台主机的一条连接会话（UI 可观察状态 + SSHClient 持有者）
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

    private var client: SSHClient?
    private var connectTask: Task<Void, Never>?

    public init(host: HostSnapshot) {
        self.host = host
    }

    /// 建立连接。hostKeyCallback 用于首次指纹确认（TOFU）。
    public func open(hostKeyCallback: @escaping @Sendable (TOFUHostKeyValidator.HostKeyFacts) async -> Bool) {
        guard phase != .connecting, phase != .connected else { return }
        phase = .connecting

        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                let client = try await SSHConnectionFactory.connect(to: self.host, hostKeyCallback: hostKeyCallback)
                guard !Task.isCancelled else {
                    try? await client.close()
                    return
                }
                self.client = client
                client.onDisconnect { [weak self] in
                    Task { @MainActor in
                        guard let self, self.phase.isAlive else { return }
                        self.phase = .closed
                        self.client = nil
                    }
                }
                self.lastConnectedAt = Date()
                self.phase = .connected
            } catch {
                if !Task.isCancelled {
                    self.phase = .failed(message: error.localizedDescription)
                }
            }
        }
    }

    public func close() {
        connectTask?.cancel()
        let client = self.client
        self.client = nil
        phase = .closed
        guard let client else { return }
        Task.detached {
            try? await client.close()
        }
    }

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
