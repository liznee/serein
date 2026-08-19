import { preferences } from '@kit.ArkData'
import { encryptToken, decryptToken } from './TokenCipher'

// ===== 持久化存储键名 =====
const PREF_NAME = 'SEREIN_prefs'
const KEY_BACKEND_URL = 'backend_url'
const KEY_CLIENT_TOKEN = 'client_token'
const KEY_DEVICE_ID = 'device_id'
const KEY_DEVICE_NAME = 'device_name'
const KEY_PROJECTS = 'projects' // JSON 数组字符串
const KEY_THEME = 'term_theme'
const KEY_FONT_SIZE = 'term_font_size'
const KEY_SNIPPETS = 'term_snippets'
const KEY_WORKFLOWS = 'term_workflows'
const KEY_VERBOSITY = 'term_verbosity'
const KEY_PIN_ENABLED = 'pin_enabled'
const KEY_PIN_HASH = 'pin_hash'
const KEY_HIDDEN_PROJECTS = 'hidden_projects'  // 用户已删除的远程项目黑名单
const KEY_PERMISSION_MODE = 'permission_mode'
const KEY_TERM_SESSION_PREFIX = 'term_session_'
// session 数据最大行数（限制持久化大小）
const MAX_SAVED_SESSION_LINES = 500

/** 默认后端地址（用户自己的服务器，用户在设置页可修改） */
// 不连接任何第三方默认服务；首次使用必须扫描或输入用户自己的后端。
const DEFAULT_BACKEND_URL = ''

/** 配置快照（启动时读一次写入 AppStorage） */
export interface ConfigSnapshot {
  backendUrl: string
  clientToken: string
  deviceId: string
  deviceName: string
  projects: ProjectConfig[]
}

/** 项目配置 */
export interface ProjectConfig {
  name: string       // 用户自定义项目名
  backendUrl: string // 后端地址
  agentType?: AgentType // 每个项目独立选择 Claude Code / Codex；旧数据默认 Claude
  runtimeMode?: ProjectRuntimeMode // CLI 或真实 Codex Desktop 会话；旧数据默认 CLI
}

/** 当前正式支持的 Agent 类型。 */
export type AgentType = 'claude' | 'codex'
export type ProjectRuntimeMode = 'cli' | 'desktop'

/** 兼容旧版配置和异常输入，任何未知值都安全回退到 Claude Code。 */
export function normalizeAgentType(value?: string): AgentType {
  return value === 'codex' ? 'codex' : 'claude'
}

export function agentDisplayName(value?: string): string {
  return normalizeAgentType(value) === 'codex' ? 'Codex' : 'Claude Code'
}

export function normalizeProjectRuntimeMode(value?: string): ProjectRuntimeMode {
  return value === 'desktop' ? 'desktop' : 'cli'
}

/** 命令片段 */
export interface Snippet {
  name: string
  command: string
}

/** Workflow 单步 */
export interface WorkflowStep {
  command: string
  description: string
}

/** Workflow 模板 */
export interface WorkflowTemplate {
  name: string
  description: string
  steps: WorkflowStep[]
}

/**
 * Preferences 封装 — 集中持久化逻辑
 * 使用前必须调用 init(context)
 */
export class PrefStore {
  private static instance: PrefStore
  private prefs?: preferences.Preferences
  private context?: Context

  static getInstance(): PrefStore {
    if (!PrefStore.instance) {
      PrefStore.instance = new PrefStore()
    }
    return PrefStore.instance
  }

  /** 必须在 EntryAbility.onCreate 中调用 */
  init(context: Context): void {
    this.context = context
  }

  /** 懒加载 preferences 实例 */
  private async getPrefs(): Promise<preferences.Preferences> {
    if (!this.context) {
      throw new Error('PrefStore 未初始化，请先调用 init(context)')
    }
    if (!this.prefs) {
      this.prefs = await preferences.getPreferences(this.context, PREF_NAME)
    }
    return this.prefs
  }

  /** 启动时装载所有配置（token 使用 HUKS 解密） */
  async loadAll(): Promise<ConfigSnapshot> {
    const p = await this.getPrefs()
    const backendUrl = (p.getSync(KEY_BACKEND_URL, DEFAULT_BACKEND_URL) as string) ?? DEFAULT_BACKEND_URL
    const encryptedToken = (p.getSync(KEY_CLIENT_TOKEN, '') as string) ?? ''
    const clientToken = await decryptToken(encryptedToken)
    // 早期版本在 HUKS 不可用时可能保存 __plain: 兼容数据。后续启动时一旦
    // HUKS 恢复可用，立即迁移回加密格式，避免明文兼容状态长期存在。
    if (clientToken !== '' && encryptedToken.startsWith('__plain:')) {
      try {
        const migrated = await encryptToken(clientToken)
        const verified = await decryptToken(migrated)
        if (verified !== clientToken) {
          throw new Error('HUKS migration verification failed')
        }
        await p.put(KEY_CLIENT_TOKEN, migrated)
        await p.flush()
        console.info('serein: plaintext token migrated to HUKS')
      } catch (e) {
        console.warn('serein: plaintext token migration deferred: ' + (e as Error).message)
      }
    }
    const deviceId = (p.getSync(KEY_DEVICE_ID, '') as string) ?? ''
    const deviceName = (p.getSync(KEY_DEVICE_NAME, '') as string) ?? ''
    const projectsJson = (p.getSync(KEY_PROJECTS, '[]') as string) ?? '[]'
    let projects: ProjectConfig[] = []
    try {
      projects = JSON.parse(projectsJson) as ProjectConfig[]
      // agentType 是后加字段；在内存中补默认值，保证所有调用方行为一致。
      const normalized: ProjectConfig[] = []
      for (let i = 0; i < projects.length; i++) {
        const item = projects[i]
        normalized.push({
          name: item.name,
          backendUrl: item.backendUrl,
          agentType: normalizeAgentType(item.agentType),
          runtimeMode: normalizeProjectRuntimeMode(item.runtimeMode),
        })
      }
      projects = normalized
    } catch (e) {
      projects = []
    }
    return { backendUrl, clientToken, deviceId, deviceName, projects }
  }

  /** 保存配对信息（token 使用 HUKS 加密后存储，HUKS 不可用时降级明文） */
  async saveToken(token: string, deviceId: string, deviceName: string): Promise<void> {
    const p = await this.getPrefs()
    let encrypted: string
    try {
      encrypted = await encryptToken(token)
      const verified = await decryptToken(encrypted)
      if (verified !== token) {
        throw new Error('HUKS round-trip verification failed')
      }
    } catch (e) {
      // HUKS 加密失败时降级为明文存储（带前缀标记），避免 token 丢失导致重复弹二维码
      console.warn('serein: HUKS encrypt failed, using plaintext fallback: ' + (e as Error).message)
      encrypted = '__plain:' + token
    }
    await p.put(KEY_CLIENT_TOKEN, encrypted)
    await p.put(KEY_DEVICE_ID, deviceId)
    await p.put(KEY_DEVICE_NAME, deviceName)
    await p.flush()
  }

  /** 保存后端地址 */
  async saveBackendUrl(url: string): Promise<void> {
    const p = await this.getPrefs()
    await p.put(KEY_BACKEND_URL, url)
    await p.flush()
  }

  /** 清除配对信息（解除绑定） */
  async clearToken(): Promise<void> {
    const p = await this.getPrefs()
    await p.put(KEY_CLIENT_TOKEN, '')
    await p.put(KEY_DEVICE_ID, '')
    await p.put(KEY_DEVICE_NAME, '')
    await p.flush()
  }

  /** 保存项目列表 */
  async saveProjects(projects: ProjectConfig[]): Promise<void> {
    const p = await this.getPrefs()
    const normalized: ProjectConfig[] = []
    for (let i = 0; i < projects.length; i++) {
      normalized.push({
        name: projects[i].name,
        backendUrl: projects[i].backendUrl,
        agentType: normalizeAgentType(projects[i].agentType),
        runtimeMode: normalizeProjectRuntimeMode(projects[i].runtimeMode),
      })
    }
    await p.put(KEY_PROJECTS, JSON.stringify(normalized))
    await p.flush()
  }

  /** 校验项目名合法性（字符集 + 长度限制，防止 Preferences key 注入） */
  static validateProjectName(name: string): void {
    if (typeof name !== 'string' || name.length === 0) {
      throw new Error('项目名不能为空')
    }
    if (name.length > 64) {
      throw new Error('项目名不能超过 64 个字符')
    }
    if (!/^[a-zA-Z0-9_-]+$/.test(name)) {
      throw new Error('项目名只允许字母、数字、下划线和连字符')
    }
  }

  /** 添加项目（去重，含名称校验） */
  async addProject(proj: ProjectConfig): Promise<void> {
    PrefStore.validateProjectName(proj.name)
    const snapshot = await this.loadAll()
    const exists = snapshot.projects.some((p: ProjectConfig) => p.name === proj.name)
    if (!exists) {
      const normalized: ProjectConfig = {
        name: proj.name,
        backendUrl: proj.backendUrl,
        agentType: normalizeAgentType(proj.agentType),
        runtimeMode: normalizeProjectRuntimeMode(proj.runtimeMode),
      }
      await this.saveProjects(snapshot.projects.concat([normalized]))
    }
  }

  /** 修改项目默认 Agent；远程发现的项目也会在本地持久化。 */
  async updateProjectAgentType(name: string, agentType: string, backendUrl: string): Promise<void> {
    PrefStore.validateProjectName(name)
    const snapshot = await this.loadAll()
    const normalizedType = normalizeAgentType(agentType)
    const updated: ProjectConfig[] = []
    let found = false
    for (let i = 0; i < snapshot.projects.length; i++) {
      const item = snapshot.projects[i]
      if (item.name === name) {
        updated.push({
          name: item.name,
          backendUrl: item.backendUrl,
          agentType: normalizedType,
          runtimeMode: normalizeProjectRuntimeMode(item.runtimeMode),
        })
        found = true
      } else {
        updated.push(item)
      }
    }
    if (!found) {
      updated.push({ name: name, backendUrl: backendUrl, agentType: normalizedType, runtimeMode: 'cli' })
    }
    await this.saveProjects(updated)
  }

  /** 修改项目启动方式；是否真的支持 Desktop 仍由本机真实会话能力决定。 */
  async updateProjectRuntimeMode(name: string, runtimeMode: string, backendUrl: string): Promise<void> {
    PrefStore.validateProjectName(name)
    const snapshot = await this.loadAll()
    const normalizedMode = normalizeProjectRuntimeMode(runtimeMode)
    const updated: ProjectConfig[] = []
    let found = false
    for (let i = 0; i < snapshot.projects.length; i++) {
      const item = snapshot.projects[i]
      if (item.name === name) {
        updated.push({
          name: item.name,
          backendUrl: item.backendUrl,
          agentType: normalizeAgentType(item.agentType),
          runtimeMode: normalizedMode,
        })
        found = true
      } else {
        updated.push(item)
      }
    }
    if (!found) {
      updated.push({ name: name, backendUrl: backendUrl, agentType: 'claude', runtimeMode: normalizedMode })
    }
    await this.saveProjects(updated)
  }

  /** 删除项目（同时加入隐藏列表，防止远程项目重新出现） */
  async removeProject(name: string): Promise<void> {
    PrefStore.validateProjectName(name)
    const snapshot = await this.loadAll()
    snapshot.projects = snapshot.projects.filter((p: ProjectConfig) => p.name !== name)
    await this.saveProjects(snapshot.projects)
    // 加入隐藏列表，防止 /agent/projects 远程合并时重新出现
    await this.addHiddenProject(name)
  }

  /** 添加隐藏项目 */
  async addHiddenProject(name: string): Promise<void> {
    const p = await this.getPrefs()
    const raw = (p.getSync(KEY_HIDDEN_PROJECTS, '[]') as string) ?? '[]'
    let hidden: string[] = []
    try { hidden = JSON.parse(raw) as string[] } catch { hidden = [] }
    if (hidden.indexOf(name) < 0) {
      hidden.push(name)
      await p.put(KEY_HIDDEN_PROJECTS, JSON.stringify(hidden))
      await p.flush()
    }
  }

  /** 加载隐藏项目列表 */
  async loadHiddenProjects(): Promise<string[]> {
    const p = await this.getPrefs()
    const raw = (p.getSync(KEY_HIDDEN_PROJECTS, '[]') as string) ?? '[]'
    try { return JSON.parse(raw) as string[] } catch { return [] }
  }

  // ═══ 终端主题 / 字号 / 片段 ═══

  async loadTheme(): Promise<string> {
    const p = await this.getPrefs()
    return (p.getSync(KEY_THEME, 'dark') as string) ?? 'dark'
  }
  async saveTheme(theme: string): Promise<void> {
    const p = await this.getPrefs()
    await p.put(KEY_THEME, theme)
    await p.flush()
  }
  async loadFontSize(): Promise<number> {
    const p = await this.getPrefs()
    return (p.getSync(KEY_FONT_SIZE, 13) as number) ?? 13
  }
  async saveFontSize(size: number): Promise<void> {
    const p = await this.getPrefs()
    await p.put(KEY_FONT_SIZE, size)
    await p.flush()
  }
  async loadSnippets(): Promise<Snippet[]> {
    const p = await this.getPrefs()
    const raw = (p.getSync(KEY_SNIPPETS, '[]') as string) ?? '[]'
    try { return JSON.parse(raw) as Snippet[] } catch (e) { return [] }
  }
  async saveSnippets(snippets: Snippet[]): Promise<void> {
    const p = await this.getPrefs()
    await p.put(KEY_SNIPPETS, JSON.stringify(snippets))
    await p.flush()
  }

  // ═══ Workflow 模板 ═══

  async loadWorkflows(): Promise<WorkflowTemplate[]> {
    const p = await this.getPrefs()
    const raw = (p.getSync(KEY_WORKFLOWS, '[]') as string) ?? '[]'
    try { return JSON.parse(raw) as WorkflowTemplate[] } catch (e) { return [] }
  }

  async saveWorkflows(workflows: WorkflowTemplate[]): Promise<void> {
    const p = await this.getPrefs()
    await p.put(KEY_WORKFLOWS, JSON.stringify(workflows))
    await p.flush()
  }

  // ═══ PIN 保护 ═══

  async loadPinEnabled(): Promise<boolean> {
    const p = await this.getPrefs()
    const v = p.getSync(KEY_PIN_ENABLED, false) as boolean
    return v ?? false
  }
  async savePinEnabled(enabled: boolean): Promise<void> {
    const p = await this.getPrefs()
    await p.put(KEY_PIN_ENABLED, enabled)
    await p.flush()
  }
  async loadPinHash(): Promise<string> {
    const p = await this.getPrefs()
    return (p.getSync(KEY_PIN_HASH, '') as string) ?? ''
  }
  async savePinHash(hash: string): Promise<void> {
    const p = await this.getPrefs()
    await p.put(KEY_PIN_HASH, hash)
    await p.flush()
  }

  // ═══ 权限模式 ═══

  async loadPermissionMode(): Promise<string | null> {
    const p = await this.getPrefs()
    const mode = p.getSync(KEY_PERMISSION_MODE, '') as string
    return mode ?? null
  }
  async savePermissionMode(mode: string): Promise<void> {
    const p = await this.getPrefs()
    await p.put(KEY_PERMISSION_MODE, mode)
    await p.flush()
  }

  // ═══ 终端显示分级 ═══
  async loadVerbosity(): Promise<number> {
    const p = await this.getPrefs()
    const v = p.getSync(KEY_VERBOSITY, 2) as number
    return v ?? 2
  }
  async saveVerbosity(level: number): Promise<void> {
    const p = await this.getPrefs()
    await p.put(KEY_VERBOSITY, level)
    await p.flush()
  }

  // ═══ 命令历史（按项目持久化） ═══

  private histKey(proj: string): string {
    // 防御性过滤：仅保留允许的字符集，兼容旧数据中可能存在的未校验项目名
    const safe = proj.replace(/[^a-zA-Z0-9_-]/g, '_')
    return 'cmd_hist_' + safe
  }

  async loadCmdHistory(proj: string): Promise<string[]> {
    const p = await this.getPrefs()
    const raw = (p.getSync(this.histKey(proj), '[]') as string) ?? '[]'
    try { return JSON.parse(raw) as string[] } catch (e) { return [] }
  }
  async saveCmdHistory(proj: string, history: string[]): Promise<void> {
    const p = await this.getPrefs()
    // 仅保留最近 200 条，防止无限增长
    const trimmed = history.length > 200 ? history.slice(history.length - 200) : history
    await p.put(this.histKey(proj), JSON.stringify(trimmed))
    await p.flush()
  }

  /** 清除指定项目的全部命令历史 */
  async clearCmdHistory(proj: string): Promise<void> {
    const p = await this.getPrefs()
    await p.put(this.histKey(proj), '[]')
    await p.flush()
  }

  // ═══ 终端会话持久化（切换 tab 不丢失） ═══

  /** 保存项目终端会话数据（行内容 + 会话状态） */
  async saveTermSession(proj: string, data: Record<string, Object>): Promise<void> {
    const p = await this.getPrefs()
    const safe = proj.replace(/[^a-zA-Z0-9_-]/g, '_')
    // 限制行数防止过大
    const lines = (data['lines'] as Record<string, Object>[] ?? [])
    if (lines.length > MAX_SAVED_SESSION_LINES) {
      data['lines'] = lines.slice(lines.length - MAX_SAVED_SESSION_LINES)
    }
    await p.put(KEY_TERM_SESSION_PREFIX + safe, JSON.stringify(data))
    await p.flush()
  }

  /** 加载项目终端会话数据，不存在返回 null */
  async loadTermSession(proj: string): Promise<Record<string, Object> | null> {
    const p = await this.getPrefs()
    const safe = proj.replace(/[^a-zA-Z0-9_-]/g, '_')
    const raw = (p.getSync(KEY_TERM_SESSION_PREFIX + safe, '') as string) ?? ''
    if (raw === '') return null
    try { return JSON.parse(raw) as Record<string, Object> } catch (e) { return null }
  }

  /** 清除项目的终端会话数据 */
  async clearTermSession(proj: string): Promise<void> {
    const p = await this.getPrefs()
    const safe = proj.replace(/[^a-zA-Z0-9_-]/g, '_')
    await p.put(KEY_TERM_SESSION_PREFIX + safe, '')
    await p.flush()
  }

  // ═══ E2E 加密密钥持久化 ═══

  /** 保存项目的 E2E 加密密钥（AES-256 key, base64 编码） */
  async saveE2EKey(project: string, key: string): Promise<void> {
    const p = await this.getPrefs()
    await p.put('e2e_key_' + project, key)
    await p.flush()
  }

  /** 加载项目的 E2E 加密密钥，返回 null 表示未配置 */
  async loadE2EKey(project: string): Promise<string | null> {
    const p = await this.getPrefs()
    const key = (p.getSync('e2e_key_' + project, '') as string) ?? ''
    return key !== '' ? key : null
  }

  /** 清除项目的 E2E 加密密钥 */
  async clearE2EKey(project: string): Promise<void> {
    const p = await this.getPrefs()
    await p.put('e2e_key_' + project, '')
    await p.flush()
  }
}

export default PrefStore.getInstance()
