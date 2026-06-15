# claude-net-monitor

在 [Claude Code](https://claude.com/claude-code)(claude-cli)的状态栏实时显示网络 / 代理状态。
用 Clash 之类的代理翻墙、代理不稳定时，一眼看出当前是通畅、变慢还是断了——无需离开对话界面。

```
🟢 187ms          # 代理通畅
🟡 890ms          # 代理慢（延迟偏高）
🔴 代理断          # 本地网络正常，但代理出境失败
🔴 断网            # 本地网络也不通
```

## 状态含义

| 显示 | 含义 |
|---|---|
| 🟢 `187ms` | 代理通畅（延迟 ≤ 500ms） |
| 🟡 `890ms` | 代理慢（延迟 > 500ms） |
| 🔴 `代理断` | 本地网络正常，但代理出境失败 |
| 🔴 `断网` | 本地网络也不通 |
| ⚪ `检测中` | 守护进程刚启动，尚无首次结果 |

## 平台要求

- **目前仅支持 macOS**：守护进程用到 `stat -f %m`、`date -v` 等 BSD 语法。Linux 需改这两处（欢迎 PR）。
- 依赖：`bash`、`curl`、`awk`（系统自带）。
- 一个本地 HTTP 代理（默认 Clash 混合端口 `127.0.0.1:7897`，可改）。

## 安装

```bash
git clone https://github.com/bangbangmao666666/claude-net-monitor.git && cd claude-net-monitor
./install.sh
```

把脚本拷到 `~/.claude/net-monitor/`，然后在 `~/.claude/settings.json` 配置 statusLine：

```json
"statusLine": {
  "type": "command",
  "command": "~/.claude/net-monitor/statusline.sh"
}
```

新开一个 claude 会话，状态栏几秒内出现。

### 与 cc-costline 等已有状态栏共存

Claude Code 只支持一个 statusLine 命令。如果你已经在用别的状态栏（比如 [cc-costline](https://github.com/) 显示花费），可以改用合并脚本，把两者拼成一行：

```json
"statusLine": {
  "type": "command",
  "command": "~/.claude/net-monitor/statusline-combined.sh"
}
```

效果：`🟢 187ms │ $0.42`。`statusline-combined.sh` 对 cc-costline 是「**有则显示、无则跳过**」——没装也不会报错、更不会自动安装任何东西。

## 工作原理

- **`monitor.sh`**（后台守护进程）：每 5 秒经 curl 探测两件事——
  - 本地直连 `https://www.baidu.com`（判断本地网络）
  - 走代理 HEAD 请求 `https://www.youtube.com`（判断代理出境 + 延迟）

  结果原子写入 `~/.claude/net-monitor/status`。状态栏 30 秒不来读取（claude 关掉了）就自行退出，不留后台进程。
- **`statusline.sh`**：Claude Code 调用，纯读文件、毫秒返回，并在守护进程没跑时按需拉起它。不发任何网络请求。
- **`statusline-combined.sh`**：可选，合并网络监听与 cc-costline 到一行。

## 自定义

编辑 `~/.claude/net-monitor/monitor.sh` 顶部常量：

| 常量 | 默认 | 说明 |
|---|---|---|
| `INTERVAL` | `5` | 探测间隔（秒） |
| `SLOW_MS` | `500` | 慢阈值（毫秒），超过显示 🟡 |
| `TIMEOUT` | `3` | 单次 curl 超时（秒） |
| `HEARTBEAT_TTL` | `30` | 状态栏多久不读取就自杀（秒） |
| `PROXY` | `http://127.0.0.1:7897` | 本地代理地址（Clash 混合端口） |
| `DIRECT_URL` | `https://www.baidu.com` | 本地直连探测目标 |
| `PROXY_URL` | `https://www.youtube.com` | 代理出境探测目标 |

改完无需重启：守护进程会在下次自杀后由状态栏重新拉起；或手动
`pkill -f net-monitor/monitor.sh` 让它立刻重起。

## 排障

- 状态栏一直 `⚪ 检测中`：看 `~/.claude/net-monitor/monitor.log`，确认 `monitor.sh` 能跑、`curl` 可用。
- 手动单测一次探测：`~/.claude/net-monitor/monitor.sh --once`，会打印当前状态行。
- 确认守护进程在跑：`pgrep -f net-monitor/monitor.sh`。

## License

[MIT](./LICENSE)
