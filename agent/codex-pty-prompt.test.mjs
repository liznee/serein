#!/usr/bin/env node

import assert from 'node:assert/strict';
import test from 'node:test';
import { createCodexPromptDetector, extractCodexChoicePrompt } from './codex-pty-prompt.mjs';

const RATE_LIMIT_PROMPT = '\x1b[2JApproaching rate limits\r\n'
  + 'Switch to gpt-5.4-mini for lower credit usage?\r\n\x1b[1m'
  + '› 1. Switch to gpt-5.4-mini  Small, fast, and cost-efficient model for simpler coding tasks.\x1b[0m\r\n'
  + '  2. Keep current model\r\n'
  + '  3. Keep current model (never show again)  Hide future warnings\r\n';

const UPDATE_PROMPT = '\x1b[2J✨ Update available! 0.144.4 -> 0.144.5\r\n'
  + 'Release notes: https://github.com/openai/codex/releases/latest\r\n\r\n'
  + '› 1. Update now (runs `npm install -g @openai/codex`)\r\n'
  + '  2. Skip\r\n'
  + '  3. Skip until next version\r\n\r\n'
  + 'Press enter to continue\r\n';

test('extracts the Codex rate-limit question and numbered choices through ANSI redraws', () => {
  const prompt = extractCodexChoicePrompt(RATE_LIMIT_PROMPT);
  assert.ok(prompt);
  assert.equal(prompt.question, 'Approaching rate limits\nSwitch to gpt-5.4-mini for lower credit usage?');
  assert.deepEqual(prompt.options.map((item) => item.number), [1, 2, 3]);
  assert.equal(prompt.options[2].label, 'Keep current model (never show again) Hide future warnings');
});

test('does not turn ordinary numbered model output into an interactive prompt', () => {
  assert.equal(extractCodexChoicePrompt('Choose an approach?\n1. First\n2. Second\n'), null);
});

test('extracts Codex update menu without auto-selecting an action', () => {
  const prompt = extractCodexChoicePrompt(UPDATE_PROMPT);
  assert.ok(prompt);
  assert.equal(prompt.header, '✨ Update available! 0.144.4 -> 0.144.5');
  assert.equal(prompt.question, '✨ Update available! 0.144.4 -> 0.144.5\nChoose how to continue.');
  assert.deepEqual(prompt.options.map((item) => item.label), [
    'Update now (runs `npm install -g @openai/codex`)',
    'Skip',
    'Skip until next version',
  ]);
});

test('does not emit the directory trust prompt handled by the trust detector', () => {
  const trust = 'Do you trust the contents of this directory?\r\n› 1. Yes, continue\r\n2. No, quit\r\n';
  assert.equal(extractCodexChoicePrompt(trust), null);
});

test('emits one structured question group across split chunks and resolves it', () => {
  const events = [];
  let clock = 1000;
  const detector = createCodexPromptDetector(
    (type, content, name) => events.push({ type, content, name }),
    () => clock,
  );
  detector.push(RATE_LIMIT_PROMPT.slice(0, 80));
  assert.equal(events.length, 0);
  detector.push(RATE_LIMIT_PROMPT.slice(80));
  assert.deepEqual(events.map((event) => event.type), ['question', 'choice', 'choice', 'choice']);
  detector.push('\x1b[H' + RATE_LIMIT_PROMPT);
  assert.equal(events.length, 4);
  assert.equal(detector.hasActivePrompt(), true);
  assert.equal(detector.resolve(), true);
  assert.equal(events.at(-1).type, 'question_resolved');
  assert.equal(detector.hasActivePrompt(), false);

  clock += 4000;
  detector.push(RATE_LIMIT_PROMPT);
  assert.equal(events.filter((event) => event.type === 'question').length, 2);
});
