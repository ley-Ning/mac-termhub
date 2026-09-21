import SwiftUI
import TermHubCore

/// 热更新弹窗：检查结果 + 一键安装（拉代码 → 稳定签名重建 → 自动重启）
struct UpdateSheet: View {
    @ObservedObject var updater: UpdateService

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(tint)
            title
            detail
            HStack {
                Button("关闭") { updater.showsUpdateSheet = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if case .available = updater.status.kind {
                    Button("立即热更新") { updater.installUpdate() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(updater.isUpdating)
                }
                if case .failed = updater.status.kind {
                    Button("重试检查") {
                        Task { await updater.checkForUpdates() }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var icon: String {
        switch updater.status.kind {
        case .idle: return "questionmark.circle"
        case .checking: return "arrow.triangle.2.circlepath"
        case .upToDate: return "checkmark.seal.fill"
        case .available: return "arrow.down.circle.fill"
        case .updating: return "gearshape.2.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch updater.status.kind {
        case .upToDate: return .green
        case .available: return .accentColor
        case .updating: return .orange
        case .failed: return .red
        default: return .secondary
        }
    }

    @ViewBuilder
    private var title: some View {
        switch updater.status.kind {
        case .idle:
            Text("等待检查").font(.headline)
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在检查远端更新…").font(.headline)
            }
        case .upToDate(let commit):
            Text("已是最新版本（\(commit)）").font(.headline)
        case .available(let count, _):
            Text("发现 \(count) 个新提交").font(.headline)
        case .updating(let step):
            Text("正在热更新").font(.headline)
            Text(step).font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Text("检查失败").font(.headline)
            Text(message).font(.caption).foregroundStyle(.red).lineLimit(3)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if case .available(_, let log) = updater.status.kind {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(log.prefix(8).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 11, design: .monospaced))
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
            .background(.bar.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            Text("点击「立即热更新」：自动拉取代码 → 稳定签名重新打包 → 重启 TermHub（终端会话会断开）")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
