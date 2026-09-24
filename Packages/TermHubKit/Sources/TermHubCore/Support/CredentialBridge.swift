import Foundation

/// 凭据桥：Core 层连接代码通过它取密码/口令，具体来源由宿主注入——
/// GUI 注入 VaultGateway（进程内解锁库）、MCP 注入 socket 客户端（GUI 解锁期服务）、
/// Smoke 注入本地解锁库。未注入或返回 nil = 凭据不可用（未解锁/未保存）。
public enum CredentialBridge {
    public static var provider: (@Sendable (UUID, CredentialVault.Kind) -> String?)?
}
