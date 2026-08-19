#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const required = [
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
const forbidden = [
  /(^|\/)__pycache__(\/|$)/i,
  /\.pyc$/i,
  /(^|\/)test[^/]*\.(py|js|mjs)$/i,
  /(^|\/)scripts\/(export-personal|export-public)\.ps1$/i,
  /(^|\/)scripts\/sign-and-install\.ps1$/i,
  /(^|\/)AGENTS\.md$/i,
  /(^|\/)private(\/|$)/i,
  /\.log$/i,
  /\.db(?:-wal|-shm)?$/i,
];

function fail(message) {
  console.error('✗ ' + message);
  process.exitCode = 1;
}

function ok(message) {
  console.log('✓ ' + message);
}

function main() {
  const packageJson = JSON.parse(fs.readFileSync(path.join(ROOT, 'package.json'), 'utf8'));
  if (!packageJson.name || !packageJson.version || !packageJson.bin?.serein) {
    fail('package.json 缺少 name、version 或 bin.serein');
    return;
  }
  ok(`package.json: ${packageJson.name}@${packageJson.version}`);

  const packed = process.platform === 'win32'
    ? spawnSync('C:\\Windows\\System32\\cmd.exe', ['/d', '/s', '/c', 'npm pack --dry-run --json'], {
        cwd: ROOT,
        encoding: 'utf8',
        timeout: 60000,
        windowsHide: true,
      })
    : spawnSync('npm', ['pack', '--dry-run', '--json'], {
        cwd: ROOT,
        encoding: 'utf8',
        timeout: 60000,
        windowsHide: true,
      });
  if (packed.status !== 0) {
    fail('npm pack --dry-run 失败');
    if (packed.stderr) console.error(packed.stderr.trim());
    return;
  }

  let manifest;
  try {
    manifest = JSON.parse(packed.stdout)[0];
  } catch (error) {
    fail('无法解析 npm pack 清单: ' + error.message);
    return;
  }
  const files = manifest.files.map(item => item.path.replace(/\\/g, '/'));
  const missing = required.filter(file => !files.includes(file));
  if (missing.length) fail('npm 包缺少运行文件: ' + missing.join(', '));
  else ok('npm 包运行文件完整');

  const leaked = files.filter(file => forbidden.some(pattern => pattern.test(file)));
  if (leaked.length) fail('npm 包含不应发布的文件: ' + leaked.join(', '));
  else ok('npm 包未包含测试、缓存、日志、私人导出或危险签名脚本');

  if (files.length > 40) fail(`npm 包文件过多（${files.length}），请复核 files 白名单`);
  else ok(`npm 包清单精简为 ${files.length} 个文件`);

  const packageBytes = manifest.unpackedSize || 0;
  if (packageBytes > 2 * 1024 * 1024) fail(`npm 解包体积异常：${packageBytes} bytes`);
  else ok(`npm 解包体积：${packageBytes} bytes`);

  const binPath = path.join(ROOT, packageJson.bin.serein);
  if (!fs.existsSync(binPath)) fail('bin.serein 指向的文件不存在');
  else ok('全局命令入口存在');
}

main();
