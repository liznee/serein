package approval

import "time"

// Record 一条审批记录。
type Record struct {
	ID         string     `json:"id"`
	SessionID  string     `json:"session_id"`
	ToolName   string     `json:"tool_name"`
	Command    string     `json:"command"`
	Cwd        string     `json:"cwd,omitempty"`
	RiskLevel  string     `json:"risk_level"`
	RuleReason string     `json:"rule_reason"`
	Decision   string     `json:"decision"`
	Project    string     `json:"project,omitempty"`
	Diff       string     `json:"diff,omitempty"`
	DecidedBy  string     `json:"decided_by,omitempty"`
	DecidedAt  *time.Time `json:"decided_at,omitempty"`
	CreatedAt  time.Time  `json:"created_at"`
	TimeoutAt  time.Time  `json:"timeout_at"`
}

// 决策取值
const (
	DecisionPending = "pending"
	DecisionAllow   = "allow"
	DecisionDeny    = "deny"
	DecisionTimeout = "timeout"
)

// 风险级别
const (
	LevelGreen  = "green"
	LevelYellow = "yellow"
	LevelRed    = "red"
)

// ProjectSystem 是系统级审批/告警的特殊项目值。
// 不归属于任何具体项目的全局性事件（如 NTFY 超时告警、远程控制安全告警、
// 二次确认弹窗记录等）使用此值，便于手机端按「系统」分类筛选。
const ProjectSystem = "__system__"
