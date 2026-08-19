package store

import (
	"database/sql"
	"time"
)

// CollaborationRunRecord contains only local work metadata and Agent output.
// Provider credentials are never accepted by this repository.
type CollaborationRunRecord struct {
	WorkScope      string
	TransportID    string
	Provider       string
	RepositoryID   string
	ItemKind       string
	ItemNumber     string
	Project        string
	AgentType      string
	AgentSessionID string
	Status         string
	RawText        string
	SummaryJSON    string
	UpdatedAt      time.Time
}

type CollaborationRunRepo struct {
	db *sql.DB
}

func NewCollaborationRunRepo(db *sql.DB) *CollaborationRunRepo {
	return &CollaborationRunRepo{db: db}
}

func (r *CollaborationRunRepo) Upsert(value CollaborationRunRecord) error {
	_, err := r.db.Exec(`
		INSERT INTO collaboration_runs (
			work_scope, transport_id, provider, repository_id, item_kind, item_number,
			project, agent_type, agent_session_id, status, raw_text, summary_json, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(work_scope) DO UPDATE SET
			transport_id=excluded.transport_id,
			provider=excluded.provider,
			repository_id=excluded.repository_id,
			item_kind=excluded.item_kind,
			item_number=excluded.item_number,
			project=excluded.project,
			agent_type=excluded.agent_type,
			agent_session_id=excluded.agent_session_id,
			status=excluded.status,
			raw_text=excluded.raw_text,
			summary_json=excluded.summary_json,
			updated_at=excluded.updated_at`,
		value.WorkScope, value.TransportID, value.Provider, value.RepositoryID,
		value.ItemKind, value.ItemNumber, value.Project, value.AgentType,
		value.AgentSessionID, value.Status, value.RawText, value.SummaryJSON, value.UpdatedAt)
	return err
}

func (r *CollaborationRunRepo) Get(scope string) (*CollaborationRunRecord, error) {
	var value CollaborationRunRecord
	err := r.db.QueryRow(`
		SELECT work_scope, transport_id, provider, repository_id, item_kind, item_number,
		       project, agent_type, agent_session_id, status, raw_text, summary_json, updated_at
		FROM collaboration_runs WHERE work_scope = ?`, scope).Scan(
		&value.WorkScope, &value.TransportID, &value.Provider, &value.RepositoryID,
		&value.ItemKind, &value.ItemNumber, &value.Project, &value.AgentType,
		&value.AgentSessionID, &value.Status, &value.RawText, &value.SummaryJSON, &value.UpdatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &value, nil
}

func (r *CollaborationRunRepo) DeleteOlderThan(cutoff time.Time) error {
	_, err := r.db.Exec(`DELETE FROM collaboration_runs WHERE updated_at < ?`, cutoff)
	return err
}

func (r *CollaborationRunRepo) Delete(scope string) error {
	_, err := r.db.Exec(`DELETE FROM collaboration_runs WHERE work_scope = ?`, scope)
	return err
}
