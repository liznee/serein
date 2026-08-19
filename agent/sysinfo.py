#!/usr/bin/env python3
"""系统信息采集模块：CPU/内存/磁盘/GPU/温度/Token用量。
提取自 local_agent.py，减少主文件体积。
"""
import os, sys, json, time, glob, re, subprocess, threading, ctypes
from collections import deque
from common import (USER_HOME, estimate_cost_cny, http_req, _safe_stderr)

try:
    import psutil
except ImportError:
    psutil = None

try:
    import pythoncom
    import win32com.client
except ImportError:
    pythoncom = None
    win32com = None

# ── 告警系统 ──

ALERT_THRESHOLDS = {
    'cpu': 90,      # CPU > 90% 告警
    'gpu': 95,      # GPU 利用率 > 95% 告警
    'gpu_temp': 80, # GPU 温度 > 80°C 告警
    'mem': 90,      # 内存 > 90% 告警
}

_last_alert: dict[str, float] = {}  # metric -> 上次告警时间戳
_alert_cooldown = 300  # 同一指标 5 分钟内不重复告警


def check_alerts(sysinfo: dict) -> None:
    """检查系统信息阈值，超限则向后端推送告警通知。
    5 分钟去重，不阻塞主流程。
    """
    now = time.time()
    alerts: list[dict] = []
    cpu = sysinfo.get("cpu", 0) or 0
    mem = sysinfo.get("memory", {}) or {}
    mem_pct = mem.get("percent", 0) or 0
    gpu = sysinfo.get("gpu", {}) or {}
    gpu_util = gpu.get("util", 0) or 0
    gpu_temp = gpu.get("temp", 0) or 0

    for metric, val, threshold in [
        ("cpu", cpu, ALERT_THRESHOLDS["cpu"]),
        ("gpu", gpu_util, ALERT_THRESHOLDS["gpu"]),
        ("gpu_temp", gpu_temp, ALERT_THRESHOLDS["gpu_temp"]),
        ("mem", mem_pct, ALERT_THRESHOLDS["mem"]),
    ]:
        if val >= threshold:
            last = _last_alert.get(metric, 0.0)
            if now - last > _alert_cooldown:
                alerts.append({"metric": metric, "value": val, "threshold": threshold})
                _last_alert[metric] = now

    if alerts:
        _safe_stderr(f"[Agent alerts] 发送 {len(alerts)} 条告警: {alerts}")
        try:
            http_req("POST", "/agent/alert", {"alerts": alerts}, timeout=10)
            _safe_stderr(f"[Agent alerts] 发送成功")
        except Exception as e:
            _safe_stderr(f"[Agent alerts] 发送失败: {e}")


_last_reported_states: dict[str, bool] = {}
_last_alert_report_at: float = 0.0


def check_alerts(sysinfo: dict) -> None:
    """Report monitor state transitions; backend owns alert lifecycle dedupe."""
    global _last_alert_report_at
    now = time.time()
    mem = sysinfo.get("memory", {}) or {}
    gpu = sysinfo.get("gpu", {}) or {}
    samples = [
        ("cpu", sysinfo.get("cpu", 0) or 0, ALERT_THRESHOLDS["cpu"]),
        ("gpu", gpu.get("util", 0) or 0, ALERT_THRESHOLDS["gpu"]),
        ("gpu_temp", gpu.get("temp", 0) or 0, ALERT_THRESHOLDS["gpu_temp"]),
        ("mem", mem.get("percent", 0) or 0, ALERT_THRESHOLDS["mem"]),
    ]
    observations = [
        {"metric": metric, "value": value, "threshold": threshold, "active": value >= threshold}
        for metric, value, threshold in samples
    ]
    changed = any(_last_reported_states.get(item["metric"]) != item["active"] for item in observations)
    if not changed and now - _last_alert_report_at < _alert_cooldown:
        return
    try:
        http_req("POST", "/agent/alert", {"observations": observations}, timeout=10)
        _last_reported_states.clear()
        _last_reported_states.update({item["metric"]: item["active"] for item in observations})
        _last_alert_report_at = now
        _safe_stderr("[Agent alerts] monitor state reported")
    except Exception as e:
        # Preserve the prior state so the next monitor tick retries the change.
        _safe_stderr(f"[Agent alerts] monitor report failed: {e}")


def _powershell_metric(command: str) -> float | None:
    """执行只返回一个数字的 PowerShell 性能计数器查询。"""
    try:
        out = subprocess.run(
            ["powershell", "-NoProfile", "-Command", command],
            capture_output=True, timeout=5, text=True,
            creationflags=subprocess.CREATE_NO_WINDOW, check=True
        ).stdout.strip()
        for line in reversed(out.splitlines()):
            value = line.strip().replace(",", ".")
            try:
                return float(value)
            except ValueError:
                continue
    except Exception:
        pass
    return None


def _wmi_values(query: str, property_name: str) -> list[float] | None:
    """Read WMI in-process so periodic monitoring never opens PowerShell."""
    if win32com is None:
        return None
    initialized = False
    service = None
    items = None
    try:
        if pythoncom is not None:
            pythoncom.CoInitialize()
            initialized = True
        service = win32com.client.GetObject(r"winmgmts:\\.\root\cimv2")
        values: list[float] = []
        items = service.ExecQuery(query)
        for item in items:
            raw = getattr(item, property_name, None)
            if raw is not None:
                values.append(float(raw))
        return values
    except Exception:
        return None
    finally:
        items = None
        service = None
        if initialized:
            pythoncom.CoUninitialize()


def get_cpu_usage() -> float:
    """获取与 Windows 任务管理器更接近的即时 CPU 使用率。"""
    if psutil is not None:
        return round(max(0.0, min(100.0, psutil.cpu_percent(interval=0.12))), 1)
    value = _powershell_metric(
        '$v=(Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation '
        '-Filter "Name=\'_Total\'").PercentProcessorTime; '
        'if ($null -ne $v) { [Console]::WriteLine($v) }'
    )
    if value is not None:
        return round(max(0.0, min(100.0, value)), 1)

    # 老版本 Windows / 精简系统没有对应性能类时再回退到 WMIC。
    try:
        out = subprocess.run(
            ["wmic", "cpu", "get", "loadpercentage", "/format:csv"],
            capture_output=True, timeout=5, text=True,
            creationflags=subprocess.CREATE_NO_WINDOW, check=True
        ).stdout
        for line in out.strip().split("\n"):
            parts = line.strip().split(",")
            if len(parts) >= 2 and parts[-1].strip().isdigit():
                return float(parts[-1].strip())
    except Exception as _e:
        _safe_stderr(f"[Agent] get_cpu_usage 失败: {type(_e).__name__}: {_e}")
    return 0.0


def get_cpu_temp() -> float:
    """获取 CPU 温度（摄氏度）。
    优先用 PowerShell 读 Win32_PerfFormattedData_Counters_ThermalZoneInformation（返回十分之一开尔文），
    兜底 wmic MSAcpi_ThermalZoneTemperature。都不支持则返回 0。
    """
    if psutil is not None and hasattr(psutil, 'sensors_temperatures'):
        try:
            groups = psutil.sensors_temperatures() or {}
            readings = [entry.current for entries in groups.values() for entry in entries
                        if getattr(entry, 'current', 0) > 0]
            if readings:
                return round(max(readings), 1)
        except Exception:
            pass
    values = _wmi_values(
        'SELECT HighPrecisionTemperature FROM '
        'Win32_PerfFormattedData_Counters_ThermalZoneInformation',
        'HighPrecisionTemperature'
    )
    if values:
        celsius = [(value - 2732) / 10 for value in values if value > 0]
        if celsius:
            return round(max(celsius), 1)
    try:
        out = subprocess.run(
            ['powershell', '-NoProfile', '-Command',
             'Get-CimInstance Win32_PerfFormattedData_Counters_ThermalZoneInformation | '
             'Select-Object -ExpandProperty HighPrecisionTemperature'],
            capture_output=True, timeout=5, text=True,
            creationflags=subprocess.CREATE_NO_WINDOW, check=True
        ).stdout.strip()
        if out and out.replace('.', '').replace('-', '').isdigit():
            val = float(out.split('\n')[-1].strip())
            if val > 0:
                return round((val - 2732) / 10, 1)
    except Exception as _e:
        _safe_stderr(f"[Agent] get_cpu_temp (PS) 失败: {type(_e).__name__}: {_e}")
    # 兜底：wmic MSAcpi_ThermalZoneTemperature
    try:
        out = subprocess.run(
            ['wmic', '/namespace:\\\\root\\\\wmi', 'PATH', 'MSAcpi_ThermalZoneTemperature',
             'get', 'CurrentTemperature'],
            capture_output=True, timeout=5, text=True,
            creationflags=subprocess.CREATE_NO_WINDOW, check=True
        ).stdout
        for line in out.strip().split('\n')[1:]:
            val = line.strip()
            if val and val.isdigit():
                return round((int(val) - 2732) / 10, 1)
    except Exception as _e:
        _safe_stderr(f"[Agent] get_cpu_temp (wmic) 失败: {type(_e).__name__}: {_e}")
    return 0.0


def _parse_wmic_csv(output: str) -> dict[str, str]:
    """解析 wmic /format:csv 输出，返回 {列名: 值}。跳过标题行。"""
    lines = [l.strip() for l in output.strip().split("\n") if l.strip()]
    if len(lines) < 2:
        return {}
    headers = [h.strip() for h in lines[0].split(",")]
    for line in lines[1:]:
        vals = [v.strip() for v in line.split(",")]
        if len(vals) >= len(headers):
            return dict(zip(headers, vals))
    return {}


def get_ram_usage() -> dict:
    """获取内存使用情况（wmic，单位 MB）。"""
    if psutil is not None:
        memory = psutil.virtual_memory()
        return {
            "total_mb": round(memory.total / (1024 ** 2), 1),
            "used_mb": round(memory.used / (1024 ** 2), 1),
            "free_mb": round(memory.available / (1024 ** 2), 1),
            "percent": round(memory.percent, 1),
        }
    try:
        out = subprocess.run(
            ["wmic", "OS", "get", "TotalVisibleMemorySize,FreePhysicalMemory", "/format:csv"],
            capture_output=True, timeout=5, text=True,
            creationflags=subprocess.CREATE_NO_WINDOW, check=True
        ).stdout
        row = _parse_wmic_csv(out)
        total_kb = int(row.get("TotalVisibleMemorySize", "0"))
        free_kb = int(row.get("FreePhysicalMemory", "0"))
        if total_kb <= 0:
            return {"total_mb": 0, "used_mb": 0, "free_mb": 0, "percent": 0}
        used_kb = total_kb - free_kb
        return {
            "total_mb": round(total_kb / 1024, 1),
            "used_mb": round(used_kb / 1024, 1),
            "free_mb": round(free_kb / 1024, 1),
            "percent": round(used_kb / total_kb * 100, 1),
        }
    except Exception as _e:
        _safe_stderr(f"[Agent] get_ram_usage 失败: {type(_e).__name__}: {_e}")
    return {"total_mb": 0, "used_mb": 0, "free_mb": 0, "percent": 0}


def get_disk_usage(path: str = "C:") -> dict:
    """获取磁盘使用情况（wmic，单位 GB）。
    path 仅接受 [A-Z]: 格式的盘符，防止 WMIC 注入。
    """
    if not re.match(r'^[A-Za-z]:$', path):
        return {"total_gb": 0, "used_gb": 0, "free_gb": 0, "percent": 0}
    if psutil is not None:
        disk = psutil.disk_usage(path + '\\')
        return {
            "total_gb": round(disk.total / (1024 ** 3), 1),
            "used_gb": round(disk.used / (1024 ** 3), 1),
            "free_gb": round(disk.free / (1024 ** 3), 1),
            "percent": round(disk.percent, 1),
        }
    try:
        out = subprocess.run(
            ["wmic", "logicaldisk", "where", f"deviceid='{path}'",
             "get", "deviceid,freespace,size", "/format:csv"],
            capture_output=True, timeout=5, text=True,
            creationflags=subprocess.CREATE_NO_WINDOW, check=True
        ).stdout
        row = _parse_wmic_csv(out)
        total = int(row.get("Size", "0"))
        free = int(row.get("FreeSpace", "0"))
        if total <= 0:
            return {"total_gb": 0, "used_gb": 0, "free_gb": 0, "percent": 0}
        used = total - free
        return {
            "total_gb": round(total / (1024 ** 3), 1),
            "used_gb": round(used / (1024 ** 3), 1),
            "free_gb": round(free / (1024 ** 3), 1),
            "percent": round(used / total * 100, 1) if total > 0 else 0,
        }
    except Exception as _e:
        _safe_stderr(f"[Agent] get_disk_usage 失败: {type(_e).__name__}: {_e}")
    return {"total_gb": 0, "used_gb": 0, "free_gb": 0, "percent": 0}


class _NvmlUtilization(ctypes.Structure):
    _fields_ = [('gpu', ctypes.c_uint), ('memory', ctypes.c_uint)]


class _NvmlMemory(ctypes.Structure):
    _fields_ = [('total', ctypes.c_ulonglong), ('free', ctypes.c_ulonglong), ('used', ctypes.c_ulonglong)]


_nvml_lock = threading.Lock()
_nvml_library = None
_nvml_load_attempted = False


def _load_nvml():
    """Load NVIDIA's driver DLL in-process; no nvidia-smi console is created."""
    global _nvml_library, _nvml_load_attempted
    with _nvml_lock:
        if _nvml_load_attempted:
            return _nvml_library
        _nvml_load_attempted = True
        candidates = ['nvml.dll']
        program_files = os.environ.get('ProgramFiles', '')
        if program_files:
            candidates.append(os.path.join(program_files, 'NVIDIA Corporation', 'NVSMI', 'nvml.dll'))
        for candidate in candidates:
            try:
                library = ctypes.WinDLL(candidate)
                init = getattr(library, 'nvmlInit_v2', None) or getattr(library, 'nvmlInit', None)
                if init is not None and init() == 0:
                    _nvml_library = library
                    return library
            except (OSError, AttributeError):
                continue
        return None


def _nvml_gpu_usage() -> dict | None:
    if os.name != 'nt':
        return None
    library = _load_nvml()
    if library is None:
        return None
    try:
        handle = ctypes.c_void_p()
        get_handle = (getattr(library, 'nvmlDeviceGetHandleByIndex_v2', None)
                      or getattr(library, 'nvmlDeviceGetHandleByIndex', None))
        if get_handle is None or get_handle(0, ctypes.byref(handle)) != 0:
            return None

        name_buffer = ctypes.create_string_buffer(128)
        name = ''
        get_name = getattr(library, 'nvmlDeviceGetName', None)
        if get_name is not None and get_name(handle, name_buffer, len(name_buffer)) == 0:
            name = name_buffer.value.decode('utf-8', errors='replace')

        utilization = _NvmlUtilization()
        get_util = getattr(library, 'nvmlDeviceGetUtilizationRates', None)
        if get_util is None or get_util(handle, ctypes.byref(utilization)) != 0:
            utilization.gpu = 0

        memory = _NvmlMemory()
        get_memory = getattr(library, 'nvmlDeviceGetMemoryInfo', None)
        if get_memory is None or get_memory(handle, ctypes.byref(memory)) != 0:
            memory.total = 0
            memory.used = 0

        temperature = ctypes.c_uint(0)
        get_temperature = getattr(library, 'nvmlDeviceGetTemperature', None)
        if get_temperature is not None:
            get_temperature(handle, 0, ctypes.byref(temperature))

        total_mb = round(memory.total / (1024 ** 2), 0)
        used_mb = round(memory.used / (1024 ** 2), 0)
        return {
            'name': name,
            'util': float(utilization.gpu),
            'mem_used_mb': used_mb,
            'mem_total_mb': total_mb,
            'mem_percent': round(used_mb / total_mb * 100, 1) if total_mb > 0 else 0,
            'temp': float(temperature.value),
        }
    except (OSError, AttributeError, TypeError, ValueError):
        return None


def get_gpu_usage() -> dict:
    """获取 GPU 利用率 + NVIDIA 显存、名称和温度。

    利用率优先使用 Windows GPU Engine 最忙引擎，与任务管理器的 GPU 百分比
    口径一致；性能计数器不可用时才回退到 nvidia-smi 的核心忙碌率。
    非 N 卡或无 nvidia-smi 时返回零值，不影响主流程。
    """
    try:
        in_process = _nvml_gpu_usage()
        if in_process is not None:
            gpu_values = _wmi_values(
                'SELECT UtilizationPercentage FROM '
                'Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine',
                'UtilizationPercentage'
            )
            if gpu_values:
                in_process['util'] = round(max(0.0, min(100.0, max(gpu_values))), 1)
            return in_process

        out = subprocess.run(
            ['nvidia-smi',
             '--query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu',
             '--format=csv,noheader,nounits'],
            capture_output=True, timeout=5, text=True,
            creationflags=subprocess.CREATE_NO_WINDOW, check=True
        ).stdout.strip()
        if not out:
            return {"name": "", "util": 0, "mem_used_mb": 0, "mem_total_mb": 0, "mem_percent": 0, "temp": 0}
        first = out.split('\n')[0]
        parts = [p.strip() for p in first.split(',')]
        name = parts[0] if len(parts) > 0 else ''
        nvidia_util = float(parts[1]) if len(parts) > 1 and parts[1] else 0
        mem_used = float(parts[2]) if len(parts) > 2 and parts[2] else 0
        mem_total = float(parts[3]) if len(parts) > 3 and parts[3] else 0
        mem_pct = round(mem_used / mem_total * 100, 1) if mem_total > 0 else 0
        temp = float(parts[4]) if len(parts) > 4 and parts[4] else 0
        gpu_values = _wmi_values(
            'SELECT UtilizationPercentage FROM '
            'Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine',
            'UtilizationPercentage'
        )
        task_manager_util = max(gpu_values) if gpu_values else None
        util = task_manager_util if task_manager_util is not None else nvidia_util
        return {
            "name": name,
            "util": round(max(0.0, min(100.0, util)), 1),
            "mem_used_mb": round(mem_used, 0),
            "mem_total_mb": round(mem_total, 0),
            "mem_percent": mem_pct,
            "temp": temp,
        }
    except Exception as _e:
        _safe_stderr(f"[Agent] get_gpu_usage 失败: {type(_e).__name__}: {_e}")
    return {"name": "", "util": 0, "mem_used_mb": 0, "mem_total_mb": 0, "mem_percent": 0, "temp": 0}


# 硬件型号信息缓存（型号不变，进程生命周期内只采集一次）
_hw_info_cache: dict | None = None


def get_hardware_info() -> dict:
    """采集硬件型号信息（CPU/RAM/DISK/GPU/主板）。型号不变，缓存只采一次。"""
    global _hw_info_cache
    if _hw_info_cache is not None:
        return _hw_info_cache
    info = {"cpu": "", "ram": "", "disk": "", "gpu": "", "board": ""}
    try:
        # CPU 型号
        try:
            out = subprocess.run(['wmic', 'cpu', 'get', 'name'], capture_output=True, timeout=5, text=True, creationflags=subprocess.CREATE_NO_WINDOW, check=True).stdout
            lines = [l.strip() for l in out.strip().split('\n') if l.strip()]
            if len(lines) > 1:
                info["cpu"] = lines[1]
        except Exception as _e:
            _safe_stderr(f"[Agent] get_hardware_info CPU: {type(_e).__name__}: {_e}")
        # RAM：每条容量+型号，汇总成 "4x8GB Gloway DDR4-3200" 之类
        try:
            out = subprocess.run(
                ['wmic', 'memorychip', 'get', 'capacity,manufacturer,partnumber,speed'],
                capture_output=True, timeout=5, text=True,
                creationflags=subprocess.CREATE_NO_WINDOW, check=True).stdout
            lines = [l.strip() for l in out.strip().split('\n') if l.strip()]
            sticks = []
            for line in lines[1:]:
                parts = line.split()
                if not parts:
                    continue
                try:
                    cap_bytes = int(parts[0])
                except ValueError:
                    continue
                cap_gb = round(cap_bytes / (1024 ** 3))
                rest = ' '.join(parts[1:]).strip()
                sticks.append(f"{cap_gb}GB {rest}".strip())
            if sticks:
                info["ram"] = f"{len(sticks)}x " + sticks[0]
        except Exception as _e:
            _safe_stderr(f"[Agent] get_hardware_info RAM: {type(_e).__name__}: {_e}")
        # DISK 型号
        try:
            out = subprocess.run(['wmic', 'diskdrive', 'get', 'model'], capture_output=True, timeout=5, text=True, creationflags=subprocess.CREATE_NO_WINDOW, check=True).stdout
            lines = [l.strip() for l in out.strip().split('\n') if l.strip()]
            if len(lines) > 1:
                info["disk"] = lines[1]
        except Exception as _e:
            _safe_stderr(f"[Agent] get_hardware_info DISK: {type(_e).__name__}: {_e}")
        # GPU 型号（复用 nvidia-smi）
        try:
            gpu = get_gpu_usage()
            info["gpu"] = gpu.get("name", "")
        except Exception as _e:
            _safe_stderr(f"[Agent] get_hardware_info GPU: {type(_e).__name__}: {_e}")
        # 主板
        try:
            out = subprocess.run(
                ['wmic', 'baseboard', 'get', 'manufacturer,product'], capture_output=True, timeout=5, text=True,
                creationflags=subprocess.CREATE_NO_WINDOW, check=True).stdout
            lines = [l.strip() for l in out.strip().split('\n') if l.strip()]
            if len(lines) > 1:
                info["board"] = lines[1]
        except Exception as _e:
            _safe_stderr(f"[Agent] get_hardware_info 主板: {type(_e).__name__}: {_e}")
    except Exception as _e:
        _safe_stderr(f"[Agent] get_hardware_info 失败: {type(_e).__name__}: {_e}")
    _hw_info_cache = info
    return info


def get_token_stats() -> dict:
    """统计最近 7 天所有会话的 token 用量 + 缓存命中率 + 估算成本(元)。"""
    try:
        cutoff = time.time() - 7 * 86400
        total_input = 0
        total_output = 0
        total_cache_read = 0
        msg_count = 0
        model_name = "unknown"
        total_cost = 0.0  # 元
        sessions_dir = os.path.join(USER_HOME, ".claude", "projects")
        for entry in os.listdir(sessions_dir):
            if entry.lower().endswith("-serein"):
                sdir = os.path.join(sessions_dir, entry)
                if os.path.isdir(sdir):
                    for fname in os.listdir(sdir):
                        if not fname.endswith(".jsonl"):
                            continue
                        fpath = os.path.join(sdir, fname)
                        if os.path.getmtime(fpath) < cutoff:
                            continue
                        with open(fpath, "r", encoding="utf-8") as f:
                            for line in f:
                                try:
                                    msg = json.loads(line)
                                    inner = msg.get("message")
                                    if not isinstance(inner, dict):
                                        inner = {}
                                    usage = msg.get("usage")
                                    if not isinstance(usage, dict):
                                        usage = inner.get("usage")
                                    if isinstance(usage, dict):
                                        inp = usage.get("input_tokens", 0) or 0
                                        out = usage.get("output_tokens", 0) or 0
                                        cache = usage.get("cache_read_input_tokens", 0) or 0
                                        total_input += inp
                                        total_output += out
                                        total_cache_read += cache
                                        msg_count += 1
                                        mdl = inner.get("model")
                                        if isinstance(mdl, str) and mdl != "":
                                            total_cost += estimate_cost_cny(mdl, inp, out, cache)
                                        if model_name == "unknown" and isinstance(mdl, str) and mdl != "":
                                            model_name = mdl
                                except Exception:
                                    pass
        total_tokens = total_input + total_output
        total_relevant = total_input + total_cache_read
        hit_rate = round(total_cache_read / total_relevant * 100, 1) if total_relevant > 0 else 0
        return {
            "estimated_tokens": total_tokens,
            "messages": msg_count,
            "model": model_name,
            "cache_hit_rate": hit_rate,
            "cost_cny": round(total_cost, 2),
            "input_tokens": total_input,
            "output_tokens": total_output,
            "cache_tokens": total_cache_read,
        }
    except Exception as _e:
        _safe_stderr(f"[Agent] get_token_stats 失败: {type(_e).__name__}: {_e}")
    return {"estimated_tokens": 0, "messages": 0, "model": "unknown", "cache_hit_rate": 0, "cost_cny": 0}


def collect_sysinfo() -> dict:
    """采集系统信息，失败时返回零值。"""
    try:
        gpu = get_gpu_usage()
        gpu["temp"] = gpu.get("temp", 0)
        return {
            "cpu": get_cpu_usage(),
            "cpu_temp": get_cpu_temp(),
            "memory": get_ram_usage(),
            "disk": get_disk_usage(),
            "gpu": gpu,
            "tokens": get_token_stats(),
            "hardware": get_hardware_info(),
        }
    except Exception as _e:
        _safe_stderr(f"[Agent] collect_sysinfo 失败: {type(_e).__name__}: {_e}")
        return {"cpu": 0, "cpu_temp": 0, "memory": {"total_mb": 0, "used_mb": 0, "free_mb": 0, "percent": 0},
                "disk": {"total_gb": 0, "used_gb": 0, "free_gb": 0, "percent": 0},
                "gpu": {"name": "", "util": 0, "mem_used_mb": 0, "mem_total_mb": 0, "mem_percent": 0, "temp": 0},
                "tokens": {"estimated_tokens": 0, "messages": 0, "model": "unknown"},
                "hardware": {"cpu": "", "ram": "", "disk": "", "gpu": "", "board": ""}}
