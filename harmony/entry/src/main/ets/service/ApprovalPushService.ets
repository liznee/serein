import ntfyClient from './NtfyClient'
import NotificationMgr from './NotificationMgr'
import ApprovalApi from '../api/ApprovalApi'
import MonitoringAlertApi from '../api/MonitoringAlertApi'
import type { ApprovalRecord } from '../api/types'
import { NotificationQueue } from '../model/NotificationQueue'
import type { NotificationItem } from '../model/NotificationQueue'

/**
 * 审批推送编排服务（后台常驻版）
 *
 * 双通道保障：
 *   WebSocket（ntfy）→ 主通道，秒级延迟
 *   HTTP 轮询        → 兜底通道，后台/断连时自动接管
 *
 * 通知策略：
 *   App 前台 → 需要页面的 NotificationPopup 展示液态玻璃弹窗
 *   App 后台 → 系统通知横幅（SOCIAL_COMMUNICATION slot，能在其他 App 上层浮动）
 *
 * 生命周期：
 *   EntryAbility.onWindowStageCreate 启动 → 全生命周期存活
 *   EntryAbility.onDestroy 停止
 *
 * 安全设计：ntfy topic 是公开 pub/sub 总线，推送体只含 id + risk_level，
 * 命令正文绝不经过 ntfy，由客户端凭 token 拉取。
 */

type RefreshHandler = () => void
type PopupHandler = (item: NotificationItem) => void

/** 轮询间隔 — WebSocket 存活时 */
const POLL_SLOW_MS = 60000
/** 轮询间隔 — WebSocket 断连时 */
const POLL_FAST_MS = 10000
/** WebSocket 最后消息超时判定（超过此时间视为断连） */
const WS_DEAD_THRESHOLD_MS = 30000

export class ApprovalPushService {
  private static instance: ApprovalPushService
  private refreshHandler: RefreshHandler = () => {}
  private popupHandler: PopupHandler = () => {}
  private running: boolean = false
  private pollTimer: number = -1
  private seenIds: Set<string> = new Set()
  /** 首轮轮询只建立基线，避免 App 重启后把历史 pending 全部重新提醒。 */
  private pollBaselineReady: boolean = false
  private isForeground: boolean = true
  /** 处理中 ID 集合 — 防止 ntfy WS 和轮询并发处理同一条审批 */
  private processingIds: Set<string> = new Set()
  /** 轮询进行中标志 — 防止两个 pollOnce 并发执行 */
  private pollingActive: boolean = false
  /** 后台期间积压的通知队列，回前台时弹出 */
  private pendingPopupQueue: NotificationQueue = new NotificationQueue()

  static getInstance(): ApprovalPushService {
    if (!ApprovalPushService.instance) {
      ApprovalPushService.instance = new ApprovalPushService()
    }
    return ApprovalPushService.instance
  }

  start(ntfyBaseUrl: string, topic: string): void {
    // 防止重复启动（onWindowStageCreate 可能被多次调用）
    if (this.running) {
      console.warn('[Push] start() called while already running - ignored')
      return
    }
    this.running = true
    this.pollBaselineReady = false
    this.isForeground = true

    // 主通道：WebSocket
    ntfyClient.start(ntfyBaseUrl, topic, (body: string) => {
      this.handleMessage(body)
    })

    // 兜底通道：HTTP 轮询（自调节间隔）— 先立即轮一次，再按间隔调度
    this.pollAndSchedule()

    console.info('ApprovalPushService started: ws=' + ntfyBaseUrl + '/' + topic + ' http fallback enabled')
  }

  setRefreshHandler(fn: RefreshHandler): void {
    this.refreshHandler = fn
  }

  /** 设置前台弹窗回调 */
  setPopupHandler(fn: PopupHandler): void {
    this.popupHandler = fn
  }

  /** 通知 App 已进入前台 — 冲刷后台积压通知为液态玻璃弹窗 */
  onForeground(): void {
    this.isForeground = true
    // 冲刷积压通知队列
    const queueLen = this.pendingPopupQueue.length
    while (this.pendingPopupQueue.hasPending()) {
      const item = this.pendingPopupQueue.dequeue()
      if (item !== null) {
        this.popupHandler(item)
      }
    }
    console.info('ApprovalPushService: foreground, flushed ' + queueLen + ' pending popups')
  }

  /** 通知 App 已进入后台 */
  onBackground(): void {
    this.isForeground = false
    console.info('ApprovalPushService: marked background mode')
  }

  /** 后台恢复：立即轮询一次，然后切换到快速间隔（10s）。
   *  后台 ntfy WS 可能被系统静默断开但 tcp keepalive 未超时，
   *  强制创建通知（覆盖 WS alive 检查）。 */
  resumeFastPoll(): void {
    if (!this.running) {
      return
    }
    // 先停掉旧轮询，防止与新的 pollOnce 并行导致重复通知
    this.stopPolling()
    // 立即轮询：后台 WS 状态不可靠，轮询会补发首轮基线之后新出现的审批。
    console.info('ApprovalPushService: fast poll for background, ntfyAlive=' + this.ntfyAlive())
    this.pollOnce().then(() => {
      if (this.running) {
        this.schedulePoll()
      }
    })
  }

  stop(): void {
    this.running = false
    ntfyClient.stop()
    this.stopPolling()
    this.seenIds.clear()
    this.pollBaselineReady = false
    this.pendingPopupQueue.clear()
  }

  isRunning(): boolean {
    return this.running
  }

  /** 获取队列以供页面消费 */
  getPopupQueue(): NotificationQueue {
    return this.pendingPopupQueue
  }

  // ── 轮询 ──

  private schedulePoll(): void {
    this.stopPolling()
    if (!this.running) {
      return
    }
    // 后台的 WebSocket 可能被系统静默挂起：即使最后消息仍在阈值内，
    // 也必须保持快速 HTTP 兜底，不能等 60 秒才发现漏推。
    const interval = this.isForeground && this.ntfyAlive() ? POLL_SLOW_MS : POLL_FAST_MS
    this.pollTimer = setTimeout(() => {
      this.pollAndSchedule()
    }, interval)
  }

  /** 立即轮询一次，然后按间隔安排下一次 */
  private pollAndSchedule(): void {
    this.pollOnce().then(() => {
      if (this.running) {
        this.schedulePoll()
      }
    })
  }

  private stopPolling(): void {
    if (this.pollTimer !== -1) {
      clearTimeout(this.pollTimer)
      this.pollTimer = -1
    }
  }

  /** ntfy WebSocket 是否存活（最近 30 秒内有消息到达） */
  private ntfyAlive(): boolean {
    const last = ntfyClient.getLastMsgTime()
    if (last === 0) {
      return false
    }
    return (Date.now() - last * 1000) < WS_DEAD_THRESHOLD_MS
  }

  /** HTTP 轮询 — 用客户端 token 鉴权拉取 pending 列表。 */
  private async pollOnce(): Promise<void> {
    if (this.pollingActive) return
    this.pollingActive = true
    try {
      const resp = await ApprovalApi.listPending(200)
      const items = resp.items ?? []
      const firstPoll = !this.pollBaselineReady
      const newlyObserved: ApprovalRecord[] = []
      for (const rec of items) {
        if (this.seenIds.has(rec.id) || this.processingIds.has(rec.id)) continue
        // 先占位再 await，ntfy 与轮询同时抵达时只会有其中一个负责通知。
        this.seenIds.add(rec.id)
        if (!firstPoll) {
          this.processingIds.add(rec.id)
          newlyObserved.push(rec)
        }
      }
      this.pollBaselineReady = true
      // 首轮只建立已见审批的基线。之后轮询是 ntfy 在后台被系统挂起时的
      // 可靠兜底，仍然只为从未见过的审批发送一次系统通知。
      for (const rec of newlyObserved) {
        try {
          await this.dispatchNotification(rec)
        } catch (error) {
          // 通知槽被系统短暂拒绝时，仍保留前台/回前台可见的审批入口。
          console.warn('[Push] fallback notification failed: ' + (error as Error).message)
        } finally {
          this.processingIds.delete(rec.id)
        }
        this.sendToTarget(this.toActionableItem(rec))
      }
      this.refreshHandler()
    } catch (_e) {
      // 静默
    } finally {
      this.pollingActive = false
    }
  }

  // ── WebSocket 消息处理 ──

  private async handleMessage(body: string): Promise<void> {
    let sig: PushSignal
    try {
      sig = JSON.parse(body) as PushSignal
    } catch (e) {
      console.warn('push message not json: ' + body)
      return
    }
    if (sig.kind === 'monitor_alert') {
      await this.handleMonitoringAlert(sig)
      return
    }
    if (sig.id === undefined || sig.id === '') {
      return
    }
    // 处理锁：防止 ntfy WS 和轮询并发处理同一条审批
    if (this.processingIds.has(sig.id)) {
      console.info('[Push] skipped (processing): ' + sig.id)
      return
    }
    // 去重：已通知过的审批不重复弹窗
    if (this.seenIds.has(sig.id)) {
      console.info('[Push] skipped duplicate: ' + sig.id)
      return
    }
    this.processingIds.add(sig.id)
    this.seenIds.add(sig.id)
    const riskLevel = sig.risk_level !== undefined ? sig.risk_level : ''
    try {
      const rec = await ApprovalApi.detail(sig.id)
      // 系统通知
      await this.dispatchNotification(rec)
      // 弹窗带 Allow/Deny 按钮
      this.sendToTarget(this.toActionableItem(rec))
    } catch (e) {
      // 拉取失败：只发系统通知，弹窗不带按钮
      const item: NotificationItem = {
        id: sig.id,
        title: this.riskLabel(riskLevel) + ' 审批请求',
        command: '点击查看详情',
        riskLevel: riskLevel
      }
      this.sendToTarget(item)
    } finally {
      this.processingIds.delete(sig.id)
    }
    this.refreshHandler()
  }

  // ── 通知分发 ──

  private async dispatchNotification(rec: ApprovalRecord): Promise<void> {
    const systemPushActive = AppStorage.get<boolean>('pushKitDeliveryActive') ?? false
    if (!this.isForeground && systemPushActive) {
      console.info('[Push] background notification delegated to system Push Kit')
      return
    }
    const riskLevel: string = rec.risk_level !== undefined ? rec.risk_level : 'green'
    const label = this.riskLabel(riskLevel)
    const cmd = this.shortenCmd(rec.command)
    const title = label + ' 审批请求'
    const cmdBody = rec.rule_reason !== undefined && rec.rule_reason !== '' ?
      cmd + '\n原因: ' + rec.rule_reason : cmd

    // 弹窗由 handleMessage / pollOnce 统一构造带按钮 item 后 sendToTarget
    // dispatchNotification 仅负责系统通知（后台横幅+通知中心）

    // 始终发系统通知（前台也发，确保横幅覆盖），附带 project
    const recProject: string = rec.project ?? ''
    console.info('[Push] dispatching system notify: ' + title + ' fg=' + this.isForeground + ' project=' + recProject)
    await NotificationMgr.publishApproval(title, cmdBody, rec.id, riskLevel, recProject)
  }

  /** 根据前台/后台决定走弹窗还是队列 */
  private sendToTarget(item: NotificationItem): void {
    if (this.isForeground) {
      this.popupHandler(item)
    } else {
      // 后台：存队列，回前台时冲刷为弹窗
      this.pendingPopupQueue.enqueue(item)
    }
  }

  private async handleMonitoringAlert(sig: PushSignal): Promise<void> {
    if (sig.id === undefined || sig.id === '' || this.seenIds.has('monitoring:' + sig.id)) return
    this.seenIds.add('monitoring:' + sig.id)
    try {
      const record = await MonitoringAlertApi.detail(sig.id)
      await NotificationMgr.publishMonitoringAlert(record.title, record.message, record.id, record.level)
    } catch (e) {
      console.warn('[Push] monitoring alert fetch failed: ' + (e as Error).message)
    }
  }

  private toActionableItem(rec: ApprovalRecord): NotificationItem {
    const riskLevel: string = rec.risk_level !== undefined ? rec.risk_level : ''
    return {
      id: rec.id,
      title: this.riskLabel(riskLevel) + ' 审批请求',
      command: this.shortenCmd(rec.command),
      riskLevel: riskLevel,
      onAllow: () => { ApprovalApi.decide(rec.id, 'allow').catch(() => {}) },
      onDeny: () => { ApprovalApi.decide(rec.id, 'deny').catch(() => {}) }
    }
  }

  private riskLabel(level: string): string {
    if (level === 'red') return '[高危]'
    if (level === 'yellow') return '[注意]'
    return '[安全]'
  }

  private shortenCmd(cmd: string): string {
    if (cmd === undefined || cmd === null) return ''
    if (cmd.length <= 60) return cmd
    return cmd.substring(0, 57) + '...'
  }
}

interface PushSignal {
  id: string
  risk_level?: string
  kind?: string
  level?: string
}

export default ApprovalPushService.getInstance()
