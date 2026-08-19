package store

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"fmt"
	"time"
)

// MonitoringObservation is the bounded telemetry contract accepted from the
// local agent. The API validates the metric before it reaches this repository.
type MonitoringObservation struct {
	Metric    string
	Value     float64
	Threshold float64
	Active    bool
}

// MonitoringAlertRecord is a persisted lifecycle record, not an approval.
type MonitoringAlertRecord struct {
	ID         string     `json:"id"`
	Metric     string     `json:"metric"`
	Level      string     `json:"level"`
	Title      string     `json:"title"`
	Message    string     `json:"message"`
	Value      float64    `json:"value"`
	Threshold  float64    `json:"threshold"`
	State      string     `json:"state"`
	CreatedAt  time.Time  `json:"created_at"`
	LastSeenAt time.Time  `json:"last_seen_at"`
	ResolvedAt *time.Time `json:"resolved_at,omitempty"`
}

type MonitoringAlertSummary struct {
	Active int `json:"active"`
	Total  int `json:"total"`
}

type MonitoringAlertRepo struct{ db *sql.DB }

func NewMonitoringAlertRepo(db *sql.DB) *MonitoringAlertRepo { return &MonitoringAlertRepo{db: db} }

func newMonitoringAlertID() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// Observe atomically opens, refreshes, or resolves alert lifecycles. Returned
// records are newly opened alerts only and are the sole source of push notices.
func (r *MonitoringAlertRepo) Observe(ctx context.Context, observations []MonitoringObservation) ([]MonitoringAlertRecord, error) {
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()

	opened := make([]MonitoringAlertRecord, 0)
	for _, observation := range observations {
		if observation.Active {
			var exists string
			err := tx.QueryRowContext(ctx, `SELECT id FROM monitoring_alerts WHERE metric = ? AND state = 'active' LIMIT 1`, observation.Metric).Scan(&exists)
			if err == nil {
				if _, err = tx.ExecContext(ctx, `UPDATE monitoring_alerts SET value = ?, threshold = ?, last_seen_at = CURRENT_TIMESTAMP WHERE id = ?`, observation.Value, observation.Threshold, exists); err != nil {
					return nil, err
				}
				continue
			}
			if err != sql.ErrNoRows {
				return nil, err
			}

			id, err := newMonitoringAlertID()
			if err != nil {
				return nil, fmt.Errorf("new monitoring alert id: %w", err)
			}
			level, title, message := monitoringAlertPresentation(observation)
			if _, err = tx.ExecContext(ctx, `INSERT INTO monitoring_alerts (id, metric, level, title, message, value, threshold, state) VALUES (?, ?, ?, ?, ?, ?, ?, 'active')`, id, observation.Metric, level, title, message, observation.Value, observation.Threshold); err != nil {
				return nil, err
			}
			var record MonitoringAlertRecord
			if err = scanMonitoringAlert(tx.QueryRowContext(ctx, monitoringAlertSelect+` WHERE id = ?`, id), &record); err != nil {
				return nil, err
			}
			opened = append(opened, record)
		} else {
			if _, err = tx.ExecContext(ctx, `UPDATE monitoring_alerts SET state = 'resolved', last_seen_at = CURRENT_TIMESTAMP, resolved_at = CURRENT_TIMESTAMP WHERE metric = ? AND state = 'active'`, observation.Metric); err != nil {
				return nil, err
			}
		}
	}
	if err = tx.Commit(); err != nil {
		return nil, err
	}
	return opened, nil
}

func monitoringAlertPresentation(o MonitoringObservation) (string, string, string) {
	name, unit := "系统资源", "%"
	switch o.Metric {
	case "cpu":
		name = "CPU 占用"
	case "gpu":
		name = "GPU 占用"
	case "gpu_temp":
		name, unit = "GPU 温度", "°C"
	case "mem":
		name = "内存占用"
	}
	level := "warning"
	if o.Value >= o.Threshold+10 {
		level = "critical"
	}
	return level, name + "过高", fmt.Sprintf("当前 %.1f%s，阈值 %.1f%s", o.Value, unit, o.Threshold, unit)
}

const monitoringAlertSelect = `SELECT id, metric, level, title, message, value, threshold, state, created_at, last_seen_at, resolved_at FROM monitoring_alerts`

type rowScanner interface{ Scan(...interface{}) error }

func scanMonitoringAlert(row rowScanner, record *MonitoringAlertRecord) error {
	return row.Scan(&record.ID, &record.Metric, &record.Level, &record.Title, &record.Message, &record.Value, &record.Threshold, &record.State, &record.CreatedAt, &record.LastSeenAt, &record.ResolvedAt)
}

func (r *MonitoringAlertRepo) List(ctx context.Context, state string, limit, offset int) ([]MonitoringAlertRecord, int, error) {
	where, args := "", []interface{}{}
	if state != "" {
		where, args = " WHERE state = ?", append(args, state)
	}
	var total int
	if err := r.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM monitoring_alerts`+where, args...).Scan(&total); err != nil {
		return nil, 0, err
	}
	args = append(args, limit, offset)
	rows, err := r.db.QueryContext(ctx, monitoringAlertSelect+where+` ORDER BY CASE state WHEN 'active' THEN 0 ELSE 1 END, last_seen_at DESC LIMIT ? OFFSET ?`, args...)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	items := make([]MonitoringAlertRecord, 0)
	for rows.Next() {
		var item MonitoringAlertRecord
		if err := scanMonitoringAlert(rows, &item); err != nil {
			return nil, 0, err
		}
		items = append(items, item)
	}
	return items, total, rows.Err()
}

func (r *MonitoringAlertRepo) Detail(ctx context.Context, id string) (MonitoringAlertRecord, error) {
	var record MonitoringAlertRecord
	err := scanMonitoringAlert(r.db.QueryRowContext(ctx, monitoringAlertSelect+` WHERE id = ?`, id), &record)
	return record, err
}

func (r *MonitoringAlertRepo) Summary(ctx context.Context) (MonitoringAlertSummary, error) {
	var summary MonitoringAlertSummary
	err := r.db.QueryRowContext(ctx, `SELECT COALESCE(SUM(CASE WHEN state = 'active' THEN 1 ELSE 0 END), 0), COUNT(*) FROM monitoring_alerts`).Scan(&summary.Active, &summary.Total)
	return summary, err
}
