'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

const requiredFiles = [
  'bin/serein.js',
  'agent/serein.mjs',
  'agent/agent-registry.mjs',
  'agent/codex-jsonl.mjs',
  'agent/codex-pty-prompt.mjs',
  'agent/trust-prompt.mjs',
  'agent/local_agent.py',
  'hooks/approval_hook.py',
  'scripts/postinstall.js',
  'scripts/doctor.js',
  'scripts/doctor-lib.js',
];

test('release check accepts a UTF-8 BOM in package.json', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'serein-release-check-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));

  for (const relativePath of requiredFiles) {
    const target = path.join(root, relativePath);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, relativePath === 'bin/serein.js' ? '#!/usr/bin/env node\n' : '');
  }

  const checkerTarget = path.join(root, 'scripts', 'release-check.js');
  fs.copyFileSync(path.join(__dirname, 'release-check.js'), checkerTarget);

  const manifest = {
    name: '@serein/release-check-fixture',
    version: '1.0.0-rc.1',
    bin: { serein: 'bin/serein.js' },
    files: requiredFiles,
  };
  fs.writeFileSync(path.join(root, 'package.json'), `\uFEFF${JSON.stringify(manifest, null, 2)}\n`);

  const result = spawnSync(process.execPath, [checkerTarget], {
    cwd: root,
    encoding: 'utf8',
    timeout: 60_000,
    windowsHide: true,
  });

  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
});
