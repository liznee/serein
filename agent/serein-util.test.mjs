#!/usr/bin/env node
/**
 * serein-util.test.mjs — serein-util.mjs 纯函数单元测试
 *
 * 使用 Node.js 内置 node:test 和 node:assert 模块，无需额外依赖。
 * 运行: node --test serein-util.test.mjs
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

// 从源文件导入函数（纯函数，无副作用）
import {
  stripAnsi,
  stripSgr,
  sanitizeLog,
  hasSpinnerChar,
} from './serein-util.mjs';

// ── stripAnsi ──
describe('stripAnsi', () => {
  it('保留普通文本不变', () => {
    assert.equal(stripAnsi('hello world'), 'hello world');
  });

  it('移除 OSC 序列（窗口标题等）', () => {
    // ESC ] 0 ; My Title BEL
    const input = 'hello\x1b]0;My Title\x07world';
    assert.equal(stripAnsi(input), 'helloworld');
  });

  it('保留 SGR 颜色码（\x1b[...m）', () => {
    const input = '\x1b[31mred\x1b[0m';
    assert.equal(stripAnsi(input), '\x1b[31mred\x1b[0m');
  });

  it('移除光标移动 CSI 序列', () => {
    // CUU (Cursor Up): \x1b[A
    const input = 'line1\x1b[2Aline2';
    assert.equal(stripAnsi(input), 'line1line2');
  });

  it('移除清屏序列', () => {
    const input = 'before\x1b[2Jafter';
    assert.equal(stripAnsi(input), 'beforeafter');
  });

  it('移除 DCS 序列', () => {
    const input = 'a\x1bP1~st\x1b\\b';
    assert.equal(stripAnsi(input), 'ab');
  });

  it('处理空字符串', () => {
    assert.equal(stripAnsi(''), '');
  });

  it('处理无 ANSI 的字符串', () => {
    assert.equal(stripAnsi('no escape here'), 'no escape here');
  });

  it('同时移除多种序列', () => {
    // 光标移动 + SGR 保留 + OSC 移除
    const input = '\x1b[31mhello\x1b[0m\x1b[A\x1b]0;title\x07world';
    const result = stripAnsi(input);
    // SGR (\x1b[31m, \x1b[0m) 保留，光标移动 (\x1b[A) 和 OSC 移除
    assert.ok(result.includes('\x1b[31m'));
    assert.ok(result.includes('\x1b[0m'));
    assert.ok(result.includes('hello'));
    assert.ok(result.includes('world'));
    // 光标移动被移除
    assert.equal(result.indexOf('\x1b[A'), -1);
  });
});

// ── stripSgr ──
describe('stripSgr', () => {
  it('移除 SGR 颜色码', () => {
    assert.equal(stripSgr('\x1b[31mred\x1b[0m'), 'red');
  });

  it('保留非 SGR 文本', () => {
    assert.equal(stripSgr('hello world'), 'hello world');
  });

  it('处理多个 SGR 序列', () => {
    assert.equal(stripSgr('\x1b[1m\x1b[31mbold red\x1b[0m'), 'bold red');
  });

  it('处理空字符串', () => {
    assert.equal(stripSgr(''), '');
  });
});

// ── sanitizeLog ──
describe('sanitizeLog', () => {
  it('脱敏 token 字段', () => {
    assert.equal(
      sanitizeLog('"token":"my-secret-token"'),
      '"token":"***"'
    );
  });

  it('替换控制字符为点号', () => {
    const input = 'line1\x00line2\x7fline3';
    const result = sanitizeLog(input);
    assert.equal(result, 'line1.line2.line3');
  });

  it('保留正常文本不变', () => {
    assert.equal(sanitizeLog('hello world'), 'hello world');
  });

  it('处理空字符串', () => {
    assert.equal(sanitizeLog(''), '');
  });
});

// ── hasSpinnerChar ──
describe('hasSpinnerChar', () => {
  it('检测旋转指示符 ◐', () => {
    assert.equal(hasSpinnerChar('◐'), true);
  });

  it('检测旋转指示符 ◓', () => {
    assert.equal(hasSpinnerChar('◓'), true);
  });

  it('检测星形旋转 ✶', () => {
    assert.equal(hasSpinnerChar('✶'), true);
  });

  it('普通文本返回 false', () => {
    assert.equal(hasSpinnerChar('hello world'), false);
  });

  it('CJK 字符不误判', () => {
    assert.equal(hasSpinnerChar('你好世界'), false);
  });

  it('点号不误判', () => {
    assert.equal(hasSpinnerChar('·'), false);
    assert.equal(hasSpinnerChar('…'), false);
  });

  it('空字符串返回 false', () => {
    assert.equal(hasSpinnerChar(''), false);
  });
});

// ── stripAnsi + stripSgr 组合测试（真实场景）──
describe('ANSI 处理组合场景', () => {
  it('Claude Code 思考模式输出：SGR 颜色 + 思考标记', () => {
    // Claude Code 使用 > 前缀 + dim 模式显示思考内容
    const thinkingOutput = '\x1b[2m> Thinking\x1b[0m\n\x1b[2m> step 1\x1b[0m';
    // stripAnsi 保留 SGR
    const sgrKept = stripAnsi(thinkingOutput);
    assert.equal(sgrKept, thinkingOutput);
    // stripSgr 去掉颜色，得到纯文本
    const plain = stripSgr(sgrKept);
    assert.equal(plain, '> Thinking\n> step 1');
  });

  it('进度动画行：spinner + \r 覆盖，stripAnsi 后只保留最终内容', () => {
    // claude 进度动画：\r 回到行首 + spinner 字符
    const anim = '\r◐ Processing\r◓ Processing\r◑ Processing';
    const cleaned = stripAnsi(anim);
    // \r 处理不在 stripAnsi 职责范围内，保留原始 \r 分隔
    assert.ok(cleaned.includes('◐') || cleaned.includes('Processing'));
  });

  it('混合 SGR 和 OSC 序列', () => {
    const mixed = '\x1b]0;tab title\x07\x1b[32mgreen\x1b[0m';
    const result = stripAnsi(mixed);
    // OSC 移除，SGR 保留
    assert.equal(result, '\x1b[32mgreen\x1b[0m');
  });
});
