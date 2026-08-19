import { stripTerminalControl } from './trust-prompt.mjs';

const MAX_BUFFER_CHARS = 64 * 1024;
const REPEAT_SUPPRESS_MS = 3_000;
const MAX_APPROVAL_DETAIL = 2_000;

function cleanLine(value) {
  return String(value || '')
    .replace(/\u00a0/g, ' ')
    .replace(/[ \t]+/g, ' ')
    .trim();
}

function promptId(signature) {
  let hash = 2166136261;
  for (let i = 0; i < signature.length; i++) {
    hash ^= signature.charCodeAt(i);
    hash = Math.imul(hash, 16777619);
  }
  return `codex-tui-${(hash >>> 0).toString(16)}`;
}

function approvalId(signature) {
  let hash = 2166136261;
  for (let i = 0; i < signature.length; i++) {
    hash ^= signature.charCodeAt(i);
    hash = Math.imul(hash, 16777619);
  }
  return `codex-approval-${(hash >>> 0).toString(16)}`;
}

function truncateDetail(text) {
  const clean = String(text || '').trim();
  if (clean.length <= MAX_APPROVAL_DETAIL) return clean;
  return `${clean.slice(0, MAX_APPROVAL_DETAIL)}\n…（内容已截断）`;
}

/**
 * Extract a numbered Codex TUI choice screen.
 *
 * A selected-row marker (›/❯/>) and a question ending in "?" are both
 * required. This intentionally rejects ordinary numbered lists in model
 * output. The first-run directory trust screen is handled separately and is
 * excluded here because Serein already confirms that exact prompt safely.
 */
export function extractCodexChoicePrompt(rawOutput) {
  // Codex uses a right-chevron as the selected row marker. Normalize its two
  // common glyph forms so the parser is stable across terminal encodings.
  const plain = stripTerminalControl(rawOutput).replace(/^[\u203a\u276f]/gmu, '>');
  const lines = plain.split(/\r\n|\n|\r/).map(cleanLine).filter(Boolean);
  let best = null;

  for (let start = 0; start < lines.length; start++) {
    const first = lines[start].match(/^([›❯>]\s*)?(\d+)\.\s+(.+)$/u);
    if (!first || Number(first[2]) !== 1) continue;

    const options = [];
    let hasSelectionMarker = false;
    let expected = 1;
    let end = start;
    for (let i = start; i < lines.length; i++) {
      const match = lines[i].match(/^([›❯>]\s*)?(\d+)\.\s+(.+)$/u);
      if (!match || Number(match[2]) !== expected) break;
      hasSelectionMarker = hasSelectionMarker || !!match[1];
      options.push({ number: expected, label: cleanLine(match[3]) });
      expected += 1;
      end = i;
      if (options.length >= 9) break;
    }
    if (options.length < 2 || !hasSelectionMarker) continue;

    let questionIndex = -1;
    const questionSearchStart = Math.max(0, start - 6);
    for (let i = start - 1; i >= questionSearchStart; i--) {
      if (/\?\s*$/u.test(lines[i])) {
        questionIndex = i;
        break;
      }
    }
    let updateHeading = '';
    if (questionIndex < 0) {
      for (let i = start - 1; i >= questionSearchStart; i--) {
        if (/\bUpdate available!/iu.test(lines[i])) {
          updateHeading = lines[i];
          break;
        }
      }
      if (updateHeading === '') continue;
    }

    const questionLine = questionIndex >= 0 ? lines[questionIndex] : 'Choose how to continue.';
    if (/Do you trust the contents of this directory\?/iu.test(questionLine)) continue;

    let header = updateHeading;
    if (header === '' && questionIndex > 0) {
      const candidate = lines[questionIndex - 1]
        .replace(/^[•⚠]\s*/u, '')
        .trim();
      if (candidate !== '' && !/^[›❯>]?\s*\d+\./u.test(candidate)) header = candidate;
    }
    const question = header !== '' ? `${header}\n${questionLine}` : questionLine;
    const signature = `${question}\u0000${options.map((item) => `${item.number}.${item.label}`).join('\u0000')}`;
    best = {
      id: promptId(signature),
      header,
      question,
      options,
      signature,
      end,
    };
  }

  return best;
}

/**
 * Patterns for Codex CLI sandbox approval prompts.
 *
 * Codex CLI renders approval requests in the TUI with a header line like
 * "Codex wants to run:" or "Codex wants to modify:" followed by the command
 * or file path, and then a row of single-key shortcuts:
 *   [y]es  [n]o  [a]lways  [esc]ape
 *
 * The exact wording varies slightly across Codex versions, so we match
 * common prefixes rather than exact strings.
 */
const APPROVAL_PATTERNS = [
  {
    kind: 'command',
    headerRegex: /(?:codex\s+)?wants\s+to\s+(?:run|execute)\b/iu,
    label: '命令执行审批',
  },
  {
    kind: 'file',
    headerRegex: /(?:codex\s+)?wants\s+to\s+(?:modify|change|write|edit|patch)\b/iu,
    label: '文件修改审批',
  },
];

const APPROVAL_KEY_LINE_REGEX = /\[y\]\s*es.*\[n\]\s*o.*(?:\[a\]\s*lways)?.*(?:\[esc\]\s*ape)?/iu;

/**
 * Extract a Codex CLI sandbox approval prompt from raw PTY output.
 *
 * Returns null if no approval prompt is found. The returned object has:
 *   - id: stable hash for dedup
 *   - kind: 'command' | 'file'
 *   - detail: the command text or file path(s)
 *   - signature: for dedup
 */
export function extractCodexApprovalPrompt(rawOutput) {
  const plain = stripTerminalControl(rawOutput);
  const lines = plain.split(/\r\n|\n|\r/).map(cleanLine).filter(Boolean);

  for (const pattern of APPROVAL_PATTERNS) {
    for (let i = 0; i < lines.length; i++) {
      if (!pattern.headerRegex.test(lines[i])) continue;

      // Collect detail lines between the header and the key-shortcut line.
      const detailLines = [];
      let keyLineIndex = -1;
      for (let j = i + 1; j < Math.min(i + 20, lines.length); j++) {
        if (APPROVAL_KEY_LINE_REGEX.test(lines[j])) {
          keyLineIndex = j;
          break;
        }
        // Stop if we hit another header or a very long line (likely model output).
        if (APPROVAL_PATTERNS.some(p => p.headerRegex.test(lines[j]))) break;
        if (lines[j].length > 500) break;
        detailLines.push(lines[j]);
      }
      if (keyLineIndex < 0) continue;

      // Filter out empty or UI-noise lines from the detail.
      const filtered = detailLines
        .filter((line) => {
          if (!line) return false;
          // Skip TUI decorative elements
          if (/^[│|┌┐└┘─═]/.test(line)) return false;
          if (/^\s*[•●○]/.test(line)) return false;
          return true;
        })
        .map((line) => line.replace(/^[›❯>]\s*/, '').trim());

      if (filtered.length === 0) continue;

      const detail = truncateDetail(filtered.join('\n'));
      const signature = `${pattern.kind}\u0000${detail}`;
      const id = approvalId(signature);

      return {
        id,
        kind: pattern.kind,
        label: pattern.label,
        detail,
        signature,
      };
    }
  }

  return null;
}

/**
 * Stateful detector for PTY redraw chunks. It emits the same question/choice
 * events as the JSONL adapters so the HarmonyOS client needs no Codex-only UI.
 *
 * Additionally, it detects Codex CLI sandbox approval prompts (y/n/a) and
 * emits codex_approval_required / codex_approval_resolved events so the phone
 * can use the same approval UI as Claude Code hooks.
 */
export function createCodexPromptDetector(onEvent, now = () => Date.now()) {
  let buffer = '';
  let activeId = '';
  let lastSignature = '';
  let lastEmittedAt = 0;
  let activeApprovalId = '';

  function push(chunk) {
    buffer = (buffer + String(chunk || '')).slice(-MAX_BUFFER_CHARS);

    // Check for approval prompts first — they take priority over choice
    // prompts because the key-shortcut line ([y]es [n]o) could be
    // misinterpreted as a numbered choice by the choice extractor.
    const approval = extractCodexApprovalPrompt(buffer);
    if (approval) {
      if (activeApprovalId === approval.id) return approval;
      if (lastSignature === approval.signature && now() - lastEmittedAt < REPEAT_SUPPRESS_MS) {
        return approval;
      }
      // If a choice prompt was active, resolve it first to avoid stale state.
      if (activeId !== '') {
        const resolvedId = activeId;
        activeId = '';
        onEvent('question_resolved', resolvedId, resolvedId);
      }
      activeApprovalId = approval.id;
      lastSignature = approval.signature;
      lastEmittedAt = now();
      onEvent('codex_approval_required', JSON.stringify({
        approval_id: approval.id,
        tool_use_id: approval.id,
        kind: approval.kind,
        label: approval.label,
        detail: approval.detail,
      }), approval.id);
      return approval;
    }

    const prompt = extractCodexChoicePrompt(buffer);
    if (!prompt) return null;
    if (activeId === prompt.id) return prompt;
    if (lastSignature === prompt.signature && now() - lastEmittedAt < REPEAT_SUPPRESS_MS) return prompt;

    activeId = prompt.id;
    lastSignature = prompt.signature;
    lastEmittedAt = now();
    onEvent('question', JSON.stringify({
      question_id: prompt.id,
      tool_use_id: prompt.id,
      question: prompt.question,
      header: prompt.header,
    }), prompt.id);
    for (const option of prompt.options) {
      onEvent('choice', `${option.number}. ${option.label}`, prompt.id);
    }
    return prompt;
  }

  function resolve() {
    let resolved = false;
    if (activeId !== '') {
      const resolvedId = activeId;
      activeId = '';
      buffer = '';
      onEvent('question_resolved', resolvedId, resolvedId);
      resolved = true;
    }
    if (activeApprovalId !== '') {
      const resolvedApprovalId = activeApprovalId;
      activeApprovalId = '';
      buffer = '';
      onEvent('codex_approval_resolved', resolvedApprovalId, resolvedApprovalId);
      resolved = true;
    }
    return resolved;
  }

  function reset() {
    buffer = '';
    activeId = '';
    activeApprovalId = '';
    lastSignature = '';
    lastEmittedAt = 0;
  }

  function hasActivePrompt() {
    return activeId !== '' || activeApprovalId !== '';
  }

  function hasActiveApproval() {
    return activeApprovalId !== '';
  }

  function getActiveApprovalId() {
    return activeApprovalId;
  }

  return { push, resolve, reset, hasActivePrompt, hasActiveApproval, getActiveApprovalId };
}
