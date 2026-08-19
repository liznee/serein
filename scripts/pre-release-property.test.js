'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { normalizeBackend } = require('./doctor-lib');

const CASES = 100;
const SEED = 0x5e71e1;

function rng(seed = SEED) {
  let value = seed >>> 0;
  return () => {
    value = (value + 0x6d2b79f5) >>> 0;
    let out = value;
    out = Math.imul(out ^ (out >>> 15), out | 1);
    out ^= out + Math.imul(out ^ (out >>> 7), out | 61);
    return ((out ^ (out >>> 14)) >>> 0) / 0x100000000;
  };
}

function token(next, length = 28) {
  const alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-';
  let value = '';
  for (let i = 0; i < length; i += 1) value += alphabet[Math.floor(next() * alphabet.length)];
  return value;
}

test(`property: normalizeBackend removes credentials and request-only URL parts (${CASES} seeds)`, () => {
  const next = rng();
  for (let i = 0; i < CASES; i += 1) {
    const scheme = i % 2 === 0 ? 'https' : 'http';
    const user = token(next, 10);
    const password = token(next, 14);
    const host = `example-${i}.invalid`;
    const path = `/api/${Math.floor(next() * 1000)}/`;
    const raw = `${scheme}://${user}:${password}@${host}${path}?access_token=${token(next)}#${token(next, 8)}`;
    const result = normalizeBackend(raw);
    assert.ok(result.url, `seed ${i} must be accepted`);
    assert.equal(result.url.username, '', `seed ${i} leaked username`);
    assert.equal(result.url.password, '', `seed ${i} leaked password`);
    assert.equal(result.url.search, '', `seed ${i} leaked query`);
    assert.equal(result.url.hash, '', `seed ${i} leaked fragment`);
    assert.equal(result.url.pathname.endsWith('/'), false, `seed ${i} retained trailing slash`);
    assert.equal(result.url.origin, `${scheme}://${host}`);
  }
});

test(`property: unsupported backend schemes and malformed values fail closed (${CASES} seeds)`, () => {
  const next = rng(SEED + 1);
  const schemes = ['ftp', 'file', 'javascript', 'data', 'ws', 'wss'];
  for (let i = 0; i < CASES; i += 1) {
    const raw = i % 4 === 0
      ? `${schemes[i % schemes.length]}://host-${i}.invalid/${token(next, 8)}`
      : `${token(next, 3)} ${token(next, 9)}`;
    const result = normalizeBackend(raw);
    assert.ok(result.error, `seed ${i} unexpectedly accepted ${raw}`);
    assert.equal(result.url, undefined, `seed ${i} returned a URL on failure`);
  }
});

test(`property: Agent registry accepts only normalized documented agents (${CASES} seeds)`, async () => {
  const { normalizeAgentType } = await import('../agent/agent-registry.mjs');
  const next = rng(SEED + 2);
  const documented = ['claude', 'codex'];
  for (let i = 0; i < CASES; i += 1) {
    const name = documented[i % documented.length];
    const decorated = `${' '.repeat(i % 3)}${[...name].map(c => next() > 0.5 ? c.toUpperCase() : c).join('')}${' '.repeat((i + 1) % 3)}`;
    assert.equal(normalizeAgentType(decorated), name, `seed ${i} did not normalize ${decorated}`);
  }
  for (let i = 0; i < CASES; i += 1) {
    const invalid = `agent-${i}-${token(next, 7)}`;
    assert.throws(() => normalizeAgentType(invalid), RangeError, `seed ${i} accepted an undocumented agent`);
  }
});

test(`property: sanitizeLog redacts random token fields and control bytes (${CASES} seeds)`, async () => {
  const { sanitizeLog } = await import('../agent/serein-util.mjs');
  const next = rng(SEED + 3);
  for (let i = 0; i < CASES; i += 1) {
    const secret = token(next, 24 + (i % 16));
    const input = `before\u0000 {"token":"${secret}"} \u001b after-${i}`;
    const output = sanitizeLog(input);
    assert.equal(output.includes(secret), false, `seed ${i} leaked token content`);
    assert.match(output, /"token":"\*\*\*"/, `seed ${i} did not redact token field`);
    assert.equal(/[\u0000\u001b]/.test(output), false, `seed ${i} retained an unsafe control byte`);
  }
});

test(`property: trust detector never auto-confirms random generic prompts (${CASES} seeds)`, async () => {
  const { isAgentTrustPrompt } = await import('../agent/trust-prompt.mjs');
  const next = rng(SEED + 4);
  for (let i = 0; i < CASES; i += 1) {
    const noise = `Warning ${token(next, 8)}: trust=${token(next, 6)} permission=${token(next, 6)} ${i}`;
    assert.equal(isAgentTrustPrompt('claude', noise), false, `seed ${i} auto-confirmed generic Claude text`);
    assert.equal(isAgentTrustPrompt('codex', noise), false, `seed ${i} auto-confirmed generic Codex text`);
  }
});
