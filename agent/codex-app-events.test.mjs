import assert from 'node:assert/strict';
import test from 'node:test';

import {
  CodexAppEventAdapter,
  eventsFromThreadItem,
  historyEventsFromThread,
} from './codex-app-events.mjs';

test('normalizes persisted desktop history', () => {
  const events = historyEventsFromThread({
    turns: [{
      id: 'turn-1',
      status: 'completed',
      items: [
        { id: 'u1', type: 'userMessage', content: [{ type: 'text', text: '你好' }] },
        { id: 'a1', type: 'agentMessage', text: '你好，我在。', phase: 'final_answer' },
        { id: 'w1', type: 'webSearch', query: '上海天气' },
      ],
    }],
  });
  assert.deepEqual(events.map((event) => event.type), [
    'desktop_history_reset', 'turn_start', 'user_msg', 'stream_text',
    'tool_use', 'tool_result', 'turn_end',
  ]);
  assert.equal(events[3].toolName, 'a1');
});

test('coalesces agent message deltas under one item id', () => {
  const events = [];
  const adapter = new CodexAppEventAdapter({
    onEvent: (type, content, toolName) => events.push({ type, content, toolName }),
  });
  adapter.handle({ method: 'item/started', params: {
    item: { id: 'a1', type: 'agentMessage', text: '' }, threadId: 't1', turnId: 'r1',
  }});
  adapter.handle({ method: 'item/agentMessage/delta', params: {
    itemId: 'a1', delta: '你', threadId: 't1', turnId: 'r1',
  }});
  adapter.handle({ method: 'item/agentMessage/delta', params: {
    itemId: 'a1', delta: '好', threadId: 't1', turnId: 'r1',
  }});
  assert.deepEqual(events.slice(-2), [
    { type: 'stream_text', content: '你', toolName: 'a1' },
    { type: 'stream_text', content: '你好', toolName: 'a1' },
  ]);
});

test('maps command completion to tool start and result', () => {
  const events = eventsFromThreadItem({
    id: 'c1', type: 'commandExecution', command: 'npm test',
    status: 'completed', aggregatedOutput: 'ok', exitCode: 0,
  });
  assert.equal(events[0].type, 'tool_use');
  assert.equal(events[0].toolName, 'Terminal');
  assert.equal(events[1].type, 'tool_result');
  assert.match(events[1].content, /Exit code: 0/);
});

