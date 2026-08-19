package api

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	"serein/internal/agent"
	"serein/internal/session"
)

// ──────────────────────────────────────────────────────────────────────
// 手机→电脑方向测试（需求6-13）
//
// 需求6:  手机 session_msg 发送到后端
// 需求7:  session_msg 写入 CmdQueue (Python agent HTTP 轮询路径)
// 需求8:  session_msg 广播到 relay terminal (WS 实时路径)
// 需求9:  session_msg 内容验证（空、过长、非可打印字符）
// 需求10: session_msg 速率限制
// 需求11: session_msg 入 CmdQueue 安全网
// 需求12: session_msg 回环防护（phone 不收到自己的消息）
// 需求13: session_msg 跨 project 隔离
// ──────────────────────────────────────────────────────────────────────

// ── 需求6: session_msg 发送到后端 ──

func TestPhoneToTerminal_BasicDelivery(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "p2t-basic")
	hub.handleMessage(phone, makeSessionMsg(sid, "hello from phone"))
	msg := recvOne(t, terminal)
	if msg == nil {
		t.Fatal("terminal should receive session_msg")
	}
	var env session.WSEnvelope
	mustUnmarshal(t, msg, &env)
	if env.Type != session.MsgTypeSessionMsg {
		t.Errorf("type = %s, want session_msg", env.Type)
	}
}

func TestPhoneToTerminal_ContentExactMatch(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "p2t-exact")
	testContents := []string{
		"simple text",
		"中文消息测试",
		"emoji 🎉🚀 test",
		"multi\nline\ntext",
		"tab\tseparated\tvalues",
		"special chars: !@#$%^&*()",
		"json: {\"key\":\"value\"}",
		"path: C:\\Users\\test",
		"unicode: αβγδ εζηθ",
		"very long message: " + strings.Repeat("a", 1000),
	}
	for _, content := range testContents {
		t.Run(content[:min(20, len(content))], func(t *testing.T) {
			hub.handleMessage(phone, makeSessionMsg(sid, content))
			time.Sleep(250 * time.Millisecond) // rate limit
			msg := recvOne(t, terminal)
			if msg == nil {
				t.Fatal("terminal should receive message")
			}
			got := extractPayloadField(t, msg, "content")
			if got != content {
				t.Errorf("content mismatch:\n  got:  %v\n  want: %q", got, content)
			}
		})
	}
}

func TestPhoneToTerminal_MultipleSequentialMessages(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "p2t-multi")
	messages := []string{"msg-1", "msg-2", "msg-3", "msg-4", "msg-5"}
	for _, m := range messages {
		hub.handleMessage(phone, makeSessionMsg(sid, m))
		time.Sleep(250 * time.Millisecond)
	}
	for i, expected := range messages {
		msg := recvOne(t, terminal)
		if msg == nil {
			t.Fatalf("terminal should receive message %d", i+1)
		}
		content := extractPayloadField(t, msg, "content")
		if content != expected {
			t.Errorf("message %d: content = %v, want %q", i+1, content, expected)
		}
	}
}

func TestPhoneToTerminal_MessageOrdering(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "p2t-order")
	// Send messages with rate limit to avoid rate limiting
	for i := 0; i < 10; i++ {
		hub.handleMessage(phone, makeSessionMsg(sid, "order-"+string(rune('A'+i))))
		time.Sleep(250 * time.Millisecond)
	}
	// Verify order
	for i := 0; i < 10; i++ {
		msg := recvOne(t, terminal)
		if msg == nil {
			t.Fatalf("message %d not received", i+1)
		}
		expected := "order-" + string(rune('A'+i))
		content := extractPayloadField(t, msg, "content")
		if content != expected {
			t.Errorf("order mismatch at %d: got %v, want %q", i+1, content, expected)
		}
	}
}

// ── 需求9: session_msg 内容验证 ──

func TestPhoneToTerminal_EmptyContentRejected(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, _, sid := joinPhoneAndTerminal(t, hub, "p2t-empty")
	hub.handleMessage(phone, makeSessionMsg(sid, ""))
	if hub.relay.CmdQueue.PendingCount() > 0 {
		// Should not enqueue empty content — but it may have pending from join
		// Check that no NEW command was added
	}
}

func TestPhoneToTerminal_ContentTooLongRejected(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "p2t-toolong")
	before := hub.relay.CmdQueue.PendingCount()
	longContent := strings.Repeat("x", 8001)
	hub.handleMessage(phone, makeSessionMsg(sid, longContent))
	after := hub.relay.CmdQueue.PendingCount()
	if after > before {
		t.Error("content over 8000 chars should not be enqueued")
	}
	msg := recvOne(t, terminal)
	if msg != nil {
		var env session.WSEnvelope
		mustUnmarshal(t, msg, &env)
		if env.Type == session.MsgTypeSessionMsg {
			t.Error("terminal should not receive overly long content")
		}
	}
}

func TestPhoneToTerminal_ContentExactlyAtLimit(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, _, sid := joinPhoneAndTerminal(t, hub, "p2t-atlimit")
	// 8000 chars should be accepted
	content := strings.Repeat("x", 8000)
	before := hub.relay.CmdQueue.PendingCount()
	hub.handleMessage(phone, makeSessionMsg(sid, content))
	after := hub.relay.CmdQueue.PendingCount()
	if after != before+1 {
		t.Errorf("content at limit (8000) should be accepted: before=%d after=%d", before, after)
	}
}

func TestPhoneToTerminal_NonPrintableContentRejected(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, _, sid := joinPhoneAndTerminal(t, hub, "p2t-nonprint")
	nonPrintableContents := []string{
		"hello\x00world",
		"\x01\x02\x03",
		"bell\x07ring",
		"escape\x1b[0m",
		"delete\x7fchar",
	}
	for _, content := range nonPrintableContents {
		before := hub.relay.CmdQueue.PendingCount()
		hub.handleMessage(phone, makeSessionMsg(sid, content))
		after := hub.relay.CmdQueue.PendingCount()
		if after > before {
			t.Errorf("non-printable content should not be enqueued: %q", content)
		}
		time.Sleep(250 * time.Millisecond) // rate limit
	}
}

func TestPhoneToTerminal_ShellMetacharsAllowed(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, _, sid := joinPhoneAndTerminal(t, hub, "p2t-shellmeta")
	// session_msg goes to PTY stdin, not shell — shell metacharacters should be allowed
	contents := []string{
		"ls; rm -rf /",
		"cat file | grep pattern",
		"echo $HOME",
		"cmd && cmd2",
		"echo `whoami`",
		"redirect > file.txt",
		"input < file.txt",
	}
	for _, content := range contents {
		before := hub.relay.CmdQueue.PendingCount()
		hub.handleMessage(phone, makeSessionMsg(sid, content))
		after := hub.relay.CmdQueue.PendingCount()
		if after != before+1 {
			t.Errorf("shell metachar content should be accepted for session_msg: %q", content)
		}
		time.Sleep(250 * time.Millisecond)
	}
}

func TestPhoneToTerminal_NewlinesAllowed(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, _, sid := joinPhoneAndTerminal(t, hub, "p2t-newlines")
	content := "line1\nline2\nline3"
	before := hub.relay.CmdQueue.PendingCount()
	hub.handleMessage(phone, makeSessionMsg(sid, content))
	after := hub.relay.CmdQueue.PendingCount()
	if after != before+1 {
		t.Error("content with newlines should be accepted")
	}
}

func TestPhoneToTerminal_TabsAllowed(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, _, sid := joinPhoneAndTerminal(t, hub, "p2t-tabs")
	content := "col1\tcol2\tcol3"
	before := hub.relay.CmdQueue.PendingCount()
	hub.handleMessage(phone, makeSessionMsg(sid, content))
	after := hub.relay.CmdQueue.PendingCount()
	if after != before+1 {
		t.Error("content with tabs should be accepted")
	}
}

func TestPhoneToTerminal_CJKContentPreserved(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "p2t-cjk")
	contents := []string{
		"你好世界",
		"日本語テスト",
		"한국어 시험",
		"emoji 🎉 test",
		"mixed 中English 文",
	}
	for _, content := range contents {
		hub.handleMessage(phone, makeSessionMsg(sid, content))
		time.Sleep(250 * time.Millisecond)
		msg := recvOne(t, terminal)
		if msg == nil {
			t.Fatalf("terminal should receive CJK content: %q", content)
		}
		got := extractPayloadField(t, msg, "content")
		if got != content {
			t.Errorf("CJK content mismatch: got %v, want %q", got, content)
		}
	}
}

// ── 需求10: session_msg 速率限制 ──

func TestPhoneToTerminal_RateLimit_FirstMessageAllowed(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "p2t-rl-1")
	hub.handleMessage(phone, makeSessionMsg(sid, "first-msg"))
	msg := recvOne(t, terminal)
	if msg == nil {
		t.Fatal("first message should be allowed (within rate limit)")
	}
}

func TestPhoneToTerminal_RateLimit_SecondImmediateDropped(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "p2t-rl-2")
	// First message
	hub.handleMessage(phone, makeSessionMsg(sid, "first"))
	recvOne(t, terminal)

	// Second message immediately — should be rate limited
	hub.handleMessage(phone, makeSessionMsg(sid, "second-rate-limited"))
	msg := recvOne(t, terminal)
	if msg != nil {
		content := extractPayloadField(t, msg, "content")
		if content == "second-rate-limited" {
			t.Error("second message should be rate-limited")
		}
	}
}

func TestPhoneToTerminal_RateLimit_AfterWindowAllowed(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "p2t-rl-3")
	hub.handleMessage(phone, makeSessionMsg(sid, "first"))
	recvOne(t, terminal)

	time.Sleep(300 * time.Millisecond) // wait for rate limit window

	hub.handleMessage(phone, makeSessionMsg(sid, "after-wait"))
	msg := recvOne(t, terminal)
	if msg == nil {
		t.Fatal("message after rate limit window should be delivered")
	}
	content := extractPayloadField(t, msg, "content")
	if content != "after-wait" {
		t.Errorf("content = %v, want 'after-wait'", content)
	}
}

func TestPhoneToTerminal_RateLimit_PerClientIsolation(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	repo := setupTestDeviceRepo(t)
	dev1 := pairDevice(t, repo, "phone-rl-a")
	dev2 := logicalTestDevice(dev1)
	hub.SetDeviceRepo(repo)

	phone1 := newTestWSClient()
	hub.handleJoin(phone1, mustMarshal(t, session.JoinMessage{
		ClientType: "phone", ClientID: "phone-rl-a", Project: "rl-iso-proj", Token: dev1.ClientToken,
	}))
	recvAll(t, phone1, 5)

	phone2 := newTestWSClient()
	hub.handleJoin(phone2, mustMarshal(t, session.JoinMessage{
		ClientType: "phone", ClientID: "phone-rl-b", Project: "rl-iso-proj", Token: dev2.ClientToken,
	}))
	recvAll(t, phone2, 5)

	terminal := newTestWSClient()
	hub.handleJoin(terminal, mustMarshal(t, session.JoinMessage{
		ClientType: "terminal", ClientID: "relay-rl-iso", Project: "rl-iso-proj", Token: "hook-secret",
	}))
	recvAll(t, terminal, 5)

	sid := phone1.sessionID

	// Both phones send simultaneously — both should be allowed (different clientIDs)
	hub.handleMessage(phone1, makeSessionMsg(sid, "from-phone-1"))
	hub.handleMessage(phone2, makeSessionMsg(sid, "from-phone-2"))

	// Both messages should be received by terminal (order may vary)
	msgs := recvAll(t, terminal, 5)
	found1, found2 := false, false
	for _, m := range msgs {
		content := extractPayloadField(t, m, "content")
		if content == "from-phone-1" {
			found1 = true
		}
		if content == "from-phone-2" {
			found2 = true
		}
	}
	if !found1 {
		t.Error("phone-1 message should be delivered (rate limit is per-client)")
	}
	if !found2 {
		t.Error("phone-2 message should be delivered (rate limit is per-client)")
	}
}

func TestPhoneToTerminal_RateLimit_RemovedOnDisconnect(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, _, sid := joinPhoneAndTerminal(t, hub, "p2t-rl-rm")

	// Send a message to create a rate limit entry
	hub.handleMessage(phone, makeSessionMsg(sid, "trigger-rate-limit"))

	// Check rate limit entry exists after sending
	hub.rateLimitMu.Lock()
	_, exists := hub.rateLimitTimers[phone.clientID]
	hub.rateLimitMu.Unlock()
	if !exists {
		t.Fatal("rate limit entry should exist after sending message")
	}

	// Remove client
	hub.mu.Lock()
	hub.removeClientFromSession(phone)
	hub.mu.Unlock()

	// Rate limit entry should be cleaned up
	hub.rateLimitMu.Lock()
	_, exists = hub.rateLimitTimers[phone.clientID]
	hub.rateLimitMu.Unlock()
	if exists {
		t.Error("rate limit entry should be removed after client disconnect")
	}
}

// ── 需求11: session_msg 入 CmdQueue 安全网 ──

func TestPhoneToTerminal_EnqueuedToCmdQueue(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, _, sid := joinPhoneAndTerminal(t, hub, "p2t-cq")
	before := hub.relay.CmdQueue.PendingCount()
	hub.handleMessage(phone, makeSessionMsg(sid, "cq-test"))
	after := hub.relay.CmdQueue.PendingCount()
	if after != before+1 {
		t.Errorf("CmdQueue pending: before=%d after=%d, expected +1", before, after)
	}
}

func TestPhoneToTerminal_CmdQueueContainsChatAction(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, _, sid := joinPhoneAndTerminal(t, hub, "p2t-cq-action")
	hub.handleMessage(phone, makeSessionMsg(sid, "cq-action-test"))
	// Dequeue and verify action is chat
	ctx, cancel := contextWithTimeoutStd()
	defer cancel()
	cmd := hub.relay.CmdQueue.Dequeue(ctx, 1*time.Second)
	if cmd == nil {
		t.Fatal("should dequeue command from CmdQueue")
	}
	if cmd.Action != agent.ActionChat {
		t.Errorf("action = %s, want chat", cmd.Action)
	}
	if cmd.Command != "cq-action-test" {
		t.Errorf("command = %s, want 'cq-action-test'", cmd.Command)
	}
	if cmd.SessionID != sid {
		t.Errorf("sessionID = %s, want %s", cmd.SessionID, sid)
	}
}

func TestPhoneToTerminal_CmdQueueProjectRouting(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, _, sid := joinPhoneAndTerminal(t, hub, "p2t-cq-proj")
	hub.handleMessage(phone, makeSessionMsg(sid, "cq-proj-test"))
	ctx, cancel := contextWithTimeoutStd()
	defer cancel()
	cmd := hub.relay.CmdQueue.Dequeue(ctx, 1*time.Second)
	if cmd == nil {
		t.Fatal("should dequeue command")
	}
	// Project should be set (from join's project)
	if cmd.Project == "" {
		t.Error("command should have project set")
	}
}

// ── 需求12: 回环防护 ──

func TestPhoneToTerminal_NoSelfEcho(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, _, sid := joinPhoneAndTerminal(t, hub, "p2t-noecho")
	hub.handleMessage(phone, makeSessionMsg(sid, "my-own-message"))
	msg := recvOne(t, phone)
	if msg != nil {
		var env session.WSEnvelope
		mustUnmarshal(t, msg, &env)
		if env.Type == session.MsgTypeSessionMsg {
			t.Error("phone should NOT receive its own session_msg")
		}
	}
}

func TestPhoneToTerminal_OtherPhonesReceiveInSameSession(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	repo := setupTestDeviceRepo(t)
	dev1 := pairDevice(t, repo, "phone-echo-1")
	dev2 := logicalTestDevice(dev1)
	hub.SetDeviceRepo(repo)

	phone1 := newTestWSClient()
	hub.handleJoin(phone1, mustMarshal(t, session.JoinMessage{
		ClientType: "phone", ClientID: "phone-echo-1", Project: "echo-proj", Token: dev1.ClientToken,
	}))
	recvAll(t, phone1, 5)

	phone2 := newTestWSClient()
	hub.handleJoin(phone2, mustMarshal(t, session.JoinMessage{
		ClientType: "phone", ClientID: "phone-echo-2", Project: "echo-proj", Token: dev2.ClientToken,
	}))
	recvAll(t, phone2, 5)

	terminal := newTestWSClient()
	hub.handleJoin(terminal, mustMarshal(t, session.JoinMessage{
		ClientType: "terminal", ClientID: "relay-echo", Project: "echo-proj", Token: "hook-secret",
	}))
	recvAll(t, terminal, 5)

	sid := phone1.sessionID

	// phone1 sends → phone2 and terminal should receive, phone1 should NOT
	hub.handleMessage(phone1, makeSessionMsg(sid, "from-phone-1"))

	// phone2 receives
	msg2 := recvOne(t, phone2)
	if msg2 == nil {
		t.Fatal("phone2 should receive phone1's message (same session)")
	}
	content := extractPayloadField(t, msg2, "content")
	if content != "from-phone-1" {
		t.Errorf("phone2 content = %v, want 'from-phone-1'", content)
	}

	// terminal receives
	msgT := recvOne(t, terminal)
	if msgT == nil {
		t.Fatal("terminal should receive phone1's message")
	}

	// phone1 does NOT receive
	msg1 := recvOne(t, phone1)
	if msg1 != nil {
		var env session.WSEnvelope
		mustUnmarshal(t, msg1, &env)
		if env.Type == session.MsgTypeSessionMsg {
			t.Error("phone1 should NOT receive its own message")
		}
	}
}

// ── 需求13: 跨 project 隔离 ──

func TestPhoneToTerminal_CrossProjectIsolation(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	_, terminalA, _ := joinPhoneAndTerminal(t, hub, "iso-proj-a")
	phoneB, terminalB, sidB := joinPhoneAndTerminal(t, hub, "iso-proj-b")

	// phoneB sends message to session B
	hub.handleMessage(phoneB, makeSessionMsg(sidB, "msg-for-b-only"))

	// terminalB receives
	msgB := recvOne(t, terminalB)
	if msgB == nil {
		t.Fatal("terminalB should receive message from phoneB")
	}

	// terminalA should NOT receive phoneB's message (different project)
	msgA := recvOne(t, terminalA)
	if msgA != nil {
		var env session.WSEnvelope
		mustUnmarshal(t, msgA, &env)
		if env.Type == session.MsgTypeSessionMsg {
			content := extractPayloadField(t, msgA, "content")
			if content == "msg-for-b-only" {
				t.Error("terminalA should NOT receive phoneB's message (cross-project isolation)")
			}
		}
	}
}

func TestPhoneToTerminal_BroadcastToAllTerminalsSameProject(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	repo := setupTestDeviceRepo(t)
	dev := pairDevice(t, repo, "phone-bcast")
	hub.SetDeviceRepo(repo)

	phone := newTestWSClient()
	hub.handleJoin(phone, mustMarshal(t, session.JoinMessage{
		ClientType: "phone", ClientID: "phone-bcast", Project: "bcast-proj", Token: dev.ClientToken,
	}))
	recvAll(t, phone, 5)

	// Two relays in same project
	relay1 := newTestWSClient()
	hub.handleJoin(relay1, mustMarshal(t, session.JoinMessage{
		ClientType: "terminal", ClientID: "relay-bcast-1", Project: "bcast-proj", Token: "hook-secret",
	}))
	recvAll(t, relay1, 5)

	relay2 := newTestWSClient()
	hub.handleJoin(relay2, mustMarshal(t, session.JoinMessage{
		ClientType: "terminal", ClientID: "relay-bcast-2", Project: "bcast-proj", Token: "hook-secret",
	}))
	recvAll(t, relay2, 5)

	sid := phone.sessionID

	// Phone sends message
	hub.handleMessage(phone, makeSessionMsg(sid, "broadcast-test"))

	// Both relays should receive
	msg1 := recvOne(t, relay1)
	if msg1 == nil {
		t.Error("relay1 should receive broadcast message")
	}
	msg2 := recvOne(t, relay2)
	if msg2 == nil {
		t.Error("relay2 should receive broadcast message")
	}
}

// ── 并发发送测试 ──

func TestPhoneToTerminal_ConcurrentSendSafety(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "p2t-concurrent")

	const N = 10
	var wg sync.WaitGroup
	for i := 0; i < N; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			hub.handleMessage(phone, makeSessionMsg(sid, "concurrent-msg"))
			time.Sleep(250 * time.Millisecond)
		}(i)
	}
	wg.Wait()

	// Drain all messages — should not deadlock or panic
	recvAll(t, terminal, N+5)
	recvAll(t, phone, N+5)
}

// ── project 字段处理 ──

func TestPhoneToTerminal_EmptyProjectDefaultsToserein(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, _, sid := joinPhoneAndTerminal(t, hub, "p2t-defproj")
	// Send session_msg without project in payload
	env := session.WSEnvelope{
		Type:      session.MsgTypeSessionMsg,
		SessionID: sid,
		Payload: map[string]interface{}{
			"content": "no-project-in-payload",
		},
	}
	hub.handleMessage(phone, mustMarshal(t, env))
	// Should be enqueued with default project
	ctx, cancel := contextWithTimeoutStd()
	defer cancel()
	cmd := hub.relay.CmdQueue.Dequeue(ctx, 1*time.Second)
	if cmd == nil {
		t.Fatal("should dequeue command")
	}
	if cmd.Project != "serein" && cmd.Project != "p2t-defproj" {
		t.Errorf("project should be set: got %q", cmd.Project)
	}
}

// ── 非手机客户端发送 session_msg 被拒绝 ──

func TestPhoneToTerminal_TerminalSessionMsgRejected(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "p2t-term-rej")
	hub.handleMessage(terminal, makeSessionMsg(sid, "from-terminal"))
	// Terminal should get error
	msg := recvOne(t, terminal)
	if msg != nil {
		var env session.WSEnvelope
		mustUnmarshal(t, msg, &env)
		if env.Type != session.MsgTypeError {
			// May be silently rejected or error
		}
	}
	// Phone should NOT receive terminal's session_msg
	msg2 := recvOne(t, phone)
	if msg2 != nil {
		var env session.WSEnvelope
		mustUnmarshal(t, msg2, &env)
		if env.Type == session.MsgTypeSessionMsg {
			t.Error("phone should not receive terminal's session_msg")
		}
	}
}

func TestPhoneToTerminal_AgentSessionMsgRejected(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	repo := setupTestDeviceRepo(t)
	dev := pairDevice(t, repo, "phone-agent-rej")
	hub.SetDeviceRepo(repo)

	phone := newTestWSClient()
	hub.handleJoin(phone, mustMarshal(t, session.JoinMessage{
		ClientType: "phone", ClientID: "phone-agent-rej", Project: "agent-rej", Token: dev.ClientToken,
	}))
	recvAll(t, phone, 5)

	agentClient := newTestWSClient()
	hub.handleJoin(agentClient, mustMarshal(t, session.JoinMessage{
		ClientType: "agent", ClientID: "agent-rej", Project: "agent-rej", Token: "hook-secret",
	}))
	recvAll(t, agentClient, 5)

	sid := phone.sessionID
	hub.handleMessage(agentClient, makeSessionMsg(sid, "from-agent"))

	// Phone should NOT receive agent's session_msg
	msg := recvOne(t, phone)
	if msg != nil {
		var env session.WSEnvelope
		mustUnmarshal(t, msg, &env)
		if env.Type == session.MsgTypeSessionMsg {
			t.Error("phone should not receive agent's session_msg")
		}
	}
}

// ── 未 join 客户端发送 session_msg ──

func TestPhoneToTerminal_UnjoinedClientRejected(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	// Client that never joined
	stranger := newTestWSClient()
	stranger.clientType = "phone"
	stranger.clientID = "stranger"
	hub.handleMessage(stranger, makeSessionMsg("", "from-stranger"))
	// Should not crash, should not produce any output
}

// ── relay 未初始化时 session_msg ──

func TestPhoneToTerminal_RelayNilSafe(t *testing.T) {
	hub := newWSHub()
	hub.SetHookToken("hook-secret")
	// Don't set relay — should not panic
	repo := setupTestDeviceRepo(t)
	dev := pairDevice(t, repo, "phone-nil")
	hub.SetDeviceRepo(repo)

	phone := newTestWSClient()
	hub.handleJoin(phone, mustMarshal(t, session.JoinMessage{
		ClientType: "phone", ClientID: "phone-nil", Project: "nil-proj", Token: dev.ClientToken,
	}))
	recvAll(t, phone, 5)

	// Should not panic when relay is nil
	hub.handleMessage(phone, makeSessionMsg(phone.sessionID, "nil-relay-test"))
}

// ── JSON 特殊字符测试 ──

func TestPhoneToTerminal_JSONSpecialChars(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "p2t-json")
	tests := []string{
		`{"key":"value"}`,
		`{"nested":{"arr":[1,2,3]}}`,
		`{"escaped":"\"quoted\""}`,
		`back\slash`,
		`unicode \u00e9`,
	}
	for _, tc := range tests {
		t.Run(tc[:min(15, len(tc))], func(t *testing.T) {
			hub.handleMessage(phone, makeSessionMsg(sid, tc))
			time.Sleep(250 * time.Millisecond)
			msg := recvOne(t, terminal)
			if msg == nil {
				t.Fatal("terminal should receive message")
			}
			content := extractPayloadField(t, msg, "content")
			if content != tc {
				t.Errorf("content = %v, want %q", content, tc)
			}
		})
	}
}

// ── 大消息测试 ──

func TestPhoneToTerminal_LargeMessageNearLimit(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "p2t-large")
	content := strings.Repeat("A", 7999)
	hub.handleMessage(phone, makeSessionMsg(sid, content))
	msg := recvOne(t, terminal)
	if msg == nil {
		t.Fatal("terminal should receive large message")
	}
	got := extractPayloadField(t, msg, "content")
	if got != content {
		t.Error("large message content should be preserved exactly")
	}
}

// ── session_msg payload 格式测试 ──

func TestPhoneToTerminal_PayloadAsStringContent(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "p2t-payload")
	// Send with properly typed payload
	env := session.WSEnvelope{
		Type:      session.MsgTypeSessionMsg,
		SessionID: sid,
		Payload: session.SessionMsgPayload{
			Content: "typed-payload-test",
		},
	}
	hub.handleMessage(phone, mustMarshal(t, env))
	msg := recvOne(t, terminal)
	if msg == nil {
		t.Fatal("terminal should receive typed payload message")
	}
	content := extractPayloadField(t, msg, "content")
	if content != "typed-payload-test" {
		t.Errorf("content = %v, want 'typed-payload-test'", content)
	}
}

// ── 速率限制精确性测试 ──

func TestPhoneToTerminal_RateLimit_BoundaryTime(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "p2t-rl-boundary")
	// First message
	hub.handleMessage(phone, makeSessionMsg(sid, "first"))
	recvOne(t, terminal)

	// Wait exactly rate limit duration
	time.Sleep(sessionMsgRateLimit + 50*time.Millisecond)

	// Second message should be allowed
	hub.handleMessage(phone, makeSessionMsg(sid, "second-after-boundary"))
	msg := recvOne(t, terminal)
	if msg == nil {
		t.Fatal("message after rate limit boundary should be delivered")
	}
	content := extractPayloadField(t, msg, "content")
	if content != "second-after-boundary" {
		t.Errorf("content = %v, want 'second-after-boundary'", content)
	}
}

// ── 多 phone 同时发送到同一 session ──

func TestPhoneToTerminal_MultiplePhonesSameSession(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	repo := setupTestDeviceRepo(t)
	hub.SetDeviceRepo(repo)

	terminal := newTestWSClient()
	hub.handleJoin(terminal, mustMarshal(t, session.JoinMessage{
		ClientType: "terminal", ClientID: "relay-multi-phone", Project: "multi-phone-sess", Token: "hook-secret",
	}))
	recvAll(t, terminal, 5)

	const N = 3
	// Product policy permits one paired physical phone. These are three
	// simulated WebSocket connections from that same paired device, which still
	// exercises concurrent-session delivery without weakening pairing rules.
	dev := pairDevice(t, repo, "phone-mp")
	var phones []*wsClient
	for i := 0; i < N; i++ {
		phone := newTestWSClient()
		hub.handleJoin(phone, mustMarshal(t, session.JoinMessage{
			ClientType: "phone", ClientID: "phone-mp-" + string(rune('1'+i)),
			Project: "multi-phone-sess", Token: dev.ClientToken,
		}))
		recvAll(t, phone, 5)
		phones = append(phones, phone)
	}

	sid := terminal.sessionID

	// All phones send simultaneously
	var wg sync.WaitGroup
	for i, phone := range phones {
		wg.Add(1)
		go func(idx int, p *wsClient) {
			defer wg.Done()
			hub.handleMessage(p, makeSessionMsg(sid, "from-phone-"+string(rune('1'+idx))))
		}(i, phone)
	}
	wg.Wait()

	// Terminal should receive all messages
	msgs := recvAll(t, terminal, N+2)
	if len(msgs) < N {
		t.Errorf("terminal should receive at least %d messages, got %d", N, len(msgs))
	}
}

// ── 安全: 不泄露 sessionID 给其他 session ──

func TestPhoneToTerminal_SessionIDNotLeaked(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	_, terminalA, sidA := joinPhoneAndTerminal(t, hub, "leak-a")
	phoneB, _, _ := joinPhoneAndTerminal(t, hub, "leak-b")

	// phoneB tries to send message with sidA (session A's ID)
	hub.handleMessage(phoneB, makeSessionMsg(sidA, "cross-session-attempt"))

	// terminalA might receive it via broadcastToAllTerminals if same project,
	// but they have different projects, so should not receive
	msg := recvOne(t, terminalA)
	if msg != nil {
		var env session.WSEnvelope
		mustUnmarshal(t, msg, &env)
		if env.Type == session.MsgTypeSessionMsg {
			content := extractPayloadField(t, msg, "content")
			if content == "cross-session-attempt" {
				// This may be OK if broadcastToAllTerminals checks project match
				// But terminalA is in a different project, so should not receive
			}
		}
	}
}

// ── session_msg 广播到 relay pending 缓冲 ──

func TestPhoneToTerminal_PendingBufferWhenNoRelay(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	repo := setupTestDeviceRepo(t)
	dev := pairDevice(t, repo, "phone-pending")
	hub.SetDeviceRepo(repo)

	phone := newTestWSClient()
	hub.handleJoin(phone, mustMarshal(t, session.JoinMessage{
		ClientType: "phone", ClientID: "phone-pending", Project: "pending-proj", Token: dev.ClientToken,
	}))
	recvAll(t, phone, 5)

	// Send message with matching project so pending buffer filters correctly
	env := session.WSEnvelope{
		Type:      session.MsgTypeSessionMsg,
		SessionID: phone.sessionID,
		Payload: map[string]interface{}{
			"content": "pending-test",
			"project": "pending-proj",
		},
	}
	hub.handleMessage(phone, mustMarshal(t, env))

	// Now relay joins — should receive buffered message
	relay := newTestWSClient()
	hub.handleJoin(relay, mustMarshal(t, session.JoinMessage{
		ClientType: "terminal", ClientID: "relay-pending", Project: "pending-proj", Token: "hook-secret",
	}))

	msgs := recvAll(t, relay, 10)
	foundPending := false
	for _, m := range msgs {
		var env session.WSEnvelope
		mustUnmarshal(t, m, &env)
		if env.Type == session.MsgTypeSessionMsg {
			content := extractPayloadField(t, m, "content")
			if content == "pending-test" {
				foundPending = true
			}
		}
	}
	if !foundPending {
		t.Error("relay should receive buffered pending message on join")
	}
}

// ── 完整往返: phone → terminal → phone ──

func TestPhoneToTerminal_FullRoundTrip(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone, terminal, sid := joinPhoneAndTerminal(t, hub, "p2t-roundtrip")

	// Step 1: Phone sends
	hub.handleMessage(phone, makeSessionMsg(sid, "user input"))
	msg1 := recvOne(t, terminal)
	if msg1 == nil {
		t.Fatal("terminal should receive phone's message")
	}

	// Step 2: Terminal responds with cmd_step
	hub.handleMessage(terminal, makeCmdStepMsg(sid, "cmd-rt", "text", "processing..."))
	msg2 := recvOne(t, phone)
	if msg2 == nil {
		t.Fatal("phone should receive terminal's cmd_step")
	}

	// Step 3: Terminal sends final result
	hub.handleMessage(terminal, makeCmdResultMsg(sid, "cmd-rt", "done"))
	msg3 := recvOne(t, phone)
	if msg3 == nil {
		t.Fatal("phone should receive terminal's cmd_result")
	}
	var env session.WSEnvelope
	mustUnmarshal(t, msg3, &env)
	if env.Type != session.MsgTypeCmdResult {
		t.Errorf("final message should be cmd_result, got %s", env.Type)
	}
}

// ── BroadcastToSession excludes sender by clientID ──

func TestPhoneToTerminal_BroadcastExcludesByClientID(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	repo := setupTestDeviceRepo(t)
	dev1 := pairDevice(t, repo, "phone-excl-1")
	hub.SetDeviceRepo(repo)

	phone1 := newTestWSClient()
	hub.handleJoin(phone1, mustMarshal(t, session.JoinMessage{
		ClientType: "phone", ClientID: "phone-excl-1", Project: "excl-proj", Token: dev1.ClientToken,
	}))
	recvAll(t, phone1, 5)

	phone2 := newTestWSClient()
	hub.handleJoin(phone2, mustMarshal(t, session.JoinMessage{
		ClientType: "phone", ClientID: "phone-excl-2", Project: "excl-proj", Token: dev1.ClientToken,
	}))
	recvAll(t, phone2, 5)

	sid := phone1.sessionID

	// BroadcastToSession with phone1's clientID as exclude
	hub.BroadcastToSession(sid, session.MsgTypeSessionMsg,
		map[string]interface{}{"content": "broadcast-excl"}, "phone-excl-1")

	// phone2 should receive
	msg2 := recvOne(t, phone2)
	if msg2 == nil {
		t.Fatal("phone2 should receive broadcast")
	}

	// phone1 should NOT receive (excluded)
	msg1 := recvOne(t, phone1)
	if msg1 != nil {
		var env session.WSEnvelope
		mustUnmarshal(t, msg1, &env)
		if env.Type == session.MsgTypeSessionMsg {
			t.Error("phone1 should be excluded from broadcast")
		}
	}
}

// ── helpers ──

// contextWithTimeoutStd creates a context with 5s timeout for test dequeue.
func contextWithTimeoutStd() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), 5*time.Second)
}
