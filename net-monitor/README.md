# claude-net-monitor

claude-cli 状态栏实时网络 / Clash 代理监听。代理不稳定时，一眼看出是通畅、变慢还是断了。

## 状态含义

| 显示 | 含义 |
|---|---|
| 🟢 `187ms` | 代理通畅（延迟 ≤ 500ms） |
| 🟡 `890ms` | 代理慢（延迟 > 500ms） |
| 🔴 `代理断` | 本地网络正常，但代理出境失败 |
| 🔴 `断网` | 本地网络也不通 |
| ⚪ `检测中` | 守护进程刚启动，尚无首次结果 |

## 工作原理

- **`monitor.sh`**（后台守护进程）：每 5 秒经 curl 探测两件事——
  - 本地直连 `https://www.baidu.com`（判断本地网络）
  - 走代理 `127.0.0.1:7897` HEAD 请求 `https://www.youtube.com`（判断代理出境 + 延迟）

  结果原子写入 `~/.claude/net-monitor/status`。状态栏 30 秒不来读取（claude 关掉了）就自行退出，不留后台。
- **`statusline.sh`**：Claude Code statusLine 调用，纯读文件、毫秒返回，并在守护进程没跑时按需拉起它。不发任何网络请求。
- **`statusline-combined.sh`**：合并状态栏。把网络监听与 `cc-costline`（花费显示）拼成一行，形如
  `🟢 187ms │ $0.42`。Claude Code 的 JSON 经 stdin 只能消费一次，故先捕获再分发给两个子命令。
  没有 `cc-costline` 时自动只显示网络部分。

## 安装

```bash
./install.sh
```

把三个脚本拷到 `~/.claude/net-monitor/`，然后在 `~/.claude/settings.json` 配置：

```json
"statusLine": {
  "type": "command",
  "command": "~/.claude/net-monitor/statusline-combined.sh"
}
```

> 只想要网络、不要花费合并时，把 `command` 改成 `~/.claude/net-monitor/statusline.sh` 即可。

改完新开一个 claude 会话，状态栏几秒内出现。

## 自定义

编辑 `~/.claude/net-monitor/monitor.sh` 顶部常量：

| 常量 | 默认 | 说明 |
|---|---|---|
| `INTERVAL` | `5` | 探测间隔（秒） |
| `SLOW_MS` | `500` | 慢阈值（毫秒），超过显示 🟡 |
| `TIMEOUT` | `3` | 单次 curl 超时（秒） |
| `HEARTBEAT_TTL` | `30` | 状态栏多久不读取就自杀（秒） |
| `PROXY` | `http://127.0.0.1:7897` | Clash 混合代理地址 |
| `DIRECT_URL` | `https://www.baidu.com` | 本地直连探测目标 |
| `PROXY_URL` | `https://www.youtube.com` | 代理出境探测目标 |

改完无需重启：守护进程会在下次自杀后由状态栏重新拉起；或手动
`pkill -f net-monitor/monitor.sh` 让它立刻重起。

## 排障

- 状态栏一直 `⚪ 检测中`：看 `~/.claude/net-monitor/monitor.log`，确认 `monitor.sh` 能跑、curl 可用。
- 手动单测一次探测：`~/.claude/net-monitor/monitor.sh --once`，会打印当前状态行。
- 确认守护进程在跑：`pgrep -f net-monitor/monitor.sh`。

## 文件

```
monitor.sh              # 守护进程：探测 + 判定 + 自杀
statusline.sh           # 纯网络状态栏脚本
statusline-combined.sh  # 网络 + cc-costline 合并状态栏
install.sh              # 安装到 ~/.claude/net-monitor
```

运行期在 `~/.claude/net-monitor/` 生成：`status`、`monitor.pid`、`heartbeat`、`monitor.log`（均不入库）。
