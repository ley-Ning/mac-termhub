import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// GUI 进程内的凭据 socket 服务（设计 §MCP 与工具）：
/// 仅在解锁期间监听本机 Unix domain socket（0600），按对端 UID 校验后返回单条凭据。
/// 锁定/退出即关闭监听并清理 socket 文件。不提供批量导出或主密码接口。
public final class VaultCredentialService {
    public static let defaultSocketPath = AppStorage.supportDirectory.appending(path: "vault.sock").path

    private var serverFD: Int32 = -1
    private var listenThread: Thread?
    private let gateway: @MainActor (UUID, CredentialVault.Kind) -> String?

    /// @MainActor 读凭据的闭包（VaultGateway.read）
    public init(gateway: @MainActor @escaping (UUID, CredentialVault.Kind) -> String?) {
        self.gateway = gateway
    }

    public var isRunning: Bool { serverFD >= 0 }

    /// 开始监听（幂等）；socket 文件先清理旧残留
    public func start(path: String = VaultCredentialService.defaultSocketPath) {
        guard serverFD < 0 else { return }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes) }
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, listen(fd, 4) == 0 else { close(fd); return }
        chmod(path, 0o600)
        serverFD = fd
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "vault-credential-service"
        thread.start()
        listenThread = thread
    }

    /// 停止监听并清理 socket（锁定/退出调用）
    public func stop(path: String = VaultCredentialService.defaultSocketPath) {
        guard serverFD >= 0 else { return }
        let fd = serverFD
        serverFD = -1
        close(fd) // 阻塞中的 accept 立即返回
        unlink(path)
        listenThread = nil
    }

    private func acceptLoop() {
        while serverFD >= 0 {
            var clientAddr = sockaddr_un()
            var len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let client = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(serverFD, $0, &len)
                }
            }
            guard client >= 0 else { return }
            handle(client: client)
        }
    }

    private func handle(client: Int32) {
        defer { close(client) }
        // 对端 UID 校验（LOCAL_PEERCRED）：仅同一登录用户
        var cred = xucred()
        var credLen = socklen_t(MemoryLayout<xucred>.size)
        let credOK = getsockopt(client, SOL_LOCAL, LOCAL_PEERCRED, &cred, &credLen) == 0
        guard credOK, cred.cr_uid == getuid() else { return }

        guard let line = readLine(fd: client, timeout: 3.0), let data = line.data(using: .utf8),
              let request = try? JSONDecoder().decode(Request.self, from: data),
              let hostID = UUID(uuidString: request.uuid) else {
            respond(client, Response(value: nil, error: "bad-request"))
            return
        }
        let kind: CredentialVault.Kind = request.kind == "passphrase" ? .passphrase : .password
        // 读凭据回主线程
        let value = DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                gateway(hostID, kind)
            }
        }
        respond(client, Response(value: value, error: value == nil ? "unavailable" : nil))
    }

    private struct Request: Codable {
        let uuid: String
        let kind: String
    }

    private struct Response: Codable {
        let value: String?
        let error: String?
    }

    private func respond(_ fd: Int32, _ response: Response) {
        guard let data = try? JSONEncoder().encode(response) else { return }
        var payload = data
        payload.append(0x0A)
        _ = payload.withUnsafeBytes { write(fd, $0.baseAddress!, payload.count) }
    }

    private func readLine(fd: Int32, timeout: TimeInterval) -> String? {
        var buffer = [UInt8]()
        buffer.reserveCapacity(256)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var ch: UInt8 = 0
            let n = read(fd, &ch, 1)
            if n == 1 {
                if ch == 0x0A { return String(bytes: buffer, encoding: .utf8) }
                buffer.append(ch)
                if buffer.count > 1024 { return nil }
            } else if n == 0 {
                return buffer.isEmpty ? nil : String(bytes: buffer, encoding: .utf8)
            } else {
                return nil
            }
        }
        return nil
    }
}

/// MCP 进程侧的凭据客户端：向 GUI 的服务请求单条凭据。
/// socket 不通（GUI 未运行/已退出）或返回 unavailable（未解锁/未保存）都给 nil——
/// 由连接层转为明确的解锁指引错误。
public enum VaultCredentialClient {
    public static func fetch(hostID: UUID, kind: CredentialVault.Kind, path: String = VaultCredentialService.defaultSocketPath, timeout: TimeInterval = 3.0) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes) }
        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { return nil }

        struct Request: Codable { let uuid: String; let kind: String }
        struct Response: Codable { let value: String?; let error: String? }
        guard let payload = try? JSONEncoder().encode(Request(uuid: hostID.uuidString, kind: kind.rawValue)) else { return nil }
        var bytes = payload
        bytes.append(0x0A)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress!, bytes.count) }

        // 读一行响应（带超时）
        var buffer = [UInt8]()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var ch: UInt8 = 0
            let n = read(fd, &ch, 1)
            if n == 1 {
                if ch == 0x0A { break }
                buffer.append(ch)
                if buffer.count > 4096 { return nil }
            } else if n == 0 {
                break
            } else {
                return nil
            }
        }
        guard let data = String(bytes: buffer, encoding: .utf8)?.data(using: .utf8),
              let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return response.value
    }
}
