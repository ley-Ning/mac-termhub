# TermHub MCP 接入指南与安全模型

## 接入 AI 客户端

在 AI 客户端（ZCode / Claude Code 等）的 MCP 配置中加入：

```json
{
  "mcpServers": {
    "termhub": {
      "command": "/Users/wen/WorkBuddy/TermHub/.build/release/TermHubMCP"
    }
  }
}
```

无需 GUI 常驻；stdio 传输，AI 客户端按需拉起进程，进程退出即断开全部连接。

排错：临时把 `"env": {"TERMHUB_MCP_DEBUG": "1"}` 加进配置，stderr 会输出收发日志。

## 工具一览

| 工具 | 用途 |
|---|---|
| `list_hosts` | 列出已配置主机（别名/地址/用户/认证方式/分组/备注） |
| `exec` | 远程执行命令（host 别名 + command，可选 timeoutSeconds） |
| `docker_status` | 全部容器状态（名称/镜像/状态/端口） |
| `docker_logs` | 容器日志（container + lines? + grep?，grep 在本地过滤） |

主机必须先在 TermHub App 里添加；**MCP 不提供添加/修改主机或设置密码的入口**。

## 安全模型（凭据零暴露）

1. **凭据只在 Keychain**：SSH 密码与私钥口令仅存 macOS Keychain，MCP 进程只在建连瞬间读取，任何工具的返回结构中不存在凭据字段——AI 从协议上就拿不到密码。
2. **指纹需预先人工信任**：MCP 只连接已在 GUI 指纹确认框里信任过（known_hosts）的主机；遇到未知指纹一律拒绝并提示去 GUI 操作，杜绝静默信任/中间人。
3. **输入不拼接 shell**：`docker_logs` 的容器名做 `^[A-Za-z0-9_.-]+$` 白名单校验，`grep` 在本地对返回文本过滤；AI 的输入不会被拼进远端 shell 命令（`exec` 除外——它本身就是执行命令的工具，用意明确）。
4. **主机清单无敏感字段**：`list_hosts` 只输出元数据，私钥只显示路径不显示内容。
5. **机密走环境变量**：任何未来的 token/密钥配置一律走环境变量（如 `TERMHUB_MCP_TOKEN`），不落配置文件。

## 主机数据存放

- 主机配置（SwiftData）：`~/Library/Application Support/TermHub/TermHub.store`（GUI 与 MCP 共享）
- 已信任指纹：`~/Library/Application Support/TermHub/known_hosts.json`
- 凭据：macOS Keychain（service 前缀 `com.termhub.host.`）
