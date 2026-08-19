#!/usr/bin/env node
/**
 * serein CLI 入口 — npm 全局安装后的 `serein` 命令。
 *
 * 自动从 ~/.claude/settings.json 读取后端地址和 Token，
 * 注入环境变量后启动 serein.mjs。用户无需任何手动配置。
 */
'use strict';

const { spawn, spawnSync } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

// ── 解析包根目录 ──
const PKG_ROOT = path.resolve(__dirname, '..');
const AGENT_DIR = path.join(PKG_ROOT, 'agent');
const SEREIN_MJS = path.join(AGENT_DIR, 'serein.mjs');

const rawArgs = process.argv.slice(2);
const args = [];
let selectedAgent = '';
for (let index = 0; index < rawArgs.length; index += 1) {
  const arg = rawArgs[index];
  if (arg === '--agent') {
    const value = String(rawArgs[index + 1] || '').trim();
    if (!value || value.startsWith('-')) {
      console.error('[serein] --agent 缺少值；可选值：claude、codex');
      process.exit(1);
    }
    selectedAgent = value.toLowerCase();
    index += 1;
    continue;
  }
  if (arg.startsWith('--agent=')) {
    selectedAgent = arg.slice('--agent='.length).trim().toLowerCase();
    if (!selectedAgent) {
      console.error('[serein] --agent 缺少值；可选值：claude、codex');
      process.exit(1);
    }
    continue;
  }
  args.push(arg);
}
if (selectedAgent && !['claude', 'codex'].includes(selectedAgent)) {
  console.error(`[serein] 不支持的 Agent: ${selectedAgent}；可选值：claude、codex`);
  process.exit(1);
}
if (selectedAgent) process.env.SEREIN_AGENT_TYPE = selectedAgent;
const command = args[0];

function runNodeScript(scriptName, scriptArgs = []) {
  const scriptPath = path.join(PKG_ROOT, 'scripts', scriptName);
  if (!fs.existsSync(scriptPath)) {
    console.error('[serein] 错误: 安装不完整，找不到 ' + scriptPath);
    process.exit(1);
  }
  const result = spawnSync(process.execPath, [scriptPath, ...scriptArgs], {
    stdio: 'inherit',
  });
  process.exit(result.status ?? 1);
}

function printHelp() {
  const version = require(path.join(PKG_ROOT, 'package.json')).version;
  console.log(`serein ${version} — 自托管 AI 编程审批网关`);
  console.log('');
  console.log('用法:');
  console.log('  serein [项目路径]        启动当前项目的远程终端');
  console.log('  serein start [项目路径]  同上，显式启动');
  console.log('  serein setup             配置 Claude Code Hook');
  console.log('  serein init              setup 的易记别名');
  console.log('  serein doctor            只读检查安装、配置和后端连接');
  console.log('  serein pair [项目路径]   显示项目配对二维码');
  console.log('  serein daemon            启动后台 Relay');
  console.log('  --agent claude|codex     选择本次启动使用的 Agent');
  console.log('  serein --help            显示帮助');
  console.log('  serein --version         显示版本');
}

if (command === 'setup' || command === 'init') {
  runNodeScript('postinstall.js', args.slice(1));
}

if (command === 'doctor') {
  runNodeScript('doctor.js', args.slice(1));
}

if (command === 'help' || command === '--help' || command === '-h') {
  printHelp();
  process.exit(0);
}

if (command === 'version' || command === '--version' || command === '-v') {
  console.log(require(path.join(PKG_ROOT, 'package.json')).version);
  process.exit(0);
}

let relayArgs = args;
if (command === 'start') relayArgs = args.slice(1);
if (command === 'pair') relayArgs = ['--qr', ...args.slice(1)];
if (command === 'daemon') relayArgs = ['--daemon', ...args.slice(1)];

// ── 检查 serein.mjs 是否存在 ──
if (!fs.existsSync(SEREIN_MJS)) {
  console.error('[serein] 错误: 找不到 serein.mjs，安装可能不完整');
  console.error('[serein] 预期路径: ' + SEREIN_MJS);
  console.error('[serein] 请运行 serein doctor 查看完整诊断。');
  process.exit(1);
}

// ── 从 ~/.claude/settings.json 读取配置，注入环境变量 ──
const env = { ...process.env };
env.SEREIN_AGENT_DIR = AGENT_DIR;
if (!env.SEREIN_AGENT_PY) {
  env.SEREIN_AGENT_PY = path.join(AGENT_DIR, 'local_agent.py');
}

// 如果环境变量未设置，从 settings.json 读取后端地址和 Token
if (!env.SEREIN_BACKEND || !env.SEREIN_HOOK_TOKEN || !env.SEREIN_AGENT_PROXY) {
  const settingsPath = path.join(os.homedir(), '.claude', 'settings.json');
  try {
    if (fs.existsSync(settingsPath)) {
      const settings = JSON.parse(fs.readFileSync(settingsPath, 'utf-8'));
      const sereinEnv = settings.env || {};
      if (!env.SEREIN_BACKEND && sereinEnv.SEREIN_BACKEND) {
        env.SEREIN_BACKEND = sereinEnv.SEREIN_BACKEND;
      }
      if (!env.SEREIN_HOOK_TOKEN && sereinEnv.SEREIN_HOOK_TOKEN) {
        env.SEREIN_HOOK_TOKEN = sereinEnv.SEREIN_HOOK_TOKEN;
      }
      if (!env.SEREIN_AGENT_PROXY && sereinEnv.SEREIN_AGENT_PROXY) {
        env.SEREIN_AGENT_PROXY = sereinEnv.SEREIN_AGENT_PROXY;
      }
    }
  } catch (e) {
    // settings.json 读取失败不致命，serein.mjs 会报具体错误
  }
}

// ── 启动 serein.mjs ──
const child = spawn(process.execPath, [SEREIN_MJS, ...relayArgs], {
  stdio: 'inherit',
  env: env,
  cwd: process.cwd(),
});

child.on('error', (err) => {
  console.error('[serein] 启动失败:', err.message);
  process.exit(1);
});

child.on('exit', (code, signal) => {
  if (signal) {
    process.kill(process.pid, signal);
  } else {
    process.exit(code || 0);
  }
});
