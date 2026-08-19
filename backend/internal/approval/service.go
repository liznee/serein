package approval

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
)

// ErrNotFound 审批记录不存在。
var ErrNotFound = errors.New("approval not found")

// Service 审批业务逻辑,操作 SQLite。
type Service struct {
	db      *sql.DB
	timeout time.Duration
}

func NewService(db *sql.DB, timeoutSec int) *Service {
	return &Service{db: db, timeout: time.Duration(timeoutSec) * time.Second}
}

// CreateReq 创建审批请求(hook 提交)。
type CreateReq struct {
	SessionID  string
	ToolName   string
	Command    string
	Cwd        string
	RiskLevel  string
	RuleReason string
	Project    string
	Diff       string
}

// Create 创建一条 pending 审批记录。
func (s *Service) Create(ctx context.Context, req CreateReq) (*Record, error) {
	id := uuid.NewString()
	now := time.Now().UTC()
	timeoutAt := now.Add(s.timeout)
	_, err := s.db.ExecContext(ctx, `
INSERT INTO approval_records (id, session_id, tool_name, command, cwd, risk_level, rule_reason, decision, project, diff, created_at, timeout_at)
VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?)`,
		id, req.SessionID, req.ToolName, req.Command, req.Cwd, req.RiskLevel, req.RuleReason, req.Project, req.Diff, now, timeoutAt)
	if err != nil {
		return nil, err
	}
	return &Record{
		ID: id, SessionID: req.SessionID, ToolName: req.ToolName,
		Command: req.Command, Cwd: req.Cwd, RiskLevel: req.RiskLevel,
		RuleReason: req.RuleReason, Decision: DecisionPending,
		CreatedAt: now, TimeoutAt: timeoutAt,
	}, nil
}

// Get 按 id 查询审批记录。
func (s *Service) Get(ctx context.Context, id string) (*Record, error) {
	r := &Record{}
	var decidedAt sql.NullTime
	var decidedBy sql.NullString
	err := s.db.QueryRowContext(ctx, `
SELECT id, session_id, tool_name, command, cwd, risk_level, rule_reason, decision, project, diff, decided_by, decided_at, created_at, timeout_at
FROM approval_records WHERE id = ?`, id).Scan(
		&r.ID, &r.SessionID, &r.ToolName, &r.Command, &r.Cwd, &r.RiskLevel,
		&r.RuleReason, &r.Decision, &r.Project, &r.Diff, &decidedBy, &decidedAt, &r.CreatedAt, &r.TimeoutAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	r.DecidedBy = decidedBy.String
	if decidedAt.Valid {
		r.DecidedAt = &decidedAt.Time
	}
	return r, nil
}

// Status 返回当前决策。若 pending 且已超时,标记 timeout 并返回 deny 语义。
// 返回的 decision ∈ {allow, deny, pending}(timeout 归一为 deny)。
func (s *Service) Status(ctx context.Context, id string) (decision, reason string, err error) {
	// 超时兜底: pending 且超过 timeout_at → 标记 timeout
	// 用 Go time 比较(modernc 存 time.Time 格式与 CURRENT_TIMESTAMP 文本不一致)
	now := time.Now().UTC()
	_, e := s.db.ExecContext(ctx, `
UPDATE approval_records SET decision='timeout', decided_at=?
WHERE id=? AND decision='pending' AND timeout_at <= ?`, now, id, now)
	if e != nil {
		return "", "", e
	}
	r, err := s.Get(ctx, id)
	if err != nil {
		return "", "", err
	}
	switch r.Decision {
	case DecisionAllow:
		return DecisionAllow, decidedByLabel("approved", r.DecidedBy), nil
	case DecisionDeny:
		return DecisionDeny, decidedByLabel("denied", r.DecidedBy), nil
	case DecisionTimeout:
		return DecisionDeny, "approval timeout", nil
	default:
		return DecisionPending, "", nil
	}
}

// Decide 幂等决策。仅当 pending 且未超时时更新。
// 返回 updated=true 表示本次决策生效;false 表示已决策/超时(幂等忽略)。
func (s *Service) Decide(ctx context.Context, id, decision, decidedBy string) (bool, error) {
	now := time.Now().UTC()
	res, err := s.db.ExecContext(ctx, `
UPDATE approval_records
SET decision=?, decided_by=?, decided_at=?
WHERE id=? AND decision='pending' AND timeout_at > ?`,
		decision, decidedBy, now, id, now)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// List 分页查询审批历史。status 为空则不限。project 为空则不限。
// pending 查询时自动过滤已超时的审批（timeout_at <= now）。
func (s *Service) List(ctx context.Context, limit, offset int, status, project string) ([]*Record, int, error) {
	if limit <= 0 || limit > 500 {
		limit = 50
	}
	if offset < 0 {
		offset = 0
	}
	var (
		rows *sql.Rows
		err  error
	)
	now := time.Now().UTC()

	// project 过滤条件片段
	projCond := ""
	projArgs := make([]interface{}, 0)
	if project != "" {
		projCond = " AND project=? "
		projArgs = []interface{}{project}
	}

	selectCols := `id, session_id, tool_name, command, cwd, risk_level, rule_reason, decision, project, diff, decided_by, decided_at, created_at, timeout_at`

	if status != "" {
		if status == "pending" {
			query := `SELECT ` + selectCols + ` FROM approval_records WHERE decision=?` + projCond + ` AND timeout_at > ? ORDER BY created_at DESC LIMIT ? OFFSET ?`
			args := append([]interface{}{status}, projArgs...)
			args = append(args, now, limit, offset)
			rows, err = s.db.QueryContext(ctx, query, args...)
		} else {
			query := `SELECT ` + selectCols + ` FROM approval_records WHERE decision=?` + projCond + ` ORDER BY created_at DESC LIMIT ? OFFSET ?`
			args := append([]interface{}{status}, projArgs...)
			args = append(args, limit, offset)
			rows, err = s.db.QueryContext(ctx, query, args...)
		}
	} else {
		if project != "" {
			rows, err = s.db.QueryContext(ctx, `SELECT `+selectCols+` FROM approval_records WHERE project=? ORDER BY created_at DESC LIMIT ? OFFSET ?`, project, limit, offset)
		} else {
			rows, err = s.db.QueryContext(ctx, `SELECT `+selectCols+` FROM approval_records ORDER BY created_at DESC LIMIT ? OFFSET ?`, limit, offset)
		}
	}
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()

	var out []*Record
	for rows.Next() {
		r := &Record{}
		var decidedAt sql.NullTime
		var decidedBy sql.NullString
		var projectCol sql.NullString
		if err := rows.Scan(&r.ID, &r.SessionID, &r.ToolName, &r.Command, &r.Cwd,
			&r.RiskLevel, &r.RuleReason, &r.Decision, &projectCol, &r.Diff, &decidedBy, &decidedAt,
			&r.CreatedAt, &r.TimeoutAt); err != nil {
			return nil, 0, err
		}
		r.Project = projectCol.String
		r.DecidedBy = decidedBy.String
		if decidedAt.Valid {
			r.DecidedAt = &decidedAt.Time
		}
		out = append(out, r)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, err
	}

	var total int
	var countErr error
	if status != "" {
		// 列表查询只有 pending 需要排除已超时记录；allow/deny/timeout
		// 的历史记录不应因为 timeout_at 过去而从 total 中消失。
		timeoutCond := ""
		countArgs := make([]interface{}, 0, 3)
		if status == "pending" {
			timeoutCond = " AND timeout_at > ?"
			countArgs = append(countArgs, now)
		}
		if project != "" {
			query := `SELECT COUNT(*) FROM approval_records WHERE decision=? AND project=?` + timeoutCond
			args := []interface{}{status, project}
			args = append(args, countArgs...)
			countErr = s.db.QueryRowContext(ctx, query, args...).Scan(&total)
		} else {
			query := `SELECT COUNT(*) FROM approval_records WHERE decision=?` + timeoutCond
			args := []interface{}{status}
			args = append(args, countArgs...)
			countErr = s.db.QueryRowContext(ctx, query, args...).Scan(&total)
		}
	} else {
		if project != "" {
			countErr = s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM approval_records WHERE project=?`, project).Scan(&total)
		} else {
			countErr = s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM approval_records`).Scan(&total)
		}
	}
	if countErr != nil {
		return nil, 0, countErr
	}
	return out, total, nil
}

// ListTimedOutPending 返回所有已超时（timeout_at <= now）且尚未推送过超时通知的审批记录。
//
// 查询条件包含 decision='pending' 和 decision='timeout' 两种状态：
//   - pending: hook 尚未轮询到，扫描器需要主动标记 timeout
//   - timeout: hook 的 Status 轮询已将其标记为 timeout（竞态：hook 每 1s 轮询，
//     扫描器每 30s 才运行，所以大部分记录在被扫描器看到时已经是 timeout）
//
// timeout_notified_at IS NULL 确保每个审批只通知一次（持久化去重，重启不丢失）。
// 1 小时时间窗口避免重启后补推大量历史超时记录。
func (s *Service) ListTimedOutPending(ctx context.Context) ([]*Record, error) {
	now := time.Now().UTC()
	cutoff := now.Add(-1 * time.Hour)
	rows, err := s.db.QueryContext(ctx, `
SELECT id, session_id, tool_name, command, cwd, risk_level, rule_reason, decision, project, diff, decided_by, decided_at, created_at, timeout_at
FROM approval_records
WHERE (decision='pending' OR decision='timeout')
  AND timeout_at <= ?
  AND timeout_at >= ?
  AND timeout_notified_at IS NULL`, now, cutoff)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*Record
	for rows.Next() {
		r := &Record{}
		var decidedAt sql.NullTime
		var decidedBy sql.NullString
		var projectCol sql.NullString
		if err := rows.Scan(&r.ID, &r.SessionID, &r.ToolName, &r.Command, &r.Cwd,
			&r.RiskLevel, &r.RuleReason, &r.Decision, &projectCol, &r.Diff, &decidedBy, &decidedAt,
			&r.CreatedAt, &r.TimeoutAt); err != nil {
			return nil, err
		}
		r.Project = projectCol.String
		r.DecidedBy = decidedBy.String
		if decidedAt.Valid {
			r.DecidedAt = &decidedAt.Time
		}
		out = append(out, r)
	}
	return out, nil
}

// MarkTimeoutNotified 标记审批记录的超时通知已推送。
// 持久化去重：即使服务重启，也不会重复推送同一条超时通知。
func (s *Service) MarkTimeoutNotified(ctx context.Context, id string) error {
	_, err := s.db.ExecContext(ctx,
		`UPDATE approval_records SET timeout_notified_at=? WHERE id=?`,
		time.Now().UTC(), id)
	return err
}

// DeleteAllExceptPending 删除所有非 pending 的审批记录（清空历史）。
// 返回删除行数。
func (s *Service) DeleteAllExceptPending(ctx context.Context) (int64, error) {
	res, err := s.db.ExecContext(ctx, `DELETE FROM approval_records WHERE decision != 'pending'`)
	if err != nil {
		return 0, err
	}
	n, _ := res.RowsAffected()
	return n, nil
}

func decidedByLabel(action, by string) string {
	if by == "" {
		return action
	}
	return action + " by " + by
}

// DailyStats 单日统计
type DailyStats struct {
	Date     string `json:"date"`
	Total    int64  `json:"total"`
	Approved int64  `json:"approved"`
	Denied   int64  `json:"denied"`
	HighRisk int64  `json:"high_risk"`
}

func (s *Service) GetDailyStats(ctx context.Context, days int, project string) ([]DailyStats, error) {
	projCond := ""
	projArgs := make([]interface{}, 0)
	if project != "" {
		projCond = " AND project=?"
		projArgs = []interface{}{project}
	}
	query := `SELECT substr(created_at,1,10) as dt,
		COUNT(*) as total,
		SUM(CASE WHEN decision='allow' THEN 1 ELSE 0 END) as approved,
		SUM(CASE WHEN decision='deny' THEN 1 ELSE 0 END) as denied,
		SUM(CASE WHEN risk_level='red' THEN 1 ELSE 0 END) as high_risk
		FROM approval_records
		WHERE created_at >= datetime('now', ? || ' days')` + projCond + `
		GROUP BY dt ORDER BY dt`
	args := append([]interface{}{fmt.Sprintf("-%d", days)}, projArgs...)
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []DailyStats
	for rows.Next() {
		var ds DailyStats
		if err := rows.Scan(&ds.Date, &ds.Total, &ds.Approved, &ds.Denied, &ds.HighRisk); err != nil {
			return nil, err
		}
		result = append(result, ds)
	}
	return result, nil
}
