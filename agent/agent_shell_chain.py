#!/usr/bin/env python3
"""serein 纯 Python Shell 链执行器

替代 cmd.exe /c 路径，消除 cmd.exe 批处理语法（%VAR%、FOR 循环、延迟扩展等）
带来的理论绕过风险。每个段通过 [exe, ...args] 安全路径独立执行。
支持：| pipe、&& AND、|| OR、; seq、\\n seq、>/>>/< 重定向。

从 agent_exec.py 提取，降低主文件复杂度。
"""
import os, re, shlex, shutil, subprocess
from typing import Any

from common import (
    PROJECT_PATHS, _safe_stderr,
    _sanitize_stdout, _sanitize_stderr,
    _EXEC_WHITELIST, _EXEC_PATH_CACHE,
)

# ANSI 转义序列正则（用于剥离颜色码）
_ANSI_RE = re.compile(r'\x1b\[[0-9;]*[a-zA-Z]|\x1b\][^\x07]*\x07|\x1b[=>]')


def _exec_decode_output(b: bytes) -> str:
    """解码子进程输出字节（尝试 utf-8 → gbk → replace）。"""
    if not b:
        return ""
    try:
        return b.decode("utf-8")
    except UnicodeDecodeError:
        try:
            return b.decode("gbk")
        except UnicodeDecodeError:
            return b.decode("utf-8", errors="replace")


def _exec_sanitize_output(stdout: str, stderr: str) -> tuple[str, str]:
    """剥离 ANSI 转义序列并脱敏敏感信息。"""
    stdout = _ANSI_RE.sub('', stdout)
    stderr = _ANSI_RE.sub('', stderr)
    return _sanitize_stdout(stdout), _sanitize_stderr(stderr)


def _iter_shell_segments(command: str):
    """在 shell 分隔符处拆分命令，同时尊重引号上下文。

    将命令按 &&、||、|、;、\\n 拆分为段，但忽略引号内的分隔符。
    re.split 不理解 shell 引号，会将 git log --format="%s; %an" 等
    含字面分隔符的合法命令误拆成多段，本生成器避免此问题。
    产生 (segment_text, operator) 元组。第一段的操作符始终为 ''。
    操作符: '', '|', '&&', '||', ';', '\\n'
    """
    buf: list[str] = []
    in_sq = False
    in_dq = False
    i = 0
    n = len(command)
    pending_op = ''
    while i < n:
        c = command[i]
        if in_sq:
            buf.append(c)
            if c == "'":
                in_sq = False
        elif in_dq:
            buf.append(c)
            if c == '"':
                in_dq = False
        elif c == "'":
            buf.append(c)
            in_sq = True
        elif c == '"':
            buf.append(c)
            in_dq = True
        elif c in (';', '\n'):
            s = ''.join(buf).strip()
            if s:
                yield (s, pending_op)
            buf = []
            pending_op = c
        elif c == '&' and i + 1 < n and command[i + 1] == '&':
            s = ''.join(buf).strip()
            if s:
                yield (s, pending_op)
            buf = []
            pending_op = '&&'
            i += 1
        elif c == '|':
            if i + 1 < n and command[i + 1] == '|':
                s = ''.join(buf).strip()
                if s:
                    yield (s, pending_op)
                buf = []
                pending_op = '||'
                i += 1
            else:
                s = ''.join(buf).strip()
                if s:
                    yield (s, pending_op)
                buf = []
                pending_op = '|'
        else:
            buf.append(c)
        i += 1
    s = ''.join(buf).strip()
    if s:
        yield (s, pending_op)


def _split_shell_chain(command: str) -> list[str]:
    """在 shell 分隔符处拆分命令，忽略引号内的分隔符。

    委托给 _iter_shell_segments 避免约 100 行重复 FSM 代码。
    """
    return [seg for seg, _op in _iter_shell_segments(command)]


def _parse_chain_operators(command: str) -> list[tuple[str, str]]:
    """解析 shell 命令为 (段字符串, 连接操作符) 的列表。

    与 _split_shell_chain 共享相同的 _iter_shell_segments 核心 FSM。
    连接操作符: '', '|', '&&', '||', ';', '\\n'
    第一段的操作符始终为 ''。
    """
    return list(_iter_shell_segments(command))


def _extract_redirects(tokens: list[str]) -> tuple[list[str], dict[str, str]]:
    """从 token 列表中提取 I/O 重定向操作符和文件名。

    扫描 tokens 中后跟文件名的重定向操作符。
    支持: >, >>, <, 1>, 1>>, 2>, 2>>。
    返回 (清洗后的 tokens, 重定向字典)。
    """
    clean = list(tokens)
    redirects: dict[str, str] = {}
    i = 0
    while i < len(clean):
        t = clean[i]
        if t in ('>', '>>', '<', '1>', '1>>', '2>', '2>>') and i + 1 < len(clean):
            redirects[t] = clean[i + 1]
            clean = clean[:i] + clean[i + 2:]
            continue
        i += 1
    return clean, redirects


def _validate_redirect_path(fname: str, cwd: str, project: str) -> str | None:
    """校验 I/O 重定向目标路径是否在项目目录内，防止路径遍历。

    解析 fname 为绝对路径后检查是否以项目根目录为前缀。
    返回绝对路径（合法时）或 None（路径遍历/越界）。
    """
    abs_path = os.path.realpath(os.path.join(cwd, fname))
    proj_base = os.path.realpath(PROJECT_PATHS.get(project, cwd))
    if not os.path.normcase(abs_path).startswith(os.path.normcase(proj_base)):
        return None
    return abs_path


def _exec_single_segment(segment: str, cwd: str, project: str,
                         stdin_bytes: bytes | None = None,
                         timeout: int = 180,
                         whitelist: dict | None = None,
                         exec_path_cache: dict | None = None,
                         exec_cmd_builtin=None,
                         exec_decode_output=None,
                         exec_sanitize_output=None) -> dict:
    """通过安全非 shell 路径执行一个命令段。

    处理段内的 I/O 重定向 (>, >>, <, 2>, 2>>)。
    每个可执行文件以 [exe, ...args] 形式运行——完全不涉及 shell。
    返回包含 stdout, stderr, returncode 的字典。
    """
    # whitelist / exec_path_cache / exec_cmd_builtin / exec_decode_output / exec_sanitize_output
    # 由调用方传入，消除与 agent_exec 的循环导入。
    # whitelist 和 path_cache 从 common 导入作为默认值。
    # exec_cmd_builtin 调用方应始终显式传入（不提供默认值，避免循环导入 agent_exec）。
    if whitelist is None:
        whitelist = _EXEC_WHITELIST
    if exec_path_cache is None:
        exec_path_cache = _EXEC_PATH_CACHE
    if exec_decode_output is None:
        exec_decode_output = _exec_decode_output
    if exec_sanitize_output is None:
        exec_sanitize_output = _exec_sanitize_output

    try:
        tokens = shlex.split(segment.strip())
    except ValueError as e:
        return {"error": f"segment parse error: {e}", "stdout": "", "stderr": "", "returncode": -1}

    if not tokens:
        return {"error": "empty segment", "stdout": "", "stderr": "", "returncode": -1}

    clean_tokens, redirects = _extract_redirects(tokens)

    if not clean_tokens:
        return {"error": "no command after redirect extraction", "stdout": "", "stderr": "", "returncode": -1}

    base_cmd = clean_tokens[0].lower()
    entry = whitelist.get(base_cmd)
    if entry is None:
        return {"error": f"blocked: '{base_cmd}' not in whitelist", "stdout": "", "stderr": "", "returncode": -1}

    cmd_type, exe_name = entry
    clean_command = ' '.join(clean_tokens)

    # ── 内置命令 (cmd_builtin) ──
    if cmd_type == "cmd_builtin":
        pp = exec_cmd_builtin(clean_command, clean_tokens, cwd, project)
        seg_out = (pp.stdout or b'')
        seg_err = (pp.stderr or b'')
        rc = pp.returncode

        stdout_str = seg_out.decode('utf-8', 'replace')
        stderr_str = seg_err.decode('utf-8', 'replace')

        # 为内置命令从外部处理重定向
        for op, fname in redirects.items():
            # 路径遍历保护：校验重定向目标路径在项目目录内
            abs_fname = _validate_redirect_path(fname, cwd, project)
            if abs_fname is None:
                stderr_str = f"redirect target outside project: {fname}\n"
                rc = 1
                continue
            if op in ('>', '1>'):
                try:
                    with open(abs_fname, 'w', encoding='utf-8') as f:
                        f.write(stdout_str)
                except OSError as e:
                    stderr_str = f"cannot write {abs_fname}: {e.strerror}\n"
                    rc = 1
            elif op in ('>>', '1>>'):
                try:
                    with open(abs_fname, 'a', encoding='utf-8') as f:
                        f.write(stdout_str)
                except OSError as e:
                    stderr_str = f"cannot append {abs_fname}: {e.strerror}\n"
                    rc = 1
            elif op in ('2>', '2>>'):
                mode = 'a' if op == '2>>' else 'w'
                try:
                    with open(abs_fname, mode, encoding='utf-8') as f:
                        f.write(stderr_str)
                except OSError as e:
                    stderr_str = f"cannot write {abs_fname}: {e.strerror}\n"
                    rc = 1
            elif op == '<':
                _safe_stderr(f"[Agent] builtin '{base_cmd}' redirect < not supported")
        return {"stdout": stdout_str, "stderr": stderr_str, "returncode": rc}

    # ── 外部可执行文件 ──
    # 优先使用调用方传入的 PATH 缓存（启动时解析的绝对路径），防止运行时 PATH 篡改。
    if exec_path_cache and base_cmd in exec_path_cache:
        exe = exec_path_cache[base_cmd]
    else:
        exe = shutil.which(exe_name) if exe_name else None
    if not exe:
        return {"error": f"executable not found: {exe_name or base_cmd}", "stdout": "", "stderr": "", "returncode": -1}

    cmd_list = [exe] + clean_tokens[1:]

    # I/O 设置
    stdin_src: Any = None
    stdout_dest: Any = subprocess.PIPE
    stderr_dest: Any = subprocess.PIPE
    close_handles: list = []

    for op, fname in redirects.items():
        # 路径遍历保护：校验重定向目标路径在项目目录内
        abs_fname = _validate_redirect_path(fname, cwd, project)
        if abs_fname is None:
            for h in close_handles:
                try:
                    h.close()
                except OSError:
                    pass
            return {"error": f"redirect target outside project: {fname}",
                    "stdout": "", "stderr": "", "returncode": -1}
        if op == '<':
            stdin_src = open(abs_fname, 'rb')
            close_handles.append(stdin_src)
        elif op in ('>', '1>'):
            stdout_dest = open(abs_fname, 'wb')
            close_handles.append(stdout_dest)
        elif op in ('>>', '1>>'):
            stdout_dest = open(abs_fname, 'ab')
            close_handles.append(stdout_dest)
        elif op == '2>':
            stderr_dest = open(abs_fname, 'wb')
            close_handles.append(stderr_dest)
        elif op == '2>>':
            stderr_dest = open(abs_fname, 'ab')
            close_handles.append(stderr_dest)

    try:
        # stdin: 如果上一个 pipe 传了 stdin_bytes 则用 input=，
        # 如果有 < file 文件重定向则用 stdin=，否则 None。
        if stdin_bytes is not None:
            proc = subprocess.run(
                cmd_list, shell=False,
                input=stdin_bytes,
                stdout=stdout_dest,
                stderr=stderr_dest,
                timeout=timeout,
                cwd=cwd,
                creationflags=subprocess.CREATE_NO_WINDOW,
            )
        else:
            proc = subprocess.run(
                cmd_list, shell=False,
                stdin=stdin_src,
                stdout=stdout_dest,
                stderr=stderr_dest,
                timeout=timeout,
                cwd=cwd,
                creationflags=subprocess.CREATE_NO_WINDOW,
            )

        stdout_raw = proc.stdout if stdout_dest is subprocess.PIPE else b''
        stderr_raw = proc.stderr if stderr_dest is subprocess.PIPE else b''

        stdout_str = exec_decode_output(stdout_raw)
        stderr_str = exec_decode_output(stderr_raw)
        stdout_str, stderr_str = exec_sanitize_output(stdout_str, stderr_str)

        return {
            "stdout": stdout_str,
            "stderr": stderr_str,
            "returncode": proc.returncode,
            "_stdout_bytes": proc.stdout,  # 用于 pipe 链（原始字节）
        }
    except subprocess.TimeoutExpired:
        return {"error": "segment timed out", "stdout": "", "stderr": "", "returncode": -1}
    except Exception as e:
        return {"error": str(e), "stdout": "", "stderr": "", "returncode": -1}
    finally:
        for h in close_handles:
            try:
                h.close()
            except OSError:
                pass


def _exec_shell_chain_python(command: str, cwd: str, project: str,
                              whitelist: dict | None = None,
                              exec_path_cache: dict | None = None,
                              exec_cmd_builtin=None,
                              exec_decode_output=None,
                              exec_sanitize_output=None) -> dict:
    """在纯 Python 中执行 shell 命令链，完全绕过 cmd.exe /c。

    处理 | (pipe)、&& (AND)、|| (OR)、; (顺序)、\\n (顺序)，
    以及段内的 I/O 重定向 (>, >>, <, 2>, 2>>)。
    每个段以 [exe, ...args] 形式运行——完全不涉及 shell。

    whitelist / exec_cmd_builtin / exec_decode_output / exec_sanitize_output
    由调用方传入，消除与 agent_exec 的循环导入。未传入时使用延迟导入兜底。

    返回包含 stdout, stderr, returncode 的字典。
    """
    segments_with_ops = _parse_chain_operators(command)

    if len(segments_with_ops) > 20:
        return {"error": "shell chain too long (>20 segments)", "stdout": "", "stderr": "", "returncode": -1}

    overall_stdout: list[str] = []
    overall_stderr: list[str] = []
    last_returncode = 0
    last_stdout_bytes: bytes | None = None

    for seg_str, operator in segments_with_ops:
        seg_str = seg_str.strip()
        if not seg_str:
            continue

        # 链短路检查：在执行当前段前，基于前一段结果和连接操作符判断。
        # operator 来自 _parse_chain_operators，表示连接前一段与当前段的操作符。
        # 例如 A && B：B 的 operator='&&'，意味着"前一段成功时才执行 B"。
        if operator == '&&' and last_returncode != 0:
            break  # 前一段失败，跳过当前段（短路）
        if operator == '||' and last_returncode == 0:
            break  # 前一段成功，跳过当前段（短路）
        # '|', ';', '\n' 无条件继续（不支持 pipe 短路）

        # 仅当上一个操作符是 | 时才将 stdout 作为 stdin 传递
        stdin_data = last_stdout_bytes if operator == '|' else None

        result = _exec_single_segment(
            seg_str, cwd, project,
            stdin_bytes=stdin_data,
            whitelist=whitelist,
            exec_path_cache=exec_path_cache,
            exec_cmd_builtin=exec_cmd_builtin,
            exec_decode_output=exec_decode_output,
            exec_sanitize_output=exec_sanitize_output,
        )

        seg_rc = result.get('returncode', 0)
        seg_stdout = result.get('stdout', '')
        seg_stderr = result.get('stderr', '')

        # 为 pipe 保留原始 stdout 字节
        if operator == '|' and 'error' not in result and '_stdout_bytes' in result:
            last_stdout_bytes = result['_stdout_bytes']
        else:
            last_stdout_bytes = None

        if seg_stdout:
            overall_stdout.append(seg_stdout)
        if seg_stderr:
            overall_stderr.append(seg_stderr)

        last_returncode = seg_rc


    return {
        "stdout": ''.join(overall_stdout),
        "stderr": ''.join(overall_stderr),
        "returncode": last_returncode,
    }
