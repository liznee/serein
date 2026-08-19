import assert from "node:assert/strict";
import test from "node:test";

import {
  buildCodexApprovalResult,
  buildCodexAppServerCommand,
  buildThreadListParams,
  buildTurnStartParams,
  CODEX_DESKTOP_SOURCE_KINDS,
  CodexAppServerProvider,
  isCodexDesktopThread,
  normalizeCodexThreadStatus,
} from "./codex-app-server.mjs";

test("builds safe command and file approval responses", () => {
  assert.deepEqual(buildCodexApprovalResult('item/commandExecution/requestApproval', 'allow'), {
    decision: 'accept',
  });
  assert.deepEqual(buildCodexApprovalResult('item/fileChange/requestApproval', 'deny'), {
    decision: 'decline',
  });
  assert.deepEqual(buildCodexApprovalResult('execCommandApproval', 'allow'), {
    decision: 'approved',
  });
  assert.throws(
    () => buildCodexApprovalResult('item/permissions/requestApproval', 'allow'),
    /unsupported approval request/,
  );
});

test("uses a hidden cmd wrapper for the Windows Codex command", () => {
  assert.deepEqual(buildCodexAppServerCommand("win32", "C:\\Windows\\System32\\cmd.exe"), {
    command: "C:\\Windows\\System32\\cmd.exe",
    args: ["/d", "/s", "/c", "codex.cmd app-server --stdio"],
  });
});

test("builds a read-only thread list request without inventing source kinds", () => {
  assert.deepEqual(buildThreadListParams("C:/workspace/serein"), {
    cwd: "C:/workspace/serein",
    limit: 100,
    useStateDbOnly: false,
  });
  assert.deepEqual(buildThreadListParams("C:/workspace/serein", { sourceKinds: [] }), {
    cwd: "C:/workspace/serein",
    limit: 100,
    useStateDbOnly: false,
    sourceKinds: [],
  });
});

test("classifies only Codex Desktop/App Server thread sources as desktop", () => {
  assert.deepEqual(CODEX_DESKTOP_SOURCE_KINDS, ['vscode', 'appServer']);
  assert.equal(isCodexDesktopThread({ source: 'vscode' }), true);
  assert.equal(isCodexDesktopThread({ sourceKind: 'appServer' }), true);
  assert.equal(isCodexDesktopThread({ source: 'cli' }), false);
  assert.equal(isCodexDesktopThread({ source: 'exec' }), false);
  assert.equal(isCodexDesktopThread({ source: { subAgent: null } }), false);
});

test("normalizes both object and string thread status shapes", () => {
  assert.equal(normalizeCodexThreadStatus({ status: { type: 'notLoaded' } }), 'notLoaded');
  assert.equal(normalizeCodexThreadStatus({ status: 'active' }), 'active');
  assert.equal(normalizeCodexThreadStatus({ status: null }), '');
});

test("builds an explicit text turn without overriding desktop safety settings", () => {
  assert.deepEqual(buildTurnStartParams("thread-1", "检查这个问题"), {
    threadId: "thread-1",
    input: [{ type: "text", text: "检查这个问题" }],
  });
  assert.deepEqual(buildTurnStartParams("thread-1", "继续", {
    approvalPolicy: "on-request",
    cwd: "C:/workspace/serein",
  }), {
    threadId: "thread-1",
    input: [{ type: "text", text: "继续" }],
    approvalPolicy: "on-request",
    cwd: "C:/workspace/serein",
  });
});

test("discovers and reads a local Codex thread", { skip: process.env.SEREIN_CODEX_APP_SERVER_INTEGRATION !== "1" }, async () => {
  const provider = new CodexAppServerProvider({ cwd: process.cwd() });
  try {
    const listed = await provider.listThreads({ sourceKinds: CODEX_DESKTOP_SOURCE_KINDS });
    assert.ok(Array.isArray(listed.threads));
    if (listed.threads.length > 0) {
      const id = listed.threads[0].id ?? listed.threads[0].threadId;
      const thread = await provider.readThread(id, { includeTurns: true });
      assert.equal(thread.id ?? thread.threadId, id);
      assert.ok(Array.isArray(thread.turns));
    }
  } finally {
    await provider.close();
  }
});
