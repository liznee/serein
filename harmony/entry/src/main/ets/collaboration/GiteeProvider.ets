import type {
  CollaborationAccount, CollaborationWorkItem, CreatePullRequestResult, ProviderCapabilities,
  ProviderKind, ProviderNotification, PullRequestDraft, RemoteRepository, RepositoryMetrics,
  WorkComment, WorkItemState, WorkLabel, WritebackAudit
} from '../model/collaboration/CollaborationModels'
import { workItemKey } from '../model/collaboration/CollaborationModels'
import type {
  CollaborationProvider, ListRepositoryOptions, ListWorkItemOptions, ProviderPage
} from './CollaborationProvider'
import { CollaborationProviderError } from './CollaborationProvider'
import { ProviderHttpClient } from './ProviderHttpClient'
import {
  boundedExternalText, jsonArray, jsonBoolean, jsonNumber, jsonObject, jsonString, stringId
} from './ProviderJson'

const GITEE_CAPABILITIES: ProviderCapabilities = {
  repositories: true, issues: true, comments: true, pullRequests: true,
  builds: true, notifications: true, publishComment: true, labels: true,
  closeIssue: true, reopenIssue: true, createPullRequest: true, mergePullRequest: true,
  pullRequestChanges: true, rerunBuild: false,
}

export class GiteeProvider implements CollaborationProvider {
  readonly kind: ProviderKind = 'gitee'
  readonly capabilities: ProviderCapabilities = GITEE_CAPABILITIES
  private client: ProviderHttpClient = new ProviderHttpClient('gitee')

  async getAuthenticatedAccount(accessToken: string): Promise<CollaborationAccount> {
    const data = await this.client.get<Record<string, Object>>('/user', accessToken)
    const login = jsonString(data, 'login')
    return {
      id: 'gitee:' + stringId(data['id']), provider: 'gitee', login: login,
      displayName: jsonString(data, 'name', login), avatarUrl: jsonString(data, 'avatar_url'),
      webUrl: jsonString(data, 'html_url'), scopes: [], privateReposEnabled: false,
      writeEnabled: false, capabilities: GITEE_CAPABILITIES, lastSyncAt: Date.now(),
    }
  }

  async listRepositories(accessToken: string, accountId: string,
    options: ListRepositoryOptions): Promise<ProviderPage<RemoteRepository>> {
    const query: Record<string, string> = {}
    query['visibility'] = options.includePrivate ? 'all' : 'public'
    query['affiliation'] = 'owner,collaborator,organization_member,enterprise_member'
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
    let pullCount = 0
    let pullAvailable = true
    let page = 1
    try {
      while (page <= 100) {
        const pullsQuery: Record<string, string> = {}
        pullsQuery['state'] = 'open'
        pullsQuery['page'] = page.toString()
        pullsQuery['per_page'] = '100'
        pullsQuery['sort'] = 'updated'
        pullsQuery['direction'] = 'desc'
        const pulls = await this.client.get<Record<string, Object>[]>(
          this.repoPath(repository) + '/pulls', accessToken,
          pullsQuery)
        pullCount += pulls.length
        if (pulls.length < 100) break
        page++
      }
      if (page > 100) pullAvailable = false
    } catch (_) {
      pullAvailable = false
    }

    let buildState: WorkItemState = 'unknown'
    let buildAvailable = false
    try {
      const checkQuery: Record<string, string> = {}
      checkQuery['page'] = '1'
      checkQuery['per_page'] = '1'
      checkQuery['filter'] = 'latest'
      const result = await this.client.get<Record<string, Object>>(
        this.repoPath(repository) + '/commits/' + encodeURIComponent(repository.defaultBranch) + '/check-runs',
        accessToken, checkQuery)
      if (stringId(result['id']) !== '') {
        buildState = this.checkRunState(result)
        buildAvailable = true
      }
    } catch (_) {}

    return {
      openIssues: repository.openIssues, openIssuesAvailable: repository.openIssues >= 0,
      openPullRequests: pullCount, openPullRequestsAvailable: pullAvailable,
      buildState: buildState, buildStateAvailable: buildAvailable,
    }
  }

  async listNotifications(accessToken: string, accountId: string,
    page: number): Promise<ProviderPage<ProviderNotification>> {
    const query: Record<string, string> = {}
    query['unread'] = 'true'
    query['type'] = 'all'
    query['page'] = page.toString()
    query['per_page'] = '50'
    const result = await this.client.get<Record<string, Object>>('/notifications/threads', accessToken,
      query)
    const raw = jsonArray(result, 'list')
    const items: ProviderNotification[] = []
    for (let i = 0; i < raw.length; i++) {
      const notification = raw[i]
      const subject = jsonObject(notification, 'subject')
      const repository = jsonObject(notification, 'repository')
      const type = jsonString(subject, 'type')
      const url = jsonString(subject, 'url')
      items.push({
        id: 'gitee:' + stringId(notification['id']), provider: 'gitee',
        repositoryId: 'gitee:' + stringId(repository['id']), kind: this.notificationKind(type),
        number: this.lastPathSegment(url), title: boundedExternalText(jsonString(subject, 'title'), 500),
        reason: jsonString(notification, 'type'), unread: jsonBoolean(notification, 'unread', true),
        webUrl: jsonString(notification, 'html_url', url), updatedAt: jsonString(notification, 'updated_at'),
      })
    }
    return { items: items, nextPage: page + 1, hasMore: raw.length === 50 }
  }

  async listWorkItems(accessToken: string, repository: RemoteRepository,
    options: ListWorkItemOptions): Promise<ProviderPage<CollaborationWorkItem>> {
    const state = options.state === '' ? 'open' : options.state
    const listQuery: Record<string, string> = {}
    listQuery['state'] = state
    listQuery['sort'] = 'updated'
    listQuery['direction'] = 'desc'
    listQuery['page'] = options.page.toString()
    listQuery['per_page'] = options.perPage.toString()
    const issues = await this.client.get<Record<string, Object>[]>(
      this.repoPath(repository) + '/issues', accessToken,
      listQuery)
    const pulls = await this.client.get<Record<string, Object>[]>(
      this.repoPath(repository) + '/pulls', accessToken,
      listQuery)

    const items: CollaborationWorkItem[] = []
    for (let i = 0; i < issues.length; i++) items.push(this.mapIssue(issues[i], repository))
    for (let i = 0; i < pulls.length; i++) items.push(this.mapPull(pulls[i], repository))
    if (options.page === 1) {
      try {
        const checkQuery: Record<string, string> = {}
        checkQuery['page'] = '1'
        checkQuery['per_page'] = '1'
        checkQuery['filter'] = 'latest'
        const check = await this.client.get<Record<string, Object>>(
          this.repoPath(repository) + '/commits/' + encodeURIComponent(repository.defaultBranch) + '/check-runs',
          accessToken, checkQuery)
        const checkState = this.checkRunState(check)
        if (checkState === 'failed' || checkState === 'running') items.push(this.mapCheckRun(check, repository, checkState))
      } catch (_) {}
    }
    items.sort((a: CollaborationWorkItem, b: CollaborationWorkItem) => b.updatedAt.localeCompare(a.updatedAt))
    return {
      items: items, nextPage: options.page + 1,
      hasMore: issues.length === options.perPage || pulls.length === options.perPage,
    }
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
    const issue = await this.client.get<Record<string, Object>>(
      this.repoPath(repository) + '/issues/' + encodeURIComponent(item.number), accessToken)
    return this.mapIssue(issue, repository)
  }

  async listComments(accessToken: string, repository: RemoteRepository,
    item: CollaborationWorkItem, page: number): Promise<ProviderPage<WorkComment>> {
    const kindPath = item.kind === 'pull_request' ? '/pulls/' : '/issues/'
    const query: Record<string, string> = {}
    query['page'] = page.toString()
    query['per_page'] = '50'
    query['order'] = 'asc'
    const raw = await this.client.get<Record<string, Object>[]>(
      this.repoPath(repository) + kindPath + encodeURIComponent(item.number) + '/comments', accessToken,
      query)
    const comments: WorkComment[] = []
    for (let i = 0; i < raw.length; i++) comments.push(this.mapComment(raw[i]))
    return { items: comments, nextPage: page + 1, hasMore: raw.length === 50 }
  }

  async publishComment(accessToken: string, repository: RemoteRepository,
    item: CollaborationWorkItem, body: string): Promise<WritebackAudit> {
    const kindPath = item.kind === 'pull_request' ? '/pulls/' : '/issues/'
    const payload: Record<string, Object> = {}
    payload['body'] = body
    await this.client.post<Record<string, Object>>(
      this.repoPath(repository) + kindPath + encodeURIComponent(item.number) + '/comments',
      accessToken, payload, true)
    return this.audit(repository, item, 'publish_comment', '发布回复评论')
  }

  async updateIssueState(accessToken: string, repository: RemoteRepository,
    item: CollaborationWorkItem, state: string): Promise<WritebackAudit> {
    if (item.kind !== 'issue') {
      throw new CollaborationProviderError('gitee', 400, 'unsupported_operation', 'Gitee PR/MR 状态请在后续 PR 操作中单独确认')
    }
    const payload: Record<string, Object> = {}
    payload['state'] = state
    await this.client.patch<Record<string, Object>>(
      this.repoPath(repository) + '/issues/' + encodeURIComponent(item.number), accessToken,
      payload, true)
    return this.audit(repository, item, 'update_issue_state', 'Issue 状态改为 ' + state)
  }

  async updateLabels(accessToken: string, repository: RemoteRepository,
    item: CollaborationWorkItem, labels: string[]): Promise<WritebackAudit> {
    if (item.kind !== 'issue') {
      throw new CollaborationProviderError('gitee', 400, 'unsupported_operation', '当前只支持修改 Gitee Issue 标签')
    }
    const payload: Record<string, Object> = {}
    payload['labels'] = labels.join(',')
    await this.client.patch<Record<string, Object>>(
      this.repoPath(repository) + '/issues/' + encodeURIComponent(item.number), accessToken,
      payload, true)
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
      this.repoPath(repository) + '/pulls', accessToken, payload, true)
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
      this.repoPath(repository) + '/pulls/' + encodeURIComponent(item.number) + '/merge',
      accessToken, payload, true)
    return this.audit(repository, item, 'merge_pull_request', '使用 ' + method + ' 合并 Pull Request #' + item.number)
  }

  async rerunBuild(accessToken: string, repository: RemoteRepository,
    item: CollaborationWorkItem): Promise<WritebackAudit> {
    throw new CollaborationProviderError('gitee', 400, 'unsupported_operation',
      'Gitee API v5 没有为检查项提供安全的重跑接口')
  }

  private mapRepository(data: Record<string, Object>, accountId: string): RemoteRepository {
    const owner = jsonObject(data, 'owner')
    const webUrl = jsonString(data, 'html_url')
    return {
      id: 'gitee:' + stringId(data['id']), provider: 'gitee', accountId: accountId,
      owner: jsonString(owner, 'login'), name: jsonString(data, 'path', jsonString(data, 'name')),
      fullName: jsonString(data, 'full_name'), webUrl: webUrl,
      cloneUrl: jsonString(data, 'clone_url', webUrl === '' ? '' : webUrl + '.git'),
      sshUrl: jsonString(data, 'ssh_url'), defaultBranch: jsonString(data, 'default_branch', 'master'),
      isPrivate: jsonBoolean(data, 'private'), archived: jsonString(data, 'status') === 'closed',
      stars: jsonNumber(data, 'stargazers_count'), openIssues: jsonNumber(data, 'open_issues_count', -1),
      openPullRequests: -1, buildState: 'unknown', updatedAt: jsonString(data, 'updated_at'),
      lastSyncAt: Date.now(),
    }
  }

  private mapIssue(data: Record<string, Object>, repository: RemoteRepository): CollaborationWorkItem {
    const user = jsonObject(data, 'user')
    const assignees: string[] = []
    const assignee = jsonObject(data, 'assignee')
    if (jsonString(assignee, 'login') !== '') assignees.push(jsonString(assignee, 'login'))
    const collaborators = jsonArray(data, 'collaborators')
    for (let i = 0; i < collaborators.length; i++) {
      const login = jsonString(collaborators[i], 'login')
      if (login !== '' && assignees.indexOf(login) < 0) assignees.push(login)
    }
    const number = stringId(data['number'])
    return {
      id: workItemKey('gitee', repository.id, number, 'issue'), provider: 'gitee',
      repositoryId: repository.id, kind: 'issue', number: number, externalId: number,
      title: boundedExternalText(jsonString(data, 'title'), 1000),
      body: boundedExternalText(jsonString(data, 'body'), 32000),
      author: jsonString(user, 'login'), authorAvatarUrl: jsonString(user, 'avatar_url'),
      webUrl: jsonString(data, 'html_url'), state: this.giteeIssueState(data),
      labels: this.mapLabels(data), assignees: assignees, mentioned: false, unread: false,
      commentsCount: jsonNumber(data, 'comments'), comments: [],
      createdAt: jsonString(data, 'created_at'), updatedAt: jsonString(data, 'updated_at'), lastSyncAt: Date.now(),
    }
  }

  private mapPull(data: Record<string, Object>, repository: RemoteRepository): CollaborationWorkItem {
    const user = jsonObject(data, 'user')
    const assigneesRaw = jsonArray(data, 'assignees')
    const assignees: string[] = []
    for (let i = 0; i < assigneesRaw.length; i++) assignees.push(jsonString(assigneesRaw[i], 'login'))
    const number = stringId(data['number'])
    let state: WorkItemState = jsonString(data, 'state') === 'closed' ? 'closed' : 'open'
    if (jsonString(data, 'merged_at') !== '') state = 'merged'
    return {
      id: workItemKey('gitee', repository.id, number, 'pull_request'), provider: 'gitee',
      repositoryId: repository.id, kind: 'pull_request', number: number, externalId: number,
      title: boundedExternalText(jsonString(data, 'title'), 1000),
      body: boundedExternalText(jsonString(data, 'body'), 32000),
      author: jsonString(user, 'login'), authorAvatarUrl: jsonString(user, 'avatar_url'),
      webUrl: jsonString(data, 'html_url'), state: state, labels: this.mapLabels(data),
      assignees: assignees, mentioned: false, unread: false,
      commentsCount: jsonNumber(data, 'comments'), comments: [],
      createdAt: jsonString(data, 'created_at'), updatedAt: jsonString(data, 'updated_at'), lastSyncAt: Date.now(),
    }
  }

  private mapCheckRun(data: Record<string, Object>, repository: RemoteRepository,
    state: WorkItemState): CollaborationWorkItem {
    const number = stringId(data['id'])
    return {
      id: workItemKey('gitee', repository.id, number, 'build'), provider: 'gitee',
      repositoryId: repository.id, kind: 'build', number: number, externalId: number,
      title: boundedExternalText(jsonString(data, 'name', 'Gitee Check Run'), 1000),
      body: '提交：' + jsonString(data, 'head_sha') + '\n结论：' +
        jsonString(data, 'conclusion', jsonString(data, 'status')),
      author: '', authorAvatarUrl: '', webUrl: jsonString(data, 'html_url', jsonString(data, 'details_url')),
      state: state, labels: [], assignees: [], mentioned: false, unread: state === 'failed',
      commentsCount: 0, comments: [], createdAt: jsonString(data, 'started_at'),
      updatedAt: jsonString(data, 'completed_at', jsonString(data, 'started_at')), lastSyncAt: Date.now(),
    }
  }

  private async getBuildItem(accessToken: string, repository: RemoteRepository,
    item: CollaborationWorkItem): Promise<CollaborationWorkItem> {
    const checkId = item.externalId === '' ? item.number : item.externalId
    const raw = await this.client.get<Record<string, Object>>(
      this.repoPath(repository) + '/check-runs/' + encodeURIComponent(checkId), accessToken)
    const result = this.mapCheckRun(raw, repository, this.checkRunState(raw))
    const output = jsonObject(raw, 'output')
    let detail = '\n\nCheck output:'
    const title = jsonString(output, 'title')
    const summary = jsonString(output, 'summary')
    const text = jsonString(output, 'text')
    if (title !== '') detail += '\n' + title
    if (summary !== '') detail += '\n' + summary
    if (text !== '') detail += '\n' + text
    try {
      const annotation = await this.client.get<Record<string, Object>>(
        this.repoPath(repository) + '/check-runs/' + encodeURIComponent(checkId) + '/annotations', accessToken)
      const message = jsonString(annotation, 'message')
      if (message !== '') {
        detail += '\n\nAnnotation: ' + jsonString(annotation, 'path') + ':' +
          jsonNumber(annotation, 'start_line') + ' ' + message
      }
    } catch (_) {}
    result.body = boundedExternalText(result.body + detail, 32000)
    return result
  }

  private pullRequestDetails(body: string, files: Record<string, Object>[],
    commits: Record<string, Object>[]): string {
    let detail = '\n\nChanged files (' + files.length + '):'
    for (let i = 0; i < files.length; i++) {
      const filename = jsonString(files[i], 'filename', jsonString(files[i], 'path'))
      detail += '\n- ' + filename + ' [' + jsonString(files[i], 'status') + ']'
      const patch = jsonString(files[i], 'patch', jsonString(files[i], 'diff'))
      if (patch !== '') detail += '\n' + patch
    }
    detail += '\n\nCommits (' + commits.length + '):'
    for (let i = 0; i < commits.length; i++) {
      const commit = jsonObject(commits[i], 'commit')
      detail += '\n- ' + jsonString(commits[i], 'sha').substring(0, 12) + ' ' +
        jsonString(commit, 'message', jsonString(commits[i], 'message'))
    }
    return boundedExternalText(body + detail, 32000)
  }

  private mapComment(data: Record<string, Object>): WorkComment {
    const user = jsonObject(data, 'user')
    return {
      id: 'gitee:' + stringId(data['id']), author: jsonString(user, 'login'),
      authorAvatarUrl: jsonString(user, 'avatar_url'), body: boundedExternalText(jsonString(data, 'body'), 16000),
      webUrl: jsonString(data, 'html_url'), createdAt: jsonString(data, 'created_at'),
      updatedAt: jsonString(data, 'updated_at'),
    }
  }

  private mapLabels(data: Record<string, Object>): WorkLabel[] {
    const raw = jsonArray(data, 'labels')
    const labels: WorkLabel[] = []
    for (let i = 0; i < raw.length; i++) {
      labels.push({ name: jsonString(raw[i], 'name'), color: jsonString(raw[i], 'color') })
    }
    return labels
  }

  private giteeIssueState(data: Record<string, Object>): WorkItemState {
    const state = jsonString(data, 'state')
    return state === 'closed' || state === 'rejected' ? 'closed' : 'open'
  }

  private checkRunState(data: Record<string, Object>): WorkItemState {
    const status = jsonString(data, 'status')
    const conclusion = jsonString(data, 'conclusion')
    if (status === 'queued' || status === 'in_progress') return 'running'
    if (conclusion === 'success' || conclusion === 'neutral' || conclusion === 'skipped') return 'success'
    if (conclusion !== '') return 'failed'
    return 'unknown'
  }

  private notificationKind(type: string): 'issue' | 'pull_request' | 'build' {
    const normalized = type.toLowerCase()
    if (normalized.indexOf('pull') >= 0) return 'pull_request'
    if (normalized.indexOf('check') >= 0 || normalized.indexOf('build') >= 0) return 'build'
    return 'issue'
  }

  private lastPathSegment(value: string): string {
    const parts = value.split('?')[0].split('/')
    return parts.length > 0 ? parts[parts.length - 1] : ''
  }

  private repoPath(repository: RemoteRepository): string {
    return '/repos/' + encodeURIComponent(repository.owner) + '/' + encodeURIComponent(repository.name)
  }

  private audit(repository: RemoteRepository, item: CollaborationWorkItem,
    operation: string, summary: string): WritebackAudit {
    const now = Date.now()
    return {
      id: 'gitee:' + operation + ':' + now, provider: 'gitee', accountId: repository.accountId,
      repositoryId: repository.id, workItemId: item.id, operation: operation, summary: summary,
      confirmedAt: now, completedAt: now, success: true, error: '',
    }
  }
}

export default new GiteeProvider()
