#!/usr/bin/env node

/**
 * Runtime capabilities for every CLI that Serein can launch.
 *
 * "experimental" means the PTY and selected adapters are available, but
 * Serein must not claim approval parity with the fully supported integration.
 */
const REGISTRY = Object.freeze({
  claude: Object.freeze({
    name: 'claude',
    displayName: 'Claude Code',
    supportLevel: 'full',
    supportsStructuredEvents: true,
    supportsApprovalHook: true,
    eventAdapter: 'claude',
    sessionLayout: 'project-slug',
    binaryName: 'claude',
    binaryNameWin: 'claude.exe',
    envVar: 'CLAUDE_EXE',
    sessionDirBase: '.claude/projects',
    npmPath: 'AppData/Roaming/npm/claude.cmd',
    npmFallback: 'AppData/Roaming/npm/node_modules/@anthropic-ai/claude-code/bin/claude.exe',
  }),
  codex: Object.freeze({
    name: 'codex',
    displayName: 'OpenAI Codex',
    supportLevel: 'experimental',
    supportsStructuredEvents: true,
    supportsApprovalHook: true,
    eventAdapter: 'codex',
    sessionLayout: 'global-nested',
    binaryName: 'codex',
    binaryNameWin: 'codex.exe',
    envVar: 'CODEX_EXE',
    sessionDirBase: '.codex/sessions',
    npmPath: 'AppData/Roaming/npm/codex.cmd',
    npmFallback: '',
  }),
});

export const AGENT_TYPES = Object.freeze(Object.keys(REGISTRY));

export function normalizeAgentType(value = 'claude') {
  const normalized = String(value || 'claude').trim().toLowerCase();
  if (!Object.hasOwn(REGISTRY, normalized)) {
    throw new RangeError(`Unsupported SEREIN_AGENT_TYPE: ${normalized || '(empty)'}. Expected one of: ${AGENT_TYPES.join(', ')}`);
  }
  return normalized;
}

export function getAgentConfig(value = 'claude') {
  return REGISTRY[normalizeAgentType(value)];
}
