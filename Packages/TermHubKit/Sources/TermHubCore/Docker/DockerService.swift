import Foundation
import Citadel
import NIO

/// 基于 SSH exec 的 Docker 服务：容器/镜像/资源占用 + 容器操作
@MainActor
public final class DockerService: ObservableObject {
    public enum Availability: Equatable {
        case unknown
        case checking
        case available(version: String)
        case unavailable(String)
    }

    public let ssh: SSHSession

    @Published public var availability: Availability = .unknown
    @Published private(set) public var containers: [DockerContainer] = []
    @Published private(set) public var stats: [String: DockerStats] = [:]
    @Published private(set) public var images: [DockerImage] = []
    @Published private(set) public var lastError: String?
    @Published private(set) public var isRefreshing = false

    private var pollTask: Task<Void, Never>?
    public private(set) var pollInterval: TimeInterval = 5

    public init(ssh: SSHSession) {
        self.ssh = ssh
    }

    // MARK: - 可用性

    public func checkAvailability() async {
        availability = .checking
        do {
            let output = try await ssh.exec("docker version --format '{{.Server.Version}}' 2>&1")
            let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if version.isEmpty || version.lowercased().contains("command not found") || version.contains("Cannot connect") {
                availability = .unavailable(version.isEmpty ? "服务器上没有 docker 命令" : version)
            } else if let first = version.split(separator: "\n").first.map(String.init),
                      first.contains("."),
                      !first.contains("permission denied") {
                availability = .available(version: first)
            } else {
                availability = .unavailable(version)
            }
        } catch {
            availability = .unavailable(error.localizedDescription)
        }
    }

    // MARK: - 轮询

    public func startPolling() {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.availability == .unknown {
                    await self.checkAvailability()
                }
                if case .available = self.availability {
                    await self.refresh()
                }
                try? await Task.sleep(for: .seconds(self.pollInterval))
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - 数据刷新

    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.refreshContainers() }
            group.addTask { await self.refreshStats() }
        }
        lastError = nil
    }

    public func refreshContainers() async {
        do {
            let output = try await ssh.exec(
                "docker ps -a --format '{{json .}}' 2>/dev/null | head -200"
            )
            containers = Self.decodeLines(DockerContainer.self, from: output)
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func refreshStats() async {
        do {
            let output = try await ssh.exec(
                "docker stats --no-stream --format '{{json .}}' 2>/dev/null"
            )
            let list = Self.decodeLines(DockerStats.self, from: output)
            var map: [String: DockerStats] = [:]
            for item in list { map[item.containerID] = item }
            stats = map
        } catch {
            // stats 权限或 cgroup 差异常见，不覆盖 lastError，仅静默
        }
    }

    public func refreshImages() async {
        do {
            let output = try await ssh.exec(
                "docker images --format '{{json .}}' 2>/dev/null | head -300"
            )
            images = Self.decodeLines(DockerImage.self, from: output)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - 容器操作

    public enum ContainerAction: String {
        case start, stop, restart, pause, unpause
    }

    public func perform(_ action: ContainerAction, on container: DockerContainer) async {
        do {
            let _ = try await ssh.exec("docker \(action.rawValue) \(container.id)")
            await refreshContainers()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 进入容器的交互终端：返回一个流 + 写入口，由终端组件消费
    public func execStream(_ command: String) async throws -> AsyncThrowingStream<ExecCommandOutput, Error> {
        try await ssh.execStream(command)
    }

    // MARK: - 工具

    public nonisolated static func decodeLines<T: Decodable>(_ type: T.Type, from output: String) -> [T] {
        let decoder = JSONDecoder()
        var results: [T] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.hasPrefix("{") else { continue }
            if let data = trimmed.data(using: .utf8), let item = try? decoder.decode(T.self, from: data) {
                results.append(item)
            }
        }
        return results
    }
}

/// 容器日志：跟随 docker logs -f 的实时流
@MainActor
public final class DockerLogStreamer: ObservableObject {
    @Published private(set) public var lines: [String] = []
    @Published private(set) public var isFollowing = false
    @Published private(set) public var lastError: String?

    private var followTask: Task<Void, Never>?
    private let maxLines = 5000

    public init() {}

    public func start(ssh: SSHSession, container: DockerContainer, tail: Int = 200, follow: Bool = true) {
        stop()
        lines = []
        lastError = nil
        isFollowing = follow
        followTask = Task { [weak self] in
            do {
                let cmd = "docker logs --tail \(tail)\(follow ? " -f" : "") \(container.id) 2>&1"
                let stream = try await ssh.execStream(cmd)
                for try await chunk in stream {
                    if Task.isCancelled { break }
                    switch chunk {
                    case .stdout(let buffer), .stderr(let buffer):
                        let text = String(decoding: buffer.readableBytesView, as: UTF8.self)
                        guard !text.isEmpty else { continue }
                        self?.append(text)
                    }
                }
                await MainActor.run { self?.isFollowing = false }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run { self?.lastError = error.localizedDescription; self?.isFollowing = false }
                }
            }
        }
    }

    private func append(_ text: String) {
        let newLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.append(contentsOf: newLines)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    public func stop() {
        followTask?.cancel()
        followTask = nil
        isFollowing = false
    }

    public func clear() {
        lines = []
    }

    public var fullText: String { lines.joined(separator: "\n") }
}
