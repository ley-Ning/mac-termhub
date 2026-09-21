import Foundation
import Network

/// 资产延迟监测（借鉴 HexHub 的延迟列）：周期对每台主机做 TCP 连通探测，
/// 发布 RTT 毫秒值或超时。走 HTTP 代理的主机探测代理入口（链路健康）。
@MainActor
public final class LatencyMonitor: ObservableObject {
    public enum Probe: Equatable, Sendable {
        case ms(Int)
        case timeout

        public var text: String {
            switch self {
            case .ms(let value): return "\(value)ms"
            case .timeout: return "超时"
            }
        }
    }

    @Published public private(set) var results: [UUID: Probe] = [:]

    public var interval: TimeInterval = 60
    private static let maxConcurrent = 8
    private static let probeTimeout: TimeInterval = 4

    private var loopTask: Task<Void, Never>?
    private var snapshots: [HostSnapshot] = []

    public init() {}

    /// 主机目录变化时更新探测集合；新增的主机立即补测
    public func updateHosts(_ hosts: [HostSnapshot]) {
        snapshots = hosts
        let ids = Set(hosts.map(\.id))
        results = results.filter { ids.contains($0.key) }
        let unknown = hosts.filter { results[$0.id] == nil }
        guard !unknown.isEmpty else { return }
        Task { await probe(unknown) }
    }

    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.probe(self.snapshots)
                try? await Task.sleep(for: .seconds(self.interval))
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// 手动触发一轮（下拉刷新类场景）
    public func refreshNow() {
        let targets = snapshots
        guard !targets.isEmpty else { return }
        Task { await probe(targets) }
    }

    private func probe(_ targets: [HostSnapshot]) async {
        // 限并发分批，避免 18 台同时 connect 触发防火墙行为
        var index = 0
        while index < targets.count {
            let chunk = targets[index ..< min(index + Self.maxConcurrent, targets.count)]
            index += Self.maxConcurrent
            let batch = await withTaskGroup(of: (UUID, Probe).self) { group in
                for host in chunk {
                    group.addTask {
                        let started = Date()
                        let reachable = await Self.tcpConnect(
                            host: host.probeHost, port: host.probePort,
                            timeout: Self.probeTimeout
                        )
                        let rtt = Int(Date().timeIntervalSince(started) * 1000)
                        return (host.id, reachable ? .ms(rtt) : .timeout)
                    }
                }
                var collected: [(UUID, Probe)] = []
                for await pair in group { collected.append(pair) }
                return collected
            }
            for (id, probe) in batch { results[id] = probe }
        }
    }

    /// 单次 TCP 连接探测（NWConnection，带超时；回调与超时同队列串行防双 resume）
    nonisolated private static func tcpConnect(host: String, port: Int, timeout: TimeInterval) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }
        return await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "termhub.latency.probe")
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            var finished = false
            func finish(_ value: Bool) {
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
            connection.start(queue: queue)
        }
    }
}

extension HostSnapshot {
    /// 探测目标：HTTP 代理主机测代理入口，其余测 SSH 端口
    public var probeHost: String {
        proxyType == .http ? (proxyHost ?? hostname) : hostname
    }

    public var probePort: Int {
        proxyType == .http ? (proxyPort ?? port) : port
    }
}
