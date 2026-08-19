import { notificationManager } from '@kit.NotificationKit'
import { wantAgent, WantAgent } from '@kit.AbilityKit'

/**
 * 系统通知管理器
 *
 * 把审批推送到鸿蒙系统通知中心，锁屏弹横幅 + 振动 + 铃声。
 * 点击通知横幅进入 ProjectPage 后自动跳转对应待审批页。
 *
 * 横幅通知（heads-up）通过 SOCIAL_COMMUNICATION slot type 实现，
 * 能在其他 App 上层浮动展示横幅。用户需在系统设置中开启横幅权限。
 */
const BUNDLE_NAME = 'com.serein.client'
const ABILITY_NAME = 'EntryAbility'
const NOTIFICATION_ID_BASE = 1000

export class NotificationMgr {
  /** 已发布通知的审批 ID — 防止同一条审批被上游双通道推送两次 */
  private static publishedIds: Set<string> = new Set()
  /** 项目级冷却时间戳 — 同一项目 5 秒内只发一条通知，合并批量工具调用 */
  private static lastPublishMs: Map<string, number> = new Map()
  private static readonly COOLDOWN_MS = 5000

  /**
   * 读取通知授权状态。
   * 授权对话框必须由拥有 UIAbilityContext 的 EntryAbility 在前台发起；
   * 后台推送路径只能检查状态，不能尝试弹出无归属的系统对话框。
   */
  static async requestPermission(): Promise<boolean> {
    try {
      return await notificationManager.isNotificationEnabled()
    } catch (e) {
      console.warn('notification permission check failed: ' + (e as Error).message)
      return false
    }
  }

  /**
   * 读取审批通知的系统通道。
   *
   * SOCIAL_COMMUNICATION 的默认等级是 LEVEL_HIGH，系统才会在其他 App
   * 上方显示横幅。用户在系统设置里手动降级后，应用只能检测和提示，
   * 不能绕过用户的通知偏好强行改回去。
   */
  private static async ensureApprovalSlot(): Promise<void> {
    try {
      const slot = await notificationManager.getSlot(notificationManager.SlotType.SOCIAL_COMMUNICATION)
      console.info('[Notify] approval slot: enabled=' + slot.enabled + ' level=' + slot.notificationLevel)
      // 通知栏有但不出横幅 → slot 被系统降级；提示用户检查系统设置
      if (!slot.enabled) {
        console.warn('[Notify] slot DISABLED — banners will not appear')
      }
      return
    } catch (e) {
      // 首次使用时没有该通道，创建系统预设的高优先级社交通道
      try {
        await notificationManager.addSlot(notificationManager.SlotType.SOCIAL_COMMUNICATION)
        console.info('[Notify] approval slot created (SOCIAL_COMMUNICATION, should support heads-up)')
      } catch (slotError) {
        console.error('[Notify] approval slot unavailable: ' + (slotError as Error).message)
      }
    }
  }

  /**
   * 发布一条审批通知——点击横幅自动跳转对应项目的待审批页
   * SOCIAL_COMMUNICATION slot → 支持横幅通知悬浮在其他 App 上层
   */
  static async publishApproval(title: string, command: string, id: string, riskLevel: string, project?: string): Promise<void> {
    if (NotificationMgr.publishedIds.has(id)) return
    NotificationMgr.publishedIds.add(id)
    // 防止 Set 无限增长
    if (NotificationMgr.publishedIds.size > 500) {
      const arr = Array.from(NotificationMgr.publishedIds)
      NotificationMgr.publishedIds = new Set(arr.slice(-250))
    }
    const enabled = await NotificationMgr.requestPermission()
    if (!enabled) {
      console.error('[Notify] skipped: application notifications are disabled')
      return
    }
    await NotificationMgr.ensureApprovalSlot()
    const numericId = NotificationMgr.hashToId(id)
    const agent = await NotificationMgr.buildLaunchAgent(id, project)

    // 基本文本类型：SOCIAL_COMMUNICATION slot + BASIC_TEXT 确保横幅能弹出
    // LONG_TEXT 在某些 HarmonyOS 版本中可能影响 heads-up 横幅显示
    const basicContent: notificationManager.NotificationBasicContent = {
      title: title,
      text: command !== '' ? command : '点击查看审批详情',
      additionalText: ''
    }

    const request: notificationManager.NotificationRequest = {
      id: numericId,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: basicContent
      },
      wantAgent: agent,
      notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
      label: '审批提醒',
      autoDeletedTime: 0  // 不自动消失，审批完成时由代码取消
    }
    try {
      await notificationManager.publish(request)
      console.info('[Notify] published: ' + title + ' id=' + id)
    } catch (e) {
      console.error('[Notify] FAIL: ' + (e as Error).message)
    }
  }

  /** Publish a monitor alert separately from approval actions. */
  static async publishMonitoringAlert(title: string, message: string, id: string, level: string): Promise<void> {
    const uniqueId = 'monitoring:' + id
    if (NotificationMgr.publishedIds.has(uniqueId)) return
    NotificationMgr.publishedIds.add(uniqueId)
    const enabled = await NotificationMgr.requestPermission()
    if (!enabled) return
    await NotificationMgr.ensureApprovalSlot()
    const agent = await NotificationMgr.buildMonitoringLaunchAgent(id)
    const content: notificationManager.NotificationBasicContent = {
      title: title,
      text: message,
      additionalText: level === 'critical' ? '请及时检查电脑状态' : '点击查看监控告警记录'
    }
    const request: notificationManager.NotificationRequest = {
      id: NotificationMgr.hashToId(uniqueId),
      content: { notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT, normal: content },
      wantAgent: agent,
      notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
      label: '监控告警',
      autoDeletedTime: 0
    }
    try { await notificationManager.publish(request) } catch (e) { console.error('[Notify] monitor alert failed: ' + (e as Error).message) }
  }

  /** 构造点击通知启动 EntryAbility 的 WantAgent，携带审批 ID + 项目名 */
  private static async buildLaunchAgent(approvalId: string, project?: string): Promise<WantAgent> {
    const params: Record<string, string> = {
      'approvalId': approvalId,
      'navigateTo': 'projects'
    }
    if (project !== undefined && project !== '') {
      params['project'] = project
    }

    const info: wantAgent.WantAgentInfo = {
      wants: [{
        bundleName: BUNDLE_NAME,
        abilityName: ABILITY_NAME,
        parameters: params
      }],
      operationType: wantAgent.OperationType.START_ABILITY,
      requestCode: 1,
      wantAgentFlags: [wantAgent.WantAgentFlags.CONSTANT_FLAG]
    }
    return await wantAgent.getWantAgent(info)
  }

  private static async buildMonitoringLaunchAgent(alertId: string): Promise<WantAgent> {
    const info: wantAgent.WantAgentInfo = {
      wants: [{
        bundleName: BUNDLE_NAME,
        abilityName: ABILITY_NAME,
        parameters: { 'navigateTo': 'monitoring_alerts', 'monitoringAlertId': alertId }
      }],
      operationType: wantAgent.OperationType.START_ABILITY,
      requestCode: 2,
      wantAgentFlags: [wantAgent.WantAgentFlags.CONSTANT_FLAG]
    }
    return await wantAgent.getWantAgent(info)
  }

  /** 取消单条通知 */
  static cancel(id: string): void {
    NotificationMgr.publishedIds.delete(id)
    try {
      notificationManager.cancel(NotificationMgr.hashToId(id))
    } catch (e) {
      // 忽略
    }
  }

  /** 清除所有审批通知 */
  static cancelAll(): void {
    try {
      notificationManager.cancelAll()
    } catch (e) {
      // 忽略
    }
  }

  /** 把 string id 映射到稳定的 int 通知 ID（取 hashCode 后 5 位） */
  private static hashToId(id: string): number {
    let h = 0
    for (let i = 0; i < id.length; i++) {
      h = (h * 31 + id.charCodeAt(i)) | 0
    }
    return NOTIFICATION_ID_BASE + (Math.abs(h) % 100000)
  }
}

export default NotificationMgr
