import { webSocket } from '@kit.NetworkKit'
import PrefStore from '../store/PrefStore'

/**
 * ntfy WebSocket 订阅客户端
 *
 * 连接 ws://<ntfy-host>/<topic>/ws，实时接收审批推送消息，
 * 替代 10 秒轮询。ntfy 消息格式(JSON):
 *   {"id":"...","event":"message","topic":"...","message":"<body>",
 *    "title":"...","time":...}
 * body 为审批 JSON（后端 notify.ApprovalMessage）。
 */
export class NtfyClient {
  private ws: webSocket.WebSocket | null = null
  private url: string = ''
  private reconnectDelayMs: number = 2000
  private maxReconnectDelayMs: number = 60000
  private shouldRun: boolean = false
  private reconnectTimer: number = -1
  private onMessage: (body: string) => void = () => {}
  private lastMsgTime: number = 0
  private seenIds: Set<string> = new Set()

  /**
   * 启动订阅。
   * @param ntfyBaseUrl  ntfy 根地址，如 http://your-ntfy-host:8090
   * @param topic        订阅 topic，如 serein-approvals
   * @param handler      收到 message body 时的回调
   */
  start(ntfyBaseUrl: string, topic: string, handler: (body: string) => void): void {
    this.stop()
    this.shouldRun = true
    this.onMessage = handler
    // http(s):// → ws(s)://
    const wsUrl = ntfyBaseUrl.replace(/^http/, 'ws').replace(/\/$/, '') + '/' + topic + '/ws'
    this.url = wsUrl
    this.reconnectDelayMs = 2000
    // 初始化为当前时间：轮询在 WS 连接阶段不抢发通知
    this.lastMsgTime = Math.floor(Date.now() / 1000)
    this.seenIds.clear()
    this.connect()
  }

  /** 获取最后一次收到消息的时间戳（用于判断 WebSocket 活跃性） */
  getLastMsgTime(): number {
    return this.lastMsgTime
  }

  /** 停止订阅，不再重连 */
  stop(): void {
    this.shouldRun = false
    // 取消尚未触发的重连定时器，避免销毁后仍尝试重连
    if (this.reconnectTimer !== -1) {
      clearTimeout(this.reconnectTimer)
      this.reconnectTimer = -1
    }
    if (this.ws !== null) {
      try {
        this.ws.off('open')
        this.ws.off('message')
        this.ws.off('close')
        this.ws.off('error')
        this.ws.close()
      } catch (e) {
        // 忽略关闭异常
      }
      this.ws = null
    }
  }

  private connect(): void {
    if (!this.shouldRun) {
      return
    }
    // 先关闭旧连接，防止两条 WS 同时存活（重连时 connect() 会创建新连接，
    // 旧的 WS close 事件异步触发 → scheduleReconnect → connect → 覆盖 this.ws
    // → 旧连接仍然存活并接收消息 → 与新连接重复）
    if (this.ws !== null) {
      try {
        this.ws.off('open')
        this.ws.off('message')
        this.ws.off('close')
        this.ws.off('error')
        this.ws.close()
      } catch (_e) {}
      this.ws = null
    }
    try {
      const socket = webSocket.createWebSocket()
      this.ws = socket
      console.info('[Ntfy] connecting to: ' + this.url)
      socket.on('open', () => {
        if (this.ws !== socket) return
        console.info('[Ntfy] ws OPENED: ' + this.url)
        this.reconnectDelayMs = 2000 // 连上后重置退避
      })
      socket.on('message', (err, data) => {
        if (this.ws !== socket) return
        if (err || data === undefined || data === null) {
          return
        }
        this.handleRaw(data)
      })
      socket.on('close', (err, value) => {
        if (this.ws !== socket) return
        this.ws = null
        const code = value !== undefined && value !== null ? value.code : -1
        const reason = value !== undefined && value !== null ? value.reason : ''
        console.info('[Ntfy] ws CLOSED: code=' + code + ' reason=' + reason + ' delay=' + this.reconnectDelayMs + 'ms')
        this.scheduleReconnect()
      })
      socket.on('error', (err) => {
        if (this.ws !== socket) return
        console.error('[Ntfy] ws ERROR: ' + JSON.stringify(err))
        console.warn('ntfy ws error')
        this.scheduleReconnect()
      })
      // 断线补拉：重连时带上最后一条消息的时间戳，重放断线期间的消息
      let connectUrl = this.url
      if (this.lastMsgTime > 0) {
        connectUrl = this.url + '?since=' + this.lastMsgTime
      }
      socket.connect(connectUrl)
    } catch (e) {
      console.warn('ntfy connect exception: ' + (e as Error).message)
      this.scheduleReconnect()
    }
  }

  private handleRaw(data: string | ArrayBuffer): void {
    let text: string
    if (typeof data === 'string') {
      text = data
    } else {
      // ArrayBuffer → utf8
      const arr = new Uint8Array(data)
      text = this.decodeUtf8(arr)
    }
    // ntfy 一次可能推送多条 JSON（逐行），逐行解析
    const lines = text.split('\n')
    for (const line of lines) {
      const trimmed = line.trim()
      if (trimmed === '') {
        continue
      }
      try {
        const obj: ntfyEnvelope = JSON.parse(trimmed)
        if (obj.event === 'message' && obj.message !== undefined && obj.message !== null) {
          // 按 ntfy 消息 id 去重（since 补拉会重放历史消息，避免重复通知）
          const ntfyId = obj.id !== undefined ? obj.id : ''
          if (ntfyId !== '') {
            if (this.seenIds.has(ntfyId)) {
              continue
            }
            this.seenIds.add(ntfyId)
            // 只截断旧记录，不清空。清空后 ?since= 重连会重放全部历史消息
            if (this.seenIds.size > 200) {
              const arr = Array.from(this.seenIds)
              this.seenIds = new Set(arr.slice(-150))
            }
          }
          const t = obj.time
          if (t !== undefined && t !== null) {
            this.lastMsgTime = t
          }
          this.onMessage(obj.message)
        }
      } catch (e) {
        // 非 JSON 行忽略
      }
    }
  }

  private decodeUtf8(bytes: Uint8Array): string {
    let s = ''
    for (let i = 0; i < bytes.length; i++) {
      s += String.fromCharCode(bytes[i])
    }
    // 简单 ASCII/扩展解码；中文走 message 字段已是 UTF-8 文本，由 JSON.parse 处理
    return s
  }

  private scheduleReconnect(): void {
    if (!this.shouldRun || this.reconnectTimer !== -1) {
      return
    }
    const delay = this.reconnectDelayMs
    // 指数退避，上限 60s
    this.reconnectDelayMs = Math.min(this.reconnectDelayMs * 2, this.maxReconnectDelayMs)
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = -1
      this.connect()
    }, delay)
  }
}

interface ntfyEnvelope {
  id?: string
  event?: string // "message" | "open" | "keepalive"
  topic?: string
  message?: string
  title?: string
  time?: number
}

export default new NtfyClient()
