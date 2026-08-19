import type {
  CollaborationAccount, CollaborationWorkItem, CreatePullRequestResult, ProviderCapabilities,
  ProviderKind, ProviderNotification, PullRequestDraft, RemoteRepository, RepositoryMetrics,
  WorkComment, WorkItemKind, WorkItemState, WorkLabel, WritebackAudit
} from '../model/collaboration/CollaborationModels'
import { workItemKey } from '../model/collaboration/CollaborationModels'
import type {
  CollaborationProvider, ListRepositoryOptions, ListWorkItemOptions, ProviderPage
} from './CollaborationProvider'
import { ProviderHttpClient } from './ProviderHttpClient'
import {
  boundedExternalText, jsonArray, jsonBoolean, jsonNumber, jsonObject, jsonString, stringId
} from './ProviderJson'

const GITHUB_CAPABILITIES: ProviderCapabilities = {
  repositories: true, issues: true, comments: true, pullRequests: true,
  builds: true, notifications: true, publishComment: true, labels: true,
  closeIssue: true, reopenIssue: true, createPullRequest: true, mergePullRequest: true,
  pullRequestChanges: true, rerunBuild: true,
}

export class GithubProvider implements CollaborationProvider {
  readonly kind: ProviderKind = 'github'
  readonly capabilities: ProviderCapabilities = GITHUB_CAPABILITIES
  private client: ProviderHttpClient = new ProviderHttpClient('github')

  async getAuthenticatedAccount(accessToken: string): Promise<CollaborationAccount> {
    const data = await this.client.get<Record<string, Object>>('/user', accessToken)
    const login = jsonString(data, 'login')
    return {
      id: 'github:' + stringId(data['id']), provider: 'github', login: login,
      displayName: jsonString(data, 'name', login), avatarUrl: jsonString(data, 'avatar_url'),
      webUrl: jsonString(data, 'html_url'), scopes: [], privateReposEnabled: false,
      writeEnabled: false, capabilities: GITHUB_CAPABILITIES, lastSyncAt: Date.now(),
    }
  }

  async listRepositories(accessToken: string, accountId: string,
    options: ListRepositoryOptions): Promise<ProviderPage<RemoteRepository>> {
    const query: Record<string, string> = {}
    query['visibility'] = options.includePrivate ? 'all' : 'public'
    query['affiliation'] = 'owner,collaborator,organization_member'
    query['sort'] = 'updated'
    query['direction'] = 'desc'
    query['page'] = options.page.toString()
    query['per_page'] = options.perPage.toString()
    const raw = await this.client.get<Record<string, Object>[]>('/user/repos', accessToken, query)
    const items: RemoteRepository[] = []
    for (let i = 0; i < raw.length; i++) items.push(this.mapRepository(raw[i], accountId))
    return { items: items, nextPage: options.page + 1, hasMore: raw.length === options.perPage }
  }

  async getRepositoryMetrics(accessToken: string, repository: RemoteRepository): Promise<RepositoryMetrics> {
    const repoQuery = 'repo:' + repository.fullName
    const issueQuery: Record<string, string> = {}
    issueQuery['q'] = repoQuery + ' type:issue state:open'
    issueQuery['per_page'] = '1'
    const pullQuery: Record<string, string> = {}
    pullQuery['q'] = repoQuery + ' type:pr state:open'
    pullQuery['per_page'] = '1'
    const issueSearch = await this.client.get<Record<string, Object>>('/search/issues', accessToken,
      issueQuery)
    const pullSearch = await this.client.get<Record<string, Object>>('/search/issues', accessToken,
      pullQuery)
    let buildState: WorkItemState = 'unknown'
    let buildAvailable = false
    try {
      const runsQuery: Record<string, string> = {}
      runsQuery['per_page'] = '1'
      runsQuery['page'] = '1'
      const runs = await this.client.get<Record<string, Object>>(
        this.repoPath(repository) + '/actions/runs', accessToken, runsQuery)
      const values = jsonArray(runs, 'workflow_runs')
      buildAvailable = true
      if (values.length > 0) buildState = this.githubBuildState(values[0])
    } catch (_) {
      buildAvailable = false
    }
    return {
      openIssues: jsonNumber(issueSearch, 'total_count'), openIssuesAvailable: true,
      openPullRequests: jsonNumber(pullSearch, 'total_count'), openPullRequestsAvailable: true,
      buildState: buildState, buildStateAvailable: buildAvailable,
    }
  }

  async listNotifications(accessToken: string, accountId: string,
    page: number): Promise<ProviderPage<ProviderNotification>> {
    const query: Record<string, string> = {}
    query['all'] = 'false'
    query['participating'] = 'false'
    query['per_page'] = '50'
    query['page'] = page.toString()
    const raw = await this.client.get<Record<string, Object>[]>('/notifications', accessToken,
      query)
    const items: ProviderNotification[] = []
    for (let i = 0; i < raw.length; i++) {
      const notification = raw[i]
      const subject = jsonObject(notification, 'subject')
      const repository = jsonObject(notification, 'repository')
      const subjectType = jsonString(subject, 'type')
      const apiUrl = jsonString(subject, 'url')
      const number = this.lastPathSegment(apiUrl)
      items.push({
        id: 'github:' + stringId(notification['id']), provider: 'github',
        repositoryId: 'github:' + stringId(repository['id']),
        kind: this.notificationKind(subjectType), number: number,
        title: boundedExternalText(jsonString(subject, 'title'), 500),
        reason: jsonString(notification, 'reason'), unread: jsonBoolean(notification, 'unread', true),
        webUrl: this.githubWebUrl(apiUrl), updatedAt: jsonString(notification, 'updated_at'),
      })
    }
    return { items: items, nextPage: page + 1, hasMore: raw.length === 50 }
  }

  async listWorkItems(accessToken: string, repository: RemoteRepository,
    options: ListWorkItemOptions): Promise<ProviderPage<CollaborationWorkItem>> {
    const query: Record<string, string> = {}
    query['state'] = options.state === '' ? 'open' : options.state
    query['sort'] = 'updated'
    query['direction'] = 'desc'
    query['page'] = options.page.toString()
    query['per_page'] = options.perPage.toString()
    if (options.since !== '') query['since'] = options.since
    const raw = await this.client.get<Record<string, Object>[]>(
      this.repoPath(repository) + '/issues', accessToken, query)
    const items: CollaborationWorkItem[] = []
    for (let i = 0; i < raw.length; i++) items.push(this.mapIssue(raw[i], repository))

    // Build failures/running jobs are real work items. Failure to read Actions is
    // treated as an unavailable capability, never as a fake successful build.
    if (options.page === 1) {
      try {
        const runsQuery: Record<string, string> = {}
        runsQuery['per_page'] = '20'
        runsQuery['page'] = '1'
        const runs = await this.client.get<Record<string, Object>>(
          this.repoPath(repository) + '/actions/runs', accessToken, runsQuery)
        const values = jsonArray(runs, 'workflow_runs')
        for (let i = 0; i < values.length; i++) {
          const state = this.githubBuildState(values[i])
          if (state === 'failed' || state === 'running') items.push(this.mapBuild(values[i], repository, state))
        }
      } catch (_) {}
    }
    items.sort((a: CollaborationWorkItem, b: CollaborationWorkItem) => b.updatedAt.localeCompare(a.updatedAt))
    return { items: items, nextPage: options.page + 1, hasMore: raw.length === options.perPage }
  }

  async getWorkItem(accessToken: string, repository: RemoteRepository,
    item: CollaborationWorkItem): Promise<CollaborationWorkItem> {
    if (item.kind === 'pull_request') {
      const pull = await this.client.get<Record<string, Object>>(
        this.repoPath(repository) + '/pulls/' + encodeURIComponent(item.number), accessToken)
      const result = this.mapPull(pull, repository)
      try {
        const files = await this.client.get<Record<string, Object>[]>(
          this.repoPath(repository) + '/pulls/' + encodeURIComponent(item.number) + '/files', accessToken)
        const commits = await this.client.get<Record<string, Object>[]>(
          this.repoPath(repository) + '/pulls/' + encodeURIComponent(item.number) + '/commits', accessToken)
        result.body = this.pullRequestDetails(result.body, files, commits)
      } catch (_) {}
      return result
    }
    if (item.kind === 'build') return this.getBuildItem(accessToken, repository, item)
    const raw = await this.client.get<Record<string, Object>>(
      this.repoPath(repository) + '/issues/' + encodeURIComponent(item.number), accessToken)
    return this.mapIssue(raw, repository)
  }

  async listComments(accessToken: string, repository: RemoteRepository,
    item: CollaborationWorkItem, page: number): Promise<ProviderPage<WorkComment>> {
    const query: Record<string, string> = {}
    query['page'] = page.toString()
    query['per_page'] = '50'
    query['sort'] = 'created'
    query['direction'] = 'asc'
    const raw = await this.client.get<Record<string, Object>[]>(
      this.repoPath(repository) + '/issues/' + encodeURIComponent(item.number) + '/comments', accessToken,
      query)
    const items: WorkComment[] = []
    for (let i = 0; i < raw.length; i++) items.push(this.mapComment(raw[i]))
    let reviewCount = 0
    if (item.kind === 'pull_request') {
      try {
        const reviews = await this.client.get<Record<string, Object>[]>(
          this.repoPath(repository) + '/pulls/' + encodeURIComponent(item.number) + '/comments', accessToken,
          query)
        reviewCount = reviews.length
        for (let i = 0; i < reviews.length; i++) items.push(this.mapComment(reviews[i]))
        items.sort((a: WorkComment, b: WorkComment) => a.createdAt.localeCompare(b.createdAt))
      } catch (_) {}
    }
    return { items: items, nextPage: page + 1, hasMore: raw.length === 50 || reviewCount === 50 }
  }

  async publishComment(accessToken: string, repository: RemoteRepository,
    item: CollaborationWorkItem, body: string): Promise<WritebackAudit> {
    const payload: Record<string, Object> = {}
    payload['body'] = body
    await this.client.post<Record<string, Object>>(
      this.repoPath(repository) + '/issues/' + encodeURIComponent(item.number) + '/comments',
      accessToken, payload)
    return this.audit(repository, item, 'publish_comment', '发布回复评论')
  }

  async updateIssueState(accessToken: string, repository: RemoteRepository,
    item: CollaborationWorkItem, state: string): Promise<WritebackAudit> {
    const payload: Record<string, Object> = {}
    payload['state'] = state
    await this.client.patch<Record<string, Object>>(
      this.repoPath(repository) + '/issues/' + encodeURIComponent(item.number),
      accessToken, payload)
    return this.audit(repository, item, 'update_issue_state', 'Issue 状态改为 ' + state)
  }

  async updateLabels(accessToken: string, repository: RemoteRepository,
    item: CollaborationWorkItem, labels: string[]): Promise<WritebackAudit> {
    const payload: Record<string, Object> = {}
    payload['labels'] = labels
    await this.client.put<Record<string, Object>>(
      this.repoPath(repository) + '/issues/' + encodeURIComponent(item.number) + '/labels',
      accessToken, payload)
    return this.audit(repository, item, 'update_labels', '更新 ' + labels.length + ' 个标签')
  }

  async createPullRequest(accessToken: string, repository: RemoteRepository,
    draft: PullRequestDraft): Promise<CreatePullRequestResult> {
    const payload: Record<string, Object> = {}
    payload['title'] = draft.title
    payload['body'] = draft.body
    payload['head'] = draft.head
    payload['base'] = draft.base
    payload['draft'] = draft.draft
    const raw = await this.client.post<Record<string, Object>>(
      this.repoPath(repository) + '/pulls', accessToken, payload)
    const item = this.mapPull(raw, repository)
    return {
      item: item,
      audit: this.audit(repository, item, 'create_pull_request', '创建 Pull Request #' + item.number),
    }
  }

  async mergePullRequest(accessToken: string, repository: RemoteRepository,
    item: CollaborationWorkItem, method: string): Promise<WritebackAudit> {
    const payload: Record<string, Object> = {}
    payload['merge_method'] = method
    await this.client.put<Record<string, Object>>(
      this.repoPath(repository) + '/pulls/' + encodeURIComponent(item.number) + '/merge', accessToken, payload)
    return this.audit(repository, item, 'merge_pull_request', '使用 ' + method + ' 合并 Pull Request #' + item.number)
  }

  async rerunBuild(accessToken: string, repository: RemoteRepository,
    item: CollaborationWorkItem): Promise<WritebackAudit> {
    const runId = await this.resolveBuildId(accessToken, repository, item)
    await this.client.post<Record<string, Object>>(
      this.repoPath(repository) + '/actions/runs/' + encodeURIComponent(runId) + '/rerun-failed-jobs',
      accessToken, {})
    return this.audit(repository, item, 'rerun_failed_build', '重跑失败构建 ' + runId)
  }

  private mapRepository(data: Record<string, Object>, accountId: string): RemoteRepository {
    const owner = jsonObject(data, 'owner')
    return {
      id: 'github:' + stringId(data['id']), provider: 'github', accountId: accountId,
      owner: jsonString(owner, 'login'), name: jsonString(data, 'name'), fullName: jsonString(data, 'full_name'),
      webUrl: jsonString(data, 'html_url'), cloneUrl: jsonString(data, 'clone_url'),
      sshUrl: jsonString(data, 'ssh_url'), defaultBranch: jsonString(data, 'default_branch'),
      isPrivate: jsonBoolean(data, 'private'), archived: jsonBoolean(data, 'archived'),
      stars: jsonNumber(data, 'stargazers_count'), openIssues: -1, openPullRequests: -1,
      buildState: 'unknown', updatedAt: jsonString(data, 'updated_at'), lastSyncAt: Date.now(),
    }
  }

  private mapIssue(data: Record<string, Object>, repository: RemoteRepository): CollaborationWorkItem {
    const user = jsonObject(data, 'user')
    const kind: WorkItemKind = Object.keys(jsonObject(data, 'pull_request')).length > 0 ? 'pull_request' : 'issue'
    const labelsRaw = jsonArray(data, 'labels')
    const labels: WorkLabel[] = []
    for (let i = 0; i < labelsRaw.length; i++) {
      labels.push({ name: jsonString(labelsRaw[i], 'name'), color: jsonString(labelsRaw[i], 'color') })
    }
    const assigneesRaw = jsonArray(data, 'assignees')
    const assignees: string[] = []
    for (let i = 0; i < assigneesRaw.length; i++) assignees.push(jsonString(assigneesRaw[i], 'login'))
    const number = stringId(data['number'])
    return {
      id: workItemKey('github', repository.id, number, kind), provider: 'github',
      repositoryId: repository.id, kind: kind, number: number, externalId: number,
      title: boundedExternalText(jsonString(data, 'title'), 1000),
      body: boundedExternalText(jsonString(data, 'body'), 32000),
      author: jsonString(user, 'login'), authorAvatarUrl: jsonString(user, 'avatar_url'),
      webUrl: jsonString(data, 'html_url'), state: jsonString(data, 'state') === 'closed' ? 'closed' : 'open',
      labels: labels, assignees: assignees, mentioned: false, unread: false,
      commentsCount: jsonNumber(data, 'comments'), comments: [],
      createdAt: jsonString(data, 'created_at'), updatedAt: jsonString(data, 'updated_at'), lastSyncAt: Date.now(),
    }
  }

  private mapBuild(data: Record<string, Object>, repository: RemoteRepository,
    state: WorkItemState): CollaborationWorkItem {
    const actor = jsonObject(data, 'actor')
    const number = stringId(data['run_number'])
    return {
      id: workItemKey('github', repository.id, number, 'build'), provider: 'github',
      repositoryId: repository.id, kind: 'build', number: number, externalId: stringId(data['id']),
      title: boundedExternalText(jsonString(data, 'name', 'GitHub Actions'), 1000),
      body: '工作流：' + jsonString(data, 'display_title') + '\n分支：' + jsonString(data, 'head_branch') +
        '\n结论：' + jsonString(data, 'conclusion', jsonString(data, 'status')),
      author: jsonString(actor, 'login'), authorAvatarUrl: jsonString(actor, 'avatar_url'),
      webUrl: jsonString(data, 'html_url'), state: state, labels: [], assignees: [],
      mentioned: false, unread: state === 'failed', commentsCount: 0, comments: [],
      createdAt: jsonString(data, 'created_at'), updatedAt: jsonString(data, 'updated_at'), lastSyncAt: Date.now(),
    }
  }

  private mapPull(data: Record<string, Object>, repository: RemoteRepository): CollaborationWorkItem {
    const user = jsonObject(data, 'user')
    const labelsRaw = jsonArray(data, 'labels')
    const labels: WorkLabel[] = []
    for (let i = 0; i < labelsRaw.length; i++) {
      labels.push({ name: jsonString(labelsRaw[i], 'name'), color: jsonString(labelsRaw[i], 'color') })
    }
    const assigneesRaw = jsonArray(data, 'assignees')
    const assignees: string[] = []
    for (let i = 0; i < assigneesRaw.length; i++) assignees.push(jsonString(assigneesRaw[i], 'login'))
    const number = stringId(data['number'])
    let state: WorkItemState = jsonString(data, 'state') === 'closed' ? 'closed' : 'open'
    if (jsonBoolean(data, 'merged')) state = 'merged'
    const head = jsonObject(data, 'head')
    const base = jsonObject(data, 'base')
    const branchInfo = 'Head: ' + jsonString(head, 'label', jsonString(head, 'ref')) +
      '\nBase: ' + jsonString(base, 'label', jsonString(base, 'ref'))
    const originalBody = boundedExternalText(jsonString(data, 'body'), 28000)
    return {
      id: workItemKey('github', repository.id, number, 'pull_request'), provider: 'github',
      repositoryId: repository.id, kind: 'pull_request', number: number, externalId: number,
      title: boundedExternalText(jsonString(data, 'title'), 1000),
      body: boundedExternalText(originalBody + (originalBody === '' ? '' : '\n\n') + branchInfo, 32000),
      author: jsonString(user, 'login'), authorAvatarUrl: jsonString(user, 'avatar_url'),
      webUrl: jsonString(data, 'html_url'), state: state, labels: labels, assignees: assignees,
      mentioned: false, unread: false,
      commentsCount: jsonNumber(data, 'comments') + jsonNumber(data, 'review_comments'), comments: [],
      createdAt: jsonString(data, 'created_at'), updatedAt: jsonString(data, 'updated_at'), lastSyncAt: Date.now(),
    }
  }

  private async getBuildItem(accessToken: string, repository: RemoteRepository,
    item: CollaborationWorkItem): Promise<CollaborationWorkItem> {
    const runId = await this.resolveBuildId(accessToken, repository, item)
    const raw = await this.client.get<Record<string, Object>>(
      this.repoPath(repository) + '/actions/runs/' + encodeURIComponent(runId), accessToken)
    const result = this.mapBuild(raw, repository, this.githubBuildState(raw))
    try {
      const query: Record<string, string> = {}
      query['per_page'] = '100'
      const jobsData = await this.client.get<Record<string, Object>>(
        this.repoPath(repository) + '/actions/runs/' + encodeURIComponent(runId) + '/jobs', accessToken, query)
      const jobs = jsonArray(jobsData, 'jobs')
      let detail = '\n\nJobs and steps:'
      for (let i = 0; i < jobs.length; i++) {
        detail += '\n- ' + jsonString(jobs[i], 'name') + ': ' +
          jsonString(jobs[i], 'conclusion', jsonString(jobs[i], 'status'))
        const steps = jsonArray(jobs[i], 'steps')
        for (let j = 0; j < steps.length; j++) {
          detail += '\n  - ' + jsonString(steps[j], 'name') + ': ' +
            jsonString(steps[j], 'conclusion', jsonString(steps[j], 'status'))
        }
      }
      result.body = boundedExternalText(result.body + detail, 32000)
    } catch (_) {}
    return result
  }

  private async resolveBuildId(accessToken: string, repository: RemoteRepository,
    item: CollaborationWorkItem): Promise<string> {
    if (item.externalId !== '' && item.externalId !== item.number) return item.externalId
    const query: Record<string, string> = {}
    query['per_page'] = '100'
    const runs = await this.client.get<Record<string, Object>>(
      this.repoPath(repository) + '/actions/runs', accessToken, query)
    const values = jsonArray(runs, 'workflow_runs')
    for (let i = 0; i < values.length; i++) {
      if (stringId(values[i]['run_number']) === item.number) return stringId(values[i]['id'])
    }
    throw new Error('最近的 GitHub Actions 记录中已找不到该构建')
  }

  private pullRequestDetails(body: string, files: Record<string, Object>[],
    commits: Record<string, Object>[]): string {
    let detail = '\n\nChanged files (' + files.length + '):'
    for (let i = 0; i < files.length; i++) {
      detail += '\n- ' + jsonString(files[i], 'filename') + ' [' + jsonString(files[i], 'status') +
        ', +' + jsonNumber(files[i], 'additions') + '/-' + jsonNumber(files[i], 'deletions') + ']'
      const patch = jsonString(files[i], 'patch')
      if (patch !== '') detail += '\n' + patch
    }
    detail += '\n\nCommits (' + commits.length + '):'
    for (let i = 0; i < commits.length; i++) {
      const commit = jsonObject(commits[i], 'commit')
      detail += '\n- ' + jsonString(commits[i], 'sha').substring(0, 12) + ' ' + jsonString(commit, 'message')
    }
    return boundedExternalText(body + detail, 32000)
  }

  private mapComment(data: Record<string, Object>): WorkComment {
    const user = jsonObject(data, 'user')
    return {
      id: 'github:' + stringId(data['id']), author: jsonString(user, 'login'),
      authorAvatarUrl: jsonString(user, 'avatar_url'), body: boundedExternalText(jsonString(data, 'body'), 16000),
      webUrl: jsonString(data, 'html_url'), createdAt: jsonString(data, 'created_at'),
      updatedAt: jsonString(data, 'updated_at'),
    }
  }

  private repoPath(repository: RemoteRepository): string {
    return '/repos/' + encodeURIComponent(repository.owner) + '/' + encodeURIComponent(repository.name)
  }

  private githubBuildState(data: Record<string, Object>): WorkItemState {
    const status = jsonString(data, 'status')
    const conclusion = jsonString(data, 'conclusion')
    if (status === 'queued' || status === 'in_progress' || status === 'waiting' || status === 'pending') return 'running'
    if (conclusion === 'success' || conclusion === 'neutral' || conclusion === 'skipped') return 'success'
    if (conclusion !== '') return 'failed'
    return 'unknown'
  }

  private notificationKind(type: string): WorkItemKind {
    if (type === 'PullRequest') return 'pull_request'
    if (type === 'CheckSuite' || type === 'WorkflowRun') return 'build'
    return 'issue'
  }

  private lastPathSegment(value: string): string {
    const clean = value.split('?')[0]
    const parts = clean.split('/')
    return parts.length > 0 ? parts[parts.length - 1] : ''
  }

  private githubWebUrl(apiUrl: string): string {
    return apiUrl.replace('https://api.github.com/repos/', 'https://github.com/').replace('/pulls/', '/pull/')
  }

  private audit(repository: RemoteRepository, item: CollaborationWorkItem,
    operation: string, summary: string): WritebackAudit {
    const now = Date.now()
    return {
      id: 'github:' + operation + ':' + now, provider: 'github', accountId: repository.accountId,
      repositoryId: repository.id, workItemId: item.id, operation: operation, summary: summary,
      confirmedAt: now, completedAt: now, success: true, error: '',
    }
  }
}

export default new GithubProvider()
