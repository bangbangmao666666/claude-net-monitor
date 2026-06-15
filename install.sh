#!/usr/bin/env bash
# 把监听与切换脚本安装到 ~/.claude/net-monitor 并赋可执行权限。
set -eu
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.claude/net-monitor"
mkdir -p "$DEST"
cp "$SRC/monitor.sh" "$DEST/monitor.sh"
cp "$SRC/clash.sh" "$DEST/clash.sh"
cp "$SRC/statusline.sh" "$DEST/statusline.sh"
cp "$SRC/statusline-combined.sh" "$DEST/statusline-combined.sh"
chmod +x "$DEST/monitor.sh" "$DEST/clash.sh" "$DEST/statusline.sh" "$DEST/statusline-combined.sh"
echo "installed to $DEST"
echo "下一步：在 ~/.claude/settings.json 配置 statusLine 指向 $DEST/statusline-combined.sh"
