import Foundation
import SwiftData

/// GUI App 与 termhub-mcp 共享的存储路径约定
public enum AppStorage {
    /// ~/Library/Application Support/TermHub/
    public static var supportDirectory: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "TermHub", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// SwiftData 共享库文件（GUI 与 MCP 都用这一份主机配置）
    public static var sharedStoreURL: URL {
        supportDirectory.appending(path: "TermHub.store")
    }

    public static func makeSharedContainer() throws -> ModelContainer {
        let config = ModelConfiguration(url: sharedStoreURL)
        return try ModelContainer(for: SSHHost.self, configurations: config)
    }
}
