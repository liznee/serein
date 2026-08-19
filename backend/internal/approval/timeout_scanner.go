package approval

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"serein/internal/notify"
)

// ApprovalTimeoutScanner 定期扫描已超时的审批，标记为 timeout 并推送 ntfy 通知提醒用户。
//
// 背景：审批创建时会推送一次 ntfy（仅在 relay 未连接时），但如果用户
// 没有及时看到通知，审批超时后会静默变为 deny，用户可能完全不知情。
// 本扫描器在审批超时后主动推送一条"已超时自动拒绝"的提醒。
//
// 去重：通过 DB 的 timeout_notified_at 列持久化去重，每个审批 ID 只推送一次超时通知，
// 即使服务重启也不会重复推送。
type ApprovalTimeoutScanner struct {
	svc      *Service
	pub      *notify.Publisher
	interval time.Duration
}

// NewApprovalTimeoutScanner 创建审批超时扫描器。
// publisher 为 nil 时只标记 timeout 不推送 ntfy（dry-run 模式）。
func NewApprovalTimeoutScanner(svc *Service, pub *notify.Publisher, interval time.Duration) *ApprovalTimeoutScanner {
	if interval <= 0 {
		interval = 30 * time.Second
	}
	return &ApprovalTimeoutScanner{
		svc:      svc,
		pub:      pub,
		interval: interval,
	}
}

// Start 运行扫描循环，直到 ctx 取消。阻塞，用 go 调用。
func (s *ApprovalTimeoutScanner) Start(ctx context.Context) {
	if s.svc == nil {
		slog.Warn("approval timeout scanner skipped: service is nil")
		return
	}
	slog.Info("approval timeout scanner started", slog.Duration("interval", s.interval))
	// 启动后立即扫描一次，不等待第一个 tick
	s.scan(ctx)
	ticker := time.NewTicker(s.interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			slog.Info("approval timeout scanner stopped")
			return
		case <-ticker.C:
			s.scan(ctx)
		}
	}
}

func (s *ApprovalTimeoutScanner) scan(ctx context.Context) {
	records, err := s.svc.ListTimedOutPending(ctx)
	if err != nil {
		slog.Warn("approval timeout scanner: query failed", slog.String("err", err.Error()))
		return
	}
	if len(records) == 0 {
		return
	}
	for _, r := range records {
		// 标记为 timeout（复用 Status 逻辑，幂等）。
		// 对于已被 hook 轮询标记为 timeout 的记录，此调用是 no-op。
		// 对于仍为 pending 的记录，此调用将其标记为 timeout。
		decision, _, _ := s.svc.Status(ctx, r.ID)
		if decision != DecisionDeny {
			// 可能已被用户手动决策（allow/deny），跳过通知
			continue
		}
		s.sendTimeoutAlert(ctx, r)
		// 持久化标记已通知，防止重启后重复推送
		if err := s.svc.MarkTimeoutNotified(ctx, r.ID); err != nil {
			slog.Warn("approval timeout scanner: mark notified failed",
				slog.String("id", r.ID), slog.String("err", err.Error()))
		}
		slog.Info("approval timeout scanner: timeout notified",
			slog.String("id", r.ID),
			slog.String("project", r.Project),
			slog.String("risk_level", r.RiskLevel))
	}
}

func (s *ApprovalTimeoutScanner) sendTimeoutAlert(ctx context.Context, r *Record) {
	if s.pub == nil {
		return
	}
	title := "⏰ 审批已超时自动拒绝"
	cmd := r.Command
	if len(cmd) > 60 {
		cmd = cmd[:57] + "..."
	}
	projectLabel := r.Project
	if projectLabel == "" {
		projectLabel = "default"
	}
	msg := fmt.Sprintf("审批 #%s 已超时被自动拒绝\n命令: %s\n项目: %s\n风险: %s",
		r.ID[:8], cmd, projectLabel, r.RiskLevel)
	// 使用 approval.ProjectSystem ("__system__") 作为 tag 之一，
	// 标记此为系统级告警，手机端可按「系统」分类筛选。
	if err := s.pub.PublishAlert(ctx, title, msg, []string{"warning", "timeout", "system"}); err != nil {
		slog.Warn("approval timeout scanner: ntfy publish failed", slog.String("err", err.Error()))
	}
}
