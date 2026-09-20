import Foundation
import Crypto

/// known_hosts 存储：host:port -> SHA256 指纹（TOFU 信任模型）。
/// 文件位置：~/Library/Application Support/TermHub/known_hosts.json
public final class KnownHostsStore: @unchecked Sendable {
    public struct Record: Codable {
        public var fingerprintSHA256: String
        public var keyType: String
        public var trustedAt: Date
    }

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.termhub.knownhosts")
    private var cache: [String: Record]

    public init(directory: URL? = nil) {
        let dir = directory ?? URL.applicationSupportDirectory.appending(path: "TermHub", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appending(path: "known_hosts.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Record].self, from: data) {
            self.cache = decoded
        } else {
            self.cache = [:]
        }
    }

    private static func key(host: String, port: Int) -> String {
        "[\(host)]:\(port)"
    }

    public func record(for host: String, port: Int) -> Record? {
        queue.sync { cache[Self.key(host: host, port: port)] }
    }

    public func trust(host: String, port: Int, fingerprintSHA256: String, keyType: String) {
        queue.sync {
            cache[Self.key(host: host, port: port)] = Record(
                fingerprintSHA256: fingerprintSHA256,
                keyType: keyType,
                trustedAt: Date()
            )
            if let data = try? JSONEncoder().encode(cache) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    public func remove(host: String, port: Int) {
        queue.sync {
            cache.removeValue(forKey: Self.key(host: host, port: port))
            if let data = try? JSONEncoder().encode(cache) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    /// 由 SSH wire 格式的公钥数据计算 SHA256 指纹（与 ssh-keygen 的展示形式一致）
    public static func fingerprint(blob: Data) -> String {
        let digest = SHA256.hash(data: blob)
        let base64 = Data(digest).base64EncodedString()
        return "SHA256:\(base64)"
    }
}
