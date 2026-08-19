import { router, promptAction } from '@kit.ArkUI'
import { http } from '@kit.NetworkKit'
import { fileIo } from '@kit.CoreFileKit'
import { pasteboard } from '@kit.BasicServicesKit'
import PrefStore from '../store/PrefStore'
import NavPath from '../model/NavPath'
import { hashPin } from '../service/PinGuard'
import { COLOR, TYPO, SPACE, TOUCH, RADIUS, ICON, HEADER_HEIGHT, WEIGHT, SURFACE } from '../utils/DesignTokens'
import { Icons } from '../utils/Icons'
import { APP_VERSION } from '../utils/AppVersion'
import { ActionIcon, ActionIconType } from '../components/ActionIcon'
import { WebSocketClient } from '../api/WebSocketClient'
import type { PermissionMode } from '../api/ws_types'
import { PERM_DEFAULT, PERM_ACCEPT_EDITS, PERM_SAFE_YOLO, PERM_YOLO, PERM_PLAN, PERM_READ_ONLY, PERM_BYPASS_PERMISSIONS } from '../api/ws_types'
import CollaborationStore from '../store/CollaborationStore'
import CollaborationSyncService from '../collaboration/CollaborationSyncService'
import DeviceApi from '../api/DeviceApi'
import { FEATURE_COLLABORATION_CENTER } from '../config/ProductFeatures'

/**
 * 设置页 — HarmonyOS 风格分区分卡片布局
 */
@Component
export struct SettingsContent {
  @State backendUrl: string = ''
  @State deviceName: string = ''
  @State deviceId: string = ''
  @State clientToken: string = ''
  @State editUrl: string = ''
  @State testing: boolean = false
  @State testResult: string = ''
  @State testOk: boolean = false
  @State showUnpairConfirm: boolean = false
  @State deploying: boolean = false
  @State updateMsg: string = ''
  @State updateOk: boolean = false
  @State serverVersion: string = ''
  @State pinEnabled: boolean = false
  @State showPinSetupDialog: boolean = false
  @State pinSetupInput: string = ''
  @State pinSetupConfirm: string = ''
  @State pinSetupError: string = ''
  @State permissionMode: PermissionMode = PERM_DEFAULT
  @State usageLoading: boolean = true
  @State diagnosticBackendOk: boolean = false
  @State diagnosticAgentOk: boolean = false
  @State diagnosticRunningCount: number = 0
  @State diagnosticSystemAvailable: boolean = false
  @State diagnosticCpu: number = 0
  @State diagnosticMemory: number = 0
  @State diagnosticDisk: number = 0
  @State collaborationAccountCount: number = 0
  @State collaborationRepositoryCount: number = 0
  @State collaborationAuditCount: number = 0
  @State collaborationClearing: boolean = false
  @State showEmergencyBrakeConfirm: boolean = false
  @State emergencyBrakeSending: boolean = false

  aboutToAppear(): void {
    this.loadFromStorage()
    this.fetchServerVersion()
    this.loadPinPref()
    this.loadUsageDiagnostics()
    if (FEATURE_COLLABORATION_CENTER) this.loadCollaborationSummary()
    // 清理沙箱旧 HAP
    try { fileIo.unlink(getContext().cacheDir + '/serein.hap') } catch (e) {}
  }

  private diagnosticHeaders(): Record<string, string> {
    const headers: Record<string, string> = {}
    if (this.clientToken !== '') headers['Authorization'] = 'Bearer ' + this.clientToken
    return headers
  }

  /** 只加载后端能够直接证明的数据，不推算额度、成本或上下文占比。 */
  async loadUsageDiagnostics(): Promise<void> {
    this.usageLoading = true
    this.diagnosticBackendOk = false
    this.diagnosticAgentOk = false
    this.diagnosticRunningCount = 0
    this.diagnosticSystemAvailable = false

    if (this.backendUrl === '') {
      this.usageLoading = false
      return
    }

    const health = http.createHttp()
    try {
      const response = await health.request(this.backendUrl + '/healthz', {
        method: http.RequestMethod.GET, connectTimeout: 4000, readTimeout: 4000
      })
      this.diagnosticBackendOk = response.responseCode === 200
    } catch (e) {
      this.diagnosticBackendOk = false
    } finally {
      health.destroy()
    }

    if (this.diagnosticBackendOk) {
      const status = http.createHttp()
      try {
        const response = await status.request(this.backendUrl + '/agent/status', {
          method: http.RequestMethod.GET, header: this.diagnosticHeaders(),
          connectTimeout: 5000, readTimeout: 5000
        })
        if (response.responseCode === 200) {
          const data = JSON.parse(response.result as string) as Record<string, Object>
          this.diagnosticAgentOk = (data['running'] as boolean) ?? false
          const output = data['output'] as Record<string, Object> | undefined
          const running = output ? (output['running'] as Object[] ?? []) : []
          this.diagnosticRunningCount = running.length
        }
      } catch (e) {
        this.diagnosticAgentOk = false
      } finally {
        status.destroy()
      }

      const sysinfo = http.createHttp()
      try {
        const response = await sysinfo.request(this.backendUrl + '/agent/sysinfo', {
          method: http.RequestMethod.GET, header: this.diagnosticHeaders(),
          connectTimeout: 5000, readTimeout: 5000
        })
        if (response.responseCode === 200) {
          const data = JSON.parse(response.result as string) as Record<string, Object>
          const timestamp = (data['_timestamp'] as number) ?? 0
          if (timestamp > 0) {
            const memory = data['memory'] as Record<string, Object> | undefined
            const disk = data['disk'] as Record<string, Object> | undefined
            this.diagnosticCpu = (data['cpu'] as number) ?? 0
            this.diagnosticMemory = memory ? ((memory['percent'] as number) ?? 0) : 0
            this.diagnosticDisk = disk ? ((disk['percent'] as number) ?? 0) : 0
            this.diagnosticSystemAvailable = true
          }
        }
      } catch (e) {
        this.diagnosticSystemAvailable = false
      } finally {
        sysinfo.destroy()
      }
    }

    this.usageLoading = false
  }

  async loadPinPref(): Promise<void> {
    this.pinEnabled = await PrefStore.loadPinEnabled()
    const modeStr = await PrefStore.loadPermissionMode()
    this.permissionMode = (modeStr ?? PERM_DEFAULT) as PermissionMode
  }

  async handlePermissionModeChange(mode: PermissionMode): Promise<void> {
    this.permissionMode = mode
    await PrefStore.savePermissionMode(mode)

    // 发送 mode_switch 消息到 WS
    const wsClient = AppStorage.get<WebSocketClient>('wsClient')
    if (wsClient && wsClient.connected) {
      const sent = wsClient.sendModeSwitch(mode)
      if (sent) {
        promptAction.showToast({ message: '权限模式已切换', duration: 2000 })
      }
    }
  }

  private getModeLabel(mode: PermissionMode): string {
    switch (mode) {
      case PERM_DEFAULT: return '默认'
      case PERM_ACCEPT_EDITS: return '接受编辑'
      case PERM_SAFE_YOLO: return '安全自动'
      case PERM_YOLO: return '完全自动'
      case PERM_PLAN: return '仅计划'
      case PERM_READ_ONLY: return '只读'
      case PERM_BYPASS_PERMISSIONS: return '绕过权限'
      default: return mode
    }
  }

  private getModeDesc(mode: PermissionMode): string {
    switch (mode) {
      case PERM_DEFAULT: return '绿色自动批准，黄色/红色需审批'
      case PERM_ACCEPT_EDITS: return '绿色/黄色自动批准，红色需审批'
      case PERM_SAFE_YOLO: return '绿色/黄色自动批准，红色自动拒绝'
      case PERM_YOLO: return '所有命令自动批准'
      case PERM_PLAN: return '只读操作自动，写操作自动拒绝'
      case PERM_READ_ONLY: return '只读操作自动，写操作自动拒绝'
      case PERM_BYPASS_PERMISSIONS: return '所有命令自动批准'
      default: return ''
    }
  }

  private getModeColor(mode: PermissionMode): Resource {
    switch (mode) {
      case PERM_DEFAULT: return COLOR.textSecondary
      case PERM_ACCEPT_EDITS: return COLOR.warning
      case PERM_SAFE_YOLO: return COLOR.primary
      case PERM_YOLO: return COLOR.danger
      case PERM_PLAN: return COLOR.textSecondary
      case PERM_READ_ONLY: return COLOR.textSecondary
      case PERM_BYPASS_PERMISSIONS: return COLOR.danger
      default: return COLOR.textSecondary
    }
  }

  async handlePinToggle(enabled: boolean): Promise<void> {
    // 不立即设置 pinEnabled，等待 PIN 输入弹窗确认后才设置。
    // 防止用户通过系统返回手势关闭弹窗后 pinEnabled 残留 true 但 PIN 未设置。
    if (enabled) {
      this.showPinSetupDialog = true
      this.pinSetupInput = ''
      this.pinSetupConfirm = ''
      this.pinSetupError = ''
    } else {
      await PrefStore.savePinEnabled(false)
      promptAction.showToast({ message: 'PIN 保护已关闭', duration: 2000 })
    }
  }

  /** Stops every configured local Agent relay. Deliberately reachable only from Settings. */
  async handleEmergencyBrake(): Promise<void> {
    if (this.emergencyBrakeSending) return
    this.emergencyBrakeSending = true
    let successCount = 0
    try {
      const snapshot = await PrefStore.loadAll()
      const urls: string[] = []
      const addUrl = (url: string): void => {
        const normalized = url.trim().replace(/\/$/, '')
        if (normalized !== '' && urls.indexOf(normalized) < 0) urls.push(normalized)
      }
      addUrl(snapshot.backendUrl)
      for (let i = 0; i < snapshot.projects.length; i++) addUrl(snapshot.projects[i].backendUrl)
      if (urls.length === 0) {
        promptAction.showToast({ message: '没有可停止的本机 Agent', duration: 1800 })
        return
      }
      for (let i = 0; i < urls.length; i++) {
        const request = http.createHttp()
        try {
          const response = await request.request(urls[i] + '/agent/cmd?async=true', {
            method: http.RequestMethod.POST,
            header: this.diagnosticHeaders(),
            extraData: JSON.stringify({ action: 'kill-all' }),
            connectTimeout: 5000,
            readTimeout: 10000,
          })
          if (response.responseCode >= 200 && response.responseCode < 300) successCount++
        } catch (e) {
          // Try every configured backend before reporting the aggregated result.
        } finally {
          request.destroy()
        }
      }
      promptAction.showToast({
        message: successCount > 0 ? '已停止 ' + successCount + ' 个本机 Agent 服务' : '停止请求未送达，请检查连接',
        duration: 2500,
      })
    } catch (e) {
      promptAction.showToast({ message: '停止失败，请重试', duration: 1800 })
    } finally {
      this.emergencyBrakeSending = false
      this.showEmergencyBrakeConfirm = false
    }
  }

  async fetchServerVersion(): Promise<void> {
    const httpRequest = http.createHttp()
    try {
      const resp = await httpRequest.request(this.backendUrl + '/version', {
        method: http.RequestMethod.GET, connectTimeout: 3000, readTimeout: 3000
      })
      const data = JSON.parse(resp.result as string) as Record<string, Object>
      const rawVer = (data['version'] as string) ?? ''
      this.serverVersion = rawVer !== '' ? 'v' + rawVer : ''
    } catch (e) {
      this.serverVersion = ''
    } finally {
      httpRequest.destroy()
    }
  }

  private loadFromStorage(): void {
    const url = AppStorage.get<string>('backendUrl')
    const dname = AppStorage.get<string>('deviceName')
    const did = AppStorage.get<string>('deviceId')
    const token = AppStorage.get<string>('clientToken')
    this.backendUrl = (url !== undefined && url !== null) ? url : ''
    this.deviceName = (dname !== undefined && dname !== null) ? dname : ''
    this.deviceId = (did !== undefined && did !== null) ? did : ''
    this.clientToken = (token !== undefined && token !== null) ? token : ''
    this.editUrl = this.backendUrl
  }

  @Builder modeOption(mode: PermissionMode) {
    Column() {
      Text(this.getModeLabel(mode))
        .fontSize(11).fontColor(this.permissionMode === mode ? '#0B0E12' : '#E1E2E8')
        .fontWeight(this.permissionMode === mode ? 600 : 400)
    }
    .width('48%')
    .padding({ top: 10, bottom: 10 })
    .backgroundColor(this.permissionMode === mode ? '#D97757' : 'rgba(140,144,159,0.08)')
    .borderRadius(8)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => { this.handlePermissionModeChange(mode) })
  }

  async handleSaveUrl(): Promise<void> {
    const url = this.editUrl.trim()
    if (url === '') {
      this.testResult = '地址不能为空'
      this.testOk = false
      return
    }
    AppStorage.setOrCreate('backendUrl', url)
    await PrefStore.saveBackendUrl(url)
    const snapshot = await PrefStore.loadAll()
    for (let i = 0; i < snapshot.projects.length; i++) {
      snapshot.projects[i].backendUrl = url
    }
    await PrefStore.saveProjects(snapshot.projects)
    this.backendUrl = url
    this.testResult = Icons.CHECK + ' 已保存'
    this.testOk = true
    this.fetchServerVersion()
  }

  async handleTestConnection(): Promise<void> {
    this.testing = true
    this.testResult = ''
    const baseUrl = this.editUrl.trim()
    if (baseUrl === '') {
      this.testResult = '请先输入后端地址'
      this.testOk = false
      this.testing = false
      return
    }
    const httpRequest = http.createHttp()
    try {
      const resp = await httpRequest.request(baseUrl + '/healthz', {
        method: http.RequestMethod.GET,
        connectTimeout: 5000,
        readTimeout: 5000
      })
      if (resp.responseCode === 200) {
        this.testResult = Icons.CHECK + ' 连接成功'
        this.testOk = true
      } else {
        this.testResult = '服务返回 ' + resp.responseCode
        this.testOk = false
      }
    } catch (e) {
      this.testResult = '连接失败，请检查地址和网络'
      this.testOk = false
    } finally {
      httpRequest.destroy()
      this.testing = false
    }
  }

  async handleUnpair(): Promise<void> {
	try {
	  // Local data must remain intact if the server cannot revoke the paired
	  // device; otherwise no other phone could be paired afterwards.
	  await DeviceApi.unpairCurrent()
	  await PrefStore.clearToken()
	  AppStorage.setOrCreate('clientToken', '')
	  AppStorage.setOrCreate('deviceId', '')
	  AppStorage.setOrCreate('deviceName', '')
	  router.replaceUrl({ url: NavPath.PAIR })
	} catch (error) {
	  promptAction.showToast({ message: '解除失败，请确认网络后重试', duration: 2500 })
	}
  }

  private isBackendHttp(): boolean {
    return this.backendUrl !== '' && !this.backendUrl.startsWith('https://')
  }

  async handleCheckUpdate(): Promise<void> {
    if (this.isBackendHttp()) {
      this.updateMsg = '[安全] HTTP 模式下不允许检查更新，请在设置中配置 HTTPS 后端地址'
      this.updateOk = false
      return
    }
    const httpRequest = http.createHttp()
    try {
      const resp = await httpRequest.request(this.backendUrl + '/admin/check-update', {
        method: http.RequestMethod.GET, connectTimeout: 5000, readTimeout: 5000,
        header: { 'Authorization': 'Bearer ' + this.clientToken }
      })
      const data = JSON.parse(resp.result as string) as Record<string, Object>
      if (data['update_available'] === true) {
        this.updateMsg = '有新版本可部署'
        this.updateOk = true
      } else {
        this.updateMsg = '已是最新版本'
        this.updateOk = false
      }
    } catch (e) {
      this.updateMsg = '检查失败'
      this.updateOk = false
    } finally {
      httpRequest.destroy()
    }
  }

  async handleDeploy(): Promise<void> {
    if (this.isBackendHttp()) {
      this.updateMsg = '[安全] HTTP 模式下不允许部署，请在设置中配置 HTTPS 后端地址'
      this.updateOk = false
      return
    }
    this.deploying = true
    this.updateMsg = '正在部署…'
    this.updateOk = false
    const httpRequest = http.createHttp()
    try {
      const resp = await httpRequest.request(this.backendUrl + '/admin/deploy', {
        method: http.RequestMethod.POST, connectTimeout: 10000, readTimeout: 10000,
        header: {
          'Authorization': 'Bearer ' + this.clientToken,
          'X-Deploy-Token': this.clientToken,
        }
      })
      if (resp.responseCode !== 200) {
        this.updateMsg = '部署请求失败'
        this.updateOk = false
        this.deploying = false
        return
      }
      const data = JSON.parse(resp.result as string) as Record<string, Object>

      if (data['ok'] !== true) {
        this.updateMsg = '部署请求失败'
        this.updateOk = false
        this.deploying = false
        return
      }

      this.updateMsg = '服务器重启中，正在验证…'
      const oldVersion = this.serverVersion
      for (let i = 0; i < 10; i++) {
        await this.sleep(2000)
        let checkReq: http.HttpRequest | null = null
        try {
          checkReq = http.createHttp()
          const checkResp = await checkReq.request(this.backendUrl + '/version', {
            method: http.RequestMethod.GET, connectTimeout: 3000, readTimeout: 3000
          })
          const verData = JSON.parse(checkResp.result as string) as Record<string, Object>
          const newVer = (verData['version'] as string) ?? ''
          if (newVer !== '' && newVer !== oldVersion) {
            this.serverVersion = newVer
            this.updateMsg = '部署成功 ' + newVer
            this.updateOk = true
            this.deploying = false
            return
          }
        } catch (e) {
          // 服务器还没起来，继续等
        } finally {
          if (checkReq !== null) { checkReq.destroy() }
        }
      }
      try {
        await this.fetchServerVersion()
        if (this.serverVersion !== oldVersion) {
          this.updateMsg = '部署成功 ' + this.serverVersion
          this.updateOk = true
        } else {
          this.updateMsg = '部署已完成，请稍后刷新'
          this.updateOk = true
        }
      } catch (e) {
        this.updateMsg = '部署已完成，请稍后刷新'
        this.updateOk = true
      }
    } catch (e) {
      this.updateMsg = '部署请求失败，请重试'
      this.updateOk = false
    } finally {
      httpRequest.destroy()
      this.deploying = false
    }
  }

  private sleep(ms: number): Promise<void> {
    return new Promise((resolve: () => void) => setTimeout(resolve, ms))
  }

  private async loadCollaborationSummary(): Promise<void> {
    try {
      const state = await CollaborationStore.load()
      this.collaborationAccountCount = state.accounts.length
      this.collaborationRepositoryCount = state.repositories.length
      this.collaborationAuditCount = state.writebackAudits.length
    } catch (_) {
      this.collaborationAccountCount = 0
      this.collaborationRepositoryCount = 0
      this.collaborationAuditCount = 0
    }
  }

  private clearCollaborationData(): void {
    if (this.collaborationClearing) return
    promptAction.showDialog({
      title: '清除全部协作数据',
      message: '将从本机删除 GitHub/Gitee Token、仓库与 Issue 缓存、绑定、Agent 处理记录、Stars 快照和写回审计。远程平台上的评论、PR/MR 或 Issue 状态不会被撤销。',
      buttons: [{ text: '取消', color: '#8C909F' }, { text: '确认清除', color: '#C89A89' }],
    }).then(async (result) => {
      if (result.index !== 1) return
      this.collaborationClearing = true
      try {
        await CollaborationSyncService.clearAllData()
        await this.loadCollaborationSummary()
        promptAction.showToast({ message: '协作凭证和本地缓存已清除', duration: 2000 })
      } catch (e) {
        promptAction.showToast({ message: '清除失败：' + (e as Error).message, duration: 2400 })
      } finally {
        this.collaborationClearing = false
      }
    }).catch(() => {})
  }

  build() {
    Column() {
      // == Header ==
      Row() {
        Blank()
        Text('Settings').fontSize(22).fontWeight(700).fontColor('#D97757').fontFamily('monospace')
        Blank()
        Row().width(36)
      }
      .width('100%').padding({left:16,right:16,top:44,bottom:12})
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])

      // == 内容区 ==
      Scroll() {
        Column() {

          // -- 服务器卡片 --
          Text('服务器连接')
            .fontSize(TYPO.caption.size)
            .fontColor('#C2C6D6')
            .fontWeight(WEIGHT.medium)
            .alignSelf(ItemAlign.Start)
            .margin({ top: SPACE.lg, bottom: SPACE.sm, left: SPACE.xs })

          Column() {
            TextInput({ text: this.editUrl, placeholder: 'https://your-server.example' })
              .fontSize(15).height(48).width('100%')
              .backgroundColor('#0B0E12').border({width:1,color:'rgba(140,144,159,0.20)'}).borderRadius(6)
              .fontColor('#E1E2E8').placeholderColor('#475569')
              .onChange((value: string) => { this.editUrl = value })

            Row() {
              Button(this.testing ? '测试中…' : '测试连接')
                .fontSize(TYPO.bodySmall.size)
                .fontColor(COLOR.primary)
                .backgroundColor(Color.Transparent)
                .onClick(() => { this.handleTestConnection() })
                .enabled(!this.testing)

              if (this.testResult !== '') {
                Text(this.testResult)
                  .fontSize(TYPO.caption.size)
                  .fontColor(this.testOk ? COLOR.success : COLOR.danger)
                  .margin({ left: 12 })
              }

              Blank()

              Button('保存')
                .fontSize(13).height(36).padding({ left: 20, right: 20 })
                .fontColor('#1A1C20').backgroundColor('#D97757').borderRadius(6)
                .onClick(() => { this.handleSaveUrl() })
            }
            .width('100%').margin({ top: 12 }).alignItems(VerticalAlign.Center)
          }
          .width('100%')
          .padding(SPACE.lg)
          .backgroundColor('#161B22').border({width:1,color:'rgba(140,144,159,0.12)'})
          .borderRadius(RADIUS.lg)

          // -- 设备卡片 --
          Text('设备信息')
            .fontSize(TYPO.caption.size)
            .fontColor('#C2C6D6')
            .fontWeight(WEIGHT.medium)
            .alignSelf(ItemAlign.Start)
            .margin({ top: SPACE.xl, bottom: SPACE.sm, left: SPACE.xs })

          Column() {
            this.infoLine('设备名', this.deviceName)
            Divider().color(COLOR.divider).margin({ left: SPACE.lg })
            this.infoLine('设备 ID', this.deviceId)
            Divider().color(COLOR.divider).margin({ left: SPACE.lg })
            this.infoLine('Token', this.clientToken)
          }
          .width('100%')
          .padding({ left: SPACE.lg, right: SPACE.lg, top: SPACE.xs, bottom: SPACE.xs })
          .backgroundColor('#161B22').border({width:1,color:'rgba(140,144,159,0.12)'})
          .borderRadius(RADIUS.lg)

          // -- 权限模式卡片 --
          Text('权限模式')
            .fontSize(TYPO.caption.size)
            .fontColor('#C2C6D6')
            .fontWeight(WEIGHT.medium)
            .alignSelf(ItemAlign.Start)
            .margin({ top: SPACE.xl, bottom: SPACE.sm, left: SPACE.xs })

          Column() {
            Row() {
              Column() {
                Text('当前模式')
                  .fontSize(TYPO.bodySmall.size)
                  .fontColor('#E1E2E8')
                Text(this.getModeDesc(this.permissionMode))
                  .fontSize(TYPO.caption.size)
                  .fontColor('#8C909F')
                  .margin({ top: 2 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Text(this.getModeLabel(this.permissionMode))
                .fontSize(TYPO.bodySmall.size)
                .fontColor(this.getModeColor(this.permissionMode))
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .backgroundColor('rgba(140,144,159,0.08)')
                .borderRadius(6)
            }
            .width('100%')
            .padding({ top: 12, bottom: 12, left: SPACE.lg, right: SPACE.lg })

            Divider().color(COLOR.divider).margin({ left: SPACE.lg, right: SPACE.lg })

            Column() {
              Text('切换模式')
                .fontSize(TYPO.caption.size)
                .fontColor('#8C909F')
                .margin({ bottom: SPACE.sm })

              Row() {
                this.modeOption(PERM_DEFAULT)
                this.modeOption(PERM_ACCEPT_EDITS)
              }
              .width('100%')
              .justifyContent(FlexAlign.SpaceBetween)
              .margin({ bottom: SPACE.sm })

              Row() {
                this.modeOption(PERM_SAFE_YOLO)
                this.modeOption(PERM_YOLO)
              }
              .width('100%')
              .justifyContent(FlexAlign.SpaceBetween)
              .margin({ bottom: SPACE.sm })

              Row() {
                this.modeOption(PERM_PLAN)
                this.modeOption(PERM_READ_ONLY)
              }
              .width('100%')
              .justifyContent(FlexAlign.SpaceBetween)
            }
            .width('100%')
            .padding({ top: SPACE.md, bottom: SPACE.md, left: SPACE.lg, right: SPACE.lg })
          }
          .width('100%')
          .backgroundColor('#161B22').border({width:1,color:'rgba(140,144,159,0.12)'})
          .borderRadius(RADIUS.lg)

          // -- 安全卡片 --
          Text('安全与隐私')
            .fontSize(TYPO.caption.size)
            .fontColor('#C2C6D6')
            .fontWeight(WEIGHT.medium)
            .alignSelf(ItemAlign.Start)
            .margin({ top: SPACE.xl, bottom: SPACE.sm, left: SPACE.xs })

          Column() {
            Row() {
              Column() {
                Text('PIN 保护')
                  .fontSize(TYPO.bodySmall.size)
                  .fontColor('#E1E2E8')
                Text('打开 App 时需要验证 PIN 或生物识别')
                  .fontSize(TYPO.caption.size)
                  .fontColor('#8C909F')
                  .margin({ top: 2 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Toggle({ type: ToggleType.Switch, isOn: this.pinEnabled })
                .height(26)
                .selectedColor('#D97757')
                .switchPointColor('#0B0E12')
                .onChange((isOn: boolean) => {
                  this.handlePinToggle(isOn)
                })
            }
            .width('100%')
            .padding({ top: 12, bottom: 12 })

            Divider().color(COLOR.divider)

            Row() {
              Column() {
                Text('紧急停止')
                  .fontSize(TYPO.bodySmall.size)
                  .fontColor('#E1E2E8')
                Text('终止所有本机 Agent 并清空命令队列')
                  .fontSize(TYPO.caption.size)
                  .fontColor('#8C909F')
                  .margin({ top: 2 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Button(this.emergencyBrakeSending ? '处理中…' : '停止全部')
                .fontSize(12).fontWeight(WEIGHT.semibold)
                .height(34).padding({ left: 12, right: 12 })
                .fontColor('#F0C8BC')
                .backgroundColor('rgba(112,53,43,0.34)')
                .border({ width: 1, color: 'rgba(217,119,87,0.36)' })
                .borderRadius(7)
                .enabled(!this.emergencyBrakeSending)
                .onClick(() => { this.showEmergencyBrakeConfirm = true })
            }
            .width('100%')
            .padding({ top: 14, bottom: 12 })
          }
          .width('100%')
          .padding({ left: SPACE.lg, right: SPACE.lg })
          .backgroundColor('#161B22').border({width:1,color:'rgba(140,144,159,0.12)'})
          .borderRadius(RADIUS.lg)

          if (FEATURE_COLLABORATION_CENTER) {
            Text('协作数据')
              .fontSize(TYPO.caption.size).fontColor('#C2C6D6').fontWeight(WEIGHT.medium)
              .alignSelf(ItemAlign.Start).margin({ top: SPACE.xl, bottom: SPACE.sm, left: SPACE.xs })

            Column() {
              Row() {
                Column() {
                  Text(this.collaborationAccountCount + ' 个账号 · ' + this.collaborationRepositoryCount + ' 个仓库')
                    .fontSize(TYPO.bodySmall.size).fontColor('#E1E2E8')
                  Text(this.collaborationAuditCount + ' 条本地写回审计；Token 由系统安全存储保护')
                    .fontSize(TYPO.caption.size).fontColor('#8C909F').margin({ top: 3 })
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                Text(this.collaborationClearing ? '清除中…' : '清除全部')
                  .fontSize(TYPO.caption.size).fontColor('#C89A89')
                  .onClick(() => { this.clearCollaborationData() })
              }.width('100%').padding({ top: 14, bottom: 14 })
            }
            .width('100%').padding({ left: SPACE.lg, right: SPACE.lg })
            .backgroundColor('#161B22').border({width:1,color:'rgba(140,144,159,0.12)'})
            .borderRadius(RADIUS.lg)
          }

          // -- 连接与诊断：仅显示能够直接验证的本机状态 --
          Row() {
            Text('连接与诊断')
              .fontSize(TYPO.caption.size).fontColor('#C2C6D6').fontWeight(WEIGHT.medium)
            Blank()
            Text(this.usageLoading ? '刷新中' : '刷新')
              .fontSize(TYPO.caption.size).fontColor('#D97757')
              .onClick(() => { if (!this.usageLoading) this.loadUsageDiagnostics() })
          }
          .width('100%').margin({ top: SPACE.xl, bottom: SPACE.sm, left: SPACE.xs, right: SPACE.xs })

          Column() {
            if (this.usageLoading) {
              LoadingProgress().width(28).height(28).color('#D97757').margin({ top: 18, bottom: 18 })
            } else {
              this.diagnosticLine('后端连接', this.diagnosticBackendOk ? '正常' : '不可用', this.diagnosticBackendOk)
              Divider().color(COLOR.divider)
              this.diagnosticLine('Agent 心跳', this.diagnosticAgentOk ? '正常 · ' + this.diagnosticRunningCount + ' 个任务' : '离线', this.diagnosticAgentOk)
              if (this.diagnosticSystemAvailable) {
                Divider().color(COLOR.divider)
                Row() {
                  Text('机器诊断').fontSize(12).fontColor('#C2C6D6').layoutWeight(1)
                  Text('CPU ' + Math.round(this.diagnosticCpu) + '%')
                    .fontSize(10).fontColor('#8C909F').fontFamily('monospace')
                  Text('内存 ' + Math.round(this.diagnosticMemory) + '%')
                    .fontSize(10).fontColor('#8C909F').fontFamily('monospace').margin({ left: 10 })
                  Text('磁盘 ' + Math.round(this.diagnosticDisk) + '%')
                    .fontSize(10).fontColor('#8C909F').fontFamily('monospace').margin({ left: 10 })
                }.width('100%').padding({ top: 14, bottom: 14 })
              }

            }
          }
          .width('100%').padding({ left: SPACE.lg, right: SPACE.lg })
          .backgroundColor('#161B22').border({width:1,color:'rgba(140,144,159,0.12)'})
          .borderRadius(RADIUS.lg)

          // -- 危险区域 --
          Text('危险区域')
            .fontSize(TYPO.caption.size)
            .fontColor(COLOR.danger)
            .fontWeight(WEIGHT.medium)
            .alignSelf(ItemAlign.Start)
            .margin({ top: SPACE.xxl, bottom: SPACE.sm, left: SPACE.xs })

          if (this.showUnpairConfirm) {
            Column() {
              Text('解除配对后需要重新输入配对码才能连接，确定继续？')
                .fontSize(TYPO.bodySmall.size)
                .fontColor('#C2C6D6')
                .margin({ bottom: SPACE.md })

              Row() {
                Button('取消')
                  .fontSize(TYPO.body.size)
                  .height(TOUCH.button)
                  .layoutWeight(1)
                  .fontColor('#C2C6D6')
                  .backgroundColor(COLOR.surfaceSecondary)
                  .borderRadius(RADIUS.md)
                  .onClick(() => { this.showUnpairConfirm = false })

                Button('确定解除')
                  .fontSize(TYPO.body.size)
                  .height(TOUCH.button)
                  .layoutWeight(1)
                  .fontColor(COLOR.textInverse)
                  .backgroundColor(COLOR.danger)
                  .borderRadius(RADIUS.md)
                  .margin({ left: SPACE.md })
                  .onClick(() => { this.handleUnpair() })
              }
              .width('100%')
            }
            .width('100%')
            .padding(SPACE.lg)
            .backgroundColor('#161B22').border({width:1,color:'rgba(140,144,159,0.12)'})
            .borderRadius(RADIUS.lg)
          } else {
            Button('解除配对')
              .width('100%')
              .height(TOUCH.button)
              .fontSize(TYPO.body.size)
              .fontColor(COLOR.danger)
              .backgroundColor('#161B22').border({width:1,color:'rgba(140,144,159,0.12)'})
              .borderRadius(RADIUS.lg)
              .onClick(() => { this.showUnpairConfirm = true })
          }

          // -- 部署区域 --
          Text('系统部署')
            .fontSize(TYPO.caption.size)
            .fontColor('#C2C6D6')
            .fontWeight(WEIGHT.medium)
            .alignSelf(ItemAlign.Start)
            .margin({ top: SPACE.xl, bottom: SPACE.sm, left: SPACE.xs })

          Column() {
            Row() {
              Button(this.deploying ? '部署中…' : '部署新版本')
                .fontSize(TYPO.body.size).height(TOUCH.button)
                .fontColor('#0B0E12').backgroundColor('#D97757')
                .borderRadius(RADIUS.md).layoutWeight(1)
                .enabled(!this.deploying)
                .onClick(() => { this.handleDeploy() })

              Button('检查更新')
                .fontSize(TYPO.body.size).height(TOUCH.button)
                .fontColor('#D97757').backgroundColor('rgba(217,119,87,0.08)')
                .border({ width: 1, color: 'rgba(217,119,87,0.25)' })
                .borderRadius(RADIUS.md).layoutWeight(1)
                .margin({ left: SPACE.md })
                .onClick(() => { this.handleCheckUpdate() })
            }
            .width('100%')

            if (this.updateMsg !== '') {
              Text(this.updateMsg)
                .fontSize(TYPO.caption.size)
                .fontColor(this.updateOk ? COLOR.success : '#C2C6D6')
                .margin({ top: SPACE.sm })
            }
          }
          .width('100%')
          .padding(SPACE.lg)
          .backgroundColor('#161B22').border({width:1,color:'rgba(140,144,159,0.12)'})
          .borderRadius(RADIUS.lg)

          // -- 版本信息 --
          Text(this.serverVersion !== '' ?
            'App ' + APP_VERSION + ' · 服务器 ' + this.serverVersion :
            'App ' + APP_VERSION)
            .fontSize(TYPO.caption.size)
            .fontColor('#8C909F')
            .textAlign(TextAlign.Center)
            .width('100%')
            .margin({ top: SPACE.xl })

          // bottom safe area
          Row().height(48)
        }
        .width('100%')
        .padding({ left: SPACE.lg, right: SPACE.lg })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)

      // PIN 设置弹窗（开启 PIN 保护时弹出）
      if (this.showPinSetupDialog) {
        Stack() {
          Column() {
            Text('设置 PIN 码')
              .fontSize(18).fontWeight(700).fontColor('#E1E2E8').margin({ bottom: 16 })

            TextInput({ text: this.pinSetupInput, placeholder: '输入 4-6 位数字 PIN' })
              .type(InputType.Password).maxLength(6).fontSize(20).height(48).width('100%')
              .textAlign(TextAlign.Center).fontColor('#E1E2E8')
              .backgroundColor('rgba(29,32,36,0.60)')
              .border({ width: 1, color: 'rgba(140,144,159,0.20)' }).borderRadius(8)
              .onChange((v: string) => { this.pinSetupInput = v; this.pinSetupError = '' })

            TextInput({ text: this.pinSetupConfirm, placeholder: '再次输入确认' })
              .type(InputType.Password).maxLength(6).fontSize(20).height(48).width('100%')
              .textAlign(TextAlign.Center).fontColor('#E1E2E8').margin({ top: 12 })
              .backgroundColor('rgba(29,32,36,0.60)')
              .border({ width: 1, color: 'rgba(140,144,159,0.20)' }).borderRadius(8)
              .onChange((v: string) => { this.pinSetupConfirm = v; this.pinSetupError = '' })

            if (this.pinSetupError !== '') {
              Text(this.pinSetupError).fontSize(12).fontColor('#b53333').margin({ top: 8 })
            }

            Row() {
              Button('取消')
                .fontSize(15).height(44).layoutWeight(1)
                .fontColor('#C2C6D6').backgroundColor('rgba(39,42,47,0.60)')
                .border({ width: 1, color: 'rgba(140,144,159,0.15)' }).borderRadius(8)
                .onClick(() => {
                  this.showPinSetupDialog = false
                  // handlePinToggle 不提前设置 pinEnabled，所以此处不需要重置
                  this.pinSetupInput = ''
                  this.pinSetupConfirm = ''
                })

              Button('确定')
                .fontSize(15).height(44).layoutWeight(1).margin({ left: 12 })
                .fontColor('#1A1C20').backgroundColor('#D97757').borderRadius(8)
                .onClick(async () => {
                  const p = this.pinSetupInput.trim()
                  const c = this.pinSetupConfirm.trim()
                  if (p.length < 4 || p.length > 6) {
                    this.pinSetupError = 'PIN 长度需要 4-6 位'
                    return
                  }
                  if (p !== c) {
                    this.pinSetupError = '两次输入的 PIN 不一致'
                    return
                  }
                  // PBKDF2-SHA256 哈希存储（替代 XOR 混淆 — 大理寺 M1 修复，防 Preferences 明文可逆读取）
                  try {
                    const hash = await hashPin(p)
                    await PrefStore.savePinHash(hash)
                    await PrefStore.savePinEnabled(true)
                    this.pinEnabled = true  // 保存成功后设置 toggle 为 ON
                    this.showPinSetupDialog = false
                    this.pinSetupInput = ''
                    this.pinSetupConfirm = ''
                    promptAction.showToast({ message: 'PIN 保护已开启', duration: 2000 })
                  } catch (e) {
                    this.pinSetupError = 'PIN 加密失败: ' + (e as Error).message
                  }
                })
            }.width('100%').margin({ top: 20 })
          }
          .width('80%').padding(24)
          .backgroundColor('rgba(39,42,47,0.80)').backdropBlur(32)
          .border({ width: 1, color: 'rgba(140,144,159,0.15)' }).borderRadius(12)
        }
        .width('100%').height('100%')
        .backgroundColor('rgba(0,0,0,0.65)')
        .onClick(() => {}) // 阻止穿透
      }
      this.emergencyBrakeDialog()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(COLOR.background)
  }

  @Builder
  emergencyBrakeDialog() {
    if (this.showEmergencyBrakeConfirm) {
      Stack() {
        Column() {
          Text('确认紧急停止')
            .fontSize(18).fontWeight(WEIGHT.bold).fontColor('#F0C8BC')
            .margin({ bottom: 10 })
          Text('这会终止所有已配置电脑上的 Agent，并清空命令队列。')
            .fontSize(TYPO.bodySmall.size).fontColor('#C2C6D6')
            .textAlign(TextAlign.Center).margin({ bottom: 20 })
          Row() {
            Button('取消')
              .fontSize(15).height(44).layoutWeight(1)
              .fontColor('#C2C6D6').backgroundColor('rgba(39,42,47,0.60)')
              .border({ width: 1, color: 'rgba(140,144,159,0.15)' }).borderRadius(8)
              .enabled(!this.emergencyBrakeSending)
              .onClick(() => { this.showEmergencyBrakeConfirm = false })
            Button(this.emergencyBrakeSending ? '正在停止…' : '确认停止')
              .fontSize(15).height(44).layoutWeight(1).margin({ left: 12 })
              .fontColor('#F0E5C7').backgroundColor('#7B3A32').borderRadius(8)
              .enabled(!this.emergencyBrakeSending)
              .onClick(() => { this.handleEmergencyBrake() })
          }.width('100%')
        }
        .width('82%').padding(24)
        .backgroundColor('rgba(28,25,27,0.96)').backdropBlur(32)
        .border({ width: 1, color: 'rgba(217,119,87,0.36)' }).borderRadius(12)
      }
      .width('100%').height('100%')
      .backgroundColor('rgba(0,0,0,0.65)')
      .onClick(() => {})
    }
  }

  @Builder
  diagnosticLine(label: string, value: string, ok: boolean): void {
    Row() {
      Circle({ width: 8, height: 8 }).fill(ok ? '#17a34a' : '#8C909F')
      Text(label).fontSize(TYPO.bodySmall.size).fontColor('#C2C6D6').margin({ left: 10 })
      Blank()
      Text(value).fontSize(TYPO.caption.size).fontColor(ok ? '#17a34a' : '#8C909F')
    }.width('100%').padding({ top: 14, bottom: 14 })
  }

  @Builder
  infoLine(label: string, value: string): void {
    Row() {
      Text(label)
        .fontSize(TYPO.bodySmall.size)
        .fontColor('#C2C6D6')
        .width(72)
      Text(value !== '' ? value : '(未设置)')
        .fontSize(TYPO.bodySmall.size)
        .fontColor('#E1E2E8')
        .layoutWeight(1)
        .wordBreak(WordBreak.BREAK_ALL)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ top: SPACE.md, bottom: SPACE.md })
    .onClick(() => { this.copyInfoValue(label, value) })
  }

  /** 整行轻点即复制，避免 Text 选区和系统粘贴浮层残留。 */
  private copyInfoValue(label: string, value: string): void {
    if (value === '') {
      promptAction.showToast({ message: label + '未设置', duration: 1200 })
      return
    }
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, value)
      pasteboard.getSystemPasteboard().setDataSync(data)
      promptAction.showToast({ message: label + '已复制', duration: 1200 })
    } catch (e) {
      console.error('[Settings] copy ' + label + ' failed: ' + (e as Error).message)
      promptAction.showToast({ message: '复制失败', duration: 1200 })
    }
  }
}

@Entry
@Component
struct SettingsPage {
  build() {
    Stack() {
      SettingsContent()
    }
  }
}
