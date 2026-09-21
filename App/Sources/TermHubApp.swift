import SwiftUI
import SwiftData
import TermHubCore
import TermHubUI

@main
struct TermHubApp: App {
    @State private var appState = AppState()
    @StateObject private var updater = UpdateService()
    @StateObject private var theme = ThemeSettings.shared
    @State private var showingSettings = false

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
                .environmentObject(updater)
                // 主题：外观模式 + 强调色（设置页即时生效）
                .preferredColorScheme(theme.appearance.colorScheme)
                .tint(theme.accentColor)
                .sheet(isPresented: $showingSettings) {
                    SettingsView()
                }
                .task {
                    // 启动后台静默检查更新（本地仓库存在时）
                    if !uiTest { await updater.checkForUpdates() }
                }
                .sheet(isPresented: Binding(
                    get: { updater.showsUpdateSheet },
                    set: { if !$0 { updater.showsUpdateSheet = false } }
                )) {
                    UpdateSheet(updater: updater)
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新增主机…") {
                    NotificationCenter.default.post(name: .termHubNewHost, object: nil)
                }
                .keyboardShortcut("n")
            }
            CommandGroup(after: .newItem) {
                Button("快速切换主机…") {
                    NotificationCenter.default.post(name: .termHubQuickSwitch, object: nil)
                }
                .keyboardShortcut("k")
            }
            // 热更新：检查 + 一键安装（拉代码 → 稳定签名重建 → 自动重启）
            CommandGroup(after: .appInfo) {
                Button("设置…") {
                    showingSettings = true
                }
                .keyboardShortcut(",")
                Button("检查更新…") {
                    Task {
                        await updater.checkForUpdates()
                        updater.showsUpdateSheet = true
                    }
                }
                .disabled(!updater.isAvailable)
                if let badge = updater.updateBadgeText {
                    Button("安装\(badge)（热更新）") {
                        updater.installUpdate()
                    }
                    .keyboardShortcut("u")
                    .disabled(updater.isUpdating)
                }
            }
        }
    }
}
