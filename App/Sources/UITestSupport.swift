import SwiftUI
import AppKit
import SwiftData
import TermHubCore
import TermHubUI

/// UI 自检模式：TERMHUB_UITEST=1 时用内存库种演示主机（真实连接 163），
/// 自动打开各面板并截屏到 /tmp，供开发自查样式（不影响真实数据）。
@MainActor
enum UITestSupport {
    static func runIfNeeded(appState: AppState, modelContext: ModelContext) {
        guard ProcessInfo.processInfo.environment["TERMHUB_UITEST"] == "1" else { return }

        let demo = SSHHost(
            alias: "演示主机",
            hostname: "192.168.2.163",
            port: 22,
            username: "root",
            authMethod: .key,
            keyPath: NSHomeDirectory() + "/.ssh/id_ed25519",
            groupName: "演示"
        )
        modelContext.insert(demo)
        try? modelContext.save()

        appState.selectedHostID = demo.id
        appState.openSession(for: demo.snapshot)

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4.0))   // 连接 + 终端启动
            guard let session = appState.sessions[demo.id] else { exit(0) }

            // 面板切换前先截一张：此时徽章若为"已连接"，证明是 phase 转发独立驱动刷新
            print("[uitest] phase=\(session.ssh.phase)")
            capture("early")

            session.activeTool = .stats
            try? await Task.sleep(for: .seconds(5.0))    // 两次采样出曲线
            dumpLayout("stats")
            capture("stats")

            session.activeTool = .docker
            try? await Task.sleep(for: .seconds(6.5))    // 轮询拿到容器与资源占用
            dumpLayout("docker")
            capture("docker")

            session.activeTool = .files
            try? await Task.sleep(for: .seconds(3.0))    // SFTP 列目录
            dumpLayout("files")
            capture("files")

            session.activeTool = nil
            try? await Task.sleep(for: .seconds(1.0))
            dumpLayout("terminal")
            capture("terminal")

            exit(0)
        }
    }

    /// 布局真值：递归打印 NSView 层级的 frame，判定分栏/终端实际尺寸
    /// （cacheDisplay 对 NSSplitView/材质会拍扁，像素仅供参考，frame 才是布局事实）
    static func dumpLayout(_ name: String) {
        guard let root = NSApp.windows.first(where: { $0.contentView != nil })?.contentView else { return }
        var lines: [String] = ["[uitest-layout] === \(name) ==="]
        func walk(_ view: NSView, depth: Int) {
            guard depth < 13 else { return }
            let f = view.frame
            let line = String(repeating: "  ", count: depth)
                + "\(type(of: view)) frame=\(Int(f.width))x\(Int(f.height))@\(Int(f.minX)),\(Int(f.minY))"
            lines.append(line)
            for sub in view.subviews { walk(sub, depth: depth + 1) }
        }
        walk(root, depth: 0)
        print(lines.joined(separator: "\n"))
    }

    /// 优先系统 screencapture 拍真实窗口（含 Metal 终端与毛玻璃材质）；
    /// 失败再退回 cacheDisplay（材质会被拍扁，仅布局可参考）。
    static func capture(_ name: String) {
        let path = "/tmp/termhub-ui-\(name).png"
        if let window = NSApp.windows.first(where: { $0.contentView != nil && $0.windowNumber > 0 }) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            proc.arguments = ["-x", "-l", String(window.windowNumber), path]
            do {
                try proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 {
                    print("[uitest] 已截图(screencapture) \(path)")
                    return
                }
            } catch { /* 落到 cacheDisplay */ }
        }
        guard let view = NSApp.windows.first(where: { $0.contentView != nil })?.contentView else { return }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        print("[uitest] 已截图(cacheDisplay) \(path)")
    }
}
