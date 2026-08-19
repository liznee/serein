import { preferences } from '@kit.ArkData'
import { decryptSecret, deleteSecretKey, encryptSecret } from './TokenCipher'
import type { CollaborationState } from '../model/collaboration/CollaborationModels'
import { emptyCollaborationState } from '../model/collaboration/CollaborationModels'
import type { ProviderCapabilities } from '../model/collaboration/CollaborationModels'

const PREF_NAME = 'SEREIN_collaboration_cache'
const KEY_STATE = 'encrypted_state_v1'
const HUKS_ALIAS = 'serein.collaboration.cache.v1'
const MAX_WORK_ITEMS = 300
const MAX_RECORDS = 300
const MAX_AUDITS = 200
const MAX_SNAPSHOTS = 1000

/** 协作数据加密缓存。私有仓库标题、Issue 正文和评论不会以明文写入 Preferences。 */
export class CollaborationStore {
  private static instance: CollaborationStore
  private context?: Context
  private prefs?: preferences.Preferences

  static getInstance(): CollaborationStore {
    if (!CollaborationStore.instance) CollaborationStore.instance = new CollaborationStore()
    return CollaborationStore.instance
  }

  init(context: Context): void { this.context = context }

  private async getPrefs(): Promise<preferences.Preferences> {
    if (!this.context) throw new Error('CollaborationStore 未初始化')
    if (!this.prefs) this.prefs = await preferences.getPreferences(this.context, PREF_NAME)
    return this.prefs
  }

  async load(): Promise<CollaborationState> {
    const p = await this.getPrefs()
    const encrypted = (p.getSync(KEY_STATE, '') as string) ?? ''
    if (encrypted === '') return emptyCollaborationState()
    const plain = await decryptSecret(encrypted, HUKS_ALIAS)
    const parsed = JSON.parse(plain) as CollaborationState
    if (parsed.version !== 1) throw new Error('不支持的协作缓存版本')
    if (!parsed.accounts) parsed.accounts = []
    if (!parsed.repositories) parsed.repositories = []
    if (!parsed.trackedRepositoryIds) parsed.trackedRepositoryIds = []
    if (!parsed.workItems) parsed.workItems = []
    if (!parsed.bindings) parsed.bindings = []
    if (!parsed.records) parsed.records = []
    if (!parsed.starSnapshots) parsed.starSnapshots = []
    if (!parsed.writebackAudits) parsed.writebackAudits = []
    for (let i = 0; i < parsed.accounts.length; i++) {
      if (!parsed.accounts[i].scopes) parsed.accounts[i].scopes = []
      if (typeof parsed.accounts[i].privateReposEnabled !== 'boolean') parsed.accounts[i].privateReposEnabled = false
      if (typeof parsed.accounts[i].writeEnabled !== 'boolean') parsed.accounts[i].writeEnabled = false
      parsed.accounts[i].capabilities = this.migrateCapabilities(
        parsed.accounts[i].provider, parsed.accounts[i].capabilities)
    }
    for (let i = 0; i < parsed.records.length; i++) {
      if (!parsed.records[i].workScope) parsed.records[i].workScope = ''
      if (!parsed.records[i].rawResult) parsed.records[i].rawResult = ''
      if (!parsed.records[i].replyDraft) parsed.records[i].replyDraft = ''
    }
    for (let i = 0; i < parsed.workItems.length; i++) {
      if (!parsed.workItems[i].externalId) parsed.workItems[i].externalId = parsed.workItems[i].number
    }
    return parsed
  }

  private migrateCapabilities(provider: string, existing?: ProviderCapabilities): ProviderCapabilities {
    return {
      repositories: existing?.repositories ?? true,
      issues: existing?.issues ?? true,
      comments: existing?.comments ?? true,
      pullRequests: existing?.pullRequests ?? true,
      builds: existing?.builds ?? true,
      notifications: existing?.notifications ?? true,
      publishComment: existing?.publishComment ?? true,
      labels: existing?.labels ?? true,
      closeIssue: existing?.closeIssue ?? true,
      reopenIssue: existing?.reopenIssue ?? true,
      createPullRequest: existing?.createPullRequest ?? true,
      mergePullRequest: existing?.mergePullRequest ?? true,
      pullRequestChanges: existing?.pullRequestChanges ?? true,
      rerunBuild: existing?.rerunBuild ?? provider === 'github',
    }
  }

  async save(state: CollaborationState): Promise<void> {
    const bounded: CollaborationState = {
      version: 1,
      accounts: state.accounts,
      repositories: state.repositories,
      trackedRepositoryIds: state.trackedRepositoryIds,
      workItems: state.workItems.slice(0, MAX_WORK_ITEMS),
      bindings: state.bindings,
      records: state.records.slice(0, MAX_RECORDS),
      starSnapshots: state.starSnapshots.slice(0, MAX_SNAPSHOTS),
      writebackAudits: state.writebackAudits.slice(0, MAX_AUDITS),
      lastSyncAt: state.lastSyncAt,
    }
    const plain = JSON.stringify(bounded)
    const encrypted = await encryptSecret(plain, HUKS_ALIAS)
    const p = await this.getPrefs()
    await p.put(KEY_STATE, encrypted)
    await p.flush()
  }

  async clear(): Promise<void> {
    const p = await this.getPrefs()
    await p.put(KEY_STATE, '')
    await p.flush()
    await deleteSecretKey(HUKS_ALIAS)
  }
}

export default CollaborationStore.getInstance()
