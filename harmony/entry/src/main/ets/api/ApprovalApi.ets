import { HttpClient } from './HttpClient'
import type { HistoryResp, ApprovalRecord, OkResp, DecideReq, ClearHistoryResp, StatsResp } from './types'

// ===== 审批 API 层 =====
// 封装 /approvals/* 端点，与 Go 后端路由契约对齐

export class ApprovalApi {
  private static instance: ApprovalApi
  private client: HttpClient = new HttpClient()

  static getInstance(): ApprovalApi {
    if (!ApprovalApi.instance) {
      ApprovalApi.instance = new ApprovalApi()
    }
    return ApprovalApi.instance
  }

  /**
   * 获取审批历史（支持 status 过滤 + 分页 + project 过滤）
   * @param status  pending | allow | deny | timeout | ''(全部)
   * @param limit   每页条数，默认 50
   * @param offset  偏移量，默认 0
   * @param project 项目标识，空则不限
   */
  async list(status?: string, limit: number = 50, offset: number = 0, project?: string): Promise<HistoryResp> {
    let path = '/approvals/history?limit=' + limit + '&offset=' + offset
    if (status !== undefined && status !== '') {
      path += '&status=' + status
    }
    if (project !== undefined && project !== '') {
      path += '&project=' + project
    }
    return this.client.get<HistoryResp>(path)
  }

  /** 统计接口 — GET /approvals/stats */
  async stats(days: number = 7, project?: string): Promise<StatsResp> {
    let path = '/approvals/stats?days=' + days
    if (project) path += '&project=' + project
    return this.client.get<StatsResp>(path)
  }

  /** 清空所有历史记录（保留 pending）— DELETE /approvals/history */
  async clearHistory(): Promise<ClearHistoryResp> {
    return this.client.delete('/approvals/history')
  }

  /** 获取待审批列表（便捷方法） */
  async listPending(limit: number = 50, offset: number = 0, project?: string): Promise<HistoryResp> {
    return this.list('pending', limit, offset, project)
  }

  /** 获取审批详情 — GET /approvals/{id} */
  async detail(id: string): Promise<ApprovalRecord> {
    return this.client.get<ApprovalRecord>('/approvals/' + id)
  }

  /**
   * 审批决策 — POST /approvals/{id}/decide
   * @param id        审批 ID
   * @param decision  'allow' | 'deny'
   * @param reason    可选原因
   * @returns         409 时抛 ApiError{status:409}
   */
  async decide(id: string, decision: 'allow' | 'deny', reason?: string): Promise<OkResp> {
    const body: DecideReq = { decision: decision }
    if (reason !== undefined && reason !== '') {
      body.reason = reason
    }
    return this.client.post<OkResp>('/approvals/' + id + '/decide', body)
  }
}

export default ApprovalApi.getInstance()
