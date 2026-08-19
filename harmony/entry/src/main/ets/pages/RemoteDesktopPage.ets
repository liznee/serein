import { KeyboardAvoidMode, promptAction, router, window } from '@kit.ArkUI'
import { webview } from '@kit.ArkWeb'
import remoteAuthService from '../remote/RemoteAuthService'
import remoteStore from '../remote/RemoteStore'
import {
  RemoteIceCandidate,
  RemoteSessionDescription,
  RemoteSignalClient,
  RemoteSignalEvent
} from '../remote/RemoteSignalClient'
import { isRemoteTerminalState, RemoteHost, RemoteSession, remoteStateLabel } from '../remote/RemoteModels'
import DeviceApi from '../api/DeviceApi'
import NavPath from '../model/NavPath'
import { COLOR, RADIUS, SPACE, TYPO, WEIGHT } from '../utils/DesignTokens'
import { AmbientBackdrop } from '../components/AmbientBackdrop'

interface RemoteMediaBridgeEvent {
  v: number
  type: string
  state?: string
  description?: RemoteSessionDescription
  candidate?: RemoteIceCandidate
}

class RemoteMediaBridge {
  private handler: (payload: string) => void

  constructor(handler: (payload: string) => void) {
    this.handler = handler
  }

  postMessage(payload: string): void {
    this.handler(payload)
  }
}

@Component
export struct RemoteDesktopContent {
  @Prop asTab: boolean = false
  @State private hosts: RemoteHost[] = []
  @State private loading: boolean = true
  @State private errorText: string = ''
  @State private currentSession?: RemoteSession = undefined
  @State private actionBusy: boolean = false
  @State private connectionPending: boolean = false
  // Set synchronously when the confirmation dialog is accepted. This prevents
  // a normal host-card frame from rendering between dialog dismissal and the
  // first remote-session response.
  @State private remoteTransitioning: boolean = false
  @State private mediaState: string = 'waiting'
  @State private wsStatus: string = 'connecting'
  @State private readyStatus: string = ''
  @State private primaryLoading: boolean = true
  @State private isPrimary: boolean = false
  @State private primaryDeviceName: string = ''
  @State private primaryRegistering: boolean = false
  @State private primaryClearing: boolean = false
	@State private primaryPendingRequests: RemoteSession[] = []
	@State private primaryDecisionBusy: boolean = false
  // 自定义弹窗状态（替代系统 promptAction.showDialog，统一深色风格）
  @State private dialogVisible: boolean = false
  @State private dialogTitle: string = ''
  @State private dialogMessage: string = ''
  @State private dialogConfirmText: string = ''
  @State private dialogCancelText: string = ''
  @State private dialogConfirmPrimary: boolean = true
  private dialogCallback: (() => void) | null = null
  @State private isFullscreen: boolean = false
  @State private isLandscape: boolean = false
  @State private remoteKeyboardVisible: boolean = false
  @State private remoteKeyboardText: string = ''
  private ignoreKeyboardBufferClear: boolean = false
  private pollTimer: number = -1
	private primaryRequestPollTimer: number = -1
  private signal: RemoteSignalClient = new RemoteSignalClient()
  private mediaController: webview.WebviewController = new webview.WebviewController()
  private mediaBridge: RemoteMediaBridge = new RemoteMediaBridge((payload: string) => {
    this.handleMediaBridge(payload)
  })
  private mediaReady: boolean = false
  private mediaSessionId: string = ''
  private mediaRevision: number = 0
  private readyRevision: number = 0
  private readyInFlightRevision: number = 0
  private readyRetryTimer: number = -1
  private readyRetrySessionId: string = ''
  private offerReceived: boolean = false
  private pendingMediaSignals: RemoteSignalEvent[] = []

  aboutToAppear(): void {
    this.syncTabImmersiveMode()
    // Remote desktop needs to shrink the video area for the system IME. The
    // app default is OFFSET, which moves the whole page and can leave the
    // keyboard covering the remote image.
    this.setRemoteKeyboardAvoidMode(true)
    this.connectEvents()
    this.loadHosts()
    this.loadPrimaryStatus()
	this.startPrimaryRequestPolling()
  }

  onPageShow(): void {
    // 页面重新显示时刷新主设备状态（例如从其他页面返回）
    this.loadPrimaryStatus()
  }

  aboutToDisappear(): void {
    this.stopPolling()
	this.stopPrimaryRequestPolling()
    this.stopReadyRetry()
    this.signal.close()
    this.closeMedia()
    this.remoteKeyboardVisible = false
    this.restoreWindowPresentation()
    this.setRemoteKeyboardAvoidMode(false)
  }

  /**
   * In the tab shell, landscape remote control owns the whole display. Keep
   * this as a shared UI-only flag so the parent Tabs removes its bottom bar
   * without affecting system orientation or any remote-input coordinates.
   */
  private syncTabImmersiveMode(): void {
    AppStorage.setOrCreate('remoteDesktopImmersive', this.asTab && this.isLandscape)
  }

  private setRemoteKeyboardAvoidMode(resize: boolean): void {
    try {
      this.getUIContext().setKeyboardAvoidMode(
        resize ? KeyboardAvoidMode.RESIZE : KeyboardAvoidMode.OFFSET)
    } catch (_) {}
  }

  private connectEvents(): void {
    const backend = AppStorage.get<string>('backendUrl') ?? ''
    const token = AppStorage.get<string>('clientToken') ?? ''
    console.info('serein remote: connectEvents backend=' + backend.slice(0, 30) + ' tokenLen=' + token.length)
    this.wsStatus = 'connecting'
    this.signal.connect(backend, token, (event) => {
		// The primary phone receives a real-time event for secondary-device
		// requests. Refresh only the approval queue; never reload the visible
		// primary-device status card here.
		if (this.isPrimary && event.type === 'remote.session.requested' &&
		  event.session !== undefined && !event.session.controller_is_primary) {
		  this.loadPrimaryRequests()
		}
      if (event.session !== undefined && remoteStore.applySession(event.session)) {
        if (this.currentSession !== undefined && this.currentSession.id === event.session.id) {
          this.applySession(event.session)
        } else {
          console.info('serein remote: event session id mismatch or no currentSession, skipping applySession')
        }
      }
      this.handleSignalEvent(event)
    })
  }

  private applySession(session: RemoteSession): void {
    const prevState = this.currentSession?.state ?? 'none'
    const previous = this.currentSession
    if ((session.state === 'negotiating' || session.state === 'reconnecting') &&
      previous !== undefined && previous.id === session.id && previous.revision !== session.revision) {
      this.signal.dropQueuedSignalsForRevision(session.id, session.revision)
    }
    this.currentSession = session
    this.remoteTransitioning = false
    console.info('serein remote: applySession state=' + session.state + ' rev=' + session.revision +
      ' prev=' + prevState)
    if (session.state === 'negotiating' || session.state === 'reconnecting') {
      this.connectionPending = false
      this.mediaSessionId = session.id
      this.mediaRevision = session.revision
      this.ensureControllerReady(session)
      this.startReadyRetry(session.id)
	} else if (session.state === 'waiting_primary') {
		// A secondary phone is waiting for a human decision on the primary
		// device, not for media. Remove the connection overlay and show the
		// session card instead of a misleading black remote screen.
		this.connectionPending = false
	} else if (isRemoteTerminalState(session.state)) {
      this.connectionPending = false
      this.closeMedia()
      this.stopReadyRetry()
      // Auto-clear the session card after 2s so the user briefly sees
      // "已结束" / "连接失败" before the card disappears.
      const endedSessionId = session.id
      setTimeout(() => {
        if (this.currentSession !== undefined && this.currentSession.id === endedSessionId) {
          this.currentSession = undefined
          this.readyStatus = ''
        }
      }, 2000)
    }
  }

  private async ensureControllerReady(session: RemoteSession): Promise<void> {
    if (this.readyRevision === session.revision || this.readyInFlightRevision === session.revision) {
      console.info('serein remote: ensureControllerReady skip rev=' + session.revision +
        ' readyRev=' + this.readyRevision + ' inFlightRev=' + this.readyInFlightRevision)
      return
    }
    this.readyInFlightRevision = session.revision
    this.readyStatus = 'refreshing ticket'
    console.info('serein remote: ensureControllerReady start rev=' + session.revision + ' session=' + session.id.slice(0, 8) +
      ' wsStatus=' + this.wsStatus)
    try {
      const ticket = await remoteAuthService.refreshTicket(session.id)
      console.info('serein remote: refreshTicket ok rev=' + ticket.revision + ' ticketLen=' + ticket.ticket.length)
      this.readyStatus = 'ticket ok, sending client_ready'
      const latest = this.currentSession
      if (latest === undefined || latest.id !== session.id || latest.revision !== ticket.revision ||
        (latest.state !== 'negotiating' && latest.state !== 'reconnecting')) {
        console.warn('serein remote: ensureControllerReady state changed during await' +
          ' latestRev=' + (latest?.revision ?? 0) + ' latestState=' + (latest?.state ?? 'none'))
        this.readyStatus = 'state changed, aborted'
        return
      }
      // Await the actual WS send result — previously this was fire-and-forget
      // and readyRevision was set prematurely, causing all retries to skip.
      const sent = await this.signal.sendClientReady(latest.id, ticket.revision, ticket.ticket)
      if (sent) {
        this.readyRevision = ticket.revision
        this.readyStatus = 'client_ready sent rev=' + ticket.revision
        console.info('serein remote: ensureControllerReady done rev=' + ticket.revision)
      } else {
        // WS send failed — do NOT set readyRevision so startReadyRetry retries.
        this.readyStatus = 'send failed (ws: ' + this.wsStatus + '), will retry'
        console.warn('serein remote: ensureControllerReady send FAILED rev=' + ticket.revision +
          ' wsStatus=' + this.wsStatus)
      }
    } catch (error) {
      const msg = (error as Error).message
      console.error('serein remote: ensureControllerReady failed: ' + msg)
      this.readyStatus = 'failed: ' + msg
      this.errorText = msg
      // Schedule a retry after 3s. The readyInFlightRevision guard is reset in
      // finally, so the next applySession (from polling or WS) can re-enter.
      // But if no new applySession fires within 3s, this timer ensures we
      // retry even without a state change.
      setTimeout(() => {
        const current = this.currentSession
        if (current !== undefined && current.id === session.id &&
          (current.state === 'negotiating' || current.state === 'reconnecting') && this.readyRevision === 0) {
          console.info('serein remote: ensureControllerReady retry after error')
          this.ensureControllerReady(current)
        }
      }, 3000)
    } finally {
      if (this.readyInFlightRevision === session.revision) this.readyInFlightRevision = 0
    }
  }

  private handleSignalEvent(event: RemoteSignalEvent): void {
    if (event.type === 'remote.joined') {
      console.info('serein remote: ws joined')
      this.wsStatus = 'joined'
      if (this.currentSession !== undefined &&
        (this.currentSession.state === 'negotiating' || this.currentSession.state === 'reconnecting')) {
        this.readyRevision = 0
        this.ensureControllerReady(this.currentSession)
      }
      return
    }
    if (event.type === 'remote.signal.disconnected') {
      console.warn('serein remote: ws disconnected')
      this.wsStatus = 'disconnected'
      this.readyRevision = 0
      this.mediaState = 'disconnected'
      return
    }
    if (event.type === 'remote.error') {
      console.error('serein remote: ws error ' + (event.error ?? 'unknown'))
      // An old queued ICE packet can race a reconnect. The backend must reject
      // it, but it is not a failure of the current media session.
      if (event.error === 'REMOTE_STATE_CONFLICT' && this.currentSession !== undefined) {
        const session = this.currentSession
        if (session.state === 'negotiating' || session.state === 'reconnecting') {
          this.signal.dropQueuedSignalsForRevision(session.id, session.revision)
          this.readyRevision = 0
          if (this.readyInFlightRevision === 0) this.ensureControllerReady(session)
        }
        return
      }
      this.wsStatus = 'error: ' + (event.error ?? 'unknown')
      this.errorText = event.error ?? 'REMOTE_SIGNAL_ERROR'
      return
    }
    if (event.type === 'remote.signal.client_ready') {
      // Host's client_ready forwarded by backend — this is a definitive signal
      // that the bridge has joined signaling and is ready to receive our
      // client_ready. If our previous send was dropped (because the bridge
      // hadn't joined yet), re-send immediately instead of waiting for the
      // 3s retry timer. This cuts first-frame latency by ~3 seconds.
      console.info('serein remote: <- host client_ready rev=' + event.revision)
      if (!this.offerReceived && this.currentSession !== undefined &&
        (this.currentSession.state === 'negotiating' || this.currentSession.state === 'reconnecting') &&
        this.readyInFlightRevision === 0) {
        console.info('serein remote: host ready, re-sending client_ready immediately' +
          ' readyRev=' + this.readyRevision + ' offerRx=' + this.offerReceived)
        this.readyRevision = 0
        this.ensureControllerReady(this.currentSession)
      }
      return
    }
    if (event.session_id !== this.mediaSessionId || event.revision !== this.mediaRevision) {
      console.info('serein remote: signal filtered sid=' + (event.session_id ?? '').slice(0, 8) +
        ' rev=' + event.revision + ' expected sid=' + this.mediaSessionId.slice(0, 8) +
        ' rev=' + this.mediaRevision)
      return
    }
    if (event.type === 'remote.signal.offer' || event.type === 'remote.signal.ice' ||
      event.type === 'remote.signal.peer_left') {
      if (event.type === 'remote.signal.offer') {
        this.offerReceived = true
        console.info('serein remote: offer received, stopping readyRetry')
      }
      console.info('serein remote: -> media ' + event.type)
      this.pushSignalToMedia(event)
    }
  }

  private pushSignalToMedia(event: RemoteSignalEvent): void {
    if (!this.mediaReady) {
      if (this.pendingMediaSignals.length < 128) this.pendingMediaSignals.push(event)
      return
    }
    const payload: Record<string, Object> = {
      'v': 1,
      'type': event.type
    }
    if (event.description !== undefined) payload['description'] = event.description
    if (event.candidate !== undefined) payload['candidate'] = event.candidate
    const raw = JSON.stringify(payload)
    const script = 'window.sereinRemote&&window.sereinRemote.receive(' + JSON.stringify(raw) + ')'
    this.mediaController.runJavaScript(script).catch(() => {
      this.mediaReady = false
      if (this.pendingMediaSignals.length < 128) this.pendingMediaSignals.push(event)
    })
  }

  private handleMediaBridge(payload: string): void {
    if (payload.length === 0 || payload.length > 320 * 1024) return
    try {
      const event = JSON.parse(payload) as RemoteMediaBridgeEvent
      if (event.v !== 1) return
      if (event.type === 'remote.media.ready') {
        this.mediaReady = true
        const queued = this.pendingMediaSignals
        this.pendingMediaSignals = []
        queued.forEach((signalEvent: RemoteSignalEvent) => { this.pushSignalToMedia(signalEvent) })
      } else if (event.type === 'remote.media.state' && event.state !== undefined) {
        const allowed = ['new', 'connecting', 'connected', 'disconnected', 'failed', 'closed', 'playing',
          'track_received', 'peer_left']
        if (allowed.indexOf(event.state) >= 0) this.mediaState = event.state
        if (event.state === 'fullscreen') {
          this.isFullscreen = true
          this.applyWindowPresentation()
        }
        if (event.state === 'windowed') {
          this.isFullscreen = false
          this.applyWindowPresentation()
        }
        if (event.state === 'landscape') {
          this.isLandscape = true
          this.syncTabImmersiveMode()
          this.applyWindowPresentation()
        }
        if (event.state === 'portrait') {
          this.isLandscape = false
          this.syncTabImmersiveMode()
          this.applyWindowPresentation()
        }
        if (event.state === 'keyboard') this.showRemoteKeyboard()
      } else if (event.type === 'remote.signal.answer' && event.description !== undefined &&
        event.description.type === 'answer' && this.mediaSessionId.length > 0) {
        this.signal.sendDescription(this.mediaSessionId, this.mediaRevision, event.description)
      } else if (event.type === 'remote.signal.ice' && event.candidate !== undefined &&
        this.mediaSessionId.length > 0) {
        this.signal.sendCandidate(this.mediaSessionId, this.mediaRevision, event.candidate)
      }
    } catch (_) {}
  }

  private closeMedia(): void {
    if (this.mediaReady) {
      this.mediaController.runJavaScript('window.sereinRemote&&window.sereinRemote.close()').catch(() => {})
    }
    this.mediaReady = false
    this.mediaSessionId = ''
    this.mediaRevision = 0
    this.readyRevision = 0
    this.readyInFlightRevision = 0
    this.offerReceived = false
    this.pendingMediaSignals = []
    this.mediaState = 'waiting'
  }

  private async applyWindowPresentation(): Promise<void> {
    const context = this.getUIContext().getHostContext()
    if (context === undefined) return
    try {
      const appWindow = await window.getLastWindow(context)
      await appWindow.setPreferredOrientation(
        this.isLandscape ? window.Orientation.LANDSCAPE : window.Orientation.PORTRAIT)
      await appWindow.setWindowSystemBarEnable(this.isFullscreen ? [] : ['status', 'navigation'])
    } catch (error) {
      console.warn('serein remote: update presentation failed: ' + (error as Error).message)
    }
  }

  private restoreWindowPresentation(): void {
    this.isFullscreen = false
    this.isLandscape = false
    this.syncTabImmersiveMode()
    this.applyWindowPresentation()
  }

  private showRemoteKeyboard(): void {
    this.remoteKeyboardVisible = true
    setTimeout(() => {
      try {
        this.getUIContext().getFocusController().requestFocus('remote-keyboard-input')
      } catch (_) {}
    }, 80)
  }

  private hideRemoteKeyboard(): void {
    this.remoteKeyboardVisible = false
    this.remoteKeyboardText = ''
  }

  private sendRemoteKeyboardText(text: string): void {
    if (text.length === 0) return
    const script = 'window.sereinRemote&&window.sereinRemote.sendText(' +
      JSON.stringify(text.slice(0, 8192)) + ')'
    this.mediaController.runJavaScript(script).catch(() => {})
  }

  private sendRemoteKeyPress(keyCode: number, count: number = 1): void {
    const safeCount = Math.max(1, Math.min(count, 256))
    const script = 'window.sereinRemote&&window.sereinRemote.sendKeyPress(' +
      keyCode + ',' + safeCount + ')'
    this.mediaController.runJavaScript(script).catch(() => {})
  }

  private forwardRemoteKeyboardChange(value: string): void {
    if (this.ignoreKeyboardBufferClear && value.length === 0) {
      this.ignoreKeyboardBufferClear = false
      this.remoteKeyboardText = ''
      return
    }
    const previous = this.remoteKeyboardText
    if (value === previous) return

    let prefix = 0
    const limit = Math.min(previous.length, value.length)
    while (prefix < limit && previous.charAt(prefix) === value.charAt(prefix)) prefix++
    let previousEnd = previous.length
    let valueEnd = value.length
    while (previousEnd > prefix && valueEnd > prefix &&
      previous.charAt(previousEnd - 1) === value.charAt(valueEnd - 1)) {
      previousEnd--
      valueEnd--
    }

    const removedCount = previousEnd - prefix
    if (removedCount > 0) this.sendRemoteKeyPress(8, removedCount)
    const inserted = value.slice(prefix, valueEnd)
    const lines = inserted.split(/\r\n|\r|\n/)
    for (let i = 0; i < lines.length; i++) {
      this.sendRemoteKeyboardText(lines[i])
      if (i < lines.length - 1) this.sendRemoteKeyPress(13)
    }
    this.remoteKeyboardText = value
  }

  private submitRemoteKeyboard(): void {
    this.sendRemoteKeyPress(13)
    this.ignoreKeyboardBufferClear = true
    this.remoteKeyboardText = ''
  }

  private async loadHosts(): Promise<void> {
    this.loading = true
    this.errorText = ''
    try {
      const response = await remoteAuthService.listHosts()
      remoteStore.replaceHosts(response.items)
      this.hosts = remoteStore.listHosts()
    } catch (error) {
      this.errorText = (error as Error).message
    } finally {
      this.loading = false
    }
  }

  /**
   * 二次确认弹窗：申请远程桌面前的本地确认。
   *
   * 安全设计：远程桌面属于系统级敏感操作，手机端发起前必须弹窗确认，
   * 且后端只接受已配对的主设备。主设备确认后电脑端自动授权，不重复弹窗。
   */
  private async confirmRequestView(host: RemoteHost): Promise<void> {
    // The primary-device fact is already loaded with the page. Do not refresh
    // the visible primary card just before opening this dialog: that caused
    // the cards and their pills to re-layout and appear to jump.
    if (!this.isPrimary) {
		this.showPrimaryApprovalRequiredDialog(host)
      return
    }
    this.showCustomDialog(
      '申请远程桌面',
      `即将向「${host.display_name}」发起远程桌面请求（含触控输入）。\n当前主设备确认后将直接连接，电脑端不会重复弹窗。`,
      '确认申请',
      '取消',
      true,
      () => { this.beginRemoteConnection(host) }
    )
  }

  /**
   * 加载主设备状态并更新 UI
   */
  private async loadPrimaryStatus(): Promise<void> {
    this.primaryLoading = true
    try {
      const resp = await DeviceApi.getPrimaryStatus()
      this.isPrimary = resp.is_primary
      this.primaryDeviceName = resp.device_name
		if (this.isPrimary) {
			this.loadPrimaryRequests()
		} else {
			this.primaryPendingRequests = []
		}
    } catch (e) {
      console.error('serein remote: loadPrimaryStatus failed: ' + (e as Error).message)
      this.isPrimary = false
      this.primaryDeviceName = ''
		this.primaryPendingRequests = []
    } finally {
      this.primaryLoading = false
    }
  }

  /**
   * 检查当前设备是否为主设备（用于申请远程桌面前的校验）
   */
  private async checkPrimaryDevice(): Promise<boolean> {
    await this.loadPrimaryStatus()
    return this.isPrimary
  }

  // This polling updates only the approval queue. It intentionally does not
  // call loadPrimaryStatus(), so a control request never causes the visible
  // primary-device cards or their pills to jump.
  private startPrimaryRequestPolling(): void {
    this.stopPrimaryRequestPolling()
    this.primaryRequestPollTimer = setInterval(() => {
      if (this.isPrimary) this.loadPrimaryRequests()
    }, 4000)
  }

  private stopPrimaryRequestPolling(): void {
    if (this.primaryRequestPollTimer >= 0) {
      clearInterval(this.primaryRequestPollTimer)
      this.primaryRequestPollTimer = -1
    }
  }

  private async loadPrimaryRequests(): Promise<void> {
    if (!this.isPrimary) return
    try {
      const result = await remoteAuthService.listPrimaryRequests()
      this.primaryPendingRequests = result.items
    } catch (error) {
      // The normal host list remains usable if a backend is still upgrading.
      // Do not surface an error or alter the primary card for this background
      // refresh.
      console.warn('serein remote: load primary requests failed: ' + (error as Error).message)
    }
  }

  private async decidePrimaryRequest(session: RemoteSession, approve: boolean): Promise<void> {
    if (this.primaryDecisionBusy) return
    this.primaryDecisionBusy = true
    try {
      if (approve) {
        await remoteAuthService.approvePrimaryRequest(session)
        promptAction.showToast({ message: '已允许远程控制申请', duration: 1800 })
      } else {
        await remoteAuthService.rejectPrimaryRequest(session)
        promptAction.showToast({ message: '已拒绝远程控制申请', duration: 1800 })
      }
      await this.loadPrimaryRequests()
    } catch (error) {
      promptAction.showToast({ message: '处理失败: ' + (error as Error).message, duration: 2500 })
    } finally {
      this.primaryDecisionBusy = false
    }
  }

  // A secondary device must ask the primary phone; it must never take over
  // the primary-device role merely to start a remote session.
  private showPrimaryApprovalRequiredDialog(host: RemoteHost): void {
    this.showCustomDialog(
      '请求主设备确认',
      '当前设备不是主设备。确认后会将本次远程控制申请发送到主设备；主设备同意前，电脑端不会收到任何控制请求。',
      '发送申请',
      '取消',
      true,
      () => { this.beginRemoteConnection(host) }
    )
  }

  /**
   * 注册当前设备为主设备（卡片按钮触发）
   */
  private async registerAsPrimaryFromCard(): Promise<void> {
    if (this.primaryRegistering) return
    this.primaryRegistering = true
    try {
      const resp = await DeviceApi.registerAsPrimary()
      this.isPrimary = resp.is_primary
      this.primaryDeviceName = resp.device_name
      promptAction.showToast({ message: '已注册为主设备', duration: 2000 })
    } catch (e) {
      const error = e as Error
      promptAction.showToast({ message: '注册失败: ' + error.message, duration: 3000 })
      console.error('serein remote: registerAsPrimaryFromCard failed: ' + error.message)
    } finally {
      this.primaryRegistering = false
    }
  }

  /**
   * 取消主设备前的二次确认
   */
  private confirmClearPrimary(): void {
    if (this.primaryClearing) return
    this.showCustomDialog(
      '取消主设备',
      '取消后当前设备将无法发起远程桌面请求。确定继续？',
      '确认取消',
      '保留',
      false,
      () => { this.clearPrimaryFromCard() }
    )
  }

  /**
   * 显示自定义深色弹窗（替代系统 promptAction.showDialog）
   * @param title           标题
   * @param message         正文
   * @param confirmText     确认按钮文字
   * @param cancelText      取消按钮文字
   * @param confirmPrimary  确认按钮是否为主色（珊瑚色）；false 则取消按钮为主色
   * @param onConfirm       确认回调
   */
  private showCustomDialog(
    title: string,
    message: string,
    confirmText: string,
    cancelText: string,
    confirmPrimary: boolean,
    onConfirm: () => void
  ): void {
    this.dialogTitle = title
    this.dialogMessage = message
    this.dialogConfirmText = confirmText
    this.dialogCancelText = cancelText
    this.dialogConfirmPrimary = confirmPrimary
    this.dialogCallback = onConfirm
    this.dialogVisible = true
  }

  private dismissDialog(): void {
    this.dialogVisible = false
    this.dialogCallback = null
  }

  private onDialogConfirm(): void {
    const cb = this.dialogCallback
    if (cb !== null) cb()
    // Start the next UI state while the dialog is still covering the page.
    // Otherwise ArkUI renders one normal-page frame after the dialog closes,
    // making the primary-device and PC cards visibly jump before connecting.
    this.dismissDialog()
  }

  /**
   * 取消当前设备的主设备标记
   */
  private async clearPrimaryFromCard(): Promise<void> {
    if (this.primaryClearing) return
    this.primaryClearing = true
    try {
      await DeviceApi.clearPrimary()
      this.isPrimary = false
      promptAction.showToast({ message: '已取消主设备', duration: 2000 })
    } catch (e) {
      const error = e as Error
      promptAction.showToast({ message: '取消失败: ' + error.message, duration: 3000 })
      console.error('serein remote: clearPrimaryFromCard failed: ' + error.message)
    } finally {
      this.primaryClearing = false
    }
  }

  /**
   * 注册当前设备为主设备（申请远程桌面流程内部调用）
   */
  private async registerAsPrimary(): Promise<boolean> {
    try {
      await DeviceApi.registerAsPrimary()
      await this.loadPrimaryStatus()
      return true
    } catch (e) {
      const error = e as Error
      this.errorText = '注册失败: ' + error.message
      console.error('serein remote: registerAsPrimary failed: ' + error.message)
      return false
    }
  }

  /** Begin the visual transition before the dialog can disappear. */
  private beginRemoteConnection(host: RemoteHost): void {
    if (!this.hostCanView(host) || this.actionBusy) return
    this.remoteTransitioning = true
    this.connectionPending = true
    this.actionBusy = true
    this.mediaState = 'waiting'
    this.errorText = ''
    this.requestView(host, true)
  }

  private async requestView(host: RemoteHost, alreadyTransitioning: boolean = false): Promise<void> {
    if (!this.hostCanView(host) || (this.actionBusy && !alreadyTransitioning)) return
    if (!alreadyTransitioning) {
      this.remoteTransitioning = true
      this.connectionPending = true
      this.actionBusy = true
      this.mediaState = 'waiting'
      this.errorText = ''
    }
    try {
      const session = await remoteAuthService.requestViewSession(host.id)
      remoteStore.applySession(session)
      this.applySession(session)
      this.startPolling(session.id)
    } catch (error) {
      this.remoteTransitioning = false
      this.connectionPending = false
      this.errorText = (error as Error).message
    } finally {
      this.actionBusy = false
    }
  }

  private hostCanView(host: RemoteHost): boolean {
    return host.online && host.capabilities.monitors > 0 && host.capabilities.capture.length > 0 &&
      host.capabilities.video_codecs.indexOf('h264') >= 0 && host.capabilities.transports.indexOf('webrtc') >= 0 &&
      host.capabilities.input.indexOf('pointer') >= 0 && host.capabilities.input.indexOf('keyboard') >= 0
  }

  private hostUnavailableReason(host: RemoteHost): string {
    if (!host.online) return '电脑当前离线'
    if (host.capabilities.monitors <= 0 || host.capabilities.capture.length === 0) return '未检测到可用屏幕采集能力'
    if (host.capabilities.video_codecs.indexOf('h264') < 0) return '电脑未验证 H.264 编码能力'
    if (host.capabilities.transports.indexOf('webrtc') < 0) return '原生画面发送模块尚未接入'
    if (host.capabilities.input.indexOf('pointer') < 0 || host.capabilities.input.indexOf('keyboard') < 0) {
      return '电脑未验证触控输入能力'
    }
    return ''
  }

  private startPolling(sessionId: string): void {
    this.stopPolling()
    this.pollTimer = setInterval(async () => {
      try {
        const latest = await remoteAuthService.getSession(sessionId)
        if (remoteStore.applySession(latest)) this.applySession(latest)
        if (isRemoteTerminalState(latest.state)) this.stopPolling()
      } catch (_) {}
    }, 1500)
  }

  private stopPolling(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer)
      this.pollTimer = -1
    }
  }

  private async endCurrentSession(): Promise<void> {
    if (this.currentSession === undefined) return
    this.actionBusy = true
    try {
      await remoteAuthService.endSession(this.currentSession)
    } catch (error) {
      // Even if the API call fails (e.g. already ended), still clear the UI
      console.warn('serein remote: endSession error (clearing UI anyway): ' + (error as Error).message)
    }
    this.stopPolling()
    this.stopReadyRetry()
    this.closeMedia()
    this.currentSession = undefined
    this.readyStatus = ''
    this.actionBusy = false
  }

  /**
   * Periodic retry for client_ready. The first ensureControllerReady call may
   * succeed at the WS level but the message can be silently dropped by the
   * backend (e.g. bridge WS not yet registered, or sendRawToEndpoint finds no
   * client). The phone receives no error in that case, so it must proactively
   * re-send client_ready every 3s until an offer arrives or the session ends.
   *
   * Additionally, when the host's client_ready is received (indicating the
   * bridge has joined signaling), we re-send immediately in handleSignalEvent
   * instead of waiting for this timer — this is the primary fast path.
   * This 3s timer is the fallback for cases where the host client_ready is
   * also dropped or delayed.
   *
   * Each retry fetches a fresh ticket via refreshTicket, so the backend's
   * ConsumeTicket always gets a valid (unconsumed) ticket.
   */
  private startReadyRetry(sessionId: string): void {
    // Guard: if the same session's retry timer is already running, do NOT
    // stop and recreate it. applySession is called every ~1.5s by the poll
    // loop, and without this guard the timer would be reset before the 3s
    // interval ever fires, making retries impossible.
    if (this.readyRetryTimer >= 0 && this.readyRetrySessionId === sessionId) {
      return
    }
    this.stopReadyRetry()
    this.readyRetrySessionId = sessionId
    this.readyRetryTimer = setInterval(() => {
      const current = this.currentSession
      if (current === undefined || current.id !== sessionId ||
        isRemoteTerminalState(current.state)) {
        this.stopReadyRetry()
        return
      }
      // Retry if: still negotiating, no offer received, no send in flight.
      // We reset readyRevision to 0 so ensureControllerReady doesn't skip.
      if ((current.state === 'negotiating' || current.state === 'reconnecting') &&
          !this.offerReceived && this.readyInFlightRevision === 0) {
        console.info('serein remote: readyRetry periodic retry rev=' + current.revision +
          ' readyRev=' + this.readyRevision + ' offerRx=' + this.offerReceived)
        this.readyRevision = 0
        this.ensureControllerReady(current)
      }
    }, 3000)
  }

  private stopReadyRetry(): void {
    if (this.readyRetryTimer >= 0) {
      clearInterval(this.readyRetryTimer)
      this.readyRetryTimer = -1
    }
    this.readyRetrySessionId = ''
  }

  @Builder
  private PrimaryApprovalCard(session: RemoteSession) {
    Column() {
      Row() {
        Column() {
          Text('远程控制申请').fontSize(TYPO.bodySmall.size).fontWeight(WEIGHT.semibold).fontColor('#E1E2E8')
          Text('已配对设备正在申请连接电脑；允许后电脑端才会收到请求。')
            .fontSize(10).fontColor('#8C909F').margin({ top: 4 })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Text('待确认').fontSize(10).fontColor('#D97757')
          .padding({ left: 9, right: 9, top: 4, bottom: 4 })
          .backgroundColor('rgba(217,119,87,0.10)').borderRadius(RADIUS.full)
      }.width('100%')
      Text('请求 ' + session.id.slice(0, 8) + ' · 含触控输入')
        .fontSize(10).fontColor('#686D78').fontFamily('monospace').width('100%').margin({ top: 8 })
      Row() {
        Text(this.primaryDecisionBusy ? '处理中…' : '拒绝')
          .fontSize(TYPO.caption.size).fontColor('#C2C6D6')
          .padding({ left: 18, right: 18, top: 9, bottom: 9 })
          .backgroundColor('rgba(140,144,159,0.08)').borderRadius(RADIUS.full)
          .onClick(() => { this.decidePrimaryRequest(session, false) })
        Blank().layoutWeight(1)
        Text(this.primaryDecisionBusy ? '处理中…' : '允许')
          .fontSize(TYPO.caption.size).fontColor('#1A1C20')
          .padding({ left: 18, right: 18, top: 9, bottom: 9 })
          .backgroundColor('#D97757').borderRadius(RADIUS.full)
          .onClick(() => { this.decidePrimaryRequest(session, true) })
      }.width('100%').margin({ top: SPACE.md })
    }.width('100%').padding(SPACE.md).backgroundColor('rgba(217,119,87,0.05)')
      .border({ width: 1, color: 'rgba(217,119,87,0.20)' }).borderRadius(RADIUS.lg).margin({ bottom: SPACE.md })
  }

  @Builder
  private PrimaryDeviceCard() {
    Column() {
      if (this.primaryLoading) {
        Row() {
          LoadingProgress().width(16).height(16).color('#8C909F')
          Text('正在检查主设备状态…')
            .fontSize(TYPO.bodySmall.size).fontColor('#8C909F').margin({ left: 8 })
        }.width('100%').padding({ top: 14, bottom: 14 })
      } else if (this.isPrimary) {
        Column() {
          Row() {
            Column().width(8).height(8).borderRadius(4).backgroundColor('#17a34a').margin({ left: 4, right: 4 })
            Column() {
              Text('当前设备为主设备')
                .fontSize(TYPO.bodySmall.size).fontColor('#E1E2E8').fontWeight(WEIGHT.semibold)
              if (this.primaryDeviceName.length > 0) {
                Text(this.primaryDeviceName)
                  .fontSize(TYPO.caption.size).fontColor('#8C909F').margin({ top: 2 })
              }
            }.layoutWeight(1).alignItems(HorizontalAlign.Start).margin({ left: 8 })
            Text(this.primaryClearing ? '取消中…' : '取消主设备')
              .fontSize(TYPO.caption.size).fontColor('#8C909F')
              .padding({ left: 14, right: 14, top: 8, bottom: 8 })
              .backgroundColor('rgba(140,144,159,0.06)')
              .borderRadius(RADIUS.full)
              .onClick(() => { this.confirmClearPrimary() })
          }.width('100%')
          Text('取消后当前设备将无法发起远程桌面请求，可随时重新注册。')
            .fontSize(10).fontColor('#686D78').width('100%').margin({ top: 6 })
        }.width('100%').padding({ top: 14, bottom: 14 })
      } else {
        Column() {
          Row() {
            Column().width(8).height(8).borderRadius(4).backgroundColor('#C98D78').margin({ left: 4, right: 4 })
            Text('未注册为主设备')
              .fontSize(TYPO.bodySmall.size).fontColor('#E1E2E8').fontWeight(WEIGHT.semibold)
              .margin({ left: 8 })
          }.width('100%')
          Text('远程桌面是敏感操作，只有主设备才能发起远程请求。点击下方按钮将当前设备注册为主设备（会自动取消其他设备的主设备标记）。')
            .fontSize(TYPO.caption.size).fontColor('#8C909F').margin({ top: 6 }).width('100%')
          Row() {
            Blank()
            Text(this.primaryRegistering ? '注册中…' : '注册为主设备')
              .fontSize(TYPO.caption.size).fontColor('#D97757')
              .padding({ left: 16, right: 16, top: 9, bottom: 9 })
              .backgroundColor('rgba(217,119,87,0.08)')
              .border({ width: 1, color: 'rgba(217,119,87,0.22)' })
              .borderRadius(RADIUS.full)
              .onClick(() => { this.registerAsPrimaryFromCard() })
          }.width('100%').margin({ top: SPACE.sm })
        }.width('100%').padding({ top: 14, bottom: 14 })
      }
    }.width('100%').padding({ left: SPACE.md, right: SPACE.md })
      .backgroundColor('#161B22').border({ width: 1, color: 'rgba(140,144,159,0.14)' })
      .borderRadius(RADIUS.lg).margin({ bottom: SPACE.md })
  }

  @Builder
  private Header() {
    Row() {
      if (this.asTab) {
        Blank().width(36).height(36)
      } else {
        Text('<').fontSize(24).fontColor('#D97757').fontFamily('monospace')
          .width(36).height(36).textAlign(TextAlign.Center)
          .backgroundColor('rgba(217,119,87,0.08)').borderRadius(18)
          .onClick(() => { router.back() })
      }
      Column() {
        Text('远程桌面').fontSize(TYPO.title.size).fontWeight(WEIGHT.bold).fontColor('#E1E2E8')
      }.layoutWeight(1).alignItems(HorizontalAlign.Center)
      Text('↻').fontSize(20).fontColor('#D97757').width(36).height(36).textAlign(TextAlign.Center)
        .onClick(() => { this.loadHosts() })
    }.width('100%').padding({ left: 16, right: 16, top: 44, bottom: 10 })
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
  }

  @Builder
  private HostCard(host: RemoteHost) {
    Column() {
      Row() {
        Column() {
          Text(host.display_name).fontSize(TYPO.bodyLarge.size).fontWeight(WEIGHT.semibold).fontColor('#E1E2E8')
          Text(host.online ? '电脑在线' : '电脑离线').fontSize(TYPO.caption.size)
            .fontColor(host.online ? '#C98D78' : '#8C909F').margin({ top: 3 })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Text(host.capabilities.monitors + ' 屏 · ' + (host.capabilities.video_codecs.indexOf('h264') >= 0 ? 'H.264' : '未报告编码器'))
          .fontSize(10).fontColor('#8C909F')
      }.width('100%')
      Row() {
        Text(this.hostCanView(host) ? '手机可触控操作桌面，点击画面执行点击，拖动移动鼠标' :
          this.hostUnavailableReason(host))
          .fontSize(10).fontColor('#8C909F').layoutWeight(1)
        Text(this.currentSession !== undefined ? '远程中' :
          (this.actionBusy ? '请求中' : (this.hostCanView(host) ? '申请控制' : '暂不可用')))
          .fontSize(TYPO.caption.size)
          .fontColor(this.currentSession !== undefined ? '#8C909F' :
            (this.hostCanView(host) ? '#D97757' : '#686D78'))
          .padding({ left: 14, right: 14, top: 9, bottom: 9 })
          .backgroundColor(this.currentSession !== undefined ? 'rgba(140,144,159,0.06)' :
            (this.hostCanView(host) ? 'rgba(217,119,87,0.08)' : 'rgba(104,109,120,0.06)'))
          .borderRadius(RADIUS.full)
          .onClick(() => {
            if (this.currentSession === undefined) this.confirmRequestView(host)
          })
      }.width('100%').margin({ top: SPACE.md })
    }.width('100%').padding(SPACE.md).backgroundColor('#161B22')
      .border({ width: 1, color: 'rgba(140,144,159,0.14)' }).borderRadius(RADIUS.lg)
      .margin({ bottom: SPACE.md })
  }

  @Builder
  private SessionPanel(session: RemoteSession) {
    Column() {
      Text('当前请求').fontSize(TYPO.caption.size).fontColor('#8C909F').width('100%')
      Text(remoteStateLabel(session.state)).fontSize(TYPO.bodyLarge.size).fontWeight(WEIGHT.semibold)
        .fontColor('#E1E2E8').width('100%').margin({ top: 6 })
      Text('revision ' + session.revision + ' · ' + session.id.slice(0, 8))
        .fontSize(10).fontColor('#8C909F').fontFamily('monospace').width('100%').margin({ top: 4 })
      // Diagnostic: show WS status and controller ready status
      if (!isRemoteTerminalState(session.state)) {
        Text('WS: ' + this.wsStatus + (this.readyStatus.length > 0 ? ' · ' + this.readyStatus : ''))
          .fontSize(10).fontColor('#686D78').fontFamily('monospace').width('100%').margin({ top: 4 })
      }
      // Show "结束请求" button for both active and terminal states.
      // For terminal states, clicking it just clears the card.
      Text('结束请求').fontSize(TYPO.bodySmall.size).fontColor('#C98D78')
        .padding({ left: 18, right: 18, top: 10, bottom: 10 }).margin({ top: SPACE.md })
        .backgroundColor('rgba(201,141,120,0.08)').borderRadius(RADIUS.full)
        .onClick(() => { this.endCurrentSession() })
    }.width('100%').alignItems(HorizontalAlign.Start).padding(SPACE.md)
      .backgroundColor('rgba(217,119,87,0.05)').border({ width: 1, color: 'rgba(217,119,87,0.18)' })
      .borderRadius(RADIUS.lg).margin({ bottom: SPACE.md })
  }

  @Builder
  private MediaPanel(transitionOnly: boolean = false) {
    Column() {
      if (!transitionOnly) {
        Row() {
          Text('远程画面').fontSize(TYPO.caption.size).fontColor('#8C909F').layoutWeight(1)
          Text(this.mediaState === 'playing' || this.mediaState === 'connected' ? '画面+触控' : '连接中')
            .fontSize(10).fontColor('#C98D78')
        }.width('100%').padding({ left: 12, right: 12, top: 10, bottom: 8 })
      }
      Web({ src: $rawfile('remote-view/index.html'), controller: this.mediaController })
        // The Web view shares this column with its small title row. Giving it
        // a fixed 100% height pushes the bottom controls beyond the card.
        // Let it take the remaining height instead, so the Web toolbar stays
        // anchored at the bottom of the remote picture.
        .width('100%').layoutWeight(1)
        .javaScriptAccess(true)
        .domStorageAccess(false)
        .geolocationAccess(false)
        .backgroundColor('#090C10')
        .javaScriptProxy({
          object: this.mediaBridge,
          name: 'sereinRemoteNative',
          methodList: ['postMessage'],
          controller: this.mediaController
        })
    }.width('100%').layoutWeight(1).backgroundColor('#11161C')
      .border({ width: (this.isFullscreen || transitionOnly) ? 0 : 1, color: 'rgba(140,144,159,0.14)' })
      .borderRadius((this.isFullscreen || transitionOnly) ? 0 : RADIUS.lg)
      .clip(true).margin({ bottom: (this.isFullscreen || transitionOnly) ? 0 : SPACE.md })
  }

  build() {
    Stack() {
    AmbientBackdrop()
    Column() {
      if (!this.isFullscreen && !this.remoteTransitioning) {
        this.Header()
      }
      if (this.connectionPending || this.actionBusy || (this.currentSession !== undefined &&
        (this.currentSession.state === 'negotiating' || this.currentSession.state === 'reconnecting' ||
          this.currentSession.state === 'connected_view' || this.currentSession.state === 'connected_control'))) {
        // 紧凑状态条
        if (!this.isFullscreen && !this.remoteTransitioning) {
        Row() {
          Circle({ width: 7, height: 7 }).fill(this.mediaState === 'playing' ? '#17a34a' : '#D97757')
          Text(this.mediaState === 'playing' ? '已连接' : '正在连接…')
            .fontSize(12).fontColor('#C2C6D6').margin({ left: 6 }).layoutWeight(1)
          Text('结束').fontSize(12).fontColor('#D97757')
            .padding({ left: 14, right: 14, top: 7, bottom: 7 })
            .border({ width: 1, color: 'rgba(217,119,87,0.25)', radius: 14 })
            .onClick(() => { this.endCurrentSession() })
        }.width('100%').padding({ left: SPACE.md, right: SPACE.md, top: 4, bottom: 4 })
        }
      }
      if (this.connectionPending || this.actionBusy || (this.currentSession !== undefined &&
        (this.currentSession.state === 'negotiating' || this.currentSession.state === 'reconnecting' ||
          this.currentSession.state === 'connected_view' || this.currentSession.state === 'connected_control'))) {
        this.MediaPanel(this.remoteTransitioning)
      }
		if (this.currentSession !== undefined && !this.connectionPending &&
		  this.currentSession.state !== 'negotiating' && this.currentSession.state !== 'reconnecting' &&
		  this.currentSession.state !== 'connected_view' && this.currentSession.state !== 'connected_control') {
		  this.SessionPanel(this.currentSession)
		}
		if (this.currentSession === undefined && !this.connectionPending && !this.actionBusy &&
		  !this.remoteTransitioning && this.isPrimary && this.primaryPendingRequests.length > 0) {
		  ForEach(this.primaryPendingRequests, (request: RemoteSession) => {
			this.PrimaryApprovalCard(request)
		  }, (request: RemoteSession) => request.id)
		}
      if ((this.currentSession === undefined && !this.actionBusy && !this.connectionPending) ||
        (this.currentSession !== undefined && isRemoteTerminalState(this.currentSession.state))) {
        this.PrimaryDeviceCard()
      }
      if (this.loading) {
        Text('正在读取真实主机状态…').fontSize(TYPO.bodySmall.size).fontColor('#8C909F').margin({ top: 80 })
      } else if (this.errorText.length > 0) {
        Text(this.errorText).fontSize(TYPO.bodySmall.size).fontColor('#C98D78').margin({ top: 60 })
      } else if (this.hosts.length === 0 && this.currentSession === undefined) {
        Text('还没有 Remote Host 上线').fontSize(TYPO.body.size).fontColor('#C2C6D6').margin({ top: 72 })
      } else if (this.currentSession === undefined && !this.connectionPending && !this.actionBusy &&
        !this.remoteTransitioning) {
        ForEach(this.hosts, (host: RemoteHost) => { this.HostCard(host) }, (host: RemoteHost) => host.id)
      }
      if (this.currentSession === undefined && !this.connectionPending && !this.actionBusy &&
        !this.remoteTransitioning) {
        Text('设备能力实验').fontSize(TYPO.caption.size).fontColor('#8C909F').margin({ top: SPACE.md, bottom: SPACE.xl })
          .onClick(() => { router.pushUrl({ url: NavPath.REMOTE_CAPABILITY }) })
      }
    }.width('100%').height('100%').backgroundColor('transparent')

      // A transparent 1 px native IME receiver: no floating text field is
      // shown, but every character, backspace and enter reaches the desktop.
      if (this.remoteKeyboardVisible && this.currentSession !== undefined &&
        !isRemoteTerminalState(this.currentSession.state)) {
        TextInput({ text: this.remoteKeyboardText })
          .id('remote-keyboard-input')
          .width(1).height(1).opacity(0.01)
          .fontSize(1).fontColor('transparent').caretColor('transparent')
          .backgroundColor('transparent').border({ width: 0 })
          .align(Alignment.BottomStart)
          .onChange((value: string) => { this.forwardRemoteKeyboardChange(value) })
          .onSubmit(() => { this.submitRemoteKeyboard() })
      }

      // The Web view may need a moment to create its renderer. Show native
      // feedback from the first request until the first decoded frame arrives.
      if ((this.connectionPending || this.actionBusy || (this.currentSession !== undefined &&
        (this.currentSession.state === 'negotiating' || this.currentSession.state === 'reconnecting' ||
          this.currentSession.state === 'connected_view' || this.currentSession.state === 'connected_control'))) &&
        this.mediaState !== 'playing') {
        Column() {
          LoadingProgress().width(34).height(34).color('#D97757')
          Text('正在建立安全连接…').fontSize(13).fontColor('#C2C6D6').margin({ top: 12 })
          Text('正在等待电脑画面').fontSize(11).fontColor('#8C909F').margin({ top: 4 })
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
        .backgroundColor('rgba(11,14,18,0.52)')
      }

      // 自定义深色弹窗（替代系统 promptAction.showDialog）
      if (this.dialogVisible) {
        Stack() {
          Column() {
            Text(this.dialogTitle)
              .fontSize(18).fontWeight(700).fontColor('#E1E2E8').margin({ bottom: 16 })

            Text(this.dialogMessage)
              .fontSize(14).fontColor('#C2C6D6').lineHeight(22).width('100%')

            Row() {
              Button(this.dialogCancelText)
                .fontSize(15).height(44).layoutWeight(1)
                .fontColor(this.dialogConfirmPrimary ? '#C2C6D6' : '#1A1C20')
                .backgroundColor(this.dialogConfirmPrimary ? 'rgba(39,42,47,0.60)' : '#D97757')
                .border({ width: 1, color: 'rgba(140,144,159,0.15)' }).borderRadius(8)
                .onClick(() => { this.dismissDialog() })

              Button(this.dialogConfirmText)
                .fontSize(15).height(44).layoutWeight(1).margin({ left: 12 })
                .fontColor(this.dialogConfirmPrimary ? '#1A1C20' : '#C2C6D6')
                .backgroundColor(this.dialogConfirmPrimary ? '#D97757' : 'rgba(39,42,47,0.60)')
                .border({ width: 1, color: this.dialogConfirmPrimary ? 'rgba(217,119,87,0.30)' : 'rgba(140,144,159,0.15)' })
                .borderRadius(8)
                .onClick(() => { this.onDialogConfirm() })
            }.width('100%').margin({ top: 24 })
          }
          .width('82%').padding(24)
          .backgroundColor('rgba(39,42,47,0.92)').backdropBlur(32)
          .border({ width: 1, color: 'rgba(140,144,159,0.15)' }).borderRadius(12)
        }
        .width('100%').height('100%')
        .backgroundColor('rgba(0,0,0,0.65)')
      }
    }
    .width('100%').height('100%')
  }
}

@Entry
@Component
struct RemoteDesktopPage {
  build() {
    Stack() {
      RemoteDesktopContent()
    }
    .width('100%').height('100%')
  }
}
