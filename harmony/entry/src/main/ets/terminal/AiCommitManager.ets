/**
 * AiCommitManager — AI 生成 commit message 管理
 *
 * 从 TerminalPage.TerminalContent 提取，减少主文件代码行数。
 * 负责调用后端 /agent/ai-commit API 获取 git diff，通过 WS 发送给 Claude 生成 commit message。
 */
import { http } from '@kit.NetworkKit'
import { router } from '@kit.ArkUI'
import { TerminalSession } from './TerminalSession'
import { WebSocketClient } from '../api/WebSocketClient'
import { KEY_CLIENT_TOKEN, handleAuthError } from '../state/AppStore'
import NavPath from '../model/NavPath'
import { currentTheme } from './TerminalTheme'

/** AI Commit 回调 */
export interface AiCommitCallbacks {
  appendSystem(text: string, color: string): void
  syncLines(): void
  scrollToBottom(): void
  appendError(text: string): void
  setExecuting(v: boolean): void
  isDestroyed(): boolean
}

/** AI Commit 回调绑定 */
export class AiCommitBinding implements AiCommitCallbacks {
  public appendSystem: (text: string, color: string) => void
  public syncLines: () => void
  public scrollToBottom: () => void
  public appendError: (text: string) => void
  public setExecuting: (v: boolean) => void
  public isDestroyed: () => boolean
  constructor(
    appendSystem: (text: string, color: string) => void,
    syncLines: () => void,
    scrollToBottom: () => void,
    appendError: (text: string) => void,
    setExecuting: (v: boolean) => void,
    isDestroyed: () => boolean,
  ) {
    this.appendSystem = appendSystem
    this.syncLines = syncLines
    this.scrollToBottom = scrollToBottom
    this.appendError = appendError
    this.setExecuting = setExecuting
    this.isDestroyed = isDestroyed
  }
}

export class AiCommitManager {
  private backendUrl: string = ''
  private session: TerminalSession
  private callbacks: AiCommitCallbacks
  private wsClient: WebSocketClient
  private _terminalProject: string = ''
  // #review: 发送 diff 到 Claude API 前的用户确认回调，由 TerminalPage 注入实现(promptAction.showDialog)。
  // 用户可审查 diff 摘要后选择继续或取消，防止正则脱敏遗漏的敏感信息通过 WS 发送。
  public onRequestConfirm?: (message: string) => Promise<boolean>

  constructor(session: TerminalSession, wsClient: WebSocketClient, callbacks: AiCommitCallbacks) {
    this.session = session
    this.wsClient = wsClient
    this.callbacks = callbacks
  }

  setBackendUrl(url: string): void {
    this.backendUrl = url
  }

  setProject(project: string): void {
    this._terminalProject = project
  }

  setSession(session: TerminalSession): void {
    this.session = session
  }

  /** 执行 AI Commit 流程 */
  async handleAiCommit(): Promise<void> {
    const token = AppStorage.get<string>(KEY_CLIENT_TOKEN) ?? ''
    const hc = http.createHttp()
    try {
      const hdr: Record<string, string> = { 'Content-Type': 'application/json' }
      if (token !== '') hdr['Authorization'] = 'Bearer ' + token
      this.callbacks.appendSystem('[AI Commit] 获取 git diff...', '#A1A1AA')
      this.callbacks.syncLines()
      const r = await hc.request(this.backendUrl + '/agent/ai-commit', {
        method: http.RequestMethod.POST,
        header: hdr,
        extraData: JSON.stringify({ project: this._terminalProject }),
        connectTimeout: 30000,
        readTimeout: 30000,
      })
      if (r.responseCode === 200) {
        const result = JSON.parse(r.result as string) as Record<string, Object>
        if (result['success'] === true) {
          const diff = (result['diff'] as string) ?? ''
          if (diff === '') {
            this.callbacks.appendSystem('[AI Commit] 无未提交的变更', currentTheme().result)
            this.callbacks.syncLines()
            return
          }
          const safeDiff = (diff as string).replace(/\x60{3}/g, '\\`\\`\\`')
          this.callbacks.appendSystem('[AI Commit] 已获取 diff (' + diff.length + ' 字符)', currentTheme().result)
          this.callbacks.syncLines()
          // #review: 发送前请求用户确认。diff 中的敏感信息（密钥/token/密码）依赖后端
          // sanitizeDiff() 正则脱敏，必然有 false negative。用户审查后确认再继续。
          if (this.onRequestConfirm) {
            const confirmed = await this.onRequestConfirm(
              'AI Commit 将把以下 git diff 发送给 Claude API 生成 commit message。\n\n' +
              'diff 长度: ' + diff.length + ' 字符\n' +
              '⚠️ 敏感信息（密钥/token/密码）已在服务端脱敏，但正则脱敏可能遗漏。\n\n' +
              '是否继续发送？'
            )
            if (!confirmed) {
              this.callbacks.appendSystem('[AI Commit] 已取消', '#A1A1AA')
              this.callbacks.syncLines()
              return
            }
          }
          const prompt = '请为以下 git diff 生成规范的 conventional commit message（格式: type(scope): description，如 feat(auth): add login endpoint）:\n\n```\n' + safeDiff + '\n```\n\n请直接输出 commit message，不要额外解释。'
          this.callbacks.appendSystem('[AI Commit] 正在发送给 Claude...', currentTheme().tool)
          this.callbacks.syncLines()
          // 通过 WS 发送到 relay claude
          const payload: Record<string, Object> = {}
          payload['content'] = prompt
          payload['project'] = this._terminalProject
          const msg: Record<string, Object> = {}
          msg['type'] = 'session_msg'
          msg['payload'] = payload
          this.wsClient.send(msg)
        } else {
          this.callbacks.appendError('[AI Commit] ' + ((result['error'] as string) ?? '未知错误'))
        }
      } else if (r.responseCode === 401) {
        handleAuthError()
        router.replaceUrl({ url: NavPath.PAIR })
        return
      } else {
        this.callbacks.appendError('[AI Commit] 服务器返回 ' + r.responseCode + '，请检查网络')
      }
    } catch (e) {
      this.callbacks.appendError('[AI Commit] ' + ((e as Error).message || '网络错误'))
    } finally {
      hc.destroy()
      this.callbacks.setExecuting(false)
      this.callbacks.syncLines()
      this.callbacks.scrollToBottom()
    }
  }
}
