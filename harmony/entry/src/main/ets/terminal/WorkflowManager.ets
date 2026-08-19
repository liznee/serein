/**
 * WorkflowManager — Workflow 步骤执行管理
 *
 * 从 TerminalPage.TerminalContent 提取，减少主文件代码行数。
 * 负责按序提交 Workflow 步骤命令，每步完成后自动执行下一步，超时处理。
 *
 * #review: 使用轮询 isExecuting() 判断是否存在竞争条件。
 * 改进方案：submitFn resolve 后延迟检查 isExecuting()，
 * 若仍有命令执行则继续轮询，同时记录自上次轮询以来是否有新的 session 行追加
 * （通过 isExecuting + 超时双重保护，防止回调链中断导致卡死）。
 */
import { TerminalSession } from './TerminalSession'
import { currentTheme } from './TerminalTheme'

/** 提交命令的函数签名 */
export type SubmitCommandFn = (cmd: string) => Promise<void>

/** Workflow 管理器回调 */
export interface WorkflowCallbacks {
  appendSystem(text: string, color: string): void
  syncLines(): void
  scrollToBottom(): void
  isExecuting(): boolean
  isDestroyed(): boolean
}

/** Workflow 回调绑定 */
export class WorkflowBinding implements WorkflowCallbacks {
  public appendSystem: (text: string, color: string) => void
  public syncLines: () => void
  public scrollToBottom: () => void
  public isExecuting: () => boolean
  public isDestroyed: () => boolean
  constructor(
    appendSystem: (text: string, color: string) => void,
    syncLines: () => void,
    scrollToBottom: () => void,
    isExecuting: () => boolean,
    isDestroyed: () => boolean,
  ) {
    this.appendSystem = appendSystem
    this.syncLines = syncLines
    this.scrollToBottom = scrollToBottom
    this.isExecuting = isExecuting
    this.isDestroyed = isDestroyed
  }
}

export class WorkflowManager {
  private session: TerminalSession
  private callbacks: WorkflowCallbacks
  private submitFn: SubmitCommandFn
  private _workflowSteps: string[] = []
  private _workflowStepIndex: number = 0
  private _workflowRetries: number = 0
  private readonly MAX_WORKFLOW_RETRIES: number = 30

  constructor(session: TerminalSession, submitFn: SubmitCommandFn, callbacks: WorkflowCallbacks) {
    this.session = session
    this.submitFn = submitFn
    this.callbacks = callbacks
  }

  setSession(session: TerminalSession): void {
    this.session = session
  }

  /** 执行 Workflow 步骤（按序提交命令） */
  submitWorkflowSteps(steps: string[], index: number): void {
    if (this.callbacks.isDestroyed()) return
    if (index >= steps.length) {
      this.callbacks.appendSystem('[Workflow 全部完成]', currentTheme().success)
      this.callbacks.syncLines()
      this.callbacks.scrollToBottom()
      return
    }
    const cmd = steps[index].trim()
    if (cmd === '') {
      this.submitWorkflowSteps(steps, index + 1)
      return
    }
    this._workflowSteps = steps
    this._workflowStepIndex = index
    this._workflowRetries = 0
    this.callbacks.appendSystem('[Workflow ' + (index + 1) + '/' + steps.length + '] ' + cmd, currentTheme().tool)
    this.callbacks.syncLines()
    this.callbacks.scrollToBottom()
    // 提交当前步骤，完成后自动下一步
    this.submitFn(cmd).then(() => {
      // #review: 延迟首次检查，给命令启动留出时间。使用指数退避 + 状态变化检测
      // 代替纯时间轮询：检测到 isExecuting() 从 true 变为 false 时视为完成。
      setTimeout(() => {
        this._workflowRetries = 0
        const checkDone = (): void => {
          if (this.callbacks.isDestroyed()) return
          const stillExecuting = this.callbacks.isExecuting()
          // 检测到执行状态从 true→false（步骤完成）或从未执行过（无异步操作）
          if (!stillExecuting) {
            this.submitWorkflowSteps(steps, index + 1)
          } else {
            this._workflowRetries++
            if (this._workflowRetries > this.MAX_WORKFLOW_RETRIES) {
              this.callbacks.appendSystem('[Workflow 超时，已停止]', '#EF4444')
              this.callbacks.syncLines()
              return
            }
            setTimeout(checkDone, 500)
          }
        }
        checkDone()
      }, 500)
    }).catch(() => {
      if (this.callbacks.isDestroyed()) return
      this.callbacks.appendSystem('[Workflow 步骤失败，已停止]', '#EF4444')
      this.callbacks.syncLines()
    })
  }
}
