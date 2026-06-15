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
