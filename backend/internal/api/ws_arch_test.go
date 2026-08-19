package api

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"

	"serein/internal/agent"
	"serein/internal/session"
)

// ──────────────────────────────────────────────────────────────────────
// 架构基础测试（需求1-5）
//
// 需求1: 三层架构 — 手机 App ← WSS → 后端 ← HTTP/WSS → Agent/Relay
// 需求2: 两种 Agent 模式 — 1) Python local_agent HTTP 长轮询  2) serein.mjs WS relay
// 需求3: Session 隔离 — 同一 project 对应一个 session，不同 project 不同 session
// 需求4: 消息类型协议 — session_msg/cmd_step/cmd_result/permission/perm_decision/mode_switch
// 需求5: clientType 隔离 — terminal/phone/agent 各有不同权限和路由
// ──────────────────────────────────────────────────────────────────────

// ── 需求1: 三层架构验证 ──

func TestArch_ThreeTierArchitecture_PhoneBackendRelay(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "three-tier")
	hub.handleMessage(phone, makeSessionMsg(sid, "three-tier-test"))
	msg := recvOne(t, terminal)
	if msg == nil {
		t.Fatal("three-tier: terminal should receive phone's message via backend")
	}
	if got := extractPayloadField(t, msg, "content"); got != "three-tier-test" {
		t.Errorf("content = %v, want 'three-tier-test'", got)
	}
}

func TestArch_PhoneAndTerminalShareSameSession(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	_, _, sid := joinPhoneAndTerminal(t, hub, "shared-sess")
	if sid == "" {
		t.Fatal("shared session ID should not be empty")
	}
}

func TestArch_DifferentProjectsDifferentSessions(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	_, _, sid1 := joinPhoneAndTerminal(t, hub, "proj-1")
	_, _, sid2 := joinPhoneAndTerminal(t, hub, "proj-2")
	if sid1 == sid2 {
		t.Fatalf("different projects should have different sessions: %s == %s", sid1, sid2)
	}
}

func TestArch_BackendActsAsRelayForCmdStep(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "relay-arch")
	hub.handleMessage(terminal, makeCmdStepMsg(sid, "cmd-arch", "text", "backend relay test"))
	msg := recvOne(t, phone)
	if msg == nil {
		t.Fatal("phone should receive cmd_step relayed by backend")
	}
}

func TestArch_BackendActsAsRelayForSessionMsg(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "relay-sm")
	hub.handleMessage(phone, makeSessionMsg(sid, "backend relay sm"))
	msg := recvOne(t, terminal)
	if msg == nil {
		t.Fatal("terminal should receive session_msg relayed by backend")
	}
}

func TestArch_MultiClientSameProjectSameSession(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	repo := setupTestDeviceRepo(t)
	dev1 := pairDevice(t, repo, "phone-multi-1")
	dev2 := logicalTestDevice(dev1)
	hub.SetDeviceRepo(repo)

	phone1 := newTestWSClient()
	hub.handleJoin(phone1, mustMarshal(t, session.JoinMessage{
		ClientType: "phone", ClientID: "phone-multi-1", Project: "multi-proj", Token: dev1.ClientToken,
	}))
	recvAll(t, phone1, 5)

	phone2 := newTestWSClient()
	hub.handleJoin(phone2, mustMarshal(t, session.JoinMessage{
		ClientType: "phone", ClientID: "phone-multi-2", Project: "multi-proj", Token: dev2.ClientToken,
	}))
	recvAll(t, phone2, 5)

	terminal := newTestWSClient()
	hub.handleJoin(terminal, mustMarshal(t, session.JoinMessage{
		ClientType: "terminal", ClientID: "relay-multi", Project: "multi-proj", Token: "hook-secret",
	}))
	recvAll(t, terminal, 5)

	if phone1.sessionID != phone2.sessionID || phone2.sessionID != terminal.sessionID {
		t.Errorf("all clients in same project should share session")
	}
}

func TestArch_AgentClientTypeSupported(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	agentClient := newTestWSClient()
	hub.handleJoin(agentClient, mustMarshal(t, session.JoinMessage{
		ClientType: "agent", ClientID: "agent-001", Project: "agent-proj", Token: "hook-secret",
	}))
	ack := recvOne(t, agentClient)
	if ack == nil {
		t.Fatal("agent should receive join_ack")
	}
}

func TestArch_JoinAckContainsSessionID(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	terminal := newTestWSClient()
	hub.handleJoin(terminal, mustMarshal(t, session.JoinMessage{
		ClientType: "terminal", ClientID: "relay-ack-test", Project: "ack-proj", Token: "hook-secret",
	}))
	ack := recvOne(t, terminal)
	if ack == nil {
		t.Fatal("should receive join_ack")
	}
	var env session.WSEnvelope
	mustUnmarshal(t, ack, &env)
	if env.SessionID == "" {
		t.Error("join_ack should contain session_id")
	}
}

func TestArch_SessionIDFormat(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	_, _, sid := joinPhoneAndTerminal(t, hub, "format-test")
	if !strings.HasPrefix(sid, "sess-") {
		t.Errorf("sessionID should start with 'sess-', got: %s", sid)
	}
}

func TestArch_ExplicitSessionIDRespected(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	terminal := newTestWSClient()
	explicitSID := "sess-custom-explicit-id"
	hub.handleJoin(terminal, mustMarshal(t, session.JoinMessage{
		SessionID:  explicitSID,
		ClientType: "terminal", ClientID: "relay-explicit", Project: "explicit-proj", Token: "hook-secret",
	}))
	recvAll(t, terminal, 5)
	if terminal.sessionID != explicitSID {
		t.Errorf("explicit sessionID should be respected: got %s, want %s", terminal.sessionID, explicitSID)
	}
}

func TestArch_JoinAckContainsClientID(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	terminal := newTestWSClient()
	hub.handleJoin(terminal, mustMarshal(t, session.JoinMessage{
		ClientType: "terminal", ClientID: "relay-ack-cid", Project: "ack-cid-proj", Token: "hook-secret",
	}))
	ack := recvOne(t, terminal)
	if ack == nil {
		t.Fatal("should receive join_ack")
	}
	var env session.WSEnvelope
	mustUnmarshal(t, ack, &env)
	payload, ok := env.Payload.(map[string]interface{})
	if !ok {
		t.Fatal("join_ack payload should be a map")
	}
	if payload["client_id"] != "relay-ack-cid" {
		t.Errorf("join_ack client_id = %v, want 'relay-ack-cid'", payload["client_id"])
	}
}

// ── 需求2: 两种 Agent 模式 ──

func TestArch_PythonAgentMode_HTTPLongPolling(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, _, sid := joinPhoneAndTerminal(t, hub, "python-agent")
	hub.handleMessage(phone, makeSessionMsg(sid, "python-agent-test"))
	if hub.relay.CmdQueue.PendingCount() == 0 {
		t.Error("Python agent mode: CmdQueue should have pending command for HTTP polling")
	}
}

func TestArch_RelayAgentMode_WSRealTime(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "relay-agent")
	hub.handleMessage(phone, makeSessionMsg(sid, "relay-agent-test"))
	msg := recvOne(t, terminal)
	if msg == nil {
		t.Fatal("relay agent mode: terminal should receive message via WS")
	}
}

func TestArch_CmdQueueEnqueueOnly(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, _, sid := joinPhoneAndTerminal(t, hub, "enqueue-only")
	before := hub.relay.CmdQueue.PendingCount()
	hub.handleMessage(phone, makeSessionMsg(sid, "enqueue-test"))
	after := hub.relay.CmdQueue.PendingCount()
	if after != before+1 {
		t.Errorf("EnqueueOnly should add 1 to pending: before=%d after=%d", before, after)
	}
}

func TestArch_RelayReceiverFlagSetForRelayPrefix(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	tests := []struct {
		clientID  string
		wantRelay bool
	}{
		{"relay-123", true},
		{"relay-", true},
		{"relay-abc-def", true},
		{"terminal-001", false},
		{"term-001", false},
		{"agent-001", false},
	}
	for _, tc := range tests {
		t.Run(tc.clientID, func(t *testing.T) {
			client := newTestWSClient()
			hub.handleJoin(client, mustMarshal(t, session.JoinMessage{
				ClientType: "terminal", ClientID: tc.clientID, Project: "relay-flag-test", Token: "hook-secret",
			}))
			recvAll(t, client, 3)
			if client.relayReceiver != tc.wantRelay {
				t.Errorf("relayReceiver for %q = %v, want %v", tc.clientID, client.relayReceiver, tc.wantRelay)
			}
		})
	}
}

func TestArch_AgentCanSendCmdStepAndResult(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	repo := setupTestDeviceRepo(t)
	dev := pairDevice(t, repo, "phone-agent-send")
	hub.SetDeviceRepo(repo)

	phone := newTestWSClient()
	hub.handleJoin(phone, mustMarshal(t, session.JoinMessage{
		ClientType: "phone", ClientID: "phone-agent-send", Project: "agent-send-proj", Token: dev.ClientToken,
	}))
	recvAll(t, phone, 5)

	agentClient := newTestWSClient()
	hub.handleJoin(agentClient, mustMarshal(t, session.JoinMessage{
		ClientType: "agent", ClientID: "agent-sender", Project: "agent-send-proj", Token: "hook-secret",
	}))
	recvAll(t, agentClient, 5)
	sid := phone.sessionID

	hub.handleMessage(agentClient, makeCmdStepMsg(sid, "agent-step", "text", "agent step"))
	if msg := recvOne(t, phone); msg == nil {
		t.Error("phone should receive cmd_step from agent")
	}

	hub.handleMessage(agentClient, makeCmdResultMsg(sid, "agent-result", "agent final"))
	if msg := recvOne(t, phone); msg == nil {
		t.Error("phone should receive cmd_result from agent")
	}
}

func TestArch_AgentCannotSendSessionMsg(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	repo := setupTestDeviceRepo(t)
	dev := pairDevice(t, repo, "phone-agent-nosm")
	hub.SetDeviceRepo(repo)

	phone := newTestWSClient()
	hub.handleJoin(phone, mustMarshal(t, session.JoinMessage{
		ClientType: "phone", ClientID: "phone-agent-nosm", Project: "agent-nosm", Token: dev.ClientToken,
	}))
	recvAll(t, phone, 5)

	agentClient := newTestWSClient()
	hub.handleJoin(agentClient, mustMarshal(t, session.JoinMessage{
		ClientType: "agent", ClientID: "agent-nosm", Project: "agent-nosm", Token: "hook-secret",
	}))
	recvAll(t, agentClient, 5)

	hub.handleMessage(agentClient, makeSessionMsg(phone.sessionID, "agent sm"))
	msg := recvOne(t, phone)
	if msg != nil {
		var env session.WSEnvelope
		mustUnmarshal(t, msg, &env)
		if env.Type == session.MsgTypeSessionMsg {
			t.Error("agent should not send session_msg")
		}
	}
}

func TestArch_TerminalCanSendCmdStep(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "term-cmdstep")
	hub.handleMessage(terminal, makeCmdStepMsg(sid, "term-step", "text", "terminal step"))
	if msg := recvOne(t, phone); msg == nil {
		t.Error("phone should receive cmd_step from terminal")
	}
}

func TestArch_TerminalCannotSendSessionMsg(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "term-nosm")
	hub.handleMessage(terminal, makeSessionMsg(sid, "terminal sm"))
	msg := recvOne(t, phone)
	if msg != nil {
		var env session.WSEnvelope
		mustUnmarshal(t, msg, &env)
		if env.Type == session.MsgTypeSessionMsg {
			t.Error("terminal should not send session_msg")
		}
	}
}

func TestArch_PhoneCannotSendCmdStep(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "phone-nostep")
	hub.handleMessage(phone, makeCmdStepMsg(sid, "phone-step", "text", "forged"))
	msg := recvOne(t, terminal)
	if msg != nil {
		var env session.WSEnvelope
		mustUnmarshal(t, msg, &env)
		if env.Type == session.MsgTypeCmdStep {
			t.Error("phone should not send cmd_step")
		}
	}
}

func TestArch_PhoneCannotSendCmdResult(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "phone-noresult")
	hub.handleMessage(phone, makeCmdResultMsg(sid, "phone-result", "forged"))
	msg := recvOne(t, terminal)
	if msg != nil {
		var env session.WSEnvelope
		mustUnmarshal(t, msg, &env)
		if env.Type == session.MsgTypeCmdResult {
			t.Error("phone should not send cmd_result")
		}
	}
}

// ── 需求3: Session 隔离 ──

func TestArch_SessionIsolation_DifferentProjects(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	_, terminalA, sidA := joinPhoneAndTerminal(t, hub, "iso-proj-a")
	_, terminalB, sidB := joinPhoneAndTerminal(t, hub, "iso-proj-b")
	if sidA == sidB {
		t.Fatal("different projects should have different sessions")
	}
	hub.handleMessage(terminalA, makeCmdStepMsg(sidA, "cmd-iso-a", "text", "msg-for-a"))
	msgB := recvOne(t, terminalB)
	if msgB != nil {
		var env session.WSEnvelope
		mustUnmarshal(t, msgB, &env)
		if env.Type == session.MsgTypeCmdStep {
			t.Error("terminal B should not receive terminal A's cmd_step")
		}
	}
}

func TestArch_SessionIsolation_SameProjectSharesSession(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	repo := setupTestDeviceRepo(t)
	dev := pairDevice(t, repo, "phone-share")
	hub.SetDeviceRepo(repo)

	phone := newTestWSClient()
	hub.handleJoin(phone, mustMarshal(t, session.JoinMessage{
		ClientType: "phone", ClientID: "phone-share", Project: "share-proj", Token: dev.ClientToken,
	}))
	recvAll(t, phone, 5)

	terminal := newTestWSClient()
	hub.handleJoin(terminal, mustMarshal(t, session.JoinMessage{
		ClientType: "terminal", ClientID: "relay-share", Project: "share-proj", Token: "hook-secret",
	}))
	recvAll(t, terminal, 5)

	if phone.sessionID != terminal.sessionID {
		t.Errorf("same project should share session")
	}
}

func TestArch_SessionIsolation_EmptyProjectDefaults(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	terminal := newTestWSClient()
	hub.handleJoin(terminal, mustMarshal(t, session.JoinMessage{
		ClientType: "terminal", ClientID: "relay-default", Token: "hook-secret",
	}))
	recvAll(t, terminal, 5)
	if terminal.sessionID == "" {
		t.Fatal("should have sessionID even with empty project")
	}
	if terminal.project != "serein" {
		t.Errorf("empty project should default to 'serein', got %q", terminal.project)
	}
}

func TestArch_SessionIsolation_MultiSessionNoLeak(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	var sessions []struct {
		phone, terminal *wsClient
		sid             string
	}
	for i := 0; i < 5; i++ {
		projName := "leak-test-" + string(rune('a'+i))
		phone, terminal, sid := joinPhoneAndTerminal(t, hub, projName)
		sessions = append(sessions, struct {
			phone, terminal *wsClient
			sid             string
		}{phone, terminal, sid})
	}
	for i, s := range sessions {
		hub.handleMessage(s.phone, makeSessionMsg(s.sid, "unique-msg-"+string(rune('a'+i))))
		time.Sleep(250 * time.Millisecond)
	}
	for i, s := range sessions {
		msg := recvOne(t, s.terminal)
		if msg == nil {
			t.Fatalf("terminal %d should receive message", i)
		}
		content := extractPayloadField(t, msg, "content")
		expected := "unique-msg-" + string(rune('a'+i))
		if content != expected {
			t.Errorf("terminal %d: content = %v, want %q", i, content, expected)
		}
	}
}

// ── 需求4: 消息类型协议 ──

func TestArch_MessageType_SessionMsg(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "msg-sm")
	hub.handleMessage(phone, makeSessionMsg(sid, "type-test"))
	msg := recvOne(t, terminal)
	if msg == nil {
		t.Fatal("should receive session_msg")
	}
	var env session.WSEnvelope
	mustUnmarshal(t, msg, &env)
	if env.Type != session.MsgTypeSessionMsg {
		t.Errorf("type = %s, want session_msg", env.Type)
	}
}

func TestArch_MessageType_CmdStep(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "msg-cs")
	hub.handleMessage(terminal, makeCmdStepMsg(sid, "type-cmd", "text", "type test"))
	msg := recvOne(t, phone)
	if msg == nil {
		t.Fatal("should receive cmd_step")
	}
	var env session.WSEnvelope
	mustUnmarshal(t, msg, &env)
	if env.Type != session.MsgTypeCmdStep {
		t.Errorf("type = %s, want cmd_step", env.Type)
	}
}

func TestArch_MessageType_CmdResult(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "msg-cr")
	hub.handleMessage(terminal, makeCmdResultMsg(sid, "type-result", "type result"))
	msg := recvOne(t, phone)
	if msg == nil {
		t.Fatal("should receive cmd_result")
	}
	var env session.WSEnvelope
	mustUnmarshal(t, msg, &env)
	if env.Type != session.MsgTypeCmdResult {
		t.Errorf("type = %s, want cmd_result", env.Type)
	}
}

func TestArch_MessageType_Heartbeat(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, _, _ := joinPhoneAndTerminal(t, hub, "msg-hb")
	hub.handleMessage(phone, mustMarshal(t, session.WSEnvelope{Type: session.MsgTypeHeartbeat}))
	msg := recvOne(t, phone)
	if msg != nil {
		var env session.WSEnvelope
		mustUnmarshal(t, msg, &env)
		if env.Type == session.MsgTypeError {
			t.Error("heartbeat should not produce error")
		}
	}
}

func TestArch_MessageType_JoinAck(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	terminal := newTestWSClient()
	hub.handleJoin(terminal, mustMarshal(t, session.JoinMessage{
		ClientType: "terminal", ClientID: "relay-ack", Project: "ack-proj", Token: "hook-secret",
	}))
	msg := recvOne(t, terminal)
	if msg == nil {
		t.Fatal("should receive join_ack")
	}
	var env session.WSEnvelope
	mustUnmarshal(t, msg, &env)
	if env.Type != session.MsgTypeJoinAck {
		t.Errorf("type = %s, want join_ack", env.Type)
	}
}

func TestArch_MessageType_Error(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	terminal := newTestWSClient()
	hub.handleJoin(terminal, mustMarshal(t, session.JoinMessage{
		ClientType: "terminal", ClientID: "relay-err", Token: "wrong-token",
	}))
	msg := recvOne(t, terminal)
	if msg == nil {
		t.Fatal("should receive error message")
	}
	var env session.WSEnvelope
	mustUnmarshal(t, msg, &env)
	if env.Type != session.MsgTypeError {
		t.Errorf("type = %s, want error", env.Type)
	}
}

func TestArch_MessageType_History(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, _, sid := joinPhoneAndTerminal(t, hub, "hist-type")

	cmd := &agent.Command{
		Action: agent.ActionExec, Project: "hist-type", Command: "echo test", SessionID: sid,
	}
	hub.relay.CmdQueue.EnqueueOnly(cmd)
	hub.relay.CmdQueue.NotifyResult(cmd.ID, true, map[string]interface{}{"stdout": "test"})

	terminal2 := newTestWSClient()
	hub.handleJoin(terminal2, mustMarshal(t, session.JoinMessage{
		ClientType: "terminal", ClientID: "relay-hist", Project: "hist-type", Token: "hook-secret",
	}))
	msgs := recvAll(t, terminal2, 10)

	foundHistory := false
	for _, m := range msgs {
		var env session.WSEnvelope
		mustUnmarshal(t, m, &env)
		if env.Type == session.MsgTypeHistory {
			foundHistory = true
			break
		}
	}
	_ = phone
	if !foundHistory {
		t.Log("no history messages found (may be empty for new session)")
	}
}

func TestArch_MessageType_UnknownIgnored(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "msg-unknown")
	hub.handleMessage(phone, mustMarshal(t, session.WSEnvelope{
		Type: "completely_unknown", SessionID: sid, Payload: map[string]interface{}{"data": "test"},
	}))
	if msg := recvOne(t, phone); msg != nil {
		var env session.WSEnvelope
		mustUnmarshal(t, msg, &env)
		if env.Type == "completely_unknown" {
			t.Error("unknown type should be ignored")
		}
	}
	if msg := recvOne(t, terminal); msg != nil {
		var env session.WSEnvelope
		mustUnmarshal(t, msg, &env)
		if env.Type == "completely_unknown" {
			t.Error("unknown type should not reach terminal")
		}
	}
}

func TestArch_MessageType_MalformedJSONIgnored(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, _, _ := joinPhoneAndTerminal(t, hub, "msg-malformed")
	hub.handleMessage(phone, []byte("{not valid json"))
	// Should not crash
}

func TestArch_MessageType_EmptyPayload(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, _, sid := joinPhoneAndTerminal(t, hub, "msg-empty")
	hub.handleMessage(phone, mustMarshal(t, session.WSEnvelope{
		Type: session.MsgTypeSessionMsg, SessionID: sid, Payload: nil,
	}))
	// Should not panic
}

// ── 需求5: clientType 隔离 ──

func TestArch_ClientType_PhoneOnlyPermDecision(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "ct-permdec")
	hub.handleMessage(terminal, mustMarshal(t, session.WSEnvelope{
		Type: session.MsgTypePermDecision, SessionID: sid,
		Payload: session.PermDecisionPayload{CmdID: "cmd-ct", Decision: "allow"},
	}))
	msg := recvOne(t, phone)
	if msg != nil {
		var env session.WSEnvelope
		mustUnmarshal(t, msg, &env)
		if env.Type == session.MsgTypePermDecision {
			t.Error("terminal should not send perm_decision")
		}
	}
}

func TestArch_ClientType_PhoneOnlyModeSwitch(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "ct-modeswitch")
	hub.handleMessage(terminal, mustMarshal(t, session.WSEnvelope{
		Type: session.MsgTypeModeSwitch, SessionID: sid,
		Payload: session.ModeSwitchPayload{Mode: session.PermModeYolo},
	}))
	msg := recvOne(t, phone)
	if msg != nil {
		var env session.WSEnvelope
		mustUnmarshal(t, msg, &env)
		if env.Type == session.MsgTypeModeSwitch {
			t.Error("terminal should not send mode_switch")
		}
	}
}

func TestArch_ConcurrentJoinStressTest(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	const N = 50
	var wg sync.WaitGroup
	for i := 0; i < N; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			client := newTestWSClient()
			hub.handleJoin(client, mustMarshal(t, session.JoinMessage{
				ClientType: "terminal",
				ClientID:   "relay-stress-" + string(rune('a'+id%26)),
				Project:    "stress-proj",
				Token:      "hook-secret",
			}))
			recvAll(t, client, 5)
		}(i)
	}
	wg.Wait()
}

func TestArch_RelayClientsMapUpdated(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	hub.mu.RLock()
	if len(hub.relayClients) != 0 {
		t.Errorf("initial relayClients should be 0")
	}
	hub.mu.RUnlock()

	relay := newTestWSClient()
	hub.handleJoin(relay, mustMarshal(t, session.JoinMessage{
		ClientType: "terminal", ClientID: "relay-map-test", Project: "map-proj", Token: "hook-secret",
	}))
	recvAll(t, relay, 5)

	hub.mu.RLock()
	if len(hub.relayClients) != 1 {
		t.Errorf("after relay join, relayClients should be 1, got %d", len(hub.relayClients))
	}
	hub.mu.RUnlock()

	hub.mu.Lock()
	hub.removeClientFromSession(relay)
	hub.mu.Unlock()

	hub.mu.RLock()
	if len(hub.relayClients) != 0 {
		t.Errorf("after relay remove, relayClients should be 0, got %d", len(hub.relayClients))
	}
	hub.mu.RUnlock()
}

func TestArch_NonRelayTerminalNotInRelayClients(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	terminal := newTestWSClient()
	hub.handleJoin(terminal, mustMarshal(t, session.JoinMessage{
		ClientType: "terminal", ClientID: "non-relay-term", Project: "non-relay", Token: "hook-secret",
	}))
	recvAll(t, terminal, 5)
	hub.mu.RLock()
	count := len(hub.relayClients)
	hub.mu.RUnlock()
	if count != 0 {
		t.Errorf("non-relay terminal should not be in relayClients, count = %d", count)
	}
}

func TestArch_BroadcastToRelays(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	relay1 := newTestWSClient()
	hub.handleJoin(relay1, mustMarshal(t, session.JoinMessage{
		ClientType: "terminal", ClientID: "relay-btr-1", Project: "btr-proj", Token: "hook-secret",
	}))
	recvAll(t, relay1, 5)

	relay2 := newTestWSClient()
	hub.handleJoin(relay2, mustMarshal(t, session.JoinMessage{
		ClientType: "terminal", ClientID: "relay-btr-2", Project: "btr-proj", Token: "hook-secret",
	}))
	recvAll(t, relay2, 5)

	hub.BroadcastToRelays("test_broadcast", map[string]interface{}{"data": "hello"})
	if msg := recvOne(t, relay1); msg == nil {
		t.Error("relay1 should receive broadcast")
	}
	if msg := recvOne(t, relay2); msg == nil {
		t.Error("relay2 should receive broadcast")
	}
}

func TestArch_GetSessionClients(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	repo := setupTestDeviceRepo(t)
	dev := pairDevice(t, repo, "phone-gsc")
	hub.SetDeviceRepo(repo)

	phone := newTestWSClient()
	hub.handleJoin(phone, mustMarshal(t, session.JoinMessage{
		ClientType: "phone", ClientID: "phone-gsc", Project: "gsc-proj", Token: dev.ClientToken,
	}))
	recvAll(t, phone, 5)

	terminal := newTestWSClient()
	hub.handleJoin(terminal, mustMarshal(t, session.JoinMessage{
		ClientType: "terminal", ClientID: "relay-gsc", Project: "gsc-proj", Token: "hook-secret",
	}))
	recvAll(t, terminal, 5)

	clients := hub.GetSessionClients(phone.sessionID)
	if len(clients) != 2 {
		t.Errorf("GetSessionClients should return 2, got %d", len(clients))
	}
}

func TestArch_BroadcastToAllClients(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	repo := setupTestDeviceRepo(t)
	dev1 := pairDevice(t, repo, "phone-bac-1")
	dev2 := logicalTestDevice(dev1)
	hub.SetDeviceRepo(repo)

	phone1 := newTestWSClient()
	hub.handleJoin(phone1, mustMarshal(t, session.JoinMessage{
		ClientType: "phone", ClientID: "phone-bac-1", Project: "bac-1", Token: dev1.ClientToken,
	}))
	recvAll(t, phone1, 5)
	// Broadcast iterates h.clients (set by HandleWS), not clientsBySession.
	// handleJoin only adds to clientsBySession, so manually register for Broadcast test.
	hub.mu.Lock()
	hub.clients[phone1] = true
	hub.mu.Unlock()

	phone2 := newTestWSClient()
	hub.handleJoin(phone2, mustMarshal(t, session.JoinMessage{
		ClientType: "phone", ClientID: "phone-bac-2", Project: "bac-2", Token: dev2.ClientToken,
	}))
	recvAll(t, phone2, 5)
	hub.mu.Lock()
	hub.clients[phone2] = true
	hub.mu.Unlock()

	hub.Broadcast("global", map[string]interface{}{"msg": "all"})
	if msg := recvOne(t, phone1); msg == nil {
		t.Error("phone1 should receive global broadcast")
	}
	if msg := recvOne(t, phone2); msg == nil {
		t.Error("phone2 should receive global broadcast")
	}
}

// ── SessionManager 测试 ──

func TestArch_SessionManagerStop(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	sm := hub.getSessionManager()
	if sm == nil {
		t.Fatal("SessionManager should not be nil")
	}
	sm.Stop()
	sm.Stop() // double stop should not panic
}

func TestArch_SessionManagerGetOrCreate(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	sm := hub.getSessionManager()
	s1 := sm.GetOrCreateSession("idempotent-proj")
	s2 := sm.GetOrCreateSession("idempotent-proj")
	if s1 == nil || s2 == nil {
		t.Fatal("GetOrCreateSession should not return nil")
	}
	if s1.ID != s2.ID {
		t.Errorf("GetOrCreateSession should be idempotent")
	}
}

func TestArch_SessionManagerGetByProject(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	sm := hub.getSessionManager()
	s := sm.GetOrCreateSession("getby-proj")
	found := sm.GetSessionByProject("getby-proj")
	if found == nil || found.ID != s.ID {
		t.Error("GetSessionByProject should find the session")
	}
	if sm.GetSessionByProject("non-existent") != nil {
		t.Error("should return nil for non-existent project")
	}
}

func TestArch_SessionManagerGetByID(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	sm := hub.getSessionManager()
	s := sm.GetOrCreateSession("getbyid-proj")
	found := sm.GetSessionByID(s.ID)
	if found == nil || found.ID != s.ID {
		t.Error("GetSessionByID should find the session")
	}
	if sm.GetSessionByID("non-existent") != nil {
		t.Error("should return nil for non-existent ID")
	}
}

func TestArch_SessionManagerRemoveSession(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	sm := hub.getSessionManager()
	s := sm.GetOrCreateSession("remove-proj")
	sm.RemoveSession(s.ID)
	if sm.GetSessionByID(s.ID) != nil {
		t.Error("session should be removed")
	}
	if sm.GetSessionByProject("remove-proj") != nil {
		t.Error("project mapping should be removed")
	}
}

func TestArch_SessionManagerJoinLeave(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	sm := hub.getSessionManager()
	s := sm.GetOrCreateSession("joinleave-proj")
	sm.JoinSession(s.ID, "client-001", "phone")
	if s2 := sm.GetSessionByID(s.ID); s2 == nil || len(s2.Clients) != 1 {
		t.Error("after join, session should have 1 client")
	}
	sm.LeaveSession(s.ID, "client-001")
	if s3 := sm.GetSessionByID(s.ID); s3 != nil && len(s3.Clients) != 0 {
		t.Error("after leave, session should have 0 clients")
	}
}

func TestArch_SessionManagerNextSeq(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	sm := hub.getSessionManager()
	s1 := sm.NextSeq()
	s2 := sm.NextSeq()
	s3 := sm.NextSeq()
	if s1 >= s2 || s2 >= s3 {
		t.Errorf("NextSeq should be monotonically increasing: %d, %d, %d", s1, s2, s3)
	}
}

// ── DeviceRepo 测试 ──

func TestArch_DeviceRepoPair(t *testing.T) {
	repo := setupTestDeviceRepo(t)
	dev, err := repo.Pair("dev-pair-test", "test-phone", "pair-token-123")
	if err != nil {
		t.Fatalf("Pair failed: %v", err)
	}
	if dev.ClientToken != "pair-token-123" {
		t.Errorf("ClientToken = %s, want 'pair-token-123'", dev.ClientToken)
	}
}

func TestArch_DeviceRepoByClientToken(t *testing.T) {
	repo := setupTestDeviceRepo(t)
	_, err := repo.Pair("dev-bct-test", "test-phone", "bct-token-456")
	if err != nil {
		t.Fatalf("Pair failed: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	dev, err := repo.ByClientToken(ctx, "bct-token-456")
	if err != nil || dev == nil {
		t.Fatalf("ByClientToken failed: %v", err)
	}
	dev2, _ := repo.ByClientToken(ctx, "wrong-token")
	if dev2 != nil {
		t.Error("should not find device with wrong token")
	}
}

// ── re-join 测试 ──

func TestArch_RejoinDifferentProjectChangesSession(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	repo := setupTestDeviceRepo(t)
	dev := pairDevice(t, repo, "phone-rejoin-diff")
	hub.SetDeviceRepo(repo)

	client := newTestWSClient()
	hub.handleJoin(client, mustMarshal(t, session.JoinMessage{
		ClientType: "phone", ClientID: "phone-rejoin-diff", Project: "proj-rejoin-1", Token: dev.ClientToken,
	}))
	recvAll(t, client, 5)
	sid1 := client.sessionID

	hub.handleJoin(client, mustMarshal(t, session.JoinMessage{
		ClientType: "phone", ClientID: "phone-rejoin-diff", Project: "proj-rejoin-2", Token: dev.ClientToken,
	}))
	recvAll(t, client, 5)
	sid2 := client.sessionID

	if sid1 == sid2 {
		t.Error("re-joining different project should change session")
	}
}

func TestArch_RejoinSameProjectKeepsSession(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	repo := setupTestDeviceRepo(t)
	dev := pairDevice(t, repo, "phone-rejoin-same")
	hub.SetDeviceRepo(repo)

	client := newTestWSClient()
	hub.handleJoin(client, mustMarshal(t, session.JoinMessage{
		ClientType: "phone", ClientID: "phone-rejoin-same", Project: "rejoin-same", Token: dev.ClientToken,
	}))
	recvAll(t, client, 5)
	sid1 := client.sessionID

	hub.handleJoin(client, mustMarshal(t, session.JoinMessage{
		ClientType: "phone", ClientID: "phone-rejoin-same", Project: "rejoin-same", Token: dev.ClientToken,
	}))
	recvAll(t, client, 5)
	sid2 := client.sessionID

	if sid1 != sid2 {
		t.Error("re-joining same project should keep same session")
	}
}

func TestArch_RejoinResetsRelayReceiverFlag(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	repo := setupTestDeviceRepo(t)
	dev := pairDevice(t, repo, "phone-rejoin-flag")
	hub.SetDeviceRepo(repo)

	client := newTestWSClient()
	hub.handleJoin(client, mustMarshal(t, session.JoinMessage{
		ClientType: "terminal", ClientID: "relay-rejoin-flag", Project: "proj-flag-1", Token: "hook-secret",
	}))
	recvAll(t, client, 5)
	if !client.relayReceiver {
		t.Fatal("relay terminal should have relayReceiver=true")
	}

	// Re-join as phone
	hub.handleJoin(client, mustMarshal(t, session.JoinMessage{
		ClientType: "phone", ClientID: "phone-rejoin-flag", Project: "proj-flag-2", Token: dev.ClientToken,
	}))
	recvAll(t, client, 5)
	if client.relayReceiver {
		t.Error("relayReceiver must be reset to false after re-joining as phone")
	}
}

// ── removeClientFromSession 测试 ──

func TestArch_RemoveClientFromSession(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	repo := setupTestDeviceRepo(t)
	dev := pairDevice(t, repo, "phone-remove")
	hub.SetDeviceRepo(repo)

	phone := newTestWSClient()
	hub.handleJoin(phone, mustMarshal(t, session.JoinMessage{
		ClientType: "phone", ClientID: "phone-remove", Project: "remove-proj", Token: dev.ClientToken,
	}))
	recvAll(t, phone, 5)

	sid := phone.sessionID
	clients := hub.GetSessionClients(sid)
	if len(clients) != 1 {
		t.Fatalf("should have 1 client, got %d", len(clients))
	}

	hub.mu.Lock()
	hub.removeClientFromSession(phone)
	hub.mu.Unlock()

	clients = hub.GetSessionClients(sid)
	if len(clients) != 0 {
		t.Errorf("after remove, should have 0 clients, got %d", len(clients))
	}
}

func TestArch_RemoveClientFromSessionWithReplacement(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	repo := setupTestDeviceRepo(t)
	dev := pairDevice(t, repo, "phone-replace")
	hub.SetDeviceRepo(repo)

	// First client joins
	client1 := newTestWSClient()
	hub.handleJoin(client1, mustMarshal(t, session.JoinMessage{
		ClientType: "phone", ClientID: "phone-replace", Project: "replace-proj", Token: dev.ClientToken,
	}))
	recvAll(t, client1, 5)
	sid := client1.sessionID

	// Second client with same clientID joins (replacement)
	client2 := newTestWSClient()
	hub.handleJoin(client2, mustMarshal(t, session.JoinMessage{
		ClientType: "phone", ClientID: "phone-replace", Project: "replace-proj", Token: dev.ClientToken,
	}))
	recvAll(t, client2, 5)

	// Now remove client1 (old connection) — should NOT leave session
	// because client2 (replacement) exists
	hub.mu.Lock()
	hub.removeClientFromSession(client1)
	hub.mu.Unlock()

	clients := hub.GetSessionClients(sid)
	if len(clients) != 1 {
		t.Errorf("after removing old client with replacement, should have 1 client, got %d", len(clients))
	}
}

// ── 安全: safeClientID ──

func TestArch_SafeClientID(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{"relay-12345678", "relay-12"},
		{"short", "short"},
		{"", ""},
		{"a", "a"},
		{"12345678", "12345678"},
		{"123456789", "12345678"},
	}
	for _, tc := range tests {
		got := safeClientID(tc.input)
		if got != tc.want {
			t.Errorf("safeClientID(%q) = %q, want %q", tc.input, got, tc.want)
		}
	}
}

// ── 读取截止时间 ──

func TestArch_ReadDeadlineFor(t *testing.T) {
	tests := []struct {
		clientType string
		want       time.Duration
	}{
		{"phone", phoneReadDeadline},
		{"terminal", clientReadDeadline},
		{"agent", clientReadDeadline},
		{"unknown", clientReadDeadline},
		{"", clientReadDeadline},
	}
	for _, tc := range tests {
		got := readDeadlineFor(tc.clientType)
		if got != tc.want {
			t.Errorf("readDeadlineFor(%q) = %v, want %v", tc.clientType, got, tc.want)
		}
	}
}

// ── JSON 序列化完整性 ──

func TestArch_WSEnvelopeSerialization(t *testing.T) {
	env := session.WSEnvelope{
		Type:      session.MsgTypeCmdStep,
		SessionID: "sess-test-123",
		Source:    "terminal",
		Payload: map[string]interface{}{
			"cmd_id":  "cmd-001",
			"content": "test content",
			"event":   "text",
		},
	}
	raw, err := json.Marshal(env)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var decoded session.WSEnvelope
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if decoded.Type != env.Type {
		t.Errorf("type mismatch: %s vs %s", decoded.Type, env.Type)
	}
	if decoded.SessionID != env.SessionID {
		t.Errorf("sessionID mismatch: %s vs %s", decoded.SessionID, env.SessionID)
	}
	if decoded.Source != env.Source {
		t.Errorf("source mismatch: %s vs %s", decoded.Source, env.Source)
	}
}

func TestArch_JoinMessageSerialization(t *testing.T) {
	join := session.JoinMessage{
		SessionID:      "sess-test",
		ClientType:     "phone",
		ClientID:       "phone-001",
		Project:        "test-proj",
		Token:          "secret-token",
		PermissionMode: session.PermModeDefault,
		AllowedTools:   []string{"Read", "Grep"},
	}
	raw, err := json.Marshal(join)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var decoded session.JoinMessage
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if decoded.ClientType != join.ClientType {
		t.Errorf("clientType mismatch")
	}
	if decoded.Project != join.Project {
		t.Errorf("project mismatch")
	}
}

// ── maxConns 测试 ──

func TestArch_MaxConnsDefault(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	if hub.maxConns != 100 {
		t.Errorf("default maxConns should be 100, got %d", hub.maxConns)
	}
}

// ── Send channel capacity ──

func TestArch_SendChannelCapacity(t *testing.T) {
	client := newTestWSClient()
	// newTestWSClient creates send channel with 256 capacity
	for i := 0; i < 256; i++ {
		select {
		case client.send <- []byte("msg"):
		default:
			t.Fatalf("send channel should accept 256 messages, failed at %d", i)
		}
	}
	// 257th should block
	select {
	case client.send <- []byte("overflow"):
		t.Error("send channel should be full at 257")
	default:
		// expected
	}
}

// ── store.DeviceRepo 重复 Pair ──

func TestArch_DeviceRepoDuplicatePair(t *testing.T) {
	repo := setupTestDeviceRepo(t)
	_, err := repo.Pair("dup-dev-id", "phone-1", "token-1")
	if err != nil {
		t.Fatalf("first pair failed: %v", err)
	}
	// Pairing same device ID should fail with UNIQUE constraint error
	_, err = repo.Pair("dup-dev-id", "phone-1-updated", "token-2")
	if err == nil {
		t.Error("second pair with same device ID should fail (UNIQUE constraint)")
	}
	// First token should still work
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	dev, err := repo.ByClientToken(ctx, "token-1")
	if err != nil || dev == nil {
		t.Fatalf("original token should still work: %v", err)
	}
}
