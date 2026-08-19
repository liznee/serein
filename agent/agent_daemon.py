#!/usr/bin/env python3
"""serein 本地 Daemon — HTTP 控制端口。

在 localhost 上暴露 REST API，允许本地工具/脚本直接控制 agent，
无需后端中转。与 local_agent.py 主循环并行运行（后台线程）。

端点：
  GET  /status           → 查询运行状态
  POST /start            → 启动项目 agent (body: {"project": "...", "agent_type": "claude"})
  POST /stop             → 停止项目 agent (body: {"project": "..."})
  POST /kill-all         → 紧急刹车
  GET  /health           → 健康检查
  GET  /agent-types      → 支持的 agent 类型列表

默认端口 7331，可通过 SEREIN_DAEMON_PORT 环境变量配置。
仅监听 127.0.0.1，不接受外部连接。
"""
import json
import os
import threading
import traceback
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

from common import _safe_stderr
from agent_config import AGENT_TYPES
from agent_proc import do_status, do_start, do_stop, do_kill_all

DAEMON_PORT = int(os.environ.get("SEREIN_DAEMON_PORT", "7331"))
DAEMON_HOST = "127.0.0.1"

_daemon_server: HTTPServer | None = None
_daemon_thread: threading.Thread | None = None


class DaemonHandler(BaseHTTPRequestHandler):
    """HTTP 请求处理器 — 将 REST 请求映射到 agent_proc 函数。"""

    def _send_json(self, code: int, body: dict):
        data = json.dumps(body).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _read_body(self) -> dict:
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            return {}
        try:
            raw = self.rfile.read(length)
            return json.loads(raw) if raw.strip() else {}
        except (json.JSONDecodeError, UnicodeDecodeError):
            return {}

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/health":
            self._send_json(200, {"ok": True, "service": "serein-daemon"})
        elif path == "/status":
            try:
                result = do_status()
                self._send_json(200, result)
            except Exception as e:
                _safe_stderr(f"[Daemon] /status error: {type(e).__name__}: {e}")
                self._send_json(500, {"error": str(e)})
        elif path == "/agent-types":
            self._send_json(200, {"types": AGENT_TYPES})
        else:
            self._send_json(404, {"error": f"unknown path: {path}"})

    def do_POST(self):
        path = urlparse(self.path).path
        body = self._read_body()
        try:
            if path == "/start":
                project = body.get("project", "")
                agent_type = body.get("agent_type", "")
                if not project:
                    self._send_json(400, {"error": "missing 'project' field"})
                    return
                result = do_start(project, agent_type)
                self._send_json(200, result)
            elif path == "/stop":
                project = body.get("project", "")
                if not project:
                    self._send_json(400, {"error": "missing 'project' field"})
                    return
                result = do_stop(project)
                self._send_json(200, result)
            elif path == "/kill-all":
                result = do_kill_all()
                self._send_json(200, result)
            else:
                self._send_json(404, {"error": f"unknown path: {path}"})
        except Exception as e:
            _safe_stderr(f"[Daemon] {path} error: {type(e).__name__}: {e}\n{traceback.format_exc()}")
            self._send_json(500, {"error": str(e)})

    def log_message(self, fmt, *args):
        """静默 HTTP 日志（避免刷屏），错误通过 _send_json 返回。"""
        pass


def start_daemon(port: int = 0):
    """启动 daemon HTTP 服务器（后台线程）。
    port=0 时使用 SEREIN_DAEMON_PORT 环境变量或默认 7331。"""
    global _daemon_server, _daemon_thread
    if _daemon_thread and _daemon_thread.is_alive():
        return
    actual_port = port or DAEMON_PORT
    try:
        _daemon_server = HTTPServer((DAEMON_HOST, actual_port), DaemonHandler)
        _daemon_thread = threading.Thread(
            target=_daemon_server.serve_forever,
            daemon=True,
            name="serein-daemon"
        )
        _daemon_thread.start()
        _safe_stderr(f"[Daemon] 本地 HTTP 控制端口已启动: http://{DAEMON_HOST}:{actual_port}")
    except OSError as e:
        _safe_stderr(f"[Daemon] 端口 {actual_port} 启动失败: {e}（可能被占用）")
    except Exception as e:
        _safe_stderr(f"[Daemon] 启动异常: {type(e).__name__}: {e}")


def stop_daemon():
    """停止 daemon HTTP 服务器。"""
    global _daemon_server, _daemon_thread
    if _daemon_server:
        try:
            _daemon_server.shutdown()
            _daemon_server.server_close()
        except Exception:
            pass
    _daemon_server = None
    _daemon_thread = None
