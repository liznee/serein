import { parseAnsi, stripAnsi, type AnsiSegment } from './AnsiParser'

/** 显示分级：2=详细全部，1=摘要(隐藏普通行)，0=极简(仅标题/错误/系统) */
export type VerbosityLevel = 0 | 1 | 2

/** 行类型 —— 决定渲染颜色与背景 */
export type LineKind =
  | 'normal'
  | 'prompt'
  | 'system'
  | 'error'
  | 'diff-add'
  | 'diff-del'
  | 'diff-hunk'
  | 'diff-meta'
  | 'heading'
  | 'choice'  // 可点击选项（1. Yes / 2. No）

/**
 * 终端输出行数据
 */
export interface TerminalLineData {
  segments: AnsiSegment[]
  timestamp: number
  isPrompt: boolean   // 是否为命令提示行（echo 回来的命令）
  kind: LineKind
  blockId: number     // 所属 block（命令+其输出），-1 = 不分组
  text: string        // 纯文本副本，供复制用
  selected: boolean   // 选项是否已被选中（点击后变灰标记）
  locked: boolean     // 选项组已锁定（同组任一选项被选后，全部不可再点）
  thinkingDuration: number  // 思考时长（秒），>0 表示是思考完成行
  choiceGroupId: number  // 选项组 ID，同一组审批选项共享；-1 = 非选项行
  /** App Server 增量消息键；相同键的后续 delta 会原位替换该行。 */
  streamKey?: string
}

function mkLine(segments: AnsiSegment[], kind: LineKind, blockId: number, text: string, overrideTimestamp?: number): TerminalLineData {
return { segments, timestamp: overrideTimestamp ?? Date.now(), isPrompt: kind === 'prompt', kind, blockId, text, selected: false, locked: false, thinkingDuration: 0, choiceGroupId: -1 }
}

/**
 * TerminalSession — 终端会话状态
 * 管理输出缓冲和命令历史
 */
@Observed
export class TerminalSession {
  lines: TerminalLineData[] = []
  commandHistory: string[] = []
  historyIndex: number = -1  // -1 = 新命令，>=0 = 历史位置
  connected: boolean = false
  verbosity: VerbosityLevel = 2
  hasBanner: boolean = false  // 是否显示启动横幅（首次会话或者新项目为 true）
  bannerProject: string = '' // 横幅中显示的项目名
  blockSeq: number = 0  // 非 private 以便持久化
  currentBlockId: number = -1  // 当前命令的 block id
  private _choiceGroupSeq: number = 0  // 选项组计数器，每次新审批弹窗递增
  private _currentChoiceGroupId: number = -1  // 当前选项组 ID，-1 = 无活跃组
  private _lastChoiceNum: number = 0  // 上一个选项的编号，用于检测新组
  // 全局去重 Set：记录已输出到屏幕的行文本（纯文本），防止 TUI 重绘导致重复
  private _outputTextSet: Set<string> = new Set()
  private static readonly DEDUP_SET_MAX: number = 2000

  /** 开启新 block（每次提交命令时调用），返回新 blockId */
  startBlock(): number {
    this.blockSeq++
    this.currentBlockId = this.blockSeq
    // 新消息开始时清空去重 Set：SDK 模式下不同回复可能包含相同行，
    // 全局去重会误杀后续回复中的合法内容。仅在同一回复内去重。
    this._outputTextSet.clear()
    return this.currentBlockId
  }

  /** 添加普通输出行（带 ANSI 解析 + diff 围栏识别） */
  appendOutput(rawText: string): void {
    const cleaned: string = rawText.replace(/\r/g, '')
    // 按行切分，识别 ```diff 围栏，diff 行单独着色
    const lines: string[] = cleaned.split('\n')
    let inDiff: boolean = false
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i]
      const trimmed = line.trim()
      // 围栏检测：```diff 或 ``` 开/闭
      if (trimmed.startsWith('```')) {
        const lang = trimmed.substring(3).toLowerCase()
        if (lang === 'diff') {
          inDiff = true
          continue
        }
        if (lang === '') {
          // 闭围栏
          inDiff = false
          continue
        }
        // 其它语言围栏当普通文本
        this.pushAnsiLine(line)
        continue
      }
      if (inDiff) {
        this.pushDiffLine(line)
      } else {
        this.pushAnsiLine(line)
      }
    }
  }

  /**
   * 原位更新一条 App Server 流式回复。
   *
   * App Server 会为同一个 agentMessage item 连续推送 delta。这里保留一条
   * 带 streamKey 的可换行文本，而不是把每个 token 追加成新行。完成事件
   * 会用相同 key 写入权威全文，因此断包或重连后也能收敛到正确结果。
   */
  appendOrReplaceStreamingOutput(streamKey: string, content: string): void {
    const key = streamKey.trim()
    const cleaned = content.replace(/\r/g, '').replace(/^\n+/, '')
    if (key === '' || cleaned === '') return
    const replacement = mkLine(
      [{ text: cleaned, fg: '', bg: '', bold: false, underline: false }],
      'normal', this.currentBlockId, cleaned,
    )
    replacement.streamKey = key
    let found = false
    const next: TerminalLineData[] = []
    for (let i = 0; i < this.lines.length; i++) {
      const line = this.lines[i]
      if (line.streamKey === key) {
        if (!found) {
          replacement.timestamp = line.timestamp
          next.push(replacement)
          found = true
        }
      } else {
        next.push(line)
      }
    }
    if (!found) next.push(replacement)
    this.lines = next
  }

  private pushAnsiLine(line: string): void {
    // 轻量 Markdown：标题行(# 1-6 级)单独着色加粗
    let kind: LineKind = 'normal'
    if (line.length >= 2 && line.charAt(0) === '#') {
      let hashes = 0
      while (hashes < line.length && hashes < 6 && line.charAt(hashes) === '#') hashes++
      if (hashes < line.length && line.charAt(hashes) === ' ') {
        kind = 'heading'
      }
    }
    // 选项自动检测已移除：真正的选项通过 appendChoice 专线传入
    // （来自 JSONL watcher 的 choice 事件，如 AskUserQuestion / WebFetch 权限提示）
    // appendOutput 只接收 AI 文本回复和命令输出，其中的编号列表不应被误判为选项
    const plain = stripAnsi(line).trim()
    // 全局去重：TUI 重绘会导致相同行重复输出，用 Set 标记已输出的行
    if (this._outputTextSet.has(plain)) {
      return  // 已输出过，跳过
    }
    this._outputTextSet.add(plain)
    if (this._outputTextSet.size > TerminalSession.DEDUP_SET_MAX) {
      // 超上限时清空重建（保留最近 500 条）
      const recent = this.lines.slice(-500).map(l => l.text.trim()).filter(t => t.length > 0)
      this._outputTextSet = new Set(recent)
    }
    const segments: AnsiSegment[] = parseAnsi(line)
    // text 字段用 stripAnsi 剥离所有逃逸序列，确保长按复制时不泄漏 ANSI SGR 码
    const newLine = mkLine(segments, kind, this.currentBlockId, stripAnsi(line))
    this.lines = this.lines.concat([newLine])
  }

  /** 推送单个选项行（从多选项拆分调用） */
  private pushSingleChoiceLine(optText: string): void {
    // choice 行：仅防止与上一行完全相同的连续重复（TUI 重绘）
    const plain = stripAnsi(optText).trim()
    const lastLine = this.lines.length > 0 ? this.lines[this.lines.length - 1] : null
    if (lastLine && lastLine.kind === 'choice' && lastLine.text.trim() === plain) {
      return
    }
    // 检测新选项组开始：上一行不是 choice，或选项编号回到 1
    const choiceNumMatch = plain.match(/^(?:❯\s*)?(\d+)[.\s]/)
    const curNum = choiceNumMatch ? parseInt(choiceNumMatch[1]) : 0
    if (curNum === 1 || lastLine === null || lastLine.kind !== 'choice') {
      this._choiceGroupSeq++
      this._currentChoiceGroupId = this._choiceGroupSeq
    }
    this._lastChoiceNum = curNum
    const segments: AnsiSegment[] = parseAnsi(optText)
    const newLine = mkLine(segments, 'choice', this.currentBlockId, optText)
    newLine.choiceGroupId = this._currentChoiceGroupId
    this.lines = this.lines.concat([newLine])
  }

  private pushDiffLine(line: string): void {
    let kind: LineKind = 'normal'
    if (line.startsWith('+++') || line.startsWith('---') || line.startsWith('diff ') || line.startsWith('index ')) {
      kind = 'diff-meta'
    } else if (line.startsWith('@@')) {
      kind = 'diff-hunk'
    } else if (line.startsWith('+')) {
      kind = 'diff-add'
    } else if (line.startsWith('-')) {
      kind = 'diff-del'
    } else {
      kind = 'normal'
    }
    // diff 行用单段着色，保留 +/- 前缀
    this.lines = this.lines.concat([mkLine([{ text: line, fg: '', bg: '', bold: false, underline: false }], kind, this.currentBlockId, line)])
  }

  /** 添加命令回显行 */
  appendPrompt(cmd: string): void {
    this.lines = this.lines.concat([mkLine(
      [{ text: cmd, fg: '', bg: '', bold: false, underline: false }],
      'prompt', this.currentBlockId, cmd
    )])
  }

  /** 添加系统消息（连接、错误等） */
  appendSystem(msg: string, color: string = '#8C909F'): void {
    this.lines = this.lines.concat([mkLine(
      [{ text: msg, fg: color, bg: '', bold: false, underline: false }],
      'system', -1, msg
    )])
  }

  /** 添加错误行 */
  appendError(msg: string): void {
    this.lines = this.lines.concat([mkLine(
      [{ text: msg, fg: '#b53333', bg: '', bold: true, underline: false }],
      'error', -1, msg
    )])
  }

  /** 记录命令到历史 */
  addToHistory(cmd: string): void {
    const trimmed = cmd.trim()
    if (trimmed === '') {
      return
    }
    // 去重相邻重复
    const lastIdx = this.commandHistory.length - 1
    if (lastIdx >= 0 && this.commandHistory[lastIdx] === trimmed) {
      return
    }
    const MAX_HISTORY = 500
    let next = this.commandHistory.concat([trimmed])
    if (next.length > MAX_HISTORY) {
      next = next.slice(next.length - MAX_HISTORY)
    }
    this.commandHistory = next
    this.historyIndex = -1
  }

  /** 历史导航：上/下 */
  navigateHistory(direction: 'up' | 'down', currentInput: string): string {
    if (this.commandHistory.length === 0) {
      return currentInput
    }

    if (direction === 'up') {
      if (this.historyIndex === -1) {
        // 首次上翻：从最新开始
        this.historyIndex = this.commandHistory.length - 1
      } else if (this.historyIndex > 0) {
        this.historyIndex--
      }
      return this.commandHistory[this.historyIndex]
    } else {
      // down
      if (this.historyIndex === -1) {
        return currentInput
      }
      if (this.historyIndex < this.commandHistory.length - 1) {
        this.historyIndex++
        return this.commandHistory[this.historyIndex]
      } else {
        this.historyIndex = -1
        return ''
      }
    }
  }

  /** 模糊过滤历史：按子串匹配（大小写不敏感），最新在前 */
  filterHistory(query: string): string[] {
    const q = query.toLowerCase()
    const out: string[] = []
    for (let i = this.commandHistory.length - 1; i >= 0; i--) {
      const cmd = this.commandHistory[i]
      if (q === '' || cmd.toLowerCase().indexOf(q) >= 0) {
        out.push(cmd)
      }
    }
    return out
  }

  /** 按 verbosity 过滤行数组（不修改原数组） */
  static filterByVerbosity(lines: TerminalLineData[], verbosity: VerbosityLevel): TerminalLineData[] {
    if (verbosity >= 2) return lines
    const out: TerminalLineData[] = []
    let visibleCount = 0
    for (let i = 0; i < lines.length; i++) {
      const ln = lines[i]
      let pass = false
      if (verbosity >= 1) {
        // Level 1（摘要）：prompt/system/error/heading/diff-meta/hunk 保留
        pass = ln.kind !== 'normal' && ln.kind !== 'diff-add' && ln.kind !== 'diff-del'
      } else {
        // Level 0（极简）：只保留 heading/error/system/prompt
        // prompt 保留——让用户在极简模式下也能看到自己发了什么命令，不会以为卡住
        pass = ln.kind === 'heading' || ln.kind === 'error' || ln.kind === 'system' || ln.kind === 'prompt'
      }
      if (pass) {
        out.push(ln); visibleCount++
      }
    }
    if (visibleCount === 0 && lines.length > 0) {
      // 全过滤掉时留一条提示
      const last = lines[lines.length - 1]
      out.push({
        segments: [{ text: '(verbosity ' + verbosity + ' — 切换至详细查看全部 ' + lines.length + ' 行)', fg: '#8C909F', bg: '', bold: false, underline: false }],
        timestamp: last.timestamp, isPrompt: false, kind: 'system', blockId: -1,
        text: '', selected: false, locked: false, thinkingDuration: 0, choiceGroupId: -1
      })
    }
    return out
  }

  /** 添加选项行（来自 relay choice 事件，直接创建为可点击选项，绕过自动检测） */
  appendChoice(rawText: string): number {
    const cleaned: string = rawText.replace(/\r/g, '')
    const lines: string[] = cleaned.split('\n')
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim()
      if (line === '') continue
      const plain = stripAnsi(line).trim()
      if (plain === '') continue
      // 检测新选项组开始：上一行不是 choice，或选项编号回到 1
      const lastLine = this.lines.length > 0 ? this.lines[this.lines.length - 1] : null
      const choiceNumMatch = plain.match(/^(?:❯\s*)?(\d+)[.\s]/)
      const curNum = choiceNumMatch ? parseInt(choiceNumMatch[1]) : 0
      if (curNum === 1 || lastLine === null || lastLine.kind !== 'choice') {
        this._choiceGroupSeq++
        this._currentChoiceGroupId = this._choiceGroupSeq
      }
      this._lastChoiceNum = curNum
      const segments: AnsiSegment[] = parseAnsi(line)
      const newLine = mkLine(segments, 'choice', this.currentBlockId, plain)
      newLine.choiceGroupId = this._currentChoiceGroupId
      this.lines = this.lines.concat([newLine])
    }
    return this._currentChoiceGroupId
  }

  /**
   * 选项仍在屏幕上时，Agent 处于“等待用户输入”而不是“正在思考”。
   * 供发送路径决定是否应立即显示通用 thinking 指示器。
   */
  hasPendingChoice(): boolean {
    for (let i = 0; i < this.lines.length; i++) {
      if (this.lines[i].kind === 'choice' && !this.lines[i].locked) return true
    }
    return false
  }

  /** 清屏 */
  clear(): void {
    this.lines = []
    this._thinkingLineIdx = -1  // 清屏时重置思考索引，防止残留索引导致后续 thinking 误替换
    this._outputTextSet.clear()  // 清空去重 Set
  }

  /** 思考块索引（-1 表示不存在）：用于 thinking 就地更新 */
  private _thinkingLineIdx: number = -1

  /** 追加或替换思考内容：首次追加，后续更新替换原位置
   *  thinkingDuration = -1 标记「思考进行中」，>0 标记「思考完成」
   *  清理内容：去除首尾空白、合并连续空行（防止过多空白行） */
  appendOrReplaceThinking(content: string): void {
    const cleaned: string = content
      .replace(/\r/g, '')
      .replace(/\t/g, ' ')
      .replace(/ +\n/g, '\n')        // 行尾空格
      .replace(/\n +/g, '\n')        // 行首空格
      .replace(/\n{3,}/g, '\n\n')    // 最多连续2个换行
      .replace(/^\s+|\s+$/g, '')     // 去首尾空白
    if (this._thinkingLineIdx >= 0 && this._thinkingLineIdx < this.lines.length) {
      const origLine = this.lines[this._thinkingLineIdx]
      // 保留 origLine.thinkingDuration：如果已 finalizeThinking(>0) 则不覆盖回 -1
      const dur: number = origLine.thinkingDuration > 0 ? origLine.thinkingDuration : -1
      this.lines = this.lines.map((l, i) =>
        i === this._thinkingLineIdx
          ? { segments: [{ text: cleaned, fg: '#8C909F', bg: '', bold: false, underline: false }],
              timestamp: origLine.timestamp, isPrompt: false, kind: 'system' as LineKind,
              blockId: -1, text: cleaned, selected: false, locked: false, thinkingDuration: dur, choiceGroupId: -1 }
          : l
      )
    } else {
      this._thinkingLineIdx = this.lines.length
      this.lines = this.lines.concat([{
        segments: [{ text: cleaned, fg: '#8C909F', bg: '', bold: false, underline: false }],
        timestamp: Date.now(), isPrompt: false, kind: 'system' as LineKind,
        blockId: -1, text: cleaned, selected: false, locked: false, thinkingDuration: -1, choiceGroupId: -1
      }])
    }
  }

  /** 结束思考块：重置索引，下次 thinking 内容将是新块 */
  endThinking(): void {
    this._thinkingLineIdx = -1
  }

  /** 最终化思考块：设置时长，手机端显示 "Thought for Ns" 可折叠头 */
  finalizeThinking(duration: number): void {
    if (this._thinkingLineIdx >= 0 && this._thinkingLineIdx < this.lines.length) {
      const origLine = this.lines[this._thinkingLineIdx]
      this.lines = this.lines.map((l, i) =>
        i === this._thinkingLineIdx
          ? { segments: l.segments, timestamp: l.timestamp, isPrompt: l.isPrompt, kind: l.kind, blockId: l.blockId, text: l.text, selected: l.selected, locked: l.locked, thinkingDuration: duration, choiceGroupId: l.choiceGroupId }
          : l
      )
    }
    this._thinkingLineIdx = -1
  }


  /**
   * 如果存在活跃的 thinking 块则结束它。
   * 供持久化前调用（saveCurrentSession 保存行内容前确保 thinking 状态干净），
   * 防止 session 恢复后 _thinkingLineIdx 丢失导致后续 thinking 追加新块而非替换旧块。
   */
  endThinkingIfActive(): void {
    this._thinkingLineIdx = -1  // 赋值 -1 是幂等操作，无需 null 检查
  }

  /** 移除指定 choiceGroupId 的所有 choice 行（选完后直接消失）
   *  仅删除同一审批组的选项，不影响其他审批组的选项 */
  removeChoiceLines(choiceGroupId: number): void {
    if (choiceGroupId < 0) return
    this.lines = this.lines.filter(l => !(l.kind === 'choice' && l.choiceGroupId === choiceGroupId))
  }

  /** 输出行数（用于 LazyForEach 或判断自动滚动） */
  get lineCount(): number {
    return this.lines.length
  }
}
