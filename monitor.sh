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
