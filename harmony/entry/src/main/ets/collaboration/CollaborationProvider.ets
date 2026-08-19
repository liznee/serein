import type {
  CollaborationAccount, CollaborationWorkItem, ProviderCapabilities, ProviderKind,
  CreatePullRequestResult, ProviderNotification, PullRequestDraft, RemoteRepository,
  RepositoryMetrics, WorkComment, WritebackAudit
} from '../model/collaboration/CollaborationModels'

export interface ProviderPage<T> {
  items: T[]
  nextPage: number
  hasMore: boolean
}

export interface ProviderAuthRequest {
  verificationUri: string
  userCode: string
  deviceCode: string
  expiresIn: number
  interval: number
}

export interface ProviderTokenResult {
  accessToken: string
  scopes: string[]
}

export interface ListRepositoryOptions {
  page: number
  perPage: number
  includePrivate: boolean
}

export interface ListWorkItemOptions {
  page: number
  perPage: number
  state: string
  since: string
}

export interface CollaborationProvider {
  readonly kind: ProviderKind
  readonly capabilities: ProviderCapabilities

  getAuthenticatedAccount(accessToken: string): Promise<CollaborationAccount>
  listRepositories(accessToken: string, accountId: string,
    options: ListRepositoryOptions): Promise<ProviderPage<RemoteRepository>>
  getRepositoryMetrics(accessToken: string, repository: RemoteRepository): Promise<RepositoryMetrics>
  listNotifications(accessToken: string, accountId: string,
    page: number): Promise<ProviderPage<ProviderNotification>>
  listWorkItems(accessToken: string, repository: RemoteRepository,
    options: ListWorkItemOptions): Promise<ProviderPage<CollaborationWorkItem>>
  getWorkItem(accessToken: string, repository: RemoteRepository,
    item: CollaborationWorkItem): Promise<CollaborationWorkItem>
  listComments(accessToken: string, repository: RemoteRepository,
    item: CollaborationWorkItem, page: number): Promise<ProviderPage<WorkComment>>

  publishComment(accessToken: string, repository: RemoteRepository,
    item: CollaborationWorkItem, body: string): Promise<WritebackAudit>
  updateIssueState(accessToken: string, repository: RemoteRepository,
    item: CollaborationWorkItem, state: string): Promise<WritebackAudit>
  updateLabels(accessToken: string, repository: RemoteRepository,
    item: CollaborationWorkItem, labels: string[]): Promise<WritebackAudit>
  createPullRequest(accessToken: string, repository: RemoteRepository,
    draft: PullRequestDraft): Promise<CreatePullRequestResult>
  mergePullRequest(accessToken: string, repository: RemoteRepository,
    item: CollaborationWorkItem, method: string): Promise<WritebackAudit>
  rerunBuild(accessToken: string, repository: RemoteRepository,
    item: CollaborationWorkItem): Promise<WritebackAudit>
}

export class CollaborationProviderError extends Error {
  provider: ProviderKind
  status: number
  code: string
  retryAfterSeconds: number

  constructor(provider: ProviderKind, status: number, code: string, message: string,
    retryAfterSeconds: number = 0) {
    super(message)
    this.name = 'CollaborationProviderError'
    this.provider = provider
    this.status = status
    this.code = code
    this.retryAfterSeconds = retryAfterSeconds
  }
}
