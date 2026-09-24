// termhub-mcp：TermHub 的 MCP 服务器（stdio / JSON-RPC 2.0）
//
// 安全模型（硬约束）：
// 1. 密码/口令只存 macOS Keychain，仅在建连瞬间读取；任何工具的返回结构中不存在凭据字段
// 2. 只连接已在 TermHub GUI 完成指纹信任（known_hosts）的主机；未知指纹一律拒绝
// 3. docker_logs 的 grep 在本地过滤、container 名做白名单校验，避免把 AI 输入拼进 shell
// 4. 未来的 token 等机密一律走环境变量，不落配置文件
import Foundation
import SwiftData
import Citadel
import TermHubCore

// MARK: - IO

let input = FileHandle.standardInput
let output = FileHandle.standardOutput
let debugEnabled = ProcessInfo.processInfo.environment["TERMHUB_MCP_DEBUG"] == "1"

func debugLog(_ message: String) {
    guard debugEnabled else { return }
    FileHandle.standardError.write(Data(("[termhub-mcp] \(message)\n").utf8))
}

func send(_ payload: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
          let line = String(data: data, encoding: .utf8) else { return }
    debugLog("-> \(line.prefix(300))")
    output.write(Data((line + "\n").utf8))
}

func sendResult(id: Any?, result: [String: Any]) {
    send(["jsonrpc": "2.0", "id": id ?? 0, "result": result])
}

func sendError(id: Any?, code: Int, message: String) {
    send(["jsonrpc": "2.0", "id": id ?? 0, "error": ["code": code, "message": message]])
}

func toolResponse(_ text: String, isError: Bool = false) -> [String: Any] {
    var result: [String: Any] = ["content": [["type": "text", "text": text]]]
    if isError { result["isError"] = true }
    return result
}

// MARK: - 主机库（共享 SwiftData，只读）

final class HostDirectory {
    private let context: ModelContext

    init() throws {
        let container = try AppStorage.makeSharedContainer()
        self.context = ModelContext(container)
        self.context.autosaveEnabled = false
    }

    /// 返回全部主机快照（不含任何凭据）
    func allHosts() -> [HostSnapshot] {
        let hosts = (try? context.fetch(FetchDescriptor<SSHHost>())) ?? []
        return hosts.map { $0.snapshot }
    }

    func find(alias: String) -> HostSnapshot? {
        allHosts().first { $0.alias == alias || $0.alias.localizedCaseInsensitiveCompare(alias) == .orderedSame }
    }
}

// MARK: - 连接管理（按别名缓存，进程退出即断开）

final class ConnectionPool {
    private var clients: [String: SSHClient] = [:]
    private let directory: HostDirectory

    init(directory: HostDirectory) {
        self.directory = directory
    }

    func client(alias: String) async throws -> SSHClient {
        if let cached = clients[alias], cached.isConnected {
            return cached
        }
        guard let snapshot = directory.find(alias: alias) else {
            throw MCPError.hostNotFound(alias)
        }
        // 安全约束：仅连接已信任过指纹的主机；未知指纹拒绝（提示先在 GUI 连一次）
        guard SharedKnownHosts.store.record(for: snapshot.hostname, port: snapshot.port) != nil else {
            throw MCPError.hostKeyNotTrusted(snapshot.alias, snapshot.hostname)
        }
        let client = try await SSHConnectionFactory.connect(to: snapshot) { facts in
            FileHandle.standardError.write(Data(("[termhub-mcp] 拒绝未知指纹 host=\(facts.host) fp=\(facts.fingerprint)\n").utf8))
            return false
        }.client
        clients[alias] = client
        return client
    }
}

enum MCPError: LocalizedError {
    case hostNotFound(String)
    case hostKeyNotTrusted(String, String)
    case badParameter(String)

    var errorDescription: String? {
        switch self {
        case .hostNotFound(let alias):
            return "找不到别名对应的主机：\(alias)。用 list_hosts 查看已配置主机（需先在 TermHub App 里添加）。"
        case .hostKeyNotTrusted(let alias, let hostname):
            return "主机 \(alias)（\(hostname)）的指纹尚未信任。请先在 TermHub App 里连接一次并在指纹确认框选择“信任”，MCP 出于安全考虑不会自动信任新指纹。"
        case .badParameter(let reason):
            return "参数不合法：\(reason)"
        }
    }
}

// MARK: - 工具定义

func toolDefinitions() -> [[String: Any]] {
    [
        [
            "name": "list_hosts",
            "description": "列出 TermHub 中已配置的服务器（别名、地址、用户、认证方式、分组、备注；不包含任何凭据）",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any], "required": [] as [String]],
        ],
        [
            "name": "exec",
            "description": "在指定主机上远程执行 shell 命令，返回 stdout/stderr 合并文本",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "host": ["type": "string", "description": "主机别名（见 list_hosts）"],
                    "command": ["type": "string", "description": "要执行的 shell 命令"],
                    "timeoutSeconds": ["type": "integer", "description": "可选，远端 timeout 包裹的超时秒数"],
                ] as [String: Any],
                "required": ["host", "command"],
            ],
        ],
        [
            "name": "docker_status",
            "description": "查看主机上全部 Docker 容器状态（名称/镜像/状态/端口）",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "host": ["type": "string", "description": "主机别名"],
                ] as [String: Any],
                "required": ["host"],
            ],
        ],
        [
            "name": "server_stats",
            "description": "查看主机系统资源：CPU/内存/Swap/磁盘/负载/运行时长/网络速率（一次采样）",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "host": ["type": "string", "description": "主机别名"],
                ] as [String: Any],
                "required": ["host"],
            ],
        ],
        [
            "name": "docker_logs",
            "description": "查看容器日志（本地过滤，不向远端拼接用户输入）",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "host": ["type": "string", "description": "主机别名"],
                    "container": ["type": "string", "description": "容器名或 ID（仅允许字母数字 _ . -）"],
                    "lines": ["type": "integer", "description": "尾部行数，默认 100"],
                    "grep": ["type": "string", "description": "可选，本地按子串过滤（大小写不敏感）"],
                ] as [String: Any],
                "required": ["host", "container"],
            ],
        ],
    ]
}

// MARK: - 工具执行

// 凭据入口已收敛到 GUI 加密库：--set-password 已按设计移除（密码只在 GUI 录入）

// MCP 凭据通道：GUI 已解锁时经本机 socket 取单条凭据；未运行/锁定时连接报解锁指引
CredentialBridge.provider = { hostID, kind in
    VaultCredentialClient.fetch(hostID: hostID, kind: kind)
}

let directory: HostDirectory
do {
    directory = try HostDirectory()
} catch {
    FileHandle.standardError.write(Data(("无法打开主机库：\(error.localizedDescription)\n").utf8))
    exit(1)
}
let pool = ConnectionPool(directory: directory)

func runTool(_ name: String, _ arguments: [String: Any], id: Any?) async {
    do {
        let result: [String: Any]
        switch name {
        case "list_hosts":
            result = toolResponse(listHostsText())
        case "exec":
            result = try await execTool(arguments)
        case "docker_status":
            result = try await dockerStatusTool(arguments)
        case "docker_logs":
            result = try await dockerLogsTool(arguments)
        case "server_stats":
            result = try await serverStatsTool(arguments)
        default:
            sendError(id: id, code: -32602, message: "未知工具：\(name)")
            return
        }
        sendResult(id: id, result: result)
    } catch let mcpError as MCPError {
        sendResult(id: id, result: toolResponse(mcpError.errorDescription ?? "错误", isError: true))
    } catch {
        sendResult(id: id, result: toolResponse(error.localizedDescription, isError: true))
    }
}

func requireString(_ arguments: [String: Any], _ key: String) throws -> String {
    guard let value = arguments[key] as? String, !value.isEmpty else {
        throw MCPError.badParameter("缺少字符串参数 \(key)")
    }
    return value
}

func listHostsText() -> String {
    let hosts = directory.allHosts()
    guard !hosts.isEmpty else {
        return "（没有已配置的主机。请先在 TermHub App 里添加服务器，MCP 不提供添加/修改入口以保护凭据。）"
    }
    return hosts.map { host in
        let auth = host.authMethod == .key ? "私钥" : "密码"
        let keyNote = host.authMethod == .key ? " key=\(host.keyPath ?? "")" : ""
        return "- \(host.alias)：\(host.username)@\(host.displayAddress) [\(auth)] 分组=\(host.groupName)\(keyNote)\(host.notes.isEmpty ? "" : " 备注：\(host.notes)")"
    }.joined(separator: "\n")
}

func execTool(_ arguments: [String: Any]) async throws -> [String: Any] {
    let alias = try requireString(arguments, "host")
    let command = try requireString(arguments, "command")
    let timeoutSeconds = arguments["timeoutSeconds"] as? Int

    let client = try await pool.client(alias: alias)
    let finalCommand: String
    if let timeoutSeconds, timeoutSeconds > 0 {
        finalCommand = "timeout \(timeoutSeconds) sh -c " + shellQuoted(command)
    } else {
        finalCommand = command
    }
    let buffer = try await client.executeCommand(finalCommand, mergeStreams: true)
    let text = String(buffer: buffer)
    return toolResponse(text.isEmpty ? "（无输出）" : text)
}

func shellQuoted(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func dockerStatusTool(_ arguments: [String: Any]) async throws -> [String: Any] {
    let alias = try requireString(arguments, "host")
    let client = try await pool.client(alias: alias)
    let output = String(buffer: try await client.executeCommand(
        "docker ps -a --format '{{json .}}' 2>&1 | head -100"
    ))
    let containers = DockerService.decodeLines(DockerContainer.self, from: output)
    guard !containers.isEmpty else {
        return toolResponse(output.isEmpty ? "（没有容器）" : output)
    }
    let lines = containers.map { c in
        "- \(c.displayName)\n  镜像: \(c.image)\n  状态: \(c.status)（\(c.state)）\n  端口: \(c.ports.isEmpty ? "—" : c.ports)"
    }
    return toolResponse(lines.joined(separator: "\n"))
}

func serverStatsTool(_ arguments: [String: Any]) async throws -> [String: Any] {
    let alias = try requireString(arguments, "host")
    let client = try await pool.client(alias: alias)
    let output = String(buffer: try await client.executeCommand(ServerStatsParser.command, mergeStreams: true))
    let parsed = ServerStatsParser.parse(output: output, previous: nil)
    let s = parsed.stats
    var lines: [String] = []
    lines.append("运行时长: \(s.uptimeText)  负载: \(String(format: "%.2f %.2f %.2f", s.loadAvg1, s.loadAvg5, s.loadAvg15))")
    let memFormatter = ByteCountFormatter(); memFormatter.countStyle = .memory
    lines.append("内存: \(memFormatter.string(fromByteCount: s.memUsedBytes)) / \(memFormatter.string(fromByteCount: s.memTotalBytes))（\(String(format: "%.0f%%", s.memPercent))）")
    if s.swapTotalBytes > 0 {
        lines.append("Swap: \(memFormatter.string(fromByteCount: s.swapUsedBytes)) / \(memFormatter.string(fromByteCount: s.swapTotalBytes))")
    }
    lines.append("CPU: 单次采样无法计算占用率（需两次采样求差，GUI 资源页可看实时曲线）")
    for disk in s.disks.prefix(12) {
        lines.append("磁盘 \(disk.mount): \(memFormatter.string(fromByteCount: disk.usedBytes)) / \(memFormatter.string(fromByteCount: disk.totalBytes))（\(String(format: "%.0f%%", disk.usedPercent))）")
    }
    return toolResponse(lines.joined(separator: "\n"))
}

func dockerLogsTool(_ arguments: [String: Any]) async throws -> [String: Any] {
    let alias = try requireString(arguments, "host")
    let container = try requireString(arguments, "container")
    // 白名单：容器名/ID 只允许字母数字 _ . -，防止把 AI 输入拼进远端 shell
    guard container.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else {
        throw MCPError.badParameter("container 仅允许字母数字与 _ . - 字符")
    }
    let lines = min(max((arguments["lines"] as? Int) ?? 100, 1), 2000)
    let grep = arguments["grep"] as? String

    let client = try await pool.client(alias: alias)
    let output = String(buffer: try await client.executeCommand(
        "docker logs --tail \(lines) \(container) 2>&1"
    ))
    var result = output
    if let grep, !grep.isEmpty {
        result = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.range(of: grep, options: .caseInsensitive) != nil }
            .joined(separator: "\n")
    }
    return toolResponse(result.isEmpty ? "（无匹配日志）" : result)
}

// MARK: - JSON-RPC 主循环

var protocolVersion = "2025-06-18"

func handleMessage(_ message: [String: Any]) async {
    let method = message["method"] as? String ?? ""
    let id = message["id"]

    // notification（无 id）不回包
    let isNotification = id == nil && !method.isEmpty

    switch method {
    case "initialize":
        if let params = message["params"] as? [String: Any],
           let requested = params["protocolVersion"] as? String {
            protocolVersion = requested
        }
        sendResult(id: id, result: [
            "protocolVersion": protocolVersion,
            "capabilities": ["tools": ["listChanged": false]] as [String: Any],
            "serverInfo": ["name": "termhub", "version": "0.1.0"] as [String: Any],
        ])

    case "notifications/initialized", "notifications/cancelled":
        break

    case "ping":
        sendResult(id: id, result: [:])

    case "tools/list":
        sendResult(id: id, result: ["tools": toolDefinitions()])

    case "tools/call":
        guard let params = message["params"] as? [String: Any],
              let name = params["name"] as? String else {
            sendError(id: id, code: -32602, message: "tools/call 参数错误")
            return
        }
        let arguments = (params["arguments"] as? [String: Any]) ?? [:]
        await runTool(name, arguments, id: id)

    default:
        if !isNotification {
            sendError(id: id, code: -32601, message: "未知方法：\(method)")
        }
    }
}

// 逐行读取 stdin（newline-delimited JSON），顶层 await 串行处理保证连接缓存一致
while let line = readLine() {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { continue }
    guard let message = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else {
        debugLog("忽略无法解析的行：\(trimmed.prefix(120))")
        continue
    }
    debugLog("<- \(trimmed.prefix(200))")
    await handleMessage(message)
}

exit(0)
