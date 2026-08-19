/**
 * Remove terminal control sequences before matching first-run trust prompts.
 * Keep this deliberately small and deterministic: it is used only to decide
 * whether Serein may press Enter on an Agent's explicit "trust this folder"
 * screen.
 */
export function stripTerminalControl(value = '') {
  return String(value)
    .replace(/\x1b\[[0-9;?]*[a-zA-Z]/g, '')
    .replace(/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g, '')
    .replace(/\x1b[()*+][AB012]/g, '')
    .replace(/\x1b[78=>HM78]/g, '')
    .replace(/[\x00-\x08\x0e-\x1f]/g, '');
}

/**
 * 压缩空白字符用于模式匹配。
 * node-pty + Windows ConPTY 在渲染 TUI 时，ANSI 序列会吞掉单词间的空格，
 * stripTerminalControl 后文本变成 "Isthisaproject..." 的形式。
 * 因此匹配前统一移除所有空白，用无空格模式对比。
 */
function normalizeSpace(text) {
  return text.replace(/\s+/g, '');
}

/**
 * Match only the known first-run directory trust screens. A generic "trust"
 * match is intentionally avoided so unrelated warnings are never confirmed.
 */
export function isAgentTrustPrompt(agentType, output) {
  const plain = stripTerminalControl(output);
  const ns = normalizeSpace(plain);
  if (agentType === 'codex') {
    return /Doyoutrustthecontentsofthisdirectory\?/i.test(ns)
      && /Yes,\s*continue/i.test(plain)
      && /No,\s*quit/i.test(plain);
  }
  if (agentType === 'claude') {
    // 旧版匹配：移除空格后对比
    //   "Do you trust the files in this folder?"
    //   "Do you trust the contents of this folder/directory?"
    if (/Doyoutrust(?:thefilesinthisfolder|thecontentsofthis(?:folder|directory))\?/i.test(ns)) {
      return true;
    }
    // 新版 v2.1.219+：移除空格后对比
    //   "Is this a project you created or one you trust?"
    //   "Yes, I trust this folder"
    return /Isthisaprojectyoucreatedoroneyoutrust\?/i.test(ns)
      && /Yes,?\s*(?:Itrustthisfolder|continue|trust)/i.test(ns);
  }
  return false;
}
