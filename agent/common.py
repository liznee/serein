#!/usr/bin/env python3
"""serein 共享模块：配置、网络请求、输出脱敏等基础功能。
提取自 local_agent.py，供 sysinfo.py 和其他模块共用。
"""
import os, sys, json, time, re, shutil, threading, urllib.request
from types import MappingProxyType

# 不在模块级清理代理环境变量——将其移至 http_req 函数内部，按需清理。
# 模块级清理有副作用：干扰其他可能依赖代理的模块（如子进程中的 git/npm）。
# http_req 内部在发送 HTTP 请求前清理代理，确保直连后端的同时不破坏其他模块。

# 用户主目录——SYSTEM 服务账户的 ~ 是 systemprofile，需指定真实用户目录。
# 优先读 RDP_USER_HOME 环境变量，否则用 expanduser（交互运行时正常）。
USER_HOME = os.environ.get("RDP_USER_HOME", "")
if not USER_HOME:
    USER_HOME = os.path.expanduser("~")
# Token 安全校验：只允许字母数字 + 连字符/下划线/点，拦截 CRLF 注入
_VALID_TOKEN_RE = re.compile(r'^[a-zA-Z0-9._\-]+$')

def _load_server() -> str:
    """优先读环境变量 SEREIN_BACKEND，否则从 ~/.claude/settings.json 的 env 段回退读取。

    这样 VBS 守护脚本直接启动 pythonw.exe local_agent.py 时无需预先设置系统环境变量——
    serein.bat 会设置 SEREIN_BACKEND 环境变量（优先级最高），
    而 VBS 守护脚本启动时则从 settings.json 回退读取。
    """
    val = os.environ.get("SEREIN_BACKEND")
    if val:
        return val
    try:
        settings_path = os.path.join(USER_HOME, ".claude", "settings.json")
        with open(settings_path, "r", encoding="utf-8-sig") as f:
            data = json.load(f)
        env = data.get("env") or {}
        val = env.get("SEREIN_BACKEND")
        if val:
            return val
    except Exception:
        pass  # 无 settings.json 或解析失败时静默降级，由 require_server() 报错
    return ""


SERVER = _load_server()
# Write back to os.environ so child processes (relay/serein.mjs) inherit these.
# When agent is started by VBS watchdog (not serein.bat), os.environ doesn't
# have SEREIN_BACKEND — it was loaded from ~/.claude/settings.json above.
if SERVER and not os.environ.get("SEREIN_BACKEND"):
    os.environ["SEREIN_BACKEND"] = SERVER


def _load_settings_env() -> None:
    """Load all env vars from ~/.claude/settings.json into os.environ.

    Only sets variables that are not already present in os.environ, so
    explicitly-set environment variables always win. This lets the VBS
    watchdog start the agent without pre-setting every env var — any key
    in settings.json's "env" object is picked up automatically.
    """
    try:
        settings_path = os.path.join(USER_HOME, ".claude", "settings.json")
        with open(settings_path, "r", encoding="utf-8-sig") as f:
            data = json.load(f)
        env = data.get("env") or {}
        if not isinstance(env, dict):
            return
        for key, value in env.items():
            if not isinstance(key, str) or not isinstance(value, str):
                continue
            if key not in os.environ:
                os.environ[key] = value
    except Exception:
        pass


# Load all settings.json env vars (e.g. SEREIN_REMOTE_HOST_ENABLE) into
# os.environ so modules like RemoteHostManager can read them via os.environ.get.
_load_settings_env()


def require_server() -> str:
    """返回后端地址，若未设置则抛出 RuntimeError（运行时校验，避免模块级 import 时误杀）。

    调用时机：仅在真正需要 SERVER 值的函数中调用（http_req、report_step），
    不阻塞仅引用 HOOK_TOKEN / USER_HOME 的模块。
    """
    if not SERVER:
        raise RuntimeError("SEREIN_BACKEND 未设置（环境变量或 ~/.claude/settings.json），无法连接后端")
    return SERVER.rstrip('/')


def _load_hook_token() -> str:
    """优先读环境变量，否则从 ~/.claude/settings.json 的 env.SEREIN_HOOK_TOKEN 读。
    拒绝使用源码内硬编码默认值——token 必须来自用户配置。"""
    token = os.environ.get("SEREIN_HOOK_TOKEN")
    if token:
        return token
    try:
        settings_path = os.path.join(USER_HOME, ".claude", "settings.json")
        with open(settings_path, "r", encoding="utf-8-sig") as f:
            data = json.load(f)
        env = data.get("env") or {}
        token = env.get("SEREIN_HOOK_TOKEN")
        if token:
            return token
    except FileNotFoundError:
        pass  # 无 settings.json 是正常状态，静默降级
    except json.JSONDecodeError as e:
        _safe_stderr(f"[Agent] settings.json 解析失败（JSON 格式错误）: {e}")
    except OSError as e:
        _safe_stderr(f"[Agent] 读取 settings.json 失败（IO/权限错误）: {e}")
    except Exception as e:
        _safe_stderr(f"[Agent] 读取 settings.json 未知错误: {type(e).__name__}: {e}")
    return ""


HOOK_TOKEN = _load_hook_token()
# Same as SERVER: write back to os.environ for child process inheritance.
if HOOK_TOKEN and not os.environ.get("SEREIN_HOOK_TOKEN"):
    os.environ["SEREIN_HOOK_TOKEN"] = HOOK_TOKEN


def _load_agent_proxy() -> str:
    """Load the optional proxy used only by spawned AI agent processes."""
    value = os.environ.get("SEREIN_AGENT_PROXY")
    if value:
        return value
    try:
        settings_path = os.path.join(USER_HOME, ".claude", "settings.json")
        with open(settings_path, "r", encoding="utf-8-sig") as f:
            data = json.load(f)
        value = (data.get("env") or {}).get("SEREIN_AGENT_PROXY")
        if isinstance(value, str):
            return value.strip()
    except Exception:
        pass
    return ""


AGENT_PROXY = _load_agent_proxy()
if AGENT_PROXY and not os.environ.get("SEREIN_AGENT_PROXY"):
    os.environ["SEREIN_AGENT_PROXY"] = AGENT_PROXY

CLAUDE_EXE = shutil.which("claude.exe")
if not CLAUDE_EXE:
    # 源码泄露场景下避免暴露用户名，用空字符串强制通过环境变量配置
    CLAUDE_EXE = ""

PYTHON = os.environ.get("SEREIN_PYTHON", "")
if not PYTHON:
    PYTHON = shutil.which("python")
if not PYTHON:
    PYTHON = ""  # 源码泄露场景下避免暴露用户名

# AGENT_DIR: 本文件所在目录（agent/），用于定位 local_agent.py 等代理文件
_AGENT_DIR = os.path.dirname(os.path.abspath(__file__))
AGENT_PY = os.environ.get("SEREIN_AGENT_PY", "")
if not AGENT_PY:
    AGENT_PY = os.path.join(_AGENT_DIR, "local_agent.py")
AGENT_DIR = _AGENT_DIR

# 项目路径字典 — 从 ~/.serein/projects.json 动态加载。
# serein 命令启动时自动注册项目到该文件，无需手动配置。
# 使用 MappingProxyType 包装为只读，防止导入方意外修改。
_PROJECT_PATHS_DATA: dict[str, str] = {}
_PROJECT_NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


def register_runtime_project(name: str, path: str) -> bool:
    """Register a locally discovered project for this Agent process only.

    Desktop session discovery uses this to expose a real local cwd without
    rewriting the user's ``projects.json``. Name collisions are rejected.
    """
    if not isinstance(name, str) or not _PROJECT_NAME_RE.fullmatch(name):
        return False
    if not isinstance(path, str) or not path or not os.path.isdir(path):
        return False
    normalized = os.path.normcase(os.path.abspath(path.rstrip("\\/")))
    existing = _PROJECT_PATHS_DATA.get(name)
    if existing:
        return os.path.normcase(os.path.abspath(existing.rstrip("\\/"))) == normalized
    for known_path in _PROJECT_PATHS_DATA.values():
        if os.path.normcase(os.path.abspath(known_path.rstrip("\\/"))) == normalized:
            return False
    _PROJECT_PATHS_DATA[name] = path
    return True


def _load_dynamic_projects() -> None:
    """从 ~/.serein/projects.json 加载动态注册的项目路径。

    serein.mjs 启动新项目时写入此文件，使 agent (local_agent.py) 能发现
    非硬编码的项目并上报到 /agent/projects。每次 do_status() 调用时重新加载，
    确保新注册的项目及时被手机端看到。
    """
    try:
        projects_file = os.path.join(USER_HOME, ".serein", "projects.json")
        with open(projects_file, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict):
            for name, path in data.items():
                if name not in _PROJECT_PATHS_DATA and isinstance(path, str):
                    _PROJECT_PATHS_DATA[name] = path
    except (FileNotFoundError, json.JSONDecodeError):
        pass
    except Exception as e:
        _safe_stderr(f"[Agent] 加载动态项目文件未知错误: {type(e).__name__}: {e}")


_load_dynamic_projects()
PROJECT_PATHS = MappingProxyType(_PROJECT_PATHS_DATA)

# ── 安全命令白名单（与 agent_exec.py / agent_shell_chain.py 共享，消除循环导入）──
# "exe" = 外部可执行文件，以 [exe_path, ...args] 列表形式运行
# "cmd_builtin" = 纯 Python 内置命令实现
_EXEC_WHITELIST: MappingProxyType[str, tuple[str, str | None]] = MappingProxyType({
    # 开发工具
    "git":   ("exe", "git"),
    "npm":   ("exe", "npm"),
    # npx 已从白名单移除（见 agent_exec.py 注释）
    "go":    ("exe", "go"),
    "pip":   ("exe", "pip.exe"),
    "node":  ("exe", "node"),
    "ncu":   ("exe", "ncu"),
    # 常用系统工具
    "curl":  ("exe", "curl"),
    "where": ("exe", "where.exe"),
    "tasklist": ("exe", "tasklist"),
    "whoami": ("exe", "whoami"),
    "find":  ("exe", "find"),
    "sort":  ("exe", "sort"),
    # cmd 内置命令（纯 Python 实现）
    "dir":   ("cmd_builtin", None),
    "ls":    ("cmd_builtin", None),
    "echo":  ("cmd_builtin", None),
    "type":  ("cmd_builtin", None),
    "cat":   ("cmd_builtin", None),
    "cd":    ("cmd_builtin", None),
    "pwd":   ("cmd_builtin", None),
    "cls":   ("cmd_builtin", None),
    "clear": ("cmd_builtin", None),
})

# ── PATH 缓存：模块加载时将所有 exe 类型命令解析为绝对路径 ──
# 由 agent_exec 的 _resolve_whitelist_paths() 在模块加载时填充。
_EXEC_PATH_CACHE: dict[str, str] = {}

# 代理环境变量保护锁：_report_retry 的 daemon 线程与主循环心跳可能并发调用 http_req，
# 两者都 pop/restore 代理环境变量。使用此锁保护 save/restore 逻辑，防止线程切入时
# 用空值覆盖已恢复的代理变量，导致子进程（git/npm）暂时失去代理连接。
_proxy_lock = threading.Lock()


def http_req(
    method: str,
    path: str,
    body: dict | None = None,
    timeout: int = 35,
    *,
    auth_token: str | None = None,
) -> dict:
    # 发送 HTTP 请求前临时清理代理环境变量，确保直连后端避免 Clash TUN/系统代理拦截导致 SSL 握手超时。
    # 请求完成后恢复原始代理环境变量，不影响子进程（git/npm 等仍需代理访问外网）。
    # 之前使用 os.environ.pop() 导致代理被永久删除，破坏后续子进程的网络访问。
    with _proxy_lock:
        _saved_proxy: dict[str, str] = {}
        for _p in ("http_proxy", "https_proxy", "all_proxy",
                   "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"):
            try:
                _v = os.environ.pop(_p, None)
                if _v is not None:
                    _saved_proxy[_p] = _v
            except KeyError:
                pass
    try:
        url = f"{require_server()}{path}"
        data = json.dumps(body).encode("utf-8") if body else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Content-Type", "application/json")
        token = HOOK_TOKEN if auth_token is None else auth_token
        if token:
            if not _VALID_TOKEN_RE.fullmatch(token):
                raise ValueError("invalid authorization token format")
            req.add_header("Authorization", f"Bearer {token}")
        req.add_header("User-Agent", "serein-agent/1.0")
        proxy_handler = urllib.request.ProxyHandler({})
        opener = urllib.request.build_opener(proxy_handler)
        with opener.open(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw.strip() else {}
    finally:
        # 恢复代理环境变量，确保子进程（git/npm 等）仍可正常使用代理访问外网
        # 与 save 共用同一锁，防止 daemon 线程和主循环并发操作代理环境变量
        with _proxy_lock:
            os.environ.update(_saved_proxy)


def _sanitize_stderr(text: str) -> str:
    """对 stderr 文本做敏感信息脱敏，防止文件路径、用户名、IP 地址泄漏到后端。

    脱敏项：
    - 用户主目录路径 → <REDACTED_PATH>
    - 用户名 → <REDACTED_USER>
    - IP 地址 → <REDACTED_IP>

    脱敏策略偏保守：宁可误脱敏（"误报"）不可漏脱敏（信息泄漏）。
    路径正则 [a-zA-Z]:\\[^\\s:;*?"<>|]{1,200} 覆盖面较广，可能匹配到非敏感路径
    （如编译错误中的示例路径），但在 CI/日志遥测场景中，保守安全优于调试便利。
    """
    if not text:
        return ""
    # 1. 替换用户目录路径（仅匹配 Users/ProgramData 等敏感前缀，避免误伤项目路径）
    text = re.sub(r'(?i)[a-zA-Z]:\\(?:Users|ProgramData|Documents and Settings)\\[^\s:;*?"<>|]{1,200}', '<REDACTED_PATH>', text)
    # 2. 替换用户名路径（Users/xxx 或 /home/xxx 等，作为步骤 1 的补充）
    text = re.sub(r'(?i)(?:Users\\|/home/|/Users/)[^\s\\/:*?"<>|]{1,50}', '<REDACTED_USER>', text)
    # 3. 替换 IP 地址（0-255 范围校验，防止 999.999.999.999 等非法 IP 被误替换）
    text = re.sub(r'\b(?:(?:25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)\b', '<REDACTED_IP>', text)
    return text


def _sanitize_stdout(text: str) -> str:
    """对 stdout 文本做敏感信息脱敏，复用 _sanitize_stderr 的规则。
    stdout 可能包含路径/IP/用户名等泄漏到后端日志，需与 stderr 同等处理。
    """
    return _sanitize_stderr(text)


def _safe_stderr(msg: str) -> None:
    """脱敏后输出到 stderr。所有 agent 日志应使用此函数而非直接 print(file=sys.stderr)。"""
    print(_sanitize_stderr(str(msg)), file=sys.stderr, flush=True)


# 验证用户主目录下 .claude 目录存在（使用 _safe_stderr 避免模块级 print 暴露路径）
if not os.path.isdir(os.path.join(USER_HOME, ".claude")):
    _safe_stderr(f"[Agent] 警告: ~/.claude 目录未找到于: {USER_HOME}。请设置 RDP_USER_HOME 环境变量指向正确的用户主目录。")


# 模型单价表（元 / 百万 token）：input / output / cache_read
# 价格为公开 API 大致费率，仅作估算。
_MODEL_PRICING_CNY: dict[str, tuple[float, float, float]] = {
    "glm-5.2": (0.5, 1.5, 0.05),
    "glm-4.6": (0.5, 1.5, 0.05),
    "glm-4.5": (0.5, 1.5, 0.05),
    "deepseek-v4-pro": (0.5, 3.0, 0.1),
    "deepseek": (0.5, 3.0, 0.1),
    "claude-sonnet-4-6": (22, 84, 2.2),
    "claude-sonnet-4-5": (22, 84, 2.2),
    "claude-opus-4-8": (55, 220, 5.5),
    "claude-haiku-4-5": (5, 25, 0.5),
}
_DEFAULT_PRICE_CNY: tuple[float, float, float] = (1.0, 3.0, 0.1)


def estimate_cost_cny(model: str, inp: int, out: int, cache: int) -> float:
    """按模型单价估算单条消息成本（元）。"""
    price = _DEFAULT_PRICE_CNY
    m = model.lower()
    for k, v in _MODEL_PRICING_CNY.items():
        if m.startswith(k):
            price = v
            break
    return (inp / 1_000_000 * price[0]
            + out / 1_000_000 * price[1]
            + cache / 1_000_000 * price[2])
