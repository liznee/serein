package notify

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

// TestRiskTitle 验证风险等级到通知标题的映射(不含命令正文)。
func TestRiskTitle(t *testing.T) {
	tests := []struct{ level, want string }{
		{"red", "🔴 高危审批请求"},
		{"yellow", "🟡 审批请求"},
		{"green", "🟢 审批请求"},
		{"", "🟢 审批请求"},
	}
	for _, tt := range tests {
		if got := riskTitle(tt.level); got != tt.want {
			t.Errorf("riskTitle(%q) = %q, want %q", tt.level, got, tt.want)
		}
	}
}

// TestRiskPriority 验证风险等级到 ntfy 优先级的映射。
func TestRiskPriority(t *testing.T) {
	tests := []struct{ level, want string }{
		{"red", "high"},
		{"yellow", "default"},
		{"green", "low"},
		{"", "low"},
	}
	for _, tt := range tests {
		if got := riskPriority(tt.level); got != tt.want {
			t.Errorf("riskPriority(%q) = %q, want %q", tt.level, got, tt.want)
		}
	}
}

// TestPublishSendsIDOnly 核心安全断言:命令正文绝不经过公开 ntfy topic,body 只含 ID 和风险等级。
func TestPublishSendsIDOnly(t *testing.T) {
	var gotBody map[string]interface{}
	var gotTitle, gotPriority, gotTopic string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotTopic = r.URL.Path
		gotTitle = r.Header.Get("Title")
		gotPriority = r.Header.Get("Priority")
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &gotBody)
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	pub := New(srv.URL, "test-topic")
	err := pub.Publish(context.Background(), ApprovalMessage{ID: "abc123", RiskLevel: "red"})
	if err != nil {
		t.Fatalf("publish: %v", err)
	}
	// 安全断言:命令相关字段绝不出现
	for _, key := range []string{"command", "tool_name", "cwd", "reason"} {
		if _, ok := gotBody[key]; ok {
			t.Errorf("敏感字段 %q 泄露到 ntfy body: %v", key, gotBody)
		}
	}
	if gotBody["id"] != "abc123" {
		t.Errorf("id = %v, want abc123", gotBody["id"])
	}
	if gotBody["risk_level"] != "red" {
		t.Errorf("risk_level = %v, want red", gotBody["risk_level"])
	}
	if gotTitle != "🔴 高危审批请求" {
		t.Errorf("title = %q, want 高危标题", gotTitle)
	}
	if gotPriority != "high" {
		t.Errorf("priority = %q, want high", gotPriority)
	}
	if gotTopic != "/test-topic" {
		t.Errorf("topic path = %q, want /test-topic", gotTopic)
	}
}

// TestPublishFailureNonBlocking ntfy 不可达时返回错误但不 panic(主流程不阻断)。
func TestPublishFailureNonBlocking(t *testing.T) {
	pub := New("http://127.0.0.1:59999", "test")
	err := pub.Publish(context.Background(), ApprovalMessage{ID: "x", RiskLevel: "red"})
	if err == nil {
		t.Error("expected error for unreachable ntfy, got nil")
	}
}

func TestPublishMonitoringAlertSendsOnlySignal(t *testing.T) {
	var got map[string]interface{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &got)
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()
	if err := New(srv.URL, "test-topic").PublishMonitoringAlert(context.Background(), "abc123", "critical"); err != nil {
		t.Fatal(err)
	}
	if got["kind"] != "monitor_alert" || got["id"] != "abc123" || got["level"] != "critical" {
		t.Fatalf("unexpected monitoring signal: %#v", got)
	}
	for _, forbidden := range []string{"value", "threshold", "message", "command", "token", "path"} {
		if _, exists := got[forbidden]; exists { t.Fatalf("monitoring signal leaked %q: %#v", forbidden, got) }
	}
}

// TestPublishServer500 ntfy 返回 5xx 时应返回错误。
func TestPublishServer500(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	pub := New(srv.URL, "test")
	err := pub.Publish(context.Background(), ApprovalMessage{ID: "x", RiskLevel: "green"})
	if err == nil {
		t.Error("expected error for 500, got nil")
	}
}
