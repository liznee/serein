/** Codex Desktop/App Server 会话状态。协议细节不向用户展示。 */

export const KEY_CODEX_DESKTOP_EVENT_TYPE: string = 'codexDesktopEventType'
export const KEY_CODEX_DESKTOP_EVENT: string = 'codexDesktopEvent'
export const KEY_CODEX_DESKTOP_ERROR: string = 'codexDesktopError'
export const KEY_CODEX_DESKTOP_PROJECT: string = 'codexDesktopProject'
export const KEY_CODEX_DESKTOP_THREADS: string = 'codexDesktopThreads'
export const KEY_CODEX_DESKTOP_LOADING: string = 'codexDesktopLoading'
export const KEY_CODEX_DESKTOP_ACTIVE: string = 'codexDesktopActive'
export const KEY_CODEX_DESKTOP_APPROVAL: string = 'codexDesktopApproval'

export interface CodexDesktopThread {
  id: string
  title: string
  cwd: string
  source: string
  status: string
  updatedAt: number
  path: string
  turns: number
}

export interface CodexDesktopLease {
  threadId: string
  threadTitle: string
  leaseId: string
  expiresAt: number
  turnId: string
}

export interface CodexDesktopEvent {
  ok: boolean
  action: string
  cwd: string
  nextCursor: string
  threads: CodexDesktopThread[]
  thread?: CodexDesktopThread
  error: string
}

function parseObject(content: string): Record<string, Object> | undefined {
  try {
    return JSON.parse(content) as Record<string, Object>
  } catch (_) {
    return undefined
  }
}

function parseThreads(raw: Object | undefined): CodexDesktopThread[] {
  if (!raw || !Array.isArray(raw)) return []
  const values = raw as Object[]
  const result: CodexDesktopThread[] = []
  for (let i = 0; i < values.length; i++) {
    const item = values[i] as Record<string, Object>
    result.push({
      id: (item['id'] as string) ?? '',
      title: (item['title'] as string) ?? '',
      cwd: (item['cwd'] as string) ?? '',
      source: (item['source'] as string) ?? '',
      status: typeof item['status'] === 'string' ? item['status'] as string : '',
      updatedAt: (item['updatedAt'] as number) ?? 0,
      path: (item['path'] as string) ?? '',
      turns: (item['turns'] as number) ?? 0,
    })
  }
  return result
}

export function loadCodexDesktopThreads(): CodexDesktopThread[] {
  return AppStorage.get<CodexDesktopThread[]>(KEY_CODEX_DESKTOP_THREADS) ?? []
}

export function loadCodexDesktopLease(): CodexDesktopLease | null {
  return AppStorage.get<CodexDesktopLease>(KEY_CODEX_DESKTOP_ACTIVE) ?? null
}

export function desktopThreadCommand(action: string, threadId: string, leaseId: string = '', value: string = ''): string {
  const parts: string[] = ['/desktop', action, threadId]
  if (leaseId !== '') parts.push(leaseId)
  if (value !== '') parts.push(value)
  return parts.join(' ')
}

export function saveCodexDesktopEvent(project: string, eventType: string, content: string): void {
  AppStorage.setOrCreate(KEY_CODEX_DESKTOP_PROJECT, project)
  AppStorage.setOrCreate(KEY_CODEX_DESKTOP_EVENT_TYPE, eventType)
  AppStorage.setOrCreate(KEY_CODEX_DESKTOP_EVENT, content)
  let error = ''
  if (eventType === 'desktop_error') {
    try {
      const raw = JSON.parse(content) as Record<string, Object>
      error = (raw['error'] as string) ?? 'Codex Desktop 会话读取失败'
    } catch (_) {
      error = content
    }
  }
  AppStorage.setOrCreate(KEY_CODEX_DESKTOP_ERROR, error)
  if (eventType === 'desktop_thread_list' || eventType === 'desktop_error' ||
      eventType === 'desktop_thread_taken') {
    AppStorage.setOrCreate(KEY_CODEX_DESKTOP_LOADING, false)
  }
  if (eventType === 'desktop_error' &&
      (error.indexOf('连接已过期') >= 0 || error.indexOf('重新打开') >= 0)) {
    AppStorage.setOrCreate(KEY_CODEX_DESKTOP_ACTIVE, null)
    AppStorage.setOrCreate(KEY_CODEX_DESKTOP_APPROVAL, '')
    AppStorage.setOrCreate('openCodexDesktopPanel', true)
  }
  const raw = parseObject(content)
  if (!raw) return
  if (eventType === 'desktop_thread_list') {
    AppStorage.setOrCreate(KEY_CODEX_DESKTOP_THREADS, parseThreads(raw['threads']))
  } else if (eventType === 'desktop_thread_taken') {
    const thread = raw['thread'] as Record<string, Object> | undefined
    const lease: CodexDesktopLease = {
      threadId: (thread?.['id'] as string) ?? (raw['threadId'] as string) ?? '',
      threadTitle: (thread?.['title'] as string) ?? '桌面会话',
      leaseId: (raw['leaseId'] as string) ?? '',
      expiresAt: (raw['expiresAt'] as number) ?? 0,
      turnId: '',
    }
    AppStorage.setOrCreate(KEY_CODEX_DESKTOP_ACTIVE, lease)
    AppStorage.setOrCreate(KEY_CODEX_DESKTOP_APPROVAL, '')
    AppStorage.setOrCreate('openCodexDesktopPanel', false)
  } else if (eventType === 'desktop_turn_started') {
    const current = loadCodexDesktopLease()
    if (current) {
      const turn = raw['turn'] as Record<string, Object> | undefined
      const nestedTurn = turn?.['turn'] as Record<string, Object> | undefined
      const turnId = (turn?.['id'] as string) ?? (turn?.['turnId'] as string) ??
        (nestedTurn?.['id'] as string) ?? ''
      AppStorage.setOrCreate(KEY_CODEX_DESKTOP_ACTIVE, {
        threadId: current.threadId, threadTitle: current.threadTitle,
        leaseId: current.leaseId, expiresAt: current.expiresAt, turnId: turnId,
      } as CodexDesktopLease)
    }
  } else if (eventType === 'desktop_lease_renewed') {
    const current = loadCodexDesktopLease()
    if (current && raw['granted'] === true) {
      AppStorage.setOrCreate(KEY_CODEX_DESKTOP_ACTIVE, {
        threadId: current.threadId, threadTitle: current.threadTitle,
        leaseId: current.leaseId,
        expiresAt: (raw['expiresAt'] as number) ?? current.expiresAt,
        turnId: current.turnId,
      } as CodexDesktopLease)
    }
  } else if (eventType === 'desktop_lease_released') {
    AppStorage.setOrCreate(KEY_CODEX_DESKTOP_ACTIVE, null)
    AppStorage.setOrCreate(KEY_CODEX_DESKTOP_APPROVAL, '')
    AppStorage.setOrCreate('openCodexDesktopPanel', true)
  } else if (eventType === 'desktop_approval_required') {
    AppStorage.setOrCreate(KEY_CODEX_DESKTOP_APPROVAL, content)
  } else if (eventType === 'desktop_approval_resolved') {
    AppStorage.setOrCreate(KEY_CODEX_DESKTOP_APPROVAL, '')
  } else if (eventType === 'desktop_notification') {
    const current = loadCodexDesktopLease()
    if (current) {
      const method = (raw['method'] as string) ?? ''
      const params = raw['params'] as Record<string, Object> | undefined
      if (method === 'turn/started') {
        const turn = params?.['turn'] as Record<string, Object> | undefined
        AppStorage.setOrCreate(KEY_CODEX_DESKTOP_ACTIVE, {
          threadId: current.threadId, threadTitle: current.threadTitle,
          leaseId: current.leaseId, expiresAt: current.expiresAt,
          turnId: (turn?.['id'] as string) ?? (params?.['turnId'] as string) ?? current.turnId,
        } as CodexDesktopLease)
      } else if (method === 'turn/completed') {
        AppStorage.setOrCreate(KEY_CODEX_DESKTOP_APPROVAL, '')
        AppStorage.setOrCreate(KEY_CODEX_DESKTOP_ACTIVE, {
          threadId: current.threadId, threadTitle: current.threadTitle,
          leaseId: current.leaseId, expiresAt: current.expiresAt, turnId: '',
        } as CodexDesktopLease)
      }
    }
  }
}

export function clearCodexDesktopEvent(): void {
  AppStorage.setOrCreate(KEY_CODEX_DESKTOP_EVENT_TYPE, '')
  AppStorage.setOrCreate(KEY_CODEX_DESKTOP_EVENT, '')
  AppStorage.setOrCreate(KEY_CODEX_DESKTOP_ERROR, '')
  AppStorage.setOrCreate(KEY_CODEX_DESKTOP_THREADS, [])
  AppStorage.setOrCreate(KEY_CODEX_DESKTOP_LOADING, false)
  AppStorage.setOrCreate(KEY_CODEX_DESKTOP_ACTIVE, null)
  AppStorage.setOrCreate(KEY_CODEX_DESKTOP_APPROVAL, '')
}
