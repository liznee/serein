import { UIAbility, Want, AbilityConstant, wantAgent, WantAgent } from '@kit.AbilityKit'
import { window, KeyboardAvoidMode, display } from '@kit.ArkUI'
import { backgroundTaskManager } from '@kit.BackgroundTasksKit'
import { notificationManager } from '@kit.NotificationKit'
import PrefStore from '../store/PrefStore'
import CollaborationStore from '../store/CollaborationStore'
import CollaborationCredentialStore from '../store/CollaborationCredentialStore'
import { bootstrap, KEY_BACKEND_URL } from '../state/AppStore'
import ApprovalPushService from '../service/ApprovalPushService'
import PushKitService from '../service/PushKitService'
import { setScreenWidthVp } from '../terminal/TerminalTheme'
import { FEATURE_COLLABORATION_CENTER } from '../config/ProductFeatures'

export default class EntryAbility extends UIAbility {
  private longRunningActive: boolean = false

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    PrefStore.init(this.context)
    if (FEATURE_COLLABORATION_CENTER) {
      CollaborationStore.init(this.context)
      CollaborationCredentialStore.init(this.context)
    }
    // 启动时读一次屏幕宽度并缓存（等效于设备字典查表，后续不再调用 API）
    try {
      const d = display.getDefaultDisplaySync()
      // d.width 是 px，转成 vp
      const widthVp = d.width / d.densityPixels
      setScreenWidthVp(widthVp)
      console.info('serein: screen width cached = ' + widthVp + 'vp (px=' + d.width + ', density=' + d.densityPixels + ')')
    } catch (e) {
      console.warn('serein: failed to read screen width, using default 360vp: ' + (e as Error).message)
    }
    this.handleWantParams(want)
  }

  /** App 已在后台运行时点击通知走 onNewWant，而非 onCreate */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.handleWantParams(want)
  }

  /** 解析通知携带的跳转参数 */
  private handleWantParams(want: Want): void {
    try {
      const action = want?.action ?? ''
      if (action === 'ohos.want.action.sendData') {
        this.handleShareText(want)
        return
      }
      const navTo = want?.parameters?.['navigateTo'] as string | undefined
      if (navTo === 'monitoring_alerts') {
        AppStorage.setOrCreate('monitoringAlertLaunch', true)
        setTimeout(() => { AppStorage.setOrCreate('triggerNotificationJump', true) }, 300)
        return
      }
      if (navTo === 'projects') {
        AppStorage.setOrCreate('notificationLaunch', true)
        const notifProject = want?.parameters?.['project'] as string | undefined
        if (notifProject !== undefined && notifProject !== '') {
          AppStorage.setOrCreate('notificationProject', notifProject)
        }
        setTimeout(() => {
          AppStorage.setOrCreate('triggerNotificationJump', true)
        }, 300)
      }
    } catch (e) {
      console.error('serein: handleWantParams failed: ' + (e as Error).message)
    }
  }

  /** 处理分享文本：从其他 App 选中的文字 → 自动填入终端并发送 */
  private handleShareText(want: Want): void {
    try {
      let text = ''
      const candidates: string[] = [
        'shareText', 'text', 'content', 'ability.params.stream', 'share_message'
      ]
      for (let i = 0; i < candidates.length; i++) {
        const v = want?.parameters?.[candidates[i]]
        if (typeof v === 'string' && v.trim().length > 0) {
          text = v.trim()
          break
        }
      }
      // 如果参数中未找到，尝试 URI（data:text/plain,... 格式）
      if (text === '') {
        const uri = want?.uri ?? ''
        if (uri.startsWith('data:text/plain,')) {
          text = decodeURIComponent(uri.substring('data:text/plain,'.length)).trim()
        }
      }
      if (text !== '') {
        console.info('serein share: received text len=' + text.length)
        AppStorage.setOrCreate('sharedCommandText', text)
        AppStorage.setOrCreate('switchToTerminal', true)
      }
    } catch (e) {
      console.error('serein: handleShareText failed: ' + (e as Error).message)
    }
  }

  onDestroy(): void {
    this.stopLongRunningTask()
    ApprovalPushService.stop()
    PushKitService.stop()
  }

  async onWindowStageCreate(windowStage: window.WindowStage): Promise<void> {
    // 沉浸全屏 + 键盘避让
    try {
      const win = windowStage.getMainWindowSync()
      win.setWindowLayoutFullScreen(true)
      win.setWindowSystemBarProperties({
        statusBarColor: '#0B0E12',
        navigationBarColor: '#0B0E12',
        statusBarContentColor: '#E1E2E8',
        navigationBarContentColor: '#E1E2E8'
      })
      win.setWindowBackgroundColor('#0B0E12')
      // 沉浸全屏模式下手动 padding/expandSafeArea 均不生效（窗口高度不变），
      // 改用系统级键盘避让模式 OFFSET：键盘弹起时由系统自动平移 UIContext，
      // 把底部输入栏顶到键盘上方。之前 9 次失败均未用此 API。
      try {
        win.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.OFFSET)
        console.info('serein: keyboard avoid mode set to OFFSET')
      } catch (ke) {
        console.error('serein: setKeyboardAvoidMode OFFSET failed: ' + (ke as Error).message)
      }
    } catch (e) { console.error('set immersive dark failed: ' + (e as Error).message) }
    // 立即加载 SplashPage，消除 startWindow 与 SplashPage 之间的黑屏阶段。
    // 之前 await bootstrap() 阻塞了 loadContent，导致用户看到纯黑 startWindow
    // 直到 bootstrap（Preferences 读取）完成。现在先加载 SplashPage 让动画
    // 立即开始播放，bootstrap 在后台并行执行。
    windowStage.loadContent('pages/SplashPage', (err) => {
      if (err.code !== 0) console.error('load splash page failed: code=' + err.code)
    })
    try { await bootstrap() } catch (e) {
      console.error('bootstrap failed: ' + (e as Error).message)
    }
    PushKitService.start(this).catch((error: Object) => {
      console.warn('push kit startup failed')
    })
    try {
      const backendUrl = AppStorage.get<string>(KEY_BACKEND_URL)
      if (backendUrl !== undefined && backendUrl !== '') {
        // 先尝试从 AppStorage 读取用户配置的 ntfy 地址（可在设置页配置）
        let ntfyBase = AppStorage.get<string>('ntfyBaseUrl') ?? ''
        if (ntfyBase === '') {
          // 从后端 URL 推导 ntfy 地址：替换最左子域为 ntfy
          // 如 your-backend.example → your-ntfy.example
          // 如 api.custom-server.com → ntfy.custom-server.com（需实际存在 ntfy 服务）
          // 如 a.b.c.d.com → ntfy.b.c.d.com（原 slice(-2) 产生 ntfy.d.com，多级子域名错误）
          const m = backendUrl.match(/^https?:\/\/([^/:]+)/)
          if (m !== null && m.length > 1) {
            const host = m[1]
            // 检测 IP 地址（IPv4），跳过域级推导避免产生 ntfy.0.1 等无效域名
            const isIp = /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(host)
            if (!isIp) {
              const parts = host.split('.')
              if (parts.length >= 2) {
                // 替换最左子域为 ntfy：适用于任意级子域名
                parts[0] = 'ntfy'
                ntfyBase = 'https://' + parts.join('.')
              }
            }
          }
        }
        if (ntfyBase === '') ntfyBase = 'https://your-ntfy.example'
        console.info('serein push: ntfyBase=' + ntfyBase)
        ApprovalPushService.start(ntfyBase, 'serein-approvals')
      }
    } catch (e) {
      console.error('push service init failed: ' + (e as Error).message)
    }
    // 先请求通知权限，再启动长时任务（权限未授权时 startBackgroundRunning 会失败）
    this.startLongRunningTask()
  }

  onWindowStageDestroy(): void {}

  onForeground(): void {
    ApprovalPushService.onForeground()
    // 触发 PIN 重新验证（MainTabs 的 checkPin 会检查 AppStorage 标志）
    AppStorage.setOrCreate('appForegrounded', true)
    // 如果长时任务启动失败过，前台时重试
    if (!this.longRunningActive) {
      this.startLongRunningTask()
    }
  }

  onBackground(): void {
    ApprovalPushService.onBackground()
    // 切换到快速轮询（10s），确保 ntfy WS 断开时仍能收到审批通知
    ApprovalPushService.resumeFastPoll()
    // 记录进入后台的时间戳，供 MainTabs 判断是否需要重新验证 PIN
    AppStorage.setOrCreate('lastBackgroundTime', Date.now())
    // 后台长时任务未激活时重试（系统可能已销毁之前的后台任务）
    if (!this.longRunningActive) {
      this.startLongRunningTask()
    }
  }

  // ── 长时任务 — 系统 DATA_TRANSFER 通知默认静默，不额外发声音 ──

  private async startLongRunningTask(): Promise<void> {
    if (this.longRunningActive) {
      return
    }
    try {
      // 先确保通知权限已授权，否则 startBackgroundRunning 会报 9800006
      try {
        // 新版 API 必须绑定已加载 UI 的 AbilityContext。旧的无 Context 重载在
        // HarmonyOS 5/6 上可能不展示授权框，导致后台通知始终被系统静默丢弃。
        await notificationManager.requestEnableNotification(this.context)
        console.info('serein: notification permission granted')
      } catch (ne) {
        console.warn('serein: notification permission denied: ' + (ne as Error).message)
      }
      const agent = await this.buildLaunchAgent()
      await backgroundTaskManager.startBackgroundRunning(
        this.context,
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER,
        agent
      )
      this.longRunningActive = true
      console.info('serein: long-running task active, all lifecycle')
    } catch (e) {
      const err = e as Record<string, Object>
      console.error('serein: startBackgroundRunning failed: code=' + err['code'] + ' msg=' + err['message'])
    }
  }

  private async stopLongRunningTask(): Promise<void> {
    if (!this.longRunningActive) {
      return
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.context)
      this.longRunningActive = false
    } catch (e) {
      console.warn('serein: stopBackgroundRunning failed: ' + (e as Error).message)
    }
  }

  /** 点击常驻通知 → 跳转项目列表页 */
  private async buildLaunchAgent(): Promise<WantAgent> {
    const info: wantAgent.WantAgentInfo = {
      wants: [{
        bundleName: 'com.serein.client',
        abilityName: 'EntryAbility',
        parameters: { 'navigateTo': 'projects' }
      }],
      operationType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    }
    return await wantAgent.getWantAgent(info)
  }
}
