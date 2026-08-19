/**
 * serein-watchdog — watchdog agent 管理 + PID 文件
 *
 * 从 serein.mjs 提取，降低主文件体积。
 * 使用工厂函数创建实例，接收依赖对象。
 */
import { spawn, spawnSync } from 'child_process';
import { existsSync, unlinkSync, readFileSync, writeFileSync } from 'fs';
import { resolve } from 'path';

export function createWatchdog(deps) {
  const { PYTHON, AGENT_PY, AGENT_DIR, RELAY_PID_FILE } = deps;

  function writePidFile() {
    try {
      writeFileSync(RELAY_PID_FILE, String(process.pid), 'utf-8');
    } catch (e) {
      console.error(`[serein] 写入 PID 文件失败:`, e?.message || e);
    }
  }

  function removePidFile() {
    try {
      if (existsSync(RELAY_PID_FILE)) unlinkSync(RELAY_PID_FILE);
    } catch (e) {
      console.error(`[serein] 删除 PID 文件 ${RELAY_PID_FILE} 失败:`, e?.message || e);
    }
  }

  async function ensureWatchdog() {
    const agentPidFile = resolve(AGENT_DIR, '.agent.pid');

    // 1) 先查 PID 文件
    try {
      if (existsSync(agentPidFile)) {
        const pidStr = readFileSync(agentPidFile, 'utf-8').trim();
        if (!/^\d+$/.test(pidStr)) {
          console.error(`[serein] watchdog 无效 pid 文件内容 (非纯数字)，跳过: ${pidStr}`);
          try { unlinkSync(agentPidFile); } catch { /* ignored */ }
        }
        const pid = parseInt(pidStr, 10);
        if (!isNaN(pid)) {
          const result = spawnSync('powershell', [
            '-NoProfile', '-Command',
            `Get-Process -Id ${pid} -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id`
          ], { timeout: 3000, encoding: 'utf-8', windowsHide: true });
          const alive = (result.stdout || '').trim();
          if (alive) {
            console.error(`[serein] watchdog agent 已在运行 (PID=${pid})`);
            return;
          }
        }
        try { unlinkSync(agentPidFile); } catch { /* ignored */ }
      }
    } catch (e) {
      console.error('[serein] watchdog PID 检查失败:', e?.message?.slice(0, 80) || e);
    }

    // 2) 回退: PowerShell 查 local_agent.py 进程
    try {
      const result2 = spawnSync('powershell', [
        '-NoProfile', '-Command',
        'Get-Process python -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like \'*local_agent*\' }'
      ], { timeout: 5000, encoding: 'utf-8', windowsHide: true });
      if (result2.stdout && result2.stdout.trim()) {
        console.error('[serein] watchdog agent 已在运行 (PowerShell 检测)');
        return;
      }
    } catch (e) {
      console.error('[serein] watchdog 检查失败:', e?.message?.slice(0, 80) || e);
    }

    // 3) 启动 watchdog agent
    console.error('[serein] 启动 watchdog agent...');
    spawn(PYTHON, [AGENT_PY], {
      cwd: AGENT_DIR,
      detached: true,
      stdio: 'ignore',
      windowsHide: true,
    }).unref();
  }

  return { ensureWatchdog, writePidFile, removePidFile };
}
