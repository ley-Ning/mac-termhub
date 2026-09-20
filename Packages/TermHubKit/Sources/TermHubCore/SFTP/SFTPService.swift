import Foundation
import Citadel
import NIO

/// SFTP 目录条目（视图友好模型）
public struct SFTPEntry: Identifiable, Hashable, Sendable {
    public let id: String          // 完整路径
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let size: UInt64?
    public let modified: Date?
    public let permissionsText: String
    public let longname: String

    public var formattedSize: String {
        guard let size, !isDirectory else { return isDirectory ? "—" : "" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

/// 基于 Citadel SFTPClient 的文件服务：浏览 + 增删改名 + 上传下载（分块带进度）
@MainActor
public final class SFTPService: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case opening
        case ready
        case failed(String)
    }

    public let ssh: SSHSession

    @Published private(set) public var phase: Phase = .idle
    @Published private(set) public var currentPath = "/"
    @Published private(set) public var entries: [SFTPEntry] = []
    @Published private(set) public var isListing = false
    @Published public var transfers: [FileTransfer] = []

    private var sftp: SFTPClient?
    private static let chunkSize: UInt32 = 256 * 1024

    public init(ssh: SSHSession) {
        self.ssh = ssh
    }

    /// 打开 SFTP 子系统（连接建立后调用）
    public func ensureOpen() async {
        if case .ready = phase { return }
        guard let client = ssh.activeClient else {
            phase = .failed("SSH 未连接")
            return
        }
        phase = .opening
        do {
            let sftp = try await client.openSFTP()
            self.sftp = sftp
            let home = try await sftp.getRealPath(atPath: ".")
            currentPath = home
            phase = .ready
            await list(path: home)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// 列目录
    public func list(path: String? = nil) async {
        guard let sftp else { return }
        let target = path ?? currentPath
        isListing = true
        defer { isListing = false }
        do {
            let names = try await sftp.listDirectory(atPath: target)
            var result: [SFTPEntry] = []
            for name in names {
                for component in name.components {
                    guard component.filename != ".", component.filename != ".." else { continue }
                    result.append(Self.entry(
                        component: component,
                        directory: target
                    ))
                }
            }
            result.sort { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            entries = result
            currentPath = target
        } catch {
            phase = .failed("列目录失败：\(error.localizedDescription)")
        }
    }

    /// 进入上级
    public func goUp() async {
        guard currentPath != "/", currentPath.count > 1 else { return }
        let parent = (currentPath as NSString).deletingLastPathComponent
        await list(path: parent.isEmpty ? "/" : parent)
    }

    // MARK: - 文件操作

    public func createDirectory(name: String) async {
        guard let sftp else { return }
        let path = (currentPath as NSString).appendingPathComponent(name)
        do {
            try await sftp.createDirectory(atPath: path)
            await list()
        } catch {
            phase = .failed("新建目录失败：\(error.localizedDescription)")
        }
    }

    public func delete(_ entry: SFTPEntry) async {
        guard let sftp else { return }
        do {
            if entry.isDirectory {
                try await sftp.rmdir(at: entry.path)
            } else {
                try await sftp.remove(at: entry.path)
            }
            await list()
        } catch {
            phase = .failed("删除失败：\(error.localizedDescription)")
        }
    }

    public func rename(_ entry: SFTPEntry, to newName: String) async {
        guard let sftp else { return }
        let newPath = (entry.path as NSString).deletingLastPathComponent + "/" + newName
        do {
            try await sftp.rename(at: entry.path, to: newPath)
            await list()
        } catch {
            phase = .failed("重命名失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 高级文件操作（复制/移动等走远端 shell，路径单引号转义防注入）

    nonisolated private static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 静默命令：成功无输出；有输出（stderr）视为失败
    private func run(_ command: String) async -> String? {
        guard let output = try? await ssh.exec(command) else { return nil }
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    public func copyEntries(_ entries: [SFTPEntry], toDirectory dir: String) async {
        let cmds = entries.map {
            "cp -Rp \(Self.quote($0.path)) \(Self.quote((dir as NSString).appendingPathComponent($0.name)))"
        }
        if let err = await run(cmds.joined(separator: " && ")) {
            phase = .failed("复制失败：\(String(err.prefix(200)))")
        } else {
            await list()
        }
    }

    public func moveEntries(_ entries: [SFTPEntry], toDirectory dir: String) async {
        let cmds = entries.map {
            "mv \(Self.quote($0.path)) \(Self.quote((dir as NSString).appendingPathComponent($0.name)))"
        }
        if let err = await run(cmds.joined(separator: " && ")) {
            phase = .failed("移动失败：\(String(err.prefix(200)))")
        } else {
            await list()
        }
    }

    /// 递归删除（目录连同内容）
    public func deleteRecursive(_ entry: SFTPEntry) async {
        if let err = await run("rm -rf \(Self.quote(entry.path))") {
            phase = .failed("删除失败：\(String(err.prefix(200)))")
        } else {
            await list()
        }
    }

    public func createFile(name: String) async {
        let path = (currentPath as NSString).appendingPathComponent(name)
        if let err = await run("touch \(Self.quote(path))") {
            phase = .failed("新建文件失败：\(String(err.prefix(200)))")
        } else {
            await list()
        }
    }

    public func setPermissions(_ entry: SFTPEntry, mode: String) async {
        if let err = await run("chmod \(mode) \(Self.quote(entry.path))") {
            phase = .failed("权限修改失败：\(String(err.prefix(200)))")
        } else {
            await list()
        }
    }

    /// 读小文本文件内容；二进制（含 NUL）或超限时返回 nil
    public func readTextPreview(_ entry: SFTPEntry, maxBytes: Int = 512 * 1024) async -> String? {
        guard let sftp, !entry.isDirectory else { return nil }
        if let size = entry.size, Int(size) > maxBytes { return nil }
        do {
            return try await sftp.withFile(filePath: entry.path, flags: [.read]) { file in
                var data = Data()
                var offset: UInt64 = 0
                while true {
                    let chunk = try await file.read(from: offset, length: 64 * 1024)
                    let readable = chunk.readableBytes
                    guard readable > 0 else { break }
                    data.append(contentsOf: chunk.readableBytesView)
                    if data.contains(0) { return nil }          // 二进制
                    offset += UInt64(readable)
                    if readable < 64 * 1024 { break }
                }
                return String(data: data, encoding: .utf8)
            }
        } catch {
            return nil
        }
    }

    /// 文本写回（整文件覆盖）
    public func writeText(_ entry: SFTPEntry, content: String) async -> Bool {
        guard let sftp else { return false }
        do {
            try await sftp.withFile(filePath: entry.path, flags: [.write, .create, .truncate]) { file in
                let data = Data(content.utf8)
                var offset: UInt64 = 0
                while offset < UInt64(data.count) {
                    let end = min(offset + UInt64(Self.chunkSize), UInt64(data.count))
                    try await file.write(ByteBuffer(bytes: data[Int(offset)..<Int(end)]), at: offset)
                    offset = UInt64(end)
                }
            }
            await list()
            return true
        } catch {
            phase = .failed("保存失败：\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 传输（分块 + 进度）

    public func download(_ entry: SFTPEntry, to localURL: URL) async {
        guard let sftp else { return }
        let total = Int(min(entry.size ?? 0, UInt64(Int.max)))
        let transfer = FileTransfer(name: entry.name, direction: .download, totalBytes: total)
        transfers.append(transfer)
        transfer.state = .running

        do {
            try await sftp.withFile(filePath: entry.path, flags: [.read]) { file in
                var offset: UInt64 = 0
                let handle = try FileHandle(forWritingTo: localURL)
                defer { try? handle.close() }
                try handle.truncate(atOffset: 0)

                while true {
                    let chunk = try await file.read(from: offset, length: Self.chunkSize)
                    let readable = chunk.readableBytes
                    guard readable > 0 else { break }
                    let data = Data(chunk.readableBytesView)
                    try handle.write(contentsOf: data)
                    offset += UInt64(readable)
                    await MainActor.run {
                        transfer.transferredBytes = Int(offset)
                    }
                    if readable < Int(Self.chunkSize) { break }
                }
            }
            transfer.state = .done
        } catch {
            transfer.state = .failed(error.localizedDescription)
        }
    }

    public func upload(_ localURL: URL) async {
        guard let sftp else { return }
        let name = localURL.lastPathComponent
        let remotePath = (currentPath as NSString).appendingPathComponent(name)
        let attrs = try? FileManager.default.attributesOfItem(atPath: localURL.path)
        let total = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let transfer = FileTransfer(name: name, direction: .upload, totalBytes: Int(total))
        transfers.append(transfer)
        transfer.state = .running

        do {
            let data = try Data(contentsOf: localURL)
            try await sftp.withFile(filePath: remotePath, flags: [.write, .create, .truncate]) { file in
                var offset: UInt64 = 0
                while offset < UInt64(data.count) {
                    let end = min(offset + UInt64(Self.chunkSize), UInt64(data.count))
                    let slice = data[Int(offset)..<Int(end)]
                    let buffer = ByteBuffer(bytes: slice)
                    try await file.write(buffer, at: offset)
                    offset = UInt64(end)
                    await MainActor.run {
                        transfer.transferredBytes = Int(offset)
                    }
                }
            }
            transfer.state = .done
            await list()
        } catch {
            transfer.state = .failed(error.localizedDescription)
        }
    }

    public func clearFinishedTransfers() {
        transfers.removeAll { $0.state == .done }
    }

    // MARK: - 工具

    nonisolated private static func entry(component: SFTPPathComponent, directory: String) -> SFTPEntry {
        let path = directory == "/" ? "/\(component.filename)" : "\(directory)/\(component.filename)"
        let perms = component.attributes.permissions ?? 0
        let isDirectory = (perms & 0o040000) != 0
        let modeString = String(format: "%@%o", isDirectory ? "d" : "-", perms & 0o7777)
        return SFTPEntry(
            id: path,
            name: component.filename,
            path: path,
            isDirectory: isDirectory,
            size: component.attributes.size,
            modified: component.attributes.accessModificationTime?.modificationTime,
            permissionsText: modeString,
            longname: component.longname
        )
    }
}

/// 传输任务（可观察）
@MainActor
public final class FileTransfer: ObservableObject, Identifiable {
    public enum Direction { case upload, download }
    public enum State: Equatable {
        case running
        case done
        case failed(String)
    }

    public let id = UUID()
    public let name: String
    public let direction: Direction
    public let totalBytes: Int

    @Published public var transferredBytes = 0
    @Published public var state: State = .running

    public var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(transferredBytes) / Double(totalBytes)
    }

    public init(name: String, direction: Direction, totalBytes: Int) {
        self.name = name
        self.direction = direction
        self.totalBytes = totalBytes
    }
}
