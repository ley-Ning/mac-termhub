import Foundation

/// 命令片段。hostIDs 为空 = 全局可见；非空 = 仅这些主机的片段面板显示。
public struct Snippet: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var body: String
    public var groupName: String
    public var hostIDs: [UUID]

    public init(
        id: UUID = UUID(),
        title: String,
        body: String,
        groupName: String = "默认",
        hostIDs: [UUID] = []
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.groupName = groupName.isEmpty ? "默认" : groupName
        self.hostIDs = hostIDs
    }
}

/// 片段存储：JSON 文件落在 AppStorage.supportDirectory/snippets.json。
/// 刻意独立于 GUI/MCP 共享的 SwiftData store（改 schema 有波及面，此功能无需入库存档）。
@MainActor
public final class SnippetStore: ObservableObject {
    @Published public private(set) var snippets: [Snippet] = []

    /// 跨主机共享单例（终端/面板都取这一份）
    public static let shared = SnippetStore()

    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL
            ?? AppStorage.supportDirectory.appending(path: "snippets.json")
        load()
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let loaded = try? JSONDecoder().decode([Snippet].self, from: data) {
            snippets = loaded
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(snippets) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - CRUD

    @discardableResult
    public func add(_ snippet: Snippet) -> Snippet {
        snippets.append(snippet)
        save()
        return snippet
    }

    public func update(_ snippet: Snippet) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        snippets[index] = snippet
        save()
    }

    public func delete(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        save()
    }

    // MARK: - 查询

    /// 指定主机可见的片段：全局（hostIDs 空）+ 显式包含该主机
    public func visibleSnippets(forHost hostID: UUID) -> [Snippet] {
        snippets.filter { $0.hostIDs.isEmpty || $0.hostIDs.contains(hostID) }
    }

    /// 搜索（标题/内容/分组，大小写不敏感；query 为空返回全部）
    public func search(_ query: String, hostID: UUID?) -> [Snippet] {
        let base = hostID.map { visibleSnippets(forHost: $0) } ?? snippets
        guard !query.isEmpty else { return base }
        let q = query.lowercased()
        return base.filter {
            $0.title.lowercased().contains(q)
                || $0.body.lowercased().contains(q)
                || $0.groupName.lowercased().contains(q)
        }
    }
}
