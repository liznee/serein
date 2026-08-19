import type {
  CollaborationAccount, CollaborationRecord, CollaborationState, CollaborationWorkItem, ProviderKind,
  ProviderNotification, RemoteRepository, RepositoryBinding, StarSnapshot, WritebackAudit
} from '../model/collaboration/CollaborationModels'
import { collaborationPendingCount, workItemKey } from '../model/collaboration/CollaborationModels'
import CollaborationCredentialStore from '../store/CollaborationCredentialStore'
import CollaborationStore from '../store/CollaborationStore'
import { getCollaborationProvider } from './ProviderRegistry'
import HttpClient from '../api/HttpClient'

const MAX_REPOSITORY_PAGES = 10
const REPOSITORIES_PER_PAGE = 50

export class CollaborationSyncService {
  async finishAuthorization(providerKind: ProviderKind, accessToken: string,
    scopes: string[], writeEnabled: boolean = false, privateReposEnabled: boolean = false): Promise<CollaborationAccount> {
    const provider = getCollaborationProvider(providerKind)
    const account = await provider.getAuthenticatedAccount(accessToken)
    account.scopes = scopes
    account.privateReposEnabled = privateReposEnabled
    account.writeEnabled = writeEnabled
    account.lastSyncAt = Date.now()

    await CollaborationCredentialStore.save(account.id, accessToken)
    try {
      const state = await CollaborationStore.load()
      state.accounts = state.accounts.filter((item: CollaborationAccount) => item.id !== account.id)
      state.accounts.push(account)
      await CollaborationStore.save(state)
    } catch (e) {
      await CollaborationCredentialStore.remove(account.id)
      throw e as Error
    }
    return account
  }

  async removeAccount(accountId: string): Promise<void> {
    const state = await CollaborationStore.load()
    const repositoryIds: string[] = []
    for (let i = 0; i < state.repositories.length; i++) {
      if (state.repositories[i].accountId === accountId) repositoryIds.push(state.repositories[i].id)
    }
    const scopes: string[] = []
    for (let i = 0; i < state.records.length; i++) {
      const record = state.records[i]
      if (repositoryIds.indexOf(record.repositoryId) >= 0 && record.workScope !== '' &&
        scopes.indexOf(record.workScope) < 0) scopes.push(record.workScope)
    }
    for (let i = 0; i < scopes.length; i++) {
      try {
        await HttpClient.delete<Object>('/collaboration/result?scope=' + encodeURIComponent(scopes[i]))
      } catch (_) {}
    }
    state.accounts = state.accounts.filter((account: CollaborationAccount) => account.id !== accountId)
    state.repositories = state.repositories.filter((repo: RemoteRepository) => repo.accountId !== accountId)
    state.trackedRepositoryIds = state.trackedRepositoryIds.filter((id: string) => repositoryIds.indexOf(id) < 0)
    state.workItems = state.workItems.filter((item: CollaborationWorkItem) => repositoryIds.indexOf(item.repositoryId) < 0)
    state.bindings = state.bindings.filter((binding: RepositoryBinding) => repositoryIds.indexOf(binding.repositoryId) < 0)
    state.records = state.records.filter((record: CollaborationRecord) => repositoryIds.indexOf(record.repositoryId) < 0)
    state.starSnapshots = state.starSnapshots.filter((snapshot: StarSnapshot) => repositoryIds.indexOf(snapshot.repositoryId) < 0)
    state.writebackAudits = state.writebackAudits.filter((audit: WritebackAudit) => repositoryIds.indexOf(audit.repositoryId) < 0)
    // Remove the credential first. If the following cache write fails the old
    // account metadata may remain visible, but no usable provider Token remains.
    await CollaborationCredentialStore.remove(accountId)
    await CollaborationStore.save(state)
    this.updatePendingCount(state)
  }

  async clearAllData(): Promise<void> {
    try {
      const state = await CollaborationStore.load()
      const scopes: string[] = []
      for (let i = 0; i < state.records.length; i++) {
        const scope = state.records[i].workScope
        if (scope !== '' && scopes.indexOf(scope) < 0) scopes.push(scope)
      }
      for (let i = 0; i < scopes.length; i++) {
        try {
          await HttpClient.delete<Object>('/collaboration/result?scope=' + encodeURIComponent(scopes[i]))
        } catch (_) {}
      }
    } catch (_) {}
    await CollaborationCredentialStore.clearAll()
    await CollaborationStore.clear()
    AppStorage.setOrCreate('collaborationPendingCount', 0)
  }

  async setTracked(repositoryId: string, tracked: boolean): Promise<void> {
    const state = await CollaborationStore.load()
    const index = state.trackedRepositoryIds.indexOf(repositoryId)
    if (tracked && index < 0) state.trackedRepositoryIds.push(repositoryId)
    if (!tracked && index >= 0) state.trackedRepositoryIds.splice(index, 1)
    await CollaborationStore.save(state)
  }

  async syncAll(): Promise<CollaborationState> {
    const state = await CollaborationStore.load()
    let allNotifications: ProviderNotification[] = []
    for (let i = 0; i < state.accounts.length; i++) {
      const account = state.accounts[i]
      const token = await CollaborationCredentialStore.load(account.id)
      if (token === '') continue
      const provider = getCollaborationProvider(account.provider)

      const repositories: RemoteRepository[] = []
      let page = 1
      while (page <= MAX_REPOSITORY_PAGES) {
        const result = await provider.listRepositories(token, account.id, {
          page: page, perPage: REPOSITORIES_PER_PAGE,
          includePrivate: account.privateReposEnabled,
        })
        repositories.push(...result.items)
        if (!result.hasMore) break
        page = result.nextPage
      }
      state.repositories = state.repositories.filter((repo: RemoteRepository) => repo.accountId !== account.id)
      state.repositories.push(...repositories)

      try {
        const notifications = await provider.listNotifications(token, account.id, 1)
        allNotifications = allNotifications.concat(notifications.items)
      } catch (_) {
        // 权限不足时保留旧数据，不伪造“无通知”。
      }
      account.lastSyncAt = Date.now()
    }

    const targetIds = this.syncTargetRepositoryIds(state, allNotifications)
    const syncedItems: CollaborationWorkItem[] = []
    for (let i = 0; i < state.repositories.length; i++) {
      const repository = state.repositories[i]
      if (targetIds.indexOf(repository.id) < 0) continue
      const account = this.findAccount(state, repository.accountId)
      if (!account) continue
      const token = await CollaborationCredentialStore.load(account.id)
      if (token === '') continue
      const provider = getCollaborationProvider(repository.provider)
      try {
        const metrics = await provider.getRepositoryMetrics(token, repository)
        repository.openIssues = metrics.openIssuesAvailable ? metrics.openIssues : -1
        repository.openPullRequests = metrics.openPullRequestsAvailable ? metrics.openPullRequests : -1
        repository.buildState = metrics.buildStateAvailable ? metrics.buildState : 'unknown'
      } catch (_) {
        repository.openIssues = -1
        repository.openPullRequests = -1
        repository.buildState = 'unknown'
      }
      const work = await provider.listWorkItems(token, repository,
        { page: 1, perPage: 50, state: 'open', since: '' })
      for (let j = 0; j < work.items.length; j++) syncedItems.push(work.items[j])
    }

    this.applyNotifications(syncedItems, allNotifications)
    const preserved = state.workItems.filter((item: CollaborationWorkItem) => {
      if (targetIds.indexOf(item.repositoryId) < 0) return true
      const hasRecord = state.records.find((record: CollaborationRecord) => record.workItemId === item.id) !== undefined
      const refreshed = syncedItems.find((value: CollaborationWorkItem) => value.id === item.id) !== undefined
      return hasRecord && !refreshed
    })
    state.workItems = syncedItems.concat(preserved)
    state.starSnapshots = this.captureStarSnapshots(state.starSnapshots, state.repositories)
    state.lastSyncAt = Date.now()
    await CollaborationStore.save(state)
    this.updatePendingCount(state)
    return state
  }

  async loadWorkItemDetails(itemId: string): Promise<CollaborationWorkItem> {
    const state = await CollaborationStore.load()
    const item = state.workItems.find((value: CollaborationWorkItem) => value.id === itemId)
    if (!item) throw new Error('工作项不存在')
    const repository = state.repositories.find((value: RemoteRepository) => value.id === item.repositoryId)
    if (!repository) throw new Error('仓库不存在')
    const account = this.findAccount(state, repository.accountId)
    if (!account) throw new Error('账号不存在')
    const token = await CollaborationCredentialStore.load(account.id)
    const provider = getCollaborationProvider(repository.provider)
    const detail = await provider.getWorkItem(token, repository, item)
    if (item.kind !== 'build') {
      const comments = await provider.listComments(token, repository, detail, 1)
      detail.comments = comments.items
      detail.commentsCount = Math.max(detail.commentsCount, comments.items.length)
    }
    const index = state.workItems.findIndex((value: CollaborationWorkItem) => value.id === item.id)
    if (index >= 0) state.workItems[index] = detail
    await CollaborationStore.save(state)
    return detail
  }

  private syncTargetRepositoryIds(state: CollaborationState,
    notifications: ProviderNotification[]): string[] {
    const ids: string[] = state.trackedRepositoryIds.slice()
    for (let i = 0; i < state.bindings.length; i++) {
      if (ids.indexOf(state.bindings[i].repositoryId) < 0) ids.push(state.bindings[i].repositoryId)
    }
    for (let i = 0; i < notifications.length; i++) {
      if (notifications[i].unread && ids.indexOf(notifications[i].repositoryId) < 0) ids.push(notifications[i].repositoryId)
    }
    return ids
  }

  private applyNotifications(items: CollaborationWorkItem[], notifications: ProviderNotification[]): void {
    for (let i = 0; i < notifications.length; i++) {
      const notification = notifications[i]
      const id = workItemKey(notification.provider, notification.repositoryId,
        notification.number, notification.kind)
      const item = items.find((value: CollaborationWorkItem) => value.id === id)
      if (item) {
        item.unread = notification.unread
        item.mentioned = notification.reason === 'mention' || notification.reason === 'team_mention' ||
          notification.reason === 'referer'
      }
    }
  }

  private captureStarSnapshots(existing: StarSnapshot[], repositories: RemoteRepository[]): StarSnapshot[] {
    const snapshots = existing.slice()
    const now = Date.now()
    for (let i = 0; i < repositories.length; i++) {
      const latest = snapshots.find((value: StarSnapshot) => value.repositoryId === repositories[i].id)
      if (latest && latest.stars === repositories[i].stars && now - latest.capturedAt < 6 * 60 * 60 * 1000) continue
      snapshots.unshift({ repositoryId: repositories[i].id, stars: repositories[i].stars, capturedAt: now })
    }
    return snapshots.slice(0, 1000)
  }

  private findAccount(state: CollaborationState, accountId: string): CollaborationAccount | undefined {
    return state.accounts.find((item: CollaborationAccount) => item.id === accountId)
  }

  private updatePendingCount(state: CollaborationState): void {
    AppStorage.setOrCreate('collaborationPendingCount', collaborationPendingCount(state))
  }
}

export default new CollaborationSyncService()
