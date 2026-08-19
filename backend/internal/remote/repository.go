package remote

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

var (
	ErrNotFound       = errors.New("remote resource not found")
	ErrConflict       = errors.New("remote state conflict")
	ErrTicketConsumed = errors.New("remote ticket already consumed")
	ErrTicketExpired  = errors.New("remote ticket expired")
)

type Repository struct {
	db *sql.DB
}

func NewRepository(db *sql.DB) *Repository { return &Repository{db: db} }

func encodeJSON(value any) (string, error) {
	b, err := json.Marshal(value)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

func (r *Repository) UpsertHost(host Host) error {
	caps, err := encodeJSON(host.Capabilities)
	if err != nil {
		return err
	}
	_, err = r.db.Exec(`
		INSERT INTO remote_hosts (
			id, device_fingerprint, display_name, version, capabilities_json, online, last_seen_at, revoked_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET
			device_fingerprint=excluded.device_fingerprint,
			display_name=excluded.display_name,
			version=excluded.version,
			capabilities_json=excluded.capabilities_json,
			online=excluded.online,
			last_seen_at=excluded.last_seen_at`,
		host.ID, host.DeviceFingerprint, host.DisplayName, host.Version, caps,
		boolInt(host.Online), host.LastSeenAt, host.RevokedAt)
	return err
}

func (r *Repository) TouchHost(id string, at time.Time) error {
	result, err := r.db.Exec(`UPDATE remote_hosts SET online=1, last_seen_at=? WHERE id=? AND revoked_at IS NULL`, at, id)
	if err != nil {
		return err
	}
	n, _ := result.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

func (r *Repository) GetHost(id string) (*Host, error) {
	row := r.db.QueryRow(`
		SELECT id, device_fingerprint, display_name, version, capabilities_json, online, last_seen_at, revoked_at
		FROM remote_hosts WHERE id=?`, id)
	return scanHost(row)
}

func (r *Repository) ListHosts() ([]Host, error) {
	rows, err := r.db.Query(`
		SELECT id, device_fingerprint, display_name, version, capabilities_json, online, last_seen_at, revoked_at
		FROM remote_hosts WHERE revoked_at IS NULL ORDER BY display_name, id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Host
	for rows.Next() {
		h, err := scanHost(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *h)
	}
	return out, rows.Err()
}

func (r *Repository) HostCredentialHash(hostID string) (hash string, revoked bool, err error) {
	var revokedAt sql.NullTime
	err = r.db.QueryRow(`
		SELECT token_hash, revoked_at FROM remote_host_credentials WHERE host_id=?`, hostID).Scan(&hash, &revokedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, ErrNotFound
	}
	return hash, revokedAt.Valid, err
}

// HostCredentialAge 返回 credential 的最近轮换时间(rotated_at 优先,否则 created_at)。
// 用于自动轮换策略:超过 maxAge 的 credential 应被拒绝并强制重新轮换。
func (r *Repository) HostCredentialAge(hostID string) (rotatedAt time.Time, err error) {
	var rotated, created sql.NullTime
	err = r.db.QueryRow(`
		SELECT rotated_at, created_at FROM remote_host_credentials WHERE host_id=?`, hostID).Scan(&rotated, &created)
	if errors.Is(err, sql.ErrNoRows) {
		return time.Time{}, ErrNotFound
	}
	if rotated.Valid {
		return rotated.Time, err
	}
	if created.Valid {
		return created.Time, err
	}
	return time.Time{}, err
}

func (r *Repository) SetHostCredential(hostID, tokenHash string, now time.Time) error {
	_, err := r.db.Exec(`
		INSERT INTO remote_host_credentials (host_id, token_hash, created_at)
		VALUES (?, ?, ?)
		ON CONFLICT(host_id) DO UPDATE SET
			token_hash=excluded.token_hash,
			rotated_at=excluded.created_at,
			revoked_at=NULL`, hostID, tokenHash, now)
	return err
}

func (r *Repository) RevokeHostCredential(hostID string, now time.Time) error {
	tx, err := r.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	result, err := tx.Exec(`
		UPDATE remote_host_credentials SET revoked_at=?
		WHERE host_id=? AND revoked_at IS NULL`, now, hostID)
	if err != nil {
		return err
	}
	n, _ := result.RowsAffected()
	if n == 0 {
		return ErrNotFound
	}
	if _, err := tx.Exec(`UPDATE remote_hosts SET online=0 WHERE id=?`, hostID); err != nil {
		return err
	}
	return tx.Commit()
}

type rowScanner interface{ Scan(...any) error }

func scanHost(row rowScanner) (*Host, error) {
	var host Host
	var caps string
	var online int
	var revoked sql.NullTime
	if err := row.Scan(&host.ID, &host.DeviceFingerprint, &host.DisplayName, &host.Version,
		&caps, &online, &host.LastSeenAt, &revoked); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	if err := json.Unmarshal([]byte(caps), &host.Capabilities); err != nil {
		return nil, fmt.Errorf("decode host capabilities: %w", err)
	}
	host.Online = online != 0
	if revoked.Valid {
		host.RevokedAt = &revoked.Time
	}
	return &host, nil
}

func (r *Repository) UpsertAuthorization(id, hostID, controllerID string, capabilities []string, now time.Time) error {
	caps, err := encodeJSON(capabilities)
	if err != nil {
		return err
	}
	_, err = r.db.Exec(`
		INSERT INTO remote_authorizations (
			id, host_id, controller_device_id, mode, capabilities_json, created_at, last_used_at
		) VALUES (?, ?, ?, 'paired', ?, ?, ?)
		ON CONFLICT(host_id, controller_device_id) DO UPDATE SET
			capabilities_json=excluded.capabilities_json,
			last_used_at=excluded.last_used_at`, id, hostID, controllerID, caps, now, now)
	return err
}

func (r *Repository) InsertSession(session Session) error {
	requested, err := encodeJSON(session.RequestedCapabilities)
	if err != nil {
		return err
	}
	granted, err := encodeJSON(session.GrantedCapabilities)
	if err != nil {
		return err
	}
	_, err = r.db.Exec(`
		INSERT INTO remote_sessions (
			id, host_id, controller_device_id, controller_is_primary, primary_approved, state, revision,
			requested_capabilities_json, granted_capabilities_json, transport_type,
			requested_at, updated_at, started_at, ended_at, end_reason
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		session.ID, session.HostID, session.ControllerDeviceID, boolInt(session.ControllerIsPrimary), boolInt(session.PrimaryApproved), session.State, session.Revision,
		requested, granted, session.TransportType, session.RequestedAt, session.UpdatedAt,
		session.StartedAt, session.EndedAt, session.EndReason)
	return err
}

func (r *Repository) GetSession(id string) (*Session, error) {
	row := r.db.QueryRow(`
		SELECT id, host_id, controller_device_id, controller_is_primary, primary_approved, state, revision,
		       requested_capabilities_json, granted_capabilities_json, transport_type,
		       requested_at, updated_at, started_at, ended_at, end_reason
		FROM remote_sessions WHERE id=?`, id)
	return scanSession(row)
}

func (r *Repository) ListSessionsByHostState(hostID, state string) ([]Session, error) {
	rows, err := r.db.Query(`
		SELECT id, host_id, controller_device_id, controller_is_primary, primary_approved, state, revision,
		       requested_capabilities_json, granted_capabilities_json, transport_type,
		       requested_at, updated_at, started_at, ended_at, end_reason
		FROM remote_sessions WHERE host_id=? AND state=? ORDER BY requested_at`, hostID, state)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Session
	for rows.Next() {
		s, err := scanSession(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *s)
	}
	return out, rows.Err()
}

func (r *Repository) ListSessionsByState(state string) ([]Session, error) {
	rows, err := r.db.Query(`
		SELECT id, host_id, controller_device_id, controller_is_primary, primary_approved, state, revision,
		       requested_capabilities_json, granted_capabilities_json, transport_type,
		       requested_at, updated_at, started_at, ended_at, end_reason
		FROM remote_sessions WHERE state=? ORDER BY requested_at`, state)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Session
	for rows.Next() {
		s, err := scanSession(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *s)
	}
	return out, rows.Err()
}

func scanSession(row rowScanner) (*Session, error) {
	var s Session
	var requested, granted string
	var started, ended sql.NullTime
	var controllerIsPrimary, primaryApproved int
	if err := row.Scan(&s.ID, &s.HostID, &s.ControllerDeviceID, &controllerIsPrimary, &primaryApproved, &s.State, &s.Revision,
		&requested, &granted, &s.TransportType, &s.RequestedAt, &s.UpdatedAt,
		&started, &ended, &s.EndReason); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	s.ControllerIsPrimary = controllerIsPrimary != 0
	s.PrimaryApproved = primaryApproved != 0
	if err := json.Unmarshal([]byte(requested), &s.RequestedCapabilities); err != nil {
		return nil, fmt.Errorf("decode requested capabilities: %w", err)
	}
	if err := json.Unmarshal([]byte(granted), &s.GrantedCapabilities); err != nil {
		return nil, fmt.Errorf("decode granted capabilities: %w", err)
	}
	if started.Valid {
		s.StartedAt = &started.Time
	}
	if ended.Valid {
		s.EndedAt = &ended.Time
	}
	return &s, nil
}

// TransitionSession performs a compare-and-swap transition so stale clients
// cannot move a newer revision backwards.
func (r *Repository) TransitionSession(id string, expectedRevision int64, allowedStates []string, nextState string,
	granted []string, transport, endReason string, now time.Time) (*Session, error) {
	tx, err := r.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	row := tx.QueryRow(`
		SELECT id, host_id, controller_device_id, controller_is_primary, primary_approved, state, revision,
		       requested_capabilities_json, granted_capabilities_json, transport_type,
		       requested_at, updated_at, started_at, ended_at, end_reason
		FROM remote_sessions WHERE id=?`, id)
	s, err := scanSession(row)
	if err != nil {
		return nil, err
	}
	if expectedRevision > 0 && s.Revision != expectedRevision {
		return nil, ErrConflict
	}
	if !contains(allowedStates, s.State) {
		return nil, ErrConflict
	}
	if granted == nil {
		granted = s.GrantedCapabilities
	}
	if transport == "" {
		transport = s.TransportType
	}
	grantedJSON, err := encodeJSON(granted)
	if err != nil {
		return nil, err
	}
	nextRevision := s.Revision + 1
	var startedAt any = s.StartedAt
	var endedAt any = s.EndedAt
	if nextState == StateConnectedView || nextState == StateConnectedControl {
		if s.StartedAt == nil {
			startedAt = now
		}
	}
	if IsTerminalState(nextState) {
		endedAt = now
	}
	result, err := tx.Exec(`
		UPDATE remote_sessions
		SET state=?, revision=?, granted_capabilities_json=?, transport_type=?,
		    updated_at=?, started_at=?, ended_at=?, end_reason=?
		WHERE id=? AND revision=?`, nextState, nextRevision, grantedJSON, transport,
		now, startedAt, endedAt, endReason, id, s.Revision)
	if err != nil {
		return nil, err
	}
	n, _ := result.RowsAffected()
	if n != 1 {
		return nil, ErrConflict
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return r.GetSession(id)
}

// ApprovePrimarySession makes a non-primary request eligible for host consent.
// It is deliberately a compare-and-swap transition so only one approval wins.
func (r *Repository) ApprovePrimarySession(id string, expectedRevision int64, now time.Time) (*Session, error) {
	tx, err := r.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	row := tx.QueryRow(`
		SELECT id, host_id, controller_device_id, controller_is_primary, primary_approved, state, revision,
		       requested_capabilities_json, granted_capabilities_json, transport_type,
		       requested_at, updated_at, started_at, ended_at, end_reason
		FROM remote_sessions WHERE id=?`, id)
	s, err := scanSession(row)
	if err != nil {
		return nil, err
	}
	if (expectedRevision > 0 && s.Revision != expectedRevision) || s.State != StateWaitingPrimary {
		return nil, ErrConflict
	}
	result, err := tx.Exec(`UPDATE remote_sessions
		SET state=?, primary_approved=1, revision=?, updated_at=?
		WHERE id=? AND revision=?`, StateWaitingConsent, s.Revision+1, now, id, s.Revision)
	if err != nil {
		return nil, err
	}
	if n, _ := result.RowsAffected(); n != 1 {
		return nil, ErrConflict
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return r.GetSession(id)
}

func (r *Repository) CreateTicketNonce(hash, sessionID, endpointID, role string, revision int64, expiresAt, now time.Time) error {
	_, err := r.db.Exec(`
		INSERT INTO remote_ticket_nonces (
			nonce_hash, session_id, endpoint_id, role, revision, expires_at, created_at
		) VALUES (?, ?, ?, ?, ?, ?, ?)`, hash, sessionID, endpointID, role, revision, expiresAt, now)
	return err
}

func (r *Repository) ConsumeTicketNonce(hash, sessionID, endpointID, role string, revision int64, now time.Time) error {
	result, err := r.db.Exec(`
		UPDATE remote_ticket_nonces SET consumed_at=?
		WHERE nonce_hash=? AND session_id=? AND endpoint_id=? AND role=? AND revision=?
		  AND consumed_at IS NULL AND expires_at>?`, now, hash, sessionID, endpointID, role, revision, now)
	if err != nil {
		return err
	}
	n, _ := result.RowsAffected()
	if n == 1 {
		return nil
	}
	var expires time.Time
	var consumed sql.NullTime
	err = r.db.QueryRow(`SELECT expires_at, consumed_at FROM remote_ticket_nonces WHERE nonce_hash=?`, hash).Scan(&expires, &consumed)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if consumed.Valid {
		return ErrTicketConsumed
	}
	if !expires.After(now) {
		return ErrTicketExpired
	}
	return ErrConflict
}

func (r *Repository) DeleteExpiredTicketNonces(now time.Time) error {
	_, err := r.db.Exec(`DELETE FROM remote_ticket_nonces WHERE expires_at<=?`, now)
	return err
}

func (r *Repository) InsertAudit(event AuditEvent) error {
	metadata, err := encodeJSON(event.SafeMetadata)
	if err != nil {
		return err
	}
	var sessionID any
	if event.SessionID != "" {
		sessionID = event.SessionID
	}
	_, err = r.db.Exec(`
		INSERT INTO remote_audit_events (
			id, session_id, actor_type, actor_id, event_type, safe_metadata_json, client_ip, created_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`, event.ID, sessionID, event.ActorType,
		event.ActorID, event.EventType, metadata, event.ClientIP, event.CreatedAt)
	return err
}

func (r *Repository) ListAudit(controllerID, hostID string, limit int) ([]AuditEvent, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	rows, err := r.db.Query(`
		SELECT a.id, COALESCE(a.session_id, ''), a.actor_type, a.actor_id, a.event_type, a.safe_metadata_json, COALESCE(a.client_ip, ''), a.created_at
		FROM remote_audit_events a
		LEFT JOIN remote_sessions s ON s.id=a.session_id
		WHERE (?='' OR s.controller_device_id=? OR (a.session_id='' AND a.actor_id=?))
		  AND (?='' OR s.host_id=? OR (a.session_id='' AND a.actor_id=?))
		ORDER BY a.created_at DESC LIMIT ?`, controllerID, controllerID, controllerID,
		hostID, hostID, hostID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []AuditEvent
	for rows.Next() {
		var event AuditEvent
		var metadata string
		if err := rows.Scan(&event.ID, &event.SessionID, &event.ActorType, &event.ActorID,
			&event.EventType, &metadata, &event.ClientIP, &event.CreatedAt); err != nil {
			return nil, err
		}
		if err := json.Unmarshal([]byte(metadata), &event.SafeMetadata); err != nil {
			return nil, err
		}
		out = append(out, event)
	}
	return out, rows.Err()
}

// ListRecentAuditEvents returns audit events created since the given time,
// ordered by most recent first. Used by AuditScanner for anomaly detection.
func (r *Repository) ListRecentAuditEvents(since time.Time, limit int) ([]AuditEvent, error) {
	if limit <= 0 || limit > 500 {
		limit = 200
	}
	rows, err := r.db.Query(`
		SELECT id, COALESCE(session_id, ''), actor_type, actor_id, event_type, safe_metadata_json, COALESCE(client_ip, ''), created_at
		FROM remote_audit_events
		WHERE created_at >= ?
		ORDER BY created_at DESC LIMIT ?`, since, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []AuditEvent
	for rows.Next() {
		var event AuditEvent
		var metadata string
		if err := rows.Scan(&event.ID, &event.SessionID, &event.ActorType, &event.ActorID,
			&event.EventType, &metadata, &event.ClientIP, &event.CreatedAt); err != nil {
			return nil, err
		}
		if err := json.Unmarshal([]byte(metadata), &event.SafeMetadata); err != nil {
			return nil, err
		}
		out = append(out, event)
	}
	return out, rows.Err()
}

func contains(values []string, value string) bool {
	for _, item := range values {
		if item == value {
			return true
		}
	}
	return false
}

func boolInt(value bool) int {
	if value {
		return 1
	}
	return 0
}
