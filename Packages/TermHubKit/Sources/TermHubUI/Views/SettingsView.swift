import SwiftUI
import AppKit
import TermHubCore


/// 设置：外观模式 / 强调色 / 终端配色 / 语言（即时生效，UserDefaults 持久化）
public struct SettingsView: View {
    @ObservedObject private var theme = ThemeSettings.shared
    @State private var language = ThemeSettings.AppLanguage.current

    public init() {}

    public var body: some View {
        TabView {
            appearanceTab.tabItem { Label("外观", systemImage: "paintbrush") }
            terminalTab.tabItem { Label("终端", systemImage: "terminal") }
            sessionTab.tabItem { Label("会话", systemImage: "clock.arrow.circlepath") }
            securityTab.tabItem { Label("安全", systemImage: "lock.shield") }
        }
        .frame(width: 460, height: 420)
    }

    private var appearanceTab: some View {
        Form {
            Section("语言 / Language") {
                Picker("语言", selection: $language) {
                    ForEach(ThemeSettings.AppLanguage.allCases) { lang in
                        Text(lang.label).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if language != ThemeSettings.AppLanguage.current {
                    HStack(spacing: 8) {
                        Label("重启后生效", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("重启") {
                            language.apply()
                            // 借热更新的重启路径：退出并以新语言拉起
                            let repo = NSString(string: "~/WorkBuddy/TermHub").expandingTildeInPath
                            let proc = Process()
                            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
                            proc.arguments = ["-c", "sleep 1; open '\(repo)/build/TermHub.app'"]
                            try? proc.run()
                            NSApplication.shared.terminate(nil)
                        }
                    }
                }
            }
            Section("外观模式") {
                Picker("模式", selection: $theme.appearance) {
                    ForEach(ThemeSettings.Appearance.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Section("强调色") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 10) {
                    ForEach(ThemeSettings.AccentOption.presets) { option in
                        Button {
                            theme.accentID = option.id
                        } label: {
                            ZStack {
                                Circle().fill(option.color).frame(width: 26, height: 26)
                                if theme.accentID == option.id {
                                    Circle().strokeBorder(.white, lineWidth: 2.5)
                                        .frame(width: 30, height: 30)
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .help(option.label)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, -8)
    }

    private var terminalTab: some View {
        Form {
            Section("终端配色") {
                Picker("方案", selection: $theme.terminalThemeID) {
                    ForEach(TermHubSettingsTerminalThemeOptions.options) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .onChange(of: theme.terminalThemeID) { _, _ in
                    NotificationCenter.default.post(name: ThemeSettings.terminalThemeChanged, object: nil)
                }
            }
            Section {
                // 配色预览
                HStack(spacing: 0) {
                    ForEach(0 ..< 8, id: \.self) { i in
                        Rectangle().fill(previewColor(i)).frame(height: 26)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                HStack(spacing: 0) {
                    ForEach(8 ..< 16, id: \.self) { i in
                        Rectangle().fill(previewColor(i)).frame(height: 26)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } header: {
                Text("预览（16 色）")
            }
        }
        .formStyle(.grouped)
        .padding(.top, -8)
    }

    @EnvironmentObject private var vaultGateway: VaultGateway
    @State private var showingChangePassword = false
    @State private var oldPassword = ""
    @State private var newPassword1 = ""
    @State private var newPassword2 = ""

    private var securityTab: some View {
        Form {
            Section("凭据库") {
                Label("SSH 密码保存在本机加密文件中，仅主密码可解密", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("修改主密码…") { showingChangePassword = true }
                Button("立即锁定（关闭全部连接）", role: .destructive) {
                    vaultGateway.lock()
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, -8)
        .sheet(isPresented: $showingChangePassword) {
            VStack(spacing: 12) {
                Text("修改主密码").font(.headline)
                SecureField("当前主密码", text: $oldPassword).frame(width: 260)
                SecureField("新主密码（≥6 位）", text: $newPassword1).frame(width: 260)
                SecureField("再次输入新主密码", text: $newPassword2).frame(width: 260)
                if let error = vaultGateway.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Button("取消", role: .cancel) {
                        showingChangePassword = false
                        oldPassword = ""; newPassword1 = ""; newPassword2 = ""
                    }
                    Spacer()
                    Button("确认修改") {
                        guard vaultGateway.unlock(masterPassword: oldPassword),
                              newPassword1.count >= 6, newPassword1 == newPassword2 else { return }
                        if vaultGateway.changeMasterPassword(to: newPassword1) {
                            showingChangePassword = false
                            oldPassword = ""; newPassword1 = ""; newPassword2 = ""
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(oldPassword.isEmpty || newPassword1.count < 6 || newPassword1 != newPassword2)
                }
            }
            .padding(24)
            .frame(width: 360)
        }
    }

    private var sessionTab: some View {
        Form {
            Section("连接") {
                Toggle("意外掉线自动重连", isOn: Binding(
                    get: { SSHSessionSettings.reconnectEnabled },
                    set: { SSHSessionSettings.reconnectEnabled = $0 }
                ))
                Toggle("心跳保活（防空闲断开）", isOn: Binding(
                    get: { SSHSessionSettings.keepaliveEnabled },
                    set: { SSHSessionSettings.keepaliveEnabled = $0 }
                ))
                Picker("心跳间隔", selection: Binding(
                    get: { SSHSessionSettings.keepaliveInterval },
                    set: { SSHSessionSettings.keepaliveInterval = $0 }
                )) {
                    ForEach([15.0, 30.0, 60.0], id: \.self) { seconds in
                        Text("\(Int(seconds)) 秒").tag(seconds)
                    }
                }
            }
            Section("终端") {
                Toggle("多行粘贴前确认", isOn: Binding(
                    get: { PasteProtectSettings.enabled },
                    set: { PasteProtectSettings.enabled = $0 }
                ))
            }
        }
        .formStyle(.grouped)
        .padding(.top, -8)
    }

    private func previewColor(_ index: Int) -> Color {
        let rgb = theme.terminalTheme.ansi[index]
        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }
}

/// 终端主题选项桥（保持 Picker 的 id 简洁）
enum TermHubSettingsTerminalThemeOptions {
    struct Option: Identifiable {
        let id: String
        let label: String
    }

    static let options: [Option] = ThemeSettings.TerminalTheme.themes.map { .init(id: $0.id, label: $0.label) }
}
