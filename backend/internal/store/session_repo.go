package store

import (
	"crypto/sha256"
	"database/sql"
	"fmt"
	"time"
)

// SessionMemo 会话记忆条目。
type SessionMemo struct {
	SessionID     string    `json:"session_id"`
	CommandHash   string    `json:"command_hash"`
	CommandSample string    `json:"command_sample"`
	CreatedAt     time.Time `json:"created_at"`
}

// SessionRepo 会话记忆仓储。按 (session_id, command_hash) 去重。
type SessionRepo struct {
	db *sql.DB
}

func NewSessionRepo(db *sql.DB) *SessionRepo {
	return &SessionRepo{db: db}
}

// HashCommand 返回命令的 SHA256 哈希(用于会话记忆去重)。
func HashCommand(command string) string {
	h := sha256.Sum256([]byte(command))
	return fmt.Sprintf("%x", h)
}

// Remember 记录审批结果。同 session 同命令已存在时静默忽略。
func (r *SessionRepo) Remember(sessionID, command string) error {
	hash := HashCommand(command)
	now := time.Now().UTC()
	_, err := r.db.Exec(`
INSERT OR IGNORE INTO session_memo (session_id, command_hash, command_sample, created_at)
VALUES (?, ?, ?, ?)`, sessionID, hash, truncate(command, 200), now)
	return err
}

// IsKnown 检查 session 内是否已审批过该命令。
func (r *SessionRepo) IsKnown(sessionID, command string) (bool, error) {
	hash := HashCommand(command)
	var count int
	err := r.db.QueryRow(`SELECT COUNT(*) FROM session_memo WHERE session_id = ? AND command_hash = ?`, sessionID, hash).Scan(&count)
	if err != nil {
		return false, err
	}
	return count > 0, nil
}

// ForgetSession 清除指定 session 的所有记忆(会话结束或重置)。
func (r *SessionRepo) ForgetSession(sessionID string) error {
	_, err := r.db.Exec(`DELETE FROM session_memo WHERE session_id = ?`, sessionID)
	return err
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}
