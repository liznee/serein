package api

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"

	"serein/internal/remote"
	"serein/internal/store"
)

const (
	remoteWSMaxMessage = 320 * 1024
	remoteWSSendBuffer = 32
	remoteWSMaxConns   = 30
	remoteWSJoinWait   = 5 * time.Second
	remoteWSPingEvery  = 25 * time.Second
)

type remoteWSHub struct {
	mu         sync.RWMutex
	clients    map[string]map[*remoteWSClient]struct{}
	service    *remote.Service
	deviceRepo *store.DeviceRepo
	connCount  int64
	ipCounters map[string]*ipCounter // per-IP concurrent connection counters
}

// ipCounter tracks concurrent WS connections from a single remote IP to
// mitigate connection-exhaustion DoS. A single controller or host should
// never need more than a few concurrent signaling sockets.
type ipCounter struct {
	count int64
}

const remoteWSMaxConnsPerIP = 4
const remoteWSMaxICEPerSession = 50

type remoteWSClient struct {
	conn       *websocket.Conn
	send       chan []byte
	done       chan struct{}
	role       string
	endpointID string
	authorized map[string]int64 // session_id -> revision consumed by this connection
	ip         string           // client IP for connection accounting
	// iceCounters 限制每 session+revision 的 ICE 候选数量,防止 ICE 候选洪水攻击。
	// 正常 WebRTC 连接不会超过 20 个候选,50 是宽裕上限。
	iceCounters map[string]int // key: session_id+"#"+revision → count
}

type remoteJoinMessage struct {
	V          int    `json:"v"`
	Type       string `json:"type"`
	Role       string `json:"role"`
	EndpointID string `json:"endpoint_id,omitempty"`
	Token      string `json:"token"`
}

type remoteSignalMessage struct {
	V           int                       `json:"v"`
	Type        string                    `json:"type"`
	SessionID   string                    `json:"session_id"`
	Revision    int64                     `json:"revision"`
	Ticket      string                    `json:"ticket,omitempty"`
	Description *remoteSessionDescription `json:"description,omitempty"`
	Candidate   *remoteICECandidate       `json:"candidate,omitempty"`
}

type remoteSessionDescription struct {
	Type string `json:"type"`
	SDP  string `json:"sdp"`
}

type remoteICECandidate struct {
	Candidate        string  `json:"candidate"`
	SDPMid           *string `json:"sdpMid,omitempty"`
	SDPMLineIndex    *int    `json:"sdpMLineIndex,omitempty"`
	UsernameFragment *string `json:"usernameFragment,omitempty"`
}

func newRemoteWSHub(service *remote.Service, repo *store.DeviceRepo) *remoteWSHub {
	return &remoteWSHub{service: service, deviceRepo: repo,
		clients: make(map[string]map[*remoteWSClient]struct{})}
}

func remoteEndpointKey(role, id string) string { return role + "\x00" + id }

// HandleWS is a signaling-only WebSocket. Media never passes through this
// handler, and SDP/ICE payloads are validated and forwarded in memory without
// persistence or payload logging.
func (h *remoteWSHub) HandleWS(w http.ResponseWriter, r *http.Request) {
	if atomic.AddInt64(&h.connCount, 1) > remoteWSMaxConns {
		atomic.AddInt64(&h.connCount, -1)
		http.Error(w, "too many remote signaling connections", http.StatusServiceUnavailable)
		return
	}
	// Per-IP concurrent connection limit to mitigate connection-exhaustion DoS.
	ip := clientIPFromRequest(r)
	if !h.acquireIPSlot(ip) {
		atomic.AddInt64(&h.connCount, -1)
		http.Error(w, "too many connections from this IP", http.StatusTooManyRequests)
		return
	}
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("[remote-ws] upgrade error from %s: %v", ip, err)
		atomic.AddInt64(&h.connCount, -1)
		h.releaseIPSlot(ip)
		return
	}
	conn.SetReadLimit(remoteWSMaxMessage)
	conn.SetReadDeadline(time.Now().Add(remoteWSJoinWait))
	_, raw, err := conn.ReadMessage()
	if err != nil {
		log.Printf("[remote-ws] join read error from %s: %v", ip, err)
		atomic.AddInt64(&h.connCount, -1)
		h.releaseIPSlot(ip)
		conn.Close()
		return
	}
	join, err := h.authenticateJoin(raw)
	if err != nil {
		log.Printf("[remote-ws] join failed from %s: %v", ip, err)
		atomic.AddInt64(&h.connCount, -1)
		h.releaseIPSlot(ip)
		_ = conn.WriteJSON(map[string]any{"v": 1, "type": "remote.error", "error": "REMOTE_AUTH_FAILED"})
		conn.Close()
		return
	}
	client := &remoteWSClient{conn: conn, send: make(chan []byte, remoteWSSendBuffer), done: make(chan struct{}),
		role: join.Role, endpointID: join.EndpointID, authorized: make(map[string]int64), ip: ip,
		iceCounters: make(map[string]int)}
	h.addClient(client)
	conn.SetReadDeadline(time.Now().Add(phoneReadDeadline))
	conn.SetPongHandler(func(string) error {
		conn.SetReadDeadline(time.Now().Add(phoneReadDeadline))
		return nil
	})
	h.send(client, map[string]any{"v": 1, "type": "remote.joined", "role": client.role, "endpoint_id": client.endpointID})

	go h.writeLoop(client)
	go h.readLoop(client)
}

// clientIPFromRequest extracts the real client IP, honoring X-Forwarded-For
// when present (Nginx/Cloudflare proxy chain). Falls back to RemoteAddr.
func clientIPFromRequest(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		for i := len(xff) - 1; i >= 0; i-- {
			if xff[i] == ',' {
				return strings.TrimSpace(xff[i+1:])
			}
		}
		return strings.TrimSpace(xff)
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func (h *remoteWSHub) acquireIPSlot(ip string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.ipCounters == nil {
		h.ipCounters = make(map[string]*ipCounter)
	}
	c := h.ipCounters[ip]
	if c == nil {
		c = &ipCounter{}
		h.ipCounters[ip] = c
	}
	if c.count >= remoteWSMaxConnsPerIP {
		return false
	}
	c.count++
	return true
}

func (h *remoteWSHub) releaseIPSlot(ip string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	c := h.ipCounters[ip]
	if c == nil {
		return
	}
	c.count--
	if c.count <= 0 {
		delete(h.ipCounters, ip)
	}
}

func (h *remoteWSHub) authenticateJoin(raw []byte) (*remoteJoinMessage, error) {
	var join remoteJoinMessage
	if err := strictJSON(raw, &join); err != nil || join.V != remote.ProtocolVersion || join.Type != "remote.join" || join.Token == "" {
		return nil, errors.New("invalid remote join")
	}
	switch join.Role {
	case remote.RoleController:
		if h.deviceRepo == nil {
			return nil, remote.ErrUnauthorized
		}
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		device, err := h.deviceRepo.ByClientToken(ctx, join.Token)
		if err != nil || device == nil {
			return nil, remote.ErrUnauthorized
		}
		// Ignore any claimed endpoint and bind identity from the paired token.
		join.EndpointID = device.ID
	case remote.RoleHost:
		join.EndpointID = strings.TrimSpace(join.EndpointID)
		if join.EndpointID == "" || len(join.EndpointID) > 128 {
			return nil, remote.ErrUnauthorized
		}
		if err := h.service.AuthenticateHost(join.EndpointID, join.Token); err != nil {
			return nil, remote.ErrUnauthorized
		}
	default:
		return nil, remote.ErrUnauthorized
	}
	join.Token = ""
	log.Printf("[remote-ws] join ok role=%s endpoint=%s", join.Role, safeClientID(join.EndpointID))
	return &join, nil
}

func (h *remoteWSHub) readLoop(client *remoteWSClient) {
	defer h.removeClient(client)
	for {
		_, raw, err := client.conn.ReadMessage()
		if err != nil {
			return
		}
		client.conn.SetReadDeadline(time.Now().Add(phoneReadDeadline))
		if err := h.handleSignal(client, raw); err != nil {
			// Never include the raw message, ticket, SDP or ICE in logs/errors.
			log.Printf("[remote-ws] rejected message endpoint=%s role=%s", safeClientID(client.endpointID), client.role)
			h.send(client, map[string]any{"v": 1, "type": "remote.error", "error": remoteSignalErrorCode(err)})
		}
	}
}

func (h *remoteWSHub) writeLoop(client *remoteWSClient) {
	ticker := time.NewTicker(remoteWSPingEvery)
	defer ticker.Stop()
	for {
		select {
		case <-client.done:
			return
		case raw := <-client.send:
			client.conn.SetWriteDeadline(time.Now().Add(writeDeadline))
			if err := client.conn.WriteMessage(websocket.TextMessage, raw); err != nil {
				return
			}
		case <-ticker.C:
			client.conn.SetWriteDeadline(time.Now().Add(writeDeadline))
			if err := client.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}

func (h *remoteWSHub) handleSignal(client *remoteWSClient, raw []byte) error {
	var message remoteSignalMessage
	if err := strictJSON(raw, &message); err != nil {
		return err
	}
	if message.V != remote.ProtocolVersion || !validRemoteSessionID(message.SessionID) || message.Revision <= 0 {
		return errors.New("invalid remote signal envelope")
	}
	switch message.Type {
	case "remote.signal.client_ready":
		if message.Ticket == "" || message.Description != nil || message.Candidate != nil {
			return errors.New("invalid remote ready signal")
		}
		if _, err := h.service.ConsumeTicket(message.Ticket, message.SessionID, client.endpointID, client.role, message.Revision); err != nil {
			return err
		}
		message.Ticket = ""
		client.authorized[message.SessionID] = message.Revision
		return h.forwardSignal(client, message)
	case "remote.signal.offer", "remote.signal.answer":
		if !h.isAuthorized(client, message.SessionID, message.Revision) || message.Ticket != "" || message.Description == nil || message.Candidate != nil {
			return remote.ErrUnauthorized
		}
		wantType := strings.TrimPrefix(message.Type, "remote.signal.")
		if message.Description.Type != wantType || len(message.Description.SDP) == 0 || len(message.Description.SDP) > 262144 {
			return errors.New("invalid remote session description")
		}
		return h.forwardSignal(client, message)
	case "remote.signal.ice":
		if !h.isAuthorized(client, message.SessionID, message.Revision) || message.Ticket != "" || message.Description != nil || message.Candidate == nil {
			return remote.ErrUnauthorized
		}
		if len(message.Candidate.Candidate) > 65536 || !validOptionalLength(message.Candidate.SDPMid, 128) ||
			!validOptionalLength(message.Candidate.UsernameFragment, 256) ||
			(message.Candidate.SDPMLineIndex != nil && *message.Candidate.SDPMLineIndex < 0) {
			return errors.New("invalid remote ICE candidate")
		}
		// 安全加固:限制每 session+revision 的 ICE 候选数量,防止洪水攻击
		iceKey := message.SessionID + "#" + strconv.FormatInt(message.Revision, 10)
		client.iceCounters[iceKey]++
		if client.iceCounters[iceKey] > remoteWSMaxICEPerSession {
			log.Printf("[remote-ws] ICE flood detected from %s endpoint=%s session=%s rev=%d count=%d",
				client.ip, safeClientID(client.endpointID), safeClientID(message.SessionID), message.Revision, client.iceCounters[iceKey])
			return errors.New("too many ICE candidates")
		}
		return h.forwardSignal(client, message)
	default:
		return errors.New("unsupported remote signal type")
	}
}

func (h *remoteWSHub) isAuthorized(client *remoteWSClient, sessionID string, revision int64) bool {
	return client.authorized[sessionID] == revision
}

func (h *remoteWSHub) forwardSignal(client *remoteWSClient, message remoteSignalMessage) error {
	session, err := h.sessionForEndpoint(message.SessionID, client)
	if err != nil {
		return err
	}
	// A signal authorization is scoped to the ticket revision. Once a connected
	// session enters reconnecting, packets from the previous connection must not
	// cross into the new negotiation. The connected state itself is one CAS
	// transition newer than the ticket that established it.
	validRevision := (session.State == remote.StateNegotiating || session.State == remote.StateReconnecting) &&
		session.Revision == message.Revision
	if session.State == remote.StateConnectedView || session.State == remote.StateConnectedControl {
		validRevision = session.Revision == message.Revision+1
	}
	if !validRevision {
		return remote.ErrConflict
	}
	targetRole, targetID := remote.RoleHost, session.HostID
	if client.role == remote.RoleHost {
		targetRole, targetID = remote.RoleController, session.ControllerDeviceID
	}
	message.Ticket = ""
	raw, err := json.Marshal(message)
	if err != nil {
		return err
	}
	log.Printf("[remote-ws] forward %s %s/%s -> %s/%s",
		message.Type, client.role, safeClientID(client.endpointID), targetRole, safeClientID(targetID))
	h.sendRawToEndpoint(targetRole, targetID, raw)
	return nil
}

func (h *remoteWSHub) sessionForEndpoint(sessionID string, client *remoteWSClient) (*remote.Session, error) {
	if client.role == remote.RoleController {
		return h.service.GetSessionForController(sessionID, client.endpointID)
	}
	return h.service.GetSessionForHost(sessionID, client.endpointID)
}

func (h *remoteWSHub) Notify(event remote.Event) {
	payload := map[string]any{"v": 1, "type": event.Type, "session": event.Session}
	h.sendToEndpoint(remote.RoleController, event.Session.ControllerDeviceID, payload)
	h.sendToEndpoint(remote.RoleHost, event.Session.HostID, payload)
	// A secondary controller is not the primary device. Its initial request is
	// sent to the primary phone in real time, while the normal REST poll remains
	// a fallback for a temporarily disconnected app.
	if event.Type == "remote.session.requested" && !event.Session.ControllerIsPrimary && h.deviceRepo != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		primary, err := h.deviceRepo.Primary(ctx)
		cancel()
		if err == nil && primary != nil && primary.ID != event.Session.ControllerDeviceID {
			h.sendToEndpoint(remote.RoleController, primary.ID, payload)
		}
	}
}

func (h *remoteWSHub) addClient(client *remoteWSClient) {
	key := remoteEndpointKey(client.role, client.endpointID)
	h.mu.Lock()
	if h.clients[key] == nil {
		h.clients[key] = make(map[*remoteWSClient]struct{})
	}
	h.clients[key][client] = struct{}{}
	h.mu.Unlock()
}

func (h *remoteWSHub) removeClient(client *remoteWSClient) {
	key := remoteEndpointKey(client.role, client.endpointID)
	endpointOffline := false
	h.mu.Lock()
	if peers := h.clients[key]; peers != nil {
		delete(peers, client)
		if len(peers) == 0 {
			delete(h.clients, key)
			endpointOffline = true
		}
	}
	h.mu.Unlock()
	select {
	case <-client.done:
	default:
		close(client.done)
	}
	client.conn.Close()
	atomic.AddInt64(&h.connCount, -1)
	h.releaseIPSlot(client.ip)
	if endpointOffline {
		log.Printf("[remote-ws] endpoint offline role=%s endpoint=%s", client.role, safeClientID(client.endpointID))
		h.notifyPeerLeft(client)
	}
}

func (h *remoteWSHub) notifyPeerLeft(client *remoteWSClient) {
	for sessionID := range client.authorized {
		session, err := h.sessionForEndpoint(sessionID, client)
		if err != nil || remote.IsTerminalState(session.State) {
			continue
		}
		if session.State == remote.StateConnectedView || session.State == remote.StateConnectedControl {
			if reconnecting, transitionErr := h.service.MarkReconnecting(
				sessionID, client.endpointID, client.role, session.Revision,
			); transitionErr == nil {
				session = reconnecting
			}
		}
		targetRole, targetID := remote.RoleHost, session.HostID
		if client.role == remote.RoleHost {
			targetRole, targetID = remote.RoleController, session.ControllerDeviceID
		}
		h.sendToEndpoint(targetRole, targetID, remoteSignalMessage{
			V: remote.ProtocolVersion, Type: "remote.signal.peer_left",
			SessionID: sessionID, Revision: session.Revision,
		})
	}
}

func (h *remoteWSHub) send(client *remoteWSClient, value any) {
	raw, err := json.Marshal(value)
	if err == nil {
		select {
		case client.send <- raw:
		default:
		}
	}
}

func (h *remoteWSHub) sendToEndpoint(role, endpointID string, value any) {
	raw, err := json.Marshal(value)
	if err == nil {
		h.sendRawToEndpoint(role, endpointID, raw)
	}
}

func (h *remoteWSHub) sendRawToEndpoint(role, endpointID string, raw []byte) {
	key := remoteEndpointKey(role, endpointID)
	h.mu.RLock()
	clients := make([]*remoteWSClient, 0, len(h.clients[key]))
	for client := range h.clients[key] {
		clients = append(clients, client)
	}
	h.mu.RUnlock()
	if len(clients) == 0 {
		log.Printf("[remote-ws] drop: no connected client for role=%s endpoint=%s", role, safeClientID(endpointID))
		return
	}
	for _, client := range clients {
		select {
		case client.send <- raw:
		default:
		}
	}
}

func strictJSON(raw []byte, target any) error {
	decoder := json.NewDecoder(strings.NewReader(string(raw)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	var extra any
	if decoder.Decode(&extra) == nil {
		return errors.New("multiple JSON values")
	}
	return nil
}

func validRemoteSessionID(value string) bool {
	if len(value) < 8 || len(value) > 128 {
		return false
	}
	for _, r := range value {
		if !(r == '.' || r == '_' || r == ':' || r == '-' || r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9') {
			return false
		}
	}
	return true
}

func validOptionalLength(value *string, max int) bool {
	return value == nil || len(*value) <= max
}

func remoteSignalErrorCode(err error) string {
	switch {
	case errors.Is(err, remote.ErrTicketConsumed):
		return "REMOTE_AUTH_TICKET_REPLAYED"
	case errors.Is(err, remote.ErrTicketExpired):
		return "REMOTE_AUTH_TICKET_EXPIRED"
	case errors.Is(err, remote.ErrUnauthorized):
		return "REMOTE_AUTH_FORBIDDEN"
	case errors.Is(err, remote.ErrConflict):
		return "REMOTE_STATE_CONFLICT"
	default:
		return "REMOTE_SIGNAL_INVALID"
	}
}
