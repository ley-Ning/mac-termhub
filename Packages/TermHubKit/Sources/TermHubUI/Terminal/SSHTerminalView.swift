import SwiftUI
import AppKit
import SwiftTerm
import TermHubCore

/// 粘贴保护设置（UserDefaults 持久化，详情页设置菜单可改）
public enum PasteProtectSettings {
    public static var enabled: Bool {
        get {
            UserDefaults.standard.object(forKey: "pasteProtect.enabled") as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: "pasteProtect.enabled") }
    }

    /// 超过该行数触发确认（默认 3）
    public static var maxLines: Int {
        let value = UserDefaults.standard.integer(forKey: "pasteProtect.maxLines")
        return value > 0 ? value : 3
    }

    /// 超过该字符数触发确认（默认 200）
    public static var maxChars: Int {
        let value = UserDefaults.standard.integer(forKey: "pasteProtect.maxChars")
        return value > 0 ? value : 200
    }
}

/// 粘贴保护终端视图：多行/大段粘贴前弹确认对话框，
/// 可选「全部粘贴 / 仅粘贴首行 / 取消」。单行小段粘贴零打扰直通。
final class ProtectedTerminalView: TerminalView {
    override func paste(_ sender: Any) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            super.paste(sender)
            return
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let needsConfirm = PasteProtectSettings.enabled
            && (lines.count > PasteProtectSettings.maxLines || text.count > PasteProtectSettings.maxChars)
        guard needsConfirm else {
            super.paste(sender)
            return
        }

        switch confirmPaste(text: text, lines: lines) {
        case .all:
            sendAsPaste(text)
        case .firstLineOnly:
            // 首行去掉结尾 \r（CRLF 剪贴板），避免把回车带进去直接执行
            let firstLine = lines[0].replacingOccurrences(of: "\r", with: "")
            sendAsPaste(firstLine)
        case .cancel:
            break
        }
    }

    private enum PasteChoice {
        case all
        case firstLineOnly
        case cancel
    }

    /// AppKit 同步确认弹窗（MainActor 上调用）：预览前 10 行
    private func confirmPaste(text: String, lines: [Substring]) -> PasteChoice {
        let alert = NSAlert()
        alert.messageText = "粘贴 \(lines.count) 行 / \(text.count) 字符"
        alert.informativeText = "多行文本粘贴到终端可能被逐行执行，请确认内容。"

        let previewLines = lines.prefix(10)
        var preview = previewLines.joined(separator: "\n")
        if lines.count > 10 {
            preview += "\n…（其余 \(lines.count - 10) 行省略）"
        }
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 150))
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.isEditable = false
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.string = preview
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 160))
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll

        alert.addButton(withTitle: "全部粘贴")
        alert.addButton(withTitle: "仅粘贴首行")
        alert.addButton(withTitle: "取消")

        switch alert.runModal() {
        case .alertFirstButtonReturn: return .all
        case .alertSecondButtonReturn: return .firstLineOnly
        default: return .cancel
        }
    }

    /// 发送粘贴文本：Terminal.sendUserInput 是公开的宿主输入通道
    /// （insertText(_:replacementRange:isPaste:) 为 internal，子类不可达）；
    /// bracketed paste 模式下手动包 ESC[200~/ESC[201~，语义与原实现一致，
    /// 避免远端 shell 逐行回车执行。
    private func sendAsPaste(_ text: String) {
        var bytes = Array(text.utf8)
        if terminal.bracketedPasteMode {
            // ESC[200~ 与 ESC[201~
            bytes = [0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e] + bytes
                + [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]
        }
        terminal.sendUserInput(bytes[...])
    }
}

/// SwiftTerm 的 TerminalView 桥接到 SwiftUI
struct SSHTerminalView: NSViewRepresentable {
    @ObservedObject var terminal: TerminalSession

    func makeNSView(context: Context) -> TerminalView {
        let view = ProtectedTerminalView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        view.autoresizingMask = [.width, .height]
        view.terminalDelegate = context.coordinator
        applyTerminalTheme(view)
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        context.coordinator.terminalView = view
        terminal.attach { [weak view] bytes in
            view?.feed(byteArray: bytes)
        }
        // 主题热切换：设置页改配色后所有在用终端立即重着色
        NotificationCenter.default.addObserver(
            forName: ThemeSettings.terminalThemeChanged, object: nil, queue: .main
        ) { [weak view] _ in
            if let view { applyTerminalTheme(view) }
        }
        // 视图就绪后同步一次初始尺寸
        Task { @MainActor [weak view, weak terminal] in
            guard let view, let terminal else { return }
            terminal.remoteResize(cols: view.terminal.cols, rows: view.terminal.rows)
        }
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {}

    /// 应用终端配色主题（前景/背景/ANSI 16 色）
    @MainActor
    private func applyTerminalTheme(_ view: TerminalView) {
        let theme = ThemeSettings.shared.terminalTheme
        func termColor(_ rgb: (Double, Double, Double)) -> SwiftTerm.Color {
            SwiftTerm.Color(
                red: UInt16(rgb.0 * 65535),
                green: UInt16(rgb.1 * 65535),
                blue: UInt16(rgb.2 * 65535)
            )
        }
        view.setBackgroundColor(source: view.terminal, color: termColor(theme.background))
        view.setForegroundColor(source: view.terminal, color: termColor(theme.foreground))
        view.setCursorColor(
            source: view.terminal,
            color: termColor(theme.foreground),
            textColor: termColor(theme.background)
        )
        // 16 色（8 正常 + 8 亮色）一次性安装，索引顺序即 ANSI 0-15
        view.installColors(theme.ansi.map(termColor))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(terminal: terminal)
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        let terminal: TerminalSession
        weak var terminalView: TerminalView?

        init(terminal: TerminalSession) {
            self.terminal = terminal
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            terminal.sendToRemote(data)
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            terminal.remoteResize(cols: newCols, rows: newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            terminal.title = title.isEmpty ? "终端" : title
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func scrolled(source: TerminalView, position: Double) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link) else { return }
            NSWorkspace.shared.open(url)
        }

        func bell(source: TerminalView) {
            NSSound.beep()
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(content, forType: .string)
        }

        func clipboardRead(source: TerminalView) -> Data? {
            NSPasteboard.general.string(forType: .string)?.data(using: .utf8)
        }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
