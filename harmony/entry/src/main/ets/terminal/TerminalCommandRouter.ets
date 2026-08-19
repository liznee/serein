/**
 * TerminalCommandRouter — 从 TerminalPage.submitCommand 提取的命令路由模块
 *
 * 将 if-else 链重构为查表分派，减少主文件行数，新增命令类型
 * 只需在路由表中注册而不必修改路由函数本身。
 *
 * v2: 新增 executeRoute 静态方法，将路由分派逻辑从 TerminalPage
 * submitCommand 移入此处，不再手写 switch-case。
 */

import { currentTheme } from './TerminalTheme'

/** 命令路由枚举 */
export enum CommandRouteType {
  NONE = 'none',
  CLIENT = 'client',
  WORKFLOW = 'workflow',
  NL = 'nl',
  BATCH_TOGGLE = 'batchToggle',
  BATCH_CANCEL = 'batchCancel',
  BATCH_SUBMIT = 'batchSubmit',
  AI_COMMIT = 'aiCommit',
  RELAY_HELP = 'relayHelp',
  RELAY_STATUS = 'relayStatus',
  RELAY_START = 'relayStart',
  DISPATCH = 'dispatch',
}

/** 路由结果 */
export interface CommandRoute {
  type: CommandRouteType
  text?: string
}

/** route 选项 */
export interface RouteOptions {
  isExecuting: boolean
  batchMode: boolean
  batchProjects: string[]
  handleClientCommand: (t: string) => boolean
}

/** 路由执行回调集 */
export interface RouteCallbacks {
  setInputText: (v: string) => void
  setShowWorkflow: (v: boolean) => void
  setBatchMode: (v: boolean) => void
  setBatchProjects: (v: string[]) => void
  setExecuting: (v: boolean) => void
  appendSystem: (msg: string, color: string) => void
  appendError: (msg: string) => void
  syncLines: () => void
  scrollToBottom: () => void
  handleNLCommand: (text: string) => void
  handleBatchSubmit: (cmd: string) => Promise<void>
  handleAiCommitRoute: () => void
  submitAndDispatch: (t: string) => Promise<void>
  getRelayStatus: () => string
  startRelay: () => void
  /** BATCH_TOGGLE 完整处理逻辑（含条件分支） */
  execBatchToggle: () => void
}

export class TerminalCommandRouter {
  static route(input: string, options: RouteOptions): CommandRoute {
    const t = input.trim()
    if (t === '') return { type: CommandRouteType.NONE }
    if (options.handleClientCommand(t)) {
      return { type: CommandRouteType.CLIENT }
    }
    if (t === '/workflow') return { type: CommandRouteType.WORKFLOW }
    if (t === '/nl') return { type: CommandRouteType.NONE }
    if (t.startsWith('/nl ')) {
      const nlText = t.substring(3).trim()
      if (nlText === '') return { type: CommandRouteType.NONE }
      return { type: CommandRouteType.NL, text: nlText }
    }
    if (t === '/batch') return { type: CommandRouteType.BATCH_TOGGLE }
    if (t === '/batch cancel') return { type: CommandRouteType.BATCH_CANCEL }
    if (options.batchMode && options.batchProjects.length > 0) {
      return { type: CommandRouteType.BATCH_SUBMIT, text: t }
    }
    if (t === '/ai-commit') return { type: CommandRouteType.AI_COMMIT }
    if (t === '/relay') return { type: CommandRouteType.RELAY_HELP }
    if (t === '/relay status') return { type: CommandRouteType.RELAY_STATUS }
    if (t === '/relay start') return { type: CommandRouteType.RELAY_START }
    return { type: CommandRouteType.DISPATCH, text: t }
  }

  /** 执行路由结果 — 根据 route.type 调用对应的回调 */
  static async executeRoute(route: CommandRoute, cb: RouteCallbacks): Promise<void> {
    switch (route.type) {
      case CommandRouteType.NONE:
      case CommandRouteType.CLIENT:
        return
      case CommandRouteType.WORKFLOW:
        cb.setInputText('')
        cb.setShowWorkflow(true)
        return
      case CommandRouteType.NL:
        cb.handleNLCommand(route.text!)
        return
      case CommandRouteType.BATCH_TOGGLE:
        cb.execBatchToggle()
        return
      case CommandRouteType.BATCH_CANCEL:
        cb.setBatchMode(false)
        cb.setBatchProjects([])
        cb.setInputText('')
        cb.appendSystem('[Batch] 已取消', '#A1A1AA')
        cb.syncLines()
        return
      case CommandRouteType.BATCH_SUBMIT:
        await cb.handleBatchSubmit(route.text!).catch(() => {})
        return
      case CommandRouteType.AI_COMMIT:
        cb.handleAiCommitRoute()
        return
      case CommandRouteType.RELAY_HELP:
        cb.appendSystem('可用: /relay status — 查看状态, /relay start — 启动远程连接', '#A1A1AA')
        cb.syncLines()
        return
      case CommandRouteType.RELAY_STATUS:
        { const st = cb.getRelayStatus()
          const color = st === 'online' ? currentTheme().success : st === 'starting' ? currentTheme().tool : '#EF4444'
          cb.appendSystem('[Relay] 当前状态: ' + st, color)
          cb.syncLines() }
        return
      case CommandRouteType.RELAY_START:
        cb.startRelay()
        return
      case CommandRouteType.DISPATCH:
        await cb.submitAndDispatch(route.text!)
        return
    }
  }
}
