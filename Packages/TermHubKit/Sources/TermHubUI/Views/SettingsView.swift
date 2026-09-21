import SwiftUI
import TermHubCore

/// 设置：外观模式 / 强调色 / 终端配色（即时生效，UserDefaults 持久化）
public struct SettingsView: View {
    @ObservedObject private var theme = ThemeSettings.shared

    public init() {}

    public var body: some View {
        TabView {
            appearanceTab.tabItem { Label("外观", systemImage: "paintbrush") }
            terminalTab.tabItem { Label("终端", systemImage: "terminal") }
            sessionTab.tabItem { Label("会话", systemImage: "clock.arrow.circlepath") }
        }
        .frame(width: 460, height: 420)
    }

    private var appearanceTab: some View {
        Form {
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
