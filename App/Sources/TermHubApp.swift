import SwiftUI
import SwiftData
import TermHubCore
import TermHubUI

@main
struct TermHubApp: App {
    @State private var appState = AppState()

    private let uiTest = ProcessInfo.processInfo.environment["TERMHUB_UITEST"] == "1"

    /// 共享库（与 termhub-mcp 同一份）；UITest/极端情况用内存库
    private var container: ModelContainer {
        if uiTest {
            return try! ModelContainer(
                for: SSHHost.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        }
        if let shared = try? AppStorage.makeSharedContainer() {
            return shared
        }
        return try! ModelContainer(
            for: SSHHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environment(appState)
                .modelContainer(container)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新增主机…") {
                    NotificationCenter.default.post(name: .termHubNewHost, object: nil)
                }
                .keyboardShortcut("n")
            }
        }
    }
}
