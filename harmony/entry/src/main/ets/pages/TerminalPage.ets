﻿﻿﻿﻿﻿﻿import { http } from '@kit.NetworkKit'
import { promptAction } from '@kit.ArkUI'
import { common } from '@kit.AbilityKit'
import { pasteboard } from '@kit.BasicServicesKit'
import { TerminalSession, type TerminalLineData } from '../terminal/TerminalSession'
import type { VerbosityLevel } from '../terminal/TerminalSession'
import { TerminalBottomPanels } from '../terminal/TerminalBottomPanels'
import { type SlashCommandInfo } from '../terminal/SlashCommands'
import { currentTheme, currentFontSize, setTheme, setFontSize, type ThemeName } from '../terminal/TerminalTheme'
import { KEY_CLIENT_TOKEN } from '../state/AppStore'
import PrefStore, { agentDisplayName, normalizeAgentType, type Snippet } from '../store/PrefStore'
import { WebSocketClient, type WSEvent, WSConnectionState } from '../api/WebSocketClient'
import { TerminalCmdPoller } from '../terminal/TerminalCmdPoller'
import { TerminalCmdDispatcher } from '../terminal/TerminalCmdDispatcher'
import { ProjectDrawer } from '../terminal/ProjectDrawer'
import { TerminalEventHandler } from '../terminal/TerminalEventHandler'
import { desktopThreadCommand, KEY_CODEX_DESKTOP_LOADING, loadCodexDesktopLease,
  loadCodexDesktopThreads, saveCodexDesktopEvent } from '../model/CodexDesktopStore'
import { BACKEND_URL_KEY } from '../terminal/DeployConfig'
import { RelayManager } from '../terminal/RelayManager'
import { FileUploadManager } from '../terminal/FileUploadManager'
import { AiCommitManager } from '../terminal/AiCommitManager'
import { WorkflowManager, type SubmitCommandFn } from '../terminal/WorkflowManager'
import { TerminalBannerArea } from '../terminal/TerminalBannerArea'
import { TerminalHeaderBar } from '../terminal/TerminalHeaderBar'
import { TerminalOutputArea } from '../terminal/TerminalOutputArea'
import { TerminalEmptyState } from '../terminal/TerminalEmptyState'
import { TerminalSessionPersistence } from '../terminal/TerminalSessionPersistence'
import { CommandRouteType, TerminalCommandRouter, type RouteCallbacks } from '../terminal/TerminalCommandRouter'
import { TerminalComponentFactory } from '../terminal/TerminalComponentFactory'
import { AgentQuestionQueue } from '../model/AgentQuestionQueue'
import { CodexDesktopPanel } from '../terminal/CodexDesktopPanel'
import type { CodexDesktopLease, CodexDesktopThread } from '../model/CodexDesktopStore'
import { FEATURE_CODEX_DESKTOP } from '../config/ProductFeatures'

// ====== PhoneShell-inspired Neural Terminal — v4.2.0 ======

@Component
export struct TerminalContent {
  @State inputText: string = ''
  @State executing: boolean = false
  @State connected: boolean = false
  @State lines: TerminalLineData[] = []
  @State renderLines: TerminalLineData[] = []
  @State showProjectPicker: boolean = false
  @State projectList: string[] = []
  @State slashHints: SlashCommandInfo[] = []
  @State slashHintOverflow: boolean = false
  @State showHistory: boolean = false
  @State historyList: string[] = []
  @State showSnippets: boolean = false
  @State showWorkflow: boolean = false
  @State snippets: Snippet[] = []
  @State wsState: WSConnectionState = WSConnectionState.DISCONNECTED
  @State searchTerm: string = ''
  @State collapsed: number[] = []
  @State themeName: string = 'dark'
  @State uiTick: number = 0  // 主题/字号变更后 +1 强制重渲染
  @State terminalFontSize: number = 13
  @State verbosity: VerbosityLevel = 2
  @State selectedLineKey: string = ''
  @State selectedLineText: string = ''
  @State showBanner: boolean = true  // 启动横幅显示状态
  @State showDrawer: boolean = false
  @State backendIsHttp: boolean = false  // 后端 URL 非 HTTPS 时显示警告
  // relay 状态通过 RelayManager 内部跟踪，使用 /relay 命令查看
  @State destroyed: boolean = false  // 页面销毁标志，防止异步回调在 aboutToDisappear 后设置定时器
  private sessionMap: Map<string, TerminalSession> = new Map()
  private projectAgentTypes: Map<string, string> = new Map()
  /** 每个项目的 runtimeMode（cli/desktop），用于 ProjectDrawer 显示和切换 */
  private projectRuntimeModes: Map<string, string> = new Map()
  /** UI 绑定用：合并 agentType + runtimeMode → 'claude' | 'codex' | 'desktop' */
  @State projectAgentModes: Map<string, string> = new Map()
  /** #6 配合 sessionMap 记录插入顺序（ArkTS 兼容，避免直接迭代 Map） */
  private _sessionKeys: string[] = []
  private session: TerminalSession = new TerminalSession()
  private scroller: Scroller = new Scroller()
  @State userScrolledUp: boolean = false
  private backendUrl: string = ''
  private _lastSubmitText: string = ''
  private _lastSubmitAt: number = 0
  private _routeCallbacks: RouteCallbacks = null!
  private wsClient: WebSocketClient = new WebSocketClient()
  // 管理器字段 — 在 setupManagers() 中初始化（使用工厂减少主文件行数）
  private cmdPoller: TerminalCmdPoller = null!
  private wsEventHandler: TerminalEventHandler = null!
  private cmdDispatcher: TerminalCmdDispatcher = null!
  private relayManager: RelayManager = null!
  private fileUploadManager: FileUploadManager = null!
  private aiCommitManager: AiCommitManager = null!
  private workflowManager: WorkflowManager = null!
  private desktopRenewTimer: number = 0
  private desktopListTimeout: number = 0
  private desktopListRetryTimer: number = 0
  private desktopListAttempts: number = 0
  private desktopCloseAfterInterrupt: boolean = false
  // #13 防共享文字重复 toast：onSwitchedIn 和 onSharedTextChange 两路 @Watch 通过此标志互斥
  private _sharedTextProcessed: boolean = false
  // WS 首次连接标志：true 表示至少连接过一次（用于区分"已连接"和"已重连"）
  private _wsEverConnected: boolean = false
  /** #10 批量命令模式状态 */
  @State batchMode: boolean = false
  @State batchProjects: string[] = []
  @StorageLink('terminalProject') terminalProject: string = ''
  @StorageLink('terminalAgentType') agentType: string = 'claude'
  @StorageLink('terminalRuntimeMode') terminalRuntimeMode: string = 'cli'
  @StorageLink('switchToTerminal') @Watch('onSwitchedIn') switchIn: boolean = false
  @StorageLink('terminalActivationSeq') @Watch('onTerminalActivated') terminalActivationSeq: number = 0
  @StorageLink('terminalStartMsg') @Watch('onStartMsgChange') _startMsg: string = ''
  /** #8 分享文字：其他 App 选中的文字通过 Want 传递到终端自动发送 */
  @StorageLink('sharedCommandText') @Watch('onSharedTextChange') sharedCommandText: string = ''
  @StorageLink('openCodexDesktopPanel') @Watch('onDesktopPanelChanged') openCodexDesktopPanel: boolean = false
  @StorageLink('codexDesktopThreads') codexDesktopThreads: CodexDesktopThread[] = []
  @StorageLink('codexDesktopLoading') codexDesktopLoading: boolean = false
  @StorageLink('codexDesktopError') codexDesktopError: string = ''
  @StorageLink('codexDesktopStarting') codexDesktopStarting: boolean = false
  @StorageLink('codexDesktopRefreshSeq') @Watch('onDesktopRefreshRequested') codexDesktopRefreshSeq: number = 0
  @StorageLink('codexDesktopActive') codexDesktopActive: CodexDesktopLease | null = null
  @StorageLink('codexDesktopApproval') codexDesktopApproval: string = ''
  /** #9 远程命令历史（PC 端） */
  @State remoteHistoryList: string[] = []
  @State remoteHistoryLoading: boolean = false
  @State remoteHistoryError: string = ''

  /** 在 aboutToAppear 中用工厂创建所有管理器实例 */
  private setupManagers(): void {
    const cb = TerminalComponentFactory.makeCmdDispatchBinding(
      { getInputText: () => this.inputText,
        getShowHistory: () => this.showHistory,
        getLines: () => this.lines,
        getRenderLines: () => this.renderLines },
      { setInputText: (v: string) => { this.inputText = v },
        setSlashHints: (v: SlashCommandInfo[]) => { this.slashHints = v },
        setSlashHintOverflow: (v: boolean) => { this.slashHintOverflow = v },
        setShowHistory: (v: boolean) => { this.showHistory = v },
        setShowSnippets: (v: boolean) => { this.showSnippets = v },
        setSearchTerm: (v: string) => { this.searchTerm = v },
        setRenderLines: (v: TerminalLineData[]) => { this.renderLines = v },
        setHistoryList: (v: string[]) => { this.historyList = v },
        setRemoteHistoryList: (v: string[]) => { this.remoteHistoryList = v },
        setRemoteHistoryLoading: (v: boolean) => { this.remoteHistoryLoading = v },
        setRemoteHistoryError: (v: string) => { this.remoteHistoryError = v },
        setExecuting: (v: boolean) => { this.executing = v },
        setUserScrolledUp: (v: boolean) => { this.userScrolledUp = v },
        setSnippets: (v: Snippet[]) => { this.snippets = v } },
      { syncLines: () => { this.syncLines() }, scrollToBottom: () => { this.scrollToBottom() },
        computeRender: () => { this.computeRender() }, cycleTheme: () => { this.cycleTheme() },
        adjustFont: (d: number) => { this.adjustFont(d) }, submitCommand: (t: string) => { this.submitCommand(t) },
        saveHistory: () => this.saveHistory(), clearChatTimeout: () => { this.cmdDispatcher?.clearChatTimeout() } },
    )
    this.cmdPoller = new TerminalCmdPoller('', this.session,
      TerminalComponentFactory.makePollerCallbacks(this.session, {
        syncLines: () => { this.syncLines() }, scrollToBottom: () => { this.scrollToBottom() },
        setExecuting: (v: boolean) => { this.executing = v } },
      ))
this.wsEventHandler = TerminalComponentFactory.makeEventHandler(
this.session,
{ syncLines: () => { this.syncLines() }, scrollToBottom: () => { this.scrollToBottom() },
setExecuting: (v: boolean) => { this.executing = v },
clearChatTimeout: () => { this.cmdDispatcher?.clearChatTimeout() },
onDesktopEvent: (eventType: string, content: string): void => {
this.handleDesktopEvent(eventType, content)
} },
(cmdId: string, success: boolean, output: Record<string, Object>): void => {
this.fileUploadManager.handleFileUploadResult(cmdId, success, output) },
(data: Record<string, Object>): void => {
this.relayManager.handleHeartbeat(data)
this.updateAgentTypeFromDetails(data['details'] as Record<string, Object> | undefined) },
)
    this.wsEventHandler.setProject(this.terminalProject)
    this.cmdDispatcher = new TerminalCmdDispatcher(this.session, this.wsClient, this.cmdPoller, '', 'serein', cb)
    this.relayManager = TerminalComponentFactory.makeRelayManager(this.session,
      { appendSystem: (t: string, c: string) => { this.session.appendSystem(t, c) },
        syncLines: () => { this.syncLines() } },
      () => { const tok = AppStorage.get<string>(KEY_CLIENT_TOKEN) ?? ''
        this.wsClient.joinSession('', 'phone', this.terminalProject, tok) },
      (_v: string) => {}, () => this.destroyed)
    this.fileUploadManager = TerminalComponentFactory.makeFileUploadManager(this.session,
      { appendSystem: (t: string, c: string) => { this.session.appendSystem(t, c) },
        syncLines: () => { this.syncLines() }, appendError: (t: string) => { this.session.appendError(t) },
        submitCommand: (t: string) => { this.submitCommand(t) },
        dispatchPrompt: (t: string) => { this.dispatchPrompt(t) } }, () => this.destroyed)
    this.aiCommitManager = TerminalComponentFactory.makeAiCommitManager(
      this.session, this.wsClient,
      { appendSystem: (t: string, c: string) => { this.session.appendSystem(t, c) },
        syncLines: () => { this.syncLines() }, scrollToBottom: () => { this.scrollToBottom() },
        appendError: (t: string) => { this.session.appendError(t) },
        setExecuting: (v: boolean) => { this.executing = v } },
      async (message: string): Promise<boolean> => {
        return new Promise<boolean>((resolve) => {
          promptAction.showDialog({
            title: 'AI Commit 确认', message: message,
            buttons: [{ text: '取消', color: '#b53333' }, { text: '继续发送', color: currentTheme().success }],
          }).then((data: promptAction.ShowDialogSuccessResponse) => { resolve(data.index === 1) }).catch(() => { resolve(false) })
        }) },
      () => this.destroyed)
    this.workflowManager = TerminalComponentFactory.makeWorkflowManager(
      this.session, ((t: string) => this.submitCommand(t)) as SubmitCommandFn,
      { appendSystem: (t: string, c: string) => { this.session.appendSystem(t, c) },
        syncLines: () => { this.syncLines() }, scrollToBottom: () => { this.scrollToBottom() },
        getExecuting: () => this.executing }, () => this.destroyed)
  }

  private isDesktopRuntime(): boolean {
    return FEATURE_CODEX_DESKTOP &&
      (AppStorage.get<string>('terminalRuntimeMode') ?? this.terminalRuntimeMode) === 'desktop'
  }

  /** 桌面会话的内部控制命令不作为用户消息显示在终端。 */
  private sendDesktopControl(command: string): void {
    if (command === '') return
    if (command.startsWith('/desktop take ')) {
      this.codexDesktopLoading = true
      this.codexDesktopError = ''
      AppStorage.setOrCreate(KEY_CODEX_DESKTOP_LOADING, true)
      AppStorage.setOrCreate('codexDesktopError', '')
    }
    this.wsEventHandler.setLastSentText(command)
    this.cmdDispatcher.sendChatViaWS(command)
  }

  private onDesktopPanelChanged(): void {
    if (this.openCodexDesktopPanel && this.isDesktopRuntime() && !this.codexDesktopStarting) {
      setTimeout(() => {
        if (!this.destroyed && this.openCodexDesktopPanel) this.requestDesktopThreads(false)
      }, 50)
    }
  }

  /** The desktop relay has finished starting; begin discovery after its WS join. */
  private onDesktopRefreshRequested(): void {
    if (this.codexDesktopRefreshSeq <= 0 || !this.openCodexDesktopPanel || !this.isDesktopRuntime()) return
    setTimeout(() => {
      if (!this.destroyed && this.openCodexDesktopPanel && !this.codexDesktopStarting) {
        this.requestDesktopThreads(true)
      }
    }, 80)
  }

  /** Open the chooser once when entering a desktop Terminal without a lease. */
  private prepareDesktopSelectorOnEntry(): void {
    if (!this.isDesktopRuntime()) return
    const active = AppStorage.get<CodexDesktopLease>('codexDesktopActive') ?? null
    if (active !== null) return
    if (!this.openCodexDesktopPanel) {
      this.openCodexDesktopPanel = true
    } else if (!this.codexDesktopStarting) {
      this.requestDesktopThreads(false)
    }
  }

  private requestDesktopThreads(force: boolean = false): void {
    if (!this.isDesktopRuntime() || this.codexDesktopStarting) return
    if (!force && this.desktopListAttempts > 0 && this.codexDesktopLoading) return
    this.clearDesktopListTimeout()
    this.desktopListAttempts = 0
    this.codexDesktopLoading = true
    this.codexDesktopError = ''
    AppStorage.setOrCreate(KEY_CODEX_DESKTOP_LOADING, true)
    AppStorage.setOrCreate('codexDesktopError', '')
    this.sendDesktopListAttempt()
    this.desktopListTimeout = setTimeout(() => {
      this.desktopListTimeout = 0
      if (this.destroyed || !this.codexDesktopLoading) return
      if (this.desktopListRetryTimer !== 0) {
        clearTimeout(this.desktopListRetryTimer)
        this.desktopListRetryTimer = 0
      }
      this.desktopListAttempts = 0
      this.codexDesktopLoading = false
      AppStorage.setOrCreate(KEY_CODEX_DESKTOP_LOADING, false)
      if (this.codexDesktopThreads.length === 0) {
        this.codexDesktopError = '连接电脑端超时，请确认 relay 在线后重试。'
        AppStorage.setOrCreate('codexDesktopError', '连接电脑端超时，请确认 relay 在线后重试。')
      }
    }, 10000)
  }

  /** Retry only during the short process-spawn/relay-join window. */
  private sendDesktopListAttempt(): void {
    if (this.destroyed || !this.openCodexDesktopPanel || !this.isDesktopRuntime() ||
        this.codexDesktopStarting || !this.codexDesktopLoading) return
    this.desktopListAttempts++
    this.sendDesktopControl('/desktop list')
    if (this.desktopListAttempts >= 5) return
    const delay = 650 + this.desktopListAttempts * 450
    this.desktopListRetryTimer = setTimeout(() => {
      this.desktopListRetryTimer = 0
      if (!this.destroyed && this.openCodexDesktopPanel && this.codexDesktopLoading) {
        this.sendDesktopListAttempt()
      }
    }, delay)
  }

  private clearDesktopListTimeout(): void {
    if (this.desktopListTimeout !== 0) {
      clearTimeout(this.desktopListTimeout)
      this.desktopListTimeout = 0
    }
    if (this.desktopListRetryTimer !== 0) {
      clearTimeout(this.desktopListRetryTimer)
      this.desktopListRetryTimer = 0
    }
    this.desktopListAttempts = 0
  }

  private startDesktopRenewTimer(): void {
    this.clearDesktopRenewTimer()
    const active = AppStorage.get<CodexDesktopLease>('codexDesktopActive') ?? null
    if (!this.isDesktopRuntime() || active === null || active.leaseId === '') return
    this.desktopRenewTimer = setInterval(() => {
      if (this.destroyed || !this.isDesktopRuntime()) return
      const current = AppStorage.get<CodexDesktopLease>('codexDesktopActive') ?? null
      if (current !== null && current.leaseId !== '') {
        this.sendDesktopControl(desktopThreadCommand('renew', current.threadId, current.leaseId))
      }
    }, 15000)
  }

  private clearDesktopRenewTimer(): void {
    if (this.desktopRenewTimer !== 0) {
      clearInterval(this.desktopRenewTimer)
      this.desktopRenewTimer = 0
    }
  }

  private handleDesktopEvent(eventType: string, content: string): void {
    saveCodexDesktopEvent(this.terminalProject, eventType, content)
    if (eventType === 'desktop_thread_list' || eventType === 'desktop_error' ||
        eventType === 'desktop_thread_taken') {
      this.clearDesktopListTimeout()
    }
    if (eventType === 'desktop_thread_list') {
      // AppStorage object/list updates are not guaranteed to repaint an
      // already-mounted custom panel on every HarmonyOS build. Mirror the
      // canonical store value into the linked component state explicitly.
      this.codexDesktopThreads = loadCodexDesktopThreads()
      this.codexDesktopLoading = false
      this.codexDesktopError = ''
    } else if (eventType === 'desktop_thread_taken') {
      this.codexDesktopActive = loadCodexDesktopLease()
      this.codexDesktopLoading = false
      this.codexDesktopError = ''
      this.openCodexDesktopPanel = false
      this.executing = false
      setTimeout(() => { if (!this.destroyed) this.startDesktopRenewTimer() }, 80)
      promptAction.showToast({ message: '桌面会话已打开', duration: 1200 })
    } else if (eventType === 'desktop_turn_started') {
      this.executing = true
    } else if (eventType === 'desktop_lease_released') {
      this.clearDesktopRenewTimer()
      this.desktopCloseAfterInterrupt = false
      this.executing = false
      promptAction.showToast({ message: '桌面会话已关闭', duration: 1200 })
    } else if (eventType === 'desktop_turn_interrupted') {
      this.executing = false
      if (this.desktopCloseAfterInterrupt) {
        const active = AppStorage.get<CodexDesktopLease>('codexDesktopActive') ?? null
        if (active !== null) {
          this.sendDesktopControl(desktopThreadCommand('release', active.threadId, active.leaseId))
        }
      }
    } else if (eventType === 'desktop_approval_required') {
      this.executing = true
      promptAction.showToast({ message: 'Codex 需要你确认操作', duration: 1600 })
    } else if (eventType === 'desktop_approval_resolved') {
      this.executing = true
      promptAction.showToast({ message: '已提交选择', duration: 1000 })
    } else if (eventType === 'desktop_notification') {
      try {
        const raw = JSON.parse(content) as Record<string, Object>
        const method = (raw['method'] as string) ?? ''
        if (method === 'turn/started') this.executing = true
        if (method === 'turn/completed') this.executing = false
      } catch (_) {}
    } else if (eventType === 'desktop_error') {
      this.codexDesktopLoading = false
      this.codexDesktopError = AppStorage.get<string>('codexDesktopError') ?? ''
      this.desktopCloseAfterInterrupt = false
      this.executing = false
      let message = content
      try {
        const raw = JSON.parse(content) as Record<string, Object>
        message = (raw['error'] as string) ?? content
      } catch (_) {}
      if (message.indexOf('连接已过期') >= 0 || message.indexOf('重新打开') >= 0) {
        this.clearDesktopRenewTimer()
      }
      if (this.isDesktopRuntime() && this.codexDesktopActive === null) {
        this.openCodexDesktopPanel = true
      }
      promptAction.showToast({ message: message, duration: 2200 })
    }
  }

  /** 关闭手机当前打开的桌面会话；Thread 会留在 Codex 中供电脑端继续。 */
  private closeDesktopSession(): void {
    const active = AppStorage.get<CodexDesktopLease>('codexDesktopActive') ?? null
    if (active === null) {
      this.openCodexDesktopPanel = true
      return
    }
    if (active.turnId !== '') {
      this.desktopCloseAfterInterrupt = true
      this.sendDesktopControl(desktopThreadCommand('interrupt', active.threadId, active.leaseId, active.turnId))
      return
    }
    this.sendDesktopControl(desktopThreadCommand('release', active.threadId, active.leaseId))
  }

  private interruptDesktopTurn(): void {
    const active = AppStorage.get<CodexDesktopLease>('codexDesktopActive') ?? null
    if (active === null || active.turnId === '') return
    this.sendDesktopControl(desktopThreadCommand('interrupt', active.threadId, active.leaseId, active.turnId))
  }

  private desktopApprovalObject(): Record<string, Object> | undefined {
    if (this.codexDesktopApproval === '') return undefined
    try {
      return JSON.parse(this.codexDesktopApproval) as Record<string, Object>
    } catch (_) {
      return undefined
    }
  }

  private desktopApprovalSupported(): boolean {
    const raw = this.desktopApprovalObject()
    const method = (raw?.['method'] as string) ?? ''
    return method === 'item/commandExecution/requestApproval'
      || method === 'item/fileChange/requestApproval'
      || method === 'execCommandApproval' || method === 'applyPatchApproval'
  }

  private desktopApprovalSummary(): string {
    const raw = this.desktopApprovalObject()
    if (!raw) return 'Codex 需要你确认一项操作'
    const method = (raw['method'] as string) ?? ''
    const params = raw['params'] as Record<string, Object> | undefined
    let detail = (params?.['reason'] as string) ?? (params?.['command'] as string) ?? ''
    if (detail === '' && params?.['command'] !== undefined) {
      try { detail = JSON.stringify(params['command']) } catch (_) {}
    }
    const label = method.indexOf('fileChange') >= 0 || method === 'applyPatchApproval'
      ? '修改项目文件' : method.indexOf('command') >= 0 || method === 'execCommandApproval'
        ? '执行命令' : '请求额外权限'
    if (detail.length > 180) detail = detail.substring(0, 180) + '…'
    return detail !== '' ? label + '：' + detail : label
  }

  private respondDesktopApproval(decision: string): void {
    const active = AppStorage.get<CodexDesktopLease>('codexDesktopActive') ?? null
    const raw = this.desktopApprovalObject()
    if (active === null || !raw || !this.desktopApprovalSupported()) return
    const rawId = raw['requestId']
    const requestId = rawId === undefined || rawId === null ? '' : '' + rawId
    if (requestId === '') return
    this.sendDesktopControl(desktopThreadCommand(
      'approve', active.threadId, active.leaseId, requestId + ' ' + decision,
    ))
  }

  private submitDesktopPrompt(text: string): void {
    const active = AppStorage.get<CodexDesktopLease>('codexDesktopActive') ?? null
    if (active === null || active.leaseId === '') {
      this.executing = false
      this.openCodexDesktopPanel = true
      promptAction.showToast({ message: '请先选择一个桌面会话', duration: 1600 })
      return
    }
    if (active.turnId !== '') {
      this.executing = true
      promptAction.showToast({ message: '当前回答还没有完成', duration: 1400 })
      return
    }
    this.session.addToHistory(text)
    this.session.startBlock()
    this.session.appendPrompt(text)
    this.inputText = ''
    this.executing = true
    this.userScrolledUp = false
    this.syncLines()
    this.scrollToBottom()
    const command = desktopThreadCommand('send', active.threadId, active.leaseId, text)
    this.sendDesktopControl(command)
    this.saveHistory().catch((e: Error) => {
      console.warn('[serein] save desktop history failed: ' + e.message)
    })
  }

  aboutToAppear(): void {
    this.destroyed = false
    this.setupManagers()
    this._routeCallbacks = {
      setInputText: (v: string) => { this.inputText = v },
      setShowWorkflow: (v: boolean) => { this.showWorkflow = v },
      setBatchMode: (v: boolean) => { this.batchMode = v },
      setBatchProjects: (v: string[]) => { this.batchProjects = v },
      setExecuting: (v: boolean) => { this.executing = v },
      appendSystem: (msg: string, color: string) => { this.session.appendSystem(msg, color) },
      appendError: (msg: string) => { this.session.appendError(msg) },
      syncLines: () => { this.syncLines() },
      scrollToBottom: () => { this.scrollToBottom() },
      handleNLCommand: (text: string) => { this.handleNLCommand(text) },
      handleBatchSubmit: async (cmd: string) => {
        await this.handleBatchSubmit(cmd).catch((e: Error) => {
          this.session.appendError('[Batch] ' + e.message)
          this.executing = false; this.batchMode = false; this.batchProjects = []
          this.syncLines()
        })},
      handleAiCommitRoute: () => { this.handleAiCommitRoute() },
      submitAndDispatch: async (tt: string) => {
        await this.cmdDispatcher.submitAndDispatch(tt)
      },
      getRelayStatus: () => this.relayManager.relayStatus,
      startRelay: () => { this.relayManager.startRelay() },
      execBatchToggle: () => {
        this.inputText = ''
        this.batchMode = !this.batchMode
        if (this.batchMode) {
          this.session.appendSystem('[Batch] 已进入批量模式，选择项目（点击项目名切换选中），输入命令后提交', currentTheme().tool)
          this.session.appendSystem('[Batch] 已选项目: (' + this.batchProjects.length + ') ' + (this.batchProjects.length > 0 ? this.batchProjects.join(', ') : '无'), '#A1A1AA')
          this.syncLines(); this.scrollToBottom()
        } else {
          this.batchProjects = []
          this.session.appendSystem('[Batch] 已退出批量模式', '#A1A1AA')
          this.syncLines()
        }
      },
    }
    this.initBackendUrl()
    this.relayManager.setBackendUrl(this.backendUrl)
    this.relayManager.setSession(this.session)
    this.relayManager.setProject(this.terminalProject)
    this.fileUploadManager.setBackendUrl(this.backendUrl)
    this.fileUploadManager.setProject(this.terminalProject)
    this.fileUploadManager.setContext(getContext(this) as common.Context)
    this.aiCommitManager.setBackendUrl(this.backendUrl)
    this.aiCommitManager.setProject(this.terminalProject)
    this.handlePendingSharedText()
    AppStorage.setOrCreate('terminalStartMsg', '')
    this.loadProjects()
    this.checkConnection()
    this.loadTerminalPrefs()
    this.session = this.getSession(this.terminalProject)
    this.cmdPoller.setBackendUrl(this.backendUrl)
    this.cmdPoller.setBackendIsHttp(this.backendIsHttp)
    this.cmdPoller.setSession(this.session)
    this.wsEventHandler.setSession(this.session)
    this.wsEventHandler.setProject(this.terminalProject)
    this.cmdDispatcher.setSession(this.session)
    this.cmdDispatcher.setBackendUrl(this.backendUrl)
    this.cmdDispatcher.setBackendIsHttp(this.backendIsHttp)
    this.cmdDispatcher.setTerminalProject(this.terminalProject)
    this.syncLines()
    if (this.isDesktopRuntime()) {
      setTimeout(() => {
        if (!this.destroyed) {
          this.startDesktopRenewTimer()
          this.prepareDesktopSelectorOnEntry()
        }
      }, 250)
    }
    // 始终注册 WS 事件处理器（连接延迟到有选中项目时建立），
    // 防止首次启动无项目时跳过注册 → selectProject 调 joinSession 无 handler
    // 有选中项目时才恢复会话 + relay 检查
    // 注意：先恢复持久化再初始化 WS，防止 restore 与 WS 实时推送产生竞态覆盖
    if (this.terminalProject !== '') {
      this.restoreCurrentSession().then(() => {
        // 恢复完成后才注册 WS 事件处理器并连接，
        // 确保 restore 设置的 session.lines 不会被 WS 实时推送覆盖
        this.initWebSocketEvents()
        // 先重置为 checking 再检查，避免旧 online 状态 + HTTP 暂未更新
        // 导致的误报 "[Relay] 已断开"（和 selectProject 一致）
        this.relayManager.resetStatus('checking')
        this.relayManager.checkRelayStatus()
      })
    } else {
      // 无项目时提前注册 WS 处理器（selectProject 中 connect 后 handler 必须可用）
      this.initWebSocketEvents()
    }
  }

  /** 初始化后端地址并检查连接安全性 */
  private initBackendUrl(): void {
    const url = AppStorage.get<string>(BACKEND_URL_KEY)
    this.backendUrl = (url !== undefined && url !== null && url.length > 0) ? url : ''
    this.backendIsHttp = this.backendUrl !== '' && !this.backendUrl.startsWith('https://')
    if (this.backendIsHttp) {
      // 非 HTTPS 时弹出确认对话框，用户可取消连接
      promptAction.showDialog({
        title: '不安全连接',
        message: '后端连接非 HTTPS，通信将不加密，Token 和命令可能被截获。是否继续？',
        buttons: [
          { text: '取消连接', color: '#b53333' },
          { text: '继续（不安全）', color: currentTheme().warning },
        ],
      }).then((data: promptAction.ShowDialogSuccessResponse) => {
        if (data.index === 0) {
          // 用户取消：清空后端地址，断开连接
          this.backendUrl = ''
          this.backendIsHttp = false
          this.session.appendSystem('[安全] 已取消不安全连接，请在设置中配置 HTTPS 后端地址', '#b53333')
          this.syncLines()
        } else {
          // HTTP 模式下禁用 WebSocket（Token 不会通过明文网络传输），仅使用 HTTP 轮询
          this.session.appendSystem('[安全] HTTP 模式下 WebSocket 已禁用，Token 不会通过明文网络传输', currentTheme().warning)
          this.syncLines()
        }
      }).catch(() => {
        // dialog 异常时保守处理：视为用户取消
        this.backendUrl = ''
        this.backendIsHttp = false
      })
    }
    // 不自动选项目——用户通过 ☰ Drawer 或左右滑动手动选择
  }

  /** 处理冷启动/PIN锁屏时错过的分享文字 — @Watch 在首次创建时不触发 */
  private handlePendingSharedText(): void {
    const pendingText = AppStorage.get<string>('sharedCommandText') ?? ''
    if (pendingText !== '') {
      AppStorage.setOrCreate('sharedCommandText', '')
      this._sharedTextProcessed = true
      this.inputText = pendingText
      promptAction.showToast({ message: '已接收分享文字，点击发送按钮发送', duration: 2000 })
    }
  }

  /** 初始化 WS 事件监听和连接 */
  private initWebSocketEvents(): void {
    if (this.backendUrl === '') {
      console.warn('serein: backendUrl 为空，跳过 WS 连接')
      return
    }
    // HTTPS 警告对话框未完成前不擅自连接
    if (this.backendIsHttp) {
      console.warn('serein: HTTP backend — WebSocket disabled, using HTTP polling only')
      return
    }
    this.wsClient.setOnEvent((evt: WSEvent) => {
      this.wsEventHandler.handleEvent(evt)
      // 检测 start/stop cmd_result：即时切换 relay 状态
      if (evt.type === 'cmd_result' || evt.type === 'result') {
        const d = (evt.data ?? evt.payload) as Record<string, Object> | undefined
        if (d) {
          const action = (d['action'] as string) ?? ''
          const success = (d['success'] as boolean) ?? false
          if (action === 'stop') {
            this.relayManager.forceOffline()
            this.syncLines()
          } else if (action === 'start' && success) {
            this.relayManager.forceOnline()
            this.syncLines()
            this.scrollToBottom()
          }
        }
      }
    })
this.wsClient.setOnOpen(() => {
const tok = AppStorage.get<string>(KEY_CLIENT_TOKEN) ?? ''
const proj = this.terminalProject
if (proj !== '') {
this.wsClient.joinSession('', 'phone', proj, tok)
}
// WS 重连后发送排队的消息
this.cmdDispatcher.flushPendingChat()
})
    this.wsClient.setOnStateChange((state: WSConnectionState) => {
      this.wsState = state
      if (state === WSConnectionState.CONNECTED) {
        if (this._wsEverConnected) {
          // 重连：静默恢复，不清屏不显示消息
          // 用户不需要知道重连细节，只需继续对话
          this.wsEventHandler.setSkipHistory(true)
        } else {
          this._wsEverConnected = true
          // 调试阶段：不显示「WS已连接」提示，仅异常时才提示用户
        }
        // WS 连接成功说明 relay 已运行，立即刷新 relay 状态为 online
        this.relayManager.forceOnline()
        this.syncLines()
        this.scrollToBottom()
      } else if (state === WSConnectionState.RECONNECTING || state === WSConnectionState.DISCONNECTED) {
        // WS 断连：relay 可能已停止，立即标记为 offline
        this.relayManager.forceOffline()
        this.syncLines()
      }
    })
    // 仅在已有选中项目时自动连接（无项目时等 selectProject 触发 connect）
    if (this.terminalProject !== '') {
      this.wsClient.connect(this.backendUrl)
    }
  }

  aboutToDisappear(): void {
    this.destroyed = true
    this.clearDesktopRenewTimer()
    this.clearDesktopListTimeout()
    this.cmdPoller.abort()
    this.cmdDispatcher.dispose()
    this.wsClient.destroy()
    this.relayManager.clearTimers()
    this.fileUploadManager.clearTimers()
    // 同步结束 thinking 块，防止异步 saveCurrentSession 中变异
    // _thinkingLineIdx 被 fire-and-forget 调用导致竞态（页面销毁后
    // session 被复用时 thinking 状态丢失）。
    const sess = this.sessionMap.get(this.terminalProject)
    if (sess) { sess.endThinkingIfActive() }
    // 切换 tab/页面销毁前持久化当前会话（fire-and-forget，页面销毁后不等待完成）
    this.saveCurrentSession().catch((e: Error) => {
      console.error('serein: aboutToDisappear 保存会话失败: ' + e.message)
    })
  }

  /** 载入主题 + 字号 + 片段 + 显示分级 */
  private async loadTerminalPrefs(): Promise<void> {
    try {
      const th = await PrefStore.loadTheme()
      setTheme(th as ThemeName)
      this.themeName = th
      const fs = await PrefStore.loadFontSize()
      setFontSize(fs)
      this.terminalFontSize = currentFontSize()
      this.snippets = await PrefStore.loadSnippets()
      // 顶部“详细/摘要/极简”入口已移除，终端固定展示完整输出。
      this.verbosity = 2
      this.uiTick++
    } catch (e) {
      console.error('serein: 载入终端偏好失败: ' + (e as Error).message)
    }
  }

  /** 当前项目名（展示于 banner，非文件系统路径）*/
  private currentProjectName(): string {
    return this.terminalProject
  }

  /** 取/建某项目的会话（多会话：每项目独立上下文） */
  /** #6 sessionMap 清理：map 超过上限时移除最旧会话，防内存泄漏 */
  private getSession(proj: string): TerminalSession {
    let s = this.sessionMap.get(proj)
    if (s === undefined) {
      s = new TerminalSession()
      s.hasBanner = true
      s.bannerProject = proj
      this.showBanner = true
      this.sessionMap.set(proj, s)
      this._sessionKeys.push(proj)
      this.trimSessions()
    }
    return s
  }

  /** #6 限制 sessionMap 大小，移除最旧（_sessionKeys 按插入顺序）的条目。
   *  先对 _sessionKeys 去重防止重复 key 导致膨胀，再确保总数不超过 MAX。 */
  private trimSessions(): void {
    const MAX = 20
    if (this._sessionKeys.length <= MAX) return

    // 第一步：去重（同一项目可能因历史 bug 重复出现）
    const unique: string[] = []
    for (let i = 0; i < this._sessionKeys.length; i++) {
      const k = this._sessionKeys[i]
      if (unique.indexOf(k) < 0) unique.push(k)
    }
    if (unique.length <= MAX) {
      this._sessionKeys = unique
      return
    }

    // 第二步：删除最旧的（非当前项目）直到不超过 MAX
    const removeCount = unique.length - MAX
    const current = this.terminalProject
    const remaining: string[] = []
    let removed = 0
    for (let i = 0; i < unique.length; i++) {
      const key = unique[i]
      if (removed < removeCount && key !== current) {
        this.sessionMap.delete(key)
        removed++
      } else {
        remaining.push(key)
      }
    }
    this._sessionKeys = remaining
  }

  /** 从 PrefStore 载入该项目的持久化命令历史 */
  private async loadHistoryInto(proj: string, s: TerminalSession): Promise<void> {
    await TerminalSessionPersistence.loadHistoryInto(proj, s)
  }

  /** 保存当前会话命令历史 */
  private async saveHistory(): Promise<void> {
    await TerminalSessionPersistence.saveHistory(this.terminalProject, this.sessionMap.get(this.terminalProject))
  }

  /** 持久化当前项目的终端会话（行内容 + 状态） */
  private async saveCurrentSession(): Promise<void> {
    await TerminalSessionPersistence.saveCurrentSession(
      this.terminalProject, this.sessionMap.get(this.terminalProject))
  }

  /** 从持久化恢复当前项目的终端会话 */
  private async restoreCurrentSession(): Promise<void> {
    // 不再从持久化恢复旧会话内容：每次打开终端都是新会话，
    // 避免重连后手机端显示大量旧内容造成混乱
    // 仅清空持久化的旧会话数据
    const proj = this.terminalProject
    await TerminalSessionPersistence.clearSessionData(proj)
  }

  onSwitchedIn(): void {
    if (this.switchIn) {
      this.activateTerminalContext()
      AppStorage.setOrCreate('switchToTerminal', false)
    }
  }

  /** 用户直接点击“终端”Tab 时也刷新上下文，避免标题停留在上一个 Agent。 */
  onTerminalActivated(): void {
    if (this.terminalActivationSeq > 0) this.activateTerminalContext()
  }

  private activateTerminalContext(): void {
    // 直接从 AppStorage 读取最新项目名和 Agent，避开 @StorageLink 的传播时序。
    const proj: string = AppStorage.get<string>('terminalProject') ?? ''
    if (proj !== '') { this.terminalProject = proj }
    const requestedType = AppStorage.get<string>('terminalAgentType') ?? 'claude'
    this.agentType = normalizeAgentType(requestedType)
    this.terminalRuntimeMode = FEATURE_CODEX_DESKTOP
      ? (AppStorage.get<string>('terminalRuntimeMode') ?? 'cli') : 'cli'
    AppStorage.setOrCreate('terminalRuntimeMode', this.terminalRuntimeMode)
    AppStorage.setOrCreate('terminalAgentType', this.agentType)
    // 同步 RelayManager 的 agent 类型
    this.relayManager.setAgentType(this.agentType)
    this.relayManager.setRuntimeMode(this.terminalRuntimeMode)
    this.selectedLineKey = ''
    this.selectedLineText = ''
    // 同步所有管理器的项目名——用户可能从 ProjectsPage 点了不同项目的 Start。
    this.fileUploadManager.setProject(proj)
    this.aiCommitManager.setProject(proj)
    this.cmdDispatcher.setTerminalProject(proj)
    this.relayManager.setProject(proj)
    this.session = this.getSession(proj)
    this.wsEventHandler.setSession(this.session)
    this.wsEventHandler.setProject(proj)
    this.cmdDispatcher.setSession(this.session)
    this.cmdPoller.setSession(this.session)
    this.relayManager.setSession(this.session)
    this.fileUploadManager.setSession(this.session)
    this.aiCommitManager.setSession(this.session)
    this.workflowManager.setSession(this.session)
    this.checkStartMsg()
    this.checkConnection()
    this.loadProjects()
    // 切 tab 回来时强制重新检查 relay 状态（可能在 ProjectsPage 点了 Stop）。
    this.relayManager.resetStatus('checking')
    this.relayManager.checkRelayStatus()
    // TerminalContent keeps one long-lived phone WebSocket across tabs. When
    // ProjectsPage switches the selected project, update the backend
    // subscription immediately; otherwise desktop replies are published to
    // the new project while the phone is still listening to the old one.
    if (proj !== '') {
      if (this.wsClient.connected) {
        const tok = AppStorage.get<string>(KEY_CLIENT_TOKEN) ?? ''
        this.wsClient.joinSession('', 'phone', proj, tok)
        this.cmdDispatcher.flushPendingChat()
      } else if (this.backendUrl !== '' && !this.backendIsHttp) {
        // TerminalContent may have been mounted while no project was selected,
        // so initWebSocketEvents intentionally skipped connect(). Starting a
        // project from ProjectsPage must establish that first connection here;
        // onOpen joins the freshly selected project and flushes /desktop list.
        this.wsClient.connect(this.backendUrl)
      }
    }
    if (this.isDesktopRuntime()) {
      setTimeout(() => {
        if (!this.destroyed) {
          this.startDesktopRenewTimer()
          this.prepareDesktopSelectorOnEntry()
        }
      }, 60)
    } else {
      this.clearDesktopRenewTimer()
    }
    // 二次保险：切换标签页时检查待处理分享文字。
    if (!this._sharedTextProcessed) {
      const shared = AppStorage.get<string>('sharedCommandText') ?? ''
      if (shared !== '') {
        AppStorage.setOrCreate('sharedCommandText', '')
        this._sharedTextProcessed = true
        this.inputText = shared
        promptAction.showToast({ message: '已接收分享文字，点击发送按钮发送', duration: 2000 })
      }
    }
  }

  onStartMsgChange(): void {
    if (this._startMsg !== '') {
      // 如果最后一条是 "Agent: Starting agent for..." 占位消息，替换它而非追加，
      // 避免终端里同时留 "Starting..." 和 "✅已激活" 两条
      const lines = this.session.lines
      const lastIdx = lines.length - 1
      if (lastIdx >= 0 && lines[lastIdx].kind === 'system'
          && lines[lastIdx].text.startsWith('Starting agent for ')) {
        // 替换占位消息为最终结果（不可变操作：用 slice 代替 splice 避免直接突变 session.lines）
        this.session.lines = lines.slice(0, lastIdx)
      }
      this.session.appendSystem('Agent: ' + this._startMsg, currentTheme().tool)
      AppStorage.setOrCreate('terminalStartMsg', '')
      this.syncLines()
      this.scrollToBottom()
    }
  }

  /** #8 分享文字：其他 App 选中文字分享到 serein — 预填到输入框，等待用户手动发送 */
  /** #13 与 onSwitchedIn 通过 _sharedTextProcessed 标志互斥防重复 toast */
  private onSharedTextChange(): void {
    const text = this.sharedCommandText
    if (text === '') {
      // 清空标志表示 reset，下次新分享文字到来时重新允许处理
      this._sharedTextProcessed = false
      return
    }
    // 立即清空标志，防止重复触发
    AppStorage.setOrCreate('sharedCommandText', '')
    if (this.inputText === text || this._sharedTextProcessed) {
      // 内容相同不重复处理，或已由 onSwitchedIn/onAboutToAppear 处理过
      return
    }
    this._sharedTextProcessed = true
    // 安全：预填到输入框，不自动提交（防止三方 App 命令注入）
    this.inputText = text
    promptAction.showToast({ message: '已接收分享文字，点击发送按钮发送', duration: 2000 })
  }

  private syncLines(): void {
    this.lines = this.session.lines.concat([])
    this.computeRender()
  }

  /** 计算可见行：verbosity 过滤 → 折叠 block → 搜索过滤 */
  private computeRender(): void {
    this.renderLines = TerminalComponentFactory.computeRenderLines(
      this.lines, this.verbosity, this.searchTerm, this.collapsed)
  }

  private toggleCollapse(blockId: number): void {
    const idx = this.collapsed.indexOf(blockId)
    if (idx >= 0) {
      this.collapsed = this.collapsed.filter((_, i) => i !== idx)
    } else {
      this.collapsed = this.collapsed.concat([blockId])
    }
    this.computeRender()
  }

async loadProjects(): Promise<void> {
// 先加载本地项目
const localNames: string[] = []
try {
const s = await PrefStore.loadAll()
for (let i = 0; i < s.projects.length; i++) {
localNames.push(s.projects[i].name)
this.projectAgentTypes.set(s.projects[i].name, normalizeAgentType(s.projects[i].agentType))
const rm = s.projects[i].runtimeMode
this.projectRuntimeModes.set(s.projects[i].name,
  FEATURE_CODEX_DESKTOP && rm === 'desktop' ? 'desktop' : 'cli')
}
const configuredType = this.projectAgentTypes.get(this.terminalProject)
if (configuredType) {
this.agentType = configuredType
AppStorage.setOrCreate('terminalAgentType', this.agentType)
}
// 同步当前项目的 runtimeMode
const configuredRm = this.projectRuntimeModes.get(this.terminalProject)
if (configuredRm) {
this.terminalRuntimeMode = configuredRm
AppStorage.setOrCreate('terminalRuntimeMode', configuredRm)
}
this.rebuildAgentModes()
} catch (_e) {
localNames.push('serein')
this.projectAgentTypes.set('serein', 'claude')
this.projectRuntimeModes.set('serein', 'cli')
}
// 再从后端获取运行中的项目列表，合并去重
const merged: string[] = localNames.concat([])
try {
const token = AppStorage.get<string>(KEY_CLIENT_TOKEN) ?? ''
const hc = http.createHttp()
const hdr: Record<string, string> = {}
if (token !== '') hdr['Authorization'] = 'Bearer ' + token
const r = await hc.request(this.backendUrl + '/agent/projects', {
method: http.RequestMethod.GET,
header: hdr,
connectTimeout: 3000,
readTimeout: 3000,
})
hc.destroy()
if (r.responseCode === 200) {
const data = JSON.parse(r.result as string) as Record<string, Object>
// running 是当前正在运行的项目列表
const running = data['running'] as string[] ?? []
for (let i = 0; i < running.length; i++) {
if (merged.indexOf(running[i]) < 0) {
merged.push(running[i])
}
}
this.updateAgentTypeFromDetails(data['details'] as Record<string, Object> | undefined)
// projects 是项目名→路径映射
const projects = data['projects'] as Record<string, Object> | undefined
if (projects) {
const keys = Object.keys(projects)
for (let i = 0; i < keys.length; i++) {
if (merged.indexOf(keys[i]) < 0) {
merged.push(keys[i])
}
if (!this.projectAgentTypes.has(keys[i])) this.projectAgentTypes.set(keys[i], 'claude')
if (!this.projectRuntimeModes.has(keys[i])) this.projectRuntimeModes.set(keys[i], 'cli')
}
}
}
} catch (_e) {
// 后端不可达时仅使用本地项目列表
}
// 过滤掉用户已隐藏（删除）的远程项目；本地配置项目必须始终保留。
// 首页也会优先展示本地配置，因此不能让旧的 hidden_projects 记录把
// 已重新添加的 test1 等项目从终端抽屉里再次隐藏。
let hidden: string[] = []
try { hidden = await PrefStore.loadHiddenProjects() } catch (_e) {}
const filtered = hidden.length > 0
  ? merged.filter((n: string) => localNames.indexOf(n) >= 0 || hidden.indexOf(n) < 0)
  : merged
this.projectList = filtered
this.rebuildAgentModes()
}

/** 重建 projectAgentModes（UI 绑定用），合并 agentType + runtimeMode */
private rebuildAgentModes(): void {
const m = new Map<string, string>()
for (let i = 0; i < this.projectList.length; i++) {
const name = this.projectList[i]
const rm = this.projectRuntimeModes.get(name)
if (rm === 'desktop') {
m.set(name, 'desktop')
} else {
m.set(name, normalizeAgentType(this.projectAgentTypes.get(name)))
}
}
this.projectAgentModes = m
}

/**
 * 用户在 ProjectDrawer 里切换 agent 模式
 * mode: 'claude' | 'codex' | 'desktop'
 * 临时覆盖当前项目的 agent 类型，同时写回 PrefStore 持久化
 */
private async selectAgentMode(projectName: string, mode: string): Promise<void> {
let agentType = 'claude'
let runtimeMode = 'cli'
if (mode === 'codex') {
agentType = 'codex'
runtimeMode = 'cli'
} else if (mode === 'desktop') {
agentType = 'codex'
runtimeMode = 'desktop'
} else {
agentType = 'claude'
runtimeMode = 'cli'
}
this.projectAgentTypes.set(projectName, agentType)
this.projectRuntimeModes.set(projectName, runtimeMode)
this.rebuildAgentModes()

// 持久化到 PrefStore
try {
const snapshot = await PrefStore.loadAll()
const backendUrl = snapshot.backendUrl
await PrefStore.updateProjectAgentType(projectName, agentType, backendUrl)
await PrefStore.updateProjectRuntimeMode(projectName, runtimeMode, backendUrl)
} catch (e) {
console.warn('selectAgentMode persist failed: ' + (e as Error).message)
}

// 如果切换的是当前项目，实时更新终端状态并重启 relay
if (projectName === this.terminalProject) {
this.agentType = normalizeAgentType(agentType)
this.terminalRuntimeMode = runtimeMode
AppStorage.setOrCreate('terminalAgentType', this.agentType)
AppStorage.setOrCreate('terminalRuntimeMode', runtimeMode)
// 同步 RelayManager 的 agent 类型，确保 startRelay 发送正确的 agent_type
this.relayManager.setAgentType(this.agentType)
this.relayManager.setRuntimeMode(runtimeMode)
// 更新 env 标记
const lines = this.session.lines
const lastIdx = lines.length - 1
const envLabel = '> env: ' + projectName + ' · ' + this.currentModeLabel()
const alreadyShown = lastIdx >= 0 && lines[lastIdx].text === envLabel && lines[lastIdx].kind === 'system'
if (!alreadyShown) {
this.session.appendSystem(envLabel, currentTheme().result)
this.syncLines()
this.scrollToBottom()
}
// 触发 relay 重启：先停旧 agent，再启新 agent
this.restartRelayForAgentSwitch()
}
}

/**
 * 项目抽屉的显式启动入口。
 *
 * 不能把“点项目”当作切换终端；必须由用户在展开的三种方式中选择一项后，
 * 才先选中项目、再按该方式启动。这里保留原有 selectProject / selectAgentMode
 * 的状态收敛和 relay 重启逻辑，避免再出现两套启动流程。
 */
private launchProjectWithMode(projectName: string, mode: string): void {
  this.selectProject(projectName)
  void this.selectAgentMode(projectName, mode)
}

/**
 * 切换 agent 类型后重启 relay：
 * 1. 如果 relay 在线，先发 stop 命令停止当前 agent 进程
 * 2. 等待 1.5s 让后端清理
 * 3. 设置 Desktop 模式的 AppStorage 状态（如果切换到 desktop）
 * 4. 调用 startRelay 启动新 agent
 */
private async restartRelayForAgentSwitch(): Promise<void> {
const wasOnline = this.relayManager.relayStatus === 'online'
const modeLabel = this.currentModeLabel()
this.session.appendSystem('> switching to ' + modeLabel + ' ...', currentTheme().tool)
this.syncLines()
this.scrollToBottom()
if (wasOnline) {
this.session.appendSystem('[Relay] 停止当前 agent ...', currentTheme().tool)
this.syncLines()
await this.relayManager.stopRelay()
// 等待后端清理旧进程
await new Promise<void>((resolve: () => void) => { setTimeout(resolve, 1500) })
}
// Desktop 模式：设置 AppStorage 状态，弹出会话选择面板
if (this.terminalRuntimeMode === 'desktop') {
AppStorage.setOrCreate('codexDesktopProject', this.terminalProject)
AppStorage.setOrCreate('codexDesktopThreads', [])
AppStorage.setOrCreate('codexDesktopError', '')
AppStorage.setOrCreate('codexDesktopLoading', true)
AppStorage.setOrCreate('codexDesktopStarting', true)
AppStorage.setOrCreate('openCodexDesktopPanel', true)
} else {
AppStorage.setOrCreate('codexDesktopStarting', false)
AppStorage.setOrCreate('openCodexDesktopPanel', false)
}
// 设置启动消息（onStartMsgChange 会替换占位消息）
AppStorage.setOrCreate('terminalStartMsg',
this.terminalRuntimeMode === 'desktop'
? '正在连接 Codex 桌面会话 · ' + this.terminalProject + '...'
: '正在启动 ' + modeLabel + ' · ' + this.terminalProject + '...')
this.session.appendSystem('[Relay] 启动 ' + modeLabel + ' ...', currentTheme().tool)
this.syncLines()
this.relayManager.resetStatus('checking')
this.relayManager.startRelay()
}

/** 当前项目的模式显示文字（供 env 标记用） */
private currentModeLabel(): string {
if (this.terminalRuntimeMode === 'desktop') return 'Codex Desktop'
return agentDisplayName(this.agentType)
}

private updateAgentTypeFromDetails(details: Record<string, Object> | undefined): void {
if (!details || this.terminalProject === '') return
const detail = details[this.terminalProject] as Record<string, Object> | undefined
if (!detail) return
const rawType = (detail['agent_type'] as string) ?? ''
if (rawType !== 'claude' && rawType !== 'codex') return
const actualType = normalizeAgentType(rawType)
this.projectAgentTypes.set(this.terminalProject, actualType)
this.agentType = actualType
AppStorage.setOrCreate('terminalAgentType', actualType)
}

  selectProject(name: string): void {
    this.terminalProject = name
    AppStorage.setOrCreate('terminalProject', name)
    this.agentType = normalizeAgentType(this.projectAgentTypes.get(name))
    AppStorage.setOrCreate('terminalAgentType', this.agentType)
    // 同步当前项目的 runtimeMode
    const rm = this.projectRuntimeModes.get(name) ?? 'cli'
    this.terminalRuntimeMode = rm
    AppStorage.setOrCreate('terminalRuntimeMode', rm)
    // 同步 RelayManager 的 agent 类型
    this.relayManager.setAgentType(this.agentType)
    this.relayManager.setRuntimeMode(rm)
    this.selectedLineKey = ''
    this.selectedLineText = ''
    this.showProjectPicker = false
    this.session = this.getSession(name)
    this.wsEventHandler.setSession(this.session)
    this.wsEventHandler.setProject(name)
    this.cmdDispatcher.setSession(this.session)
    this.cmdDispatcher.setTerminalProject(name)
    this.relayManager.setProject(name)
    this.relayManager.setSession(this.session)
    this.fileUploadManager.setProject(name)
    this.fileUploadManager.setSession(this.session)
    this.aiCommitManager.setProject(name)
    this.aiCommitManager.setSession(this.session)
    this.workflowManager.setSession(this.session)
    // 切项目时始终显示一条 env 标记，但避免重复堆积
    const lines = this.session.lines
    // 检查最后一条是不是 env 消息，是则先移除再添加（保持最新）
    const lastIdx = lines.length - 1
    const envLabel = '> env: ' + name + ' · ' + this.currentModeLabel()
    const alreadyShown = lastIdx >= 0 && lines[lastIdx].text === envLabel && lines[lastIdx].kind === 'system'
    if (!alreadyShown) {
      this.session.appendSystem(envLabel, currentTheme().result)
    }
    this.syncLines()
    this.scrollToBottom()
    // 确保 WS 已连接并 join 到新项目 session
    // 若 WS 未连（首次启动无项目时跳过连接），先 connect，
    // 后续 setOnOpen 回调会自动 join 当前 terminalProject
    if (this.wsClient.connected) {
      const tok = AppStorage.get<string>(KEY_CLIENT_TOKEN) ?? ''
      this.wsClient.joinSession('', 'phone', name, tok)
      this.cmdDispatcher.flushPendingChat()
    } else {
      this.wsClient.connect(this.backendUrl)
    }
    // 切项目后重新检查 relay 状态
    // #review: 通过 resetStatus 方法写入（绕过 UI 回调），不要直接写 private 字段
    this.relayManager.resetStatus('checking')
    this.relayManager.checkRelayStatus()
    // 切项目后清除防重复提交记录，防止同命令被误拦截
    this._lastSubmitText = ''
    this._lastSubmitAt = 0
  }

  /** 左右滑切换项目 */
  private swipeProject(dir: 'left' | 'right'): void {
    if (this.projectList.length < 2) return
    const idx = this.projectList.indexOf(this.terminalProject)
    if (idx < 0) return
    const nextIdx = dir === 'left' ? Math.min(this.projectList.length - 1, idx + 1) : Math.max(0, idx - 1)
    if (nextIdx !== idx) this.selectProject(this.projectList[nextIdx])
  }

  async checkConnection(): Promise<void> {
    const hc = http.createHttp()
    try {
      const r = await hc.request(this.backendUrl + '/healthz', {
        method: http.RequestMethod.GET,
        connectTimeout: 3000,
        readTimeout: 3000
      })
      this.connected = r.responseCode === 200
      if (this.connected) {
        this.session.connected = true
      }
    } catch (e) {
      // #5 修复：静默吞错误，加 console.error 输出异常详情
      console.error('serein: healthz check failed — ' + (e as Error).message)
      this.connected = false
      this.session.connected = false
    } finally {
      hc.destroy()
    }
  }

  checkStartMsg(): void {
    const m = AppStorage.get<string>('terminalStartMsg')
    if (m !== undefined && m !== null && m !== '') {
      const ls = m.split('\n')
      for (let i = 0; i < ls.length; i++) {
        const line = ls[i]
        if (line !== '' && line !== '(empty session)') {
          this.session.appendSystem(line, '#8C909F')
        }
      }
      AppStorage.setOrCreate('terminalStartMsg', '')
      this.syncLines()
      this.scrollToBottom()
    }
  }

  /** /ai-commit — 委托给 aiCommitManager 处理 */
  private async handleAiCommit(): Promise<void> {
    await this.aiCommitManager.handleAiCommit()
  }

  /** 从手机选择文件并上传到 PC 服务器（委托给 fileUploadManager） */
  private async handleFilePick(): Promise<void> {
    await this.fileUploadManager.handleFilePick()
  }

  /**
   * 执行 Workflow 步骤（按序提交命令，委托给 workflowManager）。
   */
  submitWorkflowSteps(steps: string[], index: number): void {
    this.workflowManager.submitWorkflowSteps(steps, index)
  }

  // ═══ submitCommand 路由 — 拆分路径减少单函数长度 ═══

  /** 处理 /nl 自然语言转命令 */
  private handleNLCommand(nlText: string): void {
    this.inputText = ''
    this.session.appendSystem('[NL] 翻译中: ' + nlText, currentTheme().tool)
    this.syncLines()
    this.executing = true
    this.cmdDispatcher.handleNLCommand(nlText)
  }

  /** 处理 /batch 批量模式 */
  private async handleBatchSubmit(batchCmd: string): Promise<void> {
    this.inputText = ''
    this.session.appendSystem('[Batch] 在 ' + this.batchProjects.length + ' 个项目上执行: ' + batchCmd, currentTheme().tool)
    this.syncLines()
    this.executing = true
    await this.cmdDispatcher.sendBatchCommand(this.batchProjects.concat([]), batchCmd)
    this.batchMode = false
    this.batchProjects = []
  }

  /** 处理 /ai-commit */
  private handleAiCommitRoute(): void {
    this.inputText = ''
    this.session.appendSystem('[AI Commit] 正在生成 commit message…', currentTheme().tool)
    this.syncLines()
    this.executing = true
    this.handleAiCommit().catch((e: Error) => {
      this.session.appendError('AI Commit Error: ' + e.message)
      this.executing = false
      this.syncLines()
    })
  }

  /**
   * 直接分发 prompt（文件上传后自动调用）。
   * 策略：WS 已连接时走 WS；WS 断连时走 HTTP fallback（/agent/cmd?async=true），
   * 后端会通过 session_msg 广播给 relay，确保 prompt 100% 到达。
   */
  dispatchPrompt(cmd: string): void {
    try {
      const t = cmd.trim()
      if (t === '') {
        console.info('[serein] dispatchPrompt: empty prompt, skipped')
        return
      }
      if (this.isDesktopRuntime()) {
        this.submitDesktopPrompt(t)
        return
      }
      console.info('[serein] dispatchPrompt: "' + t.substring(0, 60) + '" (len=' + t.length + ') ws=' + this.wsClient.connected)
      // 记录发送文本供 WS session_msg 去重
      this.wsEventHandler.setLastSentText(t)
      // 重置 dedup 状态
      this._lastSubmitText = t
      this._lastSubmitAt = Date.now()
      // 取消旧轮询
      if (this.executing) {
        this.cmdPoller.abort()
      }
      // === UI 更新（同步执行）===
      this.session.addToHistory(t)
      this.session.startBlock()
      this.session.appendPrompt(t)
      this.inputText = ''
      this.executing = true
      this.userScrolledUp = false
      this.syncLines()
      this.scrollToBottom()
      // saveHistory 异步执行，不阻塞发送
      this.saveHistory().catch((e: Error) => {
        console.warn('[serein] saveHistory failed (non-blocking): ' + e.message)
      })
      // === 发送策略：始终走 WS（sendChatViaWS 内部处理断连排队）===
      // HTTP fallback 的 chat 会被 agent skip（relay 处理 chat），所以不走 fallback
      console.info('[serein] dispatchPrompt → WS (connected=' + this.wsClient.connected + ')')
      this.cmdDispatcher.sendChatViaWS(t)
    } catch (e) {
      console.error('[serein] dispatchPrompt ERROR: ' + ((e as Error).message ?? 'Unknown'))
      this.executing = false
      this.session.appendError('[文件上传] prompt 发送失败: ' + ((e as Error).message ?? 'Unknown'))
      this.syncLines()
    }
  }

  async submitCommand(cmd: string): Promise<void> {
    try {
      const t = cmd.trim()
      if (t === '') return
      // 记录发送文本供 WS session_msg 去重（在发送前设置）
      this.wsEventHandler.setLastSentText(t)
      // 防重复提交：相同命令 2 秒内只处理一次
      const now = Date.now()
      if (t === this._lastSubmitText && now - this._lastSubmitAt < 2000) {
        console.info('serein: dedup submit, ignored')
        return
      }
      this._lastSubmitText = t
      this._lastSubmitAt = now
      // 执行中再提交：取消旧轮询
      if (this.executing) {
        this.cmdPoller.abort()
      }
      // 裸 /nl（无参数）显示帮助，不经过 router
      if (t === '/nl') {
        this.session.appendSystem('/nl <自然语言描述> — 将自然语言描述翻译为命令序列', '#A1A1AA')
        this.syncLines()
        return
      }
      const route = TerminalCommandRouter.route(t, {
        isExecuting: this.executing,
        batchMode: this.batchMode,
        batchProjects: this.batchProjects,
        handleClientCommand: (s: string) => this.cmdDispatcher.handleClientCommand(s),
      })
      if (this.isDesktopRuntime() && route.type === CommandRouteType.DISPATCH) {
        this.submitDesktopPrompt(route.text ?? t)
        return
      }
      await TerminalCommandRouter.executeRoute(route, this._routeCallbacks)
    } catch (e) {
      this.executing = false
      this.session.appendError('Error: ' + ((e as Error).message ?? 'Unknown'))
      this.syncLines()
    }
  }

  /** 复制全部终端输出到剪贴板（保留在 TerminalContent 中供 build 引用） */
  private copyAllOutput(): void {
    this.cmdDispatcher.copyAllOutput()
  }

  /** 选中行时只复制该行；未选中时保留原来的“复制全部”。 */
  private copySelectedOrAll(): void {
    if (this.selectedLineText === '') {
      this.copyAllOutput()
      return
    }
    try {
      const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.selectedLineText)
      pasteboard.getSystemPasteboard().setDataSync(pasteData)
      promptAction.showToast({ message: '已复制选中行', duration: 1200 })
    } catch (e) {
      console.error('serein: 复制选中行失败: ' + (e as Error).message)
      promptAction.showToast({ message: '复制失败', duration: 1200 })
    }
  }

  /** 处理终端选项点击：1/2/3 直接发送，空白选项预填编号到输入框
   *  选择选项时不显示数字提示行，直接移除该组选项后静默发送 */
  private handleChoiceTap(num: string, isBlank: boolean, choiceGroupId: number): void {
    if (isBlank) {
      // 空白选项：预填编号到输入框，用户输入内容后发送
      this.inputText = num + ' '
      promptAction.showToast({ message: '请输入选项 ' + num + ' 的内容后点发送', duration: 3000 })
    } else {
      // 非空白选项：直接移除该组选项行（选完即消失），然后静默发送
      AgentQuestionQueue.resolveChoiceGroup(this.terminalProject, choiceGroupId)
      this.session.removeChoiceLines(choiceGroupId)
      this.syncLines()
      // 静默发送：不经过 submitCommand（避免 appendPrompt），直接调 sendChatViaWS
      this.wsEventHandler.setLastSentText(num)
      // 选择题的点击仅是把答案交回 CLI；它还不代表模型已经开始生成。
      // 真正开始时由 turn_start / thinking 事件打开该状态。
      this.executing = false
      this.userScrolledUp = false
      this.cmdDispatcher.sendChatViaWS(num)
      this.syncLines()
      this.scrollToBottom()
    }
  }

  /** 只在用户未手动向上滚动时自动滚动到底，否则静默添加不打断浏览 */
  private scrollToBottom(): void {
    const alignBottom = (): void => {
      if (this.destroyed) return  // 页面已销毁时不操作 UI
      if (!this.userScrolledUp) {
        this.scroller.scrollEdge(Edge.Bottom)
      }
    }
    // 第一轮处理普通事件，后两轮覆盖 ArkUI 在长文本换行后的异步重新布局。
    setTimeout(alignBottom, 50)
    setTimeout(alignBottom, 180)
    setTimeout(alignBottom, 360)
  }

  // ═══ 主题 / 字号（留在 TerminalContent，因引用 @State themeName / uiTick）═══

  private async cycleTheme(): Promise<void> {
    const order: string[] = ['dark', 'light', 'contrast']
    const idx = order.indexOf(this.themeName)
    const next = order[(idx + 1) % order.length]
    setTheme(next as ThemeName)
    this.themeName = next
    this.uiTick++
    await PrefStore.saveTheme(next)
    promptAction.showToast({ message: '主题: ' + next, duration: 1000 })
  }

  private async adjustFont(delta: number): Promise<void> {
    const cur = currentFontSize()
    setFontSize(cur + delta)
    this.terminalFontSize = currentFontSize()
    this.uiTick++
    await PrefStore.saveFontSize(currentFontSize())
    promptAction.showToast({ message: '字号 ' + currentFontSize(), duration: 800 })
  }

  // WS 事件已委托给 TerminalEventHandler.handleEvent()
  build() {
    Stack() {
      Column() {
      TerminalHeaderBar({
        terminalProject: this.terminalProject,
        agentType: this.agentType,
        runtimeMode: this.terminalRuntimeMode,
        hasLineSelection: this.selectedLineText !== '',
        onMenuClick: () => {
          if (!this.showDrawer) {
            // 打开抽屉前重新加载项目列表，确保与首页删除操作同步
            this.loadProjects()
          }
          this.showDrawer = !this.showDrawer
        },
        onFontSmaller: () => { this.adjustFont(-1) },
        onFontLarger: () => { this.adjustFont(1) },
        onCopyAll: () => { this.copySelectedOrAll() },
      })

      if (this.terminalRuntimeMode === 'desktop') {
        Row() {
          Column() {
            Text(this.codexDesktopActive !== null && this.codexDesktopActive.threadTitle !== ''
              ? this.codexDesktopActive.threadTitle : '桌面会话')
              .fontSize(11).fontWeight(600).fontColor('#DDD7D3')
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.codexDesktopActive !== null ? '已连接 · 可与电脑端继续同一会话'
              : this.codexDesktopLoading ? '正在打开桌面会话…' : '尚未选择会话')
              .fontSize(9).fontColor('#777D88').margin({ top: 2 })
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          if (this.codexDesktopActive !== null && this.codexDesktopActive.turnId !== '') {
            Text('中断').fontSize(10).fontWeight(600).fontColor('#CFA795')
              .padding({ left: 10, right: 10, top: 7, bottom: 7 })
              .backgroundColor('rgba(207,167,149,0.10)').borderRadius(8)
              .margin({ right: 8 })
              .onClick(() => { this.interruptDesktopTurn() })
          }
          Text(this.codexDesktopActive !== null ? '关闭会话' : '选择会话')
            .fontSize(10).fontWeight(650).fontColor('#D99A83')
            .padding({ left: 11, right: 11, top: 7, bottom: 7 })
            .backgroundColor('rgba(217,119,87,0.11)').borderRadius(8)
            .onClick(() => {
              if (this.codexDesktopActive !== null) this.closeDesktopSession()
              else this.openCodexDesktopPanel = true
            })
        }
        .width('100%').padding({ left: 15, right: 15, top: 8, bottom: 8 })
        .backgroundColor('rgba(18,20,24,0.94)')
        .border({ width: { bottom: 1 }, color: 'rgba(217,119,87,0.10)' })
      }

      if (this.terminalRuntimeMode === 'desktop' && this.codexDesktopApproval !== '') {
        Column() {
          Row() {
            Text('需要确认').fontSize(10).fontWeight(700).fontColor('#D99A83')
            Blank()
            Text('Codex').fontSize(9).fontColor('#777D88')
          }.width('100%')
          Text(this.desktopApprovalSummary())
            .fontSize(11).fontColor('#D8D3D0').lineHeight(17).maxLines(4)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 7 })
          if (this.desktopApprovalSupported()) {
            Row() {
              Text('拒绝').fontSize(11).fontWeight(650).fontColor('#B9B4B1')
                .textAlign(TextAlign.Center).layoutWeight(1)
                .padding({ top: 9, bottom: 9 })
                .backgroundColor('rgba(185,180,177,0.08)').borderRadius(9)
                .onClick(() => { this.respondDesktopApproval('deny') })
              Text('允许这次').fontSize(11).fontWeight(650).fontColor('#F0D8CF')
                .textAlign(TextAlign.Center).layoutWeight(1)
                .padding({ top: 9, bottom: 9 }).margin({ left: 9 })
                .backgroundColor('rgba(217,119,87,0.18)').borderRadius(9)
                .onClick(() => { this.respondDesktopApproval('allow') })
            }.width('100%').margin({ top: 10 })
          } else {
            Text('这类权限暂不能在手机上安全确认，可以中断当前回答。')
              .fontSize(9).fontColor('#858A94').margin({ top: 8 })
          }
        }
        .width('100%').padding({ left: 14, right: 14, top: 11, bottom: 11 })
        .backgroundColor('rgba(31,27,27,0.96)')
        .border({ width: { bottom: 1 }, color: 'rgba(217,119,87,0.16)' })
      }

      TerminalBannerArea({
        showProjectPicker: this.showProjectPicker,
        projectList: this.projectList,
        terminalProject: this.terminalProject,
        searchTerm: this.searchTerm,
        renderLineCount: this.renderLines.length,
        batchMode: this.batchMode,
        batchProjects: this.batchProjects,
        backendIsHttp: this.backendIsHttp,
        wsState: this.wsState,
        projectAgentModes: this.projectAgentModes,
        onLaunchProject: (name: string, mode: string) => { this.launchProjectWithMode(name, mode) },
        onClearSearch: () => { this.searchTerm = ''; this.computeRender() },
        onCloseBatch: () => { this.batchMode = false; this.batchProjects = []; this.syncLines() },
        onBatchToggleProject: (name: string) => {
          const idx = this.batchProjects.indexOf(name)
          if (idx >= 0) {
            this.batchProjects = this.batchProjects.filter((_, i) => i !== idx)
          } else {
            this.batchProjects = this.batchProjects.concat([name])
          }
        },
        onReconnect: () => { this.wsClient.connect(this.backendUrl) },
      })

      // ====== Output Area（PhoneShell 风格 Xterm 容器） ======
      if (this.terminalProject !== '') {
      TerminalOutputArea({
        scroller: this.scroller,
        renderLines: $renderLines,
        showBanner: $showBanner,
        executing: $executing,
        collapsed: $collapsed,
        fontSize: this.terminalFontSize,
        selectedLineKey: this.selectedLineKey,
        agentType: this.agentType,
        projectName: this.currentProjectName(),
        onToggleCollapse: (blockId: number) => { this.toggleCollapse(blockId) },
        onScrollChanged: (isUp: boolean) => { this.userScrolledUp = isUp },
        onFontAdjust: (delta: number) => { this.adjustFont(delta) },
        onLineSelect: (text: string, key: string) => {
          if (this.selectedLineKey === key) {
            this.selectedLineKey = ''
            this.selectedLineText = ''
          } else {
            this.selectedLineKey = key
            this.selectedLineText = text
          }
        },
        onSwipeProject: (dir: 'left' | 'right') => { this.swipeProject(dir) },
        onChoiceTap: (num: string, isBlank: boolean, choiceGroupId: number) => { this.handleChoiceTap(num, isBlank, choiceGroupId) },
      })
      } else {
        TerminalEmptyState()
      }

      // ====== Bottom bar: panels + toolbar + input ======
      TerminalBottomPanels({
        slashHints: this.slashHints,
        slashHintOverflow: this.slashHintOverflow,
        showHistory: this.showHistory,
        historyList: this.historyList,
        remoteHistory: this.remoteHistoryList,
        remoteLoading: this.remoteHistoryLoading,
        remoteError: this.remoteHistoryError,
        showSnippets: this.showSnippets,
        snippets: this.snippets,
        showWorkflow: this.showWorkflow,
        inputText: this.inputText,
        connected: this.connected,
        executing: this.executing || (this.terminalRuntimeMode === 'desktop'
          && this.codexDesktopActive !== null && this.codexDesktopActive.turnId !== ''),
        onPickSlashHint: (cmd: string) => { this.cmdDispatcher.pickSlashHint(cmd) },
        onPickHistory: (cmd: string) => { this.cmdDispatcher.pickHistory(cmd) },
        onPickSnippet: (cmd: string) => { this.inputText = cmd; this.showSnippets = false; this.cmdDispatcher.updateSlashHints(cmd) },
        onAddSnippet: () => { this.cmdDispatcher.addSnippetFromInput() },
        onDeleteSnippet: (name: string) => { this.cmdDispatcher.deleteSnippet(name) },
        onCloseSnippet: () => { this.showSnippets = false },
        onPickWorkflow: (cmds: string[]) => {
          this.showWorkflow = false
          this.submitWorkflowSteps(cmds, 0)
        },
        onCloseWorkflow: () => { this.showWorkflow = false },
        onKeyTap: (key: string) => { this.cmdDispatcher.handleKeyTap(key) },
        onChange: (text: string) => { this.inputText = text; this.cmdDispatcher.updateSlashHints(text) },
        onSubmit: (text: string) => { this.submitCommand(text) },
        onFilePick: () => { this.handleFilePick() },
        onVoiceError: (message: string) => {
          this.session.appendError('[语音] ' + message)
          this.syncLines()
        },
      })
    }

    // 项目 Drawer（左侧滑出）
    if (this.showDrawer) {
      // 遮罩
      Column()
        .width('100%').height('100%')
        .backgroundColor('rgba(0,0,0,0.50)')
        .onClick(() => { this.showDrawer = false })

            ProjectDrawer({
        projectList: this.projectList,
        terminalProject: this.terminalProject,
        connected: this.connected && (this.terminalRuntimeMode !== 'desktop' || this.codexDesktopActive !== null),
        projectAgentModes: this.projectAgentModes,
        onLaunchProject: (projectName: string, mode: string) => { this.launchProjectWithMode(projectName, mode) },
        onClose: () => { this.showDrawer = false }
      })
    }
    if (this.openCodexDesktopPanel && this.isDesktopRuntime()) {
      Row()
        .width('100%').height('100%')
        .backgroundColor('rgba(0,0,0,0.48)')
        .onClick(() => { this.openCodexDesktopPanel = false })
        .transition(TransitionEffect.OPACITY.animation({ duration: 200, curve: Curve.EaseOut }))
      CodexDesktopPanel({
        threads: this.codexDesktopThreads,
        projectName: this.terminalProject,
        loading: this.codexDesktopLoading,
        error: this.codexDesktopError,
        onCommand: (command: string) => { this.sendDesktopControl(command) },
        onRefresh: () => { this.requestDesktopThreads(true) },
        onClose: () => { this.openCodexDesktopPanel = false },
      })
    }
    }
    .width('100%').height('100%').backgroundColor(currentTheme().bg)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}

@Entry
@Component
struct TerminalPage { build() { Stack() { TerminalContent() } } }
