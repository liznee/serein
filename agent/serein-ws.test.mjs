import assert from 'node:assert/strict';
import { test } from 'node:test';

import { createWsSendQueue } from './serein-ws.mjs';

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

test('keeps queued messages while disconnected and resumes after rejoin', async () => {
  const sent = [];
  let socket = { readyState: 0, bufferedAmount: 0, send: (msg) => sent.push(msg) };
  const queue = createWsSendQueue(() => socket);

  queue.wsEnqueue('tool-event');
  await wait(20);
  assert.deepEqual(sent, []);

  socket = { readyState: 1, bufferedAmount: 0, send: (msg) => sent.push(msg) };
  queue.resumeWsSendQueue();
  await wait(20);
  assert.deepEqual(sent, ['tool-event']);
});

test('waits for queued control frames before history replay continues', async () => {
  const sent = [];
  const socket = { readyState: 1, bufferedAmount: 0, send: (msg) => sent.push(msg) };
  const queue = createWsSendQueue(() => socket);

  queue.wsEnqueue('desktop_thread_taken');
  assert.equal(await queue.waitForQueueBelow(0, 500), true);
  assert.deepEqual(sent, ['desktop_thread_taken']);

  for (let index = 0; index < 24; index++) queue.wsEnqueue(`history-${index}`);
  assert.equal(await queue.waitForQueueBelow(4, 500), true);
  await queue.waitForQueueBelow(0, 500);
  assert.equal(sent.length, 25);
  assert.equal(sent[0], 'desktop_thread_taken');
});
