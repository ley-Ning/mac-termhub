import Foundation
import Security

/// Keychain 封装：主机密码与私钥口令只存这里，绝不落明文文件。
public enum KeychainStore {
    public enum SecretKind: String {
        case password
        case passphrase
    }

    public enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                return "Keychain 操作失败（OSStatus \(status)）"
            }
        }
    }

    private static func service(for kind: SecretKind, hostID: UUID) -> String {
        "com.termhub.host.\(hostID.uuidString).\(kind.rawValue)"
    }

    /// 新建条目时预授权的自家二进制（App / MCP / 冒烟，debug+release）。
    /// 不做这一步，条目只信任创建它的那个二进制，其它二进制读取都会弹系统密码框。
    private static var trustedApplicationPaths: [String] {
        let repo = NSString(string: "~/WorkBuddy/TermHub").expandingTildeInPath
        return [
            "\(repo)/build/TermHub.app/Contents/MacOS/TermHub",
            "\(repo)/.build/release/TermHubMCP",
            "\(repo)/.build/debug/TermHubMCP",
            "\(repo)/.build/release/TermHubSmoke",
            "\(repo)/.build/debug/TermHubSmoke",
        ]
    }

    public static func save(_ secret: String, kind: SecretKind, hostID: UUID) throws {
        let service = service(for: kind, hostID: hostID)
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: kind.rawValue
        ]

        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            // 预授权自家二进制：SecAccess 带受信应用列表，读取不再弹授权框
            var trustedApps: [SecTrustedApplication] = []
            for path in trustedApplicationPaths {
                var app: SecTrustedApplication?
                if SecTrustedApplicationCreateFromPath(path, &app) == errSecSuccess,
                   let app {
                    trustedApps.append(app)
                }
            }
            if !trustedApps.isEmpty {
                var access: SecAccess?
                if SecAccessCreate(service as CFString, trustedApps as CFArray, &access) == errSecSuccess,
                   let access {
                    addQuery[kSecAttrAccess as String] = access
                }
            }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    public static func read(kind: SecretKind, hostID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: kind, hostID: hostID),
            kSecAttrAccount as String: kind.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(kind: SecretKind, hostID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: kind, hostID: hostID),
            kSecAttrAccount as String: kind.rawValue
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// 主机被删除时清掉全部密文
    public static func deleteAllSecrets(hostID: UUID) {
        delete(kind: .password, hostID: hostID)
        delete(kind: .passphrase, hostID: hostID)
    }
}
