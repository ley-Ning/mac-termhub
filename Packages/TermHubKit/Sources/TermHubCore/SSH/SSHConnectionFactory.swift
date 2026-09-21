import Foundation
import Crypto
import Citadel
import NIO
import NIOSSH

public enum SSHSetupError: LocalizedError {
    case notConnected
    case missingPassword
    case missingKeyPath
    case keyFileUnreadable(String)
    case unsupportedKeyFormat(String)
    case keyParseFailed(String)
    case hostKeyRejected(host: String)
    case hostKeyChanged(host: String, oldFingerprint: String, newFingerprint: String)
    case proxyTunnelFailed(proxy: String, detail: String)
    case jumpConnectFailed(hop: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "会话未连接，请先连接主机"
        case .missingPassword:
            return "未保存密码，请先在主机编辑里填写"
        case .missingKeyPath:
            return "未设置私钥路径"
        case .keyFileUnreadable(let path):
            return "私钥文件读取失败：\(path)"
        case .unsupportedKeyFormat(let path):
            return "暂不支持该私钥格式（支持 OpenSSH ed25519 / RSA）：\(path)"
        case .keyParseFailed(let reason):
            return "私钥解析失败：\(reason)"
        case .hostKeyRejected(let host):
            return "已拒绝主机指纹：\(host)"
        case .hostKeyChanged(let host, let old, let new):
            return """
            主机 \(host) 的指纹已改变，连接已阻止（可能存在中间人风险）。
            旧指纹：\(old)
            新指纹：\(new)
            如确认服务器重装过，可在设置里清除该主机的信任记录后重连。
            """
        case .proxyTunnelFailed(let proxy, let detail):
            return """
            HTTP 代理隧道建立失败（\(proxy)）。
            \(detail)
            请检查代理地址/端口及网络可达性。
            """
        case .jumpConnectFailed(let hop, let detail):
            return """
            经由跳板机「\(hop)」建立通道失败。
            \(detail)
            请检查跳板机是否允许 TCP 转发（sshd_config 的 AllowTcpForwarding）、
            跳板凭据是否正确、目标主机是否可达。
            """
        }
    }
}

/// 连接结果：目标主机 client + 跳板链上的中间 client（供断开时整链关闭）
public struct SSHConnection {
    public let client: SSHClient
    /// 顺序：第一跳在前。关闭时应在关闭 client 之后逆序关闭。
    public let jumpClients: [SSHClient]

    /// 关闭整条链（目标在前，跳板随后；失败忽略）
    public func closeAll() async {
        try? await client.close()
        for jumpClient in jumpClients.reversed() {
            try? await jumpClient.close()
        }
    }
}

/// 从主机配置构建认证方式与连接
public enum SSHConnectionFactory {
    /// overridePassword/overridePassphrase：编辑器“测试连接”时直接用表单输入的临时凭据
    public static func makeAuthentication(
        for host: HostSnapshot,
        overridePassword: String? = nil,
        overridePassphrase: String? = nil
    ) throws -> SSHAuthenticationMethod {
        switch host.authMethod {
        case .password:
            let password = overridePassword ?? KeychainStore.read(kind: .password, hostID: host.id)
            guard let password, !password.isEmpty else {
                throw SSHSetupError.missingPassword
            }
            return .passwordBased(username: host.username, password: password)

        case .key:
            guard let path = host.keyPath, !path.isEmpty else {
                throw SSHSetupError.missingKeyPath
            }
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                throw SSHSetupError.keyFileUnreadable(path)
            }
            let stored = KeychainStore.read(kind: .passphrase, hostID: host.id)
            let passphraseData = (overridePassphrase ?? stored).map { Data($0.utf8) }

            // OpenSSH 新格式（含 ed25519）优先，其次 PEM RSA
            if let key = try? Curve25519.Signing.PrivateKey(sshEd25519: text, decryptionKey: passphraseData) {
                return .ed25519(username: host.username, privateKey: key)
            }
            if let key = try? Insecure.RSA.PrivateKey(sshRsa: text, decryptionKey: passphraseData) {
                return .rsa(username: host.username, privateKey: key)
            }
            throw SSHSetupError.unsupportedKeyFormat(path)
        }
    }

    /// 连接。hostKeyCallback 仅在首次遇到该主机指纹时被调用（UI 弹窗确认）。
    /// jumpHosts：按顺序解析好的跳板链（不含目标；由调用侧查 SwiftData 传入，
    /// 避免本层反依赖 SwiftData）。跳板链上每一跳独立做 TOFU 校验与认证。
    public static func connect(
        to host: HostSnapshot,
        hostKeyCallback: @escaping @Sendable (TOFUHostKeyValidator.HostKeyFacts) async -> Bool,
        jumpHosts: [HostSnapshot] = [],
        overridePassword: String? = nil,
        overridePassphrase: String? = nil
    ) async throws -> SSHConnection {
        // 无跳板：保持原直连/HTTP 代理路径
        guard let firstHop = jumpHosts.first else {
            let client = try await connectSingleHop(
                to: host,
                hostKeyCallback: hostKeyCallback,
                overridePassword: overridePassword,
                overridePassphrase: overridePassphrase
            )
            return SSHConnection(client: client, jumpClients: [])
        }

        // 有跳板：先直连第一跳（第一跳自身仍可走 HTTP 代理），
        // 之后在上一跳的连接上开 direct-tcpip 通道逐跳 SSH 握手到目标。
        // 临时凭据（override*）只作用于目标主机；各跳板用自身保存的凭据。
        var chain: [SSHClient] = []
        var current = try await connectSingleHop(
            to: firstHop,
            hostKeyCallback: hostKeyCallback
        )
        chain.append(current)

        do {
            for hop in jumpHosts.dropFirst() {
                current = try await jumpThrough(current, to: hop, hostKeyCallback: hostKeyCallback)
                chain.append(current)
            }
            let target = try await jumpThrough(
                current,
                to: host,
                hostKeyCallback: hostKeyCallback,
                overridePassword: overridePassword,
                overridePassphrase: overridePassphrase
            )
            return SSHConnection(client: target, jumpClients: chain)
        } catch {
            // 失败清理：目标未建立，逆序关闭已建立的跳板
            for jumpClient in chain.reversed() {
                try? await jumpClient.close()
            }
            let failedHop = jumpHosts.count > chain.count
                ? jumpHosts[chain.count]          // 中断在 chain.count 号跳板上
                : host                             // 跳板全通，目标握手失败
            throw translateJumpError(error, at: failedHop)
        }
    }

    /// 单跳直连（含 HTTP 代理分支），原 connect 的主体逻辑
    private static func connectSingleHop(
        to host: HostSnapshot,
        hostKeyCallback: @escaping @Sendable (TOFUHostKeyValidator.HostKeyFacts) async -> Bool,
        overridePassword: String? = nil,
        overridePassphrase: String? = nil
    ) async throws -> SSHClient {
        let auth = try makeAuthentication(
            for: host,
            overridePassword: overridePassword,
            overridePassphrase: overridePassphrase
        )
        let (validator, delegate) = SSHHostKeyValidator.tofu(
            store: SharedKnownHosts.store,
            onUnknownKey: hostKeyCallback
        )
        delegate.currentHost = host.hostname
        delegate.currentPort = host.port

        // HTTP 代理：先建隧道，再把通道交给 SSH 握手
        if host.proxyType == .http, let proxyHost = host.proxyHost, let proxyPort = host.proxyPort {
            let group = MultiThreadedEventLoopGroup.singleton
            let ready = group.next().makePromise(of: Void.self)
            let bootstrap = ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(HTTPConnectTunnelHandler(
                        targetHost: host.hostname,
                        targetPort: host.port,
                        readyPromise: ready
                    ))
                }
                .connectTimeout(.seconds(20))

            let tunnel = try await bootstrap.connect(host: proxyHost, port: proxyPort).get()
            do {
                try await ready.futureResult.get()
            } catch {
                try? await tunnel.close()
                throw error
            }

            let settings = SSHClientSettings(
                host: host.hostname,
                port: host.port,
                authenticationMethod: { auth },
                hostKeyValidator: validator
            )
            return try await SSHClient.connect(on: tunnel, settings: settings)
        }

        return try await SSHClient.connect(
            host: host.hostname,
            port: host.port,
            authenticationMethod: auth,
            hostKeyValidator: validator,
            reconnect: .never
        )
    }

    /// 在已有连接上经 direct-tcpip 通道对下一台主机做 SSH 握手（Citadel 公开 jump API）
    private static func jumpThrough(
        _ client: SSHClient,
        to hop: HostSnapshot,
        hostKeyCallback: @escaping @Sendable (TOFUHostKeyValidator.HostKeyFacts) async -> Bool,
        overridePassword: String? = nil,
        overridePassphrase: String? = nil
    ) async throws -> SSHClient {
        let auth = try makeAuthentication(
            for: hop,
            overridePassword: overridePassword,
            overridePassphrase: overridePassphrase
        )
        // 每跳独立的 TOFU 校验：指纹按各跳主机名分别记录
        let (validator, delegate) = SSHHostKeyValidator.tofu(
            store: SharedKnownHosts.store,
            onUnknownKey: hostKeyCallback
        )
        delegate.currentHost = hop.hostname
        delegate.currentPort = hop.port

        let settings = SSHClientSettings(
            host: hop.hostname,
            port: hop.port,
            authenticationMethod: { auth },
            hostKeyValidator: validator
        )
        return try await client.jump(to: settings)
    }

    /// 跳板链错误转译：通道被拒多因跳板禁用 TCP 转发，给可读中文
    private static func translateJumpError(_ error: Error, at hop: HostSnapshot) -> Error {
        if case SSHClientError.channelCreationFailed = error {
            return SSHSetupError.jumpConnectFailed(
                hop: hop.alias.isEmpty ? hop.hostname : hop.alias,
                detail: "跳板机拒绝了 TCP 转发通道（channelCreationFailed）。"
            )
        }
        if let setup = error as? SSHSetupError {
            return setup
        }
        return SSHSetupError.jumpConnectFailed(
            hop: hop.alias.isEmpty ? hop.hostname : hop.alias,
            detail: error.localizedDescription
        )
    }
}

/// 全局共享的 known_hosts 存储
public enum SharedKnownHosts {
    public static let store = KnownHostsStore()
}
