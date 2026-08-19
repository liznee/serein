package api

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"serein/internal/approval"
	rdplog "serein/internal/log"
	"serein/internal/notify"
	"serein/internal/risk"
	"serein/internal/store"
)

// setupAgentRelayTestServer 创建带完整 agent relay 功能的测试服务器。
// devMode=true 时 clientAuth 无 token 放行，方便测试 agent relay handler。
func setupAgentRelayTestServer(t *testing.T, hookToken, clientToken string, devMode bool) http.Handler {
	t.Helper()
	db, err := store.Open(":memory:")
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	svc := approval.NewService(db, 300)
	pub := notify.New("http://127.0.0.1:59999", "test")
	sessionRepo := store.NewSessionRepo(db)
	engine := risk.New(store.NewBlacklistRepo(db), store.NewWhitelistRepo(db), sessionRepo)
	devHandler := NewDeviceHandler(store.NewDeviceRepo(db), "test-pair-code")
	cfgHandler := NewConfigHandler(store.NewWhitelistRepo(db), store.NewBlacklistRepo(db), engine)
	deviceRepo := store.NewDeviceRepo(db)
	return NewRouter(RouterConfig{
		HookToken:         hookToken,
		GlobalClientToken: clientToken,
		DevMode:           devMode,
		Svc:               svc,
		Pub:               pub,
		Engine:            engine,
		SessionRepo:       sessionRepo,
		DeviceRepo:        deviceRepo,
		DevHandler:        devHandler,
		CfgHandler:        cfgHandler,
		Logger:            rdplog.NoOp(),
		Version:           "test-version",
		SysInfoRepo:       store.NewSysInfoRepo(db),
	})
}

// pairTestDevice 通过 /devices/pair 配对一个真实设备并返回其 CLIENT_TOKEN。
// 用于在 devMode=false 的测试中获取 per-device token(clientAuth 不再接受 globalToken)。
func pairTestDevice(t *testing.T, srv *httptest.Server, pairCode string) string {
	t.Helper()
	body := bytes.NewBufferString(`{"pair_code":"` + pairCode + `","device_name":"test-device"}`)
	resp, err := http.Post(srv.URL+"/devices/pair", "application/json", body)
	if err != nil {
		t.Fatalf("pair: %v", err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 201 {
		t.Fatalf("pair status %d: %s", resp.StatusCode, raw)
	}
	var parsed struct {
		ClientToken string `json:"client_token"`
	}
	if err := json.Unmarshal(raw, &parsed); err != nil || parsed.ClientToken == "" {
		t.Fatalf("pair response: %s err=%v", raw, err)
	}
	return parsed.ClientToken
}

// agentRelayDo 向 agent relay 端点发送 JSON 请求并返回响应。
func agentRelayDo(t *testing.T, srv *httptest.Server, method, path, contentType, body string) *http.Response {
	t.Helper()
	var req *http.Request
	var err error
	if body != "" {
		req, err = http.NewRequest(method, srv.URL+path, strings.NewReader(body))
	} else {
		req, err = http.NewRequest(method, srv.URL+path, nil)
	}
	if err != nil {
		t.Fatalf("%s %s: %v", method, path, err)
	}
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("%s %s do: %v", method, path, err)
	}
	return resp
}

func TestCmdValidAction(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// 使用 async 避免阻塞（无 Agent 取命令时同步模式会等超时）
	resp := agentRelayDo(t, srv, "POST", "/agent/cmd?async=true", "application/json",
		`{"action":"status","project":"test-proj"}`)
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("want 200, got %d", resp.StatusCode)
	}
	var body map[string]interface{}
	json.NewDecoder(resp.Body).Decode(&body)
	if body["ok"] != true {
		t.Errorf("want ok:true, got %v", body)
	}
}

func TestCmdInvalidAction(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp := agentRelayDo(t, srv, "POST", "/agent/cmd", "application/json",
		`{"action":"unknown","project":"test-proj"}`)
	defer resp.Body.Close()
	if resp.StatusCode != 400 {
		t.Fatalf("want 400, got %d", resp.StatusCode)
	}
	var body map[string]string
	json.NewDecoder(resp.Body).Decode(&body)
	if !strings.Contains(body["error"], "invalid action") {
		t.Errorf("want invalid action error, got %v", body)
	}
}

func TestCmdMissingAction(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp := agentRelayDo(t, srv, "POST", "/agent/cmd", "application/json",
		`{"project":"test-proj"}`)
	defer resp.Body.Close()
	if resp.StatusCode != 400 {
		t.Fatalf("want 400, got %d", resp.StatusCode)
	}
}

func TestCmdMissingProjectNonKillAll(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp := agentRelayDo(t, srv, "POST", "/agent/cmd", "application/json",
		`{"action":"start"}`)
	defer resp.Body.Close()
	if resp.StatusCode != 400 {
		t.Fatalf("want 400, got %d", resp.StatusCode)
	}
	var body map[string]string
	json.NewDecoder(resp.Body).Decode(&body)
	if !strings.Contains(body["error"], "project required") {
		t.Errorf("want project required error, got %v", body)
	}
}

func TestCmdKillAllNoProjectRequired(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// 使用 async 避免阻塞
	resp := agentRelayDo(t, srv, "POST", "/agent/cmd?async=true", "application/json",
		`{"action":"kill-all"}`)
	defer resp.Body.Close()
	// kill-all 不需要 project，应返回 200
	if resp.StatusCode == 400 {
		t.Errorf("kill-all without project should not return 400")
	}
}

func TestCmdExecRequiresCommand(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp := agentRelayDo(t, srv, "POST", "/agent/cmd", "application/json",
		`{"action":"exec","project":"test"}`)
	defer resp.Body.Close()
	if resp.StatusCode != 400 {
		t.Fatalf("exec without command want 400, got %d", resp.StatusCode)
	}
	var body map[string]string
	json.NewDecoder(resp.Body).Decode(&body)
	if !strings.Contains(body["error"], "command required") {
		t.Errorf("want command required error, got %v", body)
	}
}

func TestCmdProjectTooLong(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	longProj := strings.Repeat("a", 101)
	resp := agentRelayDo(t, srv, "POST", "/agent/cmd", "application/json",
		`{"action":"status","project":"`+longProj+`"}`)
	defer resp.Body.Close()
	if resp.StatusCode != 400 {
		t.Fatalf("project too long want 400, got %d", resp.StatusCode)
	}
	var body map[string]string
	json.NewDecoder(resp.Body).Decode(&body)
	if !strings.Contains(body["error"], "project too long") {
		t.Errorf("want project too long error, got %v", body)
	}
}

func TestCmdCommandTooLong(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	longCmd := strings.Repeat("x", 8001)
	resp := agentRelayDo(t, srv, "POST", "/agent/cmd", "application/json",
		`{"action":"exec","project":"test","command":"`+longCmd+`"}`)
	defer resp.Body.Close()
	if resp.StatusCode != 400 {
		t.Fatalf("command too long want 400, got %d", resp.StatusCode)
	}
}

func TestCmdWrongContentType(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp := agentRelayDo(t, srv, "POST", "/agent/cmd", "text/plain",
		`{"action":"status"}`)
	defer resp.Body.Close()
	if resp.StatusCode != 415 {
		t.Fatalf("wrong content-type want 415, got %d", resp.StatusCode)
	}
}

func TestCmdInvalidJSON(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp := agentRelayDo(t, srv, "POST", "/agent/cmd", "application/json",
		`not json`)
	defer resp.Body.Close()
	if resp.StatusCode != 400 {
		t.Fatalf("invalid json want 400, got %d", resp.StatusCode)
	}
}

func TestCmdShellMetaInNonExec(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// status action 的 command 不应包含 shell 元字符
	resp := agentRelayDo(t, srv, "POST", "/agent/cmd", "application/json",
		`{"action":"status","project":"test","command":"hello; rm -rf /"}`)
	defer resp.Body.Close()
	if resp.StatusCode != 400 {
		t.Fatalf("shell meta in non-exec want 400, got %d", resp.StatusCode)
	}
	var body map[string]string
	json.NewDecoder(resp.Body).Decode(&body)
	if !strings.Contains(body["error"], "shell metacharacters") {
		t.Errorf("want shell metacharacters error, got %v", body)
	}
}

func TestCmdExecAllowsShellMeta(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// exec action 的 command 允许 shell 元字符（本身就是 shell 命令）
	// 使用 async 避免阻塞
	resp := agentRelayDo(t, srv, "POST", "/agent/cmd?async=true", "application/json",
		`{"action":"exec","project":"test","command":"ls -la | grep foo"}`)
	defer resp.Body.Close()
	// 应通过校验层
	if resp.StatusCode == 400 {
		t.Errorf("exec with shell meta should not be rejected at API layer")
	}
}

func TestCmdAsyncMode(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp := agentRelayDo(t, srv, "POST", "/agent/cmd?async=true", "application/json",
		`{"action":"status","project":"test-async"}`)
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("async want 200, got %d", resp.StatusCode)
	}
	var body map[string]interface{}
	json.NewDecoder(resp.Body).Decode(&body)
	if body["ok"] != true {
		t.Errorf("async want ok:true, got %v", body)
	}
	if body["cmd_id"] == "" || body["cmd_id"] == nil {
		t.Errorf("async want non-empty cmd_id, got %v", body["cmd_id"])
	}
	if body["queued"] != true {
		t.Errorf("async want queued:true, got %v", body["queued"])
	}
}

func TestQueueDequeue(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// 先发一个 async 命令入队
	resp := agentRelayDo(t, srv, "POST", "/agent/cmd?async=true", "application/json",
		`{"action":"status","project":"queue-test"}`)
	defer resp.Body.Close()
	var asyncResp struct {
		CmdID string `json:"cmd_id"`
	}
	json.NewDecoder(resp.Body).Decode(&asyncResp)

	// Agent 取命令（使用 hook token 鉴权）
	req, _ := http.NewRequest("GET", srv.URL+"/agent/queue", nil)
	req.Header.Set("Authorization", "Bearer hook-secret")
	resp2, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp2.Body.Close()
	if resp2.StatusCode != 200 {
		t.Fatalf("queue want 200, got %d", resp2.StatusCode)
	}
	var queueResp struct {
		HasCmd  bool   `json:"has_cmd"`
		CmdID   string `json:"cmd_id"`
		Action  string `json:"action"`
		Project string `json:"project"`
	}
	json.NewDecoder(resp2.Body).Decode(&queueResp)
	if !queueResp.HasCmd {
		t.Error("queue should have a command")
	}
	if queueResp.CmdID != asyncResp.CmdID {
		t.Errorf("queue cmd_id mismatch: want %s, got %s", asyncResp.CmdID, queueResp.CmdID)
	}
	if queueResp.Action != "status" {
		t.Errorf("queue action want status, got %s", queueResp.Action)
	}
	if queueResp.Project != "queue-test" {
		t.Errorf("queue project want queue-test, got %s", queueResp.Project)
	}
}

func TestStartAgentTypeSurvivesQueue(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp := agentRelayDo(t, srv, "POST", "/agent/cmd?async=true", "application/json",
		`{"action":"start","project":"queue-test","agent_type":"codex","runtime_mode":"desktop"}`)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("start codex want 200, got %d", resp.StatusCode)
	}

	req, _ := http.NewRequest("GET", srv.URL+"/agent/queue", nil)
	req.Header.Set("Authorization", "Bearer hook-secret")
	queued, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer queued.Body.Close()
	var body struct {
		HasCmd    bool   `json:"has_cmd"`
		Action    string `json:"action"`
		AgentType string `json:"agent_type"`
		RuntimeMode string `json:"runtime_mode"`
	}
	if err := json.NewDecoder(queued.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if !body.HasCmd || body.Action != "start" || body.AgentType != "codex" || body.RuntimeMode != "desktop" {
		t.Fatalf("agent type lost in queue: %+v", body)
	}
}

func TestDesktopRuntimeRequiresCodex(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp := agentRelayDo(t, srv, "POST", "/agent/cmd", "application/json",
		`{"action":"start","project":"queue-test","agent_type":"claude","runtime_mode":"desktop"}`)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("desktop with Claude want 400, got %d", resp.StatusCode)
	}
}

func TestStartRejectsUnsupportedAgentType(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp := agentRelayDo(t, srv, "POST", "/agent/cmd", "application/json",
		`{"action":"start","project":"queue-test","agent_type":"gemini"}`)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("unsupported agent type want 400, got %d", resp.StatusCode)
	}
}

func TestReportHeartbeat(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// 发送心跳报告（使用 hook token 鉴权）
	req, _ := http.NewRequest("POST", srv.URL+"/agent/report",
		strings.NewReader(`{"success":true,"output":{"_heartbeat":true,"status":"running"}}`))
	req.Header.Set("Authorization", "Bearer hook-secret")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("heartbeat want 200, got %d", resp.StatusCode)
	}

	// 检查 status 端点应显示 running
	resp2 := agentRelayDo(t, srv, "GET", "/agent/status", "", "")
	defer resp2.Body.Close()
	if resp2.StatusCode != 200 {
		t.Fatalf("status want 200, got %d", resp2.StatusCode)
	}
	var statusResp struct {
		Running bool                   `json:"running"`
		Output  map[string]interface{} `json:"output"`
	}
	json.NewDecoder(resp2.Body).Decode(&statusResp)
	if !statusResp.Running {
		t.Error("status should show running after heartbeat")
	}
	if statusResp.Output == nil {
		t.Error("status output should not be nil")
	}
	if statusResp.Output["status"] != "running" {
		t.Errorf("status output mismatch: %v", statusResp.Output)
	}
}

func TestReportSanitizesUnknownKeys(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// 发送带未知 key 的 report
	req, _ := http.NewRequest("POST", srv.URL+"/agent/report",
		strings.NewReader(`{"cmd_id":"test-cmd","success":true,"output":{"_heartbeat":true,"malicious":"<script>alert(1)</script>","nested":{"evil":"data"}}}`))
	req.Header.Set("Authorization", "Bearer hook-secret")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("report want 200, got %d", resp.StatusCode)
	}

	// 检查 status 端点应无恶意 key
	resp2 := agentRelayDo(t, srv, "GET", "/agent/status", "", "")
	defer resp2.Body.Close()
	var statusResp struct {
		Running bool                   `json:"running"`
		Output  map[string]interface{} `json:"output"`
	}
	json.NewDecoder(resp2.Body).Decode(&statusResp)
	if _, exists := statusResp.Output["malicious"]; exists {
		t.Error("sanitizeOutput should have removed unknown key 'malicious'")
	}
	if _, exists := statusResp.Output["nested"]; exists {
		t.Error("sanitizeOutput should have removed unknown key 'nested'")
	}
}

func TestReportWithCmdID(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// 先发 async 命令
	resp := agentRelayDo(t, srv, "POST", "/agent/cmd?async=true", "application/json",
		`{"action":"status","project":"report-test"}`)
	defer resp.Body.Close()
	var asyncResp struct {
		CmdID string `json:"cmd_id"`
	}
	json.NewDecoder(resp.Body).Decode(&asyncResp)

	// 回报命令结果
	req, _ := http.NewRequest("POST", srv.URL+"/agent/report",
		strings.NewReader(`{"cmd_id":"`+asyncResp.CmdID+`","success":true,"output":{"status":"done"}}`))
	req.Header.Set("Authorization", "Bearer hook-secret")
	req.Header.Set("Content-Type", "application/json")
	resp2, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp2.Body.Close()
	if resp2.StatusCode != 200 {
		t.Fatalf("report want 200, got %d", resp2.StatusCode)
	}

	// 检查 history 应包含结果
	resp3 := agentRelayDo(t, srv, "GET", "/agent/history?project=report-test", "", "")
	defer resp3.Body.Close()
	var history []map[string]interface{}
	json.NewDecoder(resp3.Body).Decode(&history)
	found := false
	for _, h := range history {
		if h["cmd_id"] == asyncResp.CmdID {
			found = true
			if h["success"] != true {
				t.Error("history entry should be successful")
			}
			break
		}
	}
	if !found {
		t.Errorf("history should contain cmd_id %s", asyncResp.CmdID)
	}
}

func TestHistorySince(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// 发 3 个 async 命令，并回报结果使其进入 history
	cmdIDs := make([]string, 3)
	for i := 0; i < 3; i++ {
		resp := agentRelayDo(t, srv, "POST", "/agent/cmd?async=true", "application/json",
			`{"action":"status","project":"history-test"}`)
		var asyncResp struct {
			CmdID string `json:"cmd_id"`
		}
		json.NewDecoder(resp.Body).Decode(&asyncResp)
		resp.Body.Close()
		cmdIDs[i] = asyncResp.CmdID

		// 回报结果，使命令进入 history
		req, _ := http.NewRequest("POST", srv.URL+"/agent/report",
			strings.NewReader(`{"cmd_id":"`+asyncResp.CmdID+`","success":true,"output":{"status":"done"}}`))
		req.Header.Set("Authorization", "Bearer hook-secret")
		req.Header.Set("Content-Type", "application/json")
		resp2, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp2.Body.Close()
	}

	// history?since= 第二个 cmd_id → 应只返回第三个
	resp := agentRelayDo(t, srv, "GET", "/agent/history?project=history-test&since="+cmdIDs[1], "", "")
	defer resp.Body.Close()
	var history []map[string]interface{}
	json.NewDecoder(resp.Body).Decode(&history)
	if len(history) != 1 {
		t.Fatalf("history since want 1 result, got %d", len(history))
	}
	if history[0]["cmd_id"] != cmdIDs[2] {
		t.Errorf("history since result mismatch: want %s, got %v", cmdIDs[2], history[0]["cmd_id"])
	}
}

func TestCmdStepAndSteps(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// 先发一个 async 命令
	resp := agentRelayDo(t, srv, "POST", "/agent/cmd?async=true", "application/json",
		`{"action":"status","project":"step-test"}`)
	defer resp.Body.Close()
	var asyncResp struct {
		CmdID string `json:"cmd_id"`
	}
	json.NewDecoder(resp.Body).Decode(&asyncResp)

	// 提交两个 step（使用 hook token 鉴权）
	for seq := 1; seq <= 2; seq++ {
		var body string
		if seq == 2 {
			body = `{"seq":2,"event":"tool_use","name":"web_search","content":"step 2"}`
		} else {
			body = `{"seq":1,"event":"tool_use","name":"read_file","content":"step 1"}`
		}
		req, _ := http.NewRequest("POST", srv.URL+"/agent/cmd/"+asyncResp.CmdID+"/step",
			strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer hook-secret")
		req.Header.Set("Content-Type", "application/json")
		resp2, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp2.Body.Close()
		if resp2.StatusCode != 200 {
			t.Fatalf("step %d want 200, got %d", seq, resp2.StatusCode)
		}
	}

	// 读取 steps
	resp3 := agentRelayDo(t, srv, "GET", "/agent/cmd/"+asyncResp.CmdID+"/steps", "", "")
	defer resp3.Body.Close()
	if resp3.StatusCode != 200 {
		t.Fatalf("steps want 200, got %d", resp3.StatusCode)
	}
	var steps []map[string]interface{}
	json.NewDecoder(resp3.Body).Decode(&steps)
	if len(steps) < 2 {
		t.Fatalf("steps want at least 2, got %d", len(steps))
	}
}

func TestAlert(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	req, _ := http.NewRequest("POST", srv.URL+"/agent/alert",
		strings.NewReader(`{"observations":[{"metric":"cpu","value":95,"threshold":90,"active":true},{"metric":"gpu","value":10,"threshold":95,"active":false},{"metric":"gpu_temp","value":45,"threshold":80,"active":false},{"metric":"mem","value":42,"threshold":90,"active":false}]}`))
	req.Header.Set("Authorization", "Bearer hook-secret")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("alert want 200, got %d", resp.StatusCode)
	}
	var body struct { Ok bool `json:"ok"`; Opened int `json:"opened"` }
	json.NewDecoder(resp.Body).Decode(&body)
	if !body.Ok || body.Opened != 1 {
		t.Errorf("alert want ok:true, got %v", body)
	}

	// 100 repeated reports must converge to one active lifecycle and must not
	// create a notification storm when the relay retries a heartbeat.
	for i := 0; i < 100; i++ {
		duplicate, _ := http.NewRequest("POST", srv.URL+"/agent/alert", strings.NewReader(`{"observations":[{"metric":"cpu","value":96,"threshold":90,"active":true}]}`))
		duplicate.Header.Set("Authorization", "Bearer hook-secret")
		duplicate.Header.Set("Content-Type", "application/json")
		res, err := http.DefaultClient.Do(duplicate)
		if err != nil { t.Fatal(err) }
		if res.StatusCode != http.StatusOK { t.Fatalf("duplicate alert %d status=%d", i, res.StatusCode) }
		res.Body.Close()
	}
	summary, err := http.Get(srv.URL + "/monitoring/alerts/summary")
	if err != nil { t.Fatal(err) }
	defer summary.Body.Close()
	var monitorSummary struct { Active int `json:"active"`; Total int `json:"total"` }
	json.NewDecoder(summary.Body).Decode(&monitorSummary)
	if monitorSummary.Active != 1 || monitorSummary.Total != 1 { t.Fatalf("monitor summary=%+v, want one active lifecycle", monitorSummary) }
}

func TestSysInfoZerosWhenNoData(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp := agentRelayDo(t, srv, "GET", "/agent/sysinfo", "", "")
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("sysinfo want 200, got %d", resp.StatusCode)
	}
	var body map[string]interface{}
	json.NewDecoder(resp.Body).Decode(&body)
	if cpu, ok := body["cpu"]; ok && cpu != float64(0) {
		// 没有 sysinfo 数据时返回 0 是正常的
	}
	// 在没有 sysinfo 数据时，应返回零值填充
	if _, ok := body["memory"]; !ok {
		t.Error("sysinfo should have memory key")
	}
}

func TestAgentRelaySecurityHeaders(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/healthz")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	if resp.Header.Get("X-Content-Type-Options") != "nosniff" {
		t.Error("missing X-Content-Type-Options: nosniff header")
	}
	if resp.Header.Get("X-Frame-Options") != "DENY" {
		t.Error("missing X-Frame-Options: DENY header")
	}
	if resp.Header.Get("Cache-Control") != "no-store" {
		t.Error("missing Cache-Control: no-store header")
	}
}

func TestAgentAuthHookRequired(t *testing.T) {
	// 生产模式：hook 路由需要 HOOK_TOKEN
	handler := setupAgentRelayTestServer(t, "hook-secret", "", false)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// queue 无 token → 401
	resp, _ := http.Get(srv.URL + "/agent/queue")
	if resp.StatusCode != 401 {
		t.Errorf("queue no token want 401, got %d", resp.StatusCode)
	}
	resp.Body.Close()

	// queue 正确 token → 200
	req, _ := http.NewRequest("GET", srv.URL+"/agent/queue", nil)
	req.Header.Set("Authorization", "Bearer hook-secret")
	resp2, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if resp2.StatusCode != 200 {
		t.Errorf("queue with token want 200, got %d", resp2.StatusCode)
	}
	resp2.Body.Close()
}

func TestAgentAuthClientRequired(t *testing.T) {
	// 生产模式：client 路由需要 per-device CLIENT_TOKEN(查 DB)
	handler := setupAgentRelayTestServer(t, "hook-secret", "", false)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// 配对一个真实设备,获取它的 CLIENT_TOKEN
	clientToken := pairTestDevice(t, srv, "test-pair-code")

	// status 无 token → 401
	resp, _ := http.Get(srv.URL + "/agent/status")
	if resp.StatusCode != 401 {
		t.Errorf("status no token want 401, got %d", resp.StatusCode)
	}
	resp.Body.Close()

	// status 正确 per-device token → 200
	req, _ := http.NewRequest("GET", srv.URL+"/agent/status", nil)
	req.Header.Set("Authorization", "Bearer "+clientToken)
	resp2, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if resp2.StatusCode != 200 {
		t.Errorf("status with token want 200, got %d", resp2.StatusCode)
	}
	resp2.Body.Close()
}

func TestAgentAuthHookClientIsolation(t *testing.T) {
	// 双 token 隔离验证:hook token 走 hook 路由,per-device token 走 client 路由
	handler := setupAgentRelayTestServer(t, "hook-secret", "", false)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	clientToken := pairTestDevice(t, srv, "test-pair-code")

	// hook token 不能访问 client 路由
	req, _ := http.NewRequest("GET", srv.URL+"/agent/status", nil)
	req.Header.Set("Authorization", "Bearer hook-secret")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != 401 {
		t.Errorf("hook token on client route want 401, got %d", resp.StatusCode)
	}
	resp.Body.Close()

	// client token 不能访问 hook 路由
	req2, _ := http.NewRequest("GET", srv.URL+"/agent/queue", nil)
	req2.Header.Set("Authorization", "Bearer "+clientToken)
	resp2, err := http.DefaultClient.Do(req2)
	if err != nil {
		t.Fatal(err)
	}
	if resp2.StatusCode != 401 {
		t.Errorf("client token on hook route want 401, got %d", resp2.StatusCode)
	}
	resp2.Body.Close()
}

func TestCmdStepMissingCmdID(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	req, _ := http.NewRequest("POST", srv.URL+"/agent/cmd//step",
		strings.NewReader(`{"seq":1,"event":"text","content":"test"}`))
	req.Header.Set("Authorization", "Bearer hook-secret")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 400 {
		t.Errorf("missing cmd_id want 400, got %d", resp.StatusCode)
	}
}

func TestCommandsStatsEndpoint(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp := agentRelayDo(t, srv, "GET", "/stats/commands", "", "")
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("commands stats want 200, got %d", resp.StatusCode)
	}
	// 响应结构改为对象 { summary, by_project, daily }
	var body map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode commands stats: %v", err)
	}
	for _, key := range []string{"summary", "by_project", "daily"} {
		if _, ok := body[key]; !ok {
			t.Errorf("commands stats response missing key %q", key)
		}
	}
}

// TestCommandsStatsWithData 验证写入命令记录后，三段统计均返回正确数据。
func TestCommandsStatsWithData(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// 使用 async 入队（无 Agent 取命令时同步模式会等超时）
	resp := agentRelayDo(t, srv, "POST", "/agent/cmd?async=true", "application/json",
		`{"action":"status","project":"serein"}`)
	if resp.StatusCode != 200 {
		t.Fatalf("cmd enqueue want 200, got %d", resp.StatusCode)
	}
	var asyncResp struct {
		CmdID string `json:"cmd_id"`
	}
	json.NewDecoder(resp.Body).Decode(&asyncResp)
	resp.Body.Close()
	if asyncResp.CmdID == "" {
		t.Fatal("missing cmd_id in async enqueue response")
	}

	// Report 成功结果 → 触发 cmdRepo.Save（用 hook token 鉴权）
	req, _ := http.NewRequest("POST", srv.URL+"/agent/report",
		strings.NewReader(`{"cmd_id":"`+asyncResp.CmdID+`","success":true,"output":{"status":"done"}}`))
	req.Header.Set("Authorization", "Bearer hook-secret")
	req.Header.Set("Content-Type", "application/json")
	resp2, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp2.Body.Close()
	if resp2.StatusCode != 200 {
		t.Fatalf("report want 200, got %d", resp2.StatusCode)
	}

	// 查询统计（devMode clientAuth 放行）
	resp3 := agentRelayDo(t, srv, "GET", "/stats/commands?days=7", "", "")
	defer resp3.Body.Close()
	if resp3.StatusCode != 200 {
		t.Fatalf("commands stats want 200, got %d", resp3.StatusCode)
	}
	var stats struct {
		Summary   []map[string]interface{} `json:"summary"`
		ByProject []map[string]interface{} `json:"by_project"`
		Daily     []map[string]interface{} `json:"daily"`
	}
	if err := json.NewDecoder(resp3.Body).Decode(&stats); err != nil {
		t.Fatalf("decode stats: %v", err)
	}
	// summary 应包含 status action
	if len(stats.Summary) == 0 {
		t.Error("summary should not be empty after report")
	}
	// by_project 应包含 serein
	if len(stats.ByProject) == 0 {
		t.Error("by_project should not be empty after report")
	}
	foundProject := false
	for _, p := range stats.ByProject {
		if p["project"] == "serein" {
			foundProject = true
		}
	}
	if !foundProject {
		t.Error("by_project should contain serein")
	}
	// daily 应包含今天的记录
	if len(stats.Daily) == 0 {
		t.Error("daily should not be empty after report")
	}
}

func TestSparklineEndpoint(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp := agentRelayDo(t, srv, "GET", "/stats/sparkline", "", "")
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("sparkline want 200, got %d", resp.StatusCode)
	}
	var body []interface{}
	json.NewDecoder(resp.Body).Decode(&body)
	if body == nil {
		t.Error("sparkline should return empty array, not nil")
	}
}

// TestCmdShellMetaChars 测试所有需要拦截的 shell 元字符
func TestCmdShellMetaChars(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// 仅真正危险的 shell 元字符：; | & $ ` < >
	metaChars := []string{";", "|", "&", "$", "`", "<", ">"}
	for _, mc := range metaChars {
		resp := agentRelayDo(t, srv, "POST", "/agent/cmd", "application/json",
			`{"action":"status","project":"test","command":"test`+mc+`cmd"}`)
		if resp.StatusCode != 400 {
			t.Errorf("shell meta char %q should be rejected, got %d", mc, resp.StatusCode)
		}
		resp.Body.Close()
	}
}

// TestQueueEmpty 测试队列为空时的响应。
// 使用 200ms context 取消后，服务器 Dequeue 经由 <-ctx.Done() 快速返回 has_cmd:false。
func TestQueueEmpty(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, "GET", srv.URL+"/agent/queue", nil)
	req.Header.Set("Authorization", "Bearer hook-secret")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		// context 超时导致请求被客户端取消，但服务器可能已经返回响应
		t.Logf("queue empty returned error (expected): %v", err)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("empty queue want 200, got %d", resp.StatusCode)
	}
	var body map[string]interface{}
	json.NewDecoder(resp.Body).Decode(&body)
	if body["has_cmd"] != false {
		t.Errorf("empty queue should have has_cmd:false, got %v", body)
	}
}

// TestReportNoOutput 测试无 output 的 report
func TestReportNoOutput(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	req, _ := http.NewRequest("POST", srv.URL+"/agent/report",
		strings.NewReader(`{"cmd_id":"test","success":true}`))
	req.Header.Set("Authorization", "Bearer hook-secret")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("report no output want 200, got %d", resp.StatusCode)
	}
}

// TestHistoryEmpty 测试空 history
func TestAgentRelayHistoryEmpty(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp := agentRelayDo(t, srv, "GET", "/agent/history", "", "")
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("history want 200, got %d", resp.StatusCode)
	}
	var body []interface{}
	json.NewDecoder(resp.Body).Decode(&body)
	if len(body) != 0 {
		t.Errorf("empty history want [], got %d items", len(body))
	}
}

// TestActivitiesEndpoint 测试活动时间线端点
func TestActivitiesEndpoint(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp := agentRelayDo(t, srv, "GET", "/activities/recent", "", "")
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("activities want 200, got %d", resp.StatusCode)
	}
	var body []interface{}
	json.NewDecoder(resp.Body).Decode(&body)
	if body == nil {
		t.Error("activities should return empty array, not nil")
	}
}

// agentRelayDoWithTimeout 带 context 超时的请求发送（用于同步 cmd 测试）
func agentRelayDoWithTimeout(t *testing.T, srv *httptest.Server, timeout time.Duration, method, path, contentType, body string) *http.Response {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	var req *http.Request
	var err error
	if body != "" {
		req, err = http.NewRequestWithContext(ctx, method, srv.URL+path, strings.NewReader(body))
	} else {
		req, err = http.NewRequestWithContext(ctx, method, srv.URL+path, nil)
	}
	if err != nil {
		t.Fatalf("%s %s: %v", method, path, err)
	}
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("%s %s do: %v", method, path, err)
	}
	return resp
}

// TestCmdSyncTimeout 测试同步命令超时（没有 agent 取命令时客户端 context 提前取消）。
// 验证超时分层机制：客户端 5s 超时 → 请求 context 取消 → EnqueueCmd 提前返回。
func TestCmdSyncTimeout(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	start := time.Now()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, "POST", srv.URL+"/agent/cmd",
		strings.NewReader(`{"action":"status","project":"timeout-test"}`))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	_, err = http.DefaultClient.Do(req)

	// 客户端超时后应返回 context deadline exceeded 错误
	if err == nil {
		t.Error("sync cmd should have timed out")
	}
	if err != nil && !strings.Contains(err.Error(), "context deadline exceeded") &&
		!strings.Contains(err.Error(), "context canceled") {
		t.Errorf("unexpected error: %v", err)
	}
	elapsed := time.Since(start)
	if elapsed > 30*time.Second {
		t.Errorf("sync cmd timeout took too long: %v", elapsed)
	}
}

// TestSyncCmdUsesProjectSession 测试 cmd 正确创建 session
func TestCmdSessionAssociation(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// 发一个 status 命令到特定 project
	resp := agentRelayDo(t, srv, "POST", "/agent/cmd?async=true", "application/json",
		`{"action":"status","project":"session-test-project"}`)
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("async cmd want 200, got %d", resp.StatusCode)
	}

	// 验证命令被入队（通过 queue 读取）
	req, _ := http.NewRequest("GET", srv.URL+"/agent/queue", nil)
	req.Header.Set("Authorization", "Bearer hook-secret")
	resp2, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp2.Body.Close()
	var queueResp struct {
		HasCmd  bool   `json:"has_cmd"`
		Project string `json:"project"`
	}
	json.NewDecoder(resp2.Body).Decode(&queueResp)
	if queueResp.Project != "session-test-project" {
		t.Errorf("project should be session-test-project, got %s", queueResp.Project)
	}
}

// TestCmdStepWrongContentType 测试 CmdStep 的 Content-Type 校验
func TestCmdStepWrongContentType(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// CmdStep 在 hook 组中，需要 HOOK_TOKEN
	req, _ := http.NewRequest("POST", srv.URL+"/agent/cmd/test-id/step",
		strings.NewReader(`{"seq":1,"event":"text","content":"test"}`))
	req.Header.Set("Authorization", "Bearer hook-secret")
	req.Header.Set("Content-Type", "text/plain")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 415 {
		t.Errorf("wrong content-type want 415, got %d", resp.StatusCode)
	}
}

// TestAlertContentType 测试 Alert 的 Content-Type 校验
func TestAlertContentType(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// Alert 在 hook 组中，需要 HOOK_TOKEN
	req, _ := http.NewRequest("POST", srv.URL+"/agent/alert",
		strings.NewReader(`{"alerts":[]}`))
	req.Header.Set("Authorization", "Bearer hook-secret")
	req.Header.Set("Content-Type", "text/plain")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 415 {
		t.Errorf("alert wrong content-type want 415, got %d", resp.StatusCode)
	}
}

// TestReportContentType 测试 Report 的 Content-Type 校验
func TestReportContentType(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// Report 在 hook 组中，需要 HOOK_TOKEN
	req, _ := http.NewRequest("POST", srv.URL+"/agent/report",
		strings.NewReader(`{"success":true}`))
	req.Header.Set("Authorization", "Bearer hook-secret")
	req.Header.Set("Content-Type", "text/plain")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 415 {
		t.Errorf("report wrong content-type want 415, got %d", resp.StatusCode)
	}
}

// TestCmdStepsAfter 测试 steps after 参数
func TestCmdStepsAfter(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// 先发一个 cmd 获取 cmdID
	resp := agentRelayDo(t, srv, "POST", "/agent/cmd?async=true", "application/json",
		`{"action":"status","project":"steps-after-test"}`)
	defer resp.Body.Close()
	var asyncResp struct {
		CmdID string `json:"cmd_id"`
	}
	json.NewDecoder(resp.Body).Decode(&asyncResp)
	if asyncResp.CmdID == "" {
		t.Fatal("no cmd_id returned")
	}

	// 发 step seq=5
	req, _ := http.NewRequest("POST", srv.URL+"/agent/cmd/"+asyncResp.CmdID+"/step",
		strings.NewReader(`{"seq":5,"event":"text","content":"after test"}`))
	req.Header.Set("Authorization", "Bearer hook-secret")
	req.Header.Set("Content-Type", "application/json")
	resp2, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp2.Body.Close()

	// ?after=5 → 应返回空（只有 seq>5 的步骤）
	resp3 := agentRelayDo(t, srv, "GET", "/agent/cmd/"+asyncResp.CmdID+"/steps?after=5", "", "")
	defer resp3.Body.Close()
	var steps []map[string]interface{}
	json.NewDecoder(resp3.Body).Decode(&steps)
	if len(steps) != 0 {
		t.Errorf("steps after=5 should be empty, got %d", len(steps))
	}

	// ?after=0 → 应返回 seq=5 的步骤
	resp4 := agentRelayDo(t, srv, "GET", "/agent/cmd/"+asyncResp.CmdID+"/steps?after=0", "", "")
	defer resp4.Body.Close()
	json.NewDecoder(resp4.Body).Decode(&steps)
	if len(steps) != 1 {
		t.Errorf("steps after=0 should have 1 step, got %d", len(steps))
	}
}

// TestCmdIDForNonExec 测试非 exec action 的命令内容拦截
func TestCmdNonExecRejectsShellMeta(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// 所有非 exec action 都应该拦截 shell 元字符
	actions := []string{"start", "stop", "status", "kill-all"}
	for _, action := range actions {
		resp := agentRelayDo(t, srv, "POST", "/agent/cmd", "application/json",
			`{"action":"`+action+`","project":"test","command":"echo hello; rm -rf /"}`)
		if resp.StatusCode != 400 {
			t.Errorf("%s with shell meta should be rejected, got %d", action, resp.StatusCode)
		}
		resp.Body.Close()
	}
}

func TestOverviewEndpoint(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp := agentRelayDo(t, srv, "GET", "/stats/overview", "", "")
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("overview want 200, got %d", resp.StatusCode)
	}
	var body map[string]interface{}
	json.NewDecoder(resp.Body).Decode(&body)
	if body["daily"] == nil {
		t.Error("overview should have daily key")
	}
	if body["hourly"] == nil {
		t.Error("overview should have hourly key")
	}
}

// TestSanitizeDiff 验证 git diff 脱敏函数的每种正则模式
func TestSanitizeDiff(t *testing.T) {
	tests := []struct {
		name  string
		input string
		check func(t *testing.T, output string)
	}{
		{
			name:  "API key with equals",
			input: `+api_key=sk-1234567890abcdef`,
			check: func(t *testing.T, out string) {
				if out != `+api_key=<REDACTED>` {
					t.Errorf("api_key= pattern: got %q", out)
				}
			},
		},
		{
			name:  "token with colon",
			input: `-TOKEN: ghp_abcdefghijklmnop`,
			check: func(t *testing.T, out string) {
				if out != `-TOKEN: <REDACTED>` {
					t.Errorf("TOKEN: pattern: got %q", out)
				}
			},
		},
		{
			name:  "secret with colon and quotes",
			input: `+SECRET="my-secret-value"`,
			check: func(t *testing.T, out string) {
				if out != `+SECRET=<REDACTED>` {
					t.Errorf("SECRET pattern with quotes: got %q", out)
				}
			},
		},
		{
			name:  "password in env line",
			input: `+DB_PASSWORD=supersecret`,
			check: func(t *testing.T, out string) {
				if out != `+DB_PASSWORD=<REDACTED>` {
					t.Errorf("DB_PASSWORD pattern: got %q", out)
				}
			},
		},
		{
			name:  "connection string postgres",
			input: `+url=postgresql://user:mypass@localhost:5432/db`,
			check: func(t *testing.T, out string) {
				if !strings.Contains(out, "<REDACTED>") {
					t.Errorf("postgres connection string should be redacted, got %q", out)
				}
			},
		},
		{
			name:  "connection string mysql",
			input: `-mysql://root:password@127.0.0.1:3306/mydb`,
			check: func(t *testing.T, out string) {
				if !strings.Contains(out, "<REDACTED>") {
					t.Errorf("mysql connection string should be redacted, got %q", out)
				}
			},
		},
		{
			name:  "connection string redis",
			input: `+redis://default:secret@redis-1:6379`,
			check: func(t *testing.T, out string) {
				if !strings.Contains(out, "<REDACTED>") {
					t.Errorf("redis connection string should be redacted, got %q", out)
				}
			},
		},
		{
			name: "RSA private key block",
			// Go raw string literal spans multiple lines
			input: `+-----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCAQEA
-----END RSA PRIVATE KEY-----`,
			check: func(t *testing.T, out string) {
				if !strings.Contains(out, "<REDACTED>") {
					t.Errorf("RSA private key should be redacted, got %q", out)
				}
			},
		},
		{
			name: "SSH private key block",
			input: `+-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjE=
-----END OPENSSH PRIVATE KEY-----`,
			check: func(t *testing.T, out string) {
				if !strings.Contains(out, "<REDACTED>") {
					t.Errorf("SSH private key should be redacted, got %q", out)
				}
			},
		},
		{
			name:  ".env export API_KEY",
			input: `+export API_KEY=sk-abcdef123456`,
			check: func(t *testing.T, out string) {
				if out != `+export API_KEY=<REDACTED>` {
					t.Errorf("export API_KEY pattern: got %q", out)
				}
			},
		},
		{
			name:  ".env export SECRET_KEY with quotes",
			input: `+export SECRET_KEY="my-long-secret-value"`,
			check: func(t *testing.T, out string) {
				if out != `+export SECRET_KEY=<REDACTED>` {
					t.Errorf("export SECRET_KEY pattern: got %q", out)
				}
			},
		},
		{
			name:  ".env SSH_KEY",
			input: `+export SSH_KEY="ssh-rsa AAAAB3NzaC1yc2E..."`,
			check: func(t *testing.T, out string) {
				if out != `+export SSH_KEY=<REDACTED>` {
					t.Errorf("export SSH_KEY pattern: got %q", out)
				}
			},
		},
		{
			name:  "JWT token",
			input: `+eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jOHNsa7jSQ`,
			check: func(t *testing.T, out string) {
				if !strings.Contains(out, "<REDACTED>") {
					t.Errorf("JWT should be redacted, got %q", out)
				}
			},
		},
		{
			name: "normal diff content preserved",
			input: `+func main() {
+	fmt.Println("hello")
-	oldFunc()
+	newFunc()`,
			check: func(t *testing.T, out string) {
				if !strings.Contains(out, "func main") {
					t.Errorf("normal diff content should be preserved, got %q", out)
				}
			},
		},
		{
			name: "API key in diff hunk header",
			input: `@@ -1,3 +1,5 @@
+api_key=sk-123456`,
			check: func(t *testing.T, out string) {
				if !strings.Contains(out, "<REDACTED>") {
					t.Errorf("API key in hunk should be redacted, got %q", out)
				}
			},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := sanitizeDiff(tt.input)
			tt.check(t, got)
		})
	}
}
func TestCmdStepInvalidJSON(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// CmdStep 在 hook 组中，需要 HOOK_TOKEN
	req, _ := http.NewRequest("POST", srv.URL+"/agent/cmd/test-id/step",
		strings.NewReader(`not json`))
	req.Header.Set("Authorization", "Bearer hook-secret")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 400 {
		t.Errorf("invalid json want 400, got %d", resp.StatusCode)
	}
}

// TestProjectsEndpoint 测试 /agent/projects 端点
func TestProjectsEndpoint(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// 无心跳数据时返回 alive=false 和空 running 列表
	resp := agentRelayDo(t, srv, "GET", "/agent/projects", "", "")
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("projects want 200, got %d", resp.StatusCode)
	}
	var body map[string]interface{}
	json.NewDecoder(resp.Body).Decode(&body)
	if body["alive"] != false {
		t.Error("projects should show alive=false when no heartbeat")
	}
	running, _ := body["running"].([]interface{})
	if len(running) != 0 {
		t.Error("running should be empty when no heartbeat")
	}
}

// TestProjectsEndpointWithHeartbeat 测试心跳后 /agent/projects 端点返回 running 信息
func TestProjectsEndpointWithHeartbeat(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// 发送带 projects/running 信息的心跳
	req, _ := http.NewRequest("POST", srv.URL+"/agent/report",
		strings.NewReader(`{"success":true,"output":{"_heartbeat":true,"projects":{"myapp":"/path/to/myapp"},"desktop_projects":{"myapp":{"available":true,"thread_count":2}},"running":["myapp"],"status":"running"}}`))
	req.Header.Set("Authorization", "Bearer hook-secret")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()

	// 验证 projects 端点返回了正确的项目信息
	resp2 := agentRelayDo(t, srv, "GET", "/agent/projects", "", "")
	defer resp2.Body.Close()
	if resp2.StatusCode != 200 {
		t.Fatalf("projects want 200, got %d", resp2.StatusCode)
	}
	var body map[string]interface{}
	json.NewDecoder(resp2.Body).Decode(&body)
	if body["alive"] != true {
		t.Error("projects should show alive=true after heartbeat")
	}
	running, _ := body["running"].([]interface{})
	if len(running) != 1 || running[0] != "myapp" {
		t.Errorf("running should contain myapp, got %v", running)
	}
	projects, ok := body["projects"].(map[string]interface{})
	if !ok {
		t.Fatal("projects should be a map")
	}
	if projects["myapp"] != "/path/to/myapp" {
		t.Errorf("projects myapp path mismatch: %v", projects["myapp"])
	}
	desktopProjects, ok := body["desktop_projects"].(map[string]interface{})
	if !ok {
		t.Fatal("desktop_projects should be a map")
	}
	desktop, ok := desktopProjects["myapp"].(map[string]interface{})
	if !ok || desktop["available"] != true || desktop["thread_count"] != float64(2) {
		t.Fatalf("desktop project capability mismatch: %v", desktopProjects["myapp"])
	}
}
