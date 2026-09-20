import SwiftUI
import TermHubCore

/// SFTP 文件管理：远程目录 + 本地目录双栏 + 传输队列
public struct FilesTabPage: View {
    @ObservedObject private var hostSession: HostSession
    @StateObject private var sftp: SFTPService

    @State private var newFolderName = ""
    @State private var showNewFolder = false
    @State private var renameTarget: SFTPEntry?
    @State private var renameText = ""
    @State private var deleteTarget: SFTPEntry?
    @State private var localPath = URL.homeDirectory
    // 文件管理增强：剪贴板 / 预览 / 新建文件 / 本地操作
    @State private var clipboard: (entries: [SFTPEntry], cut: Bool)?
    @State private var previewEntry: SFTPEntry?
    @State private var showNewFile = false
    @State private var newFileName = ""
    @State private var localRenameURL: URL?
    @State private var localRenameText = ""
    @State private var showLocalNewFolder = false
    @State private var localNewFolderName = ""
    @State private var localRefresh = 0

    public init(hostSession: HostSession) {
        self.hostSession = hostSession
        _sftp = StateObject(wrappedValue: SFTPService(ssh: hostSession.ssh))
    }

    public var body: some View {
        VStack(spacing: 0) {
            remoteToolbar
            Divider()
            HSplitView {
                remotePane.frame(maxWidth: .infinity)
                localPane.frame(minWidth: 150, idealWidth: 200, maxWidth: 320)
            }
            if !sftp.transfers.isEmpty {
                Divider()
                transfersPane
            }
        }
        .onAppear {
            if hostSession.ssh.phase.isAlive, sftp.phase == .idle {
                Task { await sftp.ensureOpen() }
            }
        }
        .onChange(of: hostSession.ssh.phase) { _, phase in
            if phase.isAlive, sftp.phase == .idle {
                Task { await sftp.ensureOpen() }
            }
        }
        .alert("新建目录", isPresented: $showNewFolder) {
            TextField("目录名", text: $newFolderName)
            Button("创建") {
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task { await sftp.createDirectory(name: name) }
            }
            Button("取消", role: .cancel) {}
        }
        .alert("重命名", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("新名称", text: $renameText)
            Button("确定") {
                if let target = renameTarget {
                    let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    Task { await sftp.rename(target, to: name) }
                }
                renameTarget = nil
            }
            Button("取消", role: .cancel) { renameTarget = nil }
        }
        .alert("确认删除", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let target = deleteTarget {
                    Task { await sftp.deleteRecursive(target) }
                }
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("删除 \(deleteTarget?.name ?? "") ？目录将连同其中所有内容一起删除。")
        }
        .alert("新建文件", isPresented: $showNewFile) {
            TextField("文件名", text: $newFileName)
            Button("创建") {
                let name = newFileName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task { await sftp.createFile(name: name) }
            }
            Button("取消", role: .cancel) {}
        }
        .alert("重命名本地项", isPresented: Binding(
            get: { localRenameURL != nil },
            set: { if !$0 { localRenameURL = nil } }
        )) {
            TextField("新名称", text: $localRenameText)
            Button("确定") {
                if let url = localRenameURL {
                    let name = localRenameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { renameLocal(url, to: name) }
                }
                localRenameURL = nil
            }
            Button("取消", role: .cancel) { localRenameURL = nil }
        }
        .alert("新建本地文件夹", isPresented: $showLocalNewFolder) {
            TextField("文件夹名", text: $localNewFolderName)
            Button("创建") {
                let name = localNewFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { createLocalFolder(name) }
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(item: $previewEntry) { entry in
            FilePreviewView(sftp: sftp, entry: entry)
        }
    }

    // MARK: - 远程工具条

    private var remoteToolbar: some View {
        HStack(spacing: 8) {
            Button {
                Task { await sftp.goUp() }
            } label: {
                Image(systemName: "arrow.up")
            }
            .help("上一级")

            Text(sftp.currentPath)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
                .help(sftp.currentPath)
                .frame(maxWidth: 260, alignment: .leading)

            if sftp.isListing {
                ProgressView().controlSize(.small)
            }
            Spacer()

            Button {
                newFolderName = ""
                showNewFolder = true
            } label: {
                Label("新建目录", systemImage: "folder.badge.plus")
            }
            Button {
                uploadFiles()
            } label: {
                Label("上传", systemImage: "square.and.arrow.up")
            }
            Button {
                Task { await sftp.list() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("刷新")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 远程列表

    private var remotePane: some View {
        Group {
            switch sftp.phase {
            case .ready:
                remoteTable
            case .failed(let message):
                VStack(spacing: 8) {
                    Text("SFTP 打开失败").font(.headline)
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    Button("重试") { Task { await sftp.ensureOpen() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .idle, .opening:
                VStack(spacing: 8) {
                    ProgressView()
                    Text(sftp.phase == .opening ? "正在打开 SFTP…" : "等待连接…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var remoteTable: some View {
        Table(sftp.entries) {
            TableColumn("名称") { entry in
                HStack(spacing: 6) {
                    Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                        .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                    Text(entry.name).font(.system(size: 12, weight: .medium))
                }
            }

            TableColumn("大小") { entry in
                Text(entry.formattedSize)
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(90)

            TableColumn("修改时间") { entry in
                if let date = entry.modified {
                    Text(date.formatted(.dateTime.year().month().day().hour().minute()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .width(140)

            TableColumn("权限") { entry in
                Text(entry.permissionsText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(90)
        }
        .contextMenu(forSelectionType: SFTPEntry.self) { selection in
            if let entry = selection.first {
                entryMenu(entry)
            }
        } primaryAction: { selection in
            guard let entry = selection.first else { return }
            if entry.isDirectory {
                Task { await sftp.list(path: entry.path) }
            } else {
                // 双击文件 = 预览（文本可编辑写回；二进制给下载打开）
                previewEntry = entry
            }
        }
    }

    @ViewBuilder
    private func entryMenu(_ entry: SFTPEntry) -> some View {
        if entry.isDirectory {
            Button("打开") { Task { await sftp.list(path: entry.path) } }
        } else {
            Button("预览 / 编辑") { previewEntry = entry }
        }
        Button("下载到本地…") { download(entry) }
        Divider()
        Button("复制") { clipboard = ([entry], cut: false) }
        Button("剪切") { clipboard = ([entry], cut: true) }
        if let clip = clipboard {
            Button("粘贴到当前目录 (\(clip.entries.count) 项)") {
                Task {
                    if clip.cut {
                        await sftp.moveEntries(clip.entries, toDirectory: sftp.currentPath)
                    } else {
                        await sftp.copyEntries(clip.entries, toDirectory: sftp.currentPath)
                    }
                    clipboard = nil
                }
            }
        }
        Divider()
        Menu("权限") {
            ForEach(["644", "600", "755", "640"], id: \.self) { mode in
                Button("chmod \(mode)") { Task { await sftp.setPermissions(entry, mode: mode) } }
            }
            Divider()
            Button("加可执行 (+x)") { Task { await sftp.setPermissions(entry, mode: "+x") } }
        }
        Button("复制路径") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.path, forType: .string)
        }
        Divider()
        Button("新建目录…") { newFolderName = ""; showNewFolder = true }
        Button("新建文件…") { newFileName = ""; showNewFile = true }
        Divider()
        Button("重命名…") {
            renameText = entry.name
            renameTarget = entry
        }
        Button("删除…", role: .destructive) {
            deleteTarget = entry
        }
    }

    // MARK: - 本地栏

    private var localPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    localPath = localPath.deletingLastPathComponent()
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(localPath.pathComponents.count <= 1)
                Text(localPath.lastPathComponent.isEmpty ? "/" : localPath.lastPathComponent)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                Button {
                    showLocalNewFolder = true
                    localNewFolderName = ""
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("新建文件夹")
                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    if panel.runModal() == .OK, let url = panel.url {
                        localPath = url
                    }
                } label: {
                    Image(systemName: "folder")
                }
                .help("选择本地目录")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            List(localEntries, id: \.self) { entryURL in
                let isDir = (try? entryURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                HStack(spacing: 6) {
                    Image(systemName: isDir ? "folder" : "doc")
                        .foregroundStyle(isDir ? Color.accentColor : .secondary)
                    Text(entryURL.lastPathComponent).font(.caption)
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    if isDir {
                        localPath = entryURL
                    } else {
                        // 双击本地文件 = 上传到远端当前目录
                        Task { await sftp.upload(entryURL) }
                    }
                }
                .contextMenu {
                    if isDir {
                        Button("进入") { localPath = entryURL }
                    } else {
                        Button("上传到远端") { Task { await sftp.upload(entryURL) } }
                        Divider()
                        Button("用默认应用打开") { NSWorkspace.shared.open(entryURL) }
                    }
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([entryURL])
                    }
                    Divider()
                    Button("重命名…") {
                        localRenameText = entryURL.lastPathComponent
                        localRenameURL = entryURL
                    }
                    Button("移到废纸篓", role: .destructive) { trashLocal(entryURL) }
                }
            }
            .listStyle(.plain)
        }
        .background(.bar.opacity(0.3))
    }

    private var localEntries: [URL] {
        _ = localRefresh
        return (try? FileManager.default.contentsOfDirectory(
            at: localPath,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ))?.sorted { a, b in
            let aDir = (try? a.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let bDir = (try? b.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if aDir != bDir { return aDir }
            return a.lastPathComponent < b.lastPathComponent
        } ?? []
    }

    // MARK: - 传输队列

    private var transfersPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("传输").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("清除已完成") { sftp.clearFinishedTransfers() }
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            ForEach(sftp.transfers) { transfer in
                TransferRow(transfer: transfer)
            }
        }
        .frame(maxHeight: 110)
    }

    // MARK: - 本地文件操作

    private func trashLocal(_ url: URL) {
        NSWorkspace.shared.recycle([url]) { _, _ in
            Task { @MainActor in localRefresh += 1 }
        }
    }

    private func renameLocal(_ url: URL, to name: String) {
        let target = url.deletingLastPathComponent().appendingPathComponent(name)
        try? FileManager.default.moveItem(at: url, to: target)
        localRefresh += 1
    }

    private func createLocalFolder(_ name: String) {
        try? FileManager.default.createDirectory(
            at: localPath.appendingPathComponent(name),
            withIntermediateDirectories: false
        )
        localRefresh += 1
    }

    // MARK: - 文件选择器动作

    private func download(_ entry: SFTPEntry) {
        let panel = NSSavePanel()
        panel.directoryURL = localPath
        panel.nameFieldStringValue = entry.name
        if panel.runModal() == .OK, let url = panel.url {
            Task { await sftp.download(entry, to: url) }
        }
    }

    private func uploadFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = localPath
        if panel.runModal() == .OK {
            for url in panel.urls {
                Task { await sftp.upload(url) }
            }
        }
    }
}

/// 远端文件预览：文本可编辑并写回服务器；二进制/超限提供下载打开
private struct FilePreviewView: View {
    @ObservedObject var sftp: SFTPService
    let entry: SFTPEntry
    @State private var original: String?
    @State private var loading = true
    @State private var edited = ""
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    private var isText: Bool { original != nil }
    private var dirty: Bool { isText && edited != original }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.headline)
                    Text(entry.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if dirty {
                    Text("未保存").font(.caption).foregroundStyle(.orange)
                }
                if isText {
                    Button("保存到服务器") {
                        Task {
                            saving = true
                            if await sftp.writeText(entry, content: edited) {
                                original = edited
                            }
                            saving = false
                        }
                    }
                    .disabled(!dirty || saving)
                }
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(10)

            Divider()

            if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isText {
                TextEditor(text: $edited)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.badge.ellipsis")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("无法预览（二进制文件或超过 512KB）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("下载到临时目录并用默认应用打开") {
                        Task {
                            let dir = FileManager.default.temporaryDirectory
                            let target = dir.appendingPathComponent(entry.name)
                            await sftp.download(entry, to: target)
                            NSWorkspace.shared.open(target)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .task {
            original = await sftp.readTextPreview(entry)
            if let original { edited = original }
            loading = false
        }
    }
}

private struct TransferRow: View {
    @ObservedObject var transfer: FileTransfer

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: transfer.direction == .upload ? "arrow.up" : "arrow.down")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(transfer.name)
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: 200, alignment: .leading)
            switch transfer.state {
            case .running:
                ProgressView(value: transfer.totalBytes > 0 ? transfer.progress : 0)
                    .frame(maxWidth: .infinity)
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(transfer.transferredBytes), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(transfer.totalBytes), countStyle: .file))")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("完成").font(.caption).foregroundStyle(.secondary)
            case .failed(let message):
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text(message).font(.caption2).foregroundStyle(.red).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }
}
