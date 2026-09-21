import SwiftUI
import TermHubCore

/// 系统资源页：CPU/内存/网络/磁盘/负载 实时面板
public struct SystemStatsTabPage: View {
    @ObservedObject private var hostSession: HostSession
    @StateObject private var stats: ServerStatsService
    @State private var pollSeconds: Double = 1

    public init(hostSession: HostSession) {
        self.hostSession = hostSession
        _stats = StateObject(wrappedValue: ServerStatsService(ssh: hostSession.ssh))
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                gaugeRow
                networkCard
                diskCard
                diskIOCard
            }
            .padding(14)
            .frame(maxWidth: .infinity)
        }
        .overlay {
            if !stats.isRunning {
                ContentUnavailableView(
                    "等待连接",
                    systemImage: "gauge.with.dots.needle.bottom.50percent",
                    description: Text("连接主机后自动开始采集（只读 /proc、free、df，不装任何远端程序）")
                )
            }
        }
        .onAppear {
            stats.pollInterval = pollSeconds
            if hostSession.ssh.phase.isAlive {
                stats.start()
            }
        }
        .onDisappear {
            stats.stop()
        }
        .onChange(of: hostSession.ssh.phase) { _, phase in
            if phase.isAlive {
                stats.start()
            } else {
                stats.stop()
                stats.reset()
            }
        }
        .overlay(alignment: .bottom) {
            if let error = stats.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(6)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(.bottom, 8)
            }
        }
    }

    // MARK: - 顶部概览

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 16) {
                Label(stats.stats.uptimeText, systemImage: "clock")
                Spacer()
                Picker("刷新", selection: $pollSeconds) {
                    Text("1s").tag(1.0)
                    Text("2s").tag(2.0)
                    Text("3s").tag(3.0)
                    Text("5s").tag(5.0)
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
                .onChange(of: pollSeconds) { _, newValue in
                    stats.pollInterval = newValue
                }
            }
            Label(
                String(format: "负载 %.2f / %.2f / %.2f", stats.stats.loadAvg1, stats.stats.loadAvg5, stats.stats.loadAvg15),
                systemImage: "speedometer"
            )
        }
        .font(.caption)
        .padding(.horizontal, 4)
    }

    // MARK: - CPU / 内存 仪表

    private var gaugeRow: some View {
        HStack(spacing: 14) {
            gaugeCard(
                title: "CPU",
                value: stats.stats.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—",
                ratio: (stats.stats.cpuPercent ?? 0) / 100,
                history: stats.cpuHistory,
                historyMax: 100,
                historyFormatter: { String(format: "%.0f%%", $0) }
            )

            gaugeCard(
                title: "内存",
                value: "\(formatBytes(stats.stats.memUsedBytes)) / \(formatBytes(stats.stats.memTotalBytes))",
                ratio: stats.stats.memPercent / 100,
                history: stats.memHistory,
                historyMax: 100,
                historyFormatter: { String(format: "%.0f%%", $0) },
                footnote: stats.stats.swapTotalBytes > 0
                    ? "Swap 已用 \(formatBytes(stats.stats.swapUsedBytes)) / \(formatBytes(stats.stats.swapTotalBytes))"
                    : nil
            )
        }
    }

    private func gaugeCard(
        title: String,
        value: String,
        ratio: Double,
        history: [Double],
        historyMax: Double,
        historyFormatter: @escaping (Double) -> String,
        footnote: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(value)
                    .font(.system(.title3, design: .rounded))
                    .monospacedDigit().bold()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: 8)
                Circle()
                    .trim(from: 0, to: min(max(ratio, 0), 1))
                    .stroke(ratio > 0.85 ? .red : ratio > 0.6 ? .orange : .accentColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.4), value: ratio)
                Text(String(format: "%.0f%%", ratio * 100))
                    .font(.system(.caption, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 110)

            if let footnote {
                Text(footnote).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 网络

    private var networkCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("网络").font(.headline)
                Spacer()
                HStack(spacing: 14) {
                    Label(formatRate(stats.stats.netRxBytesPerSec), systemImage: "arrow.down")
                        .foregroundStyle(.blue)
                    Label(formatRate(stats.stats.netTxBytesPerSec), systemImage: "arrow.up")
                        .foregroundStyle(.orange)
                }
                .font(.caption).monospacedDigit()
            }
            chart(history: stats.netRxHistory, color: .blue)
            chart(history: stats.netTxHistory, color: .orange)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 磁盘

    private var diskCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("磁盘").font(.headline)
            if stats.stats.disks.isEmpty {
                Text("（无数据）").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(stats.stats.disks) { disk in
                HStack(spacing: 10) {
                    Text(disk.mount)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .frame(minWidth: 40, maxWidth: 140, alignment: .leading)
                        .help(disk.filesystem)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule()
                                .fill(disk.usedPercent > 85 ? Color.red : disk.usedPercent > 70 ? Color.orange : Color.accentColor)
                                .frame(width: geo.size.width * disk.usedPercent / 100)
                        }
                    }
                    .frame(height: 8)
                    Text("\(formatBytes(disk.usedBytes)) / \(formatBytes(disk.totalBytes))（\(String(format: "%.0f", disk.usedPercent))%）")
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 磁盘 I/O（速率 / IOPS / 平均耗时 / 繁忙率）

    private var diskIOCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("磁盘 I/O").font(.headline)
                Spacer()
                Text("await = 平均耗时 · util = 繁忙率")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if stats.stats.diskIO.isEmpty, !stats.isRunning {
                Text("连接后自动采集 /proc/diskstats")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(stats.stats.diskIO) { io in
                HStack(alignment: .top, spacing: 10) {
                    Text(io.device)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .frame(minWidth: 44, maxWidth: 90, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 10) {
                            Label(formatRate(io.readBytesPerSec), systemImage: "arrow.down")
                                .foregroundStyle(.blue)
                            Label(formatRate(io.writeBytesPerSec), systemImage: "arrow.up")
                                .foregroundStyle(.orange)
                        }
                        .font(.caption).monospacedDigit()
                        HStack(spacing: 10) {
                            Text("IOPS 读 \(String(format: "%.0f", io.readsPerSec)) · 写 \(String(format: "%.0f", io.writesPerSec))")
                            if let awaitMs = io.awaitMs {
                                Text("耗时 \(String(format: "%.1f", awaitMs)) ms")
                            } else {
                                Text("耗时 —")
                            }
                        }
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(String(format: "%.0f%%", io.utilPercent ?? 0))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.quaternary)
                                Capsule()
                                    .fill((io.utilPercent ?? 0) > 80 ? Color.red : (io.utilPercent ?? 0) > 50 ? Color.orange : Color.accentColor)
                                    .frame(width: geo.size.width * min((io.utilPercent ?? 0) / 100, 1))
                            }
                        }
                        .frame(width: 64, height: 6)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 迷你趋势图

    private func chart(history: [Double], color: Color) -> some View {
        Canvas { context, size in
            guard history.count > 1 else { return }
            let maxValue = max(history.max() ?? 1, 1)
            let stepX = size.width / CGFloat(max(history.count - 1, 1))
            var path = Path()
            for (index, value) in history.enumerated() {
                let point = CGPoint(
                    x: CGFloat(index) * stepX,
                    y: size.height - CGFloat(value / maxValue) * (size.height - 2) - 1
                )
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(color.opacity(0.9)), lineWidth: 1.5)
        }
        .frame(height: 36)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }

    private func formatRate(_ value: Double?) -> String {
        guard let value else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(value)) + "/s"
    }
}
