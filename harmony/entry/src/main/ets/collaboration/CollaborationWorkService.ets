import { http } from '@kit.NetworkKit'
import { KEY_CLIENT_TOKEN } from '../state/AppStore'
import type {
  CollaborationRecord, CollaborationState, CollaborationWorkItem, LocalProjectRemote,
  RemoteRepository, RepositoryBinding, WorkComment
} from '../model/collaboration/CollaborationModels'
import { collaborationPendingCount } from '../model/collaboration/CollaborationModels'
import CollaborationStore from '../store/CollaborationStore'
import PrefStore from '../store/PrefStore'

interface HandoffCommentPayload {
  author: string
  body: string
  url: string
}

interface HandoffPayload {
  provider: string
  repository_id: string
  repository_name: string
  item_kind: string
  item_number: string
  item_url: string
  title: string
  body: string
  comments: HandoffCommentPayload[]
  project: string
  agent_type: string
  agent_session_id: string
}

interface HandoffResponse {
  ok: boolean
  status: string
  project: string
  agent_type: string
  work_scope: string
  serein_session_id: string
  agent_session_id: string
  prompt_dispatched: boolean
  error?: string
}

export class CollaborationWorkService {
  findRecord(state: CollaborationState, workItemId: string): CollaborationRecord | undefined {
    return state.records.find((value: CollaborationRecord) => value.workItemId === workItemId)
  }

  private resolveAgentSession(record: CollaborationRecord | undefined,
    project: LocalProjectRemote): string {
    if (!record) return ''
    if (record.agentType !== project.agentType) return ''
    if (record.agentSessionId !== '') return record.agentSessionId
    if (record.workScope !== '') return project.collaborationSessions[record.workScope] ?? ''
    return ''
  }

  async handoff(item: CollaborationWorkItem, repository: RemoteRepository,
    binding: RepositoryBinding, project: LocalProjectRemote): Promise<CollaborationRecord> {
    const state = await CollaborationStore.load()
    const existing = this.findRecord(state, item.id)
    const comments: HandoffCommentPayload[] = []
    // Keep the newest real comments within a bounded request budget. This also
    // prevents a hostile Issue thread from turning handoff into an oversized prompt.
    let commentBudget = 7000
    for (let i = item.comments.length - 1; i >= 0 && commentBudget > 0; i--) {
      const value: WorkComment = item.comments[i]
      const body = value.body.substring(0, Math.min(4000, commentBudget))
      comments.unshift({ author: value.author, body: body, url: value.webUrl })
      commentBudget -= body.length
    }
    const payload: HandoffPayload = {
      provider: item.provider,
      repository_id: repository.id,
      repository_name: repository.fullName,
      item_kind: item.kind,
      item_number: item.number,
      item_url: item.webUrl === '' ? repository.webUrl : item.webUrl,
      title: item.title,
      body: item.body,
      comments: comments,
      project: binding.project,
      agent_type: project.agentType,
      agent_session_id: this.resolveAgentSession(existing, project),
    }
    const config = await PrefStore.loadAll()
    const backendUrl = config.backendUrl !== '' ? config.backendUrl : (AppStorage.get<string>('backendUrl') ?? '')
    if (backendUrl === '') throw new Error('后端地址未配置')
    const token = AppStorage.get<string>(KEY_CLIENT_TOKEN) ?? ''
    const request = http.createHttp()
    let response: HandoffResponse
    try {
      const result = await request.request(backendUrl + '/collaboration/handoff', {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'Authorization': token === '' ? '' : 'Bearer ' + token,
        },
        extraData: JSON.stringify(payload),
        connectTimeout: 10000,
        readTimeout: 130000,
        expectDataType: http.HttpDataType.STRING,
      })
      response = JSON.parse(result.result as string) as HandoffResponse
      if (result.responseCode === 409) throw new Error('该项目正在处理另一个任务，请先完成或停止当前任务')
      if (result.responseCode !== 200 || !response.ok) {
        throw new Error(response.error ?? '交给 Agent 失败')
      }
      // `already_running` is intentionally idempotent: the backend does not
      // inject the same Issue twice into an active Agent session. Do not create
      // a brand-new local "working" record from that response, otherwise a
      // failed/old handoff is displayed as if it had successfully started.
      if (!response.prompt_dispatched && !existing) {
        throw new Error('Agent 会话已存在，但本次任务没有重新投递；请返回后刷新任务状态')
      }
    } finally {
      request.destroy()
    }

    const now = Date.now()
    let record: CollaborationRecord
    if (existing) {
      record = existing
      record.project = binding.project
      record.agentType = project.agentType
      record.workScope = response.work_scope
      record.sereinSessionId = response.serein_session_id
      if (response.agent_session_id !== '') record.agentSessionId = response.agent_session_id
      record.state = 'working'
      record.updatedAt = now
    } else {
      record = {
        id: 'work:' + item.id,
        workItemId: item.id,
        repositoryId: repository.id,
        project: binding.project,
        agentType: project.agentType,
        workScope: response.work_scope,
        sereinSessionId: response.serein_session_id,
        agentSessionId: response.agent_session_id,
        state: 'working',
        rawResult: '',
        replyDraft: '',
        createdAt: now,
        updatedAt: now,
      }
      state.records.unshift(record)
    }
    const itemIndex = state.workItems.findIndex((value: CollaborationWorkItem) => value.id === item.id)
    if (itemIndex >= 0) state.workItems[itemIndex].unread = false
    await CollaborationStore.save(state)
    this.updatePendingCount(state)
    return record
  }

  openTerminal(record: CollaborationRecord): void {
    AppStorage.setOrCreate('terminalProject', record.project)
    AppStorage.setOrCreate('terminalAgentType', record.agentType)
    AppStorage.setOrCreate('switchToTerminal', true)
  }

  private updatePendingCount(state: CollaborationState): void {
    AppStorage.setOrCreate('collaborationPendingCount', collaborationPendingCount(state))
  }
}

export default new CollaborationWorkService()
