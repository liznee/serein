// ===== 命令关键词高亮 — 暗色背景高对比度版 =====
// 红=danger / 绿=safe / 蓝=tool / 黄=operator+path / 亮灰=default

const dangerWords = [
  'rm', 'rmdir', 'del', 'chmod', 'chown', 'mkfs', 'dd', 'shutdown', 'reboot',
  'poweroff', 'halt', 'format', 'drop', 'truncate', 'fuser', 'kill', 'taskkill',
  'sudo', 'su', 'passwd', 'useradd', 'usermod', 'userdel', 'groupadd', 'iptables',
  'crontab', 'systemctl', 'mount', 'umount', 'mkfs.ext4', 'mkfs.ntfs', 'fdisk',
  'taskkill', 'Stop-Process', 'os.remove', 'os.kill', 'signal', 'subprocess.run',
  'shell=True', '--force', '-f', '-rf'
]
const safeWords = [
  'echo', 'ls', 'pwd', 'cat', 'date', 'whoami', 'true', 'false', 'uname', 'env',
  'git', 'go', 'npm', 'node', 'py', 'python3', 'python', 'java', 'cargo', 'rustc',
  'curl', 'grep', 'find', 'head', 'tail', 'sort', 'wc', 'which', 'where', 'diff',
  'read', 'glob', 'tasklist', 'taskget', 'list', 'history', 'status', 'health',
  'version', 'help', 'info', 'describe', 'check', 'show', 'display', 'print',
  'agent', 'skill', 'websearch', 'cronlist', 'taskoutput',
  'cp', 'mv', 'touch', 'mkdir', 'mktemp', 'basename', 'dirname', 'realpath'
]
const toolWords = [
  'scp', 'ssh', 'wget', 'hdc', 'export', 'set', 'path', 'cd', 'source', 'unset',
  'install', 'build', 'test', 'run', 'start', 'deploy', 'restart', 'stop', 'reload',
  'enable', 'disable', 'init', 'compile', 'make', 'cmake', 'configure',
  'write', 'edit', 'bash', 'notebookedit', 'taskcreate', 'taskupdate',
  'webfetch', 'plan', 'enterplanmode', 'exitplanmode', 'askuserquestion',
  'croncreate', 'crondelete', 'schedulewakeup', 'resume', 'save',
  'open', 'close', 'connect', 'disconnect', 'push', 'pull', 'fetch', 'merge',
  'commit', 'clone', 'checkout', 'branch', 'log', 'reset', 'rebase', 'stash',
  'add', 'remove', 'update', 'upgrade', 'new', 'create', 'delete', 'modify',
  'parcel', 'select', 'insert', 'replace', 'upsert', 'join',
  'curl.exe', 'npx', 'nohup', '&&', '||', '>>', '<<', '2>&1', '2>/dev/null'
]

export function tokenizeCommand(cmd: string): Array<[string, string]> {
  const result: Array<[string, string]> = []
  const parts = cmd.split(/([^A-Za-z0-9_.:;/\\-]+)/)
  for (let pi = 0; pi < parts.length; pi++) {
    const token = parts[pi]
    if (token === '') continue

    // 操作符
    if (token === '&&' || token === '||' || token === '>>' || token === '<<' ||
        token === '2>&1' || token === '2>/dev/null' || token === '|' ||
        token === ';' || token === '>' || token === '<') {
      result.push([token, '#d97730'])
      continue
    }

    const lower = token.toLowerCase()
    let colored = false
    // 红
    for (let di = 0; di < dangerWords.length; di++) {
      if (lower === dangerWords[di]) { result.push([token, '#b53333']); colored = true; break }
    }
    if (colored) continue
    // 蓝 — tool (check before safe to catch conflicts)
    for (let ti = 0; ti < toolWords.length; ti++) {
      if (lower === toolWords[ti]) { result.push([token, '#D97757']); colored = true; break }
    }
    if (colored) continue
    // 绿
    for (let si = 0; si < safeWords.length; si++) {
      if (lower === safeWords[si]) { result.push([token, '#17a34a']); colored = true; break }
    }
    if (colored) continue
    // 黄 — path/URL
    if (token[0] === '/' || token[0] === '\\' || token.indexOf('://') >= 0 ||
        token.indexOf(':') >= 2 || token.indexOf('.') >= 0 && token.indexOf('/') >= 0) {
      result.push([token, '#d97730']); continue
    }
    // 亮灰
    result.push([token, '#CBD5E1'])
  }
  return result
}
