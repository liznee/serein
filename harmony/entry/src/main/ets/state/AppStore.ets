import PrefStore from '../store/PrefStore'

// ===== AppStorage 键名常量 =====
// 所有页面/组件通过 AppStorage 读写全局状态，避免 prop drilling

/** 后端地址 */
export const KEY_BACKEND_URL = 'backendUrl'
/** CLIENT_TOKEN（空 = 未配对） */
export const KEY_CLIENT_TOKEN = 'clientToken'
/** 设备 ID（配对后获取） */
export const KEY_DEVICE_ID = 'deviceId'
/** 设备名 */
export const KEY_DEVICE_NAME = 'deviceName'
/** 轮询是否激活 */
export const KEY_POLLING_ACTIVE = 'pollingActive'
/** 当前 pending 数量（角标用） */
export const KEY_PENDING_COUNT = 'pendingCount'
/** 后端权限申请数量 */
export const KEY_APPROVAL_PENDING_COUNT = 'approvalPendingCount'
/** 当前进程中实时接收的 Agent 提问 */
export const KEY_PENDING_AGENT_QUESTIONS = 'pendingAgentQuestions'
/** 未处理 Agent 提问数量 */
export const KEY_PENDING_AGENT_QUESTION_COUNT = 'pendingAgentQuestionCount'
/** 最近网络错误消息（UI 红条用） */
export const KEY_LAST_ERROR = 'lastError'
/** 后端连接状态（UI 指示器用） */
export const KEY_CONNECTED = 'connected'
/** 连续失败次数（指数退避用） */
export const KEY_FAIL_STREAK = 'failStreak'

/**
 * 应用启动初始化
 * 从 Preferences 装载配置到 AppStorage
 * 必须在 EntryAbility.onCreate 中调用
 */
export async function bootstrap(): Promise<void> {
  const config = await PrefStore.loadAll()

  AppStorage.setOrCreate(KEY_BACKEND_URL, config.backendUrl)
  AppStorage.setOrCreate(KEY_CLIENT_TOKEN, config.clientToken)
  AppStorage.setOrCreate(KEY_DEVICE_ID, config.deviceId)
  AppStorage.setOrCreate(KEY_DEVICE_NAME, config.deviceName)
  AppStorage.setOrCreate(KEY_POLLING_ACTIVE, false)
  AppStorage.setOrCreate(KEY_PENDING_COUNT, 0)
  AppStorage.setOrCreate(KEY_APPROVAL_PENDING_COUNT, 0)
  AppStorage.setOrCreate(KEY_PENDING_AGENT_QUESTIONS, '[]')
  AppStorage.setOrCreate(KEY_PENDING_AGENT_QUESTION_COUNT, 0)
  AppStorage.setOrCreate(KEY_LAST_ERROR, '')
  AppStorage.setOrCreate(KEY_CONNECTED, false)
  AppStorage.setOrCreate(KEY_FAIL_STREAK, 0)
  AppStorage.setOrCreate('pushKitDeliveryActive', false)
  // 预创建所有 @StorageLink 键，避免 Tabs 组件启动时崩溃
  AppStorage.setOrCreate('switchToTerminal', false)
  AppStorage.setOrCreate('terminalActivationSeq', 0)
  AppStorage.setOrCreate('triggerNotificationJump', false)
  AppStorage.setOrCreate('terminalProject', '')
  AppStorage.setOrCreate('terminalAgentType', 'claude')
  AppStorage.setOrCreate('terminalRuntimeMode', 'cli')
  AppStorage.setOrCreate('terminalStartMsg', '')
  AppStorage.setOrCreate('notificationLaunch', false)
  AppStorage.setOrCreate('notificationProject', '')
  AppStorage.setOrCreate('currentProject', '')
  AppStorage.setOrCreate('sharedCommandText', '')
  AppStorage.setOrCreate('codexDesktopEventType', '')
  AppStorage.setOrCreate('codexDesktopEvent', '')
  AppStorage.setOrCreate('codexDesktopError', '')
  AppStorage.setOrCreate('codexDesktopProject', '')
  AppStorage.setOrCreate('codexDesktopThreads', [])
  AppStorage.setOrCreate('codexDesktopLoading', false)
  AppStorage.setOrCreate('codexDesktopStarting', false)
  AppStorage.setOrCreate('codexDesktopRefreshSeq', 0)
  AppStorage.setOrCreate('codexDesktopActive', null)
  AppStorage.setOrCreate('codexDesktopApproval', '')
  AppStorage.setOrCreate('openCodexDesktopPanel', false)
  // 诊断日志：token 加载状态
  if (config.clientToken !== '') {
    console.info('serein: bootstrap token loaded OK (len=' + config.clientToken.length + ')')
  } else {
    console.info('serein: bootstrap token empty — pairing via QR scan needed')
  }
}

/** 判断是否已配对（有有效 clientToken） */
export function isLoggedIn(): boolean {
  const token = AppStorage.get<string>(KEY_CLIENT_TOKEN)
  return token !== undefined && token !== ''
}

/** 判断是否已配置后端地址（无配对也可进入应用，配对通过扫码 QR 完成） */
export function hasBackendUrl(): boolean {
  const url = AppStorage.get<string>(KEY_BACKEND_URL)
  return url !== undefined && url !== ''
}

/**
 * 检查并清除错误标记
 * 用于 401 场景：清除 token 并返回 true
 */
export function handleAuthError(): boolean {
  AppStorage.setOrCreate(KEY_CLIENT_TOKEN, '')
  AppStorage.setOrCreate(KEY_LAST_ERROR, '认证失效，请重新扫码配对')
  return false
}
