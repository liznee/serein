'use strict';

const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const test = require('node:test');

const { findSereinHook, normalizeBackend, runDoctor } = require('./doctor-lib');

function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'serein-doctor-root-'));
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'serein-doctor-home-'));
  for (const file of ['bin/serein.js', 'agent/serein.mjs', 'agent/local_agent.py', 'hooks/approval_hook.py']) {
    const full = path.join(root, file);
    fs.mkdirSync(path.dirname(full), { recursive: true });
    fs.writeFileSync(full, 'fixture');
  }
  fs.writeFileSync(path.join(root, 'package.json'), JSON.stringify({ version: '9.9.9' }));
  return { root, home };
}

test('normalizeBackend accepts HTTP URLs and removes credentials/query data', () => {
  const result = normalizeBackend('https://user:secret@example.com/base/?token=secret#x');
  assert.equal(result.error, undefined);
  assert.equal(result.url.toString(), 'https://example.com/base');
});

test('findSereinHook locates approval_hook.py without exposing token data', () => {
  const command = findSereinHook({
    hooks: { PreToolUse: [{ matcher: 'Bash', hooks: [{ command: 'python "/tmp/approval_hook.py"' }] }] },
  });
  assert.match(command, /approval_hook\.py/);
});

test('doctor reports a healthy configured installation', async t => {
  const { root, home } = fixture();
  t.after(() => {
    fs.rmSync(root, { recursive: true, force: true });
    fs.rmSync(home, { recursive: true, force: true });
  });
  const settingsPath = path.join(home, '.claude', 'settings.json');
  fs.mkdirSync(path.dirname(settingsPath), { recursive: true });
  fs.writeFileSync(settingsPath, JSON.stringify({
    env: {
      SEREIN_BACKEND: 'https://example.com',
      SEREIN_HOOK_TOKEN: 'abcdefghijklmnopqrstuvwxyz012345',
    },
    hooks: {
      PreToolUse: [{
        matcher: 'Bash|Edit|Write|NotebookEdit',
        hooks: [{ type: 'command', command: 'python "/tmp/approval_hook.py"' }],
      }],
    },
  }));
  fs.mkdirSync(path.join(home, '.serein'), { recursive: true });
  fs.writeFileSync(path.join(home, '.serein', 'projects.json'), '{}');

  const report = await runDoctor({
    root,
    home,
    env: {},
    findPython: () => ({ command: 'python', version: 'Python 3.12.0' }),
    commandVersion: () => '2.1.0',
    probeBackend: async () => ({ ok: true, message: 'HTTP 200' }),
  });

  assert.equal(report.summary.error, 0);
  assert.equal(JSON.stringify(report).includes('abcdefghijklmnopqrstuvwxyz012345'), false);
});

test('doctor fails safely when configuration is missing', async t => {
  const { root, home } = fixture();
  t.after(() => {
    fs.rmSync(root, { recursive: true, force: true });
    fs.rmSync(home, { recursive: true, force: true });
  });
  const report = await runDoctor({
    root,
    home,
    env: {},
    skipNetwork: true,
    findPython: () => ({ command: 'python', version: 'Python 3.12.0' }),
    commandVersion: () => null,
  });
  assert.ok(report.summary.error >= 3);
});

test('doctor marks Codex as experimental and rejects Gemini', async t => {
  const { root, home } = fixture();
  t.after(() => {
    fs.rmSync(root, { recursive: true, force: true });
    fs.rmSync(home, { recursive: true, force: true });
  });
  const settingsPath = path.join(home, '.claude', 'settings.json');
  fs.mkdirSync(path.dirname(settingsPath), { recursive: true });
  fs.writeFileSync(settingsPath, JSON.stringify({
    env: {
      SEREIN_BACKEND: 'https://example.com',
      SEREIN_HOOK_TOKEN: 'abcdefghijklmnopqrstuvwxyz012345',
    },
    hooks: {
      PreToolUse: [{
        matcher: 'Bash|Edit|Write|NotebookEdit',
        hooks: [{ type: 'command', command: 'python "/tmp/approval_hook.py"' }],
      }],
    },
  }));

  const codexReport = await runDoctor({
    root,
    home,
    env: { SEREIN_AGENT_TYPE: ' CODEX ' },
    skipNetwork: true,
    findPython: () => ({ command: 'python', version: 'Python 3.12.0' }),
    commandVersion: () => '1.0.0',
  });
  assert.equal(codexReport.checks.find(check => check.id === 'agent_capabilities').status, 'warn');

  const geminiReport = await runDoctor({
    root,
    home,
    env: { SEREIN_AGENT_TYPE: 'gemini' },
    skipNetwork: true,
    findPython: () => ({ command: 'python', version: 'Python 3.12.0' }),
    commandVersion: () => '1.0.0',
  });
  assert.equal(geminiReport.checks.find(check => check.id === 'agent_cli').status, 'error');
});

test('Codex can use explicit environment config without Claude settings', async t => {
  const { root, home } = fixture();
  t.after(() => {
    fs.rmSync(root, { recursive: true, force: true });
    fs.rmSync(home, { recursive: true, force: true });
  });
  const report = await runDoctor({
    root,
    home,
    env: {
      SEREIN_AGENT_TYPE: 'codex',
      SEREIN_BACKEND: 'https://example.com',
      SEREIN_HOOK_TOKEN: 'abcdefghijklmnopqrstuvwxyz012345',
    },
    skipNetwork: true,
    findPython: () => ({ command: 'python', version: 'Python 3.12.0' }),
    commandVersion: () => '1.0.0',
  });
  assert.equal(report.checks.find(check => check.id === 'settings').status, 'pass');
  assert.equal(report.checks.find(check => check.id === 'hook').status, 'pass');
});
