/**
 * TerminalCmdPoller — HTTP 轮询命令结果管理
 * 从 TerminalPage.ets 提取的轮询逻辑，减少终端页面的复杂度
 */
import { http } from '@kit.NetworkKit'
import { router } from '@kit.ArkUI'
import { handleAuthError } from '../state/AppStore'
import NavPath from '../model/NavPath'
import type { TerminalSession } from './TerminalSession'
import { currentTheme } from './TerminalTheme'

/** 轮询回调接口，由 TerminalContent 实现 */
export interface PollerCallbacks {
  appendOutput(text: string): void
  appendSystem(text: string, color: string): void
  syncLines(): void
  scrollToBottom(): void
  setExecuting(v: boolean): void
}

/**
 * PollerCallbacks 的显式实现类。ArkTS 严格模式要求对象字面量必须对应显式声明的类，
 * 因此无法直接在 makePollerCallbacks 中用对象字面量实现 PollerCallbacks 接口。
 * 使用此类作为代理，在构造函数中注入回调函数。
 */
export class PollerBinding implements PollerCallbacks {
  private _appendOutput: (text: string) => void = () => {}
  private _appendSystem: (text: string, color: string) => void = () => {}
  private _syncLines: () => void = () => {}
  private _scrollToBottom: () => void = () => {}
  private _setExecuting: (v: boolean) => void = () => {}
  constructor(
    appendOutput: (text: string) => void,
    appendSystem: (text: string, color: string) => void,
    syncLines: () => void,
    scrollToBottom: () => void,
    setExecuting: (v: boolean) => void,
  ) {
    this._appendOutput = appendOutput
    this._appendSystem = appendSystem
    this._syncLines = syncLines
    this._scrollToBottom = scrollToBottom
    this._setExecuting = setExecuting
  }
  appendOutput(text: string): void { this._appendOutput(text) }
  appendSystem(text: string, color: string): void { this._appendSystem(text, color) }
  syncLines(): void { this._syncLines() }
  scrollToBottom(): void { this._scrollToBottom() }
  setExecuting(v: boolean): void { this._setExecuting(v) }
}

export class TerminalCmdPoller {
  private backendUrl: string = ''
  private backendIsHttp: boolean = false  // HTTP 模式拒绝轮询（防止 Token 明文）
  private pollAbort: boolean = false
  private activePollCmdId: string = ''
  private pollLastSeq: number = 0
  private resultShownCmdIds: string[] = []
  private session: TerminalSession
  private cb: PollerCallbacks

  constructor(backendUrl: string, session: TerminalSession, cb: PollerCallbacks) {
    this.backendUrl = backendUrl
    this.session = session
    this.cb = cb
  }

  /** 重置状态（提交新命令时调用） */
  resetForNewCmd(): void {
    this.pollAbort = false
    this.activePollCmdId = ''
    this.pollLastSeq = 0
  }

  /** 取消当前轮询 */
  abort(): void {
    this.pollAbort = true
  }

  /** 设置当前轮询的 cmdId */
  setActiveCmdId(cmdId: string): void {
    this.activePollCmdId = cmdId
  }

  /** 会话切换时更新引用 */
  setSession(s: TerminalSession): void {
    this.session = s
  }

  /** 设置后端 URL */
  setBackendUrl(url: string): void {
    this.backendUrl = url
  }

  /** 设置 HTTP 模式标志（HTTP 模式拒绝 token 请求） */
  setBackendIsHttp(v: boolean): void {
    this.backendIsHttp = v
  }

  /**
   * 轮询中间步骤增量并拼装显示，最终结果走 /agent/history。
   * 提取自 TerminalPage.ets 的 pollCmdResult 方法。
   */
  async pollCmdResult(token: string): Promise<void> {
    // HTTP 模式下拒绝轮询（防止 Token 在 Authorization header 中明文传输）
    if (this.backendIsHttp) {
      console.error('serein: HTTP mode — pollCmdResult rejected (token security)')
      this.cb.setExecuting(false)
      this.cb.syncLines()
      return
    }
    const cmdId = this.activePollCmdId
    let consecutiveErr: number = 0  // 连续失败次数，超过上限提前退出
    for (let i = 0; i < 300; i++) {
      await new Promise<void>(resolve => setTimeout(resolve, 3000))
      if (this.pollAbort || this.activePollCmdId !== cmdId) {
        return
      }
      try {
        // 1. 拉 step 增量（?after=lastSeq 只拿没显示过的）
        const hs = http.createHttp()
        try {
          const hStep: Record<string, string> = { 'Content-Type': 'application/json' }
          if (token !== '') { hStep['Authorization'] = 'Bearer ' + token }
          const rStep = await hs.request(this.backendUrl + '/agent/cmd/' + cmdId + '/steps?after=' + this.pollLastSeq, {
            method: http.RequestMethod.GET, header: hStep, connectTimeout: 5000, readTimeout: 5000
          })
          if (rStep.responseCode === 401) { handleAuthError(); router.replaceUrl({ url: NavPath.PAIR }); return }
          if (rStep.responseCode === 200) {
            const arr = JSON.parse(rStep.result as string) as Record<string, Object>[]
            for (const s of arr) {
              const seq = (s['seq'] as number) ?? 0
              if (seq > this.pollLastSeq) {
                this.pollLastSeq = seq
                this.renderStep(s)
              }
            }
          }
        } finally {
          hs.destroy()
        }
        if (this.pollAbort || this.activePollCmdId !== cmdId) { return }

        // 2. 拉 history 检查最终结果（每 3 轮一次，减少请求）
        if (i % 3 === 0) {
          const hc2 = http.createHttp()
          try {
            const h2: Record<string, string> = { 'Content-Type': 'application/json' }
            if (token !== '') { h2['Authorization'] = 'Bearer ' + token }
            const r2 = await hc2.request(this.backendUrl + '/agent/history', {
              method: http.RequestMethod.GET, header: h2, connectTimeout: 5000, readTimeout: 5000
            })
            if (r2.responseCode === 401) { handleAuthError(); router.replaceUrl({ url: NavPath.PAIR }); return }
            const results = JSON.parse(r2.result as string) as Record<string, Object>[]
            for (const res of results) {
              const rid = (res['cmd_id'] as string) ?? ''
              // 跳过已经展示过的 cmd_id（防重复）
              let alreadyShown: boolean = false
              for (let si = 0; si < this.resultShownCmdIds.length; si++) {
                if (this.resultShownCmdIds[si] === rid) { alreadyShown = true; break }
              }
              if (rid === '' || alreadyShown) { continue }
              if (rid === cmdId) {
                // 标记已展示，限制最多 50 条防内存泄漏
                const nextIds = this.resultShownCmdIds.concat([rid])
                this.resultShownCmdIds = nextIds.length > 50 ? nextIds.slice(nextIds.length - 50) : nextIds
                this.cb.setExecuting(false)
                this.cb.syncLines()
                this.cb.scrollToBottom()
                return
              }
            }
          } finally {
            hc2.destroy()
          }
        }
      } catch (e) {
        console.error('serein pollCmdResult: ' + ((e as Error).message ?? 'Network'))
        consecutiveErr++
        if (consecutiveErr >= 5) {
          console.error('serein pollCmdResult: 连续' + consecutiveErr + '次失败，提前退出')
          break
        }
      }
    }
    // 兜底：轮询超时（5 分钟）后最后一次检查 /agent/history，
    // 防止命令执行时间超出轮询窗口导致结果丢失（仅当 WS 不可用时可能发生）。
    try {
      const hcFinal = http.createHttp()
      try {
        const hFinal: Record<string, string> = { 'Content-Type': 'application/json' }
        if (token !== '') { hFinal['Authorization'] = 'Bearer ' + token }
        const rFinal = await hcFinal.request(this.backendUrl + '/agent/history', {
          method: http.RequestMethod.GET, header: hFinal, connectTimeout: 5000, readTimeout: 5000
        })
        if (rFinal.responseCode === 200) {
          const results = JSON.parse(rFinal.result as string) as Record<string, Object>[]
          for (const res of results) {
            const rid = (res['cmd_id'] as string) ?? ''
            if (rid === cmdId) {
              this.cb.setExecuting(false)
              this.cb.syncLines()
              this.cb.scrollToBottom()
              hcFinal.destroy()
              return
            }
          }
        }
      } finally {
        hcFinal.destroy()
      }
    } catch (_e) { /* final check failed, gracefully fall through */ }
    this.cb.setExecuting(false)
    this.cb.syncLines()
  }

  /** 把一条 step 拼成系统行显示（与 onWSEvent 渲染逻辑一致） */
  private renderStep(s: Record<string, Object>): void {
    const eventType = (s['event'] as string) ?? ''
    const eventName = (s['name'] as string) ?? ''
    const content = (s['content'] as string) ?? ''
    // text 类型：relay 端已保留 SGR 颜色码，走 appendOutput 用 parseAnsi 渲染彩色
    if (eventType === 'text') {
      if (content !== '') {
        this.cb.appendOutput(content)
        this.cb.syncLines()
        this.cb.scrollToBottom()
      }
      return
    }
    let color = '#A1A1AA'
    let prefix = ''
    if (eventType === 'tool_use') { color = currentTheme().tool; prefix = '[工具] ' + eventName }
    else if (eventType === 'tool_result') { color = currentTheme().result; prefix = '[完成] ' }
    else if (eventType === 'hook') { color = '#8C909F'; prefix = '[钩子] ' + eventName }
    else { return }
    const line = prefix !== '' ? (prefix + (content ? ' ' + content : '')) : content
    if (line !== '') {
      this.cb.appendSystem(line, color)
      this.cb.syncLines()
      this.cb.scrollToBottom()
    }
  }
}
