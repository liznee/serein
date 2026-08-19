import assert from 'node:assert/strict';
import { afterEach, test } from 'node:test';
import {
  appendFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

import { createCodexJsonlWatcher, parseCodexRecord } from './codex-jsonl.mjs';

const cleanup = [];
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

afterEach(() => {
  for (const dir of cleanup.splice(0)) {
    if (existsSync(dir)) rmSync(dir, { recursive: true, force: true });
  }
});

test('maps Codex event and tool records without duplicating response messages', () => {
  assert.deepEqual(
    parseCodexRecord({ type: 'event_msg', payload: { type: 'agent_message', message: '完成' } }),
    [{ type: 'text', content: '完成', toolName: '' }],
  );
  assert.deepEqual(
    parseCodexRecord({ type: 'event_msg', payload: { type: 'agent_reasoning', text: '分析中' } }),
    [{ type: 'thinking', content: '分析中', toolName: '' }],
  );
  assert.deepEqual(
    parseCodexRecord({
      type: 'response_item',
      payload: { type: 'function_call', name: 'shell_command', arguments: '{"command":"npm test"}' },
    }),
    [{ type: 'tool_use', content: '{\n  "command": "npm test"\n}', toolName: 'shell_command' }],
  );
  assert.deepEqual(
    parseCodexRecord({ type: 'response_item', payload: { type: 'message', role: 'assistant', content: [] } }),
    [],
  );
});

test('labels Codex web tool calls as readable Web Search steps', () => {
  assert.deepEqual(
    parseCodexRecord({
      type: 'response_item',
      payload: {
        type: 'custom_tool_call',
        name: 'exec',
        input: 'const r = await tools.web__run({search_query:[{q:"Shanghai weather today"}]}); text(r)',
      },
    }),
    [{ type: 'tool_use', content: '搜索：Shanghai weather today', toolName: 'Web Search' }],
  );
});

test('maps Codex multi-agent tools to lifecycle events', () => {
  assert.deepEqual(
    parseCodexRecord({
      type: 'response_item',
      payload: { type: 'function_call', name: 'spawn_agent', arguments: '{"message":"检查测试"}' },
    }),
    [
      { type: 'tool_use', content: '{\n  "message": "检查测试"\n}', toolName: 'spawn_agent' },
      { type: 'subagent_start', content: '{\n  "message": "检查测试"\n}', toolName: 'spawn_agent' },
    ],
  );
  assert.deepEqual(
    parseCodexRecord({
      type: 'response_item',
      payload: { type: 'function_call', name: 'close_agent', arguments: '{"id":"agent-1"}' },
    }).map(({ type }) => type),
    ['tool_use', 'subagent_stop'],
  );
});

test('selects only the recent nested Codex session for the requested project', async () => {
  const root = mkdtempSync(join(tmpdir(), 'serein-codex-jsonl-'));
  cleanup.push(root);
  const dayDir = join(root, '2026', '07', '15');
  const projectDir = join(root, 'workspace', 'serein');
  mkdirSync(dayDir, { recursive: true });
  mkdirSync(projectDir, { recursive: true });
  const events = [];
  const sessions = [];
  const watcher = createCodexJsonlWatcher({
    sessionRoot: root,
    projectPath: projectDir,
    pollIntervalMs: 20,
    onEvent: (type, content, toolName) => events.push({ type, content, toolName }),
    onSession: (id) => sessions.push(id),
  });

  watcher.start();
  writeFileSync(join(dayDir, 'wrong.jsonl'), [
    JSON.stringify({ type: 'session_meta', payload: { cwd: join(root, 'workspace', 'another-project'), originator: 'codex-tui', source: 'cli' } }),
    JSON.stringify({ type: 'event_msg', payload: { type: 'agent_message', message: 'wrong' } }),
    '',
  ].join('\n'));
  await wait(35);
  writeFileSync(join(dayDir, 'matching.jsonl'), [
    JSON.stringify({ type: 'session_meta', payload: { id: '123e4567-e89b-42d3-a456-426614174000', cwd: projectDir, originator: 'codex-tui', source: 'cli' } }),
    JSON.stringify({ type: 'event_msg', payload: { type: 'task_started' } }),
    JSON.stringify({ type: 'event_msg', payload: { type: 'agent_message', message: 'hello' } }),
    '',
  ].join('\n'));
  await wait(100);
  watcher.stop();

  assert.equal(events.some(({ content }) => content === 'wrong'), false);
  assert.equal(events.some(({ type }) => type === 'turn_start'), true);
  assert.equal(events.some(({ type, content }) => type === 'text' && content === 'hello'), true);
  assert.deepEqual(sessions, ['123e4567-e89b-42d3-a456-426614174000']);
});

test('retains a Codex record split across polling cycles', async () => {
  const root = mkdtempSync(join(tmpdir(), 'serein-codex-jsonl-'));
  cleanup.push(root);
  const dayDir = join(root, '2026', '07', '15');
  const projectDir = join(root, 'workspace', 'serein');
  mkdirSync(dayDir, { recursive: true });
  mkdirSync(projectDir, { recursive: true });
  const file = join(dayDir, 'rollout.jsonl');
  const events = [];
  const watcher = createCodexJsonlWatcher({
    sessionRoot: root,
    projectPath: projectDir,
    pollIntervalMs: 20,
    onEvent: (type, content) => events.push({ type, content }),
  });

  watcher.start();
  writeFileSync(file, `${JSON.stringify({ type: 'session_meta', payload: { cwd: projectDir, originator: 'codex-tui', source: 'cli' } })}\n`);
  await wait(60);
  appendFileSync(file, '{"type":"event_msg","payload":{"type":"agent_message","message":"hel');
  await wait(60);
  appendFileSync(file, 'lo"}}\n');
  await wait(80);
  watcher.stop();

  assert.deepEqual(
    events.filter(({ type }) => type === 'text'),
    [{ type: 'text', content: 'hello' }],
  );
});

test('emits a complete trailing record without waiting for a newline', async () => {
  const root = mkdtempSync(join(tmpdir(), 'serein-codex-jsonl-'));
  cleanup.push(root);
  const dayDir = join(root, '2026', '07', '15');
  const projectDir = join(root, 'workspace', 'serein');
  mkdirSync(dayDir, { recursive: true });
  mkdirSync(projectDir, { recursive: true });
  const file = join(dayDir, 'rollout.jsonl');
  const events = [];
  const watcher = createCodexJsonlWatcher({
    sessionRoot: root,
    projectPath: projectDir,
    pollIntervalMs: 20,
    onEvent: (type, content) => events.push({ type, content }),
  });

  writeFileSync(file, [
    JSON.stringify({ type: 'session_meta', payload: { cwd: projectDir, originator: 'codex-tui', source: 'cli' } }),
    JSON.stringify({ type: 'event_msg', payload: { type: 'task_complete' } }),
  ].join('\n'));
  watcher.start();
  await wait(80);
  watcher.stop();

  assert.equal(events.some(({ type }) => type === 'turn_end'), true);
});

test('ignores a newer Codex Desktop session for the same project', async () => {
  const root = mkdtempSync(join(tmpdir(), 'serein-codex-jsonl-'));
  cleanup.push(root);
  const dayDir = join(root, '2026', '07', '15');
  const projectDir = join(root, 'workspace', 'serein');
  mkdirSync(dayDir, { recursive: true });
  mkdirSync(projectDir, { recursive: true });
  const events = [];
  const watcher = createCodexJsonlWatcher({
    sessionRoot: root,
    projectPath: projectDir,
    pollIntervalMs: 20,
    onEvent: (type, content) => events.push({ type, content }),
  });

  watcher.start();
  writeFileSync(join(dayDir, 'tui.jsonl'), [
    JSON.stringify({ type: 'session_meta', payload: { cwd: projectDir, originator: 'codex-tui', source: 'cli' } }),
    JSON.stringify({ type: 'event_msg', payload: { type: 'agent_message', message: 'tui-message' } }),
    '',
  ].join('\n'));
  await wait(30);
  writeFileSync(join(dayDir, 'desktop.jsonl'), [
    JSON.stringify({ type: 'session_meta', payload: { cwd: projectDir, originator: 'Codex Desktop', source: 'vscode' } }),
    JSON.stringify({ type: 'event_msg', payload: { type: 'agent_message', message: 'desktop-message' } }),
    '',
  ].join('\n'));
  await wait(100);
  watcher.stop();

  assert.equal(events.some(({ content }) => content === 'tui-message'), true);
  assert.equal(events.some(({ content }) => content === 'desktop-message'), false);
});
