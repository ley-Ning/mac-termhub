// TermHubSmoke：对真实服务器验证 Core 层（连接 / exec / docker / SFTP）
// 用法：swift run TermHubSmoke [host] [user] [keyPath] [--password-stdin]
//       TermHubSmoke --seed  向共享库种入 root@163（MCP 端到端测试用）
//       TermHubSmoke --import <file.json|-stdin路径"-"时从标准输入读，密码不落盘>
//       TermHubSmoke --security-audit  审计：凭据仅存在于钥匙串、无明文落盘
import TermHubCore
import Citadel
import Crypto
import Logging
import SwiftData
import Foundation

// 打开底层日志，观察握手/认证过程
struct PrintHandler: LogHandler {
    let label: String
    var logLevel: Logger.Level = .info
    var metadata = Logger.Metadata()
    subscript(metadataKey _: String) -> Logger.Metadata.Value? {
        get { nil }
        set { _ = newValue }
    }
    func log(level: Logger.Level, message: Logger.Message, metadata _: Logger.Metadata?, source _: String, file _: String, function _: String, line _: UInt) {
        print("[\(level)] \(message)")
    }
}

let verbose = CommandLine.arguments.contains { $0 == "-v" || $0 == "--verbose" }
LoggingSystem.bootstrap { label in
    var handler = PrintHandler(label: label)
    handler.logLevel = verbose ? .trace : .info
    return handler
}

let rawArgs = Array(CommandLine.arguments.dropFirst())
let wantsStats = rawArgs.contains("--stats")
// 位置参数 = 去掉所有标志与"标志+值"对（--proxy h:p / --jump alias / --password x）
var args = rawArgs.filter { $0 != "-v" && $0 != "--verbose" && $0 != "--stats" && $0 != "--password-stdin" }
for flag in ["--proxy", "--jump", "--password", "--connect-only"] {
    if let i = args.firstIndex(of: flag), i + 1 < args.count {
        args.removeSubrange(i...i + 1)
    }
}

// --seed：把 root@163（密钥认证，不涉及任何 Keychain 凭据）写入共享库
if args.contains("--seed-cc26039") {
    do {
        let container = try AppStorage.makeSharedContainer()
        let context = ModelContext(container)
        let existing = try context.fetch(FetchDescriptor<SSHHost>())
        if existing.contains(where: { $0.alias == "cc26039-现场" }) {
            print("已存在别名 cc26039-现场，跳过")
        } else {
            let host = SSHHost(
                alias: "cc26039-现场",
                hostname: "ssh.cc26039.logistics.multiway-cloud.com",
                port: 22,
                username: "root",
                authMethod: .password,
                groupName: "客户现场",
                notes: "怡昊化工客户现场（HTTP 代理 7217）",
                proxyType: .http,
                proxyHost: "logistics.multiway-cloud.com",
                proxyPort: 7217
            )
            context.insert(host)
            try context.save()
            print("✅ 已种入主机 cc26039-现场（HTTP 代理）")
        }
        exit(0)
    } catch {
        print("❌ 种入失败：\(error.localizedDescription)")
        exit(1)
    }
}

// --import <file.json 或 "-">：批量导入主机（HexHub 等外部工具迁移）。
// JSON 数组，元素：alias/hostname/port/username/auth(password|key)/keyPath?/password?/group?/notes?/proxyHost?/proxyPort?
// 带 password 的敏感导入请用 "-"（stdin 管道），密码不落盘：cat hosts.json | TermHubSmoke --import -
if let importIndex = args.firstIndex(of: "--import"), importIndex + 1 < args.count {
    struct ImportHost: Codable {
        var alias: String
        var hostname: String
        var port: Int = 22
        var username: String
        var auth: String
        var keyPath: String?
        var password: String?
        var group: String?
        var notes: String?
        var proxyHost: String?
        var proxyPort: Int?
        var force: Bool?
    }
    do {
        let pathArg = args[args.index(after: importIndex)]
        let data: Data
        if pathArg == "-" {
            data = FileHandle.standardInput.readDataToEndOfFile()
        } else {
            data = try Data(contentsOf: URL(fileURLWithPath: pathArg))
        }
        let list = try JSONDecoder().decode([ImportHost].self, from: data)
        let carriesSecrets = list.contains { $0.password != nil || $0.keyPath != nil }
        let container = try AppStorage.makeSharedContainer()
        let context = ModelContext(container)
        let existing = try context.fetch(FetchDescriptor<SSHHost>())
        var imported = 0, skipped = 0
        for item in list {
            // 同别名 或 同 主机+端口+用户 视为重复
            let dupAlias = existing.contains { $0.alias == item.alias }
            let dupHost = existing.contains {
                $0.hostname == item.hostname && $0.port == item.port && $0.username == item.username
            }
            if (dupAlias || dupHost) && item.force != true {
                print("↩️ 跳过 \(item.alias)（已存在同别名或同 主机+用户；force=true 可强制）")
                skipped += 1
                continue
            }
            if dupAlias {
                print("⚠️ 存在同别名 \(item.alias)，仍按 force 导入")
            }
            let host = SSHHost(
                alias: item.alias,
                hostname: item.hostname,
                port: item.port,
                username: item.username,
                authMethod: item.auth == "key" ? .key : .password,
                keyPath: item.keyPath.map { NSString(string: $0).expandingTildeInPath },
                groupName: item.group ?? "导入",
                notes: item.notes ?? "",
                proxyType: item.proxyHost != nil ? .http : .none,
                proxyHost: item.proxyHost,
                proxyPort: item.proxyPort
            )
            context.insert(host)
            try context.save()
            if item.auth == "password", let password = item.password {
                try KeychainStore.save(password, kind: .password, hostID: host.id)
            }
            print("✅ 已导入 \(item.alias) -> \(item.username)@\(item.hostname)\(item.proxyHost.map { "（经 \($0)）" } ?? "")")
            imported += 1
        }
        print("导入完成：\(imported) 台，跳过 \(skipped) 台（库：\(AppStorage.sharedStoreURL.path)）")
        if pathArg != "-" && carriesSecrets {
            print("⚠️ 本次导入文件含密码明文且走了磁盘文件。建议：cat file.json | TermHubSmoke --import -（stdin，不落盘），并立即删除该文件。")
        }
        exit(0)
    } catch {
        print("❌ 导入失败：\(error.localizedDescription)")
        exit(1)
    }
}

// --security-audit：证明"凭据仅存在于钥匙串"——把 Keychain 里每条密码/口令明文
// 拿去搜索所有落盘文件的字节（store/偏好/片段/known_hosts），命中即明文泄漏。
if args.contains("--security-audit") {
    do {
        let container = try AppStorage.makeSharedContainer()
        let context = ModelContext(container)
        let hosts = try context.fetch(FetchDescriptor<SSHHost>())

        // 待扫描的全部落盘文件（存在才扫）；store 的 WAL/SHM 也要扫——删除过的行字节会残留在里面
        let storePath = AppStorage.sharedStoreURL.path
        let candidates: [String] = [
            storePath,                                                                 storePath + "-wal",
            storePath + "-shm",
            AppStorage.supportDirectory.appending(path: "snippets.json").path,   // 命令片段
            AppStorage.supportDirectory.appending(path: "known_hosts.json").path,// TOFU 指纹
            NSHomeDirectory() + "/Library/Preferences/TermHub.plist",
            NSHomeDirectory() + "/Library/Preferences/com.termhub.app.plist",
        ]
        var targets: [(path: String, data: Data)] = []
        for path in candidates {
            if let data = FileManager.default.contents(atPath: path) {
                targets.append((path, data))
            }
        }

        var secretCount = 0
        var skippedShort = 0
        var leaks = 0
        print("开始读取钥匙串凭据（若钥匙串已锁，此处会等待解锁——在弹窗里输入登录密码即可）…")
        for host in hosts {
            for kind in [KeychainStore.SecretKind.password, .passphrase] {
                guard let secret = KeychainStore.read(kind: kind, hostID: host.id),
                      !secret.isEmpty else { continue }
                secretCount += 1
                // 短密码（<6 字符）作为子串会命中大量正常数据（如用户名 mw），字节搜索不可判，跳过
                guard secret.count >= 6 else {
                    skippedShort += 1
                    print("⊘ [\(host.alias)] 密码仅 \(secret.count) 字符，子串搜索不可判，跳过（凭据本身仍仅在钥匙串）")
                    continue
                }
                for target in targets where target.data.range(of: Data(secret.utf8)) != nil {
                    print("❌ 明文泄漏：[\(host.alias)] 的\(kind == .password ? "密码" : "私钥口令")出现在 \(target.path)")
                    leaks += 1
                }
            }
        }

        print("扫描文件：\(targets.map(\.path).joined(separator: "\n         "))")
        if secretCount == 0 {
            print("⚠️ 钥匙串中无凭据可审计（先在 GUI 保存至少一条密码）")
        } else if leaks == 0 {
            print("✅ 审计通过：\(secretCount) 条凭据仅存在于钥匙串，\(targets.count) 个落盘文件零明文命中\(skippedShort > 0 ? "（\(skippedShort) 条短密码除外，见上）" : "")")
        } else {
            print("❌ 审计失败：\(leaks) 处明文泄漏")
        }
        exit(leaks == 0 ? 0 : 1)
    } catch {
        print("❌ 审计失败：\(error.localizedDescription)")
        exit(1)
    }
}

// --sftp-list <host> <path> [user] [keyPath]：列目录条数+样本（诊断"文件不全"）
// --connect-only <host> [user] [keyPath]：纯连接计时（握手+认证，不做任何采样）
if let i = rawArgs.firstIndex(of: "--connect-only"), i + 1 < rawArgs.count {
    let target = rawArgs[rawArgs.index(after: i)]
    let user2 = i + 2 < rawArgs.count ? rawArgs[rawArgs.index(after: rawArgs.index(after: i))] : "root"
    let key2 = i + 3 < rawArgs.count ? rawArgs[i + 3] : NSString(string: "~/.ssh/id_ed25519").expandingTildeInPath
    let t0 = Date()
    do {
        let conn = try await SSHConnectionFactory.connect(
            to: HostSnapshot(
                id: UUID(), alias: "timing", hostname: target, port: 22, username: user2,
                authMethod: passwordOverride != nil ? .password : .key,
                keyPath: passwordOverride != nil ? nil : key2,
                groupName: "s", notes: ""
            ),
            hostKeyCallback: { facts in
                SharedKnownHosts.store.trust(host: facts.host, port: facts.port,
                                             fingerprintSHA256: facts.fingerprint, keyType: facts.keyType)
                return true
            },
            overridePassword: passwordOverride
        )
        try? await conn.client.close()
        print(String(format: "CONNECT %.2fs %@ success", Date().timeIntervalSince(t0), target))
        exit(0)
    } catch {
        print(String(format: "CONNECT %.2fs %@ failed: %@", Date().timeIntervalSince(t0), target, error.localizedDescription))
        exit(1)
    }
}

if let i = args.firstIndex(of: "--sftp-list"), i + 2 < args.count {
    let target = args[i + 1]
    let dirPath = args[i + 2]
    let user2 = i + 3 < args.count ? args[i + 3] : "root"
    let key2 = i + 4 < args.count ? args[i + 4] : NSString(string: "~/.ssh/id_ed25519").expandingTildeInPath
    do {
        let conn = try await SSHConnectionFactory.connect(
            to: HostSnapshot(
                id: UUID(), alias: "sftplist", hostname: target, port: 22, username: user2,
                authMethod: passwordOverride != nil ? .password : .key,
                keyPath: passwordOverride != nil ? nil : key2,
                groupName: "s", notes: ""
            ),
            hostKeyCallback: { facts in
                SharedKnownHosts.store.trust(host: facts.host, port: facts.port,
                                             fingerprintSHA256: facts.fingerprint, keyType: facts.keyType)
                return true
            },
            overridePassword: passwordOverride
        )
        let sftp = try await conn.client.openSFTP()
        let names = try await sftp.listDirectory(atPath: dirPath)
        var total = 0
        for batch in names { total += batch.components.count }
        print("条目总数(含 ./..): \(total)")
        for batch in names.prefix(3) {
            for c in batch.components.prefix(10) {
                print("  \(c.longname)")
            }
        }
        try? await conn.client.close()
        exit(0)
    } catch {
        print("❌ \(error.localizedDescription)")
        exit(1)
    }
}

if args.contains("--seed") {
    do {
        let container = try AppStorage.makeSharedContainer()
        let context = ModelContext(container)
        let existing = try context.fetch(FetchDescriptor<SSHHost>())
        if existing.contains(where: { $0.alias == "163" }) {
            print("已存在别名 163 的主机，跳过")
        } else {
            let host = SSHHost(
                alias: "163",
                hostname: "192.168.2.163",
                port: 22,
                username: "root",
                authMethod: .key,
                keyPath: NSString(string: "~/.ssh/id_ed25519").expandingTildeInPath,
                groupName: "内网",
                notes: "冒烟测试种入（root + id_ed25519）"
            )
            context.insert(host)
            try context.save()
            print("✅ 已种入主机 163 -> root@192.168.2.163（库：\(AppStorage.sharedStoreURL.path)）")
        }
        exit(0)
    } catch {
        print("❌ 种入失败：\(error.localizedDescription)")
        exit(1)
    }
}

let host = args.count > 0 ? args[0] : "192.168.2.163"
let user = args.count > 1 ? args[1] : "mw"
let keyPath = args.count > 2 ? args[2] : NSString(string: "~/.ssh/id_ed25519").expandingTildeInPath
// --password-stdin：从标准输入读密码（管道传递，不进 shell history / ps 进程列表）
if let i = rawArgs.firstIndex(of: "--password"), i + 1 < rawArgs.count {
    print("❌ --password <明文> 已禁用（命令行参数会留在 shell history 与 ps 输出里）。")
    print("   请改用：echo '密码' | TermHubSmoke … --password-stdin")
    exit(2)
}
let pwStdinIndex = args.firstIndex(of: "--password-stdin")
let passwordOverride: String? = {
    guard pwStdinIndex != nil else { return nil }
    let raw = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}()
// --proxy host:port 走 HTTP 代理连接（标志对已从位置参数摘除，从 rawArgs 取值）
let proxyIndex = rawArgs.firstIndex(of: "--proxy")
let proxyParts: (host: String, port: Int)? = {
    guard let i = proxyIndex, i + 1 < args.count else { return nil }
    let value = args[args.index(after: i)]
    let parts = value.split(separator: ":")
    guard parts.count == 2, let port = Int(parts[1]) else { return nil }
    return (String(parts[0]), port)
}()

// --stats-fixture：离线校验磁盘 I/O 解析数学（不连网）
if args.contains("--stats-fixture") {
    // 两拍 /proc/diskstats：间隔 2s 的理想数据
    // 字段: major minor name rcm rm rs rms wcm wm ws wms iop msio wms
    let t1 = """
    8       0 sda 1180 12 48000 960 220 5 12000 880 0 1780 1840
    259     0 nvme0n1 5000 30 200000 1500 900 8 60000 720 0 2100 2220
    7       0 loop0 10 0 80 2 0 0 0 0 0 2 2
    8       1 sda1 900 8 30000 700 200 4 11000 800 0 1400 1500
    """
    let t2 = """
    8       0 sda 1280 12 56000 1060 320 5 16000 1040 0 2040 2100
    259     0 nvme0n1 5400 30 232000 1620 1000 8 64000 780 0 2340 2400
    7       0 loop0 10 0 80 2 0 0 0 0 0 2 2
    8       1 sda1 980 8 36000 760 280 4 15000 940 0 1620 1700
    """
    func section(_ name: String, _ body: String) -> String { "=\(name)=\n\(body)" }
    let base = section("LOAD", "0.10 0.20 0.15 1/100 12345\n")
        + section("CPU", "cpu  100 0 50 850 0 0 0 0\n")
        + section("MEM", "Mem: 8000000000 1000000000 6500000000 0 500000000 400000000 100000000\n")
        + section("DISK", "/dev/sda 1000000000000 400000000000 600000000000 5% /\n")
        + section("NET", "  eth0: 1000000 800 0 0 0 0 0 0 500000 700 0 0 0 0 0 0\n")
        + section("UP", "86400.00 100000.00\n")
    let now = Date()
    let first = ServerStatsParser.parse(output: base + section("DISKIO", t1), previous: nil, now: now)
    let second = ServerStatsParser.parse(output: base + section("DISKIO", t2), previous: first.sample, now: now + 2)
    print("== 磁盘 I/O 解析夹具（间隔 2s）==")
    print("设备数: \(second.stats.diskIO.count)（应为 2：sda + nvme0n1；loop/sda1 被过滤）")
    for io in second.stats.diskIO {
        // sda 期望: 读 8000*512/2=2.0MB/s 写 4000*512/2=1.0MB/s IOPS r50/w50 await=(100+160)/100=2.6ms util=260/2000=13%
        print("  💿 \(io.device): 读\(String(format: "%.1f", io.readBytesPerSec/1024/1024))MB/s 写\(String(format: "%.1f", io.writeBytesPerSec/1024/1024))MB/s IOPS r\(Int(io.readsPerSec))/w\(Int(io.writesPerSec)) 耗时\(io.awaitMs.map { String(format: "%.2f", $0) } ?? "—")ms util=\(io.utilPercent.map { String(format: "%.0f%%", $0) } ?? "—")")
    }
    exit(0)
}

if wantsStats {
    // 用法：TermHubSmoke --stats [直连host user keyPath]
    //       --stats --proxy h:p --password-stdin（stdin 传密码） host user keyPath
    //       --stats --jump <已存库别名> ...（经库中该主机跳板转发，实机验证跳板链）
    do {
        print("== 资源采样解析验证 ==")
        // --jump <alias>：从共享库解析跳板链（沿 jumpHostID 逐级取，防环）
        var jumpSnapshots: [HostSnapshot] = []
        if let jumpIndex = rawArgs.firstIndex(of: "--jump"), jumpIndex + 1 < rawArgs.count {
            let jumpAlias = rawArgs[rawArgs.index(after: jumpIndex)]
            let container = try AppStorage.makeSharedContainer()
            let context = ModelContext(container)
            let all = try context.fetch(FetchDescriptor<SSHHost>())
            var visited: Set<UUID> = []
            var cursor = all.first { $0.alias == jumpAlias }
            while let hop = cursor, visited.insert(hop.id).inserted {
                jumpSnapshots.append(hop.snapshot)
                cursor = all.first { $0.id == hop.jumpHostID }
            }
            print("跳板链: \(jumpSnapshots.map(\.alias).joined(separator: " -> "))(-> 目标)")
        }
        let client = try await SSHConnectionFactory.connect(
            to: HostSnapshot(
                id: UUID(), alias: "stats", hostname: host, port: 22, username: user,
                authMethod: passwordOverride != nil ? .password : .key,
                keyPath: passwordOverride != nil ? nil : keyPath,
                groupName: "s", notes: "",
                proxyType: proxyParts != nil ? .http : .none,
                proxyHost: proxyParts?.host, proxyPort: proxyParts?.port
            ),
            hostKeyCallback: { facts in
                SharedKnownHosts.store.trust(host: facts.host, port: facts.port,
                                             fingerprintSHA256: facts.fingerprint, keyType: facts.keyType)
                return true
            },
            jumpHosts: jumpSnapshots,
            overridePassword: passwordOverride
        ).client
        var previous: ServerStatsParser.PreviousSample?
        for round in 1...2 {
            let output = String(buffer: try await client.executeCommand(ServerStatsParser.command))
            let result = ServerStatsParser.parse(output: output, previous: previous)
            previous = result.sample
            let s = result.stats
            print("第\(round)次: CPU=\(s.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—") 内存=\(s.memUsedBytes/1024/1024)MB/\(s.memTotalBytes/1024/1024)MB(\(Int(s.memPercent))%) 负载=\(s.loadAvg1) 磁盘=\(s.disks.count)个挂载 RX=\(s.netRxBytesPerSec.map { Int($0/1024) } ?? -1)KB/s uptime=\(s.uptimeText)")
            for io in s.diskIO {
                print("  💿 \(io.device): 读\(Int(io.readBytesPerSec/1024))KB/s 写\(Int(io.writeBytesPerSec/1024))KB/s IOPS r\(Int(io.readsPerSec))/w\(Int(io.writesPerSec)) 耗时\(io.awaitMs.map { String(format: "%.1f", $0) } ?? "—")ms util=\(io.utilPercent.map { String(format: "%.0f%%", $0) } ?? "—")")
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        try? await client.close()
        exit(0)
    } catch {
        print("❌ \(error.localizedDescription)")
        exit(1)
    }
}


print("== TermHub 冒烟测试 ==")
print("目标：\(user)@\(host)  私钥：\(keyPath)")

// 密钥解析自检：私钥导出的公钥 vs .pub 文件
do {
    let pubURL = URL(fileURLWithPath: keyPath + ".pub")
    let pubLine = try String(contentsOf: pubURL, encoding: .utf8)
    let keyText = try String(contentsOfFile: keyPath, encoding: .utf8)
    let parsed = try Curve25519.Signing.PrivateKey(sshEd25519: keyText, decryptionKey: nil)
    let parts = pubLine.split(separator: " ")
    if parts.count > 1, let blob = Data(base64Encoded: String(parts[1])), blob.count >= 51 {
        let raw = Data(parsed.publicKey.rawRepresentation)
        let expected = blob.subdata(in: (4 + 11 + 4)..<blob.count)
        print(raw == expected ? "✅ 密钥解析自检一致" : "❌ 密钥解析不一致！解析=\(raw.base64EncodedString()) 期望=\(expected.base64EncodedString())")
    } else {
        print("⚠️ .pub 文件格式异常，跳过自检")
    }
} catch {
    print("⚠️ 密钥解析自检失败：\(error.localizedDescription)")
}

let snapshot = HostSnapshot(
    id: UUID(),
    alias: "smoke",
    hostname: host,
    port: 22,
    username: user,
    authMethod: passwordOverride != nil ? .password : .key,
    keyPath: passwordOverride != nil ? nil : keyPath,
    groupName: "smoke",
    notes: "",
    proxyType: proxyParts != nil ? .http : .none,
    proxyHost: proxyParts?.host,
    proxyPort: proxyParts?.port
)

func step(_ name: String, _ body: () async throws -> String) async {
    do {
        let started = Date()
        let result = try await body()
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let preview = result.split(separator: "\n").prefix(4).joined(separator: " | ")
        print("✅ \(name)（\(ms)ms）: \(preview.prefix(220))")
    } catch {
        print("❌ \(name): \(error.localizedDescription)")
    }
}

let client: SSHClient?
do {
    client = try await SSHConnectionFactory.connect(
        to: snapshot,
        hostKeyCallback: { facts in
            print("🔑 首次指纹：\(facts.fingerprint)（\(facts.keyType)）→ 冒烟测试自动信任")
            SharedKnownHosts.store.trust(
                host: facts.host, port: facts.port,
                fingerprintSHA256: facts.fingerprint, keyType: facts.keyType
            )
            return true
        },
        overridePassword: passwordOverride,
        overridePassphrase: nil
    ).client
} catch {
    print("❌ 连接失败：\(error.localizedDescription)")
    if let citadelErr = error as? CitadelError {
        print("   CitadelError: \(citadelErr)")
    }
    exit(1)
}
guard let client else { exit(1) }
print("✅ SSH 连接成功")

await step("exec echo") {
    String(buffer: try await client.executeCommand("echo termhub-ok")).trimmingCharacters(in: .whitespacesAndNewlines)
}

await step("docker 版本") {
    String(buffer: try await client.executeCommand("docker version --format '{{.Server.Version}}' 2>&1")).trimmingCharacters(in: .whitespacesAndNewlines)
}

await step("docker ps（前2条）") {
    let out = String(buffer: try await client.executeCommand("docker ps --format '{{json .}}' 2>/dev/null | head -2"))
    let containers = DockerService.decodeLines(DockerContainer.self, from: out)
    return containers.map(\.displayName).joined(separator: " , ") + "（共解析 \(containers.count) 条）"
}

await step("SFTP 列主目录") {
    let sftp = try await client.openSFTP()
    let home = try await sftp.getRealPath(atPath: ".")
    let names = try await sftp.listDirectory(atPath: home)
    var entries: [String] = []
    for name in names {
        for component in name.components where component.filename != "." && component.filename != ".." {
            entries.append(component.filename)
        }
    }
    try await sftp.close()
    return "home=\(home) 条目: \(entries.prefix(10).joined(separator: ", "))"
}

try? await client.close()
print("== 完成 ==")
