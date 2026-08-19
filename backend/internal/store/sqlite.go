package store

import (
	"database/sql"
	"fmt"

	_ "modernc.org/sqlite" // 纯 Go SQLite 驱动,无需 CGO
)

// Open 打开 SQLite 并执行 migration(建表)。
func Open(path string) (*sql.DB, error) {
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, fmt.Errorf("open sqlite: %w", err)
	}
	// 单连接,避免 SQLite 写锁竞争
	db.SetMaxOpenConns(1)
	if err := db.Ping(); err != nil {
		return nil, fmt.Errorf("ping sqlite: %w", err)
	}
	if err := migrate(db); err != nil {
		return nil, fmt.Errorf("migrate: %w", err)
	}
	return db, nil
}

const schema = `
CREATE TABLE IF NOT EXISTS approval_records (
    id            TEXT PRIMARY KEY,
    session_id    TEXT NOT NULL,
    tool_name     TEXT NOT NULL,
    command       TEXT NOT NULL,
    cwd           TEXT,
    risk_level    TEXT NOT NULL,
    rule_reason   TEXT,
    diff          TEXT DEFAULT "",
    decision      TEXT NOT NULL DEFAULT 'pending',
    project       TEXT,
    decided_by        TEXT,
    decided_at        TIMESTAMP,
    created_at        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    timeout_at        TIMESTAMP NOT NULL,
    timeout_notified_at TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_approval_session  ON approval_records(session_id);
CREATE INDEX IF NOT EXISTS idx_approval_decision ON approval_records(decision);
CREATE INDEX IF NOT EXISTS idx_approval_project  ON approval_records(project);
CREATE INDEX IF NOT EXISTS idx_approval_timeout_notified ON approval_records(timeout_notified_at);

CREATE TABLE IF NOT EXISTS whitelist (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    pattern     TEXT NOT NULL UNIQUE,
    description TEXT,
    created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS blacklist (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    pattern     TEXT NOT NULL UNIQUE,
    description TEXT,
    created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS session_memo (
    session_id     TEXT NOT NULL,
    command_hash   TEXT NOT NULL,
    command_sample TEXT NOT NULL,
    created_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (session_id, command_hash)
);

CREATE TABLE IF NOT EXISTS devices (
    id           TEXT PRIMARY KEY,
    device_name  TEXT NOT NULL,
    client_token TEXT NOT NULL UNIQUE,
    paired_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_seen    TIMESTAMP,
    is_primary   INTEGER NOT NULL DEFAULT 0,
    push_token   TEXT,
    push_token_updated_at TIMESTAMP
);

CREATE TABLE IF NOT EXISTS sysinfo_snapshots (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    cpu        REAL NOT NULL,
    mem_used   REAL NOT NULL,
    mem_total  REAL NOT NULL,
    disk_used  REAL NOT NULL,
    disk_total REAL NOT NULL,
    tokens     INTEGER NOT NULL DEFAULT 0,
    gpu        REAL NOT NULL DEFAULT 0,
    cpu_temp   REAL NOT NULL DEFAULT 0,
    gpu_temp   REAL NOT NULL DEFAULT 0,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_sysinfo_created ON sysinfo_snapshots(created_at);

-- Monitoring alerts are deliberately independent from approvals and projects.
-- SQLite supports a partial unique index, so one metric can have only one
-- active lifecycle while historical resolved rows remain available.
CREATE TABLE IF NOT EXISTS monitoring_alerts (
    id          TEXT PRIMARY KEY,
    metric      TEXT NOT NULL,
    level       TEXT NOT NULL,
    title       TEXT NOT NULL,
    message     TEXT NOT NULL,
    value       REAL NOT NULL,
    threshold   REAL NOT NULL,
    state       TEXT NOT NULL DEFAULT 'active',
    created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_seen_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    resolved_at TIMESTAMP
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_monitoring_alert_active_metric
    ON monitoring_alerts(metric) WHERE state = 'active';
CREATE INDEX IF NOT EXISTS idx_monitoring_alert_state_seen
    ON monitoring_alerts(state, last_seen_at DESC);

CREATE TABLE IF NOT EXISTS agent_commands (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    cmd_id      TEXT NOT NULL,
    action      TEXT NOT NULL,
    project     TEXT NOT NULL,
    session_id  TEXT NOT NULL DEFAULT '',
    success     INTEGER NOT NULL DEFAULT 0,
    duration_ms INTEGER NOT NULL DEFAULT 0,
    created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_cmd_created ON agent_commands(created_at);
CREATE INDEX IF NOT EXISTS idx_cmd_action ON agent_commands(action);

CREATE TABLE IF NOT EXISTS session_events (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id  TEXT NOT NULL,
    event_seq   INTEGER NOT NULL,
    project     TEXT NOT NULL,
    status      TEXT NOT NULL,
    detail      TEXT NOT NULL DEFAULT '',
    created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(session_id, event_seq)
);
CREATE INDEX IF NOT EXISTS idx_session_event_created ON session_events(created_at);

CREATE TABLE IF NOT EXISTS collaboration_runs (
    work_scope       TEXT PRIMARY KEY,
    transport_id     TEXT NOT NULL DEFAULT '',
    provider         TEXT NOT NULL DEFAULT '',
    repository_id    TEXT NOT NULL DEFAULT '',
    item_kind        TEXT NOT NULL DEFAULT '',
    item_number      TEXT NOT NULL DEFAULT '',
    project          TEXT NOT NULL DEFAULT '',
    agent_type       TEXT NOT NULL DEFAULT '',
    agent_session_id TEXT NOT NULL DEFAULT '',
    status           TEXT NOT NULL DEFAULT 'working',
    raw_text         TEXT NOT NULL DEFAULT '',
    summary_json     TEXT NOT NULL DEFAULT '',
    updated_at       TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_collaboration_run_updated ON collaboration_runs(updated_at);

CREATE TABLE IF NOT EXISTS remote_hosts (
    id                TEXT PRIMARY KEY,
    device_fingerprint TEXT NOT NULL UNIQUE,
    display_name      TEXT NOT NULL,
    version           TEXT NOT NULL DEFAULT '',
    capabilities_json TEXT NOT NULL DEFAULT '{}',
    online            INTEGER NOT NULL DEFAULT 0,
    last_seen_at      TIMESTAMP NOT NULL,
    revoked_at        TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_remote_hosts_seen ON remote_hosts(last_seen_at);

-- Remote Host operational credentials are separate from the global Hook
-- bootstrap secret. Only a SHA-256 hash is persisted; the raw credential is
-- returned once when it is issued or explicitly rotated.
CREATE TABLE IF NOT EXISTS remote_host_credentials (
    host_id      TEXT PRIMARY KEY,
    token_hash   TEXT NOT NULL,
    created_at   TIMESTAMP NOT NULL,
    rotated_at   TIMESTAMP,
    revoked_at   TIMESTAMP,
    FOREIGN KEY(host_id) REFERENCES remote_hosts(id)
);

CREATE TABLE IF NOT EXISTS remote_authorizations (
    id                   TEXT PRIMARY KEY,
    host_id              TEXT NOT NULL,
    controller_device_id TEXT NOT NULL,
    mode                 TEXT NOT NULL DEFAULT 'paired',
    capabilities_json    TEXT NOT NULL DEFAULT '["view"]',
    created_at           TIMESTAMP NOT NULL,
    last_used_at         TIMESTAMP NOT NULL,
    expires_at           TIMESTAMP,
    revoked_at           TIMESTAMP,
    UNIQUE(host_id, controller_device_id),
    FOREIGN KEY(host_id) REFERENCES remote_hosts(id),
    FOREIGN KEY(controller_device_id) REFERENCES devices(id)
);
CREATE INDEX IF NOT EXISTS idx_remote_authorizations_controller
    ON remote_authorizations(controller_device_id);

CREATE TABLE IF NOT EXISTS remote_sessions (
    id                          TEXT PRIMARY KEY,
    host_id                     TEXT NOT NULL,
    controller_device_id        TEXT NOT NULL,
    controller_is_primary       INTEGER NOT NULL DEFAULT 0,
    primary_approved            INTEGER NOT NULL DEFAULT 0,
    state                       TEXT NOT NULL,
    revision                    INTEGER NOT NULL DEFAULT 1,
    requested_capabilities_json TEXT NOT NULL DEFAULT '["view"]',
    granted_capabilities_json   TEXT NOT NULL DEFAULT '[]',
    transport_type              TEXT NOT NULL DEFAULT '',
    requested_at                TIMESTAMP NOT NULL,
    updated_at                  TIMESTAMP NOT NULL,
    started_at                  TIMESTAMP,
    ended_at                    TIMESTAMP,
    end_reason                  TEXT NOT NULL DEFAULT '',
    FOREIGN KEY(host_id) REFERENCES remote_hosts(id),
    FOREIGN KEY(controller_device_id) REFERENCES devices(id)
);
CREATE INDEX IF NOT EXISTS idx_remote_sessions_host ON remote_sessions(host_id, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_remote_sessions_controller ON remote_sessions(controller_device_id, updated_at DESC);

CREATE TABLE IF NOT EXISTS remote_ticket_nonces (
    nonce_hash   TEXT PRIMARY KEY,
    session_id   TEXT NOT NULL,
    endpoint_id  TEXT NOT NULL,
    role         TEXT NOT NULL,
    revision     INTEGER NOT NULL,
    expires_at   TIMESTAMP NOT NULL,
    consumed_at  TIMESTAMP,
    created_at   TIMESTAMP NOT NULL,
    FOREIGN KEY(session_id) REFERENCES remote_sessions(id)
);
CREATE INDEX IF NOT EXISTS idx_remote_ticket_session ON remote_ticket_nonces(session_id);
CREATE INDEX IF NOT EXISTS idx_remote_ticket_expiry ON remote_ticket_nonces(expires_at);

CREATE TABLE IF NOT EXISTS remote_audit_events (
    id                 TEXT PRIMARY KEY,
    session_id         TEXT,
    actor_type         TEXT NOT NULL,
    actor_id           TEXT NOT NULL,
    event_type         TEXT NOT NULL,
    safe_metadata_json TEXT NOT NULL DEFAULT '{}',
    client_ip          TEXT NOT NULL DEFAULT '',
    created_at         TIMESTAMP NOT NULL,
    FOREIGN KEY(session_id) REFERENCES remote_sessions(id)
);
CREATE INDEX IF NOT EXISTS idx_remote_audit_session ON remote_audit_events(session_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_remote_audit_actor ON remote_audit_events(actor_id, created_at DESC);
`

func migrate(db *sql.DB) error {
	// 兼容旧数据库：如果 project 列不存在则 ALTER TABLE 添加
	var hasProject int
	err := db.QueryRow("SELECT COUNT(*) FROM pragma_table_info('approval_records') WHERE name='project'").Scan(&hasProject)
	if err == nil && hasProject == 0 {
		db.Exec("ALTER TABLE approval_records ADD COLUMN project TEXT")
	}
	// 兼容旧 approval_records：如果 diff 列不存在则补上
	var hasDiff int
	if e := db.QueryRow("SELECT COUNT(*) FROM pragma_table_info('approval_records') WHERE name='diff'").Scan(&hasDiff); e == nil && hasDiff == 0 {
		db.Exec("ALTER TABLE approval_records ADD COLUMN diff TEXT DEFAULT ''")
	}
	// 兼容旧 approval_records：补充 timeout_notified_at 列用于超时通知持久化去重
	// 必须在 db.Exec(schema) 之前执行，因为 schema 中包含引用此列的 CREATE INDEX。
	// （内存 map 重启即失，DB 列确保每个审批只推送一次超时通知）
	var hasTimeoutNotified int
	if e := db.QueryRow("SELECT COUNT(*) FROM pragma_table_info('approval_records') WHERE name='timeout_notified_at'").Scan(&hasTimeoutNotified); e == nil && hasTimeoutNotified == 0 {
		db.Exec("ALTER TABLE approval_records ADD COLUMN timeout_notified_at TIMESTAMP")
	}
	// 兼容旧 sysinfo_snapshots：如果 gpu 列不存在则补上
	var hasGpu int
	if e := db.QueryRow("SELECT COUNT(*) FROM pragma_table_info('sysinfo_snapshots') WHERE name='gpu'").Scan(&hasGpu); e == nil && hasGpu == 0 {
		db.Exec("ALTER TABLE sysinfo_snapshots ADD COLUMN gpu REAL NOT NULL DEFAULT 0")
	}
	// 兼容旧 sysinfo_snapshots：如果 cpu_temp 列不存在则补上
	var hasCpuTemp int
	if e := db.QueryRow("SELECT COUNT(*) FROM pragma_table_info('sysinfo_snapshots') WHERE name='cpu_temp'").Scan(&hasCpuTemp); e == nil && hasCpuTemp == 0 {
		db.Exec("ALTER TABLE sysinfo_snapshots ADD COLUMN cpu_temp REAL NOT NULL DEFAULT 0")
	}
	// 兼容旧 sysinfo_snapshots：如果 gpu_temp 列不存在则补上
	var hasGpuTemp int
	if e := db.QueryRow("SELECT COUNT(*) FROM pragma_table_info('sysinfo_snapshots') WHERE name='gpu_temp'").Scan(&hasGpuTemp); e == nil && hasGpuTemp == 0 {
		db.Exec("ALTER TABLE sysinfo_snapshots ADD COLUMN gpu_temp REAL NOT NULL DEFAULT 0")
	}
	// 创建/更新表和索引
	if _, err = db.Exec(schema); err != nil {
		return err
	}
	// 兼容旧 remote_audit_events：补充 client_ip 列用于安全审计
	var hasAuditIP int
	if e := db.QueryRow("SELECT COUNT(*) FROM pragma_table_info('remote_audit_events') WHERE name='client_ip'").Scan(&hasAuditIP); e == nil && hasAuditIP == 0 {
		db.Exec("ALTER TABLE remote_audit_events ADD COLUMN client_ip TEXT NOT NULL DEFAULT ''")
	}
	// 兼容旧 agent_commands：补充会话标识，供动态页准确关联最近会话。
	var hasCommandSession int
	if e := db.QueryRow("SELECT COUNT(*) FROM pragma_table_info('agent_commands') WHERE name='session_id'").Scan(&hasCommandSession); e == nil && hasCommandSession == 0 {
		if _, e = db.Exec("ALTER TABLE agent_commands ADD COLUMN session_id TEXT NOT NULL DEFAULT ''"); e != nil {
			return e
		}
	}
	// 兼容旧 devices：补充 is_primary 列用于主设备注册
	var hasIsPrimary int
	if e := db.QueryRow("SELECT COUNT(*) FROM pragma_table_info('devices') WHERE name='is_primary'").Scan(&hasIsPrimary); e == nil && hasIsPrimary == 0 {
		db.Exec("ALTER TABLE devices ADD COLUMN is_primary INTEGER NOT NULL DEFAULT 0")
	}
	// Push Kit token is server-side write-only state. Existing personal
	// databases are upgraded in place without exposing or regenerating device
	// credentials.
	var hasPushToken int
	if e := db.QueryRow("SELECT COUNT(*) FROM pragma_table_info('devices') WHERE name='push_token'").Scan(&hasPushToken); e == nil && hasPushToken == 0 {
		if _, e = db.Exec("ALTER TABLE devices ADD COLUMN push_token TEXT"); e != nil {
			return e
		}
	}
	var hasPushTokenUpdatedAt int
	if e := db.QueryRow("SELECT COUNT(*) FROM pragma_table_info('devices') WHERE name='push_token_updated_at'").Scan(&hasPushTokenUpdatedAt); e == nil && hasPushTokenUpdatedAt == 0 {
		if _, e = db.Exec("ALTER TABLE devices ADD COLUMN push_token_updated_at TIMESTAMP"); e != nil {
			return e
		}
	}
	// These columns were added after the initial remote-session schema. Keep
	// existing personal databases upgrade-safe instead of assuming a new DB.
	var hasControllerIsPrimary int
	if e := db.QueryRow("SELECT COUNT(*) FROM pragma_table_info('remote_sessions') WHERE name='controller_is_primary'").Scan(&hasControllerIsPrimary); e == nil && hasControllerIsPrimary == 0 {
		if _, e = db.Exec("ALTER TABLE remote_sessions ADD COLUMN controller_is_primary INTEGER NOT NULL DEFAULT 0"); e != nil {
			return e
		}
	}
	var hasPrimaryApproved int
	if e := db.QueryRow("SELECT COUNT(*) FROM pragma_table_info('remote_sessions') WHERE name='primary_approved'").Scan(&hasPrimaryApproved); e == nil && hasPrimaryApproved == 0 {
		if _, e = db.Exec("ALTER TABLE remote_sessions ADD COLUMN primary_approved INTEGER NOT NULL DEFAULT 0"); e != nil {
			return e
		}
	}
	return nil
}
