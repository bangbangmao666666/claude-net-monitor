# Claude Code 网络监听状态栏 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 claude-cli 状态栏实时显示网络/Clash 代理状态（🟢 通畅 / 🟡 慢 / 🔴 断），区分本地断网与代理挂掉。

**Architecture:** 后台守护进程每 5 秒经 curl 探测本地直连与代理出境，把结果原子写入状态文件；状态栏脚本只读文件秒回，并负责按需拉起守护进程；守护进程在状态栏 30 秒不读取后自杀。零常驻、零手动配置。

**Tech Stack:** bash、curl、Claude Code `statusLine`（command 类型）。目标环境 macOS / zsh。

参考 spec：`docs/superpowers/specs/2026-06-15-claude-net-monitor-design.md`

---

## 文件结构

```
~/.claude/net-monitor/
  monitor.sh       # 守护进程：循环探测，原子写 status，heartbeat 超时自杀
  statusline.sh    # 状态栏脚本：touch heartbeat、按需拉起守护进程、读 status 输出
  status           # 运行期生成：当前状态单行
  monitor.pid      # 运行期生成：守护进程 pid
  heartbeat        # 运行期生成：statusline 每次调用 touch
  monitor.log      # 运行期生成：守护进程日志
~/.claude/settings.json  # 合并 statusLine 字段
```

常量（两个脚本顶部共享口径，必要时各自定义）：
`INTERVAL=5`、`SLOW_MS=500`、`TIMEOUT=3`、`HEARTBEAT_TTL=30`、
`PROXY=http://127.0.0.1:7897`、
`DIRECT_URL=https://www.baidu.com`、`PROXY_URL=https://www.youtube.com`、
`DIR=$HOME/.claude/net-monitor`

> 注：当前工作目录 `/Users/liangchao/Desktop/terminal-plugins` 不是 git 仓库。每个 Task 末尾的 commit 步骤需要先在该目录 `git init`（见 Task 0）。脚本本身安装在 `~/.claude/net-monitor/`，但源码副本同时纳入本仓库的 `net-monitor/` 目录做版本管理。

---

### Task 0: 初始化仓库与目录骨架

**Files:**
- Create: `/Users/liangchao/Desktop/terminal-plugins/.gitignore`
- Create: `/Users/liangchao/Desktop/terminal-plugins/net-monitor/.gitkeep`

- [ ] **Step 1: 初始化 git 仓库**

Run:
```bash
cd /Users/liangchao/Desktop/terminal-plugins && git init
```
Expected: `Initialized empty Git repository ...`

- [ ] **Step 2: 写 .gitignore（排除运行期产物）**

Create `/Users/liangchao/Desktop/terminal-plugins/.gitignore`:
```gitignore
# 运行期产物（安装在 ~/.claude/net-monitor，不入库）
status
monitor.pid
heartbeat
monitor.log
.DS_Store
```

- [ ] **Step 3: 建源码目录占位**

Run:
```bash
mkdir -p /Users/liangchao/Desktop/terminal-plugins/net-monitor && touch /Users/liangchao/Desktop/terminal-plugins/net-monitor/.gitkeep
```
Expected: 无输出，目录创建成功

- [ ] **Step 4: 首次提交**

```bash
cd /Users/liangchao/Desktop/terminal-plugins
git add .gitignore net-monitor/.gitkeep docs/
git commit -m "chore: init repo with net-monitor spec and plan"
```
Expected: 提交成功，包含 spec、plan、.gitignore

---

### Task 1: monitor.sh 探测与判定核心（可独立运行）

**Files:**
- Create: `/Users/liangchao/Desktop/terminal-plugins/net-monitor/monitor.sh`

本 Task 先把"探测一次 → 生成状态行"的核心做出来并能独立验证，再在 Task 2 包上循环与自杀逻辑。

- [ ] **Step 1: 写脚本骨架与常量、探测函数、判定函数**

Create `/Users/liangchao/Desktop/terminal-plugins/net-monitor/monitor.sh`:
```bash
#!/usr/bin/env bash
# Claude Code 网络监听守护进程：循环探测本地直连与 Clash 代理出境，
# 把状态原子写入 status 文件。状态栏 30 秒不读取则自杀。
set -u

# ---- 常量 ----
INTERVAL=5
SLOW_MS=500
TIMEOUT=3
HEARTBEAT_TTL=30
PROXY="http://127.0.0.1:7897"
DIRECT_URL="https://www.baidu.com"
PROXY_URL="https://www.youtube.com"
DIR="$HOME/.claude/net-monitor"
STATUS_FILE="$DIR/status"
PID_FILE="$DIR/monitor.pid"
HEARTBEAT_FILE="$DIR/heartbeat"

mkdir -p "$DIR"

# 直连探测：成功输出 "ok <ms>"，失败输出 "fail"
probe_direct() {
  local out code
  out=$(curl -s -o /dev/null --max-time "$TIMEOUT" \
    -w '%{http_code} %{time_total}' "$DIRECT_URL" 2>/dev/null) || { echo "fail"; return; }
  code=${out%% *}
  if [[ "$code" =~ ^2|^3 ]]; then
    echo "ok ${out##* }"
  else
    echo "fail"
  fi
}

# 代理探测：HEAD 请求，成功输出 "ok <ms>"，失败输出 "fail"
probe_proxy() {
  local out code
  out=$(curl -sI -o /dev/null --max-time "$TIMEOUT" --proxy "$PROXY" \
    -w '%{http_code} %{time_total}' "$PROXY_URL" 2>/dev/null) || { echo "fail"; return; }
  code=${out%% *}
  if [[ "$code" =~ ^2|^3 ]]; then
    echo "ok ${out##* }"
  else
    echo "fail"
  fi
}

# 秒转毫秒整数（curl time_total 形如 0.187）
to_ms() {
  awk -v t="$1" 'BEGIN{ printf "%d", t*1000 }'
}

# 根据两个探测结果生成状态行
decide() {
  local direct="$1" proxy="$2"
  if [[ "$proxy" == ok* ]]; then
    local ms; ms=$(to_ms "${proxy##* }")
    if (( ms <= SLOW_MS )); then
      echo "🟢 ${ms}ms"
    else
      echo "🟡 ${ms}ms"
    fi
  elif [[ "$direct" == ok* ]]; then
    echo "🔴 代理断"
  else
    echo "🔴 断网"
  fi
}

# 原子写状态文件
write_status() {
  local tmp="$STATUS_FILE.tmp.$$"
  printf '%s\n' "$1" > "$tmp" && mv -f "$tmp" "$STATUS_FILE"
}

# 跑一次完整探测并写状态
run_once() {
  local d p
  d=$(probe_direct)
  p=$(probe_proxy)
  write_status "$(decide "$d" "$p")"
}

# 允许被 source 时只载入函数，不执行主流程（便于测试）
if [[ "${1:-}" == "--once" ]]; then
  run_once
  cat "$STATUS_FILE"
fi
```

- [ ] **Step 2: 加可执行权限并验证「能跑出真实状态」**

Run:
```bash
chmod +x /Users/liangchao/Desktop/terminal-plugins/net-monitor/monitor.sh
/Users/liangchao/Desktop/terminal-plugins/net-monitor/monitor.sh --once
```
Expected: 输出一行，例如 `🟢 187ms`（当前代理正常时）。这是"真实通过"基线。

- [ ] **Step 3: 验证「代理断」判定（故意用坏端口）**

Run:
```bash
PROXY_BAD=1 bash -c '
  source /Users/liangchao/Desktop/terminal-plugins/net-monitor/monitor.sh
  PROXY="http://127.0.0.1:1" 
  d=$(probe_direct); p=$(probe_proxy); decide "$d" "$p"
'
```
Expected: 输出 `🔴 代理断`（本地 baidu 通、代理端口 1 连不上）。
> 若本机此刻断网，会输出 `🔴 断网`，属正常；联网后重跑应为 `🔴 代理断`。

- [ ] **Step 4: 验证「慢」判定（把阈值压到极低）**

Run:
```bash
bash -c '
  source /Users/liangchao/Desktop/terminal-plugins/net-monitor/monitor.sh
  SLOW_MS=1
  p=$(probe_proxy); decide "ok 0.050" "$p"
'
```
Expected: 输出 `🟡 50ms`（阈值 1ms，50ms 判为慢）。

- [ ] **Step 5: 提交**

```bash
cd /Users/liangchao/Desktop/terminal-plugins
git add net-monitor/monitor.sh
git commit -m "feat(net-monitor): probe + decide core with --once mode"
```
Expected: 提交成功

---

### Task 2: monitor.sh 守护循环与自杀逻辑

**Files:**
- Modify: `/Users/liangchao/Desktop/terminal-plugins/net-monitor/monitor.sh`（在文件末尾的 `--once` 分支后追加守护主流程）

- [ ] **Step 1: 追加单实例守护与 heartbeat 自杀的主循环**

在 `monitor.sh` 末尾（Step 1 写的 `--once` 分支之后）追加：
```bash

# ---- 守护主流程（无参数运行时进入）----

# heartbeat 是否超时：无文件或 mtime 距今 > HEARTBEAT_TTL 视为超时
heartbeat_stale() {
  [[ -f "$HEARTBEAT_FILE" ]] || return 0
  local now mtime age
  now=$(date +%s)
  mtime=$(stat -f %m "$HEARTBEAT_FILE" 2>/dev/null || echo 0)
  age=$(( now - mtime ))
  (( age > HEARTBEAT_TTL ))
}

main_loop() {
  # 单实例：已有存活进程则退出
  if [[ -f "$PID_FILE" ]]; then
    local oldpid; oldpid=$(cat "$PID_FILE" 2>/dev/null || echo "")
    if [[ -n "$oldpid" ]] && kill -0 "$oldpid" 2>/dev/null; then
      exit 0
    fi
  fi
  echo $$ > "$PID_FILE"
  # 启动时先写一个初始状态，避免状态栏长时间空白
  [[ -f "$STATUS_FILE" ]] || write_status "⚪ 检测中"

  trap 'rm -f "$PID_FILE"; exit 0' INT TERM
  while true; do
    if heartbeat_stale; then
      rm -f "$PID_FILE"
      exit 0
    fi
    run_once
    sleep "$INTERVAL"
  done
}

# 仅在无参数（非 --once、非被 source）时进入守护循环
if [[ "${1:-}" != "--once" ]] && [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main_loop
fi
```

> 说明：`stat -f %m` 是 macOS（BSD stat）取 mtime 的写法，与目标环境一致。

- [ ] **Step 2: 验证守护进程能持续刷新 status**

先确保有新鲜 heartbeat，再后台启动并观察：
```bash
touch ~/.claude/net-monitor/heartbeat
/Users/liangchao/Desktop/terminal-plugins/net-monitor/monitor.sh &
MON=$!
sleep 12
echo "--- status ---"; cat ~/.claude/net-monitor/status
echo "--- pid alive? ---"; kill -0 "$MON" && echo "alive"
```
Expected: status 有内容（如 `🟢 187ms`）；进程 alive。

- [ ] **Step 3: 验证 heartbeat 超时自杀**

接上一步（`MON` 仍在跑）。把 heartbeat 时间改老，等一个探测周期后应自杀：
```bash
# 把 heartbeat mtime 设到 60 秒前
touch -t "$(date -v-60S +%Y%m%d%H%M.%S)" ~/.claude/net-monitor/heartbeat
sleep 7
kill -0 "$MON" 2>/dev/null && echo "STILL ALIVE (BUG)" || echo "self-exited OK"
```
Expected: `self-exited OK`，且 `~/.claude/net-monitor/monitor.pid` 已被删除。
（若仍 alive：`kill "$MON"` 清理后排查。）

- [ ] **Step 4: 验证单实例（第二个实例应立即退出）**

```bash
touch ~/.claude/net-monitor/heartbeat
/Users/liangchao/Desktop/terminal-plugins/net-monitor/monitor.sh & A=$!
sleep 2
/Users/liangchao/Desktop/terminal-plugins/net-monitor/monitor.sh ; echo "second exit code: $?"
kill -0 "$A" && echo "first still alive OK"
kill "$A" 2>/dev/null; rm -f ~/.claude/net-monitor/monitor.pid
```
Expected: 第二个实例立刻退出（exit 0），第一个仍 alive。

- [ ] **Step 5: 提交**

```bash
cd /Users/liangchao/Desktop/terminal-plugins
git add net-monitor/monitor.sh
git commit -m "feat(net-monitor): daemon loop with single-instance + heartbeat suicide"
```
Expected: 提交成功

---

### Task 3: statusline.sh 状态栏脚本

**Files:**
- Create: `/Users/liangchao/Desktop/terminal-plugins/net-monitor/statusline.sh`

- [ ] **Step 1: 写状态栏脚本**

Create `/Users/liangchao/Desktop/terminal-plugins/net-monitor/statusline.sh`:
```bash
#!/usr/bin/env bash
# Claude Code statusLine 脚本：被频繁调用，必须秒回、不发网络请求。
# 职责：touch heartbeat → 按需拉起守护进程 → 读 status 并输出。
set -u

DIR="$HOME/.claude/net-monitor"
STATUS_FILE="$DIR/status"
PID_FILE="$DIR/monitor.pid"
HEARTBEAT_FILE="$DIR/heartbeat"
LOG_FILE="$DIR/monitor.log"
MONITOR="$DIR/monitor.sh"

mkdir -p "$DIR"

# 吞掉 Claude Code 经 stdin 传入的 JSON（本脚本不需要它），避免管道阻塞
cat > /dev/null 2>&1 || true

# 告诉守护进程"状态栏还在用"
touch "$HEARTBEAT_FILE"

# 守护进程是否存活
daemon_alive() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid; pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# 不存活则后台拉起（脱离当前进程，避免被 claude 回收）
if ! daemon_alive; then
  if [[ -x "$MONITOR" ]]; then
    nohup "$MONITOR" >> "$LOG_FILE" 2>&1 &
    disown 2>/dev/null || true
  fi
fi

# 输出当前状态；文件缺失则回退
if [[ -f "$STATUS_FILE" ]]; then
  head -n1 "$STATUS_FILE"
else
  echo "⚪ 检测中"
fi
```

- [ ] **Step 2: 加可执行权限**

Run:
```bash
chmod +x /Users/liangchao/Desktop/terminal-plugins/net-monitor/statusline.sh
```
Expected: 无输出

- [ ] **Step 3: 验证首次调用会拉起守护进程并最终出状态**

先清理环境，模拟 claude 首次调用（stdin 给个假 JSON）：
```bash
rm -f ~/.claude/net-monitor/monitor.pid ~/.claude/net-monitor/status
pkill -f net-monitor/monitor.sh 2>/dev/null
echo '{"session":"x"}' | /Users/liangchao/Desktop/terminal-plugins/net-monitor/statusline.sh
echo "--- pid file? ---"; sleep 7
cat ~/.claude/net-monitor/monitor.pid 2>/dev/null && echo "daemon started OK"
echo "--- status after 7s ---"; /Users/liangchao/Desktop/terminal-plugins/net-monitor/statusline.sh </dev/null
```
Expected: 首次输出 `⚪ 检测中`；7 秒后守护进程已起、再次调用输出真实状态（如 `🟢 187ms`）。

- [ ] **Step 4: 验证脚本响应快（不阻塞）**

Run:
```bash
time (/Users/liangchao/Desktop/terminal-plugins/net-monitor/statusline.sh </dev/null >/dev/null)
```
Expected: real 时间在数十毫秒级（远小于 1 秒），证明不发网络请求。

- [ ] **Step 5: 清理测试进程并提交**

```bash
pkill -f net-monitor/monitor.sh 2>/dev/null; rm -f ~/.claude/net-monitor/monitor.pid
cd /Users/liangchao/Desktop/terminal-plugins
git add net-monitor/statusline.sh
git commit -m "feat(net-monitor): statusline script reads status and auto-starts daemon"
```
Expected: 提交成功

---

### Task 4: 安装到 ~/.claude 并接入 Claude Code

**Files:**
- Create: `/Users/liangchao/Desktop/terminal-plugins/net-monitor/install.sh`
- Modify: `~/.claude/settings.json`（合并 statusLine 字段）

- [ ] **Step 1: 写安装脚本（拷贝脚本到 ~/.claude/net-monitor）**

Create `/Users/liangchao/Desktop/terminal-plugins/net-monitor/install.sh`:
```bash
#!/usr/bin/env bash
# 把 monitor.sh / statusline.sh 安装到 ~/.claude/net-monitor 并赋可执行权限。
set -eu
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.claude/net-monitor"
mkdir -p "$DEST"
cp "$SRC/monitor.sh" "$DEST/monitor.sh"
cp "$SRC/statusline.sh" "$DEST/statusline.sh"
chmod +x "$DEST/monitor.sh" "$DEST/statusline.sh"
echo "installed to $DEST"
echo "下一步：在 ~/.claude/settings.json 配置 statusLine 指向 $DEST/statusline.sh"
```

- [ ] **Step 2: 运行安装脚本**

Run:
```bash
chmod +x /Users/liangchao/Desktop/terminal-plugins/net-monitor/install.sh
/Users/liangchao/Desktop/terminal-plugins/net-monitor/install.sh
```
Expected: `installed to /Users/liangchao/.claude/net-monitor`，且两个脚本已就位。

- [ ] **Step 3: 查看现有 settings.json，决定合并还是新建**

Run:
```bash
cat ~/.claude/settings.json 2>/dev/null || echo "NO_SETTINGS_FILE"
```
Expected: 看到现有内容或 `NO_SETTINGS_FILE`。
> ⚠️ 若已存在 `statusLine` 字段，不要覆盖——记录原值，下一步用 jq 安全合并并向用户确认。

- [ ] **Step 4: 用 jq 安全合并 statusLine 字段**

Run（文件不存在时以空对象起步）：
```bash
SET=~/.claude/settings.json
[[ -f "$SET" ]] || echo '{}' > "$SET"
tmp=$(mktemp)
jq '.statusLine = {"type":"command","command":"~/.claude/net-monitor/statusline.sh"}' "$SET" > "$tmp" && mv "$tmp" "$SET"
cat "$SET"
```
Expected: 输出的 JSON 含
```json
"statusLine": { "type": "command", "command": "~/.claude/net-monitor/statusline.sh" }
```
其余原有字段保持不变。
> 若系统无 `jq`：`brew install jq`，或手动编辑 settings.json 加入该字段。

- [ ] **Step 5: 端到端验证（新开 claude 会话看状态栏）**

操作：新开一个终端运行 `claude`，观察底部状态栏。
Expected:
- 数秒内出现 `⚪ 检测中`，随后变为真实状态（`🟢 <ms>ms` 等）
- 临时在 Clash Verge 里切到一个失效节点 → 几秒后状态栏变 `🔴 代理断`
- 退出 claude 后约 30 秒，`pgrep -f net-monitor/monitor.sh` 应无输出（守护进程自杀）

- [ ] **Step 6: 提交**

```bash
cd /Users/liangchao/Desktop/terminal-plugins
git add net-monitor/install.sh
git commit -m "feat(net-monitor): install script and Claude Code statusLine integration"
```
Expected: 提交成功

---

### Task 5: README 使用说明

**Files:**
- Create: `/Users/liangchao/Desktop/terminal-plugins/net-monitor/README.md`

- [ ] **Step 1: 写 README**

Create `/Users/liangchao/Desktop/terminal-plugins/net-monitor/README.md`:
```markdown
# claude-net-monitor

claude-cli 状态栏实时网络/Clash 代理监听。

## 状态含义
- 🟢 `187ms` — 代理通畅（延迟 ≤ 500ms）
- 🟡 `890ms` — 代理慢（延迟 > 500ms）
- 🔴 `代理断` — 本地网络正常，但代理出境失败
- 🔴 `断网` — 本地网络也不通
- ⚪ `检测中` — 守护进程刚启动，尚无首次结果

## 工作原理
- `monitor.sh`：后台每 5 秒经 curl 探测本地直连（baidu）与代理出境（youtube, HEAD），
  原子写入 `~/.claude/net-monitor/status`；状态栏 30 秒不读取则自动退出。
- `statusline.sh`：Claude Code statusLine 调用，秒回读 status，并按需拉起守护进程。

## 安装
```bash
./install.sh
# 然后确保 ~/.claude/settings.json 含：
# "statusLine": { "type": "command", "command": "~/.claude/net-monitor/statusline.sh" }
```

## 自定义
编辑 `~/.claude/net-monitor/monitor.sh` 顶部常量：
- `INTERVAL` 探测间隔秒数（默认 5）
- `SLOW_MS` 慢阈值毫秒（默认 500）
- `PROXY` 代理地址（默认 http://127.0.0.1:7897）
- `DIRECT_URL` / `PROXY_URL` 探测目标
改完无需重启：守护进程会在下次自杀后由状态栏重新拉起；或手动 `pkill -f net-monitor/monitor.sh`。
```

- [ ] **Step 2: 提交**

```bash
cd /Users/liangchao/Desktop/terminal-plugins
git add net-monitor/README.md
git rm --cached net-monitor/.gitkeep 2>/dev/null || true
git commit -m "docs(net-monitor): usage README"
```
Expected: 提交成功

---

## Self-Review

**Spec coverage：**
- 状态定义（🟢/🟡/🔴 代理断/🔴 断网/⚪）→ Task 1 `decide` + Task 2 初始状态 ✓
- 检测方式（直连 baidu / 代理 youtube HEAD）→ Task 1 `probe_direct`/`probe_proxy` ✓
- 慢阈值 500ms、5 秒间隔 → Task 1 常量 ✓
- 架构三组件（monitor/statusline/settings）→ Task 1-2 / Task 3 / Task 4 ✓
- 自托管生命周期（按需拉起 + heartbeat 自杀）→ Task 2 `main_loop` + Task 3 拉起逻辑 ✓
- 错误处理（原子写、回退、pid 校验、curl 失败不崩）→ Task 1 `write_status`/probe、Task 3 回退 ✓
- 测试方案（代理断/断网/慢/自杀/集成）→ 各 Task 验证步骤 ✓
- 非目标（无趋势图/无 API/无 launchd）→ 计划未引入，符合 ✓

**Placeholder scan：** 无 TBD/TODO，所有代码步骤含完整脚本内容。

**Type/命名一致性：** `DIR`、`STATUS_FILE`、`PID_FILE`、`HEARTBEAT_FILE`、`probe_direct`、
`probe_proxy`、`decide`、`write_status`、`run_once`、`main_loop`、`heartbeat_stale`、`daemon_alive`
在各 Task 间命名一致；statusline.sh 与 monitor.sh 共用同一组路径变量口径。
