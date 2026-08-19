/**
 * TerminalComponentFactory — 终端组件工厂方法
 *
 * 从 TerminalPage.TerminalContent 提取的工厂方法集合，减少主文件代码行数。
 * 所有方法均为静态，接收依赖对象而非引用 this 上下文。
 */
import { type TerminalLineData, TerminalSession } from './TerminalSession'
import { WebSocketClient, type WSEvent, WSConnectionState } from '../api/WebSocketClient'
import { PollerBinding, type PollerCallbacks } from './TerminalCmdPoller'
import { CmdDispatchBinding, type CmdDispatchCallbacks } from './TerminalCmdDispatcher'
import { TerminalEventHandler, EventHandlerBinding } from './TerminalEventHandler'
import { RelayManager, RelayBinding } from './RelayManager'
import { FileUploadManager, FileUploadBinding } from './FileUploadManager'
import { AiCommitManager, AiCommitBinding } from './AiCommitManager'
import { WorkflowManager, WorkflowBinding, type SubmitCommandFn } from './WorkflowManager'
import { type SlashCommandInfo } from './SlashCommands'
import { type Snippet } from '../store/PrefStore'

/** 终端组件工厂需要的外部回调集（保留导出兼容） */
export interface FactoryCallbacks {
  syncLines: () => void
  scrollToBottom: () => void
  computeRender: () => void
  cycleTheme: () => void
  adjustFont: (delta: number) => void
  submitCommand: (t: string) => void
  saveHistory: () => Promise<void>
  clearChatTimeout: () => void
  submitWorkflowSteps: (steps: string[], index: number) => void
  handleAiCommit: () => Promise<void>
  handleFilePick: () => Promise<void>
  setExecuting: (v: boolean) => void
  setInputText: (v: string) => void
  setShowSnippets: (v: boolean) => void
}

/** makePollerCallbacks 需要的回调集 */
export interface PollerFactoryFns {
  syncLines: () => void
  scrollToBottom: () => void
  setExecuting: (v: boolean) => void
}

/** makeEventHandler 需要的回调集 */
export interface EventHandlerFactoryFns {
  syncLines: () => void
  scrollToBottom: () => void
  setExecuting: (v: boolean) => void
  clearChatTimeout: () => void
  onDesktopEvent: (eventType: string, content: string) => void
}

/** makeCmdDispatchBinding getters 参数 */
export interface CmdDispatchGetters {
  getInputText: () => string
  getShowHistory: () => boolean
  getLines: () => TerminalLineData[]
  getRenderLines: () => TerminalLineData[]
}

/** makeCmdDispatchBinding setters 参数 */
export interface CmdDispatchSetters {
  setInputText: (v: string) => void
  setSlashHints: (v: SlashCommandInfo[]) => void
  setSlashHintOverflow: (v: boolean) => void
  setShowHistory: (v: boolean) => void
  setShowSnippets: (v: boolean) => void
  setSearchTerm: (v: string) => void
  setRenderLines: (v: TerminalLineData[]) => void
  setHistoryList: (v: string[]) => void
  setRemoteHistoryList: (v: string[]) => void
  setRemoteHistoryLoading: (v: boolean) => void
  setRemoteHistoryError: (v: string) => void
  setExecuting: (v: boolean) => void
  setUserScrolledUp: (v: boolean) => void
  setSnippets: (v: Snippet[]) => void
}

/** makeCmdDispatchBinding fns 参数 */
export interface CmdDispatchFns {
  syncLines: () => void
  scrollToBottom: () => void
  computeRender: () => void
  cycleTheme: () => void
  adjustFont: (delta: number) => void
  submitCommand: (t: string) => void
  saveHistory: () => Promise<void>
  clearChatTimeout: () => void
}

/** makeRelayManager fns 参数 */
export interface RelayFactoryFns {
  appendSystem: (t: string, c: string) => void
  syncLines: () => void
}

/** makeFileUploadManager fns 参数 */
export interface FileUploadFactoryFns {
appendSystem: (t: string, c: string) => void
syncLines: () => void
appendError: (t: string) => void
submitCommand: (t: string) => void
dispatchPrompt: (t: string) => void
}

/** makeAiCommitManager fns 参数 */
export interface AiCommitFactoryFns {
  appendSystem: (t: string, c: string) => void
  syncLines: () => void
  scrollToBottom: () => void
  appendError: (t: string) => void
  setExecuting: (v: boolean) => void
}

/** makeWorkflowManager fns 参数 */
export interface WorkflowFactoryFns {
  appendSystem: (t: string, c: string) => void
  syncLines: () => void
  scrollToBottom: () => void
  getExecuting: () => boolean
}

/** 终端组件工厂 — 创建各管理器实例 */
export class TerminalComponentFactory {
  static makePollerCallbacks(
    session: TerminalSession,
    fns: PollerFactoryFns,
  ): PollerCallbacks {
    return new PollerBinding(
      (text: string) => { session.appendOutput(text) },
      (text: string, color: string) => { session.appendSystem(text, color) },
      () => { fns.syncLines() },
      () => { fns.scrollToBottom() },
      (v: boolean) => { fns.setExecuting(v) },
    )
  }

  static makeEventHandler(
    session: TerminalSession,
    fns: EventHandlerFactoryFns,
    onFileUploadResult: (cmdId: string, success: boolean, output: Record<string, Object>) => void,
    onHeartbeat: (data: Record<string, Object>) => void,
  ): TerminalEventHandler {
    const binding = new EventHandlerBinding(
      (v: boolean) => { fns.setExecuting(v) },
      () => { fns.clearChatTimeout() },
      () => { fns.syncLines() },
      () => { fns.scrollToBottom() },
    )
    binding.onFileUploadResult = onFileUploadResult
    binding.onHeartbeat = onHeartbeat
    binding.onDesktopEvent = (eventType: string, content: string): void => {
      fns.onDesktopEvent(eventType, content)
    }
    return new TerminalEventHandler(session, binding)
  }

  static makeCmdDispatchBinding(
    getters: CmdDispatchGetters,
    setters: CmdDispatchSetters,
    fns: CmdDispatchFns,
  ): CmdDispatchCallbacks {
    return new CmdDispatchBinding(
      (v: string) => { setters.setInputText(v) },
      (v: SlashCommandInfo[]) => { setters.setSlashHints(v) },
      (v: boolean) => { setters.setSlashHintOverflow(v) },
      (v: boolean) => { setters.setShowHistory(v) },
      (v: boolean) => { setters.setShowSnippets(v) },
      (v: string) => { setters.setSearchTerm(v) },
      (v: TerminalLineData[]) => { setters.setRenderLines(v) },
      (v: string[]) => { setters.setHistoryList(v) },
      (v: string[]) => { setters.setRemoteHistoryList(v) },
      (v: boolean) => { setters.setRemoteHistoryLoading(v) },
      (v: string) => { setters.setRemoteHistoryError(v) },
      (v: boolean) => { setters.setExecuting(v) },
      (v: boolean) => { setters.setUserScrolledUp(v) },
      (v: Snippet[]) => { setters.setSnippets(v) },
      () => getters.getInputText(),
      () => getters.getShowHistory(),
      () => getters.getLines(),
      () => getters.getRenderLines(),
      () => { fns.syncLines() },
      () => { fns.scrollToBottom() },
      () => { fns.computeRender() },
      () => { fns.cycleTheme() },
      (d: number) => { fns.adjustFont(d) },
      (t: string) => { fns.submitCommand(t) },
      () => fns.saveHistory(),
      () => { fns.clearChatTimeout() },
    )
  }

  static makeRelayManager(
    session: TerminalSession,
    fns: RelayFactoryFns,
    onWsRejoin: () => void,
    setRelayStatus: (v: string) => void,
    getDestroyed: () => boolean,
  ): RelayManager {
    return new RelayManager(session, new RelayBinding(
      (t: string, c: string) => { fns.appendSystem(t, c) },
      () => { fns.syncLines() },
      () => { onWsRejoin() },
      (_v: string) => { setRelayStatus(_v) },
      getDestroyed,
    ))
  }

static makeFileUploadManager(
session: TerminalSession,
fns: FileUploadFactoryFns,
getDestroyed: () => boolean,
): FileUploadManager {
return new FileUploadManager(session, new FileUploadBinding(
(t: string, c: string) => { fns.appendSystem(t, c) },
() => { fns.syncLines() },
(t: string) => { fns.appendError(t) },
(t: string) => { fns.submitCommand(t) },
(t: string) => { fns.dispatchPrompt(t) },
getDestroyed,
))
}

  static makeAiCommitManager(
    session: TerminalSession,
    wsClient: WebSocketClient,
    fns: AiCommitFactoryFns,
    onRequestConfirm: ((message: string) => Promise<boolean>) | undefined,
    getDestroyed: () => boolean,
  ): AiCommitManager {
    const mgr = new AiCommitManager(session, wsClient, new AiCommitBinding(
      (t: string, c: string) => { fns.appendSystem(t, c) },
      () => { fns.syncLines() },
      () => { fns.scrollToBottom() },
      (t: string) => { fns.appendError(t) },
      (v: boolean) => { fns.setExecuting(v) },
      getDestroyed,
    ))
    mgr.onRequestConfirm = onRequestConfirm
    return mgr
  }

  static makeWorkflowManager(
    session: TerminalSession,
    submitCommand: SubmitCommandFn,
    fns: WorkflowFactoryFns,
    getDestroyed: () => boolean,
  ): WorkflowManager {
    return new WorkflowManager(session, submitCommand, new WorkflowBinding(
      (t: string, c: string) => { fns.appendSystem(t, c) },
      () => { fns.syncLines() },
      () => { fns.scrollToBottom() },
      () => fns.getExecuting(),
      getDestroyed,
    ))
  }

  /** 从 lines/verbosity/searchTerm/collapsed 计算可见行 */
  static computeRenderLines(
    lines: TerminalLineData[],
    verbosity: number,
    searchTerm: string,
    collapsed: number[],
  ): TerminalLineData[] {
    let filtered = lines
    if (verbosity < 2) {
      filtered = TerminalSession.filterByVerbosity(filtered, verbosity as 0 | 1 | 2)
    }
    const out: TerminalLineData[] = []
    const kw = searchTerm.toLowerCase()
    for (let i = 0; i < filtered.length; i++) {
      const ln = filtered[i]
      if (ln.blockId >= 0 && ln.kind !== 'prompt' && collapsed.indexOf(ln.blockId) >= 0) {
        continue
      }
      if (kw !== '' && ln.text.toLowerCase().indexOf(kw) < 0) {
        continue
      }
      out.push(ln)
    }
    return out
  }
}
