#!/usr/bin/env bash
# Claude Code 网络监听守护进程：循环探测本地直连与 Clash 代理出境，
# 把状态原子写入 status 文件。状态栏 30 秒不读取则自杀。
# 可选：代理持续变差时，自动在日本节点间切到更快的（见 clash.sh）。
set -u

# ---- 监听常量 ----
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

# ---- 自动切换常量 ----
AUTO_SWITCH=1            # 1 开启自动切换，0 仅监听
SWITCH_THRESHOLD_MS=1500 # 代理延迟超过此值视为「坏」
BAD_STREAK=3            # 连续坏多少次才切（防抖）
COOLDOWN=60            # 切换后冷却秒数（防横跳）

mkdir -p "$DIR"

# 载入 Clash 操作模块（与本脚本同目录）；缺失则自动关闭切换
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/clash.sh" ]]; then
  # shellcheck source=clash.sh
  source "$SCRIPT_DIR/clash.sh"
else
  AUTO_SWITCH=0
fi

# 切换决策用的运行期状态
BAD_COUNT=0
LAST_SWITCH_EPOCH=0
SWITCH_FLAG=""
LAST_DIRECT=""
LAST_PROXY=""

# 直连探测：成功输出 "ok <ms>"，失败输出 "fail"
probe_direct() {
  local out code
  out=$(curl -s -o /dev/null --max-time "$TIMEOUT" \
    -w '%{http_code} %{time_total}' "$DIRECT_URL" 2>/dev/null) || { echo "fail"; return; }
  code=${out%% *}
  if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then  # 2xx/3xx 视为通
    echo "ok ${out##* }"
  else
    echo "fail"
  fi
}

# 代理探测：HEAD 请求，成功输出 "ok <ms>"，失败输出 "fail"
# 注：--proxy 的 http:// 指代理本身的协议（Clash 混合端口），与目标 URL 的 https 无关
probe_proxy() {
  local out code
  out=$(curl -sI -o /dev/null --max-time "$TIMEOUT" --proxy "$PROXY" \
    -w '%{http_code} %{time_total}' "$PROXY_URL" 2>/dev/null) || { echo "fail"; return; }
  code=${out%% *}
  if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then  # 2xx/3xx 视为通
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

# 节点名简称：去掉地区前缀（首个 - 之前）与 -流量倍率 后缀。日本-OS-1-流量倍率:0.6 -> OS-1
short_name() {
  local n="$1"; n="${n#*-}"; n="${n%%-流量倍率*}"; echo "$n"
}

# 切换日志（写到 stderr，nohup 会汇入 monitor.log）
log_switch() {
  echo "[$(date '+%H:%M:%S')] switch: $1" >&2
}

# 跑一次完整探测并写状态（结果暂存到全局，供切换决策使用）
run_once() {
  local d p line
  d=$(probe_direct)
  p=$(probe_proxy)
  LAST_DIRECT="$d"
  LAST_PROXY="$p"
  line=$(decide "$d" "$p")
  if [[ -n "$SWITCH_FLAG" ]]; then
    line="$line ⇄$SWITCH_FLAG"
    SWITCH_FLAG=""
  fi
  write_status "$line"
}

# 执行一次切换尝试（仅在 maybe_switch 判定该切时调用）
do_switch() {
  local group cur best
  group=$(clash_target_group)
  [[ -n "$group" ]] || { log_switch "跳过：无法确定目标组"; return; }
  cur=$(clash_current "$group")
  best=$(clash_pick_best)
  if [[ -z "$best" ]]; then
    log_switch "跳过：无健康日本节点（保持 ${cur:-?} 不动）"
    LAST_SWITCH_EPOCH=$(date +%s)   # 进冷却，避免每周期重测一轮延迟
    return
  fi
  if [[ "$best" == "$cur" ]]; then
    log_switch "已是最优日本节点 ${cur}，不切"
    LAST_SWITCH_EPOCH=$(date +%s)
    return
  fi
  if clash_switch "$group" "$best"; then
    LAST_SWITCH_EPOCH=$(date +%s)
    SWITCH_FLAG=$(short_name "$best")
    log_switch "已切换 $cur -> $best"
  else
    log_switch "切换失败 $cur -> $best"
  fi
}

# 每周期评估是否该切（基于本周期探测结果）
maybe_switch() {
  [[ "$AUTO_SWITCH" == "1" ]] || return
  local bad=0
  if [[ "$LAST_PROXY" == ok* ]]; then
    local ms; ms=$(to_ms "${LAST_PROXY##* }")
    (( ms > SWITCH_THRESHOLD_MS )) && bad=1
  elif [[ "$LAST_DIRECT" == ok* ]]; then
    bad=1                 # 代理断但本地通 → 可切
  else
    BAD_COUNT=0; return   # 本地也断 → 切换无意义
  fi

  if (( bad == 0 )); then BAD_COUNT=0; return; fi

  BAD_COUNT=$(( BAD_COUNT + 1 ))
  (( BAD_COUNT < BAD_STREAK )) && return

  local now; now=$(date +%s)
  (( now - LAST_SWITCH_EPOCH < COOLDOWN )) && return

  do_switch
  BAD_COUNT=0
}

# 允许被 source 时只载入函数，不执行主流程（便于测试）
if [[ "${1:-}" == "--once" ]]; then
  run_once
  cat "$STATUS_FILE"
fi

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
  [[ -f "$STATUS_FILE" ]] || write_status "⚪ 检测中"

  trap 'rm -f "$PID_FILE"; exit 0' INT TERM
  while true; do
    if heartbeat_stale; then
      rm -f "$PID_FILE"
      exit 0
    fi
    run_once
    maybe_switch
    sleep "$INTERVAL"
  done
}

# 仅在无参数（非 --once、非被 source）时进入守护循环
if [[ "${1:-}" != "--once" ]] && [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main_loop
fi
