package notify

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"
)

// Publisher 向 ntfy 发布审批消息(纯 pub/sub 总线)。
type Publisher struct {
	baseURL string
	topic   string
	client  *http.Client
}

func New(baseURL, topic string) *Publisher {
	return &Publisher{
		baseURL: baseURL,
		topic:   topic,
		client:  &http.Client{Timeout: 10 * time.Second},
	}
}

// ApprovalMessage 推送给客户端的审批信号(轻量)。
// 出于安全考虑:ntfy topic 是公开 pub/sub 总线,这里只携带审批 ID 和风险等级,
// 敏感的命令正文绝不经过 ntfy;客户端收到 ID 后用 CLIENT_TOKEN 鉴权拉取详情。
type ApprovalMessage struct {
	ID        string `json:"id"`
	RiskLevel string `json:"risk_level,omitempty"`
	Project   string `json:"project,omitempty"`
}

// MonitoringAlertMessage deliberately contains no telemetry, path, command or
// credential. The paired client fetches the record with its own Client Token.
type MonitoringAlertMessage struct {
	Kind  string `json:"kind"`
	ID    string `json:"id"`
	Level string `json:"level"`
}

// Publish 发布一条审批信号到 ntfy topic。失败不阻断主流程(客户端可从历史补拉)。
func (p *Publisher) Publish(ctx context.Context, msg ApprovalMessage) error {
	body, _ := json.Marshal(msg)
	url := fmt.Sprintf("%s/%s", p.baseURL, p.topic)
	req, err := http.NewRequestWithContext(ctx, "POST", url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Title", riskTitle(msg.RiskLevel))
	req.Header.Set("Tags", "warning,approval")
	req.Header.Set("Priority", riskPriority(msg.RiskLevel))
	req.Header.Set("Content-Type", "application/json")
	resp, err := p.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return fmt.Errorf("ntfy publish failed: %s", resp.Status)
	}
	return nil
}

// PublishAlert 发布一条通用告警消息到 ntfy topic。失败不阻断主流程(仅 log)。
func (p *Publisher) PublishAlert(ctx context.Context, title, message string, tags []string) error {
	url := fmt.Sprintf("%s/%s", p.baseURL, p.topic)
	req, err := http.NewRequestWithContext(ctx, "POST", url, strings.NewReader(message))
	if err != nil {
		return err
	}
	req.Header.Set("Title", title)
	req.Header.Set("Content-Type", "text/plain; charset=utf-8")
	req.Header.Set("Priority", "default")
	if len(tags) > 0 {
		req.Header.Set("Tags", strings.Join(tags, ","))
	}
	resp, err := p.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return fmt.Errorf("ntfy publish failed: %s", resp.Status)
	}
	return nil
}

func (p *Publisher) PublishMonitoringAlert(ctx context.Context, id, level string) error {
	body, _ := json.Marshal(MonitoringAlertMessage{Kind: "monitor_alert", ID: id, Level: level})
	url := fmt.Sprintf("%s/%s", p.baseURL, p.topic)
	req, err := http.NewRequestWithContext(ctx, "POST", url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Title", "Serein 监控告警")
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Tags", "warning,monitoring")
	if level == "critical" {
		req.Header.Set("Priority", "high")
	} else {
		req.Header.Set("Priority", "default")
	}
	resp, err := p.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return fmt.Errorf("ntfy monitoring publish failed: %s", resp.Status)
	}
	return nil
}

// riskTitle 把风险等级映射为通知标题(不含命令正文)。
func riskTitle(level string) string {
	switch level {
	case "red":
		return "🔴 高危审批请求"
	case "yellow":
		return "🟡 审批请求"
	default:
		return "🟢 审批请求"
	}
}

// riskPriority 把风险等级映射为 ntfy 优先级(red 高优先级推送 + 振动)。
func riskPriority(level string) string {
	switch level {
	case "red":
		return "high"
	case "yellow":
		return "default"
	default:
		return "low"
	}
}
