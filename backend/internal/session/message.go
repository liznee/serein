// Package session 定义双端实时同步的 WS 消息协议类型。
package session

import "time"

// 消息类型常量
const (
	MsgTypeJoin        = "join"
	MsgTypeJoinAck     = "join_ack"
	MsgTypeSessionMsg  = "session_msg"
	MsgTypeHistory     = "history"
	MsgTypeModeSwitch  = "mode_switch"
	MsgTypeCmdResult   = "cmd_result"
	MsgTypeCmdStep     = "cmd_step"
	MsgTypeHeartbeat   = "heartbeat"
	MsgTypeError       = "error"
	MsgTypeUpdate      = "update"       // 增量更新（new-message / update-session / update-machine）
	MsgTypePermission  = "permission"   // 权限审批请求（工具调用前）
	MsgTypePermDecision    = "perm_decision"     // 权限审批决策
	MsgTypeFileTransfer    = "file_transfer"     // 文件传输请求（后端→relay，通知下载文件）
	MsgTypeStateUpdate     = "state_update"      // Agent/relay 状态变更通知（join/leave）
	MsgTypeApprovalUpdate  = "approval_update"   // 审批状态变更通知（created/decided）
)

// ── 权限模式（参考 happy-wire MessageMeta.permissionMode）──
//
// 控制工具执行的审批策略，在 join 时通过 JoinMessage.PermissionMode 指定，
// 也可通过 mode_switch 消息实时切换。后端 risk.Engine 根据模式决定是否
// 自动批准或需要人工审批。
const (
	PermModeDefault          = "default"           // 默认：green 自动批准，yellow/red 需审批
	PermModeAcceptEdits      = "accept_edits"      // 自动批准文件编辑（green+yellow），red 需审批
	PermModeBypassPermissions = "bypass_permissions" // 跳过所有审批（危险，仅信任环境使用）
	PermModePlan             = "plan"              // 规划模式：仅允许只读工具，禁止写操作
	PermModeReadOnly         = "read_only"         // 只读模式：拒绝所有写操作
	PermModeSafeYolo         = "safe_yolo"         // 自动批准 green+yellow，拒绝 red
	PermModeYolo             = "yolo"              // 自动批准所有操作（含 red）
)

// ── 会话事件类型（参考 happy-wire SessionEvent.t）──
//
// 描述会话中发生的事件类型，用于 cmd_step payload 的 event 字段。
const (
	EventText          = "text"           // 文本输出
	EventService       = "service"        // 服务消息（如 Claude Code 状态）
	EventToolCallStart = "tool_call_start" // 工具调用开始
	EventToolCallEnd   = "tool_call_end"   // 工具调用结束
	EventFile          = "file"           // 文件操作
	EventTurnStart     = "turn_start"      // 对话轮次开始
	EventTurnEnd       = "turn_end"        // 对话轮次结束
	EventStart         = "start"          // 会话开始
	EventStop          = "stop"           // 会话停止
)

// ── 更新消息子类型（参考 happy-wire CoreUpdateBody.t）──
const (
	UpdateNewMessage    = "new-message"     // 新消息到达
	UpdateSession       = "update-session"  // 会话状态更新
	UpdateMachine       = "update-machine"  // 机器状态更新
)

// WSEnvelope 是 WS 消息的顶层信封（wire format）。
type WSEnvelope struct {
	Type      string `json:"type"`
	SessionID string `json:"session_id,omitempty"`
	Seq       int64  `json:"seq,omitempty"`
	Source    string `json:"source,omitempty"` // "terminal" | "phone" | "agent"
	Timestamp string `json:"timestamp,omitempty"`
	Payload   any    `json:"payload,omitempty"`
	Error     string `json:"error,omitempty"`
}

// JoinMessage 客户端 join session 时发送。
type JoinMessage struct {
	SessionID      string `json:"session_id"`
	ClientType     string `json:"client_type"`                  // "terminal" | "phone" | "agent"
	ClientID       string `json:"client_id,omitempty"`         // 可选客户端标识
	Project        string `json:"project,omitempty"`           // 可选项目名（为空时后端默认 "serein"）
	Token          string `json:"token,omitempty"`             // 身份认证 token（HOOK_TOKEN 或 CLIENT_TOKEN）
	PermissionMode string `json:"permission_mode,omitempty"`   // 权限模式（默认 "default"）
	AllowedTools   []string `json:"allowed_tools,omitempty"`   // 允许的工具列表（空=全部允许）
	DisallowedTools []string `json:"disallowed_tools,omitempty"` // 禁止的工具列表
}

// JoinAckPayload join 成功后返回的确认信息。
type JoinAckPayload struct {
	ClientID       string `json:"client_id"`
	SessionID      string `json:"session_id"`
	PermissionMode string `json:"permission_mode,omitempty"` // 确认当前生效的权限模式
}

// SessionMsgPayload 会话消息负载。
type SessionMsgPayload struct {
	Content  string `json:"content"`
	MsgType  string `json:"msg_type"`  // "text" | "command" | "thinking"
	Event    string `json:"event,omitempty"`    // 会话事件类型（见 Event* 常量）
	Turn     string `json:"turn,omitempty"`     // 当前对话轮次 ID
	Thinking bool   `json:"thinking,omitempty"` // 是否为 thinking 内容
}

// ClientInfo 客户端信息。
type ClientInfo struct {
	ClientID   string    `json:"client_id"`
	ClientType string    `json:"client_type"`
	JoinedAt   time.Time `json:"joined_at"`
}

// HistoryPayload 历史消息载荷。
type HistoryPayload struct {
	Messages []HistoryMsg `json:"messages"`
}

// HistoryMsg 单条历史消息。
type HistoryMsg struct {
	Seq       int64     `json:"seq"`
	Source    string    `json:"source"`
	Timestamp time.Time `json:"timestamp,omitempty"`
	MsgType   string    `json:"msg_type"` // "text" | "command" | "system"
	Content   string    `json:"content"`  // 文本内容
	CmdID     string    `json:"cmd_id,omitempty"`
	Turn      string    `json:"turn,omitempty"`     // 对话轮次 ID
	Event     string    `json:"event,omitempty"`    // 事件类型
	Thinking  bool      `json:"thinking,omitempty"` // 是否为 thinking 内容
}

// ── 权限审批相关 ──

// PermissionPayload 工具调用前的权限审批请求（后端 → 手机）。
type PermissionPayload struct {
	ToolName  string `json:"tool_name"`         // 工具名称（如 Bash, Write, Edit）
	Command   string `json:"command,omitempty"`  // 命令内容（Bash 时）
	RiskLevel string `json:"risk_level"`         // 风险等级：green/yellow/red
	RuleReason string `json:"rule_reason,omitempty"` // 触发规则的原因
	CmdID     string `json:"cmd_id"`             // 关联的命令 ID
	Timeout   int    `json:"timeout,omitempty"`  // 超时秒数（0=使用默认值）
}

// PermDecisionPayload 权限审批决策（手机 → 后端）。
type PermDecisionPayload struct {
	CmdID    string `json:"cmd_id"`
	Decision string `json:"decision"` // "allow" | "deny"
	Reason   string `json:"reason,omitempty"`
}

// ── 更新消息相关（参考 happy-wire CoreUpdateBody）──

// UpdatePayload 增量更新消息负载。
type UpdatePayload struct {
	T        string `json:"t"`                  // 更新子类型：new-message / update-session / update-machine
	SID      string `json:"sid,omitempty"`      // 会话 ID
	Metadata any    `json:"metadata,omitempty"` // 会话元数据（update-session 时）
	Daemon   any    `json:"daemon,omitempty"`   // 守护进程状态（update-machine 时）
	Active   *bool  `json:"active,omitempty"`   // 是否活跃（update-machine 时）
	ActiveAt int64  `json:"activeAt,omitempty"` // 活跃时间戳
}

// ── 模式切换 ──

// ModeSwitchPayload 模式切换消息负载。
type ModeSwitchPayload struct {
	Mode           string   `json:"mode"`                     // 新的权限模式
	AllowedTools   []string `json:"allowed_tools,omitempty"`   // 允许的工具列表
	DisallowedTools []string `json:"disallowed_tools,omitempty"` // 禁止的工具列表
}

// ── 工具函数 ──

// IsValidPermissionMode 检查权限模式是否有效。
func IsValidPermissionMode(mode string) bool {
	switch mode {
	case PermModeDefault, PermModeAcceptEdits, PermModeBypassPermissions,
		PermModePlan, PermModeReadOnly, PermModeSafeYolo, PermModeYolo:
		return true
	}
	return false
}

// PermissionDecision 表示权限评估的结果。
type PermissionDecision int

const (
	DecisionNeedsApproval PermissionDecision = iota // 需要人工审批
	DecisionAutoApprove                              // 自动批准
	DecisionAutoDeny                                 // 自动拒绝
)

// String 返回决策的字符串表示，用于日志和调试。
func (d PermissionDecision) String() string {
	switch d {
	case DecisionAutoApprove:
		return "auto_approve"
	case DecisionAutoDeny:
		return "auto_deny"
	case DecisionNeedsApproval:
		return "needs_approval"
	}
	return "unknown"
}

// IsWriteTool 判断工具是否为写操作（可能修改文件系统或执行命令）。
// 用于 read_only 和 plan 模式的工具级过滤。
// 只读工具列表与 risk/engine.go greenTools 保持同步。
func IsWriteTool(toolName string) bool {
	switch toolName {
	// 只读工具：不修改任何状态
	case "Read", "Grep", "Glob", "LS", "list_dir", "search",
		"WebSearch", "WebFetch", "codebase_search", "read_file",
		"web_fetch", "glob_file_search", "fetch_rules", "read_lints",
		"TodoWrite", "TaskList", "TaskGet", "TaskOutput",
		"AskQuestion", "SpecAskQuestion":
		return false
	// 写工具：修改文件系统、执行命令、或其他状态变更
	default:
		return true
	}
}

// EvaluatePermission 根据权限模式、风险等级和工具名评估权限决策。
// 返回 DecisionAutoApprove / DecisionAutoDeny / DecisionNeedsApproval。
//
// 模式行为矩阵:
//   - bypass_permissions / yolo: 全部自动批准
//   - safe_yolo: green+yellow 自动批准, red 自动拒绝
//   - accept_edits: green+yellow 自动批准, red 需审批
//   - default: green 自动批准, yellow+red 需审批
//   - plan: 只读工具自动批准, 写工具自动拒绝
//   - read_only: 只读工具自动批准, 写工具自动拒绝
//
// AllowedTools/DisallowedTools 优先级最高:
//   - 工具在 DisallowedTools 中 → 自动拒绝
//   - 工具在 AllowedTools 中(且非空) → 继续按模式+风险等级评估
//   - AllowedTools 为空 → 继续按模式+风险等级评估
func EvaluatePermission(mode, riskLevel, toolName string, allowedTools, disallowedTools []string) PermissionDecision {
	// 1. 工具级过滤优先
	for _, t := range disallowedTools {
		if t == toolName {
			return DecisionAutoDeny
		}
	}
	if len(allowedTools) > 0 {
		found := false
		for _, t := range allowedTools {
			if t == toolName {
				found = true
				break
			}
		}
		if !found {
			return DecisionAutoDeny
		}
	}

	// 2. 按模式评估
	switch mode {
	case PermModeBypassPermissions, PermModeYolo:
		return DecisionAutoApprove
	case PermModeSafeYolo:
		if riskLevel == "red" {
			return DecisionAutoDeny // safe_yolo: red 自动拒绝
		}
		return DecisionAutoApprove
	case PermModeAcceptEdits:
		if riskLevel == "red" {
			return DecisionNeedsApproval
		}
		return DecisionAutoApprove
	case PermModeDefault:
		if riskLevel == "green" {
			return DecisionAutoApprove
		}
		return DecisionNeedsApproval
	case PermModePlan, PermModeReadOnly:
		if !IsWriteTool(toolName) {
			return DecisionAutoApprove // 只读工具自动批准
		}
		return DecisionAutoDeny // 写工具自动拒绝
	}
	return DecisionNeedsApproval
}

// ShouldAutoApprove 根据权限模式和风险等级判断是否自动批准。
// 返回 true 表示自动批准，false 表示需要人工审批或拒绝。
// 保留向后兼容，新代码应使用 EvaluatePermission。
func ShouldAutoApprove(mode, riskLevel string) bool {
	return EvaluatePermission(mode, riskLevel, "", nil, nil) == DecisionAutoApprove
}
