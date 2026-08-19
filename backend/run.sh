#!/bin/bash
# serein server wrapper — 自动重启循环 + 环境变量自动加载
# 用法: ./run.sh   (无需手动 source，脚本自己加载 env)
# 当 /admin/deploy 触发重启时，新进程自动接管
#
# env 查找顺序（第一个存在的生效）:
#   1. $SEREIN_ENV_FILE (显式指定)
#   2. /opt/serein/serein.env (生产服务器默认)
#   3. ./serein.env (与脚本同目录)
# 关键: env 在循环内每次重启都重新加载，避免崩溃重启后变量丢失

cd "$(dirname "$0")"

load_env() {
    local candidates=(
        "${SEREIN_ENV_FILE:-}"
        "/opt/serein/serein.env"
        "./serein.env"
    )
    local envfile
    for envfile in "${candidates[@]}"; do
        if [ -n "$envfile" ] && [ -f "$envfile" ]; then
            echo "[run.sh] loading env from $envfile"
            set -a
            # shellcheck disable=SC1090
            . "$envfile"
            set +a
            return 0
        fi
    done
    echo "[run.sh] WARNING: no env file found, using inherited environment only"
    return 1
}

BIN="${SEREIN_BIN:-./serein-server}"

while true; do
    load_env
    echo "[run.sh] starting $BIN ..."
    "$BIN"
    code=$?
    echo "[run.sh] $BIN exited with code $code, restarting in 2s..."
    sleep 2
done
