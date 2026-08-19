package store

import (
	"database/sql"
	"fmt"
)

// CommandRepo 命令执行统计持久化。
type CommandRepo struct {
	db *sql.DB
}

func NewCommandRepo(db *sql.DB) *CommandRepo {
	return &CommandRepo{db: db}
}

// Save 保存一条命令执行记录。
func (r *CommandRepo) Save(cmdID, action, project, sessionID string, success bool, durationMs int64) error {
	s := 0
	if success {
		s = 1
	}
	_, err := r.db.Exec(
		`INSERT INTO agent_commands (cmd_id, action, project, session_id, success, duration_ms) VALUES (?, ?, ?, ?, ?, ?)`,
		cmdID, action, project, sessionID, s, durationMs)
	return err
}

// CommandStats 命令统计聚合。
type CommandStats struct {
	Action     string `json:"action"`
	Count      int    `json:"count"`
	SuccessCnt int    `json:"success_count"`
	FailCnt    int    `json:"fail_count"`
	AvgMs      int64  `json:"avg_ms"`
}

// Stats 返回最近 days 天内各 action 的统计聚合。
func (r *CommandRepo) Stats(days int) ([]CommandStats, error) {
	rows, err := r.db.Query(`
		SELECT action, COUNT(*), COALESCE(SUM(success),0), COUNT(*)-COALESCE(SUM(success),0), CAST(COALESCE(AVG(duration_ms),0) AS INTEGER)
		FROM agent_commands
		WHERE created_at >= datetime('now', ?)
		GROUP BY action
		ORDER BY COUNT(*) DESC
	`, fmt.Sprintf("-%d days", days))
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var stats []CommandStats
	for rows.Next() {
		var s CommandStats
		if err := rows.Scan(&s.Action, &s.Count, &s.SuccessCnt, &s.FailCnt, &s.AvgMs); err != nil {
			return nil, err
		}
		stats = append(stats, s)
	}
	return stats, rows.Err()
}

// ProjectCommandStats 按项目聚合的命令统计。
type ProjectCommandStats struct {
	Project    string `json:"project"`
	Count      int    `json:"count"`
	SuccessCnt int    `json:"success_count"`
	FailCnt    int    `json:"fail_count"`
	AvgMs      int64  `json:"avg_ms"`
}

// StatsByProject 返回最近 days 天内各 project 的命令统计聚合。
// 用于统计页"按项目拆分"视图，回答"哪个项目最活跃/成功率最低"。
func (r *CommandRepo) StatsByProject(days int) ([]ProjectCommandStats, error) {
	rows, err := r.db.Query(`
		SELECT project, COUNT(*), COALESCE(SUM(success),0), COUNT(*)-COALESCE(SUM(success),0), CAST(COALESCE(AVG(duration_ms),0) AS INTEGER)
		FROM agent_commands
		WHERE created_at >= datetime('now', ?)
		GROUP BY project
		ORDER BY COUNT(*) DESC
	`, fmt.Sprintf("-%d days", days))
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var stats []ProjectCommandStats
	for rows.Next() {
		var s ProjectCommandStats
		if err := rows.Scan(&s.Project, &s.Count, &s.SuccessCnt, &s.FailCnt, &s.AvgMs); err != nil {
			return nil, err
		}
		stats = append(stats, s)
	}
	return stats, rows.Err()
}

// CommandDailyStat 每日命令执行趋势（统计页 7 天柱状图数据源）。
type CommandDailyStat struct {
	Date       string `json:"date"`
	Total      int    `json:"total"`
	SuccessCnt int    `json:"success_count"`
	FailCnt    int    `json:"fail_count"`
}

// DailyStats 返回最近 days 天内每天的命令执行趋势（按日期升序）。
// 用于统计页命令执行的 7 天趋势柱状图，回答"命令量随时间如何变化"。
func (r *CommandRepo) DailyStats(days int) ([]CommandDailyStat, error) {
	rows, err := r.db.Query(`
		SELECT date(created_at) AS d, COUNT(*), COALESCE(SUM(success),0), COUNT(*)-COALESCE(SUM(success),0)
		FROM agent_commands
		WHERE created_at >= datetime('now', ?)
		GROUP BY date(created_at)
		ORDER BY d ASC
	`, fmt.Sprintf("-%d days", days))
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var stats []CommandDailyStat
	for rows.Next() {
		var s CommandDailyStat
		if err := rows.Scan(&s.Date, &s.Total, &s.SuccessCnt, &s.FailCnt); err != nil {
			return nil, err
		}
		stats = append(stats, s)
	}
	return stats, rows.Err()
}
