package api

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"

	"serein/internal/approval"
	rdplog "serein/internal/log"
	"serein/internal/notify"
	"serein/internal/risk"
	"serein/internal/store"
)

func setupTestServer(t *testing.T, hookToken string, timeoutSec int) http.Handler {
	t.Helper()
	db, err := store.Open(":memory:")
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	svc := approval.NewService(db, timeoutSec)
	pub := notify.New("http://127.0.0.1:59999", "test") // 假 ntfy,publish 失败不阻塞
	sessionRepo := store.NewSessionRepo(db)
	engine := risk.New(store.NewBlacklistRepo(db), store.NewWhitelistRepo(db), sessionRepo)
	devHandler := NewDeviceHandler(store.NewDeviceRepo(db), "test-pair-code")
	cfgHandler := NewConfigHandler(store.NewWhitelistRepo(db), store.NewBlacklistRepo(db), engine)
	deviceRepo := store.NewDeviceRepo(db)
	return NewRouter(RouterConfig{
		HookToken:         hookToken,
		GlobalClientToken: "",
		PairCode:          "test-pair-code",
		DevMode:           true,
		TLS:               false,
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

// setupTestServerWithClientToken 创建带 client token 的测试服务器。
// devMode=true 时无 token 放行(兼容旧 dev 测试);false 模拟生产鉴权(无 token 401)。
func setupTestServerWithClientToken(t *testing.T, hookToken, clientToken string, devMode bool, timeoutSec int) http.Handler {
	t.Helper()
	db, err := store.Open(":memory:")
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	svc := approval.NewService(db, timeoutSec)
	pub := notify.New("http://127.0.0.1:59999", "test")
	sessionRepo := store.NewSessionRepo(db)
	engine := risk.New(store.NewBlacklistRepo(db), store.NewWhitelistRepo(db), sessionRepo)
	devHandler := NewDeviceHandler(store.NewDeviceRepo(db), "test-pair-code")
	cfgHandler := NewConfigHandler(store.NewWhitelistRepo(db), store.NewBlacklistRepo(db), engine)
	deviceRepo := store.NewDeviceRepo(db)
	return NewRouter(RouterConfig{
		HookToken:         hookToken,
		GlobalClientToken: clientToken,
		PairCode:          "test-pair-code",
		DevMode:           devMode,
		TLS:               false,
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

func TestPairQRCodeUsesConfiguredPairCode(t *testing.T) {
	handler := setupTestServerWithClientToken(t, "hook-token", "", false, 300)
	req := httptest.NewRequest(http.MethodGet, "/pair/qrcode", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "|test-pair-code") {
		t.Fatalf("pair QR does not contain configured code: %s", body)
	}
	if strings.Contains(body, "serein-pair-me") {
		t.Fatal("pair QR still contains the legacy default pair code")
	}
}

func TestHealthz(t *testing.T) {
	handler := setupTestServer(t, "", 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()
	resp, err := http.Get(srv.URL + "/healthz")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Errorf("want 200, got %d", resp.StatusCode)
	}
}

func TestRegisterPushTokenIsAuthenticatedAndWriteOnly(t *testing.T) {
	handler := setupTestServer(t, "", 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	pairBody := `{"device_name":"phone","pair_code":"test-pair-code"}`
	resp, err := http.Post(srv.URL+"/devices/pair", "application/json", strings.NewReader(pairBody))
	if err != nil {
		t.Fatal(err)
	}
	var paired struct {
		ClientToken string `json:"client_token"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&paired); err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if paired.ClientToken == "" {
		t.Fatal("pair response missing client token")
	}

	const pushToken = "push-token-abcdefghijklmnopqrstuvwxyz"
	req, _ := http.NewRequest(http.MethodPut, srv.URL+"/devices/current/push-token", strings.NewReader(`{"push_token":"`+pushToken+`"}`))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+paired.ClientToken)
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.StatusCode, raw)
	}
	if strings.Contains(string(raw), pushToken) {
		t.Fatal("push token was echoed to the client")
	}
	if !strings.Contains(string(raw), `"registered":true`) || !strings.Contains(string(raw), `"delivery_enabled":false`) {
		t.Fatalf("unexpected response: %s", raw)
	}

	unauth, _ := http.NewRequest(http.MethodPut, srv.URL+"/devices/current/push-token", strings.NewReader(`{"push_token":"`+pushToken+`"}`))
	unauth.Header.Set("Content-Type", "application/json")
	resp, err = http.DefaultClient.Do(unauth)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("unauthenticated status=%d, want 401", resp.StatusCode)
	}
}

func TestCreateStatusDecideFlow(t *testing.T) {
	handler := setupTestServer(t, "", 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// POST /approvals
	body := `{"session_id":"s1","tool_name":"Bash","command":"rm -rf x","risk_level":"red","rule_reason":"test"}`
	resp, err := http.Post(srv.URL+"/approvals", "application/json", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != 201 {
		t.Fatalf("want 201, got %d", resp.StatusCode)
	}
	var cr struct {
		ID string `json:"id"`
	}
	json.NewDecoder(resp.Body).Decode(&cr)
	resp.Body.Close()
	if cr.ID == "" {
		t.Fatal("want non-empty id")
	}

	// GET /status → pending
	resp, _ = http.Get(srv.URL + "/approvals/" + cr.ID + "/status")
	var st struct {
		Decision string `json:"decision"`
	}
	json.NewDecoder(resp.Body).Decode(&st)
	resp.Body.Close()
	if st.Decision != "pending" {
		t.Errorf("want pending, got %s", st.Decision)
	}

	// POST /decide allow
	resp, _ = http.Post(srv.URL+"/approvals/"+cr.ID+"/decide", "application/json",
		strings.NewReader(`{"decision":"allow","reason":"ok"}`))
	if resp.StatusCode != 200 {
		t.Errorf("decide want 200, got %d", resp.StatusCode)
	}
	resp.Body.Close()

	// GET /status → allow
	resp, _ = http.Get(srv.URL + "/approvals/" + cr.ID + "/status")
	json.NewDecoder(resp.Body).Decode(&st)
	resp.Body.Close()
	if st.Decision != "allow" {
		t.Errorf("want allow, got %s", st.Decision)
	}
}

func TestDecideDenyFlow(t *testing.T) {
	handler := setupTestServer(t, "", 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()
	resp, _ := http.Post(srv.URL+"/approvals", "application/json",
		strings.NewReader(`{"session_id":"s1","tool_name":"Bash","command":"rm -rf test","risk_level":"red"}`))
	var cr struct {
		ID string `json:"id"`
	}
	json.NewDecoder(resp.Body).Decode(&cr)
	resp.Body.Close()

	resp, _ = http.Post(srv.URL+"/approvals/"+cr.ID+"/decide", "application/json",
		strings.NewReader(`{"decision":"deny"}`))
	if resp.StatusCode != 200 {
		t.Errorf("want 200, got %d", resp.StatusCode)
	}
	resp.Body.Close()

	resp, _ = http.Get(srv.URL + "/approvals/" + cr.ID + "/status")
	var st struct {
		Decision string `json:"decision"`
	}
	json.NewDecoder(resp.Body).Decode(&st)
	resp.Body.Close()
	if st.Decision != "deny" {
		t.Errorf("want deny, got %s", st.Decision)
	}
}

func TestDecideInvalidDecision(t *testing.T) {
	handler := setupTestServer(t, "", 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()
	resp, _ := http.Post(srv.URL+"/approvals/x/decide", "application/json",
		strings.NewReader(`{"decision":"maybe"}`))
	if resp.StatusCode != 400 {
		t.Errorf("want 400, got %d", resp.StatusCode)
	}
	resp.Body.Close()
}

func TestStatusNotFound(t *testing.T) {
	handler := setupTestServer(t, "", 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()
	resp, _ := http.Get(srv.URL + "/approvals/nonexistent/status")
	if resp.StatusCode != 404 {
		t.Errorf("want 404, got %d", resp.StatusCode)
	}
	resp.Body.Close()
}

func TestHookAuth(t *testing.T) {
	handler := setupTestServer(t, "secret-token", 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()
	// 无 token → 401
	resp, _ := http.Post(srv.URL+"/approvals", "application/json",
		strings.NewReader(`{"session_id":"s1","tool_name":"Bash","command":"rm","risk_level":"red"}`))
	if resp.StatusCode != 401 {
		t.Errorf("want 401, got %d", resp.StatusCode)
	}
	resp.Body.Close()
	// 正确 token → 201
	req, _ := http.NewRequest("POST", srv.URL+"/approvals",
		bytes.NewReader([]byte(`{"session_id":"s1","tool_name":"Bash","command":"rm","risk_level":"red"}`)))
	req.Header.Set("Authorization", "Bearer secret-token")
	req.Header.Set("Content-Type", "application/json")
	resp, _ = http.DefaultClient.Do(req)
	if resp.StatusCode != 201 {
		t.Errorf("want 201, got %d", resp.StatusCode)
	}
	resp.Body.Close()
}

func TestHistory(t *testing.T) {
	handler := setupTestServer(t, "", 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()
	for i := 0; i < 2; i++ {
		resp, _ := http.Post(srv.URL+"/approvals", "application/json",
			strings.NewReader(`{"session_id":"s1","tool_name":"Bash","command":"rm","risk_level":"red"}`))
		resp.Body.Close()
	}
	resp, _ := http.Get(srv.URL + "/approvals/history")
	var hr struct {
		Total int           `json:"total"`
		Items []interface{} `json:"items"`
	}
	json.NewDecoder(resp.Body).Decode(&hr)
	resp.Body.Close()
	if hr.Total != 2 || len(hr.Items) != 2 {
		t.Errorf("want 2, got total=%d len=%d", hr.Total, len(hr.Items))
	}
}

// ── Phase 2 测试 ──

func TestDevicePairValid(t *testing.T) {
	handler := setupTestServer(t, "", 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp, err := http.Post(srv.URL+"/devices/pair", "application/json",
		strings.NewReader(`{"device_name":"my-phone","pair_code":"test-pair-code"}`))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 201 {
		t.Fatalf("want 201, got %d", resp.StatusCode)
	}
	var out struct {
		DeviceID    string `json:"device_id"`
		DeviceName  string `json:"device_name"`
		ClientToken string `json:"client_token"`
	}
	json.NewDecoder(resp.Body).Decode(&out)
	if out.DeviceID == "" || out.ClientToken == "" || out.DeviceName != "my-phone" {
		t.Errorf("unexpected pair response: %+v", out)
	}
}

func TestDevicePairInvalidCode(t *testing.T) {
	handler := setupTestServer(t, "", 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp, _ := http.Post(srv.URL+"/devices/pair", "application/json",
		strings.NewReader(`{"device_name":"x","pair_code":"wrong"}`))
	resp.Body.Close()
	if resp.StatusCode != 403 {
		t.Errorf("want 403, got %d", resp.StatusCode)
	}
}

func TestDevicePairRequiresCurrentDeviceToUnpairFirst(t *testing.T) {
	handler := setupTestServer(t, "", 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()
	first, err := http.Post(srv.URL+"/devices/pair", "application/json",
		strings.NewReader(`{"device_name":"first","pair_code":"test-pair-code"}`))
	if err != nil || first.StatusCode != http.StatusCreated {
		t.Fatalf("first pair status=%v err=%v", first.StatusCode, err)
	}
	var paired struct {
		ClientToken string `json:"client_token"`
	}
	if err := json.NewDecoder(first.Body).Decode(&paired); err != nil || paired.ClientToken == "" {
		t.Fatalf("decode first pair: %v", err)
	}
	first.Body.Close()
	second, err := http.Post(srv.URL+"/devices/pair", "application/json",
		strings.NewReader(`{"device_name":"second","pair_code":"test-pair-code"}`))
	if err != nil {
		t.Fatal(err)
	}
	if second.StatusCode != http.StatusConflict {
		t.Fatalf("second pair want 409, got %d", second.StatusCode)
	}
	second.Body.Close()
	req, _ := http.NewRequest(http.MethodDelete, srv.URL+"/devices/current", nil)
	req.Header.Set("Authorization", "Bearer "+paired.ClientToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil || resp.StatusCode != http.StatusNoContent {
		t.Fatalf("unpair status=%v err=%v", resp.StatusCode, err)
	}
	resp.Body.Close()
	third, err := http.Post(srv.URL+"/devices/pair", "application/json",
		strings.NewReader(`{"device_name":"second","pair_code":"test-pair-code"}`))
	if err != nil || third.StatusCode != http.StatusCreated {
		t.Fatalf("pair after unpair status=%v err=%v", third.StatusCode, err)
	}
	third.Body.Close()
}

func TestDevicePairInvalidJSON(t *testing.T) {
	handler := setupTestServer(t, "", 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp, _ := http.Post(srv.URL+"/devices/pair", "application/json",
		strings.NewReader(`not json`))
	if resp.StatusCode != 400 {
		t.Errorf("want 400, got %d", resp.StatusCode)
	}
	resp.Body.Close()
}

func TestDevicePairMissingName(t *testing.T) {
	handler := setupTestServer(t, "", 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp, _ := http.Post(srv.URL+"/devices/pair", "application/json",
		strings.NewReader(`{"device_name":"","pair_code":"test-pair-code"}`))
	resp.Body.Close()
	if resp.StatusCode != 400 {
		t.Errorf("want 400, got %d", resp.StatusCode)
	}
}

func TestConfigWhitelistCRUD(t *testing.T) {
	handler := setupTestServer(t, "", 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// 空列表
	resp, _ := http.Get(srv.URL + "/config/whitelist")
	var list []map[string]interface{}
	json.NewDecoder(resp.Body).Decode(&list)
	resp.Body.Close()
	if len(list) != 0 {
		t.Fatalf("want empty list, got %d", len(list))
	}

	// 添加
	resp, _ = http.Post(srv.URL+"/config/whitelist", "application/json",
		strings.NewReader(`{"pattern":"^go test","description":"go test免审"}`))
	var entry map[string]interface{}
	json.NewDecoder(resp.Body).Decode(&entry)
	resp.Body.Close()
	if resp.StatusCode != 201 {
		t.Fatalf("add want 201, got %d", resp.StatusCode)
	}
	id := int(entry["id"].(float64))

	// 列表应有 1 条
	resp, _ = http.Get(srv.URL + "/config/whitelist")
	json.NewDecoder(resp.Body).Decode(&list)
	resp.Body.Close()
	if len(list) != 1 {
		t.Fatalf("want 1, got %d", len(list))
	}

	// 删除
	req, _ := http.NewRequest("DELETE", srv.URL+"/config/whitelist/"+strconv.Itoa(id), nil)
	resp, _ = http.DefaultClient.Do(req)
	if resp.StatusCode != 200 {
		t.Errorf("delete want 200, got %d", resp.StatusCode)
	}
	resp.Body.Close()

	// 列表应空
	resp, _ = http.Get(srv.URL + "/config/whitelist")
	json.NewDecoder(resp.Body).Decode(&list)
	resp.Body.Close()
	if len(list) != 0 {
		t.Errorf("want 0 after delete, got %d", len(list))
	}
}

func TestConfigBlacklistCRUD(t *testing.T) {
	handler := setupTestServer(t, "", 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp, _ := http.Post(srv.URL+"/config/blacklist", "application/json",
		strings.NewReader(`{"pattern":"^scp","description":"scp全封"}`))
	var entry map[string]interface{}
	json.NewDecoder(resp.Body).Decode(&entry)
	resp.Body.Close()
	if resp.StatusCode != 201 {
		t.Fatalf("add want 201, got %d", resp.StatusCode)
	}
	id := int(entry["id"].(float64))

	// 查列表
	resp, _ = http.Get(srv.URL + "/config/blacklist")
	var list []map[string]interface{}
	json.NewDecoder(resp.Body).Decode(&list)
	resp.Body.Close()
	if len(list) != 1 {
		t.Errorf("want 1, got %d", len(list))
	}

	// 删不存在的 id
	req, _ := http.NewRequest("DELETE", srv.URL+"/config/blacklist/999", nil)
	resp, _ = http.DefaultClient.Do(req)
	if resp.StatusCode != 404 {
		t.Errorf("delete 999 want 404, got %d", resp.StatusCode)
	}
	resp.Body.Close()

	// 删存在的
	req, _ = http.NewRequest("DELETE", srv.URL+"/config/blacklist/"+strconv.Itoa(id), nil)
	resp, _ = http.DefaultClient.Do(req)
	if resp.StatusCode != 200 {
		t.Errorf("delete want 200, got %d", resp.StatusCode)
	}
	resp.Body.Close()
}

func TestApprovalDetail(t *testing.T) {
	handler := setupTestServer(t, "", 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// 创建审批
	resp, _ := http.Post(srv.URL+"/approvals", "application/json",
		strings.NewReader(`{"session_id":"s-detail","tool_name":"Bash","command":"rm -rf /tmp/test","risk_level":"red"}`))
	var cr struct {
		ID string `json:"id"`
	}
	json.NewDecoder(resp.Body).Decode(&cr)
	resp.Body.Close()

	// GET /approvals/{id}
	resp, _ = http.Get(srv.URL + "/approvals/" + cr.ID)
	if resp.StatusCode != 200 {
		t.Fatalf("detail want 200, got %d", resp.StatusCode)
	}
	var rec struct {
		ID        string `json:"id"`
		SessionID string `json:"session_id"`
		Command   string `json:"command"`
		Decision  string `json:"decision"`
	}
	json.NewDecoder(resp.Body).Decode(&rec)
	resp.Body.Close()
	if rec.ID != cr.ID || rec.SessionID != "s-detail" || rec.Command != "rm -rf /tmp/test" {
		t.Errorf("detail mismatch: %+v", rec)
	}

	// 不存在的 id
	resp, _ = http.Get(srv.URL + "/approvals/nonexistent")
	if resp.StatusCode != 404 {
		t.Errorf("detail 404 want 404, got %d", resp.StatusCode)
	}
	resp.Body.Close()
}

func TestSessionMemoAutoApprove(t *testing.T) {
	handler := setupTestServer(t, "", 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	sessionID := "auto-memo-session"
	cmd := "rm -rf ./build"

	// 第一次: 红命令 → 创建 pending
	resp, _ := http.Post(srv.URL+"/approvals", "application/json",
		strings.NewReader(`{"session_id":"`+sessionID+`","tool_name":"Bash","command":"`+cmd+`","risk_level":"red"}`))
	var cr struct {
		ID       string `json:"id"`
		Auto     string `json:"auto"`
		Decision string `json:"decision"`
	}
	json.NewDecoder(resp.Body).Decode(&cr)
	resp.Body.Close()
	if cr.ID == "" {
		t.Fatal("want non-empty id")
	}
	if cr.Auto == "true" {
		t.Error("first time should NOT auto-approve (no session memo yet)")
	}

	// decide allow → 写入 session_memo
	resp, _ = http.Post(srv.URL+"/approvals/"+cr.ID+"/decide", "application/json",
		strings.NewReader(`{"decision":"allow"}`))
	resp.Body.Close()

	// 第二次: 同 session + 同命令 → 会话记忆命中,auto-approve
	resp, _ = http.Post(srv.URL+"/approvals", "application/json",
		strings.NewReader(`{"session_id":"`+sessionID+`","tool_name":"Bash","command":"`+cmd+`","risk_level":"red"}`))
	var cr2 struct {
		ID       string `json:"id"`
		Auto     string `json:"auto"`
		Decision string `json:"decision"`
	}
	json.NewDecoder(resp.Body).Decode(&cr2)
	resp.Body.Close()
	if cr2.ID == "" {
		t.Fatal("want non-empty id on second create")
	}
	if cr2.Auto != "true" {
		t.Errorf("second time should auto-approve via session memo, got auto=%s", cr2.Auto)
	}
	if cr2.Decision != "allow" {
		t.Errorf("want allow, got %s", cr2.Decision)
	}
}

func TestSessionMemoDifferentSession(t *testing.T) {
	handler := setupTestServer(t, "", 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	cmd := "rm -rf ./build"

	// session A: create + decide allow
	resp, _ := http.Post(srv.URL+"/approvals", "application/json",
		strings.NewReader(`{"session_id":"s-A","tool_name":"Bash","command":"`+cmd+`","risk_level":"red"}`))
	var cr struct {
		ID string `json:"id"`
	}
	json.NewDecoder(resp.Body).Decode(&cr)
	resp.Body.Close()
	http.Post(srv.URL+"/approvals/"+cr.ID+"/decide", "application/json",
		strings.NewReader(`{"decision":"allow"}`))

	// session B: 同命令 BUT 不同 session → 不应 auto-approve(会话记忆按 session 隔离)
	resp, _ = http.Post(srv.URL+"/approvals", "application/json",
		strings.NewReader(`{"session_id":"s-B","tool_name":"Bash","command":"`+cmd+`","risk_level":"red"}`))
	var cr2 struct {
		ID   string `json:"id"`
		Auto string `json:"auto"`
	}
	json.NewDecoder(resp.Body).Decode(&cr2)
	resp.Body.Close()
	if cr2.Auto == "true" {
		t.Error("different session should NOT auto-approve (memo is per-session)")
	}
}

func TestClientAuthProtectedRoutes(t *testing.T) {
	// 生产模式(无 token 必须拒绝)。使用 per-device token(查 DB)验证。
	handler := setupTestServerWithClientToken(t, "", "", false, 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// 配对一个真实设备,获取它的 CLIENT_TOKEN
	peerBody := bytes.NewBufferString(`{"pair_code":"test-pair-code","device_name":"test-device"}`)
	resp, err := http.Post(srv.URL+"/devices/pair", "application/json", peerBody)
	if err != nil {
		t.Fatalf("pair: %v", err)
	}
	var pairResp struct {
		ClientToken string `json:"client_token"`
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if err := json.Unmarshal(body, &pairResp); err != nil || pairResp.ClientToken == "" {
		t.Fatalf("pair response: %s err=%v", body, err)
	}
	clientToken := pairResp.ClientToken

	// history 无 token → 401
	resp, _ = http.Get(srv.URL + "/approvals/history")
	if resp.StatusCode != 401 {
		t.Errorf("history no token want 401, got %d", resp.StatusCode)
	}
	resp.Body.Close()

	// history 正确 per-device token → 200
	req, _ := http.NewRequest("GET", srv.URL+"/approvals/history", nil)
	req.Header.Set("Authorization", "Bearer "+clientToken)
	resp, _ = http.DefaultClient.Do(req)
	if resp.StatusCode != 200 {
		t.Errorf("history with token want 200, got %d", resp.StatusCode)
	}
	resp.Body.Close()

	// config whitelist 无 token → 401
	resp, _ = http.Get(srv.URL + "/config/whitelist")
	if resp.StatusCode != 401 {
		t.Errorf("config no token want 401, got %d", resp.StatusCode)
	}
	resp.Body.Close()
}

func TestHookAuthDoesNotAccessClientRoutes(t *testing.T) {
	// 只配 HOOK_TOKEN,CLIENT_TOKEN 也配(生产双 token 隔离)
	handler := setupTestServerWithClientToken(t, "hook-secret", "client-secret", false, 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// hook token 无法访问客户端路由(history 需要 CLIENT_TOKEN)
	req, _ := http.NewRequest("GET", srv.URL+"/approvals/history", nil)
	req.Header.Set("Authorization", "Bearer hook-secret")
	resp, _ := http.DefaultClient.Do(req)
	if resp.StatusCode != 401 {
		t.Errorf("hook token on client route want 401, got %d", resp.StatusCode)
	}
	resp.Body.Close()

	// client token 也无法访问 hook 路由(create 需要 HOOK_TOKEN)
	req, _ = http.NewRequest("POST", srv.URL+"/approvals", strings.NewReader(
		`{"session_id":"s","tool_name":"Bash","command":"ls","risk_level":"green"}`))
	req.Header.Set("Authorization", "Bearer client-secret")
	req.Header.Set("Content-Type", "application/json")
	resp, _ = http.DefaultClient.Do(req)
	if resp.StatusCode != 401 {
		t.Errorf("client token on hook route want 401, got %d", resp.StatusCode)
	}
	resp.Body.Close()
}

func TestClientAuthPerDevice(t *testing.T) {
	// 生产模式:无全局 token,纯 per-device DB 校验
	handler := setupTestServerWithClientToken(t, "", "", false, 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// 1. 配对设备拿 per-device token
	resp, err := http.Post(srv.URL+"/devices/pair", "application/json",
		strings.NewReader(`{"device_name":"my-phone","pair_code":"test-pair-code"}`))
	if err != nil {
		t.Fatalf("pair request: %v", err)
	}
	if resp.StatusCode != 201 {
		t.Fatalf("pair want 201, got %d", resp.StatusCode)
	}
	var pair struct {
		ClientToken string `json:"client_token"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&pair); err != nil {
		t.Fatalf("decode pair: %v", err)
	}
	resp.Body.Close()
	if pair.ClientToken == "" {
		t.Fatal("pair returned empty client_token")
	}

	// 2. per-device token 访问 client 路由 → 200
	req, _ := http.NewRequest("GET", srv.URL+"/approvals/history", nil)
	req.Header.Set("Authorization", "Bearer "+pair.ClientToken)
	resp, _ = http.DefaultClient.Do(req)
	if resp.StatusCode != 200 {
		t.Errorf("per-device token want 200, got %d", resp.StatusCode)
	}
	resp.Body.Close()

	// 3. 未配对 token → 401
	req, _ = http.NewRequest("GET", srv.URL+"/approvals/history", nil)
	req.Header.Set("Authorization", "Bearer fake-not-paired-token")
	resp, _ = http.DefaultClient.Do(req)
	if resp.StatusCode != 401 {
		t.Errorf("unknown token want 401, got %d", resp.StatusCode)
	}
	resp.Body.Close()

	// 4. 无 token(生产模式) → 401
	resp, _ = http.Get(srv.URL + "/approvals/history")
	if resp.StatusCode != 401 {
		t.Errorf("no token prod mode want 401, got %d", resp.StatusCode)
	}
	resp.Body.Close()
}

func TestPairRateLimit(t *testing.T) {
	handler := setupTestServer(t, "", 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()
	// 前 10 次:错误 pair_code 返回 403,但 rateLimit 已计数
	for i := 0; i < 10; i++ {
		resp, err := http.Post(srv.URL+"/devices/pair", "application/json",
			strings.NewReader(`{"device_name":"x","pair_code":"wrong"}`))
		if err != nil {
			t.Fatalf("attempt %d: %v", i, err)
		}
		if resp.StatusCode != 403 {
			t.Fatalf("attempt %d want 403, got %d", i, resp.StatusCode)
		}
		resp.Body.Close()
	}
	// 第 11 次 → 429 限流
	resp, _ := http.Post(srv.URL+"/devices/pair", "application/json",
		strings.NewReader(`{"device_name":"x","pair_code":"wrong"}`))
	if resp.StatusCode != 429 {
		t.Errorf("11th attempt want 429, got %d", resp.StatusCode)
	}
	resp.Body.Close()
}

func TestCreateInvalidJSON(t *testing.T) {
	handler := setupTestServer(t, "", 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp, _ := http.Post(srv.URL+"/approvals", "application/json",
		strings.NewReader(`not json`))
	if resp.StatusCode != 400 {
		t.Errorf("want 400, got %d", resp.StatusCode)
	}
	resp.Body.Close()
}

func TestCreateMissingFields(t *testing.T) {
	handler := setupTestServer(t, "", 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp, _ := http.Post(srv.URL+"/approvals", "application/json",
		strings.NewReader(`{}`))
	if resp.StatusCode != 400 {
		t.Errorf("want 400, got %d", resp.StatusCode)
	}
	resp.Body.Close()
}

func TestDecideAlreadyDecided(t *testing.T) {
	handler := setupTestServer(t, "", 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// 创建 + decide
	resp, _ := http.Post(srv.URL+"/approvals", "application/json",
		strings.NewReader(`{"session_id":"s","tool_name":"Bash","command":"rm x","risk_level":"red"}`))
	var cr struct {
		ID string `json:"id"`
	}
	json.NewDecoder(resp.Body).Decode(&cr)
	resp.Body.Close()

	resp, _ = http.Post(srv.URL+"/approvals/"+cr.ID+"/decide", "application/json",
		strings.NewReader(`{"decision":"allow"}`))
	resp.Body.Close()

	// 再次 decide → 409
	resp, _ = http.Post(srv.URL+"/approvals/"+cr.ID+"/decide", "application/json",
		strings.NewReader(`{"decision":"deny"}`))
	if resp.StatusCode != 409 {
		t.Errorf("want 409, got %d", resp.StatusCode)
	}
	resp.Body.Close()
}

func TestDecideEmptyBody(t *testing.T) {
	handler := setupTestServer(t, "", 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp, _ := http.Post(srv.URL+"/approvals/x/decide", "application/json",
		strings.NewReader(``))
	if resp.StatusCode != 400 {
		t.Errorf("want 400, got %d", resp.StatusCode)
	}
	resp.Body.Close()
}

func TestHistoryWithStatusFilter(t *testing.T) {
	handler := setupTestServer(t, "", 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// 创建 2 个 pending，1 个 decide (用 rm -rf 保证触红)
	resp, _ := http.Post(srv.URL+"/approvals", "application/json",
		strings.NewReader(`{"session_id":"s","tool_name":"Bash","command":"rm -rf /tmp/a","risk_level":"red"}`))
	var cr struct {
		ID string `json:"id"`
	}
	json.NewDecoder(resp.Body).Decode(&cr)
	resp.Body.Close()

	resp, _ = http.Post(srv.URL+"/approvals", "application/json",
		strings.NewReader(`{"session_id":"s","tool_name":"Bash","command":"rm -rf /tmp/b","risk_level":"red"}`))
	resp.Body.Close()

	// decide first one
	resp, _ = http.Post(srv.URL+"/approvals/"+cr.ID+"/decide", "application/json",
		strings.NewReader(`{"decision":"deny"}`))
	resp.Body.Close()

	// filter only pending → 1 result
	resp, _ = http.Get(srv.URL + "/approvals/history?status=pending")
	var hr struct {
		Total int           `json:"total"`
		Items []interface{} `json:"items"`
	}
	json.NewDecoder(resp.Body).Decode(&hr)
	resp.Body.Close()
	if hr.Total != 1 {
		t.Errorf("want 1 pending, got total=%d", hr.Total)
	}
}

func TestCreateGreenAutoApprove(t *testing.T) {
	handler := setupTestServer(t, "", 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// 绿命令 (echo) → 后端二次分级应自动 approve
	resp, _ := http.Post(srv.URL+"/approvals", "application/json",
		strings.NewReader(`{"session_id":"s","tool_name":"Bash","command":"echo hello","risk_level":"green"}`))
	var cr struct {
		ID       string `json:"id"`
		Decision string `json:"decision"`
		Auto     string `json:"auto"`
	}
	json.NewDecoder(resp.Body).Decode(&cr)
	resp.Body.Close()
	if resp.StatusCode != 201 {
		t.Fatalf("want 201, got %d", resp.StatusCode)
	}
	if cr.Auto != "true" || cr.Decision != "allow" {
		t.Errorf("green cmd should auto-approve: auto=%s decision=%s", cr.Auto, cr.Decision)
	}
}

func TestCreateReadOnlyToolAutoApprove(t *testing.T) {
	handler := setupTestServer(t, "", 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// Read 工具(只读) → 应自动 approve
	resp, _ := http.Post(srv.URL+"/approvals", "application/json",
		strings.NewReader(`{"session_id":"s","tool_name":"Read","command":"","risk_level":"green"}`))
	var cr struct {
		Decision string `json:"decision"`
		Auto     string `json:"auto"`
	}
	json.NewDecoder(resp.Body).Decode(&cr)
	resp.Body.Close()
	if cr.Auto != "true" || cr.Decision != "allow" {
		t.Errorf("read-only tool should auto-approve: auto=%s decision=%s", cr.Auto, cr.Decision)
	}
}

func TestHealthzIs200(t *testing.T) {
	handler := setupTestServer(t, "", 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp, _ := http.Get(srv.URL + "/healthz")
	var body map[string]bool
	json.NewDecoder(resp.Body).Decode(&body)
	resp.Body.Close()
	if resp.StatusCode != 200 || !body["ok"] {
		t.Error("healthz should return 200 ok")
	}
}

func TestConfigWhitelistErrors(t *testing.T) {
	handler := setupTestServer(t, "", 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// 添加空 pattern → 400
	resp, _ := http.Post(srv.URL+"/config/whitelist", "application/json",
		strings.NewReader(`{}`))
	if resp.StatusCode != 400 {
		t.Errorf("add empty want 400, got %d", resp.StatusCode)
	}
	resp.Body.Close()

	// 删除不存在 → 404
	req, _ := http.NewRequest("DELETE", srv.URL+"/config/whitelist/99999", nil)
	resp, _ = http.DefaultClient.Do(req)
	if resp.StatusCode != 404 {
		t.Errorf("delete not-found want 404, got %d", resp.StatusCode)
	}
	resp.Body.Close()
}

func TestConfigBlacklistErrors(t *testing.T) {
	handler := setupTestServer(t, "", 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// 添加空 pattern → 400
	resp, _ := http.Post(srv.URL+"/config/blacklist", "application/json",
		strings.NewReader(`{"pattern":""}`))
	if resp.StatusCode != 400 {
		t.Errorf("add empty want 400, got %d", resp.StatusCode)
	}
	resp.Body.Close()

	// 删除不存在 → 404（已有 TestConfigBlacklistCRUD 测过但防回归）
	req, _ := http.NewRequest("DELETE", srv.URL+"/config/blacklist/12345", nil)
	resp, _ = http.DefaultClient.Do(req)
	if resp.StatusCode != 404 {
		t.Errorf("delete not-found want 404, got %d", resp.StatusCode)
	}
	resp.Body.Close()
}

func TestConfigRulesGet(t *testing.T) {
	handler := setupTestServer(t, "", 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp, _ := http.Get(srv.URL + "/config/rules")
	if resp.StatusCode != 200 {
		t.Fatalf("want 200, got %d", resp.StatusCode)
	}
	var rules map[string]interface{}
	json.NewDecoder(resp.Body).Decode(&rules)
	resp.Body.Close()

	if _, ok := rules["red"]; !ok {
		t.Error("rules should have 'red' key")
	}
	if _, ok := rules["green"]; !ok {
		t.Error("rules should have 'green' key")
	}
}

func TestConfigRulesUpdate(t *testing.T) {
	handler := setupTestServer(t, "", 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// 更新规则（添加自定义 red 规则）
	newRules := `{"red":[{"pattern":"^custom-halt$","description":"custom halt"}]}`
	req, _ := http.NewRequest("PUT", srv.URL+"/config/rules", strings.NewReader(newRules))
	req.Header.Set("Content-Type", "application/json")
	resp, _ := http.DefaultClient.Do(req)
	if resp.StatusCode != 200 {
		t.Fatalf("PUT rules want 200, got %d", resp.StatusCode)
	}
	var rules struct {
		Red []struct {
			Pattern string `json:"pattern"`
		} `json:"red"`
	}
	json.NewDecoder(resp.Body).Decode(&rules)
	resp.Body.Close()
	if len(rules.Red) != 1 || rules.Red[0].Pattern != "^custom-halt$" {
		t.Errorf("want 1 custom red rule, got %d", len(rules.Red))
	}
}

func TestConfigRulesUpdateBadJSON(t *testing.T) {
	handler := setupTestServer(t, "", 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	req, _ := http.NewRequest("PUT", srv.URL+"/config/rules", strings.NewReader("not json"))
	req.Header.Set("Content-Type", "application/json")
	resp, _ := http.DefaultClient.Do(req)
	if resp.StatusCode != 400 {
		t.Errorf("bad JSON want 400, got %d", resp.StatusCode)
	}
	resp.Body.Close()
}

func TestHistoryEmpty(t *testing.T) {
	handler := setupTestServer(t, "", 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp, _ := http.Get(srv.URL + "/approvals/history")
	var hr struct {
		Total int           `json:"total"`
		Items []interface{} `json:"items"`
	}
	json.NewDecoder(resp.Body).Decode(&hr)
	resp.Body.Close()
	if hr.Total != 0 || len(hr.Items) != 0 {
		t.Errorf("want 0, got total=%d", hr.Total)
	}
}

func TestDetailNotFound(t *testing.T) {
	handler := setupTestServer(t, "", 300)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp, _ := http.Get(srv.URL + "/approvals/nonexistent")
	if resp.StatusCode != 404 {
		t.Errorf("want 404, got %d", resp.StatusCode)
	}
	resp.Body.Close()
}
