export interface RemoteHostCapabilities {
  protocol_version: number
  capture: string[]
  video_codecs: string[]
  transports: string[]
  hardware_encoder: boolean
  input: string[]
  monitors: number
  unattended_enabled: boolean
  secure_desktop: boolean
}

export interface RemoteHost {
  id: string
  display_name: string
  version: string
  capabilities: RemoteHostCapabilities
  online: boolean
  last_seen_at: string
}

export interface RemoteHostList {
  items: RemoteHost[]
}

export interface RemoteSession {
  id: string
  host_id: string
  controller_device_id: string
  controller_is_primary: boolean
  primary_approved: boolean
  state: string
  revision: number
  requested_capabilities: string[]
  granted_capabilities: string[]
  transport_type?: string
  requested_at: string
  updated_at: string
  started_at?: string
  ended_at?: string
  end_reason?: string
}

export interface RemoteSessionList {
  items: RemoteSession[]
}

export interface RemoteTicket {
  ticket: string
  expires_at: string
  revision: number
}

export interface RemoteAuditEvent {
  id: string
  session_id?: string
  actor_type: string
  actor_id: string
  event_type: string
  safe_metadata: Record<string, Object>
  created_at: string
}

export interface RemoteAuditList {
  items: RemoteAuditEvent[]
}

export function remoteStateLabel(state: string): string {
  switch (state) {
    case 'waiting_primary': return '等待主设备确认'
    case 'waiting_host': return '等待电脑上线'
    case 'waiting_consent': return '等待电脑响应'
    case 'negotiating': return '正在建立安全连接'
    case 'connected_view': return '只看已连接'
    case 'connected_control': return '控制已连接'
    case 'reconnecting': return '正在恢复连接'
    case 'ended': return '已结束'
    case 'failed': return '连接失败'
    default: return '准备中'
  }
}

export function isRemoteTerminalState(state: string): boolean {
  return state === 'ended' || state === 'failed'
}
