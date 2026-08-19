import assert from 'node:assert/strict';
import { afterEach, test } from 'node:test';
import {
  appendFileSync,
  existsSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

import { createJsonlWatcher } from './serein-jsonl.mjs';

const cleanup = [];

afterEach(() => {
  for (const dir of cleanup.splice(0)) {
    if (existsSync(dir)) rmSync(dir, { recursive: true, force: true });
  }
});

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

test('reports the Claude session id from the selected JSONL filename', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'serein-jsonl-session-'));
  cleanup.push(dir);
  const id = '123e4567-e89b-42d3-a456-426614174000';
  const sessions = [];
  const watcher = createJsonlWatcher({
    sessionDir: dir,
    onEvent: () => {},
    onSession: (sessionID) => sessions.push(sessionID),
  });
  watcher.start();
  await wait(20);
  writeFileSync(join(dir, id + '.jsonl'), '');
  await wait(260);
  watcher.stop();
  assert.deepEqual(sessions, [id]);
});

test('retains a JSONL record split across polling cycles', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'serein-jsonl-'));
  cleanup.push(dir);
  const file = join(dir, 'session.jsonl');
  const events = [];
  const watcher = createJsonlWatcher({
    sessionDir: dir,
    onEvent: (type, content) => events.push({ type, content }),
  });

  watcher.start();
  await wait(20);
  writeFileSync(file, '');
  await wait(250);
  appendFileSync(file, '{"type":"assistant","message":{"content":[{"type":"text","text":"hel');
  await wait(250);
  appendFileSync(file, 'lo"}]}}\n');
  await wait(250);
  watcher.stop();

  assert.deepEqual(
    events.filter(({ type }) => type === 'text'),
    [{ type: 'text', content: 'hello' }],
  );
});

test('emits subagent lifecycle for Claude Task tool calls', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'serein-jsonl-subagent-'));
  cleanup.push(dir);
  const file = join(dir, 'session.jsonl');
  const events = [];
  const watcher = createJsonlWatcher({
    sessionDir: dir,
    onEvent: (type, content, toolName) => events.push({ type, content, toolName }),
  });

  watcher.start();
  await wait(20);
  writeFileSync(file, '');
  await wait(250);
  appendFileSync(file, JSON.stringify({
    type: 'assistant',
    message: {
      content: [{ type: 'tool_use', id: 'tool-1', name: 'Task', input: { description: '检查发布配置' } }],
      stop_reason: 'tool_use',
    },
  }) + '\n');
  appendFileSync(file, JSON.stringify({
    type: 'user',
    message: { content: [{ type: 'tool_result', tool_use_id: 'tool-1', content: 'done' }] },
  }) + '\n');
  await wait(300);
  watcher.stop();

  assert.deepEqual(
    events.filter(({ type }) => type.startsWith('subagent_')),
    [
      { type: 'subagent_start', content: '检查发布配置', toolName: 'Task' },
      { type: 'subagent_stop', content: '检查发布配置', toolName: 'Task' },
    ],
  );
});

test('emits the full lifecycle for Agent questions', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'serein-jsonl-question-'));
  cleanup.push(dir);
  const file = join(dir, 'session.jsonl');
  const events = [];
  const watcher = createJsonlWatcher({
    sessionDir: dir,
    onEvent: (type, content, name) => events.push({ type, content, name }),
  });

  watcher.start();
  await wait(20);
  writeFileSync(file, '');
  await wait(250);
  appendFileSync(file, JSON.stringify({
    type: 'assistant',
    message: {
      content: [{
        type: 'tool_use', id: 'ask-1', name: 'AskUserQuestion',
        input: { questions: [{ header: '发布', question: '现在发布吗？', options: [{ label: '发布' }, { label: '稍后' }] }] },
      }],
      stop_reason: 'tool_use',
    },
  }) + '\n');
  appendFileSync(file, JSON.stringify({
    type: 'user',
    message: { content: [{ type: 'tool_result', tool_use_id: 'ask-1', content: '用户选择了发布' }] },
  }) + '\n');
  await wait(300);
  watcher.stop();

  const questionEvents = events.filter(({ type }) =>
    type === 'question' || type === 'choice' || type === 'question_resolved');
  assert.equal(questionEvents[0].type, 'question');
  assert.equal(JSON.parse(questionEvents[0].content).question, '现在发布吗？');
  assert.deepEqual(questionEvents.slice(1, 5).map(({ type, content, name }) => ({ type, content, name })), [
    { type: 'choice', content: '1. 发布', name: 'ask-1:0' },
    { type: 'choice', content: '2. 稍后', name: 'ask-1:0' },
    { type: 'choice', content: '3. Type something.', name: 'ask-1:0' },
    { type: 'choice', content: '4. Chat about this', name: 'ask-1:0' },
  ]);
  assert.deepEqual(questionEvents[5], {
    type: 'question_resolved', content: 'ask-1', name: 'ask-1',
  });
});
