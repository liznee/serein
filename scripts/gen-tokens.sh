#!/usr/bin/env bash
# 生成 HOOK_TOKEN 和配对码。在部署目录运行,输出到 .env。
set -euo pipefail

HOOK_TOKEN=$(openssl rand -hex 24 2>/dev/null || python -c "import secrets; print(secrets.token_hex(24))")
PAIR_CODE=$(openssl rand -hex 6 2>/dev/null || python -c "import secrets; print(secrets.token_hex(6))")
NTFY_TOPIC="serein-$(openssl rand -hex 8 2>/dev/null || python -c "import secrets; print(secrets.token_hex(8))")"

cat <<EOF
生成成功。将以下内容写入 deploy/.env:

HOOK_TOKEN=${HOOK_TOKEN}
PAIR_CODE=${PAIR_CODE}
NTFY_TOPIC=${NTFY_TOPIC}
APPROVAL_TIMEOUT=300

并在启动 Claude Code 的 shell 中导出(供 hook 脚本读取):
  export SEREIN_BACKEND=http://localhost:8080
  export SEREIN_HOOK_TOKEN=${HOOK_TOKEN}

手机首次配对时使用:
  ${PAIR_CODE}
EOF
