import SwiftUI
import TermHubCore

/// 进程/端口监控页：ps aux 表（列头排序+过滤）+ 监听端口列表 + kill 操作
public struct ProcessTabPage: View {
    @ObservedObject private var hostSession: HostSession
    @StateObject private var service: ProcessService

    private enum Tab: String, CaseIterable, Identifiable {
        case processes = "进程"
        case ports = "监听端口"

        var id: String { rawValue }
    }

    @State private var tab: Tab = .processes
    @State private var searchText = ""
    @State private var sortOrder: [KeyPathComparator] = [
        KeyPathComparator(\RemoteProcess.cpuPercent, order: .reverse)
    ]
    @State private var killTarget: RemoteProcess?
    @State private var killForce = false

    public init(hostSession: HostSession) {
        self.hostSession = hostSession
        _service = StateObject(wrappedValue: ProcessService(ssh: hostSession.ssh))
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            switch tab {
            case .processes:
                processTable
            case .ports:
                portList
            }
        }
        .onAppear {
            if hostSession.ssh.phase.isAlive {
                service.startPolling()
            }
        }
        .onDisappear {
            service.stopPolling()
        }
        .onChange(of: hostSession.ssh.phase) { _, phase in
            if phase.isAlive {
                service.startPolling()
            } else {
                service.stopPolling()
            }
        }
        .alert("结束进程", isPresented: Binding(
            get: { killTarget != nil },
            set: { if !$0 { killTarget = nil } }
        )) {
            Button("结束", role: .destructive) {
                if let target = killTarget {
                    Task { await service.kill(pid: target.pid, force: killForce) }
                }
                killTarget = nil
            }
            Button("取消", role: .cancel) { killTarget = nil }
        } message: {
            Text(killForce
                 ? "强制结束（kill -9）PID \(killTarget?.pid ?? 0)（\(killTarget?.command.prefix(60) ?? "")）？进程将立即被内核终止。"
                 : "发送 kill 信号结束 PID \(killTarget?.pid ?? 0)（\(killTarget?.command.prefix(60) ?? "")）？")
        }
        .overlay(alignment: .bottom) {
            if let error = service.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(6)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(.bottom, 8)
            }
        }
    }

    // MARK: - 工具条

    private var toolbar: some View {
        HStack(spacing: 6) {
            Picker("视图", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)

            TextField("过滤（命令/用户/PID/端口）", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)

            if service.isRefreshing {
                ProgressView().controlSize(.small)
            }

            Button {
                Task { await service.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("立即刷新")
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - 进程表

    private var filteredProcesses: [RemoteProcess] {
        let sorted = service.processes.sorted(using: sortOrder)
        guard !searchText.isEmpty else { return sorted }
        let q = searchText.lowercased()
        return sorted.filter {
            $0.command.lowercased().contains(q)
                || $0.user.lowercased().contains(q)
                || String($0.pid).contains(q)
        }
    }

    private var processTable: some View {
        Table(filteredProcesses, sortOrder: $sortOrder) {
            TableColumn("PID", value: \.pid) { process in
                Text(String(process.pid))
                    .font(.system(size: 12, design: .monospaced))
            }
            .width(64)

            TableColumn("用户", value: \.user) { process in
                Text(process.user)
                    .font(.caption)
                    .lineLimit(1)
                    .help(process.user)
            }
            .width(90)

            TableColumn("CPU%", value: \.cpuPercent) { process in
                Text(String(format: "%.1f", process.cpuPercent))
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(process.cpuPercent > 80 ? .red : process.cpuPercent > 40 ? .orange : .primary)
            }
            .width(58)

            TableColumn("MEM%", value: \.memPercent) { process in
                Text(String(format: "%.1f", process.memPercent))
                    .font(.caption).monospacedDigit()
            }
            .width(58)

            TableColumn("RSS", value: \.rssKB) { process in
                Text(process.rssText)
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(80)

            TableColumn("状态", value: \.stat) { process in
                Text(process.stat)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(56)

            TableColumn("时间", value: \.time) { process in
                Text(process.time)
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(64)

            TableColumn("命令") { process in
                Text(process.command)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(process.command)
            }
        }
        .contextMenu(forSelectionType: RemoteProcess.self) { selection in
            if let process = selection.first {
                Divider()
                Button("结束进程 (kill)…", role: .destructive) {
                    killForce = false
                    killTarget = process
                }
                Button("强制结束 (kill -9)…", role: .destructive) {
                    killForce = true
                    killTarget = process
                }
                Divider()
                Button("复制命令行") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(process.command, forType: .string)
                }
            }
        } primaryAction: { _ in }
        .overlay(alignment: .bottom) {
            // 非 root 下他人进程信息受限的说明（与资源面板口径一致）
            VStack(spacing: 2) {
                Text("非 root 用户下，他人进程的端口归属显示为 -，属正常现象")
                Text("仅展示 CPU 占用前 \(ProcessParser.processLimit) 个进程")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.bottom, 4)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 监听端口

    private var filteredPorts: [ListenPort] {
        guard !searchText.isEmpty else { return service.listenPorts }
        let q = searchText.lowercased()
        return service.listenPorts.filter {
            String($0.port).contains(q)
                || $0.localAddress.lowercased().contains(q)
                || ($0.process?.lowercased().contains(q) ?? false)
                || $0.proto.lowercased().contains(q)
        }
    }

    private var portList: some View {
        Table(filteredPorts) {
            TableColumn("端口") { port in
                Text(String(port.port))
                    .font(.system(size: 12, design: .monospaced))
            }
            .width(64)

            TableColumn("协议") { port in
                Text(port.proto)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .width(56)

            TableColumn("本地地址") { port in
                Text(port.localAddress)
                    .font(.system(size: 11, design: .monospaced))
            }
            .width(120)

            TableColumn("进程") { port in
                if let process = port.process {
                    Text(process).font(.caption)
                } else {
                    Text("-").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .overlay(alignment: .bottom) {
            Text(service.listenPorts.isEmpty ? "无监听端口数据（或服务器无 ss/netstat 命令）" : "非 root 用户下他人进程显示为 -")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity)
        }
    }
}
