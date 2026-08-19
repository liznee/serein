#!/usr/bin/env node

import assert from 'node:assert/strict';
import test from 'node:test';
import { AGENT_TYPES, getAgentConfig, normalizeAgentType } from './agent-registry.mjs';

test('registry exposes only the documented agent types', () => {
  assert.deepEqual(AGENT_TYPES, ['claude', 'codex']);
});

test('Claude is full and Codex exposes its experimental native approval path', () => {
  const claude = getAgentConfig('claude');
  assert.equal(claude.supportLevel, 'full');
  assert.equal(claude.supportsStructuredEvents, true);
  assert.equal(claude.eventAdapter, 'claude');
  assert.equal(claude.supportsApprovalHook, true);

  const codex = getAgentConfig('codex');
  assert.equal(codex.supportLevel, 'experimental');
  assert.equal(codex.supportsStructuredEvents, true);
  assert.equal(codex.supportsApprovalHook, true);
  assert.equal(codex.eventAdapter, 'codex');
});

test('agent type normalization is strict and case-insensitive', () => {
  assert.equal(normalizeAgentType(' CODEX '), 'codex');
  assert.throws(() => normalizeAgentType('unknown'), /Unsupported SEREIN_AGENT_TYPE/);
});
