/** 协作中心统一领域模型。页面只能依赖这些字段，不能依赖平台原始 JSON。 */

export type ProviderKind = 'github' | 'gitee'
export type WorkItemKind = 'issue' | 'pull_request' | 'build'
export type WorkItemState = 'open' | 'closed' | 'merged' | 'success' | 'failed' | 'running' | 'unknown'
export type WorkRecordState =
  'queued' | 'working' | 'completed' | 'reproduced' | 'fixed' | 'failed' | 'draft_ready' | 'replied' | 'closed'

export interface ProviderCapabilities {
  repositories: boolean
  issues: boolean
  comments: boolean
  pullRequests: boolean
  builds: boolean
  notifications: boolean
  publishComment: boolean
  labels: boolean
  closeIssue: boolean
  reopenIssue: boolean
  createPullRequest: boolean
  mergePullRequest: boolean
  pullRequestChanges: boolean
  rerunBuild: boolean
}

export interface CollaborationAccount {
  id: string
  provider: ProviderKind
  login: string
  displayName: string
  avatarUrl: string
  webUrl: string
  scopes: string[]
  privateReposEnabled: boolean
  writeEnabled: boolean
  capabilities: ProviderCapabilities
  lastSyncAt: number
}

export interface RemoteRepository {
  id: string
  provider: ProviderKind
  accountId: string
  owner: string
  name: string
  fullName: string
  webUrl: string
  cloneUrl: string
  sshUrl: string
  defaultBranch: string
  isPrivate: boolean
  archived: boolean
  stars: number
  openIssues: number
  openPullRequests: number
  buildState: WorkItemState
  updatedAt: string
  lastSyncAt: number
}

export interface WorkLabel {
  name: string
  color: string
}

export interface WorkComment {
  id: string
  author: string
  authorAvatarUrl: string
  body: string
  webUrl: string
  createdAt: string
  updatedAt: string
}

export interface CollaborationWorkItem {
  id: string
  provider: ProviderKind
  repositoryId: string
  kind: WorkItemKind
  /** GitHub 为数字，Gitee Issue 为 Ixxxx 等字符串，统一按字符串处理。 */
  number: string
  /** Provider API identifier. It can differ from the human-facing number (for example a GitHub Actions run). */
  externalId: string
  title: string
  body: string
  author: string
  authorAvatarUrl: string
  webUrl: string
  state: WorkItemState
  labels: WorkLabel[]
  assignees: string[]
  mentioned: boolean
  unread: boolean
  commentsCount: number
  comments: WorkComment[]
  createdAt: string
  updatedAt: string
  lastSyncAt: number
}

export interface PullRequestDraft {
  title: string
  body: string
  head: string
  base: string
  draft: boolean
}

export interface CreatePullRequestResult {
  item: CollaborationWorkItem
  audit: WritebackAudit
}

export interface ProviderNotification {
  id: string
  provider: ProviderKind
  repositoryId: string
  kind: WorkItemKind
  number: string
  title: string
  reason: string
  unread: boolean
  webUrl: string
  updatedAt: string
}

export interface RepositoryMetrics {
  openIssues: number
  openIssuesAvailable: boolean
  openPullRequests: number
  openPullRequestsAvailable: boolean
  buildState: WorkItemState
  buildStateAvailable: boolean
}

export interface LocalProjectRemote {
  project: string
  path: string
  agentType: string
  remotes: string[]
  /** work scope -> locally persisted Codex/Claude session UUID */
  collaborationSessions: Record<string, string>
}

export interface RepositoryBinding {
  repositoryId: string
  project: string
  projectPath: string
  normalizedRemote: string
  confirmedAt: number
}

export interface StarSnapshot {
  repositoryId: string
  stars: number
  capturedAt: number
}

export interface AgentWorkResult {
  reproduced: boolean
  cause: string
  codeChanged: boolean
  changeSummary: string
  testsRun: string[]
  testResult: string
  unresolved: string[]
  suggestedReply: string
  completedAt: number
}

export interface CollaborationRecord {
  id: string
  workItemId: string
  repositoryId: string
  project: string
  agentType: string
  workScope: string
  sereinSessionId: string
  agentSessionId: string
  state: WorkRecordState
  result?: AgentWorkResult
  rawResult: string
  replyDraft: string
  createdAt: number
  updatedAt: number
}

export interface WritebackAudit {
  id: string
  provider: ProviderKind
  accountId: string
  repositoryId: string
  workItemId: string
  operation: string
  summary: string
  confirmedAt: number
  completedAt: number
  success: boolean
  error: string
}

export interface CollaborationState {
  version: number
  accounts: CollaborationAccount[]
  repositories: RemoteRepository[]
  trackedRepositoryIds: string[]
  workItems: CollaborationWorkItem[]
  bindings: RepositoryBinding[]
  records: CollaborationRecord[]
  starSnapshots: StarSnapshot[]
  writebackAudits: WritebackAudit[]
  lastSyncAt: number
}

export function emptyCollaborationState(): CollaborationState {
  return {
    version: 1,
    accounts: [],
    repositories: [],
    trackedRepositoryIds: [],
    workItems: [],
    bindings: [],
    records: [],
    starSnapshots: [],
    writebackAudits: [],
    lastSyncAt: 0,
  }
}

export function providerDisplayName(provider: ProviderKind): string {
  return provider === 'github' ? 'GitHub' : 'Gitee'
}

/** Counts unique work items that need user action; running work does not inflate the badge. */
export function collaborationPendingCount(state: CollaborationState): number {
  const ids: string[] = []
  for (let i = 0; i < state.workItems.length; i++) {
    const item = state.workItems[i]
    if ((item.unread || item.state === 'failed') && ids.indexOf(item.id) < 0) ids.push(item.id)
  }
  for (let i = 0; i < state.records.length; i++) {
    const record = state.records[i]
    if ((record.state === 'draft_ready' || record.state === 'failed') && ids.indexOf(record.workItemId) < 0) {
      ids.push(record.workItemId)
    }
  }
  return ids.length
}

export function workItemKey(provider: ProviderKind, repositoryId: string, number: string,
  kind: WorkItemKind): string {
  return provider + ':' + repositoryId + ':' + kind + ':' + number
}
