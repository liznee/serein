import { http } from '@kit.NetworkKit'
import { KEY_CLIENT_TOKEN } from '../state/AppStore'
import type { AgentWorkResult, CollaborationRecord, CollaborationState } from '../model/collaboration/CollaborationModels'
import { collaborationPendingCount } from '../model/collaboration/CollaborationModels'
import CollaborationStore from '../store/CollaborationStore'
import PrefStore from '../store/PrefStore'

interface ResultSummaryWire {
  reproduced: boolean
  cause: string
  code_changed: boolean
  change_summary: string
  tests_run: string[]
  test_result: string
  unresolved: string[]
  suggested_reply: string
}

interface CollaborationResultResponse {
  work_scope: string
  status: string
  project: string
  agent_type: string
  agent_session_id: string
  raw_result: string
  structured_available: boolean
  updated_at: string
  summary?: ResultSummaryWire
  error?: string
}

export class CollaborationResultService {
  async refresh(recordId: string): Promise<CollaborationRecord> {
    const state = await CollaborationStore.load()
    const record = state.records.find((value: CollaborationRecord) => value.id === recordId)
    if (!record || record.workScope === '') throw new Error('这条记录还没有可查询的 Agent 会话')
    const config = await PrefStore.loadAll()
    const backendUrl = config.backendUrl !== '' ? config.backendUrl : (AppStorage.get<string>('backendUrl') ?? '')
    if (backendUrl === '') throw new Error('后端地址未配置')
    const token = AppStorage.get<string>(KEY_CLIENT_TOKEN) ?? ''
    const request = http.createHttp()
    let response: CollaborationResultResponse
    try {
      const result = await request.request(backendUrl + '/collaboration/result?scope=' + encodeURIComponent(record.workScope), {
        method: http.RequestMethod.GET,
        header: { 'Authorization': token === '' ? '' : 'Bearer ' + token },
        connectTimeout: 5000,
        readTimeout: 8000,
        expectDataType: http.HttpDataType.STRING,
      })
      response = JSON.parse(result.result as string) as CollaborationResultResponse
      if (result.responseCode === 404) throw new Error('Agent 还没有产出结果')
      if (result.responseCode !== 200) throw new Error(response.error ?? '结果查询失败')
    } finally {
      request.destroy()
    }
    if (response.agent_session_id !== '') record.agentSessionId = response.agent_session_id
    record.rawResult = response.raw_result
    record.updatedAt = Date.now()
    if (response.status === 'failed') {
      record.state = 'failed'
    } else if (response.status === 'completed') {
      record.state = 'completed'
      if (response.structured_available && response.summary) {
        const summary = response.summary
        const result: AgentWorkResult = {
          reproduced: summary.reproduced,
          cause: summary.cause,
          codeChanged: summary.code_changed,
          changeSummary: summary.change_summary,
          testsRun: summary.tests_run,
          testResult: summary.test_result,
          unresolved: summary.unresolved,
          suggestedReply: summary.suggested_reply,
          completedAt: Date.now(),
        }
        record.result = result
        record.replyDraft = summary.suggested_reply
        record.state = summary.suggested_reply !== '' ? 'draft_ready' : (summary.code_changed ? 'fixed' : 'reproduced')
      }
    } else {
      record.state = 'working'
    }
    await CollaborationStore.save(state)
    this.updatePendingCount(state)
    return record
  }

  async saveDraft(recordId: string, draft: string): Promise<void> {
    const state = await CollaborationStore.load()
    const record = state.records.find((value: CollaborationRecord) => value.id === recordId)
    if (!record) throw new Error('协作记录不存在')
    record.replyDraft = draft
    record.state = draft.trim() === '' ? 'completed' : 'draft_ready'
    record.updatedAt = Date.now()
    await CollaborationStore.save(state)
    this.updatePendingCount(state)
  }

  private updatePendingCount(state: CollaborationState): void {
    AppStorage.setOrCreate('collaborationPendingCount', collaborationPendingCount(state))
  }
}

export default new CollaborationResultService()
