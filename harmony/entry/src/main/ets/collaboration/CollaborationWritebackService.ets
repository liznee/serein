import type {
  CollaborationAccount, CollaborationRecord, CollaborationState, CollaborationWorkItem,
  PullRequestDraft, RemoteRepository, WorkLabel, WritebackAudit
} from '../model/collaboration/CollaborationModels'
import { collaborationPendingCount } from '../model/collaboration/CollaborationModels'
import CollaborationCredentialStore from '../store/CollaborationCredentialStore'
import CollaborationStore from '../store/CollaborationStore'
import { getCollaborationProvider } from './ProviderRegistry'

interface WritebackContext {
  state: CollaborationState
  record: CollaborationRecord
  item: CollaborationWorkItem
  repository: RemoteRepository
  account: CollaborationAccount
  token: string
}

export class CollaborationWritebackService {
  private async saveState(state: CollaborationState): Promise<void> {
    await CollaborationStore.save(state)
    AppStorage.setOrCreate('collaborationPendingCount', collaborationPendingCount(state))
  }

  private async context(recordId: string, itemId: string): Promise<WritebackContext> {
    const state = await CollaborationStore.load()
    const record = state.records.find((value: CollaborationRecord) => value.id === recordId)
    const item = state.workItems.find((value: CollaborationWorkItem) => value.id === itemId)
    if (!record || !item) throw new Error('协作记录或工作项不存在')
    if (record.workItemId !== item.id) throw new Error('协作记录与工作项不匹配')
    const repository = state.repositories.find((value: RemoteRepository) => value.id === item.repositoryId)
    if (!repository) throw new Error('仓库不存在')
    const account = state.accounts.find((value: CollaborationAccount) => value.id === repository.accountId)
    if (!account) throw new Error('平台账号不存在')
    if (!account.writeEnabled) throw new Error('请先单独启用受控写回权限')
    const token = await CollaborationCredentialStore.load(account.id)
    if (token === '') throw new Error('平台授权已失效，请重新授权')
    return { state: state, record: record, item: item, repository: repository, account: account, token: token }
  }

  private failedAudit(ctx: WritebackContext, operation: string, error: string): WritebackAudit {
    const now = Date.now()
    return {
      id: ctx.account.provider + ':' + operation + ':' + now,
      provider: ctx.account.provider,
      accountId: ctx.account.id,
      repositoryId: ctx.repository.id,
      workItemId: ctx.item.id,
      operation: operation,
      summary: operation,
      confirmedAt: now,
      completedAt: now,
      success: false,
      error: error.substring(0, 300),
    }
  }

  async publishReply(recordId: string, itemId: string, confirmed: boolean): Promise<void> {
    if (!confirmed) throw new Error('发布回复必须经过用户确认')
    const ctx = await this.context(recordId, itemId)
    if (!ctx.account.capabilities.publishComment) throw new Error('当前平台不支持从 Serein 发布评论')
    const draft = ctx.record.replyDraft.trim()
    if (draft === '' || draft.length > 32000) throw new Error('回复草稿为空或过长')
    const provider = getCollaborationProvider(ctx.account.provider)
    try {
      const audit = await provider.publishComment(ctx.token, ctx.repository, ctx.item, draft)
      ctx.state.writebackAudits.unshift(audit)
      ctx.record.state = 'replied'
      ctx.record.updatedAt = Date.now()
      await this.saveState(ctx.state)
    } catch (e) {
      ctx.state.writebackAudits.unshift(this.failedAudit(ctx, 'publish_comment', (e as Error).message))
      await this.saveState(ctx.state)
      throw e as Error
    }
  }

  async closeIssue(recordId: string, itemId: string, confirmed: boolean): Promise<void> {
    if (!confirmed) throw new Error('关闭 Issue 必须经过用户确认')
    const ctx = await this.context(recordId, itemId)
    if (ctx.item.kind !== 'issue' || !ctx.account.capabilities.closeIssue) {
      throw new Error('当前工作项不支持关闭操作')
    }
    const provider = getCollaborationProvider(ctx.account.provider)
    try {
      const audit = await provider.updateIssueState(ctx.token, ctx.repository, ctx.item, 'closed')
      ctx.state.writebackAudits.unshift(audit)
      ctx.item.state = 'closed'
      ctx.record.state = 'closed'
      ctx.record.updatedAt = Date.now()
      await this.saveState(ctx.state)
    } catch (e) {
      ctx.state.writebackAudits.unshift(this.failedAudit(ctx, 'close_issue', (e as Error).message))
      await this.saveState(ctx.state)
      throw e as Error
    }
  }

  async reopenIssue(recordId: string, itemId: string, confirmed: boolean): Promise<void> {
    if (!confirmed) throw new Error('重新打开 Issue 必须经过用户确认')
    const ctx = await this.context(recordId, itemId)
    if (ctx.item.kind !== 'issue' || !ctx.account.capabilities.reopenIssue) {
      throw new Error('当前工作项不支持重新打开')
    }
    const provider = getCollaborationProvider(ctx.account.provider)
    try {
      const audit = await provider.updateIssueState(ctx.token, ctx.repository, ctx.item, 'open')
      ctx.state.writebackAudits.unshift(audit)
      ctx.item.state = 'open'
      ctx.record.state = ctx.record.replyDraft === '' ? 'completed' : 'draft_ready'
      ctx.record.updatedAt = Date.now()
      await this.saveState(ctx.state)
    } catch (e) {
      ctx.state.writebackAudits.unshift(this.failedAudit(ctx, 'reopen_issue', (e as Error).message))
      await this.saveState(ctx.state)
      throw e as Error
    }
  }

  async updateLabels(recordId: string, itemId: string, labels: string[], confirmed: boolean): Promise<void> {
    if (!confirmed) throw new Error('修改标签必须经过用户确认')
    const ctx = await this.context(recordId, itemId)
    if (ctx.item.kind !== 'issue' || !ctx.account.capabilities.labels) throw new Error('当前工作项不支持标签操作')
    if (labels.length > 20) throw new Error('标签数量过多')
    const cleaned: string[] = []
    for (let i = 0; i < labels.length; i++) {
      const value = labels[i].trim()
      if (value === '' || value.length > 100) throw new Error('标签内容无效')
      cleaned.push(value)
    }
    const provider = getCollaborationProvider(ctx.account.provider)
    try {
      const audit = await provider.updateLabels(ctx.token, ctx.repository, ctx.item, cleaned)
      ctx.state.writebackAudits.unshift(audit)
      const workLabels: WorkLabel[] = []
      for (let i = 0; i < cleaned.length; i++) workLabels.push({ name: cleaned[i], color: '' })
      ctx.item.labels = workLabels
      ctx.record.updatedAt = Date.now()
      await this.saveState(ctx.state)
    } catch (e) {
      ctx.state.writebackAudits.unshift(this.failedAudit(ctx, 'update_labels', (e as Error).message))
      await this.saveState(ctx.state)
      throw e as Error
    }
  }

  async createPullRequest(recordId: string, itemId: string, draft: PullRequestDraft,
    confirmed: boolean): Promise<string> {
    if (!confirmed) throw new Error('创建 PR/MR 必须经过用户确认')
    const ctx = await this.context(recordId, itemId)
    if (!ctx.account.capabilities.createPullRequest) throw new Error('当前平台不支持创建 PR/MR')
    const title = draft.title.trim()
    const head = draft.head.trim()
    const base = draft.base.trim()
    if (title === '' || title.length > 1000) throw new Error('PR/MR 标题为空或过长')
    if (!this.validBranch(head) || !this.validBranch(base)) throw new Error('源分支或目标分支无效')
    const sanitized: PullRequestDraft = {
      title: title,
      body: draft.body.substring(0, 32000),
      head: head,
      base: base,
      draft: draft.draft,
    }
    const provider = getCollaborationProvider(ctx.account.provider)
    try {
      const result = await provider.createPullRequest(ctx.token, ctx.repository, sanitized)
      ctx.state.writebackAudits.unshift(result.audit)
      const existing = ctx.state.workItems.findIndex((value: CollaborationWorkItem) => value.id === result.item.id)
      if (existing >= 0) ctx.state.workItems[existing] = result.item
      else ctx.state.workItems.unshift(result.item)
      ctx.record.updatedAt = Date.now()
      await this.saveState(ctx.state)
      return result.item.id
    } catch (e) {
      ctx.state.writebackAudits.unshift(this.failedAudit(ctx, 'create_pull_request', (e as Error).message))
      await this.saveState(ctx.state)
      throw e as Error
    }
  }

  async mergePullRequest(recordId: string, itemId: string, method: string,
    confirmed: boolean): Promise<void> {
    if (!confirmed) throw new Error('合并 PR/MR 必须经过用户确认')
    const ctx = await this.context(recordId, itemId)
    if (ctx.item.kind !== 'pull_request' || !ctx.account.capabilities.mergePullRequest) {
      throw new Error('当前工作项不支持合并')
    }
    if (method !== 'merge' && method !== 'squash' && method !== 'rebase') throw new Error('合并方式无效')
    const provider = getCollaborationProvider(ctx.account.provider)
    try {
      const audit = await provider.mergePullRequest(ctx.token, ctx.repository, ctx.item, method)
      ctx.state.writebackAudits.unshift(audit)
      ctx.item.state = 'merged'
      ctx.record.updatedAt = Date.now()
      await this.saveState(ctx.state)
    } catch (e) {
      ctx.state.writebackAudits.unshift(this.failedAudit(ctx, 'merge_pull_request', (e as Error).message))
      await this.saveState(ctx.state)
      throw e as Error
    }
  }

  async rerunBuild(recordId: string, itemId: string, confirmed: boolean): Promise<void> {
    if (!confirmed) throw new Error('重跑构建必须经过用户确认')
    const ctx = await this.context(recordId, itemId)
    if (ctx.item.kind !== 'build' || !ctx.account.capabilities.rerunBuild) {
      throw new Error('当前平台没有可用的安全重跑接口')
    }
    const provider = getCollaborationProvider(ctx.account.provider)
    try {
      const audit = await provider.rerunBuild(ctx.token, ctx.repository, ctx.item)
      ctx.state.writebackAudits.unshift(audit)
      ctx.item.state = 'running'
      ctx.item.unread = false
      ctx.record.updatedAt = Date.now()
      await this.saveState(ctx.state)
    } catch (e) {
      ctx.state.writebackAudits.unshift(this.failedAudit(ctx, 'rerun_failed_build', (e as Error).message))
      await this.saveState(ctx.state)
      throw e as Error
    }
  }

  private validBranch(value: string): boolean {
    if (value === '' || value.length > 255 || value.startsWith('-') || value.endsWith('.') ||
      value.endsWith('/') || value.indexOf('..') >= 0 || value.indexOf('@{') >= 0 || value.indexOf('\\') >= 0) {
      return false
    }
    for (let i = 0; i < value.length; i++) {
      const code = value.charCodeAt(i)
      if (code <= 32 || code === 127 || value[i] === '~' || value[i] === '^' || value[i] === ':' ||
        value[i] === '?' || value[i] === '*' || value[i] === '[') return false
    }
    return true
  }
}

export default new CollaborationWritebackService()
