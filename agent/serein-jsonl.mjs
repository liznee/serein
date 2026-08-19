/**
 * serein-jsonl — Session JSONL 文件监听器
 *
 * 监听 Claude Code 的 session JSONL 文件，解析结构化事件，
 * 通过回调推送 thinking / text / tool_use / tool_result 到手机端。
 *
 * JSONL 文件路径：~/.claude/projects/<project-dir>/<session_id>.jsonl
 * 项目目录名规则：C:/workspace/serein → C--workspace-serein
 *
 * 事件类型映射：
 *   JSONL assistant/thinking  → callback('thinking', content)
 *   JSONL assistant/text      → callback('text', content)
 *   JSONL assistant/tool_use  → callback('tool_use', content, toolName)
 *   JSONL user/tool_result    → callback('tool_result', content)
 *   其他类型（mode/system/attachment 等）→ 忽略
 */

import { readdirSync, statSync, openSync, readSync, closeSync, existsSync, readFileSync } from 'fs';
import { basename, join } from 'path';

// ═══ 终端 Diff 生成 ═══

const MAX_DIFF_LINES = 40;  // 终端最多显示 40 行 diff，避免刷屏

/**
 * 为 Write/Edit/MultiEdit/string_replace 工具调用生成 unified diff 文本。
 * 返回空字符串表示不支持的工具或无变更。
 */
function generateToolDiff(toolName, input) {
  if (!input || typeof input !== 'object') return '';

  if (toolName === 'Write') {
    const fp = input.file_path || '';
    const newContent = input.content || '';
    let oldContent = '';
    try {
      if (fp && existsSync(fp)) {
        oldContent = readFileSync(fp, 'utf-8');
      }
    } catch (e) { /* 文件不存在或不可读 */ }

    const oldLines = oldContent ? oldContent.split('\n') : [];
    const newLines = newContent ? newContent.split('\n') : [];

    // 简单 diff：找公共前缀和后缀，中间部分为变更
    let prefix = 0;
    while (prefix < oldLines.length && prefix < newLines.length && oldLines[prefix] === newLines[prefix]) prefix++;

    let suffix = 0;
    while (suffix < oldLines.length - prefix && suffix < newLines.length - prefix
           && oldLines[oldLines.length - 1 - suffix] === newLines[newLines.length - 1 - suffix]) suffix++;

    const oldChanged = oldLines.slice(prefix, oldLines.length - suffix);
    const newChanged = newLines.slice(prefix, newLines.length - suffix);

    if (oldChanged.length === 0 && newChanged.length === 0) return '';

    // 截断过长的 diff
    const maxLines = MAX_DIFF_LINES;
    let truncated = false;
    let oldDisplay = oldChanged;
    let newDisplay = newChanged;
    if (oldChanged.length + newChanged.length > maxLines) {
      const oldKeep = Math.min(oldChanged.length, Math.floor(maxLines / 2));
      const newKeep = Math.min(newChanged.length, maxLines - oldKeep);
      oldDisplay = oldChanged.slice(0, oldKeep);
      newDisplay = newChanged.slice(0, newKeep);
      truncated = true;
    }

    let diff = `--- a/${fp}\n+++ b/${fp}\n`;
    diff += `@@ -${prefix + 1},${oldDisplay.length} +${prefix + 1},${newDisplay.length} @@\n`;
    for (const line of oldDisplay) diff += `-${line}\n`;
    for (const line of newDisplay) diff += `+${line}\n`;
    if (truncated) diff += `... (diff truncated, ${oldChanged.length + newChanged.length} total changed lines)`;
    return diff;
  }

  if (toolName === 'Edit' || toolName === 'string_replace') {
    const fp = input.file_path || '';
    const oldStr = input.old_string || '';
    const newStr = input.new_string || '';
    if (!oldStr && !newStr) return '';
    // 截断过长的字符串
    const maxStr = 300;
    const oldDisp = oldStr.length > maxStr ? oldStr.substring(0, maxStr) + '...' : oldStr;
    const newDisp = newStr.length > maxStr ? newStr.substring(0, maxStr) + '...' : newStr;
    let diff = `--- a/${fp}\n+++ b/${fp}\n@@ -1,1 +1,1 @@\n`;
    // 多行字符串拆分为多行 diff
    const oldLines = oldDisp.split('\n');
    const newLines = newDisp.split('\n');
    for (const line of oldLines) diff += `-${line}\n`;
    for (const line of newLines) diff += `+${line}\n`;
    return diff;
  }

  if (toolName === 'MultiEdit') {
    const fp = input.file_path || '';
    const edits = input.edits || [];
    if (!Array.isArray(edits) || edits.length === 0) return '';
    let diff = `--- a/${fp}\n+++ b/${fp}\n`;
    let lineCount = 0;
    for (let i = 0; i < edits.length; i++) {
      if (lineCount >= MAX_DIFF_LINES) {
        diff += `... (diff truncated at edit #${i + 1})`;
        break;
      }
      const edit = edits[i];
      if (!edit || typeof edit !== 'object') continue;
      const oldS = (edit.old_string || '').substring(0, 200);
      const newS = (edit.new_string || '').substring(0, 200);
      diff += `@@ edit #${i + 1} @@\n`;
      for (const line of oldS.split('\n')) { diff += `-${line}\n`; lineCount++; }
      for (const line of newS.split('\n')) { diff += `+${line}\n`; lineCount++; }
    }
    return diff;
  }

  return '';
}

/**
 * 创建 JSONL 文件监听器实例。
 * @param {Object} deps
 * @param {string} deps.sessionDir - session JSONL 文件所在目录
 * @param {Function} deps.onEvent - (eventType, content, toolName) => void
 * @returns {{ start: Function, stop: Function, reset: Function }}
 */
export function createJsonlWatcher(deps) {
  const { sessionDir, onEvent, onSession = () => {} } = deps;

  let currentFile = null;
  let lastSize = 0;
  let partialLine = '';
  let pollTimer = null;
  let startupTime = Date.now();
  let lastSessionID = '';

  // ── 思考状态跟踪 ──
  let thinkingTimestamp = null;
  // Task/Agent 工具用 tool_use_id 与 tool_result 关联。记录关联后，手机端
  // 可以展示明确的子 Agent 启动/完成状态，而不只是一条普通工具日志。
  const toolNamesById = new Map();
  const subagentsByToolId = new Map();

  function isSubagentTool(toolName) {
    const name = String(toolName || '').toLowerCase();
    return name === 'task' || name === 'agent' || name === 'spawn_agent' || name === 'dispatch_agent';
  }

  function subagentLabel(input, fallback) {
    if (!input || typeof input !== 'object') return fallback || 'subagent';
    const label = input.description || input.subagent_type || input.agent_type || input.name || input.prompt || fallback || 'subagent';
    const text = String(label).replace(/\s+/g, ' ').trim();
    return text.length > 180 ? text.substring(0, 180) + '…' : text;
  }

  // ════════════════════════════════════════════
  // 轮询主循环：检测新文件 + 读取新内容
  // ════════════════════════════════════════════

  function poll() {
    try {
      // 找到最新修改的 .jsonl 文件（修改时间 > 启动时间）
      const files = readdirSync(sessionDir).filter(f => f.endsWith('.jsonl'));
      let best = null;
      let bestMtime = 0;

      for (const f of files) {
        const full = join(sessionDir, f);
        const stat = statSync(full);
        if (stat.mtimeMs > startupTime && stat.mtimeMs > bestMtime) {
          bestMtime = stat.mtimeMs;
          best = { path: full, stat, name: f };
        }
      }

      // 切换到新文件（首次发现或 /clear 后切换）
      if (best && best.path !== currentFile) {
        if (currentFile) {
          console.error(`[serein-jsonl] 切换 Session 文件: ${best.name}`);
        } else {
          console.error(`[serein-jsonl] 检测到 Session 文件: ${best.name}`);
        }
        currentFile = best.path;
        lastSize = best.stat.size;
        partialLine = '';
        const discoveredID = basename(best.name, '.jsonl');
        if (discoveredID && discoveredID !== lastSessionID) {
          lastSessionID = discoveredID;
          onSession(discoveredID);
        }
        // 不读取已有内容，只读取启动后的新内容
      }

      // 读取当前文件的新增内容
      if (currentFile) {
        const stat = statSync(currentFile);
        if (stat.size > lastSize) {
          const fd = openSync(currentFile, 'r');
          const buf = Buffer.alloc(stat.size - lastSize);
          readSync(fd, buf, 0, buf.length, lastSize);
          closeSync(fd);
          lastSize = stat.size;

          // JSONL 写入不是事务性的，最后一行可能跨轮询分两次写入。
          // 保留未完成尾行，避免 lastSize 前移后永久丢失该事件。
          const chunks = (partialLine + buf.toString('utf8')).split('\n');
          partialLine = chunks.pop() || '';
          const lines = chunks;
          for (const line of lines) {
            const trimmed = line.trim();
            if (!trimmed) continue;
            try {
              const evt = JSON.parse(trimmed);
              handleEvent(evt);
            } catch (e) {
              // 忽略 JSON 解析错误（可能是不完整的行）
            }
          }
        } else if (stat.size < lastSize - 100) {
          // 文件被截断或轮转（不太可能，但防御性处理）
          lastSize = stat.size;
          partialLine = '';
        }
      }
    } catch (e) {
      // 目录不存在或文件被删除，静默忽略
    }
  }

  // ════════════════════════════════════════════
  // JSONL 事件处理
  // ════════════════════════════════════════════

  function handleEvent(evt) {
    if (!evt || !evt.type) return;

    // 跳过 meta 消息（命令注解、本地命令等）
    if (evt.isMeta) return;

    switch (evt.type) {
      case 'assistant':
        handleAssistantEntry(evt);
        break;

      case 'user':
        handleUserEntry(evt);
        break;

      // 忽略：mode, permission-mode, file-history-snapshot,
      //       attachment, system, ai-title, last-prompt, queue-operation
      default:
        break;
    }
  }

  function handleAssistantEntry(evt) {
    const message = evt.message || {};
    const contentBlocks = message.content || [];
    if (!Array.isArray(contentBlocks)) return;

    // 结构化会话协议：turn_start 事件（标记新一轮对话开始）
    const stopReason = message.stop_reason || '';
    onEvent('turn_start', stopReason, '');

    for (const block of contentBlocks) {
      if (!block || !block.type) continue;

      switch (block.type) {
        case 'thinking':
          // 思考内容：记录时间戳，推送思考文本
          thinkingTimestamp = evt.timestamp;
          if (block.thinking) {
            onEvent('thinking', block.thinking, '');
          }
          break;

        case 'text':
          // 文本回复：先结束思考模式，再推送文本
          flushThinking(evt.timestamp);
          if (block.text) {
            onEvent('text', block.text, '');
          }
          break;

        case 'tool_use':
          // 工具调用：先结束思考模式，再推送工具信息
          flushThinking(evt.timestamp);
          const toolName = block.name || '';
          const toolUseId = block.id || '';
          if (toolUseId) toolNamesById.set(toolUseId, toolName);
          
          // 检测 AskUserQuestion / AskQuestion / SpecAskQuestion
          // 将选项提取为独立的 choice 事件，手机端渲染为可点击选项
          if (toolName === 'AskUserQuestion' || toolName === 'AskQuestion' || toolName === 'SpecAskQuestion') {
            const input = block.input || {};
            const questions = input.questions || [];
            for (let questionIndex = 0; questionIndex < questions.length; questionIndex++) {
              const q = questions[questionIndex] || {};
              const questionId = `${toolUseId || 'question'}:${questionIndex}`;
              const questionText = q.question || q.header || 'Agent 正在等待你的选择';
              onEvent('question', JSON.stringify({
                question_id: questionId,
                tool_use_id: toolUseId,
                question: questionText,
                header: q.header || '',
              }), questionId);
              const qOptions = q.options || [];
              for (let i = 0; i < qOptions.length; i++) {
                const label = qOptions[i].label || qOptions[i].id || '';
                if (label) {
                  onEvent('choice', (i + 1) + '. ' + label, questionId);
                }
              }
              // Claude Code TUI 在结构化选项之后会追加两个原生选项：
              // "Type something." — 用户自由输入文本
              // "Chat about this" — 就此问题继续对话
              // 这两个选项不在 JSONL 中，需要手动补全，否则手机端看不到
              const nextNum = qOptions.length + 1;
              onEvent('choice', nextNum + '. Type something.', questionId);
              onEvent('choice', (nextNum + 1) + '. Chat about this', questionId);
            }
            break;  // 不发送 tool_use 事件，选项已单独推送
          }
          
          let toolContent = '';
          try {
            toolContent = JSON.stringify(block.input || {}, null, 2);
          } catch (e) {
            toolContent = String(block.input || '');
          }
          // 截断过长的工具输入（如 WebSearch 的长 query）
          if (toolContent.length > 500) {
            toolContent = toolContent.substring(0, 500) + '...';
          }
          onEvent('tool_use', toolContent, toolName);

          if (isSubagentTool(toolName)) {
            const label = subagentLabel(block.input || {}, toolName);
            if (toolUseId) subagentsByToolId.set(toolUseId, label);
            onEvent('subagent_start', label, toolName);
          }
          
          // 文件编辑类工具：生成 diff 并推送到终端
          const diff = generateToolDiff(toolName, block.input || {});
          if (diff) {
            onEvent('tool_diff', diff, toolName);
          }
          break;

        // 忽略其他类型（如 image）
        default:
          break;
      }
    }

    // 结构化会话协议：turn_end 事件（标记本轮对话结束，携带 stop_reason）
    onEvent('turn_end', stopReason, '');
  }

  function handleUserEntry(evt) {
    const message = evt.message || {};
    const content = message.content;

    // 字符串内容 = 普通用户消息，发送到手机端显示
    // （之前跳过了，但 CMD 端输入的问题手机端看不到）
    if (typeof content === 'string') {
      if (content.trim()) {
        onEvent('user_msg', content, '');
      }
      return;
    }

    // 数组内容 = 可能包含 tool_result
    if (!Array.isArray(content)) return;

    for (const block of content) {
      if (!block || block.type !== 'tool_result') continue;

      let resultContent = '';
      if (typeof block.content === 'string') {
        resultContent = block.content;
      } else if (Array.isArray(block.content)) {
        for (const c of block.content) {
          if (c.type === 'text' && c.text) {
            resultContent += c.text;
          }
        }
      }
// 截断过长的工具结果（如 WebSearch 返回的大量搜索结果）
// 同时去掉 WebSearch 结果中的 Links JSON 数组部分（手机端不需要）
// Links 格式示例：\n\nLinks:\n[{"title":...,"url":...}] 或类似 JSON 数组
// 去掉从 "Links:" 到末尾或到下一个非 JSON 内容的部分
const linksIdx = resultContent.indexOf('\nLinks:');
if (linksIdx >= 0) {
  resultContent = resultContent.substring(0, linksIdx).trimEnd();
}
// 也去掉独立的 "Links:" 行及后续 JSON 数组
const linksIdx2 = resultContent.indexOf('Links:');
if (linksIdx2 >= 0 && (linksIdx2 === 0 || resultContent[linksIdx2 - 1] === '\n')) {
  resultContent = resultContent.substring(0, linksIdx2).trimEnd();
}
if (resultContent.length > 800) {
  resultContent = resultContent.substring(0, 800) + '\n... (结果已截断)';
}

      if (resultContent) {
        onEvent('tool_result', resultContent, '');
      }
      const toolUseId = block.tool_use_id || '';
      const sourceToolName = toolUseId ? (toolNamesById.get(toolUseId) || '') : '';
      if (sourceToolName === 'AskUserQuestion' || sourceToolName === 'AskQuestion' || sourceToolName === 'SpecAskQuestion') {
        onEvent('question_resolved', toolUseId, toolUseId);
      }
      if (toolUseId && subagentsByToolId.has(toolUseId)) {
        const label = subagentsByToolId.get(toolUseId) || sourceToolName || 'subagent';
        const status = block.is_error ? `${label} · 失败` : label;
        onEvent('subagent_stop', status, sourceToolName);
        subagentsByToolId.delete(toolUseId);
      }
      if (toolUseId) toolNamesById.delete(toolUseId);
    }
  }

  /**
   * 结束思考模式：发送 thinking_end 事件（含估算时长）
   */
  function flushThinking(currentTimestamp) {
    if (!thinkingTimestamp) return;

    let duration = 1;
    try {
      const start = new Date(thinkingTimestamp).getTime();
      const end = new Date(currentTimestamp).getTime();
      duration = Math.max(1, Math.round((end - start) / 1000));
    } catch (e) {
      duration = 1;
    }

    onEvent('thinking_end', String(duration), '');
    thinkingTimestamp = null;
  }

  // ════════════════════════════════════════════
  // 生命周期
  // ════════════════════════════════════════════

  function start() {
    if (pollTimer) return;
    if (!existsSync(sessionDir)) {
      console.error(`[serein-jsonl] Session 目录不存在: ${sessionDir}`);
      console.error('[serein-jsonl] 将在 claude.exe 创建后自动检测');
    }
    console.error(`[serein-jsonl] 监听目录: ${sessionDir}`);
    pollTimer = setInterval(poll, 200);
  }

  function stop() {
    if (pollTimer) {
      clearInterval(pollTimer);
      pollTimer = null;
    }
    currentFile = null;
    lastSize = 0;
    partialLine = '';
    thinkingTimestamp = null;
    toolNamesById.clear();
    subagentsByToolId.clear();
    lastSessionID = '';
  }

  /**
   * 重置监听器（/clear 后调用）
   * 清除当前文件引用，重新检测新文件
   */
  function reset() {
    currentFile = null;
    lastSize = 0;
    partialLine = '';
    thinkingTimestamp = null;
    toolNamesById.clear();
    subagentsByToolId.clear();
    lastSessionID = '';
    startupTime = Date.now();
  }

  return { start, stop, reset };
}
