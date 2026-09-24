import SwiftUI
import TermHubCore

/// 进程内凭据库网关：App 启动解锁一次，全局提供凭据读取；
/// 锁定即丢弃内存密钥并关闭活动 SSH 会话（由 App 层执行）。
@MainActor
public final class VaultGateway: ObservableObject {
    @Published public private(set) var vault: CredentialVault?
    @Published public private(set) var lastError: String?

    public init() {}

    public var isUnlocked: Bool { vault != nil }
    public var needsSetup: Bool { !CredentialVault.fileExists() }

    public func create(masterPassword: String) -> Bool {
        do {
            vault = try CredentialVault.create(masterPassword: masterPassword)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    public func unlock(masterPassword: String) -> Bool {
        do {
            vault = try CredentialVault.unlock(masterPassword: masterPassword)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// 显式锁定：丢弃内存密钥（调用方负责关闭 SSH 会话与 MCP socket 服务）
    public func lock() {
        vault = nil
    }

    /// 更改主密码
    public func changeMasterPassword(to newPassword: String) -> Bool {
        guard let vault else { return false }
        do {
            try vault.changeMasterPassword(to: newPassword)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - 凭据读写（未解锁返回 nil / false，绝不弹任何系统框）

    public func read(hostID: UUID, kind: CredentialVault.Kind) -> String? {
        vault?.read(hostID: hostID, kind: kind)
    }

    public func hasCredential(hostID: UUID, kind: CredentialVault.Kind) -> Bool {
        vault?.hasCredential(hostID: hostID, kind: kind) ?? false
    }

    public func save(_ secret: String, hostID: UUID, kind: CredentialVault.Kind) throws {
        guard let vault else {
            throw CredentialVault.VaultError.missing
        }
        try vault.save(secret, hostID: hostID, kind: kind)
    }

    public func deleteHost(_ hostID: UUID) {
        try? vault?.deleteHost(hostID)
    }
}
