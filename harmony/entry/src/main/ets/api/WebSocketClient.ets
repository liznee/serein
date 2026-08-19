/**
 * WebSocketClient — 与后端 WebSocket 实时通信。
 * 接收 step（中间步骤）、result（命令结果）、heartbeat（心跳）等事件。
 * 自动重连（指数退避 1s/2s/4s/8s 最大 30s）。
 *
 * v2: 重连状态跟踪 + 自动 rejoin session + 历史消息恢复。
 * v3: E2E 加密 — session_msg 发送时自动加密 content→content_enc，
 *     cmd_step 接收时自动解密 content_enc→content。
 */
import { webSocket } from '@kit.NetworkKit'
import e2eCrypto from '../utils/E2ECrypto'

export interface WSEvent {
  type: string
  session_id?: string
  seq?: number
  source?: string
  timestamp?: string
  data?: Record<string, Object>
  payload?: Record<string, Object>
}

/** 连接状态 */
export enum WSConnectionState {
  DISCONNECTED = 'disconnected',
  CONNECTING = 'connecting',
  CONNECTED = 'connected',
  RECONNECTING = 'reconnecting',
}

export class WebSocketClient {
  private ws: webSocket.WebSocket | null = null
  private url: string = ''
  private reconnectTimer: number | null = null
  private reconnectDelay: number = 1000
  private maxReconnectDelay: number = 30000
  private destroyed: boolean = false
  private onEvent?: (event: WSEvent) => void
  private onOpen?: () => void  // 连接建立后回调（用于发送 join 等初始化消息）
  /** 连接状态变更通知 */
  private onStateChange?: (state: WSConnectionState) => void
  private _connected: boolean = false  // 实际连接状态，在 open 中设 true，close/error 中设 false
  private connId: number = 0  // 连接序号，递增；仅最新的连接触发重连，防旧连接残留 handler 导致死循环
  private connecting: boolean = false  // 正在连接中，防 doConnect 重复调用

  // ═══ 自动重连 + session 恢复 ═══
  /** 上次 join 参数，重连后自动 rejoin */
  private lastJoinSessionId: string = ''
  private lastJoinClientType: string = ''
  private lastJoinProject: string = ''
  private lastJoinToken: string = ''
  /** 上次发送 join 的时间戳（毫秒），用于重连时判断是否跳过重复 rejoin。
   *  弱网络频繁断连时，30 秒内使用相同 token 的 rejoin 被跳过，
   *  减少 Token 在网络上的暴露频次。 */
  private _lastJoinTime: number = 0

  // ═══ 心跳保活 ═══
  /** 应用层心跳定时器，每 25 秒发一次 heartbeat 消息防止后端读超时断开 */
  private heartbeatTimer: number | null = null
  private static readonly HEARTBEAT_INTERVAL = 25000

  setOnEvent(handler: (event: WSEvent) => void): void {
    this.onEvent = handler
  }

  /** 设置连接建立后的回调（用于 join、订阅等初始化操作） */
  setOnOpen(handler: () => void): void {
    this.onOpen = handler
  }

  /** 设置连接状态变更通知 */
  setOnStateChange(handler: (state: WSConnectionState) => void): void {
    this.onStateChange = handler
  }

  connect(serverUrl: string): void {
    if (this.destroyed) return
    // 替换 https:// → wss://，http:// → ws://
    const wsUrl = serverUrl.replace(/^https?:\/\//, (m: string) => m === 'https://' ? 'wss://' : 'ws://')
    // 防御性校验：仅当 URL 末尾不以 /ws 结尾时才追加，防止重复追加 /ws 导致连接失败
    this.url = wsUrl.replace(/\/+$/, '') + (wsUrl.endsWith('/ws') ? '' : '/ws')
    this.doConnect()
  }

  private doConnect(): void {
    if (this.destroyed || this.connecting || this.url === '/ws') return
    this.connecting = true
    const myConnId: number = ++this.connId
    this.notifyState(WSConnectionState.CONNECTING)

    // 关闭旧连接，防止残留 handler 触发重连
    if (this.ws) {
      try { this.ws.close() } catch (_) {}
      this.ws = null
    }

    try {
      const newWs: webSocket.WebSocket = webSocket.createWebSocket()
      newWs.on('open', () => {
        if (myConnId !== this.connId) return  // 已不是最新连接，忽略
        console.info('serein ws: OPEN (connId=' + this.connId + ')')
        this._connected = true
        this.reconnectDelay = 1000 // 连接成功重置退避
        this.connecting = false
        this.notifyState(WSConnectionState.CONNECTED)
        // 重连后自动 rejoin session（如有上次 join 参数）
        // 限流保护：同一 token 30 秒内不重复发送，减少弱网络下 Token 的暴露频次
        if (this.lastJoinToken !== '') {
          const now = Date.now()
          const rateLimitMs = 30000
          if (now - this._lastJoinTime >= rateLimitMs) {
            this.joinSession(
              this.lastJoinSessionId,
              this.lastJoinClientType,
              this.lastJoinProject,
              this.lastJoinToken,
            )
          } else {
            console.info('serein ws: skip rejoin (rate limited, last join was ' + (now - this._lastJoinTime) + 'ms ago)')
          }
        }
        if (this.onOpen) {
          this.onOpen()
        }
        // 启动心跳保活
        this.startHeartbeat()
      })
      newWs.on('message', (err: Error | null, data: string | ArrayBuffer) => {
        if (myConnId !== this.connId) return
        if (err) {
          console.error('serein ws: message err ' + (err as Error).message)
          return
        }
        if (typeof data !== 'string') return
        try {
          const parsed = JSON.parse(data) as WSEvent
          console.debug('serein ws: RECV type=' + parsed.type)
          // E2E: decrypt content_enc in incoming cmd_step messages
          if (e2eCrypto.isEnabled && parsed.payload) {
            const encContent = parsed.payload['content_enc']
            if (encContent) {
              const decrypted = e2eCrypto.decrypt(encContent as string)
              if (decrypted !== null) {
                parsed.payload['content'] = decrypted
                // ArkTS 不支持 delete，设为空字符串标记已解密
                parsed.payload['content_enc'] = ''
              }
            }
          }
          if (this.onEvent) {
            this.onEvent(parsed)
          }
        } catch (e) {
          console.error('serein ws: parse err ' + (e as Error).message)
        }
      })
      newWs.on('close', () => {
        console.info('serein ws: CLOSE (connId=' + this.connId + ')')
        this._connected = false
        this.connecting = false
        this.stopHeartbeat()
        if (myConnId === this.connId && !this.destroyed) {
          this.notifyState(WSConnectionState.RECONNECTING)
          this.scheduleReconnect()
        } else if (this.destroyed) {
          this.notifyState(WSConnectionState.DISCONNECTED)
        }
      })
      newWs.on('error', (e: Error) => {
        console.error('serein ws: ERROR ' + (e?.message ?? '?'))
        this._connected = false
        this.connecting = false
        this.stopHeartbeat()
        // 不在此处 scheduleReconnect——error 后必跟 close，close 中统一触发
      })
      newWs.connect(this.url, (err: Error) => {
        if (err && myConnId === this.connId && !this.destroyed) {
          console.error('serein ws: connect cb err ' + err.message)
          this.connecting = false
          this.notifyState(WSConnectionState.DISCONNECTED)
          this.scheduleReconnect()
        }
      })
      this.ws = newWs
    } catch (e) {
      console.error('serein ws: create err ' + (e as Error).message)
      this.connecting = false
      if (!this.destroyed) {
        this.notifyState(WSConnectionState.DISCONNECTED)
        this.scheduleReconnect()
      }
    }
  }

  private scheduleReconnect(): void {
    if (this.destroyed || this.connecting) return
    if (this.reconnectTimer !== null) {
      clearTimeout(this.reconnectTimer)
    }
    console.info('serein ws: scheduleReconnect in ' + this.reconnectDelay + 'ms (next delay: ' + Math.min(this.reconnectDelay * 2, this.maxReconnectDelay) + 'ms)')
    this.reconnectTimer = setTimeout(() => {
      this.reconnectDelay = Math.min(this.reconnectDelay * 2, this.maxReconnectDelay)
      this.doConnect()
    }, this.reconnectDelay)
  }

  private notifyState(state: WSConnectionState): void {
    if (this.onStateChange) {
      this.onStateChange(state)
    }
  }

  /** 连接是否正常 */
  get connected(): boolean {
    return this._connected && !this.destroyed
  }

  /** 发送 JSON 消息到服务端。
   *  E2E: 如果 E2E 已启用且消息类型为 session_msg，自动加密 payload.content
   *  → payload.content_enc，服务端只看到密文。 */
  send(msg: Record<string, Object>): boolean {
    if (!this.ws || !this._connected) return false
    try {
      // E2E: encrypt session_msg content before sending
      if (e2eCrypto.isEnabled && msg['type'] === 'session_msg') {
        const payload = msg['payload'] as Record<string, Object>
        if (payload && payload['content']) {
          const encrypted = e2eCrypto.encrypt(payload['content'] as string)
          if (encrypted) {
            payload['content_enc'] = encrypted
            // ArkTS 不支持 delete 操作符，设为空字符串。
            // 后端检测 content_enc 时会跳过 content 检查。
            payload['content'] = ''
          }
        }
      }
      this.ws.send(JSON.stringify(msg))
      return true
    } catch (e) {
      console.error('serein ws: send err ' + (e as Error).message)
      return false
    }
  }

  /** 发送 join session 消息。
   *  自动记忆 join 参数，重连后自动 rejoin。
   *  project 字段决定后端按项目分配 session（每项目独立收发）。
   *  token 为 CLIENT_TOKEN。
   */
  joinSession(sessionId: string, clientType: string, project: string, token: string): void {
    // 记忆 join 参数供重连使用
    this.lastJoinSessionId = sessionId
    this.lastJoinClientType = clientType
    this.lastJoinProject = project
    this.lastJoinToken = token
    if (!this.ws) return
    try {
      this.ws.send(JSON.stringify({
        type: 'join',
        session_id: sessionId,
        client_type: clientType,
        project: project,
        token: token,
      }))
      this._lastJoinTime = Date.now()  // 记录发送时间戳供重连限流使用
    } catch (e) {
      console.error('serein ws: join err ' + (e as Error).message)
    }
  }

  /** 发送权限模式切换消息（切换 default/accept_edits/yolo 等模式） */
  sendModeSwitch(mode: string, allowedTools?: string[], disallowedTools?: string[]): boolean {
    const payload: Record<string, Object> = {}
    payload['mode'] = mode
    if (allowedTools && allowedTools.length > 0) {
      payload['allowed_tools'] = allowedTools
    }
    if (disallowedTools && disallowedTools.length > 0) {
      payload['disallowed_tools'] = disallowedTools
    }
    const msg: Record<string, Object> = {}
    msg['type'] = 'mode_switch'
    msg['payload'] = payload
    return this.send(msg)
  }

  /** 启动应用层心跳保活 */
  private startHeartbeat(): void {
    this.stopHeartbeat()
    this.heartbeatTimer = setInterval(() => {
      if (this._connected && !this.destroyed) {
        const hb: Record<string, Object> = {}
        hb['type'] = 'heartbeat'
        this.send(hb)
      }
    }, WebSocketClient.HEARTBEAT_INTERVAL)
  }

  /** 停止心跳定时器 */
  private stopHeartbeat(): void {
    if (this.heartbeatTimer !== null) {
      clearInterval(this.heartbeatTimer)
      this.heartbeatTimer = null
    }
  }

  /** 手动断开（不自动重连） */
  disconnect(): void {
    this.destroyed = true
    this.stopHeartbeat()
    if (this.reconnectTimer !== null) {
      clearTimeout(this.reconnectTimer)
      this.reconnectTimer = null
    }
    if (this.ws) {
      try { this.ws.close() } catch (_) {}
      this.ws = null
    }
    this._connected = false
    this.notifyState(WSConnectionState.DISCONNECTED)
  }

  destroy(): void {
    this.disconnect()
  }
}
