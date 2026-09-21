import SwiftUI
import SwiftData
import TermHubCore

/// Cmd+K 快速跳转面板：单输入框 + 模糊匹配结果 + 键盘导航（↑↓ 移动、⏎ 确认、Esc 关闭）
public struct QuickSwitcherView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Query private var hosts: [SSHHost]

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool

    public init() {}

    /// 匹配结果：活跃会话排前，其余按别名排序
    private var results: [SSHHost] {
        let candidates = hosts.sorted { $0.alias < $1.alias }
        guard !query.isEmpty else {
            return activeFirst(candidates)
        }
        let matched = candidates.filter { matches($0, query: query) }
        return activeFirst(matched)
    }

    private func activeFirst(_ list: [SSHHost]) -> [SSHHost] {
        list.sorted { a, b in
            let aAlive = appState.sessionState(hostID: a.id)?.isAlive ?? false
            let bAlive = appState.sessionState(hostID: b.id)?.isAlive ?? false
            if aAlive != bAlive { return aAlive }
            return a.alias < b.alias
        }
    }

    /// 本地 subsequence 模糊匹配（不引依赖）：query 各字符按顺序出现于目标串即命中。
    /// 过滤字段与侧栏搜索一致：alias/hostname/username/notes
    private func matches(_ host: SSHHost, query: String) -> Bool {
        let q = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let fields = [
            host.alias, host.hostname, host.username, host.notes,
            "\(host.username)@\(host.displayAddress)"
        ]
        return fields.contains { field in
            isSubsequence(q, in: field.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
        }
    }

    private func isSubsequence(_ needle: String, in haystack: String) -> Bool {
        var rest = haystack[...]
        for char in needle {
            if let index = rest.firstIndex(of: char) {
                rest = rest[rest.index(after: index)...]
            } else {
                return false
            }
        }
        return true
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索主机（别名 / 地址 / 用户名 / 备注）", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if results.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "slash.circle")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text(query.isEmpty ? "还没有保存的主机" : "无匹配主机")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, host in
                            row(host, isSelected: index == selectedIndex)
                                .id(host.id)
                                .onTapGesture { choose(host) }
                        }
                    }
                    .padding(6)
                }
            }

            Divider()
            HStack(spacing: 14) {
                Text("↑↓ 选择")
                Text("⏎ 连接")
                Text("Esc 关闭")
                Spacer()
                Text("\(results.count) 台主机")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(width: 480, height: 380)
        .onAppear {
            searchFocused = true
            selectedIndex = 0
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
        }
        .onKeyPress(.upArrow) {
            if selectedIndex > 0 { selectedIndex -= 1 }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if selectedIndex < results.count - 1 { selectedIndex += 1 }
            return .handled
        }
        .onKeyPress(.return) {
            if let host = results[safe: selectedIndex] {
                choose(host)
            }
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private func row(_ host: SSHHost, isSelected: Bool) -> some View {
        let alive = appState.sessionState(hostID: host.id)?.isAlive ?? false
        return HStack(spacing: 8) {
            StatusDot(phase: appState.sessionState(hostID: host.id))
            VStack(alignment: .leading, spacing: 2) {
                Text(host.alias)
                    .font(.body)
                    .fontWeight(isSelected ? .semibold : .medium)
                    .lineLimit(1)
                Text("\(host.username)@\(host.displayAddress)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if alive {
                Text("活跃")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.15), in: Capsule())
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    /// 选中动作与侧栏点选等价：选中 + 建立会话
    private func choose(_ host: SSHHost) {
        appState.selectedHostID = host.id
        appState.openSession(for: host.snapshot)
        dismiss()
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
