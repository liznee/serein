package api

import (
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"

	"serein/internal/session"
)

// ──────────────────────────────────────────────────────────────────────
// 双向实时传输回归测试
//
// 测试覆盖:
//   1. Phone → Terminal: session_msg 内容完整性 + 多消息序列
//   2. Terminal → Phone: cmd_step / cmd_result 回传
//   3. Phone 发 cmd_step/cmd_result 被拒绝（防伪造终端输出注入）
//   4. 完整双向往返: phone→terminal→phone 全链路
//   5. 流式 cmd_step: 多条连续输出
//   6. 权限控制流: perm_decision phone→terminal
//   7. 模式切换: mode_switch 值正确转发 + 多次切换
//   8. 跨 session 隔离: 消息不泄漏
//   9. session_msg 速率限制
//  10. pending 缓冲区: FIFO 上限 + 跨项目隔离
//  11. 多手机同 session
//  12. Agent 客户端也可发送 cmd_step/cmd_result
// ──────────────────────────────────────────────────────────────────────

// joinPhoneAndTerminal sets up a phone and terminal in the same session/project.
// Returns (phone, terminal, sessionID). Both clients have their join messages drained.
func joinPhoneAndTerminal(t *testing.T, hub *wsHub, project string) (*wsClient, *wsClient, string) {
	t.Helper()
	repo := setupTestDeviceRepo(t)
	dev := pairDevice(t, repo, "phone-"+project)
	hub.SetDeviceRepo(repo)

	phone := newTestWSClient()
	phoneJoin := session.JoinMessage{
		ClientType: "phone",
		ClientID:   "phone-" + project,
		Project:    project,
		Token:      dev.ClientToken,
	}
	hub.handleJoin(phone, mustMarshal(t, phoneJoin))
	recvAll(t, phone, 5) // join_ack + maybe history

	terminal := newTestWSClient()
	termJoin := session.JoinMessage{
		ClientType: "terminal",
		ClientID:   "relay-" + project,
		Project:    project,
		Token:      "hook-secret",
	}
	hub.handleJoin(terminal, mustMarshal(t, termJoin))
	recvAll(t, terminal, 5) // join_ack + maybe history

	if phone.sessionID != terminal.sessionID {
		t.Fatalf("phone and terminal should be in the same session: phone=%s terminal=%s",
			phone.sessionID, terminal.sessionID)
	}
	return phone, terminal, phone.sessionID
}

// makeSessionMsg creates a raw JSON session_msg envelope for testing.
func makeSessionMsg(sessionID, content string) []byte {
	env := session.WSEnvelope{
		Type:      session.MsgTypeSessionMsg,
		SessionID: sessionID,
		Payload: map[string]interface{}{
			"content": content,
			"project": "test-proj",
		},
	}
	b, _ := json.Marshal(env)
	return b
}

// makeCmdStepMsg creates a raw JSON cmd_step envelope for testing.
func makeCmdStepMsg(sessionID, cmdID, event, content string) []byte {
	env := session.WSEnvelope{
		Type:      session.MsgTypeCmdStep,
		SessionID: sessionID,
		Source:    "terminal",
		Payload: map[string]interface{}{
			"cmd_id":  cmdID,
			"event":   event,
			"content": content,
		},
	}
	b, _ := json.Marshal(env)
	return b
}

// makeCmdResultMsg creates a raw JSON cmd_result envelope for testing.
func makeCmdResultMsg(sessionID, cmdID, output string) []byte {
	env := session.WSEnvelope{
		Type:      session.MsgTypeCmdResult,
		SessionID: sessionID,
		Source:    "terminal",
		Payload: map[string]interface{}{
			"cmd_id":      cmdID,
			"output":      output,
			"exit_code":   0,
			"duration_ms": 150,
		},
	}
	b, _ := json.Marshal(env)
	return b
}

// extractPayloadField extracts a field from a WSEnvelope payload.
func extractPayloadField(t *testing.T, raw []byte, field string) interface{} {
	t.Helper()
	var env session.WSEnvelope
	mustUnmarshal(t, raw, &env)
	payload, ok := env.Payload.(map[string]interface{})
	if !ok {
		t.Fatalf("payload is not a map: %T", env.Payload)
	}
	return payload[field]
}

// ── 1. Phone → Terminal: session_msg 内容完整性 ──

func TestBidirectional_PhoneToTerminal_ContentIntegrity(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "content-test")

	// Phone sends a message with specific content
	testContent := "你好世界 hello world 123"
	hub.handleMessage(phone, makeSessionMsg(sid, testContent))

	// Terminal should receive the message with exact content
	msg := recvOne(t, terminal)
	if msg == nil {
		t.Fatal("terminal should have received session_msg from phone")
	}
	var env session.WSEnvelope
	mustUnmarshal(t, msg, &env)
	if env.Type != session.MsgTypeSessionMsg {
		t.Errorf("type = %s, want session_msg", env.Type)
	}
	content := extractPayloadField(t, msg, "content")
	if content != testContent {
		t.Errorf("content = %v, want %q", content, testContent)
	}
}

func TestBidirectional_PhoneToTerminal_MultipleMessages(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "multi-msg")

	// Send 3 messages sequentially with rate limit awareness (200ms between messages)
	messages := []string{"msg-1", "msg-2", "msg-3"}
	for _, m := range messages {
		hub.handleMessage(phone, makeSessionMsg(sid, m))
		time.Sleep(250 * time.Millisecond) // respect rate limit
	}

	// Terminal should receive all 3 messages in order
	for i, expected := range messages {
		msg := recvOne(t, terminal)
		if msg == nil {
			t.Fatalf("terminal should have received message %d (%q)", i+1, expected)
		}
		content := extractPayloadField(t, msg, "content")
		if content != expected {
			t.Errorf("message %d: content = %v, want %q", i+1, content, expected)
		}
	}
}

// ── 2. Terminal → Phone: cmd_step 回传 ──

func TestBidirectional_TerminalToPhone_CmdStep(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "cmdstep-test")

	// Terminal sends cmd_step
	cmdID := "cmd-001"
	event := "text"
	content := "Processing your request..."
	hub.handleMessage(terminal, makeCmdStepMsg(sid, cmdID, event, content))

	// Phone should receive the cmd_step
	msg := recvOne(t, phone)
	if msg == nil {
		t.Fatal("phone should have received cmd_step from terminal")
	}
	var env session.WSEnvelope
	mustUnmarshal(t, msg, &env)
	if env.Type != session.MsgTypeCmdStep {
		t.Errorf("type = %s, want cmd_step", env.Type)
	}
	if got := extractPayloadField(t, msg, "cmd_id"); got != cmdID {
		t.Errorf("cmd_id = %v, want %q", got, cmdID)
	}
	if got := extractPayloadField(t, msg, "content"); got != content {
		t.Errorf("content = %v, want %q", got, content)
	}
}

// ── 2b. Terminal → Phone: cmd_result 回传 ──

func TestBidirectional_TerminalToPhone_CmdResult(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "cmdresult-test")

	// Terminal sends cmd_result
	cmdID := "cmd-002"
	output := `{"status":"success","result":"done"}`
	hub.handleMessage(terminal, makeCmdResultMsg(sid, cmdID, output))

	// Phone should receive the cmd_result
	msg := recvOne(t, phone)
	if msg == nil {
		t.Fatal("phone should have received cmd_result from terminal")
	}
	var env session.WSEnvelope
	mustUnmarshal(t, msg, &env)
	if env.Type != session.MsgTypeCmdResult {
		t.Errorf("type = %s, want cmd_result", env.Type)
	}
	if got := extractPayloadField(t, msg, "cmd_id"); got != cmdID {
		t.Errorf("cmd_id = %v, want %q", got, cmdID)
	}
	if got := extractPayloadField(t, msg, "output"); got != output {
		t.Errorf("output = %v, want %q", got, output)
	}
}

// ── 3. Phone 发 cmd_step/cmd_result 被拒绝 ──

func TestBidirectional_CmdStepFromPhoneRejected(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "reject-cmdstep")

	// Phone tries to send cmd_step — should be silently rejected
	hub.handleMessage(phone, makeCmdStepMsg(sid, "fake-cmd", "text", "forged output"))

	// Terminal should NOT receive anything
	msg := recvOne(t, terminal)
	if msg != nil {
		var env session.WSEnvelope
		mustUnmarshal(t, msg, &env)
		t.Errorf("phone should not be able to inject cmd_step, but terminal received: %s", env.Type)
	}
}

func TestBidirectional_CmdResultFromPhoneRejected(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "reject-cmdresult")

	// Phone tries to send cmd_result — should be silently rejected
	hub.handleMessage(phone, makeCmdResultMsg(sid, "fake-cmd", "forged result"))

	// Terminal should NOT receive anything
	msg := recvOne(t, terminal)
	if msg != nil {
		var env session.WSEnvelope
		mustUnmarshal(t, msg, &env)
		t.Errorf("phone should not be able to inject cmd_result, but terminal received: %s", env.Type)
	}
}

// ── 4. 完整双向往返: phone→terminal→phone ──

func TestBidirectional_FullRoundTrip(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "roundtrip")

	// Step 1: Phone sends a session message
	userInput := "请帮我查看当前目录"
	hub.handleMessage(phone, makeSessionMsg(sid, userInput))

	// Terminal receives the phone's message
	termMsg := recvOne(t, terminal)
	if termMsg == nil {
		t.Fatal("terminal should receive phone's session_msg")
	}
	content := extractPayloadField(t, termMsg, "content")
	if content != userInput {
		t.Errorf("terminal received content = %v, want %q", content, userInput)
	}

	// Step 2: Terminal sends cmd_step (processing output)
	hub.handleMessage(terminal, makeCmdStepMsg(sid, "cmd-rt-1", "text", "正在执行 ls -la..."))

	// Phone receives the cmd_step
	phoneMsg1 := recvOne(t, phone)
	if phoneMsg1 == nil {
		t.Fatal("phone should receive cmd_step from terminal")
	}
	if got := extractPayloadField(t, phoneMsg1, "content"); got != "正在执行 ls -la..." {
		t.Errorf("phone cmd_step content = %v, want '正在执行 ls -la...'", got)
	}

	// Step 3: Terminal sends another cmd_step (more output)
	hub.handleMessage(terminal, makeCmdStepMsg(sid, "cmd-rt-1", "text", "total 42\ndrwxr-xr-x 5 user user 4096 Jul 6 10:00 ."))

	// Phone receives the second cmd_step
	phoneMsg2 := recvOne(t, phone)
	if phoneMsg2 == nil {
		t.Fatal("phone should receive second cmd_step from terminal")
	}

	// Step 4: Terminal sends cmd_result (final result)
	hub.handleMessage(terminal, makeCmdResultMsg(sid, "cmd-rt-1", `{"exit_code":0,"output":"done"}`))

	// Phone receives the cmd_result
	phoneMsg3 := recvOne(t, phone)
	if phoneMsg3 == nil {
		t.Fatal("phone should receive cmd_result from terminal")
	}
	var resultEnv session.WSEnvelope
	mustUnmarshal(t, phoneMsg3, &resultEnv)
	if resultEnv.Type != session.MsgTypeCmdResult {
		t.Errorf("final message type = %s, want cmd_result", resultEnv.Type)
	}
}

// ── 5. 流式 cmd_step: 多条连续输出 ──

func TestBidirectional_StreamingCmdSteps(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "streaming")

	// Terminal sends 5 consecutive cmd_step messages (simulating streaming output)
	lines := []string{
		"Line 1: Starting build...",
		"Line 2: Compiling main.go",
		"Line 3: Compiling utils.go",
		"Line 4: Linking binary...",
		"Line 5: Build complete!",
	}
	cmdID := "cmd-stream-001"
	for _, line := range lines {
		hub.handleMessage(terminal, makeCmdStepMsg(sid, cmdID, "text", line))
	}

	// Phone should receive all 5 messages in order
	for i, expected := range lines {
		msg := recvOne(t, phone)
		if msg == nil {
			t.Fatalf("phone should receive cmd_step %d/%d", i+1, len(lines))
		}
		var env session.WSEnvelope
		mustUnmarshal(t, msg, &env)
		if env.Type != session.MsgTypeCmdStep {
			t.Errorf("message %d: type = %s, want cmd_step", i+1, env.Type)
		}
		if got := extractPayloadField(t, msg, "content"); got != expected {
			t.Errorf("message %d: content = %v, want %q", i+1, got, expected)
		}
		if got := extractPayloadField(t, msg, "cmd_id"); got != cmdID {
			t.Errorf("message %d: cmd_id = %v, want %q", i+1, got, cmdID)
		}
	}
}

// ── 6. 权限控制流: perm_decision phone→terminal ──

func TestBidirectional_PermDecision_PhoneToTerminal(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "permdec")

	// Phone sends perm_decision: allow
	allowEnv := session.WSEnvelope{
		Type:      session.MsgTypePermDecision,
		SessionID: sid,
		Payload: session.PermDecisionPayload{
			CmdID:    "cmd-perm-001",
			Decision: "allow",
			Reason:   "approved by user",
		},
	}
	hub.handleMessage(phone, mustMarshal(t, allowEnv))

	// Terminal should receive the perm_decision
	msg := recvOne(t, terminal)
	if msg == nil {
		t.Fatal("terminal should receive perm_decision from phone")
	}
	var env session.WSEnvelope
	mustUnmarshal(t, msg, &env)
	if env.Type != session.MsgTypePermDecision {
		t.Errorf("type = %s, want perm_decision", env.Type)
	}
	if got := extractPayloadField(t, msg, "cmd_id"); got != "cmd-perm-001" {
		t.Errorf("cmd_id = %v, want cmd-perm-001", got)
	}
	if got := extractPayloadField(t, msg, "decision"); got != "allow" {
		t.Errorf("decision = %v, want allow", got)
	}
}

func TestBidirectional_PermDecision_Deny(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "permdec-deny")

	// Phone sends perm_decision: deny
	denyEnv := session.WSEnvelope{
		Type:      session.MsgTypePermDecision,
		SessionID: sid,
		Payload: session.PermDecisionPayload{
			CmdID:    "cmd-perm-002",
			Decision: "deny",
			Reason:   "blocked by user",
		},
	}
	hub.handleMessage(phone, mustMarshal(t, denyEnv))

	// Terminal should receive the deny decision
	msg := recvOne(t, terminal)
	if msg == nil {
		t.Fatal("terminal should receive perm_decision deny from phone")
	}
	if got := extractPayloadField(t, msg, "decision"); got != "deny" {
		t.Errorf("decision = %v, want deny", got)
	}
}

func TestBidirectional_PermDecision_InvalidDecision(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "permdec-invalid")

	// Phone sends perm_decision with invalid decision value
	badEnv := session.WSEnvelope{
		Type:      session.MsgTypePermDecision,
		SessionID: sid,
		Payload: map[string]interface{}{
			"cmd_id":   "cmd-perm-003",
			"decision": "maybe", // invalid
		},
	}
	hub.handleMessage(phone, mustMarshal(t, badEnv))

	// Terminal should NOT receive the invalid decision
	msg := recvOne(t, terminal)
	if msg != nil {
		var env session.WSEnvelope
		mustUnmarshal(t, msg, &env)
		t.Errorf("invalid perm_decision should not be broadcast, but terminal got: %s", env.Type)
	}
}

func TestBidirectional_PermDecision_MissingCmdID(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "permdec-noid")

	// Phone sends perm_decision without cmd_id
	noIDEnv := session.WSEnvelope{
		Type:      session.MsgTypePermDecision,
		SessionID: sid,
		Payload: map[string]interface{}{
			"decision": "allow",
		},
	}
	hub.handleMessage(phone, mustMarshal(t, noIDEnv))

	// Terminal should NOT receive it
	msg := recvOne(t, terminal)
	if msg != nil {
		t.Error("perm_decision without cmd_id should not be broadcast")
	}
}

func TestBidirectional_PermDecision_FromTerminalRejected(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "permdec-term")

	// Terminal tries to send perm_decision — should be rejected
	termEnv := session.WSEnvelope{
		Type:      session.MsgTypePermDecision,
		SessionID: sid,
		Payload: session.PermDecisionPayload{
			CmdID:    "cmd-fake",
			Decision: "allow",
		},
	}
	hub.handleMessage(terminal, mustMarshal(t, termEnv))

	// Phone should NOT receive anything
	msg := recvOne(t, phone)
	if msg != nil {
		var env session.WSEnvelope
		mustUnmarshal(t, msg, &env)
		t.Errorf("terminal should not send perm_decision, but phone got: %s", env.Type)
	}
}

// ── 7. 模式切换: mode_switch 值正确转发 ──

func TestBidirectional_ModeSwitch_ValueForwarded(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "modeswitch")

	tests := []string{
		session.PermModeDefault,
		session.PermModeAcceptEdits,
		session.PermModeBypassPermissions,
		session.PermModePlan,
		session.PermModeReadOnly,
		session.PermModeSafeYolo,
		session.PermModeYolo,
	}

	for _, mode := range tests {
		t.Run(mode, func(t *testing.T) {
			switchEnv := session.WSEnvelope{
				Type:      session.MsgTypeModeSwitch,
				SessionID: sid,
				Payload: session.ModeSwitchPayload{
					Mode: mode,
				},
			}
			hub.handleMessage(phone, mustMarshal(t, switchEnv))

			// Terminal should receive the mode_switch with correct mode value
			msg := recvOne(t, terminal)
			if msg == nil {
				t.Fatalf("terminal should receive mode_switch for mode=%s", mode)
			}
			var env session.WSEnvelope
			mustUnmarshal(t, msg, &env)
			if env.Type != session.MsgTypeModeSwitch {
				t.Errorf("type = %s, want mode_switch", env.Type)
			}
			if got := extractPayloadField(t, msg, "mode"); got != mode {
				t.Errorf("mode = %v, want %q", got, mode)
			}
		})
	}
}

func TestBidirectional_ModeSwitch_FromTerminalRejected(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "modeswitch-rej")

	// Terminal tries to send mode_switch — should be rejected
	switchEnv := session.WSEnvelope{
		Type:      session.MsgTypeModeSwitch,
		SessionID: sid,
		Payload: session.ModeSwitchPayload{
			Mode: session.PermModeYolo,
		},
	}
	hub.handleMessage(terminal, mustMarshal(t, switchEnv))

	// Phone should NOT receive anything
	msg := recvOne(t, phone)
	if msg != nil {
		var env session.WSEnvelope
		mustUnmarshal(t, msg, &env)
		t.Errorf("terminal should not send mode_switch, but phone got: %s", env.Type)
	}
}

func TestBidirectional_ModeSwitch_WithToolFilters(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "modeswitch-tools")

	// Phone sends mode_switch with allowed/disallowed tools
	switchEnv := session.WSEnvelope{
		Type:      session.MsgTypeModeSwitch,
		SessionID: sid,
		Payload: session.ModeSwitchPayload{
			Mode:            session.PermModeDefault,
			AllowedTools:    []string{"Read", "Grep", "Bash"},
			DisallowedTools: []string{"Write", "Edit"},
		},
	}
	hub.handleMessage(phone, mustMarshal(t, switchEnv))

	// Terminal should receive the mode_switch with tool lists
	msg := recvOne(t, terminal)
	if msg == nil {
		t.Fatal("terminal should receive mode_switch with tool filters")
	}
	var env session.WSEnvelope
	mustUnmarshal(t, msg, &env)
	payload, ok := env.Payload.(map[string]interface{})
	if !ok {
		t.Fatal("payload is not a map")
	}
	allowed, ok := payload["allowed_tools"].([]interface{})
	if !ok || len(allowed) != 3 {
		t.Errorf("allowed_tools = %v, want 3 items", payload["allowed_tools"])
	}
	disallowed, ok := payload["disallowed_tools"].([]interface{})
	if !ok || len(disallowed) != 2 {
		t.Errorf("disallowed_tools = %v, want 2 items", payload["disallowed_tools"])
	}
}

// ── 8. 跨 session 隔离 ──

func TestBidirectional_CrossSessionIsolation(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")

	// Session A: phone-A + terminal-A
	phoneA, terminalA, sidA := joinPhoneAndTerminal(t, hub, "session-a")

	// Session B: phone-B + terminal-B (different project = different session)
	phoneB, terminalB, sidB := joinPhoneAndTerminal(t, hub, "session-b")

	if sidA == sidB {
		t.Fatal("sessions A and B should be different")
	}

	// Phone-A sends message — only terminal-A should receive, NOT terminal-B
	hub.handleMessage(phoneA, makeSessionMsg(sidA, "message-for-session-a-only"))

	// Terminal-A receives
	msgA := recvOne(t, terminalA)
	if msgA == nil {
		t.Fatal("terminal-A should receive message from phone-A")
	}
	content := extractPayloadField(t, msgA, "content")
	if content != "message-for-session-a-only" {
		t.Errorf("terminal-A content = %v, want 'message-for-session-a-only'", content)
	}

	// Terminal-B should NOT receive session-A's message
	msgB := recvOne(t, terminalB)
	if msgB != nil {
		var env session.WSEnvelope
		mustUnmarshal(t, msgB, &env)
		// broadcastToAllTerminals may deliver cross-session if same project,
		// but session-a and session-b have different projects, so no delivery.
		if env.Type == session.MsgTypeSessionMsg {
			t.Error("terminal-B (different project) should NOT receive session-A's message")
		}
	}

	// Phone-B should also NOT receive session-A's message
	msgPhoneB := recvOne(t, phoneB)
	if msgPhoneB != nil {
		var env session.WSEnvelope
		mustUnmarshal(t, msgPhoneB, &env)
		if env.Type == session.MsgTypeSessionMsg {
			t.Error("phone-B should NOT receive session-A's session_msg")
		}
	}

	// Now terminal-A sends cmd_step — only phone-A should receive, NOT phone-B
	hub.handleMessage(terminalA, makeCmdStepMsg(sidA, "cmd-iso", "text", "output-for-session-a"))

	// Phone-A receives
	msgPhoneA := recvOne(t, phoneA)
	if msgPhoneA == nil {
		t.Fatal("phone-A should receive cmd_step from terminal-A")
	}
	if got := extractPayloadField(t, msgPhoneA, "content"); got != "output-for-session-a" {
		t.Errorf("phone-A content = %v, want 'output-for-session-a'", got)
	}

	// Phone-B should NOT receive terminal-A's cmd_step
	msgPhoneB2 := recvOne(t, phoneB)
	if msgPhoneB2 != nil {
		var env session.WSEnvelope
		mustUnmarshal(t, msgPhoneB2, &env)
		if env.Type == session.MsgTypeCmdStep {
			t.Error("phone-B should NOT receive cmd_step from terminal-A (different session)")
		}
	}
}

// ── 9. session_msg 速率限制 ──

func TestBidirectional_SessionMsgRateLimit(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "ratelimit")

	// Send first message — should be allowed
	hub.handleMessage(phone, makeSessionMsg(sid, "msg-1"))
	msg1 := recvOne(t, terminal)
	if msg1 == nil {
		t.Fatal("first message should be delivered (within rate limit)")
	}

	// Immediately send second message — should be rate-limited (dropped)
	hub.handleMessage(phone, makeSessionMsg(sid, "msg-2-ratelimited"))
	msg2 := recvOne(t, terminal)
	if msg2 != nil {
		var env session.WSEnvelope
		mustUnmarshal(t, msg2, &env)
		content := extractPayloadField(t, msg2, "content")
		if content == "msg-2-ratelimited" {
			t.Error("second message should be rate-limited and not delivered")
		}
	}

	// Wait for rate limit window to pass (200ms + buffer)
	time.Sleep(300 * time.Millisecond)

	// Send third message — should be allowed again
	hub.handleMessage(phone, makeSessionMsg(sid, "msg-3-after-wait"))
	msg3 := recvOne(t, terminal)
	if msg3 == nil {
		t.Fatal("third message should be delivered after rate limit window")
	}
	content3 := extractPayloadField(t, msg3, "content")
	if content3 != "msg-3-after-wait" {
		t.Errorf("third message content = %v, want 'msg-3-after-wait'", content3)
	}
}

// ── 10. pending 缓冲区: FIFO 上限 ──

func TestBidirectional_PendingBuffer_LimitAndFIFO(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")

	// Buffer 55 messages (exceeds max of 50, oldest 5 should be dropped)
	for i := 0; i < 55; i++ {
		hub.broadcastToAllTerminals(
			session.MsgTypeSessionMsg,
			map[string]interface{}{"content": "pending-msg", "index": i},
			"", "", "fifo-test-proj",
		)
	}

	// Check buffer length
	hub.mu.RLock()
	bufLen := len(hub.relayPendingMsgs)
	hub.mu.RUnlock()
	if bufLen != relayPendingMsgsMax {
		t.Errorf("pending buffer length = %d, want %d (FIFO should cap at max)", bufLen, relayPendingMsgsMax)
	}

	// Relay joins — should receive join_ack + 50 pending messages
	relay := newTestWSClient()
	relayJoin := session.JoinMessage{
		ClientType: "terminal",
		ClientID:   "relay-fifo-test",
		Project:    "fifo-test-proj",
		Token:      "hook-secret",
	}
	hub.handleJoin(relay, mustMarshal(t, relayJoin))

	// Collect all messages
	msgs := recvAll(t, relay, 60)

	// First message should be join_ack
	if len(msgs) == 0 {
		t.Fatal("relay should receive at least join_ack")
	}
	var first session.WSEnvelope
	mustUnmarshal(t, msgs[0], &first)
	if first.Type != session.MsgTypeJoinAck {
		t.Errorf("first message should be join_ack, got %s", first.Type)
	}

	// Count session_msg messages (pending messages)
	pendingCount := 0
	for _, m := range msgs[1:] {
		var env session.WSEnvelope
		mustUnmarshal(t, m, &env)
		if env.Type == session.MsgTypeSessionMsg {
			pendingCount++
		}
	}
	if pendingCount != relayPendingMsgsMax {
		t.Errorf("pending messages received = %d, want %d", pendingCount, relayPendingMsgsMax)
	}
}

func TestBidirectional_PendingBuffer_CrossProjectIsolation(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")

	// Buffer messages for two different projects
	hub.broadcastToAllTerminals(
		session.MsgTypeSessionMsg,
		map[string]interface{}{"content": "proj-a-msg"},
		"", "", "proj-x",
	)
	hub.broadcastToAllTerminals(
		session.MsgTypeSessionMsg,
		map[string]interface{}{"content": "proj-b-msg"},
		"", "", "proj-y",
	)

	// Relay for proj-x joins — should only get proj-x messages
	relayX := newTestWSClient()
	relayXJoin := session.JoinMessage{
		ClientType: "terminal",
		ClientID:   "relay-proj-x",
		Project:    "proj-x",
		Token:      "hook-secret",
	}
	hub.handleJoin(relayX, mustMarshal(t, relayXJoin))

	msgs := recvAll(t, relayX, 10)
	for _, m := range msgs {
		var env session.WSEnvelope
		mustUnmarshal(t, m, &env)
		if env.Type == session.MsgTypeSessionMsg {
			payload, ok := env.Payload.(map[string]interface{})
			if !ok {
				continue
			}
			content, _ := payload["content"].(string)
			if content == "proj-b-msg" {
				t.Error("relay for proj-x should NOT receive proj-y's pending message")
			}
		}
	}

	// Relay for proj-y joins — should only get proj-y messages
	relayY := newTestWSClient()
	relayYJoin := session.JoinMessage{
		ClientType: "terminal",
		ClientID:   "relay-proj-y",
		Project:    "proj-y",
		Token:      "hook-secret",
	}
	hub.handleJoin(relayY, mustMarshal(t, relayYJoin))

	msgsY := recvAll(t, relayY, 10)
	foundProjYMsg := false
	for _, m := range msgsY {
		var env session.WSEnvelope
		mustUnmarshal(t, m, &env)
		if env.Type == session.MsgTypeSessionMsg {
			payload, ok := env.Payload.(map[string]interface{})
			if !ok {
				continue
			}
			content, _ := payload["content"].(string)
			if content == "proj-b-msg" {
				foundProjYMsg = true
			}
			if content == "proj-a-msg" {
				t.Error("relay for proj-y should NOT receive proj-x's pending message")
			}
		}
	}
	if !foundProjYMsg {
		t.Error("relay for proj-y should receive its own proj-y pending message")
	}
}

// ── 11. 多手机同 session ──

func TestBidirectional_MultiplePhonesInSession(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	repo := setupTestDeviceRepo(t)
	dev1 := pairDevice(t, repo, "phone-multi-1")
	dev2 := logicalTestDevice(dev1)
	hub.SetDeviceRepo(repo)

	// Phone 1 joins
	phone1 := newTestWSClient()
	phone1Join := session.JoinMessage{
		ClientType: "phone",
		ClientID:   "phone-multi-1",
		Project:    "multi-phone-proj",
		Token:      dev1.ClientToken,
	}
	hub.handleJoin(phone1, mustMarshal(t, phone1Join))
	recvAll(t, phone1, 5)

	// Phone 2 joins same project
	phone2 := newTestWSClient()
	phone2Join := session.JoinMessage{
		ClientType: "phone",
		ClientID:   "phone-multi-2",
		Project:    "multi-phone-proj",
		Token:      dev2.ClientToken,
	}
	hub.handleJoin(phone2, mustMarshal(t, phone2Join))
	recvAll(t, phone2, 5)

	// Terminal joins same project
	terminal := newTestWSClient()
	termJoin := session.JoinMessage{
		ClientType: "terminal",
		ClientID:   "relay-multi-phone",
		Project:    "multi-phone-proj",
		Token:      "hook-secret",
	}
	hub.handleJoin(terminal, mustMarshal(t, termJoin))
	recvAll(t, terminal, 5)

	sid := phone1.sessionID

	// Phone 1 sends message — terminal AND phone 2 should receive (broadcastToSession excludes sender only)
	hub.handleMessage(phone1, makeSessionMsg(sid, "from-phone-1"))

	// Terminal receives
	termMsg := recvOne(t, terminal)
	if termMsg == nil {
		t.Fatal("terminal should receive message from phone-1")
	}

	// Phone 2 receives (it's in the same session)
	phone2Msg := recvOne(t, phone2)
	if phone2Msg == nil {
		t.Fatal("phone-2 should receive message from phone-1 (same session)")
	}
	content := extractPayloadField(t, phone2Msg, "content")
	if content != "from-phone-1" {
		t.Errorf("phone-2 content = %v, want 'from-phone-1'", content)
	}

	// Phone 1 should NOT receive its own message
	phone1Msg := recvOne(t, phone1)
	if phone1Msg != nil {
		var env session.WSEnvelope
		mustUnmarshal(t, phone1Msg, &env)
		if env.Type == session.MsgTypeSessionMsg {
			t.Error("phone-1 should NOT receive its own session_msg")
		}
	}

	// Terminal sends cmd_step — both phones should receive
	hub.handleMessage(terminal, makeCmdStepMsg(sid, "cmd-multi", "text", "output-for-both-phones"))

	// Phone 1 receives
	msg1 := recvOne(t, phone1)
	if msg1 == nil {
		t.Fatal("phone-1 should receive cmd_step from terminal")
	}

	// Phone 2 receives
	msg2 := recvOne(t, phone2)
	if msg2 == nil {
		t.Fatal("phone-2 should receive cmd_step from terminal")
	}
}

// ── 12. Agent 客户端也可发送 cmd_step/cmd_result ──

func TestBidirectional_AgentCanSendCmdStep(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	repo := setupTestDeviceRepo(t)
	dev := pairDevice(t, repo, "phone-agent-test")
	hub.SetDeviceRepo(repo)

	// Phone joins
	phone := newTestWSClient()
	phoneJoin := session.JoinMessage{
		ClientType: "phone",
		ClientID:   "phone-agent-test",
		Project:    "agent-proj",
		Token:      dev.ClientToken,
	}
	hub.handleJoin(phone, mustMarshal(t, phoneJoin))
	recvAll(t, phone, 5)

	// Agent joins same project
	agent := newTestWSClient()
	agentJoin := session.JoinMessage{
		ClientType: "agent",
		ClientID:   "agent-001",
		Project:    "agent-proj",
		Token:      "hook-secret",
	}
	hub.handleJoin(agent, mustMarshal(t, agentJoin))
	recvAll(t, agent, 5)

	sid := phone.sessionID

	// Agent sends cmd_step — phone should receive
	hub.handleMessage(agent, makeCmdStepMsg(sid, "cmd-agent-1", "text", "agent output"))

	msg := recvOne(t, phone)
	if msg == nil {
		t.Fatal("phone should receive cmd_step from agent")
	}
	var env session.WSEnvelope
	mustUnmarshal(t, msg, &env)
	if env.Type != session.MsgTypeCmdStep {
		t.Errorf("type = %s, want cmd_step", env.Type)
	}
	if got := extractPayloadField(t, msg, "content"); got != "agent output" {
		t.Errorf("content = %v, want 'agent output'", got)
	}
}

func TestBidirectional_AgentCanSendCmdResult(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	repo := setupTestDeviceRepo(t)
	dev := pairDevice(t, repo, "phone-agent-result")
	hub.SetDeviceRepo(repo)

	phone := newTestWSClient()
	phoneJoin := session.JoinMessage{
		ClientType: "phone",
		ClientID:   "phone-agent-result",
		Project:    "agent-result-proj",
		Token:      dev.ClientToken,
	}
	hub.handleJoin(phone, mustMarshal(t, phoneJoin))
	recvAll(t, phone, 5)

	agentClient := newTestWSClient()
	agentJoin := session.JoinMessage{
		ClientType: "agent",
		ClientID:   "agent-result-001",
		Project:    "agent-result-proj",
		Token:      "hook-secret",
	}
	hub.handleJoin(agentClient, mustMarshal(t, agentJoin))
	recvAll(t, agentClient, 5)

	sid := phone.sessionID

	// Agent sends cmd_result — phone should receive
	hub.handleMessage(agentClient, makeCmdResultMsg(sid, "cmd-agent-result", "agent final output"))

	msg := recvOne(t, phone)
	if msg == nil {
		t.Fatal("phone should receive cmd_result from agent")
	}
	var env session.WSEnvelope
	mustUnmarshal(t, msg, &env)
	if env.Type != session.MsgTypeCmdResult {
		t.Errorf("type = %s, want cmd_result", env.Type)
	}
}

// ── 13. Phone 不收到自己发出的 session_msg ──

func TestBidirectional_PhoneDoesNotReceiveOwnMessage(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, _, sid := joinPhoneAndTerminal(t, hub, "self-echo")

	hub.handleMessage(phone, makeSessionMsg(sid, "my-own-message"))

	// Phone should NOT receive its own message via broadcastToSession
	msg := recvOne(t, phone)
	if msg != nil {
		var env session.WSEnvelope
		mustUnmarshal(t, msg, &env)
		if env.Type == session.MsgTypeSessionMsg {
			t.Error("phone should NOT receive its own session_msg (sender excluded)")
		}
	}
}

// ── 14. Terminal 不收到自己发出的 cmd_step/cmd_result ──

func TestBidirectional_TerminalDoesNotReceiveOwnCmdStep(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	_, terminal, sid := joinPhoneAndTerminal(t, hub, "self-cmdstep")

	hub.handleMessage(terminal, makeCmdStepMsg(sid, "cmd-self", "text", "my own output"))

	// Terminal should NOT receive its own cmd_step
	msg := recvOne(t, terminal)
	if msg != nil {
		var env session.WSEnvelope
		mustUnmarshal(t, msg, &env)
		if env.Type == session.MsgTypeCmdStep {
			t.Error("terminal should NOT receive its own cmd_step (sender excluded)")
		}
	}
}

// ── 15. 并发双向传输安全测试 ──

func TestBidirectional_ConcurrentBidirectional(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "concurrent-bidir")

	const N = 20
	var wg sync.WaitGroup

	// Goroutine 1: Phone sends N session messages (with rate limit respect)
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < N; i++ {
			hub.handleMessage(phone, makeSessionMsg(sid, "phone-msg"))
			time.Sleep(250 * time.Millisecond) // respect rate limit
		}
	}()

	// Goroutine 2: Terminal sends N cmd_step messages
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < N; i++ {
			hub.handleMessage(terminal, makeCmdStepMsg(sid, "cmd-concurrent", "text", "terminal-output"))
		}
	}()

	wg.Wait()

	// Drain all messages from both clients (should not deadlock or panic)
	recvAll(t, phone, N+10)
	recvAll(t, terminal, N+10)
	// Test passes if no panic/deadlock occurred
}

// ── 16. Session_msg 入 CmdQueue 安全网验证 ──

func TestBidirectional_SessionMsgEnqueuedToCmdQueue(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, _, sid := joinPhoneAndTerminal(t, hub, "cmdqueue-test")

	initialPending := hub.relay.CmdQueue.PendingCount()

	hub.handleMessage(phone, makeSessionMsg(sid, "enqueue-test-message"))

	// CmdQueue should have one more pending command
	finalPending := hub.relay.CmdQueue.PendingCount()
	if finalPending != initialPending+1 {
		t.Errorf("CmdQueue pending: before=%d after=%d, expected +1", initialPending, finalPending)
	}
}

// ── 17. 不同 event 类型的 cmd_step ──

func TestBidirectional_CmdStep_DifferentEventTypes(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "events")

	events := []string{
		session.EventText,
		session.EventToolCallStart,
		session.EventToolCallEnd,
		session.EventTurnStart,
		session.EventTurnEnd,
		session.EventService,
	}

	for _, event := range events {
		t.Run(event, func(t *testing.T) {
			hub.handleMessage(terminal, makeCmdStepMsg(sid, "cmd-events", event, "content-for-"+event))

			msg := recvOne(t, phone)
			if msg == nil {
				t.Fatalf("phone should receive cmd_step with event=%s", event)
			}
			if got := extractPayloadField(t, msg, "event"); got != event {
				t.Errorf("event = %v, want %q", got, event)
			}
		})
	}
}

// ── 18. JSON 特殊字符在双向传输中的完整性 ──

func TestBidirectional_SpecialCharactersPreserved(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "special-chars")

	tests := []string{
		"包含中文和emoji 🎉🚀",
		"JSON: {\"key\":\"value\",\"arr\":[1,2,3]}",
		"Newlines:\nline2\nline3",
		"Tabs:\tcol1\tcol2",
		"Quotes: \"hello\" 'world'",
		"Backslash: C:\\Users\\test",
	}

	for _, tc := range tests {
		t.Run(tc[:min(20, len(tc))], func(t *testing.T) {
			// Phone sends
			hub.handleMessage(phone, makeSessionMsg(sid, tc))
			time.Sleep(250 * time.Millisecond) // rate limit

			// Terminal receives with exact content
			msg := recvOne(t, terminal)
			if msg == nil {
				t.Fatal("terminal should receive message")
			}
			content := extractPayloadField(t, msg, "content")
			if content != tc {
				t.Errorf("content mismatch:\n  got:  %v\n  want: %q", content, tc)
			}
		})
	}
}

// ── 19. Perm_decision 在多客户端 session 中广播给所有非发送者 ──

func TestBidirectional_PermDecision_BroadcastToAllTerminals(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	repo := setupTestDeviceRepo(t)
	dev := pairDevice(t, repo, "phone-broadcast")
	hub.SetDeviceRepo(repo)

	// Set up 1 phone + 2 terminals in same session
	phone := newTestWSClient()
	phoneJoin := session.JoinMessage{
		ClientType: "phone",
		ClientID:   "phone-broadcast",
		Project:    "broadcast-proj",
		Token:      dev.ClientToken,
	}
	hub.handleJoin(phone, mustMarshal(t, phoneJoin))
	recvAll(t, phone, 5)

	terminal1 := newTestWSClient()
	term1Join := session.JoinMessage{
		ClientType: "terminal",
		ClientID:   "relay-broadcast-1",
		Project:    "broadcast-proj",
		Token:      "hook-secret",
	}
	hub.handleJoin(terminal1, mustMarshal(t, term1Join))
	recvAll(t, terminal1, 5)

	terminal2 := newTestWSClient()
	term2Join := session.JoinMessage{
		ClientType: "terminal",
		ClientID:   "relay-broadcast-2",
		Project:    "broadcast-proj",
		Token:      "hook-secret",
	}
	hub.handleJoin(terminal2, mustMarshal(t, term2Join))
	recvAll(t, terminal2, 5)

	sid := phone.sessionID

	// Phone sends perm_decision
	permEnv := session.WSEnvelope{
		Type:      session.MsgTypePermDecision,
		SessionID: sid,
		Payload: session.PermDecisionPayload{
			CmdID:    "cmd-broadcast-perm",
			Decision: "allow",
		},
	}
	hub.handleMessage(phone, mustMarshal(t, permEnv))

	// Both terminals should receive the perm_decision
	msg1 := recvOne(t, terminal1)
	if msg1 == nil {
		t.Fatal("terminal-1 should receive perm_decision")
	}
	if got := extractPayloadField(t, msg1, "decision"); got != "allow" {
		t.Errorf("terminal-1 decision = %v, want allow", got)
	}

	msg2 := recvOne(t, terminal2)
	if msg2 == nil {
		t.Fatal("terminal-2 should receive perm_decision")
	}
	if got := extractPayloadField(t, msg2, "decision"); got != "allow" {
		t.Errorf("terminal-2 decision = %v, want allow", got)
	}

	// Phone should NOT receive its own perm_decision
	phoneMsg := recvOne(t, phone)
	if phoneMsg != nil {
		var env session.WSEnvelope
		mustUnmarshal(t, phoneMsg, &env)
		if env.Type == session.MsgTypePermDecision {
			t.Error("phone should NOT receive its own perm_decision")
		}
	}
}

// ── 20. 同 project 跨 session 的 relay 广播 ──

func TestBidirectional_CrossSessionRelayBroadcast_SameProject(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")

	// Session 1: phone + relay in proj-cross
	repo := setupTestDeviceRepo(t)
	dev := pairDevice(t, repo, "phone-cross1")
	hub.SetDeviceRepo(repo)

	phone1 := newTestWSClient()
	phone1Join := session.JoinMessage{
		ClientType: "phone",
		ClientID:   "phone-cross-1",
		Project:    "cross-proj",
		Token:      dev.ClientToken,
	}
	hub.handleJoin(phone1, mustMarshal(t, phone1Join))
	recvAll(t, phone1, 5)
	sid1 := phone1.sessionID

	// Session 2: relay in same project but different session
	// Force a different session by using explicit session ID
	relay2 := newTestWSClient()
	relay2Join := session.JoinMessage{
		ClientType: "terminal",
		ClientID:   "relay-cross-2",
		Project:    "cross-proj",
		Token:      "hook-secret",
	}
	hub.handleJoin(relay2, mustMarshal(t, relay2Join))
	recvAll(t, relay2, 5)
	sid2 := relay2.sessionID

	// If same project maps to same session, both are in sid1.
	// broadcastToAllTerminals skips same-session relays (already covered by BroadcastToSession).
	// This test verifies the behavior: relay in same session gets message via BroadcastToSession,
	// relay in different session gets it via broadcastToAllTerminals.
	// Since same project = same session in current implementation, we verify relay2 receives
	// the message via BroadcastToSession (same session).
	if sid1 != sid2 {
		// Different sessions: relay2 should get message via broadcastToAllTerminals
		hub.handleMessage(phone1, makeSessionMsg(sid1, "cross-session-msg"))
		msg := recvOne(t, relay2)
		if msg == nil {
			t.Fatal("relay2 (different session, same project) should receive via broadcastToAllTerminals")
		}
	} else {
		// Same session: relay2 should get message via BroadcastToSession
		hub.handleMessage(phone1, makeSessionMsg(sid1, "same-session-msg"))
		msg := recvOne(t, relay2)
		if msg == nil {
			t.Fatal("relay2 (same session) should receive via BroadcastToSession")
		}
		content := extractPayloadField(t, msg, "content")
		if !strings.Contains(content.(string), "session-msg") {
			t.Errorf("relay2 content = %v, expected 'session-msg'", content)
		}
	}
}

// ── 21. 未知消息类型被忽略 ──

func TestBidirectional_UnknownMessageTypeIgnored(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "unknown-msg")

	// Send a message with unknown type
	unknownEnv := session.WSEnvelope{
		Type:      "unknown_type_xyz",
		SessionID: sid,
		Payload:   map[string]interface{}{"data": "test"},
	}
	hub.handleMessage(phone, mustMarshal(t, unknownEnv))

	// Neither phone nor terminal should receive anything
	phoneMsg := recvOne(t, phone)
	if phoneMsg != nil {
		t.Error("phone should not receive anything for unknown message type")
	}
	termMsg := recvOne(t, terminal)
	if termMsg != nil {
		t.Error("terminal should not receive anything for unknown message type")
	}
}

// ── 22. 完整权限审批往返流程 ──
//
// permission 消息由后端 risk engine 通过 BroadcastToSession 发送给手机，
// 不是 terminal 客户端通过 handleMessage 发送的（handleMessage 没有处理 permission 类型）。
// 此测试模拟完整流程:
//   1. 后端发送 permission 请求 → 手机收到
//   2. 手机发送 perm_decision: allow → terminal 收到
//   3. Terminal 发送 cmd_step → 手机收到
//   4. Terminal 发送 cmd_result → 手机收到

func TestBidirectional_FullPermissionApprovalFlow(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "full-perm-flow")

	// Step 1: Backend (risk engine) sends permission request to phone via BroadcastToSession.
	// permission 消息不经过 handleMessage 分发，而是由后端直接 BroadcastToSession。
	permPayload := session.PermissionPayload{
		ToolName:   "Bash",
		Command:    "rm -rf /tmp/test",
		RiskLevel:  "red",
		RuleReason: "destructive command",
		CmdID:      "cmd-perm-flow-001",
		Timeout:    30,
	}
	hub.BroadcastToSession(sid, session.MsgTypePermission, permPayload, "")

	// Phone should receive the permission request
	permMsg := recvOne(t, phone)
	if permMsg == nil {
		t.Fatal("phone should receive permission request from backend")
	}
	var permEnv session.WSEnvelope
	mustUnmarshal(t, permMsg, &permEnv)
	if permEnv.Type != session.MsgTypePermission {
		t.Errorf("type = %s, want permission", permEnv.Type)
	}
	if got := extractPayloadField(t, permMsg, "tool_name"); got != "Bash" {
		t.Errorf("tool_name = %v, want Bash", got)
	}
	if got := extractPayloadField(t, permMsg, "risk_level"); got != "red" {
		t.Errorf("risk_level = %v, want red", got)
	}
	if got := extractPayloadField(t, permMsg, "cmd_id"); got != "cmd-perm-flow-001" {
		t.Errorf("cmd_id = %v, want cmd-perm-flow-001", got)
	}

	// Terminal should also receive the permission request (BroadcastToSession sends to all)
	// Drain terminal's permission message
	recvOne(t, terminal)

	// Step 2: Phone sends perm_decision: allow
	allowEnv := session.WSEnvelope{
		Type:      session.MsgTypePermDecision,
		SessionID: sid,
		Payload: session.PermDecisionPayload{
			CmdID:    "cmd-perm-flow-001",
			Decision: "allow",
		},
	}
	hub.handleMessage(phone, mustMarshal(t, allowEnv))

	// Terminal should receive the decision
	decMsg := recvOne(t, terminal)
	if decMsg == nil {
		t.Fatal("terminal should receive perm_decision from phone")
	}
	var decEnv session.WSEnvelope
	mustUnmarshal(t, decMsg, &decEnv)
	if decEnv.Type != session.MsgTypePermDecision {
		t.Errorf("type = %s, want perm_decision", decEnv.Type)
	}
	if got := extractPayloadField(t, decMsg, "decision"); got != "allow" {
		t.Errorf("decision = %v, want allow", got)
	}

	// Step 3: Terminal sends cmd_step (executing the approved command)
	hub.handleMessage(terminal, makeCmdStepMsg(sid, "cmd-perm-flow-001", "text", "Executing approved command..."))

	// Phone receives the cmd_step
	stepMsg := recvOne(t, phone)
	if stepMsg == nil {
		t.Fatal("phone should receive cmd_step after approval")
	}

	// Step 4: Terminal sends cmd_result (final result)
	hub.handleMessage(terminal, makeCmdResultMsg(sid, "cmd-perm-flow-001", "Command completed successfully"))

	// Phone receives the cmd_result
	resultMsg := recvOne(t, phone)
	if resultMsg == nil {
		t.Fatal("phone should receive cmd_result after approved command completes")
	}
	var resultEnv session.WSEnvelope
	mustUnmarshal(t, resultMsg, &resultEnv)
	if resultEnv.Type != session.MsgTypeCmdResult {
		t.Errorf("type = %s, want cmd_result", resultEnv.Type)
	}
}
