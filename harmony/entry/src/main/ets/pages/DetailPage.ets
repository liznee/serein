import { router } from '@kit.ArkUI'
import type { ApprovalRecord } from '../api/types'
import ApprovalApi from '../api/ApprovalApi'
import { formatLocal } from '../utils/TimeUtil'
import { isApiError } from '../api/HttpClient'
import type { ApiError } from '../api/HttpClient'
import { handleAuthError } from '../state/AppStore'
import NavPath from '../model/NavPath'
import { tokenizeCommand } from '../utils/CmdHighlight'
import { WEIGHT } from '../utils/DesignTokens'

// ====== Stitch Approval Detail Blueprint ======

interface DiffLine { text: string; color: string }

@Entry
@Component
struct DetailPage {
  @State record: ApprovalRecord | null = null
  @State loading: boolean = true
  @State errorMsg: string = ''
  @State allowLoading: boolean = false
  @State denyLoading: boolean = false
  @State decided: boolean = false
  private approvalId: string = ''

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, Object>
    if (params && params['id'] !== undefined) { this.approvalId = params['id'] as string; this.loadDetail() }
    else { this.errorMsg = 'Missing approval ID'; this.loading = false }
  }

  async loadDetail(): Promise<void> {
    this.loading = true
    try { this.record = await ApprovalApi.detail(this.approvalId); this.errorMsg = '' }
    catch (err) {
      if (isApiError(err)) { const apiErr = err as ApiError; if (apiErr.status === 401) { handleAuthError(); router.replaceUrl({ url: NavPath.PAIR }); return }; this.errorMsg = apiErr.message }
      else { this.errorMsg = 'Network error' }
    } finally { this.loading = false }
  }

  async handleAllow(): Promise<void> {
    if (this.allowLoading || this.denyLoading) return
    this.allowLoading = true; this.errorMsg = ''
    try {
      console.info('[DetailPage] decide allow id=' + this.approvalId)
      await ApprovalApi.decide(this.approvalId, 'allow')
      // 乐观更新：立即隐藏按钮并显示 Allowed，不等 loadDetail（避免闪 loading 转圈）
      if (this.record) {
        this.record = {
          id: this.record.id, session_id: this.record.session_id, tool_name: this.record.tool_name,
          command: this.record.command, cwd: this.record.cwd, risk_level: this.record.risk_level,
          rule_reason: this.record.rule_reason, decision: 'allow',
          project: this.record.project, diff: this.record.diff ?? '',
          decided_by: this.record.decided_by,
          decided_at: this.record.decided_at, created_at: this.record.created_at, timeout_at: this.record.timeout_at
        }
      }
      this.decided = true
    } catch (err) {
      this.decided = false
      if (isApiError(err)) {
        const apiErr = err as ApiError
        console.error('[DetailPage] allow failed: ' + apiErr.status + ' ' + apiErr.message)
        if (apiErr.status === 409) { this.loadDetail() }
        else if (apiErr.status === 401) { handleAuthError(); router.replaceUrl({ url: NavPath.PAIR }) }
        else { this.errorMsg = apiErr.message }
      } else { this.errorMsg = 'Network error' }
    } finally { this.allowLoading = false }
  }

  async handleDeny(): Promise<void> {
    if (this.allowLoading || this.denyLoading) return
    this.denyLoading = true; this.errorMsg = ''
    try {
      console.info('[DetailPage] decide deny id=' + this.approvalId)
      await ApprovalApi.decide(this.approvalId, 'deny')
      // 乐观更新：立即隐藏按钮并显示 Denied
      if (this.record) {
        this.record = {
          id: this.record.id, session_id: this.record.session_id, tool_name: this.record.tool_name,
          command: this.record.command, cwd: this.record.cwd, risk_level: this.record.risk_level,
          rule_reason: this.record.rule_reason, decision: 'deny',
          project: this.record.project, diff: this.record.diff ?? '',
          decided_by: this.record.decided_by,
          decided_at: this.record.decided_at, created_at: this.record.created_at, timeout_at: this.record.timeout_at
        }
      }
      this.decided = true
    } catch (err) {
      this.decided = false
      if (isApiError(err)) {
        const apiErr = err as ApiError
        console.error('[DetailPage] deny failed: ' + apiErr.status + ' ' + apiErr.message)
        if (apiErr.status === 409) { this.loadDetail() }
        else if (apiErr.status === 401) { handleAuthError(); router.replaceUrl({ url: NavPath.PAIR }) }
        else { this.errorMsg = apiErr.message }
      } else { this.errorMsg = 'Network error' }
    } finally { this.denyLoading = false }
  }

  handleBack(): void { router.back() }

  private riskInfo(): [string, string, string] {
    const lv = this.record?.risk_level ?? 'green'
    if (lv === 'red') return ['HIGH RISK', '#b53333', 'rgba(255,180,171,0.08)']
    if (lv === 'yellow') return ['REVIEW', '#d97730', 'rgba(217,119,48,0.08)']
    return ['LOW RISK', '#17a34a', 'rgba(23,163,74,0.08)']
  }

  private parseDiff(diff: string): DiffLine[] {
    const lines = diff.split('\n')
    return lines.map((line: string): DiffLine => {
      if (line.startsWith('+++') || line.startsWith('---')) {
        return { text: line, color: '#d97730' }
      }
      if (line.startsWith('+')) {
        return { text: line, color: '#17a34a' }
      }
      if (line.startsWith('-')) {
        return { text: line, color: '#b53333' }
      }
      if (line.startsWith('@@')) {
        return { text: line, color: '#D97757' }
      }
      return { text: line, color: '#8C909F' }
    })
  }

  private statusInfo(): [string, string] {
    const d = this.record?.decision ?? 'pending'
    if (d === 'allow') return ['Allowed', '#17a34a']
    if (d === 'deny') return ['Denied', '#b53333']
    if (d === 'timeout') return ['Timed Out', '#8C909F']
    return ['Pending', '#F59E0B']
  }

  build() {
    Column() {
      // ====== Header ======
      Row() {
        Row() { Text('<').fontSize(24).fontColor('#D97757').fontFamily('monospace') }.width(36).height(36).borderRadius(18).backgroundColor('rgba(217,119,87,0.08)').justifyContent(FlexAlign.Center).onClick(()=>{this.handleBack()})
        Blank()
        Text('Detail').fontSize(22).fontWeight(700).fontColor('#D97757').fontFamily('monospace')
        Blank()
        Row().width(36)
      }
      .width('100%').padding({ left: 16, right: 16, top: 44, bottom: 12 })

      if (this.loading) {
        LoadingProgress().width(36).height(36).color('#D97757').margin({ top: 48 })
      } else if (this.errorMsg !== '') {
        Column() {
          Text(this.errorMsg).fontSize(16).fontColor('#b53333').margin({ bottom: 16 })
          Button('Retry').fontSize(16).height(44).fontColor('#1A1C20').backgroundColor('#D97757').borderRadius(6).onClick(() => { this.loadDetail() })
        }.width('100%').margin({ top: 48 }).alignItems(HorizontalAlign.Center)
      } else if (this.record) {
        Scroll() {
          Column() {
            // ====== Risk badge + Command ID ======
            Row() {
              Text(this.riskInfo()[0]).fontSize(10).fontWeight(600).fontColor(this.riskInfo()[1]).letterSpacing(0.5)
                .padding({ left: 8, right: 8, top: 2, bottom: 2 }).borderRadius(4).backgroundColor(this.riskInfo()[2])
                .border({ width: 1, color: this.riskInfo()[1] + '33' })
              Blank()
              Text('#' + this.approvalId.substring(0, 8)).fontSize(13).fontColor('#8C909F').fontFamily('monospace')
            }.width('100%')

            // ====== Command Block ======
            Column() {
              Text() {
                ForEach(tokenizeCommand(this.record.command),
                  (token: [string, string], idx: number) => { Span(token[0]).fontColor(token[1]).fontFamily('monospace') },
                  (token: [string, string], idx: number) => idx.toString())
              }.fontSize(14).width('100%')
            }
            .width('100%').padding(16).backgroundColor('#0B0E12').borderRadius(8).margin({ top: 12 })
            .border({ width: 1, color: 'rgba(140,144,159,0.10)' })

            // ====== Info Fields ======
            Column() {
              this.infoRow('Tool', this.record.tool_name)
              this.infoRow('Risk', this.riskInfo()[0])
              this.infoRow('Status', this.statusInfo()[0])
              if (this.record.decided_by) this.infoRow('By', this.record.decided_by)
              if (this.record.cwd) this.infoRow('Directory', this.record.cwd)
              this.infoRow('Session', this.record.session_id.substring(0, 12) + '...')
              this.infoRow('Reason', this.record.rule_reason)
              if (this.record.decided_at) this.infoRow('Decided', formatLocal(this.record.decided_at))
              this.infoRow('Timeout', formatLocal(this.record.timeout_at))
              this.infoRow('Created', formatLocal(this.record.created_at))
            }
            .width('100%').padding(16).margin({ top: 12 })
            .backgroundColor('rgba(29,32,36,0.60)').backdropBlur(20)
            .border({ width: 1, color: 'rgba(140,144,159,0.15)' }).borderRadius(12)

            // ====== Diff 审查 ======
            if (this.record.diff && this.record.diff !== '') {
              Column() {
                Text('代码改动').fontSize(14).fontWeight(WEIGHT.bold).fontColor('#E1E2E8').margin({ bottom: 8 })

                ForEach(this.parseDiff(this.record.diff), (line: DiffLine, idx: number) => {
                  Text(line.text)
                    .fontSize(10)
                    .fontFamily('monospace')
                    .fontColor(line.color)
                    .lineHeight(18)
                    .width('100%')
                }, (line: DiffLine, idx: number) => idx.toString())
              }
              .width('100%').padding(16).margin({ top: 12 })
              .backgroundColor('rgba(29,32,36,0.60)').backdropBlur(20)
              .border({ width: 1, color: 'rgba(140,144,159,0.15)' }).borderRadius(12)
            }

            // ====== Action Buttons ======
            if (this.record.decision === 'pending' && !this.decided) {
              Row() {
                Button(this.denyLoading ? '...' : 'Deny').fontSize(16).fontWeight(600).height(44).layoutWeight(1)
                  .fontColor('#b53333').backgroundColor('rgba(255,180,171,0.08)')
                  .border({ width: 1, color: 'rgba(255,180,171,0.20)' }).borderRadius(8)
                  .enabled(!this.allowLoading && !this.denyLoading).onClick(() => { this.handleDeny() })
                Button(this.allowLoading ? '...' : 'Allow').fontSize(16).fontWeight(600).height(44).layoutWeight(1)
                  .fontColor('#1A1C20').backgroundColor('#D97757').borderRadius(8).margin({ left: 12 })
                  .enabled(!this.allowLoading && !this.denyLoading).onClick(() => { this.handleAllow() })
              }.width('100%').margin({ top: 16 })
            }

            if (this.errorMsg !== '') {
              Text(this.errorMsg).fontSize(13).fontColor('#b53333').margin({ top: 8 })
            }
          }.width('100%').padding({ left: 16, right: 16, top: 16, bottom: 48 })
        }.width('100%').layoutWeight(1)
      }
    }.width('100%').height('100%').backgroundColor('#111418')
  }

  @Builder infoRow(label: string, value: string) {
    Row() {
      Text(label).fontSize(12).fontColor('#C2C6D6').fontWeight(600).letterSpacing(0.3).width(80)
      Text(value).fontSize(13).fontColor('#E1E2E8').fontFamily('monospace').layoutWeight(1).textAlign(TextAlign.End)
    }
    .width('100%').padding({ top: 10, bottom: 10 })
    .border({ width: { bottom: 1 }, color: 'rgba(140,144,159,0.06)' })
  }
}
