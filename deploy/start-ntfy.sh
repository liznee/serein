#!/usr/bin/env bash
# 启动本地 ntfy 服务(Windows 二进制,纯 pub/sub 总线)
# 用法: bash deploy/start-ntfy.sh
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/ntfy"
exec ./ntfy.exe serve --config server.yml
