import Foundation

/// 一次采样的服务器资源数据
public struct ServerStats: Sendable, Equatable {
    public struct DiskUsage: Sendable, Equatable, Identifiable {
        public var id: String { mount }
        public let filesystem: String
        public let mount: String
        public let totalBytes: Int64
        public let usedBytes: Int64

        public var usedPercent: Double {
            totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) * 100 : 0
        }
    }

    public var loadAvg1 = 0.0
    public var loadAvg5 = 0.0
    public var loadAvg15 = 0.0
    public var cpuPercent: Double?          // 需要两次采样才有值
    public var memTotalBytes: Int64 = 0
    public var memAvailableBytes: Int64 = 0
    public var memUsedBytes: Int64 = 0      // total - available（与 top/h一致的口径）
    public var swapTotalBytes: Int64 = 0
    public var swapUsedBytes: Int64 = 0
    public var disks: [DiskUsage] = []

    /// 单块物理盘的 I/O 指标（iostat 口径，两次采样求差）
    public struct DiskIO: Sendable, Equatable, Identifiable {
        public var id: String { device }
        public let device: String
        public let readsPerSec: Double
        public let writesPerSec: Double
        public let readBytesPerSec: Double
        public let writeBytesPerSec: Double
        public let awaitMs: Double?       // 每次 I/O 平均耗时（读+写合计）
        public let utilPercent: Double?   // 采样期内设备繁忙比例
    }
    public var diskIO: [DiskIO] = []
    public var netRxBytesPerSec: Double?    // 需要两次采样
    public var netTxBytesPerSec: Double?
    public var uptimeSeconds: Double = 0

    public var memPercent: Double {
        memTotalBytes > 0 ? Double(memUsedBytes) / Double(memTotalBytes) * 100 : 0
    }

    public var uptimeText: String {
        let seconds = Int(uptimeSeconds)
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        return "\(minutes) 分钟"
    }
}

/// 采样命令与解析（一次 exec 拿全部原始数据，本地解析）
public enum ServerStatsParser {
    /// 远端执行的采集命令（标记分段，一条 exec 全拿回来）
    public static let command = """
    echo '=LOAD='; cat /proc/loadavg 2>/dev/null; \
    echo '=CPU='; grep '^cpu ' /proc/stat 2>/dev/null; \
    echo '=MEM='; free -b 2>/dev/null | grep -E '^(Mem|Swap)'; \
    echo '=DISK='; df -P -B1 -x tmpfs -x devtmpfs 2>/dev/null | tail -n +2; \
    echo '=NET='; cat /proc/net/dev 2>/dev/null | tail -n +3; \
    echo '=DISKIO='; cat /proc/diskstats 2>/dev/null; \
    echo '=UP='; cat /proc/uptime 2>/dev/null
    """

    /// 上一次的原始计数（用于 CPU/网络/磁盘增量）
    public struct DiskCounters: Sendable {
        let reads: UInt64
        let sectorsRead: UInt64
        let msReading: UInt64
        let writes: UInt64
        let sectorsWritten: UInt64
        let msWriting: UInt64
        let msDoingIO: UInt64
    }

    public struct PreviousSample: Sendable {
        let cpuJiffies: [UInt64]
        let netBytes: (rx: UInt64, tx: UInt64)
        let diskCounters: [String: DiskCounters]
        let at: Date
    }

    /// 整盘过滤：保留 sdX/vdX/xvdX/nvmeXnY/mmcblkX，排除分区、loop、ram、dm、md
    static func isWholeDisk(_ name: String) -> Bool {
        for prefix in ["loop", "ram", "dm-", "md", "sr", "fd"] where name.hasPrefix(prefix) { return false }
        if name.hasPrefix("nvme") || name.hasPrefix("mmcblk") { return !name.contains("p") }
        if let last = name.last, last.isNumber { return false }   // sda1 之类分区
        return true
    }

    public static func parse(
        output: String,
        previous: PreviousSample?,
        now: Date = Date()
    ) -> (stats: ServerStats, sample: PreviousSample) {
        var stats = ServerStats()
        var sections: [String: String] = [:]
        var currentSection = ""
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            // 分段标记形如 =LOAD=（echo '=X=' 的输出，引号是 shell 层的）
            if text.hasPrefix("="), text.hasSuffix("="), text.count > 2, !text.contains(" ") {
                currentSection = String(text.dropFirst().dropLast())
                sections[currentSection] = ""
            } else if !currentSection.isEmpty {
                sections[currentSection, default: ""].append(text + "\n")
            }
        }

        // 负载
        if let loadLine = sections["LOAD"]?.split(separator: "\n").first {
            let parts = loadLine.split(separator: " ")
            if parts.count >= 3 {
                stats.loadAvg1 = Double(parts[0]) ?? 0
                stats.loadAvg5 = Double(parts[1]) ?? 0
                stats.loadAvg15 = Double(parts[2]) ?? 0
            }
        }

        // CPU（jiffies 累计值，两次采样求差）
        var cpuJiffies: [UInt64] = []
        if let cpuLine = sections["CPU"]?.split(separator: "\n").first {
            cpuJiffies = cpuLine.split(separator: " ").dropFirst().compactMap { UInt64($0) }
        }
        if let previous, previous.cpuJiffies.count == cpuJiffies.count, cpuJiffies.count >= 4 {
            let deltaTotal = zip(cpuJiffies, previous.cpuJiffies).reduce(0) { $0 + ($1.0 - $1.1) }
            let deltaIdle = (cpuJiffies[3] - previous.cpuJiffies[3])
            if deltaTotal > 0 {
                stats.cpuPercent = (1.0 - Double(deltaIdle) / Double(deltaTotal)) * 100
            }
        }

        // 内存
        for line in sections["MEM"]?.split(separator: "\n") ?? [] {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3 else { continue }
            if parts[0] == "Mem:" {
                stats.memTotalBytes = Int64(parts[1]) ?? 0
                stats.memAvailableBytes = parts.count >= 7 ? (Int64(parts[6]) ?? 0) : (Int64(parts[3]) ?? 0)
                stats.memUsedBytes = max(0, stats.memTotalBytes - stats.memAvailableBytes)
            } else if parts[0] == "Swap:" {
                stats.swapTotalBytes = Int64(parts[1]) ?? 0
                stats.swapUsedBytes = Int64(parts[2]) ?? 0
            }
        }

        // 磁盘（过滤容器 overlay / snap 循环 / 引导分区）
        for line in sections["DISK"]?.split(separator: "\n") ?? [] {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 6 else { continue }
            let filesystem = String(parts[0])
            let total = Int64(parts[1]) ?? 0
            let used = Int64(parts[2]) ?? 0
            let mount = String(parts[5])
            guard total > 0 else { continue }
            // 按挂载点过滤容器/快照/引导等噪音挂载
            if mount.hasPrefix("/var/lib/docker") || mount.hasPrefix("/snap") { continue }
            if mount == "/boot" || mount == "/boot/efi" || mount.hasPrefix("/run") { continue }
            if filesystem.contains("://") || filesystem.hasPrefix("overlay") { continue }
            stats.disks.append(.init(filesystem: filesystem, mount: mount, totalBytes: total, usedBytes: used))
        }
        stats.disks.sort { $0.totalBytes > $1.totalBytes }

        // 网络（排除 lo，汇总 rx/tx 字节；两次采样求速率）
        var rxTotal: UInt64 = 0
        var txTotal: UInt64 = 0
        for line in sections["NET"]?.split(separator: "\n") ?? [] {
            guard line.contains(":") else { continue }
            let name = String(line.split(separator: ":")[0]).trimmingCharacters(in: .whitespaces)
            guard name != "lo", !name.hasPrefix("docker"), !name.hasPrefix("veth"),
                  !name.hasPrefix("br-"), !name.hasPrefix("vibr") else { continue }
            let numbers = line.split(separator: ":")[1].split(separator: " ", omittingEmptySubsequences: true)
            guard numbers.count >= 9,
                  let rx = UInt64(numbers[0]),
                  let tx = UInt64(numbers[8]) else { continue }
            rxTotal += rx
            txTotal += tx
        }
        if let previous {
            let seconds = max(now.timeIntervalSince(previous.at), 0.5)
            stats.netRxBytesPerSec = Double(rxTotal &- previous.netBytes.rx) / seconds
            stats.netTxBytesPerSec = Double(txTotal &- previous.netBytes.tx) / seconds
        }

        // 磁盘 I/O（/proc/diskstats 增量：速率、IOPS、await、%util）
        var diskCounters: [String: DiskCounters] = [:]
        for line in sections["DISKIO"]?.split(separator: "\n") ?? [] {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            // major minor name rcm rm rs rms wcm wm ws wms iop msio wms
            guard parts.count >= 14 else { continue }
            let name = String(parts[2])
            guard Self.isWholeDisk(name),
                  let reads = UInt64(parts[3]), let sectorsRead = UInt64(parts[5]),
                  let msReading = UInt64(parts[6]),
                  let writes = UInt64(parts[7]), let sectorsWritten = UInt64(parts[9]),
                  let msWriting = UInt64(parts[10]),
                  let msDoingIO = UInt64(parts[12]) else { continue }
            diskCounters[name] = DiskCounters(
                reads: reads, sectorsRead: sectorsRead, msReading: msReading,
                writes: writes, sectorsWritten: sectorsWritten,
                msWriting: msWriting, msDoingIO: msDoingIO
            )
        }
        if let previous {
            let seconds = max(now.timeIntervalSince(previous.at), 0.5)
            for (name, c) in diskCounters {
                guard let prev = previous.diskCounters[name] else { continue }
                let dReads = c.reads &- prev.reads
                let dWrites = c.writes &- prev.writes
                let dIOs = dReads + dWrites
                var awaitMs: Double?
                if dIOs > 0 {
                    awaitMs = Double((c.msReading &- prev.msReading) + (c.msWriting &- prev.msWriting)) / Double(dIOs)
                }
                stats.diskIO.append(.init(
                    device: name,
                    readsPerSec: Double(dReads) / seconds,
                    writesPerSec: Double(dWrites) / seconds,
                    readBytesPerSec: Double((c.sectorsRead &- prev.sectorsRead)) * 512 / seconds,
                    writeBytesPerSec: Double((c.sectorsWritten &- prev.sectorsWritten)) * 512 / seconds,
                    awaitMs: awaitMs,
                    utilPercent: min(Double(c.msDoingIO &- prev.msDoingIO) / (seconds * 1000) * 100, 100)
                ))
            }
            stats.diskIO.sort { ($0.readBytesPerSec + $0.writeBytesPerSec) > ($1.readBytesPerSec + $1.writeBytesPerSec) }
        }

        // uptime
        if let upLine = sections["UP"]?.split(separator: " ").first {
            stats.uptimeSeconds = Double(upLine) ?? 0
        }

        return (stats, PreviousSample(cpuJiffies: cpuJiffies, netBytes: (rxTotal, txTotal), diskCounters: diskCounters, at: now))
    }
}

/// 资源监控服务：周期采样 + 历史曲线
@MainActor
public final class ServerStatsService: ObservableObject {
    @Published public private(set) var stats = ServerStats()
    @Published public private(set) var cpuHistory: [Double] = []     // 0-100
    @Published public private(set) var memHistory: [Double] = []     // 0-100
    @Published public private(set) var netRxHistory: [Double] = []   // bytes/s
    @Published public private(set) var netTxHistory: [Double] = []
    @Published public private(set) var lastError: String?
    @Published public private(set) var isRunning = false

    public var pollInterval: TimeInterval = 3
    public static let historyCapacity = 60

    public let ssh: SSHSession
    private var pollTask: Task<Void, Never>?
    private var previous: ServerStatsParser.PreviousSample?

    public init(ssh: SSHSession) {
        self.ssh = ssh
    }

    public func start() {
        guard !isRunning else { return }
        guard ssh.phase.isAlive else { return }
        isRunning = true
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.ssh.phase.isAlive {
                    await self.sampleOnce()
                } else {
                    self.stop()
                    return
                }
                try? await Task.sleep(for: .seconds(self.pollInterval))
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        isRunning = false
    }

    public func sampleOnce() async {
        do {
            let output = try await ssh.exec(ServerStatsParser.command)
            let result = ServerStatsParser.parse(output: output, previous: previous)
            previous = result.sample
            stats = result.stats
            lastError = nil

            if let cpu = result.stats.cpuPercent {
                cpuHistory.append(min(max(cpu, 0), 100))
                if cpuHistory.count > Self.historyCapacity { cpuHistory.removeFirst(cpuHistory.count - Self.historyCapacity) }
            }
            memHistory.append(result.stats.memPercent)
            if memHistory.count > Self.historyCapacity { memHistory.removeFirst(memHistory.count - Self.historyCapacity) }
            if let rx = result.stats.netRxBytesPerSec {
                netRxHistory.append(rx)
                if netRxHistory.count > Self.historyCapacity { netRxHistory.removeFirst(netRxHistory.count - Self.historyCapacity) }
            }
            if let tx = result.stats.netTxBytesPerSec {
                netTxHistory.append(tx)
                if netTxHistory.count > Self.historyCapacity { netTxHistory.removeFirst(netTxHistory.count - Self.historyCapacity) }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 重连后清空历史
    public func reset() {
        previous = nil
        stats = ServerStats()
        cpuHistory = []
        memHistory = []
        netRxHistory = []
        netTxHistory = []
    }
}
