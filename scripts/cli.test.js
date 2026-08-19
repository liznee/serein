'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

const cli = path.resolve(__dirname, '..', 'bin', 'serein.js');

function run(args) {
  return spawnSync(process.execPath, [cli, ...args], {
    encoding: 'utf8',
    timeout: 5000,
    windowsHide: true,
  });
}

test('CLI documents the Claude and Codex selector', () => {
  const result = run(['--help']);
  assert.equal(result.status, 0);
  assert.match(result.stdout, /--agent claude\|codex/);
});

test('CLI accepts Codex case-insensitively for non-start commands', () => {
  const result = run(['--agent', 'CODEX', '--version']);
  assert.equal(result.status, 0);
  assert.match(result.stdout, /^\d+\.\d+\.\d+/);
});

test('CLI rejects unsupported agents before starting the relay', () => {
  const result = run(['--agent=gemini', '--version']);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /不支持的 Agent/);
});

test('CLI rejects a missing agent option value', () => {
  const result = run(['--agent', '--version']);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /--agent 缺少值/);
});
