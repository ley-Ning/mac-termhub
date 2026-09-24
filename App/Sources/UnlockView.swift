import SwiftUI
import TermHubCore
import TermHubUI

/// 应用入口解锁门：首次=创建主密码；之后=解锁。忘记密码=确认后重置新库（旧密文作废重录）。
struct UnlockView: View {
    @ObservedObject var gateway: VaultGateway
    var onUnlocked: () -> Void

    @State private var masterPassword = ""
    @State private var confirmPassword = ""
    @State private var showResetConfirm = false
    @FocusState private var focused: Bool

    private var isSetup: Bool { gateway.needsSetup }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield")
                .font(.system(size: 52))
                .foregroundStyle(Color.accentColor)

            Text(isSetup ? "创建 TermHub 主密码" : "解锁 TermHub")
                .font(.title2).bold()

            Text(isSetup
                 ? "主密码用于加密你保存的所有 SSH 密码与私钥口令。\n它不存储在任何系统服务里——忘记将无法恢复，只能重置后重录。"
                 : "输入主密码解锁本机加密凭据库")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            SecureField(isSetup ? "设置主密码（不少于 6 位）" : "主密码", text: $masterPassword)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .focused($focused)
                .onSubmit { submit() }

            if isSetup {
                SecureField("再次输入确认", text: $confirmPassword)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                    .onSubmit { submit() }
            }

            if let error = gateway.lastError {
                Text(error).font(.caption).foregroundStyle(.red).frame(width: 320)
            }

            Button(isSetup ? "创建并进入" : "解锁") { submit() }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)

            if !isSetup {
                Button("忘记主密码？重置凭据库") { showResetConfirm = true }
                    .font(.caption)
                    .buttonStyle(.link)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(40)
        .frame(minWidth: 560, minHeight: 420)
        .onAppear { focused = true }
        .alert("重置凭据库", isPresented: $showResetConfirm) {
            Button("取消重置", role: .cancel) {}
            Button("确认重置（旧凭据作废）", role: .destructive) { resetVault() }
        } message: {
            Text("重置将删除当前加密文件，所有已存密码清空，需要逐台重新录入。\n旧钥匙串数据不受影响。确定继续吗？")
        }
    }

    private var valid: Bool {
        if isSetup {
            return masterPassword.count >= 6 && masterPassword == confirmPassword
        }
        return !masterPassword.isEmpty
    }

    private func submit() {
        guard valid else { return }
        let ok = isSetup ? gateway.create(masterPassword: masterPassword) : gateway.unlock(masterPassword: masterPassword)
        if ok {
            masterPassword = ""
            confirmPassword = ""
            onUnlocked()
        }
    }

    /// 忘记主密码：明确确认后重置新库（不触碰旧钥匙串——设计红线）
    private func resetVault() {
        try? FileManager.default.removeItem(at: CredentialVault.defaultFileURL())
        gateway.lock()
        masterPassword = ""
        confirmPassword = ""
        gateway.objectWillChange.send()
    }
}
