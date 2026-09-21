import SwiftUI
import SwiftData
import TermHubCore

/// 新增/编辑主机表单 + 测试连接
public struct HostEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var allHosts: [SSHHost]

    let host: SSHHost?

    @State private var alias = ""
    @State private var hostname = ""
    @State private var port = 22
    @State private var username = ""
    @State private var group = "默认"
    @State private var notes = ""
    @State private var authMethod: HostAuthMethod = .password
    @State private var keyPath = ""
    @State private var password = ""
    @State private var passphrase = ""
    @State private var proxyType: HostProxyType = .none
    @State private var proxyHost = ""
    @State private var proxyPort = 7217
    @State private var jumpHostID: UUID?
    /// 跳板链成环时的提示
    @State private var showingJumpCycleAlert = false

    @State private var testState: TestState = .idle

    enum TestState: Equatable {
        case idle
        case testing
        case success(ms: Int, fingerprint: String?)
        case failed(String)
    }

    private var hasSavedPassword: Bool {
        guard let host else { return false }
        return KeychainStore.read(kind: .password, hostID: host.id) != nil
    }

    private var hasSavedPassphrase: Bool {
        guard let host else { return false }
        return KeychainStore.read(kind: .passphrase, hostID: host.id) != nil
    }

    /// 跳板候选：其余已保存主机（不含自己）
    private var jumpCandidates: [SSHHost] {
        allHosts
            .filter { $0.id != host?.id }
            .sorted { $0.alias < $1.alias }
    }

    /// 沿表单选择的跳板链走 visited 集，成环返回 true（保存时拒绝）
    private func jumpChainHasCycle() -> Bool {
        var visited: Set<UUID> = []
        var cursor = jumpHostID
        while let id = cursor {
            // 回到已走过的节点（含被编辑主机自身）即成环
            if !visited.insert(id).inserted { return true }
            cursor = allHosts.first(where: { $0.id == id })?.jumpHostID
        }
        return false
    }

    /// 按表单当前选择解析跳板链快照（测试连接用；与 AppState.resolveJumpChain 同规则）
    private func jumpChainFromForm() -> [HostSnapshot] {
        var chain: [HostSnapshot] = []
        var visited: Set<UUID> = []
        var cursor = jumpHostID
        while let id = cursor, !visited.contains(id),
              let hopModel = allHosts.first(where: { $0.id == id }) {
            chain.append(hopModel.snapshot)
            visited.insert(id)
            cursor = hopModel.jumpHostID
        }
        return chain
    }

    public var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("基本信息") {
                    TextField("别名", text: $alias)
                    TextField("主机地址", text: $hostname)
                    Stepper("端口：\(port)", value: $port, in: 1...65535)
                        .monospacedDigit()
                    TextField("用户名", text: $username)
                    TextField("分组", text: $group)
                }

                Section("认证") {
                    Picker("方式", selection: $authMethod) {
                        ForEach(HostAuthMethod.allCases) { method in
                            Text(method.label).tag(method)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    switch authMethod {
                    case .password:
                        SecureField(
                            hasSavedPassword ? "密码（已保存，输入则更新）" : "密码",
                            text: $password
                        )
                    case .key:
                        HStack {
                            TextField("私钥路径（~/.ssh/id_ed25519）", text: $keyPath)
                                .autocorrectionDisabled()
                            Button("选择…") { chooseKeyFile() }
                        }
                        SecureField(
                            hasSavedPassphrase ? "私钥口令（已保存，输入则更新，无口令留空）" : "私钥口令（无口令留空）",
                            text: $passphrase
                        )
                    }
                }

                Section("代理") {
                    Picker("类型", selection: $proxyType) {
                        ForEach(HostProxyType.allCases) { t in
                            Text(t.label).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if proxyType == .http {
                        TextField("代理地址", text: $proxyHost)
                            .autocorrectionDisabled()
                        Stepper("代理端口：\(proxyPort)", value: $proxyPort, in: 1...65535)
                            .monospacedDigit()
                    }
                }

                Section("经由跳板机") {
                    Picker("跳板机", selection: $jumpHostID) {
                        Text("无").tag(UUID?.none)
                        ForEach(jumpCandidates) { candidate in
                            Text(candidate.alias.isEmpty ? candidate.hostname : candidate.alias)
                                .tag(UUID?.some(candidate.id))
                        }
                    }
                    if jumpHostID != nil {
                        Text("连接时先登录所选主机，再经它转发到本机（支持多级跳板，逐台配置即可）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("备注") {
                    TextField("备注（可选）", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section {
                    HStack {
                        switch testState {
                        case .idle:
                            Text(" ").font(.caption)
                        case .testing:
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("测试中…").font(.caption)
                            }
                        case .success(let ms, let fingerprint):
                            VStack(alignment: .leading, spacing: 2) {
                                Text("连接成功（\(ms)ms）").font(.caption).foregroundStyle(.green)
                                if let fingerprint {
                                    Text(fingerprint).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        case .failed(let message):
                            Text(message).font(.caption).foregroundStyle(.red)
                        }
                        Spacer()
                        Button("测试连接") {
                            testConnection()
                        }
                        .disabled(!formValid || testState == .testing)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(host == nil ? "添加" : "保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!formValid)
            }
            .padding()
        }
        .frame(width: 520, height: 560)
        .onAppear(perform: load)
        .alert("跳板链成环", isPresented: $showingJumpCycleAlert) {
            Button("返回修改", role: .cancel) {}
        } message: {
            Text("所选跳板链会形成循环，请调整「经由跳板机」设置后再保存。")
        }
    }

    private var formValid: Bool {
        !hostname.isEmpty && !username.isEmpty
        && (authMethod == .password ? (hasSavedPassword || !password.isEmpty) : !keyPath.isEmpty)
    }

    private func load() {
        guard let host else { return }
        alias = host.alias
        hostname = host.hostname
        port = host.port
        username = host.username
        group = host.groupName
        notes = host.notes
        authMethod = host.authMethod
        keyPath = host.keyPath ?? ""
        proxyType = host.proxyType
        proxyHost = host.proxyHost ?? ""
        proxyPort = host.proxyPort ?? 7217
        jumpHostID = host.jumpHostID
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".ssh")
        panel.message = "选择 SSH 私钥文件"
        if panel.runModal() == .OK, let url = panel.url {
            keyPath = url.path
        }
    }

    private func testConnection() {
        let snapshot = HostSnapshot(
            id: host?.id ?? UUID(),
            alias: alias,
            hostname: hostname,
            port: port,
            username: username,
            authMethod: authMethod,
            keyPath: authMethod == .key ? keyPath : nil,
            groupName: group,
            notes: notes,
            proxyType: proxyType,
            proxyHost: proxyType == .http ? proxyHost : nil,
            proxyPort: proxyType == .http ? proxyPort : nil,
            jumpHostID: jumpHostID
        )
        let jumpHosts = jumpChainFromForm()
        testState = .testing
        Task {
            let started = Date()
            do {
                // 测试连接：新指纹自动信任（结果里展示指纹）；已记录但指纹变化仍会报错。
                // 配置了跳板时按链测试（各跳走自身保存的凭据）。
                let connection = try await SSHConnectionFactory.connect(
                    to: snapshot,
                    hostKeyCallback: { facts in
                        SharedKnownHosts.store.trust(
                            host: facts.host, port: facts.port,
                            fingerprintSHA256: facts.fingerprint, keyType: facts.keyType
                        )
                        return true
                    },
                    jumpHosts: jumpHosts,
                    overridePassword: password.isEmpty ? nil : password,
                    overridePassphrase: passphrase.isEmpty ? nil : passphrase
                )
                let output = try await connection.client.executeCommand("echo ok")
                await connection.closeAll()
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                let ok = String(buffer: output).trimmingCharacters(in: .whitespacesAndNewlines).contains("ok")
                if ok {
                    let fp = SharedKnownHosts.store.record(for: hostname, port: port)?.fingerprintSHA256
                    testState = .success(ms: ms, fingerprint: fp)
                } else {
                    testState = .failed("命令执行异常：\(String(buffer: output))")
                }
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }

    private func save() {
        // 跳板链环检测：成环拒绝保存（连接解析会死循环）
        if jumpChainHasCycle() {
            showingJumpCycleAlert = true
            return
        }
        if let host {
            host.alias = alias.isEmpty ? hostname : alias
            host.hostname = hostname
            host.port = port
            host.username = username
            host.groupName = group
            host.authMethod = authMethod
            host.keyPath = authMethod == .key ? keyPath : nil
            host.notes = notes
            host.jumpHostID = jumpHostID
            if !password.isEmpty, authMethod == .password {
                try? KeychainStore.save(password, kind: .password, hostID: host.id)
            }
            if !passphrase.isEmpty, authMethod == .key {
                try? KeychainStore.save(passphrase, kind: .passphrase, hostID: host.id)
            }
        } else {
            let newHost = SSHHost(
                alias: alias.isEmpty ? hostname : alias,
                hostname: hostname,
                port: port,
                username: username,
                authMethod: authMethod,
                keyPath: authMethod == .key ? keyPath : nil,
                groupName: group,
                notes: notes,
                proxyType: proxyType,
                proxyHost: proxyType == .http ? proxyHost : nil,
                proxyPort: proxyType == .http ? proxyPort : nil,
                jumpHostID: jumpHostID
            )
            modelContext.insert(newHost)
            if authMethod == .password, !password.isEmpty {
                try? KeychainStore.save(password, kind: .password, hostID: newHost.id)
            }
            if authMethod == .key, !passphrase.isEmpty {
                try? KeychainStore.save(passphrase, kind: .passphrase, hostID: newHost.id)
            }
        }

        dismiss()
    }
}
