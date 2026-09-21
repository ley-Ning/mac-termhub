import Foundation

/// 远端进程行（ps aux 口径）
public struct RemoteProcess: Identifiable, Hashable, Sendable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let user: String
    public let cpuPercent: Double
    public let memPercent: Double
    /// 常驻内存（KB）
    public let rssKB: Int64
    public let stat: String
    /// 累计 CPU 时间（TIME 列）
    public let time: String
    public let command: String

    public var rssText: String {
        ByteCountFormatter.string(fromByteCount: rssKB * 1024, countStyle: .memory)
    }
}

/// 监听端口行（ss -tlnp / netstat -tlnp 口径）
public struct ListenPort: Identifiable, Hashable, Sendable {
    public var id: String { "\(proto)|\(localAddress)|\(port)" }
    public let proto: String
    /// 本地绑定地址（*:22 / 0.0.0.0 / [::] 等，不含端口）
    public let localAddress: String
    public let port: Int
    /// "进程名(PID)"；非 root 下他人进程为 nil（ss 显示 -，属正常现象）
    public let process: String?
}

/// 进程/端口采集命令与本地解析（一次 exec 拿全部原始数据）
public enum ProcessParser {
    /// 采集命令：ps aux 全量拿回本地排序截断；监听端口优先 ss，为空回退 netstat
    public static let command = """
    echo '=PS='; ps aux 2>/dev/null; \
    echo '=LISTEN='; listen=$(ss -tlnp 2>/dev/null); \
    if [ -n "$listen" ]; then printf '%s\\n' "$listen"; else netstat -tlnp 2>/dev/null; fi
    """

    /// 进程列表上限（按 CPU 排序后截断，避免超长输出拖慢解析）
    public static let processLimit = 200

    /// =X= 分段（与 ServerStatsParser 相同约定）
    static func sections(of output: String) -> [String: String] {
        var result: [String: String] = [:]
        var current = ""
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if text.hasPrefix("="), text.hasSuffix("="), text.count > 2, !text.contains(" ") {
                current = String(text.dropFirst().dropLast())
                result[current] = ""
            } else if !current.isEmpty {
                result[current, default: ""].append(text + "\n")
            }
        }
        return result
    }

    /// 解析 ps aux：按 %CPU 降序（并列看 %MEM），截断 processLimit 行
    public static func parseProcesses(output: String) -> [RemoteProcess] {
        var processes: [RemoteProcess] = []
        for line in (sections(of: output)["PS"] ?? "").split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            // USER PID %CPU %MEM VSZ RSS TTY STAT START TIME COMMAND...
            guard parts.count >= 11 else { continue }
            guard let pid = Int32(parts[1]) else { continue }
            let command = parts[10...].joined(separator: " ")
            // 表头行（USER PID ...）已因 PID 非数字被跳过
            processes.append(RemoteProcess(
                pid: pid,
                user: String(parts[0]),
                cpuPercent: Double(parts[2]) ?? 0,
                memPercent: Double(parts[3]) ?? 0,
                rssKB: Int64(parts[5]) ?? 0,
                stat: String(parts[7]),
                time: String(parts[9]),
                command: command
            ))
        }
        processes.sort {
            if $0.cpuPercent != $1.cpuPercent { return $0.cpuPercent > $1.cpuPercent }
            return $0.memPercent > $1.memPercent
        }
        if processes.count > processLimit {
            processes.removeLast(processes.count - processLimit)
        }
        return processes
    }

    /// 解析监听端口（ss -tlnp 与 netstat -tlnp 两种行格式）
    public static func parseListenPorts(output: String) -> [ListenPort] {
        var ports: [ListenPort] = []
        for line in (sections(of: output)["LISTEN"] ?? "").split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 4 else { continue }

            let proto: String
            let localField: String
            var processField: String?
            if parts[0] == "tcp" || parts[0] == "tcp6" || parts[0] == "udp" || parts[0] == "udp6" {
                // netstat：Proto Recv-Q Send-Q Local Foreign State PID/Program name
                //（程序名可含空格/斜杠，从第一个 "数字/" 字段起整体取）
                proto = String(parts[0])
                localField = String(parts[3])
                if let startIndex = parts.indices.dropFirst(4).first(where: {
                    parts[$0].first?.isNumber == true && parts[$0].contains("/")
                }) {
                    processField = parts[startIndex...].joined(separator: " ")
                }
            } else {
                // ss：State Recv-Q Send-Q Local:Port Peer:Port [users:(("name",pid=N,fd=N))]
                proto = "tcp"
                localField = String(parts[3])
                if parts.count >= 6 {
                    processField = String(parts[5])
                }
            }

            guard let splitIndex = localField.lastIndex(of: ":") else { continue }
            let addressPart = String(localField[localField.startIndex..<splitIndex])
            guard let port = Int(localField[localField.index(after: splitIndex)...]) else { continue }
            // 去掉 IPv6 方括号展示
            let address = addressPart.hasPrefix("[") && addressPart.hasSuffix("]")
                ? String(addressPart.dropFirst().dropLast())
                : (addressPart.isEmpty ? "*" : addressPart)

            ports.append(ListenPort(
                proto: proto,
                localAddress: address,
                port: port,
                process: parseProcessField(processField)
            ))
        }
        ports.sort {
            if $0.port != $1.port { return $0.port < $1.port }
            return $0.localAddress < $1.localAddress
        }
        return ports
    }

    /// 进程列归一化为 "name(pid)"：
    /// ss：users:(("sshd",pid=1234,fd=3))；netstat：1234/sshd；无权限时 "-" -> nil
    static func parseProcessField(_ field: String?) -> String? {
        guard let field, !field.isEmpty, field != "-", field != "users:(())" else { return nil }
        // ss 格式
        if field.contains("pid=") {
            let namePart: String?
            if let openQuote = field.firstIndex(of: "\""),
               let closeQuote = field[openQuote...].dropFirst().firstIndex(of: "\"") {
                namePart = String(field[field.index(after: openQuote)..<closeQuote])
            } else {
                namePart = nil
            }
            let pidPart = field
                .split(separator: ",")
                .first(where: { $0.hasPrefix("pid=") })
                .map { String($0.dropFirst("pid=".count)) }
            switch (namePart, pidPart) {
            case let (name?, pid?):
                return "\(name)(\(pid))"
            case let (name?, nil):
                return name
            case let (nil, pid?):
                return "pid \(pid)"
            default:
                return nil
            }
        }
        // netstat 格式：1234/program name（名字可含空格；"-" 无权限）
        guard let slash = field.firstIndex(of: "/") else { return nil }
        let pidPart = String(field[field.startIndex..<slash])
        let namePart = String(field[field.index(after: slash)...]).trimmingCharacters(in: .whitespaces)
        guard let pid = Int32(pidPart), !namePart.isEmpty else { return nil }
        return "\(namePart)(\(pid))"
    }
}

/// 进程/端口监控服务：一次 exec 采集 + 可选轮询 + kill 操作
@MainActor
public final class ProcessService: ObservableObject {
    @Published public private(set) var processes: [RemoteProcess] = []
    @Published public private(set) var listenPorts: [ListenPort] = []
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var lastError: String?

    public let ssh: SSHSession
    private var pollTask: Task<Void, Never>?
    public private(set) var pollInterval: TimeInterval = 5

    public init(ssh: SSHSession) {
        self.ssh = ssh
    }

    // MARK: - 轮询（模式与 DockerService 一致）

    public func startPolling() {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.ssh.phase.isAlive {
                    await self.refresh()
                } else {
                    self.stopPolling()
                    return
                }
                try? await Task.sleep(for: .seconds(self.pollInterval))
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - 采集

    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let output = try await ssh.exec(ProcessParser.command)
            processes = ProcessParser.parseProcesses(output: output)
            listenPorts = ProcessParser.parseListenPorts(output: output)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - 进程操作

    /// 结束进程（force=kill -9）。成功后刷新列表。
    public func kill(pid: Int32, force: Bool) async {
        do {
            _ = try await ssh.exec(force ? "kill -9 \(pid)" : "kill \(pid)")
            try? await Task.sleep(for: .milliseconds(300))   // 留给内核回收
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }
}
