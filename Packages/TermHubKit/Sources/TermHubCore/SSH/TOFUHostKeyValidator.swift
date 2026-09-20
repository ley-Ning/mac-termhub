import Foundation
import NIO
import NIOSSH

/// TOFU（Trust On First Use）主机指纹校验：
/// - 已信任且指纹一致 -> 通过
/// - 已信任但指纹变化 -> 拒绝（可能中间人，交给 UI 告警）
/// - 首次见到的主机 -> 回调询问 UI/用户，同意则记入 known_hosts
public final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    public struct HostKeyFacts: Sendable {
        public let host: String
        public let port: Int
        public let fingerprint: String
        public let keyType: String
    }

    /// 返回 true 表示信任该指纹
    public let onUnknownKey: @Sendable (HostKeyFacts) async -> Bool

    private let store: KnownHostsStore

    public init(store: KnownHostsStore, onUnknownKey: @escaping @Sendable (HostKeyFacts) async -> Bool) {
        self.store = store
        self.onUnknownKey = onUnknownKey
    }

    public func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let host = currentHost
        let port = currentPort

        // 序列化为 SSH wire 格式后取指纹
        var buffer = ByteBuffer()
        hostKey.write(to: &buffer)
        let blob = Data(buffer.readableBytesView)
        let fingerprint = KnownHostsStore.fingerprint(blob: blob)
        let keyType = Self.keyTypeName(fromWireBlob: blob)

        if let trusted = store.record(for: host, port: port) {
            if trusted.fingerprintSHA256 == fingerprint {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(SSHSetupError.hostKeyChanged(
                    host: host, oldFingerprint: trusted.fingerprintSHA256, newFingerprint: fingerprint
                ))
            }
            return
        }

        let facts = HostKeyFacts(host: host, port: port, fingerprint: fingerprint, keyType: keyType)
        Task {
            if await onUnknownKey(facts) {
                store.trust(host: host, port: port, fingerprintSHA256: fingerprint, keyType: keyType)
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(SSHSetupError.hostKeyRejected(host: host))
            }
        }
    }

    /// SSH wire 公钥 blob 的第一个 string 字段即算法名（如 ssh-ed25519）
    static func keyTypeName(fromWireBlob blob: Data) -> String {
        let bytes = Array(blob.prefix(64))
        guard bytes.count >= 4 else { return "unknown" }
        let length = (Int(bytes[0]) << 24) | (Int(bytes[1]) << 16) | (Int(bytes[2]) << 8) | Int(bytes[3])
        guard length > 0, length + 4 <= bytes.count else { return "unknown" }
        return String(decoding: bytes[4..<(4 + length)], as: UTF8.self)
    }

    /// 连接前由工厂设置（validator 在握手期间需要知道目标主机）
    public var currentHost: String = ""
    public var currentPort: Int = 22
}

import Citadel

extension SSHHostKeyValidator {
    public static func tofu(
        store: KnownHostsStore,
        onUnknownKey: @escaping @Sendable (TOFUHostKeyValidator.HostKeyFacts) async -> Bool
    ) -> (SSHHostKeyValidator, TOFUHostKeyValidator) {
        let delegate = TOFUHostKeyValidator(store: store, onUnknownKey: onUnknownKey)
        return (SSHHostKeyValidator.custom(delegate), delegate)
    }
}
