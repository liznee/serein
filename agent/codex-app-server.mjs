#!/usr/bin/env node

/**
 * Codex App Server provider.
 *
 * This provider is deliberately separate from the PTY/CLI relay. It can
 * discover, read, resume, and explicitly continue local Codex Desktop/CLI/App
 * Server threads. Ownership and user confirmation remain relay concerns.
 */

import { spawn } from "node:child_process";
import { createInterface } from "node:readline";

const DEFAULT_TIMEOUT_MS = 10_000;

// Codex Desktop 0.144.x currently reports its threads as `vscode`. Keep
// `appServer` as well because it is the protocol-native source used by App
// Server clients. CLI/exec/sub-agent threads are deliberately excluded.
export const CODEX_DESKTOP_SOURCE_KINDS = Object.freeze(['vscode', 'appServer']);

export const CODEX_APP_SERVER_CAPABILITIES = Object.freeze({
  canDiscoverDesktopSessions: true,
  canReadWithoutResume: true,
  canResumeSession: true,
  canStartTurn: true,
  canStreamStructuredEvents: true,
  canRespondApproval: false,
  canRespondCommandAndFileApproval: true,
  canInterrupt: true,
  canFork: false,
});

/** Build the exact response shape expected by supported App Server approvals. */
export function buildCodexApprovalResult(method, decision) {
  if (!['allow', 'deny'].includes(decision)) {
    throw new TypeError('approval decision must be allow or deny');
  }
  if (method === 'item/commandExecution/requestApproval'
      || method === 'item/fileChange/requestApproval') {
    return { decision: decision === 'allow' ? 'accept' : 'decline' };
  }
  if (method === 'execCommandApproval' || method === 'applyPatchApproval') {
    return { decision: decision === 'allow' ? 'approved' : 'denied' };
  }
  throw new CodexAppServerError(`unsupported approval request: ${method}`);
}

export function buildCodexAppServerCommand(platform = process.platform, comSpec = process.env.ComSpec) {
  if (platform === "win32") {
    return {
      command: comSpec || "cmd.exe",
      args: ["/d", "/s", "/c", "codex.cmd app-server --stdio"],
    };
  }
  return { command: "codex", args: ["app-server", "--stdio"] };
}

export function buildThreadListParams(cwd, options = {}) {
  const params = {
    cwd,
    limit: options.limit ?? 100,
    useStateDbOnly: options.useStateDbOnly ?? false,
  };
  if (Object.hasOwn(options, "sourceKinds")) {
    params.sourceKinds = options.sourceKinds;
  }
  if (options.cursor) params.cursor = options.cursor;
  if (options.searchTerm) params.searchTerm = options.searchTerm;
  return params;
}

export function normalizeThreadSourceKind(thread) {
  const source = thread?.source ?? thread?.sourceKind ?? '';
  return typeof source === 'string' ? source : '';
}

export function isCodexDesktopThread(thread) {
  return CODEX_DESKTOP_SOURCE_KINDS.includes(normalizeThreadSourceKind(thread));
}

/**
 * App Server 0.144+ returns thread status as an object such as
 * `{ type: "notLoaded" }`, while older builds may return a string. Keep that
 * protocol variation out of the phone model so the ArkTS renderer never has
 * to guess the runtime shape.
 */
export function normalizeCodexThreadStatus(thread) {
  const status = thread?.status;
  if (typeof status === 'string') return status;
  if (status && typeof status === 'object' && typeof status.type === 'string') {
    return status.type;
  }
  return '';
}

export function buildTurnStartParams(threadId, text, options = {}) {
  if (!String(threadId || '').trim()) throw new TypeError('threadId is required');
  if (!String(text || '').trim()) throw new TypeError('text is required');
  const params = {
    threadId,
    input: [{ type: 'text', text }],
  };
  // Only copy explicitly supplied overrides. Omitting these fields preserves
  // the desktop thread's existing model, approvals, and sandbox settings.
  for (const key of [
    'additionalContext', 'approvalPolicy', 'approvalsReviewer',
    'clientUserMessageId', 'cwd', 'effort', 'environments', 'model',
    'permissions', 'runtimeWorkspaceRoots', 'sandboxPolicy', 'summary',
  ]) {
    if (Object.hasOwn(options, key)) params[key] = options[key];
  }
  return params;
}

export class CodexAppServerError extends Error {
  constructor(message, details = {}) {
    super(message);
    this.name = "CodexAppServerError";
    Object.assign(this, details);
  }
}

export class CodexAppServerProvider {
  constructor({ cwd, timeoutMs = DEFAULT_TIMEOUT_MS, env = process.env, onNotification = null } = {}) {
    if (!cwd) throw new TypeError("CodexAppServerProvider requires cwd");
    this.cwd = cwd;
    this.timeoutMs = timeoutMs;
    this.env = env;
    this.child = null;
    this.lines = null;
    this.stderr = "";
    this.nextId = 1;
    this.pending = new Map();
    this.initialized = false;
    this.connecting = null;
    this.onNotification = onNotification;
  }

  get capabilities() {
    return CODEX_APP_SERVER_CAPABILITIES;
  }

  async connect() {
    if (this.initialized) return;
    if (this.connecting) return this.connecting;
    this.connecting = this.#connectInternal();
    try {
      await this.connecting;
    } finally {
      this.connecting = null;
    }
  }

  async #connectInternal() {
    const { command, args } = buildCodexAppServerCommand();
    this.child = spawn(command, args, {
      cwd: this.cwd,
      env: this.env,
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });
    this.child.stderr.setEncoding("utf8");
    this.child.stderr.on("data", (chunk) => { this.stderr += chunk; });
    this.child.on("error", (error) => this.#rejectPending(error));
    this.child.on("exit", (code, signal) => {
      if (this.pending.size > 0) {
        this.#rejectPending(new CodexAppServerError(
          `Codex App Server exited (${code ?? "null"}/${signal ?? "null"})`,
          { code, signal },
        ));
      }
      this.initialized = false;
    });

    this.lines = createInterface({ input: this.child.stdout, crlfDelay: Infinity });
    this.lines.on("line", (line) => this.#handleLine(line));

    await this.request("initialize", {
      clientInfo: {
        name: "serein-codex-app-server",
        title: "Serein Codex App Server",
        version: "0.1.0",
      },
      capabilities: { experimentalApi: true },
    });
    this.#send({ jsonrpc: "2.0", method: "initialized", params: {} });
    this.initialized = true;
  }

  async listThreads(options = {}) {
    await this.connect();
    const response = await this.request("thread/list", buildThreadListParams(this.cwd, options));
    const result = response.result || {};
    return {
      threads: Array.isArray(result.data) ? result.data : (result.threads || []),
      nextCursor: result.nextCursor ?? null,
    };
  }

  async readThread(threadId, { includeTurns = true } = {}) {
    if (!threadId) throw new TypeError("readThread requires threadId");
    await this.connect();
    const response = await this.request("thread/read", { threadId, includeTurns });
    return response.result?.thread || response.result || null;
  }

  async resumeThread(threadId, { excludeTurns = true } = {}) {
    if (!threadId) throw new TypeError("resumeThread requires threadId");
    await this.connect();
    const response = await this.request("thread/resume", { threadId, excludeTurns });
    return response.result?.thread || response.result || null;
  }

  async startTurn(threadId, text, options = {}) {
    const response = await this.request('turn/start', buildTurnStartParams(threadId, text, options));
    return response.result || null;
  }

  async interruptTurn(threadId, turnId) {
    if (!threadId) throw new TypeError('interruptTurn requires threadId');
    if (!turnId) throw new TypeError('interruptTurn requires turnId');
    const response = await this.request('turn/interrupt', { threadId, turnId });
    return response.result || null;
  }

  respondToRequest(requestId, result) {
    if (requestId === undefined || requestId === null || requestId === '') {
      throw new TypeError('respondToRequest requires requestId');
    }
    this.#send({ jsonrpc: '2.0', id: requestId, result });
  }

  async close() {
    this.#rejectPending(new CodexAppServerError("Codex App Server client closed"));
    this.lines?.close();
    this.lines = null;
    if (this.child && !this.child.killed) {
      this.child.kill();
    }
    this.child = null;
    this.initialized = false;
    this.connecting = null;
  }

  request(method, params = {}) {
    if (!this.child?.stdin?.writable) {
      return Promise.reject(new CodexAppServerError("Codex App Server stdin is not writable"));
    }
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new CodexAppServerError(`timeout waiting for ${method}`, { method }));
      }, this.timeoutMs);
      this.pending.set(id, { resolve, reject, timer, method });
      try {
        this.#send({ jsonrpc: "2.0", id, method, params });
      } catch (error) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(error);
      }
    });
  }

  #send(message) {
    if (!this.child?.stdin?.writable) {
      throw new CodexAppServerError("Codex App Server stdin is not writable");
    }
    this.child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  #handleLine(line) {
    if (!line.trim()) return;
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      return;
    }
    if (message.method) {
      if (typeof this.onNotification === 'function') {
        try {
          this.onNotification(message);
        } catch {
          // A notification consumer must never break the JSON-RPC reader.
        }
      }
      // A server request may also carry an id. It is not a response to one of
      // our pending client requests and must be answered separately.
      return;
    }
    if (message.id == null) {
      return;
    }
    const state = this.pending.get(message.id);
    if (!state) return;
    this.pending.delete(message.id);
    clearTimeout(state.timer);
    if (message.error) {
      state.reject(new CodexAppServerError(
        `${state.method}: ${JSON.stringify(message.error)}`,
        { method: state.method, response: message },
      ));
    } else {
      state.resolve(message);
    }
  }

  #rejectPending(error) {
    for (const state of this.pending.values()) {
      clearTimeout(state.timer);
      state.reject(error);
    }
    this.pending.clear();
  }
}
