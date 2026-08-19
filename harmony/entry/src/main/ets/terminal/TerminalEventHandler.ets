﻿﻿﻿﻿/**
 * TerminalEventHandler — WS 事件处理器，从 TerminalPage 拆分以降低文件大小
 *
 * ArkTS 严格模式限制：回调接口使用具体类实现（PollerBinding 模式），
 * 避免对象字面量实现接口（编译报错）。
 */

import type { WSEvent } from '../api/WebSocketClient'
import type { TerminalSession } from './TerminalSession'
import { AgentQuestionQueue } from '../model/AgentQuestionQueue'
import { currentTheme } from './TerminalTheme'
import { EVENT_DESKTOP_THREAD_LIST, EVENT_DESKTOP_THREAD_READ, EVENT_DESKTOP_THREAD_TAKEN, EVENT_DESKTOP_LEASE_RELEASED, EVENT_DESKTOP_LEASE_RENEWED, EVENT_DESKTOP_TURN_STARTED, EVENT_DESKTOP_TURN_INTERRUPTED, EVENT_DESKTOP_NOTIFICATION, EVENT_DESKTOP_APPROVAL_REQUIRED, EVENT_DESKTOP_APPROVAL_RESOLVED, EVENT_DESKTOP_ERROR } from '../api/ws_types'

/** 事件处理器需要的回调接口 */
export interface EventHandlerCallbacks {
  onExecutingChange: (v: boolean) => void
  onChatTimeoutClear: () => void
  onSyncLines: () => void
  onScrollToBottom: () => void
  /** 文件上传结果回调：cmd_id 匹配 pending 上传时调用 */
  onFileUploadResult: (cmdId: string, success: boolean, output: Record<string, Object>) => void
  /** heartbeat 回调：转发给 RelayManager.handleHeartbeat() 驱动 relay 状态检测 */
  onHeartbeat: (data: Record<string, Object>) => void
  /** Codex Desktop/App Server 只读事件 */
  onDesktopEvent: (eventType: string, content: string) => void
}

/** ArkTS 严格模式兼容：具体类实现回调接口 */
export class EventHandlerBinding implements EventHandlerCallbacks {
  public onExecutingChange: (v: boolean) => void = () => {}
  public onChatTimeoutClear: () => void = () => {}
  public onSyncLines: () => void = () => {}
  public onScrollToBottom: () => void = () => {}
  public onFileUploadResult: (cmdId: string, success: boolean, output: Record<string, Object>) => void = () => {}
  public onHeartbeat: (data: Record<string, Object>) => void = () => {}
  public onDesktopEvent: (eventType: string, content: string) => void = () => {}

  constructor(
    onExecutingChange: (v: boolean) => void,
    onChatTimeoutClear: () => void,
    onSyncLines: () => void,
    onScrollToBottom: () => void,
  ) {
    this.onExecutingChange = onExecutingChange
    this.onChatTimeoutClear = onChatTimeoutClear
    this.onSyncLines = onSyncLines
    this.onScrollToBottom = onScrollToBottom
  }
}

export class TerminalEventHandler {
  private session: TerminalSession
  private callbacks: EventHandlerCallbacks
  // 去重：手机发送的消息会被 backend 广播回来，需跳过
  private _lastSentText: string = ''
  private _lastSentAt: number = 0
  private static readonly DEDUP_WINDOW_MS: number = 15000  // 增大到 15 秒，覆盖 TUI 模式下的延迟回显
  private project: string = ''

  constructor(session: TerminalSession, callbacks: EventHandlerCallbacks) {
    this.session = session
    this.callbacks = callbacks
  }

  setSession(s: TerminalSession): void {
    this.session = s
  }

  setProject(project: string): void {
    this.project = project
  }

  /** 设置跳过历史消息标志（WS 重连时调用） */
  setSkipHistory(_v: boolean): void {
    // history 消息由 onHistoryEvent 单独忽略。cmd_step 是实时输出，即使它在
    // 断线期间进入 Relay 缓冲，也必须补发；不能用手机和电脑的时间戳比较，
    // 否则设备时钟偏差会把新工具事件、最终回复和 turn_end 一并误删。
  }

  /** 记录手机端发送的消息文本（供 onSessionMsg 去重） */
  setLastSentText(text: string): void {
    this._lastSentText = text.trim()
    this._lastSentAt = Date.now()
  }

  /** WS 事件总入口 — 分派到具体处理器 */
  handleEvent(evt: WSEvent): void {
    // 收到任何 WS 回复（step/result）均清除 chat 超时定时器
    this.callbacks.onChatTimeoutClear()

    const data = (evt.data ?? evt.payload) as Record<string, Object> | undefined
    if (evt.type === 'step' || evt.type === 'cmd_step') {
      this.onCmdStep(data)
    } else if (evt.type === 'result' || evt.type === 'cmd_result') {
      this.onCmdResult(data)
    } else if (evt.type === 'session_msg') {
      this.onSessionMsg(evt.payload as Record<string, Object> | undefined)
    } else if (evt.type === 'join_ack') {
      this.onJoinAck(evt.payload as Record<string, Object> | undefined)
    } else if (evt.type === 'history') {
      this.onHistoryEvent(evt.payload as Record<string, Object> | undefined)
    } else if (evt.type === 'heartbeat') {
      // heartbeat 事件：转发给 RelayManager 驱动 relay 状态检测 + watchdog
      if (data) {
        this.callbacks.onHeartbeat(data)
      }
    }
  }

  /** cmd_step：实时步骤推送（tool_use / tool_result / hook / text / thinking / terminal_clear） */
  private onCmdStep(s: Record<string, Object> | undefined): void {
    if (!s) return
    const eventType = (s['event'] as string) ?? ''
    const eventName = (s['name'] as string) ?? ''
    const content = (s['content'] as string) ?? ''
    if (eventType === EVENT_DESKTOP_THREAD_LIST || eventType === EVENT_DESKTOP_THREAD_READ
      || eventType === EVENT_DESKTOP_THREAD_TAKEN || eventType === EVENT_DESKTOP_LEASE_RELEASED
      || eventType === EVENT_DESKTOP_LEASE_RENEWED || eventType === EVENT_DESKTOP_TURN_STARTED
      || eventType === EVENT_DESKTOP_TURN_INTERRUPTED || eventType === EVENT_DESKTOP_NOTIFICATION
      || eventType === EVENT_DESKTOP_APPROVAL_REQUIRED || eventType === EVENT_DESKTOP_APPROVAL_RESOLVED
      || eventType === EVENT_DESKTOP_ERROR) {
      this.callbacks.onDesktopEvent(eventType, content)
      return
    }
    let color = '#A1A1AA'
    if (eventType === 'tool_use') { color = currentTheme().tool } else if (eventType === 'tool_result') { color = currentTheme().result } else if (eventType === 'hook') { color = currentTheme().hint }
    if (eventType === 'desktop_history_reset') {
      // 用户选择桌面会话后，用该 Thread 的真实历史替换当前空白终端，
      // 后续 stream_text 会继续原位更新同一条消息。
      this.session.clear()
      this.callbacks.onSyncLines()
    } else if (eventType === 'stream_text' && content !== '') {
      // Codex Desktop App Server 的正文是增量 stream_text；第一段出现时
      // 才结束统一的 thinking 状态，和 Claude/Codex CLI 的 text 保持一致。
      this.callbacks.onExecutingChange(false)
      this.session.endThinking()
      this.session.appendOrReplaceStreamingOutput(eventName, content)
      this.callbacks.onSyncLines()
      this.callbacks.onScrollToBottom()
    } else if (eventType === 'question') {
      const question = AgentQuestionQueue.beginQuestion(this.project, content, eventName)
      // 问题/选择是 Agent 暂停等待用户，不应继续显示通用“正在思考”。
      this.callbacks.onExecutingChange(false)
      this.session.endThinking()
      this.session.appendSystem('？ ' + question, currentTheme().tool)
      this.callbacks.onSyncLines()
      this.callbacks.onScrollToBottom()
    } else if (eventType === 'question_resolved') {
      AgentQuestionQueue.resolveToolQuestions(this.project, content !== '' ? content : eventName)
      this.callbacks.onExecutingChange(false)
    } else if (eventType === 'choice') {
      // AskUserQuestion 选项：直接推送为可点击选项行（绕过 appendOutput 的自动检测）
      if (content !== '') {
        this.callbacks.onExecutingChange(false)
        this.session.endThinking()
        const choiceGroupId = this.session.appendChoice(content)
        AgentQuestionQueue.appendChoice(this.project, content, eventName, choiceGroupId)
        this.callbacks.onSyncLines()
        this.callbacks.onScrollToBottom()
      }
    } else if (eventType === 'turn_start') {
      // 回合开始不写入分隔线；输入行和后续输出的语义已经足够清晰。
      // 保持全局“is thinking”状态，直到首段正文或回合结束，避免网络/JSONL
      // 事件一到就把刚刚出现的状态提示闪掉。
      this.session.endThinking()
      this.callbacks.onExecutingChange(true)
    } else if (eventType === 'turn_end') {
      // 结构化会话协议：对话轮次结束 — 异常停止原因提示
      if (content === 'max_tokens') {
        this.session.appendSystem('⚠ 回复被截断（max_tokens）', '#b53333')
        this.callbacks.onSyncLines()
        this.callbacks.onScrollToBottom()
      }
      this.callbacks.onExecutingChange(false)
      // 正常 end_turn / tool_use 不显示任何内容
    } else if (eventType === 'tool_diff' && content !== '') {
      // 文件编辑类工具的 diff 展示：用 ```diff 围栏包裹，触发 TerminalSession 的 diff 着色
      this.session.endThinking()
      this.session.appendOutput('```diff\n' + content + '\n```')
      this.callbacks.onSyncLines()
      this.callbacks.onScrollToBottom()
    } else if (eventType === 'subagent_start') {
      this.session.endThinking()
      const label = content !== '' ? content : (eventName !== '' ? eventName : '子任务')
      this.session.appendSystem('↳ 子 Agent 启动 · ' + label, currentTheme().tool)
      this.callbacks.onSyncLines()
      this.callbacks.onScrollToBottom()
    } else if (eventType === 'subagent_stop') {
      const label = content !== '' ? content : (eventName !== '' ? eventName : '子任务')
      this.session.appendSystem('✓ 子 Agent 完成 · ' + label, currentTheme().success)
      this.callbacks.onSyncLines()
      this.callbacks.onScrollToBottom()
    } else if (eventType === 'tool_use' || eventType === 'tool_result' || eventType === 'hook') {
      const prefix = eventType === 'tool_use' ? '[工具] ' + eventName : eventType === 'tool_result' ? '[完成] ' : '[钩子] ' + eventName
      // 截断过长的工具内容（WebSearch 结果等可能非常长）
      const maxLen: number = 300
      const displayContent: string = content.length > maxLen ? content.substring(0, maxLen) + '…' : content
      const line = prefix + (displayContent ? ' ' + displayContent : '')
      if (line !== '') {
        this.session.appendSystem(line, color)
        this.callbacks.onSyncLines()
        this.callbacks.onScrollToBottom()
      }
    } else if (eventType === 'user_msg' && content !== '') {
      // 纯数字（1/2/3）= 选项选择，不显示到屏幕
      if (/^\d{1,2}$/.test(content.trim())) {
        return
      }
      // 去重：手机端发送的消息会被 relay 通过 user_msg 回传，需跳过
      // 不清除 _lastSentText，让 onSessionMsg 也能检查（两通道可能同时到达）
      if (this._lastSentText.length > 0) {
        const trimmedContent = content.trim()
        if (trimmedContent === this._lastSentText
            && Date.now() - this._lastSentAt < TerminalEventHandler.DEDUP_WINDOW_MS) {
          return
        }
        // 子串匹配（TUI 可能添加了前缀如 ❯ 或空格）
        if (trimmedContent.includes(this._lastSentText)
            && Date.now() - this._lastSentAt < TerminalEventHandler.DEDUP_WINDOW_MS) {
          return
        }
      }
      // CMD 端用户输入的问题：显示为跟随主题正文色的提示行。
      this.session.endThinking()
      this.session.appendPrompt(content)
      this.callbacks.onSyncLines()
      this.callbacks.onScrollToBottom()
    } else if (eventType === 'terminal_clear') {
      // now unused: relay 不再发送 terminal_clear 事件，因为 claude TUI 频繁清屏重绘
      // 导致手机端反复清空+追加，造成历史丢失和内容重复。手机端只追加不主动清屏。
      // 保留 handler 兼容未来手动清屏需求。
      this.session.clear()
      this.callbacks.onSyncLines()
    } else if (eventType === 'thinking') {
      // 不把模型内部思考正文混进终端历史；只保留一个实时状态提示。
      // 这样手机端会先稳定显示 “<Agent> is thinking…”，再展示最终回答。
      this.callbacks.onExecutingChange(true)
    } else if (eventType === 'thinking_end') {
      // 保持状态到真正开始输出正文；部分 CLI 会在工具调用前多次结束/开始思考。
    } else if (eventType === 'text' && content !== '') {
      // 普通文本输出：结束思考块的就地更新模式
      this.session.endThinking()
      // 去除文本开头的多余空行（思考块结束后常有空白间隔）
      const trimmedContent: string = content.replace(/^\n+/, '')
      if (trimmedContent !== '') {
        // 去重：跳过 TUI 回显的用户输入（已由 user_msg 事件显示为 prompt 行）
        if (this._lastSentText.length > 0 && trimmedContent.trim() === this._lastSentText) {
          return
        }
        // 子串匹配（TUI 可能添加了前缀如 ❯ 或空格）
        if (this._lastSentText.length > 0 && trimmedContent.includes(this._lastSentText)
            && Date.now() - this._lastSentAt < TerminalEventHandler.DEDUP_WINDOW_MS) {
          return
        }
        // 文字开始流式输出时再隐藏状态，而不是在收到 turn_start 时立即隐藏。
        this.callbacks.onExecutingChange(false)
        this.session.appendOutput(trimmedContent)
        this.callbacks.onSyncLines()
        this.callbacks.onScrollToBottom()
      }
    }
  }

  /** cmd_result：最终结果（stdout/stderr / 文件写入结果） */
  private onCmdResult(d: Record<string, Object> | undefined): void {
    if (!d) return
    const output = d['output'] as Record<string, Object> | undefined
    const cmdId = (d['cmd_id'] as string) ?? ''
    if (output) {
      // 判断是否为文件写入结果（output 含 path 和 filename 字段）
      const hasFileFields = (output['path'] as string ?? '') !== '' && (output['filename'] as string ?? '') !== ''
      // 判断是否为文件写入错误（output 含 error 字段但无 path/filename）
      const hasErrorOnly = !hasFileFields && ((output['error'] as string) ?? '') !== ''
      if (hasFileFields) {
        // 文件写入结果：触发上传回调（通知 TerminalPage 显示成功/失败）
        const success = (d['success'] as boolean) ?? false
        this.callbacks.onFileUploadResult(cmdId, success, output)
      } else if (hasErrorOnly) {
        // 文件写入错误：output 只有 error 字段（无 path/filename），
        // 仍触发回调告知用户失败，避免错误被静默吞掉
        this.callbacks.onFileUploadResult(cmdId, false, output)
      }
      const s = ((output['stdout'] as string) ?? '').replace(/\r/g, '')
      const e = ((output['stderr'] as string) ?? '').replace(/\r/g, '')
      if (s.length > 0) {
        this.session.appendOutput(s)
      }
      if (e.length > 0) {
        this.session.appendOutput('\x1b[31m' + e + '\x1b[0m')
      }
    }
    this.callbacks.onExecutingChange(false)
    this.callbacks.onSyncLines()
    this.callbacks.onScrollToBottom()
  }

  /** session_msg：实时会话消息 */
  private onSessionMsg(p: Record<string, Object> | undefined): void {
    if (!p) return
    const content = (p['content'] as string) ?? ''
    if (!content) return
    // 选项选择发送的纯数字消息（1/2/3）不显示到屏幕
    const trimmed = content.trim()
    if (/^\d{1,2}$/.test(trimmed)) {
      return
    }
    // 去重：如果内容与最近发送的消息匹配（15秒窗口内），跳过不显示
    // 手机端发送消息后，后端会广播 session_msg 回来，必须过滤
    // 不清除 _lastSentText，让 user_msg 通道也能检查（两通道可能同时到达）
    if (this._lastSentText.length > 0 && trimmed === this._lastSentText
        && Date.now() - this._lastSentAt < TerminalEventHandler.DEDUP_WINDOW_MS) {
      return
    }
    // 进一步检查：即使内容不完全匹配，如果 _lastSentText 是 content 的子串
    // （TUI 可能添加了前缀如 ❯），也过滤
    if (this._lastSentText.length > 0 && content.includes(this._lastSentText)
        && Date.now() - this._lastSentAt < TerminalEventHandler.DEDUP_WINDOW_MS) {
      return
    }
    this.session.appendSystem('[手机] ' + content, currentTheme().result)
    this.callbacks.onSyncLines()
    this.callbacks.onScrollToBottom()
  }

  /** join_ack：加入会话确认（不显示到终端，仅日志记录） */
  private onJoinAck(p: Record<string, Object> | undefined): void {
    if (!p) return
    const sid = (p['session_id'] as string) ?? ''
    // 仅日志记录，不在终端显示“已加入会话”消息
    console.info('serein: session_id prefix=' + sid.substring(0, 8))
  }

  /** history：历史消息回放（始终跳过，不在终端显示历史内容） */
  private onHistoryEvent(p: Record<string, Object> | undefined): void {
    // 始终跳过历史消息：用户不需要看到旧对话被恢复
    // 重连后只显示新产生的内容
    console.info('serein: history event skipped')
  }
}
