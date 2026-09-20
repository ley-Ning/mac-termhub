import SwiftUI
import TermHubCore

/// 连接状态小圆点
public struct StatusDot: View {
    let phase: SSHSession.Phase?

    public var color: Color {
        switch phase {
        case .connected: return .green
        case .connecting: return .orange
        case .failed: return .red
        case .closed: return .gray
        case .idle: return .secondary.opacity(0.5)
        case nil: return .secondary.opacity(0.35)
        }
    }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }
}

/// 详情页头部的状态文字
public struct PhaseBadge: View {
    let phase: SSHSession.Phase

    public var body: some View {
        switch phase {
        case .idle:
            Label("未连接", systemImage: "circle.dashed")
        case .connecting:
            Label("连接中…", systemImage: "arrow.triangle.2.circlepath")
        case .connected:
            Label("已连接", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label("失败：\(message)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .closed:
            Label("已断开", systemImage: "minus.circle")
        }
    }
}
