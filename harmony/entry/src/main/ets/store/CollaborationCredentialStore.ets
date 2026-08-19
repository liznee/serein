import { preferences } from '@kit.ArkData'
import { decryptSecret, deleteSecretKey, encryptSecret } from './TokenCipher'

const PREF_NAME = 'SEREIN_collaboration_credentials'
const KEY_INDEX = 'credential_index'
const TOKEN_PREFIX = 'credential_'
const HUKS_ALIAS = 'serein.collaboration.credentials.v1'

/**
 * 平台凭证安全仓储。只返回调用 Provider 所需的短生命周期明文，UI 不得直接使用。
 * HUKS 不可用时保存失败，不允许明文降级。
 */
export class CollaborationCredentialStore {
  private static instance: CollaborationCredentialStore
  private context?: Context
  private prefs?: preferences.Preferences

  static getInstance(): CollaborationCredentialStore {
    if (!CollaborationCredentialStore.instance) {
      CollaborationCredentialStore.instance = new CollaborationCredentialStore()
    }
    return CollaborationCredentialStore.instance
  }

  init(context: Context): void {
    this.context = context
  }

  private async getPrefs(): Promise<preferences.Preferences> {
    if (!this.context) throw new Error('CollaborationCredentialStore 未初始化')
    if (!this.prefs) {
      this.prefs = await preferences.getPreferences(this.context, PREF_NAME)
    }
    return this.prefs
  }

  private safeId(id: string): string {
    if (!id || id.length > 160 || !/^[a-zA-Z0-9:_.-]+$/.test(id)) {
      throw new Error('非法协作账号 ID')
    }
    return id.replace(/[:.-]/g, '_')
  }

  private async loadIndex(): Promise<string[]> {
    const p = await this.getPrefs()
    const raw = (p.getSync(KEY_INDEX, '[]') as string) ?? '[]'
    try { return JSON.parse(raw) as string[] } catch (_) { return [] }
  }

  async save(accountId: string, accessToken: string): Promise<void> {
    if (!accessToken || accessToken.length > 8192) throw new Error('平台 Token 无效')
    const p = await this.getPrefs()
    const encrypted = await encryptSecret(accessToken, HUKS_ALIAS)
    const verified = await decryptSecret(encrypted, HUKS_ALIAS)
    if (verified !== accessToken) throw new Error('平台 Token 安全存储校验失败')

    await p.put(TOKEN_PREFIX + this.safeId(accountId), encrypted)
    const index = await this.loadIndex()
    if (index.indexOf(accountId) < 0) index.push(accountId)
    await p.put(KEY_INDEX, JSON.stringify(index))
    await p.flush()
  }

  async load(accountId: string): Promise<string> {
    const p = await this.getPrefs()
    const encrypted = (p.getSync(TOKEN_PREFIX + this.safeId(accountId), '') as string) ?? ''
    if (encrypted === '') return ''
    return decryptSecret(encrypted, HUKS_ALIAS)
  }

  async remove(accountId: string): Promise<void> {
    const p = await this.getPrefs()
    await p.put(TOKEN_PREFIX + this.safeId(accountId), '')
    const index = (await this.loadIndex()).filter((id: string) => id !== accountId)
    await p.put(KEY_INDEX, JSON.stringify(index))
    await p.flush()
    if (index.length === 0) await deleteSecretKey(HUKS_ALIAS)
  }

  async clearAll(): Promise<void> {
    const p = await this.getPrefs()
    const index = await this.loadIndex()
    for (let i = 0; i < index.length; i++) {
      await p.put(TOKEN_PREFIX + this.safeId(index[i]), '')
    }
    await p.put(KEY_INDEX, '[]')
    await p.flush()
    await deleteSecretKey(HUKS_ALIAS)
  }
}

export default CollaborationCredentialStore.getInstance()

