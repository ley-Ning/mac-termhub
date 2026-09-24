import Foundation
import CommonCrypto
import Crypto

/// 自管加密凭据库（设计：docs/superpowers/specs/2026-09-25-app-managed-credential-vault-design.md）
///
/// 完全独立于 macOS 钥匙串：主密码经 PBKDF2-HMAC-SHA256（600k 轮）派生 AES-256-GCM 密钥，
/// 整个 {hostUUID: {password, passphrase}} 映射加密存单一版本化文件；原子写、0600 权限。
/// 读 API 区分 missing / corrupt / wrongMasterPassword；错误主密码与损坏文件都不会破坏现有密文。
public final class CredentialVault: @unchecked Sendable {
    // 文件格式（v1）：
    // magic 8B "THVAULT1" | salt 16B | rounds 4B BE | nonce 12B | tag 16B | ciphertext…
    private static let magic = Data("THVAULT1".utf8)
    private static let saltLength = 16
    private static let defaultRounds: UInt32 = 600_000

    public struct Entry: Codable, Equatable {
        public var password: String?
        public var passphrase: String?
        public init(password: String? = nil, passphrase: String? = nil) {
            self.password = password
            self.passphrase = passphrase
        }
    }

    public enum Kind: String {
        case password
        case passphrase

        public var label: String { self == .passphrase ? "私钥口令" : "密码" }
    }

    public enum VaultError: LocalizedError, Equatable {
        case missing
        case corrupt(String)
        case wrongMasterPassword
        case invalidMasterPassword
        case alreadyExists
        case ioFailure(String)

        public var errorDescription: String? {
            switch self {
            case .missing: return "凭据库不存在（首次使用请创建主密码）"
            case .corrupt(let detail): return "凭据库文件损坏：\(detail)"
            case .wrongMasterPassword: return "主密码错误"
            case .invalidMasterPassword: return "主密码不能为空"
            case .alreadyExists: return "凭据库已存在，请直接解锁"
            case .ioFailure(let detail): return "凭据库读写失败：\(detail)"
            }
        }
    }

    // MARK: - 文件级操作（静态：不含进程内密钥）

    public static func defaultFileURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["TERMHUB_VAULT_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return AppStorage.supportDirectory.appending(path: "vault.bin")
    }

    public static func fileExists(at url: URL? = nil) -> Bool {
        FileManager.default.fileExists(atPath: (url ?? defaultFileURL()).path)
    }

    /// 首次创建（排它）：文件已存在即失败，绝不覆盖
    public static func create(masterPassword: String, at url: URL? = nil) throws -> CredentialVault {
        guard !masterPassword.isEmpty else { throw VaultError.invalidMasterPassword }
        let url = url ?? defaultFileURL()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            if errno == EEXIST { throw VaultError.alreadyExists }
            throw VaultError.ioFailure("创建失败 errno=\(errno)")
        }
        close(fd)
        let salt = randomBytes(count: saltLength)
        let vault = CredentialVault(
            fileURL: url,
            key: deriveKey(password: masterPassword, salt: salt, rounds: defaultRounds),
            salt: salt,
            rounds: defaultRounds,
            entries: [:]
        )
        try vault.persist()
        return vault
    }

    /// 解锁：错误主密码/损坏文件都抛错且不改动文件
    public static func unlock(masterPassword: String, at url: URL? = nil) throws -> CredentialVault {
        let url = url ?? defaultFileURL()
        guard let blob = try? Data(contentsOf: url) else { throw VaultError.missing }
        let parsed = try parse(blob)
        let key = deriveKey(password: masterPassword, salt: parsed.salt, rounds: parsed.rounds)
        guard let nonce = try? AES.GCM.Nonce(data: parsed.nonce),
              let plaintext = try? AES.GCM.open(
                  .init(nonce: nonce, ciphertext: parsed.ciphertext, tag: parsed.tag),
                  using: key
              ) else {
            throw VaultError.wrongMasterPassword
        }
        let entries = (try? JSONDecoder().decode([String: Entry].self, from: plaintext)) ?? [:]
        return CredentialVault(
            fileURL: url, key: key, salt: parsed.salt, rounds: parsed.rounds, entries: entries
        )
    }

    // MARK: - 实例操作（解锁态；线程安全）

    public func read(hostID: UUID, kind: Kind) -> String? {
        lock.lock(); defer { lock.unlock() }
        let entry = entries[hostID.uuidString]
        return kind == .passphrase ? entry?.passphrase : entry?.password
    }

    public func hasCredential(hostID: UUID, kind: Kind) -> Bool {
        read(hostID: hostID, kind: kind) != nil
    }

    public func save(_ secret: String, hostID: UUID, kind: Kind) throws {
        lock.lock(); defer { lock.unlock() }
        var next = entries
        var entry = next[hostID.uuidString] ?? Entry()
        if kind == .passphrase { entry.passphrase = secret } else { entry.password = secret }
        next[hostID.uuidString] = entry
        // 先写盘成功、再提交内存——失败时内存快照与磁盘保持一致
        try Self.write(entries: next, key: key, salt: salt, rounds: rounds, to: fileURL)
        entries = next
    }

    public func deleteHost(_ hostID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        var next = entries
        next.removeValue(forKey: hostID.uuidString)
        try Self.write(entries: next, key: key, salt: salt, rounds: rounds, to: fileURL)
        entries = next
    }

    public var hostCount: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    /// 更换主密码：当前密钥已在内存（已验证），以新盐/新密钥全量重加密；
    /// persist 失败时旧文件保持原样（原子写语义），但需回滚内存态由调用方重建实例。
    public func changeMasterPassword(to newPassword: String) throws {
        let newSalt = randomBytes(count: Self.saltLength)
        let newKey = Self.deriveKey(password: newPassword, salt: newSalt, rounds: Self.defaultRounds)
        lock.lock(); defer { lock.unlock() }
        try Self.write(entries: entries, key: newKey, salt: newSalt, rounds: Self.defaultRounds, to: fileURL)
        self.key = newKey
        self.salt = newSalt
        self.rounds = Self.defaultRounds
    }

    // MARK: - 内部

    private let fileURL: URL
    private var key: SymmetricKey
    private var salt: Data
    private var rounds: UInt32
    private var entries: [String: Entry]
    private let lock = NSLock()

    private init(fileURL: URL, key: SymmetricKey, salt: Data, rounds: UInt32, entries: [String: Entry]) {
        self.fileURL = fileURL
        self.key = key
        self.salt = salt
        self.rounds = rounds
        self.entries = entries
    }

    /// 以当前 key+salt 落盘（nonce 每次随机；salt/rounds 不变保证可再解锁）
    private func persist() throws {
        lock.lock(); defer { lock.unlock() }
        try Self.write(entries: entries, key: key, salt: salt, rounds: rounds, to: fileURL)
    }

    private static func write(entries: [String: Entry], key: SymmetricKey, salt: Data, rounds: UInt32, to url: URL) throws {
        let plaintext = try JSONEncoder().encode(entries)
        let nonce = AES.GCM.Nonce()
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        let payload = magic + salt + rounds.bigEndianData + Data(nonce) + box.tag + box.ciphertext
        try atomicWrite(payload, to: url)
    }

    private struct Parsed {
        let salt: Data
        let rounds: UInt32
        let nonce: Data
        let tag: Data
        let ciphertext: Data
    }

    private static func parse(_ blob: Data) throws -> Parsed {
        var offset = 0
        func take(_ n: Int) throws -> Data {
            guard offset + n <= blob.count else { throw VaultError.corrupt("长度不足") }
            defer { offset += n }
            return blob.subdata(in: offset ..< (offset + n))
        }
        guard try take(magic.count) == magic else { throw VaultError.corrupt("magic 不符") }
        let salt = try take(saltLength)
        let roundsRaw = try take(4)
        let rounds = roundsRaw.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let nonce = try take(12)
        let tag = try take(16)
        let ciphertext = try take(blob.count - offset)
        guard rounds >= 100_000, rounds <= 10_000_000 else {
            throw VaultError.corrupt("轮数非法 \(rounds)")
        }
        return Parsed(salt: salt, rounds: rounds, nonce: nonce, tag: tag, ciphertext: ciphertext)
    }

    private static func deriveKey(password: String, salt: Data, rounds: UInt32) -> SymmetricKey {
        var derived = Data(repeating: 0, count: 32)
        let passwordData = Data(password.utf8)
        // 三个缓冲区的指针都必须在各自 withUnsafe* 作用域内使用——
        // 内联在调用实参里的 withUnsafeBytes 返回值是悬垂指针（Swift 安全规则），会读到随机内存
        passwordData.withUnsafeBytes { pwPtr in
            salt.withUnsafeBytes { saltPtr in
                derived.withUnsafeMutableBytes { derivedPtr in
                    _ = CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwPtr.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        rounds,
                        derivedPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), 32
                    )
                }
            }
        }
        return SymmetricKey(data: derived)
    }

    /// 同目录临时文件 + fsync + 原子替换 + 0600；失败保持旧文件完整
    private static func atomicWrite(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let tmp = dir.appending(path: ".vault.tmp.\(UUID().uuidString)")
        do {
            try data.write(to: tmp, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp, backupItemName: nil, options: [])
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw VaultError.ioFailure(error.localizedDescription)
        }
    }
}

private func randomBytes(count: Int) -> Data {
    var bytes = Data(count: count)
    _ = bytes.withUnsafeMutableBytes { ptr in
        SecRandomCopyBytes(kSecRandomDefault, count, ptr.baseAddress!)
    }
    return bytes
}

extension UInt32 {
    var bigEndianData: Data {
        withUnsafeBytes(of: self.bigEndian) { Data($0) }
    }
}
