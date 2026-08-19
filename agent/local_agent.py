#!/usr/bin/env python3
"""serein 本地 Claude Code 控制 Agent（纯 Watchdog 模式）

watchdog 进程：HTTP 长轮询取远程命令 + WS 实时通道。
chat 命令由 serein.mjs（Relay 模式：node-pty + WS 桥接）处理，
watchdog 不处理任何 chat 命令，全部跳过。

开机由 agent_watchdog.vbs 守护，死掉自动重拉。
"""
import os, sys, json, time, glob, re, threading
from urllib.error import HTTPError, URLError
from collections import deque

from common import (
    HOOK_TOKEN, SERVER, USER_HOME, PROJECT_PATHS, AGENT_DIR,
    _VALID_TOKEN_RE, http_req, require_server,
    _safe_stderr,
)
from sysinfo import check_alerts, collect_sysinfo
from agent_proc import (
running_projects, _running_lock, AGENT_PID_FILE,
pid_alive,
scan_running, do_status,
do_start, do_stop, do_kill_all,
collect_project_git_remotes, collect_codex_desktop_projects, collect_collaboration_sessions,
_is_relay_active, is_relay_starting,
do_file_write,
RELAY_QUIT_FILE, RELAY_PROJECT_FILE, RELAY_SCOPE_FILE, RELAY_RUNTIME_FILE,
)
from agent_daemon import start_daemon
from agent_exec import do_exec
from remote_host_manager import RemoteHostManager

# The desktop watchdog and manual recovery commands can overlap briefly.
# Two owners poll the same remote session and can tear down each other's stream.
AGENT_INSTANCE_LOCK_FILE = os.path.join(AGENT_DIR, ".agent.instance.pid")


def _read_pid_file(path: str) -> int:
    try:
        with open(path, "r", encoding="ascii") as handle:
            return int(handle.read().strip())
    except (OSError, ValueError):
        return 0


def acquire_agent_instance_lock() -> int | None:
    """Atomically claim the local-agent role, removing only stale locks."""
    for _ in range(2):
        try:
            descriptor = os.open(
                AGENT_INSTANCE_LOCK_FILE,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
            )
            os.write(descriptor, str(os.getpid()).encode("ascii"))
            return descriptor
        except FileExistsError:
            owner_pid = _read_pid_file(AGENT_INSTANCE_LOCK_FILE)
            if owner_pid > 0 and pid_alive(owner_pid):
                _safe_stderr(f"[Agent] another local_agent is already active (PID={owner_pid}); exiting")
                return None
            try:
                os.remove(AGENT_INSTANCE_LOCK_FILE)
            except OSError:
                return None
    return None


def release_agent_instance_lock(descriptor: int | None) -> None:
    if descriptor is not None:
        try:
            os.close(descriptor)
        except OSError:
            pass
    if _read_pid_file(AGENT_INSTANCE_LOCK_FILE) == os.getpid():
        try:
            os.remove(AGENT_INSTANCE_LOCK_FILE)
        except OSError:
            pass


def remove_own_agent_pid_file() -> None:
    if _read_pid_file(AGENT_PID_FILE) == os.getpid():
        try:
            os.remove(AGENT_PID_FILE)
        except OSError:
            pass

# ── 会话总结函数（保留在本地，依赖 USER_HOME）──

def find_latest_session_summary(proj_path: str) -> str | None:
    """在 ~/.claude/session-data/ 找该项目最新的 /save-session 摘要文件。"""
    sd_dir = os.path.join(USER_HOME, ".claude", "session-data")
    if not os.path.isdir(sd_dir):
        return None
    project_name = os.path.basename(proj_path).lower()
    candidates: list[tuple[str, str]] = []
    for f in glob.glob(os.path.join(sd_dir, "*-session.tmp")):
        try:
            with open(f, "r", encoding="utf-8") as fh:
                head = fh.read(4096)
        except Exception:
            continue
        proj_line = ""
        ts = "00:00:00"
        for line in head.splitlines():
            if line.startswith("**Project:**"):
                proj_line = line.lower()
            elif line.startswith("**Last Updated:**"):
                m = re.search(r"\d{2}:\d{2}:\d{2}", line)
                ts = m.group(0) if m else "00:00:00"
        if project_name not in proj_line:
            continue
        fname = os.path.basename(f)
        dm = re.match(r"(\d{4}-\d{2}-\d{2})", fname)
        fdate = dm.group(1).replace("-", "") if dm else "00000000"
        candidates.append((fdate + ts.replace(":", ""), f))
    if not candidates:
        return None
    candidates.sort(key=lambda x: x[0], reverse=True)
    return candidates[0][1]


def parse_session_summary(path: str) -> str:
    """从 /save-session 摘要文件提取关键段落。"""
    try:
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()
    except Exception:
        return ""
    parts = re.split(r"(?=^## )", content, flags=re.MULTILINE)
    wanted = ["What We Are Building", "Current State of Files", "Blockers & Open Questions", "Exact Next Step"]
    out: list[str] = []
    for p in parts:
        for w in wanted:
            if p.startswith("## " + w):
                seg = p.split("\n---\n")[0]
                out.append(seg.strip())
    if not out:
        return content[:1500]
    return "\n\n".join(out)


def _fallback_jsonl_summary(proj_path: str) -> str:
    """无 save-session 摘要文件时，从 jsonl 取最近 assistant 关键回复精简输出。"""
    sessions_dir = os.path.join(USER_HOME, ".claude", "projects")
    if not os.path.isdir(sessions_dir):
        return "(no session data directory found)"
    project_name = os.path.basename(proj_path).lower()
    for entry in os.listdir(sessions_dir):
        if entry.lower().endswith("-" + project_name):
            sdir = os.path.join(sessions_dir, entry)
            if os.path.isdir(sdir):
                files = glob.glob(os.path.join(sdir, "*.jsonl"))
                if files:
                    files.sort(key=os.path.getmtime, reverse=True)
                    result: list[str] = []
                    with open(files[0], "r", encoding="utf-8") as f:
                        recent = list(deque(f, maxlen=80))
                    for line in recent:
                        try:
                            msg = json.loads(line)
                            if msg.get("role") != "assistant":
                                continue
                            content = msg.get("content", "")
                            if isinstance(content, list):
                                txt = ""
                                for block in content:
                                    if isinstance(block, dict) and block.get("type") == "text":
                                        txt = block.get("text", "")
                                        break
                                content = txt
                            if isinstance(content, str) and len(content) > 0:
                                short = content[:200].replace("\n", " ")
                                result.append("• " + short)
                        except Exception as _jsonl_e:
                            _safe_stderr(f"[Agent] JSONL 解析跳过: {type(_jsonl_e).__name__}: {_jsonl_e}")
                    seen: set[str] = set()
                    dedup: list[str] = []
                    for r in result:
                        if r not in seen:
                            seen.add(r)
                            dedup.append(r)
                    if dedup:
                        return "📖 最近会话要点:\n" + "\n".join(dedup[-10:])
                    return "(empty session)"
    return "(no session found)"


def get_session_resume(proj_path: str) -> str:
    """返回上次会话总结：优先读 save-session 摘要文件，回退到 jsonl 精简要点。"""
    sp = find_latest_session_summary(proj_path)
    if sp:
        summary = parse_session_summary(sp)
        if summary:
            return "📖 上次会话总结（" + os.path.basename(sp) + "）:\n" + summary
    return _fallback_jsonl_summary(proj_path)


def do_resume(project: str) -> dict:
    """加载指定项目上次会话的总结（/resume 命令）。"""
    proj_path = PROJECT_PATHS.get(project)
    if not proj_path:
        return {"error": f"unknown project: {project}"}
    return {"stdout": get_session_resume(proj_path), "stderr": "", "returncode": 0}


# ── 命令执行与回传 ──

def _report_retry(method: str, path: str, body: dict, max_retries: int = 3) -> bool:
    """重试版 http_req，用于 chat skip report 等需要确保送达的场景。

    第一次同步尝试确保进程退出前至少发送一次 report，
    后续重试在后台 daemon 线程执行避免阻塞主循环。
    """
    # 第一次同步尝试（在 execute_cmd 返回前执行，防止进程退出时 report 丢失）
    try:
        http_req(method, path, body, timeout=10)
        return True
    except (URLError, OSError, TimeoutError, json.JSONDecodeError):
        pass

    # 第一次失败后启动后台线程继续重试剩余 max_retries-1 次
    def _do_retry(retries: int):
        for attempt in range(1, retries):
            time.sleep(1 * attempt)
            try:
                http_req(method, path, body, timeout=10)
                return
            except Exception:
                pass

    thread = threading.Thread(target=_do_retry, args=(max_retries,), daemon=True)
    thread.start()
    return True


def execute_cmd(cmd: dict) -> dict:
    """分发并执行远程命令，返回执行结果。

    支持的 action：
    - "chat"     → 跳过，由 serein.mjs Relay 模式处理
    - "status"   → 查询本地进程状态
    - "start"    → 激活项目
    - "stop"     → 停止项目进程
    - "exec"     → 执行 shell 命令
    - "resume"   → 加载上次会话总结
    - "kill-all" → 紧急刹车杀所有进程

    所有 action 执行后自动通过 http_req POST /agent/report 回传结果。
    """
    action = cmd.get("action", "")
    project = cmd.get("project", "")
    cmd_id = cmd.get("cmd_id", "")

    if action == "chat":
        # chat 由 serein.mjs Relay 模式（node-pty + WS 桥接）处理
        # 必须检查指定项目的 relay 是否活跃，而非任意 relay
        with _running_lock:
            project_running = project in running_projects
        if _is_relay_active() and project_running:
            # relay 通过 WS cmd_step 实时推送手机端，但仍需上报标记 cmd_id 完成，
            # 防止僵尸条目残留在后端 commands map 中。
            _report_retry("POST", "/agent/report",
                          {"cmd_id": cmd_id, "success": True, "output": {"status": "skipped, handled by relay"}})
            return {"ok": True, "status": "skipped, handled by relay"}
        # relay 未运行或不在该项目：报告不可用
        msg = f"relay not active for project: {project}"
        _report_retry("POST", "/agent/report",
                      {"cmd_id": cmd_id, "success": False, "output": {"error": msg}})
        return {"error": msg}
    elif action == "status":
        result = do_status()
        # 手机主动下拉时请求现场采样；普通 heartbeat 仍按原节奏静默采样。
        if cmd.get("command", "") == "sysinfo":
            result["sysinfo"] = collect_sysinfo()
    elif action == "start":
        agent_type = cmd.get("agent_type", "")
        runtime_mode = cmd.get("runtime_mode", "")
        if not runtime_mode and cmd.get("command", "") in ("cli", "desktop"):
            runtime_mode = cmd["command"]
        result = do_start(
            project,
            agent_type,
            cmd.get("work_scope", ""),
            cmd.get("agent_session_id", ""),
            cmd.get("session_id", ""),
            cmd.get("agent_session_mode", ""),
            runtime_mode or "cli",
        )
    elif action == "stop":
        result = do_stop(project)
    elif action == "exec":
        command = cmd.get("command", "")
        result = do_exec(project, command)
    elif action == "resume":
        result = do_resume(project)
    elif action == "file_write":
        file_name = cmd.get("file_name", "")
        file_data = cmd.get("file_data", "")
        result = do_file_write(project, file_name, file_data)
    elif action == "kill-all":
        result = do_kill_all()
    else:
        result = {"error": f"unknown action: {action}"}

    success = "error" not in result
    try:
        http_req("POST", "/agent/report", {"cmd_id": cmd_id, "success": success, "output": result})
    except Exception as e:
        _safe_stderr(f"[Agent] report failed: {e}")
    return result


# ── WS 连接与消息处理 ──

def _report_cached_runtime_status() -> None:
    """启停后立即推送轻量状态，避免等待下一次 20 秒 heartbeat。

    这里仅读取已经更新过的内存状态，不再执行进程扫描，因此不会拖慢 stop。
    """
    desktop_projects = collect_codex_desktop_projects()
    with _running_lock:
        snapshot_running = list(running_projects.keys())
        snapshot_details: dict[str, dict] = {}
        for name, detail in running_projects.items():
            safe = dict(detail)
            safe.pop("cmd_line", None)
            snapshot_details[name] = safe
    for project, capability in desktop_projects.items():
        detail = snapshot_details.setdefault(project, {})
        detail["desktop_available"] = bool(capability.get("available"))
        detail["desktop_thread_count"] = int(capability.get("thread_count") or 0)
    output = {
        "_heartbeat": True,
        "running": snapshot_running,
        "details": snapshot_details,
        "projects": dict(PROJECT_PATHS),
        "git_remotes": collect_project_git_remotes(),
        "desktop_projects": desktop_projects,
        "collaboration_sessions": collect_collaboration_sessions(),
    }
    try:
        http_req("POST", "/agent/report", {
            "cmd_id": "", "success": True, "output": output,
        })
    except Exception as e:
        _safe_stderr(f"[Agent] immediate status report failed: {e}")

def _ws_connect() -> tuple:
    """建立 WS 连接到后端，返回 (ws, session_id)。
    连接后自动 join 默认 session。
    """
    backend_url = require_server()
    if backend_url.startswith("https://"):
        ws_url = backend_url.replace("https://", "wss://")
    elif backend_url.startswith("http://"):
        # HTTP 模式：WS 明文传输 token 有安全风险，但直连 IP（非域名）时
        # 不经过 DNSPod/ISP 拦截，且 agent→服务器是点对点直连，允许 WS。
        # 域名 HTTP（被 DNSPod 拦截）不允许 WS。
        ws_url = backend_url.replace("http://", "ws://")
        _safe_stderr(f"[Agent WS] HTTP 模式 WS（直连），token 明文传输风险已知")
    else:
        _safe_stderr(f"[Agent WS] 错误：后端地址缺少协议前缀（当前: {backend_url[:30]}），应使用 http:// 或 https://")
        return None, ""
    # 防御性校验：仅当 URL 末尾不以 /ws 结尾时才追加，防止重复追加
    if not ws_url.endswith('/ws'):
        ws_url += '/ws'
    try:
        import ssl as _ssl
        import websocket as _ws
        # 清理代理环境变量，防 Clash TUN 模式/VPN 拦截 WebSocket 连接
        _saved_proxy: dict[str, str] = {}
        for _pk in ("http_proxy", "https_proxy", "all_proxy",
                     "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"):
            try:
                _pv = os.environ.pop(_pk, None)
                if _pv is not None:
                    _saved_proxy[_pk] = _pv
            except KeyError:
                pass
        # 将服务器域名加入 no_proxy，防 TUN 模式劫持
        _no_proxy_hosts = os.environ.get("SEREIN_NO_PROXY", "")
        os.environ["no_proxy"] = _no_proxy_hosts
        os.environ["NO_PROXY"] = _no_proxy_hosts
        try:
            if ws_url.startswith("wss://"):
                ssl_ctx = _ssl.create_default_context()
                ssl_ctx.check_hostname = True
                ssl_ctx.verify_mode = _ssl.CERT_REQUIRED
                ws = _ws.create_connection(ws_url, timeout=10, sslopt={"context": ssl_ctx})
            else:
                ws = _ws.create_connection(ws_url, timeout=10)
        finally:
            os.environ.update(_saved_proxy)
        _prefix = "WSS" if ws_url.startswith("wss://") else "WS"
        _safe_stderr(f"[Agent WS] connected ({_prefix}) to {ws_url}")
        join_msg = json.dumps({
            "type": "join",
            "session_id": "",
            "client_type": "agent",
            "token": HOOK_TOKEN,
        })
        ws.send(join_msg)
        session_id = ""
        history_received = False
        ws.settimeout(1.0)
        while True:
            try:
                resp = json.loads(ws.recv())
            except _ws.WebSocketTimeoutException:
                break
            except json.JSONDecodeError:
                continue
            if resp.get("type") == "join_ack":
                session_id = (resp.get("payload") or {}).get("session_id", "")
            elif resp.get("type") == "history":
                history_received = True
                msgs = (resp.get("payload") or {}).get("messages", [])
                _safe_stderr(f"[Agent WS] received {len(msgs)} history messages")
        ws.settimeout(None)
        _safe_stderr(f"[Agent WS] session_id={session_id}" + (" + history" if history_received else ""))
        return ws, session_id
    except ImportError:
        _safe_stderr("[Agent WS] websocket-client 未安装，降级到 HTTP 轮询模式")
        return None, ""
    except Exception as e:
        _safe_stderr(f"[Agent WS] 连接失败: {e}，降级到 HTTP 轮询模式")
        return None, ""


def _handle_ws_messages(ws, ws_module) -> None:
    """从 WS 接收并处理一条消息（非阻塞，1 秒超时）。

    提取为独立函数以降低 poll_loop 的复杂度。
    支持的消息类型：
    - session_msg → 跳过（chat 由 serein.mjs Relay 模式处理）
    - cmd → 远程命令分发执行
    """
    if ws_module is None:
        return
    try:
        ws.settimeout(1.0)
        raw = ws.recv()
        if raw:
            try:
                msg = json.loads(raw)
                msg_type = msg.get("type", "")
                payload = msg.get("payload") or {}
                if msg_type == "session_msg":
                    return
                elif msg_type == "cmd":
                    action = payload.get("action", "")
                    project = payload.get("project", "")
                    agent_type = payload.get("agent_type", "")
                    command = payload.get("command", "")
                    cmd_id = payload.get("cmd_id", "")
                    file_name = payload.get("file_name", "")
                    file_data = payload.get("file_data", "")
                    cmd = {"action": action, "project": project, "cmd_id": cmd_id}
                    if agent_type:
                        cmd["agent_type"] = agent_type
                    if command:
                        cmd["command"] = command
                    if file_name:
                        cmd["file_name"] = file_name
                    if file_data:
                        cmd["file_data"] = file_data
                    for field in (
                        "work_scope", "agent_session_id", "session_id",
                        "agent_session_mode", "runtime_mode",
                    ):
                        value = payload.get(field, "")
                        if value:
                            cmd[field] = value
                    _safe_stderr(f"[Agent WS] cmd: {action} {project}")
                    result = execute_cmd(cmd)
                    if action in ("start", "stop", "kill-all"):
                        _report_cached_runtime_status()
                    _safe_stderr(f"[Agent WS] done: {result.get('status', result.get('error', 'rc=' + str(result.get('returncode', '?'))))}")
            except json.JSONDecodeError:
                pass
    except ws_module.WebSocketTimeoutException:
        pass
    except Exception:
        _safe_stderr("[Agent] WS 连接异常，回退到 HTTP 轮询模式，60s 后尝试重连")
        ws.close()
        raise


def _poll_http_commands() -> None:
    """HTTP 回退模式：从后端取一个命令并执行（单次轮询）。"""
    try:
        resp = http_req("GET", "/agent/queue")
    except Exception as e:
        _safe_stderr(f"[Agent] HTTP queue 请求失败: {e}")
        return
    if not resp.get("has_cmd"):
        return
    cmd = {
        "cmd_id": resp["cmd_id"],
        "action": resp["action"],
        "project": resp["project"],
    }
    if resp.get("agent_type"):
        cmd["agent_type"] = resp["agent_type"]
    if resp.get("command"):
        cmd["command"] = resp["command"]
    if resp.get("file_name"):
        cmd["file_name"] = resp["file_name"]
    if resp.get("file_data"):
        cmd["file_data"] = resp["file_data"]
        # 安全警告：file_data 以 Base64 在 HTTP JSON 响应体中传输，等同于明文。
        # 建议后端使用 HTTPS 或在 HTTP 队列中传输文件 URL 引用而非内容本身。
        _safe_stderr("[Agent] 安全警告：file_data 通过 HTTP 明文传输（Base64 编码非加密）")
    for field in (
        "work_scope", "agent_session_id", "session_id",
        "agent_session_mode", "runtime_mode",
    ):
        if resp.get(field):
            cmd[field] = resp[field]
    _safe_stderr(f"[Agent] cmd: {cmd['action']} {cmd['project']}")
    result = execute_cmd(cmd)
    if cmd["action"] in ("start", "stop", "kill-all"):
        _report_cached_runtime_status()
    _safe_stderr(f"[Agent] done: {result.get('status', result.get('error', 'rc=' + str(result.get('returncode', '?'))))}")


# ── 主循环 ──

class _PollState:
    """poll_loop 内部状态容器，减少主循环中的分散局部变量。"""

    __slots__ = ('ws', 'session_id', 'ws_module', 'remote_host',
                 'last_heartbeat', 'hb_count',
                 'last_ws_reconnect', 'ws_permanently_disabled')

    def __init__(self, ws, session_id, ws_module, remote_host):
        self.ws = ws
        self.session_id = session_id
        self.ws_module = ws_module
        self.remote_host = remote_host
        self.last_heartbeat = 0.0
        self.hb_count = 0
        self.last_ws_reconnect = time.time() if ws is None else 0.0
        self.ws_permanently_disabled = False  # HTTP 后端时设为 True，防止重连循环


def _heartbeat_tick(state: _PollState, now: float) -> None:
    """每 20 秒发送一次 agent 心跳。"""
    if now - state.last_heartbeat < 20:
        return
    status = do_status()
    state.hb_count += 1
    output = {"_heartbeat": True, **status}
    if state.hb_count % 3 == 0:
        sysinfo = collect_sysinfo()
        output["sysinfo"] = sysinfo
        _safe_stderr(f"[Agent] heartbeat: {status['running']} sysinfo cpu={sysinfo['cpu']}% mem={sysinfo['memory']['percent']}% disk={sysinfo['disk']['percent']}%")
        check_alerts(sysinfo)
    else:
        _safe_stderr(f"[Agent] heartbeat: {status['running']}")
    try:
        http_req("POST", "/agent/report", {
            "cmd_id": "", "success": True,
            "output": output,
        })
    except Exception:
        _safe_stderr('[Agent] heartbeat report failed（不会阻断主循环）')
    state.last_heartbeat = now


def _ws_reconnect_tick(state: _PollState, now: float) -> None:
    """WS 断开后每 10 秒尝试重连。
    HTTP 后端（ws_permanently_disabled=True）跳过所有重连，防止死循环。
    """
    if state.ws is not None:
        return
    if state.ws_permanently_disabled:
        return  # HTTP 后端，永久禁用 WS 重连
    if now - state.last_ws_reconnect < 10:
        return
    state.last_ws_reconnect = now  # 防止紧循环重试
    _safe_stderr("[Agent] 尝试重新连接 WS...")
    try:
        new_ws, new_sid = _ws_connect()
        if new_ws:
            state.ws = new_ws
            state.session_id = new_sid
            _safe_stderr("[Agent] WS 重连成功")
    except Exception as e:
        _safe_stderr(f"[Agent] WS 重连失败: {e}")


def _ws_message_tick(state: _PollState) -> None:
    """接收并处理一条 WS 消息（非阻塞）。"""
    if state.ws is None:
        return
    try:
        _handle_ws_messages(state.ws, state.ws_module)
    except Exception:
        _safe_stderr("[Agent] WS 连接异常，回退到 HTTP 轮询模式，60s 后尝试重连")
        state.ws = None
        state.last_ws_reconnect = time.time()


def _http_poll_tick(state: _PollState) -> None:
    """HTTP 轮询取命令并执行。

    file_write 等非 chat 命令只通过 HTTP 队列投递（不走 WS），
    因此无论 WS 是否连接都执行 HTTP 轮询，WS 连接仅用于
    实时 session_msg/cmd_step 推送。
    """
    _poll_http_commands()


def _relay_watchdog_tick() -> None:
    """检测 relay 是否已退出，清除 running_projects 状态。

    relay 死了就死了——自动重启没有意义（之前的 session/聊天记录已丢失），
    手机端重新点 Start 即可拉起新的 relay。
    本函数只负责检测 relay 退出并清理状态，不做任何重启。
    """
    with _running_lock:
        active = list(running_projects.keys())
    if not active:
        return
    if _is_relay_active():
        return
    # relay 已死，清理 quit 标记和项目名标记
    if os.path.isfile(RELAY_QUIT_FILE):
        try:
            os.remove(RELAY_QUIT_FILE)
        except OSError:
            pass
    if os.path.isfile(RELAY_PROJECT_FILE):
        try:
            os.remove(RELAY_PROJECT_FILE)
        except OSError:
            pass
    if os.path.isfile(RELAY_SCOPE_FILE):
        try:
            os.remove(RELAY_SCOPE_FILE)
        except OSError:
            pass
    if os.path.isfile(RELAY_RUNTIME_FILE):
        try:
            os.remove(RELAY_RUNTIME_FILE)
        except OSError:
            pass
    with _running_lock:
        for project in active:
            running_projects.pop(project, None)
    _safe_stderr(f"[Agent relay-watchdog] relay 已退出，已清除项目状态: {active}（手机端重新 Start 即可唤醒）")
    # 用户直接关闭 Relay/CMD 时不会经过 stop 命令，因此必须在这里立即
    # 推送新的空运行快照。否则后端和手机只能等下一轮 20 秒 heartbeat，
    # 启动后的短暂状态保护还可能让旧的 Online 状态停留得更久。
    _report_cached_runtime_status()


def _remote_host_tick(state: _PollState, now: float) -> None:
    """Advance the optional hidden Remote Host without spawning shell windows."""
    state.remote_host.tick(now)


def poll_loop():
    """主循环：调度心跳 / WS 重连 / WS 消息处理 / HTTP 轮询。"""
    print(f"[Agent] connected to {require_server()}")
    print(f"[Agent] projects: {list(PROJECT_PATHS.keys())}")
    # startup: scan for already running claude
    real = scan_running()
    with _running_lock:
        running_projects.update(real)
    if real:
        # 安全：只暴露项目名和 PID，不打印 cmd_line（可能含 session token 等敏感信息）
        safe = {k: {"pid": v["pid"]} for k, v in real.items()}
        print(f"[Agent] found running: {safe}")

    # 尝试 WS 连接（_ws_connect 内部已处理异常并记录日志）
    ws, session_id = _ws_connect()

    try:
        import websocket as _ws_mod
    except ImportError:
        _ws_mod = None
        _safe_stderr("[Agent] websocket-client 未安装（poll_loop），WS 功能不可用")

    remote_host = RemoteHostManager(AGENT_DIR, http_req, backend_url=require_server())
    _safe_stderr(f"[Agent] RemoteHostManager: enabled={remote_host.enabled} env={os.environ.get('SEREIN_REMOTE_HOST_ENABLE', '<not set>')} exe={remote_host.executable.is_file()}")
    state = _PollState(ws, session_id, _ws_mod, remote_host)
    # WS 已连接就不禁用（HTTP 直连 IP 的 WS 是允许的）
    # 仅当 WS 连接失败（ws is None）且后端是 HTTP 时才永久禁用
    if ws is None and require_server().startswith("http://"):
        state.ws_permanently_disabled = True
        _safe_stderr("[Agent] HTTP 后端且 WS 连接失败，永久禁用 WS 重连")

    # Run remote-host tick in a dedicated thread so the main loop's
    # /agent/queue long-poll (up to 25s) does not delay consent popup latency.
    # The remote host needs sub-2s pending-session polling.
    import threading as _threading_mod
    _remote_host_stop = _threading_mod.Event()
    def _remote_host_loop() -> None:
        while not _remote_host_stop.is_set():
            try:
                remote_host.tick()
            except Exception as e:
                _safe_stderr(f"[Agent] remote_host thread err: {type(e).__name__}: {e}")
            time.sleep(1)
    if remote_host.enabled:
        _t = _threading_mod.Thread(target=_remote_host_loop, name="remote-host", daemon=True)
        _t.start()
        _safe_stderr("[Agent] remote-host tick thread started")

    while True:
        try:
            now = time.time()
            _heartbeat_tick(state, now)
            _ws_reconnect_tick(state, now)
            _ws_message_tick(state)
            _http_poll_tick(state)
            _relay_watchdog_tick()
            # _remote_host_tick removed from main loop — now runs in dedicated thread
            # WS 断开时所有 tick 函数立即返回，此处 sleep 防止 CPU 空转
            time.sleep(1)
        except HTTPError as e:
            _safe_stderr(f"[Agent] HTTP {e.code}, retry in 5s")
            time.sleep(5)
        except URLError as e:
            _safe_stderr(f"[Agent] net: {e.reason}, retry in 5s")
            time.sleep(5)
        except Exception as e:
            _safe_stderr(f"[Agent] err: {type(e).__name__}: {e}, retry in 5s")
            time.sleep(5)


if __name__ == "__main__":
    # 纯 watchdog 模式：心跳 + HTTP 命令轮询
    # 不再支持 --interactive（已由 serein.mjs Relay 模式替代）

    # pythonw.exe 无控制台，stderr/stdout 默认无效。
    # 重定向到日志文件，确保 _safe_stderr 输出可追踪。
    _log_dir = os.path.join(AGENT_DIR, "logs")
    os.makedirs(_log_dir, exist_ok=True)
    _log_file = os.path.join(_log_dir, "agent_debug.log")
    try:
        _log_fh = open(_log_file, "a", encoding="utf-8", buffering=1)
        sys.stderr = _log_fh
        sys.stdout = _log_fh
    except Exception:
        pass  # 重定向失败不阻止启动

    # 防 Clash TUN 模式/VPN 劫持：将服务器加入 no_proxy 直连列表
    _no_proxy_hosts = os.environ.get("SEREIN_NO_PROXY", "")
    os.environ.setdefault("no_proxy", _no_proxy_hosts)
    os.environ.setdefault("NO_PROXY", _no_proxy_hosts)
    if not HOOK_TOKEN:
        _safe_stderr("[Agent] SEREIN_HOOK_TOKEN 未设置（环境变量或 ~/.claude/settings.json），拒绝启动。")
        sys.exit(1)
    if not _VALID_TOKEN_RE.fullmatch(HOOK_TOKEN):
        _safe_stderr(f"[Agent] SEREIN_HOOK_TOKEN 包含非法字符，拒绝启动（token 必须匹配 {_VALID_TOKEN_RE.pattern}）。")
        sys.exit(1)
    if not SERVER:
        _safe_stderr("[Agent] SEREIN_BACKEND 未设置（环境变量或 ~/.claude/settings.json），拒绝启动。")
        sys.exit(1)

    _instance_lock = acquire_agent_instance_lock()
    if _instance_lock is None:
        sys.exit(0)

    with open(AGENT_PID_FILE, "w") as f:
        f.write(str(os.getpid()))
    print(f"[Agent] started PID={os.getpid()}")

    # 启动本地 Daemon HTTP 控制端口（后台线程，localhost:7331）
    start_daemon()

    try:
        poll_loop()
    except KeyboardInterrupt:
        print("[Agent] stopped")
    finally:
        remove_own_agent_pid_file()
        release_agent_instance_lock(_instance_lock)
