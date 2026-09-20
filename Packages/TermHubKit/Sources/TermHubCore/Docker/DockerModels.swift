import Foundation

/// docker ps --format '{{json}}' 解析结果
public struct DockerContainer: Identifiable, Hashable, Sendable {
    public let id: String
    public let shortID: String
    public let names: [String]
    public let image: String
    public let command: String
    public let state: String
    public let status: String
    public let createdAt: String
    public let ports: String

    public var displayName: String { names.first ?? shortID }
    public var isRunning: Bool { state == "running" }

    public enum CodingKeys: String, CodingKey {
        case id = "ID"
        case names = "Names"
        case image = "Image"
        case command = "Command"
        case state = "State"
        case status = "Status"
        case createdAt = "CreatedAt"
        case ports = "Ports"
    }
}

extension DockerContainer: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fullID = try c.decode(String.self, forKey: .id)
        id = fullID
        shortID = String(fullID.prefix(12))
        let namesRaw = try c.decode(String.self, forKey: .names)
        names = namesRaw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        image = (try? c.decode(String.self, forKey: .image)) ?? ""
        command = (try? c.decode(String.self, forKey: .command)) ?? ""
        state = (try? c.decode(String.self, forKey: .state)) ?? ""
        status = (try? c.decode(String.self, forKey: .status)) ?? ""
        createdAt = (try? c.decode(String.self, forKey: .createdAt)) ?? ""
        ports = (try? c.decode(String.self, forKey: .ports)) ?? ""
    }
}

/// docker images --format '{{json}}' 解析结果
public struct DockerImage: Identifiable, Hashable, Sendable {
    public let id: String
    public let repository: String
    public let tag: String
    public let sizeBytes: Int64
    public let createdAt: String

    public var displayTag: String { repository == "<none>" && tag == "<none>" ? id.prefix(12).description : "\(repository):\(tag)" }
}

extension DockerImage: Decodable {
    public enum CodingKeys: String, CodingKey {
        case id = "ID"
        case repository = "Repository"
        case tag = "Tag"
        case size = "Size"
        case createdAt = "CreatedAt"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        repository = (try? c.decode(String.self, forKey: .repository)) ?? ""
        tag = (try? c.decode(String.self, forKey: .tag)) ?? ""
        let sizeRaw = (try? c.decode(String.self, forKey: .size)) ?? "0"
        sizeBytes = DockerImage.parseSize(sizeRaw)
        createdAt = (try? c.decode(String.self, forKey: .createdAt)) ?? ""
    }

    /// "123.4MB" / "1.2GB" -> 字节数
    public static func parseSize(_ text: String) -> Int64 {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
        let unit: Double
        var numberPart = cleaned
        if cleaned.hasSuffix("kB") { unit = 1_000; numberPart = String(cleaned.dropLast(2)) }
        else if cleaned.hasSuffix("MB") { unit = 1_000_000; numberPart = String(cleaned.dropLast(2)) }
        else if cleaned.hasSuffix("GB") { unit = 1_000_000_000; numberPart = String(cleaned.dropLast(2)) }
        else if cleaned.hasSuffix("TB") { unit = 1_000_000_000_000; numberPart = String(cleaned.dropLast(2)) }
        else if cleaned.hasSuffix("B") { unit = 1; numberPart = String(cleaned.dropLast(1)) }
        else { unit = 1 }
        return Int64((Double(numberPart) ?? 0) * unit)
    }
}

/// docker stats --no-stream --format '{{json}}' 单容器资源占用
public struct DockerStats: Hashable, Sendable {
    public let containerID: String
    public let name: String
    public let cpuPercent: Double
    public let memUsedBytes: Int64
    public let memLimitBytes: Int64
    public let memPercent: Double
    public let netIO: String
    public let blockIO: String
    public let pids: Int

    public var cpuText: String { String(format: "%.1f%%", cpuPercent) }
    public var memText: String {
        let used = ByteCountFormatter.string(fromByteCount: memUsedBytes, countStyle: .memory)
        let limit = ByteCountFormatter.string(fromByteCount: memLimitBytes, countStyle: .memory)
        return "\(used) / \(limit)"
    }
}

extension DockerStats: Decodable {
    public enum CodingKeys: String, CodingKey {
        case containerID = "ID"
        case name = "Name"
        case cpuPercent = "CPUPerc"
        case memUsage = "MemUsage"
        case memPercent = "MemPerc"
        case netIO = "NetIO"
        case blockIO = "BlockIO"
        case pids = "PIDs"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        containerID = (try? c.decode(String.self, forKey: .containerID)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        cpuPercent = DockerStats.parsePercent((try? c.decode(String.self, forKey: .cpuPercent)) ?? "0")
        // MemUsage: "128.5MiB / 3.84GiB"
        let memUsage = (try? c.decode(String.self, forKey: .memUsage)) ?? ""
        let parts = memUsage.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        memUsedBytes = parts.count > 0 ? DockerImage.parseSize(parts[0]) : 0
        memLimitBytes = parts.count > 1 ? DockerImage.parseSize(parts[1]) : 0
        memPercent = DockerStats.parsePercent((try? c.decode(String.self, forKey: .memPercent)) ?? "0")
        netIO = (try? c.decode(String.self, forKey: .netIO)) ?? ""
        blockIO = (try? c.decode(String.self, forKey: .blockIO)) ?? ""
        pids = Int((try? c.decode(String.self, forKey: .pids)) ?? "0") ?? 0
    }

    public static func parsePercent(_ text: String) -> Double {
        Double(text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) ?? 0
    }
}
