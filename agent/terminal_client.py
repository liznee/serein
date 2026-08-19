#!/usr/bin/env python3
"""serein 终端客户端 — 双端实时同步的终端界面。

用户在电脑上运行此程序，连接到后端 WebSocket，与手机 App 共享同一会话。
依赖：websocket-client, rich

安装：pip install websocket-client rich

用法：
  python terminal_client.py               # 连接默认项目
  python terminal_client.py --project env  # 连接指定项目
  python terminal_client.py --server http://localhost:8080
"""
import sys
import os
import json
import time
import argparse
import threading
import urllib.request
import urllib.error

SERVER = os.environ.get("SEREIN_BACKEND", "http://localhost:8080")

# ── Rich TUI ──
try:
    from rich.console import Console
    from rich.live import Live
    from rich.panel import Panel
    from rich.text import Text
    from rich.layout import Layout
    from rich.prompt import PromptBase
    from rich.align import Align
    HAS_RICH = True
except ImportError:
    HAS_RICH = False

# ── WebSocket ──
try:
    import websocket
    HAS_WS = True
except ImportError:
    HAS_WS = False


def main():
    parser = argparse.ArgumentParser(description="serein 双端实时终端")
    parser.add_argument("--project", default="serein", help="项目名")
    parser.add_argument("--server", default=SERVER, help="后端地址")
    args = parser.parse_args()

    if not HAS_WS:
        print("[错误] 需要安装 websocket-client：pip install websocket-client", file=sys.stderr)
        sys.exit(1)

    if not HAS_RICH:
        print("[提示] 推荐安装 rich 以获得更好的终端体验：pip install rich", file=sys.stderr)

    client = TerminalClient(args.server, args.project)
    try:
        client.run()
    except KeyboardInterrupt:
        print("\n[退出] 用户中断")
        client.close()


class TerminalClient:
    """终端客户端 — WS 连接 + 消息渲染 + 键盘输入"""

    def __init__(self, server: str, project: str):
        self.server = server
        self.project = project
        self.ws = None
        self.session_id = ""
        self.messages: list[dict] = []  # 消息历史
        self.running = False
        self._console = Console() if HAS_RICH else None
        self._lock = threading.Lock()

    def connect(self) -> bool:
        """建立 WS 连接并 join session。"""
        ws_url = self.server.replace("https://", "wss://").replace("http://", "ws://") + "/ws"
        try:
            import ssl
            self.ws = websocket.create_connection(ws_url, timeout=10,
                                                   sslopt={"cert_reqs": ssl.CERT_NONE})
            # join
            join_msg = json.dumps({"type": "join", "session_id": "", "client_type": "terminal"})
            self.ws.send(join_msg)
            # 处理返回的消息
            while True:
                raw = self.ws.recv()
                if not raw:
                    continue
                msg = json.loads(raw)
                if msg.get("type") == "join_ack":
                    self.session_id = (msg.get("payload") or {}).get("session_id", "")
                    print(f"[连接] 加入 session: {self.session_id}")
                elif msg.get("type") == "history":
                    history = (msg.get("payload") or {}).get("messages", [])
                    with self._lock:
                        self.messages = history
                    print(f"[连接] 收到 {len(history)} 条历史消息")
                    return True
                elif msg.get("type") == "session_msg":
                    with self._lock:
                        self.messages.append(msg)
            return True
        except Exception as e:
            print(f"[连接失败] {e}", file=sys.stderr)
            return False

    def close(self):
        if self.ws:
            self.ws.close()

    def run(self):
        if not self.connect():
            print("[错误] 无法连接到后端，请检查网络和后端地址")
            sys.exit(1)

        self.running = True
        # 读线程
        reader = threading.Thread(target=self._reader, daemon=True)
        reader.start()

        if HAS_RICH:
            self._run_rich_ui()
        else:
            self._run_simple_ui()

        self.running = False

    def _reader(self):
        """后台读 WS 消息。"""
        while self.running and self.ws:
            try:
                self.ws.settimeout(1.0)
                raw = self.ws.recv()
                if not raw:
                    continue
                msg = json.loads(raw)
                msg_type = msg.get("type", "")
                if msg_type in ("session_msg", "cmd_result", "cmd_step"):
                    with self._lock:
                        self.messages.append(msg)
                    if self._console and msg_type == "session_msg":
                        payload = msg.get("payload") or {}
                        if isinstance(payload, dict):
                            content = payload.get("content", "")
                            if content:
                                self._console.print(f"[dim]{self._ts(msg)}[/dim] {content}")
                elif msg_type == "mode_switch":
                    with self._lock:
                        self.messages.append(msg)
                    if self._console:
                        self._console.print(f"[yellow]⚡ 模式切换: {msg.get('payload', {})}[/yellow]")
            except Exception:
                pass

    def _ts(self, msg: dict) -> str:
        """从消息中提取时间戳。"""
        ts = msg.get("timestamp", "")
        if ts and len(ts) >= 16:
            return ts[11:16]
        return time.strftime("%H:%M")

    def _run_simple_ui(self):
        """无 rich 时的简单 UI。"""
        print(f"\n===== serein 实时终端 [{self.project}] =====")
        print("输入消息，Enter 发送 | Ctrl+C 退出\n")
        # 显示历史
        with self._lock:
            for m in self.messages[-20:]:
                print(f"[{self._ts(m)}] {m.get('payload', {})}")
        # 输入循环
        while self.running:
            try:
                text = input("> ")
                if text.strip():
                    self._send(text.strip())
            except (EOFError, KeyboardInterrupt):
                break

    def _run_rich_ui(self):
        """基于 rich 的 TUI。"""
        with self._lock:
            init_msgs = list(self.messages)

        layout = Layout()
        layout.split_column(
            Layout(name="header", size=3),
            Layout(name="body", ratio=1),
            Layout(name="input", size=3),
        )

        # 消息渲染函数
        def render_body() -> Panel:
            lines = []
            with self._lock:
                for m in self.messages[-50:]:
                    t = m.get("type", "")
                    payload = m.get("payload", {}) or {}
                    ts = self._ts(m)
                    if t == "session_msg":
                        content = ""
                        if isinstance(payload, dict):
                            content = payload.get("content", "")
                        if content:
                            lines.append(Text(f"{ts} {content}", style="cyan"))
                    elif t == "cmd_result":
                        lines.append(Text(f"{ts} [结果] {payload}", style="green"))
                    elif t == "cmd_step":
                        lines.append(Text(f"{ts} [步骤] {payload}", style="dim"))
            if not lines:
                lines.append(Text("等待消息...", style="dim"))
            return Panel("\n".join(str(t) for t in lines), title=f"📱 {self.project}")

        self._console.clear()
        self._console.print(f"[bold cyan]serein 实时终端 — {self.project}[/bold cyan]")
        self._console.print("[dim]Ctrl+C 退出[/dim]\n")

        # 显示初始消息
        for m in init_msgs:
            payload = m.get("payload", {}) or {}
            if isinstance(payload, dict):
                content = payload.get("content", "")
                if content:
                    self._console.print(f"[dim]{self._ts(m)}[/dim] {content}")

        # 输入循环
        while self.running:
            try:
                if HAS_RICH:
                    text = input("> ")
                else:
                    text = input("> ")
                if text.strip():
                    self._send(text.strip())
            except (EOFError, KeyboardInterrupt):
                break

    def _send(self, text: str):
        """发送消息到后端。"""
        if not self.ws or not self.session_id:
            return
        msg = {
            "type": "session_msg",
            "session_id": self.session_id,
            "source": "terminal",
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "payload": {
                "content": text,
                "msg_type": "text",
                "project": self.project,
            }
        }
        try:
            self.ws.send(json.dumps(msg))
            if self._console:
                self._console.print(f"[dim]{time.strftime('%H:%M')}[/dim] {text}")
        except Exception as e:
            if self._console:
                self._console.print(f"[red]发送失败: {e}[/red]")


if __name__ == "__main__":
    main()
