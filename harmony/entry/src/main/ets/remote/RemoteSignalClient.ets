import { webSocket } from '@kit.NetworkKit'
import { RemoteSession } from './RemoteModels'

export interface RemoteSessionDescription {
  type: string
  sdp: string
}

export interface RemoteIceCandidate {
  candidate: string
  sdpMid?: string | null
  sdpMLineIndex?: number | null
  usernameFragment?: string | null
}

export interface RemoteSignalEvent {
  v: number
  type: string
  session?: RemoteSession
  error?: string
  session_id?: string
  revision?: number
  description?: RemoteSessionDescription
  candidate?: RemoteIceCandidate
}

interface QueuedSignalEnvelope {
  session_id?: string
  revision?: number
}

export class RemoteSignalClient {
  private ws: webSocket.WebSocket | null = null
  private active: boolean = false
  private joined: boolean = false
  private pending: string[] = []
  private reconnectTimer: number = -1
  private flushRetryTimer: number = -1
  private onEvent?: (event: RemoteSignalEvent) => void

  connect(backendUrl: string, token: string, handler: (event: RemoteSignalEvent) => void): void {
    this.close()
    if (backendUrl.length === 0 || token.length === 0) return
    this.onEvent = handler
    this.active = true
    this.joined = false
    this.pending = []
    const url = backendUrl.replace(/^https?:\/\//, (value: string) => value === 'https://' ? 'wss://' : 'ws://')
      .replace(/\/+$/, '') + '/v1/remote/ws'
    const joinPayload = JSON.stringify({ 'v': 1, 'type': 'remote.join', 'role': 'controller', 'token': token })
    const socket = webSocket.createWebSocket()
    let joinRetryTimer: number = -1
    let joinAttempts = 0
    // Connect watchdog: if not joined within 5s, force close to trigger
    // reconnect. Without this, a silently stuck WS connection leaves wsStatus
    // at 'connecting' forever and client_ready never gets sent.
    let connectWatchdog: number = setTimeout(() => {
      if (!this.joined && this.ws === socket) {
        console.warn('serein remote ws: connect watchdog (5s no join), forcing reconnect')
        try { socket.close() } catch (_) {}
      }
    }, 5000)
    const sendJoin = () => {
      if (!this.active || this.ws !== socket) return
      joinAttempts++
      try {
        const p: Promise<boolean> = socket.send(joinPayload)
        p.then((ok: boolean) => {
          console.info('serein remote ws: join sent (attempt ' + joinAttempts + ', ok=' + ok + ')')
          if (!ok) {
            console.error('serein remote ws: join send returned false')
          }
        }).catch((e: Error) => {
          console.error('serein remote ws: join send promise err ' + e.message)
        })
      } catch (e) {
        console.error('serein remote ws: join send err ' + (e as Error).message)
      }
      // If no remote.joined within 2s, resend (max 3 attempts)
      if (!this.joined && joinAttempts < 3) {
        joinRetryTimer = setTimeout(sendJoin, 2000)
      }
    }
    socket.on('open', () => {
      console.info('serein remote ws: open')
      sendJoin()
    })
    socket.on('message', (error: Error | null, data: string | ArrayBuffer) => {
      if (!this.active || this.ws !== socket) return
      // HarmonyOS may pass undefined instead of null for error on success
      if (error !== null && error !== undefined) {
        console.error('serein remote ws: message error ' + (error as Error).message)
        return
      }
      if (typeof data !== 'string') {
        console.warn('serein remote ws: non-string message type=' + typeof data)
        return
      }
      console.info('serein remote ws: raw msg len=' + data.length)
      try {
        const event = JSON.parse(data) as RemoteSignalEvent
        if (event.v !== 1 || typeof event.type !== 'string') {
          console.warn('serein remote ws: bad envelope, type=' + typeof event.type + ' v=' + event.v)
          return
        }
        console.info('serein remote ws: RECV ' + event.type)
        if (event.type === 'remote.joined') {
          this.joined = true
          if (joinRetryTimer >= 0) { clearTimeout(joinRetryTimer); joinRetryTimer = -1 }
          if (connectWatchdog >= 0) { clearTimeout(connectWatchdog); connectWatchdog = -1 }
          this.flushPending()
        }
        if (this.onEvent) this.onEvent(event)
      } catch (e) {
        console.error('serein remote ws: parse err ' + (e as Error).message + ' data=' + data.slice(0, 100))
      }
    })
    socket.on('close', () => {
      console.info('serein remote ws: close')
      if (joinRetryTimer >= 0) { clearTimeout(joinRetryTimer); joinRetryTimer = -1 }
      if (connectWatchdog >= 0) { clearTimeout(connectWatchdog); connectWatchdog = -1 }
      if (this.ws !== socket) return
      this.ws = null
      this.joined = false
      this.pending = []
      if (this.onEvent) this.onEvent({ v: 1, type: 'remote.signal.disconnected' })
      if (this.active && this.reconnectTimer < 0) {
        this.reconnectTimer = setTimeout(() => {
          this.reconnectTimer = -1
          if (this.active) this.connect(backendUrl, token, handler)
        }, 1500)
      }
    })
    socket.on('error', (e: Error) => {
      console.error('serein remote ws: error ' + (e?.message ?? '?'))
      if (this.ws !== socket) return
      this.pending = []
    })
    this.ws = socket
    socket.connect(url, (err: Error) => {
      if (err) {
        console.error('serein remote ws: connect err ' + err.message)
        // On connect error, trigger reconnect. Previously this just returned,
        // leaving wsStatus stuck at 'connecting' forever.
        if (this.ws === socket) {
          try { socket.close() } catch (_) {}
        }
        return
      }
      console.info('serein remote ws: connected')
      // Do NOT send join here — on HarmonyOS the connect callback fires before
      // the WS handshake is complete (before 'open' event). Sending here causes
      // the join to be silently dropped, and the backend never receives it,
      // resulting in a 5s ReadMessage timeout and endless reconnect loop.
      // The 'open' event handler above calls sendJoin() at the right time.
    })
  }

  async sendClientReady(sessionId: string, revision: number, ticket: string): Promise<boolean> {
    if (!this.validSessionEnvelope(sessionId, revision) || ticket.length < 32 || ticket.length > 4096) {
      console.error('serein remote ws: sendClientReady rejected envelope rev=' + revision +
        ' ticketLen=' + ticket.length)
      return false
    }
    console.info('serein remote ws: -> client_ready rev=' + revision + ' session=' + sessionId.slice(0, 8) +
      ' joined=' + this.joined)
    return this.sendOrQueueAsync(JSON.stringify({
      'v': 1,
      'type': 'remote.signal.client_ready',
      'session_id': sessionId,
      'revision': revision,
      'ticket': ticket
    }))
  }

  sendDescription(sessionId: string, revision: number, description: RemoteSessionDescription): void {
    if (!this.validSessionEnvelope(sessionId, revision) || description.type !== 'answer' ||
      description.sdp.length === 0 || description.sdp.length > 262144) return
    this.sendOrQueue(JSON.stringify({
      'v': 1,
      'type': 'remote.signal.answer',
      'session_id': sessionId,
      'revision': revision,
      'description': description
    }))
  }

  sendCandidate(sessionId: string, revision: number, candidate: RemoteIceCandidate): void {
    if (!this.validSessionEnvelope(sessionId, revision) || candidate.candidate.length > 65536) return
    this.sendOrQueue(JSON.stringify({
      'v': 1,
      'type': 'remote.signal.ice',
      'session_id': sessionId,
      'revision': revision,
      'candidate': candidate
    }))
  }

  /**
   * 切换到新的协商代次前丢弃旧信令。旧 ICE 在断线重连后才被 flush 时，
   * 后端会按设计返回 REMOTE_STATE_CONFLICT；它不能再影响新的画面会话。
   */
  dropQueuedSignalsForRevision(sessionId: string, revision: number): void {
    const kept: string[] = []
    for (const raw of this.pending) {
      try {
        const signal = JSON.parse(raw) as QueuedSignalEnvelope
        if (signal.session_id === sessionId && signal.revision !== revision) continue
      } catch (_) {}
      kept.push(raw)
    }
    if (kept.length !== this.pending.length) {
      console.info('serein remote ws: dropped ' + (this.pending.length - kept.length) +
        ' stale queued signal(s) for rev=' + revision)
    }
    this.pending = kept
  }

  private validSessionEnvelope(sessionId: string, revision: number): boolean {
    return sessionId.length >= 8 && sessionId.length <= 128 && revision > 0
  }

  private sendOrQueue(raw: string): boolean {
    if (!this.active || this.ws === null) {
      console.warn('serein remote ws: sendOrQueue inactive or null ws, dropping ' + raw.slice(0, 60))
      return false
    }
    if (!this.joined) {
      if (this.pending.length < 32) {
        this.pending.push(raw)
        console.info('serein remote ws: queued (not joined), pending=' + this.pending.length)
      } else {
        console.warn('serein remote ws: pending queue full, dropping')
      }
      return false
    }
    this.sendRaw(raw)
    return true
  }

  /**
   * Async variant of sendOrQueue that waits for the WS send Promise to resolve
   * before returning. Used by sendClientReady so the caller knows whether the
   * message was actually handed to the OS network stack.
   */
  private async sendOrQueueAsync(raw: string): Promise<boolean> {
    if (!this.active || this.ws === null) {
      console.warn('serein remote ws: sendOrQueueAsync inactive or null ws, dropping ' + raw.slice(0, 60))
      return false
    }
    if (!this.joined) {
      if (this.pending.length < 32) {
        this.pending.push(raw)
        console.info('serein remote ws: queued (not joined), pending=' + this.pending.length)
      } else {
        console.warn('serein remote ws: pending queue full, dropping')
      }
      return false
    }
    return this.sendRawConfirm(raw)
  }

  // sendRaw wraps this.ws.send() and properly handles the Promise<boolean>
  // returned by HarmonyOS webSocket.send(). Without this, sends can silently
  // fail (Promise rejection swallowed) and the bridge never receives
  // client_ready, causing the 30s "timeout waiting for controller ready".
  private sendRaw(raw: string): void {
    if (this.ws === null) {
      if (this.pending.length < 32) this.pending.push(raw)
      return
    }
    const tag = raw.slice(0, 80)
    try {
      const p: Promise<boolean> = this.ws.send(raw)
      p.then((ok: boolean) => {
        if (!ok) {
          console.error('serein remote ws: send returned false for ' + tag)
          this.requeueOrRetry(raw)
        }
      }).catch((e: Error) => {
        console.error('serein remote ws: send promise err ' + e.message + ' for ' + tag)
        this.requeueOrRetry(raw)
      })
    } catch (e) {
      console.error('serein remote ws: send threw ' + (e as Error).message + ' for ' + tag)
      this.requeueOrRetry(raw)
    }
  }

  /**
   * Confirmed send: returns a Promise that resolves with the actual WS send
   * result (true = handed to OS, false = failed). Unlike sendRaw which is
   * fire-and-forget, this lets the caller decide what to do on failure.
   */
  private sendRawConfirm(raw: string): Promise<boolean> {
    const ws = this.ws
    if (ws === null) {
      return Promise.resolve(false)
    }
    const tag = raw.slice(0, 80)
    return new Promise<boolean>((resolve: (v: boolean) => void) => {
      try {
        const p: Promise<boolean> = ws.send(raw)
        p.then((ok: boolean) => {
          if (!ok) {
            console.error('serein remote ws: send returned false for ' + tag)
          }
          resolve(ok)
        }).catch((e: Error) => {
          console.error('serein remote ws: send promise err ' + e.message + ' for ' + tag)
          resolve(false)
        })
      } catch (e) {
        console.error('serein remote ws: send threw ' + (e as Error).message + ' for ' + tag)
        resolve(false)
      }
    })
  }

  // requeueOrRetry puts a failed send back into pending and schedules a
  // flush retry. This avoids losing client_ready if the WS had a transient
  // issue right at the moment of sending.
  private requeueOrRetry(raw: string): void {
    if (this.pending.length < 32) this.pending.push(raw)
    if (this.flushRetryTimer < 0) {
      this.flushRetryTimer = setTimeout(() => {
        this.flushRetryTimer = -1
        if (this.active && this.joined) this.flushPending()
      }, 500)
    }
  }

  private flushPending(): void {
    if (!this.active || !this.joined || this.ws === null) return
    const items = this.pending
    this.pending = []
    if (items.length > 0) console.info('serein remote ws: flushing ' + items.length + ' pending messages')
    items.forEach((raw: string) => { this.sendRaw(raw) })
  }

  close(): void {
    this.active = false
    this.joined = false
    this.pending = []
    if (this.reconnectTimer >= 0) {
      clearTimeout(this.reconnectTimer)
      this.reconnectTimer = -1
    }
    if (this.flushRetryTimer >= 0) {
      clearTimeout(this.flushRetryTimer)
      this.flushRetryTimer = -1
    }
    if (this.ws !== null) {
      try { this.ws.close() } catch (_) {}
      this.ws = null
    }
  }
}
