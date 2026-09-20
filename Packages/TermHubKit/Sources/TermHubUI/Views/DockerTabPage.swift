import SwiftUI
import TermHubCore

/// Docker 面板：容器列表 + 操作 + 资源占用 + 镜像 + 日志
public struct DockerTabPage: View {
    @ObservedObject private var hostSession: HostSession
    @StateObject private var docker: DockerService

    @State private var section: Section = .containers
    @State private var selectedContainer: DockerContainer?
    @State private var logsContainer: DockerContainer?

    public enum Section: String, CaseIterable, Identifiable {
        case containers = "容器"
        case images = "镜像"

        public var id: String { rawValue }
    }

    public init(hostSession: HostSession) {
        self.hostSession = hostSession
        _docker = StateObject(wrappedValue: DockerService(ssh: hostSession.ssh))
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            switch docker.availability {
            case .unavailable(let reason):
                unavailableView(reason)
            default:
                content
            }
        }
        .sheet(item: $logsContainer) { container in
            DockerLogsView(ssh: hostSession.ssh, container: container)
        }
        .onAppear {
            guard hostSession.ssh.phase.isAlive else { return }
            docker.startPolling()
        }
        .onDisappear {
            docker.stopPolling()
        }
        .onChange(of: hostSession.ssh.phase) { _, phase in
            if phase.isAlive {
                if docker.availability == .unknown {
                    docker.startPolling()
                }
            } else {
                docker.stopPolling()
            }
        }
    }

    // MARK: - 工具条

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $section) {
                ForEach(Section.allCases) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)

            switch docker.availability {
            case .available(let version):
                Label("Docker \(version)", systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            case .checking:
                ProgressView().controlSize(.small)
            case .unknown:
                Text("未检测").font(.caption).foregroundStyle(.secondary)
            case .unavailable:
                EmptyView()
            }

            Spacer()

            if docker.isRefreshing {
                ProgressView().controlSize(.small)
            }
            Button {
                Task {
                    if docker.availability == .unknown {
                        await docker.checkAvailability()
                    }
                    await docker.refresh()
                    await docker.refreshImages()
                }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .containers:
            containersList
        case .images:
            imagesTable
        }
    }

    // MARK: - 容器列表

    private var containersList: some View {
        List(docker.containers) { c in
            containerRow(c)
                .padding(.vertical, 2)
                .contextMenu { containerMenu(c) }
                .onTapGesture(count: 2) { logsContainer = c }
        }
        .listStyle(.inset)
        .overlay {
            if docker.containers.isEmpty && !docker.isRefreshing {
                ContentUnavailableView(
                    "没有容器",
                    systemImage: "cube.box",
                    description: Text("docker ps 没有返回任何容器")
                )
            }
        }
    }

    private func containerRow(_ c: DockerContainer) -> some View {
        // 面板宽度有限（~520pt），按两行卡片排布：上行名称+资源，下行镜像/状态/端口，全部弹性宽度
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(c.isRunning ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(c.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(c.image)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(c.status)
                    if !c.ports.isEmpty {
                        Text("·")
                        Text(c.ports)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let stat = docker.stats[c.id] {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("CPU \(stat.cpuText)")
                        .font(.caption2).monospacedDigit()
                        .foregroundStyle(.secondary)
                    statBar(
                        value: stat.cpuPercent,
                        max: 100,
                        text: ""
                    )
                    .frame(width: 64)
                    Text(stat.memText)
                        .font(.caption2).monospacedDigit()
                        .foregroundStyle(.secondary)
                    statBar(
                        value: Double(stat.memUsedBytes),
                        max: Double(max(stat.memLimitBytes, 1)),
                        text: ""
                    )
                    .frame(width: 64)
                }
            }
        }
    }

    @ViewBuilder
    private func containerMenu(_ c: DockerContainer) -> some View {
        Button("查看日志…") { logsContainer = c }
        Divider()
        if c.isRunning {
            Button("重启") { Task { await docker.perform(.restart, on: c) } }
            Button("停止") { Task { await docker.perform(.stop, on: c) } }
        } else {
            Button("启动") { Task { await docker.perform(.start, on: c) } }
        }
    }

    @ViewBuilder
    private func statBar(value: Double, max: Double, text: String) -> some View {
        let ratio = max > 0 ? min(value / max, 1) : 0
        VStack(alignment: .leading, spacing: 2) {
            Text(text).font(.caption2).monospacedDigit()
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(ratio > 0.8 ? Color.red : ratio > 0.5 ? Color.orange : Color.accentColor)
                        .frame(width: geo.size.width * ratio)
                }
            }
            .frame(height: 3)
        }
        .padding(.vertical, 2)
    }

    // MARK: - 镜像列表

    private var imagesTable: some View {
        Table(docker.images) {
            TableColumn("镜像") { img in
                Text(img.displayTag).font(.system(size: 12, weight: .medium))
            }
            TableColumn("ID") { img in
                Text(img.id).font(.caption).foregroundStyle(.secondary)
            }
            TableColumn("大小") { img in
                Text(ByteCountFormatter.string(fromByteCount: img.sizeBytes, countStyle: .file))
                    .font(.caption).monospacedDigit()
            }
            TableColumn("创建时间") { img in
                Text(img.createdAt).font(.caption)
            }
        }
        .overlay {
            if docker.images.isEmpty && !docker.isRefreshing {
                ContentUnavailableView("没有镜像", systemImage: "photo.on.rectangle.angled")
            }
        }
        .task {
            if docker.images.isEmpty {
                await docker.refreshImages()
            }
        }
    }

    private func unavailableView(_ reason: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "xmark.octagon")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Docker 不可用").font(.headline)
            Text(reason.isEmpty ? "服务器上没有 docker 命令或守护进程未运行" : reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
                .multilineTextAlignment(.center)
            Button("重试") {
                docker.availability = .unknown
                docker.startPolling()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 日志窗口

struct DockerLogsView: View {
    @ObservedObject var ssh: SSHSession
    let container: DockerContainer

    @StateObject private var streamer = DockerLogStreamer()
    @State private var follow = true
    @State private var tailCount = 200
    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(container.displayName)
                    .font(.headline)
                Text(container.image)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("跟随", isOn: $follow)
                    .onChange(of: follow) { _, newValue in
                        if newValue {
                            restart()
                        } else {
                            streamer.stop()
                        }
                    }
                Toggle("自动滚动", isOn: $autoScroll)
                Picker("", selection: $tailCount) {
                    Text("100 行").tag(100)
                    Text("500 行").tag(500)
                    Text("2000 行").tag(2000)
                }
                .frame(width: 110)
                .onChange(of: tailCount) { _, _ in restart() }
                Button("清屏") { streamer.clear() }
                Button("导出…") { exportLogs() }
            }
            .padding(10)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(streamer.lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 0.5)
                                .id(index)
                        }
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: streamer.lines.count) { _, count in
                    if autoScroll {
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            }

            if let error = streamer.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(4)
            }

            Divider()
            HStack {
                Text("\(streamer.lines.count) 行")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(8)
        }
        .frame(minWidth: 680, minHeight: 460)
        .onAppear(perform: restart)
        .onDisappear { streamer.stop() }
    }

    private func restart() {
        streamer.start(ssh: ssh, container: container, tail: tailCount, follow: follow)
    }

    private func exportLogs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(container.displayName.replacingOccurrences(of: "/", with: "_")).log"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? Data(streamer.fullText.utf8).write(to: url)
        }
    }
}
