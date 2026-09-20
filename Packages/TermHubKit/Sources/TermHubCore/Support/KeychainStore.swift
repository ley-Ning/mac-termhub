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
