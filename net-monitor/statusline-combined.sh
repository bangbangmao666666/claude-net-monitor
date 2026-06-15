#!/usr/bin/env bash
# 合并状态栏：把网络监听与 cc-costline 拼成一行。
# Claude Code 经 stdin 传入 JSON，只能消费一次，故先捕获再分发给两个子命令。
set -u

DIR="$HOME/.claude/net-monitor"
NET_SCRIPT="$DIR/statusline.sh"

input=$(cat)

# 网络监听（左）
net=$(printf '%s' "$input" | "$NET_SCRIPT" 2>/dev/null)

# cc-costline（右），不可用时留空
cost=""
if command -v cc-costline >/dev/null 2>&1; then
  cost=$(printf '%s' "$input" | cc-costline render 2>/dev/null | head -n1)
fi

if [[ -n "$net" && -n "$cost" ]]; then
  printf '%s │ %s\n' "$net" "$cost"
elif [[ -n "$net" ]]; then
  printf '%s\n' "$net"
else
  printf '%s\n' "$cost"
fi
