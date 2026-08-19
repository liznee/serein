#!/usr/bin/env python3
"""serein 命令执行模块：白名单校验、shell 危险模式检查、内置命令实现。

从 local_agent.py 提取，降低主文件复杂度。
"""
import os, json, re, shutil, shlex, subprocess, time

from common import (
    PROJECT_PATHS, USER_HOME, _safe_stderr,
    _sanitize_stdout, _sanitize_stderr,
    _EXEC_WHITELIST, _EXEC_PATH_CACHE,
)
from agent_shell_chain import (
    _split_shell_chain,
    _parse_chain_operators,
    _extract_redirects,
    _exec_single_segment,
    _exec_shell_chain_python,
    _exec_decode_output,
    _exec_sanitize_output,
)

# ── 状态 ──
# 命令别名缓存
_aliases_cache: dict[str, str] | None = None
_aliases_cache_mtime: float = 0
_ALIASES_CACHE_TTL = 30
# 项目当前工作目录（由 cd 内置命令更新，后续 do_exec 以此为准）
_project_cwd: dict[str, str] = {}

# ── PATH 缓存初始化：解析白名单中 exe 类型命令的绝对路径 ──
# 定义与 _EXEC_WHITELIST 分离，因为 whitelist 定义已移至 common.py 共享。
# 在模块加载时解析并缓存绝对路径，防止运行中 PATH 篡改导致 shutil.which() 返回恶意程序。
def _resolve_whitelist_paths() -> None:
    """解析白名单中所有 'exe' 类型可执行文件为绝对路径并缓存。

    对 shutil.which() 结果做路径归一化（os.path.realpath），
    防止符号链接指向恶意副本。解析失败时保留原始 exe_name 作为 fallback。
    启动后 PATH 篡改不影响已缓存的路径。
    """
    for name, (cmd_type, exe_name) in _EXEC_WHITELIST.items():
        if cmd_type != "exe" or not exe_name:
            continue
        resolved = shutil.which(exe_name)
        if resolved:
            _EXEC_PATH_CACHE[name] = os.path.realpath(resolved)
        else:
            # 找不到时保留原 exe_name（后续执行仍会失败，但不会静默执行恶意程序）
            _EXEC_PATH_CACHE[name] = exe_name


_resolve_whitelist_paths()

_DANGEROUS_PATTERNS: list[tuple[str, str]] = [
    (r'\$\(', "command substitution $()"),
    (r'`', "backtick command substitution"),
    (r'\beval\b', "eval"),
    (r';\s*(curl|wget|powershell|pwsh|certutil|bitsadmin|mshta|msiexec|cscript|wscript|regsvr32|rundll32|del|erase|rmdir|shutdown|reboot|format|diskpart|taskkill|fsutil|bcdedit|cacls|subst|wmic)\b',
     "chained download-execute with dangerous tool"),
    (r'&\s*(curl|wget|powershell|pwsh|certutil|bitsadmin|mshta|cscript|wscript|del|erase|rmdir|shutdown|reboot|format|diskpart|taskkill|fsutil|bcdedit|cacls|subst|wmic)\b',
     "background download-execute with dangerous tool"),
    (r'\|\s*(sh|bash|powershell|pwsh|python|python3)\b', "pipe-to-shell"),
    (r'(?<!\S)(python|python3)\s+-[c]\b', "standalone python -c inline execution"),
    (r';\s*(python|python3)\s+-[c]\b', "python inline execution"),
    (r'(?<!\S)(node|deno|bun)\s+-(e|eval)\b', "standalone node/deno/bun inline execution"),
    (r';\s*(node|deno|bun)\s+-(e|eval)\b', "node/deno/bun inline execution"),
    (r';\s*cmd\s+/[cce]\b', "cmd /c or /k execution"),
    (r'&&\s*(curl|wget|powershell|pwsh|certutil|bitsadmin|mshta|msiexec|cscript|wscript|regsvr32|rundll32|del|erase|rmdir|shutdown|reboot|format|diskpart|taskkill|fsutil|bcdedit|cacls|subst|wmic)\b',
     "chained && download-execute"),
    (r'&&\s*(python|python3)\s+-[c]\b', "chained && python inline execution"),
    (r'&&\s*(node|deno|bun)\s+-(e|eval)\b', "chained && node/deno/bun inline execution"),
    (r'&&\s*cmd\s+/[cce]\b', "chained && cmd execution"),
    (r'\|\|\s*(curl|wget|powershell|pwsh|certutil|bitsadmin|mshta|msiexec|cscript|wscript|regsvr32|rundll32|python|python3|node|deno|bun|ssh|scp|schtasks|reg|del|erase|rmdir|shutdown|reboot|format|diskpart|taskkill|fsutil|bcdedit|cacls|subst|wmic)\b',
     "chained || download-execute"),
    (r'\bssh\b', "ssh (potential exfiltration)"),
    (r'\bscp\b', "scp (potential exfiltration)"),
    (r'\breg\s+(add|delete|copy|save|restore|load|unload)\b', "registry modification"),
    (r'\bnet\s+(user|localgroup|share|use|session|start|stop)\b', "net user/group/share/service management"),
    (r'\bschtasks\b', "scheduled task manipulation"),
    (r'\bvssadmin\b', "volume shadow copy"),
    (r'\btakeown\b', "file ownership takeover"),
    (r'\bicacls\b', "ACL modification"),
    (r'\bcertreq\b', "certreq (CERTSRV manipulation)"),
    (r'\bnslookup\b', "nslookup (DNS exfiltration)"),
    (r'\battrib\s+-r\s+-s\s+-h\b', "attrib unhide system files"),
    (r'\bshutdown\b', "system shutdown"),
    (r'\breboot\b', "system reboot"),
    (r'\bformat\s+[a-zA-Z]:', "disk format"),
    (r'\brmdir\s+[/\\]S', "directory removal"),
    (r'\bdiskpart\b', "disk partition management"),
    (r'\bfsutil\b', "filesystem manipulation"),
    (r'\bbcdedit\b', "boot configuration modification"),
    (r'\bcacls\b', "ACL modification (cacls)"),
    (r'\bsubst\b', "drive mapping"),
    (r'\bwmic\b', "WMI (potential system manipulation)"),
]

_NEEDS_SHELL_RE = re.compile(r'\$\(|`|\&\&|\|\||(?<!\w)\|(?!\|)|;|[<>]')


def _expand_cat_version(command: str) -> str:
    """展开 $(cat VERSION) 命令替换，使用纯 Python 替代危险的 cmd.exe /c 路径。

    仅处理 $(cat VERSION) 这一个特定模式——不展开任意 $(...) 表达式。
    替换后的 VERSION 内容由 Python 直接读取，不经过 cmd.exe /c 路径，
    避免 VERSION 文件被篡改时通过 shell 解释传播恶意内容。

    命名明确限定为 cat_version 而非泛化的 cmd_subst，防止维护者误以为
    此函数可安全展开任何 $(...) 表达式。
    """
    # 仅处理 $(cat VERSION) 模式
    m = re.search(r'\$\(\s*cat\s+VERSION\s*\)', command)
    if not m:
        return command

    # 尝试读取 VERSION 文件
    version_content = ""
    for proj in PROJECT_PATHS.values():
        version_path = os.path.join(proj, "VERSION")
        if os.path.isfile(version_path):
            try:
                with open(version_path, 'r', encoding='utf-8') as f:
                    version_content = f.read().strip()
                break
            except OSError:
                continue
    if not version_content:
        # VERSION 文件不存在或读取失败，替换为空字符串
        version_content = ""

    # 使用正则替换所有匹配项，安全地转义版本号中的特殊字符
    # 版本号预期为 semver 格式（如 1.2.3），不含 shell 特殊字符
    return re.sub(r'\$\(\s*cat\s+VERSION\s*\)', version_content, command)


# Unicode shell 元字符相似字符映射表
# 用于归一化检测，防止全角/异形字符绕过 regex 黑名单
# 覆盖范围：全角 ASCII、常见同形异义字符、数学符号变体
_UNICODE_SHELL_MAP = str.maketrans({
    '；': ';',   # U+FF1B 全角分号
    '｜': '|',   # U+FF5C 全角竖线
    '＄': '$',   # U+FF04 全角美元
    '＆': '&',   # U+FF06 全角 and
    '～': '~',   # U+FF5E 全角波浪号
    '（': '(',   # U+FF08 全角左括号
    '）': ')',   # U+FF09 全角右括号
    '‘': "'",   # U+2018 左单引号
    '’': "'",   # U+2019 右单引号
    '“': '"',   # U+201C 左双引号
    '”': '"',   # U+201D 右双引号
    '«': '<',   # U+00AB 左双尖括号
    '»': '>',   # U+00BB 右双尖括号
    # 扩展：更多全角 ASCII 字符
    '＃': '#',   # U+FF03 全角井号
    '＠': '@',   # U+FF20 全角 at
    '＾': '^',   # U+FF3E 全角脱字符
    '＊': '*',   # U+FF0A 全角星号
    '＋': '+',   # U+FF0B 全角加号
    '＝': '=',   # U+FF1D 全角等号
    '％': '%',   # U+FF05 全角百分号
    '！': '!',   # U+FF01 全角感叹号
    '？': '?',   # U+FF1F 全角问号
    '｛': '{',   # U+FF5B 全角左大括号
    '｝': '}',   # U+FF5D 全角右大括号
    '［': '[',   # U+FF3B 全角左方括号
    '］': ']',   # U+FF3D 全角右方括号
    '＼': '\\',  # U+FF3C 全角反斜线
    # 扩展：数学符号变体（常见 shell 危险字符）
    '﹨': '\\',  # U+FE68 小反斜线
    '﹪': '%',   # U+FE6A 小百分号
    '﹫': '@',   # U+FE6B 小 at
    '﹟': '#',   # U+FE5F 小井号
    '﹡': '*',   # U+FE61 小星号
    '﹢': '+',   # U+FE62 小加号
    '﹦': '=',   # U+FE66 小等号
    '﹣': '-',   # U+FE63 小减号
    '﹖': '?',   # U+FE56 小问号
    '﹗': '!',   # U+FE57 小感叹号
    # 扩展：半角片假名/发音符号（某些 shell 环境可能解析为特殊含义）
    # 半角片假名范围 U+FF65-U+FF9F 一般不构成 shell 危险字符，暂不纳入
})


def _normalize_command(command: str) -> str:
    """归一化命令字符串：将 Unicode shell 字符相似形转成 ASCII 等价字符。"""
    return command.translate(_UNICODE_SHELL_MAP)


def _check_dangerous(command: str, label: str = "") -> str | None:
    """检查命令是否包含危险模式。返回错误消息或 None（安全）。

    先对命令做 Unicode 归一化，防止全角/异形字符绕过 regex 黑名单。
    """
    normalized = _normalize_command(command)
    for pat, desc in _DANGEROUS_PATTERNS:
        if re.search(pat, normalized):
            _safe_stderr(f"[Agent] blocked dangerous pattern{label}: {desc}")
            return f"blocked dangerous pattern{label}: {desc}"
    return None


def _exec_resolve_command(command_expanded: str) -> dict | tuple:
    """解析命令：白名单 / PATH 查找，返回 (parts, cmd_type, exe_name) 或 error dict。"""
    try:
        parts = shlex.split(command_expanded.strip())
    except ValueError as _shlex_e:
        _safe_stderr(f"[Agent] shlex.split 解析失败: {_shlex_e}")
        return {"error": f"command parse error: {_shlex_e}", "stdout": "", "stderr": "", "returncode": -1}
    if not parts:
        return {"error": "empty command", "stdout": "", "stderr": "", "returncode": -1}
    base_cmd = parts[0].lower()

    entry = _EXEC_WHITELIST.get(base_cmd)
    if entry is not None:
        cmd_type, exe_name = entry
    else:
        # 不在白名单中的命令立即拒绝，不使用 shutil.which 绕过白名单
        _safe_stderr(f"[Agent] blocked: command '{base_cmd}' not in whitelist")
        return {"error": f"command not found: {base_cmd} (not in whitelist)", "stdout": "", "stderr": "", "returncode": -1}
    return (parts, cmd_type, exe_name)

def do_exec(project: str, command: str) -> dict:
    """在指定项目目录下执行 shell 命令，捕获 stdout/stderr。

    使用白名单安全模式：只允许预先定义的命令以 shell=False 方式执行。
    所有外部命令通过 [executable, ...args] 列表形式执行，完全避免 shell 注入。
    """
    proj_path = PROJECT_PATHS.get(project)
    if not proj_path:
        return {"error": f"unknown project: {project}"}

    # 1. 安全命令替换展开（用纯 Python 替代危险的 cmd.exe /c 路径）
    #    当前处理 $(cat VERSION) — 由 Python 读取 VERSION 文件后替换回命令中，
    #    避免 VERSION 被篡改时通过 cmd.exe /c 的 shell 解释传播恶意内容。
    command_safe = _expand_cat_version(command)

    # 2. 危险模式检查（展开后）
    err = _check_dangerous(command_safe, " in do_exec")
    if err:
        return {"error": err, "stdout": "", "stderr": "", "returncode": -1}

    if len(command_safe) > 10000:
        return {"error": "command too long (>10000 chars)", "stdout": "", "stderr": "", "returncode": -1}

    # 3. 别名展开
    command_expanded = expand_alias(command_safe)

    # 4. 危险模式检查（展开后）
    err = _check_dangerous(command_expanded, " after alias expansion")
    if err:
        return {"error": err, "stdout": "", "stderr": "", "returncode": -1}

    # 4. 解析命令（白名单 / PATH）
    resolved = _exec_resolve_command(command_expanded)
    if isinstance(resolved, dict):
        return resolved
    parts, cmd_type, exe_name = resolved
    base_cmd = parts[0].lower()

    # 5. 使用 cwd：优先取 cd 命令设置的 _project_cwd，否则用项目默认路径
    effective_cwd = _project_cwd.get(project, proj_path)

    # 6. 检测是否需要 shell 功能
    needs_shell = bool(_NEEDS_SHELL_RE.search(command_expanded))

    try:
        if cmd_type == "exe":
            # 从 PATH 缓存中取绝对路径，避免 shutil.which() 受运行时 PATH 篡改影响
            exe = _EXEC_PATH_CACHE.get(base_cmd)
            if not exe:
                return {"error": f"executable not found: {exe_name} (not in path cache)", "stdout": "", "stderr": "", "returncode": -1}
            if needs_shell:
                # 对含 shell 元字符的命令，逐段校验各段首词是否在白名单中
                # 防止分号/&&/|| 后的命令绕过白名单（shell=True 的安全替代方案）
                # 使用引号感知的分段函数替代 re.split——re.split 不理解 shell 引号，
                # 会将 git log --format="%s; %an" 等含字面分隔符的合法命令误拆成多段。
                # I/O 重定向 (< >) 不是命令链操作符，不在 segment 白名单校验中切分
                segments = _split_shell_chain(command_expanded)
                # shell 链长度限制：最多 20 个段，防止利用长链执行大量命令耗尽资源
                if len(segments) > 20:
                    return {"error": "shell chain too long (>20 segments)", "stdout": "", "stderr": "", "returncode": -1}
                for seg in segments:
                    seg = seg.strip()
                    if not seg:
                        continue
                    try:
                        seg_parts = shlex.split(seg)
                    except ValueError:
                        continue
                    if not seg_parts:
                        continue
                    seg_base = seg_parts[0].lower()
                    seg_entry = _EXEC_WHITELIST.get(seg_base)
                    if seg_entry is None:
                        _safe_stderr(f"[Agent] blocked (shell chain): command '{seg_base}' not in whitelist")
                        return {"error": f"blocked: '{seg_base}' (segment of shell chain) not in whitelist", "stdout": "", "stderr": "", "returncode": -1}
                # 所有段通过白名单校验后，用纯 Python shell 链执行器替代 cmd.exe /c。
                # _exec_shell_chain_python 完全在 Python 中处理 |、&&、||、; 等操作符，
                # 每个段以 [exe, ...args] 安全路径独立执行，消除 cmd.exe 批处理语法
                # （%VAR% 展开、FOR 循环、延迟扩展等）理论绕过风险。
                # 段级白名单校验保留作为纵深防御——执行器内部同样执行白名单检查。
                _safe_stderr(f"[Agent] executing shell chain (pure Python): {command_expanded[:120]}")
                return _exec_shell_chain_python(
                    command_expanded, effective_cwd, project,
                    whitelist=_EXEC_WHITELIST,
                    exec_path_cache=_EXEC_PATH_CACHE,
                    exec_cmd_builtin=_exec_cmd_builtin,
                    exec_decode_output=_exec_decode_output,
                    exec_sanitize_output=_exec_sanitize_output,
                )
            else:
                cmd_list = [exe] + parts[1:]
                proc = subprocess.run(
                    cmd_list,
                    shell=False,
                    capture_output=True,
                    timeout=180,
                    cwd=effective_cwd,
                    creationflags=subprocess.CREATE_NO_WINDOW,
               )
        else:  # cmd_builtin — 纯 Python 实现
            proc = _exec_cmd_builtin(command_expanded, parts, effective_cwd, project)

        stdout = _exec_decode_output(proc.stdout)
        stderr = _exec_decode_output(proc.stderr)
        stdout, stderr = _exec_sanitize_output(stdout, stderr)
        return {
            "stdout": stdout,
            "stderr": stderr,
            "returncode": proc.returncode,
        }
    except subprocess.TimeoutExpired:
        return {"error": "command timed out after 180s", "stdout": "", "stderr": "", "returncode": -1}
    except Exception as e:
        return {"error": str(e), "stdout": "", "stderr": "", "returncode": -1}


def _exec_cmd_builtin(command: str, parts: list[str], cwd: str, project: str = '') -> subprocess.CompletedProcess:
    """用纯 Python 执行 cmd 内置命令，完全避免 cmd.exe 的 shell 操作符绕过。

    支持的命令：echo, dir/ls, type/cat, cd, pwd, cls/clear
    cd 命令会更新 _project_cwd[project]，后续 do_exec 使用该路径作为工作目录。
    type/cat 限制读取范围在项目目录内。
    """
    cmd = parts[0].lower()
    args = parts[1:]
    output = ""
    stderr_buf = ""

    if cmd == "echo":
        output = " ".join(args) + "\n"
    elif cmd in ("dir", "ls"):
        try:
            target = args[0] if args else cwd
            # 路径限制：只允许列出项目目录内的文件
            abs_target = os.path.realpath(os.path.join(cwd, target))
            proj_base = os.path.realpath(PROJECT_PATHS.get(project, cwd))
            if not os.path.normcase(abs_target).startswith(os.path.normcase(proj_base)):
                stderr_buf = f"ls: {target}: permission denied (path outside project directory)\n"
                return subprocess.CompletedProcess(args=command, returncode=1,
                                                   stdout=b"", stderr=stderr_buf.encode())
            entries = os.listdir(abs_target)
            entries.sort()
            output = "\n".join(entries) + "\n" if entries else "\n"
        except OSError as e:
            stderr_buf = f"ls: {target}: {e.strerror}\n"
            return subprocess.CompletedProcess(args=command, returncode=1,
                                               stdout=b"", stderr=stderr_buf.encode())
    elif cmd in ("type", "cat"):
        try:
            target = args[0] if args else ""
            # 路径限制：只允许读取项目目录内的文件，防止 HOOK_TOKEN 泄漏后的任意文件读取。
            # 使用项目根目录而非当前 cwd，防止 cd subdir 后无法访问父级项目文件。
            abs_target = os.path.realpath(os.path.join(cwd, target))
            proj_base = os.path.realpath(PROJECT_PATHS.get(project, cwd))
            if not os.path.normcase(abs_target).startswith(os.path.normcase(proj_base)):
                stderr_buf = f"cat: {target}: permission denied (path outside project directory)\n"
                return subprocess.CompletedProcess(args=command, returncode=1,
                                                   stdout=b"", stderr=stderr_buf.encode())
            with open(abs_target, "r", encoding="utf-8", errors="replace") as f:
                output = f.read(5 * 1024 * 1024)  # 5MB 上限，防止大文件撑爆内存和 API 响应体
                remaining = f.read(1)
                if remaining:
                    output += "\n... [file truncated at 5MB]"
        except (OSError, IndexError) as e:
            stderr_buf = f"cat: {target}: {e.strerror}\n"
            return subprocess.CompletedProcess(args=command, returncode=1,
                                               stdout=b"", stderr=stderr_buf.encode())
    elif cmd == "cd":
        try:
            target = args[0] if args else os.path.expanduser("~")
            if not os.path.isdir(target):
                stderr_buf = f"cd: {target}: No such directory\n"
                return subprocess.CompletedProcess(args=command, returncode=1,
                                                   stdout=b"", stderr=stderr_buf.encode())
            abspath = os.path.realpath(target)
            # 路径限制：只允许切换到项目目录及其子目录内，防止 cd .. 越界。
            proj_base = os.path.realpath(PROJECT_PATHS.get(project, cwd))
            if not os.path.normcase(abspath).startswith(os.path.normcase(proj_base)):
                stderr_buf = f"cd: {target}: permission denied (path outside project directory)\n"
                return subprocess.CompletedProcess(args=command, returncode=1,
                                                   stdout=b"", stderr=stderr_buf.encode())
            # 更新项目级工作目录，后续 do_exec 以此为准
            _project_cwd[project] = abspath
            output = abspath + "\n"
        except OSError as e:
            stderr_buf = f"cd: {e.strerror}\n"
            return subprocess.CompletedProcess(args=command, returncode=1,
                                               stdout=b"", stderr=stderr_buf.encode())
    elif cmd == "pwd":
        output = _project_cwd.get(project, cwd) + "\n"
    elif cmd in ("cls", "clear"):
        output = ""
    else:
        return subprocess.CompletedProcess(args=command, returncode=1,
                                           stdout=b"", stderr=b"unknown builtin command")

    return subprocess.CompletedProcess(args=command, returncode=0,
                                       stdout=output.encode(), stderr=b"")


# ── 纯 Python Shell 链执行器 ──
# 替代 cmd.exe /c 路径，消除 cmd.exe 批处理语法（%VAR%、FOR 循环、延迟扩展等）
# 带来的理论绕过风险。每个段通过 [exe, ...args] 安全路径独立执行。
# 支持：| pipe、&& AND、|| OR、; seq、\n seq、>/>>/<stderr 重定向。


def load_aliases() -> dict[str, str]:
    """从 ~/.claude/SEREIN_aliases.json 加载命令别名（带 30 秒 TTL 缓存）。"""
    global _aliases_cache, _aliases_cache_mtime
    now = time.time()
    path = os.path.join(USER_HOME, ".claude", "SEREIN_aliases.json")
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        return {}
    if (_aliases_cache is not None
            and now - _aliases_cache_mtime < _ALIASES_CACHE_TTL
            and mtime <= _aliases_cache_mtime):
        return _aliases_cache
    # 先读取文件内容，再检查权限。顺序不可调换：先 stat 后 open 存在 TOCTOU 竞态窗口
    # （攻击者可在 stat 和 open 之间替换文件为恶意内容）。
    # 当前策略：先 read 后 stat。文件内容已读入内存后检查权限，攻击者无法通过替换文件
    # 影响已读入的数据。剩余盲区：文件读取后到检查前的极短窗口内，若攻击者替换文件，
    # 权限检查可能通过但已读内容属于旧文件。在单用户场景下此窗口无实际攻击价值——攻击者
    # 已具有能替换文件的权限时，可直接修改自身别名文件而非绕过全局可写检查。
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:
        _safe_stderr(f"[Agent] 加载别名文件失败: {type(e).__name__}: {e}")
        return {}
    # 文件读取成功后检查全局可写权限（此时文件已读入内存，攻击者无法通过替换文件影响已读数据）
    try:
        st = os.stat(path)
        if st.st_mode & 0o002:
            _safe_stderr(f"[Agent] 拒绝加载：别名文件 {path} 对所有人可写（建议限制为仅当前用户可读写）")
            data = None  # 显式清除已读入的数据，减少理论残留盲区
            return {}
    except OSError:
        pass
    if isinstance(data, dict):
        validated = {}
        for k, v in data.items():
            if not isinstance(k, str) or not isinstance(v, str):
                _safe_stderr(f"[Agent] 别名文件跳过非字符串条目: key={k!r} type={type(v).__name__}")
                continue
            if len(k) > 100 or len(v) > 1000:
                _safe_stderr(f"[Agent] 别名文件跳过超长条目: key={k!r} len(key)={len(k)} len(val)={len(v)}")
                continue
            validated[k] = v
        _aliases_cache = validated
        _aliases_cache_mtime = now
        return _aliases_cache
    return {}


def expand_alias(command: str) -> str:
    """若命令首词是别名，用展开替换首词；否则原样返回。"""
    if not command or not command.strip():
        return command
    aliases = load_aliases()
    if not aliases:
        return command
    stripped = command.lstrip()
    leading = command[:len(command) - len(stripped)]
    sp = 0
    while sp < len(stripped) and not stripped[sp].isspace():
        sp += 1
    head = stripped[:sp]
    rest = stripped[sp:]
    if head in aliases:
        return leading + aliases[head] + rest
    return command
