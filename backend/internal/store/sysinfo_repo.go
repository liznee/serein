package store

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

type SysInfoSnapshot struct {
	ID        int64     `json:"id"`
	CPU       float64   `json:"cpu"`
	MemUsed   float64   `json:"mem_used"`
	MemTotal  float64   `json:"mem_total"`
	DiskUsed  float64   `json:"disk_used"`
	DiskTotal float64   `json:"disk_total"`
	Tokens    int64     `json:"tokens"`
	GPU       float64   `json:"gpu"`
	CPUTemp   float64   `json:"cpu_temp"`
	GPUTemp   float64   `json:"gpu_temp"`
	CreatedAt time.Time `json:"created_at"`
}

type SysInfoRepo struct {
	db *sql.DB
}

func NewSysInfoRepo(db *sql.DB) *SysInfoRepo {
	return &SysInfoRepo{db: db}
}

// DB 返回底层 *sql.DB，供其他 Repo 共享连接。
func (r *SysInfoRepo) DB() *sql.DB {
	return r.db
}

// Save 插入一条 sysinfo 快照，使用传入 context 控制超时。
func (r *SysInfoRepo) Save(ctx context.Context, cpu, memUsed, memTotal, diskUsed, diskTotal float64, tokens int64, gpu, cpuTemp, gpuTemp float64) error {
	_, err := r.db.ExecContext(ctx,
		`INSERT INTO sysinfo_snapshots (cpu, mem_used, mem_total, disk_used, disk_total, tokens, gpu, cpu_temp, gpu_temp) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		cpu, memUsed, memTotal, diskUsed, diskTotal, tokens, gpu, cpuTemp, gpuTemp,
	)
	return err
}

// RecentN 返回最近 N 条快照（按时间升序）。
func (r *SysInfoRepo) RecentN(n int) ([]SysInfoSnapshot, error) {
	rows, err := r.db.Query(
		`SELECT id, cpu, mem_used, mem_total, disk_used, disk_total, tokens, gpu, cpu_temp, gpu_temp, created_at FROM sysinfo_snapshots ORDER BY created_at DESC LIMIT ?`,
		n,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var snaps []SysInfoSnapshot
	for rows.Next() {
		var s SysInfoSnapshot
		if err := rows.Scan(&s.ID, &s.CPU, &s.MemUsed, &s.MemTotal, &s.DiskUsed, &s.DiskTotal, &s.Tokens, &s.GPU, &s.CPUTemp, &s.GPUTemp, &s.CreatedAt); err != nil {
			return nil, err
		}
		snaps = append(snaps, s)
	}
	// 反转成升序
	for i, j := 0, len(snaps)-1; i < j; i, j = i+1, j-1 {
		snaps[i], snaps[j] = snaps[j], snaps[i]
	}
	return snaps, nil
}

// DailyStats 每日聚合统计（token/资源趋势用）
type DailyStats struct {
	Date    string  `json:"date"`
	CPU     float64 `json:"cpu_avg"`
	GPU     float64 `json:"gpu_avg"`
	MemPct  float64 `json:"mem_pct_avg"`
	Tokens  int64   `json:"tokens"`   // 当天最后一条的 token 累计值
	CostCny float64 `json:"cost_cny"` // 估算成本
	CPUTemp float64 `json:"cpu_temp_avg"`
	GPUTemp float64 `json:"gpu_temp_avg"`
}

// DailyAggregates 返回最近 N 天的每日聚合统计。
// token 取每天最后一条快照的值（累计值），cpu/gpu/mem 取当天平均值。
func (r *SysInfoRepo) DailyAggregates(days int) ([]DailyStats, error) {
	rows, err := r.db.Query(`
SELECT
  date(created_at) AS d,
  AVG(cpu) AS cpu_avg,
  AVG(gpu) AS gpu_avg,
  AVG(CASE WHEN mem_total > 0 THEN mem_used/mem_total*100 ELSE 0 END) AS mem_pct_avg,
  MAX(tokens) AS max_tokens,
  AVG(cpu_temp) AS cpu_temp_avg,
  AVG(gpu_temp) AS gpu_temp_avg
FROM sysinfo_snapshots
WHERE created_at >= datetime('now', ?)
GROUP BY date(created_at)
ORDER BY d ASC`, fmt.Sprintf("-%d days", days))
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var result []DailyStats
	for rows.Next() {
		var d DailyStats
		var maxTok float64
		if err := rows.Scan(&d.Date, &d.CPU, &d.GPU, &d.MemPct, &maxTok, &d.CPUTemp, &d.GPUTemp); err != nil {
			return nil, err
		}
		d.Tokens = int64(maxTok)
		// 粗略成本估算: input+output 平均 ¥1.5/百万 token
		d.CostCny = maxTok / 1_000_000 * 1.5
		result = append(result, d)
	}
	return result, nil
}

// HourlyResource 返回最近 24 小时的 CPU/GPU 平均值（按小时聚合，资源趋势图用）
type HourlyResource struct {
	Hour    string  `json:"hour"`
	CPU     float64 `json:"cpu"`
	GPU     float64 `json:"gpu"`
	CPUTemp float64 `json:"cpu_temp"`
	GPUTemp float64 `json:"gpu_temp"`
}

func (r *SysInfoRepo) HourlyResource(hours int) ([]HourlyResource, error) {
	rows, err := r.db.Query(`
SELECT
  strftime('%H:00', created_at) AS h,
  AVG(cpu), AVG(gpu), AVG(cpu_temp), AVG(gpu_temp)
FROM sysinfo_snapshots
WHERE created_at >= datetime('now', ?)
GROUP BY strftime('%Y-%m-%d %H', created_at)
ORDER BY created_at ASC
LIMIT ?`, fmt.Sprintf("-%d hours", hours), hours)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []HourlyResource
	for rows.Next() {
		var h HourlyResource
		if err := rows.Scan(&h.Hour, &h.CPU, &h.GPU, &h.CPUTemp, &h.GPUTemp); err != nil {
			return nil, err
		}
		result = append(result, h)
	}
	return result, nil
}
