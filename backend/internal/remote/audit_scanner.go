package remote

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"serein/internal/notify"
)

// AuditScanner periodically scans remote_audit_events for security-relevant
// events and sends ntfy alerts when anomalies are detected.
//
// Alert conditions:
//   - remote.host.credential_expired  → immediate alert
//   - remote.host.credential_revoked  → immediate alert
//   - remote.session.failed            → immediate alert
//   - Same IP with 5+ rejected/auth events in one scan window → alert
//
// Deduplication: the same alert type is not re-sent within dedupWindow to
// avoid alert fatigue during sustained attacks.
type AuditScanner struct {
	repo      *Repository
	publisher *notify.Publisher
	interval  time.Duration
	lastScan  time.Time
	lastAlert map[string]time.Time
}

// NewAuditScanner creates a scanner that checks for security anomalies every
// interval. Pass nil publisher to run in dry-run mode (logs only, no ntfy).
func NewAuditScanner(repo *Repository, publisher *notify.Publisher, interval time.Duration) *AuditScanner {
	if interval <= 0 {
		interval = 60 * time.Second
	}
	return &AuditScanner{
		repo:      repo,
		publisher: publisher,
		interval:  interval,
		lastAlert: make(map[string]time.Time),
	}
}

// Start runs the scanner loop until ctx is cancelled. It blocks; call with go.
func (s *AuditScanner) Start(ctx context.Context) {
	s.lastScan = time.Now().UTC()
	slog.Info("audit scanner started", slog.Duration("interval", s.interval))
	ticker := time.NewTicker(s.interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			slog.Info("audit scanner stopped")
			return
		case <-ticker.C:
			s.scan(ctx)
		}
	}
}

// alertEventTypes are events that should trigger an immediate ntfy alert.
var alertEventTypes = map[string]bool{
	"remote.host.credential_expired": true,
	"remote.host.credential_revoked": true,
	"remote.session.failed":          true,
}

// dedupWindow prevents re-alerting for the same key within this period.
const dedupWindow = 5 * time.Minute

// rejectThreshold is the minimum number of rejection/auth-failure events from
// a single IP in one scan window to trigger an alert.
const rejectThreshold = 5

func (s *AuditScanner) scan(ctx context.Context) {
	now := time.Now().UTC()
	since := s.lastScan
	s.lastScan = now

	events, err := s.repo.ListRecentAuditEvents(since, 200)
	if err != nil {
		slog.Warn("audit scanner: query failed", slog.String("err", err.Error()))
		return
	}
	if len(events) == 0 {
		return
	}

	// Group events by type for counting
	typeCounts := make(map[string]int)
	ipRejectCounts := make(map[string]int)

	for _, event := range events {
		if alertEventTypes[event.EventType] {
			typeCounts[event.EventType]++
		}
		// Track auth rejections by IP (for rate-based alerting)
		if strings.Contains(event.EventType, "rejected") || strings.Contains(event.EventType, "auth") {
			if event.ClientIP != "" {
				ipRejectCounts[event.ClientIP]++
			}
		}
	}

	// Alert for critical event types
	for eventType, count := range typeCounts {
		key := "event:" + eventType
		if last, ok := s.lastAlert[key]; ok && now.Sub(last) < dedupWindow {
			continue
		}
		s.lastAlert[key] = now
		s.sendAlert(ctx, "🔐 远程控制安全告警",
			fmt.Sprintf("检测到 %d 条 %s 事件\n时间: %s", count, eventType, now.Format(time.RFC3339)),
			[]string{"warning", "security"})
		slog.Info("audit scanner: alert sent",
			slog.String("event", eventType), slog.Int("count", count))
	}

	// Alert for repeated auth rejections from same IP
	for ip, count := range ipRejectCounts {
		if count < rejectThreshold {
			continue
		}
		key := "ip:" + ip
		if last, ok := s.lastAlert[key]; ok && now.Sub(last) < dedupWindow {
			continue
		}
		s.lastAlert[key] = now
		s.sendAlert(ctx, "🔐 认证失败告警",
			fmt.Sprintf("IP %s 在最近 %s 内有 %d 次认证失败/拒绝\n时间: %s",
				ip, s.interval, count, now.Format(time.RFC3339)),
			[]string{"warning", "security"})
		slog.Info("audit scanner: auth rejection alert",
			slog.String("ip", ip), slog.Int("count", count))
	}
}

func (s *AuditScanner) sendAlert(ctx context.Context, title, message string, tags []string) {
	if s.publisher == nil {
		return
	}
	if err := s.publisher.PublishAlert(ctx, title, message, tags); err != nil {
		slog.Warn("audit scanner: ntfy publish failed", slog.String("err", err.Error()))
	}
}
