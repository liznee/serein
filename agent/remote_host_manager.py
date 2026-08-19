"""Silent lifecycle manager for the optional Serein Windows Remote Host.

When enabled it never invokes cmd.exe or PowerShell, starts the native Host and
per-session WebRTC bridge with CREATE_NO_WINDOW, and talks to the already-running
single Host instance through a local named pipe.
"""

from __future__ import annotations

import base64
import ctypes
import ctypes.wintypes
import hashlib
import json
import os
import re
import subprocess
import threading
import time
import uuid
from pathlib import Path
import sys as _sys
from typing import Callable, TextIO


CREATE_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000)
DETACHED_PROCESS = getattr(subprocess, "DETACHED_PROCESS", 0x00000008)
PIPE_PATH = r"\\.\pipe\serein-remote-host-v1"
STREAM_PIPE_PATH = r"\\.\pipe\serein-remote-host-stream-v1"
CRYPTPROTECT_UI_FORBIDDEN = 0x01
REMOTE_TICKET_RE = re.compile(r"^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$")
DEFAULT_STREAM_MONITOR = 0
DEFAULT_STREAM_FPS = 15
DEFAULT_STREAM_BITRATE = 2_000_000


class _DataBlob(ctypes.Structure):
    _fields_ = [
        ("cbData", ctypes.wintypes.DWORD),
        ("pbData", ctypes.POINTER(ctypes.c_byte)),
    ]


def _dpapi_protect(secret: str) -> str:
    """Protect a secret for the current Windows user; never fall back."""
    if os.name != "nt" or not secret:
        raise OSError("Windows DPAPI is unavailable")
    raw = secret.encode("utf-8")
    source_buffer = ctypes.create_string_buffer(raw)
    source = _DataBlob(len(raw), ctypes.cast(source_buffer, ctypes.POINTER(ctypes.c_byte)))
    protected = _DataBlob()
    crypt32 = ctypes.windll.crypt32
    if not crypt32.CryptProtectData(
        ctypes.byref(source), "Serein Remote Host", None, None, None,
        CRYPTPROTECT_UI_FORBIDDEN, ctypes.byref(protected),
    ):
        raise ctypes.WinError()
    try:
        return base64.b64encode(ctypes.string_at(protected.pbData, protected.cbData)).decode("ascii")
    finally:
        ctypes.windll.kernel32.LocalFree(protected.pbData)


def _dpapi_unprotect(encoded: str) -> str:
    """Unprotect a current-user DPAPI value; malformed data fails closed."""
    if os.name != "nt" or not encoded:
        raise OSError("Windows DPAPI is unavailable")
    raw = base64.b64decode(encoded, validate=True)
    source_buffer = ctypes.create_string_buffer(raw)
    source = _DataBlob(len(raw), ctypes.cast(source_buffer, ctypes.POINTER(ctypes.c_byte)))
    plain = _DataBlob()
    crypt32 = ctypes.windll.crypt32
    if not crypt32.CryptUnprotectData(
        ctypes.byref(source), None, None, None, None,
        CRYPTPROTECT_UI_FORBIDDEN, ctypes.byref(plain),
    ):
        raise ctypes.WinError()
    try:
        return ctypes.string_at(plain.pbData, plain.cbData).decode("utf-8")
    finally:
        ctypes.windll.kernel32.LocalFree(plain.pbData)


class RemoteHostManager:
    def __init__(
        self,
        agent_dir: str,
        http_request: Callable[..., dict],
        *,
        enabled: bool | None = None,
        state_dir: str | None = None,
        executable: str | None = None,
        bridge_executable: str | None = None,
        backend_url: str | None = None,
        protect_secret: Callable[[str], str] | None = None,
        unprotect_secret: Callable[[str], str] | None = None,
    ) -> None:
        self.agent_dir = Path(agent_dir)
        self.http_request = http_request
        self.enabled = (
            os.environ.get("SEREIN_REMOTE_HOST_ENABLE", "0") == "1"
            if enabled is None else enabled
        )
        base_state = state_dir or os.path.join(
            os.environ.get("LOCALAPPDATA", str(Path.home())), "Serein"
        )
        self.state_dir = Path(base_state)
        self.identity_file = self.state_dir / "remote-host.json"
        remote_root = self.agent_dir.parent / "remote" / "windows-host"
        default_exe = remote_root / "build" / "serein-remote-host.exe"
        self.executable = Path(executable or os.environ.get("SEREIN_REMOTE_HOST_EXE", str(default_exe)))
        default_bridge = remote_root / "bridge" / "serein-remote-bridge.exe"
        self.bridge_executable = Path(
            bridge_executable or os.environ.get("SEREIN_REMOTE_BRIDGE_EXE", str(default_bridge)))
        self.backend_url = backend_url or os.environ.get("SEREIN_REMOTE_BACKEND_URL", "")
        self.host_id = ""
        self.fingerprint = ""
        self.host_token = ""
        self._identity_seed = ""
        self._protect_secret = protect_secret or _dpapi_protect
        self._unprotect_secret = unprotect_secret or _dpapi_unprotect
        self._credential_storage_failed = False
        self.last_register_at = 0.0
        self.last_poll_at = 0.0
        self.last_bridge_check_at = 0.0
        self.service_process: subprocess.Popen | None = None
        self.in_flight: set[str] = set()
        self._lock = threading.Lock()
        self._capabilities: dict | None = None
        # session_id -> (proc, log_file_handle) so we can close the log handle
        # when the bridge process exits.
        self._bridge_sessions: dict[str, tuple[subprocess.Popen, TextIO]] = {}

    def tick(self, now: float | None = None) -> None:
        if not self.enabled or os.name != "nt" or not self.executable.is_file():
            return
        now = time.time() if now is None else now
        if not self._ensure_service():
            return
        if self._credential_storage_failed:
            return
        if now - self.last_bridge_check_at >= 2:
            self._check_bridge_processes()
            self.last_bridge_check_at = now
        # Heartbeat every 30s. Consent latency no longer depends on this
        # because RequestSession uses a 5-minute LastSeenAt window to decide
        # waiting_consent directly. The 1s pending-poll below is what gives
        # sub-2s consent popup latency.
        if now - self.last_register_at >= 30:
            if self.host_token:
                self._heartbeat()
            else:
                self._register()
            self.last_register_at = now
        # Poll pending sessions every 1s (was 2s) for sub-2s consent latency.
        if self.host_token and now - self.last_poll_at >= 1:
            self._poll_pending()
            self.last_poll_at = now

    def close(self) -> None:
        # Stop all bridge processes and native streams before letting the shared
        # service survive a relay restart. The service itself stays resident for
        # other CLI projects; only the per-session media is torn down.
        self._stop_all_bridges()
        self.service_process = None

    def _load_identity(self) -> None:
        if self.host_id and self.fingerprint:
            return
        try:
            raw = json.loads(self.identity_file.read_text(encoding="utf-8"))
            host_id = str(raw.get("host_id", ""))
            seed = str(raw.get("seed", ""))
            if host_id and seed:
                self.host_id = host_id
                self._identity_seed = seed
                self.fingerprint = "sha256:" + hashlib.sha256(seed.encode()).hexdigest()
                protected_token = raw.get("host_token_dpapi")
                if isinstance(protected_token, str) and protected_token:
                    try:
                        self.host_token = self._unprotect_secret(protected_token)
                    except (OSError, ValueError, UnicodeError):
                        self.host_token = ""
                return
        except (OSError, ValueError, TypeError):
            pass
        self.state_dir.mkdir(parents=True, exist_ok=True)
        seed = uuid.uuid4().hex + uuid.uuid4().hex
        self.host_id = "windows-" + uuid.uuid4().hex
        self._identity_seed = seed
        self.fingerprint = "sha256:" + hashlib.sha256(seed.encode()).hexdigest()
        self._save_identity()

    def _save_identity(self, protected_token: str = "") -> None:
        self.state_dir.mkdir(parents=True, exist_ok=True)
        temp = self.identity_file.with_suffix(".tmp")
        payload = {"host_id": self.host_id, "seed": self._identity_seed}
        if protected_token:
            payload["host_token_dpapi"] = protected_token
        temp.write_text(json.dumps(payload), encoding="utf-8")
        os.replace(temp, self.identity_file)

    def _store_host_token(self, token: str) -> bool:
        try:
            protected = self._protect_secret(token)
            self._save_identity(protected)
        except (OSError, ValueError, UnicodeError):
            self.host_token = ""
            self._credential_storage_failed = True
            return False
        self.host_token = token
        return True

    def _invalidate_host_token(self) -> None:
        self.host_token = ""
        self.last_register_at = 0.0
        try:
            self._save_identity()
        except OSError:
            self._credential_storage_failed = True

    def _host_request(
        self,
        method: str,
        path: str,
        body: dict | None = None,
        *,
        timeout: int,
    ) -> dict:
        if not self.host_token:
            raise PermissionError("remote host credential unavailable")
        try:
            return self.http_request(
                method, path, body, timeout=timeout, auth_token=self.host_token
            )
        except Exception as exc:
            if getattr(exc, "code", None) == 401:
                self._invalidate_host_token()
            raise

    def _ensure_service(self) -> bool:
        self._load_identity()
        if self._pipe_call("PING") is not None:
            return True
        # PING failed. The native host's pipe server is single-threaded
        # (nMaxInstances=1). When a CONSENT command is being processed,
        # MessageBoxW blocks the server loop and PING cannot connect.
        # This is normal — do NOT kill the process during consent, just
        # wait for the next tick.
        with self._lock:
            if self.in_flight:
                return False
            # A bridge owns the native stream pipe while it is alive. A busy
            # control-pipe PING is not evidence that this host is stale.
            if any(proc.poll() is None for proc, _log_fh in self._bridge_sessions.values()):
                return True
        # PING failed and no consent is in progress. The native host process
        # may be alive but its pipe server stuck (e.g. after the previous agent
        # process was killed mid-message). Since the native host uses a
        # single-instance mutex, a new launch would silently exit while the
        # stale process holds the mutex. Kill any stale processes before
        # relaunching so the new process can acquire the mutex and recreate
        # the pipe.
        stale_killed = self._kill_stale_host_processes()
        if stale_killed:
            print(f"[RemoteHost] killed {stale_killed} stale native host process(es), restarting", file=_sys.stderr)
            time.sleep(0.5)
        try:
            self.service_process = subprocess.Popen(
                [str(self.executable), "--service"],
                cwd=str(self.executable.parent),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                close_fds=True,
                creationflags=CREATE_NO_WINDOW | DETACHED_PROCESS,
            )
        except OSError:
            return False
        # Do not use a visible shell or a long blocking wait. The next one-second
        # agent tick retries if the pipe is not ready yet.
        return False

    def _kill_stale_host_processes(self) -> int:
        """Kill any running serein-remote-host.exe processes (except service_process).

        Uses taskkill with /IM (image name) and /F (force). Returns the number
        of processes killed. Returns 0 if taskkill fails or no process was
        found. This is necessary because the native host holds a single-instance
        mutex — without killing the stale process, a new launch silently exits.
        """
        if os.name != "nt":
            return 0
        try:
            result = subprocess.run(
                ["taskkill", "/IM", "serein-remote-host.exe", "/F", "/T"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                creationflags=CREATE_NO_WINDOW,
                timeout=5,
                text=True,
            )
        except (OSError, subprocess.SubprocessError):
            return 0
        # taskkill returns 0 on success (killed at least one process), 128 if
        # no matching process found, other non-zero on error.
        if result.returncode == 0:
            self.service_process = None
            # Count "SUCCESS" lines in stdout (one per killed process)
            return result.stdout.count("SUCCESS:")
        return 0

    def _read_capabilities(self) -> dict:
        if self._capabilities is not None:
            # Transport and input availability belong to the Go bridge. Probe it
            # instead of trusting the mere presence of an executable, so a stale
            # or mismatched binary fails closed.
            bridge_input = self._read_bridge_input_capabilities()
            updated = dict(self._capabilities)
            updated["transports"] = ["webrtc"] if bridge_input else []
            updated["input"] = bridge_input
            return updated
        safe = {
            "protocol_version": 1,
            "capture": [],
            "video_codecs": [],
            "transports": [],
            "hardware_encoder": False,
            "input": [],
            "monitors": 0,
            "unattended_enabled": False,
            "secure_desktop": False,
        }
        try:
            result = subprocess.run(
                [str(self.executable), "--capabilities"],
                cwd=str(self.executable.parent),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                creationflags=CREATE_NO_WINDOW,
                timeout=8,
                check=True,
                text=True,
                encoding="utf-8",
            )
            payload = json.loads(result.stdout)
            if payload.get("protocol_version") != 1 or payload.get("desktop_pixels_read") is not False:
                raise ValueError("invalid capability probe")
            monitors = payload.get("monitors", 0)
            capture = payload.get("capture", [])
            codecs = payload.get("video_codecs", [])
            transports = payload.get("transports", [])
            if not isinstance(monitors, int) or monitors < 0 or monitors > 32:
                raise ValueError("invalid monitor count")
            if capture not in ([], ["dxgi-duplication"]) or codecs not in ([], ["h264"]) or transports != []:
                raise ValueError("invalid media capabilities")
            safe["monitors"] = monitors
            safe["capture"] = capture
            safe["video_codecs"] = codecs
            # The native probe never claims WebRTC transport or SendInput support
            # on its own. Those belong to the Go bridge and are enabled only after
            # its side-effect-free capability probe succeeds.
            bridge_input = self._read_bridge_input_capabilities()
            safe["transports"] = ["webrtc"] if bridge_input else []
            safe["input"] = bridge_input
        except (OSError, subprocess.SubprocessError, ValueError, TypeError):
            pass
        # Hardware MFT selection has not yet been proven, so this remains false
        # even when the H.264 software-capability probe succeeds.
        self._capabilities = safe
        return self._capabilities

    def _read_bridge_input_capabilities(self) -> list[str]:
        if not self.bridge_executable.is_file():
            return []
        try:
            result = subprocess.run(
                [str(self.bridge_executable), "--capabilities"],
                cwd=str(self.bridge_executable.parent),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                creationflags=CREATE_NO_WINDOW,
                timeout=5,
                check=True,
                text=True,
                encoding="utf-8",
            )
            payload = json.loads(result.stdout)
            input_capabilities = payload.get("input")
            if (payload.get("protocol_version") != 1 or
                    payload.get("desktop_pixels_read") is not False or
                    input_capabilities != ["pointer", "keyboard", "text"]):
                raise ValueError("invalid bridge capability probe")
            return list(input_capabilities)
        except (OSError, subprocess.SubprocessError, ValueError, TypeError):
            return []

    def _register(self) -> None:
        try:
            response = self.http_request("POST", "/v1/remote/hosts/register", {
                "id": self.host_id,
                "device_fingerprint": self.fingerprint,
                "display_name": os.environ.get("COMPUTERNAME", "Windows PC")[:128],
                "version": "0.1.0",
                "capabilities": self._read_capabilities(),
                "rotate_credential": True,
            }, timeout=10)
        except Exception as exc:
            print(f"[RemoteHost] register failed: {type(exc).__name__}: {exc}", file=_sys.stderr)
            return
        token = response.get("host_token", "") if isinstance(response, dict) else ""
        if isinstance(token, str) and token:
            self._store_host_token(token)
            print(f"[RemoteHost] register ok: host_id={self.host_id[:16]} token_len={len(token)}", file=_sys.stderr)
        else:
            print(f"[RemoteHost] register ok but no token in response: {response}", file=_sys.stderr)

    def _heartbeat(self) -> None:
        try:
            self._host_request(
                "POST", f"/v1/remote/hosts/{self.host_id}/heartbeat",
                {"version": "0.1.0", "capabilities": self._read_capabilities()},
                timeout=10,
            )
            print(f"[RemoteHost] heartbeat ok: host_id={self.host_id[:16]}", file=_sys.stderr)
        except Exception as exc:
            code = getattr(exc, 'code', None)
            print(f"[RemoteHost] heartbeat FAILED: {type(exc).__name__}: code={code} msg={exc}", file=_sys.stderr)
            return

    def _poll_pending(self) -> None:
        if not self.host_id:
            return
        try:
            response = self._host_request(
                "GET", f"/v1/remote/hosts/{self.host_id}/sessions/pending", timeout=5
            )
        except Exception:
            return
        items = response.get("items", [])
        if not isinstance(items, list):
            return
        for item in items:
            if not isinstance(item, dict):
                continue
            session_id = str(item.get("id", ""))
            controller_id = str(item.get("controller_device_id", ""))
            revision = item.get("revision", 0)
            if not session_id or not isinstance(revision, int):
                continue
            with self._lock:
                if session_id in self.in_flight:
                    continue
                self.in_flight.add(session_id)
            threading.Thread(
                target=self._handle_consent,
                args=(session_id, controller_id, revision, item),
                daemon=True,
                name="serein-remote-consent",
            ).start()

    def _handle_consent(self, session_id: str, controller_id: str, revision: int, item: dict) -> None:
        action = "reject"
        handoff_started = False
        try:
            print(f"[RemoteHost] consent start: session={session_id} controller={controller_id[:8]}", file=_sys.stderr)
            requested = item.get("requested_capabilities", []) if isinstance(item, dict) else []
            if (not isinstance(requested, list) or
                    requested not in (["view"], ["view", "input"])):
                print(f"[RemoteHost] rejecting invalid capabilities for session={session_id}", file=_sys.stderr)
            else:
                # The backend only exposes pending sessions created by the paired
                # primary device. GRANT records that trusted-device decision in
                # the native Host without displaying a desktop MessageBoxW.
                grant = self._pipe_call(f"GRANT {session_id}", timeout=5.0)
                if (isinstance(grant, dict) and grant.get("ok") is True and
                        grant.get("consent_granted") is True):
                    action = "accept"
                    print(f"[RemoteHost] auto-accepting primary-device session={session_id}", file=_sys.stderr)
            body = {"revision": revision}
            api_response = self._host_request(
                "POST",
                f"/v1/remote/hosts/{self.host_id}/sessions/{session_id}/{action}",
                body,
                timeout=10,
            )
            print(f"[RemoteHost] consent decision={action}", file=_sys.stderr)
            if action == "accept":
                handoff_started = True
            if action == "accept" and not self._handoff_host_ticket(session_id, api_response):
                self._pipe_call(f"END {session_id}")
                accepted = api_response.get("session", {}) if isinstance(api_response, dict) else {}
                accepted_revision = accepted.get("revision", 0) if isinstance(accepted, dict) else 0
                if isinstance(accepted_revision, int) and accepted_revision > 0:
                    try:
                        self._host_request(
                            "POST",
                            f"/v1/remote/hosts/{self.host_id}/sessions/{session_id}/end",
                            {"revision": accepted_revision, "reason": "host_transport_unavailable"},
                            timeout=10,
                        )
                    except Exception:
                        pass
        except Exception:
            # A stale duplicate accept must not terminate a session owned by
            # the other valid local agent.
            if handoff_started:
                self._pipe_call(f"END {session_id}")
            return
        finally:
            with self._lock:
                self.in_flight.discard(session_id)

    def _handoff_host_ticket(self, session_id: str, response: dict) -> bool:
        ticket_info = response.get("ticket", {}) if isinstance(response, dict) else {}
        session_info = response.get("session", {}) if isinstance(response, dict) else {}
        if not isinstance(ticket_info, dict) or not isinstance(session_info, dict):
            print(f"[RemoteHost] handoff FAIL: ticket_info={type(ticket_info).__name__} session_info={type(session_info).__name__}", file=_sys.stderr)
            return False
        ticket = ticket_info.get("ticket", "")
        expires_at = ticket_info.get("expires_at", "")
        revision = ticket_info.get("revision", 0)
        if session_info.get("id") != session_id or not isinstance(revision, int) or revision <= 0:
            print(f"[RemoteHost] handoff FAIL: session_id mismatch or bad revision. session_info.id={session_info.get('id')} revision={revision}", file=_sys.stderr)
            return False
        granted = session_info.get("granted_capabilities", [])
        if (not isinstance(granted, list) or
                granted not in (["view"], ["view", "input"])):
            print(f"[RemoteHost] handoff FAIL: invalid granted capabilities={granted}", file=_sys.stderr)
            return False
        if not isinstance(ticket, str) or len(ticket) > 4096 or REMOTE_TICKET_RE.fullmatch(ticket) is None:
            print(f"[RemoteHost] handoff FAIL: bad ticket format. len={len(ticket) if isinstance(ticket, str) else 'N/A'}", file=_sys.stderr)
            return False
        if not isinstance(expires_at, str):
            print(f"[RemoteHost] handoff FAIL: expires_at not str", file=_sys.stderr)
            return False
        try:
            from datetime import datetime
            normalized = expires_at[:-1] + "+00:00" if expires_at.endswith("Z") else expires_at
            expires_unix = int(datetime.fromisoformat(normalized).timestamp())
        except (ValueError, OverflowError):
            print(f"[RemoteHost] handoff FAIL: bad expires_at={expires_at}", file=_sys.stderr)
            return False
        if expires_unix <= int(time.time()):
            print(f"[RemoteHost] handoff FAIL: ticket expired. expires_unix={expires_unix} now={int(time.time())}", file=_sys.stderr)
            return False
        command = f"AUTHORIZE {session_id} {revision} {expires_unix} {ticket}"
        if len(command) > 8192:
            print(f"[RemoteHost] handoff FAIL: AUTHORIZE command too long {len(command)}", file=_sys.stderr)
            return False
        result = self._pipe_call(command)
        if not (isinstance(result, dict) and result.get("ok") is True and
                result.get("transport_authorized") is True):
            print(f"[RemoteHost] handoff FAIL: AUTHORIZE pipe response={result}", file=_sys.stderr)
            return False
        print(f"[RemoteHost] handoff: AUTHORIZE ok, starting stream...", file=_sys.stderr)
        if not self._start_stream(session_id):
            print(f"[RemoteHost] handoff FAIL: _start_stream returned False", file=_sys.stderr)
            return False
        print(f"[RemoteHost] handoff: stream started, launching bridge...", file=_sys.stderr)
        if not self._launch_bridge(session_id, revision, ticket, "input" in granted):
            print(f"[RemoteHost] handoff FAIL: _launch_bridge returned False", file=_sys.stderr)
            self._pipe_call(f"STREAM_STOP {session_id}")
            return False
        print(f"[RemoteHost] handoff: bridge launched successfully", file=_sys.stderr)
        return True

    def _start_stream(self, session_id: str) -> bool:
        command = (f"STREAM_START {session_id} {DEFAULT_STREAM_MONITOR} "
                   f"{DEFAULT_STREAM_FPS} {DEFAULT_STREAM_BITRATE}")
        result = self._pipe_call(command)
        return isinstance(result, dict) and result.get("ok") is True and result.get("streaming") is True

    def _launch_bridge(self, session_id: str, revision: int, ticket: str, input_enabled: bool) -> bool:
        if not self.bridge_executable.is_file() or not self.backend_url or not self.host_token:
            return False
        env = os.environ.copy()
        env["SEREIN_REMOTE_BACKEND_URL"] = self.backend_url
        env["SEREIN_REMOTE_HOST_ID"] = self.host_id
        env["SEREIN_REMOTE_HOST_TOKEN"] = self.host_token
        env["SEREIN_REMOTE_SESSION_ID"] = session_id
        env["SEREIN_REMOTE_REVISION"] = str(revision)
        env["SEREIN_REMOTE_HOST_TICKET"] = ticket
        env["SEREIN_REMOTE_STREAM_PIPE"] = STREAM_PIPE_PATH
        env["SEREIN_REMOTE_FPS"] = str(DEFAULT_STREAM_FPS)
        env["SEREIN_REMOTE_INPUT_ENABLED"] = "1" if input_enabled else "0"
        try:
            log_dir = self.agent_dir / "logs"
            log_dir.mkdir(parents=True, exist_ok=True)
            log_file = log_dir / f"bridge-{session_id[:12]}.log"
            log_fh = open(log_file, "a", encoding="utf-8")
            print(f"\n=== bridge launch {time.strftime('%Y-%m-%d %H:%M:%S')} ===", file=log_fh, flush=True)
            print(f"session={session_id} revision={revision} backend={self.backend_url}", file=log_fh, flush=True)
            print(f"pipe={STREAM_PIPE_PATH} fps={DEFAULT_STREAM_FPS} input_enabled={input_enabled}", file=log_fh, flush=True)
            proc = subprocess.Popen(
                [str(self.bridge_executable)],
                cwd=str(self.bridge_executable.parent),
                stdin=subprocess.DEVNULL,
                stdout=log_fh,
                stderr=log_fh,
                close_fds=True,
                creationflags=CREATE_NO_WINDOW | DETACHED_PROCESS,
                env=env,
            )
        except OSError:
            return False
        with self._lock:
            old = self._bridge_sessions.get(session_id)
            if old is not None and old[0].poll() is None:
                try:
                    old[0].kill()
                except OSError:
                    pass
                try:
                    old[1].close()
                except OSError:
                    pass
            self._bridge_sessions[session_id] = (proc, log_fh)
        return True

    def _check_bridge_processes(self) -> None:
        with self._lock:
            finished = []
            for session_id, (proc, log_fh) in list(self._bridge_sessions.items()):
                if proc.poll() is not None:
                    finished.append((session_id, proc.returncode, log_fh))
                    del self._bridge_sessions[session_id]
        for session_id, returncode, log_fh in finished:
            try:
                log_fh.write(f"\n=== bridge exited code={returncode} {time.strftime('%Y-%m-%d %H:%M:%S')} ===\n")
                log_fh.close()
            except OSError:
                pass
            print(f"[RemoteHost] bridge exited: session={session_id[:12]} code={returncode}", file=_sys.stderr)
            # The bridge already calls endSession on any non-zero exit. We only
            # need to stop the native capture loop so the named pipe is released.
            self._pipe_call(f"STREAM_STOP {session_id}")

    def _stop_all_bridges(self) -> None:
        with self._lock:
            sessions = list(self._bridge_sessions.items())
            self._bridge_sessions.clear()
        for session_id, (proc, log_fh) in sessions:
            try:
                proc.terminate()
            except OSError:
                pass
            try:
                proc.wait(timeout=3)
            except OSError:
                pass
            except subprocess.TimeoutExpired:
                try:
                    proc.kill()
                except OSError:
                    pass
            try:
                log_fh.close()
            except OSError:
                pass
            self._pipe_call(f"STREAM_STOP {session_id}")
            try:
                self._host_request(
                    "POST",
                    f"/v1/remote/hosts/{self.host_id}/sessions/{session_id}/end",
                    {"revision": 0, "reason": "host_shutdown"},
                    timeout=10,
                )
            except Exception:
                pass

    def _pipe_call(self, command: str, timeout: float = 5.0) -> dict | None:
        """Send a command to the native host via named pipe and read the response.

        The read has a timeout (default 5s). Without it, a stuck native host
        can block the tick thread forever — e.g. STREAM_STOP after a bridge
        crash can hang if the native host's capture loop is in a bad state,
        which would freeze all subsequent PING/heartbeat/poll calls.
        """
        if len(command) > 8192 or "\n" in command or "\r" in command:
            return None
        result: list = [None]
        def _do_call() -> None:
            fd = -1
            try:
                # Python 3.13 on Windows: built-in open() cannot access
                # \\.\pipe\ paths (returns ENOENT). Use os.open() which
                # passes the path directly to the CRT's _wopen / CreateFileW.
                fd = os.open(PIPE_PATH, os.O_RDWR)
                os.write(fd, command.encode("utf-16-le"))
                raw = os.read(fd, 8192)
                if len(raw) % 2 == 0:
                    result[0] = json.loads(raw.decode("utf-16-le"))
            except (OSError, ValueError, UnicodeError):
                pass
            finally:
                if fd >= 0:
                    try:
                        os.close(fd)
                    except OSError:
                        pass
        t = threading.Thread(target=_do_call, daemon=True)
        t.start()
        t.join(timeout)
        if t.is_alive():
            print(f"[RemoteHost] pipe_call TIMEOUT ({timeout}s) for {command[:40]}", file=_sys.stderr)
        return result[0]
