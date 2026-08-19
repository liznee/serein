// ===== 通知队列（NotificationQueue） =====
// 管理多个待展示通知，逐个弹出，支持入队/出队/清空/计数

export interface NotificationItem {
  id: string
  title: string
  command: string
  riskLevel: string
  /** 点击允许时的回调（由调用方注入） */
  onAllow?: () => void
  /** 点击拒绝时的回调 */
  onDeny?: () => void
}

export class NotificationQueue {
  private items: NotificationItem[] = []
  private current: NotificationItem | null = null

  /** 获取队列长度（不含当前展示） */
  get length(): number {
    return this.items.length
  }

  /** 当前展示的通知 */
  getCurrent(): NotificationItem | null {
    return this.current
  }

  /** 是否有待展示通知 */
  hasPending(): boolean {
    return this.items.length > 0
  }

  /** 入队 */
  enqueue(item: NotificationItem): void {
    // 去重：同 id 不重复入队
    const exists = this.items.some((v: NotificationItem) => v.id === item.id)
    if (exists) {
      return
    }
    if (this.current !== null && this.current.id === item.id) {
      return
    }
    this.items.push(item)
  }

  /** 出队下一个（设为 current 并返回，无则返回 null） */
  dequeue(): NotificationItem | null {
    if (this.items.length === 0) {
      this.current = null
      return null
    }
    this.current = this.items.shift() ?? null
    return this.current
  }

  /** 移除并跳过当前 */
  dismissCurrent(): void {
    this.current = null
  }

  /** 清空全部 */
  clear(): void {
    this.items = []
    this.current = null
  }
}
