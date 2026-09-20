# Mac-TermHub

macOS 原生 SSH 可视化管理客户端（类 HexHub）：SwiftUI + SwiftTerm + Citadel，纯 SwiftPM 工程（无 xcodeproj）。

## 功能

- **主机管理**：分组（折叠/重命名/移动）、搜索、连接凭据只存 Keychain，TOFU 主机指纹信任（首次弹窗确认，指纹变化自动拒绝）
- **多标签终端**：同一连接多开 shell，右上角随开随用
- **右侧工具面板**（与终端并排、可拖宽）：
  - **容器**：Docker 容器/镜像列表、CPU/内存占用、日志跟随（tail 行数/导出）、启停重启
  - **文件**：SFTP 双栏文件管理——远端预览/编辑写回、复制/剪切/粘贴、递归删除、chmod、新建文件/目录；本地栏上传/重命名/废纸篓；传输队列带进度
  - **资源**：CPU/内存仪表+历史曲线、网络速率、磁盘、负载（只读 /proc 等，服务器免安装）
- **HTTP 代理**：可按主机配置 CONNECT 隧道代理直连客户现场
- **MCP**（`TermHubMCP`，stdio JSON-RPC）：AI 客户端可用 list_hosts / exec / docker_status / docker_logs / server_stats 操作主机；凭据零暴露（密码只存 Keychain、工具响应不含任何凭据字段、仅连已信任指纹的主机）

## 构建

```bash
swift build --skip-update          # 调试
./scripts/build-app.sh release     # 组装 build/TermHub.app（ad-hoc 签名）
open build/TermHub.app
```

要求：macOS 15+，Xcode 命令行工具。

## MCP 接入

```json
{ "mcpServers": { "termhub": { "command": "/path/to/TermHub/.build/release/TermHubMCP" } } }
```

密码通过 `TermHubMCP --set-password <别名> <密码>` 写入 Keychain（不落盘）。详见 `docs/mcp-接入与安全模型.md`。

## 说明

- `Packages/Citadel` 是带补丁的 vendored fork（ClientSession 用 `eventLoop.submit` 修复 `connect(on:)` 跨线程崩溃）；升级依赖需重打补丁。
- UI 自检：`TERMHUB_UITEST=1 ./.build/debug/TermHub` 自动连演示机、遍历面板截图并打印 NSView 布局转储。
