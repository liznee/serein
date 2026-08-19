#!/usr/bin/env node

import assert from 'node:assert/strict';
import test from 'node:test';
import { isAgentTrustPrompt, stripTerminalControl } from './trust-prompt.mjs';

test('detects the Codex directory trust screen through ANSI redraws', () => {
  const output = '\x1b[2JDo you trust the contents of this directory?\r\n'
    + '\x1b[1m› 1. Yes, continue\x1b[0m\r\n  2. No, quit\r\n';
  assert.equal(isAgentTrustPrompt('codex', output), true);
});

test('detects the Claude folder trust screen', () => {
  // 旧版文案
  assert.equal(isAgentTrustPrompt('claude', 'Do you trust the files in this folder?'), true);
  // 新版 v2.1.219+ 文案（正常空格）
  assert.equal(isAgentTrustPrompt('claude', 'Is this a project you created or one you trust?\n1. Yes, I trust this folder'), true);
  // 新版 v2.1.219+ 文案（PTY 空格被吃掉的情况）
  assert.equal(isAgentTrustPrompt('claude', 'Isthisaprojectyoucreatedoroneyoutrust?Yes,Itrustthisfolder'), true);
});

test('does not confirm generic trust or permission warnings', () => {
  assert.equal(isAgentTrustPrompt('codex', 'Trust is required to enable hooks.'), false);
  assert.equal(isAgentTrustPrompt('claude', 'This command needs permission.'), false);
  assert.equal(isAgentTrustPrompt('unknown', 'Do you trust the contents of this directory?'), false);
});

test('strips terminal control sequences without removing text', () => {
  assert.equal(stripTerminalControl('\x1b[31mhello\x1b[0m'), 'hello');
});
