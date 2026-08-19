#!/usr/bin/env node
/**
 * serein-util — serein 纯工具函数（ANSI 处理、日志脱敏、shell 元字符检测）
 *
 * 从 serein.mjs 提取为独立模块以减少主文件体积。
 * 所有函数均为纯函数，无状态依赖。
 */

/**
 * 预处理 PTY 原始输出：将光标移动序列转换为等效的纯文本控制字符。
 *
 * 手动解析器方案（非正则替换），解决两个核心问题：
 * 1. 列跟踪：同行 H 序列根据列间距插入空格，防止碎片无分隔拼接
 *    （选项 "1. Yes" "2. No" → 之前变成 "1. Yes2. No"，现在 "1. Yes 2. No"）
 * 2. 部分转义序列缓冲：PTY 数据跨 chunk 分割时，不完整的 ESC 序列
 *    会被缓冲到下次调用，防止截断导致解析失败和字符竖排
 *
 * SGR 颜色码 (\x1b[...m) 原样保留，供手机端 parseAnsi 渲染彩色。
 * 必须在 stripAnsi 之前调用。
 */

// ── 状态跟踪器（跨 preprocessPty 调用持久化）──
let _prevHRow = -1;      // 上一个 H 序列的行号（-1 = 帧边界后未初始化）
let _currentCol = 0;     // 当前光标列位置（0-indexed，跟踪文本写入推进）
let _escapeBuffer = '';  // 跨 chunk 的不完整转义序列缓冲

/** 重置 PTY 预处理状态（新会话/新对话轮次时调用） */
export function resetPtyState() {
  _prevHRow = -1;
  _currentCol = 0;
  _escapeBuffer = '';
}

/**
 * 查找转义序列的结束位置。
 * @param text 完整文本
 * @param start ESC 字符位置
 * @returns 结束位置索引（含），-1 表示序列不完整
 */
function findEscapeEnd(text, start) {
  if (text[start] !== '\x1b') return -1;
  if (start + 1 >= text.length) return -1;

  const c = text[start + 1];

  if (c === '[') {
    // CSI: ESC [ params... final(0x40-0x7e)
    for (let i = start + 2; i < text.length; i++) {
      const code = text.charCodeAt(i);
      if (code >= 0x40 && code <= 0x7e) return i;
    }
    return -1;  // 不完整
  }

  if (c === ']') {
    // OSC: ESC ] ... ST(BEL | ESC \)
    for (let i = start + 2; i < text.length; i++) {
      if (text[i] === '\x07') return i;
      if (text[i] === '\x1b' && i + 1 < text.length && text[i + 1] === '\\') return i + 1;
    }
    return -1;
  }

  if (c === 'P' || c === '_' || c === 'X' || c === '^') {
    // DCS/APC/SOS/PM: ESC P/_/X/^ ... ST
    for (let i = start + 2; i < text.length; i++) {
      if (text[i] === '\x1b' && i + 1 < text.length && text[i + 1] === '\\') return i + 1;
      if (text[i] === '\x9c') return i;
    }
    return -1;
  }

  // ESC + 单字符（ESC 7, ESC 8, ESC =, ESC > 等）
  return start + 1;
}

/**
 * 处理单个转义序列，返回替换文本。
 * SGR (m) 原样返回；光标移动序列转为 \n/\r/空格；其他序列移除。
 */
function processEscape(seq) {
  if (seq.length < 2) return '';

  if (seq[1] === '[') {
    // CSI 序列
    let paramStart = 2;
    let isPrivate = false;
    if (seq.length > 2 && seq[2] === '?') {
      isPrivate = true;
      paramStart = 3;
    }

    const final = seq[seq.length - 1];
    const paramStr = seq.substring(paramStart, seq.length - 1);
    const params = paramStr ? paramStr.split(';').map(p => parseInt(p) || 0) : [];

    if (isPrivate) {
      // ?25l(隐藏光标) / ?25h(显示光标) → 帧边界，重置状态
      if (final === 'l' || final === 'h') {
        _prevHRow = -1;
        _currentCol = 0;
      }
      return '';
    }

    switch (final) {
      case 'H':
      case 'f': {
        // 光标定位：row;col（1-indexed）
        const row = params[0] || 1;
        const col = params[1] || 1;
        if (_prevHRow === -1 || row !== _prevHRow) {
          // 跨行：行分隔
          _prevHRow = row;
          _currentCol = col - 1;  // 转 0-indexed
          return '\n';
        }
        // 同行：根据列间距插入空格
        const targetCol = col - 1;  // 0-indexed
        const gap = targetCol - _currentCol;
        _currentCol = targetCol;
        if (gap > 0) return ' '.repeat(gap);
        return '';  // 重叠/同位置：覆盖，不插入分隔
      }
      case 'G': {
        // 光标水平绝对移动到指定列 → \r（行首重绘）
        _currentCol = (params[0] || 1) - 1;
        return '\r';
      }
      case 'C': {
        // 光标右移 N 列 → N 个空格
        const n = params[0] || 1;
        _currentCol += n;
        return ' '.repeat(n);
      }
      case 'D': {
        // 光标左移 N 列 → \r（回到行首重绘）
        const n = params[0] || 1;
        _currentCol = Math.max(0, _currentCol - n);
        return '\r';
      }
      case 'A':
      case 'B': {
        // 光标上/下移 → 行分隔（TUI 换行）
        _prevHRow = -1;
        return '\n';
      }
      case 'J': {
        // 清屏：2J = 全屏清，0J = 光标到屏底
        if ((params[0] || 0) === 2) {
          _prevHRow = -1;
          _currentCol = 0;
        }
        return '';
      }
      case 'K':
        // 清除行：直接移除
        return '';
      case 'm':
        // SGR 颜色码：原样保留供手机端渲染彩色
        return seq;
      default:
        // 其他 CSI 序列：移除
        return '';
    }
  }

  // OSC/DCS/APC 等非 CSI 序列：移除
  return '';
}

export function preprocessPty(raw) {
  // 合并上次残留的不完整转义序列
  let text = _escapeBuffer + raw;
  _escapeBuffer = '';

  let result = '';
  let i = 0;

  while (i < text.length) {
    const ch = text[i];

    if (ch === '\x1b') {
      // 尝试解析完整转义序列
      const end = findEscapeEnd(text, i);
      if (end < 0) {
        // 序列不完整：缓冲到下次调用
        _escapeBuffer = text.substring(i);
        // 防止缓冲区无限增长（异常场景兜底）
        if (_escapeBuffer.length > 200) _escapeBuffer = '';
        break;
      }
      const seq = text.substring(i, end + 1);
      result += processEscape(seq);
      i = end + 1;
    } else if (ch === '\r') {
      _currentCol = 0;
      result += '\r';
      i++;
    } else if (ch === '\n') {
      _currentCol = 0;
      result += '\n';
      i++;
    } else if (ch === '\t') {
      _currentCol = Math.min(_currentCol + 8 - (_currentCol % 8), 120);
      result += '\t';
      i++;
    } else if (text.charCodeAt(i) >= 32) {
      // 可打印字符（含 Unicode 多字节）
      const code = text.codePointAt(i);
      const char = String.fromCodePoint(code);
      result += char;
      _currentCol += 1;
      i += char.length;
    } else {
      // 其他控制字符：跳过
      i++;
    }
  }

  return result;
}

// ── ANSI 剥离（保留 SGR 颜色码供手机端 parseAnsi 渲染彩色，仅过滤非可见序列）──
export function stripAnsi(text) {
  // 只过滤 OSC/DCS/APC/SOS/PM 和非 SGR CSI（光标移动/清屏等），保留 SGR 颜色码 (\x1b[...m)
  let result = text;
  // OSC 序列: ESC ] ... ST(BEL|ESC\|\x9c) —— 窗口标题、剪贴板等
  result = result.replace(/[\x1b\x9b]\][^\x1b\x07\x9c]*(?:\x1b\\|\x07|\x9c)/g, '');
  // DCS 序列: ESC P ... ST
  result = result.replace(/\x1bP[^\x1b\x9c]*(?:\x1b\\|\x9c)/g, '');
  // APC 序列: ESC _ ... ST
  result = result.replace(/\x1b_[^\x1b\x9c]*(?:\x1b\\|\x9c)/g, '');
  // SOS / PM 序列: ESC X / ESC ^ ... ST
  result = result.replace(/\x1b[X^][^\x1b\x9c]*(?:\x1b\\|\x9c)/g, '');
  // 非 SGR CSI 序列（光标移动、清屏、DECTCEM 等，排除以 m 结尾的 SGR）
  result = result.replace(/\x1b\[[\x20-\x2f]*[\x30-\x3f]*[\x40-\x6c\x6e-\x7e]/g, '');
  result = result.replace(/\x9b[\x20-\x2f]*[\x30-\x3f]*[\x40-\x6c\x6e-\x7e]/g, '');
  // 单字符 ESC 序列。排除多字符序列的引入字节：P(DCS) X(SOS) [(CSI) ](OSC) ^(PM) _(APC)
  // 这些引入字节已在前面分别处理；若在此匹配会吃掉后续 SGR 颜色码的 ESC[ 前缀
  result = result.replace(/\x1b[\x40-\x4f\x51-\x57\x59-\x5a\x5c]/g, '');
  // 控制字符（保留 \t \n \r；保留 \x1b / \x9b —— SGR 颜色码的组成部分）
  result = result.replace(/[\x00-\x08\x0b\x0c\x0e-\x1a\x1c-\x1f\x7f-\x9a\x9c-\x9f]/g, '');
  return result;
}

// ── 日志脱敏（防 CR/LF 日志注入 + token 字段泄漏）──

// 匹配 JSON 中的 "token":"<value>" 字段，与 Go 后端 ws_handler.go tokenFieldRe 保持一致。
// 处理截断 JSON（缺少尾部引号），覆盖 token 泄漏到错误日志的攻击场景。
const tokenFieldRe = /"token"\s*:\s*"[^"]*"?/;

export function sanitizeLog(text) {
  // 先脱敏 token 字段（HOOK_TOKEN/CLIENT_TOKEN），防止出现在 agent 日志中
  text = text.replace(tokenFieldRe, '"token":"***"');
  // 控制字符替换（\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f）
  return text.replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]/g, '.');
}

// ── shell 元字符检测（匹配后端 agent_relay.go containsShellMeta）──
// 仅匹配真正危险的 shell 元字符：; | & $ ` < >
// 移除 ! ? # * [ ] { } ( ) ~ ' " \ \n \r 等自然语言标点，
// 避免手机端聊天消息（含 ? ! ' " 等）被静默丢弃。
// 注意：当前 JS/TS 模块中无 import 使用此函数（Shell 元字符检测在 Go 侧
// agent_relay.go:93 有独立实现）。保留实现供参考/未来使用，不 export。
function containsShellMeta(s) {
  return /[;&|$`<>]/.test(s);
}

/** 剥离 SGR 颜色码，保留其他可见文本（用于思考模式检测时去掉颜色干扰）*/
export function stripSgr(text) {
  return text.replace(/\x1b\[[\d;:]*m/g, '').replace(/\x9b[\d;:]*m/g, '');
}

// ── 进度动画 / spinner 字符检测 ──
// Claude Code PTY 输出中使用的旋转指示符 Unicode 范围
export function hasSpinnerChar(text) {
  // Claude Code PTY 输出中实测出现的旋转指示符和进度字符。
  // 仅匹配以下具体字符，不使用宽 Unicode 范围，避免误匹配 CJK 符号：
  //   ◐ ◓ ◑ ◒ — 旋转圆盘
  //   ✶ ✢ ✽ ✻ — 星形旋转
  //   ● — 黑色圆点（Claude Code TUI spinner 指示符，如 "●Thinking for 8s"）
  // 排除 ·（中间点 U+00B7）和 …（省略号 U+2026）：这两个字符在正常文本中频繁出现
  // （如 "· item"列表、自然语言省略），短行(<120字符)时容易被误判为 spinner 行
  // 而丢弃正常文本。排除 * 和 • 同理。
  return /[◐◓◑◒✶✢✽✻●]/u.test(text);
}
