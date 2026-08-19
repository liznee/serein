/**
 * Normalize Codex App Server threads and notifications into Serein terminal
 * events. The phone should not need to understand every App Server protocol
 * object; it only receives the same small event vocabulary used by CLI mode.
 */

const DEFAULT_HISTORY_TURNS = 20;
const MAX_TEXT = 24_000;
const MAX_TOOL_TEXT = 4_000;

function clampText(value, maxLength = MAX_TEXT) {
  const text = String(value ?? '').replace(/\r/g, '').trim();
  if (text.length <= maxLength) return text;
  return `${text.slice(0, maxLength)}\n…（内容已截断）`;
}

function userMessageText(item) {
  const content = Array.isArray(item?.content) ? item.content : [];
  return content
    .map((part) => {
      if (typeof part === 'string') return part;
      if (part?.type === 'text' && typeof part.text === 'string') return part.text;
      if (part?.type === 'image' || part?.type === 'localImage') return '[图片]';
      if (part?.type === 'skill' && part.name) return `[Skill: ${part.name}]`;
      if (part?.type === 'mention' && part.name) return `[@${part.name}]`;
      return '';
    })
    .filter(Boolean)
    .join('\n');
}

function reasoningText(item) {
  const summary = Array.isArray(item?.summary) ? item.summary : [];
  const content = Array.isArray(item?.content) ? item.content : [];
  return [...summary, ...content].map((part) => String(part ?? '')).filter(Boolean).join('\n');
}

function toolLabel(item) {
  switch (item?.type) {
    case 'commandExecution': return 'Terminal';
    case 'fileChange': return '文件修改';
    case 'mcpToolCall': return [item.server, item.tool].filter(Boolean).join(' · ') || 'MCP';
    case 'dynamicToolCall': return [item.namespace, item.tool].filter(Boolean).join(' · ') || '工具';
    case 'collabAgentToolCall': return item.tool || '子 Agent';
    case 'webSearch': return 'Web Search';
    case 'imageView': return '查看图片';
    case 'imageGeneration': return '生成图片';
    default: return String(item?.type || '工具');
  }
}

function toolInput(item) {
  switch (item?.type) {
    case 'commandExecution': return item.command || '';
    case 'fileChange':
      return (Array.isArray(item.changes) ? item.changes : [])
        .map((change) => change?.path || '')
        .filter(Boolean)
        .join('\n');
    case 'mcpToolCall':
    case 'dynamicToolCall':
      try { return JSON.stringify(item.arguments ?? item.input ?? {}, null, 2); } catch { return ''; }
    case 'collabAgentToolCall': return item.prompt || '';
    case 'webSearch': return item.query || '';
    case 'imageView': return item.path || '';
    case 'imageGeneration': return item.revisedPrompt || '';
    default: return '';
  }
}

function toolResult(item) {
  if (item?.type === 'commandExecution') {
    const output = item.aggregatedOutput || '';
    const suffix = item.exitCode == null ? '' : `\nExit code: ${item.exitCode}`;
    return `${output}${suffix}`.trim();
  }
  if (item?.type === 'fileChange') return item.status || 'completed';
  if (item?.type === 'mcpToolCall') {
    if (item.error?.message) return item.error.message;
    try { return JSON.stringify(item.result ?? { status: item.status }, null, 2); } catch { return item.status || ''; }
  }
  if (item?.type === 'dynamicToolCall') {
    const content = Array.isArray(item.contentItems)
      ? item.contentItems.map((part) => part?.text || '').filter(Boolean).join('\n')
      : '';
    return content || item.status || (item.success === false ? 'failed' : 'completed');
  }
  if (item?.type === 'collabAgentToolCall') return item.status || '';
  if (item?.type === 'webSearch') return 'completed';
  if (item?.type === 'imageGeneration') return item.result || item.status || '';
  return item?.status || '';
}

function isToolItem(item) {
  return [
    'commandExecution', 'fileChange', 'mcpToolCall', 'dynamicToolCall',
    'collabAgentToolCall', 'webSearch', 'imageView', 'imageGeneration',
  ].includes(item?.type);
}

export function eventsFromThreadItem(item, { completed = true } = {}) {
  if (!item || typeof item !== 'object') return [];
  const itemId = String(item.id || '');
  if (item.type === 'userMessage') {
    const text = clampText(userMessageText(item));
    return text ? [{ type: 'user_msg', content: text, toolName: itemId }] : [];
  }
  if (item.type === 'agentMessage') {
    const text = clampText(item.text);
    return text ? [{ type: 'stream_text', content: text, toolName: itemId }] : [];
  }
  if (item.type === 'reasoning') {
    const text = clampText(reasoningText(item));
    return text
      ? [
        { type: 'thinking', content: text, toolName: itemId },
        ...(completed ? [{ type: 'thinking_end', content: '1', toolName: itemId }] : []),
      ]
      : [];
  }
  if (item.type === 'plan') {
    const text = clampText(item.text);
    return text ? [{ type: 'stream_text', content: text, toolName: itemId }] : [];
  }
  if (!isToolItem(item)) return [];

  const label = toolLabel(item);
  const input = clampText(toolInput(item), MAX_TOOL_TEXT);
  const result = clampText(toolResult(item), MAX_TOOL_TEXT);
  return [
    { type: 'tool_use', content: input, toolName: label },
    ...(completed && result ? [{ type: 'tool_result', content: result, toolName: label }] : []),
  ];
}

export function historyEventsFromThread(thread, { maxTurns = DEFAULT_HISTORY_TURNS } = {}) {
  const turns = Array.isArray(thread?.turns) ? thread.turns.slice(-maxTurns) : [];
  const events = [{ type: 'desktop_history_reset', content: '', toolName: '' }];
  for (const turn of turns) {
    events.push({ type: 'turn_start', content: '', toolName: String(turn?.id || '') });
    for (const item of Array.isArray(turn?.items) ? turn.items : []) {
      events.push(...eventsFromThreadItem(item, { completed: true }));
    }
    events.push({ type: 'turn_end', content: String(turn?.status || ''), toolName: String(turn?.id || '') });
  }
  return events;
}

export class CodexAppEventAdapter {
  constructor({ onEvent = () => {} } = {}) {
    this.onEvent = onEvent;
    this.agentText = new Map();
    this.reasoningText = new Map();
  }

  reset() {
    this.agentText.clear();
    this.reasoningText.clear();
  }

  #emit(event) {
    if (!event) return;
    this.onEvent(event.type, event.content || '', event.toolName || '');
  }

  handle(message) {
    const method = String(message?.method || '');
    const params = message?.params || {};
    const item = params.item || null;
    const itemId = String(params.itemId || item?.id || '');

    if (method === 'turn/started') {
      this.#emit({ type: 'turn_start', content: '', toolName: String(params.turn?.id || params.turnId || '') });
      return;
    }
    if (method === 'turn/completed') {
      this.#emit({
        type: 'turn_end',
        content: String(params.turn?.status || params.status || 'completed'),
        toolName: String(params.turn?.id || params.turnId || ''),
      });
      return;
    }
    if (method === 'item/started') {
      if (item?.type === 'agentMessage') this.agentText.set(itemId, String(item.text || ''));
      if (item?.type === 'reasoning') this.reasoningText.set(itemId, reasoningText(item));
      for (const event of eventsFromThreadItem(item, { completed: false })) this.#emit(event);
      return;
    }
    if (method === 'item/agentMessage/delta') {
      const text = `${this.agentText.get(itemId) || ''}${params.delta || ''}`;
      this.agentText.set(itemId, text);
      this.#emit({ type: 'stream_text', content: text, toolName: itemId });
      return;
    }
    if (method === 'item/reasoning/summaryTextDelta' || method === 'item/reasoning/textDelta') {
      const text = `${this.reasoningText.get(itemId) || ''}${params.delta || ''}`;
      this.reasoningText.set(itemId, text);
      this.#emit({ type: 'thinking', content: text, toolName: itemId });
      return;
    }
    if (method === 'item/completed') {
      if (item?.type === 'agentMessage') this.agentText.delete(itemId);
      if (item?.type === 'reasoning') this.reasoningText.delete(itemId);
      const events = eventsFromThreadItem(item, { completed: true });
      for (const event of events) {
        // 工具在 item/started 时已经展示过调用卡片；完成时只补结果，避免
        // 同一个工具在手机端重复出现两次。普通文本仍以最终内容收口。
        if (isToolItem(item) && event.type !== 'tool_result') continue;
        this.#emit(event);
      }
    }
  }
}
