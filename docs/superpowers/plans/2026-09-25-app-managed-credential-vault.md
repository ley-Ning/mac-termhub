# App-Managed Credential Vault Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Work inline in this session; do not dispatch subagents. Preserve pre-existing concurrent edits and `bin/`.

**Goal:** Replace every SSH credential Keychain path in GUI, MCP, Smoke, and normal build/update with a master-password-encrypted vault, then verify the actual local binaries.

**Architecture:** `CredentialVault` encrypts the whole host-secret map; GUI unlocks and holds it in memory. `CredentialBridge` supplies typed credentials to SSH independently of SwiftUI, while a same-UID Unix socket serves MCP only during the GUI unlock session. Old Keychain records remain untouched.

**Tech Stack:** Swift 6 package in Swift 5 language mode, SwiftUI/SwiftData, CommonCrypto PBKDF2, Crypto AES-GCM, POSIX Unix sockets, XCTest.

---

## Current-worktree rule

The working tree already contains uncommitted vault/UI edits from another local process. Before each task re-run `git status --short` and inspect overlapping diffs. Do not overwrite concurrent edits, run two builds into the same `.build`, or delete `bin/`. Test and amend the existing implementation after the other writer stops.

### Task 1: Make the encrypted file trustworthy

**Files:** `Packages/TermHubKit/Sources/TermHubCore/Support/CredentialVault.swift`, `Tests/TermHubCoreTests/CredentialVaultTests.swift`, `Package.swift`

- [ ] **Step 1: Add failing tests** for valid-GCM-but-invalid-JSON (`corrupt`, never empty), empty master password rejection, missing versus unreadable file, failed persistence leaving disk and memory unchanged, concurrent saves, change password only after verifying the current one, lock refusing reads, and exact mode `0600`/directory `0700`. Construct test fixtures in a unique temporary directory; never touch a real vault or Keychain. E.g. `XCTAssertThrowsError(try CredentialVault.unlock(masterPassword: "right", at: corruptedFixture))` must assert `.corrupt`, not merely any error.
- [ ] **Step 2: Run** `swift test --filter CredentialVaultTests` and record the expected named failures (not a compilation typo). Avoid a simultaneous `swift build` in the same checkout.
- [ ] **Step 3: Fix the implementation**: reject KDF/RNG errors, validate parsed payload, derive into bounded memory, serialize changes under one lock, persist the candidate map before replacing in-memory state, use `open(O_CREAT|O_EXCL,0600)` for creation and same-directory `fsync`/`rename` for replacement, check ownership/modes and symlinks before use. Add `lock()` that invalidates the in-memory key and makes all later reads fail with `.locked`. For example, `guard isUnlocked else { throw VaultError.locked }` must precede every read/write under the vault's lock.
- [ ] **Step 4: Run** `swift test --filter CredentialVaultTests`, then `swift test`. Confirm vault bytes contain neither test password nor test master password; keep all tests in fixture paths.
- [ ] **Step 5: Review only this task's diff** with `git diff --check` and commit only once other writer has finished and ownership of files is clear.

### Task 2: Connect GUI and SSH without hidden credential reads

**Files:** `Packages/TermHubKit/Sources/TermHubCore/Support/CredentialBridge.swift`, `Packages/TermHubKit/Sources/TermHubCore/SSH/SSHConnectionFactory.swift`, `Packages/TermHubKit/Sources/TermHubCore/SSH/SSHSession.swift`, `Packages/TermHubKit/Sources/TermHubUI/VaultGateway.swift`, `Packages/TermHubKit/Sources/TermHubUI/{AppState.swift,Views/SidebarView.swift,Views/HostDetailView.swift,Views/HostEditView.swift,Views/SettingsView.swift}`, `App/Sources/{TermHubApp.swift,UnlockView.swift}`; tests under `Tests/TermHubCoreTests/`.

- [ ] **Step 1: Add failing tests** for password, optional private-key passphrase, missing secret, locked vault, temporary override, jump-host credential, and cancellation/reconnect on lock. The provider must return a typed failure, e.g. `.locked` versus `.missing`, rather than treating both as `nil`.
- [ ] **Step 2: Run** `swift test --filter CredentialBridgeTests` (expected failure for missing behavior).
- [ ] **Step 3: Replace the current global optional closure** with thread-safe installation/clear and a throwing credential lookup. Do not call `MainActor.assumeIsolated` from SSH background work. GUI installs an unlocked vault handle and revokes it before closing sessions on lock. Keep UI `body` limited to cached presence metadata (`hasCredential`) with no decryption; edit-save failure must not leave a saved host claiming an absent password. Update `SSHConnectionFactory.makeAuthentication` for direct and jump hops; no connection retry on `.locked`.
- [ ] **Step 4: Gate GUI on create/unlock.** Clear SecureField values after success/failure, expose lock and master-password change in Settings, verify old master before change, and make reset explicit and recoverable (backup encrypted file before replacement). UITest vault path must be a unique temporary directory, not a shared hard-coded `/tmp` filename.
- [ ] **Step 5: Run** focused tests, `swift test`, and `swift build -c release`; manually exercise create → save → quit → wrong password → correct password → lock → reconnect with synthetic host data. Do not enter real SSH credentials in tests.

### Task 3: Unlock-scoped MCP bridge and no cached-connection bypass

**Files:** `Packages/TermHubKit/Sources/TermHubCore/Support/CredentialIPC.swift` (create; replace incomplete `CredentialBridge` socket ideas if necessary), `App/Sources/TermHubApp.swift`, `MCP/main.swift`, tests under `Tests/TermHubCoreTests/`.

- [ ] **Step 1: Add failing integration tests** with a fixture vault and a Unix socket in a temporary `0700` directory: same UID can request only one bounded `UUID+kind` secret; malformed frames, oversized data, incorrect UID, locked server, server exit, and timeout fail closed. Check socket mode `0600` and that replies/logs never include the master password. A separate state request returns only unlocked/locked.
- [ ] **Step 2: Run** `swift test --filter CredentialIPCTests` and confirm the missing behaviors fail.
- [ ] **Step 3: Implement** bounded length-delimited request/response, `getpeereid` before lookup, no bulk export, timeout for connect/read, safe socket cleanup guarded by file identity, and lifecycle tied to GUI unlock/lock/quit. MCP uses the socket client as its credential provider; remove `--set-password` (password in argv) and Keychain imports. `list_hosts` stays read-only even locked.
- [ ] **Step 4: On every MCP tool requiring SSH**, check unlock state before consulting the pool; if locked, close pooled clients and return the unlock instruction. Re-check after lookup to limit lock race, retain TOFU constraints, and test locked → unlocked → locked → GUI exited. Cache cannot bypass the lock.
- [ ] **Step 5: Run** IPC tests, all package tests, and an MCP JSON-RPC smoke test using a fixture GUI server. Inspect stderr/stdout for secrets and assert no Keychain prompt/call path.

### Task 4: Complete the remaining entry points and docs

**Files:** `Smoke/main.swift`, `scripts/build-app.sh`, `Packages/TermHubKit/Sources/TermHubCore/Support/KeychainStore.swift` (remove), `Packages/TermHubKit/Sources/TermHubCore/Models/SSHHost.swift`, `docs/mcp-接入与安全模型.md`, `README.md`.

- [ ] **Step 1: Add failing source/build checks**: `rg -n 'KeychainStore|SecItem|security find-identity|钥匙串' App MCP Smoke Packages/TermHubKit scripts` must reveal only explicitly historical documentation, no executable paths. `Smoke --security-audit` uses fixture secrets and asserts no plaintext in vault/store/WAL.
- [ ] **Step 2: Refactor Smoke** to use temporary stdin credentials or the unlocked fixture vault; remove Keychain `--import`, `--security-audit` reads, and misleading messages. Do not execute network Smoke against a real host without an explicit test target.
- [ ] **Step 3: Default app build to ad-hoc signing (`codesign --sign -`) without `security find-identity`; optional explicit release signing is separate and never automatically reads login Keychain. Update README/MCP security model, migration guidance, backup and forgotten-master-password limitations.
- [ ] **Step 4: Run** source audit, `swift test`, `swift build -c release`, `scripts/build-app.sh release` serially; assert installed/executed binaries correspond to this source. Ensure `git diff --check` and no real Keychain data was read, changed, or removed.

### Task 5: Runtime acceptance and safe handoff

**Files:** generated `build/TermHub.app`, optional `bin/TermHubMCP` only after current process and config ownership are verified; no real vault modification for automated tests.

- [ ] **Step 1: Read-only inventory** `ps`/`lsof` of active GUI and MCP processes, binary paths/signatures, socket path, and current config. Avoid replacing a running executable or silently terminating active SSH sessions.
- [ ] **Step 2: Launch a separate test instance with isolated support/vault path**, create/unlock, save synthetic credential, relaunch, lock and prove MCP returns lock errors. Verify no macOS password popup on the user-facing route. For the production GUI/MCP binaries, arrange a deliberate replacement/restart after confirming it will not interrupt active user work.
- [ ] **Step 3: Compare source, packaged and running binary identity; run all tests and audit against the actual shipped path.** Report code/test/package/runtime independently; if current live processes are not switched, state that explicitly instead of claiming the popup is fixed in the running app.
