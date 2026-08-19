package store

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

// Device 已配对设备。
type Device struct {
	ID          string    `json:"id"`
	DeviceName  string    `json:"device_name"`
	ClientToken string    `json:"client_token"`
	PairedAt    time.Time `json:"paired_at"`
	LastSeen    time.Time `json:"last_seen,omitempty"`
	IsPrimary   bool      `json:"is_primary"`
}

// PushTarget is deliberately separate from Device so a Push Kit token can
// never leak through an existing device JSON response or diagnostic log.
type PushTarget struct {
	DeviceID string
	Token    string
}

// DeviceRepo 设备配对仓储。
type DeviceRepo struct {
	db *sql.DB
}

func NewDeviceRepo(db *sql.DB) *DeviceRepo {
	return &DeviceRepo{db: db}
}

// Pair 创建新设备配对。pairCode 已由调用方校验。
func (r *DeviceRepo) Pair(id, deviceName, clientToken string) (*Device, error) {
	now := time.Now().UTC()
	// Pairing is intentionally single-device. The conditional insert keeps the
	// check and creation atomic, so two simultaneous QR scans cannot both win.
	result, err := r.db.Exec(`
INSERT INTO devices (id, device_name, client_token, paired_at, last_seen)
SELECT ?, ?, ?, ?, ?
WHERE NOT EXISTS (SELECT 1 FROM devices)`, id, deviceName, clientToken, now, now)
	if err != nil {
		return nil, err
	}
	if inserted, _ := result.RowsAffected(); inserted != 1 {
		return nil, ErrDeviceAlreadyPaired
	}
	return &Device{
		ID: id, DeviceName: deviceName, ClientToken: clientToken,
		PairedAt: now, LastSeen: now,
	}, nil
}

// ByClientToken 按 client_token 查找设备。
func (r *DeviceRepo) ByClientToken(ctx context.Context, token string) (*Device, error) {
	d := &Device{}
	var lastSeen sql.NullTime
	err := r.db.QueryRowContext(ctx, `
SELECT id, device_name, client_token, paired_at, last_seen, is_primary FROM devices WHERE client_token = ?`, token).
		Scan(&d.ID, &d.DeviceName, &d.ClientToken, &d.PairedAt, &lastSeen, &d.IsPrimary)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if lastSeen.Valid {
		d.LastSeen = lastSeen.Time
	}
	return d, nil
}

// TouchLastSeen 更新设备最后活跃时间。
func (r *DeviceRepo) TouchLastSeen(token string) error {
	_, err := r.db.Exec(`UPDATE devices SET last_seen = ? WHERE client_token = ?`, time.Now().UTC(), token)
	return err
}

// SetPushToken stores the system Push Kit token for one authenticated device.
// The token is write-only at the HTTP layer and must never be logged.
func (r *DeviceRepo) SetPushToken(deviceID, token string) error {
	res, err := r.db.Exec(`
UPDATE devices
SET push_token = ?, push_token_updated_at = ?
WHERE id = ?`, token, time.Now().UTC(), deviceID)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrDeviceNotFound
	}
	return nil
}

// PushTargets returns only registered Push Kit targets. Callers must treat the
// returned tokens as credentials and avoid including them in logs or errors.
func (r *DeviceRepo) PushTargets(ctx context.Context) ([]PushTarget, error) {
	rows, err := r.db.QueryContext(ctx, `
SELECT id, push_token
FROM devices
WHERE push_token IS NOT NULL AND push_token <> ''
ORDER BY paired_at ASC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	targets := make([]PushTarget, 0, 1)
	for rows.Next() {
		var target PushTarget
		if err := rows.Scan(&target.DeviceID, &target.Token); err != nil {
			return nil, err
		}
		targets = append(targets, target)
	}
	return targets, rows.Err()
}

// List 返回所有已配对设备。
func (r *DeviceRepo) List() ([]*Device, error) {
	rows, err := r.db.Query(`SELECT id, device_name, client_token, paired_at, last_seen, is_primary FROM devices ORDER BY paired_at DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*Device
	for rows.Next() {
		d := &Device{}
		var lastSeen sql.NullTime
		if err := rows.Scan(&d.ID, &d.DeviceName, &d.ClientToken, &d.PairedAt, &lastSeen, &d.IsPrimary); err != nil {
			return nil, err
		}
		if lastSeen.Valid {
			d.LastSeen = lastSeen.Time
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

// Primary returns the one device currently allowed to authorize sensitive
// remote-control requests. A nil result is valid when no device has claimed
// that role yet.
func (r *DeviceRepo) Primary(ctx context.Context) (*Device, error) {
	d := &Device{}
	var lastSeen sql.NullTime
	err := r.db.QueryRowContext(ctx, `
SELECT id, device_name, client_token, paired_at, last_seen, is_primary
FROM devices WHERE is_primary = 1 LIMIT 1`).Scan(
		&d.ID, &d.DeviceName, &d.ClientToken, &d.PairedAt, &lastSeen, &d.IsPrimary)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if lastSeen.Valid {
		d.LastSeen = lastSeen.Time
	}
	return d, nil
}

// Unpair 删除设备配对(吊销 CLIENT_TOKEN)。
func (r *DeviceRepo) Unpair(token string) error {
	_, err := r.db.Exec(`DELETE FROM devices WHERE client_token = ?`, token)
	return err
}

// SetPrimary 将指定设备标记为主设备，同时取消其他设备的主设备标记。
// 同一时间只有一台设备可以是主设备。
func (r *DeviceRepo) SetPrimary(deviceID string) error {
	tx, err := r.db.Begin()
	if err != nil {
		return err
	}
	// 先取消所有设备的主设备标记
	if _, err := tx.Exec(`UPDATE devices SET is_primary = 0`); err != nil {
		tx.Rollback()
		return err
	}
	// 再设置目标设备为主设备
	res, err := tx.Exec(`UPDATE devices SET is_primary = 1 WHERE id = ?`, deviceID)
	if err != nil {
		tx.Rollback()
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		tx.Rollback()
		return ErrDeviceNotFound
	}
	return tx.Commit()
}

// ClearPrimary 取消指定设备的主设备标记。
// 如果该设备本来就不是主设备，操作无效但返回 nil（幂等）。
func (r *DeviceRepo) ClearPrimary(deviceID string) error {
	_, err := r.db.Exec(`UPDATE devices SET is_primary = 0 WHERE id = ?`, deviceID)
	return err
}

// ErrDeviceNotFound 设备不存在。
var ErrDeviceNotFound = errors.New("device not found")
var ErrDeviceAlreadyPaired = errors.New("a device is already paired")
