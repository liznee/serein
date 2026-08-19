package store

import (
	"database/sql"
	"regexp"
	"time"
)

// WhitelistEntry 白名单条目。
type WhitelistEntry struct {
	ID          int       `json:"id"`
	Pattern     string    `json:"pattern"`
	Description string    `json:"description,omitempty"`
	CreatedAt   time.Time `json:"created_at"`
}

// WhitelistRepo 白名单模式仓储。
type WhitelistRepo struct {
	db *sql.DB
}

func NewWhitelistRepo(db *sql.DB) *WhitelistRepo {
	return &WhitelistRepo{db: db}
}

// Add 添加白名单模式。
func (r *WhitelistRepo) Add(pattern, description string) (*WhitelistEntry, error) {
	res, err := r.db.Exec(`INSERT INTO whitelist (pattern, description) VALUES (?, ?)`, pattern, description)
	if err != nil {
		return nil, err
	}
	id, _ := res.LastInsertId()
	return &WhitelistEntry{
		ID: int(id), Pattern: pattern, Description: description, CreatedAt: time.Now().UTC(),
	}, nil
}

// Remove 按 id 删除白名单模式。
func (r *WhitelistRepo) Remove(id int) (bool, error) {
	res, err := r.db.Exec(`DELETE FROM whitelist WHERE id = ?`, id)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// List 返回所有白名单模式。
func (r *WhitelistRepo) List() ([]*WhitelistEntry, error) {
	return r.queryList(`SELECT id, pattern, COALESCE(description,''), created_at FROM whitelist ORDER BY id`)
}

// Match 检查 command 是否匹配任一白名单模式。返回匹配条目的描述或空字符串。
func (r *WhitelistRepo) Match(command string) (string, bool) {
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

func (r *WhitelistRepo) queryList(query string, args ...interface{}) ([]*WhitelistEntry, error) {
	rows, err := r.db.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*WhitelistEntry
	for rows.Next() {
		e := &WhitelistEntry{}
		if err := rows.Scan(&e.ID, &e.Pattern, &e.Description, &e.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}
