# Claude Code 网络监听状态栏 — 设计文档

日期：2026-06-15
作者：penny.young

## 背景与目标

用户在终端使用 claude-cli（Claude Code）时通过 Clash Verge（verge-mihomo）翻墙，代理不稳定。
需要在 **不离开 claude 界面** 的前提下，实时知道网络是否通畅，并能区分"本地断网"还是"代理挂了"。

实现方式：Claude Code 的 `statusLine` 自定义状态栏，底部常驻一行网络状态。

### 环境事实（已确认）

- macOS（Darwin 25.5.0），shell：zsh
- Clash Verge 运行中，**混合代理端口 `127.0.0.1:7897`（已确认开放）**
- Clash **未开启 TCP RESTful API**：`external-controller` 为空，仅有 unix socket，且 secret 为占位符
  → 因此不依赖 Clash API，改用 curl 走代理端口直接探测（更贴近真实翻墙体验）
- claude-cli 版本 2.1.177

## 状态定义

状态栏显示一行，三档状态用带颜色 emoji：

| 状态 | 触发条件 | 显示示例 |
|---|---|---|
| 🟢 通畅 | 代理出境成功，延迟 ≤ 500ms | `🟢 187ms` |
| 🟡 慢 | 代理出境成功，延迟 > 500ms | `🟡 890ms` |
| 🔴 代理断 | 本地直连成功，但代理出境失败 | `🔴 代理断` |
| 🔴 断网 | 本地直连也失败 | `🔴 断网` |
| ⚪ 初始化 | 守护进程刚启动，尚无首次探测结果 | `⚪ 检测中` |

- 慢阈值 `SLOW_MS = 500`（可在脚本顶部常量调整）
- emoji 由用户选定（绿/黄/红）

## 检测方式

每个探测周期（默认 5 秒）跑两个独立探测：

1. **本地直连**：不走代理 curl 国内稳定目标，判断本地网络
   - 目标：`https://www.baidu.com`
   - `curl -s -o /dev/null --max-time 3 -w '%{http_code} %{time_total}'`
2. **代理出境**：走 `http://127.0.0.1:7897` curl 境外目标，判断代理
   - 目标：`https://www.youtube.com`（比 Google 更能反映真实翻墙体验：有些代理能连 Google 却卡 YouTube）
   - 用 **HEAD 请求**（`curl -sI -o /dev/null --max-time 3 --proxy http://127.0.0.1:7897 -w '%{http_code} %{time_total}'`），只拿响应头、不下载几百 KB 正文，5 秒一次也不费流量
   - 延迟取该请求的 `time_total`，毫秒化

判定逻辑：
- 代理成功（http 2xx/204）→ 按延迟分 🟢/🟡
- 代理失败但直连成功 → 🔴 代理断
- 直连也失败 → 🔴 断网

常量（脚本顶部，便于改）：`INTERVAL=5`、`SLOW_MS=500`、`PROXY=http://127.0.0.1:7897`、
`DIRECT_URL`、`PROXY_URL`、`TIMEOUT=3`、`HEARTBEAT_TTL=30`。

## 架构

statusLine 命令每次刷新都会被 Claude Code 调用，必须瞬间返回、不能阻塞网络。
因此拆成「探测守护进程」+「读取状态的状态栏脚本」两部分，通过状态文件通信。

```
~/.claude/net-monitor/
  monitor.sh       # 守护进程：循环探测，写 status
  statusline.sh    # 状态栏脚本：读 status，秒回；负责拉起守护进程
  status           # 当前状态（单行，由 monitor.sh 写）
  monitor.pid      # 守护进程 pid
  heartbeat        # statusline 每次被调用时 touch；守护进程据此自杀
  monitor.log      # 守护进程标准错误日志（排障用）
```

### 组件 1：monitor.sh（守护进程）

- 启动时写 `monitor.pid`
- `while true` 循环：
  1. 检查 `heartbeat` 文件 mtime，若距今 > `HEARTBEAT_TTL`(30s) → 说明状态栏已不再读取（claude 关了）→ 自行退出，清理 pid
  2. 跑本地直连 + 代理出境两个探测
  3. 按判定逻辑生成状态行，原子写入 `status`（先写临时文件再 `mv`，避免读到半行）
  4. `sleep INTERVAL`
- 单实例保证：启动前检查 pid 是否存活，已存活则退出

### 组件 2：statusline.sh（状态栏脚本）

Claude Code 调用时通过 stdin 传入 JSON 上下文（本脚本不需要用它）。流程：
1. `touch heartbeat`（告诉守护进程"我还在"）
2. 检查守护进程是否存活（读 pid，`kill -0`）；不存活则 `nohup monitor.sh >> monitor.log 2>&1 &` 拉起
3. 读 `status` 文件内容并输出（首行）；文件不存在则输出 `⚪ 检测中`
4. 整个过程不发起任何网络请求，纯本地文件操作，毫秒级返回

### 组件 3：Claude Code 配置

在 `~/.claude/settings.json` 增加：
```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/net-monitor/statusline.sh"
  }
}
```
（若用户已有 statusLine，需要合并/告知，不能直接覆盖。）

## 生命周期（方案 A 自托管）

- **启动**：打开 claude → 状态栏首次刷新 → statusline.sh 发现守护进程没跑 → 拉起 → 5 秒内出现首次状态
- **运行**：守护进程后台每 5 秒探测；状态栏每次刷新读文件，无感
- **退出**：关掉 claude → 状态栏不再刷新 → heartbeat 停止更新 → 守护进程 30 秒内检测到、自行退出
- 结果：零手动配置、零常驻后台、只在用 claude 时才探测

## 错误处理

- curl 超时/失败：视为对应探测失败，不让脚本崩溃（`set +e` 局部处理，捕获退出码）
- 状态文件缺失或损坏：statusline.sh 回退显示 `⚪ 检测中`
- 守护进程意外死亡：下次状态栏刷新时由 statusline.sh 重新拉起
- pid 文件残留（进程已死）：用 `kill -0` 校验，失效则忽略并重启
- 写状态文件用「临时文件 + mv」原子替换，避免状态栏读到半行

## 测试方案

- **单元/手动**：
  - 直接运行 `monitor.sh`，确认每 5 秒更新 `status`
  - 运行 `statusline.sh`，确认输出当前状态行且能拉起守护进程
  - 模拟代理断：临时改 `PROXY` 端口为无效值 → 应显示 🔴 代理断
  - 模拟断网：断开 Wi-Fi → 应显示 🔴 断网
  - 模拟慢：把 `SLOW_MS` 调到极低 → 应显示 🟡
  - 自杀测试：停止 touch heartbeat，等 30 秒，确认守护进程自动退出
- **集成**：配置 settings.json 后启动 claude，肉眼确认状态栏出现并随网络变化

## 非目标（YAGNI）

- 不做延迟趋势图/丢包率（用户选了简洁版）
- 不依赖 Clash RESTful API
- 不做 launchd 常驻
- 不做多代理节点切换/管理

## 文件清单

```
~/.claude/net-monitor/monitor.sh
~/.claude/net-monitor/statusline.sh
~/.claude/settings.json   （新增/合并 statusLine 字段）
```
运行期生成：status / monitor.pid / heartbeat / monitor.log
