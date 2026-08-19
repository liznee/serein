﻿﻿﻿/**
 * RelayManager — 远程连接管理（P1-2）
 *
 * 从 TerminalPage.TerminalContent 提取，减少主文件代码行数。
 * 负责 relay 启动、状态检测和超时处理，不涉及 UI。
 *
 * v2: 改用 WS heartbeat 驱动状态检测，HTTP 轮询降频为 60s fallback。
 */
import { http } from '@kit.NetworkKit'
import { TerminalSession } from './TerminalSession'
import { KEY_CLIENT_TOKEN } from '../state/AppStore'
import { currentTheme } from './TerminalTheme'

/** Relay 管理器回调 — TerminalContent 通过此接口暴露 UI 更新方法 */
export interface RelayCallbacks {
  appendSystem(text: string, color: string): void
  syncLines(): void
  joinWSSession(): void
  setRelayStatus(v: string): void
  isDestroyed(): boolean
}

/** Relay 回调绑定 */
export class RelayBinding implements RelayCallbacks {
  public appendSystem: (text: string, color: string) => void
  public syncLines: () => void
  public joinWSSession: () => void
  public setRelayStatus: (v: string) => void
  public isDestroyed: () => boolean
  constructor(
    appendSystem: (text: string, color: string) => void,
    syncLines: () => void,
    joinWSSession: () => void,
    setRelayStatus: (v: string) => void,
    isDestroyed: () => boolean,
  ) {
    this.appendSystem = appendSystem
    this.syncLines = syncLines
    this.joinWSSession = joinWSSession
    this.setRelayStatus = setRelayStatus
    this.isDestroyed = isDestroyed
  }
}

export class RelayManager {
  private backendUrl: string = ''
  private session: TerminalSession
  private callbacks: RelayCallbacks
  private _terminalProject: string = ''
  private _agentType: string = 'claude'
  private _runtimeMode: string = 'cli'
  /** #review: private 字段，外部通过 getter 读取，通过 resetStatus/setRelayStatus 回调写入 */
  private _relayStatus: string = 'checking'
  private _relayCheckTimer: number = -1
  private _relayStartTimer: number = -1
  /** 启动中标志，防止 checkRelayStatus 异步执行期间的并发 startRelay 调用
   *  参考 agent_proc.py 的 _relay_starting 模式 */
  private _relayStarting: boolean = false
  /** Heartbeat watchdog：检测 relay 停止发送心跳 */
  private _heartbeatWatchdog: number = -1
  /** forceOnline 调用时间戳，用于 handleHeartbeat 宽限期（避免 WS 先连上但 agent 心跳尚未更新 running 列表时的 online→offline 误报） */
  private _forceOnlineAt: number = 0

  /** 公开 getter — 外部只读访问 relayStatus */
  get relayStatus(): string {
    return this._relayStatus
  }

  constructor(session: TerminalSession, callbacks: RelayCallbacks) {
    this.session = session
    this.callbacks = callbacks
  }

  setBackendUrl(url: string): void {
    this.backendUrl = url
  }

  setProject(project: string): void {
    this._terminalProject = project
  }

  setAgentType(agentType: string): void {
    this._agentType = agentType
  }

  setRuntimeMode(runtimeMode: string): void {
    this._runtimeMode = runtimeMode
  }

  setSession(session: TerminalSession): void {
    this.session = session
  }

  /** #review: 外部重置状态（不触发 UI 回调），用于切项目时预置 checking */
  resetStatus(v: string): void {
    this._relayStatus = v
  }

  /** WS 连接成功时调用：直接设置状态为 online。
   *  场景：relay 通过 serein CLI 启动后 WS 连接成功，
   *  但 HTTP /agent/projects 可能尚未反映 relay 状态。
   *  注意：WS 连接的是后端而非 relay，relay 被杀后 WS 不会断开，
   *  因此 online 状态下仍需保持 heartbeat watchdog 来检测 relay 是否被停止。 */
  forceOnline(): void {
    this._relayStatus = 'online'
    this.callbacks.setRelayStatus('online')
    this._forceOnlineAt = Date.now()
    if (this._relayStartTimer >= 0) {
      clearTimeout(this._relayStartTimer)
      this._relayStartTimer = -1
    }
    this._relayStarting = false
    // online 状态下启动慢轮询（60s）作为 fallback
    // 主状态检测由 heartbeat watchdog 负责
    if (this._relayCheckTimer >= 0) {
      clearTimeout(this._relayCheckTimer)
    }
    if (!this.callbacks.isDestroyed()) {
      this._relayCheckTimer = setTimeout(() => { this.checkRelayStatus() }, 60000)
    } else {
      this._relayCheckTimer = -1
    }
  }

  /** WS 断连或收到 stop cmd_result 时调用：立即设置为 offline 并重启轮询。
   *  给用户秒级反馈，不需要等待 HTTP 轮询确认。 */
  forceOffline(): void {
    if (this._relayStatus === 'offline') return
    const wasOnline = this._relayStatus === 'online'
    this._relayStatus = 'offline'
    this.callbacks.setRelayStatus('offline')
    this.stopHeartbeatWatchdog()
    if (wasOnline) {
      this.callbacks.appendSystem('[Relay] 连接已断开', '#EF4444')
      this.callbacks.syncLines()
    }
    // 重启轮询以检测 relay 恢复（WS 断连时 fallback）
    if (this._relayCheckTimer >= 0) {
      clearTimeout(this._relayCheckTimer)
    }
    if (!this.callbacks.isDestroyed()) {
      this._relayCheckTimer = setTimeout(() => { this.checkRelayStatus() }, 5000)
    } else {
      this._relayCheckTimer = -1
    }
  }

  /** 检查 relay 在线状态（HTTP fallback） */
  async checkRelayStatus(): Promise<void> {
    if (this.backendUrl === '') return
    // 安全警告：HTTP 模式下 CLIENT_TOKEN 明文传输（Authorization: Bearer）
    if (this.backendUrl.startsWith('http://')) {
      console.warn('serein: HTTP 模式 — CLIENT_TOKEN 以明文 Bearer 传输，建议使用 HTTPS')
    }
    // #review: 清除前一个定时器防止泄漏（startRelay 轮询中反复调用会累积定时器）
    if (this._relayCheckTimer >= 0) {
      clearTimeout(this._relayCheckTimer)
      this._relayCheckTimer = -1
    }
    const hc = http.createHttp()
    try {
      const token = AppStorage.get<string>(KEY_CLIENT_TOKEN) ?? ''
      const hdr: Record<string, string> = {}
      if (token !== '') hdr['Authorization'] = 'Bearer ' + token
      const r = await hc.request(this.backendUrl + '/agent/projects', {
        method: http.RequestMethod.GET,
        header: hdr,
        connectTimeout: 3000,
        readTimeout: 3000,
      })
      const pStatus = this._relayStatus
      if (r.responseCode === 200) {
        const data = JSON.parse(r.result as string) as Record<string, Object>
        const running = data['running'] as string[] ?? []
        const newStatus = running.indexOf(this._terminalProject) >= 0 ? 'online' : 'offline'
        this._relayStatus = newStatus
        this.callbacks.setRelayStatus(newStatus)
        if (pStatus === 'checking' && newStatus === 'online') {
          // 只在首次检查就成功时输出「已就绪」
          this.callbacks.appendSystem('[Relay] 已就绪（在线）', currentTheme().success)
          this.callbacks.syncLines()
        }
        // 检测 online→offline 转换（relay 被停止）
        if (pStatus === 'online' && newStatus === 'offline') {
          this.callbacks.appendSystem('[Relay] 已断开', '#EF4444')
          this.callbacks.syncLines()
        }
        // 首次检查结果是 offline 时不输出任何提示，继续静默轮询
      } else {
        // HTTP 非200：如果是 online 状态则降级
        if (pStatus === 'online') {
          this._relayStatus = 'offline'
          this.callbacks.setRelayStatus('offline')
          this.callbacks.appendSystem('[Relay] 已断开', '#EF4444')
          this.callbacks.syncLines()
        } else {
          this._relayStatus = 'offline'
          this.callbacks.setRelayStatus('offline')
        }
      }
    } catch (e) {
      console.error('serein: checkRelayStatus failed: ' + (e as Error).message)
      this._relayStatus = 'offline'
      this.callbacks.setRelayStatus('offline')
      // 网络异常：静默继续轮询，不输出「未就绪（离线）」
    } finally {
      hc.destroy()
    }
    // online 时保持 60s 慢轮询作为 fallback（主状态由 heartbeat watchdog 驱动）
    // checking/offline 时 5s 轮询（Start 后等 relay 上线 / Stop 后等 relay 恢复）
    if (!this.callbacks.isDestroyed()) {
      const interval = this._relayStatus === 'online' ? 60000 : 5000
      this._relayCheckTimer = setTimeout(() => { this.checkRelayStatus() }, interval)
    } else {
      this._relayCheckTimer = -1
    }
  }

  /** 远程停止 relay（切换 agent 类型时先停再启） */
  async stopRelay(): Promise<void> {
    if (this.backendUrl === '') return
    const hc = http.createHttp()
    try {
      const token = AppStorage.get<string>(KEY_CLIENT_TOKEN) ?? ''
      const hdr: Record<string, string> = {}
      if (token !== '') hdr['Authorization'] = 'Bearer ' + token
      await hc.request(this.backendUrl + '/agent/cmd?async=true', {
        method: http.RequestMethod.POST,
        header: hdr,
        extraData: JSON.stringify({ action: 'stop', project: this._terminalProject }),
        connectTimeout: 5000,
        readTimeout: 8000,
      })
    } catch (e) {
      console.error('stopRelay failed: ' + (e as Error).message)
    } finally {
      hc.destroy()
    }
  }

  /** 远程启动 relay 并等待上线（附带 429/503 重试，指数退避） */
  async startRelay(): Promise<void> {
    if (this._relayStatus === 'starting' || this._relayStatus === 'online') return
    // 使用 _relayStarting 标志位防止 checkRelayStatus 异步执行期间的并发启动
    if (this._relayStarting) return
    // 安全警告：HTTP 模式下 CLIENT_TOKEN 明文传输（Authorization: Bearer）
    if (this.backendUrl.startsWith('http://')) {
      console.warn('serein: HTTP 模式 — CLIENT_TOKEN 以明文 Bearer 传输，建议使用 HTTPS')
    }
    this._relayStarting = true
    this._relayStatus = 'starting'
    this.callbacks.setRelayStatus('starting')
    this.callbacks.appendSystem('[Relay] 正在启动远程连接...', currentTheme().tool)
    this.callbacks.syncLines()
    let retries = 0
    const maxRetries = 3
    let started = false
    while (!started && retries <= maxRetries) {
      const hc = http.createHttp()
      try {
        const token = AppStorage.get<string>(KEY_CLIENT_TOKEN) ?? ''
        const hdr: Record<string, string> = {}
        if (token !== '') hdr['Authorization'] = 'Bearer ' + token
        const resp = await hc.request(this.backendUrl + '/agent/cmd?async=true', {
          method: http.RequestMethod.POST,
          header: hdr,
          extraData: JSON.stringify({
            action: 'start',
            project: this._terminalProject,
            agent_type: this._agentType,
            runtime_mode: this._runtimeMode,
            command: this._runtimeMode,
          }),
          connectTimeout: 5000,
          readTimeout: 10000,
        })
        if (resp.responseCode === 200) {
          started = true
        } else if ((resp.responseCode === 429 || resp.responseCode === 503) && retries < maxRetries) {
          retries++
          const delay = Math.pow(2, retries) * 1000
          this.callbacks.appendSystem('[Relay] 服务器繁忙 (' + resp.responseCode + ')，' + (delay / 1000) + 's 后重试 (' + retries + '/' + maxRetries + ')', currentTheme().warning)
          this.callbacks.syncLines()
          await new Promise<void>((resolve: () => void) => { setTimeout(resolve, delay) })
        } else {
          this.callbacks.appendSystem('[Relay] 启动请求失败 (HTTP ' + resp.responseCode + ')', '#EF4444')
          this.callbacks.syncLines()
          break  // 退出循环，不进入轮询
        }
      } catch (e) {
        console.error('startRelay failed: ' + (e as Error).message)
        if (retries < maxRetries) {
          retries++
          const delay = Math.pow(2, retries) * 1000
          await new Promise<void>((resolve: () => void) => { setTimeout(resolve, delay) })
        } else {
          this._relayStatus = 'offline'
          this.callbacks.setRelayStatus('offline')
          this.callbacks.appendSystem('[Relay] 启动请求失败: ' + ((e as Error).message || '网络错误'), '#EF4444')
          this.callbacks.syncLines()
          break  // 退出循环，不进入轮询
        }
      } finally {
        hc.destroy()
      }
    }
    this._relayStarting = false  // HTTP 请求阶段结束，清除启动中标志
    if (!started) {
      // 所有尝试失败（含 HTTP 错误、429/503 耗尽、网络异常耗尽）
      this._relayStatus = 'offline'
      this.callbacks.setRelayStatus('offline')
      this.callbacks.appendSystem('[Relay] 启动请求失败，请稍后重试', '#EF4444')
      this.callbacks.syncLines()
      this._relayStartTimer = -1
      return  // 不进入轮询阶段，避免交互矛盾
    }
    // 只有 HTTP 200 成功才进入轮询等待 relay 上线
    const pollStart = Date.now()
    this._schedulePoll(pollStart)
  }

  /** 轮询等待 relay 上线（从 startRelay 提取为独立方法）。
   *  30 秒超时 → offline，online → joinWSSession */
  private _schedulePoll(pollStart: number): void {
    if (this._relayStartTimer >= 0) {
      clearTimeout(this._relayStartTimer)
      this._relayStartTimer = -1
    }
    this._relayStartTimer = setTimeout(() => { this._pollForOnline(pollStart) }, 2000)
  }

  private _pollForOnline(pollStart: number): void {
    if (this.callbacks.isDestroyed()) {
      this._relayStartTimer = -1
      return
    }
    if (Date.now() - pollStart > 30000) {
      this._relayStatus = 'offline'
      this.callbacks.setRelayStatus('offline')
      this.callbacks.appendSystem('[Relay] 启动超时，请重试', '#EF4444')
      this.callbacks.syncLines()
      this._relayStartTimer = -1
      return
    }
    this.checkRelayStatus().then(() => {
      if (this.callbacks.isDestroyed()) return
      if (this._relayStatus === 'online') {
        this._relayStarting = false
        this.callbacks.appendSystem('[Relay] 已连接', currentTheme().success)
        this.callbacks.syncLines()
        this._relayStartTimer = -1
        this.callbacks.joinWSSession()
      } else {
        this._schedulePoll(pollStart)
      }
    }).catch(() => {
      if (this.callbacks.isDestroyed()) {
        this._relayStartTimer = -1
        return
      }
      this._schedulePoll(pollStart)
    })
  }

  /** 清除所有定时器 */
  clearTimers(): void {
    this._relayStarting = false
    if (this._relayCheckTimer >= 0) {
      clearTimeout(this._relayCheckTimer)
      this._relayCheckTimer = -1
    }
    if (this._relayStartTimer >= 0) {
      clearTimeout(this._relayStartTimer)
      this._relayStartTimer = -1
    }
    this.stopHeartbeatWatchdog()
  }

  /** 处理 WS heartbeat 数据，检测 relay 在线状态。
   *  由 TerminalPage 在收到 heartbeat 事件时调用。
   *  如果 heartbeat 中 running 列表包含当前项目，则 relay online。
   *  如果不包含，且当前状态为 online，则标记 offline。 */
  handleHeartbeat(data: Record<string, Object>): void {
    if (this.callbacks.isDestroyed()) return
    const runningRaw = data['running']
    if (!runningRaw) return
    const runningList = runningRaw as Object[]
    let isRunning = false
    for (let i = 0; i < runningList.length; i++) {
      if ((runningList[i] as string) === this._terminalProject) {
        isRunning = true
        break
      }
    }
    if (isRunning && this._relayStatus !== 'online') {
      // relay 上线
      this._relayStatus = 'online'
      this.callbacks.setRelayStatus('online')
      if (this._relayStartTimer >= 0) {
        clearTimeout(this._relayStartTimer)
        this._relayStartTimer = -1
      }
      this._relayStarting = false
      this.callbacks.appendSystem('[Relay] 已就绪（在线）', currentTheme().success)
      this.callbacks.syncLines()
    } else if (!isRunning && this._relayStatus === 'online') {
      // forceOnline 后 3s 宽限期：WS 先连上但 agent 心跳 running 列表尚未更新时，
      // 不立即报 offline，等下一次心跳再确认。避免 "已断开" → "已就绪" 的闪烁。
      if (this._forceOnlineAt > 0 && Date.now() - this._forceOnlineAt < 3000) {
        this.resetHeartbeatWatchdog()
        return
      }
      // relay 不在 running 列表中，标记为 offline
      this._relayStatus = 'offline'
      this.callbacks.setRelayStatus('offline')
      this.callbacks.appendSystem('[Relay] 已断开', '#EF4444')
      this.callbacks.syncLines()
    }
    // 重置 heartbeat watchdog
    this.resetHeartbeatWatchdog()
  }

  /** 重置 heartbeat watchdog：40s 内无 heartbeat 则标记 offline */
  private resetHeartbeatWatchdog(): void {
    this.stopHeartbeatWatchdog()
    if (this.callbacks.isDestroyed()) return
    // 40s = agent heartbeat interval (25s) * 1.6 容差
    this._heartbeatWatchdog = setTimeout(() => {
      if (this.callbacks.isDestroyed()) { this._heartbeatWatchdog = -1; return }
      if (this._relayStatus === 'online') {
        console.warn('[Relay] heartbeat watchdog: no heartbeat in 40s, marking offline')
        this._relayStatus = 'offline'
        this.callbacks.setRelayStatus('offline')
        this.callbacks.appendSystem('[Relay] 心跳超时', '#EF4444')
        this.callbacks.syncLines()
      }
      this._heartbeatWatchdog = -1
    }, 40000)
  }

  /** 停止 heartbeat watchdog */
  private stopHeartbeatWatchdog(): void {
    if (this._heartbeatWatchdog >= 0) {
      clearTimeout(this._heartbeatWatchdog)
      this._heartbeatWatchdog = -1
    }
  }
}
