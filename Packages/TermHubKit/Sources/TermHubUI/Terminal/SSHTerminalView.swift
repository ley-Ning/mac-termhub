import SwiftUI
import AppKit
import SwiftTerm
import TermHubCore

/// SwiftTerm 的 TerminalView 桥接到 SwiftUI
struct SSHTerminalView: NSViewRepresentable {
    @ObservedObject var terminal: TerminalSession

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        view.autoresizingMask = [.width, .height]
        view.terminalDelegate = context.coordinator
        view.configureNativeColors()
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        context.coordinator.terminalView = view
        terminal.attach { [weak view] bytes in
            view?.feed(byteArray: bytes)
        }
        // 视图就绪后同步一次初始尺寸
        Task { @MainActor [weak view, weak terminal] in
            guard let view, let terminal else { return }
            terminal.remoteResize(cols: view.terminal.cols, rows: view.terminal.rows)
        }
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {}

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
