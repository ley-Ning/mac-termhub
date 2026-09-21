import Foundation
import SwiftData

/// 认证方式：密码 或 私钥
public enum HostAuthMethod: String, Codable, CaseIterable, Identifiable {
    case password
    case key

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .password: return "密码"
        case .key: return "私钥"
        }
    }
}

/// 连接代理类型
public enum HostProxyType: String, Codable, CaseIterable, Identifiable {
    case none
    case http

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .none: return "无"
        case .http: return "HTTP"
        }
    }
}

/// 主机配置（SwiftData 持久化）。密钥/密码本体存 Keychain，这里只存配置。
@Model
public final class SSHHost {
    @Attribute(.unique) public var id: UUID
    public var alias: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var authMethodRaw: String
    public var keyPath: String?
    public var groupName: String
    public var notes: String
    public var createdAt: Date
    public var lastConnectedAt: Date?
    public var proxyTypeRaw: String?
    public var proxyHost: String?
    public var proxyPort: Int?
    /// 经由哪台已保存主机做跳板（nil=直连）；新增可选字段属轻量迁移
    public var jumpHostID: UUID?

    public init(
        id: UUID = UUID(),
        alias: String,
        hostname: String,
        port: Int = 22,
        username: String,
        authMethod: HostAuthMethod = .password,
        keyPath: String? = nil,
        groupName: String = "默认",
        notes: String = "",
        createdAt: Date = Date(),
        lastConnectedAt: Date? = nil,
        proxyType: HostProxyType = .none,
        proxyHost: String? = nil,
        proxyPort: Int? = nil,
        jumpHostID: UUID? = nil
    ) {
        self.id = id
        self.alias = alias
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authMethodRaw = authMethod.rawValue
        self.keyPath = keyPath
        self.groupName = groupName
        self.notes = notes
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
        self.proxyTypeRaw = proxyType == .none ? nil : proxyType.rawValue
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.jumpHostID = jumpHostID
    }

    public var authMethod: HostAuthMethod {
        get { HostAuthMethod(rawValue: authMethodRaw) ?? .password }
        set { authMethodRaw = newValue.rawValue }
    }

    public var proxyType: HostProxyType {
        get { proxyTypeRaw.flatMap { HostProxyType(rawValue: $0) } ?? .none }
        set { proxyTypeRaw = newValue == .none ? nil : newValue.rawValue }
    }

    public var displayAddress: String {
        port == 22 ? hostname : "\(hostname):\(port)"
    }

    public var proxyDescription: String? {
        guard proxyType == .http, let host = proxyHost, let port = proxyPort else { return nil }
        return "HTTP 代理 \(host):\(port)"
    }
}

/// 发给 SSH 层的纯值快照，避免 @Model 对象跨并发域。
public struct HostSnapshot: Identifiable, Hashable, Sendable {
    public init(
        id: UUID,
        alias: String,
        hostname: String,
        port: Int,
        username: String,
        authMethod: HostAuthMethod,
        keyPath: String?,
        groupName: String,
        notes: String,
        proxyType: HostProxyType = .none,
        proxyHost: String? = nil,
        proxyPort: Int? = nil,
        jumpHostID: UUID? = nil
    ) {
        self.id = id
        self.alias = alias
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.keyPath = keyPath
        self.groupName = groupName
        self.notes = notes
        self.proxyType = proxyType
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
        self.jumpHostID = jumpHostID
    }

    public let id: UUID
    public var alias: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var authMethod: HostAuthMethod
    public var keyPath: String?
    public var groupName: String
    public var notes: String
    public var proxyType: HostProxyType
    public var proxyHost: String?
    public var proxyPort: Int?
    public var jumpHostID: UUID?

    public var displayAddress: String {
        port == 22 ? hostname : "\(hostname):\(port)"
    }

    /// 代理描述（无代理返回 nil）
    public var proxyDescription: String? {
        guard proxyType == .http, let host = proxyHost, let port = proxyPort else { return nil }
        return "HTTP 代理 \(host):\(port)"
    }
}

public extension SSHHost {
    var snapshot: HostSnapshot {
        HostSnapshot(
            id: id,
            alias: alias,
            hostname: hostname,
            port: port,
            username: username,
            authMethod: authMethod,
            keyPath: keyPath,
            groupName: groupName,
            notes: notes,
            proxyType: proxyType,
            proxyHost: proxyHost,
            proxyPort: proxyPort,
            jumpHostID: jumpHostID
        )
    }
}
