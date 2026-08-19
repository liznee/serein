package store

import (
	"database/sql"
	"regexp"
	"time"
)

// BlacklistEntry 黑名单条目。
type BlacklistEntry struct {
	ID          int       `json:"id"`
	Pattern     string    `json:"pattern"`
	Description string    `json:"description,omitempty"`
	CreatedAt   time.Time `json:"created_at"`
}

// BlacklistRepo 黑名单模式仓储。
type BlacklistRepo struct {
	db *sql.DB
}

func NewBlacklistRepo(db *sql.DB) *BlacklistRepo {
	return &BlacklistRepo{db: db}
}

// Add 添加黑名单模式。
func (r *BlacklistRepo) Add(pattern, description string) (*BlacklistEntry, error) {
	res, err := r.db.Exec(`INSERT INTO blacklist (pattern, description) VALUES (?, ?)`, pattern, description)
	if err != nil {
		return nil, err
	}
	id, _ := res.LastInsertId()
	return &BlacklistEntry{
		ID: int(id), Pattern: pattern, Description: description, CreatedAt: time.Now().UTC(),
	}, nil
}

// Remove 按 id 删除黑名单模式。
func (r *BlacklistRepo) Remove(id int) (bool, error) {
	res, err := r.db.Exec(`DELETE FROM blacklist WHERE id = ?`, id)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// List 返回所有黑名单模式。
func (r *BlacklistRepo) List() ([]*BlacklistEntry, error) {
	return r.queryList(`SELECT id, pattern, COALESCE(description,''), created_at FROM blacklist ORDER BY id`)
}

// Match 检查 command 是否匹配任一黑名单模式。返回匹配条目的描述或空字符串。
// 黑名单永远优先于白名单和会话记忆。
func (r *BlacklistRepo) Match(command string) (string, bool) {
	entries, err := r.List()
	if err != nil {
		return "", false
	}
	for _, e := range entries {
		re, err := regexp.Compile(e.Pattern)
		if err != nil {
			continue
		}
		if re.MatchString(command) {
			if e.Description != "" {
				return e.Description, true
			}
			return e.Pattern, true
		}
	}
	return "", false
}

func (r *BlacklistRepo) queryList(query string, args ...interface{}) ([]*BlacklistEntry, error) {
	rows, err := r.db.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*BlacklistEntry
	for rows.Next() {
		e := &BlacklistEntry{}
		if err := rows.Scan(&e.ID, &e.Pattern, &e.Description, &e.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}
