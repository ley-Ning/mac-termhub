import Foundation
import SwiftUI

/// 主题设置：外观模式 / 强调色 / 终端配色（UserDefaults 持久化，全局生效）
public final class ThemeSettings: ObservableObject {
    public static let shared = ThemeSettings()

    private let defaults = UserDefaults.standard

    /// 外观模式
    public enum Appearance: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .system: return "跟随系统"
            case .light: return "浅色"
            case .dark: return "深色"
            }
        }

        public var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    /// 强调色（预置主题色）
    public struct AccentOption: Identifiable {
        public let id: String
        public let label: String
        public let color: Color

        public static let presets: [AccentOption] = [
            .init(id: "blue", label: "经典蓝", color: .blue),
            .init(id: "purple", label: "紫罗兰", color: .purple),
            .init(id: "pink", label: "品红", color: .pink),
            .init(id: "red", label: "绯红", color: .red),
            .init(id: "orange", label: "暖橙", color: .orange),
            .init(id: "green", label: "森绿", color: .green),
            .init(id: "teal", label: "青碧", color: .teal),
            .init(id: "indigo", label: "靛蓝", color: .indigo),
        ]
    }

    /// 终端配色方案：前景/背景/ANSI 16 色
    public struct TerminalTheme: Identifiable {
        public let id: String
        public let label: String
        public let foreground: (Double, Double, Double)
        public let background: (Double, Double, Double)
        public let ansi: [(Double, Double, Double)] // 16 色：8 正常 + 8 亮色

        public static let themes: [TerminalTheme] = [
            TerminalTheme(
                id: "default-dark", label: "默认深色",
                foreground: (0.9, 0.9, 0.92), background: (0.11, 0.11, 0.13),
                ansi: [
                    (0, 0, 0), (0.78, 0.18, 0.19), (0.29, 0.71, 0.35), (0.81, 0.65, 0.16),
                    (0.25, 0.47, 0.84), (0.66, 0.32, 0.78), (0.24, 0.62, 0.66), (0.78, 0.78, 0.8),
                    (0.45, 0.45, 0.5), (0.94, 0.35, 0.36), (0.47, 0.85, 0.53), (0.95, 0.8, 0.36),
                    (0.45, 0.65, 0.95), (0.8, 0.5, 0.9), (0.42, 0.8, 0.84), (0.95, 0.95, 0.96),
                ]
            ),
            TerminalTheme(
                id: "solarized-dark", label: "Solarized 深色",
                foreground: (0.39, 0.48, 0.51), background: (0.0, 0.17, 0.21),
                ansi: [
                    (0.0, 0.17, 0.21), (0.86, 0.31, 0.24), (0.52, 0.6, 0.0), (0.71, 0.54, 0.0),
                    (0.15, 0.55, 0.82), (0.83, 0.44, 0.0), (0.16, 0.63, 0.68), (0.93, 0.9, 0.84),
                    (0.03, 0.21, 0.26), (0.94, 0.39, 0.33), (0.6, 0.69, 0.05), (0.81, 0.64, 0.09),
                    (0.23, 0.63, 0.89), (0.9, 0.5, 0.05), (0.21, 0.71, 0.76), (1.0, 0.97, 0.91),
                ]
            ),
            TerminalTheme(
                id: "dracula", label: "Dracula",
                foreground: (0.97, 0.97, 0.99), background: (0.16, 0.17, 0.23),
                ansi: [
                    (0.19, 0.2, 0.25), (1.0, 0.33, 0.39), (0.29, 0.94, 0.55), (0.98, 0.75, 0.17),
                    (0.45, 0.57, 1.0), (0.72, 0.39, 1.0), (0.3, 0.87, 0.87), (0.94, 0.94, 0.96),
                    (0.39, 0.41, 0.49), (1.0, 0.47, 0.51), (0.55, 1.0, 0.72), (1.0, 0.86, 0.4),
                    (0.62, 0.72, 1.0), (0.87, 0.57, 1.0), (0.5, 1.0, 1.0), (1.0, 1.0, 1.0),
                ]
            ),
            TerminalTheme(
                id: "gruvbox", label: "Gruvbox 深色",
                foreground: (0.85, 0.8, 0.68), background: (0.16, 0.15, 0.13),
                ansi: [
                    (0.16, 0.15, 0.13), (0.76, 0.24, 0.19), (0.55, 0.55, 0.24), (0.85, 0.62, 0.16),
                    (0.32, 0.49, 0.55), (0.68, 0.37, 0.43), (0.35, 0.57, 0.4), (0.85, 0.8, 0.68),
                    (0.36, 0.32, 0.29), (0.88, 0.39, 0.31), (0.68, 0.69, 0.31), (0.98, 0.76, 0.24),
                    (0.42, 0.62, 0.7), (0.81, 0.47, 0.54), (0.44, 0.71, 0.5), (0.95, 0.92, 0.82),
                ]
            ),
            TerminalTheme(
                id: "light", label: "浅色纸面",
                foreground: (0.13, 0.13, 0.14), background: (1.0, 1.0, 1.0),
                ansi: [
                    (0.13, 0.13, 0.14), (0.7, 0.15, 0.15), (0.1, 0.45, 0.15), (0.65, 0.45, 0.05),
                    (0.1, 0.3, 0.75), (0.55, 0.2, 0.65), (0.1, 0.5, 0.55), (0.3, 0.3, 0.32),
                    (0.5, 0.5, 0.53), (0.85, 0.25, 0.25), (0.2, 0.6, 0.25), (0.8, 0.6, 0.1),
                    (0.25, 0.45, 0.85), (0.65, 0.3, 0.75), (0.2, 0.6, 0.65), (0.15, 0.15, 0.16),
                ]
            ),
        ]
    }

    private enum Keys {
        static let appearance = "theme.appearance"
        static let accent = "theme.accent"
        static let terminal = "theme.terminal"
    }

    @Published public var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    @Published public var accentID: String {
        didSet { defaults.set(accentID, forKey: Keys.accent) }
    }

    @Published public var terminalThemeID: String {
        didSet { defaults.set(terminalThemeID, forKey: Keys.terminal) }
    }

    public var accentColor: Color {
        AccentOption.presets.first { $0.id == accentID }?.color ?? .blue
    }

    public var terminalTheme: TerminalTheme {
        TerminalTheme.themes.first { $0.id == terminalThemeID } ?? .themes[0]
    }

    /// 终端主题变化通知（SSHTerminalView 监听后重设颜色）
    public static let terminalThemeChanged = Notification.Name("termhub.terminalThemeChanged")

    private init() {
        appearance = Appearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        accentID = defaults.string(forKey: Keys.accent) ?? "blue"
        terminalThemeID = defaults.string(forKey: Keys.terminal) ?? "default-dark"
    }
}
