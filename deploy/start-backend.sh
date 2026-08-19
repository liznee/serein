#!/usr/bin/env bash
# 启动 serein 后端(指向本地 ntfy)
# 用法: bash deploy/start-backend.sh
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../backend"
export PATH="$HOME/go-sdk/bin:$PATH"

# 不使用可预测的默认凭证。即使是本地开发，也必须由启动者显式提供。
: "${SEREIN_HOOK_TOKEN:?SEREIN_HOOK_TOKEN is required; generate one with: openssl rand -hex 24}"
: "${SEREIN_PAIR_CODE:?SEREIN_PAIR_CODE is required; generate one with: openssl rand -hex 6}"

# 全局 client token 是历史兼容后门，生产环境必须保持为空。
export SEREIN_CLIENT_TOKEN="${SEREIN_CLIENT_TOKEN:-}"
export SEREIN_ENV="${SEREIN_ENV:-development}"
export SEREIN_DB="${SEREIN_DB:-serein.db}"
export SEREIN_NTFY_URL="${SEREIN_NTFY_URL:-http://127.0.0.1:8090}"
export SEREIN_NTFY_TOPIC="${SEREIN_NTFY_TOPIC:-serein-approvals}"

echo "starting serein backend on :8080 (ntfy=$SEREIN_NTFY_URL/$SEREIN_NTFY_TOPIC)"
exec go run ./cmd/server
