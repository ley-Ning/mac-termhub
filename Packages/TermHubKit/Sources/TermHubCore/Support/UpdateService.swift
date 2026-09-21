import Foundation

/// 热更新：检查 origin/main 是否有新提交 → 一键拉代码重建（稳定签名）→ 自动重启。
/// 依托 scripts/update-local.sh（git pull + build-app.sh + 替换 + open）。
@MainActor
public final class UpdateService: ObservableObject {
    public struct Status: Equatable {
        public enum Kind: Equatable {
            case idle
            case checking
            case upToDate(commit: String)
            case available(commitsAhead: Int, log: [String])
            case updating(step: String)
            case failed(String)
        }

        public var kind: Kind
        public init(_ kind: Kind) { self.kind = kind }
    }

    @Published public private(set) var status = Status(.idle)
    /// 菜单「检查更新…」打开的弹窗
    @Published public var showsUpdateSheet = false

    /// 本地仓库路径（脚本与仓库同机存在才可用；打分发包装到别的机器时不可用）
    private let repoURL = URL(fileURLWithPath: NSString(string: "~/WorkBuddy/TermHub").expandingTildeInPath)
    private var updateProcess: Process?

    public init() {}

    public var isAvailable: Bool {
        FileManager.default.fileExists(atPath: repoURL.appending(path: "scripts/update-local.sh").path)
    }

    /// 后台检查远端（不弹任何 UI，结果供菜单徽标/入口用）
    public func checkForUpdates() async {
        guard isAvailable else { return }
        status = .init(.checking)
        let result = await runScript("--check-only")
        switch result {
        case .success(let output):
            if output.contains("UP_TO_DATE") {
                let commit = output.split(separator: " ").last.map(String.init) ?? ""
                status = .init(.upToDate(commit: String(commit.prefix(8))))
            } else if output.contains("UPDATE_AVAILABLE") {
                let count = output
                    .split(separator: " ")
                    .first { part in part.allSatisfy { $0.isNumber } }
                    .flatMap { Int($0) } ?? 1
                let log = output.split(separator: "\n").dropFirst().map(String.init)
                status = .init(.available(commitsAhead: count, log: log))
            } else if output.contains("无法访问远端") {
                // 网络不可达不算失败，静默回 idle
                status = .init(.idle)
            } else {
                status = .init(.failed("检查更新失败：\(output.prefix(120))"))
            }
        case .failure(let message):
            status = .init(.failed("检查更新失败：\(message)"))
        }
    }

    /// 执行热更新：脚本完成前 App 会被脚本 quit——跑到 updating 即可，完成态由重启体现
    public func installUpdate() {
        guard isAvailable else {
            status = .init(.failed("未找到本地仓库（~/WorkBuddy/TermHub），请手动更新"))
            return
        }
        guard updateProcess == nil else { return }
        status = .init(.updating(step: "拉取代码并重新打包（约 1-2 分钟）…"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [repoURL.appending(path: "scripts/update-local.sh").path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        updateProcess = process
        DispatchQueue.global().async { [weak self, process] in
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                Task { @MainActor [weak self] in
                    self?.status = .init(.failed("无法启动更新脚本：\(error.localizedDescription)"))
                    self?.updateProcess = nil
                }
            }
        }
    }

    public var isUpdating: Bool {
        if case .updating = status.kind { return true }
        return false
    }

    public var updateBadgeText: String? {
        if case .available(let count, _) = status.kind {
            return "\(count) 个更新"
        }
        return nil
    }

    private enum ScriptResult {
        case success(String)
        case failure(String)
    }

    private func runScript(_ arguments: String...) async -> ScriptResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [repoURL.appending(path: "scripts/update-local.sh").path] + arguments
            process.standardOutput = pipe
            process.standardError = Pipe()
            process.environment = ProcessInfo.processInfo.environment
            do {
                try process.run()
            } catch {
                continuation.resume(returning: .failure(error.localizedDescription))
                return
            }
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: .success(output))
                } else {
                    continuation.resume(returning: .failure(output.isEmpty ? "exit \(process.terminationStatus)" : output))
                }
            }
        }
    }
}
