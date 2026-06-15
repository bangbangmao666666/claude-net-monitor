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
