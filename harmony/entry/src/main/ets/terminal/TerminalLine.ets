import type { AnsiSegment } from './AnsiParser'
import type { LineKind } from './TerminalSession'
import { currentTheme, screenWidthVp } from './TerminalTheme'
import { pasteboard } from '@kit.BasicServicesKit'
import { promptAction } from '@kit.ArkUI'

/**
 * TerminalLine — 终端输出单行渲染组件
 * 按 kind 着色（diff +/- 红绿、错误、系统等），长按复制整行纯文本。
 * prompt 行可带折叠箭头（block 化）：点箭头折叠/展开该命令的输出。
 *
 * 表格行（含 box-drawing 字符）使用水平滚动，防止边框错位。
 * thinking 内容（system 类型且较长）默认折叠 3 行，点击展开。
 */
@Component
export struct TerminalLine {
  @Prop segments: AnsiSegment[] = []
  @Prop kind: LineKind = 'normal'
  @Prop text: string = ''
  @Prop fontSize: number = 13
  @Prop copySelected: boolean = false
  @Prop collapsible: boolean = false
  @Prop collapsed: boolean = false
  @Prop thinkingDuration: number = 0  // 思考时长（秒），>0 表示思考完成行
  @Prop choiceGroupId: number = -1  // 选项组 ID，用于精确删除同一审批组
  @Prop selected: boolean = false  // 选项是否已被选中
  @Prop locked: boolean = false  // 选项组是否已锁定
  @State thinkingExpanded: boolean = false
  onToggleCollapse?: () => void
  onChoiceTap?: (num: string, isBlank: boolean, choiceGroupId: number) => void  // 点击选项按钮的回调
  onLineTap?: (text: string) => void

  private bgColor(): string {
    const t = currentTheme()
    if (this.kind === 'diff-add') return t.diffAddBg
    if (this.kind === 'diff-del') return t.diffDelBg
    return ''
  }
  /** 取当前行本应使用的颜色（如果 seg.fg 有自定义颜色则优先用自定义） */
  private rowColor(segFg: string): string {
    const t = currentTheme()
    if (this.kind === 'diff-add') return t.diffAdd
    if (this.kind === 'diff-del') return t.diffDel
    if (this.kind === 'diff-hunk') return t.diffHunk
    if (this.kind === 'diff-meta') return t.diffMeta
    if (this.kind === 'error') return t.error
    // system/heading/prompt：如果 seg 自带了颜色优先用 seg 的
    if (this.kind === 'system') {
      return segFg !== '' ? segFg : t.system
    }
    if (this.kind === 'heading') {
      return segFg !== '' ? segFg : t.accent
    }
    if (this.kind === 'prompt') {
      return segFg !== '' ? segFg : t.prompt
    }
    // normal 行：如果有 SGR 颜色（来自 parseAnsi 解析），优先使用
    if (segFg !== '') return segFg
    return t.text
  }
  private isBold(): boolean {
    return this.kind === 'heading' || this.kind === 'error'
  }
private fontSizeFor(): number {
  if (this.kind === 'heading') return this.fontSize + 2
  if (this.kind === 'choice') return this.fontSize  // 选项字号与正文一致，确保可读性
  const plainText = this.text.trim()
  if (this.isTableLine()) {
    // 表格行：根据屏幕宽度和行内容计算最佳字体大小
    // CJK 字符宽度约为 ASCII 的 2 倍，需分别计算
    const padding = 16
    const availWidth = screenWidthVp() - padding
    // 计算有效字符宽度：CJK=2, ASCII=1
    let effWidth = 0
    for (let i = 0; i < plainText.length; i++) {
      const code = plainText.charCodeAt(i)
      // CJK 统一表意文字、全角标点等
      if (code >= 0x4E00 && code <= 0x9FFF || code >= 0x3000 && code <= 0x30FF || code >= 0xFF00 && code <= 0xFFEF) {
        effWidth += 2
      } else {
        effWidth += 1
      }
    }
    // 等宽字体每个 ASCII 字符约 0.55 × fontSize vp 宽
    const idealSize = Math.floor(availWidth / (effWidth * 0.55))
    // 限制在 8 ~ currentFontSize 之间
    return Math.max(8, Math.min(idealSize, this.fontSize))
  }
  if (plainText.length > 120) return this.fontSize - 2
  if (plainText.length > 80) return this.fontSize - 1
  return this.fontSize
}

  /** 是否为表格行（含 box-drawing 字符或管道符表格）→ 使用水平滚动而非换行 */
  private isTableLine(): boolean {
    // box-drawing 字符表格：┌┐└┘├┤┬┴┼─│═║等
    if (/[│┌┐└┘├┤┬┴┼─═║╔╗╚╝╠╣╦╩╬]/.test(this.text)) return true
    // 管道符表格：| col1 | col2 | 格式（至少 2 个管道符）
    const pipeCount = (this.text.match(/\|/g) || []).length
    if (pipeCount >= 2 && /^\s*\|.*\|\s*$/.test(this.text)) return true
    return false
  }

  /** 是否为 thinking 内容行（有思考时长或以 ⎿ 开头）→ 默认折叠，点击展开
   *  thinkingDuration: -1=进行中, >0=已完成, 0=非思考行 */
  private isThinkingLine(): boolean {
    if (this.kind !== 'system') return false
    // thinkingDuration !== 0 → 是思考行（-1 进行中 / >0 已完成）
    if (this.thinkingDuration !== 0) return true
    if (this.text.trimStart().startsWith('⎿')) return true
    return false
  }

  private copyText(): void {
    try {
      const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.text)
      const sys = pasteboard.getSystemPasteboard()
      sys.setDataSync(pasteData)
      promptAction.showToast({ message: '已复制', duration: 1000 })
    } catch (e) {
      console.error('serein: TerminalLine 复制失败: ' + (e as Error).message)
      promptAction.showToast({ message: '复制失败', duration: 1000 })
    }
  }

  /** 从选项行中提取编号数字（如 "❯ 1. Yes"→"1", "1  Submit"→"1", "4. "→"4"） */
  private choiceNum(): string {
    const m = this.text.trim().match(/(\d+)[.\s]/)
    return m ? m[1] : ''
  }

  /** 是否为空白选项（如 "4. " 或 "4  " — 需要用户自行输入内容）
   *  "Type something." 也视为空白选项，因为它是 TUI 的自由输入入口 */
  private isBlankChoice(): boolean {
    const trimmed = this.text.trim()
    const afterNum = trimmed.replace(/^(❯\s*)?\d+[.\s]\s*/, '')
    if (afterNum === '') return true
    // "Type something." 是 Claude Code TUI 原生的自由输入选项
    if (afterNum.toLowerCase() === 'type something.') return true
    return false
  }

  build() {
    Row() {
      // 选项按钮：编号圆形徽章（未选中=珊瑚色透明，选中=珊瑚色实心）
      if (this.kind === 'choice') {
        Text(this.choiceNum())
          .width(28).height(28)
          .textAlign(TextAlign.Center)
          .borderRadius(14)
          .backgroundColor(this.selected ? 'rgba(140,144,159,0.30)' : 'rgba(217,119,87,0.15)')
          .fontColor(this.selected ? '#8C909F' : '#D97757')
          .fontWeight(FontWeight.Bold)
          .fontFamily('monospace')
          .fontSize(this.fontSizeFor())
          .margin({ right: 8 })
      }

      if (this.collapsible) {
        Text(this.collapsed ? '▸' : '▾')
          .fontSize(this.fontSize - 2)
          .fontColor(currentTheme().textDim)
          .width(16)
          .margin({ right: 2 })
          .onClick(() => { if (this.onToggleCollapse) this.onToggleCollapse() })
      }

      // 表格行：自动换行，不使用水平滚动
      if (this.isTableLine()) {
        Text() {
          ForEach(this.segments, (seg: AnsiSegment, idx: number) => {
            Span(seg.text)
              .fontColor(this.rowColor(seg.fg))
              .fontWeight((seg.bold || this.isBold()) ? FontWeight.Bold : FontWeight.Normal)
              .decoration({
                type: seg.underline ? TextDecorationType.Underline : TextDecorationType.None
              })
              .fontFamily('monospace')
          }, (seg: AnsiSegment, idx: number) => idx.toString() + '_' + seg.text.length)
        }
        .fontSize(this.fontSizeFor())
        .lineHeight(this.fontSizeFor() + 3)
        .layoutWeight(1)
        .wordBreak(WordBreak.BREAK_ALL)
        .textOverflow({ overflow: TextOverflow.Clip })
        .maxLines(500)
        .gesture(LongPressGesture({ repeat: false, duration: 500 })
          .onAction(() => { this.copyText() }))
      } else if (this.isThinkingLine()) {
        // thinking 内容：默认折叠显示 "Thought for Ns"，点击展开思考过程
        // 折叠=1行头部，展开=完整内容向下挤开（Column 自然撑高）
        Column() {
          // 头部行：▸/▾ + "Thought for Ns" 或 "思考中…"
          Row() {
            Text(this.thinkingExpanded ? '▾' : '▸')
              .fontSize(this.fontSizeFor() - 2)
              .fontColor(currentTheme().textDim)
              .width(16)
            Text(this.thinkingDuration > 0
              ? 'Thought for ' + this.thinkingDuration + 's'
              : '思考中…')
              .fontSize(this.fontSize + 1)
              .fontColor(currentTheme().textDim)
              .fontFamily('monospace')
              .layoutWeight(1)
          }
          .width('100%')
          .height(this.fontSizeFor() + 6)  // 紧凑高度：1行

          if (this.thinkingExpanded) {
            // 展开状态：显示完整思考内容，向下挤开后续行
            Text() {
              ForEach(this.segments, (seg: AnsiSegment, idx: number) => {
                Span(seg.text)
                  .fontColor(this.rowColor(seg.fg))
                  .fontWeight((seg.bold || this.isBold()) ? FontWeight.Bold : FontWeight.Normal)
                  .decoration({
                    type: seg.underline ? TextDecorationType.Underline : TextDecorationType.None
                  })
                  .fontFamily('monospace')
              }, (seg: AnsiSegment, idx: number) => idx.toString() + '_' + seg.text.length)
            }
            .fontSize(this.fontSize)
            .lineHeight(this.fontSize + 4)
            .width('100%')
            .wordBreak(WordBreak.BREAK_ALL)
            .maxLines(500)
            .margin({ top: 2 })
            .gesture(LongPressGesture({ repeat: false, duration: 500 })
              .onAction(() => { this.copyText() }))
          }
        }
        .layoutWeight(1)
        .onClick(() => { this.thinkingExpanded = !this.thinkingExpanded })
      } else {
        // 普通行：自动换行
        Text() {
          ForEach(this.segments, (seg: AnsiSegment, idx: number) => {
            Span(seg.text)
              .fontColor(this.rowColor(seg.fg))
              .fontWeight((seg.bold || this.isBold()) ? FontWeight.Bold : FontWeight.Normal)
              .decoration({
                type: seg.underline ? TextDecorationType.Underline : TextDecorationType.None
              })
              .fontFamily('monospace')
          }, (seg: AnsiSegment, idx: number) => idx.toString() + '_' + seg.text.length)
        }
        .fontSize(this.fontSizeFor())
        .lineHeight(this.fontSizeFor() + 6)
        .layoutWeight(1)
        .wordBreak(WordBreak.BREAK_ALL)
        .textOverflow({ overflow: TextOverflow.Clip })
        .maxLines(500)
        .gesture(LongPressGesture({ repeat: false, duration: 500 })
          .onAction(() => { this.copyText() }))
      }
    }
    .width('100%')
    .padding({ left: this.kind === 'choice' ? 10 : 8, right: this.kind === 'choice' ? 10 : 8, top: this.isThinkingLine() ? 1 : (this.kind === 'choice' ? 4 : 3), bottom: this.isThinkingLine() ? 1 : (this.kind === 'choice' ? 4 : 3) })
    .backgroundColor(this.copySelected ? 'rgba(217,119,87,0.12)' : (this.kind === 'choice' ? (this.selected ? 'rgba(140,144,159,0.06)' : 'rgba(217,119,87,0.06)') : this.bgColor()))
    .borderRadius(this.kind === 'choice' ? 10 : 4)
    .border(this.copySelected ? { width: 1, color: 'rgba(217,119,87,0.38)' } : (this.kind === 'choice' ? { width: 1, color: this.selected ? 'rgba(140,144,159,0.15)' : 'rgba(217,119,87,0.20)' } : { width: 0 }))
    .margin({ top: this.kind === 'choice' ? 4 : 0, bottom: this.kind === 'choice' ? 4 : 0 })
    .onClick(() => {
      if (this.kind === 'choice' && this.onChoiceTap && this.choiceNum()) {
        this.onChoiceTap(this.choiceNum(), this.isBlankChoice(), this.choiceGroupId)
      } else if (!this.isThinkingLine() && this.onLineTap && this.text !== '') {
        this.onLineTap(this.text)
      }
    })
  }
}
