﻿﻿﻿﻿/**
 * TerminalCmdDispatcher — 命令分派逻辑
 *
 * 从 TerminalPage.TerminalContent 提取，减少主文件代码行数。
 * 负责命令解析、发送、远程历史、输出复制等非 UI 逻辑。
 */
import { http } from '@kit.NetworkKit'
import { router, promptAction } from '@kit.ArkUI'
import { pasteboard } from '@kit.BasicServicesKit'
import { TerminalSession, type TerminalLineData } from './TerminalSession'
import { WebSocketClient } from '../api/WebSocketClient'
import { TerminalCmdPoller } from './TerminalCmdPoller'
import { handleAuthError, KEY_CLIENT_TOKEN } from '../state/AppStore'
import NavPath from '../model/NavPath'
import { fetchDeployCommand } from './DeployConfig'
import PrefStore, { type Snippet } from '../store/PrefStore'
import { SLASH_COMMANDS, SLASH_HINT_MAX, type SlashCommandInfo } from './SlashCommands'
import { currentTheme } from './TerminalTheme'

/** AI Commit 响应类型 */
export interface AiCommitResult {
  success: boolean
  message?: string
  error?: string
}

/** 解析命令返回类型 */
export interface ResolvedActionInfo {
  action: string
  command: string
}

interface PendingChatMessage {
  content: string
  project: string
}

/** 命令分派回调接口 — TerminalContent 通过此接口暴露状态和 UI 方法 */
export interface CmdDispatchCallbacks {
  setInputText(v: string): void
  setSlashHints(v: SlashCommandInfo[]): void
  setSlashHintOverflow(v: boolean): void
  setShowHistory(v: boolean): void
  setShowSnippets(v: boolean): void
  setSearchTerm(v: string): void
  setRenderLines(v: TerminalLineData[]): void
  setHistoryList(v: string[]): void
  setRemoteHistoryList(v: string[]): void
  setRemoteHistoryLoading(v: boolean): void
  setRemoteHistoryError(v: string): void
  setExecuting(v: boolean): void
  setUserScrolledUp(v: boolean): void
  setSnippets(v: Snippet[]): void
  getInputText(): string
  getShowHistory(): boolean
  getLines(): TerminalLineData[]
  getRenderLines(): TerminalLineData[]
  syncLines(): void
  scrollToBottom(): void
  computeRender(): void
  cycleTheme(): void
  adjustFont(delta: number): void
  submitCommand(t: string): void
  saveHistory(): Promise<void>
  clearChatTimeout(): void
}

/** ArkTS 严格模式兼容：具体类实现回调接口 */
export class CmdDispatchBinding implements CmdDispatchCallbacks {
  private _setInputText: (v: string) => void = () => {}
  private _setSlashHints: (v: SlashCommandInfo[]) => void = (_v: SlashCommandInfo[]) => {}
  private _setSlashHintOverflow: (v: boolean) => void = () => {}
  private _setShowHistory: (v: boolean) => void = () => {}
  private _setShowSnippets: (v: boolean) => void = () => {}
  private _setSearchTerm: (v: string) => void = () => {}
  private _setRenderLines: (v: TerminalLineData[]) => void = (_v: TerminalLineData[]) => {}
  private _setHistoryList: (v: string[]) => void = (_v: string[]) => {}
  private _setRemoteHistoryList: (v: string[]) => void = (_v: string[]) => {}
  private _setRemoteHistoryLoading: (v: boolean) => void = () => {}
  private _setRemoteHistoryError: (v: string) => void = () => {}
  private _setExecuting: (v: boolean) => void = () => {}
  private _setUserScrolledUp: (v: boolean) => void = () => {}
  private _setSnippets: (v: Snippet[]) => void = (_v: Snippet[]) => {}
  private _getInputText: () => string = () => ''
  private _getShowHistory: () => boolean = () => false
  private _getLines: () => TerminalLineData[] = () => []
  private _getRenderLines: () => TerminalLineData[] = () => []
  private _syncLines: () => void = () => {}
  private _scrollToBottom: () => void = () => {}
  private _computeRender: () => void = () => {}
  private _cycleTheme: () => void = () => {}
  private _adjustFont: (delta: number) => void = (_d: number) => {}
  private _submitCommand: (t: string) => void = (_t: string) => {}
  private _saveHistory: () => Promise<void> = async () => {}
  private _clearChatTimeout: () => void = () => {}

  constructor(
    setInputText: (v: string) => void,
    setSlashHints: (v: SlashCommandInfo[]) => void,
    setSlashHintOverflow: (v: boolean) => void,
    setShowHistory: (v: boolean) => void,
    setShowSnippets: (v: boolean) => void,
    setSearchTerm: (v: string) => void,
    setRenderLines: (v: TerminalLineData[]) => void,
    setHistoryList: (v: string[]) => void,
    setRemoteHistoryList: (v: string[]) => void,
    setRemoteHistoryLoading: (v: boolean) => void,
    setRemoteHistoryError: (v: string) => void,
    setExecuting: (v: boolean) => void,
    setUserScrolledUp: (v: boolean) => void,
    setSnippets: (v: Snippet[]) => void,
    getInputText: () => string,
    getShowHistory: () => boolean,
    getLines: () => TerminalLineData[],
    getRenderLines: () => TerminalLineData[],
    syncLines: () => void,
    scrollToBottom: () => void,
    computeRender: () => void,
    cycleTheme: () => void,
    adjustFont: (delta: number) => void,
    submitCommand: (t: string) => void,
    saveHistory: () => Promise<void>,
    clearChatTimeout: () => void,
  ) {
    this._setInputText = setInputText
    this._setSlashHints = setSlashHints
    this._setSlashHintOverflow = setSlashHintOverflow
    this._setShowHistory = setShowHistory
    this._setShowSnippets = setShowSnippets
    this._setSearchTerm = setSearchTerm
    this._setRenderLines = setRenderLines
    this._setHistoryList = setHistoryList
    this._setRemoteHistoryList = setRemoteHistoryList
    this._setRemoteHistoryLoading = setRemoteHistoryLoading
    this._setRemoteHistoryError = setRemoteHistoryError
    this._setExecuting = setExecuting
    this._setUserScrolledUp = setUserScrolledUp
    this._setSnippets = setSnippets
    this._getInputText = getInputText
    this._getShowHistory = getShowHistory
    this._getLines = getLines
    this._getRenderLines = getRenderLines
    this._syncLines = syncLines
    this._scrollToBottom = scrollToBottom
    this._computeRender = computeRender
    this._cycleTheme = cycleTheme
    this._adjustFont = adjustFont
    this._submitCommand = submitCommand
    this._saveHistory = saveHistory
    this._clearChatTimeout = clearChatTimeout
  }

  setInputText(v: string): void { this._setInputText(v) }
  setSlashHints(v: SlashCommandInfo[]): void { this._setSlashHints(v) }
  setSlashHintOverflow(v: boolean): void { this._setSlashHintOverflow(v) }
  setShowHistory(v: boolean): void { this._setShowHistory(v) }
  setShowSnippets(v: boolean): void { this._setShowSnippets(v) }
  setSearchTerm(v: string): void { this._setSearchTerm(v) }
  setRenderLines(v: TerminalLineData[]): void { this._setRenderLines(v) }
  setHistoryList(v: string[]): void { this._setHistoryList(v) }
  setRemoteHistoryList(v: string[]): void { this._setRemoteHistoryList(v) }
  setRemoteHistoryLoading(v: boolean): void { this._setRemoteHistoryLoading(v) }
  setRemoteHistoryError(v: string): void { this._setRemoteHistoryError(v) }
  setExecuting(v: boolean): void { this._setExecuting(v) }
  setUserScrolledUp(v: boolean): void { this._setUserScrolledUp(v) }
  setSnippets(v: Snippet[]): void { this._setSnippets(v) }
  getInputText(): string { return this._getInputText() }
  getShowHistory(): boolean { return this._getShowHistory() }
  getLines(): TerminalLineData[] { return this._getLines() }
  getRenderLines(): TerminalLineData[] { return this._getRenderLines() }
  syncLines(): void { this._syncLines() }
  scrollToBottom(): void { this._scrollToBottom() }
  computeRender(): void { this._computeRender() }
  cycleTheme(): void { this._cycleTheme() }
  adjustFont(delta: number): void { this._adjustFont(delta) }
  submitCommand(t: string): void { this._submitCommand(t) }
  saveHistory(): Promise<void> { return this._saveHistory() }
  clearChatTimeout(): void { this._clearChatTimeout() }
}

export class TerminalCmdDispatcher {
  private session: TerminalSession
  private wsClient: WebSocketClient
  private cmdPoller: TerminalCmdPoller
  private backendUrl: string
  private backendIsHttp: boolean = false  // HTTP 模式拒绝带 token 请求
  private terminalProject: string
  private cb: CmdDispatchCallbacks
  private chatTimeoutId: number = 0
  // WS 断连时的待发送消息队列
  private _pendingChatMsgs: PendingChatMessage[] = []
  private _pendingChatTimer: number = 0
  private _pendingFlushTimer: number = 0
  private static readonly MAX_PENDING_CHAT: number = 10

  constructor(
    session: TerminalSession,
    wsClient: WebSocketClient,
    cmdPoller: TerminalCmdPoller,
    backendUrl: string,
    terminalProject: string,
    cb: CmdDispatchCallbacks,
  ) {
    this.session = session
    this.wsClient = wsClient
    this.cmdPoller = cmdPoller
    this.backendUrl = backendUrl
    this.terminalProject = terminalProject
    this.cb = cb
  }

  setSession(s: TerminalSession): void { this.session = s }
  setBackendUrl(url: string): void { this.backendUrl = url }
  setBackendIsHttp(v: boolean): void { this.backendIsHttp = v }
  setCmdPoller(cp: TerminalCmdPoller): void { this.cmdPoller = cp }
  setTerminalProject(proj: string): void { this.terminalProject = proj }
  clearChatTimeout(): void {
    if (this.chatTimeoutId !== 0) {
      clearTimeout(this.chatTimeoutId)
      this.chatTimeoutId = 0
    }
  }

  dispose(): void {
    this.clearChatTimeout()
    if (this._pendingChatTimer) { clearTimeout(this._pendingChatTimer); this._pendingChatTimer = 0 }
    if (this._pendingFlushTimer) { clearTimeout(this._pendingFlushTimer); this._pendingFlushTimer = 0 }
    this._pendingChatMsgs = []
  }

  /** 处理客户端本地命令，返回 true 表示已处理无需继续 */
  handleClientCommand(t: string): boolean {
    if (t === 'clear' || t === 'cls') {
      this.session.clear(); this.cb.setInputText('')
      this.cb.setSlashHints([]); this.cb.setSlashHintOverflow(false); this.cb.setShowHistory(false); this.cb.setShowSnippets(false)
      this.cb.syncLines()
      return true
    }
    if (t === '/help') {
      this.printHelp(); this.cb.setInputText(''); this.cb.setSlashHints([]); this.cb.setSlashHintOverflow(false); return true
    }
    if (t === '/snippets') {
      this.loadSnippets(); this.cb.setInputText(''); this.cb.setSlashHints([]); return true
    }
    if (t === '/history') {
      this.cb.setInputText(''); this.cb.setSlashHints([]); this.openHistory(); return true
    }
    if (t === '/theme') {
      this.cb.setInputText(''); this.cb.setSlashHints([]); this.cb.cycleTheme(); return true
    }
    if (t === '/font' || t === '/font +') {
      this.cb.setInputText(''); this.cb.setSlashHints([]); this.cb.adjustFont(1); return true
    }
    if (t === '/font -') {
      this.cb.setInputText(''); this.cb.setSlashHints([]); this.cb.adjustFont(-1); return true
    }
    if (t.startsWith('/search')) {
      const kw = t.substring(7).trim()
      this.cb.setSearchTerm(kw)
      this.cb.setInputText(''); this.cb.setSlashHints([]); this.cb.setSlashHintOverflow(false)
      this.cb.computeRender()
      const rl = this.cb.getRenderLines()
      this.session.appendSystem(kw === '' ? '已清除搜索' : '搜索: ' + kw + ' (' + rl.length + ' 行)', currentTheme().hint)
      this.cb.syncLines(); this.cb.scrollToBottom()
      return true
    }
    return false
  }

  /** /resume → resume；/!cmd → exec shell；/diff /undo → exec git；其它 /xxx → claude -p；否则 chat */
  private async resolveActionAndCommand(t: string): Promise<ResolvedActionInfo> {
    if (t === '/resume' || t === '/resume-session') {
      return { action: 'resume', command: '' }
    }
    if (t === '/diff') {
      return { action: 'exec', command: 'git --no-pager diff' }
    }
    if (t === '/undo') {
      return { action: 'exec', command: 'git reset --hard HEAD~1' }
    }
    if (t === '/release-backend') {
      const cmd = await fetchDeployCommand(this.backendUrl, 'backend')
      if (cmd === null) {
        this.session.appendSystem('获取部署命令失败，请检查后端地址', '#b53333')
        return { action: 'exec', command: 'echo "deploy command fetch failed"' }
      }
      return { action: 'exec', command: cmd }
    }
    if (t === '/release-app') {
      const cmd = await fetchDeployCommand(this.backendUrl, 'app')
      if (cmd === null) {
        this.session.appendSystem('获取部署命令失败，请检查后端地址', '#b53333')
        return { action: 'exec', command: 'echo "deploy command fetch failed"' }
      }
      return { action: 'exec', command: cmd }
    }
    if (t === '/release') {
      const cmd = await fetchDeployCommand(this.backendUrl, 'full')
      if (cmd === null) {
        this.session.appendSystem('获取部署命令失败，请检查后端地址', '#b53333')
        return { action: 'exec', command: 'echo "deploy command fetch failed"' }
      }
      return { action: 'exec', command: cmd }
    }
    if (t.startsWith('/!')) {
      return { action: 'exec', command: t.substring(2).trimStart() }
    }
    return { action: 'chat', command: t }
  }

  /**
   * /nl 自然语言转命令：将用户自然语言描述包装为 prompt，
   * 通过 WS session_msg 发给 relay claude，由 claude 输出具体命令序列。
   */
  handleNLCommand(nlText: string): void {
    const prompt = '用户输入了以下自然语言描述：\n\n```\n' + nlText + '\n```\n\n' +
      '请分析该任务，输出具体的命令行命令序列来完成。每行一条命令，按执行顺序排列。\n' +
      '如果是 Claude Code 斜杠命令（如 /code-review），请直接输出。\n' +
      '如果是 shell 命令，以 /! 前缀开头（如 /!git pull origin main）。\n' +
      '先简要分析任务需求（1-2句话），然后逐条列出命令。'
    this.sendChatViaWS(prompt)
  }

  /**
   * /batch 批量多项目执行：向 /agent/batch-cmd 提交批处理命令，
   * 返回后轮询各项目的执行结果。
   */
  async sendBatchCommand(projects: string[], command: string): Promise<void> {
    // HTTP 模式下拒绝发送 token 请求
    if (this.backendIsHttp) {
      this.session.appendSystem('[安全] HTTP 模式下不允许批量命令，请在设置中配置 HTTPS 后端地址', '#b53333')
      this.cb.setExecuting(false)
      this.cb.syncLines()
      return
    }
    const token = AppStorage.get<string>(KEY_CLIENT_TOKEN) ?? ''
    const hc = http.createHttp()
    try {
      const hdr: Record<string, string> = { 'Content-Type': 'application/json' }
      if (token !== '') {
        hdr['Authorization'] = 'Bearer ' + token
      }
      const r = await hc.request(this.backendUrl + '/agent/batch-cmd', {
        method: http.RequestMethod.POST,
        header: hdr,
        extraData: JSON.stringify({ projects: projects, command: command }),
        connectTimeout: 5000,
        readTimeout: 15000
      })
      if (r.responseCode === 401) {
        handleAuthError()
        this.cb.setExecuting(false)
        router.replaceUrl({ url: NavPath.PAIR })
        return
      }
      const d = JSON.parse(r.result as string) as Record<string, Object>
      if (d['ok'] === true) {
        const items = d['items'] as Record<string, Object>[]
        this.session.appendSystem('[Batch] 已提交 ' + items.length + ' 个项目', currentTheme().tool)
        for (let i = 0; i < items.length; i++) {
          const item = items[i] as Record<string, Object>
          const proj = item['project'] as string
          const cmdId = item['cmd_id'] as string
          this.session.appendSystem('  ' + proj + ' → cmd: ' + cmdId.substring(0, 8) + '…', '#A1A1AA')
        }
        this.cb.syncLines()
        this.cb.scrollToBottom()
        // 开始轮询各 cmd 结果。return 确保 Promise 直到轮询全部完成才 resolve，
        // 防止 .then() 在轮询开始前就将 batchMode 设为 false。
        return this.pollBatchResults(items as Record<string, Object>[], token)
      } else {
        this.session.appendError('[Batch] ' + ((d['error'] as string) ?? 'Unknown'))
        this.cb.setExecuting(false)
        this.cb.syncLines()
      }
    } catch (e) {
      this.session.appendError('[Batch] ' + ((e as Error).message ?? 'Network'))
      this.cb.setExecuting(false)
      this.cb.syncLines()
    } finally {
      hc.destroy()
    }
  }

  /** 轮询批量命令的执行结果，最多 30 秒 */
  private async pollBatchResults(items: Record<string, Object>[], token: string): Promise<void> {
    // 改用数组替代 Map（ArkTS strict mode 兼容）
    const pendingProjects: string[] = []
    const pendingCmdIds: string[] = []
    for (let i = 0; i < items.length; i++) {
      pendingCmdIds.push(items[i]['cmd_id'] as string)
      pendingProjects.push(items[i]['project'] as string)
    }
    const maxAttempts = 15  // 每 2 秒轮询，最多 30 秒
    for (let attempt = 0; attempt < maxAttempts && pendingCmdIds.length > 0; attempt++) {
      await this.sleep(2000)
      const hc = http.createHttp()
      try {
        const hdr: Record<string, string> = { 'Content-Type': 'application/json' }
        if (token !== '') hdr['Authorization'] = 'Bearer ' + token
        const r = await hc.request(this.backendUrl + '/agent/history', {
          method: http.RequestMethod.GET,
          header: hdr,
          connectTimeout: 5000,
          readTimeout: 8000
        })
        if (r.responseCode === 200) {
          const results = JSON.parse(r.result as string) as Record<string, Object>[]
          // 标记已找到的索引（从后向前遍历避免索引偏移）
          const resolvedIdx: number[] = []
          for (let pi = 0; pi < pendingCmdIds.length; pi++) {
            for (let rj = 0; rj < results.length; rj++) {
              if (results[rj]['cmd_id'] as string === pendingCmdIds[pi]) {
                const proj = pendingProjects[pi]
                const success = results[rj]['success'] === true
                const outVal = results[rj]['output'] as Record<string, Object> | undefined
                let preview = ''
                if (outVal) {
                  const stdout = outVal['stdout'] as string | undefined
                  if (stdout && stdout.length > 0) {
                    preview = stdout.substring(0, 100).replace(/\n/g, ' ').trim()
                  }
                  const stderr = outVal['stderr'] as string | undefined
                  if (preview === '' && stderr && stderr.length > 0) {
                    preview = 'stderr: ' + stderr.substring(0, 80).replace(/\n/g, ' ').trim()
                  }
                }
                const color = success ? currentTheme().success : '#EF4444'
                const status = success ? 'OK' : 'FAIL'
                this.session.appendSystem('  [' + status + '] ' + proj + ': ' + (preview !== '' ? preview : '(无输出)'), color)
                resolvedIdx.push(pi)
                break
              }
            }
          }
          // 从后向前移除已解决项
          for (let ri = resolvedIdx.length - 1; ri >= 0; ri--) {
            pendingCmdIds.splice(resolvedIdx[ri], 1)
            pendingProjects.splice(resolvedIdx[ri], 1)
          }
        }
      } catch (_e) {
        // 单次轮询失败，下次继续
      } finally {
        hc.destroy()
      }
    }
    if (pendingCmdIds.length > 0) {
      this.session.appendSystem('[Batch] 还有 ' + pendingCmdIds.length + ' 个结果未返回（超时）', '#b53333')
    }
    this.session.appendSystem('[Batch] 批量执行完成', '#A1A1AA')
    this.cb.setExecuting(false)
    this.cb.syncLines()
    this.cb.scrollToBottom()
  }

  /** 异步等待指定毫秒 */
  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms)
    })
  }

  /**
   * chat 走 HTTP fallback 通道（WS 断连时使用）。
   * 通过 /agent/cmd?async=true 发送 action=chat，后端入队 CmdQueue，
   * relay 通过 WS 或轮询获取并注入 PTY。
   */
  async sendChatViaHTTPFallback(command: string): Promise<boolean> {
    if (this.backendIsHttp) {
      this.session.appendSystem('[安全] HTTP 模式下不允许发送命令', '#b53333')
      this.cb.setExecuting(false)
      this.cb.syncLines()
      return false
    }
    const token = AppStorage.get<string>(KEY_CLIENT_TOKEN) ?? ''
    const hc = http.createHttp()
    try {
      const hdr: Record<string, string> = { 'Content-Type': 'application/json' }
      if (token !== '') hdr['Authorization'] = 'Bearer ' + token
      console.info('[serein] HTTP fallback: sending chat via /agent/cmd?async=true')
      const r = await hc.request(this.backendUrl + '/agent/cmd?async=true', {
        method: http.RequestMethod.POST,
        header: hdr,
        extraData: JSON.stringify({ action: 'chat', project: this.terminalProject, command: command }),
        connectTimeout: 5000,
        readTimeout: 10000,
      })
      if (r.responseCode === 200) {
        const d = JSON.parse(r.result as string) as Record<string, Object>
        if (d['ok'] === true) {
          console.info('[serein] HTTP fallback: chat sent OK')
          // 启动轮询获取结果
          const cmdId = (d['cmd_id'] as string) ?? ''
          if (cmdId !== '') {
            this.cmdPoller.resetForNewCmd()
            this.cmdPoller.setActiveCmdId(cmdId)
            this.cmdPoller.pollCmdResult(token)
          }
          // 设置超时定时器（与 WS 路径一致）
          this.clearChatTimeout()
          this.chatTimeoutId = setTimeout(() => {
            this.cb.setExecuting(false)
            this.session.appendSystem('[响应超时，请重试]', '#EF4444')
            this.cb.syncLines()
            this.cb.scrollToBottom()
            this.chatTimeoutId = 0
          }, 60000)
          return true
        }
      }
      console.error('[serein] HTTP fallback failed: ' + r.responseCode + ' body=' + (r.result as string ?? ''))
      this.cb.setExecuting(false)
      this.session.appendError('[发送失败] HTTP ' + r.responseCode + ': ' + (r.result as string ?? ''))
      this.cb.syncLines()
      return false
    } catch (e) {
      console.error('[serein] HTTP fallback error: ' + ((e as Error).message ?? ''))
      this.cb.setExecuting(false)
      this.session.appendError('[发送失败] ' + ((e as Error).message ?? '网络错误'))
      this.cb.syncLines()
      return false
    } finally {
      hc.destroy()
    }
  }

  /** chat 走 WS 双向实时通道（WS 断连时排队等重连，不走 HTTP fallback） */
  sendChatViaWS(command: string): void {
    if (!this.wsClient.connected) {
      // WS 断连：排队等重连，不走 HTTP fallback（HTTP fallback 的 chat 会被 agent skip）
      console.info('serein ws: WS not connected, queuing message for reconnect...')
      this.enqueuePendingChat(command)
      // 确保 WS 在尝试重连
      this.wsClient.connect(this.backendUrl)
      // 15 秒后允许用户继续输入，但不丢弃消息；网络恢复后仍会自动发送。
      if (this._pendingChatTimer) { clearTimeout(this._pendingChatTimer) }
      this._pendingChatTimer = setTimeout(() => {
        if (this._pendingChatMsgs.length > 0) {
          this._pendingChatTimer = 0
          this.cb.setExecuting(false)
          this.session.appendSystem('[网络仍未恢复，消息已保留，重连后会自动发送]', currentTheme().warning)
          this.cb.syncLines()
          this.cb.scrollToBottom()
        }
      }, 15000)
      return
    }
    const payload: Record<string, Object> = {}
    payload['content'] = command
    payload['project'] = this.terminalProject
    const msg: Record<string, Object> = {}
    msg['type'] = 'session_msg'
    msg['payload'] = payload
    const sent = this.wsClient.send(msg)
    if (!sent) {
      console.error('serein ws: send returned false, queuing for reconnect')
      this.enqueuePendingChat(command)
      this.wsClient.connect(this.backendUrl)
      return
    }
    this.clearChatTimeout()
    this.chatTimeoutId = setTimeout(() => {
      this.cb.setExecuting(false)
      this.session.appendSystem('[WS 响应超时，请重试]', '#EF4444')
      this.cb.syncLines()
      this.cb.scrollToBottom()
      this.chatTimeoutId = 0
    }, 60000)
  }

  private enqueuePendingChat(command: string): void {
    // 防止 connect/error 回调重复把同一条消息压入队列。
    const last = this._pendingChatMsgs.length > 0 ? this._pendingChatMsgs[this._pendingChatMsgs.length - 1] : undefined
    if (last && last.content === command && last.project === this.terminalProject) return
    if (this._pendingChatMsgs.length >= TerminalCmdDispatcher.MAX_PENDING_CHAT) {
      this.cb.setExecuting(false)
      this.session.appendSystem('[待发送队列已满（10 条），请等待网络恢复]', '#EF4444')
      this.cb.syncLines()
      return
    }
    this._pendingChatMsgs.push({ content: command, project: this.terminalProject })
    this.session.appendSystem('[已加入待发送队列 · ' + this._pendingChatMsgs.length + ']', '#8C909F')
    this.cb.syncLines()
  }

  /** WS 重连成功后发送排队的消息（由 TerminalPage 的 onOpen 回调调用） */
  flushPendingChat(): void {
    if (!this.wsClient.connected || this._pendingChatMsgs.length === 0) return
    if (this._pendingChatTimer) { clearTimeout(this._pendingChatTimer); this._pendingChatTimer = 0 }
    if (this._pendingFlushTimer) return
    this.flushNextPendingChat()
  }

  /** 按项目、按顺序恢复发送；间隔 750ms，避免 TUI 的粘贴/Enter 抑制窗口吞消息。 */
  private flushNextPendingChat(): void {
    if (!this.wsClient.connected) { this._pendingFlushTimer = 0; return }
    let pendingIndex = -1
    for (let i = 0; i < this._pendingChatMsgs.length; i++) {
      if (this._pendingChatMsgs[i].project === this.terminalProject) { pendingIndex = i; break }
    }
    if (pendingIndex < 0) { this._pendingFlushTimer = 0; return }
    const item = this._pendingChatMsgs[pendingIndex]
    this._pendingChatMsgs.splice(pendingIndex, 1)
    console.info('serein ws: flushing pending chat after reconnect')
    this.session.appendSystem('[网络已恢复，发送待处理消息 · 剩余 ' + this._pendingChatMsgs.length + ']', currentTheme().success)
    this.cb.syncLines()
    this.sendChatViaWS(item.content)
    this._pendingFlushTimer = setTimeout(() => {
      this._pendingFlushTimer = 0
      this.flushNextPendingChat()
    }, 750)
  }

  /** exec 走 HTTP 轮询 */
  async sendExecViaHTTP(action: string, command: string): Promise<void> {
    // HTTP 模式下拒绝发送 token 请求（防止 Token 明文传输被中间人截获）
    if (this.backendIsHttp) {
      this.session.appendSystem('[安全] HTTP 模式下不允许执行命令，请在设置中配置 HTTPS 后端地址', '#b53333')
      this.cb.setExecuting(false)
      this.cb.syncLines()
      return
    }
    const token = AppStorage.get<string>(KEY_CLIENT_TOKEN) ?? ''
    const hc = http.createHttp()
    try {
      const hdr: Record<string, string> = { 'Content-Type': 'application/json' }
      if (token !== '') {
        hdr['Authorization'] = 'Bearer ' + token
      }
      const r = await hc.request(this.backendUrl + '/agent/cmd?async=true', {
        method: http.RequestMethod.POST,
        header: hdr,
        extraData: JSON.stringify({ action: action, project: this.terminalProject, command: command }),
        connectTimeout: 5000,
        readTimeout: 10000
      })
      if (r.responseCode === 401) {
        this.cb.setExecuting(false)
        this.cb.syncLines()
        handleAuthError()
        router.replaceUrl({ url: NavPath.PAIR })
        return
      }
      const d = JSON.parse(r.result as string) as Record<string, Object>
      if (d['ok'] === true && d['queued'] === true) {
        const cmdId = (d['cmd_id'] as string) ?? ''
        this.cmdPoller.resetForNewCmd()
        this.cmdPoller.setActiveCmdId(cmdId)
        this.cmdPoller.pollCmdResult(token)
      } else {
        this.session.appendError('Error: ' + ((d['error'] as string) ?? 'Unknown'))
        this.cb.setExecuting(false)
        this.cb.syncLines()
      }
    } catch (e) {
      this.session.appendError('Error: ' + ((e as Error).message ?? 'Network'))
      this.cb.setExecuting(false)
      this.cb.syncLines()
    } finally {
      hc.destroy()
    }
  }

  printHelp(): void {
    this.session.appendSystem('可用命令:', currentTheme().tool)
    this.session.appendSystem('  /resume /clear /help /snippets /history /theme /font +/-', '#A1A1AA')
    this.session.appendSystem('  /diff — git diff     /undo — git reset HEAD~1', '#A1A1AA')
    this.session.appendSystem('  /<命令> — Claude Code 斜杠/skill，如 /code-review', '#A1A1AA')
    this.session.appendSystem('  /!<cmd> — 远程 shell，如 /!ls -la', '#A1A1AA')
    this.session.appendSystem('  长按输出行复制 · 双指缩放字号 · 左右滑切项目', currentTheme().hint)
    this.cb.syncLines()
    this.cb.scrollToBottom()
  }

  /** 远程历史：从后端查询 PC 端执行过的命令 */
  async fetchRemoteHistory(): Promise<void> {
    if (this.backendUrl === '') { this.cb.setRemoteHistoryError('未配置后端地址'); return }
    // HTTP 模式下拒绝发送 token 请求
    if (this.backendIsHttp) { this.cb.setRemoteHistoryError('HTTP 模式不允许远程历史'); this.cb.setRemoteHistoryLoading(false); return }
    this.cb.setRemoteHistoryLoading(true)
    this.cb.setRemoteHistoryError('')
    const token = AppStorage.get<string>('clientToken') ?? ''
    const hc = http.createHttp()
    try {
      const hdr: Record<string, string> = { 'Content-Type': 'application/json' }
      if (token !== '') hdr['Authorization'] = 'Bearer ' + token
      const r = await hc.request(this.backendUrl + '/agent/history', {
        method: http.RequestMethod.GET,
        header: hdr,
        connectTimeout: 5000,
        readTimeout: 8000
      })
      if (r.responseCode === 200) {
        const results = JSON.parse(r.result as string) as Record<string, Object>[]
        this.cb.setRemoteHistoryList(this.buildRemoteHistoryPreviews(results))
        this.cb.setRemoteHistoryError('')
      } else if (r.responseCode === 401) {
        handleAuthError()
        router.replaceUrl({ url: NavPath.PAIR })
        return
      } else {
        this.cb.setRemoteHistoryError('服务器返回 ' + r.responseCode)
      }
    } catch (e) {
      this.cb.setRemoteHistoryError('加载失败，请检查网络')
      console.error('serein: fetchRemoteHistory failed: ' + (e as Error).message)
    } finally {
      this.cb.setRemoteHistoryLoading(false)
      hc.destroy()
    }
  }

  /** 解析远程历史结果，构建预览行 */
  buildRemoteHistoryPreviews(results: Record<string, Object>[]): string[] {
    const out: string[] = []
    for (let i = 0; i < results.length; i++) {
      const res = results[i]
      const action = (res['action'] as string) ?? ''
      const outVal = res['output'] as Record<string, Object> | undefined
      let preview = ''
      if (outVal) {
        const stdout = outVal['stdout'] as string | undefined
        if (stdout && stdout.length > 0) {
          preview = stdout.substring(0, 80).replace(/\n/g, ' ').trim()
        }
      }
      if (preview !== '') {
        out.push(action + ': ' + preview)
      } else {
        out.push('[' + action + ']')
      }
    }
    return out
  }

  /** 复制全部终端输出到剪贴板 */
  copyAllOutput(): void {
    try {
      const lines = this.cb.getLines()
      let allText = ''
      for (let i = 0; i < lines.length; i++) {
        if (lines[i].text) {
          allText += lines[i].text + '\n'
        }
      }
      if (!allText) { promptAction.showToast({ message: '无输出可复制', duration: 1000 }); return }
      const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, allText)
      const sys = pasteboard.getSystemPasteboard()
      sys.setDataSync(pasteData)
      promptAction.showToast({ message: '已复制全部 (' + lines.length + ' 行)', duration: 2000 })
    } catch (e) {
      promptAction.showToast({ message: '复制全部失败: ' + (e as Error).message, duration: 2000 })
    }
  }

  /** 命令补全提示更新 */
  updateSlashHints(text: string): void {
    if (text.startsWith('/')) {
      const matched: SlashCommandInfo[] = []
      for (let i = 0; i < SLASH_COMMANDS.length; i++) {
        if (SLASH_COMMANDS[i].cmd.startsWith(text)) {
          matched.push(SLASH_COMMANDS[i])
        }
      }
      matched.sort((a: SlashCommandInfo, b: SlashCommandInfo) => {
        if (a.builtin !== b.builtin) { return a.builtin ? -1 : 1 }
        return a.cmd < b.cmd ? -1 : 1
      })
      this.cb.setSlashHintOverflow(matched.length > SLASH_HINT_MAX)
      this.cb.setSlashHints(matched.slice(0, SLASH_HINT_MAX))
    } else {
      this.cb.setSlashHints([])
      this.cb.setSlashHintOverflow(false)
    }
    if (this.cb.getShowHistory()) {
      this.cb.setHistoryList(this.session.filterHistory(text))
    }
  }

  /** 选择斜杠补全 */
  pickSlashHint(cmd: string): void {
    this.cb.setSlashHints([])
    this.cb.setSlashHintOverflow(false)
    this.cb.submitCommand(cmd)
  }

  /** 打开历史面板 */
  openHistory(): void {
    this.cb.setShowHistory(true)
    this.cb.setHistoryList(this.session.filterHistory(this.cb.getInputText()))
    this.cb.setRemoteHistoryError('')
    // 不自动加载远程历史，保持和 PC Claude 一致：空白开始
  }

  /** 选择历史命令 */
  pickHistory(cmd: string): void {
    this.cb.setInputText(cmd)
    this.cb.setShowHistory(false)
    this.cb.setHistoryList([])
    this.cb.setRemoteHistoryList([])
    this.updateSlashHints(cmd)
  }

  /** 键盘按键处理 */
  handleKeyTap(key: string): void {
    if (key === '↑') {
      if (this.cb.getInputText().length > 0 || this.cb.getShowHistory()) {
        if (!this.cb.getShowHistory()) { this.openHistory() }
        else {
          const h = this.session.navigateHistory('up', this.cb.getInputText())
          if (h !== this.cb.getInputText()) this.cb.setInputText(h)
        }
      } else {
        const h = this.session.navigateHistory('up', this.cb.getInputText())
        if (h !== this.cb.getInputText()) this.cb.setInputText(h)
      }
      this.updateSlashHints(this.cb.getInputText())
      return
    }
    if (key === '↓') {
      const h = this.session.navigateHistory('down', this.cb.getInputText())
      this.cb.setInputText(h)
      this.updateSlashHints(h)
      return
    }
    if (key === 'Esc') {
      this.cb.setInputText('')
      this.cb.setSlashHints([])
      this.cb.setSlashHintOverflow(false)
      this.cb.setShowHistory(false)
      return
    }
    this.cb.setInputText(this.cb.getInputText() + (key === 'Tab' ? '\t' : key))
    this.updateSlashHints(this.cb.getInputText())
  }

  /** 载入片段列表到面板 */
  async loadSnippets(): Promise<void> {
    const snippets = await PrefStore.loadSnippets()
    this.cb.setSnippets(snippets as Snippet[])
    this.cb.setShowSnippets(true)
  }

  /** 从输入保存片段 */
  async addSnippetFromInput(): Promise<void> {
    const t = this.cb.getInputText().trim()
    if (t === '') { promptAction.showToast({ message: '输入为空', duration: 1000 }); return }
    const name = t.length > 20 ? t.substring(0, 20) : t
    const cur = await PrefStore.loadSnippets()
    const next = cur.concat([{ name: name, command: t }])
    this.cb.setSnippets(next as Snippet[])
    await PrefStore.saveSnippets(next)
    promptAction.showToast({ message: '已保存片段', duration: 1000 })
  }

  /** 删除片段 */
  async deleteSnippet(name: string): Promise<void> {
    const cur = await PrefStore.loadSnippets()
    const next: Snippet[] = []
    for (let i = 0; i < cur.length; i++) {
      if (cur[i].name !== name) next.push(cur[i])
    }
    this.cb.setSnippets(next as Snippet[])
    await PrefStore.saveSnippets(next)
  }

  /** 提交并分发：prepare UI + dispatch to WS or HTTP */
  async submitAndDispatch(t: string): Promise<void> {
    this.session.addToHistory(t)
    await this.cb.saveHistory()
    this.session.startBlock()
    this.session.appendPrompt(t)
    this.cb.setInputText('')
    this.cb.setSlashHints([])
    this.cb.setSlashHintOverflow(false)
    this.cb.setShowHistory(false)
    this.cb.setShowSnippets(false)
    // 对目录信任、更新确认、模型切换等交互选项的回答，不是假定的模型回合。
    // 等 relay 明确发来 turn_start / thinking 后再显示 “is thinking”。
    this.cb.setExecuting(!this.session.hasPendingChoice())
    this.cb.setUserScrolledUp(false)
    this.cb.syncLines()
    this.cb.scrollToBottom()

    const info = await this.resolveActionAndCommand(t)
    if (info.action === 'chat') {
      this.sendChatViaWS(info.command)
    } else {
      await this.sendExecViaHTTP(info.action, info.command)
    }
  }
}
