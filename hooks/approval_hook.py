#!/usr/bin/env python3
"""Claude Code PreToolUse hook —— 远程权限审批桥接。

流程:
  读 stdin JSON → 本地风险分级(绿/黄/红)
  → 所有等级: POST /approvals 由后端二次分级
  → 后端自动决策则立即返回；需要人工审批时轮询 /status

安全失败: 任何异常(网络/后端故障/解析错误) → deny,绝不放行。
超时兜底: hook 脚本自己 5min 主动返回 deny,早于 Claude Code 默认超时放行。

环境变量:
  SEREIN_BACKEND     Go 后端地址(默认 http://localhost:8080)
  SEREIN_HOOK_TOKEN  hook 认证 token
  SEREIN_HOOK_TIMEOUT  hook 自超时秒数(默认 300)
"""
import sys
import os
import json
import difflib
import time
import threading
import urllib.request
import urllib.error

BACKEND_URL = os.environ.get("SEREIN_BACKEND", "http://localhost:8080").rstrip("/")
HOOK_TOKEN = os.environ.get("SEREIN_HOOK_TOKEN", "")


def _read_timeout() -> int:
    """读取 hook 超时配置；非法或过小值统一回退到安全默认值。"""
    try:
        value = int(os.environ.get("SEREIN_HOOK_TIMEOUT", "300"))
    except (TypeError, ValueError):
        return 300
    return max(1, min(value, 3600))


HOOK_TIMEOUT_SEC = _read_timeout()  # 5min

# Token 清洗：校验合法性，拦截含换行/控制字符的恶意注入
import re as _re
_HOOK_TOKEN_OK = bool(_re.match(r'^[a-zA-Z0-9._\-]+$', HOOK_TOKEN)) if HOOK_TOKEN else False
if HOOK_TOKEN and not _HOOK_TOKEN_OK:
    HOOK_TOKEN = ""  # 清空非法 token，后续请求会因未认证被拒
SEREIN_PROJECT = os.environ.get("SEREIN_PROJECT", "default")  # 项目标识（fallback，优先用 cwd 自动检测）
POLL_INTERVAL_SEC = 1.0
HTTP_TIMEOUT = 8  # 单次 HTTP 请求超时(秒)


def _load_known_projects():
    """加载已知项目路径映射（从 ~/.serein/projects.json 动态加载）。

    serein 命令启动时自动注册项目到该文件，无需手动配置。
    """
    projects = {}
    try:
        home = os.path.expanduser("~")
        pfile = os.path.join(home, ".serein", "projects.json")
        with open(pfile, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict):
            for name, path in data.items():
                if isinstance(path, str):
                    projects[name] = path
    except (FileNotFoundError, json.JSONDecodeError):
        pass
    except Exception:
        pass
    return projects


def detect_project(cwd):
    """从 Claude Code 传入的 cwd 自动推断项目名。

    优先级：
      1. cwd 匹配已知项目路径（含子目录）→ 返回项目名
      2. basename(cwd) 作为项目名
      3. 环境变量 SEREIN_PROJECT（fallback）

    这样无需在每个项目目录下配 .claude/settings.json，
    全局 ~/.claude/settings.json 的 hook 配置自动覆盖所有项目。
    """
    if not cwd:
        return SEREIN_PROJECT

    cwd_norm = cwd.replace("\\", "/").rstrip("/").lower()

    # 匹配已知项目路径
    for name, ppath in _load_known_projects().items():
        norm = ppath.replace("\\", "/").rstrip("/").lower()
        if cwd_norm == norm or cwd_norm.startswith(norm + "/"):
            return name

    # basename fallback
    base = cwd_norm.rsplit("/", 1)[-1] if "/" in cwd_norm else cwd_norm
    if base and base != cwd_norm:
        return base

    return SEREIN_PROJECT


def read_hook_input():
    """读 stdin JSON: {session_id, cwd, tool_name, tool_input:{command}}

    显式用 UTF-8 解码,避免 Windows GBK 环境(sys.stdin.encoding=gbk)
    把 UTF-8 字节误解码成乱码(如 文件检查→鏂囦欢)。
    """
    raw_bytes = sys.stdin.buffer.read()
    if not raw_bytes.strip():
        return {}
    raw = raw_bytes.decode("utf-8")
    return json.loads(raw)


def emit(decision, reason):
    """输出 Claude Code 期望的 JSON 到 stdout,exit 0。

    decision: allow / deny / ask
    """
    out = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": decision,
            "permissionDecisionReason": reason,
        }
    }
    sys.stdout.write(json.dumps(out))
    sys.stdout.flush()
    sys.exit(0)


def http_request(method, path, body=None, token=None):
    """发起 HTTP 请求,返回 (status, json_resp)。失败抛异常。"""
    url = f"{BACKEND_URL}{path}"
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    req.add_header("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    # 绕过 HTTP 代理(Claude Code 在 HTTPS_PROXY 下,走代理会被 Cloudflare WAF 拦截)
    proxy_handler = urllib.request.ProxyHandler({})
    opener = urllib.request.build_opener(proxy_handler)
    with opener.open(req, timeout=HTTP_TIMEOUT) as resp:
        raw = resp.read().decode("utf-8")
        return resp.status, (json.loads(raw) if raw.strip() else {})


def classify_local(tool_name, command):
    """本地风险分级(与后端规则镜像)。返回 (level, reason)。"""
    from risk_classify import classify
    return classify(tool_name, command)


def describe_tool_action(data):
    """从任意工具调用中提取可读的命令描述。

    覆盖所有 Claude Code / CatPaw 工具类型，确保手机端审批界面
    能显示有意义的描述，而不是 "(no command field)"。
    """
    tool_name = data.get("tool_name", "")
    tool_input = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}

    # ── 命令执行类（取 command 字段）──
    if tool_name in ("Bash", "PowerShell", "run_terminal_cmd"):
        return tool_input.get("command", f"(empty {tool_name.lower()})")

    # ── 文件编辑类 ──
    if tool_name == "Edit":
        fp = tool_input.get("file_path", "?")
        old = tool_input.get("old_string", "")
        new = tool_input.get("new_string", "")
        if old and new:
            return 'Edit ' + fp + ': "' + old.strip()[:40] + '" → "' + new.strip()[:40] + '"'
        return 'Edit ' + fp

    if tool_name == "string_replace":
        fp = tool_input.get("file_path", "?")
        old = tool_input.get("old_string", "")
        new = tool_input.get("new_string", "")
        if old and new:
            return 'Replace ' + fp + ': "' + old.strip()[:40] + '" → "' + new.strip()[:40] + '"'
        return 'Replace ' + fp

    if tool_name == "MultiEdit":
        fp = tool_input.get("file_path", "?")
        edits = tool_input.get("edits", [])
        count = len(edits) if isinstance(edits, list) else "?"
        return f"MultiEdit {fp} ({count} edits)"

    if tool_name == "Write":
        fp = tool_input.get("file_path", "?")
        content = tool_input.get("content", "")
        preview = content.strip()[:60].replace("\n", " ")
        return 'Write ' + fp + (": " + preview if preview else "")

    if tool_name == "NotebookEdit":
        return "NotebookEdit " + tool_input.get("notebook_path", "?")

    # ── 文件系统类 ──
    if tool_name == "delete_file":
        return "Delete " + tool_input.get("target_file", "?")

    if tool_name == "file_write":
        return "FileWrite " + tool_input.get("file_name", "?")

    # ── Task 管理 ──
    if tool_name in ("TaskCreate", "TaskUpdate", "TaskList", "TaskGet", "TaskOutput", "TaskStop"):
        subject = tool_input.get("subject", "") or tool_input.get("description", "") or ""
        status = tool_input.get("status", "")
        extra = (": " + subject[:40]) if subject else ""
        extra += (" [" + status + "]" if status else "")
        return tool_name + extra or tool_name

    # ── 只读工具（通常不会触发 hook，但兜底描述）──
    if tool_name == "Read" or tool_name == "read_file":
        return "Read " + tool_input.get("file_path", tool_input.get("target_file", "?"))
    if tool_name == "Glob" or tool_name == "glob_file_search":
        return "Glob " + tool_input.get("pattern", tool_input.get("glob_pattern", "?"))
    if tool_name == "Grep":
        return "Grep " + tool_input.get("pattern", "?")
    if tool_name == "LS" or tool_name == "list_dir":
        return "LS " + tool_input.get("target_directory", tool_input.get("path", "?"))
    if tool_name == "WebFetch" or tool_name == "web_fetch":
        urls = tool_input.get("urls", [])
        url = urls[0] if isinstance(urls, list) and urls else tool_input.get("url", "?")
        return f"WebFetch {str(url)[:80]}"
    if tool_name == "WebSearch":
        return "WebSearch " + tool_input.get("query", "?")[:80]
    if tool_name == "codebase_search":
        return "Search " + tool_input.get("query", "?")[:60]
    if tool_name == "TodoWrite" or tool_name == "todo_write":
        return "TodoWrite"
    if tool_name == "fetch_rules":
        rules = tool_input.get("rule_names", [])
        return "FetchRules " + (", ".join(rules) if rules else "?")
    if tool_name == "read_lints":
        return "ReadLints " + str(tool_input.get("paths", "?"))
    if tool_name in ("AskQuestion", "SpecAskQuestion"):
        return tool_name
    if tool_name == "Skill":
        return "Skill " + tool_input.get("skill", "?") or tool_name
    if tool_name == "Agent":
        return "Agent " + tool_input.get("description", "?")[:60]

    # ── 兜底：尝试常见字段 ──
    cmd = tool_input.get("command", "")
    if cmd:
        return cmd
    fp = tool_input.get("file_path", tool_input.get("target_file", ""))
    if fp:
        return f"{tool_name} {fp}"
    return tool_name + " (no command field)"


def generate_diff(data: dict) -> str:
    """对 Write/Edit/MultiEdit/string_replace 工具调用生成 unified diff，截断至 5000 字符。"""
    tool_name = data.get("tool_name", "")
    tool_input = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
    if tool_name == "Write":
        fp = tool_input.get("file_path", "")
        new_content = tool_input.get("content", "")
        try:
            with open(fp, "r", encoding="utf-8") as f:
                old_lines = f.read().splitlines(keepends=True)
        except (FileNotFoundError, OSError):
            old_lines = []
        new_lines = new_content.splitlines(keepends=True)
        diff = "".join(difflib.unified_diff(old_lines, new_lines,
                      fromfile="a/" + fp, tofile="b/" + fp))
        if len(diff) > 5000:
            diff = diff[:5000] + "\n... (diff truncated)"
        return diff
    if tool_name in ("Edit", "string_replace"):
        fp = tool_input.get("file_path", "")
        old_str = tool_input.get("old_string", "")
        new_str = tool_input.get("new_string", "")
        return f"--- a/{fp}\n+++ b/{fp}\n@@ -1,1 +1,1 @@\n-{old_str[:300]}\n+{new_str[:300]}"
    if tool_name == "MultiEdit":
        fp = tool_input.get("file_path", "")
        edits = tool_input.get("edits", [])
        if not isinstance(edits, list):
            return ""
        lines = [f"--- a/{fp}", f"+++ b/{fp}"]
        for i, edit in enumerate(edits):
            if not isinstance(edit, dict):
                continue
            old_s = edit.get("old_string", "")
            new_s = edit.get("new_string", "")
            lines.append(f"@@ edit #{i + 1} @@")
            lines.append(f"-{old_s[:200]}")
            lines.append(f"+{new_s[:200]}")
        result = "\n".join(lines)
        if len(result) > 5000:
            result = result[:5000] + "\n... (diff truncated)"
        return result
    return ""


def request_approval(data, level, reason):
    """POST /approvals 创建审批,返回 (approval_id, decision, reason)。

    后端可能 auto-approve(会话记忆/白名单命中)→ decision 为 allow/deny,
    此时无需轮询,直接返回。否则 decision 为空,需 poll 等待客户端审批。
    """
    tool_input = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
    diff = generate_diff(data)
    body = {
        "session_id": data.get("session_id", ""),
        "tool_name": data.get("tool_name", ""),
        "command": describe_tool_action(data),
        "cwd": data.get("cwd", ""),
        "risk_level": level,
        "rule_reason": reason,
        "project": SEREIN_PROJECT,
    }
    if diff:
        body["diff"] = diff
    _, resp = http_request("POST", "/approvals", body=body, token=HOOK_TOKEN)
    return resp.get("id", ""), resp.get("decision", ""), resp.get("reason", "")


def poll_status(approval_id, deadline):
    """轮询 GET /approvals/{id}/status,直到拿到结果或超时。返回 (decision, reason)。

    通过 stderr 输出心跳进度，防止用户看到命令卡死却不知道发生了什么。
    """
    path = f"/approvals/{approval_id}/status"
    last_heartbeat = 0
    heartbeat_interval = 10  # 每 10 秒打一次心跳
    errors = 0
    MAX_CONSECUTIVE_ERRORS = 10

    while time.time() < deadline:
        try:
            _, resp = http_request("GET", path, token=HOOK_TOKEN)
            errors = 0  # 成功则重置错误计数
            decision = resp.get("decision")
            if decision in ("allow", "deny"):
                elapsed = int(time.time() - (deadline - HOOK_TIMEOUT_SEC))
                if elapsed > 2:
                    print(f"[serein] 审批完成: {decision} (等待了 {elapsed}s)", file=sys.stderr)
                return decision, resp.get("reason", "")
            # decision 为 pending/None,继续轮询
        except urllib.error.HTTPError as e:
            errors += 1
            if e.code == 404:
                return "deny", f"approval not found: {approval_id}"
            print(f"[serein] HTTP {e.code} 轮询 /status (第{errors}次)", file=sys.stderr)
            if errors >= MAX_CONSECUTIVE_ERRORS:
                return "deny", f"too many HTTP errors ({errors} consecutive 5xx/errors)"
        except urllib.error.URLError as e:
            errors += 1
            print(f"[serein] 网络错误轮询 /status: {e.reason} (第{errors}次)", file=sys.stderr)
            if errors >= MAX_CONSECUTIVE_ERRORS:
                return "deny", f"too many network errors ({errors} consecutive)"
        except Exception as e:
            errors += 1
            print(f"[serein] 轮询异常: {type(e).__name__}: {e} (第{errors}次)", file=sys.stderr)
            if errors >= MAX_CONSECUTIVE_ERRORS:
                return "deny", f"too many errors ({errors} consecutive)"

        # 心跳: 告诉用户 hook 还在等
        now = time.time()
        if now - last_heartbeat >= heartbeat_interval:
            remaining = int(deadline - now)
            print(f"[serein] 等待手机审批中... id={approval_id[:8]} 剩余{remaining}s", file=sys.stderr)
            last_heartbeat = now

        time.sleep(POLL_INTERVAL_SEC)

    return "deny", f"approval timeout ({HOOK_TIMEOUT_SEC}s, hook-side)"


def main():
    # 1. 读 stdin
    try:
        data = read_hook_input()
    except Exception as e:
        emit("deny", f"hook: failed to read stdin: {e}")
        return

    # 空输入拒绝：stdin 为空时不应继续执行（可能是 Claude Code 调用异常）
    if not data:
        emit("deny", "hook: empty stdin input")
        return

    # 从 cwd 自动检测项目名（覆盖环境变量的静态值）
    # Claude Code 每次 hook 调用都传入当前 cwd，无需手动配 SEREIN_PROJECT
    global SEREIN_PROJECT
    SEREIN_PROJECT = detect_project(data.get("cwd", ""))

    # 非 serein 已知项目 → 直接放行，不拦截。
    # 全局 hooks 会拦截所有目录的工具调用，但只有绑定过的项目
    # 才有手机端审批客户端。未绑定项目拦截后无人审批，导致死循环。
    if SEREIN_PROJECT not in _load_known_projects():
        emit("allow", f"unknown serein project: {SEREIN_PROJECT}")
        return

    tool_name = data.get("tool_name", "")
    tool_input = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
    command = tool_input.get("command", "")

    # 2. 本地风险分级
    try:
        level, reason = classify_local(tool_name, command)
    except Exception as e:
        emit("deny", f"hook: classify error: {e}")
        return

    # 3. 绿/黄: 后端二次分级后再决定是否放行。
    # 后端可能有动态黑名单/热更新规则，本地结果不能覆盖服务端结果。
    if level in ("green", "yellow"):
        try:
            approval_id, decision, dec_reason = request_approval(data, level, reason)
            if decision in ("allow", "deny"):
                emit(decision, dec_reason or f"backend decision: {decision}")
                return
            if not approval_id:
                emit("deny", "hook: backend returned no approval id")
                return
            decision, dec_reason = poll_status(
                approval_id, time.time() + HOOK_TIMEOUT_SEC
            )
            emit(decision, dec_reason or f"backend decision: {decision}")
        except (urllib.error.URLError, urllib.error.HTTPError) as e:
            emit("deny", f"hook: backend unavailable: {e}")
        except Exception as e:
            emit("deny", f"hook: approval infra error: {e}")
        return

    # 4. 红色: 远程审批
    deadline = time.time() + HOOK_TIMEOUT_SEC
    try:
        approval_id, decision, dec_reason = request_approval(data, level, reason)
        if not approval_id:
            emit("deny", "hook: backend returned no approval id")
            return
        # 后端 auto-approve(会话记忆/白名单命中)→ 秒回,无需轮询
        if decision in ("allow", "deny"):
            emit(decision, dec_reason or "auto-approved by backend (session memo/whitelist)")
            return
        # 仍 pending → 轮询等待客户端审批
        decision, dec_reason = poll_status(approval_id, deadline)
        emit(decision, dec_reason)
    except (urllib.error.URLError, urllib.error.HTTPError) as e:
        # 后端不可达时必须拒绝，避免审批网关故障变成放行后门。
        emit("deny", f"hook: backend unreachable: {e}")
    except Exception as e:
        emit("deny", f"hook: approval infra error: {e}")
if __name__ == "__main__":
    main()
