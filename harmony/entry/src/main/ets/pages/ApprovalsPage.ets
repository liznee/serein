import { router } from '@kit.ArkUI'
import type { ApprovalRecord } from '../api/types'
import ApprovalApi from '../api/ApprovalApi'
import { isLoggedIn, handleAuthError, KEY_CONNECTED, KEY_FAIL_STREAK, KEY_BACKEND_URL } from '../state/AppStore'
import NavPath from '../model/NavPath'
import { isApiError } from '../api/HttpClient'
import type { ApiError } from '../api/HttpClient'
import ApprovalPushService from '../service/ApprovalPushService'
import NotificationMgr from '../service/NotificationMgr'
import { tokenizeCommand } from '../utils/CmdHighlight'
import { formatRelative } from '../utils/TimeUtil'

// ====== Stitch Approval History Blueprint ======
// Colors from Stitch DESIGN.md: primary=#D97757, surface=#111418, outline=#8C909F,
// text-primary=#E1E2E8, text-secondary=#C2C6D6, danger=#FFB4AB, success=#4AE176

const MAX_CMD = 80

interface FilterTab { label: string; filter: string }

@Entry
@Component
struct ApprovalsPage {
  @State pendingList: ApprovalRecord[] = []
  @State loading: boolean = false
  @State lastError: string = ''
  @State connected: boolean = false
  @State failStreak: number = 0
  @State activeFilter: number = 0
  private lastFetchAt: number = 0  // 上次 fetch 时间戳，防 aboutToAppear+onPageShow 双触发打爆限流
  private project: string = ''  // 空 = 不按项目过滤，显示全部项目
  private filterTabs: FilterTab[] = [
    { label: 'Pending', filter: 'pending' }, { label: 'All', filter: '' },
    { label: 'Allowed', filter: 'allow' }, { label: 'Denied', filter: 'deny' },
    { label: 'Timeout', filter: 'timeout' }
  ]

  aboutToAppear(): void {
    if (!isLoggedIn()) {
      setTimeout(() => { router.replaceUrl({ url: NavPath.PAIR }) }, 100)
      return
    }
    const params = router.getParams() as Record<string, Object>
    if (params && params['project'] !== undefined) { this.project = params['project'] as string }
    AppStorage.setOrCreate('currentProject', this.project)
    this.ensurePushService(); this.fetchOnce()
  }

  private ensurePushService(): void {
    // 仅注册 UI 刷新回调，不重启推送服务。
    // 推送服务由 EntryAbility 在启动时统一创建，页面不应重复启动（会导致双 WebSocket 连接 + 双轮询 → 重复通知）。
    ApprovalPushService.setRefreshHandler(() => { this.fetchOnce() })
  }

  onPageShow(): void {
    // 防抖：3 秒内不重复请求，避免 aboutToAppear + onPageShow 双触发打爆后端限流
    const now = Date.now()
    if (now - this.lastFetchAt < 3000) return
    this.lastFetchAt = now
    this.fetchOnce()
  }

  async handleApproveDeny(item: ApprovalRecord, decision: 'allow' | 'deny'): Promise<void> {
    // 先立即更新 UI（乐观更新），再发 API
    const updated: ApprovalRecord[] = []
    for (let i = 0; i < this.pendingList.length; i++) {
      const r = this.pendingList[i]
      if (r.id === item.id) {
        const newItem: ApprovalRecord = {
          id: r.id, session_id: r.session_id, tool_name: r.tool_name,
          command: r.command, cwd: r.cwd, risk_level: r.risk_level,
          rule_reason: r.rule_reason, decision: decision,
          project: r.project, decided_by: r.decided_by,
          decided_at: r.decided_at, created_at: r.created_at, timeout_at: r.timeout_at
        }
        updated.push(newItem)
      } else {
        updated.push(r)
      }
    }
    this.pendingList = updated
    try {
      await ApprovalApi.decide(item.id, decision)
      // 审批完成 → 取消该审批的系统通知
      NotificationMgr.cancel(item.id)
    } catch (e) { this.fetchOnce() }
  }

  async fetchOnce(): Promise<void> {
    if (this.loading) return
    this.lastFetchAt = Date.now()
    this.loading = true
    const status = this.filterTabs[this.activeFilter].filter || undefined
    try {
      const resp = await ApprovalApi.list(status, 200, 0, this.project)
      this.pendingList = resp.items ?? []; this.lastError = ''; this.connected = true; this.failStreak = 0
      AppStorage.setOrCreate(KEY_CONNECTED, true); AppStorage.setOrCreate(KEY_FAIL_STREAK, 0)
    } catch (err) {
      if (isApiError(err)) { const apiErr = err as ApiError; if (apiErr.status === 401) { handleAuthError(); router.replaceUrl({ url: NavPath.PAIR }); return }; this.lastError = apiErr.message }
      else { this.lastError = 'Network error' }
      this.connected = false; this.failStreak++
    } finally { this.loading = false }
  }

  handleTapCard(record: ApprovalRecord): void { router.pushUrl({ url: NavPath.DETAIL, params: { id: record.id } }) }
  handleGoSettings(): void { router.pushUrl({ url: NavPath.SETTINGS }) }
  handleBack(): void { router.back() }

  private riskBadgeColor(level: string): [string, string, string] {
    if (level === 'red') return ['#b53333', 'rgba(181,51,51,0.08)', 'rgba(181,51,51,0.20)']
    if (level === 'yellow') return ['#d97730', 'rgba(217,119,48,0.08)', 'rgba(217,119,48,0.20)']
    return ['#17a34a', 'rgba(23,163,74,0.08)', 'rgba(23,163,74,0.20)']
  }

  private riskBadgeLabel(level: string): string {
    if (level === 'red') return 'HIGH RISK'
    if (level === 'yellow') return 'REVIEW'
    return 'LOW RISK'
  }

  private statusColor(decision: string): [string, string] {
    if (decision === 'allow') return ['#17a34a', 'check_circle']
    if (decision === 'deny') return ['#b53333', 'cancel']
    if (decision === 'timeout') return ['#8C909F', 'timer_off']
    return ['#d97730', 'pending']
  }

  private truncateCmd(cmd: string): string { return cmd.length <= MAX_CMD ? cmd : cmd.substring(0, MAX_CMD) + '...' }

  build() {
    Column() {
      // ====== Header ======
      Row() {
        Row() { Text('<').fontSize(24).fontColor('#D97757').fontFamily('monospace') }.width(36).height(36).borderRadius(18).backgroundColor('rgba(217,119,87,0.08)').justifyContent(FlexAlign.Center).onClick(()=>{router.back()})
        Blank()
        // 显示「系统」而不是 __system__
        Text(this.project !== '' ? (this.project === '__system__' ? '系统' : this.project) : 'Project').fontSize(22).fontWeight(700).fontColor('#D97757').fontFamily('monospace')
        if (this.pendingList.length > 0) {
          Text('' + this.pendingList.length).fontSize(11).fontWeight(700).fontColor('#1A1C20')
            .textAlign(TextAlign.Center).constraintSize({ minWidth: 18 }).height(18)
            .padding({ left: 6, right: 6 }).borderRadius(9999).backgroundColor('#b53333').margin({ left: 6 })
        }
        Blank()
        Row().width(36)
      }
      .width('100%').padding({ left: 16, right: 16, top: 44, bottom: 12 })

      // ====== Stitch Filter Tabs: glass-surface + pill group ======
      Scroll() {
        Row() {
          ForEach(this.filterTabs, (tab: FilterTab, idx: number) => {
            Text(tab.label).fontSize(12).fontWeight(600).letterSpacing(0.5)
              .fontColor(idx === this.activeFilter ? '#1A1C20' : '#C2C6D6')
              .padding({ left: 12, right: 12, top: 6, bottom: 6 }).borderRadius(8)
              .backgroundColor(idx === this.activeFilter ? '#D97757' : 'transparent')
              .onClick(() => { this.activeFilter = idx; this.fetchOnce() })
          })
        }
        .padding(4).borderRadius(8)
        .backgroundColor('rgba(29,32,36,0.60)').backdropBlur(20)
        .border({ width: 1, color: 'rgba(140,144,159,0.15)' })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .margin({ left: 16, right: 16, top: 12 })

      // ====== Error banner ======
      if (this.lastError !== '') {
        Row() { Text(this.lastError).fontSize(12).fontColor('#FFFFFF').layoutWeight(1)
          Text('Retry').fontSize(12).fontWeight(700).fontColor('#FFFFFF')
            .padding({ left: 12, right: 12, top: 4, bottom: 4 })
            .border({ width: 1, color: 'rgba(255,255,255,0.3)' }).borderRadius(6)
            .onClick(() => { this.fetchOnce() })
        }
        .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 }).backgroundColor('#EF4444')
        .margin({ left: 16, right: 16, top: 8 }).borderRadius(8)
      }

      // ====== List: Stitch glass-card for each item ======
      if (this.pendingList.length === 0 && !this.loading) {
        Column() {
          Image($r('app.media.logo'))
            .width(32).height(32)
            .borderRadius(8)
            .opacity(0.12)
            .margin({ bottom: 16 })
          Text('暂无审批请求').fontSize(16).fontColor('#C2C6D6')
        }.width('100%').justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center).layoutWeight(1)
      } else {
        List() {
          ForEach(this.pendingList, (item: ApprovalRecord, idx: number) => {
            ListItem() { this.approvalCardItem(item) }
            .margin({ bottom: 12 })
            .transition(TransitionEffect.OPACITY.animation({ duration: 300, delay: idx * 60, curve: Curve.EaseOut })
              .combine(TransitionEffect.translate({ x: 8 }).animation({ duration: 300, delay: idx * 60, curve: Curve.EaseOut })))
          }, (item: ApprovalRecord) => item.id + '_' + item.decision)
        }
        .width('100%').layoutWeight(1).padding({ left: 16, right: 16, top: 12 }).backgroundColor('#111418')
      }
    }
    .width('100%').height('100%').backgroundColor('#111418')
  }

  @Builder
  approvalCardItem(item: ApprovalRecord) {
    // ====== Stitch: glass-card + rounded-xl + p-md ======
    Column() {
      // Top row: Risk badge + Command ID
      Row() {
        Row() {
          Text(this.riskBadgeLabel(item.risk_level))
            .fontSize(10).fontWeight(600).fontColor(this.riskBadgeColor(item.risk_level)[0]).letterSpacing(0.5)
            .padding({ left: 8, right: 8, top: 2, bottom: 2 }).borderRadius(4)
            .backgroundColor(this.riskBadgeColor(item.risk_level)[1])
            .border({ width: 1, color: this.riskBadgeColor(item.risk_level)[2] })
        }
        Blank()
        Text('#' + item.id.substring(0, 8)).fontSize(13).fontColor('#8C909F').fontFamily('monospace')
      }.width('100%')

      // Code block: dark bg + syntax highlighting
      Column() {
        Text() {
          ForEach(tokenizeCommand(this.truncateCmd(item.command)),
            (token: [string, string], idx: number) => { Span(token[0]).fontColor(token[1]).fontFamily('monospace') },
            (token: [string, string], idx: number) => idx.toString())
        }.fontSize(13).maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      }
      .width('100%').padding(12).backgroundColor('#070A0E').borderRadius(6)
      .border({ width: 1, color: 'rgba(140,144,159,0.08)' })

      if (item.rule_reason !== '') {
        Column() {
          Text('Why this needs review').fontSize(11).fontWeight(600)
            .fontColor(this.riskBadgeColor(item.risk_level)[0])
          Text(item.rule_reason).fontSize(12).fontColor('#C2C6D6')
            .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 4 })
        }
        .width('100%').alignItems(HorizontalAlign.Start).padding(8).margin({ top: 8 })
        .backgroundColor(this.riskBadgeColor(item.risk_level)[1]).borderRadius(6)
        .border({ width: 1, color: this.riskBadgeColor(item.risk_level)[2] })
      }

      // Metadata: folder + tool
      Row() {
        Text('folder ' + (item.cwd ? item.cwd : '~')).fontSize(12).fontColor('#C2C6D6')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        Text('tool ' + item.tool_name).fontSize(12).fontColor('#C2C6D6').margin({ left: 16 })
      }.width('100%').margin({ top: 8 })

      if (item.project && item.project !== '') {
        Text('project ' + item.project).fontSize(11).fontColor('#8C909F')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%').margin({ top: 4 })
      }

      Divider().color('rgba(140,144,159,0.06)').margin({ top: 12, bottom: 12 })

      // Status + Time + Actions
      Row() {
        Row() {
          Circle({ width: 6, height: 6 }).fill(this.statusColor(item.decision)[0])
          Text(item.decision === 'allow' ? 'Allowed' : item.decision === 'deny' ? 'Denied' :
               item.decision === 'timeout' ? 'Timed Out' : 'Pending')
            .fontSize(12).fontWeight(600).fontColor(this.statusColor(item.decision)[0]).margin({ left: 4 })
        }
        Blank()
        Text(formatRelative(item.created_at)).fontSize(11).fontColor('#8C909F')
        if (item.decision === 'pending') {
          Button('Deny').fontSize(11).height(32).fontWeight(600)
            .fontColor('#b53333').backgroundColor('rgba(181,51,51,0.08)')
            .border({ width: 1, color: 'rgba(181,51,51,0.25)' }).borderRadius(6).margin({ left: 8 })
            .onClick(() => { this.handleApproveDeny(item, 'deny') })
          Button('Allow').fontSize(11).height(32).fontWeight(600).fontColor('#1A1C20')
            .backgroundColor('#D97757').borderRadius(6).margin({ left: 8 })
            .onClick(() => { this.handleApproveDeny(item, 'allow') })
        }
      }.width('100%')
    }
    .width('100%').padding(16)
    .backgroundColor('rgba(23,20,18,0.96)')
    .border({ width: 1, color: 'rgba(217,119,87,0.16)' }).borderRadius(12)
    .shadow({ radius: 14, color: 'rgba(0,0,0,0.28)', offsetY: 5 })
    .onClick(() => { this.handleTapCard(item) })
  }
}
