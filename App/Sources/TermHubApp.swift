import SwiftUI
import SwiftData
import TermHubCore
import TermHubUI

@main
struct TermHubApp: App {
    @State private var appState = AppState()
    @StateObject private var updater = UpdateService()
    @StateObject private var theme = ThemeSettings.shared
    @StateObject private var vaultGateway = VaultGateway()
    @State private var showingSettings = false
    @State private var vaultUnlocked = false
    @State private var credentialService = VaultCredentialService(gateway: { _, _ in nil })

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

    /// 连接层取凭据的唯一通道：GUI 解锁态=进程内加密库；锁定=返回不可用。
    /// 同时向本机 MCP 提供 socket 凭据服务（同 UID 才应答）。
    private func installCredentialBridge() {
        // provider 直接持有线程安全的 CredentialVault 实例——
        // 连接/自动重连可能在非主线程取凭据，不能走 assumeIsolated
        let vault = vaultGateway.vault
        credentialService = VaultCredentialService(gateway: { hostID, kind in
            vault?.read(hostID: hostID, kind: kind)
        })
        credentialService.start()
        CredentialBridge.provider = { hostID, kind in
            vault?.read(hostID: hostID, kind: kind)
        }
    }

    private func shutdownCredentialService() {
        credentialService.stop()
        CredentialBridge.provider = nil
    }

    var body: some Scene {
        WindowGroup {
            // 入口解锁门：未解锁只显示解锁界面（UITest 自动直通测试库）
            Group {
                if vaultUnlocked {
                    MainWindowView()
                } else {
                    UnlockView(gateway: vaultGateway) {
                        vaultUnlocked = true
                        installCredentialBridge()
                    }
                }
            }
            .environment(appState)
            .modelContainer(container)
            .environmentObject(updater)
            .environmentObject(vaultGateway)
            .task {
                if uiTest {
                    // UITest：临时目录测试库，固定主密码直通
                    setenv("TERMHUB_VAULT_PATH", "/tmp/termhub-uitest-vault.bin", 1)
                    if !vaultGateway.needsSetup {
                        _ = vaultGateway.unlock(masterPassword: "uitest")
                    } else {
                        _ = vaultGateway.create(masterPassword: "uitest")
                    }
                    vaultUnlocked = vaultGateway.isUnlocked
                    installCredentialBridge()
                }
            }
            .onDisappear {
                shutdownCredentialService()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                shutdownCredentialService()
            }
            .onChange(of: vaultGateway.isUnlocked) { _, unlocked in
                if !unlocked {
                    // 显式锁定：关闭全部 SSH 会话（凭据已不可用），回到解锁门
                    for session in appState.sessions.values {
                        appState.closeSession(hostID: session.ssh.host.id)
                    }
                    vaultUnlocked = false
                }
            }
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
