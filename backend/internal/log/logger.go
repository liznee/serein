// Package log 提供结构化审批事件日志。
// 使用 Go 标准库 log/slog，JSON 格式输出到 stdout 和可选文件，
// 方便外部脚本/日志监控工具解析。
package log

import (
	"fmt"
	"io"
	"log/slog"
	"os"
)

// EventType 审批系统事件类型，序列化到日志的 event 字段。
type EventType string

const (
	EventApprovalCreated EventType = "approval_created" // hook 创建审批
	EventAutoApproved    EventType = "auto_approved"    // 后端二次分级自动放行
	EventDecided         EventType = "decided"          // 客户端回执（同意/拒绝）
	EventTimeout         EventType = "timeout"          // 审批超时（后端 ctx 到期）
	EventNtfyError       EventType = "ntfy_error"       // ntfy 推送失败（不阻塞）
	EventDBError         EventType = "db_error"         // 数据库操作错误
	EventStartup         EventType = "startup"          // 服务启动
	EventShutdown        EventType = "shutdown"         // 服务关闭
)

// Logger 审批事件记录器。
type Logger struct {
	slog *slog.Logger
}

// Open 初始化 Logger。若 logPath 非空则同时写文件。
func Open(logPath string) (*Logger, error) {
	var writers []io.Writer
	writers = append(writers, os.Stdout)

	if logPath != "" {
		f, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
		if err != nil {
			return nil, fmt.Errorf("open log file: %w", err)
		}
		writers = append(writers, f)
	}

	handler := slog.NewJSONHandler(io.MultiWriter(writers...), &slog.HandlerOptions{
		Level: slog.LevelInfo,
	})
	return &Logger{slog: slog.New(handler)}, nil
}

// Event 记录一条审批事件日志。
// attrs 由各事件函数构造，固定包含 event 类型字段。
func (l *Logger) Event(event EventType, msg string, attrs ...slog.Attr) {
	args := make([]any, 0, len(attrs)+1)
	args = append(args, slog.String("event", string(event)))
	for _, a := range attrs {
		args = append(args, a)
	}
	l.slog.Info(msg, args...)
}

// Error 记录错误级别日志。
func (l *Logger) Error(event EventType, msg string, err error, attrs ...slog.Attr) {
	args := make([]any, 0, len(attrs)+2)
	args = append(args, slog.String("event", string(event)))
	args = append(args, slog.String("error", err.Error()))
	for _, a := range attrs {
		args = append(args, a)
	}
	l.slog.Error(msg, args...)
}

// ---- 便捷方法 ----

func (l *Logger) ApprovalCreated(id, sessionID, riskLevel, command string) {
	l.Event(EventApprovalCreated, "approval created",
		slog.String("id", id),
		slog.String("session_id", sessionID),
		slog.String("risk_level", riskLevel),
		slog.String("command", command),
	)
}

func (l *Logger) AutoApproved(id, sessionID, reason string) {
	l.Event(EventAutoApproved, "auto-approved",
		slog.String("id", id),
		slog.String("session_id", sessionID),
		slog.String("reason", reason),
	)
}

func (l *Logger) Decided(id, decision, by string) {
	l.Event(EventDecided, "approval decided",
		slog.String("id", id),
		slog.String("decision", decision),
		slog.String("decided_by", by),
	)
}

func (l *Logger) Timeout(id, sessionID string) {
	l.Event(EventTimeout, "approval timed out",
		slog.String("id", id),
		slog.String("session_id", sessionID),
	)
}

func (l *Logger) NtfyError(id string, err error) {
	l.Error(EventNtfyError, "ntfy publish failed (non-blocking)",
		err,
		slog.String("id", id),
	)
}

func (l *Logger) DBError(ctx string, err error) {
	l.Error(EventDBError, "database error",
		err,
		slog.String("context", ctx),
	)
}

// NoOp 返回一个空操作的 Logger（用于测试或不需要日志的场景）。
func NoOp() *Logger {
	return &Logger{slog: slog.New(slog.NewJSONHandler(io.Discard, nil))}
}
