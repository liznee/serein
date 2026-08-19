import {
  KEY_APPROVAL_PENDING_COUNT,
  KEY_PENDING_AGENT_QUESTION_COUNT,
  KEY_PENDING_AGENT_QUESTIONS,
  KEY_PENDING_COUNT,
} from '../state/AppStore'

export interface AgentQuestionItem {
  id: string
  toolUseId: string
  project: string
  question: string
  header: string
  options: string[]
  createdAt: number
  choiceGroupId: number
}

interface QuestionPayload {
  question_id?: string
  tool_use_id?: string
  question?: string
  header?: string
}

/**
 * 保存当前 App 进程亲自收到的结构化 Agent 提问。
 * 不持久化这些记录，避免 App 关闭期间电脑端已回答却仍显示过期待处理项。
 */
export class AgentQuestionQueue {
  static load(): AgentQuestionItem[] {
    const raw = AppStorage.get<string>(KEY_PENDING_AGENT_QUESTIONS) ?? '[]'
    try {
      return JSON.parse(raw) as AgentQuestionItem[]
    } catch (e) {
      return []
    }
  }

  static beginQuestion(project: string, rawPayload: string, eventName: string): string {
    let payload: QuestionPayload = {}
    try { payload = JSON.parse(rawPayload) as QuestionPayload } catch (e) {}
    const question = payload.question && payload.question !== ''
      ? payload.question : 'Agent 正在等待你的选择'
    const questionId = payload.question_id && payload.question_id !== ''
      ? payload.question_id : (eventName !== '' ? eventName : project + ':' + Date.now())
    const toolUseId = payload.tool_use_id ?? ''
    const current = AgentQuestionQueue.load()
    const next: AgentQuestionItem[] = []
    for (let i = 0; i < current.length; i++) {
      if (current[i].id !== questionId) next.push(current[i])
    }
    next.push({
      id: questionId, toolUseId: toolUseId, project: project,
      question: question, header: payload.header ?? '', options: [],
      createdAt: Date.now(), choiceGroupId: -1,
    })
    AgentQuestionQueue.save(next)
    return question
  }

  static appendChoice(project: string, rawChoice: string, questionId: string, choiceGroupId: number): void {
    const current = AgentQuestionQueue.load()
    let target = -1
    for (let i = current.length - 1; i >= 0; i--) {
      if ((questionId !== '' && current[i].id === questionId)
          || (questionId === '' && current[i].project === project && current[i].choiceGroupId === choiceGroupId)) {
        target = i
        break
      }
    }
    if (target < 0) {
      current.push({
        id: questionId !== '' ? questionId : project + ':choice:' + choiceGroupId,
        toolUseId: '', project: project, question: 'Agent 正在等待你的选择',
        header: '', options: [rawChoice], createdAt: Date.now(), choiceGroupId: choiceGroupId,
      })
    } else {
      const item = current[target]
      const options = item.options.indexOf(rawChoice) >= 0 ? item.options : item.options.concat([rawChoice])
      current[target] = {
        id: item.id, toolUseId: item.toolUseId, project: item.project,
        question: item.question, header: item.header, options: options,
        createdAt: item.createdAt, choiceGroupId: choiceGroupId,
      }
    }
    AgentQuestionQueue.save(current)
  }

  static resolveToolQuestions(project: string, toolUseId: string): void {
    if (toolUseId === '') return
    const current = AgentQuestionQueue.load()
    const next: AgentQuestionItem[] = []
    for (let i = 0; i < current.length; i++) {
      if (!(current[i].project === project && current[i].toolUseId === toolUseId)) next.push(current[i])
    }
    AgentQuestionQueue.save(next)
  }

  static resolveChoiceGroup(project: string, choiceGroupId: number): void {
    const current = AgentQuestionQueue.load()
    const next: AgentQuestionItem[] = []
    for (let i = 0; i < current.length; i++) {
      if (!(current[i].project === project && current[i].choiceGroupId === choiceGroupId)) next.push(current[i])
    }
    AgentQuestionQueue.save(next)
  }

  static setApprovalCount(count: number): void {
    AppStorage.setOrCreate(KEY_APPROVAL_PENDING_COUNT, count)
    AgentQuestionQueue.syncTotalCount()
  }

  static syncTotalCount(): void {
    const approvals = AppStorage.get<number>(KEY_APPROVAL_PENDING_COUNT) ?? 0
    const questions = AppStorage.get<number>(KEY_PENDING_AGENT_QUESTION_COUNT) ?? 0
    AppStorage.setOrCreate(KEY_PENDING_COUNT, approvals + questions)
  }

  private static save(items: AgentQuestionItem[]): void {
    AppStorage.setOrCreate(KEY_PENDING_AGENT_QUESTIONS, JSON.stringify(items))
    AppStorage.setOrCreate(KEY_PENDING_AGENT_QUESTION_COUNT, items.length)
    AgentQuestionQueue.syncTotalCount()
  }
}
