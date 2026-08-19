import type { ApprovalRecord } from '../api/types'
import { formatRelative } from '../utils/TimeUtil'
import ApprovalApi from '../api/ApprovalApi'
import { isApiError } from '../api/HttpClient'
import type { ApiError } from '../api/HttpClient'
import { COLOR, TYPO, SPACE, RADIUS, TOUCH } from '../utils/DesignTokens'
import { tokenizeCommand } from '../utils/CmdHighlight'

const MAX_CMD_PREVIEW = 80
const MAX_DIFF_LINES_COLLAPSED = 8
const MAX_DIFF_LINES_EXPANDED = 60

/** Diff 行解析结果 */
interface DiffLine {
  text: string
  color: string
  bgColor: string
}

@Component
export struct ApprovalCard {
  @Prop record: ApprovalRecord
  @Prop showActions: boolean = true
  onDecided?: () => void
  onTap?: () => void
  @State allowLoading: boolean = false
  @State denyLoading: boolean = false
  @State isExpanded: boolean = false
  @State diffExpanded: boolean = false
  @State errorMsg: string = ''
  @State allowPressed: boolean = false
  @State denyPressed: boolean = false
  private decideTimer: number = -1

  aboutToDisappear(): void {
    // 清理 409 冲突时挂起的回调定时器，避免组件销毁后仍触发 onDecided
    if (this.decideTimer !== -1) {
      clearTimeout(this.decideTimer)
      this.decideTimer = -1
    }
  }

  private riskLevel(): string { return this.record.risk_level }
  private riskColor(): Resource {
    if (this.riskLevel() === 'red') return COLOR.danger
    if (this.riskLevel() === 'yellow') return COLOR.warning
    return COLOR.success
  }
  private riskLabel(): string {
    if (this.riskLevel() === 'red') return 'HIGH RISK'
    if (this.riskLevel() === 'yellow') return 'REVIEW'
    return 'LOW RISK'
  }
  private riskBackground(): string {
    if (this.riskLevel() === 'red') return 'rgba(181,51,51,0.08)'
    if (this.riskLevel() === 'yellow') return 'rgba(217,119,48,0.08)'
    return 'rgba(23,163,74,0.08)'
  }
  private riskBorder(): string {
    if (this.riskLevel() === 'red') return 'rgba(181,51,51,0.20)'
    if (this.riskLevel() === 'yellow') return 'rgba(217,119,48,0.20)'
    return 'rgba(23,163,74,0.20)'
  }
  private statusColor(): Resource {
    if (this.record.decision === 'allow') return COLOR.success
    if (this.record.decision === 'deny') return COLOR.danger
    if (this.record.decision === 'timeout') return COLOR.textTertiary
    return COLOR.warning
  }
  private statusLabel(): string {
    if (this.record.decision === 'allow') return 'Allowed'
    if (this.record.decision === 'deny') return 'Denied'
    if (this.record.decision === 'timeout') return 'Timed Out'
    return 'Pending'
  }
  private truncateCommand(cmd: string): string { return cmd.length <= MAX_CMD_PREVIEW ? cmd : cmd.substring(0, MAX_CMD_PREVIEW) + '...' }

  /** 判断是否为文件编辑类工具 */
  private isEditTool(): boolean {
    const t = this.record.tool_name
    return t === 'Write' || t === 'Edit' || t === 'MultiEdit' || t === 'string_replace' || t === 'NotebookEdit'
  }

  /** 将 unified diff 文本解析为带颜色的行数组 */
  private parseDiffLines(diff: string): DiffLine[] {
    if (!diff) return []
    const lines: string[] = diff.split('\n')
    const maxLines = this.diffExpanded ? MAX_DIFF_LINES_EXPANDED : MAX_DIFF_LINES_COLLAPSED
    const result: DiffLine[] = []
    for (let i = 0; i < Math.min(lines.length, maxLines); i++) {
      const line = lines[i]
      if (line.startsWith('+++') || line.startsWith('---')) {
        result.push({ text: line, color: '#d97730', bgColor: 'transparent' })
      } else if (line.startsWith('+')) {
        result.push({ text: line, color: '#17a34a', bgColor: 'rgba(23,163,74,0.10)' })
      } else if (line.startsWith('-')) {
        result.push({ text: line, color: '#b53333', bgColor: 'rgba(181,51,51,0.10)' })
      } else if (line.startsWith('@@')) {
        result.push({ text: line, color: '#D97757', bgColor: 'transparent' })
      } else {
        result.push({ text: line, color: '#8C909F', bgColor: 'transparent' })
      }
    }
    if (lines.length > maxLines) {
      result.push({ text: `... ${lines.length - maxLines} more lines`, color: '#8C909F', bgColor: 'transparent' })
    }
    return result
  }

  @Builder
  cmdBlock() {
    Column() {
      Text() {
        ForEach(tokenizeCommand(this.isExpanded ? this.record.command : this.truncateCommand(this.record.command)),
          (token: [string, string], idx: number) => { Span(token[0]).fontColor(token[1]).fontFamily('monospace') },
          (token: [string, string], idx: number) => idx.toString())
      }
      .fontSize(13).maxLines(this.isExpanded ? 10 : 2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
    }
    .width('100%').padding(SPACE.md)
    .backgroundColor('#070A0E').borderRadius(RADIUS.sm)
    .border({ width: 1, color: 'rgba(66,71,84,0.15)' })
  }

  @Builder
  diffBlock() {
    if (this.record.diff && this.record.diff.length > 0) {
      Column() {
        // Diff header row
        Row() {
          Row() {
            Text('Code Changes').fontSize(11).fontColor(COLOR.textSecondary).fontWeight(600)
            if (this.isEditTool()) {
              Text(' · edit').fontSize(10).fontColor(COLOR.textTertiary).margin({ left: 4 })
            }
          }
          Blank()
          Text(this.diffExpanded ? 'collapse' : 'expand').fontSize(11).fontColor(COLOR.primary)
            .hitTestBehavior(HitTestMode.Block)
            .onClick(() => { this.diffExpanded = !this.diffExpanded })
        }.width('100%').margin({ top: SPACE.sm })

        // Diff content
        Scroll() {
          Column() {
            ForEach(this.parseDiffLines(this.record.diff), (line: DiffLine, idx: number) => {
              Row() {
                Text(line.text).fontSize(11).fontFamily('monospace').fontColor(line.color)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
              }
              .width('100%')
              .padding({ left: SPACE.sm, right: SPACE.sm, top: 1, bottom: 1 })
              .backgroundColor(line.bgColor)
            }, (line: DiffLine, idx: number) => idx.toString())
          }
        }
        .width('100%')
        .height(this.diffExpanded ? 300 : 160)
        .margin({ top: SPACE.xs })
        .backgroundColor('#070A0E')
        .borderRadius(RADIUS.sm)
        .border({ width: 1, color: 'rgba(66,71,84,0.15)' })
      }
      .width('100%')
    }
  }

  build() {
    Column() {
      // Top row: risk badge + command ID
      Row() {
        Row() {
          Text(this.riskLabel()).fontSize(10).fontColor(this.riskColor()).fontWeight(600)
            .letterSpacing(0.5).padding({ left: SPACE.sm, right: SPACE.sm, top: 2, bottom: 2 })
            .borderRadius(RADIUS.sm)
            .backgroundColor(this.riskBackground())
            .border({ width: 1, color: this.riskBorder() })
        }
        Blank()
        Text('#' + this.record.id.substring(0, 8)).fontSize(13).fontColor(COLOR.textTertiary).fontFamily('monospace')
      }.width('100%')

      // Command code block
      this.cmdBlock()

      if (this.record.command.length > MAX_CMD_PREVIEW) {
        Text(this.isExpanded ? 'collapse' : 'expand').fontSize(11).fontColor(COLOR.primary)
          .alignSelf(ItemAlign.Start).margin({ top: SPACE.xs }).hitTestBehavior(HitTestMode.Block)
          .onClick(() => { this.isExpanded = !this.isExpanded })
      }

      // Diff preview (for Write/Edit tools)
      this.diffBlock()

      if (this.record.rule_reason !== '') {
        Column() {
          Text('Why this needs review').fontSize(11).fontWeight(600).fontColor(this.riskColor())
          Text(this.record.rule_reason).fontSize(12).fontColor(COLOR.textSecondary)
            .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: SPACE.xs })
        }
        .width('100%').alignItems(HorizontalAlign.Start).padding(SPACE.sm).margin({ top: SPACE.sm })
        .backgroundColor(this.riskBackground()).borderRadius(RADIUS.sm)
        .border({ width: 1, color: this.riskBorder() })
      }

      // Metadata row
      Row() {
        Text('folder ' + (this.record.cwd ? this.record.cwd : '~')).fontSize(12).fontColor(COLOR.textSecondary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        Text('tool ' + (this.record.tool_name ? this.record.tool_name : 'cli')).fontSize(12).fontColor(COLOR.textSecondary)
          .maxLines(1).margin({ left: SPACE.md })
      }.width('100%').margin({ top: SPACE.sm })

      if (this.record.project && this.record.project !== '') {
        Text('project ' + this.record.project).fontSize(11).fontColor(COLOR.textTertiary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%').margin({ top: SPACE.xs })
      }

      Divider().color('rgba(140,144,159,0.08)').margin({ top: SPACE.md, bottom: SPACE.md })

      // Bottom: status + time + actions
      Row() {
        // Status indicator
        Row() {
          Circle({ width: 6, height: 6 }).fill(this.statusColor())
          Text(this.statusLabel())
            .fontSize(12).fontColor(this.statusColor()).margin({ left: SPACE.xs })
        }
        Blank()
        Text(formatRelative(this.record.created_at)).fontSize(11).fontColor(COLOR.textTertiary)
        if (this.showActions && this.record.decision === 'pending') {
          Button() {
            if (this.denyLoading) {
              LoadingProgress().width(16).height(16).color(COLOR.danger)
            } else {
              Text('Deny').fontSize(11).fontColor(COLOR.danger)
            }
          }
          .height(32)
          .fontColor(COLOR.danger).backgroundColor(COLOR.dangerContainer).borderRadius(RADIUS.sm)
          .border({ width: 1, color: 'rgba(181,51,51,0.25)' }).margin({ left: SPACE.sm })
          .scale(this.denyPressed ? { x: 0.96, y: 0.96 } : { x: 1, y: 1 })
          .animation({ duration: 100, curve: Curve.EaseOut })
          .enabled(!this.allowLoading && !this.denyLoading)
          .onClick(() => { this.handleDeny() })
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) { this.denyPressed = true }
            else if (event.type === TouchType.Up || event.type === TouchType.Cancel) { this.denyPressed = false }
          })
          Button() {
            if (this.allowLoading) {
              LoadingProgress().width(16).height(16).color(COLOR.textInverse)
            } else {
              Text('Allow').fontSize(11).fontColor(COLOR.textInverse)
            }
          }
          .height(32)
          .fontColor(COLOR.textInverse).backgroundColor(COLOR.primary).borderRadius(RADIUS.sm)
          .margin({ left: SPACE.xs })
          .scale(this.allowPressed ? { x: 0.96, y: 0.96 } : { x: 1, y: 1 })
          .animation({ duration: 100, curve: Curve.EaseOut })
          .shadow(this.allowPressed ? { radius: 8, color: 'rgba(217,119,87,0.25)', offsetX: 0, offsetY: 0 } : { radius: 0, color: 'transparent', offsetX: 0, offsetY: 0 })
          .enabled(!this.allowLoading && !this.denyLoading)
          .onClick(() => { this.handleAllow() })
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) { this.allowPressed = true }
            else if (event.type === TouchType.Up || event.type === TouchType.Cancel) { this.allowPressed = false }
          })
        }
      }.width('100%')

      if (this.errorMsg !== '') {
        Text(this.errorMsg).fontSize(11).fontColor(COLOR.danger).margin({ top: SPACE.xs })
      }
    }
    .width('100%').padding(SPACE.md)
    .backgroundColor('rgba(23,20,18,0.96)')
    .border({ width: 1, color: 'rgba(217,119,87,0.16)' }).borderRadius(RADIUS.md)
    .shadow({ radius: 14, color: 'rgba(0,0,0,0.28)', offsetY: 5 })
    .onClick(() => { if (this.onTap) { this.onTap() } })
  }

  async handleAllow(): Promise<void> {
    if (this.allowLoading || this.denyLoading) return
    this.allowLoading = true; this.errorMsg = ''
    try { await ApprovalApi.decide(this.record.id, 'allow'); if (this.onDecided) { this.onDecided() } }
    catch (err) {
      if (isApiError(err)) { const apiErr = err as ApiError; if (apiErr.status === 409) { this.decideTimer = setTimeout(() => { this.decideTimer = -1; if (this.onDecided) { this.onDecided() } }, 1200); return }; this.errorMsg = apiErr.message }
      else { this.errorMsg = 'Network error' }
    } finally { this.allowLoading = false }
  }

  async handleDeny(): Promise<void> {
    if (this.allowLoading || this.denyLoading) return
    this.denyLoading = true; this.errorMsg = ''
    try { await ApprovalApi.decide(this.record.id, 'deny'); if (this.onDecided) { this.onDecided() } }
    catch (err) {
      if (isApiError(err)) { const apiErr = err as ApiError; if (apiErr.status === 409) { this.decideTimer = setTimeout(() => { this.decideTimer = -1; if (this.onDecided) { this.onDecided() } }, 1200); return }; this.errorMsg = apiErr.message }
      else { this.errorMsg = 'Network error' }
    } finally { this.denyLoading = false }
  }
}
