# TermHub

**A native macOS SSH client for visual server management.** SwiftUI + SwiftTerm + Citadel, pure SwiftPM (no xcodeproj).

**macOS 原生 SSH 可视化管理客户端。** SwiftUI + SwiftTerm + Citadel，纯 SwiftPM 工程（无 xcodeproj）。

**[English](#english) | [中文](#中文)**

---

<a id="english"></a>

## English

A HexHub-style visual SSH client for macOS. Manage hosts, run multi-tab terminals, browse files, watch resources — all native, all fast. Credentials live **only** in the macOS Keychain.

### Features

- **Host management** — groups (collapse / rename / move), search, sidebar **latency monitor** (TCP RTT, auto-refresh), credentials stored **only** in Keychain, TOFU host-key trust (first-connect prompt, changed fingerprints auto-rejected)
- **Multi-tab terminal** — multiple shells over one connection; multi-line paste protection (all / first-line-only / cancel); ⌘K fuzzy host switcher
- **Side tool panels** (side-by-side with the terminal, resizable):
  - **Docker** — containers & images, CPU/memory usage, log follow (tail / export), start / stop / restart
  - **Files** — dual-pane SFTP manager: breadcrumb navigation, type-a-path jump, click-to-enter directories, preview / edit-and-write-back, copy / cut / paste, recursive delete, chmod, new file / folder; local pane with upload / rename / trash; transfer queue with progress
  - **Stats** — CPU / memory gauges + history curves, network rates, disk usage, **disk I/O latency (await / util)**, load — read-only `/proc` sampling, nothing to install server-side, 1s default interval
  - **Processes** — process & listening-port list (ps + ss), kill / kill -9
  - **Snippets** — reusable command snippets, per-host scoping, send to terminal
- **Jump hosts** — per-host jump chain (multi-hop, cycle detection)
- **Auto-reconnect & keepalive** — exponential backoff, heartbeat against idle drops
- **HTTP proxy** — per-host CONNECT tunnel for customer-site gateways
- **Themes** — appearance mode (system / light / dark), 8 accent colors, 5 terminal color schemes, live switching
- **In-app hot update** — check GitHub for updates, one-click rebuild + restart (dev machines)
- **MCP server** (`TermHubMCP`, stdio JSON-RPC) — let AI clients (ZCode, Claude Code, …) operate hosts via `list_hosts / exec / docker_status / docker_logs / server_stats`; zero credential exposure (Keychain-only, no secrets in any tool response, connects only to fingerprint-trusted hosts)

### Install

- **Download**: grab the latest `TermHub-x.y.z.dmg` from [Releases](https://github.com/ley-Ning/mac-termhub/releases), drag to /Applications. First launch: right-click → Open.
- **Homebrew** (no tap needed):

```bash
brew install --cask https://raw.githubusercontent.com/ley-Ning/mac-termhub/main/Casks/termhub.rb
```

- **From source**:

```bash
swift build --skip-update          # debug
./scripts/build-app.sh release     # assemble build/TermHub.app
open build/TermHub.app
```

Requires macOS 15+ and Xcode command-line tools. Tagging `v*` triggers CI to build & publish a Release.

### MCP integration

```json
{ "mcpServers": { "termhub": { "command": "/path/to/TermHub/.build/release/TermHubMCP" } } }
```

See `docs/mcp-接入与安全模型.md` for the full security model.

### Notes

- `Packages/Citadel` is a vendored fork with a patch (ClientSession `eventLoop.submit` fix for a `connect(on:)` crash); re-apply the patch when upgrading.
- UI self-test: `TERMHUB_UITEST=1 ./.build/release/TermHub` walks through panels, takes screenshots and dumps NSView layout.

---

<a id="中文"></a>

## 中文

类 HexHub 的 macOS 可视化 SSH 客户端：管主机、开多标签终端、传文件、看资源，全部原生实现。凭据**只存 macOS 钥匙串**。

### 功能

- **主机管理**：分组（折叠/重命名/移动）、搜索、侧栏**延迟监测**（TCP 往返，自动刷新）；凭据只存 Keychain；TOFU 指纹信任（首次弹窗确认，指纹变化自动拒绝）
- **多标签终端**：同一连接多开 shell；多行粘贴保护（全部/仅首行/取消）；⌘K 模糊跳转主机
- **右侧工具面板**（与终端并排、可拖宽）：
  - **容器**：Docker 容器/镜像、CPU/内存占用、日志跟随（tail 行数/导出）、启停重启
  - **文件**：SFTP 双栏——面包屑导航、手动输路径直达、单击进目录、预览/编辑写回、复制/剪切/粘贴、递归删除、chmod、新建文件/目录；本地栏上传/重命名/废纸篓；传输队列带进度
  - **资源**：CPU/内存仪表+历史曲线、网络速率、磁盘、**磁盘 I/O 延迟（await/util）**、负载——只读 /proc 采样，服务器免安装，默认 1 秒刷新
  - **进程**：进程与监听端口列表（ps + ss）、kill / kill -9
  - **片段**：常用命令片段、按主机作用域、一键发终端
- **跳板机**：按主机配置跳板链（多级跳、防环）
- **自动重连 + 心跳保活**：指数退避，防空闲掉线
- **HTTP 代理**：按主机配置 CONNECT 隧道，直连客户现场网关
- **主题**：外观模式（跟随系统/浅/深）、8 色强调色、5 套终端配色，即时切换
- **应用内热更新**：检查 GitHub 更新，一键拉代码重建并重启（开发机）
- **MCP**（`TermHubMCP`，stdio JSON-RPC）：AI 客户端（ZCode、Claude Code 等）用 `list_hosts / exec / docker_status / docker_logs / server_stats` 操作主机；**凭据零暴露**（密码只存 Keychain、工具响应不含任何凭据字段、仅连已信任指纹的主机）

### 安装

- **直接下载**：[Releases](https://github.com/ley-Ning/mac-termhub/releases) 下载最新 `TermHub-x.y.z.dmg`，拖入「应用程序」。首次打开：右键 → 打开。
- **Homebrew**（无需 tap）：

```bash
brew install --cask https://raw.githubusercontent.com/ley-Ning/mac-termhub/main/Casks/termhub.rb
```

- **从源码**：打 tag `v*` 自动构建发布 Release（`.github/workflows/release.yml`）。

```bash
swift build --skip-update          # 调试
./scripts/build-app.sh release     # 组装 build/TermHub.app
open build/TermHub.app
```

要求 macOS 15+、Xcode 命令行工具。

### MCP 接入

```json
{ "mcpServers": { "termhub": { "command": "/path/to/TermHub/.build/release/TermHubMCP" } } }
```

完整安全模型见 `docs/mcp-接入与安全模型.md`。

### 说明

- `Packages/Citadel` 是带补丁的 vendored fork（ClientSession `eventLoop.submit` 修复 `connect(on:)` 跨线程崩溃）；升级依赖需重打补丁。
- UI 自检：`TERMHUB_UITEST=1 ./.build/release/TermHub` 自动遍历面板、截图并打印 NSView 布局转储。
