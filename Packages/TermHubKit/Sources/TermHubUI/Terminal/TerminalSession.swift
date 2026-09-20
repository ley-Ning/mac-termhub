import SwiftUI
import Combine
import SwiftTerm
import NIO
import NIOSSH
import Citadel
import TermHubCore

/// 一个终端标签页的后端：监控连接状态，连接后在该连接上开 PTY shell 通道
@MainActor
public final class TerminalSession: ObservableObject, Identifiable {
    public enum Phase: Equatable {
        case waitingConnect
        case starting
        case running
        case failed(String)
        case closed
    }

    public let id = UUID()
    public let ssh: SSHSession

    @Published public private(set) var phase: Phase = .waitingConnect
    @Published public var title: String = "终端"

    // 与 SwiftTerm 视图的桥
    var feedHandler: ((ArraySlice<UInt8>) -> Void)?
    private var pendingFirstResize: ((Int, Int) -> Void)?
    private var stdinWriter: TTYStdinWriter?
    private var ptyTask: Task<Void, Never>?
    private var phaseCancellable: AnyCancellable?
    private var reportedCols = 80
    private var reportedRows = 24

    init(ssh: SSHSession) {
        self.ssh = ssh
        let sshPub = ssh
        phaseCancellable = sshPub.$phase.sink { [weak self] phase in
            guard let self else { return }
            self.sshPhaseChanged(phase)
        }
    }

    deinit {
        phaseCancellable?.cancel()
    }

    private func sshPhaseChanged(_ phase: SSHSession.Phase) {
        switch phase {
        case .connected:
            if ptyTask == nil {
                startPTY()
            }
        case .failed(let message):
            switch self.phase {
            case .running, .starting:
                self.phase = .closed
                ptyTask?.cancel()
                ptyTask = nil
                stdinWriter = nil
            case .waitingConnect, .closed:
                self.phase = .failed(message)
            case .failed:
                break
            }
        case .closed:
            if case .running = self.phase {
                self.phase = .closed
                ptyTask?.cancel()
                ptyTask = nil
                stdinWriter = nil
            }
        case .idle, .connecting:
            if case .closed = self.phase {
                self.phase = .waitingConnect
            }
        }
    }

    private func startPTY() {
        guard let client = ssh.activeClient else { return }
        phase = .starting
        let cols = reportedCols
        let rows = reportedRows

        ptyTask = Task { [weak self] in
            do {
                let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: "xterm-256color",
                    terminalCharacterWidth: cols,
                    terminalRowHeight: rows,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0,
                    terminalModes: .init([.ECHO: 1, .ICRNL: 1, .ONLCR: 1])
                )

                try await client.withPTY(request) { inbound, outbound in
                    guard let self else { return }
                    await MainActor.run {
                        self.stdinWriter = outbound
                        self.phase = .running
                        self.pendingFirstResize?(cols, rows)
                        self.pendingFirstResize = nil
                    }

                    // 循环读取远端输出，喂给终端视图
                    for try await output in inbound {
                        if Task.isCancelled { break }
                        let bytes: [UInt8]
                        switch output {
                        case .stdout(let buffer): bytes = Array(buffer.readableBytesView)
                        case .stderr(let buffer): bytes = Array(buffer.readableBytesView)
                        }
                        guard !bytes.isEmpty else { continue }
                        await MainActor.run {
                            self.feedHandler?(bytes[...])
                        }
                    }
                }
                await MainActor.run {
                    self?.ptyTask = nil
                    guard let self else { return }
                    if case .running = self.phase { self.phase = .closed }
                }
            } catch {
                await MainActor.run {
                    self?.ptyTask = nil
                    guard let self else { return }
                    if !Task.isCancelled {
                        self.phase = .failed(error.localizedDescription)
                    } else {
                        self.phase = .closed
                    }
                }
            }
        }
    }

    // MARK: - 供终端视图调用

    /// 键盘输入 → SSH stdin
    func sendToRemote(_ data: ArraySlice<UInt8>) {
        guard case .running = phase else { return }
        guard let writer = stdinWriter else { return }
        var buffer = ByteBuffer()
        buffer.writeBytes(data)
        Task.detached {
            try? await writer.write(buffer)
        }
    }

    /// 视图尺寸变化 → window-change
    func remoteResize(cols: Int, rows: Int) {
        reportedCols = cols
        reportedRows = rows
        guard let writer = stdinWriter else {
            // PTY 建立后第一时间同步真实尺寸
            pendingFirstResize = { [weak self] _, _ in
                self?.remoteResize(cols: cols, rows: rows)
            }
            return
        }
        Task.detached {
            try? await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
        }
    }

    func attach(feed: @escaping (ArraySlice<UInt8>) -> Void) {
        feedHandler = feed
    }

    /// 手动重开 shell（连接仍在、上个通道已结束/被关）
    public func restart() {
        guard ssh.phase.isAlive, ptyTask == nil else { return }
        switch phase {
        case .running, .starting:
            return
        default:
            break
        }
        startPTY()
    }

    /// 关闭该终端（发 exit 让 shell 正常退出，通道随之关闭）
    func stop() {
        ptyTask?.cancel()
        ptyTask = nil
        if case .running = phase {
            var buffer = ByteBuffer()
            buffer.writeString("exit\n")
            let writer = stdinWriter
            Task.detached {
                try? await writer?.write(buffer)
            }
            stdinWriter = nil
            phase = .closed
        }
    }
}
