// ===== serein API 类型定义 =====
// 与 Go 后端 internal/approval/model.go Record 字段一一对应

/** 审批记录（与后端 Record JSON 契约一致） */
export interface ApprovalRecord {
  id: string
  session_id: string
  tool_name: string
  command: string
  cwd?: string
  risk_level: RiskLevel
  rule_reason: string
  decision: Decision
  project?: string
  diff?: string
  decided_by?: string
  decided_at?: string
  created_at: string
  timeout_at: string
}

/** 历史列表响应 — GET /approvals/history */
export interface HistoryResp {
  total: number
  items: ApprovalRecord[]
}

/** 决策枚举 */
export type Decision = 'pending' | 'allow' | 'deny' | 'timeout'

/** 风险等级枚举 */
export type RiskLevel = 'green' | 'yellow' | 'red'

/** 设备配对请求 — POST /devices/pair */
export interface PairReq {
  device_name: string
  pair_code: string
}

/** 设备配对响应 */
export interface PairResp {
  device_id: string
  device_name: string
  client_token: string
}

/** 审批决策请求 — POST /approvals/{id}/decide */
export interface DecideReq {
  decision: 'allow' | 'deny'
  reason?: string
}

/** 通用成功响应 */
export interface OkResp {
  ok: boolean
}

/** 健康检查响应 — GET /healthz */
export interface HealthzResp {
  ok: boolean
}

/** 单日统计 */
export interface DailyStat {
  date: string
  total: number
  approved: number
  denied: number
  high_risk: number
}

/** 统计响应 — GET /approvals/stats */
export interface StatsResp {
  items: DailyStat[]
}

/** 清空历史响应 — DELETE /approvals/history */
export interface ClearHistoryResp {
  ok: boolean
  deleted: number
}

/** 独立于审批与项目的资源监控告警记录。 */
export interface MonitoringAlertRecord {
  id: string
  metric: string
  level: 'warning' | 'critical'
  title: string
  message: string
  value: number
  threshold: number
  state: 'active' | 'resolved'
  created_at: string
  last_seen_at: string
  resolved_at?: string
}

export interface MonitoringAlertListResp {
  items: MonitoringAlertRecord[]
  total: number
}

export interface MonitoringAlertSummary {
  active: number
  total: number
}
