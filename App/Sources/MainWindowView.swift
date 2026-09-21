import SwiftUI
import SwiftData
import TermHubCore
import TermHubUI

struct MainWindowView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Query private var hosts: [SSHHost]

    @State private var showingQuickSwitcher = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            detailContent
        }
        // Tahoe 液态玻璃默认让侧栏浮于内容之上（内容延伸到侧栏下方并打安全区避让），
        // 会把终端 pane 挤成 ~100px；balanced 是经典并排布局
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 980, minHeight: 620)
        .hostKeyConfirmAlert(appState: appState)
        .onAppear {
            // 主机目录快照：渲染期更新缓存，供跳板链解析（不在选中回调里同步 fetch，防 SwiftData trap）
            appState.updateHostCatalog(hosts.map(\.snapshot))
            UITestSupport.runIfNeeded(appState: appState, modelContext: modelContext)
        }
        .onChange(of: hosts.map(\.id)) { _, _ in
            appState.updateHostCatalog(hosts.map(\.snapshot))
        }
        .onReceive(NotificationCenter.default.publisher(for: .termHubQuickSwitch)) { _ in
            showingQuickSwitcher = true
        }
        .sheet(isPresented: $showingQuickSwitcher) {
            QuickSwitcherView()
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if let id = appState.selectedHostID,
           let session = appState.sessions[id] {
            HostDetailView(session: session)
                .id(id) // 切主机时强制重建视图
        } else {
            WelcomeView()
        }
    }
}

private struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("TermHub")
                .font(.largeTitle).fontWeight(.bold)
            Text("在侧边栏添加你的第一台服务器")
                .foregroundStyle(.secondary)
            Text("左侧 + 按钮新增主机，点选主机即连接")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// TOFU 指纹确认弹窗
extension View {
    @ViewBuilder
    func hostKeyConfirmAlert(appState: AppState) -> some View {
        let isPresented = Binding(
            get: { appState.hostKeyPrompt != nil },
            set: { if !$0 { appState.resolveHostKeyPrompt(accepted: false) } }
        )
        self.alert(
            "首次连接该主机",
            isPresented: isPresented,
            presenting: appState.hostKeyPrompt
        ) { _ in
            Button("信任并连接") { appState.resolveHostKeyPrompt(accepted: true) }
            Button("拒绝", role: .cancel) { appState.resolveHostKeyPrompt(accepted: false) }
        } message: { prompt in
            Text("""
            主机 \(prompt.facts.host):\(prompt.facts.port) 的指纹：
            \(prompt.facts.fingerprint)
            （密钥类型：\(prompt.facts.keyType)）
            确认无误后信任。指纹变化的主机会自动拒绝连接。
            """)
        }
    }
}
