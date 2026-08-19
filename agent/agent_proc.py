#!/usr/bin/env python3
"""serein 进程管理模块：状态扫描、PID 存活检测、进程启停。
从 local_agent.py 提取，降低主文件复杂度。"""
import base64
import csv
import glob
import io
import json
import os
import re
import shutil
import subprocess
import time
import threading
from urllib.parse import unquote, urlsplit

try:
    import psutil
except ImportError:  # Public installs keep the existing Windows fallbacks.
    psutil = None

from common import(
    PROJECT_PATHS, USER_HOME, AGENT_DIR, _safe_stderr, _load_dynamic_projects,
    register_runtime_project,
)
from agent_config import get_agent_config, resolve_binary, is_supported, AGENT_TYPES, DEFAULT_AGENT_TYPE

# ── 状态 ──
running_projects: dict[str, dict] = {}
_running_lock = threading.Lock()
_git_remote_cache: dict[str, tuple[float, list[str]]] = {}
_git_remote_cache_lock = threading.Lock()
_GIT_REMOTE_CACHE_TTL = 300.0
_codex_desktop_cache: tuple[float, tuple[tuple[str, str], ...], dict[str, dict[str, object]]] = (0.0, tuple(), {})
_codex_desktop_cache_lock = threading.Lock()
_CODEX_DESKTOP_CACHE_TTL = 30.0
_CODEX_DESKTOP_SOURCE_KINDS = frozenset(("vscode", "appServer"))
AGENT_PID_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".agent.pid")
RELAY_PID_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".relay.pid")
RELAY_QUIT_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".relay_quit")  # relay 正常退出标记
RELAY_PROJECT_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".relay_project")  # relay 关联的项目名
RELAY_SCOPE_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".relay_scope")
RELAY_RUNTIME_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".relay_runtime")
_WORK_SCOPE_RE = re.compile(r"^[A-Za-z0-9._:/-]{1,500}$")
_SESSION_UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$"
)
_SEREIN_SESSION_RE = re.compile(r"^[A-Za-z0-9._-]{1,100}$")
COLLABORATION_SESSIONS_FILE = os.path.join(USER_HOME, ".serein", "collaboration_sessions.json")
# _is_relay_active 缓存（减少 tasklist 子进程调用频率）
_relay_cache: tuple[bool, float] = (False, 0.0)
# _relay_cache 专用的线程锁，防止 _is_relay_active 的并发读写导致返回过期值。
# _is_relay_active 会被主循环的 _relay_watchdog_tick 和 execute_cmd 的 chat 路径
# 多个线程同时调用，虽然 CPython GIL 和 2 秒 TTL 降低了风险，但作为全局可变状态
# 应当加锁保护。
_relay_cache_lock = threading.Lock()
# 缓存 TTL 为 2 秒（原 10 秒），缩小 relay 崩溃后 watchdog 误报"relay 活跃"窗口。
# 当 relay 崩溃时，watchdog 仍错误报告 chat 命令"已由 relay 处理"最长 2 秒，
# 而不是之前的 10 秒。同时通过 execute_cmd 中 chat 路径的实时检查兜底。
_RELAY_CACHE_TTL: float = 2.0
# relay 启动中标志（防止 watchdog 在 do_start() 执行期间误判 relay 未启动而重复 spawn）
_relay_starting: bool = False
_relay_starting_lock = threading.Lock()


def pid_alive(pid: int) -> bool:
    """检查进程是否存活（Windows tasklist 查询）。"""
    if pid <= 0:
        return False
    if psutil is not None:
        return psutil.pid_exists(pid)
    try:
        out = subprocess.run(
            ['tasklist', '/FI', f'PID eq {pid}', '/FO', 'CSV', '/NH'],
            capture_output=True, timeout=5, text=True,
            creationflags=subprocess.CREATE_NO_WINDOW, check=True
        ).stdout
        # CSV 格式：例如 "claude.exe","1234","Console","1","7,800 K"
        return f'"{pid}"' in out
    except Exception:
        return False


def _parse_wmic_output(stdout: str) -> list[tuple[str, str]]:
    """解析 wmic CSV 输出为 (CommandLine, PID) 列表。
    提取为模块级函数，避免 scan_running 和 _scan_all_claude_pids 重复实现。"""
    reader = csv.reader(io.StringIO(stdout))
    entries: list[tuple[str, str]] = []
    for row in reader:
        if len(row) < 3:
            continue
        # CSV 格式: Node,CommandLine,ProcessId
        # 第一行是列名（Node,CommandLine,ProcessId），跳过
        if row[0].strip() == 'Node':
            continue
        cmd_line = row[1].strip() if row[1] else ''
        pid_str = row[2].strip() if row[2] else ''
        if pid_str.isdigit():
            entries.append((cmd_line, pid_str))
    return entries


def _wmic_query_agent(binary_name: str = 'claude.exe') -> list[tuple[str, str]] | None:
    """通过 wmic 查询指定 agent 进程，返回 [(CommandLine, PID), ...]。
    返回 None 表示 wmic 不可用（需要回退到 PowerShell）；
    返回空列表表示 wmic 可用但无匹配进程。"""
    try:
        out = subprocess.run(
            ['wmic', 'process', 'where', f"name='{binary_name}'",
             'GET', 'ProcessId,CommandLine', '/FORMAT:CSV'],
            capture_output=True, timeout=5, text=True,
            creationflags=subprocess.CREATE_NO_WINDOW
        ).stdout
        return _parse_wmic_output(out)
    except FileNotFoundError:
        # wmic 不可用（Windows 11 24H2+ 可选功能移除）
        return None
    except Exception as _e:
        _safe_stderr(f"[Agent] _wmic_query_agent({binary_name}) 失败: {type(_e).__name__}: {_e}")
        return None


def _powershell_query_agent(binary_name: str = 'claude.exe') -> list[tuple[str, str]]:
    """通过 PowerShell Get-CimInstance 查询指定 agent 进程，
    返回 [(CommandLine, PID), ...]。
    使用 ConvertTo-Csv 格式保证含逗号命令行的正确解析。"""
    try:
        out = subprocess.run(
            ['powershell', '-NoProfile', '-Command',
             f'Get-CimInstance Win32_Process -Filter "name=\'{binary_name}\'" | Select-Object CommandLine,ProcessId | ConvertTo-Csv -NoTypeInformation'],
            capture_output=True, timeout=5, text=True,
            creationflags=subprocess.CREATE_NO_WINDOW
        ).stdout
        reader = csv.reader(io.StringIO(out))
        entries: list[tuple[str, str]] = []
        for row in reader:
            if len(row) < 2:
                continue
            # CSV: "CommandLine","ProcessId"
            cmd_line = row[0].strip() if row[0] else ''
            pid_str = row[1].strip() if row[1] else ''
            if pid_str.isdigit():
                entries.append((cmd_line, pid_str))
        return entries
    except Exception as _e:
        _safe_stderr(f"[Agent] _powershell_query_agent({binary_name}) 失败: {type(_e).__name__}: {_e}")
        return []


def _psutil_query_agent(binary_name: str = 'claude.exe') -> list[tuple[str, str]] | None:
    """Read Agent command lines in-process without opening a console window."""
    if psutil is None:
        return None
    entries: list[tuple[str, str]] = []
    expected = binary_name.lower()
    try:
        for process in psutil.process_iter(['pid', 'name', 'cmdline']):
            try:
                name = str(process.info.get('name') or '').lower()
                if name != expected:
                    continue
                raw_cmd = process.info.get('cmdline') or []
                cmd_line = subprocess.list2cmdline([str(part) for part in raw_cmd])
                entries.append((cmd_line, str(process.info['pid'])))
            except (psutil.AccessDenied, psutil.NoSuchProcess, psutil.ZombieProcess):
                continue
        return entries
    except Exception as exc:
        _safe_stderr(f"[Agent] _psutil_query_agent({binary_name}) failed: {type(exc).__name__}: {exc}")
        return None


def _query_agent_processes(binary_name: str) -> list[tuple[str, str]]:
    """Prefer console-free process inspection and retain compatible fallbacks."""
    entries = _psutil_query_agent(binary_name)
    if entries is not None:
        return entries
    entries = _wmic_query_agent(binary_name)
    if entries is not None:
        return entries
    return _powershell_query_agent(binary_name)


def scan_running() -> dict[str, dict]:
    """用 wmic 扫描所有受支持的 agent 进程（CommandLine + PID），按工作目录匹配项目。
    - 遍历 AGENT_TYPES 中所有 agent 类型的二进制名
    - 优先 wmic（约 50-100ms，比 PowerShell ~500ms 快 5-10x）
    - wmic 不可用时回退到 PowerShell（旧系统兼容）
    - 返回完整信息（含 cmd_line），调用方应优先使用 scan_running_safe() 避免 cmd_line 泄漏"""
    result: dict[str, dict] = {}

    for agent_type in AGENT_TYPES:
        config = get_agent_config(agent_type)
        binary = config.binary_name if os.name == 'nt' else config.binary_name_unix

        entries = _query_agent_processes(binary)

        for cmd_line, pid_str in entries:
            pid = int(pid_str)
            for proj_name, proj_path in PROJECT_PATHS.items():
                if proj_path.lower() in cmd_line.lower():
                    result[proj_name] = {
                        "pid": pid,
                        "cmd_line": cmd_line,
                        "agent_type": agent_type,
                        "runtime_mode": "cli",
                    }
                    break
    return result


def scan_running_safe() -> dict[str, dict]:
    """扫描 claude.exe 进程，返回 dict 不含 cmd_line 字段。
    安全版本，防止调用方误用 cmd_line（可能含 session token 等敏感信息）。"""
    raw = scan_running()
    safe: dict[str, dict] = {}
    for name, info in raw.items():
        safe[name] = {"pid": info["pid"]}
    return safe


def normalize_git_remote(remote: str) -> str:
    """Return a credential-free canonical Git remote key.

    HTTPS, SSH URL and SCP-like remotes all become ``host/owner/repo``.
    Local/file remotes are deliberately ignored. The canonical key is enough
    for repository matching and never exposes embedded usernames or tokens.
    """
    value = (remote or "").strip()
    if not value or value.startswith(("/", "./", "../", "file://")):
        return ""

    host = ""
    path = ""
    if "://" in value:
        try:
            parsed = urlsplit(value)
        except ValueError:
            return ""
        if parsed.scheme.lower() not in ("http", "https", "ssh", "git"):
            return ""
        host = (parsed.hostname or "").lower().rstrip(".")
        path = parsed.path
    else:
        # SCP-like syntax, for example git@github.com:owner/repository.git.
        if ":" not in value:
            return ""
        authority, path = value.split(":", 1)
        host = authority.rsplit("@", 1)[-1].lower().rstrip(".")

    if not host or any(ch.isspace() for ch in host):
        return ""
    clean_path = unquote(path).replace("\\", "/").strip("/")
    if clean_path.lower().endswith(".git"):
        clean_path = clean_path[:-4]
    parts = [part for part in clean_path.split("/") if part not in ("", ".", "..")]
    if len(parts) < 2:
        return ""
    return host + "/" + "/".join(parts)


def _read_project_git_remotes(project_path: str) -> list[str]:
    """Read all configured Git remotes without invoking a shell."""
    if not project_path or not os.path.isdir(project_path):
        return []
    try:
        names_result = subprocess.run(
            ["git", "-C", project_path, "remote"],
            capture_output=True, text=True, encoding="utf-8", errors="replace",
            timeout=4, check=False,
            creationflags=subprocess.CREATE_NO_WINDOW,
        )
    except (OSError, subprocess.SubprocessError):
        return []
    if names_result.returncode != 0:
        return []

    keys: list[str] = []
    names = [line.strip() for line in names_result.stdout.splitlines() if line.strip()][:20]
    for name in names:
        try:
            urls_result = subprocess.run(
                ["git", "-C", project_path, "remote", "get-url", "--all", name],
                capture_output=True, text=True, encoding="utf-8", errors="replace",
                timeout=4, check=False,
                creationflags=subprocess.CREATE_NO_WINDOW,
            )
        except (OSError, subprocess.SubprocessError):
            continue
        if urls_result.returncode != 0:
            continue
        for raw_url in urls_result.stdout.splitlines():
            key = normalize_git_remote(raw_url)
            if key and key not in keys:
                keys.append(key)
            if len(keys) >= 20:
                return keys
    return keys


def collect_project_git_remotes(force: bool = False) -> dict[str, list[str]]:
    """Return canonical remotes for every registered project with a short TTL."""
    now = time.monotonic()
    result: dict[str, list[str]] = {}
    for project, project_path in PROJECT_PATHS.items():
        cache_key = os.path.normcase(os.path.abspath(project_path))
        cached: tuple[float, list[str]] | None = None
        with _git_remote_cache_lock:
            cached = _git_remote_cache.get(cache_key)
        if force or cached is None or now - cached[0] >= _GIT_REMOTE_CACHE_TTL:
            remotes = _read_project_git_remotes(project_path)
            with _git_remote_cache_lock:
                _git_remote_cache[cache_key] = (now, list(remotes))
        else:
            remotes = list(cached[1])
        result[project] = remotes
    return result


def collect_codex_desktop_projects(force: bool = False) -> dict[str, dict[str, object]]:
    """Discover projects that have real Codex Desktop/App Server threads.

    Codex CLI, exec and sub-agent JSONL files can share the same cwd. They must
    not make a project appear as Desktop-capable, so only the protocol source
    kinds ``vscode`` and ``appServer`` are counted. No prompt, turn text or
    thread id leaves this process.
    """
    global _codex_desktop_cache
    signature = tuple(sorted(
        (name, os.path.normcase(os.path.abspath(path.rstrip("\\/"))))
        for name, path in PROJECT_PATHS.items()
    ))
    now = time.monotonic()
    with _codex_desktop_cache_lock:
        cached_at, cached_signature, cached_result = _codex_desktop_cache
        if not force and signature == cached_signature and now - cached_at < _CODEX_DESKTOP_CACHE_TTL:
            return {name: dict(value) for name, value in cached_result.items()}

    by_path = {path: name for name, path in signature}
    counts: dict[str, int] = {}
    session_root = os.path.join(USER_HOME, ".codex", "sessions")
    if os.path.isdir(session_root):
        for root, _, files in os.walk(session_root):
            for filename in files:
                if not filename.endswith(".jsonl"):
                    continue
                try:
                    with open(os.path.join(root, filename), "r", encoding="utf-8") as handle:
                        first_line = handle.readline(64 * 1024 + 1)
                    if len(first_line) > 64 * 1024:
                        continue
                    record = json.loads(first_line)
                    if record.get("type") != "session_meta":
                        continue
                    payload = record.get("payload") or {}
                    source = payload.get("source")
                    if not isinstance(source, str) or source not in _CODEX_DESKTOP_SOURCE_KINDS:
                        continue
                    cwd = str(payload.get("cwd") or "").rstrip("\\/")
                    if not cwd:
                        continue
                    project = by_path.get(os.path.normcase(os.path.abspath(cwd)))
                    if not project:
                        candidate = os.path.basename(cwd)
                        if register_runtime_project(candidate, cwd):
                            project = candidate
                            by_path[os.path.normcase(os.path.abspath(cwd))] = candidate
                    if project:
                        counts[project] = counts.get(project, 0) + 1
                except (OSError, ValueError, TypeError, json.JSONDecodeError):
                    continue

    result: dict[str, dict[str, object]] = {
        name: {"available": True, "thread_count": count}
        for name, count in counts.items() if count > 0
    }
    with _codex_desktop_cache_lock:
        _codex_desktop_cache = (now, signature, result)
    return {name: dict(value) for name, value in result.items()}


def _read_relay_runtime() -> dict[str, str]:
    """Read the relay's non-sensitive runtime identity marker."""
    try:
        if not os.path.isfile(RELAY_RUNTIME_FILE):
            return {}
        with open(RELAY_RUNTIME_FILE, "r", encoding="utf-8") as handle:
            raw = json.load(handle)
        runtime_mode = str(raw.get("runtime_mode") or "")
        agent_type = str(raw.get("agent_type") or "")
        if runtime_mode not in ("cli", "desktop"):
            return {}
        if agent_type not in AGENT_TYPES:
            return {}
        return {"runtime_mode": runtime_mode, "agent_type": agent_type}
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        return {}


def collect_collaboration_sessions() -> dict[str, dict[str, str]]:
    """Load the local work-scope -> Agent session index without exposing paths or credentials."""
    try:
        if not os.path.isfile(COLLABORATION_SESSIONS_FILE):
            return {}
        if os.path.getsize(COLLABORATION_SESSIONS_FILE) > 1024 * 1024:
            return {}
        with open(COLLABORATION_SESSIONS_FILE, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, ValueError, TypeError):
        return {}
    raw_sessions = payload.get("sessions", {}) if isinstance(payload, dict) else {}
    if not isinstance(raw_sessions, dict):
        return {}
    result: dict[str, dict[str, str]] = {}
    for scope, raw in list(raw_sessions.items())[:500]:
        if not isinstance(scope, str) or not _WORK_SCOPE_RE.fullmatch(scope) or not isinstance(raw, dict):
            continue
        agent_session_id = raw.get("agent_session_id", "")
        agent_type = raw.get("agent_type", "")
        project = raw.get("project", "")
        updated_at = raw.get("updated_at", "")
        if not isinstance(agent_session_id, str) or not _SESSION_UUID_RE.fullmatch(agent_session_id):
            continue
        if agent_type not in AGENT_TYPES:
            continue
        if not isinstance(project, str) or project not in PROJECT_PATHS:
            continue
        if not isinstance(updated_at, str) or len(updated_at) > 64:
            continue
        result[scope] = {
            "agent_session_id": agent_session_id,
            "agent_type": agent_type,
            "project": project,
            "updated_at": updated_at,
        }
    return result


def do_status() -> dict:
    """查询本地进程状态——实时扫描 + 合并缓存。

    当 relay 活跃但 scan_running 未检测到 claude.exe 时（CLI serein 启动场景），
    从 .relay_project 文件读取项目名并补充到 running_projects 中，
    确保手机端能看到项目 online。
    """
    # 重新加载动态注册的项目（serein.mjs --qr 启动新项目时写入 ~/.serein/projects.json）
    _load_dynamic_projects()
    real = scan_running()
    with _running_lock:
        for name, info in real.items():
            running_projects[name] = info
        to_check = [name for name in list(running_projects.keys()) if name not in real]
        pids = {name: running_projects[name].get("pid", 0) for name in to_check}
    dead = [name for name, pid in pids.items() if pid > 0 and not pid_alive(pid)]
    if dead:
        with _running_lock:
            for name in dead:
                running_projects.pop(name, None)
    
    # relay 活跃但 scan_running 未检测到时，从 .relay_project 补充
    # 场景：用户直接在 CMD 输入 serein 启动（非手机 Start），
    # claude.exe 由 node-pty 创建，scan_running 可能无法通过命令行匹配项目路径。
    if _is_relay_active():
        try:
            if os.path.isfile(RELAY_PROJECT_FILE):
                with open(RELAY_PROJECT_FILE, "r", encoding="utf-8") as f:
                    relay_project = f.read().strip()
                if relay_project and relay_project in PROJECT_PATHS:
                    relay_runtime = _read_relay_runtime()
                    with _running_lock:
                        if relay_project not in running_projects:
                            running_projects[relay_project] = {
                                "pid": 0,
                                "cmd_line": PROJECT_PATHS[relay_project],
                            }
                        if relay_runtime:
                            running_projects[relay_project].update(relay_runtime)
        except Exception as e:
            _safe_stderr(f"[Agent] scan_running 未知错误: {type(e).__name__}: {e}")

    desktop_projects = collect_codex_desktop_projects()
    with _running_lock:
        snapshot_running = list(running_projects.keys())
        # 只暴露 pid 和项目名，不泄露完整命令行（可能含 session ID 等敏感信息）
        snapshot_details = {}
        for k, v in running_projects.items():
            safe = dict(v)
            safe.pop("cmd_line", None)
            snapshot_details[k] = safe
    # Backward-compatible transport: older cloud backends already preserve the
    # nested `details` map, even before they know the dedicated
    # `desktop_projects` top-level field.
    for project, capability in desktop_projects.items():
        detail = snapshot_details.setdefault(project, {})
        detail["desktop_available"] = bool(capability.get("available"))
        detail["desktop_thread_count"] = int(capability.get("thread_count") or 0)
    return {
        "running": snapshot_running,
        "details": snapshot_details,
        # 暴露所有已知项目路径（供后端 /agent/projects 缓存消费）
        "projects": dict(PROJECT_PATHS),
        # 只上报移除了账号、Token 和 URL 参数的 host/owner/repo 规范键。
        "git_remotes": collect_project_git_remotes(),
        # 只包含真实存在 vscode/appServer 来源会话的项目；CLI 会话不会进入这里。
        "desktop_projects": desktop_projects,
        "collaboration_sessions": collect_collaboration_sessions(),
        # 支持的 agent 类型列表（供手机端 UI 渲染 agent 选择器）
        "agent_types": AGENT_TYPES,
    }


def find_latest_session(proj_path: str, agent_type: str = "") -> str | None:
    """找到项目最新的 agent 会话 UUID。
    根据 agent_type 选择对应的会话目录（默认 claude）。"""
    config = get_agent_config(agent_type)
    if not config.supports_jsonl:
        return None
    # 从 session_dir_pattern 提取目录部分：{home}/.claude/projects/{slug}
    sessions_dir = config.session_dir_pattern.format(home=USER_HOME, slug='').rstrip('/').rstrip('\\')
    # sessions_dir 现在是 ~/.claude/projects 或 ~/.codex/sessions 等
    if not os.path.isdir(sessions_dir):
        return None  # 目录不存在（如新安装环境），优雅返回 None 而非抛出 FileNotFoundError

    if config.name == "codex":
        # Codex 按 YYYY/MM/DD 全局嵌套保存会话，项目路径位于首行
        # session_meta.payload.cwd 中，不能沿用 Claude 的项目 slug 目录。
        candidates: list[str] = []
        for root, _, files in os.walk(sessions_dir):
            for filename in files:
                if filename.endswith(config.session_file_ext):
                    candidates.append(os.path.join(root, filename))
        candidates.sort(key=os.path.getmtime, reverse=True)
        expected = os.path.normcase(os.path.abspath(proj_path.rstrip("\\/")))
        for file_path in candidates:
            try:
                with open(file_path, "r", encoding="utf-8") as session_file:
                    first_record = json.loads(session_file.readline())
                if first_record.get("type") != "session_meta":
                    continue
                payload = first_record.get("payload") or {}
                actual = os.path.normcase(os.path.abspath(str(payload.get("cwd") or "").rstrip("\\/")))
                if actual != expected:
                    continue
                originator = str(payload.get("originator") or "").lower()
                source = payload.get("source")
                if not (source == "cli" or originator == "codex-tui"):
                    continue
                return str(
                    payload.get("session_id")
                    or payload.get("id")
                    or os.path.splitext(os.path.basename(file_path))[0]
                )
            except (OSError, ValueError, TypeError, json.JSONDecodeError):
                continue
        return None

    project_name = os.path.basename(proj_path).lower()
    for entry in os.listdir(sessions_dir):
        if entry.lower().endswith("-" + project_name):
            sdir = os.path.join(sessions_dir, entry)
            if os.path.isdir(sdir):
                files = glob.glob(os.path.join(sdir, "*" + config.session_file_ext))
                if files:
                    files.sort(key=os.path.getmtime, reverse=True)
                    return os.path.splitext(os.path.basename(files[0]))[0]
    return None


def _start_relay_process(
    proj_path: str,
    project: str,
    agent_type: str = "",
    work_scope: str = "",
    agent_session_id: str = "",
    serein_session_id: str = "",
    agent_session_mode: str = "",
    runtime_mode: str = "cli",
) -> tuple[subprocess.Popen | None, dict | None]:
    """启动 relay 子进程（serein.mjs），返回 (proc, error)。
    职责单一：查找依赖 → 构造环境 → Popen → 等待 PID 文件。

    agent_type 指定 AI agent 类型（claude/codex），通过 SEREIN_AGENT_TYPE
    环境变量传递给 serein.mjs，relay 据此选择对应的二进制和会话目录。

    以隐藏进程启动 relay；手机端通过 WS 交互，relay 内部仍然使用 PTY。
    不再为每次 Start 创建可见控制台窗口，避免 watchdog/重复启动时闪窗。
    error 为 None 表示启动成功。"""
    # 直接写文件调试（绕过 _safe_stderr 排查日志丢失问题）
    try:
        with open(os.path.join(AGENT_DIR, "logs", "relay_debug.log"), "a", encoding="utf-8") as _df:
            _df.write(f"[_start_relay_process] ENTERED, project={project}, path={proj_path}\n")
            _df.write(f"[_start_relay_process] BACKEND={os.environ.get('SEREIN_BACKEND', '(missing)')}, TOKEN={'(set)' if os.environ.get('SEREIN_HOOK_TOKEN') else '(missing)'}\n")
            _df.flush()
    except Exception:
        pass
    relay_script = os.path.join(AGENT_DIR, "serein.mjs")
    if not os.path.isfile(relay_script):
        return None, {"error": f"relay script not found: {relay_script}"}

    node_exe = shutil.which("node")
    if not node_exe:
        return None, {"error": "node.exe not found in PATH"}

    env = os.environ.copy()
    env["SEREIN_PROJECT"] = proj_path
    env["SEREIN_PROJECT_NAME"] = project
    env["SEREIN_AGENT_TYPE"] = agent_type or DEFAULT_AGENT_TYPE
    env["SEREIN_RUNTIME_MODE"] = runtime_mode
    scoped_env = {
        "SEREIN_WORK_SCOPE": work_scope,
        "SEREIN_AGENT_SESSION_ID": agent_session_id,
        "SEREIN_SESSION_ID": serein_session_id,
        "SEREIN_AGENT_SESSION_MODE": agent_session_mode,
    }
    for key, value in scoped_env.items():
        if value:
            env[key] = value
        else:
            env.pop(key, None)

    # 清理可能残留的旧 PID 文件，防止 _is_relay_active 误判
    try:
        if os.path.isfile(RELAY_PID_FILE):
            os.remove(RELAY_PID_FILE)
    except Exception:
        pass

    # 清理可能残留的 quit 标记文件，确保新启动的 relay 不被 watchdog 误判为"正常退出"
    try:
        if os.path.isfile(RELAY_QUIT_FILE):
            os.remove(RELAY_QUIT_FILE)
    except Exception:
        pass

    # 清理可能残留的项目名文件
    try:
        if os.path.isfile(RELAY_PROJECT_FILE):
            os.remove(RELAY_PROJECT_FILE)
    except Exception:
        pass
    try:
        if os.path.isfile(RELAY_SCOPE_FILE):
            os.remove(RELAY_SCOPE_FILE)
    except Exception:
        pass
    try:
        if os.path.isfile(RELAY_RUNTIME_FILE):
            os.remove(RELAY_RUNTIME_FILE)
    except Exception:
        pass

    # 清除 _is_relay_active 缓存，确保后续检测重新读 PID 文件
    # do_start() 开头调用 _is_relay_active() 会设置缓存 (False, now)，
    # 如果不清除，后续 2 秒内的检测都会返回缓存的 False
    global _relay_cache
    with _relay_cache_lock:
        _relay_cache = (False, 0.0)

    _safe_stderr(f"[Agent _start_relay] 启动 relay: node={node_exe}, script={relay_script}")
    _safe_stderr(f"[Agent _start_relay] BACKEND={env.get('SEREIN_BACKEND', '(missing)')}, TOKEN={'(set)' if env.get('SEREIN_HOOK_TOKEN') else '(missing)'}")

    try:
        # 用户需要能直接看到 relay/Agent 启动后的 CMD 终端，因此显式创建
        # 一个独立控制台；不要将 stdout/stderr 重定向到后台日志。
        proc = subprocess.Popen(
            [node_exe, relay_script],
            cwd=AGENT_DIR,
            env=env,
            creationflags=subprocess.CREATE_NEW_CONSOLE,
        )
    except Exception as e:
        _safe_stderr(f"[Agent _start_relay] Popen 失败: {e}")
        return None, {"error": f"failed to start relay: {e}"}

    # 等待 relay 写入 PID 文件（最多 10 秒，增加超时应对慢启动）
    relay_started = False
    for i in range(20):
        if _is_relay_active():
            relay_started = True
            break
        # 检查 node 进程是否已退出（proc.poll() 返回退出码，None 表示仍在运行）
        exit_code = proc.poll()
        if exit_code is not None:
            _safe_stderr(f"[Agent _start_relay] relay 进程已退出，exit_code={exit_code}，PID文件存在={os.path.isfile(RELAY_PID_FILE)}")
            return None, {"error": f"relay 启动失败：进程已退出(exit_code={exit_code})", "relay_started": False}
        time.sleep(0.5)

    if not relay_started:
        # 调试日志：记录失败时的状态
        pid_exists = os.path.isfile(RELAY_PID_FILE)
        proc_alive = proc.poll() is None
        _safe_stderr(f"[Agent _start_relay] relay 启动超时(10s)，PID文件存在={pid_exists}，进程存活={proc_alive}")
        # 超时后终止子进程，防止僵尸进程残留
        try:
            proc.terminate()
        except Exception:
            pass
        return None, {"error": "relay 启动失败：进程已退出或 PID 文件未写入", "relay_started": False}

    _safe_stderr("[Agent _start_relay] relay 启动成功")
    return proc, None


def _notify_activation(project: str, agent_name: str) -> None:
    """Windows 桌面通知 - 弹出 PowerShell balloon tip。
    独立函数：职责单一，项目名通过环境变量传递而非字符串拼接防止注入。"""
    try:
        notify_env = os.environ.copy()
        notify_env['_RDPC_NOTIFY_PROJECT'] = project
        notify_env['_RDPC_NOTIFY_AGENT'] = agent_name
        subprocess.Popen(
            ['powershell', '-NoProfile', '-Command',
             '& {[System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms")|Out-Null;'
             '$n=New-Object System.Windows.Forms.NotifyIcon;'
             '$n.Icon=[System.Drawing.SystemIcons]::Information;'
             '$n.BalloonTipIcon="Info";'
             '$n.BalloonTipTitle="serein Relay";'
             '$proj=[System.Environment]::GetEnvironmentVariable("_RDPC_NOTIFY_PROJECT");'
             '$agent=[System.Environment]::GetEnvironmentVariable("_RDPC_NOTIFY_AGENT");'
             '$n.BalloonTipText="项目「$proj」$agent 已启动，手机可发送命令";'
             '$n.Visible=$true;$n.ShowBalloonTip(3000);'
             'Start-Sleep 3;$n.Dispose()}'],
            env=notify_env,
            creationflags=subprocess.CREATE_NO_WINDOW,
        )
    except Exception:
        pass  # 通知非关键，静默吞错误


def do_start(
    project: str,
    agent_type: str = "",
    work_scope: str = "",
    agent_session_id: str = "",
    serein_session_id: str = "",
    agent_session_mode: str = "",
    runtime_mode: str = "cli",
) -> dict:
    """激活指定项目：启动 serein.mjs Relay 模式（若尚未运行）。

    agent_type 指定 AI agent 类型（claude/codex），默认为 claude。
    启动 relay 所需的 SEREIN_BACKEND / SEREIN_HOOK_TOKEN 等
    环境变量从当前 agent 的 os.environ 继承（agent 启动时已设置）。
    显式设置 SEREIN_PROJECT / SEREIN_PROJECT_NAME / SEREIN_AGENT_TYPE。
    """
    if not agent_type:
        agent_type = DEFAULT_AGENT_TYPE
    agent_type = agent_type.strip().lower()
    work_scope = work_scope.strip()
    agent_session_id = agent_session_id.strip()
    serein_session_id = serein_session_id.strip()
    agent_session_mode = agent_session_mode.strip().lower()
    runtime_mode = runtime_mode.strip().lower() or "cli"
    if work_scope and not _WORK_SCOPE_RE.fullmatch(work_scope):
        return {"error": "invalid work scope", "relay_started": False}
    if agent_session_id and not _SESSION_UUID_RE.fullmatch(agent_session_id):
        return {"error": "invalid agent session id", "relay_started": False}
    if serein_session_id and not _SEREIN_SESSION_RE.fullmatch(serein_session_id):
        return {"error": "invalid Serein session id", "relay_started": False}
    if agent_session_mode not in ("", "new", "resume"):
        return {"error": "invalid agent session mode", "relay_started": False}
    if runtime_mode not in ("cli", "desktop"):
        return {"error": "invalid runtime mode", "relay_started": False}
    if not is_supported(agent_type):
        return {
            "error": f"unsupported agent type: {agent_type or '(empty)'}; "
                     f"expected one of: {', '.join(AGENT_TYPES)}",
            "relay_started": False,
        }
    if runtime_mode == "desktop" and agent_type != "codex":
        return {"error": "desktop runtime requires Codex", "relay_started": False}
    agent_config = get_agent_config(agent_type)

    # 直接写文件调试
    try:
        with open(os.path.join(AGENT_DIR, "logs", "relay_debug.log"), "a", encoding="utf-8") as _df:
            _df.write(f"[do_start] ENTERED, project={project}, agent_type={agent_type}\n")
            _df.flush()
    except Exception:
        pass
    proj_path = PROJECT_PATHS.get(project)
    if not proj_path:
        return {"error": f"unknown project: {project}"}

    session_id = find_latest_session(proj_path, agent_type) if runtime_mode == "cli" else None

    # 1) 设置启动中标志，防止 watchdog 在此期间重复 spawn
    #    同时二次检查 relay 是否已启动（TOCTOU 防护）：
    #    在获取锁后重新检查 _is_relay_active()，防止并发调用 do_start()
    #    时第二个线程在第一个线程创建 relay 后仍然通过锁并重复 spawn。
    with _relay_starting_lock:
        global _relay_starting
        if _is_relay_active():
            active_project = ""
            try:
                if os.path.isfile(RELAY_PROJECT_FILE):
                    with open(RELAY_PROJECT_FILE, "r", encoding="utf-8") as f:
                        active_project = f.read().strip()
            except OSError:
                active_project = ""
            active_runtime = _read_relay_runtime()
            if active_project and active_project != project:
                return {
                    "status": "project_busy",
                    "project": project,
                    "active_project": active_project,
                    "relay_started": False,
                    "agent_type": agent_type,
                    "runtime_mode": active_runtime.get("runtime_mode", "cli"),
                }
            if active_runtime and active_runtime.get("runtime_mode") != runtime_mode:
                return {
                    "status": "project_busy",
                    "project": project,
                    "relay_started": False,
                    "agent_type": active_runtime.get("agent_type", agent_type),
                    "runtime_mode": active_runtime.get("runtime_mode", "cli"),
                }
            active_scope = ""
            try:
                if os.path.isfile(RELAY_SCOPE_FILE):
                    with open(RELAY_SCOPE_FILE, "r", encoding="utf-8") as f:
                        active_scope = f.read().strip()
            except OSError:
                active_scope = ""
            if work_scope and active_scope != work_scope:
                return {
                    "status": "project_busy",
                    "project": project,
                    "relay_started": False,
                    "agent_type": agent_type,
                    "work_scope": active_scope,
                }
            with _running_lock:
                running_projects[project] = {
                    "pid": 0,
                    "cmd_line": proj_path,
                    "agent_type": agent_type,
                    "runtime_mode": runtime_mode,
                }
            return {"status": "already_running", "project": project,
                    "session": session_id or "", "relay_started": False,
                    "agent_type": agent_type, "runtime_mode": runtime_mode, "work_scope": work_scope,
                    "agent_session_id": agent_session_id}
        _relay_starting = True

    _safe_stderr(f"[Agent do_start] 调用 _start_relay_process, project={project}, agent_type={agent_type}")
    try:
        proc, error = _start_relay_process(
            proj_path,
            project,
            agent_type,
            work_scope,
            agent_session_id,
            serein_session_id,
            agent_session_mode,
            runtime_mode,
        )
        _safe_stderr(f"[Agent do_start] _start_relay_process 返回, error={error}")
        if error:
            return error

        with _running_lock:
            running_projects[project] = {
                "pid": 0,
                "cmd_line": proj_path,
                "agent_type": agent_type,
                "runtime_mode": runtime_mode,
            }

        runtime_label = "Codex 桌面会话桥接" if runtime_mode == "desktop" else agent_config.display_name + " CLI"
        ctx = "✓ " + project + " 已激活（" + runtime_label + " relay 已在后台运行）"
        if session_id:
            ctx += " · 上次会话: " + session_id[:8]

        _notify_activation(project, agent_config.display_name)

        return {"status": "activated", "project": project,
                "session": session_id or "",
                "relay_started": True,
                "agent_type": agent_type,
                "runtime_mode": runtime_mode,
                "work_scope": work_scope,
                "agent_session_id": agent_session_id,
                "context": ctx}
    finally:
        # 无论成功与否，清除启动中标志，允许 watchdog 后续正常检测
        with _relay_starting_lock:
            _relay_starting = False


def _kill_relay() -> bool:
    """杀掉 relay 进程（serein.mjs），停止 PTY + claude.exe 的自动重启循环。
    使用 /T 标志杀掉整个进程树（node + claude.exe 子进程），
    避免 taskkill /F 只杀 node 导致 claude.exe 变成孤儿进程继续运行。"""
    relay_pid = -1
    try:
        if os.path.isfile(RELAY_PID_FILE):
            with open(RELAY_PID_FILE, "r") as f:
                _pid_str = f.read().strip()
            if _pid_str.isdigit():
                relay_pid = int(_pid_str)
    except Exception:
        pass
    if relay_pid > 0 and pid_alive(relay_pid):
        try:
            # /T = kill process tree (node + child claude.exe)
            # /F = force (node 进程可能不响应优雅终止)
            subprocess.run(['taskkill', '/F', '/T', '/PID', str(relay_pid)],
                           timeout=10, capture_output=True,
                           creationflags=subprocess.CREATE_NO_WINDOW)
            time.sleep(1)
            if not pid_alive(relay_pid):
                _cleanup_stale_relay_pid()
                return True
        except Exception as e:
            _safe_stderr(f"[Agent] _kill_relay 失败: {type(e).__name__}: {e}")
    return False


def _kill_safe(pid: int) -> bool:
    """尝试优雅终止进程，回退到强制 kill。
    使用 taskkill /PID 而非 os.kill(CTRL_BREAK_EVENT)：
    CTRL_BREAK_EVENT 发送到整个进程组，可能误杀其他共享控制台的进程。
    taskkill /PID 精确杀单个进程，不影响其他进程组。"""
    if pid <= 0 or not pid_alive(pid):
        return False
    try:
        # 先尝试优雅终止（无 /F 标志）
        subprocess.run(['taskkill', '/PID', str(pid)],
                       timeout=5, capture_output=True,
                       creationflags=subprocess.CREATE_NO_WINDOW)
        time.sleep(0.5)
        if not pid_alive(pid):
            return True
    except Exception as _e:
        _safe_stderr(f"[Agent] _kill_safe 优雅终止失败: {type(_e).__name__}: {_e}")
    try:
        subprocess.run(['taskkill', '/F', '/PID', str(pid)],
                       timeout=5, capture_output=True,
                       creationflags=subprocess.CREATE_NO_WINDOW)
        time.sleep(0.5)
        return not pid_alive(pid)
    except Exception as _e:
        _safe_stderr(f"[Agent] _kill_safe 强制终止失败: {type(_e).__name__}: {_e}")
    return False


def _read_relay_project() -> str:
    """读取 .relay_project 文件，返回 relay 当前关联的项目名。
    文件不存在或为空时返回空字符串。"""
    try:
        if os.path.isfile(RELAY_PROJECT_FILE):
            with open(RELAY_PROJECT_FILE, "r", encoding="utf-8") as f:
                return f.read().strip()
    except Exception:
        pass
    return ""


def do_stop(project: str) -> dict:
    """停止指定项目的 Claude Code 进程。

    若 relay 模式活跃且关联的正是本项目，则杀掉 serein.mjs 继电器进程
    （切断 PTY 自动重启循环），再回退到直接 kill claude.exe。

    关键修复：只杀 relay 关联项目的进程，不影响其他项目。
    之前 _kill_relay() 无条件杀 relay，导致 stop 项目 A 时误杀了
    relay 正在运行的项目 B 的 claude 进程。
    _scan_all_claude_pids() 兜底更是杀掉了所有项目的 claude，
    现已改为只杀指定项目的 claude 进程。

    关键：先写 quit 标记 + 清 running_projects，再杀 relay。
    之前先杀 relay 再清 running_projects，存在竞态——watchdog 在两者之间
    运行时发现 relay 已死且无 quit 标记，会自动重启 relay 生成新 CMD 窗口。"""
    # 1. 先写 quit 标记：watchdog 检测到此文件后不会自动重启 relay
    try:
        with open(RELAY_QUIT_FILE, 'w') as f:
            f.write(str(os.getpid()))
    except OSError:
        pass

    # 2. 先清 running_projects：watchdog 检测到空列表时直接返回，不重启
    with _running_lock:
        cached = running_projects.get(project)
        cached_pid = cached.get("pid", 0) if cached else 0
        running_projects.pop(project, None)
        # 检查是否还有其他项目在运行
        other_projects_running = len(running_projects) > 0

    # 3. 检查 relay 关联的项目是否正是要停止的项目
    relay_project = _read_relay_project()
    relay_matches = (relay_project == project) or (not relay_project and not other_projects_running)

    # 4. 只在 relay 关联本项目时才杀 relay（否则会误杀其他项目）
    relay_stopped = False
    if relay_matches and _is_relay_active():
        _safe_stderr(f"[Agent do_stop] relay 关联项目={relay_project or '(未知)'}, 停止 relay")
        relay_stopped = _kill_relay()
    elif _is_relay_active():
        _safe_stderr(f"[Agent do_stop] relay 关联项目={relay_project}, 与停止项目={project} 不匹配，不杀 relay")

    # 5. 清理 quit 标记（relay 被 taskkill /F 强杀或未杀时都需要清理）
    try:
        if os.path.isfile(RELAY_QUIT_FILE):
            os.remove(RELAY_QUIT_FILE)
    except OSError:
        pass
    # 只在 relay 被杀时清理项目名标记
    if relay_matches:
        try:
            if os.path.isfile(RELAY_PROJECT_FILE):
                os.remove(RELAY_PROJECT_FILE)
        except OSError:
            pass
        try:
            if os.path.isfile(RELAY_SCOPE_FILE):
                os.remove(RELAY_SCOPE_FILE)
        except OSError:
            pass
        try:
            if os.path.isfile(RELAY_RUNTIME_FILE):
                os.remove(RELAY_RUNTIME_FILE)
        except OSError:
            pass

    # relay 的进程树已被成功终止时，内部 Agent 也随之退出，无需再做一轮
    # WMIC/PowerShell 全盘扫描。旧实现正是在这里让手机长期停留在 Stopping。
    killed = relay_stopped
    if not killed and cached_pid > 0:
        killed = _kill_safe(cached_pid)
    if not killed:
        real = scan_running()
        if project in real:
            killed = _kill_safe(real[project]["pid"])
    if not killed:
        # 补充清理：只杀指定项目的 agent 进程
        proj_path = PROJECT_PATHS.get(project)
        if proj_path:
            try:
                proj_path_lower = proj_path.lower()
                for agent_type in AGENT_TYPES:
                    config = get_agent_config(agent_type)
                    binary = config.binary_name if os.name == 'nt' else config.binary_name_unix
                    entries = _query_agent_processes(binary)
                    for cmd_line, pid_str in entries:
                        if proj_path_lower in cmd_line.lower():
                            pid = int(pid_str)
                            if pid_alive(pid):
                                _kill_safe(pid)
                                killed = True
            except Exception as e:
                _safe_stderr(f"[Agent] do_stop wmic/powershell 扫描失败: {type(e).__name__}: {e}")
    return {"status": "stopped", "project": project, "killed": killed}


def _scan_all_agent_pids() -> list[int]:
    """扫描所有受支持的 agent 进程（含非本项目），按项目路径过滤。
    遍历 AGENT_TYPES 中所有 agent 类型的二进制名。
    仅返回 CommandLine 包含 PROJECT_PATHS 中任一项目路径的进程 PID。
    返回的 PID 按升序排列。"""
    pids: list[int] = []
    proj_paths_lower = [p.lower() for p in PROJECT_PATHS.values()]

    for agent_type in AGENT_TYPES:
        config = get_agent_config(agent_type)
        binary = config.binary_name if os.name == 'nt' else config.binary_name_unix

        entries = _query_agent_processes(binary)

        for cmd_line, pid_str in entries:
            cmd_lower = cmd_line.lower()
            if any(p in cmd_lower for p in proj_paths_lower):
                pids.append(int(pid_str))

    pids.sort()
    return pids


def do_kill_all() -> dict:
    """紧急刹车：杀掉 relay + 所有 claude 进程 + 清空 running_projects 缓存。
    按 PID 精确杀进程，避免 taskkill /IM 无差别杀掉系统上所有 claude.exe。"""
    _safe_stderr("[Agent do_kill_all] emergency kill-all triggered")
    killed_pids: list[int] = []

    # 先杀 relay（切断 claude PTY 自动重启循环）
    if _is_relay_active():
        _kill_relay()

    # 按 PID 精确杀：先扫描本项目的 claude 进程，再逐个 kill
    running = scan_running()
    for proj_name, info in running.items():
        pid = info.get("pid", 0)
        if pid > 0 and pid_alive(pid):
            if _kill_safe(pid):
                killed_pids.append(pid)

    # 补充清理：使用 wmic（回退到 PowerShell）查找残留 claude.exe 进程，
    # 按项目路径过滤，防止误杀其他项目的 claude 进程。
    try:
        for pid in _scan_all_agent_pids():
            if pid not in killed_pids and pid_alive(pid):
                if _kill_safe(pid):
                    killed_pids.append(pid)
    except Exception as e:
        _safe_stderr(f"[Agent do_kill_all] supplementary cleanup failed: {e}")

    with _running_lock:
        running_projects.clear()
    _safe_stderr(f"[Agent do_kill_all] done: killed_pids={killed_pids}")
    return {"status": "killed-all", "killed_pids": killed_pids}


def _is_relay_active() -> bool:
    """检查 relay 模式（serein.mjs PTY + WS）是否在运行。
    同时验证 PID 文件中的进程确实是 node.exe 运行 serein.mjs，
    防止 OS 将旧 PID 回收给其他进程后误判。
    使用 _RELAY_CACHE_TTL 秒缓存减少 tasklist 子进程调用频率。
    此函数为纯 getter，不修改文件系统（PID 文件删除由 _cleanup_stale_relay_pid 负责）。"""
    global _relay_cache
    with _relay_cache_lock:
        cached, cached_at = _relay_cache
    now_cache = time.time()
    if now_cache - cached_at < _RELAY_CACHE_TTL:
        return cached
    if not os.path.isfile(RELAY_PID_FILE):
        with _relay_cache_lock:
            _relay_cache = (False, now_cache)
        return False
    try:
        with open(RELAY_PID_FILE, "r") as f:
            pid_str = f.read().strip()
        if not pid_str or not pid_str.isdigit():
            with _relay_cache_lock:
                _relay_cache = (False, now_cache)
            return False
        pid = int(pid_str)
        if pid <= 0:
            with _relay_cache_lock:
                _relay_cache = (False, now_cache)
            return False
        if not pid_alive(pid):
            # 不在此删除 PID 文件：由 _cleanup_stale_relay_pid 或外部逻辑处理
            with _relay_cache_lock:
                _relay_cache = (False, now_cache)
            return False
        result = False
        if psutil is not None:
            try:
                result = psutil.Process(pid).name().lower() == 'node.exe'
            except (psutil.AccessDenied, psutil.NoSuchProcess, psutil.ZombieProcess):
                result = False
        else:
            # 兼容未安装 psutil 的公开环境。
            out = subprocess.run(
                ['tasklist', '/FI', f'PID eq {pid}', '/FO', 'CSV', '/NH'],
                capture_output=True, timeout=5, text=True,
                creationflags=subprocess.CREATE_NO_WINDOW
            ).stdout.strip()
            if out:
                try:
                    reader = csv.reader(io.StringIO(out))
                    for row in reader:
                        if row and row[0].strip('"').lower() == 'node.exe':
                            result = True
                            break
                except Exception:
                    pass
        with _relay_cache_lock:
            _relay_cache = (result, now_cache)
        return result
    except Exception as _re:
        _safe_stderr(f"[Agent] _is_relay_active 异常: {type(_re).__name__}: {_re}")
    with _relay_cache_lock:
        _relay_cache = (False, now_cache)
    return False


def is_relay_starting() -> bool:
    """返回 relay 是否正在启动中（do_start 执行期间）。
    供 watchdog 使用，防止在 do_start 执行期间重复 spawn。"""
    with _relay_starting_lock:
        return _relay_starting


def do_file_write(project: str, file_name: str, file_data_b64: str) -> dict:
    """手机上传文件写入项目目录（Relay 模式）。

    file_data_b64 是 Base64 编码的文件内容。
    写入 PROJECT_PATHS[project]/uploads/ 目录下。
    确保路径在项目目录内（防路径穿越）。
    """
    proj_path = PROJECT_PATHS.get(project)
    if not proj_path:
        # 动态重新加载项目列表：relay 可能在 agent 启动后才注册新项目
        _load_dynamic_projects()
        proj_path = PROJECT_PATHS.get(project)
    if not proj_path:
        return {"error": f"unknown project: {project}"}

    # 清理文件名：只保留 basename，防止路径穿越
    safe_name = os.path.basename(file_name.replace("\\", "/"))
    if not safe_name:
        return {"error": "invalid file name: empty after sanitization"}

    # 路径穿越防护：确保目标路径在项目目录内
    upload_dir = os.path.join(proj_path, "uploads")
    dest_path = os.path.realpath(os.path.join(upload_dir, safe_name))
    proj_real = os.path.realpath(proj_path)
    if not dest_path.startswith(proj_real + os.sep) and dest_path != proj_real:
        return {"error": "path traversal detected"}

    # 解码 base64
    try:
        decoded = base64.b64decode(file_data_b64)
    except Exception as e:
        return {"error": f"base64 decode failed: {e}"}

    # 限制大小 10MB
    if len(decoded) > 10 * 1024 * 1024:
        return {"error": "file too large (max 10MB)"}

    # 确保 uploads 目录存在
    try:
        os.makedirs(upload_dir, exist_ok=True)
    except OSError as e:
        return {"error": f"mkdir failed: {e}"}

    # 写入文件
    try:
        with open(dest_path, "wb") as f:
            f.write(decoded)
    except OSError as e:
        return {"error": f"write failed: {e}"}

    _safe_stderr(f"[Agent] file_write: {safe_name} -> {dest_path} ({len(decoded)} bytes)")
    return {
        "ok": True,
        "path": dest_path,
        "filename": safe_name,
        "project": project,
    }


def _cleanup_stale_relay_pid() -> None:
    """清理过期的 relay PID 文件。
    由 _kill_relay / do_kill_all 等需要实际清理的场景调用，
    不作为 _is_relay_active 的副作用。"""
    global _relay_cache
    try:
        if os.path.isfile(RELAY_PID_FILE):
            os.remove(RELAY_PID_FILE)
            with _relay_cache_lock:
                _relay_cache = (False, 0.0)
    except OSError:
        pass
    # 同步清理项目名文件
    try:
        if os.path.isfile(RELAY_PROJECT_FILE):
            os.remove(RELAY_PROJECT_FILE)
    except OSError:
        pass
    try:
        if os.path.isfile(RELAY_SCOPE_FILE):
            os.remove(RELAY_SCOPE_FILE)
    except OSError:
        pass
