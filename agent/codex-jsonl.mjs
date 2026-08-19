/**
 * Codex session JSONL adapter.
 *
 * Codex stores sessions below ~/.codex/sessions/YYYY/MM/DD/*.jsonl. Unlike
 * Claude Code, the project path is recorded in the session_meta payload, so
 * discovery must inspect metadata instead of deriving a directory slug.
 */

import {
  closeSync,
  existsSync,
  openSync,
  readSync,
  readdirSync,
  statSync,
} from 'fs';
import { resolve } from 'path';
import { StringDecoder } from 'string_decoder';

const MAX_META_BYTES = 256 * 1024;
const MAX_READ_BYTES = 256 * 1024;
const DEFAULT_POLL_MS = 250;
const DEFAULT_STARTUP_TOLERANCE_MS = 15_000;
const MAX_EVENT_TEXT = 4_000;
const MAX_TOOL_TEXT = 1_200;

function normalizePath(value) {
  const normalized = resolve(String(value || ''))
    .replace(/\\/g, '/')
    .replace(/\/$/, '');
  return process.platform === 'win32' ? normalized.toLowerCase() : normalized;
}

function truncate(value, maxLength) {
  const text = String(value ?? '').trim();
  if (text.length <= maxLength) return text;
  return `${text.slice(0, maxLength)}\n…（内容已截断）`;
}

function extractText(value) {
  if (typeof value === 'string') return value;
  if (Array.isArray(value)) {
    return value
      .map((item) => {
        if (typeof item === 'string') return item;
        if (item && typeof item.text === 'string') return item.text;
        return '';
      })
      .filter(Boolean)
      .join('\n');
  }
  if (value && typeof value === 'object') {
    try {
      return JSON.stringify(value, null, 2);
    } catch {
      return String(value);
    }
  }
  return '';
}

function formatToolPayload(value) {
  if (typeof value !== 'string') return truncate(extractText(value), MAX_TOOL_TEXT);
  const text = value.trim();
  if (!text) return '';
  try {
    return truncate(JSON.stringify(JSON.parse(text), null, 2), MAX_TOOL_TEXT);
  } catch {
    return truncate(text, MAX_TOOL_TEXT);
  }
}

function decodeQuotedValue(value) {
  try {
    return JSON.parse(`"${value}"`);
  } catch {
    return value;
  }
}

function describeTool(toolName, content) {
  const name = String(toolName || 'tool');
  if (name.toLowerCase() !== 'exec' || !content.includes('tools.web__run')) {
    return { toolName: name, content };
  }

  const queries = [];
  const queryPattern = /\bq\s*:\s*"((?:\\.|[^"\\])*)"/g;
  let match;
  while ((match = queryPattern.exec(content)) !== null) {
    queries.push(decodeQuotedValue(match[1]));
  }
  if (queries.length > 0) {
    return { toolName: 'Web Search', content: `搜索：${queries.join('；')}` };
  }

  const locationMatch = content.match(/\blocation\s*:\s*"((?:\\.|[^"\\])*)"/);
  if (locationMatch) {
    return { toolName: 'Web Search', content: `查询天气：${decodeQuotedValue(locationMatch[1])}` };
  }
  if (/\bopen\s*:/.test(content)) {
    return { toolName: 'Web Search', content: '打开搜索结果' };
  }
  return { toolName: 'Web Search', content: '查询网页信息' };
}

function codexSubagentEvent(toolName, content) {
  const name = String(toolName || '').toLowerCase();
  if (name === 'spawn_agent' || name === 'dispatch_agent') {
    return { type: 'subagent_start', content, toolName: String(toolName || 'subagent') };
  }
  if (name === 'close_agent') {
    return { type: 'subagent_stop', content, toolName: String(toolName || 'subagent') };
  }
  return null;
}

/**
 * Convert one Codex rollout record into Serein terminal events.
 * Response-item message/reasoning records are intentionally ignored because
 * Codex also emits event_msg versions of those records; using both duplicates
 * text on the phone.
 */
export function parseCodexRecord(record) {
  if (!record || typeof record !== 'object') return [];
  const payload = record.payload;
  if (!payload || typeof payload !== 'object') return [];

  if (record.type === 'event_msg') {
    switch (payload.type) {
      case 'task_started':
        return [{ type: 'turn_start', content: '', toolName: '' }];
      case 'task_complete':
        return [{ type: 'turn_end', content: 'end_turn', toolName: '' }];
      case 'turn_aborted':
        return [{
          type: 'turn_end',
          content: 'aborted:' + truncate(payload.reason || 'unknown', MAX_EVENT_TEXT),
          toolName: '',
        }];
      case 'user_message':
        return payload.message
          ? [{ type: 'user_msg', content: truncate(payload.message, MAX_EVENT_TEXT), toolName: '' }]
          : [];
      case 'agent_reasoning':
        return payload.text
          ? [{ type: 'thinking', content: truncate(payload.text, MAX_EVENT_TEXT), toolName: '' }]
          : [];
      case 'agent_message':
        return payload.message
          ? [{ type: 'text', content: truncate(payload.message, MAX_EVENT_TEXT), toolName: '' }]
          : [];
      default:
        return [];
    }
  }

  if (record.type !== 'response_item') return [];

  if (payload.type === 'function_call' || payload.type === 'custom_tool_call') {
    const content = formatToolPayload(payload.arguments ?? payload.input ?? '');
    const described = describeTool(payload.name, content);
    const toolName = described.toolName;
    const events = [{ type: 'tool_use', content: described.content, toolName }];
    const subagentEvent = codexSubagentEvent(payload.name, content);
    if (subagentEvent) events.push(subagentEvent);
    return events;
  }

  if (payload.type === 'function_call_output' || payload.type === 'custom_tool_call_output') {
    const content = truncate(extractText(payload.output), MAX_TOOL_TEXT);
    return content ? [{ type: 'tool_result', content, toolName: '' }] : [];
  }

  return [];
}

function listJsonlFiles(root) {
  const files = [];
  const pending = [root];
  while (pending.length) {
    const dir = pending.pop();
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      const fullPath = resolve(dir, entry.name);
      if (entry.isDirectory()) pending.push(fullPath);
      else if (entry.isFile() && entry.name.endsWith('.jsonl')) files.push(fullPath);
    }
  }
  return files;
}

function readSessionMeta(filePath) {
  let fd;
  try {
    fd = openSync(filePath, 'r');
    const stat = statSync(filePath);
    const buffer = Buffer.alloc(Math.min(stat.size, MAX_META_BYTES));
    const bytesRead = readSync(fd, buffer, 0, buffer.length, 0);
    const chunk = buffer.subarray(0, bytesRead).toString('utf8');
    const newline = chunk.indexOf('\n');
    if (newline < 0 && stat.size > MAX_META_BYTES) return null;
    const line = (newline >= 0 ? chunk.slice(0, newline) : chunk).trim();
    if (!line) return null;
    const record = JSON.parse(line);
    return record.type === 'session_meta' ? record.payload : null;
  } catch {
    return null;
  } finally {
    if (fd !== undefined) {
      try { closeSync(fd); } catch { /* already closed */ }
    }
  }
}

export function createCodexJsonlWatcher(deps) {
  const {
    sessionRoot,
    projectPath,
    onEvent,
    onSession = () => {},
    pollIntervalMs = DEFAULT_POLL_MS,
    startupToleranceMs = DEFAULT_STARTUP_TOLERANCE_MS,
  } = deps;

  const normalizedProject = normalizePath(projectPath);
  let currentFile = null;
  let lastSize = 0;
  let partialLine = '';
  let pollTimer = null;
  let startupTime = Date.now();
  let pollsSinceDiscovery = Number.POSITIVE_INFINITY;
  let lastEventKey = '';
  let lastSessionID = '';
  let decoder = new StringDecoder('utf8');

  function matchingSessionMeta(filePath) {
    const meta = readSessionMeta(filePath);
    if (!meta?.cwd || normalizePath(meta.cwd) !== normalizedProject) return null;
    const originator = String(meta.originator || '').toLowerCase();
    const source = typeof meta.source === 'string' ? meta.source.toLowerCase() : '';
    // The desktop app and the CLI can update sessions for the same project at
    // the same time. Serein launches the interactive TUI, so attaching only to
    // CLI/TUI metadata prevents mobile output from leaking across sessions.
    return source === 'cli' || originator === 'codex-tui' ? meta : null;
  }

  function discoverSession() {
    const cutoff = startupTime - startupToleranceMs;
    const candidates = listJsonlFiles(sessionRoot)
      .map((filePath) => {
        try {
          return { filePath, stat: statSync(filePath) };
        } catch {
          return null;
        }
      })
      .filter((item) => item && item.stat.mtimeMs >= cutoff)
      .sort((a, b) => b.stat.mtimeMs - a.stat.mtimeMs);

    for (const candidate of candidates) {
      const meta = matchingSessionMeta(candidate.filePath);
      if (!meta) continue;
      if (candidate.filePath !== currentFile) {
        currentFile = candidate.filePath;
        lastSize = 0;
        partialLine = '';
        lastEventKey = '';
        decoder = new StringDecoder('utf8');
        console.error(`[serein-codex-jsonl] 检测到 Session: ${candidate.filePath}`);
      }
      const discoveredID = String(meta.id || meta.session_id || '').trim();
      if (discoveredID && discoveredID !== lastSessionID) {
        lastSessionID = discoveredID;
        onSession(discoveredID);
      }
      return;
    }
  }

  function emitRecord(record) {
    for (const event of parseCodexRecord(record)) {
      const key = `${record.timestamp || ''}\u0000${event.type}\u0000${event.toolName}\u0000${event.content}`;
      if (key === lastEventKey) continue;
      lastEventKey = key;
      try {
        onEvent(event.type, event.content, event.toolName);
      } catch (error) {
        // One delivery callback must never abort the rest of the JSONL chunk.
        // Otherwise lastSize has already advanced and every later event in the
        // same read (including the final answer and turn_end) is lost forever.
        console.error(`[serein-codex-jsonl] event delivery failed (${event.type}): ${error?.message || error}`);
      }
    }
  }

  function readNewContent() {
    if (!currentFile) return;
    let stat;
    try {
      stat = statSync(currentFile);
    } catch {
      currentFile = null;
      lastSize = 0;
      partialLine = '';
      decoder = new StringDecoder('utf8');
      return;
    }

    if (stat.size < lastSize) {
      lastSize = 0;
      partialLine = '';
      decoder = new StringDecoder('utf8');
    }
    if (stat.size === lastSize) return;

    const bytesToRead = Math.min(stat.size - lastSize, MAX_READ_BYTES);
    let fd;
    try {
      fd = openSync(currentFile, 'r');
      const buffer = Buffer.alloc(bytesToRead);
      const bytesRead = readSync(fd, buffer, 0, bytesToRead, lastSize);
      lastSize += bytesRead;
      const chunks = (partialLine + decoder.write(buffer.subarray(0, bytesRead))).split('\n');
      partialLine = chunks.pop() || '';
      for (const line of chunks) {
        const trimmed = line.trim();
        if (!trimmed) continue;
        try {
          emitRecord(JSON.parse(trimmed));
        } catch {
          // A malformed completed line is isolated; later records still flow.
        }
      }
      // Codex can leave the latest complete JSON record without a trailing
      // newline until another event is appended. Parse it eagerly when it is
      // already valid JSON so task_complete is not delayed indefinitely.
      const trailing = partialLine.trim();
      if (trailing) {
        try {
          emitRecord(JSON.parse(trailing));
          partialLine = '';
        } catch {
          // The writer may still be appending this record; keep it for the
          // next polling cycle.
        }
      }
    } catch {
      // The file can briefly be locked while Codex rotates or appends it.
    } finally {
      if (fd !== undefined) {
        try { closeSync(fd); } catch { /* already closed */ }
      }
    }
  }

  function poll() {
    pollsSinceDiscovery += 1;
    if (!currentFile || pollsSinceDiscovery >= 20) {
      discoverSession();
      pollsSinceDiscovery = 0;
    }
    readNewContent();
  }

  function start() {
    if (pollTimer) return;
    if (!existsSync(sessionRoot)) {
      console.error(`[serein-codex-jsonl] Session 目录暂不存在: ${sessionRoot}`);
    }
    console.error(`[serein-codex-jsonl] 监听目录: ${sessionRoot}`);
    poll();
    pollTimer = setInterval(poll, pollIntervalMs);
  }

  function stop() {
    if (pollTimer) clearInterval(pollTimer);
    pollTimer = null;
    currentFile = null;
    lastSize = 0;
    partialLine = '';
    lastEventKey = '';
    lastSessionID = '';
    decoder = new StringDecoder('utf8');
  }

  function reset() {
    currentFile = null;
    lastSize = 0;
    partialLine = '';
    lastEventKey = '';
    lastSessionID = '';
    decoder = new StringDecoder('utf8');
    startupTime = Date.now();
    pollsSinceDiscovery = Number.POSITIVE_INFINITY;
  }

  return { start, stop, reset };
}
