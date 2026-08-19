import { router, promptAction } from '@kit.ArkUI'
import { scanBarcode, scanCore } from '@kit.ScanKit'
import { BusinessError } from '@kit.BasicServicesKit'
import vibrator from '@ohos.vibrator'
import { http } from '@kit.NetworkKit'
import { isLoggedIn, KEY_CLIENT_TOKEN, KEY_DEVICE_ID, KEY_DEVICE_NAME, KEY_BACKEND_URL } from '../state/AppStore'
import DeviceApi from '../api/DeviceApi'
import NavPath from '../model/NavPath'
import PrefStore, { agentDisplayName, normalizeAgentType, normalizeProjectRuntimeMode } from '../store/PrefStore'
import type { AgentType, ProjectConfig, ProjectRuntimeMode } from '../store/PrefStore'
import { COLOR, TYPO, SPACE, RADIUS, HEADER_HEIGHT, WEIGHT, GLASS } from '../utils/DesignTokens'
import ApprovalApi from '../api/ApprovalApi'
import MonitoringAlertApi from '../api/MonitoringAlertApi'
import type { ApprovalRecord } from '../api/types'
import { MetricTile } from '../terminal/MetricTile'
import { WebSocketClient, WSConnectionState, WSEvent } from '../api/WebSocketClient'
import { WS_MSG_HEARTBEAT, WS_MSG_STATE_UPDATE, WS_MSG_APPROVAL_UPDATE } from '../api/ws_types'
import e2eCrypto from '../utils/E2ECrypto'
import { FEATURE_CODEX_DESKTOP } from '../config/ProductFeatures'

interface ProjectCardData {
  config: ProjectConfig
  pendingCount: number
  connected: boolean
  agentRunning: boolean
  /** 后端上报的实际运行类型；与用户为下次启动保存的 config.agentType 分开。 */
  actualAgentType?: AgentType
  /** 后端上报的真实运行入口；与用户下次启动偏好分开。 */
  actualRuntimeMode?: ProjectRuntimeMode
}
interface SysInfoMem { total_mb: number; used_mb: number; free_mb: number; percent: number }
interface SysInfoDisk { total_gb: number; used_gb: number; free_gb: number; percent: number }
interface SysInfoTokens { estimated_tokens: number; messages: number; model: string; cache_hit_rate: number; cost_cny?: number }
interface SysInfoGpu { name: string; util: number; mem_used_mb: number; mem_total_mb: number; mem_percent: number; temp?: number }
interface SysInfoHardware { cpu: string; ram: string; disk: string; gpu: string; board: string }
interface SysInfoData { cpu: number; cpu_temp?: number; memory: SysInfoMem; disk: SysInfoDisk; gpu?: SysInfoGpu; tokens?: SysInfoTokens; hardware?: SysInfoHardware; _timestamp?: number }
interface SparkPoint { cpu: number; mem_used: number; mem_total: number; disk_used: number; disk_total: number; tokens: number; gpu: number; created_at: string }
@Component
export struct ProjectsContent {
  @State projects: ProjectCardData[] = []
  @State loading: boolean = true
  @State showAddDialog: boolean = false
  @State newProjectName: string = ''
  @State newProjectAgentType: AgentType = 'claude'
  @State deleteConfirmName: string = ''
  @State sysInfo: SysInfoData = { cpu: 0, memory: { total_mb: 0, used_mb: 0, free_mb: 0, percent: 0 }, disk: { total_gb: 0, used_gb: 0, free_gb: 0, percent: 0 } }
  // 拆成独立 @State 基本类型字段——V1 对基本类型观察可靠，对象赋值后 @Builder 参数能正确重新求值
  @State cpuPct: number = 0
  @State memUsedGb: number = 0
  @State memTotalGb: number = 0
  @State memPct: number = 0
  @State diskUsedGb: number = 0
  @State diskTotalGb: number = 0
  @State diskPct: number = 0
  @State gpuPct: number = 0
  @State gpuName: string = ''
  @State gpuMemUsedGb: number = 0
  @State gpuMemTotalGb: number = 0
  @State gpuMemPct: number = 0
  @State gpuTemp: number = 0
  @State cpuTemp: number = 0
  @State tokenCount: number = 0
  @State tokenHitRate: number = 0
  @State tokenModel: string = ''
  @State tokenCostCny: number = 0
  // 硬件型号
  @State hwCpu: string = ''
  @State hwRam: string = ''
  @State hwDisk: string = ''
  @State hwGpu: string = ''
  // sparkline 趋势数据（从 /stats/sparkline 拉取，每个是数字数组，最近在前）
  @State cpuSpark: number[] = []
  @State memSpark: number[] = []
  @State diskSpark: number[] = []
  @State gpuSpark: number[] = []
  @State tokenSpark: number[] = []
  @State refreshing: boolean = false
  private refreshRequestRunning: boolean = false
  @State dragIdx: number = -1
  @State dragOffY: number = 0
  @State killAllConfirm: boolean = false       // 紧急刹车二次确认弹窗
  @State killAllSending: boolean = false        // 正在发送 kill-all
  @State pendingPreview: ApprovalRecord[] = []  // 首页待审批预览（最多 2 条）
  @State pendingCount: number = 0               // 待审批总数
  @State monitoringAlertCount: number = 0
  @State startingProjects: string[] = []
  @State stoppingProjects: string[] = []
  @State agentTypeSavingProjects: string[] = []
  @State runtimeModeSavingProjects: string[] = []
  @State expandedProjectName: string = ''
  /** 仅包含本机检测到 vscode/appServer 来源 Thread 的项目。 */
  @State desktopProjectNames: string[] = []
  private sysInfoTimer: number = -1
  private statusTimer: number = -1
  private heartbeatWatchdog: number = -1
  private lastHeartbeatAt: number = 0
  private disposed: boolean = false
  private wsClient: WebSocketClient | null = null
  private wsConnected: boolean = false
  private expectedRunning: Map<string, boolean> = new Map()
  private statusHoldUntil: Map<string, number> = new Map()

  aboutToAppear(): void {
    this.disposed = false
    this.loadProjects()
    this.checkNotificationJump()
    this.setupWS()
  }

  aboutToDisappear(): void {
    this.disposed = true
    this.refreshing = false
    this.refreshRequestRunning = false
    if (this.sysInfoTimer >= 0) { clearTimeout(this.sysInfoTimer); this.sysInfoTimer = -1 }
    if (this.statusTimer >= 0) { clearTimeout(this.statusTimer); this.statusTimer = -1 }
    if (this.heartbeatWatchdog >= 0) { clearTimeout(this.heartbeatWatchdog); this.heartbeatWatchdog = -1 }
    if (this.wsClient) { this.wsClient.destroy(); this.wsClient = null }
  }

  onPageShow(): void {
    this.checkNotificationJump()
    if (isLoggedIn()) {
      this.fetchMonitoringAlertSummary()
      this.fetchPendingApprovals()
      // 正常连接时只接收 heartbeat 静默更新；断连时才读取后端缓存兜底。
      if (!this.wsConnected) {
        this.startSysInfoPolling()
        this.startStatusPolling()
      }
    }
  }
  @StorageLink('triggerNotificationJump') @Watch('checkNotificationJump') _tj: boolean = false

  checkNotificationJump(): void {
    const alertLaunch: boolean = AppStorage.get<boolean>('monitoringAlertLaunch') ?? false
    if (alertLaunch) {
      AppStorage.setOrCreate('monitoringAlertLaunch', false)
      AppStorage.setOrCreate('triggerNotificationJump', false)
      setTimeout(() => { router.pushUrl({ url: NavPath.MONITORING_ALERTS }) }, 300)
      return
    }
    const fromNotify: boolean = AppStorage.get<boolean>('notificationLaunch') ?? false
    if (!fromNotify) return
    AppStorage.setOrCreate('notificationLaunch', false); AppStorage.setOrCreate('triggerNotificationJump', false)
    const proj = AppStorage.get<string>('notificationProject') ?? 'default'; AppStorage.setOrCreate('notificationProject', '')
    setTimeout(() => { router.pushUrl({ url: NavPath.APPROVALS, params: { project: proj, backendUrl: AppStorage.get<string>('backendUrl') ?? '' } }) }, 400)
  }

  /** 建立 WS 连接，监听 heartbeat / state_update / approval_update 事件 */
  private setupWS(): void {
    if (this.wsClient) return
    const backendUrl = AppStorage.get<string>('backendUrl') ?? ''
    if (backendUrl === '') return
    const token = AppStorage.get<string>(KEY_CLIENT_TOKEN) ?? ''
    this.wsClient = new WebSocketClient()
    this.wsClient.setOnEvent((event: WSEvent) => {
      if (event.type === WS_MSG_HEARTBEAT && event.data) {
        this.handleWSHeartbeat(event.data)
      } else if (event.type === WS_MSG_STATE_UPDATE && event.payload) {
        this.handleStateUpdate(event.payload)
      } else if (event.type === WS_MSG_APPROVAL_UPDATE) {
        this.fetchPendingApprovals()
      }
    })
    this.wsClient.setOnStateChange((state: WSConnectionState) => {
      const wasConnected = this.wsConnected
      this.wsConnected = state === WSConnectionState.CONNECTED
      if (this.wsConnected) {
        console.info('[Projects] WS connected, heartbeat push active — stopping fallback polling')
        // WS 恢复连接时停止所有 fallback 轮询
        if (this.sysInfoTimer >= 0) { clearTimeout(this.sysInfoTimer); this.sysInfoTimer = -1 }
        if (this.statusTimer >= 0) { clearTimeout(this.statusTimer); this.statusTimer = -1 }
      } else if (wasConnected && !this.disposed) {
        // WS 断连时启动 fallback 轮询（sysinfo + status + approval）
        console.info('[Projects] WS disconnected — starting fallback polling')
        this.doSysInfoFetch()
        this.startStatusPolling()
        this.fetchPendingApprovals()
      }
    })
    this.wsClient.setOnOpen(() => {
      // join session as phone client to receive broadcasts
      this.wsClient?.joinSession('', 'phone', '', token)
    })
    this.wsClient.connect(backendUrl)
  }

  /** 处理 WS heartbeat 事件，实时更新 sysinfo + 项目状态 */
  private handleWSHeartbeat(data: Record<string, Object>): void {
    if (this.disposed) return
    this.lastHeartbeatAt = Date.now()
    this.resetHeartbeatWatchdog()
    // heartbeat data 是 agent 的 output，包含 _heartbeat/status/running/sysinfo 等
    // 1. 更新项目在线状态（从 running 字段）
    const runningRaw = data['running']
    if (runningRaw !== undefined && runningRaw !== null) {
      const runningList = runningRaw as Object[]
      const runningStrs: string[] = []
      for (let i = 0; i < runningList.length; i++) {
        runningStrs.push(runningList[i] as string)
      }
      this.updateProjectStatusFromRunning(runningStrs)
      this.updateAgentTypesFromDetails(data['details'] as Record<string, Object> | undefined, runningStrs)
    }
    this.updateDesktopProjects(data['desktop_projects'] as Record<string, Object> | undefined)
    this.updateDesktopProjectsFromDetails(data['details'] as Record<string, Object> | undefined)
    // 2. 更新 sysinfo 显示
    const sysinfoRaw = data['sysinfo']
    if (!sysinfoRaw) return
    const sysinfo = sysinfoRaw as Record<string, Object>
    const s: SysInfoData = JSON.parse(JSON.stringify(sysinfo))
    this.applySysInfo(s)
    console.info('[Projects] sysinfo updated via WS heartbeat push')
  }

  /** 将缓存、心跳和手动采样统一落到同一套字段，0% 也是有效实时值。 */
  private applySysInfo(s: SysInfoData): void {
    this.sysInfo = s
    this.cpuPct = Math.max(0, s.cpu)
    if (s.memory) {
      this.memUsedGb = Math.round(s.memory.used_mb / 1024 * 10) / 10
      this.memTotalGb = Math.round(s.memory.total_mb / 1024 * 10) / 10
      this.memPct = Math.max(0, s.memory.percent)
    }
    if (s.disk) {
      this.diskUsedGb = s.disk.used_gb
      this.diskTotalGb = s.disk.total_gb
      this.diskPct = Math.max(0, s.disk.percent)
    }
    if (s.gpu) {
      this.gpuPct = Math.max(0, s.gpu.util)
      this.gpuName = s.gpu.name
      this.gpuMemUsedGb = Math.round(s.gpu.mem_used_mb / 1024 * 10) / 10
      this.gpuMemTotalGb = Math.round(s.gpu.mem_total_mb / 1024 * 10) / 10
      this.gpuMemPct = Math.max(0, s.gpu.mem_percent)
      if (s.gpu.temp !== undefined && s.gpu.temp > 0) { this.gpuTemp = s.gpu.temp }
    }
    if (s.cpu_temp !== undefined && s.cpu_temp > 0) { this.cpuTemp = s.cpu_temp }
    if (s.tokens && s.tokens.estimated_tokens > 0) {
      this.tokenCount = s.tokens.estimated_tokens
      this.tokenHitRate = s.tokens.cache_hit_rate
      this.tokenModel = s.tokens.model
      this.tokenCostCny = s.tokens.cost_cny ?? 0
    }
    if (s.hardware) {
      if (s.hardware.cpu !== '') this.hwCpu = s.hardware.cpu
      if (s.hardware.ram !== '') this.hwRam = s.hardware.ram
      if (s.hardware.disk !== '') this.hwDisk = s.hardware.disk
      if (s.hardware.gpu !== '') this.hwGpu = s.hardware.gpu
    }
  }

  /** 处理 WS state_update 事件（relay join/leave） */
  private handleStateUpdate(payload: Record<string, Object>): void {
    if (this.disposed) return
    const event = (payload['event'] as string) ?? ''
    const project = (payload['project'] as string) ?? ''
    const runningRaw = payload['running']
    if (runningRaw !== undefined && runningRaw !== null) {
      const runningList = runningRaw as Object[]
      const runningStrs: string[] = []
      for (let i = 0; i < runningList.length; i++) {
        runningStrs.push(runningList[i] as string)
      }
      // relay_joined/relay_left 来自后端真实 WebSocket 连接集合，比启动/停止
      // 命令前后的 heartbeat 快照更权威。解除状态保护，避免用户刚启动后立即
      // 关闭 CMD 时，离线事件被 12 秒的防闪烁窗口误判为旧状态。
      if ((event === 'relay_joined' || event === 'relay_left') && project !== '') {
        this.expectedRunning.delete(project)
        this.statusHoldUntil.delete(project)
      }
      this.updateProjectStatusFromRunning(runningStrs)
    }
    console.info('[Projects] state_update: event=' + event)
  }

  private isStarting(projectName: string): boolean {
    return this.startingProjects.indexOf(projectName) >= 0
  }

  private isStopping(projectName: string): boolean {
    return this.stoppingProjects.indexOf(projectName) >= 0
  }

  private isAgentTypeSaving(projectName: string): boolean {
    return this.agentTypeSavingProjects.indexOf(projectName) >= 0
  }

  private isRuntimeModeSaving(projectName: string): boolean {
    return this.runtimeModeSavingProjects.indexOf(projectName) >= 0
  }

  private beginStatusHold(projectName: string, expected: boolean, durationMs: number): void {
    this.expectedRunning.set(projectName, expected)
    this.statusHoldUntil.set(projectName, Date.now() + durationMs)
  }

  /**
   * 启停命令刚成功时，heartbeat 可能仍携带命令前的旧快照。
   * 在短暂确认窗口内忽略与本地命令结果相反的旧状态，收到预期状态后立即解除保护。
   */
  private shouldApplyRunning(projectName: string, incoming: boolean): boolean {
    const expected = this.expectedRunning.get(projectName)
    const holdUntil = this.statusHoldUntil.get(projectName) ?? 0
    if (expected !== undefined && Date.now() < holdUntil && incoming !== expected) {
      return false
    }
    if (expected !== undefined && (incoming === expected || Date.now() >= holdUntil)) {
      this.expectedRunning.delete(projectName)
      this.statusHoldUntil.delete(projectName)
    }
    return true
  }

  private displayedAgentType(card: ProjectCardData): AgentType {
    if (card.agentRunning && card.actualAgentType !== undefined) {
      return normalizeAgentType(card.actualAgentType)
    }
    return normalizeAgentType(card.config.agentType)
  }

  private hasDesktopSessions(projectName: string): boolean {
    return FEATURE_CODEX_DESKTOP && this.desktopProjectNames.indexOf(projectName) >= 0
  }

  private hasCachedDesktopThreads(projectName: string): boolean {
    const cachedProject = AppStorage.get<string>('codexDesktopProject') ?? ''
    const cachedThreads = AppStorage.get<Object[]>('codexDesktopThreads') ?? []
    return cachedProject === projectName && cachedThreads.length > 0
  }

  private displayedRuntimeMode(card: ProjectCardData): ProjectRuntimeMode {
    if (card.agentRunning && card.actualRuntimeMode !== undefined) {
      return normalizeProjectRuntimeMode(card.actualRuntimeMode)
    }
    const configured = normalizeProjectRuntimeMode(card.config.runtimeMode)
    return configured === 'desktop' && this.hasDesktopSessions(card.config.name) ? 'desktop' : 'cli'
  }

  private selectedRuntimeModeForProject(projectName: string): ProjectRuntimeMode {
    for (let i = 0; i < this.projects.length; i++) {
      const card = this.projects[i]
      if (card.config.name === projectName) return this.displayedRuntimeMode(card)
    }
    return 'cli'
  }

  private updateDesktopProjects(raw: Record<string, Object> | undefined): void {
    if (raw === undefined) return
    const names: string[] = []
    const keys = Object.keys(raw)
    for (let i = 0; i < keys.length; i++) {
      const value = raw[keys[i]] as Record<string, Object> | undefined
      const count = value ? (value['thread_count'] as number) : 0
      if (value && value['available'] === true && count > 0) {
        names.push(keys[i])
      }
    }
    this.desktopProjectNames = names
  }

  private updateDesktopProjectsFromDetails(details: Record<string, Object> | undefined): void {
    if (details === undefined) return
    const keys = Object.keys(details)
    const names: string[] = []
    let hasCapabilityMarker = false
    for (let i = 0; i < keys.length; i++) {
      const detail = details[keys[i]] as Record<string, Object> | undefined
      if (detail && detail['desktop_available'] !== undefined) {
        hasCapabilityMarker = true
        const count = (detail['desktop_thread_count'] as number) ?? 0
        if (detail['desktop_available'] === true && count > 0) names.push(keys[i])
      }
    }
    if (hasCapabilityMarker) this.desktopProjectNames = names
  }

  /** 点击时从当前响应式项目列表取值，避免 Builder 闭包保留旧卡片对象。 */
  private selectedAgentTypeForProject(projectName: string, fallback: string): AgentType {
    for (let i = 0; i < this.projects.length; i++) {
      if (this.projects[i].config.name === projectName) {
        return normalizeAgentType(this.projects[i].config.agentType)
      }
    }
    return normalizeAgentType(fallback)
  }

  /** 根据 running 列表更新所有项目的 agentRunning + connected 状态 */
  private updateProjectStatusFromRunning(running: string[]): void {
    if (this.disposed || this.projects.length === 0) return
    const updated: ProjectCardData[] = []
    for (let i = 0; i < this.projects.length; i++) {
      const card = this.projects[i]
      const incoming = running.indexOf(card.config.name) >= 0
      if (!this.shouldApplyRunning(card.config.name, incoming)) {
        updated.push(card)
        continue
      }
      updated.push({
        config: card.config,
        pendingCount: card.pendingCount,
        connected: incoming,         // running implies backend reachable + agent alive
        agentRunning: incoming,
        actualAgentType: incoming ? card.actualAgentType : undefined,
        actualRuntimeMode: incoming ? card.actualRuntimeMode : undefined,
      })
    }
    this.projects = updated
  }

  /** 用 agent 心跳里的真实运行类型刷新项目卡片，避免 UI 与实际进程不一致。 */
  private updateAgentTypesFromDetails(details: Record<string, Object> | undefined, runningProjects: string[]): void {
    if (!details || this.projects.length === 0) return
    const updated: ProjectCardData[] = []
    for (let i = 0; i < this.projects.length; i++) {
      const card = this.projects[i]
      const rawDetail = details[card.config.name] as Record<string, Object> | undefined
      const isRunning = runningProjects.indexOf(card.config.name) >= 0
      const actualType = isRunning && rawDetail
        ? normalizeAgentType(rawDetail['agent_type'] as string)
        : card.actualAgentType
      const actualRuntimeMode = isRunning && rawDetail
        ? normalizeProjectRuntimeMode(rawDetail['runtime_mode'] as string)
        : card.actualRuntimeMode
      updated.push({
        // 实际运行类型只用于展示，不能反向覆盖用户选择的下次启动类型。
        config: card.config,
        pendingCount: card.pendingCount,
        connected: card.connected,
        agentRunning: card.agentRunning,
        actualAgentType: actualType,
        actualRuntimeMode: actualRuntimeMode,
      })
      if (isRunning && actualType !== undefined &&
        (AppStorage.get<string>('terminalProject') ?? '') === card.config.name) {
        AppStorage.setOrCreate('terminalAgentType', actualType)
      }
    }
    this.projects = updated
  }

  /** Heartbeat watchdog：如果 40s 内没有收到 heartbeat，标记所有项目为离线 */
  private resetHeartbeatWatchdog(): void {
    if (this.heartbeatWatchdog >= 0) { clearTimeout(this.heartbeatWatchdog) }
    if (this.disposed) { this.heartbeatWatchdog = -1; return }
    // 40s = agent heartbeat interval (25s) * 1.6 容差
    this.heartbeatWatchdog = setTimeout(() => {
      if (this.disposed) { this.heartbeatWatchdog = -1; return }
      console.warn('[Projects] heartbeat watchdog: no heartbeat in 40s, marking offline')
      this.updateProjectStatusFromRunning([])
      this.heartbeatWatchdog = -1
    }, 40000)
  }

  // ═══════ SysInfo ═══════

  startSysInfoPolling(): void {
    if (this.sysInfoTimer >= 0) { clearTimeout(this.sysInfoTimer); this.sysInfoTimer = -1 }
    if (!this.wsConnected) { this.doSysInfoFetch() }
  }

  /** 用户主动下拉时要求本机 Agent 现场采样，不读取后端上一次 heartbeat 缓存。 */
  private async manualSysInfoRefresh(): Promise<void> {
    let backendUrl: string = ''
    let project: string = 'serein'
    if (this.projects.length > 0) {
      backendUrl = this.projects[0].config.backendUrl
      project = this.projects[0].config.name
    } else {
      backendUrl = AppStorage.get<string>('backendUrl') ?? ''
    }
    if (backendUrl === '') return
    const hc: http.HttpRequest = http.createHttp()
    try {
      const token = AppStorage.get<string>(KEY_CLIENT_TOKEN) ?? ''
      const hdr: Record<string, string> = { 'Content-Type': 'application/json' }
      if (token !== '') hdr['Authorization'] = 'Bearer ' + token
      const resp: http.HttpResponse = await hc.request(backendUrl + '/agent/cmd', {
        method: http.RequestMethod.POST,
        header: hdr,
        extraData: JSON.stringify({ action: 'status', project: project, command: 'sysinfo' }),
        connectTimeout: 5000,
        // 手动刷新不能无限占住下拉动画。正常本机采样通常数秒完成；
        // Agent/后端异常时 15 秒内失败并由 doRefresh 回退到缓存快照。
        readTimeout: 15000,
      })
      if (resp.responseCode !== 200) {
        throw new Error('HTTP ' + resp.responseCode)
      }
      const respData = JSON.parse(resp.result as string) as Record<string, Object>
      const output = respData['output'] as Record<string, Object> | undefined
      const fresh = output ? output['sysinfo'] as Record<string, Object> | undefined : undefined
      if (!fresh) { throw new Error('fresh sysinfo missing') }
      const s: SysInfoData = JSON.parse(JSON.stringify(fresh))
      this.applySysInfo(s)
      this.doSparklineFetch(backendUrl)
      console.info('[SysInfo] manual fresh sample cpu=' + this.cpuPct + '% gpu=' + this.gpuPct + '%')
    } finally {
      hc.destroy()
    }
  }

  async doSysInfoFetch(): Promise<void> {
    if (this.disposed) return
    let backendUrl: string = ''
    if (this.projects.length > 0) {
      backendUrl = this.projects[0].config.backendUrl
    } else {
      backendUrl = AppStorage.get<string>('backendUrl') ?? ''
    }
    if (backendUrl === '') return
    const hc: http.HttpRequest = http.createHttp()
    try {
      const token = AppStorage.get<string>(KEY_CLIENT_TOKEN) ?? ''
      const hdr: Record<string, string> = {}
      if (token !== '') hdr['Authorization'] = 'Bearer ' + token
      const resp: http.HttpResponse = await hc.request(backendUrl + '/agent/sysinfo', {
        method: http.RequestMethod.GET, header: hdr, connectTimeout: 5000, readTimeout: 5000
      })
      if (this.disposed) return  // 组件销毁后丢弃异步结果
      if (resp.responseCode === 200) {
        const s = JSON.parse(resp.result as string) as SysInfoData
        this.applySysInfo(s)
        console.info('[SysInfo] loaded from ' + backendUrl + ' cpu=' + this.cpuPct + ' mem=' + this.memPct + '% disk=' + this.diskPct + '%')
      } else {
        console.error('[SysInfo] bad responseCode=' + resp.responseCode)
      }
    } catch (e) {
      console.error('[SysInfo] fetch failed: ' + (e as Error).message)
    } finally {
      hc.destroy()
    }
    // 拉取 sparkline 趋势数据（与 sysinfo 同后端，失败不影响主流程）
    this.doSparklineFetch(backendUrl)
    // 递归调度下一次 sysinfo 轮询
    // WS 连接时完全停止轮询（heartbeat 实时推送 sysinfo + sparkline fetch 跟随页面可见时触发）
    // WS 断开时 30s fallback 轮询
    if (!this.disposed && !this.wsConnected) {
      this.sysInfoTimer = setTimeout(() => { this.doSysInfoFetch() }, 30000)
    }
  }

  /** 独立的项目状态轮询（fallback）
   * WS 连接时完全停止轮询（heartbeat + state_update + watchdog 覆盖）
   * WS 断开时保持 8s 轮询项目状态 + 审批列表 */
  startStatusPolling(): void {
    if (this.statusTimer >= 0) { clearTimeout(this.statusTimer); this.statusTimer = -1 }
    // WS 连接时不再轮询，由 heartbeat + state_update 事件驱动
    if (this.wsConnected) return
    for (let i = 0; i < this.projects.length; i++) { this.checkOnline(i) }
    // WS 断连时同时刷新审批列表（WS approval_update 事件不可用）
    this.fetchPendingApprovals()
    if (!this.disposed) {
      this.statusTimer = setTimeout(() => { this.startStatusPolling() }, 8000)
    }
  }

  /** 拉取待审批列表（最多 2 条预览 + 总数），首页总览卡片用 */
  private async fetchPendingApprovals(): Promise<void> {    if (this.disposed) return
    try {
      const resp = await ApprovalApi.listPending(2, 0)
      this.pendingPreview = resp.items ?? []
      this.pendingCount = resp.total ?? 0
    } catch (e) {
      console.error('[Projects] fetchPendingApprovals failed: ' + (e as Error).message)
    }
  }

  /** 拉取 /stats/sparkline 趋势数据，拆成 4 个数组供 MetricTile 画折线 */
  private async fetchMonitoringAlertSummary(): Promise<void> {
    if (this.disposed) return
    try {
      const summary = await MonitoringAlertApi.summary()
      this.monitoringAlertCount = summary.active ?? 0
    } catch (e) {
      console.error('[Projects] monitoring alert summary failed: ' + (e as Error).message)
    }
  }

  private async doSparklineFetch(backendUrl: string): Promise<void> {
    if (this.disposed || backendUrl === '') return
    const hc: http.HttpRequest = http.createHttp()
    try {
      const token = AppStorage.get<string>(KEY_CLIENT_TOKEN) ?? ''
      const hdr: Record<string, string> = {}
      if (token !== '') hdr['Authorization'] = 'Bearer ' + token
      const resp: http.HttpResponse = await hc.request(backendUrl + '/stats/sparkline?count=30', {
        method: http.RequestMethod.GET, header: hdr, connectTimeout: 5000, readTimeout: 5000
      })
      if (resp.responseCode === 200) {
        const arr = JSON.parse(resp.result as string) as SparkPoint[]
        if (arr.length > 0) {
          // API 返回最近在前，折线图按时间正序绘制，需反转
          const sorted = arr.slice().reverse()
          this.cpuSpark = sorted.map((p: SparkPoint) => p.cpu)
          this.memSpark = sorted.map((p: SparkPoint) => p.mem_total > 0 ? Math.round(p.mem_used / p.mem_total * 100) : 0)
          this.diskSpark = sorted.map((p: SparkPoint) => p.disk_total > 0 ? Math.round(p.disk_used / p.disk_total * 100) : 0)
          this.gpuSpark = sorted.map((p: SparkPoint) => p.gpu ? p.gpu : 0)
          this.tokenSpark = sorted.map((p: SparkPoint) => p.tokens)
        }
      }
    } catch (e) {
      console.error('[Projects] sparkline fetch failed: ' + (e as Error).message)
    } finally {
      hc.destroy()
    }
  }

  private fmtNum(val: number | undefined | null, suffix: string = ''): string {
    if (val === undefined || val === null || val <= 0) return '--'
    return String(val) + suffix
  }

  private fmtToken(t: SysInfoTokens | undefined): string {
    if (!t || t.estimated_tokens <= 0) return '--'
    const n: number = t.estimated_tokens
    if (n >= 1000000) return (n / 1000000).toFixed(1) + 'M'
    if (n >= 1000) return Math.round(n / 1000) + 'K'
    return String(n)
  }
  private fmtTokenNum(n: number): string {
    if (n <= 0) return '--'
    if (n >= 1000000) return (n / 1000000).toFixed(1) + 'M'
    if (n >= 1000) return Math.round(n / 1000) + 'K'
    return String(n)
  }
  private fmtCost(cny: number): string {
    if (cny >= 1000) return (cny / 1000).toFixed(1) + 'K'
    if (cny >= 100) return cny.toFixed(0)
    return cny.toFixed(2)
  }

  async loadProjects(): Promise<void> {
    this.loading = true
    try {
      const snapshot = await PrefStore.loadAll()
      let burl = snapshot.backendUrl
      if (burl === '') {
        burl = AppStorage.get<string>('backendUrl') ?? ''
      }
      if (snapshot.projects.length === 0 && burl !== '') {
        snapshot.projects.push({ name: 'serein', backendUrl: burl, agentType: 'claude' }); await PrefStore.saveProjects(snapshot.projects)
      }
      const cards: ProjectCardData[] = []
      for (let i = 0; i < snapshot.projects.length; i++) { cards.push({ config: snapshot.projects[i], pendingCount: -1, connected: false, agentRunning: false }) }
      // 合并远程项目列表（从 /agent/projects API 获取）
      if (burl !== '') {
        try {
          const remote = await this.fetchAgentProjects(burl)
          if (remote) {
            this.updateDesktopProjects(remote['desktop_projects'] as Record<string, Object> | undefined)
            this.updateDesktopProjectsFromDetails(remote['details'] as Record<string, Object> | undefined)
          }
          if (remote && remote['projects']) {
            const remoteProjects = remote['projects'] as Record<string, string>
            const remoteNames = Object.keys(remoteProjects)
            // 加载隐藏列表，过滤用户已删除的远程项目
            const hidden = await PrefStore.loadHiddenProjects()
            for (const rn of remoteNames) {
              const exists = cards.some((c: ProjectCardData) => c.config.name === rn)
              if (!exists && hidden.indexOf(rn) < 0) {
                cards.push({
                  config: { name: rn, backendUrl: burl, agentType: 'claude', runtimeMode: 'cli' },
                  pendingCount: -1,
                  connected: false,
                  agentRunning: false,
                })
              }
            }
          }
        } catch (e) {
          console.error('loadProjects remote fetch failed: ' + (e as Error).message)
        }
      }
      this.projects = cards; this.loading = false
      this.fetchMonitoringAlertSummary()
      // 初次加载拉取一次审批列表
      this.fetchPendingApprovals()
      // WS 断连时启动 fallback 轮询；WS 连接时由 heartbeat 事件驱动
      this.startSysInfoPolling()
      if (!this.wsConnected) {
        for (let i = 0; i < cards.length; i++) { this.checkOnline(i) }
        this.startStatusPolling()
      }
    } catch (e) { console.error('loadProjects failed: ' + (e as Error).message); this.loading = false }
  }

  private async checkOnline(index: number): Promise<void> {
    const cfg = this.projects[index].config
    let online = false
    const hc = http.createHttp()
    try {
      const hresp = await hc.request(cfg.backendUrl + '/healthz', {
        method: http.RequestMethod.GET, connectTimeout: 3000, readTimeout: 3000
      })
      if (this.disposed) return  // 组件销毁后丢弃异步结果
      online = hresp.responseCode === 200
    } catch (e) {
      online = false
      console.error('[Projects] healthz check failed: ' + (e as Error).message)
    } finally {
      hc.destroy()
    }

    let agentRunning = false
    let actualAgentType: AgentType = normalizeAgentType(cfg.agentType)
    let actualRuntimeMode: ProjectRuntimeMode = normalizeProjectRuntimeMode(cfg.runtimeMode)
    if (online) {
      const ac = http.createHttp()
      try {
        // /agent/status 需要 clientAuth 鉴权，必须携带 Authorization header
        const token = AppStorage.get<string>(KEY_CLIENT_TOKEN) ?? ''
        const hdr: Record<string, string> = {}
        if (token !== '') hdr['Authorization'] = 'Bearer ' + token
        const aresp = await ac.request(cfg.backendUrl + '/agent/status', {
          method: http.RequestMethod.GET, header: hdr, connectTimeout: 3000, readTimeout: 5000
        })
        if (this.disposed) return  // 组件销毁后丢弃异步结果
        const raw = aresp.result as string
        // 使用 JSON.parse 代替脆弱的 indexOf 字符串匹配
        try {
          const statusData = JSON.parse(raw) as Record<string, Object>
          const running = statusData['running'] as boolean ?? false
          const output = statusData['output'] as Record<string, Object> | undefined
          const runningProjects: string[] = output ? (output['running'] as string[] ?? []) : []
          agentRunning = running && runningProjects.indexOf(cfg.name) >= 0
          const details = output ? (output['details'] as Record<string, Object> | undefined) : undefined
          const detail = details ? (details[cfg.name] as Record<string, Object> | undefined) : undefined
          if (agentRunning && detail) {
            actualAgentType = normalizeAgentType(detail['agent_type'] as string)
            actualRuntimeMode = normalizeProjectRuntimeMode(detail['runtime_mode'] as string)
          }
        } catch (parseErr) {
          console.error('[Projects] ' + cfg.name + ' status JSON parse failed: ' + (parseErr as Error).message)
          agentRunning = false
        }
        console.info('[Projects] ' + cfg.name + ' agentRunning=' + agentRunning)
      } catch (e) {
        agentRunning = false
        console.error('[Projects] ' + cfg.name + ' status check failed: ' + (e as Error).message)
      } finally {
        ac.destroy()
      }
    }
    const updated: ProjectCardData[] = []
    for (let i = 0; i < this.projects.length; i++) {
      if (this.projects[i].config.name === cfg.name) {
        const current = this.projects[i]
        const applyIncoming = this.shouldApplyRunning(cfg.name, agentRunning)
        const finalRunning = applyIncoming ? agentRunning : current.agentRunning
        updated.push({
          config: current.config,
          pendingCount: current.pendingCount,
          connected: applyIncoming ? online : current.connected,
          agentRunning: finalRunning,
          actualAgentType: finalRunning
            ? (applyIncoming && agentRunning ? actualAgentType : current.actualAgentType)
            : undefined,
          actualRuntimeMode: finalRunning
            ? (applyIncoming && agentRunning ? actualRuntimeMode : current.actualRuntimeMode)
            : undefined,
        })
      } else {
        updated.push(this.projects[i])
      }
    }
    this.projects = updated
  }

  /** Selecting a project only reveals its launch choices; it never starts an Agent by itself. */
  private toggleProjectExpansion(projectName: string): void {
    this.expandedProjectName = this.expandedProjectName === projectName ? '' : projectName
  }

  private isProjectExpanded(projectName: string): boolean {
    return this.expandedProjectName === projectName
  }

  /** Persist the explicit launch choice first, then start using exactly that choice. */
  private async chooseProjectLaunch(card: ProjectCardData, runtimeMode: ProjectRuntimeMode,
    agentType: AgentType): Promise<void> {
    const project = card.config.name
    if (card.agentRunning || this.isStarting(project) || this.isStopping(project) ||
      this.isAgentTypeSaving(project) || this.isRuntimeModeSaving(project)) return
    if (runtimeMode === 'desktop' && !this.hasDesktopSessions(project)) {
      promptAction.showToast({ message: '这个项目没有可用的 Codex 桌面会话', duration: 1800 })
      return
    }
    const selectedAgent: AgentType = runtimeMode === 'desktop' ? 'codex' : agentType
    const oldAgent = normalizeAgentType(card.config.agentType)
    const oldRuntime = normalizeProjectRuntimeMode(card.config.runtimeMode)
    this.setProjectAgentType(project, selectedAgent)
    this.setProjectRuntimeMode(project, runtimeMode)
    try {
      await PrefStore.updateProjectAgentType(project, selectedAgent, card.config.backendUrl)
      await PrefStore.updateProjectRuntimeMode(project, runtimeMode, card.config.backendUrl)
      this.expandedProjectName = ''
      await this.handleAgentStart(project, card.config.backendUrl, selectedAgent)
    } catch (e) {
      this.setProjectAgentType(project, oldAgent)
      this.setProjectRuntimeMode(project, oldRuntime)
      promptAction.showToast({ message: '启动方式保存失败，请重试', duration: 1800 })
    }
  }

  /** 打开 Codex Desktop 会话面板；所有接管、发送和中断仍由 relay 租约校验。 */
  private openCodexDesktopSessions(card: ProjectCardData): void {
    if (!this.hasDesktopSessions(card.config.name)) return
    const previousProject = AppStorage.get<string>('codexDesktopProject') ?? ''
    const hasCachedThreads = this.hasCachedDesktopThreads(card.config.name)
    if (previousProject !== '' && previousProject !== card.config.name) {
      AppStorage.setOrCreate('codexDesktopActive', null)
    }
    // 会话列表属于具体项目。切换/重新打开时先进入明确的加载态，不能把
    // 上一个项目的旧列表或尚未返回的空数组误报成“没有会话”。
    if (!hasCachedThreads) AppStorage.setOrCreate('codexDesktopThreads', [])
    AppStorage.setOrCreate('codexDesktopError', '')
    AppStorage.setOrCreate('codexDesktopLoading', !hasCachedThreads)
    AppStorage.setOrCreate('terminalProject', card.config.name)
    AppStorage.setOrCreate('terminalAgentType', 'codex')
    AppStorage.setOrCreate('terminalRuntimeMode', 'desktop')
    AppStorage.setOrCreate('codexDesktopProject', card.config.name)
    AppStorage.setOrCreate('openCodexDesktopPanel', true)
    AppStorage.setOrCreate('terminalStartMsg', '')
    AppStorage.setOrCreate('switchToTerminal', true)
  }
  /** 内嵌扫码添加项目 — 调用 @kit.ScanKit 相机扫码，不跳外部页面 */
  private handleScanAddProject(): void {
    const options: scanBarcode.ScanOptions = {
      scanTypes: [scanCore.ScanType.ALL],
      enableMultiMode: false,
      enableAlbum: false,
    }
    scanBarcode.startScanForResult(getContext(this), options)
      .then(async (result: scanBarcode.ScanResult) => {
        const content: string = result.originalValue
        if (content === undefined || content === null || content === '') {
          promptAction.showToast({ message: '扫码结果为空', duration: 2000 })
          return
        }
        let addedName: string = ''
        try {
          // 尝试解析二维码内容（JSON 格式：{name, backendUrl, token}）
          const parsed: Record<string, string> = JSON.parse(content) as Record<string, string>
          const name: string = parsed['name'] ?? ''
          const backendUrl: string = parsed['backendUrl'] ?? ''
            const token: string = parsed['token'] ?? ''
            const agentType: AgentType = normalizeAgentType(parsed['agentType'] ?? parsed['agent_type'])
            // E2E: extract encryption key from QR payload
            const e2eKey: string = parsed['e2eKey'] ?? ''
            // 扫码配对：若 QR 含 pairCode 且设备未配对，自动调用配对接口
            const pairCode: string = parsed['pairCode'] ?? ''
            if (pairCode !== '') {
              const currentToken = AppStorage.get<string>(KEY_CLIENT_TOKEN)
              if (currentToken === undefined || currentToken === '') {
                try {
                  // ?? 只在 null/undefined 时回退，AppStorage 引导后是空串 ''，必须用 || 才能兜底
                  const deviceName = (AppStorage.get<string>(KEY_DEVICE_NAME) || 'My Phone').trim() || 'My Phone'
                  const pairResp = await DeviceApi.pair(deviceName, pairCode)
                  await PrefStore.saveToken(pairResp.client_token, pairResp.device_id, pairResp.device_name)
                  AppStorage.setOrCreate(KEY_CLIENT_TOKEN, pairResp.client_token)
                  AppStorage.setOrCreate(KEY_DEVICE_ID, pairResp.device_id)
                  AppStorage.setOrCreate(KEY_DEVICE_NAME, pairResp.device_name)
                  promptAction.showToast({ message: '设备已绑定' })
                } catch (pairErr) {
                  const apiErr = pairErr as Record<string, Object>
                  const status = apiErr['status'] as number | undefined
                  if (status === 403) {
                    promptAction.showToast({ message: '配对码错误' })
                  } else if (status === 409) {
                    promptAction.showToast({ message: '已有设备绑定，请先在已绑定设备上解除配对' })
                  } else {
                    promptAction.showToast({ message: '配对失败，项目仍可添加' })
                  }
                }
              }
            }
            if (name !== '' && backendUrl !== '') {
              // 扫码添加项目时同步保存全局后端地址，避免 SplashPage 反复跳转配对页
              AppStorage.setOrCreate(KEY_BACKEND_URL, backendUrl)
              await PrefStore.saveBackendUrl(backendUrl)
              await PrefStore.addProject({ name: name, backendUrl: backendUrl, agentType: agentType })
            if (token !== '') {
              AppStorage.setOrCreate<string>(KEY_CLIENT_TOKEN, token)
            }
            // E2E: store key in AppStorage + PrefStore and initialize crypto module
            if (e2eKey !== '') {
              AppStorage.setOrCreate<string>('e2e_key_' + name, e2eKey)
              await PrefStore.saveE2EKey(name, e2eKey)
              e2eCrypto.setKey(e2eKey)
              console.info('serein: E2E key loaded for project ' + name)
            }
            this.loadProjects()
            addedName = name
          }
        } catch (_e) {
          // 非 JSON 格式，当作纯文本项目名处理
        }
        // 兜底：纯文本当作项目名
        if (addedName === '') {
          const name: string = content.trim()
          if (name !== '') {
            const snapshot = await PrefStore.loadAll()
            await PrefStore.addProject({ name: name, backendUrl: snapshot.backendUrl, agentType: 'claude' })
            this.loadProjects()
            addedName = name
          }
        }
        // 绑定成功 → 跳转到 Terminal 页面
        if (addedName !== '') {
          promptAction.showToast({ message: '项目已添加: ' + addedName, duration: 2000 })
          AppStorage.setOrCreate('terminalProject', addedName)
          AppStorage.setOrCreate('switchToTerminal', true)
        }
      })
      .catch((error: BusinessError) => {
        if (error.code !== 200) {
          promptAction.showToast({ message: '扫码失败: ' + error.message, duration: 2000 })
        }
      })
  }

  handleAddProject(): void { this.newProjectName = ''; this.newProjectAgentType = 'claude'; this.showAddDialog = true }
  async confirmAddProject(): Promise<void> { const name = this.newProjectName.trim(); if (name === '') return; const snapshot = await PrefStore.loadAll(); await PrefStore.addProject({ name: name, backendUrl: snapshot.backendUrl, agentType: this.newProjectAgentType }); this.showAddDialog = false; this.loadProjects() }
  async handleDeleteProject(name: string): Promise<void> { await PrefStore.removeProject(name); this.deleteConfirmName = ''; this.loadProjects() }

  async handleAgentStart(project: string, backendUrl: string, agentType: string): Promise<void> {
    if (this.isStarting(project) || this.isStopping(project) || this.isAgentTypeSaving(project)) return
    this.startingProjects = this.startingProjects.concat([project])
    const runtimeMode: ProjectRuntimeMode = this.selectedRuntimeModeForProject(project)
    const cliType: AgentType = this.selectedAgentTypeForProject(project, agentType)
    const selectedType: AgentType = runtimeMode === 'desktop' ? 'codex' : cliType
    // 当前卡片是用户刚刚确认过的选择：先将它写回存储，再按同一个值启动。
    // 不重新读取旧快照，否则会出现卡片显示 Codex、实际却启动 Claude 的竞态。
    try {
      await PrefStore.updateProjectAgentType(project, cliType, backendUrl)
    } catch (e) {
      console.warn('[Projects] persist selected agent type failed, continuing with card value: ' + (e as Error).message)
    }
    console.info('[Projects] start request project=' + project + ' agent_type=' + selectedType + ' runtime_mode=' + runtimeMode)
    // 立即切到 Terminal tab，不等待 Agent 响应
    AppStorage.setOrCreate('terminalProject', project)
    AppStorage.setOrCreate('terminalAgentType', selectedType)
    AppStorage.setOrCreate('terminalRuntimeMode', runtimeMode)
    if (runtimeMode === 'desktop') {
      const hasCachedThreads = this.hasCachedDesktopThreads(project)
      AppStorage.setOrCreate('codexDesktopProject', project)
      if (!hasCachedThreads) AppStorage.setOrCreate('codexDesktopThreads', [])
      AppStorage.setOrCreate('codexDesktopError', '')
      AppStorage.setOrCreate('codexDesktopLoading', !hasCachedThreads)
      AppStorage.setOrCreate('codexDesktopStarting', true)
    } else {
      AppStorage.setOrCreate('codexDesktopStarting', false)
    }
    // Desktop mode always enters Terminal through the session chooser. CLI
    // keeps the existing direct-entry behavior.
    AppStorage.setOrCreate('openCodexDesktopPanel', runtimeMode === 'desktop')
    AppStorage.setOrCreate('terminalStartMsg', runtimeMode === 'desktop'
      ? '正在连接 Codex 桌面会话 · ' + project + '...'
      : '正在启动 ' + agentDisplayName(selectedType) + ' CLI · ' + project + '...')
    AppStorage.setOrCreate('switchToTerminal', true)

    let ok = false
    let startMsg = ''
    let actualType: AgentType = selectedType
    let actualRuntimeMode: ProjectRuntimeMode = runtimeMode
    const hc = http.createHttp()
    try {
      const token = AppStorage.get<string>(KEY_CLIENT_TOKEN) ?? ''
      const hdr: Record<string,string> = {}
      if (token !== '') hdr['Authorization'] = 'Bearer ' + token
      const resp = await hc.request(backendUrl + '/agent/cmd', {
        method: http.RequestMethod.POST, header: hdr,
        extraData: JSON.stringify({
          action: 'start',
          project: project,
          agent_type: selectedType,
          runtime_mode: runtimeMode,
          // 兼容尚未升级的后端：旧版会透传 start.command，新版优先使用 runtime_mode。
          command: runtimeMode,
        }),
        connectTimeout: 5000, readTimeout: 45000
      })
      const raw = resp.result as string
      // 统一使用 JSON.parse（替代之前 indexOf + JSON.parse 两遍解析的反模式）
      try {
        const respData = JSON.parse(raw) as Record<string, Object>
        ok = respData['ok'] === true
        if (ok) {
          const output = respData['output'] as Record<string, Object> | undefined
          if (output) {
            const status = (output['status'] as string) ?? ''
            if (status === 'project_busy') {
              ok = false
              startMsg = '启动失败：已有其他项目或启动方式正在运行'
            }
            const reportedType = (output['agent_type'] as string) ?? ''
            if (reportedType !== '') actualType = normalizeAgentType(reportedType)
            const reportedRuntime = (output['runtime_mode'] as string) ?? ''
            if (reportedRuntime !== '') actualRuntimeMode = normalizeProjectRuntimeMode(reportedRuntime)
            const ctx = (output['context'] as string) ?? ''
            // context 为空时给默认成功提示，避免占位 "Starting..." 一直留着
            if (ok) startMsg = ctx !== '' ? ctx : ('' + project + ' 已激活')
          }
        } else {
          startMsg = '启动失败'
        }
      } catch (parseErr) {
        ok = false
        startMsg = 'start failed: JSON parse error'
        console.error('[Projects] start JSON parse failed: ' + (parseErr as Error).message)
      }
    } catch (e) {
      startMsg = 'start failed: ' + (e as Error).message
    } finally {
      hc.destroy()
    }
    if (ok) {
      // /agent/cmd 已确认启动成功。短时间忽略旧 heartbeat 的“未运行”快照，
      // 避免 Stop → Start → Stop 的视觉闪烁。
      this.beginStatusHold(project, true, 12000)
      this.setProjectRunning(project, true)
      this.setProjectActualAgentType(project, actualType)
      this.setProjectActualRuntimeMode(project, actualRuntimeMode)
      AppStorage.setOrCreate('terminalAgentType', actualType)
      AppStorage.setOrCreate('terminalRuntimeMode', actualRuntimeMode)
      if (actualType !== selectedType) {
        startMsg = '实际启动的是 ' + agentDisplayName(actualType) + '。' + startMsg
      }
      if (actualRuntimeMode === 'desktop') {
        for (let i = 0; i < this.projects.length; i++) {
          if (this.projects[i].config.name === project) {
            this.openCodexDesktopSessions(this.projects[i])
            break
          }
        }
        AppStorage.setOrCreate('codexDesktopStarting', false)
        const refreshSeq = AppStorage.get<number>('codexDesktopRefreshSeq') ?? 0
        AppStorage.setOrCreate('codexDesktopRefreshSeq', refreshSeq + 1)
      } else {
        AppStorage.setOrCreate('codexDesktopStarting', false)
        AppStorage.setOrCreate('openCodexDesktopPanel', false)
      }
      setTimeout(() => {
        if (!this.disposed) this.refreshAgentStatus(project)
      }, 1200)
    } else {
      this.setProjectRunning(project, false)
      if (runtimeMode === 'desktop') {
        AppStorage.setOrCreate('codexDesktopStarting', false)
        AppStorage.setOrCreate('codexDesktopLoading', false)
        AppStorage.setOrCreate('codexDesktopError', startMsg !== '' ? startMsg : '桌面会话启动失败')
      }
    }
    this.startingProjects = this.startingProjects.filter((name: string) => name !== project)
    // 用最终结果覆盖占位 "Starting agent..." 消息
    AppStorage.setOrCreate('terminalStartMsg', startMsg)
  }

  private setProjectAgentType(projectName: string, agentType: AgentType): void {
    const updated: ProjectCardData[] = []
    for (let i = 0; i < this.projects.length; i++) {
      const item = this.projects[i]
      if (item.config.name === projectName) {
        updated.push({
          config: {
            name: item.config.name,
            backendUrl: item.config.backendUrl,
            agentType: agentType,
            runtimeMode: item.config.runtimeMode,
          },
          pendingCount: item.pendingCount,
          connected: item.connected,
          agentRunning: item.agentRunning,
          actualAgentType: item.actualAgentType,
          actualRuntimeMode: item.actualRuntimeMode,
        })
      } else {
        updated.push(item)
      }
    }
    this.projects = updated
  }

  private setProjectActualAgentType(projectName: string, agentType: AgentType): void {
    const updated: ProjectCardData[] = []
    for (let i = 0; i < this.projects.length; i++) {
      const item = this.projects[i]
      if (item.config.name === projectName) {
        updated.push({
          config: item.config,
          pendingCount: item.pendingCount,
          connected: item.connected,
          agentRunning: item.agentRunning,
          actualAgentType: agentType,
          actualRuntimeMode: item.actualRuntimeMode,
        })
      } else {
        updated.push(item)
      }
    }
    this.projects = updated
  }

  private setProjectActualRuntimeMode(projectName: string, runtimeMode: ProjectRuntimeMode): void {
    const updated: ProjectCardData[] = []
    for (let i = 0; i < this.projects.length; i++) {
      const item = this.projects[i]
      if (item.config.name === projectName) {
        updated.push({
          config: item.config,
          pendingCount: item.pendingCount,
          connected: item.connected,
          agentRunning: item.agentRunning,
          actualAgentType: item.actualAgentType,
          actualRuntimeMode: runtimeMode,
        })
      } else {
        updated.push(item)
      }
    }
    this.projects = updated
  }

  private setProjectRuntimeMode(projectName: string, runtimeMode: ProjectRuntimeMode): void {
    const updated: ProjectCardData[] = []
    for (let i = 0; i < this.projects.length; i++) {
      const item = this.projects[i]
      if (item.config.name === projectName) {
        updated.push({
          config: {
            name: item.config.name,
            backendUrl: item.config.backendUrl,
            agentType: item.config.agentType,
            runtimeMode: runtimeMode,
          },
          pendingCount: item.pendingCount,
          connected: item.connected,
          agentRunning: item.agentRunning,
          actualAgentType: item.actualAgentType,
          actualRuntimeMode: item.actualRuntimeMode,
        })
      } else {
        updated.push(item)
      }
    }
    this.projects = updated
  }

  private async handleRuntimeModeTap(card: ProjectCardData): Promise<void> {
    if (card.agentRunning) {
      if (this.displayedRuntimeMode(card) === 'desktop') this.openCodexDesktopSessions(card)
      return
    }
    if (!this.hasDesktopSessions(card.config.name) || this.isRuntimeModeSaving(card.config.name)) return
    const previous = normalizeProjectRuntimeMode(card.config.runtimeMode)
    const next: ProjectRuntimeMode = previous === 'desktop' ? 'cli' : 'desktop'
    this.runtimeModeSavingProjects = this.runtimeModeSavingProjects.concat([card.config.name])
    this.setProjectRuntimeMode(card.config.name, next)
    try {
      await PrefStore.updateProjectRuntimeMode(card.config.name, next, card.config.backendUrl)
      promptAction.showToast({
        message: next === 'desktop' ? '启动方式：Codex 桌面会话' : '启动方式：CLI',
        duration: 1500,
      })
    } catch (e) {
      this.setProjectRuntimeMode(card.config.name, previous)
      promptAction.showToast({ message: '启动方式保存失败，请重试', duration: 1800 })
    } finally {
      this.runtimeModeSavingProjects = this.runtimeModeSavingProjects.filter((name: string) => name !== card.config.name)
    }
  }

  /** 离线时轻触 Agent 胶囊即可切换，并按项目持久化。 */
  private async toggleProjectAgent(card: ProjectCardData): Promise<void> {
    if (card.agentRunning || this.isStarting(card.config.name) || this.isStopping(card.config.name)) {
      promptAction.showToast({ message: '请先停止当前 Agent 再切换', duration: 1800 })
      return
    }
    if (this.isAgentTypeSaving(card.config.name)) return
    const previous: AgentType = normalizeAgentType(card.config.agentType)
    const next: AgentType = previous === 'claude' ? 'codex' : 'claude'
    this.agentTypeSavingProjects = this.agentTypeSavingProjects.concat([card.config.name])
    // 先刷新界面，再异步保存，避免存储耗时让点击看起来没有响应。
    this.setProjectAgentType(card.config.name, next)
    try {
      await PrefStore.updateProjectAgentType(card.config.name, next, card.config.backendUrl)
      promptAction.showToast({ message: '已切换到 ' + agentDisplayName(next), duration: 1500 })
    } catch (e) {
      this.setProjectAgentType(card.config.name, previous)
      promptAction.showToast({ message: '切换失败，请重试', duration: 1800 })
      console.error('[Projects] save agent type failed: ' + (e as Error).message)
    } finally {
      this.agentTypeSavingProjects = this.agentTypeSavingProjects.filter((name: string) => name !== card.config.name)
    }
  }

  async handleAgentStop(project: string, backendUrl: string): Promise<void> {
    if (this.isStarting(project) || this.isStopping(project)) return
    this.stoppingProjects = this.stoppingProjects.concat([project])
    let ok = false
    const hc = http.createHttp()
    try {
      const token = AppStorage.get<string>(KEY_CLIENT_TOKEN) ?? ''
      const hdr: Record<string, string> = {}
      if (token !== '') hdr['Authorization'] = 'Bearer ' + token
      const resp = await hc.request(backendUrl + '/agent/cmd?async=true', {
        method: http.RequestMethod.POST,
        header: hdr,
        extraData: JSON.stringify({ action: 'stop', project: project }),
        connectTimeout: 5000,
        readTimeout: 8000,
      })
      const respData = JSON.parse(resp.result as string) as Record<string, Object>
      ok = resp.responseCode === 200 && respData['ok'] === true && respData['queued'] === true
    } catch (e) {
      console.error('[Projects] stop failed: ' + (e as Error).message)
    } finally {
      hc.destroy()
    }
    if (ok) {
      this.beginStatusHold(project, false, 25000)
      this.setProjectRunning(project, false)
    } else {
      promptAction.showToast({ message: '停止失败，请重试', duration: 1800 })
    }
    this.stoppingProjects = this.stoppingProjects.filter((name: string) => name !== project)
  }

  /** 紧急刹车：向所有已配置后端广播 kill-all，杀掉全部 claude.exe + 清空队列 */
  async handleKillAll(): Promise<void> {
    if (this.killAllSending) return
    this.killAllSending = true
    // 收集所有不重复的 backendUrl（多项目可能共用同一后端）
    const urls: string[] = []
    for (let i = 0; i < this.projects.length; i++) {
      const u = this.projects[i].config.backendUrl
      if (u !== '' && urls.indexOf(u) < 0) urls.push(u)
    }
    let okCount = 0
    for (let i = 0; i < urls.length; i++) {
      const hc = http.createHttp()
      try {
        const token = AppStorage.get<string>(KEY_CLIENT_TOKEN) ?? ''
        const hdr: Record<string,string> = {}
        if (token !== '') hdr['Authorization'] = 'Bearer ' + token
        await hc.request(urls[i] + '/agent/cmd?async=true', {
          method: http.RequestMethod.POST, header: hdr,
          extraData: JSON.stringify({ action: 'kill-all' }),
          connectTimeout: 5000, readTimeout: 10000
        })
        okCount++
      } catch (e) {}
      finally { hc.destroy() }
    }
    // 本地把所有项目标记为未运行
    const updated: ProjectCardData[] = []
    for (let i = 0; i < this.projects.length; i++) {
      updated.push({
        config: this.projects[i].config,
        pendingCount: this.projects[i].pendingCount,
        connected: this.projects[i].connected,
        agentRunning: false,
        actualAgentType: undefined,
        actualRuntimeMode: undefined,
      })
    }
    this.projects = updated
    this.killAllSending = false
    this.killAllConfirm = false
    promptAction.showToast({ message: okCount > 0 ? `紧急刹车已触发 (${okCount} 个后端)` : '发送失败，请重试', duration: 2500 })
  }

  private async refreshAgentStatus(projectName: string): Promise<void> {
    const hc = http.createHttp()
    try {
      const token = AppStorage.get<string>(KEY_CLIENT_TOKEN) ?? ''
      const hdr: Record<string, string> = {}
      if (token !== '') hdr['Authorization'] = 'Bearer ' + token
      let cfg: ProjectConfig | undefined = undefined
      for (let i = 0; i < this.projects.length; i++) {
        if (this.projects[i].config.name === projectName) {
          cfg = this.projects[i].config
          break
        }
      }
      if (!cfg) { hc.destroy(); return }
      const aresp = await hc.request(cfg.backendUrl + '/agent/status', {
        method: http.RequestMethod.GET,
        header: hdr,
        connectTimeout: 3000,
        readTimeout: 5000,
      })
      const raw = aresp.result as string
      // 使用 JSON.parse 代替脆弱的 indexOf 字符串匹配
      try {
        const statusData = JSON.parse(raw) as Record<string, Object>
        const running = statusData['running'] as boolean ?? false
        const output = statusData['output'] as Record<string, Object> | undefined
        const runningProjects: string[] = output ? (output['running'] as string[] ?? []) : []
        const incoming = running && runningProjects.indexOf(projectName) >= 0
        if (this.shouldApplyRunning(projectName, incoming)) {
          this.setProjectRunning(projectName, incoming)
          if (incoming && output) {
            const details = output['details'] as Record<string, Object> | undefined
            const detail = details ? details[projectName] as Record<string, Object> | undefined : undefined
            if (detail) {
              const actualType = normalizeAgentType(detail['agent_type'] as string)
              this.setProjectActualAgentType(projectName, actualType)
              this.setProjectActualRuntimeMode(
                projectName,
                normalizeProjectRuntimeMode(detail['runtime_mode'] as string),
              )
              if ((AppStorage.get<string>('terminalProject') ?? '') === projectName) {
                AppStorage.setOrCreate('terminalAgentType', actualType)
              }
            }
          }
        }
      } catch (parseErr) {
        console.error('[Projects] refreshAgentStatus JSON parse failed: ' + (parseErr as Error).message)
      }
    } catch (e) {
      console.error('[Projects] refreshAgentStatus failed: ' + (e as Error).message)
    } finally {
      hc.destroy()
    }
  }

  private setProjectRunning(projectName: string, isRunning: boolean): void {
    const updated: ProjectCardData[] = []
    for (let i = 0; i < this.projects.length; i++) {
      const card = this.projects[i]
      if (card.config.name === projectName) {
        updated.push({
          config: card.config,
          pendingCount: card.pendingCount,
          connected: card.connected,
          agentRunning: isRunning,
          actualAgentType: isRunning ? card.actualAgentType : undefined,
          actualRuntimeMode: isRunning ? card.actualRuntimeMode : undefined,
        })
      } else {
        updated.push(card)
      }
    }
    this.projects = updated
  }

  private async pinToTop(index: number): Promise<void> {
    if (index <= 0) return
    const item = this.projects[index]
    const result: ProjectCardData[] = [item]
    for (let i = 0; i < this.projects.length; i++) { if (i !== index) result.push(this.projects[i]) }
    this.projects = result
    const configs: ProjectConfig[] = []
    for (let i = 0; i < result.length; i++) configs.push(result[i].config)
    await PrefStore.saveProjects(configs)
  }

  private swapProjects(a: number, b: number): void {
    if (a === b || a < 0 || b < 0 || a >= this.projects.length || b >= this.projects.length) return
    const copy: ProjectCardData[] = []
    for (let i = 0; i < this.projects.length; i++) copy.push(this.projects[i])
    const tmp = copy[a]; copy[a] = copy[b]; copy[b] = tmp
    this.projects = copy
    const configs: ProjectConfig[] = []
    for (let i = 0; i < copy.length; i++) configs.push(copy[i].config)
    PrefStore.saveProjects(configs)
  }

  /** 从后端 /agent/projects 拉取远程项目列表 + relay 状态 */
  private async fetchAgentProjects(backendUrl: string): Promise<Record<string, Object> | null> {
    const hc = http.createHttp()
    try {
      const token = AppStorage.get<string>(KEY_CLIENT_TOKEN) ?? ''
      const hdr: Record<string, string> = {}
      if (token !== '') hdr['Authorization'] = 'Bearer ' + token
      const r = await hc.request(backendUrl + '/agent/projects', {
        method: http.RequestMethod.GET,
        header: hdr,
        connectTimeout: 5000,
        readTimeout: 5000,
      })
      if (r.responseCode === 200) {
        return JSON.parse(r.result as string) as Record<string, Object>
      }
    } catch (e) {
      console.error('[Projects] fetchAgentProjects failed: ' + (e as Error).message)
    } finally {
      hc.destroy()
    }
    return null
  }

  async doRefresh(): Promise<void> {
    // Refresh 的 $$ 双向绑定会在 onRefreshing 回调之前先把 refreshing
    // 设为 true，不能用它判断请求是否已经开始，否则会提前 return，
    // 导致 finally 永远不执行、下拉动画一直转圈。
    if (this.refreshRequestRunning) return
    this.refreshRequestRunning = true
    this.refreshing = true
    try {
      await this.manualSysInfoRefresh()
      for (let i = 0; i < this.projects.length; i++) { this.checkOnline(i) }
      this.fetchPendingApprovals()
    } catch (e) {
      console.error('[Projects] manual refresh failed: ' + (e as Error).message)
      // 现场采样失败时仍尝试读取后端最近一次有效快照；doSysInfoFetch
      // 自身会吞掉网络异常，不影响 finally 关闭刷新动画。
      await this.doSysInfoFetch()
      promptAction.showToast({ message: '刷新失败，请检查电脑端 Agent', duration: 1800 })
    } finally {
      this.refreshing = false
      this.refreshRequestRunning = false
    }
  }

  /** Keep the home pull-to-refresh spinner on the same coral accent as the app. */
  @Builder
  private projectPullRefreshIndicator(): void {
    Row() {
      LoadingProgress().width(28).height(28).color('#D97757')
    }
    .width('100%').height(52)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  swipeActions(card: ProjectCardData) {
    Row() {
      Button('置顶').fontSize(14).fontWeight(WEIGHT.semibold).fontColor('#F0E5C7')
        .width(72).height('100%').backgroundColor('#4A4633')
        .border({ width: 1, color: 'rgba(240,229,199,0.12)' }).borderRadius(12)
        .onClick(() => { this.pinToTop(this.findCardIndex(card)) })
      Button('删除').fontSize(14).fontWeight(WEIGHT.semibold).fontColor('#F0D2C8')
        .width(72).height('100%').backgroundColor('#51342F')
        .border({ width: 1, color: 'rgba(240,210,200,0.12)' }).borderRadius(12)
        .margin({ left: 8 })
        .onClick(() => { this.deleteConfirmName = card.config.name })
    }
    .width(160).height('100%').padding({ left: 4, right: 4 })
    .alignItems(VerticalAlign.Center).backgroundColor('#151516')
    .borderRadius({ topRight: 12, bottomRight: 12 })
  }

  private findCardIndex(card: ProjectCardData): number {
    for (let i = 0; i < this.projects.length; i++) {
      if (this.projects[i].config.name === card.config.name) return i
    }
    return -1
  }

  build() {
    Stack() {
    Column() {
      // ====== Header: seamless with page bg, no border line ======
      Row() {
        Image($r('app.media.logo'))
          .width(28).height(28)
          .borderRadius(6)
          .margin({ right: 8 })
        Text('Serein').fontSize(22).fontWeight(700).fontColor('#D97757').fontFamily('monospace')
        Blank()
        Image($r('app.media.scan_icon'))
          .width(48).height(48)
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .onClick(() => { this.handleScanAddProject() })
        Image($r('app.media.nav_settings_active'))
          .width(48).height(48)
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .margin({ left: 2 })
          .onClick(() => { router.pushUrl({ url: NavPath.SETTINGS }) })
      }
      .width('100%').padding({ left: 16, right: 16, top: 44, bottom: 12 })
      .border({ width: { bottom: 1 }, color: 'rgba(255,255,255,0.05)' })

      // ====== Content ======
      if (this.loading) {
        LoadingProgress().width(36).height(36).color('#D97757').margin({ top: 24 })
      } else if (this.projects.length === 0) {
        Column() {
          Text('No projects').fontSize(16).fontColor('#C2C6D6').margin({ bottom: 16 })
          Button('+ Add Project').fontSize(16).height(44).fontColor('#1A1C20').backgroundColor('#D97757').borderRadius(6).onClick(() => { this.handleAddProject() })
        }.width('100%').margin({ top: 24 }).alignItems(HorizontalAlign.Center)
      } else {
        Refresh({
          refreshing: $$this.refreshing,
          builder: () => { this.projectPullRefreshIndicator() }
        }) {
          List() {
          // ====== Agent 状态总览卡片 ======
          ListItem() {
            this.agentOverviewCard()
          }
          .margin({ bottom: SPACE.md })

          // ====== 待审批预览卡片（有 pending 才显示）======
          ListItem() {
            this.pendingPreviewCard()
          }
          .margin({ bottom: SPACE.md })

          ForEach(this.projects, (card: ProjectCardData, idx: number) => {
            ListItem() { this.projectCard(card) }
            .margin({ bottom: 12 })
            .offset({ y: this.dragIdx === idx ? this.dragOffY : 0 })
            .zIndex(this.dragIdx === idx ? 99 : 1)
            .borderRadius(12)  // 匹配卡片圆角，拖拽边框跟随
            // 选中时阴影抬升 + 边框高亮（不用 scale——卡片顶满宽度，放大必溢出屏幕）
            .shadow(this.dragIdx === idx ? { radius: 24, color: 'rgba(217,119,87,0.40)', offsetX: 0, offsetY: 8 } : { radius: 0, color: 'transparent', offsetX: 0, offsetY: 0 })
            .border(this.dragIdx === idx ? { width: 2, color: '#D97757' } : { width: 0, color: 'transparent' })
            .animation({ duration: 200, curve: Curve.FastOutSlowIn })
            .transition(TransitionEffect.OPACITY.animation({ duration: 400, delay: idx * 60, curve: Curve.EaseOut })
              .combine(TransitionEffect.translate({ y: 8 }).animation({ duration: 400, delay: idx * 60, curve: Curve.EaseOut })))
            .swipeAction({
              end: {
                builder: () => { this.swipeActions(card) },
                actionAreaDistance: 160
              }
            })
            .gesture(
              GestureGroup(GestureMode.Sequence,
                LongPressGesture({ duration: 500 })
                  .onAction(() => {
                    this.dragIdx = idx; this.dragOffY = 0
                    // 长按选中震动反馈
                    try { vibrator.startVibration({ type: 'time', duration: 30 }, { id: 0, usage: 'touch' }) } catch (e) {}
                  }),
                PanGesture({ direction: PanDirection.Vertical, distance: 5 })
                  .onActionUpdate((event: GestureEvent) => {
                    if (this.dragIdx < 0) return
                    this.dragOffY = event.offsetY
                  })
                  .onActionEnd(() => {
                    if (this.dragIdx < 0) return
                    const dy = this.dragOffY
                    const h = 100
                    const slots = dy > 0 ? Math.floor(dy / h) : Math.ceil(dy / h)
                    const targetIdx = idx + slots
                    if (targetIdx !== idx && targetIdx >= 0 && targetIdx < this.projects.length) {
                      this.swapProjects(idx, targetIdx)
                      // 换位成功震动反馈
                      try { vibrator.startVibration({ type: 'time', duration: 50 }, { id: 0, usage: 'touch' }) } catch (e) {}
                    }
                    this.dragIdx = -1; this.dragOffY = 0
                  })
              )
            )
            }, (card: ProjectCardData) => card.config.name + '_' + this.displayedAgentType(card) + '_' +
              this.displayedRuntimeMode(card) + '_' + (this.hasDesktopSessions(card.config.name) ? 'desktop' : 'cli-only') + '_' +
              (card.agentRunning ? '1' : '0'))

            ListItem() {
              Column() {
                Column() { Text('+').fontSize(24).fontColor('#D97757') }
                .width(40).height(40).borderRadius(9999).backgroundColor('#32353A')
                .border({ width: 1, color: 'rgba(140,144,159,0.30)' }).justifyContent(FlexAlign.Center)
                Text('Add Project').fontSize(13).fontColor('#C2C6D6').fontWeight(600).margin({ top: 10 })
              }
              .width('100%').padding(20).alignItems(HorizontalAlign.Center)
              .backgroundColor('#161B22')
              .border({ width: 2, color: 'rgba(140,144,159,0.15)', style: BorderStyle.Dashed }).borderRadius(12)
              .onClick(() => { this.handleAddProject() })
          }.margin({ bottom: 90 })  // 底部导航栏 72vp + 余量，确保 Add Project 不被遮挡
        }
        .width('100%').layoutWeight(1).padding({ left: 16, right: 16 })
        }
        .onRefreshing(() => { this.doRefresh() })
      }
    }
    .width('100%').height('100%').backgroundColor('#0B0E12')
    .expandSafeArea([SafeAreaType.KEYBOARD, SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

    // ====== Add Dialog ======
    if (this.showAddDialog) {
      Column() {
        Column() {
          Text('New Project').fontSize(20).fontWeight(600).fontColor('#E1E2E8').fontFamily('monospace').margin({ bottom: 16 })
          TextInput({ text: this.newProjectName, placeholder: 'project name' }).fontSize(15).height(48)
            .backgroundColor('#0B0E12').borderRadius(6).border({ width: 1, color: 'rgba(140,144,159,0.15)' })
            .fontColor('#E1E2E8').placeholderColor('#8C909F').fontFamily('monospace')
            .margin({ bottom: 12 }).onChange((value: string) => { this.newProjectName = value })
          Text('默认 Agent').fontSize(12).fontColor('#8C909F').width('100%').margin({ bottom: 8 })
          Row() {
            Button('Claude Code').fontSize(12).height(38).layoutWeight(1)
              .fontColor(this.newProjectAgentType === 'claude' ? '#1A1C20' : '#C2C6D6')
              .backgroundColor(this.newProjectAgentType === 'claude' ? '#D97757' : 'rgba(39,42,47,0.60)')
              .border({ width: 1, color: this.newProjectAgentType === 'claude' ? '#D97757' : 'rgba(140,144,159,0.15)' })
              .borderRadius(6).onClick(() => { this.newProjectAgentType = 'claude' })
            Button('Codex').fontSize(12).height(38).layoutWeight(1).margin({ left: 8 })
              .fontColor(this.newProjectAgentType === 'codex' ? '#1A1C20' : '#C2C6D6')
              .backgroundColor(this.newProjectAgentType === 'codex' ? '#D97757' : 'rgba(39,42,47,0.60)')
              .border({ width: 1, color: this.newProjectAgentType === 'codex' ? '#D97757' : 'rgba(140,144,159,0.15)' })
              .borderRadius(6).onClick(() => { this.newProjectAgentType = 'codex' })
          }.width('100%').margin({ bottom: 16 })
          Row() {
            Button('Cancel').fontSize(15).height(44).layoutWeight(1).fontColor('#C2C6D6')
              .backgroundColor('rgba(39,42,47,0.60)').border({ width: 1, color: 'rgba(140,144,159,0.15)' }).borderRadius(6)
              .onClick(() => { animateTo({ duration: 200, curve: Curve.EaseIn }, () => { this.showAddDialog = false }) })
            Button('Create').fontSize(15).height(44).layoutWeight(1).fontColor('#1A1C20')
              .backgroundColor('#D97757').borderRadius(6).margin({ left: 8 })
              .onClick(() => { this.confirmAddProject() })
          }.width('100%')
        }
        .width('85%').padding(16)
        .backgroundColor('rgba(39,42,47,0.80)').backdropBlur(32)
        .borderRadius(12).border({ width: 1, color: 'rgba(217,119,87,0.30)' })
        .transition(TransitionEffect.scale({ x: 0.92, y: 0.92 }).combine(TransitionEffect.OPACITY).animation({ duration: 250, curve: Curve.FastOutSlowIn }))
      }
      .width('100%').height('100%').justifyContent(FlexAlign.Center).backgroundColor('rgba(0,0,0,0.65)')
      .onClick(() => { this.showAddDialog = false }).transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
    }

    if (this.deleteConfirmName !== '') {
      Column() {
        Column() {
          Text('Delete ' + this.deleteConfirmName + '?').fontSize(20).fontWeight(600).fontColor('#b53333').fontFamily('monospace').margin({ bottom: 4 })
          Text('This cannot be undone.').fontSize(15).fontColor('#C2C6D6').margin({ bottom: 16 })
          Row() {
            Button('Cancel').fontSize(15).height(44).layoutWeight(1).fontColor('#C2C6D6')
              .backgroundColor('rgba(39,42,47,0.60)').border({ width: 1, color: 'rgba(140,144,159,0.15)' }).borderRadius(6)
              .onClick(() => { this.deleteConfirmName = '' })
            Button('Delete').fontSize(15).height(44).layoutWeight(1).fontColor('#FFFFFF')
              .backgroundColor('#b53333').borderRadius(6).margin({ left: 8 })
              .onClick(() => { this.handleDeleteProject(this.deleteConfirmName) })
          }.width('100%')
        }
        .width('80%').padding(16)
        .backgroundColor('rgba(39,42,47,0.80)').backdropBlur(32)
        .borderRadius(12).border({ width: 1, color: 'rgba(181,51,51,0.30)' })
        .transition(TransitionEffect.scale({ x: 0.92, y: 0.92 }).combine(TransitionEffect.OPACITY).animation({ duration: 250, curve: Curve.FastOutSlowIn }))
      }
      .width('100%').height('100%').justifyContent(FlexAlign.Center).backgroundColor('rgba(0,0,0,0.65)').onClick(() => { this.deleteConfirmName = '' })
    }

    // 紧急刹车二次确认
    if (this.killAllConfirm) {
      Column() {
        Column() {
          Row() {
            Circle({ width: 12, height: 12 }).fill('#b53333')
              .shadow({ radius: 6, color: 'rgba(181,51,51,0.50)', offsetX: 0, offsetY: 0 })
            Text('紧急刹车').fontSize(20).fontWeight(700).fontColor('#b53333').fontFamily('monospace').margin({ left: SPACE.sm, bottom: 4 })
          }.width('100%').justifyContent(FlexAlign.Center)
          Text('将立即杀掉所有 Agent 进程并清空命令队列。')
            .fontSize(11).fontColor('#C2C6D6').margin({ bottom: 16 })
            .textAlign(TextAlign.Center).maxLines(1)
          Row() {
            Button('取消').fontSize(15).height(44).layoutWeight(1).fontColor('#C2C6D6')
              .backgroundColor('rgba(39,42,47,0.60)').border({ width: 1, color: 'rgba(140,144,159,0.15)' }).borderRadius(6)
              .onClick(() => { this.killAllConfirm = false })
            Button('确认刹车').fontSize(15).height(44).layoutWeight(1).fontColor('#0B0E12').fontWeight(700)
              .backgroundColor('#b53333').borderRadius(6).margin({ left: 8 })
              .onClick(() => { this.handleKillAll() })
          }.width('100%')
        }
        .width('80%').padding(16)
        .backgroundColor('rgba(39,42,47,0.80)').backdropBlur(32)
        .borderRadius(12).border({ width: 1, color: 'rgba(181,51,51,0.30)' })
        .transition(TransitionEffect.scale({ x: 0.92, y: 0.92 }).combine(TransitionEffect.OPACITY).animation({ duration: 250, curve: Curve.FastOutSlowIn }))
      }
      .width('100%').height('100%').justifyContent(FlexAlign.Center).backgroundColor('rgba(0,0,0,0.65)').onClick(() => { this.killAllConfirm = false })
    }
    } // Stack
  }

  /** Agent 在线状态：任一项目 agentRunning 即在线 */
  private anyAgentRunning(): boolean {
    for (let i = 0; i < this.projects.length; i++) {
      if (this.projects[i].agentRunning) return true
    }
    return false
  }

  /** 在线项目名（取第一个 running 的）*/
  private runningProjectName(): string {
    for (let i = 0; i < this.projects.length; i++) {
      if (this.projects[i].agentRunning) return this.projects[i].config.name
    }
    return ''
  }

  /** GPU 名称精简：'NVIDIA GeForce RTX 3060 Ti' → 'RTX 3060 Ti' */
  private gpuShortName(): string {
    return this.shortGpu(this.hwGpu)
  }

  /** CPU 精简：'12th Gen Intel(R) Core(TM) i5-12490F' → 'i5-12490F' */
  private shortCpu(): string {
    if (this.hwCpu === '') return ''
    // 提取 i5/i7/i9/Rygen 之类核心型号
    const m = this.hwCpu.match(/i[3579]-\w+/i)
    if (m) return m[0]
    return this.hwCpu.replace(/^.*Core\(TM\)\s*/i, '').replace(/\(R\)/g, '').replace(/\(TM\)/g, '').trim()
  }

  /** RAM 精简：'4x 8GB Gloway ...' → '4x8G DDR4' */
  private shortRam(): string {
    if (this.hwRam === '') return ''
    // hwRam 格式 "4x 8GB Gloway ..."，提取条数x容量
    const m = this.hwRam.match(/(\d+)x\s*(\d+)GB/i)
    if (m) return m[1] + 'x' + m[2] + 'G DDR4'
    return this.hwRam
  }

  /** GPU 精简：'NVIDIA GeForce RTX 3060 Ti' → 'RTX 3060 Ti' */
  private shortGpu(name: string): string {
    if (name === '') return ''
    return name.replace(/^NVIDIA\s+/i, '').replace(/^GeForce\s+/i, '')
  }

  /** DISK 精简：保持完整（型号短） */
  private shortDisk(): string {
    return this.hwDisk
  }

  // ====== 硬件监控总览卡片（无子框，纯内容平铺）======
  @Builder
  emergencyBrakeBar() {
    Row() {
      Column() {
        Text('安全控制').fontSize(TYPO.caption.size).fontWeight(WEIGHT.semibold).fontColor('#D99A83')
        Text('紧急刹车').fontSize(TYPO.body.size).fontWeight(WEIGHT.bold).fontColor('#F0E5C7').margin({ top: 1 })
      }.alignItems(HorizontalAlign.Start)
      Blank()
      if (this.killAllSending) {
        LoadingProgress().width(20).height(20).color('#D97757')
      } else {
        Text('STOP ALL').fontSize(TYPO.caption.size).fontWeight(WEIGHT.bold).letterSpacing(0.8).fontColor('#F0C8BC')
      }
    }
    .width('100%').height(54).padding({ left: SPACE.md, right: SPACE.md })
    .backgroundColor('rgba(112,53,43,0.34)')
    .border({ width: 1, color: 'rgba(217,119,87,0.38)' })
    .borderRadius(RADIUS.md)
    .onClick(() => { this.killAllConfirm = true })
  }

  @Builder
  agentOverviewCard() {
    Column() {
      // 监控数据 2x2（无独立框，直接平铺，用间距区分）
      Row() {
        Column() { MetricTile({ label: 'CPU', value: this.fmtNum(this.cpuPct) + '%', sub: this.shortCpu(), pct: this.cpuPct, spark: this.cpuSpark, temp: this.cpuTemp > 0 ? this.cpuTemp + '°C' : '' }) }.layoutWeight(1).height('100%')
        Column() { MetricTile({ label: 'RAM', value: this.fmtNum(this.memUsedGb, ' GB'), sub: this.shortRam(), pct: this.memPct, spark: this.memSpark, temp: '' }) }.layoutWeight(1).height('100%').margin({ left: SPACE.md })
      }.width('100%').layoutWeight(1)
      Row() {
        Column() { MetricTile({ label: 'DISK', value: this.fmtNum(this.diskUsedGb, ' GB'), sub: this.shortDisk(), pct: this.diskPct, spark: [], temp: "" }) }.layoutWeight(1).height('100%')
        Column() { MetricTile({ label: 'GPU', value: this.fmtNum(this.gpuPct) + '%', sub: (this.gpuShortName() !== '' ? this.gpuShortName() + ' · ' : '') + this.fmtNum(this.gpuMemUsedGb, 'GB') + '/' + this.fmtNum(this.gpuMemTotalGb, 'GB'), pct: this.gpuPct, spark: this.gpuSpark, temp: this.gpuTemp > 0 ? this.gpuTemp + '°C' : '' }) }.layoutWeight(1).height('100%').margin({ left: SPACE.md })
      }.width('100%').layoutWeight(1).margin({ top: SPACE.sm })

      // Kill Switch（无独立框，分隔线 + 一行文字按钮）
      if (this.monitoringAlertCount > 0) {
      Row().width('100%').height(1).backgroundColor('rgba(140,144,159,0.10)').margin({ top: SPACE.md })
      Row() {
        Text('监控告警').fontSize(TYPO.bodySmall.size).fontWeight(WEIGHT.semibold).fontColor('#C2C6D6')
        Blank()
        Text(this.monitoringAlertCount > 0 ? this.monitoringAlertCount + ' 项需要关注' : '正常')
          .fontSize(TYPO.caption.size).fontColor(this.monitoringAlertCount > 0 ? '#D99A83' : '#8C909F')
      }
      .width('100%').height(38)
      .onClick(() => { router.pushUrl({ url: NavPath.MONITORING_ALERTS }) })
      }

      if (false) {
      Row().width('100%').height(1).backgroundColor('rgba(140,144,159,0.10)').margin({ top: SPACE.md })
      Row() {
        Circle({ width: 10, height: 10 }).fill('#b53333')
          .shadow({ radius: 5, color: 'rgba(181,51,51,0.50)', offsetX: 0, offsetY: 0 })
        Text('紧急刹车').fontSize(TYPO.bodySmall.size).fontWeight(WEIGHT.semibold)
          .fontColor('#b53333').margin({ left: SPACE.xs })
        Blank()
        if (this.killAllSending) {
          LoadingProgress().width(16).height(16).color('#b53333')
        } else {
          Text('STOP ALL').fontSize(TYPO.caption.size).fontWeight(WEIGHT.bold)
            .fontColor('#b53333').letterSpacing(1).opacity(0.8)
        }
      }
      .width('100%').padding({ top: SPACE.sm, bottom: 4 })
      .onClick(() => { this.killAllConfirm = true })
      }
    }
    .width('100%').aspectRatio(1).padding(SPACE.md)
    .justifyContent(FlexAlign.SpaceBetween)
    .backgroundColor('#161B22')
    .border({ width: 1, color: 'rgba(217,119,87,0.45)' })
    .borderRadius(RADIUS.lg)
  }

  // ====== 待审批预览卡片 ======
  @Builder
  pendingPreviewCard() {
    Column() {
      // 标题行
      Row() {
        Circle({ width: 10, height: 10 }).fill('#d97730')
          .shadow({ radius: 5, color: 'rgba(217,119,48,0.50)', offsetX: 0, offsetY: 0 })
        Text(this.pendingCount + ' 个待审批')
          .fontSize(TYPO.bodySmall.size).fontWeight(WEIGHT.bold).fontColor('#d97730')
          .margin({ left: SPACE.xs })
        Blank()
        Text('查看全部')
          .fontSize(TYPO.caption.size).fontColor('#8C909F')
      }.width('100%').alignItems(VerticalAlign.Center)
      .onClick(() => { router.pushUrl({ url: NavPath.APPROVALS }) })

      // 预览条目（最多 2 条）
      ForEach(this.pendingPreview, (item: ApprovalRecord) => {
        Row() {
          Circle({ width: 7, height: 7 }).fill(this.riskTextColor(item.risk_level))
          Text(item.command.length > 40 ? item.command.substring(0, 40) + '…' : item.command)
            .fontSize(TYPO.caption.size).fontColor('#C2C6D6').fontFamily('monospace')
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1).margin({ left: SPACE.xs })
          Text(this.riskLabel(item.risk_level))
            .fontSize(10).fontColor(this.riskTextColor(item.risk_level))
        }
        .width('100%').padding({ top: 6, bottom: 6 })
      }, (item: ApprovalRecord) => item.id)
    }
    .width('100%').padding(SPACE.md)
    .backgroundColor('rgba(217,119,48,0.04)')
    .border({ width: 1, color: 'rgba(217,119,48,0.15)' })
    .borderRadius(RADIUS.md)
    .onClick(() => { router.pushUrl({ url: NavPath.APPROVALS }) })
  }

  private riskDot(level: string): string {
    if (level === 'red') return '!'
    if (level === 'yellow') return '?'
    return '-'
  }
  private riskLabel(level: string): string {
    if (level === 'red') return '高风险'
    if (level === 'yellow') return '中风险'
    return '低风险'
  }
  private riskTextColor(level: string): string {
    if (level === 'red') return '#b53333'
    if (level === 'yellow') return '#d97730'
    return '#8C909F'
  }

  // ═══════ Metric Tile 见文件末尾 @Component MetricTile ═══════

  @Builder
  launchChoice(card: ProjectCardData, title: string, subtitle: string,
    runtimeMode: ProjectRuntimeMode, agentType: AgentType, available: boolean) {
    Column() {
      Text(title).fontSize(10).fontWeight(WEIGHT.semibold)
        .fontColor(available ? '#E1E2E8' : '#777C8A').maxLines(1)
      Text(subtitle).fontSize(9).fontColor(available ? '#C98B75' : '#686D78')
        .margin({ top: 4 }).maxLines(1)
    }
    .width('31.5%').height(62).padding({ left: 8, right: 8, top: 10, bottom: 8 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(available ? 'rgba(217,119,87,0.075)' : 'rgba(140,144,159,0.05)')
    .border({ width: 1, color: available ? 'rgba(217,119,87,0.22)' : 'rgba(140,144,159,0.10)' })
    .borderRadius(8).opacity(available ? 1 : 0.65).enabled(available)
    .onClick(() => { this.chooseProjectLaunch(card, runtimeMode, agentType) })
  }

  @Builder
  projectCard(card: ProjectCardData) {
    // ====== Stitch: glass-surface metallic-border p-md rounded-xl ======
    Column() {
      // First row: project + status
      Row() {
        Text(card.config.name)
          .fontSize(13).fontWeight(500).fontColor(card.agentRunning ? '#D97757' : '#C2C6D6').fontFamily('monospace')
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor(card.agentRunning ? 'rgba(217,119,87,0.08)' : 'rgba(140,144,159,0.08)')
          .borderRadius(4).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: '42%' })

        Row() {
          Circle({ width: 7, height: 7 }).fill(card.agentRunning ? '#17a34a' : '#8C909F')
          Text(card.agentRunning ? 'Online' : 'Offline')
            .fontSize(10).fontWeight(700).fontColor(card.agentRunning ? '#17a34a' : '#8C909F')
            .letterSpacing(0.5).margin({ left: 6 })
        }
        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
        .backgroundColor(card.agentRunning ? 'rgba(23,163,74,0.10)' : 'rgba(140,144,159,0.10)')
        .border({ width: 1, color: card.agentRunning ? 'rgba(23,163,74,0.20)' : 'rgba(140,144,159,0.15)' })
        .borderRadius(9999).margin({ left: 8 })
        Blank()
      }
      .width('100%').alignItems(VerticalAlign.Center)

      // Second row: launch entry and CLI Agent are separate concepts.
      Row() {
        Row() {
          if (this.isRuntimeModeSaving(card.config.name)) {
            Text('保存中…').fontSize(10).fontWeight(700).fontColor('#B7BAC4')
          } else if (this.hasDesktopSessions(card.config.name)) {
            Text('CLI').fontSize(10).fontWeight(700)
              .fontColor(this.displayedRuntimeMode(card) === 'cli' ? '#D99A83' : '#777C8A')
            Text('/').fontSize(9).fontColor('#555B66').margin({ left: 6, right: 6 })
            Text('桌面').fontSize(10).fontWeight(700)
              .fontColor(this.displayedRuntimeMode(card) === 'desktop' ? '#D99A83' : '#777C8A')
          } else {
            Text('CLI').fontSize(10).fontWeight(700).fontColor('#B7BAC4')
          }
        }
        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
        // 外层胶囊始终保持中性底色；CLI / 桌面只通过各自文字的选中色区分。
        // 避免切到桌面时整颗胶囊变成珊瑚色，而 CLI 状态只有文字变色。
        .backgroundColor('rgba(140,144,159,0.10)')
        .border({ width: 1, color: 'rgba(140,144,159,0.18)' })
        .borderRadius(9999)
        .opacity(this.hasDesktopSessions(card.config.name) ? 1 : 0.72)
        .enabled(false)

        Row() {
          Text(this.displayedRuntimeMode(card) === 'desktop' ? 'Codex Desktop'
            : (this.isAgentTypeSaving(card.config.name) ? '保存中…' : agentDisplayName(this.displayedAgentType(card))))
            .fontSize(10).fontWeight(700)
            .fontColor(card.agentRunning ? '#E1E2E8' : '#D97757').fontFamily('monospace')
        }
        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
        .backgroundColor(card.agentRunning ? 'rgba(140,144,159,0.10)' : 'rgba(217,119,87,0.12)')
        .border({ width: 1, color: card.agentRunning ? 'rgba(140,144,159,0.18)' : 'rgba(217,119,87,0.28)' })
        .borderRadius(9999)
        .enabled(!card.agentRunning && this.displayedRuntimeMode(card) === 'cli' &&
          !this.isStarting(card.config.name) && !this.isStopping(card.config.name) && !this.isAgentTypeSaving(card.config.name))
        .onClick(() => { this.toggleProjectAgent(card) })
      }
      .width('100%').justifyContent(FlexAlign.SpaceBetween).margin({ top: 10 })

      // Both buttons always visible
      Row() {
        Button(this.isStopping(card.config.name) ? 'Stopping…' : 'Stop').fontSize(13).height(46).fontWeight(600).layoutWeight(1)
          .fontColor(card.agentRunning ? '#C8A487' : '#8C909F')
          .backgroundColor(card.agentRunning ? 'rgba(200,164,135,0.10)' : 'rgba(50,53,58,0.40)')
          .border({ width: 1, color: card.agentRunning ? 'rgba(200,164,135,0.24)' : 'rgba(140,144,159,0.08)' })
          .borderRadius(8).enabled(card.agentRunning && !this.isStopping(card.config.name) && !this.isStarting(card.config.name))
          .onClick(() => { if (card.agentRunning) { this.handleAgentStop(card.config.name, card.config.backendUrl) } })

        Button(this.isStarting(card.config.name) ? 'Starting...' : 'Start').fontSize(13).height(46).fontWeight(600).layoutWeight(1)
          .fontColor(card.agentRunning ? '#8C909F' : '#1A1C20')
          .backgroundColor(card.agentRunning ? 'rgba(50,53,58,0.40)' : '#D97757')
          .border(card.agentRunning ? { width: 1, color: 'rgba(140,144,159,0.08)' } : {})
          .borderRadius(8).margin({ left: 8 })
          .enabled(!card.agentRunning && !this.isStarting(card.config.name) && !this.isStopping(card.config.name) &&
            !this.isAgentTypeSaving(card.config.name) && !this.isRuntimeModeSaving(card.config.name))
          .onClick(() => { if (!card.agentRunning) this.handleAgentStart(card.config.name, card.config.backendUrl, this.displayedAgentType(card)) })
      }.width('100%').margin({ top: 18 })
    }
        .width('100%').constraintSize({ minHeight: 166 }).padding({ left: 20, right: 20, top: 14, bottom: 14 })
    .backgroundColor('#161B22')
    .border({ width: 1, color: 'rgba(140,144,159,0.15)' }).borderRadius(12)
  }
}

@Entry
@Component
struct ProjectsPage {
  build() {
    Stack() {
      ProjectsContent()
    }
  }
}
