import XCTest
@testable import TermHubCore

/// 凭据库单元测试（临时目录 + 非真实凭据；设计文档"验证与交付"清单）
final class CredentialVaultTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appending(path: "vault-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private var file: URL { dir.appending(path: "vault.bin") }

    func testCreateSaveReloadRoundTrip() throws {
        let vault = try CredentialVault.create(masterPassword: "mp-正确马", at: file)
        let id = UUID()
        try vault.save("pw-α", hostID: id, kind: .password)
        try vault.save("pp-β", hostID: id, kind: .passphrase)

        // 重启（新实例解锁）后解密一致
        let reloaded = try CredentialVault.unlock(masterPassword: "mp-正确马", at: file)
        XCTAssertEqual(reloaded.read(hostID: id, kind: .password), "pw-α")
        XCTAssertEqual(reloaded.read(hostID: id, kind: .passphrase), "pp-β")
        XCTAssertEqual(reloaded.hostCount, 1)
    }

    func testWrongMasterPasswordFailsAndKeepsFile() throws {
        let vault = try CredentialVault.create(masterPassword: "right", at: file)
        try vault.save("secret", hostID: UUID(), kind: .password)
        let before = try Data(contentsOf: file)

        XCTAssertThrowsError(try CredentialVault.unlock(masterPassword: "wrong", at: file)) { error in
            XCTAssertEqual(error as? CredentialVault.VaultError, .wrongMasterPassword)
        }
        // 错误密码不得改动密文
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testTamperedCiphertextDetected() throws {
        let vault = try CredentialVault.create(masterPassword: "mp", at: file)
        try vault.save("x", hostID: UUID(), kind: .password)
        var blob = try Data(contentsOf: file)
        blob[blob.count - 1] ^= 0xFF // 篡改密文末字节
        try blob.write(to: file)

        XCTAssertThrowsError(try CredentialVault.unlock(masterPassword: "mp", at: file)) { error in
            guard case .wrongMasterPassword = error as? CredentialVault.VaultError else {
                return XCTFail("篡改应被 GCM 标签拒绝：\(error)")
            }
        }
    }

    func testCorruptHeaderRejected() throws {
        let vault = try CredentialVault.create(masterPassword: "mp", at: file)
        try vault.save("x", hostID: UUID(), kind: .password)
        var blob = try Data(contentsOf: file)
        blob[0] = "X".utf8.first! // 破坏 magic
        try blob.write(to: file)
        XCTAssertThrowsError(try CredentialVault.unlock(masterPassword: "mp", at: file))
    }

    func testOverwriteAndDeleteHost() throws {
        let vault = try CredentialVault.create(masterPassword: "mp", at: file)
        let a = UUID(), b = UUID()
        try vault.save("1", hostID: a, kind: .password)
        try vault.save("2", hostID: b, kind: .password)
        try vault.save("1-new", hostID: a, kind: .password) // 覆盖
        try vault.deleteHost(b)

        let reloaded = try CredentialVault.unlock(masterPassword: "mp", at: file)
        XCTAssertEqual(reloaded.read(hostID: a, kind: .password), "1-new")
        XCTAssertNil(reloaded.read(hostID: b, kind: .password))
        XCTAssertEqual(reloaded.hostCount, 1)
    }

    func testCreateExclusivelyDoesNotOverwrite() throws {
        _ = try CredentialVault.create(masterPassword: "first", at: file)
        XCTAssertThrowsError(try CredentialVault.create(masterPassword: "second", at: file)) { error in
            XCTAssertEqual(error as? CredentialVault.VaultError, .alreadyExists)
        }
        // 第二次创建失败后原库仍可用原密码解锁
        let vault = try CredentialVault.unlock(masterPassword: "first", at: file)
        XCTAssertEqual(vault.hostCount, 0)
    }

    func testChangeMasterPassword() throws {
        let vault = try CredentialVault.create(masterPassword: "old", at: file)
        let id = UUID()
        try vault.save("keep", hostID: id, kind: .password)
        try vault.changeMasterPassword(to: "new")

        XCTAssertThrowsError(try CredentialVault.unlock(masterPassword: "old", at: file))
        let reloaded = try CredentialVault.unlock(masterPassword: "new", at: file)
        XCTAssertEqual(reloaded.read(hostID: id, kind: .password), "keep")
    }

    func testMissingFileReportsMissing() {
        XCTAssertThrowsError(try CredentialVault.unlock(masterPassword: "mp", at: file)) { error in
            XCTAssertEqual(error as? CredentialVault.VaultError, .missing)
        }
    }

    func testEmptyMasterPasswordCannotCreateVault() {
        XCTAssertThrowsError(try CredentialVault.create(masterPassword: "", at: file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testFilePermissionsAre0600() throws {
        let vault = try CredentialVault.create(masterPassword: "mp", at: file)
        try vault.save("x", hostID: UUID(), kind: .password)
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o600)
    }

    func testFailedSaveDoesNotMutateUnlockedSnapshot() throws {
        let vault = try CredentialVault.create(masterPassword: "mp", at: file)
        let id = UUID()
        try vault.save("before", hostID: id, kind: .password)

        let originalDirectory = file.deletingLastPathComponent()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: originalDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: originalDirectory.path
            )
        }

        XCTAssertThrowsError(try vault.save("after", hostID: id, kind: .password))
        XCTAssertEqual(vault.read(hostID: id, kind: .password), "before")
        let reopened = try CredentialVault.unlock(masterPassword: "mp", at: file)
        XCTAssertEqual(reopened.read(hostID: id, kind: .password), "before")
    }
}
