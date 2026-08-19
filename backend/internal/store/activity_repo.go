package store

import (
	"database/sql"
	"time"
)

// ActivityItem 一条活动记录（审批/命令/系统事件）。
type ActivityItem struct {
	Time      time.Time `json:"time"`
	Type      string    `json:"type"`   // "approval" / "command" / "system"
	Action    string    `json:"action"` // "allow" / "deny" / "chat" / "exec" / "start" / "stop" / "agent_restart"
	Detail    string    `json:"detail"` // 审批: 命令内容 / 命令: action名称 / 系统: 描述
	Project   string    `json:"project"`
	SessionID string    `json:"session_id"`
	Success   bool      `json:"success"`
}

// ActivityRepo 活动时间线持久化。
type ActivityRepo struct {
	db *sql.DB
}

func NewActivityRepo(db *sql.DB) *ActivityRepo {
	return &ActivityRepo{db: db}
}

// SaveSessionEvent 保存 relay 明确报告的会话轮次最终状态。
// session_id + event_seq 唯一约束防止 WS 重连重放造成重复动态。
func (r *ActivityRepo) SaveSessionEvent(sessionID string, eventSeq int64, project, status, detail string) error {
	_, err := r.db.Exec(`
		INSERT OR IGNORE INTO session_events (session_id, event_seq, project, status, detail)
		VALUES (?, ?, ?, ?, ?)`, sessionID, eventSeq, project, status, detail)
	return err
}

// Recent 返回最近的 N 条活动（合并审批+命令）。
func (r *ActivityRepo) Recent(limit int) ([]ActivityItem, error) {
	if limit <= 0 {
		limit = 10
	}
	query := `
	SELECT time, type, action, detail, project, session_id, success FROM (
		SELECT created_at as time, 'approval' as type,
			CASE WHEN decision='allow' THEN 'allow' WHEN decision='deny' THEN 'deny' ELSE 'timeout' END as action,
			command as detail,
			COALESCE(project, '') as project,
			session_id,
			CASE WHEN decision='allow' THEN 1 ELSE 0 END as success
		FROM approval_records
		WHERE decision IN ('allow','deny','timeout')
		UNION ALL
		SELECT created_at as time, 'command' as type, action as action, action as detail, project, session_id, success
		FROM agent_commands
		UNION ALL
		SELECT created_at as time, 'session' as type, status as action, detail, project, session_id,
			CASE WHEN status='completed' THEN 1 ELSE 0 END as success
		FROM session_events
	) ORDER BY time DESC LIMIT ?
	`
	rows, err := r.db.Query(query, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var items []ActivityItem
	for rows.Next() {
		var item ActivityItem
		if err := rows.Scan(&item.Time, &item.Type, &item.Action, &item.Detail, &item.Project, &item.SessionID, &item.Success); err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, nil
}
