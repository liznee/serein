#!/usr/bin/env node
/**
 * serein — serein Claude Code Relay (PTY TUI + JSONL 双通道模式)
 *
 * 架构（方案 C 改进版）：
 * - PTY TUI 进程：node-pty → claude.exe 交互式 TUI 模式
 *   PC 用户看到完整的原生 Claude TUI 界面，支持斜杠命令、直接打字交互
 *   PTY stdout 纯粹用于 PC 屏幕显示，不解析推送到手机端
 * - JSONL 文件监听：轮询 session JSONL 文件
 *   解析结构化 JSON 事件（thinking/text/tool_use/tool_result）
 *   通过 WebSocket cmd_step 推送到手机端
 *
 * 优势：
 * - PC 体验：100% 原生 Claude TUI（spinner、颜色、斜杠命令）
 * - 手机数据：全部结构化 JSON，无 ANSI/spinner 噪声
 * - 单次 API 调用（不翻倍成本）
 * - 无响应不一致问题
 * - serein-thinking.mjs 那套 720 行复杂正则状态机不再需要
 *
 * 启动文件写入 .relay.pid，供 local_agent.py watchdog 检测。
 */

import { createRequire } from 'module';
import { existsSync, readFileSync, writeFileSync, unlinkSync, mkdirSync, renameSync } from 'fs';
import { writeFile } from 'fs/promises';
import { fileURLToPath } from 'url';
import { dirname, resolve, join } from 'path';
import { homedir } from 'os';
import { sanitizeLog } from './serein-util.mjs';
import { createWsSendQueue, createWsHeartbeat } from './serein-ws.mjs';
import { createWatchdog } from './serein-watchdog.mjs';
import { createJsonlWatcher } from './serein-jsonl.mjs';
import { createCodexJsonlWatcher } from './codex-jsonl.mjs';
import { getAgentConfig, normalizeAgentType } from './agent-registry.mjs';
import { isAgentTrustPrompt } from './trust-prompt.mjs';
import { createCodexPromptDetector } from './codex-pty-prompt.mjs';
import {
  buildCodexApprovalResult,
  CODEX_DESKTOP_SOURCE_KINDS,
  CodexAppServerProvider,
  isCodexDesktopThread,
  normalizeCodexThreadStatus,
} from './codex-app-server.mjs';
import { CodexAppEventAdapter, historyEventsFromThread } from './codex-app-events.mjs';
import { CodexThreadLeaseManager } from './codex-thread-lease.mjs';

const require = createRequire(import.meta.url);
const WebSocket = require('ws');
const pty = require('node-pty');
let qrTerminal = null;
try { qrTerminal = require('qrcode-terminal'); } catch (_) { /* optional dep */ }

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

// ── 动态主目录 ──
const _home = process.env.USERPROFILE || homedir();

// ── 配置（全部动态解析，零硬编码路径）──
const AGENT_DIR = process.env.SEREIN_AGENT_DIR || __dirname;
const AGENT_PY = process.env.SEREIN_AGENT_PY ||
  join(AGENT_DIR, 'local_agent.py');

// Python: 环境变量 > which/where > 常见路径探测
function findPython() {
  if (process.env.SEREIN_PYTHON) return process.env.SEREIN_PYTHON;
  const { execSync } = require('child_process');
  // 用 which/where 解析完整路径（existsSync 需要绝对路径）
  const whichCmd = process.platform === 'win32' ? 'where' : 'which';
  for (const cmd of process.platform === 'win32' ? ['python', 'py', 'python3'] : ['python3', 'python']) {
    try {
      execSync(cmd + ' --version', { stdio: 'pipe', timeout: 5000 });
      // 找到可用命令，解析完整路径
      try {
        const fullPath = execSync(whichCmd + ' ' + cmd, { encoding: 'utf-8', timeout: 5000 }).trim().split(/\r?\n/)[0];
        if (fullPath && existsSync(fullPath)) return fullPath;
      } catch { /* where 失败，回退到命令名 */ }
      return cmd; // 命令可用但无法解析路径（仍可作为 spawn 命令使用）
    } catch { /* try next */ }
  }
  // Windows 常见安装路径
  if (process.platform === 'win32') {
    for (const ver of ['Python313', 'Python312', 'Python311', 'Python310']) {
      const p = join(_home, 'AppData/Local/Programs/Python', ver, 'python.exe');
      if (existsSync(p)) return p;
    }
  }
  return 'python';
}
const PYTHON = findPython();

// ── Agent 类型配置（多 Agent 支持）──
let AGENT_TYPE = 'claude';
try {
  AGENT_TYPE = normalizeAgentType(process.env.SEREIN_AGENT_TYPE || 'claude');
} catch (error) {
  console.error(`[serein] ${error.message}`);
  process.exit(1);
}
const _agentCfg = getAgentConfig(AGENT_TYPE);

// Agent 二进制查找：环境变量 > which/where > npm 全局路径
function findAgentBinary() {
  const cfg = _agentCfg;
  // 1. 环境变量
  if (process.env[cfg.envVar]) return process.env[cfg.envVar];
  // 2. which/where
  const { execSync } = require('child_process');
  try {
    const which = process.platform === 'win32' ? `where ${cfg.binaryName}` : `which ${cfg.binaryName}`;
    const results = execSync(which, { encoding: 'utf-8', timeout: 5000 }).trim().split(/\r?\n/);
    // Windows: 优先选 .cmd（pty.spawn 可执行）
    if (process.platform === 'win32') {
      const cmd = results.find(r => r.toLowerCase().endsWith('.cmd'));
      if (cmd) return cmd;
      const exe = results.find(r => r.toLowerCase().endsWith('.exe'));
      if (exe) return exe;
    }
    if (results[0]) return results[0];
  } catch { /* not in PATH */ }
  // 3. npm 全局路径
  if (process.platform === 'win32') {
    if (cfg.npmPath) {
      const cmdPath = join(_home, cfg.npmPath);
      if (existsSync(cmdPath)) return cmdPath;
    }
    if (cfg.npmFallback) {
      return join(_home, cfg.npmFallback);
    }
  }
  return join(_home, '.npm-global/lib/node_modules/' + cfg.binaryName + '/bin/' + cfg.binaryName);
}
const AGENT_EXE = findAgentBinary();

// ── 项目自动检测 ──
// 从 ~/.serein/projects.json 加载已注册项目（零硬编码）
function loadKnownProjects() {
  const projects = {};
  const projectsFile = join(_home, '.serein', 'projects.json');
  try {
    if (existsSync(projectsFile)) {
      const data = JSON.parse(readFileSync(projectsFile, 'utf-8'));
      if (data && typeof data === 'object') {
        for (const [name, ppath] of Object.entries(data)) {
          if (typeof ppath === 'string') projects[name] = ppath;
        }
      }
    }
  } catch { /* file not ready yet */ }
  return projects;
}
const KNOWN_PROJECTS = loadKnownProjects();

/**
 * 自动检测项目路径和名称。
 * 优先级：
 *   1. 环境变量 SEREIN_PROJECT（手机 Start → do_start 设置）
 *   2. 命令行参数 serein <project>（如 serein serein）
 *   3. CWD 匹配已知项目路径（含子目录）
 *   4. CWD 不匹配时，使用 CWD 作为项目路径，basename 作为项目名
 */
function detectProject() {
  // 1. 环境变量（手机 Start → do_start 设置）
  if (process.env.SEREIN_PROJECT) {
    const name = process.env.SEREIN_PROJECT_NAME || basename(process.env.SEREIN_PROJECT.replace(/\\/g, '/'));
    return { path: process.env.SEREIN_PROJECT, name };
  }

  // 2. 命令行参数：serein serein
  const cliArgs = process.argv.slice(2).filter(a => !a.startsWith('-'));
  if (cliArgs.length > 0 && KNOWN_PROJECTS[cliArgs[0]]) {
    return { path: KNOWN_PROJECTS[cliArgs[0]], name: cliArgs[0] };
  }

  // 3. CWD 匹配已知项目路径（含子目录）
  const cwd = process.cwd().replace(/\\/g, '/');
  for (const [name, ppath] of Object.entries(KNOWN_PROJECTS)) {
    const normalized = ppath.toLowerCase();
    if (cwd.toLowerCase() === normalized || cwd.toLowerCase().startsWith(normalized + '/')) {
      return { path: KNOWN_PROJECTS[name], name };
    }
  }

  // 4. CWD 不匹配已知项目，使用 CWD 作为项目路径
  return { path: process.cwd(), name: basename(cwd) };
}

function basename(p) {
  return p.replace(/\/$/, '').split('/').pop() || p;
}

const { path: PROJECT_PATH, name: PROJECT_NAME } = detectProject();
const BACKEND = process.env.SEREIN_BACKEND;
if (!BACKEND) {
  console.error('[serein] 错误: 环境变量 SEREIN_BACKEND 未设置');
  process.exit(1);
}
const PAIR_CODE = process.env.SEREIN_PAIR_CODE || '';
let HOOK_TOKEN = process.env.SEREIN_HOOK_TOKEN;
if (!HOOK_TOKEN) {
  try {
    const settingsPath = resolve(
      process.env.USERPROFILE || process.env.HOME || _home,
      '.claude', 'settings.json'
    );
    if (existsSync(settingsPath)) {
      const data = JSON.parse(readFileSync(settingsPath, 'utf-8'));
      HOOK_TOKEN = (data.env || {}).SEREIN_HOOK_TOKEN || '';
    }
  } catch (e) {
    console.error('[serein] 读取 settings.json HOOK_TOKEN 失败:', e?.message || e);
  }
}
if (!BACKEND.startsWith('https://')) {
  console.warn(`[serein] 提醒：后端使用非加密连接（HTTP），Token 可能被截获`);
}
const WS_PROTO = BACKEND.startsWith('https://') ? 'wss://' : 'ws://';
const WS_URL = BACKEND.replace(/\/$/, '').replace(/^https?:\/\//, WS_PROTO) + '/ws';
const RELAY_PID_FILE = resolve(AGENT_DIR, '.relay.pid');
const RELAY_QUIT_FILE = resolve(AGENT_DIR, '.relay_quit');
const RELAY_PROJECT_FILE = resolve(AGENT_DIR, '.relay_project');
const RELAY_SCOPE_FILE = resolve(AGENT_DIR, '.relay_scope');
const RELAY_RUNTIME_FILE = resolve(AGENT_DIR, '.relay_runtime');
const RUNTIME_MODE = String(process.env.SEREIN_RUNTIME_MODE || 'cli').trim().toLowerCase();
const WORK_SCOPE = String(process.env.SEREIN_WORK_SCOPE || '').trim();
const REQUESTED_SEREIN_SESSION_ID = String(process.env.SEREIN_SESSION_ID || '').trim();
const REQUESTED_AGENT_SESSION_ID = String(process.env.SEREIN_AGENT_SESSION_ID || '').trim();
const AGENT_SESSION_MODE = String(
  process.env.SEREIN_AGENT_SESSION_MODE || (REQUESTED_AGENT_SESSION_ID ? 'resume' : '')
).trim().toLowerCase();
const WORK_SCOPE_RE = /^[A-Za-z0-9._:/-]{1,500}$/;
const SEREIN_SESSION_RE = /^[A-Za-z0-9._-]{1,100}$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const COLLABORATION_SESSIONS_FILE = join(_home, '.serein', 'collaboration_sessions.json');

if (!['cli', 'desktop'].includes(RUNTIME_MODE)) {
  console.error('[serein] invalid runtime mode');
  process.exit(1);
}
if (RUNTIME_MODE === 'desktop' && AGENT_TYPE !== 'codex') {
  console.error('[serein] desktop runtime requires Codex');
  process.exit(1);
}

if (WORK_SCOPE && !WORK_SCOPE_RE.test(WORK_SCOPE)) {
  console.error('[serein] invalid collaboration work scope');
  process.exit(1);
}
if (REQUESTED_SEREIN_SESSION_ID && !SEREIN_SESSION_RE.test(REQUESTED_SEREIN_SESSION_ID)) {
  console.error('[serein] invalid Serein transport session id');
  process.exit(1);
}
if (REQUESTED_AGENT_SESSION_ID && !UUID_RE.test(REQUESTED_AGENT_SESSION_ID)) {
  console.error('[serein] invalid Agent session id');
  process.exit(1);
}
if (AGENT_SESSION_MODE && !['new', 'resume'].includes(AGENT_SESSION_MODE)) {
  console.error('[serein] invalid Agent session mode');
  process.exit(1);
}
if (AGENT_SESSION_MODE && !REQUESTED_AGENT_SESSION_ID) {
  console.error('[serein] Agent session mode requires a session id');
  process.exit(1);
}
if (AGENT_TYPE === 'codex' && AGENT_SESSION_MODE === 'new') {
  console.error('[serein] Codex creates session ids itself; explicit new session ids are unsupported');
  process.exit(1);
}

function recordCollaborationSession(agentSessionID) {
  if (!WORK_SCOPE || !UUID_RE.test(agentSessionID)) return;
  try {
    const directory = dirname(COLLABORATION_SESSIONS_FILE);
    mkdirSync(directory, { recursive: true });
    let current = { version: 1, sessions: {} };
    if (existsSync(COLLABORATION_SESSIONS_FILE)) {
      const raw = readFileSync(COLLABORATION_SESSIONS_FILE, 'utf-8');
      const parsed = JSON.parse(raw);
      if (parsed && parsed.version === 1 && parsed.sessions && typeof parsed.sessions === 'object') {
        current = parsed;
      }
    }
    current.sessions[WORK_SCOPE] = {
      agent_session_id: agentSessionID,
      agent_type: AGENT_TYPE,
      project: PROJECT_NAME,
      updated_at: new Date().toISOString(),
    };
    const entries = Object.entries(current.sessions)
      .sort((a, b) => String(b[1]?.updated_at || '').localeCompare(String(a[1]?.updated_at || '')))
      .slice(0, 500);
    current.sessions = Object.fromEntries(entries);
    const temporary = COLLABORATION_SESSIONS_FILE + '.tmp';
    writeFileSync(temporary, JSON.stringify(current, null, 2), { encoding: 'utf-8', mode: 0o600 });
    renameSync(temporary, COLLABORATION_SESSIONS_FILE);
  } catch (error) {
    console.error('[serein] 保存协作会话索引失败:', error?.message || error);
  }
}

if (WORK_SCOPE && REQUESTED_AGENT_SESSION_ID) {
  recordCollaborationSession(REQUESTED_AGENT_SESSION_ID);
}

// ── Session JSONL 目录（根据 agent 类型动态选择）──
// C:/workspace/serein → C--workspace-serein
const sessionDirName = PROJECT_PATH
.replace(/[/\\]+$/, '')
.replace(/[/\\]/g, '-')
.replace(/:/g, '-');
const SESSION_DIR = _agentCfg.sessionLayout === 'global-nested'
  ? join(_home, ..._agentCfg.sessionDirBase.split('/'))
  : join(_home, ..._agentCfg.sessionDirBase.split('/'), sessionDirName);

// ── PTY 状态 ──
let ptyProcess = null;
let ptyReady = false;
let lastCtrlC = 0;

// ── JSONL 监听器 ──
let jsonlWatcher = null;
let codexPromptDetector = null;

// ── 状态 ──
let ws = null;
let sessionId = '';
let seq = 0;
let wsReconnectTimer = null;
let joinAckReceived = false;
let manualCleanup = false;
let fallbackTimer = null;

// ── WS 重连指数退避 ──
let wsReconnectAttempt = 0;
const WS_RECONNECT_BASE = 5000;
const WS_RECONNECT_MAX = 30000;

// 预加入消息缓冲
let preJoinBuffer = [];
const MAX_PREJOIN_BUFFER = 50;

// WS 重连缓冲
let ptyBuffer = [];
let ptyBufferTotalBytes = 0;
const MAX_PTY_BUFFER_BYTES = 5 * 1024 * 1024;

// ── Daemon 模式标记 ──
let daemonMode = process.argv.includes('--daemon');
const qrOnlyMode = process.argv.includes('--qr');

// WS 发送队列 / 心跳 / Watchdog 实例
let wsSender = null;
let heartbeat = null;
let watchdog = null;
let codexAppServerProvider = null;
let codexAppEventAdapter = null;
let codexDesktopWarmPromise = null;
let codexDesktopThreadCache = null;
const codexDesktopVisibleThreads = new Map();
const CODEX_DESKTOP_LIST_CACHE_MS = 10_000;
const codexThreadLeases = new CodexThreadLeaseManager();
const CODEX_DESKTOP_OWNER = process.env.SEREIN_DEVICE_ID || `relay-${process.pid}`;
let codexDesktopActiveThreadId = null;
const codexDesktopApprovalRequests = new Map();

// ════════════════════════════════════════════
// sendStep — 发送 cmd_step 到 WS 或缓冲
// ════════════════════════════════════════════

function sendStep(content, eventType, toolName) {
  // 结构性标记允许空内容通过；desktop_history_reset 用于在切换桌面会话时
  // 清空上一条会话的手机端显示。
  if (!content && eventType !== 'turn_start' && eventType !== 'turn_end'
      && eventType !== 'desktop_history_reset') return;
  seq++;
  const stepMsg = JSON.stringify({
    type: 'cmd_step',
    session_id: sessionId,
    seq: seq,
    source: 'terminal',
    timestamp: new Date().toISOString(),
    payload: {
      event: eventType || 'text',
      name: toolName || '',
      content: content,
      seq: seq,
    },
  });
  if (ws && ws.readyState === WebSocket.OPEN && joinAckReceived) {
    wsSender.wsEnqueue(stepMsg);
  } else {
    ptyBuffer.push({ data: content, timestamp: new Date().toISOString(), event: eventType || 'text', name: toolName || '' });
    ptyBufferTotalBytes += Buffer.byteLength(content, 'utf8');
    while (ptyBuffer.length > 1024 || ptyBufferTotalBytes > MAX_PTY_BUFFER_BYTES) {
      const removed = ptyBuffer.shift();
      if (removed) ptyBufferTotalBytes -= Buffer.byteLength(removed.data, 'utf8');
    }
  }
}

function isDesktopCommand(content) {
  return /^\/desktop(?:\s|$)/i.test(String(content || '').trim());
}

function summarizeDesktopThread(thread) {
  return {
    id: thread?.id || thread?.threadId || null,
    title: thread?.title || thread?.name || null,
    cwd: thread?.cwd || null,
    source: thread?.source || thread?.sourceKind || null,
    status: normalizeCodexThreadStatus(thread),
    updatedAt: thread?.updatedAt || thread?.updated_at || null,
    path: thread?.path || null,
    turns: Array.isArray(thread?.turns) ? thread.turns.length : undefined,
  };
}

function normalizeCwd(value) {
  return String(value || '').replace(/[\\/]+$/, '').replace(/\\/g, '/').toLowerCase();
}

function isDesktopThreadForCurrentProject(thread) {
  return isCodexDesktopThread(thread) && normalizeCwd(thread?.cwd) === normalizeCwd(PROJECT_PATH);
}

function desktopNotificationThreadId(message) {
  const params = message?.params || {};
  return params.threadId || params.thread_id || params.thread?.id || params.turn?.threadId || null;
}

function handleCodexDesktopNotification(message) {
  const method = String(message?.method || '');
  if (!codexDesktopActiveThreadId || !method) return;
  const threadId = desktopNotificationThreadId(message);
  if (threadId && threadId !== codexDesktopActiveThreadId) return;
  // Forward only session/turn/item notifications. This keeps unrelated App
  // Server account/config notifications out of the phone terminal.
  const isSessionProtocolEvent = /^(thread|turn|item)\//.test(method)
    || method.startsWith('server/request') || method.startsWith('error/')
    || method === 'execCommandApproval' || method === 'applyPatchApproval';
  if (!isSessionProtocolEvent) return;
  // Convert the App Server protocol into the same terminal event vocabulary
  // used by CLI mode. In particular, agent-message deltas are coalesced by
  // item id so the phone can replace one live block instead of appending one
  // line per token.
  codexAppEventAdapter?.handle(message);
  if (message.id != null) {
    codexDesktopApprovalRequests.set(String(message.id), {
      id: message.id,
      method,
      threadId: threadId || codexDesktopActiveThreadId,
    });
  }
  if (method === 'turn/completed') codexDesktopApprovalRequests.clear();
  // item delta 已由上面的适配器转成终端事件，不再把原始 JSON
  // 重复发给手机。只保留轮次状态和需要用户处理的请求。
  const shouldForwardControl = message.id != null
    || method === 'turn/started' || method === 'turn/completed'
    || method.startsWith('server/request');
  if (!shouldForwardControl) return;
  sendStep(JSON.stringify({
    ok: true,
    action: 'notification',
    threadId: codexDesktopActiveThreadId,
    method,
    requestId: message.id ?? null,
    requiresApproval: message.id != null,
    params: message.params || {},
  }), message.id != null ? 'desktop_approval_required' : 'desktop_notification', 'codex-app-server');
}

function ensureCodexDesktopProvider() {
  if (!codexAppEventAdapter) {
    codexAppEventAdapter = new CodexAppEventAdapter({
      onEvent: (eventType, eventContent, toolName) => sendStep(eventContent, eventType, toolName),
    });
  }
  if (!codexAppServerProvider) {
    codexAppServerProvider = new CodexAppServerProvider({
      cwd: PROJECT_PATH,
      onNotification: handleCodexDesktopNotification,
    });
  }
  return codexAppServerProvider;
}

async function refreshCodexDesktopThreadCache() {
  const startedAt = Date.now();
  const provider = ensureCodexDesktopProvider();
  const result = await provider.listThreads({ sourceKinds: CODEX_DESKTOP_SOURCE_KINDS });
  const threads = result.threads.filter(isDesktopThreadForCurrentProject);
  codexDesktopVisibleThreads.clear();
  for (const thread of threads) {
    const id = String(thread?.id || thread?.threadId || '');
    if (id) codexDesktopVisibleThreads.set(id, thread);
  }
  codexDesktopThreadCache = {
    updatedAt: Date.now(),
    nextCursor: result.nextCursor,
    threads,
  };
  console.error(`[serein] desktop cache refreshed: total=${result.threads.length} current_project=${threads.length} in ${Date.now() - startedAt}ms`);
  return codexDesktopThreadCache;
}

function warmCodexDesktopBridge(force = false) {
  if (RUNTIME_MODE !== 'desktop' || AGENT_TYPE !== 'codex') return Promise.resolve(null);
  const cacheAge = codexDesktopThreadCache ? Date.now() - codexDesktopThreadCache.updatedAt : Infinity;
  if (!force && codexDesktopThreadCache && cacheAge < CODEX_DESKTOP_LIST_CACHE_MS) {
    return Promise.resolve(codexDesktopThreadCache);
  }
  if (codexDesktopWarmPromise) return codexDesktopWarmPromise;
  codexDesktopWarmPromise = refreshCodexDesktopThreadCache()
    .finally(() => { codexDesktopWarmPromise = null; });
  return codexDesktopWarmPromise;
}

function sendCodexDesktopThreadList(cache, cached = false) {
  const provider = ensureCodexDesktopProvider();
  sendStep(JSON.stringify({
    ok: true,
    action: 'list',
    cwd: PROJECT_PATH,
    cached,
    capabilities: provider.capabilities,
    nextCursor: cache?.nextCursor ?? null,
    threads: (cache?.threads || []).map(summarizeDesktopThread),
  }), 'desktop_thread_list', 'codex-app-server');
}

async function handleDesktopCommand(content) {
  if (AGENT_TYPE !== 'codex') {
    sendStep(JSON.stringify({
      ok: false,
      error: 'Codex Desktop 会话控制仅对 Codex 项目启用，当前项目是 Claude Code。',
    }), 'desktop_error', 'codex-app-server');
    return true;
  }

  const command = String(content || '').trim().replace(/^\/desktop\s*/i, '');
  const args = command.split(/\s+/).filter(Boolean);
  const subcommand = (args[0] || '').toLowerCase();
  const threadId = args[1] || '';
  console.error(`[serein] desktop command: ${subcommand || '(empty)'}${threadId ? ` thread=${threadId.slice(0, 8)}` : ''}`);
  if (!['list', 'read', 'take', 'renew', 'send', 'interrupt', 'approve', 'release'].includes(subcommand)) {
    sendStep(JSON.stringify({
      ok: false,
      error: '用法：/desktop list、/desktop read <thread-id>、/desktop take <thread-id>、/desktop release <thread-id> <lease-id>',
    }), 'desktop_error', 'codex-app-server');
    return true;
  }

  try {
    const provider = ensureCodexDesktopProvider();
    if (subcommand.toLowerCase() === 'list') {
      const cacheAge = codexDesktopThreadCache ? Date.now() - codexDesktopThreadCache.updatedAt : Infinity;
      if (codexDesktopThreadCache) {
        // The selector should never wait on a local process round trip when a
        // valid snapshot already exists. A stale snapshot is shown first and
        // refreshed in the background.
        sendCodexDesktopThreadList(codexDesktopThreadCache, true);
        console.error(`[serein] desktop list: cache hit age=${cacheAge}ms current_project=${codexDesktopThreadCache.threads.length}`);
        if (cacheAge >= CODEX_DESKTOP_LIST_CACHE_MS) {
          void warmCodexDesktopBridge(true)
            .then((fresh) => { if (fresh) sendCodexDesktopThreadList(fresh, false); })
            .catch((error) => console.error(`[serein] desktop background refresh failed: ${error?.message || error}`));
        }
        return true;
      }
      const fresh = await warmCodexDesktopBridge(true);
      sendCodexDesktopThreadList(fresh, false);
      return true;
    }

    if (!threadId) {
      sendStep(JSON.stringify({ ok: false, error: '缺少 thread-id' }), 'desktop_error', 'codex-app-server');
      return true;
    }

    if (subcommand === 'take') {
      // A thread returned by the current-project list is already scoped. If a
      // caller supplies an unseen id, perform a cheap metadata read before any
      // resume operation so a different project's thread can never be opened.
      let listedThread = codexDesktopVisibleThreads.get(threadId) || null;
      if (!listedThread) {
        listedThread = await provider.readThread(threadId, { includeTurns: false });
      }
      if (!isDesktopThreadForCurrentProject(listedThread)) {
        sendStep(JSON.stringify({
          ok: false,
          error: '这个会话不属于当前项目，无法打开。',
          threadCwd: listedThread?.cwd || null,
          threadSource: listedThread?.source || listedThread?.sourceKind || null,
          projectCwd: PROJECT_PATH,
        }), 'desktop_error', 'codex-app-server');
        return true;
      }
      const lease = codexThreadLeases.acquire(threadId, CODEX_DESKTOP_OWNER);
      if (!lease.granted) {
        sendStep(JSON.stringify({ ok: false, error: '这个会话当前正在使用，请稍后再打开。' }), 'desktop_error', 'codex-app-server');
        return true;
      }
      try {
        const startedAt = Date.now();
        console.error(`[serein] desktop take: opening thread=${threadId.slice(0, 8)}`);
        codexDesktopActiveThreadId = threadId;
        codexAppEventAdapter?.reset();
        // History is read in parallel with resume. The phone can enter the
        // session as soon as resume succeeds instead of waiting for every old
        // turn to be serialized first.
        const historyPromise = provider.readThread(threadId, { includeTurns: true })
          .then((thread) => ({ thread, error: null }))
          .catch((error) => ({ thread: null, error }));
        const resumed = await provider.resumeThread(threadId, { excludeTurns: true });
        sendStep(JSON.stringify({
          ok: true,
          action: 'take',
          leaseId: lease.leaseId,
          expiresAt: lease.expiresAt,
          thread: summarizeDesktopThread(resumed || listedThread),
          capabilities: provider.capabilities,
        }), 'desktop_thread_taken', 'codex-app-server');
        console.error(`[serein] desktop take: resumed thread=${threadId.slice(0, 8)} in ${Date.now() - startedAt}ms`);
        // The lease/control event must reach the phone before a long history
        // replay starts. Otherwise 200+ history frames can fill the bounded WS
        // queue in one tick and evict desktop_thread_taken from its head.
        const controlFlushed = await wsSender.waitForQueueBelow(0, 1500);
        if (!controlFlushed) {
          console.error(`[serein] desktop take: history deferred because control frame is still queued thread=${threadId.slice(0, 8)}`);
          return true;
        }
        const history = await historyPromise;
        if (history.thread) {
          const historyEvents = historyEventsFromThread(history.thread);
          for (let index = 0; index < historyEvents.length; index++) {
            const event = historyEvents[index];
            sendStep(event.content, event.type, event.toolName);
            // Keep the phone responsive and apply backpressure before the
            // bounded queue can discard older structured events.
            if ((index + 1) % 24 === 0) {
              const batchFlushed = await wsSender.waitForQueueBelow(4, 1500);
              if (!batchFlushed) {
                console.error(`[serein] desktop take: history replay stopped at ${index + 1}/${historyEvents.length} because WS is congested`);
                break;
              }
            }
          }
          console.error(`[serein] desktop take: history ready thread=${threadId.slice(0, 8)} events=${historyEvents.length} in ${Date.now() - startedAt}ms`);
        } else {
          console.error(`[serein] desktop take: history unavailable thread=${threadId.slice(0, 8)}: ${history.error?.message || history.error}`);
        }
      } catch (error) {
        if (codexDesktopActiveThreadId === threadId) codexDesktopActiveThreadId = null;
        codexThreadLeases.release(threadId, lease.leaseId, CODEX_DESKTOP_OWNER);
        throw error;
      }
      return true;
    }

    if (subcommand === 'renew') {
      const leaseId = args[2] || '';
      if (!leaseId) {
        sendStep(JSON.stringify({ ok: false, error: 'renew requires lease-id' }), 'desktop_error', 'codex-app-server');
        return true;
      }
      const renewed = codexThreadLeases.renew(threadId, leaseId, CODEX_DESKTOP_OWNER);
      sendStep(JSON.stringify({ ok: renewed.granted, action: 'renew', ...renewed }), 'desktop_lease_renewed', 'codex-app-server');
      return true;
    }

    if (subcommand === 'send') {
      const leaseId = args[2] || '';
      const sendMatch = command.match(/^send\s+\S+\s+\S+\s+([\s\S]+)$/i);
      const text = String(sendMatch?.[1] || '').trim();
      if (!leaseId || !text) {
        sendStep(JSON.stringify({ ok: false, error: 'send requires lease-id and text' }), 'desktop_error', 'codex-app-server');
        return true;
      }
      const ownership = codexThreadLeases.assertOwner(threadId, leaseId, CODEX_DESKTOP_OWNER);
      if (!ownership.granted) {
        sendStep(JSON.stringify({ ok: false, error: '会话连接已过期，请重新打开。' }), 'desktop_error', 'codex-app-server');
        return true;
      }
      codexDesktopActiveThreadId = threadId;
      const turn = await codexAppServerProvider.startTurn(threadId, text);
      sendStep(JSON.stringify({
        ok: true,
        action: 'send',
        threadId,
        leaseId,
        expiresAt: ownership.expiresAt,
        turn,
      }), 'desktop_turn_started', 'codex-app-server');
      return true;
    }

    if (subcommand === 'interrupt') {
      const leaseId = args[2] || '';
      const turnId = args[3] || '';
      if (!leaseId || !turnId) {
        sendStep(JSON.stringify({ ok: false, error: 'interrupt requires lease-id and turn-id' }), 'desktop_error', 'codex-app-server');
        return true;
      }
      const ownership = codexThreadLeases.assertOwner(threadId, leaseId, CODEX_DESKTOP_OWNER);
      if (!ownership.granted) {
        sendStep(JSON.stringify({ ok: false, error: '会话连接已过期，请重新打开。' }), 'desktop_error', 'codex-app-server');
        return true;
      }
      const result = await codexAppServerProvider.interruptTurn(threadId, turnId);
      sendStep(JSON.stringify({ ok: true, action: 'interrupt', threadId, turnId, result }), 'desktop_turn_interrupted', 'codex-app-server');
      return true;
    }

    if (subcommand === 'approve') {
      const leaseId = args[2] || '';
      const requestId = args[3] || '';
      const decision = (args[4] || '').toLowerCase();
      if (!leaseId || !requestId || !['allow', 'deny'].includes(decision)) {
        sendStep(JSON.stringify({ ok: false, error: '这个确认请求已失效，请等待 Codex 重新发起。' }), 'desktop_error', 'codex-app-server');
        return true;
      }
      const ownership = codexThreadLeases.assertOwner(threadId, leaseId, CODEX_DESKTOP_OWNER);
      if (!ownership.granted) {
        sendStep(JSON.stringify({ ok: false, error: '会话连接已过期，请重新打开。' }), 'desktop_error', 'codex-app-server');
        return true;
      }
      const pending = codexDesktopApprovalRequests.get(requestId);
      if (!pending || pending.threadId !== threadId) {
        sendStep(JSON.stringify({ ok: false, error: '这个确认请求已失效。' }), 'desktop_error', 'codex-app-server');
        return true;
      }
      const result = buildCodexApprovalResult(pending.method, decision);
      codexAppServerProvider.respondToRequest(pending.id, result);
      codexDesktopApprovalRequests.delete(requestId);
      sendStep(JSON.stringify({
        ok: true,
        action: 'approve',
        requestId,
        decision,
      }), 'desktop_approval_resolved', 'codex-app-server');
      return true;
    }

    if (subcommand === 'release') {
      const leaseId = args[2] || '';
      if (!leaseId) {
        sendStep(JSON.stringify({ ok: false, error: '关闭会话失败，请重新打开后再试。' }), 'desktop_error', 'codex-app-server');
        return true;
      }
      const released = codexThreadLeases.release(threadId, leaseId, CODEX_DESKTOP_OWNER);
      if (released.released && codexDesktopActiveThreadId === threadId) {
        codexDesktopActiveThreadId = null;
        codexAppEventAdapter?.reset();
        codexDesktopApprovalRequests.clear();
        // “关闭会话”只释放当前 Thread 的控制权。保留通用 App Server
        // 进程和列表缓存，用户再次选择会话时无需重新冷启动本地服务。
      }
      sendStep(JSON.stringify({ ok: released.released, action: 'release', ...released }), 'desktop_lease_released', 'codex-app-server');
      return true;
    }

    const thread = await codexAppServerProvider.readThread(threadId, { includeTurns: true });
    if (!isDesktopThreadForCurrentProject(thread)) {
      sendStep(JSON.stringify({
        ok: false,
        error: '这个会话不属于当前项目，无法打开。',
      }), 'desktop_error', 'codex-app-server');
      return true;
    }
    sendStep(JSON.stringify({
      ok: true,
      action: 'read',
      thread: summarizeDesktopThread(thread),
    }), 'desktop_thread_read', 'codex-app-server');
  } catch (error) {
    console.error(`[serein] desktop ${subcommand || 'command'} failed: ${error?.message || String(error)}`);
    sendStep(JSON.stringify({
      ok: false,
      error: error?.message || String(error),
    }), 'desktop_error', 'codex-app-server');
  }
  return true;
}

// ════════════════════════════════════════════
// WS 连接
// ════════════════════════════════════════════

function connectWS() {
  const isReconnect = wsReconnectAttempt > 0;
  if (ws) {
    try {
      ws.removeAllListeners('close');
      ws.removeAllListeners('error');
      ws.close();
    } catch { /* ignored */ }
    ws = null;
  }

  console.error(`[serein] 连接 WS: ${WS_URL}`);
  joinAckReceived = false;
  sessionId = '';
  // Initial startup begins with clean buffers. During reconnect, however,
  // structured tool events and the final turn_end may already be waiting;
  // clearing here leaves the phone permanently stuck on "thinking".
  if (!isReconnect) {
    ptyBuffer = [];
    ptyBufferTotalBytes = 0;
    wsSender.clearWsSendQueue();
    preJoinBuffer = [];
  }

  const wsOptions = WS_URL.startsWith('wss://') ? { rejectUnauthorized: true } : {};
  const newWs = new WebSocket(WS_URL, wsOptions);

  newWs.on('open', () => {
    console.error('[serein] WS 已连接');
    wsReconnectAttempt = 0;
    heartbeat.startWsHeartbeat();
    newWs.send(JSON.stringify({
      type: 'join',
      session_id: REQUESTED_SEREIN_SESSION_ID,
      client_type: 'terminal',
      client_id: 'relay-' + process.pid,
      project: PROJECT_NAME,
      token: HOOK_TOKEN,
    }));
  });

  newWs.on('message', (raw) => {
    try {
      const msg = JSON.parse(raw.toString());
      handleWSMessage(msg);
    } catch (e) {
      console.error(`[serein] WS 消息解析失败:`, e?.message || e);
    }
  });

  newWs.on('close', () => {
    console.error('[serein] WS 已断开');
    heartbeat.stopWsHeartbeat();
    if (ws === newWs) { ws = null; }
    if (manualCleanup) {
      console.error('[serein] 手动清理，跳过 WS 重连');
      return;
    }
    scheduleReconnect();
  });

  newWs.on('error', (err) => {
    console.error('[serein] WS 错误:', err?.message || err);
  });

  ws = newWs;
  return newWs;
}

function scheduleReconnect() {
  if (wsReconnectTimer) clearTimeout(wsReconnectTimer);
  wsReconnectAttempt++;
  const delay = Math.min(
    WS_RECONNECT_BASE * (1 << Math.min(wsReconnectAttempt - 1, 3)),
    WS_RECONNECT_MAX
  );
  console.error(`[serein] ${wsReconnectAttempt} 次重连，${delay / 1000}s 后重试...`);
  wsReconnectTimer = setTimeout(() => {
    console.error('[serein] 重连 WS...');
    connectWS();
  }, delay);
}

// ════════════════════════════════════════════
// WS 消息处理
// ════════════════════════════════════════════

function flushPtyBuffer() {
  if (ptyBuffer.length === 0) return;
  console.error(`[serein] 推送重连缓冲: ${ptyBuffer.length} 条`);
  let sentCount = 0;
  let flushedBytes = 0;
  for (const bufItem of ptyBuffer) {
    if (!ws || ws.readyState !== WebSocket.OPEN) break;
    const content = bufItem.data;
    flushedBytes += Buffer.byteLength(content, 'utf8');
    seq++;
    const stepMsg = JSON.stringify({
      type: 'cmd_step',
      session_id: sessionId,
      seq: seq,
      source: 'terminal',
      timestamp: bufItem.timestamp,
      payload: {
        event: bufItem.event || 'text',
        name: bufItem.name || '',
        content: content,
        seq: seq,
      },
    });
    wsSender.wsEnqueue(stepMsg);
    sentCount++;
  }
  if (sentCount > 0) {
    ptyBuffer.splice(0, sentCount);
    ptyBufferTotalBytes -= flushedBytes;
  }
  console.error(`[serein] 重连缓冲推送完成: 已发送 ${sentCount}/${ptyBuffer.length + sentCount}`);
}

function handleJoinAck(msg) {
  sessionId = (msg.payload || {}).session_id || '';
  console.error(`[serein] 加入会话: ${sessionId}`);
  joinAckReceived = true;
  if (fallbackTimer) { clearTimeout(fallbackTimer); fallbackTimer = null; }
  wsSender.resumeWsSendQueue();
  flushPtyBuffer();
  // 处理预加入缓冲
  if (preJoinBuffer.length > 0) {
    console.error(`[serein] 处理预加入缓冲: ${preJoinBuffer.length} 条`);
    for (const bufferedMsg of preJoinBuffer) {
      if (bufferedMsg === 'RESET_RELAY') {
        resetPtySession();
        continue;
      }
      sendToPty(bufferedMsg);
    }
    preJoinBuffer = [];
  }
}

function handleSessionMsg(msg) {
  const incomingPayload = msg.payload || {};
  const incomingContent = (typeof incomingPayload === 'object' && incomingPayload !== null)
    ? incomingPayload.content : '';
  if (isDesktopCommand(incomingContent)) {
    void handleDesktopCommand(incomingContent);
    return;
  }

  if (RUNTIME_MODE === 'desktop') {
    sendStep(JSON.stringify({
      ok: false,
      error: '当前运行的是桌面会话桥接，请在桌面会话面板中选择 Thread 后发送。',
    }), 'desktop_error', 'codex-app-server');
    return;
  }

  if (!joinAckReceived) {
    const content = incomingContent;
    if (content) {
      preJoinBuffer.push(content);
      if (preJoinBuffer.length > MAX_PREJOIN_BUFFER) {
        preJoinBuffer.shift();
      }
    }
    return;
  }
  const payload = msg.payload || {};
  let content = (typeof payload === 'object' && payload !== null)
    ? payload.content : '';

  if (content === 'RESET_RELAY') {
    console.error(`[serein] 收到 RESET_RELAY 信号，重置 PTY 会话`);
    resetPtySession();
    sendStep('[PTY 会话已重置]', 'text');
    return;
  }

  // /clear 命令：重置 JSONL 监听器（新 session 文件将被检测到）
  if (content.trim() === '/clear' || content.trim() === '/reset') {
    if (jsonlWatcher) jsonlWatcher.reset();
    // 仍然转发到 PTY，让 TUI 执行 /clear
  }

  if (content) {
    console.error(`[serein] 手机→PTY: [${content.length} chars]`);

    // 长度校验
    if (content.length > 8000) {
      console.error(`[serein] 手机消息过长 (${content.length})，截断至 8000`);
      content = content.slice(0, 8000);
    }
    // Unicode 可打印字符白名单
    if (!/^[\p{L}\p{M}\p{N}\p{P}\p{S}\p{Z} \t\n\r]*$/u.test(content)) {
      console.warn('[serein] 手机消息包含非法字符，丢弃');
      return;
    }

    // 纯数字 = 选项选择，静默发送（压制 CMD 回显）
    const isChoiceSelection = /^\d{1,2}$/.test(content.trim());
    if (isChoiceSelection && codexPromptDetector) {
      codexPromptDetector.resolve();
    }
    sendToPty(content, isChoiceSelection);
    return;
  }
}

function handleCmdResult(msg) {
  // cmd_result 由手机端直接处理，relay 不重复输出
}

/**
 * handleFileTransfer — 接收后端 file_transfer WS 消息，下载文件并写入项目 uploads/ 目录。
 * 
 * 流程：
 * 1. 后端收到手机上传的原始二进制文件，存入内存 fileStore
 * 2. 后端通过 WS 推送 file_transfer 消息给 relay（绕过命令队列轮询）
 * 3. relay 通过 HTTP GET 下载原始二进制文件（无 Base64 编码）
 * 4. relay 写入 PROJECT_PATH/uploads/ 目录
 * 5. relay 通过 WS cmd_result 回传结果给手机端
 * 
 * 相比旧方案（Base64 + 命令队列）的优势：
 * - 无 Base64 编码/解码（节省 33% 带宽 + CPU 时间）
 * - 无命令队列轮询延迟（WS 即时推送）
 * - 原始二进制 HTTP 传输（高效、标准）
 */
async function handleFileTransfer(msg) {
  const payload = msg.payload || {};
  const fileId = payload.file_id || '';
  const fileName = payload.file_name || 'uploaded_file';
  const project = payload.project || PROJECT_NAME;
  const size = payload.size || 0;

  if (!fileId) {
    console.error('[serein] file_transfer: 缺少 file_id');
    return;
  }

  const t0 = Date.now();
  console.error(`[serein] file_transfer: 收到通知 file_id=${fileId} name=${fileName} size=${size}`);

  // 构建下载 URL
  const downloadUrl = `${BACKEND}/agent/file/${fileId}`;
  
  try {
    const t1 = Date.now();
    // HTTP GET 下载原始二进制文件
    const response = await fetch(downloadUrl, {
      headers: { 'Authorization': `Bearer ${HOOK_TOKEN}` },
    });

    if (!response.ok) {
      throw new Error(`HTTP ${response.status}: ${response.statusText}`);
    }

    const buffer = Buffer.from(await response.arrayBuffer());
    const t2 = Date.now();

    // 确保 uploads 目录存在
    const uploadDir = join(PROJECT_PATH, 'uploads');
    mkdirSync(uploadDir, { recursive: true });

    // 安全文件名：只保留 basename，防止路径穿越
    const safeName = fileName.replace(/[/\\]/g, '_');
    const destPath = join(uploadDir, safeName);

    // 写入文件
    await writeFile(destPath, buffer);
    const t3 = Date.now();

    console.error(`[serein] file_transfer: 完成 name=${safeName} size=${buffer.length} ` +
      `download=${t2 - t1}ms write=${t3 - t2}ms total=${t3 - t0}ms path=${destPath}`);

    // 通过 WS cmd_result 回传结果给手机端
    // 复用 cmd_result 消息类型，手机端 onCmdResult 检测到 path/filename 字段后
    // 自动调用 handleFileUploadResult。
    const resultMsg = JSON.stringify({
      type: 'cmd_result',
      session_id: sessionId,
      source: 'terminal',
      payload: {
        cmd_id: fileId,
        success: true,
        output: {
          ok: true,
          path: destPath,
          filename: safeName,
          project: project,
        },
      },
    });
    if (ws && ws.readyState === WebSocket.OPEN && joinAckReceived) {
      wsSender.wsEnqueue(resultMsg);
      console.error(`[serein] file_transfer: cmd_result 已发送 (relay总耗时 ${Date.now() - t0}ms)`);
    } else {
      console.error(`[serein] file_transfer: WS 未连接，cmd_result 未发送!`);
    }
  } catch (err) {
    console.error(`[serein] file_transfer: 下载/写入失败 (${Date.now() - t0}ms): ${err?.message || err}`);
    
    // 回传错误结果
    const errMsg = JSON.stringify({
      type: 'cmd_result',
      session_id: sessionId,
      source: 'terminal',
      payload: {
        cmd_id: fileId,
        success: false,
        output: {
          error: err?.message || 'download or write failed',
        },
      },
    });
    if (ws && ws.readyState === WebSocket.OPEN && joinAckReceived) {
      wsSender.wsEnqueue(errMsg);
    }
  }
}

function handleWSMessage(msg) {
  switch (msg.type) {
    case 'join_ack':
      handleJoinAck(msg);
      break;
    case 'session_msg':
      handleSessionMsg(msg);
      break;
    case 'history':
      break;
    case 'cmd_result':
    case 'result':
      handleCmdResult(msg);
      break;
    case 'file_transfer':
      handleFileTransfer(msg);
      break;
    case 'error':
      console.error('[serein] 后端错误:', JSON.stringify(msg.payload || msg).slice(0, 500));
      break;
    default:
      if (msg.type !== 'history' && msg.type !== 'result' && msg.type !== 'heartbeat' && msg.type !== 'cmd_result' && msg.type !== 'file_transfer') {
        console.error(`[serein] 未处理的 WS 消息类型: ${msg.type} payload=${sanitizeLog(JSON.stringify(msg.payload || {}).slice(0, 200))}`);
      }
      break;
  }
}

// ════════════════════════════════════════════
// PTY 管理 — node-pty 交互式 TUI
// ════════════════════════════════════════════

function filterRelayEnv() {
  const SEREIN_ENV_BLOCKLIST = new Set(['HOOK_TOKEN', 'SEREIN_HOOK_TOKEN']);
  const safeEnv = Object.fromEntries(
    Object.entries(process.env).filter(([k]) => !SEREIN_ENV_BLOCKLIST.has(k))
  );
  const agentProxy = String(process.env.SEREIN_AGENT_PROXY || '').trim();
  if (agentProxy) {
    // Keep Serein's own backend connection direct; only the spawned AI agent
    // receives the optional proxy settings.
    safeEnv.HTTP_PROXY = agentProxy;
    safeEnv.HTTPS_PROXY = agentProxy;
    safeEnv.ALL_PROXY = agentProxy;
  }
  safeEnv.TERM = 'xterm-256color';
  safeEnv.LANG = 'en_US.UTF-8';
  return safeEnv;
}

/**
 * 启动 PTY TUI 进程
 * claude.exe 以交互式 TUI 模式运行，PC 用户看到完整的原生界面
 */
function spawnPty() {
  // 不加 --dangerously-skip-permissions：该参数在 TUI 模式下会显示警告对话框
  // 需要用户手动确认。权限审批通过 hooks/approval_hook.py 处理。
  const args = [];
  if (REQUESTED_AGENT_SESSION_ID) {
    if (AGENT_TYPE === 'codex') {
      args.push('resume', REQUESTED_AGENT_SESSION_ID);
    } else if (AGENT_SESSION_MODE === 'new') {
      args.push('--session-id', REQUESTED_AGENT_SESSION_ID);
    } else {
      args.push('--resume', REQUESTED_AGENT_SESSION_ID);
    }
  }

  console.error(`[serein] 启动 ${_agentCfg.displayName} PTY TUI: ${AGENT_EXE}`);
  console.error(`[serein] Session 目录: ${SESSION_DIR}`);

  ptyProcess = pty.spawn(AGENT_EXE, args, {
    name: 'xterm-256color',
    cols: process.stdout.columns || 120,
    rows: process.stdout.rows || 40,
    cwd: PROJECT_PATH,
    env: filterRelayEnv(),
  });

  // ── PTY stdout → PC 屏幕显示（纯显示，不解析推送到手机）──
  // 选项选择时短暂压制回显（TUI 会显示 ❯ N，需过滤掉）
  // 自动信任检测：Claude / Codex 在新目录首次启动时都会弹出目录确认。
  // 这里只匹配两者明确的目录信任界面，不启用危险的全局免审批参数。
  let trustPromptHandled = false;
  let dataBuffer = '';
  codexPromptDetector = AGENT_TYPE === 'codex'
    ? createCodexPromptDetector((eventType, content, toolName) => sendStep(content, eventType, toolName))
    : null;
  ptyProcess.onData((data) => {
    // ── 信任/升级提示推送手机 ──
    // Claude Code 的目录信任和升级提示推送到手机端作为可选项，
    // 用户可以在手机上点选而非只能在电脑端操作（与 Codex 行为统一）。
    if (!trustPromptHandled) {
      dataBuffer += data.toString('utf8');
      if (isAgentTrustPrompt(AGENT_TYPE, dataBuffer)) {
        trustPromptHandled = true;
        // 推送信任选项到手机：与 Codex 行为统一，用户可在手机上点选
        const trustId = 'claude-trust-' + Date.now();
        sendStep(JSON.stringify({
          question_id: trustId,
          question: '首次打开此项目，是否信任该目录？',
          header: '目录信任',
        }), 'question', trustId);
        // 选项纯文本格式：每行一个 "N. label"，与 Codex 选项格式一致
        sendStep('1. 是，信任此目录\n2. 否，退出', 'choice', trustId);
        // 15s 超时自动选 Yes
        const trustTimer = setTimeout(() => {
          if (ptyProcess && ptyReady) {
            ptyProcess.write('\r');
            console.error(`[serein] 信任提示超时，自动确认`);
          }
          sendStep(JSON.stringify({ question_id: trustId, resolved: true, auto: true }), 'question_resolved', trustId);
        }, 15000);
      } else if (dataBuffer.length > 65536) {
        // 保留尾部滑动窗口，不清除 trustPromptHandled
        // Claude Code 启动时 TUI 输出可达 32KB+，信任提示在启动后期才出现
        dataBuffer = dataBuffer.slice(-8192);
      }
    }

    // Codex 的额度/模型切换等 TUI 选择框不会写入 session JSONL。
    // 仅提取带选中标记的明确编号选项，转换为与 JSONL 相同的结构化事件。
    if (codexPromptDetector) {
      codexPromptDetector.push(data.toString('utf8'));
    }

    if (suppressEchoUntil > 0 && Date.now() < suppressEchoUntil) {
      // 在压制窗口内：尝试过滤掉回显行，只丢弃纯回显 chunk
      // TUI 回显通常是 "❯ N\r\n" 或带 ANSI 的短序列
      const str = data.toString('utf8');
      // 如果这个 chunk 很短且包含选项编号 → 判定为回显，丢弃
      if (str.length < 30 && /❯\s*\d/.test(str)) {
        return; // 丢弃回显
      }
      // 否则放行（可能是 TUI 重绘）
      suppressEchoUntil = 0; // 停止压制
    }
    if (!daemonMode && process.stdout.writable) {
      process.stdout.write(data);
    }
    // 手机端数据来自 JSONL 监听器，不从这里解析
  });

  // ── PTY 退出 ──
  ptyProcess.onExit(({ exitCode, signal }) => {
    console.error(`[serein] PTY 退出: code=${exitCode} signal=${signal}`);
    ptyProcess = null;
    ptyReady = false;
    if (jsonlWatcher) {
      jsonlWatcher.stop();
      jsonlWatcher = null;
    }
    codexPromptDetector = null;
    // PTY 退出 = claude.exe 退出，relay 也退出
    if (!manualCleanup) {
      console.error('[serein] PTY 退出，relay 清理中...');
      cleanup();
      process.exit(exitCode || 0);
    }
  });

  // Each Agent uses its own JSONL adapter. Codex's nested global sessions
  // cannot be parsed with Claude Code's project-slug session format.
  if (_agentCfg.supportsStructuredEvents) {
    const watcherDeps = {
      onEvent: (eventType, content, toolName) => sendStep(content, eventType, toolName),
      onSession: (agentSessionID) => {
        recordCollaborationSession(agentSessionID);
        sendStep(agentSessionID, 'agent_session', AGENT_TYPE);
      },
    };
    jsonlWatcher = _agentCfg.eventAdapter === 'codex'
      ? createCodexJsonlWatcher({
          ...watcherDeps,
          sessionRoot: SESSION_DIR,
          projectPath: PROJECT_PATH,
        })
      : createJsonlWatcher({
          ...watcherDeps,
          sessionDir: SESSION_DIR,
        });
    jsonlWatcher.start();
    if (!_agentCfg.supportsApprovalHook) {
      console.warn(`[serein] ${_agentCfg.displayName} 的结构化会话已启用，但工具审批仍为实验能力`);
      sendStep(`${_agentCfg.displayName} 已启用结构化会话；工具审批尚未达到 Claude Code 的完整兼容级别。`, 'hook', 'compatibility');
    }
  } else {
    console.warn(`[serein] ${_agentCfg.displayName} 为实验性启动兼容层：结构化输出和审批 Hook 尚未适配`);
    sendStep(`${_agentCfg.displayName} 当前为实验模式，暂不提供结构化会话输出和工具审批。`, 'hook', 'compatibility');
  }

  ptyReady = true;
}

/**
 * 发送消息到 PTY（来自手机或本地输入）
 * 写入文本 + 回车，让 TUI 处理
 */
let suppressEchoUntil = 0;  // 压制回显的时间戳，>0 时生效
let pendingEnterTimer = null;  // 延迟回车定时器（防止 TUI 粘贴检测吞掉 \r）

function sendToPty(text, silent = false) {
  if (!ptyProcess || !ptyReady) {
    console.error('[serein] PTY 未运行，消息丢弃');
    return;
  }
  if (silent) {
    // 设定 500ms 压制窗口，过滤 TUI 的 ❯ N 回显
    suppressEchoUntil = Date.now() + 500;
  }
  console.error(`[serein] → PTY: [${text.length} chars] "${text.substring(0, 60)}${text.length > 60 ? '...' : ''}"${silent ? ' (silent)' : ''}`);

  // 长文本（>10 字符）：分离文本和回车写入，避免 TUI 的粘贴检测
  // 将整块 text+\r 当作粘贴操作，导致 \r 被当作换行而非提交键。
  // Codex 会在快速字符流结束后继续保留约 120ms 的 Enter 抑制窗口；
  // 过早发送 Enter 会插入换行而不会提交，因此 Codex 使用更长的安全间隔。
  if (text.length > 10) {
    // 取消上一个待发送的回车（防止快速连续调用导致回车错位）
    if (pendingEnterTimer) {
      clearTimeout(pendingEnterTimer);
    }
    ptyProcess.write(text);
    const submitDelayMs = AGENT_TYPE === 'codex' ? 250 : 50;
    pendingEnterTimer = setTimeout(() => {
      pendingEnterTimer = null;
      if (ptyProcess && ptyReady) {
        ptyProcess.write('\r');
      }
    }, submitDelayMs);
  } else {
    // 短文本（选项编号等）：直接写 text+\r，无延迟
    ptyProcess.write(text + '\r');
  }
}

/**
 * 重置 PTY 会话（RESET_RELAY）
 * 杀死当前 PTY，重新启动
 */
function resetPtySession() {
  if (RUNTIME_MODE === 'desktop') {
    sendStep(JSON.stringify({ ok: false, error: '桌面会话桥接没有可重置的 CLI PTY。' }), 'desktop_error', 'codex-app-server');
    return;
  }
  if (ptyProcess) {
    try {
      ptyProcess.kill();
    } catch (e) {
      console.error('[serein] kill PTY 失败:', e?.message || e);
    }
    ptyProcess = null;
  }
  if (jsonlWatcher) {
    jsonlWatcher.stop();
    jsonlWatcher = null;
  }
  // 重新启动
  setTimeout(() => {
    spawnPty();
  }, 500);
}

// ════════════════════════════════════════════
// PC 键盘输入（终端窗口直接打字）
// ════════════════════════════════════════════

function setupLocalInput() {
  if (daemonMode || !process.stdin.isTTY) return;

  try {
    // Raw 模式：所有按键直接发送到 PTY，包括方向键、Tab 等
    process.stdin.setRawMode(true);
    process.stdin.resume();

    process.stdin.on('data', (data) => {
      if (!ptyProcess) return;

      // 双击 Ctrl+C (0x03) 退出 relay
      if (data.length === 1 && data[0] === 0x03) {
        const now = Date.now();
        if (now - lastCtrlC < 1000) {
          console.error('\n[serein] 双击 Ctrl+C，退出...');
          cleanup();
          process.exit(0);
          return;
        }
        lastCtrlC = now;
        // 单击 Ctrl+C 转发到 PTY（claude.exe 处理为中断）
      }

      // PC 端在 Codex 选择框按 Enter 后，同步清理手机端待处理选项。
      if (codexPromptDetector && data.includes(0x0d)) {
        codexPromptDetector.resolve();
      }

      // 转发所有输入到 PTY
      ptyProcess.write(data);
    });

    // 终端大小变化时同步 PTY
    process.stdout.on('resize', () => {
      if (ptyProcess) {
        ptyProcess.resize(
          process.stdout.columns || 120,
          process.stdout.rows || 40
        );
      }
    });

    console.error('[serein] 本地键盘输入已启用（双击 Ctrl+C 退出）');
  } catch (e) {
    console.error('[serein] 本地输入初始化失败:', e?.message || e);
  }
}

// ════════════════════════════════════════════
// 启动路径校验
// ════════════════════════════════════════════

function validatePaths() {
  const requiredPaths = [
    { key: _agentCfg.envVar, path: AGENT_EXE, label: _agentCfg.binaryNameWin },
    { key: 'PYTHON', path: PYTHON, label: 'Python 解释器', skipExistsCheck: true },
    { key: 'AGENT_PY', path: AGENT_PY, label: 'Agent 脚本' },
    { key: 'PROJECT_PATH', path: PROJECT_PATH, label: '项目目录' },
    { key: 'AGENT_DIR', path: AGENT_DIR, label: 'Agent 目录' },
  ];
  let ok = true;
  for (const p of requiredPaths) {
    if (!p.path) {
      console.error(`[serein] 配置缺失: ${p.label} (${p.key}) — 请设置环境变量 ${p.key}`);
      ok = false;
    } else if (!existsSync(p.path) && !p.skipExistsCheck) {
      // 命令名（如 'python'）不是文件路径，existsSync 会失败，跳过
      console.error(`[serein] 路径不存在: ${p.label}=${p.path} — 请检查环境变量 ${p.key} 或安装路径`);
      ok = false;
    }
  }
  if (ok && !/\.(?:cmd|bat)$/i.test(AGENT_EXE)) {
    try {
      const { spawnSync } = require('child_process');
      const probe = spawnSync(AGENT_EXE, ['--version'], {
        encoding: 'utf8',
        timeout: 5000,
        windowsHide: true,
      });
      if (probe.error || probe.status !== 0) {
        const reason = probe.error?.message || String(probe.stderr || '').trim() || `exit ${probe.status}`;
        console.error(`[serein] ${_agentCfg.displayName} 路径存在但无法执行: ${AGENT_EXE}`);
        console.error(`[serein] 原因: ${reason}`);
        console.error(`[serein] 请安装可从终端运行的 ${_agentCfg.binaryName} CLI，或设置 ${_agentCfg.envVar}`);
        ok = false;
      }
    } catch (error) {
      console.error(`[serein] 无法验证 ${_agentCfg.displayName}: ${error?.message || error}`);
      ok = false;
    }
  }
  if (!ok) {
    console.error('[serein] 启动路径校验失败，退出');
    process.exit(1);
  }
}

// ════════════════════════════════════════════
// 项目二维码 — 终端 ASCII QR 渲染
// ════════════════════════════════════════════

/**
 * 构建项目绑定 QR payload。
 * 格式: JSON {"name":"项目名","backendUrl":"后端地址"}
 * 手机端 handleScanAddProject 已支持此格式解析。
 */
function buildProjectQRPayload() {
  const payload = { name: PROJECT_NAME, backendUrl: BACKEND };
  if (PAIR_CODE) payload.pairCode = PAIR_CODE;
  return JSON.stringify(payload);
}

/**
 * 在终端打印项目二维码（ASCII art）。
 * 用户用手机 App 扫码即可将项目添加到手机端。
 */
function printProjectQR() {
  const payload = buildProjectQRPayload();
  const bar = '═'.repeat(52);

  process.stdout.write('\r\n');
  process.stdout.write('\x1b[36m'); // cyan
  process.stdout.write(bar + '\r\n');
  process.stdout.write('  serein — 项目绑定\r\n');
  process.stdout.write('\r\n');
  process.stdout.write('  项目:  ' + PROJECT_NAME + '\r\n');
  process.stdout.write('  后端:  ' + BACKEND + '\r\n');
  process.stdout.write('  路径:  ' + PROJECT_PATH + '\r\n');
  process.stdout.write('\r\n');
  process.stdout.write('  📱 打开手机 App → 项目页 → 扫码添加\r\n');
  process.stdout.write(bar + '\r\n');
  process.stdout.write('\x1b[0m'); // reset
  process.stdout.write('\r\n');

  if (qrTerminal) {
    qrTerminal.generate(payload, { small: true }, (qrStr) => {
      process.stdout.write(qrStr);
      process.stdout.write('\r\n');
    });
  } else {
    process.stdout.write('(qrcode-terminal 未安装，请手动添加项目)\r\n');
    process.stdout.write('项目名: ' + PROJECT_NAME + '\r\n');
    process.stdout.write('后端:   ' + BACKEND + '\r\n');
    process.stdout.write('\r\n');
    process.stdout.write('或浏览器访问: ' + BACKEND + '/join/' + encodeURIComponent(PROJECT_NAME) + '\r\n');
  }
  process.stdout.write('\r\n');
}

/**
 * 等待用户按 Enter 或超时后继续。
 * 用于 QR 显示后暂停，等用户扫码完毕。
 */
function waitForEnterOrTimeout(timeoutMs) {
  return new Promise((resolve) => {
    if (!process.stdin.isTTY) {
      setTimeout(resolve, Math.min(timeoutMs, 3000));
      return;
    }
    let resolved = false;
    const cleanupStdin = () => {
      clearTimeout(timer);
      process.stdin.removeListener('data', onData);
      try { process.stdin.pause(); } catch (_) {}
    };
    const onData = (data) => {
      const s = data.toString();
      if (s === '\r' || s === '\n' || s === '\r\n') {
        if (!resolved) { resolved = true; cleanupStdin(); resolve(); }
      }
    };
    process.stdin.resume();
    process.stdin.on('data', onData);
    const timer = setTimeout(() => {
      if (!resolved) { resolved = true; cleanupStdin(); resolve(); }
    }, timeoutMs);
  });
}

/**
 * 将项目注册到 ~/.serein/projects.json，使 agent (local_agent.py)
 * 能动态发现非硬编码的新项目并上报到 /agent/projects。
 */
function registerDynamicProject() {
  // 已知项目且路径一致 → 跳过；路径不一致（删了重建）→ 更新路径
  const known = KNOWN_PROJECTS[PROJECT_NAME];
  if (known && known.replace(/\\/g, '/') === PROJECT_PATH.replace(/\\/g, '/')) return;
  const sereinDir = resolve(_home, '.serein');
  const projectsFile = join(sereinDir, 'projects.json');
  try {
    try { mkdirSync(sereinDir, { recursive: true }); } catch (_) {}
    let projects = {};
    if (existsSync(projectsFile)) {
      projects = JSON.parse(readFileSync(projectsFile, 'utf-8'));
    }
    const normPath = PROJECT_PATH.replace(/\\/g, '/');
    if (projects[PROJECT_NAME] !== normPath) {
      projects[PROJECT_NAME] = normPath;
      writeFileSync(projectsFile, JSON.stringify(projects, null, 2), 'utf-8');
      console.error('[serein] 已注册动态项目: ' + PROJECT_NAME + ' → ' + normPath);
    }
  } catch (e) {
    console.error('[serein] 注册动态项目失败: ' + (e?.message || e));
  }
}

// ════════════════════════════════════════════
// 清理
// ════════════════════════════════════════════

function cleanup(writeQuitMarker = true) {
  manualCleanup = true;
  if (writeQuitMarker) {
    try { writeFileSync(RELAY_QUIT_FILE, String(process.pid)); } catch (_) {}
  }
  // 清理项目名文件
  try { if (existsSync(RELAY_PROJECT_FILE)) unlinkSync(RELAY_PROJECT_FILE); } catch (_) {}
  try { if (existsSync(RELAY_SCOPE_FILE)) unlinkSync(RELAY_SCOPE_FILE); } catch (_) {}
  try { if (existsSync(RELAY_RUNTIME_FILE)) unlinkSync(RELAY_RUNTIME_FILE); } catch (_) {}
  if (wsReconnectTimer) { clearTimeout(wsReconnectTimer); wsReconnectTimer = null; }
  if (fallbackTimer) { clearTimeout(fallbackTimer); fallbackTimer = null; }

  // 停止 JSONL 监听器
  if (jsonlWatcher) {
    jsonlWatcher.stop();
    jsonlWatcher = null;
  }
  if (codexPromptDetector) {
    codexPromptDetector.reset();
    codexPromptDetector = null;
  }
  if (codexAppServerProvider) {
    void codexAppServerProvider.close();
    codexAppServerProvider = null;
  }
  codexAppEventAdapter = null;
  codexDesktopActiveThreadId = null;
  codexDesktopApprovalRequests.clear();

  // 杀死 PTY 进程
  if (ptyProcess) {
    try {
      // 恢复 stdin 原始模式
      if (process.stdin.isTTY) {
        process.stdin.setRawMode(false);
      }
      ptyProcess.kill();
    } catch (e) {
      console.error('[serein] cleanup kill PTY:', e?.message || e);
    }
    ptyProcess = null;
  }

  heartbeat.stopWsHeartbeat();
  if (ws) {
    try { ws.close(); } catch (e) { console.error('[serein] cleanup close ws:', e?.message || e); }
    ws = null;
  }
  wsSender.clearWsSendQueue();
  preJoinBuffer = [];
  watchdog.removePidFile();
}

// ════════════════════════════════════════════
// 主函数
// ════════════════════════════════════════════

async function main() {
  // --qr 模式: 仅打印二维码并退出（不启动 PTY / WS / watchdog）
  if (qrOnlyMode) {
    printProjectQR();
    process.stdout.write('二维码已显示，按 Ctrl+C 退出。\r\n');
    return;
  }

  // 初始化子系统
  wsSender = createWsSendQueue(() => ws);
  heartbeat = createWsHeartbeat(() => ws, () => sessionId);
  watchdog = createWatchdog({ PYTHON, AGENT_PY, AGENT_DIR, RELAY_PID_FILE });

  validatePaths();
  watchdog.writePidFile();
  // 写入项目名文件，供 watchdog do_status() 检测 relay 关联的项目
  try { writeFileSync(RELAY_PROJECT_FILE, PROJECT_NAME, 'utf-8'); } catch (_) {}
  try {
    writeFileSync(RELAY_RUNTIME_FILE, JSON.stringify({
      runtime_mode: RUNTIME_MODE,
      agent_type: AGENT_TYPE,
    }), 'utf-8');
  } catch (_) {}
  if (WORK_SCOPE) {
    try { writeFileSync(RELAY_SCOPE_FILE, WORK_SCOPE, 'utf-8'); } catch (_) {}
  }

  // 重定向 console.error 到日志文件，避免 stderr 输出混入 Claude TUI 界面
  // （TUI 模式下 stderr 和 stdout 共享同一终端，状态消息会干扰输入框）
  if (!daemonMode) {
    try {
      const logPath = resolve(AGENT_DIR, 'relay_stderr.log');
      const logFd = require('fs').openSync(logPath, 'a');
      const logStream = require('fs').createWriteStream(logPath, { fd: logFd, flags: 'a' });
      const origErr = console.error;
      console.error = (...args) => {
        try {
          logStream.write(args.map(a => typeof a === 'string' ? a : String(a)).join(' ') + '\n');
        } catch (_) { /* silent */ }
      };
      // 启动信息写入日志
      console.error('[serein] serein PTY Relay 启动');
      console.error(`[serein] Backend: ${BACKEND}`);
      console.error(`[serein] Agent: ${_agentCfg.displayName} (${AGENT_EXE}), runtime=${RUNTIME_MODE}`);
      console.error(`[serein] Project: ${PROJECT_NAME} (${PROJECT_PATH})`);
      console.error(`[serein] Session Dir: ${SESSION_DIR}`);
      console.error(`[serein] HOOK_TOKEN: ${HOOK_TOKEN ? '(已设置)' : '(empty)'}`);
      console.error(`[serein] stderr 已重定向到: ${logPath}`);
    } catch (e) {
      // 如果重定向失败，回退到原始 console.error
      console.error('[serein] serein Relay 启动 (stderr 重定向失败)');
      console.error(`[serein] Backend: ${BACKEND}`);
      console.error(`[serein] Agent: ${_agentCfg.displayName} (${AGENT_EXE}), runtime=${RUNTIME_MODE}`);
      console.error(`[serein] Project: ${PROJECT_NAME} (${PROJECT_PATH})`);
      console.error(`[serein] Session Dir: ${SESSION_DIR}`);
      console.error(`[serein] HOOK_TOKEN: ${HOOK_TOKEN ? '(已设置)' : '(empty)'}`);
    }
  } else {
    console.error('[serein] serein PTY Relay 启动');
    console.error(`[serein] Backend: ${BACKEND}`);
    console.error(`[serein] Agent: ${_agentCfg.displayName} (${AGENT_EXE}), runtime=${RUNTIME_MODE}`);
    console.error(`[serein] Project: ${PROJECT_NAME} (${PROJECT_PATH})`);
    console.error(`[serein] Session Dir: ${SESSION_DIR}`);
    console.error(`[serein] HOOK_TOKEN: ${HOOK_TOKEN ? '(已设置)' : '(empty)'}`);
  }

  // Desktop relay 启动后立即在后台完成 App Server 握手和首轮列表读取。
  // 这与 watchdog、项目注册和 WS 连接并行，不再把冷启动耗时留给用户
  // 第一次进入 Terminal 时承担。
  if (RUNTIME_MODE === 'desktop') {
    void warmCodexDesktopBridge(true)
      .catch((error) => console.error(`[serein] desktop warmup failed: ${error?.message || error}`));
  }

  // 1. 确认 watchdog 后台 agent 已运行
  await watchdog.ensureWatchdog();

  // 2. daemon 模式：关闭 stdio
  if (daemonMode) {
    try {
      if (process.stdout.isTTY) process.stdout.destroy();
    } catch { /* non-fatal */ }
    try {
      if (process.stderr.isTTY) process.stderr.destroy();
    } catch { /* non-fatal */ }
  }

  // 3. Windows 控制台设为 UTF-8
  if (process.platform === 'win32' && !daemonMode) {
    try {
      const { spawnSync } = await import('child_process');
      spawnSync('chcp', ['65001'], { stdio: 'ignore', timeout: 2000, windowsHide: true });
    } catch (_e) { /* non-fatal */ }
  }

  // 3.5 注册动态项目（新项目写入 ~/.serein/projects.json，agent 下次心跳可见）
  // 绑定标记检查：项目目录下 .serein-bound 文件存在 → 已绑定；
  // 不存在 → 目录被删后重建（即使 projects.json 有记录），视为新项目需重新扫码。
  const knownPath = KNOWN_PROJECTS[PROJECT_NAME];
  const pathMatches = !!knownPath && knownPath.replace(/\\/g, '/') === PROJECT_PATH.replace(/\\/g, '/');
  const boundMarker = join(PROJECT_PATH, '.serein-bound');
  const markerExists = existsSync(boundMarker);
  const projectAlreadyKnown = pathMatches && markerExists;
  registerDynamicProject();

  // 3.6 非交互模式: 首次启动打印项目二维码等待扫码；已绑定项目直接启动
  if (!daemonMode) {
    if (!projectAlreadyKnown) {
      printProjectQR();
      process.stdout.write(`按 Enter 启动 ${_agentCfg.displayName}（或等待 10 秒自动启动）...\r\n`);
      await waitForEnterOrTimeout(10000);
      // 扫码绑定成功后写入标记文件，下次启动不再要求扫码
      try { writeFileSync(boundMarker, new Date().toISOString()); } catch (_) {}
    } else {
      process.stdout.write('\x1b[36m项目「' + PROJECT_NAME + '」已绑定，直接启动 ' + _agentCfg.displayName + '...\x1b[0m\r\n');
      await new Promise(resolve => setTimeout(resolve, 1500));
    }
    // 清屏，给 Claude TUI 一个干净的起始界面
    process.stdout.write('\x1b[2J\x1b[H');
  }

  // 4. CLI 模式启动 PTY；桌面模式只保留 App Server + WS 桥接，绝不再拉起 Codex CLI。
  if (RUNTIME_MODE === 'cli') {
    spawnPty();
    setupLocalInput();
  } else {
    console.error('[serein] Codex 桌面会话桥接已启动（未创建 CLI PTY）');
  }

  // 6. 连接 WS（join_ack 后自动 ready）
  connectWS();

  // 7. WS 回退：30 秒后若未收到 join_ack，标记 ready 允许本地输入
  fallbackTimer = setTimeout(() => {
    if (joinAckReceived) return;
    if (!manualCleanup) {
      console.warn('[serein] WS 未在 30 秒内收到 join_ack，以本地模式启动');
      joinAckReceived = true;
    }
  }, 30000);

  // 8. 信号处理
  process.on('SIGINT', () => {
    console.error('\n[serein] 收到 SIGINT，清理退出...');
    cleanup();
  });

  process.on('SIGTERM', () => {
    console.error('[serein] 收到 SIGTERM，清理退出...');
    cleanup();
  });

  process.on('exit', () => {
    if (process.stdin.isTTY) {
      try { process.stdin.setRawMode(false); } catch { /* ignored */ }
    }
    if (ptyProcess) {
      try { ptyProcess.kill(); } catch { /* ignored */ }
    }
    if (jsonlWatcher) {
      jsonlWatcher.stop();
    }
    watchdog.removePidFile();
    try { if (existsSync(RELAY_PROJECT_FILE)) unlinkSync(RELAY_PROJECT_FILE); } catch (_) {}
    try { if (existsSync(RELAY_SCOPE_FILE)) unlinkSync(RELAY_SCOPE_FILE); } catch (_) {}
  });

  // 9. 全局异常兜底
  process.on('uncaughtException', (err) => {
    console.error('[serein] 未捕获异常:', err?.message || err);
    cleanup(false);
    setTimeout(() => process.exit(1), 100);
  });

  process.on('unhandledRejection', (reason) => {
    console.error('[serein] 未处理的 Promise 拒绝:', reason?.message || reason);
    cleanup(false);
    setTimeout(() => process.exit(1), 100);
  });
}

main().catch((e) => {
  console.error('[serein] 致命错误:', e);
  watchdog.removePidFile();
  process.exit(1);
});
