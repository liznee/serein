// Package api provides HTTP and WebSocket handlers for serein.
package api

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"log"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"

	"serein/internal/agent"
	"serein/internal/session"
	"serein/internal/store"
)

// wsHub manages WebSocket connections and routes messages to session clients.
type wsHub struct {
	mu               sync.RWMutex
	clients          map[*wsClient]bool
	clientsBySession map[string][]*wsClient  // sessionID -> clients
	relay            *AgentRelay             // provides BroadcastToSession via SessionManager
	sessionManager   *session.SessionManager // snapshot of relay.SessionManager for lock-free reads
	hookToken        string                  // HOOK_TOKEN for agent/terminal authentication
	deviceRepo       *store.DeviceRepo       // CLIENT_TOKEN for phone authentication

	// Buffered messages for relays that haven't joined yet.
	// When a relay joins, pending messages for its project are flushed to it. Max 50 entries.
	relayPendingMsgs []pendingRelayMsg

	// Dedicated relay client set for O(1) broadcast lookup.
	// Avoids scanning clientsBySession in broadcastToAllTerminals/BroadcastToRelays.
	// Updated atomically with h.mu write lock in handleJoin and removeClientFromSession.
	relayClients map[*wsClient]bool

	// Prevents resource exhaustion from concurrent WS connections. HTTP-level
	// rateLimit middleware provides additional protection.
	wsConnCount int64 // current connections (atomic)
	maxConns    int64 // max concurrent connections

	// Per-client message rate limiting for session_msg path. Protects against
	// malicious or buggy phone clients flooding the CmdQueue. HTTP rateLimit
	// middleware only protects REST endpoints; WS upgrade bypasses it, so we
	// enforce per-client limits here.
	rateLimitMu     sync.Mutex
	rateLimitTimers map[string]time.Time // clientID -> last allowed message timestamp

	// Global permission mode set by phone via mode_switch. Read by approval
	// handler to auto-approve/deny based on mode (yolo, safe_yolo, etc.).
	permMode   string
	permModeMu sync.RWMutex
}

// wsClient represents a single WebSocket connection.
type wsClient struct {
	conn          *websocket.Conn
	send          chan []byte
	done          chan struct{} // closed by read goroutine on exit to promptly stop write goroutine
	sessionID     string        // assigned on join
	clientID      string        // unique client identifier
	clientType    string        // "terminal" | "phone" | "agent"
	relayReceiver bool          // receives relay session messages; set for "relay-" prefix clients
	project       string        // project context from join, used for session routing
}

// pendingRelayMsg 缓冲待转发给 relay 的消息及其所属项目。
// relay 加入时按 project 过滤，防止跨项目消息泄漏。
type pendingRelayMsg struct {
	project string
	data    []byte
}

// Read deadline tuning per client type.
//
// phone clients do not send application-level heartbeats (see
// harmony/.../WebSocketClient.ets — only sends on user action). Mobile networks
// and HarmonyOS's webSocket library may not auto-reply to server pings reliably,
// so a tight 90s deadline causes frequent disconnects. Use a longer 5-minute
// deadline for phone; the write goroutine still sends pings every 30s, and any
// pong (if the client library responds) or app message extends the deadline.
//
// terminal/agent clients (serein.mjs relay) send a {type:"heartbeat"} every
// 25s, so 90s is comfortable and gives 3x margin.
const (
	phoneReadDeadline  = 5 * time.Minute
	clientReadDeadline = 90 * time.Second
	writeDeadline      = 15 * time.Second
	pingInterval       = 30 * time.Second
	clientSendBuf      = 64
	// maxReadLimit caps the size of a single inbound WS message. gorilla/websocket
	// has no default limit; without this an authenticated or unauthenticated peer
	// can force OOM by streaming arbitrarily large frames. 64 KiB comfortably fits
	// the largest legitimate message (join + 8000-char session_msg payload, well
	// under 16 KiB JSON-encoded) while bounding per-connection memory.
	maxReadLimit = 64 * 1024

	// relayPendingMsgsMax 单 relay 待转发消息缓冲上限。超过上限时 FIFO 丢弃最旧。
	relayPendingMsgsMax = 50

	// sessionMsgRateLimit 手机端 session_msg 发送频率上限。
	// WS 升级后 handleMessage 直接走 handleSessionMsg，绕过了 HTTP 路由层的 rateLimit
	// 中间件。此限制防止单 phone 客户端快速发送大量 session_msg 造成 CmdQueue 膨胀。
	sessionMsgRateLimit = 200 * time.Millisecond // 最多 5 条/秒
)

// readDeadlineFor returns the read deadline appropriate for the client type.
func readDeadlineFor(clientType string) time.Duration {
	if clientType == "phone" {
		return phoneReadDeadline
	}
	return clientReadDeadline
}

var upgrader = websocket.Upgrader{
	ReadBufferSize:  4096,
	WriteBufferSize: 4096,
	CheckOrigin: func(r *http.Request) bool {
		origin := r.Header.Get("Origin")
		if origin == "" {
			return true // Non-browser clients (Node.js relay, Python agent, Flutter native)
		}
		// Verify origin.Host matches Host header to prevent host-spoofing.
		originURL, err := url.Parse(origin)
		if err != nil {
			log.Printf("[WS] rejected WebSocket origin (parse error): %s", origin)
			return false
		}
		if originURL.Host == r.Host {
			return true
		}
		log.Printf("[WS] rejected WebSocket origin: %s (host: %s)", origin, r.Host)
		return false
	},
}

func newWSHub() *wsHub {
	return &wsHub{
		clients:          make(map[*wsClient]bool),
		clientsBySession: make(map[string][]*wsClient),
		relayClients:     make(map[*wsClient]bool),
		maxConns:         100, // default: max 100 concurrent WS connections
		rateLimitTimers:  make(map[string]time.Time),
		permMode:         session.PermModeDefault,
	}
}

// SetRelay injects AgentRelay for BroadcastToSession via SessionManager.
// Also snapshots SessionManager for lock-free access in getSessionManager.
func (h *wsHub) SetRelay(r *AgentRelay) {
	h.relay = r
	if r != nil {
		h.sessionManager = r.SessionManager
	}
}

// SetHookToken sets HOOK_TOKEN for agent/terminal WS auth.
func (h *wsHub) SetHookToken(token string) {
	h.hookToken = token
}

// SetDeviceRepo sets DeviceRepo for phone WS auth.
func (h *wsHub) SetDeviceRepo(repo *store.DeviceRepo) {
	h.deviceRepo = repo
}

// validateWSToken validates WS connection token.
//
// All client types MUST present a valid token — the WS channel carries session
// messages (cmd_step/cmd_result/session_msg) that include real-time terminal
// output and user commands. An unauthenticated client that guessed a session_id
// could inject commands (via session_msg — relay CmdQueue) and read other
// participants' terminal output (via broadcastToSession), so empty tokens are
// rejected for every client type.
//
//   - phone: validated against CLIENT_TOKEN via deviceRepo (never HOOK_TOKEN).
//   - agent/terminal: validated against HOOK_TOKEN using constant-time compare.
//
// HOOK_TOKEN comparison uses subtle.ConstantTimeCompare to prevent timing
// side-channel attacks that could allow byte-by-byte token brute force. This
// matches the HTTP layer (auth.go hookAuth) which also uses ConstantTimeCompare.
func (h *wsHub) validateWSToken(clientType, token string) bool {
	if token == "" {
		log.Printf("[WS] rejected %s connection: missing token", clientType)
		return false
	}
	if clientType == "phone" {
		// Phone: validate against CLIENT_TOKEN (never HOOK_TOKEN).
		if h.deviceRepo == nil {
			log.Printf("[WS] rejected phone connection: deviceRepo not initialized")
			return false
		}
		authCtx, authCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer authCancel()
		dev, err := h.deviceRepo.ByClientToken(authCtx, token)
		if err != nil {
			log.Printf("[WS] device token lookup error: %v", err)
			return false
		}
		if dev != nil {
			return true
		}
		log.Printf("[WS] rejected phone connection: invalid CLIENT_TOKEN")
		return false
	}
	// agent/terminal: validate against HOOK_TOKEN using constant-time compare
	// to prevent timing side-channels (consistent with auth.go hookAuth).
	if h.hookToken != "" && subtle.ConstantTimeCompare([]byte(token), []byte(h.hookToken)) == 1 {
		return true
	}
	log.Printf("[WS] rejected %s connection: invalid token", clientType)
	return false
}

// HandleWS upgrades HTTP to WebSocket and starts read/write goroutines.
//
// Token is sent in the join message body (not URL) to avoid leaking in
// access logs and process command lines. This follows the same approach
// as local_agent.py and serein.mjs WS connections.
func (h *wsHub) HandleWS(w http.ResponseWriter, r *http.Request) {
	// Check maxConns before upgrading to prevent fd exhaustion.
	// Atomic reservation: increment first, then check the result. If at capacity,
	// decrement and reject. This avoids the TOCTOU race of Load-then-Add.
	if atomic.AddInt64(&h.wsConnCount, 1) > h.maxConns {
		atomic.AddInt64(&h.wsConnCount, -1)
		http.Error(w, "too many connections", http.StatusServiceUnavailable)
		return
	}

	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		atomic.AddInt64(&h.wsConnCount, -1)
		log.Printf("[WS] ws upgrade: %v", err)
		return
	}
	// Cap inbound message size. gorilla/websocket defaults to unlimited reads;
	// without this a peer can force OOM by sending a single oversized frame.
	conn.SetReadLimit(maxReadLimit)
	client := &wsClient{
		conn: conn,
		send: make(chan []byte, clientSendBuf),
		done: make(chan struct{}),
	}

	h.mu.Lock()
	h.clients[client] = true
	h.mu.Unlock()

	// Detect client type early by peeking for the join message within a short
	// window. This lets us apply the correct read deadline before the read
	// loop begins. If no join arrives in time, default to the short deadline
	// (safer — prevents unauthenticated idle clients from holding fds).
	peekDeadline := 30 * time.Second
	conn.SetReadDeadline(time.Now().Add(peekDeadline))
	_, peekBytes, peekErr := conn.ReadMessage()
	if peekErr != nil {
		// Client never sent join (or connection broke). Clean up and exit
		// before starting the long-lived read/write goroutines.
		atomic.AddInt64(&h.wsConnCount, -1)
		h.mu.Lock()
		delete(h.clients, client)
		h.mu.Unlock()
		conn.Close()
		return
	}
	// Determine deadline from join's client_type (default to short if unknown).
	peekType := peekClientType(peekBytes)
	conn.SetReadDeadline(time.Now().Add(readDeadlineFor(peekType)))
	conn.SetPongHandler(func(string) error {
		conn.SetReadDeadline(time.Now().Add(readDeadlineFor(peekType)))
		return nil
	})

	// Start read goroutine.
	go func() {
		defer func() {
			if r := recover(); r != nil {
				log.Printf("[WS] panic in read goroutine: %v", r)
			}
			// Signal write goroutine to exit promptly and prevent further
			// sends into client.send (which would silently drop after the
			// write goroutine stops consuming).
			close(client.done)
			atomic.AddInt64(&h.wsConnCount, -1)
			h.mu.Lock()
			delete(h.clients, client)
			if client.sessionID != "" {
				h.removeClientFromSession(client)
			}
			h.mu.Unlock()
			conn.Close()
		}()
		// Process the already-read peek message first.
		conn.SetReadDeadline(time.Now().Add(readDeadlineFor(peekType)))
		h.handleMessage(client, peekBytes)
		for {
			_, msgBytes, err := conn.ReadMessage()
			if err != nil {
				break
			}
			// Extend read deadline on ANY received message (application-level
			// heartbeat from serein.mjs or pong from the library both refresh it).
			conn.SetReadDeadline(time.Now().Add(readDeadlineFor(peekType)))
			h.handleMessage(client, msgBytes)
		}
	}()

	// Start write goroutine.
	go func() {
		ticker := time.NewTicker(pingInterval)
		defer func() {
			if r := recover(); r != nil {
				log.Printf("[WS] panic in write goroutine: %v", r)
			}
			ticker.Stop()
			conn.Close()
		}()
		for {
			select {
			case <-client.done:
				// Read goroutine exited; stop writing. Closing done guarantees
				// we never block waiting on a ticker after the connection is gone.
				return
			case message, ok := <-client.send:
				if !ok {
					conn.WriteMessage(websocket.CloseMessage, []byte{})
					return
				}
				conn.SetWriteDeadline(time.Now().Add(writeDeadline))
				if err := conn.WriteMessage(websocket.TextMessage, message); err != nil {
					return
				}
			case <-ticker.C:
				conn.SetWriteDeadline(time.Now().Add(writeDeadline))
				if err := conn.WriteMessage(websocket.PingMessage, nil); err != nil {
					return
				}
			}
		}
	}()
}

// peekClientType reads the client_type from a join message's JSON without
// fully validating it. Returns "" if the message is malformed or not a join.
// Used only to select the read deadline before the read loop begins.
func peekClientType(raw []byte) string {
	var j struct {
		Type       string `json:"type"`
		ClientType string `json:"client_type"`
	}
	if json.Unmarshal(raw, &j) != nil {
		return ""
	}
	if j.Type != session.MsgTypeJoin {
		return ""
	}
	return j.ClientType
}

// handleMessage dispatches WS messages by type.
func (h *wsHub) handleMessage(client *wsClient, raw []byte) {
	var env session.WSEnvelope
	if err := json.Unmarshal(raw, &env); err != nil {
		log.Printf("[WS] handleMessage: JSON parse error: %v (raw[:%d]=%s)", err, min(len(raw), 200), sanitizeLog(string(raw[:min(len(raw), 200)])))
		return
	}
	switch env.Type {
	case session.MsgTypeJoin:
		h.handleJoin(client, raw)
	case session.MsgTypeSessionMsg:
		h.handleSessionMsg(client, raw)
	case session.MsgTypeCmdStep:
		h.handleCmdStep(client, &env)
	case session.MsgTypeCmdResult:
		h.handleCmdResult(client, &env)
	case session.MsgTypeHeartbeat:
		// Application-level heartbeat from serein.mjs (every 25s). The read
		// deadline has already been refreshed by ReadMessage above; nothing
		// else to do. Logged at info level for observability during
		// disconnect debugging.
		log.Printf("[WS] heartbeat from %s (type=%s session=%s)",
			safeClientID(client.clientID), client.clientType, client.sessionID)
	case session.MsgTypePermDecision:
		h.handlePermDecision(client, raw)
	case session.MsgTypeModeSwitch:
		h.handleModeSwitch(client, raw)
	default:
		// Unknown message type: silently ignored.
	}
}

// broadcastToSession sends a message to all clients in the same session,
// excluding the sender. Used for cmd_step and cmd_result messages so all
// session participants see real-time updates (e.g., mobile app receives output).
//
// TOCTOU race prevention: Copy clients list under RLock, then send outside the lock.
// Even if removeClientFromSession removes the client concurrently, the *wsClient
// pointer remains valid (goroutine defer cleanup only after send channel closes).
// Using select with default on client.send prevents blocking on full channels.
// This avoids holding RLock through sends and allows removeClientFromSession
// to modify h.clients and h.clientsBySession without deadlock since the
// wsClient is only cleaned up in the goroutine defer, not here.
func (h *wsHub) broadcastToSession(client *wsClient, env *session.WSEnvelope, msgType string) {
	envOut := session.WSEnvelope{
		Type:      msgType,
		SessionID: client.sessionID,
		Payload:   env.Payload,
		Source:    env.Source,
		Seq:       env.Seq,
		Timestamp: env.Timestamp,
	}
	raw, err := json.Marshal(envOut)
	if err != nil {
		return
	}
	h.mu.RLock()
	// Copy client list under RLock to prevent TOCTOU, then unlock before sending.
	clients := make([]*wsClient, len(h.clientsBySession[client.sessionID]))
	copy(clients, h.clientsBySession[client.sessionID])
	h.mu.RUnlock()
	for _, c := range clients {
		if c.clientID == client.clientID {
			continue
		}
		select {
		case c.send <- raw:
		default:
			log.Printf("[WS] send channel full, dropping %s to %s (session=%s)", msgType, safeClientID(c.clientID), client.sessionID)
		}
	}
}

// handleCmdStep broadcasts cmd_step to the session (real-time output to mobile app).
// Only terminal and agent clients may send cmd_step; phone clients are rejected
// to prevent forged terminal output injection into the session.
func (h *wsHub) handleCmdStep(client *wsClient, env *session.WSEnvelope) {
	if client.clientType != "terminal" && client.clientType != "agent" {
		log.Printf("[WS] rejected cmd_step from non-terminal client: type=%s id=%s", client.clientType, safeClientID(client.clientID))
		return
	}
	if h.relay != nil {
		h.relay.recordCollaborationStep(client.sessionID, env.Payload)
	}
	h.recordFinalSessionEvent(client, env)
	h.broadcastToSession(client, env, session.MsgTypeCmdStep)
}

// recordFinalSessionEvent 只持久化协议能明确判定的最终状态。
// tool_use / 空白或未知 stop reason 都不推测为完成或失败。
func (h *wsHub) recordFinalSessionEvent(client *wsClient, env *session.WSEnvelope) {
	if h.relay == nil || h.relay.CmdQueue == nil || h.relay.CmdQueue.ActivityRepo() == nil {
		return
	}
	payload, ok := env.Payload.(map[string]interface{})
	if !ok || payload["event"] != session.EventTurnEnd {
		return
	}
	detail, _ := payload["content"].(string)
	status := ""
	switch {
	case detail == "end_turn" || detail == "stop_sequence":
		status = "completed"
	case detail == "max_tokens" || strings.HasPrefix(detail, "aborted:") || strings.HasPrefix(detail, "error:"):
		status = "failed"
	default:
		return
	}
	if err := h.relay.CmdQueue.ActivityRepo().SaveSessionEvent(client.sessionID, env.Seq, client.project, status, detail); err != nil {
		log.Printf("[WS] save session event failed: %v", err)
	}
}

// handleCmdResult broadcasts cmd_result to the session (final result to mobile app).
// Only terminal and agent clients may send cmd_result; phone clients are rejected
// to prevent forged terminal output injection into the session.
func (h *wsHub) handleCmdResult(client *wsClient, env *session.WSEnvelope) {
	if client.clientType != "terminal" && client.clientType != "agent" {
		log.Printf("[WS] rejected cmd_result from non-terminal client: type=%s id=%s", client.clientType, safeClientID(client.clientID))
		return
	}
	h.broadcastToSession(client, env, session.MsgTypeCmdResult)
}

// handleSessionMsg processes phone -> PTY messages, validates, then enqueues + broadcasts.
func (h *wsHub) handleSessionMsg(client *wsClient, raw []byte) {
	// Copy to local variable to avoid nil dereference panic if h.relay is
	// modified concurrently (e.g. during shutdown). Go race detector warns
	// on repeated reads of shared pointer fields.
	relay := h.relay
	if relay == nil || relay.CmdQueue == nil {
		log.Printf("[WS] handleSessionMsg: relay not initialized, dropping session_msg from id=%s", safeClientID(client.clientID))
		return
	}

	// Per-client rate limiting: protect CmdQueue from flooding by a malicious
	// or buggy phone client. The HTTP rateLimit middleware covers REST endpoints
	// but WS messages bypass it, so we enforce limits here.
	if client.clientID != "" && !h.checkSessionMsgRateLimit(client.clientID) {
		log.Printf("[WS] session_msg rate limited: id=%s", safeClientID(client.clientID))
		return
	}

	// Only phone clients can send session messages (injected into PTY).
	if client.clientType != "phone" {
		log.Printf("[WS] rejected session_msg from non-phone client: type=%s id=%s", client.clientType, safeClientID(client.clientID))
		h.sendError(client, "only phone clients can send session messages")
		return
	}
	var env session.WSEnvelope
	if err := json.Unmarshal(raw, &env); err != nil {
		log.Printf("[WS] handleSessionMsg: JSON parse error: %v (raw[:%d]=%s)", err, min(len(raw), 200), sanitizeLog(string(raw[:min(len(raw), 200)])))
		return
	}
	payload, ok := env.Payload.(map[string]interface{})
	if !ok {
		return
	}

	// Extract project and sessionID early — both plaintext path and E2E
	// path need them for routing. project is always sent in plaintext
	// (it's routing metadata, not sensitive content).
	project, _ := payload["project"].(string)
	if project == "" {
		project = "serein"
	}
	sessionID := client.sessionID
	if sessionID == "" {
		sm := h.getSessionManager()
		if sm != nil {
			s := sm.GetOrCreateSession(project)
			if s != nil {
				sessionID = s.ID
				client.sessionID = sessionID
			}
		}
	}

	// E2E: if content_enc is present, the phone is using end-to-end encryption.
	// The server must NOT parse or validate the encrypted content — it's an
	// opaque base64 blob. We still broadcast it to the session (relay decrypts)
	// and enqueue a placeholder for the CmdQueue safety net.
	contentEnc, hasEnc := payload["content_enc"].(string)
	if hasEnc && contentEnc != "" {
		// Broadcast the encrypted message to session participants as-is.
		// The relay (serein.mjs) will decrypt content_enc and forward to PTY.
		if sessionID != "" {
			h.BroadcastToSession(sessionID, session.MsgTypeSessionMsg, env.Payload, client.clientID)
		}
		// Enqueue a placeholder for the CmdQueue safety net. The encrypted
		// content cannot be executed directly; the relay's WS path handles
		// delivery. This prevents the CmdQueue from storing plaintext.
		cmd := &agent.Command{
			Action:    agent.ActionChat,
			Project:   project,
			Command:   "[e2e-encrypted]",
			SessionID: sessionID,
		}
		relay.CmdQueue.EnqueueOnly(cmd)
		log.Printf("[WS] session_msg (e2e) queued: project=%s session=%s enc_len=%d",
			project, sessionID[:min(8, len(sessionID))], len(contentEnc))

		// Broadcast to all relay terminals (same as plaintext path).
		h.broadcastToAllTerminals(session.MsgTypeSessionMsg, env.Payload, client.clientID, sessionID, project)
		return
	}

	content, _ := payload["content"].(string)
	if content == "" {
		return
	}
	// Length and printable check (same as HTTP validateCmdRequest).
	// NOTE: shell metachar check is intentionally SKIPPED for session_msg.
	// In relay mode, session_msg is written directly to claude.exe PTY stdin
	// via term.write(), not executed as a shell command. The HTTP exec path
	// (validateCmdRequest) still enforces containsShellMeta for shell commands.
	// Skipping here prevents legitimate chat messages containing ; | & etc.
	// from being rejected.
	if len(content) > 8000 {
		log.Printf("[WS] session_msg content too long: %d chars (max 8000)", len(content))
		return
	}
	if !isPrintable(content) {
		log.Printf("[WS] session_msg content contains non-printable characters")
		return
	}

	// Broadcast to the same session (terminal/interactive clients within this session).
	if sessionID != "" {
		h.BroadcastToSession(sessionID, session.MsgTypeSessionMsg, env.Payload, client.clientID)
	}

	// Always enqueue via CmdQueue for reliability. GetHistory already filters
	// ActionChat results (manager.go GetHistory), so this won't pollute history.
	// The WS broadcastToSession above handles the real-time path; CmdQueue enqueue
	// [CMDEXEC] session_msg 入 CmdQueue 队列，最终由 Python agent 或 relay PTY 执行
	// is a safety net for the tiny window when relay WS disconnects between
	// BroadcastToSession and defer cleanup.
	cmd := &agent.Command{
		Action:    agent.ActionChat,
		Project:   project,
		Command:   content,
		SessionID: sessionID,
	}
	relay.CmdQueue.EnqueueOnly(cmd)
	log.Printf("[WS] session_msg queued (safety net): project=%s session=%s content_len=%d", project, sessionID[:min(8, len(sessionID))], len(content))

	// Broadcast to all relay terminals (excluding the same-session relay,
	// which already received the message via BroadcastToSession above).
	h.broadcastToAllTerminals(session.MsgTypeSessionMsg, env.Payload, client.clientID, sessionID, project)
}

// broadcastToAllTerminals sends a phone message to all relay terminals (not just
// those in the same session). This ensures the relay PTY receives messages even
// when the phone and relay are in different sessions.
//
// Only relayReceiver clients (terminal with "relay-" prefix) with matching project
// receive the broadcast. Non-relay terminals are excluded to prevent duplicate
// session_id propagation. If no relay is connected, the message is buffered in
// relayPendingMsgs (max 50), flushed on next relay join.
//
// Security: project filtering prevents cross-project message leakage. CLIENT_TOKEN
// alone does not guarantee relay ownership per session.
//
// TOCTOU: Copy relay list under RLock. handleJoin/removeClientFromSession run
// under write lock and may modify clientsBySession concurrently.
func (h *wsHub) broadcastToAllTerminals(msgType string, data any, excludeClientID string, excludeSessionID string, project string) {
	// Skip broadcast when project is empty to prevent legacy clients without project
	// from matching all relays.
	if project == "" {
		log.Printf("[WS] broadcastToAllTerminals skipped: empty project (type=%s)", msgType)
		return
	}
	env := session.WSEnvelope{
		Type:    msgType,
		Payload: data,
	}
	raw, err := json.Marshal(env)
	if err != nil {
		return
	}

	// TOCTOU: Copy relay client list under RLock. Uses dedicated relayClients map
	// instead of scanning clientsBySession, providing O(relay-count) lookup.
	h.mu.RLock()
	targets := make([]*wsClient, 0, len(h.relayClients))
	hasRelayInExcludedSession := false
	for c := range h.relayClients {
		// Filter conditions:
		// 1) Not the sender's own client
		// 2) Not the sender's own session (already delivered via BroadcastToSession)
		// 3) Same project to prevent cross-project leakage
		if c.clientID == excludeClientID {
			continue
		}
		if c.project != project {
			continue
		}
		if c.sessionID == excludeSessionID {
			hasRelayInExcludedSession = true // BroadcastToSession already covered this relay
			continue
		}
		targets = append(targets, c)
	}
	h.mu.RUnlock()

	sent := false
	for _, c := range targets {
		select {
		case c.send <- raw:
			sent = true
		default:
			log.Printf("[WS] send channel full, dropping relay broadcast to %s (session=%s)", safeClientID(c.clientID), c.sessionID)
		}
	}

	// Buffer only if no relay received the message at all:
	// - No relay in other sessions received it via broadcastToAllTerminals (!sent)
	// - AND no relay in the excluded session received it via BroadcastToSession
	//   (!hasRelayInExcludedSession, checked in handleSessionMsg before calling us)
	if !sent && !hasRelayInExcludedSession && msgType == session.MsgTypeSessionMsg {
		h.mu.Lock()
		h.relayPendingMsgs = append(h.relayPendingMsgs, pendingRelayMsg{project: project, data: raw})

		if len(h.relayPendingMsgs) > relayPendingMsgsMax {
			// FIFO: drop the oldest message when buffer exceeds limit
			h.relayPendingMsgs = h.relayPendingMsgs[1:]
		}
		h.mu.Unlock()
	}
}

// handleJoin processes a join request and adds the client to a session.
func (h *wsHub) handleJoin(client *wsClient, raw []byte) {
	join, err := parseAndValidateJoin(h, client, raw)
	if err != nil {
		return
	}
	sm, err := setupJoinSession(h, client, join)
	if err != nil {
		return
	}
	pending := registerJoinClient(h, client, join)

	// First send join_ack (relay uses this to set joinAckReceived=true).
	ack := session.WSEnvelope{
		Type:      session.MsgTypeJoinAck,
		SessionID: join.SessionID,
		Payload: session.JoinAckPayload{
			ClientID:  join.ClientID,
			SessionID: join.SessionID,
		},
	}
	h.sendToClient(client, ack)

	// Then send history messages.
	history := sm.GetHistory(join.SessionID, 50)
	if history != nil {
		histEnv := session.WSEnvelope{
			Type:      session.MsgTypeHistory,
			SessionID: join.SessionID,
			Payload: session.HistoryPayload{
				Messages: history,
			},
		}
		h.sendToClient(client, histEnv)
	}

	// Finally flush buffered messages — relay has received join_ack,
	// joinAckReceived=true, so it will correctly process session_msg instead of dropping.
	if len(pending) > 0 {
		for _, msg := range pending {
			select {
			case client.send <- msg:
			default:
				log.Printf("[WS] relay pending channel full, dropping buffered message to %s", safeClientID(client.clientID))
			}
		}
		log.Printf("[WS] flushed %d pending messages to relay %s (session=%s)", len(pending), safeClientID(client.clientID), safeClientID(join.SessionID))
	}

	// Notify phone clients that a relay terminal joined — they can update
	// project online/agentRunning status without HTTP polling.
	if client.relayReceiver {
		h.notifyRelayStateChange("relay_joined", join.Project)
	}
}

// parseAndValidateJoin parses the join message, validates client_type and token.
// Returns the parsed join message or an error (error is always sent to client).
func parseAndValidateJoin(h *wsHub, client *wsClient, raw []byte) (*session.JoinMessage, error) {
	var join session.JoinMessage
	if err := json.Unmarshal(raw, &join); err != nil {
		h.sendError(client, "invalid join message")
		return nil, err
	}
	if join.ClientID == "" {
		join.ClientID = "c-" + time.Now().Format("150405.000000")
	}

	// Validate token + client_type against valid types (agent, terminal, phone).
	if join.ClientType != "agent" && join.ClientType != "terminal" && join.ClientType != "phone" {
		log.Printf("[WS] rejected join: invalid client_type=%s", join.ClientType)
		h.sendError(client, "invalid client_type")
		return nil, errValidation
	}
	if !h.validateWSToken(join.ClientType, join.Token) {
		h.sendError(client, "unauthorized")
		return nil, errValidation
	}
	return &join, nil
}

// setupJoinSession ensures a session exists for the join request.
// Calls JoinSession on the SessionManager. Returns the SessionManager or error.
func setupJoinSession(h *wsHub, client *wsClient, join *session.JoinMessage) (*session.SessionManager, error) {
	sm := h.getSessionManager()
	if sm == nil {
		h.sendError(client, "session manager not initialized")
		return nil, errSession
	}

	// Create session if not specified: join includes project for session routing.
	if join.SessionID == "" {
		project := join.Project
		if project == "" {
			project = "serein"
		}
		join.Project = project // write back so client.project stores the resolved value
		s := sm.GetOrCreateSession(project)
		if s != nil {
			join.SessionID = s.ID
		} else {
			h.sendError(client, "failed to create session")
			return nil, errSession
		}
	}
	sm.JoinSession(join.SessionID, join.ClientID, join.ClientType)
	return sm, nil
}

// registerJoinClient registers the client in clientsBySession under write lock.
// Handles re-join cleanup, relayReceiver flag, and pending message buffering.
// Returns pending relay messages to flush after the lock is released.
func registerJoinClient(h *wsHub, client *wsClient, join *session.JoinMessage) [][]byte {
	// Register client in clientsBySession map under write lock so handleSessionMsg
	// and broadcastToSession can safely RLock to read the list.
	// sessionID is set here so broadcast and session_msg routing find it atomically.
	h.mu.Lock()
	// Re-join cleanup: if the client was previously in another session (e.g. phone
	// switching projects), remove it from the old session's client list first.
	// Otherwise the client lingers in the old list, receiving stale broadcasts
	// until the old session is cleaned up by staleness timeout.
	if client.sessionID != "" && client.sessionID != join.SessionID {
		h.removeClientFromSession(client)
	}
	// Reset relayReceiver before re-evaluating: a connection that previously joined
	// as a relay terminal (relayReceiver=true) and is now re-joining as a different
	// clientType (e.g. phone) must not retain the stale flag, or the pending-msg
	// flush below would deliver buffered relay messages to a non-relay client.
	// removeClientFromSession already deleted it from relayClients, but the boolean
	// field on the struct persists, so reset it explicitly here.
	client.relayReceiver = false
	client.sessionID = join.SessionID
	client.clientID = join.ClientID
	client.clientType = join.ClientType
	client.project = join.Project

	// Mark relayReceiver if client is a terminal with "relay-" prefix in clientID.
	// This ensures only relay terminals (not phones or agents) receive broadcast messages.
	// Condition: clientType == "terminal" AND clientID starts with "relay-".
	if join.ClientType == "terminal" && strings.HasPrefix(join.ClientID, "relay-") {
		client.relayReceiver = true
		h.relayClients[client] = true
	}

	h.clientsBySession[join.SessionID] = append(h.clientsBySession[join.SessionID], client)
	var pending [][]byte
	var remaining []pendingRelayMsg
	if client.relayReceiver && len(h.relayPendingMsgs) > 0 {
		for _, pm := range h.relayPendingMsgs {
			if pm.project == client.project {
				pending = append(pending, pm.data)
			} else {
				remaining = append(remaining, pm)
			}
		}
		h.relayPendingMsgs = remaining
	}
	h.mu.Unlock()
	return pending
}

// Sentinel errors for join flow control (not exported, never sent to client).
var errValidation = &joinError{"validation failed"}
var errSession = &joinError{"session setup failed"}

type joinError struct{ msg string }

func (e *joinError) Error() string { return e.msg }

// tokenFieldRe matches "token":"<value>" (with optional spaces around colon) in JSON-like
// strings. Used by sanitizeLog to prevent HOOK_TOKEN/CLIENT_TOKEN from appearing in logs.
// Also handles truncated JSON (missing trailing quote) to cover the attack scenario where
// a malformed join message leaks the token into the error log.
var tokenFieldRe = regexp.MustCompile(`"token"\s*:\s*"[^"]*"?`)

// sanitizeLog replaces C0 control characters and DEL with '.' to prevent log injection
// via CR/LF or other control characters embedded in WebSocket message payloads.
// Also masks "token" JSON field values to prevent credential leakage in error logs.
// Preserves CJK characters and all printable Unicode (aligned with serein.mjs sanitizeLog).
func sanitizeLog(s string) string {
	// Mask token fields first (before control char sanitization) to prevent
	// HOOK_TOKEN/CLIENT_TOKEN from appearing in server logs, even in truncated JSON.
	s = tokenFieldRe.ReplaceAllString(s, `"token":"***"`)
	return strings.Map(func(r rune) rune {
		// C0 control chars: 0x00-0x08, 0x0B, 0x0C, 0x0E-0x1F, and DEL 0x7F
		if r < 0x20 && r != '\t' && r != '\n' && r != '\r' || r == 0x7f {
			return '.'
		}
		return r
	}, s)
}

// sendToClient sends a WSEnvelope to a single client.
func (h *wsHub) sendToClient(client *wsClient, env session.WSEnvelope) {
	raw, err := json.Marshal(env)
	if err != nil {
		return
	}
	select {
	case client.send <- raw:
	default:
		log.Printf("[WS] send channel full, dropping %s to %s", env.Type, safeClientID(client.clientID))
	}
}

// sendError sends an error message to a client.
func (h *wsHub) sendError(client *wsClient, message string) {
	env := session.WSEnvelope{
		Type:  session.MsgTypeError,
		Error: message,
	}
	h.sendToClient(client, env)
}

// removeClientFromSession removes a client from clientsBySession.
// Must be called with h.mu write lock held (from defer in read goroutine).
// broadcastToSession uses RLock so this can run concurrently.
//
// Reconnection race: when a phone client disconnects and immediately reconnects
// with the same clientID, the OLD read goroutine's defer (this function) may
// run AFTER the NEW connection's handleJoin has re-added the client to the
// session. We check for an existing replacement (same clientID, different
// pointer) before calling LeaveSession, preventing the old defer from
// incorrectly removing the new connection's session membership.
func (h *wsHub) removeClientFromSession(client *wsClient) {
	if client.sessionID == "" {
		return
	}
	clients := h.clientsBySession[client.sessionID]
	// Check if a replacement client (same clientID, different *wsClient) exists.
	// Do this BEFORE removing this client, so we can detect the replacement.
	hasReplacement := false
	for _, c := range clients {
		if c != client && c.clientID == client.clientID {
			hasReplacement = true
			break
		}
	}
	// Remove this client's pointer from the list.
	for i, c := range clients {
		if c == client {
			h.clientsBySession[client.sessionID] = append(clients[:i], clients[i+1:]...)
			break
		}
	}
	if len(h.clientsBySession[client.sessionID]) == 0 {
		delete(h.clientsBySession, client.sessionID)
	}
	// Notify SessionManager only if no replacement client exists.
	// Otherwise, the replacement's handleJoin already called JoinSession,
	// and LeaveSession would incorrectly remove the replacement's membership.
	if !hasReplacement {
		if sm := h.getSessionManager(); sm != nil {
			sm.LeaveSession(client.sessionID, client.clientID)
		}
	}
	delete(h.relayClients, client) // no-op if not a relay
	h.removeRateLimitEntry(client.clientID)

	// Notify phone clients if a relay terminal left — they can update
	// project online/agentRunning status without HTTP polling.
	// Must be called within the write lock (we're already in removeClientFromSession
	// which is called with h.mu held). notifyRelayStateChange uses RLock internally
	// but BroadcastToPhones needs to read h.clients — deadlock risk if called under Write lock.
	// Instead, defer the notification to after the lock is released.
	wasRelay := client.relayReceiver
	leftProject := client.project
	if wasRelay {
		// Schedule notification after lock release to avoid deadlock.
		// Using a goroutine is safe here — removeClientFromSession is called from
		// the read goroutine's defer, and the write lock will be released by then.
		go h.notifyRelayStateChange("relay_left", leftProject)
	}
}

// checkSessionMsgRateLimit checks if the client has exceeded the session_msg
// rate limit. Returns true if the message should be allowed.
func (h *wsHub) checkSessionMsgRateLimit(clientID string) bool {
	h.rateLimitMu.Lock()
	defer h.rateLimitMu.Unlock()
	last, ok := h.rateLimitTimers[clientID]
	now := time.Now()
	if ok && now.Sub(last) < sessionMsgRateLimit {
		return false
	}
	h.rateLimitTimers[clientID] = now
	return true
}

// removeRateLimitEntry cleans up the rate limit tracking for a disconnected client,
// preventing the map from leaking memory over time.
func (h *wsHub) removeRateLimitEntry(clientID string) {
	if clientID == "" {
		return
	}
	h.rateLimitMu.Lock()
	delete(h.rateLimitTimers, clientID)
	h.rateLimitMu.Unlock()
}

// handlePermDecision processes permission decisions from phone clients
// (allow/deny a tool call). Only phone clients may send perm_decision.
func (h *wsHub) handlePermDecision(client *wsClient, raw []byte) {
	if client.clientType != "phone" {
		log.Printf("[WS] rejected perm_decision from non-phone client: type=%s id=%s", client.clientType, safeClientID(client.clientID))
		return
	}
	var env session.WSEnvelope
	if err := json.Unmarshal(raw, &env); err != nil {
		log.Printf("[WS] handlePermDecision: JSON parse error: %v", err)
		return
	}
	payload, ok := env.Payload.(map[string]interface{})
	if !ok {
		return
	}
	cmdID, _ := payload["cmd_id"].(string)
	decision, _ := payload["decision"].(string)
	if cmdID == "" || (decision != "allow" && decision != "deny") {
		log.Printf("[WS] perm_decision invalid: cmd_id=%s decision=%s", cmdID, decision)
		return
	}
	// Broadcast the decision to terminal/agent clients in the session.
	h.broadcastToSession(client, &env, session.MsgTypePermDecision)
	log.Printf("[WS] perm_decision: cmd=%s decision=%s from=%s", cmdID, decision, safeClientID(client.clientID))
}

// handleModeSwitch processes mode switch requests from phone clients.
// Validates the new mode and broadcasts to all session participants.
func (h *wsHub) handleModeSwitch(client *wsClient, raw []byte) {
	if client.clientType != "phone" {
		log.Printf("[WS] rejected mode_switch from non-phone client: type=%s id=%s", client.clientType, safeClientID(client.clientID))
		return
	}
	var env session.WSEnvelope
	if err := json.Unmarshal(raw, &env); err != nil {
		log.Printf("[WS] handleModeSwitch: JSON parse error: %v", err)
		return
	}
	payload, ok := env.Payload.(map[string]interface{})
	if !ok {
		return
	}
	mode, _ := payload["mode"].(string)
	if !session.IsValidPermissionMode(mode) {
		log.Printf("[WS] mode_switch invalid mode: %s", mode)
		h.sendError(client, "invalid permission mode")
		return
	}
	h.broadcastToSession(client, &env, session.MsgTypeModeSwitch)

	// Store the mode globally so approval_handler can use it for EvaluatePermission.
	h.permModeMu.Lock()
	h.permMode = mode
	h.permModeMu.Unlock()

	log.Printf("[WS] mode_switch: mode=%s from=%s session=%s", mode, safeClientID(client.clientID), client.sessionID)
}

// GetPermissionMode returns the current global permission mode set by the phone.
// Defaults to PermModeDefault if never set.
func (h *wsHub) GetPermissionMode() string {
	h.permModeMu.RLock()
	defer h.permModeMu.RUnlock()
	if h.permMode == "" {
		return session.PermModeDefault
	}
	return h.permMode
}

// HasRelayForProject checks if any relay terminal is connected for the given project.
// Used by approval_handler to decide whether to send ntfy push notifications:
// if a relay (CLI) is open, approvals go through WS inline; ntfy is only for background mode.
func (h *wsHub) HasRelayForProject(project string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for c := range h.relayClients {
		if c.project == project {
			return true
		}
	}
	return false
}

// getSessionManager returns the SessionManager snapshot.
// Uses the snapshot field set during SetRelay (happens-before any WS connections)
// instead of reading h.relay directly, avoiding a data race without requiring
// a read lock on every call (which would conflict with removeClientFromSession's write lock).
func (h *wsHub) getSessionManager() *session.SessionManager {
	return h.sessionManager
}

// safeClientID returns a truncated client ID for logging, never panicking
// on short/empty IDs. Used everywhere we previously wrote client.clientID[:min(...)].
func safeClientID(id string) string {
	if len(id) > 8 {
		return id[:8]
	}
	return id
}

// Broadcast sends a JSON message to ALL connected clients (any session).
//
// Uses the same copy-then-send pattern as broadcastToSession/BroadcastToRelays:
// copy the client set under RLock, then send outside the lock. Holding RLock
// across the send loop risks lock-ordering deadlock if the read goroutine's
// defer (which takes the write lock) fires concurrently on a slow client whose
// send channel happens to be full and the select were ever changed to block.
func (h *wsHub) Broadcast(msgType string, data interface{}) {
	payload := map[string]interface{}{
		"type": msgType,
		"data": data,
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		return
	}
	h.mu.RLock()
	clients := make([]*wsClient, 0, len(h.clients))
	for c := range h.clients {
		clients = append(clients, c)
	}
	h.mu.RUnlock()
	for _, client := range clients {
		select {
		case client.send <- raw:
		default:
			log.Printf("[WS] send channel full, dropping broadcast to %s", safeClientID(client.clientID))
		}
	}
}

// BroadcastToSession sends a message to all clients in a specific session.
// Implemented via session.BroadcastHub.
//
// TOCTOU: Uses RLock like broadcastToSession for safe concurrent access.
func (h *wsHub) BroadcastToSession(sessionID, msgType string, data any, excludeClientID string) {
	env := session.WSEnvelope{
		Type:      msgType,
		SessionID: sessionID,
		Payload:   data,
	}
	raw, err := json.Marshal(env)
	if err != nil {
		return
	}
	h.mu.RLock()
	var clients []*wsClient
	if list, ok := h.clientsBySession[sessionID]; ok {
		clients = make([]*wsClient, len(list))
		copy(clients, list)
	}
	h.mu.RUnlock()
	for _, c := range clients {
		if excludeClientID != "" && c.clientID == excludeClientID {
			continue
		}
		select {
		case c.send <- raw:
		default:
			log.Printf("[WS] send channel full, dropping session broadcast to %s (session=%s)", safeClientID(c.clientID), sessionID)
		}
	}
}

// BroadcastToRelays sends a message to ALL relay receivers across all sessions.
// Unlike broadcastToSession which is limited to one session, this targets every
// connected relay regardless of session ID.
//
// TOCTOU: Uses RLock to copy relay list, then sends outside the lock.
// The relay retain map (relayPendingMsgs) ensures no message loss during relay joins.
func (h *wsHub) BroadcastToRelays(msgType string, data any) {
	env := session.WSEnvelope{
		Type:    msgType,
		Payload: data,
	}
	raw, err := json.Marshal(env)
	if err != nil {
		return
	}
	h.mu.RLock()
	relays := make([]*wsClient, 0, len(h.relayClients))
	for c := range h.relayClients {
		relays = append(relays, c)
	}
	h.mu.RUnlock()
	for _, c := range relays {
		select {
		case c.send <- raw:
		default:
			log.Printf("[WS] send channel full, dropping relay broadcast to %s", safeClientID(c.clientID))
		}
	}
}

// BroadcastToPhones sends a message to ALL connected phone clients (any session).
// Used for state_update and approval_update notifications that are relevant to phones
// but not to relay/terminal clients. Uses the same copy-then-send pattern as Broadcast.
func (h *wsHub) BroadcastToPhones(msgType string, data any) {
	env := session.WSEnvelope{
		Type:    msgType,
		Payload: data,
	}
	raw, err := json.Marshal(env)
	if err != nil {
		return
	}
	h.mu.RLock()
	clients := make([]*wsClient, 0, len(h.clients))
	for c := range h.clients {
		if c.clientType == "phone" {
			clients = append(clients, c)
		}
	}
	h.mu.RUnlock()
	for _, client := range clients {
		select {
		case client.send <- raw:
		default:
			log.Printf("[WS] send channel full, dropping phone broadcast to %s", safeClientID(client.clientID))
		}
	}
}

// notifyRelayStateChange broadcasts a state_update message to phone clients
// when a relay terminal joins or leaves. Includes the current running projects
// so phones can update project status without polling.
func (h *wsHub) notifyRelayStateChange(event string, project string) {
	running := h.connectedRelayProjects()
	payload := map[string]interface{}{
		"event":   event,
		"project": project,
		"running": running,
	}
	h.BroadcastToPhones(session.MsgTypeStateUpdate, payload)
	log.Printf("[WS] state_update: event=%s project=%s running=%v phones=%d", event, project, running, len(running))
}

// connectedRelayProjects returns the project set represented by live relay
// WebSocket clients. A state_update must not reuse AgentRelay.lastOutput here:
// that heartbeat cache can still say "running" for up to one heartbeat after
// the user closes the relay terminal.
func (h *wsHub) connectedRelayProjects() []string {
	h.mu.RLock()
	defer h.mu.RUnlock()

	seen := make(map[string]bool)
	running := make([]string, 0, len(h.relayClients))
	for client := range h.relayClients {
		if client.project == "" || seen[client.project] {
			continue
		}
		seen[client.project] = true
		running = append(running, client.project)
	}
	return running
}

// GetSessionClients returns all clients in a session.
func (h *wsHub) GetSessionClients(sessionID string) []*wsClient {
	h.mu.RLock()
	defer h.mu.RUnlock()
	clients := h.clientsBySession[sessionID]
	out := make([]*wsClient, len(clients))
	copy(out, clients)
	return out
}
