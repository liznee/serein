package api

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"serein/internal/agent"
	"serein/internal/session"
	"serein/internal/store"
)

// setupTestWSHub creates a minimal wsHub with CmdQueue and SessionManager for handler-level tests.
func setupTestWSHub(t *testing.T, hookToken string) *wsHub {
	t.Helper()
	db, err := store.Open(":memory:")
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { db.Close() })

	hub := newWSHub()
	hub.SetHookToken(hookToken)

	cmdQueue := agent.NewQueue(20)
	sm := session.NewSessionManager(cmdQueue, hub)
	t.Cleanup(func() { sm.Stop() }) // prevent goroutine leak from cleanupLoop
	relay := &AgentRelay{
		CmdQueue:       cmdQueue,
		SessionManager: sm,
	}
	hub.SetRelay(relay)

	return hub
}

// setupTestDeviceRepo creates a DeviceRepo backed by an in-memory sqlite DB.
func setupTestDeviceRepo(t *testing.T) *store.DeviceRepo {
	t.Helper()
	db, err := store.Open(":memory:")
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	return store.NewDeviceRepo(db)
}

// pairDevice creates a device in the repo and returns the device with a valid client token.
func pairDevice(t *testing.T, repo *store.DeviceRepo, name string) *store.Device {
	t.Helper()
	token := "test-token-" + name
	dev, err := repo.Pair("id-"+name, name, token)
	if err != nil {
		t.Fatalf("Pair device %q: %v", name, err)
	}
	return dev
}

// logicalTestDevice returns a second logical phone identity for hub-only tests.
// Production pairing intentionally permits one physical phone at a time; these
// legacy transport tests still need two independently addressed WS clients to
// verify per-client routing/rate limiting. They share the already-valid test
// credential because token-to-device identity is outside the behavior under
// test here.
func logicalTestDevice(paired *store.Device) *store.Device {
	return &store.Device{ClientToken: paired.ClientToken}
}

// newTestWSClient creates a wsClient with a buffered send channel for testing.
func newTestWSClient() *wsClient {
	return &wsClient{
		send: make(chan []byte, 256),
	}
}

// recvOne reads one message from client.send with a short timeout, returning the raw bytes.
// Returns nil if no message arrives within 100ms.
func recvOne(t *testing.T, client *wsClient) []byte {
	t.Helper()
	select {
	case msg := <-client.send:
		return msg
	case <-time.After(100 * time.Millisecond):
		return nil
	}
}

// recvAll drains all messages currently in client.send, up to a maximum.
func recvAll(t *testing.T, client *wsClient, max int) [][]byte {
	t.Helper()
	var msgs [][]byte
	for i := 0; i < max; i++ {
		msg := recvOne(t, client)
		if msg == nil {
			break
		}
		msgs = append(msgs, msg)
	}
	return msgs
}

// mustMarshal marshals v to JSON and fails the test on error.
func mustMarshal(t *testing.T, v any) []byte {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return b
}

// mustUnmarshal unmarshals raw into v and fails the test on error.
func mustUnmarshal(t *testing.T, raw []byte, v any) {
	t.Helper()
	if err := json.Unmarshal(raw, v); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
}

// ── handleJoin tests ──

func TestHandleJoin_TerminalRelay(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	client := newTestWSClient()

	joinMsg := session.JoinMessage{
		SessionID:  "",
		ClientType: "terminal",
		ClientID:   "relay-test-pid",
		Project:    "test-proj",
		Token:      "hook-secret",
	}
	hub.handleJoin(client, mustMarshal(t, joinMsg))

	// Expect: join_ack
	ack := recvOne(t, client)
	if ack == nil {
		t.Fatal("expected join_ack message, got nothing")
	}
	var env session.WSEnvelope
	mustUnmarshal(t, ack, &env)
	if env.Type != session.MsgTypeJoinAck {
		t.Errorf("expected type=%q, got %q", session.MsgTypeJoinAck, env.Type)
	}
	if client.sessionID == "" {
		t.Error("client.sessionID should be set after join")
	}
	if client.clientID != "relay-test-pid" {
		t.Errorf("client.clientID want relay-test-pid, got %s", client.clientID)
	}
	if !client.relayReceiver {
		t.Error("terminal relay client should have relayReceiver=true")
	}
}

func TestHandleJoin_PhoneJoin(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")

	// Phone join without deviceRepo should be rejected (phone token validation fails)
	t.Run("phone rejected without deviceRepo", func(t *testing.T) {
		client := newTestWSClient()
		joinMsg := session.JoinMessage{
			SessionID:  "",
			ClientType: "phone",
			ClientID:   "phone-001",
			Project:    "test-proj",
			Token:      "any-token",
		}
		hub.handleJoin(client, mustMarshal(t, joinMsg))
		errMsg := recvOne(t, client)
		if errMsg == nil {
			t.Fatal("expected error message, got nothing")
		}
		var env session.WSEnvelope
		mustUnmarshal(t, errMsg, &env)
		if env.Type != session.MsgTypeError {
			t.Errorf("expected error type, got %s", env.Type)
		}
	})
}

func TestHandleJoin_InvalidClientType(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	client := newTestWSClient()

	joinMsg := session.JoinMessage{
		ClientType: "invalid-type",
		ClientID:   "test",
		Token:      "hook-secret",
	}
	hub.handleJoin(client, mustMarshal(t, joinMsg))

	errMsg := recvOne(t, client)
	if errMsg == nil {
		t.Fatal("expected error message for invalid client_type")
	}
	var env session.WSEnvelope
	mustUnmarshal(t, errMsg, &env)
	if env.Type != session.MsgTypeError {
		t.Errorf("expected error, got %s", env.Type)
	}
}

func TestHandleJoin_InvalidToken(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	client := newTestWSClient()

	joinMsg := session.JoinMessage{
		ClientType: "terminal",
		ClientID:   "relay-test",
		Project:    "test-proj",
		Token:      "wrong-token",
	}
	hub.handleJoin(client, mustMarshal(t, joinMsg))

	errMsg := recvOne(t, client)
	if errMsg == nil {
		t.Fatal("expected error message for invalid token")
	}
	var env session.WSEnvelope
	mustUnmarshal(t, errMsg, &env)
	if env.Type != session.MsgTypeError {
		t.Errorf("expected error, got %s", env.Type)
	}
}

func TestHandleJoin_RelaySetsReceiverFlag(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")

	tests := []struct {
		name       string
		clientType string
		clientID   string
		wantRelay  bool
	}{
		{name: "terminal with relay- prefix", clientType: "terminal", clientID: "relay-12345", wantRelay: true},
		{name: "terminal without relay- prefix", clientType: "terminal", clientID: "term-001", wantRelay: false},
		{name: "phone with relay- prefix", clientType: "phone", clientID: "relay-phone", wantRelay: false},
		{name: "agent with relay- prefix", clientType: "agent", clientID: "relay-agent", wantRelay: false},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			client := newTestWSClient()
			joinMsg := session.JoinMessage{
				ClientType: tc.clientType,
				ClientID:   tc.clientID,
				Project:    "test-proj",
				Token:      "hook-secret",
			}
			hub.handleJoin(client, mustMarshal(t, joinMsg))
			if client.relayReceiver != tc.wantRelay {
				t.Errorf("relayReceiver = %v, want %v", client.relayReceiver, tc.wantRelay)
			}
		})
	}
}

func TestHandleJoin_RelayWithPendingMessages(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")

	// Buffer a pending message first by calling broadcastToAllTerminals with no relay connected.
	hub.broadcastToAllTerminals(session.MsgTypeSessionMsg,
		map[string]interface{}{"content": "pending-msg"},
		"", "", "test-proj")

	// Now a relay joins -- should receive join_ack + history + pending
	client := newTestWSClient()
	joinMsg := session.JoinMessage{
		ClientType: "terminal",
		ClientID:   "relay-pending-test",
		Project:    "test-proj",
		Token:      "hook-secret",
	}
	hub.handleJoin(client, mustMarshal(t, joinMsg))

	msgs := recvAll(t, client, 5)
	if len(msgs) < 2 {
		t.Fatalf("expected at least 2 messages (join_ack + pending), got %d", len(msgs))
	}
	// First message should be join_ack
	var first session.WSEnvelope
	mustUnmarshal(t, msgs[0], &first)
	if first.Type != session.MsgTypeJoinAck {
		t.Errorf("first message should be join_ack, got %s", first.Type)
	}
	// Last message should contain the pending content
	var last session.WSEnvelope
	mustUnmarshal(t, msgs[len(msgs)-1], &last)
	if last.Type != session.MsgTypeSessionMsg {
		t.Errorf("last message should be session_msg (pending), got %s", last.Type)
	}
}

func TestHandleJoin_SessionReuseByProject(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")

	client1 := newTestWSClient()
	client2 := newTestWSClient()

	joinMsg1 := session.JoinMessage{
		ClientType: "terminal",
		ClientID:   "relay-001",
		Project:    "shared-proj",
		Token:      "hook-secret",
	}
	hub.handleJoin(client1, mustMarshal(t, joinMsg1))
	recvAll(t, client1, 3)

	joinMsg2 := session.JoinMessage{
		ClientType: "terminal",
		ClientID:   "relay-002",
		Project:    "shared-proj",
		Token:      "hook-secret",
	}
	hub.handleJoin(client2, mustMarshal(t, joinMsg2))

	if client1.sessionID == "" || client2.sessionID == "" {
		t.Fatal("both clients should have session IDs")
	}
	if client1.sessionID != client2.sessionID {
		t.Errorf("same project should share session: %s vs %s", client1.sessionID, client2.sessionID)
	}
}

// ── handleSessionMsg tests ──

func TestHandleSessionMsg_NonPhoneRejected(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")

	terminal := newTestWSClient()
	termJoin := session.JoinMessage{
		ClientType: "terminal",
		ClientID:   "relay-test",
		Project:    "test-proj",
		Token:      "hook-secret",
	}
	hub.handleJoin(terminal, mustMarshal(t, termJoin))
	recvAll(t, terminal, 3)

	// Terminal tries to send session_msg -> should be rejected
	env := session.WSEnvelope{
		Type: session.MsgTypeSessionMsg,
		Payload: session.SessionMsgPayload{
			Content: "hello from terminal",
		},
	}
	hub.handleSessionMsg(terminal, mustMarshal(t, env))

	errMsg := recvOne(t, terminal)
	if errMsg == nil {
		t.Fatal("expected error for non-phone session_msg")
	}
	var errEnv session.WSEnvelope
	mustUnmarshal(t, errMsg, &errEnv)
	if errEnv.Type != session.MsgTypeError {
		t.Errorf("expected error, got %s", errEnv.Type)
	}
}

func TestHandleSessionMsg_PhoneSendsMessage(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	repo := setupTestDeviceRepo(t)
	dev := pairDevice(t, repo, "phone-msg")
	hub.SetDeviceRepo(repo)

	phone := newTestWSClient()
	phoneJoin := session.JoinMessage{
		ClientType: "phone",
		ClientID:   "phone-msg",
		Project:    "test-proj",
		Token:      dev.ClientToken,
	}
	hub.handleJoin(phone, mustMarshal(t, phoneJoin))
	recvAll(t, phone, 3)

	if phone.sessionID == "" {
		t.Fatal("phone should have sessionID after join")
	}

	// Now phone sends session_msg
	sessionMsg := session.WSEnvelope{
		SessionID: phone.sessionID,
		Type:      session.MsgTypeSessionMsg,
		Payload: map[string]interface{}{
			"content": "hello from phone",
			"project": "test-proj",
		},
	}
	hub.handleSessionMsg(phone, mustMarshal(t, sessionMsg))

	// Verify the message was enqueued (PendingCount > 0 indicates enqueued).
	if hub.relay.CmdQueue.PendingCount() == 0 {
		t.Fatal("expected pending command after session_msg enqueue")
	}
}

func TestHandleSessionMsg_EmptyContent(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	repo := setupTestDeviceRepo(t)
	dev := pairDevice(t, repo, "phone-empty")
	hub.SetDeviceRepo(repo)

	phone := newTestWSClient()
	phoneJoin := session.JoinMessage{
		ClientType: "phone",
		ClientID:   "phone-empty-test",
		Project:    "test-proj",
		Token:      dev.ClientToken,
	}
	hub.handleJoin(phone, mustMarshal(t, phoneJoin))
	recvAll(t, phone, 3)

	// Send session_msg with empty content
	sessionMsg := session.WSEnvelope{
		SessionID: phone.sessionID,
		Type:      session.MsgTypeSessionMsg,
		Payload: map[string]interface{}{
			"content": "",
			"project": "test-proj",
		},
	}
	hub.handleSessionMsg(phone, mustMarshal(t, sessionMsg))

	// No message should be in send channel (silently ignored)
	msg := recvOne(t, phone)
	if msg != nil {
		t.Error("empty content session_msg should not produce any output")
	}
}

func TestHandleSessionMsg_ContentTooLong(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	repo := setupTestDeviceRepo(t)
	dev := pairDevice(t, repo, "phone-long")
	hub.SetDeviceRepo(repo)

	phone := newTestWSClient()
	phoneJoin := session.JoinMessage{
		ClientType: "phone",
		ClientID:   "phone-long-msg",
		Project:    "test-proj",
		Token:      dev.ClientToken,
	}
	hub.handleJoin(phone, mustMarshal(t, phoneJoin))
	recvAll(t, phone, 3)

	// Content over 8000 chars
	longContent := make([]byte, 8001)
	for i := range longContent {
		longContent[i] = 'x'
	}
	sessionMsg := session.WSEnvelope{
		SessionID: phone.sessionID,
		Type:      session.MsgTypeSessionMsg,
		Payload: map[string]interface{}{
			"content": string(longContent),
			"project": "test-proj",
		},
	}
	hub.handleSessionMsg(phone, mustMarshal(t, sessionMsg))

	// Message should NOT be enqueued (content too long)
	if hub.relay.CmdQueue.PendingCount() > 0 {
		t.Error("overly long content should not be enqueued")
	}
}

func TestHandleSessionMsg_NonPrintableContent(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	repo := setupTestDeviceRepo(t)
	dev := pairDevice(t, repo, "phone-np")
	hub.SetDeviceRepo(repo)

	phone := newTestWSClient()
	phoneJoin := session.JoinMessage{
		ClientType: "phone",
		ClientID:   "phone-nonprint",
		Project:    "test-proj",
		Token:      dev.ClientToken,
	}
	hub.handleJoin(phone, mustMarshal(t, phoneJoin))
	recvAll(t, phone, 3)

	// Content with control character
	badContent := "hello\x00world"
	sessionMsg := session.WSEnvelope{
		SessionID: phone.sessionID,
		Type:      session.MsgTypeSessionMsg,
		Payload: map[string]interface{}{
			"content": badContent,
			"project": "test-proj",
		},
	}
	hub.handleSessionMsg(phone, mustMarshal(t, sessionMsg))

	// Message should NOT be enqueued (non-printable)
	if hub.relay.CmdQueue.PendingCount() > 0 {
		t.Error("non-printable content should not be enqueued")
	}
}

func TestHandleSessionMsg_ShellMetacharAllowed(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	repo := setupTestDeviceRepo(t)
	dev := pairDevice(t, repo, "phone-meta")
	hub.SetDeviceRepo(repo)

	phone := newTestWSClient()
	phoneJoin := session.JoinMessage{
		ClientType: "phone",
		ClientID:   "phone-meta",
		Project:    "test-proj",
		Token:      dev.ClientToken,
	}
	hub.handleJoin(phone, mustMarshal(t, phoneJoin))
	recvAll(t, phone, 3)

	// Content with shell metacharacters (;) — now allowed since session_msg
	sessionMsg := session.WSEnvelope{
		SessionID: phone.sessionID,
		Type:      session.MsgTypeSessionMsg,
		Payload: map[string]interface{}{
			"content": "hello; rm -rf /",
			"project": "test-proj",
		},
	}
	hub.handleSessionMsg(phone, mustMarshal(t, sessionMsg))

	// Should BE enqueued (shell metacharacters now allowed in session_msg).
	if hub.relay.CmdQueue.PendingCount() == 0 {
		t.Error("content with shell metacharacters should be enqueued (chat goes to PTY stdin, not shell)")
	}
}

// ── re-join relayReceiver reset test ──

func TestHandleJoin_RejoinResetsRelayReceiver(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	repo := setupTestDeviceRepo(t)
	dev := pairDevice(t, repo, "phone-rejoin")
	hub.SetDeviceRepo(repo)

	// First join as a relay terminal → relayReceiver should be true.
	client := newTestWSClient()
	relayJoin := session.JoinMessage{
		ClientType: "terminal",
		ClientID:   "relay-rejoin",
		Project:    "proj-a",
		Token:      "hook-secret",
	}
	hub.handleJoin(client, mustMarshal(t, relayJoin))
	recvAll(t, client, 3)
	if !client.relayReceiver {
		t.Fatal("relay terminal should have relayReceiver=true after first join")
	}

	// Buffer a pending message for proj-b (no relay in proj-b yet).
	hub.broadcastToAllTerminals(session.MsgTypeSessionMsg,
		map[string]interface{}{"content": "should-not-flush-to-phone"},
		"", "", "proj-b")

	// Re-join same connection as a phone (different project) — relayReceiver
	// must be reset to false so pending relay messages are NOT flushed to it.
	phoneJoin := session.JoinMessage{
		ClientType: "phone",
		ClientID:   "phone-rejoin",
		Project:    "proj-b",
		Token:      dev.ClientToken,
	}
	hub.handleJoin(client, mustMarshal(t, phoneJoin))
	recvAll(t, client, 5) // join_ack + maybe history

	if client.relayReceiver {
		t.Error("relayReceiver must be reset to false after re-joining as phone")
	}
	// Verify the buffered relay message was NOT delivered to this phone client.
	for i := 0; i < 5; i++ {
		msg := recvOne(t, client)
		if msg == nil {
			break
		}
		var env session.WSEnvelope
		mustUnmarshal(t, msg, &env)
		if env.Type == session.MsgTypeSessionMsg {
			t.Error("phone re-join should NOT receive buffered relay session_msg")
		}
	}
}

// ── broadcastToAllTerminals tests ──

func TestBroadcastToAllTerminals_DeliversToMatchingRelays(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")

	relay1 := newTestWSClient()
	relay1Join := session.JoinMessage{
		ClientType: "terminal",
		ClientID:   "relay-001",
		Project:    "proj-a",
		Token:      "hook-secret",
	}
	hub.handleJoin(relay1, mustMarshal(t, relay1Join))
	recvAll(t, relay1, 3)

	relay2 := newTestWSClient()
	relay2Join := session.JoinMessage{
		ClientType: "terminal",
		ClientID:   "relay-002",
		Project:    "proj-b",
		Token:      "hook-secret",
	}
	hub.handleJoin(relay2, mustMarshal(t, relay2Join))
	recvAll(t, relay2, 3)

	// Broadcast to proj-a: only relay1 should receive the message.
	hub.broadcastToAllTerminals(
		session.MsgTypeSessionMsg,
		map[string]interface{}{"content": "msg-for-proj-a"},
		"", "", "proj-a",
	)

	msg1 := recvOne(t, relay1)
	if msg1 == nil {
		t.Error("relay1 (proj-a) should have received the broadcast")
	}
	msg2 := recvOne(t, relay2)
	if msg2 != nil {
		t.Error("relay2 (proj-b) should NOT have received proj-a broadcast")
	}
}

func TestBroadcastToAllTerminals_ExcludesSenderSession(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	repo := setupTestDeviceRepo(t)
	dev := pairDevice(t, repo, "phone-excl")
	hub.SetDeviceRepo(repo)

	phone := newTestWSClient()
	phoneJoin := session.JoinMessage{
		ClientType: "phone",
		ClientID:   "phone-001",
		Project:    "shared-proj",
		Token:      dev.ClientToken,
	}
	hub.handleJoin(phone, mustMarshal(t, phoneJoin))
	recvAll(t, phone, 3)

	relay := newTestWSClient()
	relayJoin := session.JoinMessage{
		ClientType: "terminal",
		ClientID:   "relay-001",
		Project:    "shared-proj",
		Token:      "hook-secret",
	}
	hub.handleJoin(relay, mustMarshal(t, relayJoin))
	recvAll(t, relay, 3)

	hub.broadcastToAllTerminals(
		session.MsgTypeSessionMsg,
		map[string]interface{}{"content": "cross-session"},
		"", "", "shared-proj",
	)

	msg := recvOne(t, relay)
	if msg == nil {
		t.Error("relay should receive the broadcast")
	}
}

func TestBroadcastToAllTerminals_EmptyProjectSkipped(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")

	relay := newTestWSClient()
	relayJoin := session.JoinMessage{
		ClientType: "terminal",
		ClientID:   "relay-test",
		Project:    "test-proj",
		Token:      "hook-secret",
	}
	hub.handleJoin(relay, mustMarshal(t, relayJoin))
	recvAll(t, relay, 3)

	hub.broadcastToAllTerminals(
		session.MsgTypeSessionMsg,
		map[string]interface{}{"content": "no-project"},
		"", "", "",
	)

	msg := recvOne(t, relay)
	if msg != nil {
		t.Error("broadcast with empty project should be skipped")
	}
}

func TestBroadcastToAllTerminals_BufferedWhenNoRelay(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")

	hub.broadcastToAllTerminals(
		session.MsgTypeSessionMsg,
		map[string]interface{}{"content": "buffer-me"},
		"", "", "buffered-proj",
	)

	// Now a relay joins and should receive the buffered message
	relay := newTestWSClient()
	relayJoin := session.JoinMessage{
		ClientType: "terminal",
		ClientID:   "relay-buffer-test",
		Project:    "buffered-proj",
		Token:      "hook-secret",
	}
	hub.handleJoin(relay, mustMarshal(t, relayJoin))

	msgs := recvAll(t, relay, 5)
	if len(msgs) < 2 {
		t.Fatalf("expected at least 2 messages (join_ack + buffered), got %d", len(msgs))
	}

	var lastTwo session.WSEnvelope
	mustUnmarshal(t, msgs[len(msgs)-1], &lastTwo)
	if lastTwo.Type == session.MsgTypeSessionMsg {
		return
	}
	if len(msgs) >= 3 {
		var prev session.WSEnvelope
		mustUnmarshal(t, msgs[len(msgs)-2], &prev)
		if prev.Type == session.MsgTypeSessionMsg {
			return
		}
	}
	t.Error("no buffered session_msg found among relay join messages")
}

// ── Integration: phone sends, relay receives ──

func TestPhoneToRelayFlow(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	repo := setupTestDeviceRepo(t)
	dev := pairDevice(t, repo, "flow-phone")
	hub.SetDeviceRepo(repo)

	phone := newTestWSClient()
	phoneJoin := session.JoinMessage{
		ClientType: "phone",
		ClientID:   "phone-flow-test",
		Project:    "flow-proj",
		Token:      dev.ClientToken,
	}
	hub.handleJoin(phone, mustMarshal(t, phoneJoin))
	recvAll(t, phone, 3)

	relay := newTestWSClient()
	relayJoin := session.JoinMessage{
		ClientType: "terminal",
		ClientID:   "relay-flow-test",
		Project:    "flow-proj",
		Token:      "hook-secret",
	}
	hub.handleJoin(relay, mustMarshal(t, relayJoin))
	recvAll(t, relay, 3)

	// Phone sends message
	sessionMsg := session.WSEnvelope{
		SessionID: phone.sessionID,
		Type:      session.MsgTypeSessionMsg,
		Payload: map[string]interface{}{
			"content": "phone-to-relay message",
			"project": "flow-proj",
		},
	}
	hub.handleSessionMsg(phone, mustMarshal(t, sessionMsg))

	// Relay should receive the message
	relayMsg := recvOne(t, relay)
	if relayMsg == nil {
		t.Fatal("relay should have received the phone's session_msg")
	}
	var relayEnv session.WSEnvelope
	mustUnmarshal(t, relayMsg, &relayEnv)
	if relayEnv.Type != session.MsgTypeSessionMsg {
		t.Errorf("relay received wrong type: %s, want session_msg", relayEnv.Type)
	}
}

// ── validateWSToken tests ──

func TestValidateWSToken(t *testing.T) {
	repo := setupTestDeviceRepo(t)
	dev := pairDevice(t, repo, "auth-phone")

	hub := setupTestWSHub(t, "hook-secret")
	hub.SetDeviceRepo(repo)

	tests := []struct {
		name       string
		clientType string
		token      string
		want       bool
	}{
		{name: "terminal valid hook", clientType: "terminal", token: "hook-secret", want: true},
		{name: "terminal wrong token", clientType: "terminal", token: "wrong", want: false},
		{name: "terminal empty token", clientType: "terminal", token: "", want: false},
		{name: "phone valid device token", clientType: "phone", token: dev.ClientToken, want: true},
		{name: "phone wrong token", clientType: "phone", token: "wrong", want: false},
		{name: "phone empty token", clientType: "phone", token: "", want: false},
		{name: "agent valid hook", clientType: "agent", token: "hook-secret", want: true},
		{name: "agent wrong token", clientType: "agent", token: "wrong", want: false},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := hub.validateWSToken(tc.clientType, tc.token)
			if got != tc.want {
				t.Errorf("validateWSToken(%q, %q) = %v, want %v", tc.clientType, tc.token, got, tc.want)
			}
		})
	}
}

// ── sendToClient tests ──

func TestSendToClient_Normal(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	client := newTestWSClient()

	hub.sendToClient(client, session.WSEnvelope{
		Type: session.MsgTypeJoinAck,
	})
	msg := recvOne(t, client)
	if msg == nil {
		t.Error("sendToClient should deliver message")
	}
}

// ── Concurrency safety test ──

func TestHandleJoinConcurrent(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")

	const N = 10
	done := make(chan struct{}, N)

	for i := 0; i < N; i++ {
		go func(id int) {
			client := newTestWSClient()
			joinMsg := session.JoinMessage{
				ClientType: "terminal",
				ClientID:   "relay-concurrent-" + string(rune('0'+id)),
				Project:    "concurrent-proj",
				Token:      "hook-secret",
			}
			hub.handleJoin(client, mustMarshal(t, joinMsg))
			recvAll(t, client, 3)
			done <- struct{}{}
		}(i)
	}

	timeout := time.After(3 * time.Second)
	received := 0
	for i := 0; i < N; i++ {
		select {
		case <-done:
			received++
		case <-timeout:
			t.Fatalf("timed out waiting for goroutines: %d/%d completed", received, N)
		}
	}
}

// Ensure the WebSocket upgrader is imported and usable (compile check).
var _ *websocket.Conn

// ── sanitizeLog tests ──

func TestSanitizeLog_MasksToken(t *testing.T) {
	input := `{"type":"join","token":"secret-hook-token","client_type":"terminal"}`
	out := sanitizeLog(input)
	if strings.Contains(out, "secret-hook-token") {
		t.Errorf("sanitizeLog should mask token, got: %s", out)
	}
	if !strings.Contains(out, `"token":"***"`) {
		t.Errorf("sanitizeLog should contain masked token, got: %s", out)
	}
}

func TestSanitizeLog_MasksTokenWithSpaces(t *testing.T) {
	input := `{"type":"join", "token" : "my-secret"}`
	out := sanitizeLog(input)
	if strings.Contains(out, "my-secret") {
		t.Errorf("sanitizeLog should mask token with spaces, got: %s", out)
	}
}

func TestSanitizeLog_RemovesControlChars(t *testing.T) {
	input := "hello\x00world\x07bell\x1bescape"
	out := sanitizeLog(input)
	if strings.Contains(out, "\x00") || strings.Contains(out, "\x07") || strings.Contains(out, "\x1b") {
		t.Errorf("sanitizeLog should remove control chars, got: %q", out)
	}
	// Tab, newline, carriage return should be preserved
	input2 := "line1\nline2\ttab\rreturn"
	out2 := sanitizeLog(input2)
	if !strings.Contains(out2, "\n") || !strings.Contains(out2, "\t") || !strings.Contains(out2, "\r") {
		t.Errorf("sanitizeLog should preserve \n \t \r, got: %q", out2)
	}
}

func TestSanitizeLog_PreservesCJK(t *testing.T) {
	input := "你好世界\x00日本語"
	out := sanitizeLog(input)
	if !strings.Contains(out, "你好世界") || !strings.Contains(out, "日本語") {
		t.Errorf("sanitizeLog should preserve CJK characters, got: %s", out)
	}
}

// ── peekClientType tests ──

func TestPeekClientType(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want string
	}{
		{name: "terminal join", raw: `{"type":"join","client_type":"terminal"}`, want: "terminal"},
		{name: "phone join", raw: `{"type":"join","client_type":"phone"}`, want: "phone"},
		{name: "agent join", raw: `{"type":"join","client_type":"agent"}`, want: "agent"},
		{name: "non-join message", raw: `{"type":"heartbeat"}`, want: ""},
		{name: "invalid JSON", raw: `{not json}`, want: ""},
		{name: "empty", raw: ``, want: ""},
		{name: "missing client_type", raw: `{"type":"join"}`, want: ""},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := peekClientType([]byte(tc.raw))
			if got != tc.want {
				t.Errorf("peekClientType(%q) = %q, want %q", tc.raw, got, tc.want)
			}
		})
	}
}

// ── handlePermDecision tests ──

func TestHandlePermDecision_NonPhoneRejected(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	terminal := newTestWSClient()
	terminal.clientType = "terminal"
	terminal.sessionID = "sess-001"

	env := session.WSEnvelope{
		Type: session.MsgTypePermDecision,
		Payload: session.PermDecisionPayload{
			CmdID:    "cmd-001",
			Decision: "allow",
		},
	}
	hub.handlePermDecision(terminal, mustMarshal(t, env))
	// Non-phone client should not produce any output
	msg := recvOne(t, terminal)
	if msg != nil {
		t.Error("terminal should not produce output for perm_decision")
	}
}

func TestHandleModeSwitch_InvalidMode(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone := newTestWSClient()
	phone.clientType = "phone"
	phone.sessionID = "sess-001"

	env := session.WSEnvelope{
		Type: session.MsgTypeModeSwitch,
		Payload: session.ModeSwitchPayload{
			Mode: "invalid-mode",
		},
	}
	hub.handleModeSwitch(phone, mustMarshal(t, env))

	errMsg := recvOne(t, phone)
	if errMsg == nil {
		t.Fatal("expected error for invalid mode")
	}
	var errEnv session.WSEnvelope
	mustUnmarshal(t, errMsg, &errEnv)
	if errEnv.Type != session.MsgTypeError {
		t.Errorf("expected error type, got %s", errEnv.Type)
	}
}

func TestHandleModeSwitch_ValidMode(t *testing.T) {
	hub := setupTestWSHub(t, "hook-secret")
	phone := newTestWSClient()
	phone.clientType = "phone"
	phone.sessionID = "sess-001"
	phone.clientID = "phone-001"

	// Also need a second client in the session to verify broadcast
	relay := newTestWSClient()
	relay.clientType = "terminal"
	relay.clientID = "relay-001"
	relay.sessionID = "sess-001"

	hub.mu.Lock()
	hub.clientsBySession["sess-001"] = []*wsClient{phone, relay}
	hub.mu.Unlock()

	env := session.WSEnvelope{
		Type: session.MsgTypeModeSwitch,
		Payload: session.ModeSwitchPayload{
			Mode: session.PermModeSafeYolo,
		},
	}
	hub.handleModeSwitch(phone, mustMarshal(t, env))

	// Relay should receive the mode_switch broadcast
	msg := recvOne(t, relay)
	if msg == nil {
		t.Fatal("relay should receive mode_switch broadcast")
	}
	var relayEnv session.WSEnvelope
	mustUnmarshal(t, msg, &relayEnv)
	if relayEnv.Type != session.MsgTypeModeSwitch {
		t.Errorf("expected mode_switch, got %s", relayEnv.Type)
	}
}
