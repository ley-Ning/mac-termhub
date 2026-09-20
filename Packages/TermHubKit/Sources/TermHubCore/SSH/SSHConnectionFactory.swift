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
    public static func connect(
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
}

/// 全局共享的 known_hosts 存储
public enum SharedKnownHosts {
    public static let store = KnownHostsStore()
}
