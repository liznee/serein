/**
 * ws_types.ets — WebSocket 协议类型定义（与 Go 后端 session/message.go 一一对应）
 *
 * 参考 happy-wire 的设计：所有 WS 消息类型在一个文件中集中定义，
 * 确保客户端和服务端的协议契约一致。
 *
 * 修改本文件时必须同步修改 backend/internal/session/message.go
 */

// ═══ 消息类型常量 ═══
export const WS_MSG_JOIN         = 'join'
export const WS_MSG_JOIN_ACK     = 'join_ack'
export const WS_MSG_SESSION_MSG  = 'session_msg'
export const WS_MSG_HISTORY      = 'history'
export const WS_MSG_MODE_SWITCH  = 'mode_switch'
export const WS_MSG_CMD_RESULT   = 'cmd_result'
export const WS_MSG_CMD_STEP     = 'cmd_step'
export const WS_MSG_HEARTBEAT    = 'heartbeat'
export const WS_MSG_ERROR        = 'error'
export const WS_MSG_UPDATE       = 'update'
export const WS_MSG_PERMISSION   = 'permission'
export const WS_MSG_PERM_DECISION = 'perm_decision'
export const WS_MSG_FILE_TRANSFER = 'file_transfer'
export const WS_MSG_STATE_UPDATE  = 'state_update'
export const WS_MSG_APPROVAL_UPDATE = 'approval_update'

// ═══ Codex Desktop/App Server 事件（承载于 cmd_step.payload.event） ═══
export const EVENT_DESKTOP_THREAD_LIST = 'desktop_thread_list'
export const EVENT_DESKTOP_THREAD_READ = 'desktop_thread_read'
export const EVENT_DESKTOP_THREAD_TAKEN = 'desktop_thread_taken'
export const EVENT_DESKTOP_LEASE_RELEASED = 'desktop_lease_released'
export const EVENT_DESKTOP_LEASE_RENEWED = 'desktop_lease_renewed'
export const EVENT_DESKTOP_TURN_STARTED = 'desktop_turn_started'
export const EVENT_DESKTOP_TURN_INTERRUPTED = 'desktop_turn_interrupted'
export const EVENT_DESKTOP_NOTIFICATION = 'desktop_notification'
export const EVENT_DESKTOP_APPROVAL_REQUIRED = 'desktop_approval_required'
export const EVENT_DESKTOP_APPROVAL_RESOLVED = 'desktop_approval_resolved'
export const EVENT_DESKTOP_ERROR = 'desktop_error'

// ═══ 权限模式 ═══
export const PERM_DEFAULT           = 'default'
export const PERM_ACCEPT_EDITS      = 'accept_edits'
export const PERM_BYPASS_PERMISSIONS = 'bypass_permissions'
export const PERM_PLAN              = 'plan'
export const PERM_READ_ONLY         = 'read_only'
export const PERM_SAFE_YOLO         = 'safe_yolo'
export const PERM_YOLO              = 'yolo'

export type PermissionMode =
  | 'default'
  | 'accept_edits'
  | 'bypass_permissions'
  | 'plan'
  | 'read_only'
  | 'safe_yolo'
  | 'yolo'

// ═══ 会话事件类型 ═══
export const EVENT_TEXT           = 'text'
export const EVENT_SERVICE        = 'service'
export const EVENT_TOOL_CALL_START = 'tool_call_start'
export const EVENT_TOOL_CALL_END   = 'tool_call_end'
export const EVENT_FILE           = 'file'
export const EVENT_TURN_START     = 'turn_start'
export const EVENT_TURN_END       = 'turn_end'
export const EVENT_START          = 'start'
export const EVENT_STOP           = 'stop'
export const EVENT_SUBAGENT_START = 'subagent_start'
export const EVENT_SUBAGENT_STOP  = 'subagent_stop'

export type SessionEventType =
  | 'text'
  | 'service'
  | 'tool_call_start'
  | 'tool_call_end'
  | 'file'
  | 'turn_start'
  | 'turn_end'
  | 'start'
  | 'stop'
  | 'subagent_start'
  | 'subagent_stop'

// ═══ 更新消息子类型 ═══
export const UPDATE_NEW_MESSAGE   = 'new-message'
export const UPDATE_SESSION       = 'update-session'
export const UPDATE_MACHINE       = 'update-machine'

// ═══ WS 消息信封 ═══
export interface WSEnvelope {
  type: string
  session_id?: string
  seq?: number
  source?: string
  timestamp?: string
  payload?: WSMessagePayload
  error?: string
}

// ═══ Join 消息 ═══
export interface JoinMessage {
  session_id: string
  client_type: 'terminal' | 'phone' | 'agent'
  client_id?: string
  project?: string
  token?: string
  permission_mode?: PermissionMode
  allowed_tools?: string[]
  disallowed_tools?: string[]
}

export interface JoinAckPayload {
  client_id: string
  session_id: string
  permission_mode?: PermissionMode
}

// ═══ 会话消息 ═══
export interface SessionMsgPayload {
  content: string
  msg_type: 'text' | 'command' | 'thinking'
  event?: SessionEventType
  turn?: string
  thinking?: boolean
}

// ═══ 历史消息 ═══
export interface HistoryMsg {
  seq: number
  source: string
  timestamp?: string
  msg_type: 'text' | 'command' | 'system'
  content: string
  cmd_id?: string
  turn?: string
  event?: SessionEventType
  thinking?: boolean
}

export interface HistoryPayload {
  messages: HistoryMsg[]
}

// ═══ 权限审批 ═══
export interface PermissionPayload {
  tool_name: string
  command?: string
  risk_level: 'green' | 'yellow' | 'red'
  rule_reason?: string
  cmd_id: string
  timeout?: number
}

export interface PermDecisionPayload {
  cmd_id: string
  decision: 'allow' | 'deny'
  reason?: string
}

// ═══ 更新消息 ═══
export interface UpdatePayload {
  t: 'new-message' | 'update-session' | 'update-machine'
  sid?: string
  metadata?: Record<string, Object>
  daemon?: Record<string, Object>
  active?: boolean
  activeAt?: number
}

// ═══ 模式切换 ═══
export interface ModeSwitchPayload {
  mode: PermissionMode
  allowed_tools?: string[]
  disallowed_tools?: string[]
}

// ═══ WS 消息 Payload 联合类型（必须在所有 Payload 接口之后定义） ═══
export type WSMessagePayload = JoinAckPayload | SessionMsgPayload | HistoryPayload | PermissionPayload | PermDecisionPayload | UpdatePayload | ModeSwitchPayload | Record<string, Object>

// ═══ 工具函数 ═══

/** 检查权限模式是否有效 */
export function isValidPermissionMode(mode: string): boolean {
  return [
    PERM_DEFAULT, PERM_ACCEPT_EDITS, PERM_BYPASS_PERMISSIONS,
    PERM_PLAN, PERM_READ_ONLY, PERM_SAFE_YOLO, PERM_YOLO
  ].includes(mode)
}

/** 根据权限模式和风险等级判断是否自动批准 */
export function shouldAutoApprove(mode: PermissionMode, riskLevel: string): boolean {
  switch (mode) {
    case PERM_BYPASS_PERMISSIONS:
    case PERM_YOLO:
      return true
    case PERM_SAFE_YOLO:
    case PERM_ACCEPT_EDITS:
      return riskLevel !== 'red'
    case PERM_DEFAULT:
      return riskLevel === 'green'
    case PERM_PLAN:
    case PERM_READ_ONLY:
      return false
    default:
      return false
  }
}
