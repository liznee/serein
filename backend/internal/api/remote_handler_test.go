package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gorilla/websocket"

	"serein/internal/approval"
	rdplog "serein/internal/log"
	"serein/internal/notify"
	"serein/internal/risk"
	"serein/internal/store"
)

func newRemoteAPITestServer(t *testing.T) *httptest.Server {
	t.Helper()
	db, err := store.Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	deviceRepo := store.NewDeviceRepo(db)
	sessionRepo := store.NewSessionRepo(db)
	engine := risk.New(store.NewBlacklistRepo(db), store.NewWhitelistRepo(db), sessionRepo)
	handler := NewRouter(RouterConfig{
		HookToken: "hook-secret", PairCode: "pair-secret", DevMode: false,
		Svc: approval.NewService(db, 300), Pub: notify.New("http://127.0.0.1:59999", "test"),
		Engine: engine, SessionRepo: sessionRepo, DeviceRepo: deviceRepo,
		DevHandler: NewDeviceHandler(deviceRepo, "pair-secret"),
		CfgHandler: NewConfigHandler(store.NewWhitelistRepo(db), store.NewBlacklistRepo(db), engine),
		Logger:     rdplog.NoOp(), Version: "test", SysInfoRepo: store.NewSysInfoRepo(db),
	})
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	return server
}

func remoteRequest(t *testing.T, client *http.Client, method, url, token, body string, out any) int {
	t.Helper()
	req, err := http.NewRequest(method, url, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if out != nil {
		if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
			t.Fatalf("decode %s %s: %v", method, url, err)
		}
	}
	return resp.StatusCode
}

func pairRemotePhone(t *testing.T, server *httptest.Server, name string) (string, string) {
	t.Helper()
	var result struct {
		DeviceID    string `json:"device_id"`
		ClientToken string `json:"client_token"`
	}
	status := remoteRequest(t, server.Client(), http.MethodPost, server.URL+"/devices/pair", "",
		`{"device_name":"`+name+`","pair_code":"pair-secret"}`, &result)
	if status != http.StatusCreated {
		t.Fatalf("pair status=%d", status)
	}
	return result.DeviceID, result.ClientToken
}

func remoteHostRegistrationBody(rotate bool) string {
	rotateField := ""
	if rotate {
		rotateField = `,"rotate_credential":true`
	}
	return `{"id":"host-1","device_fingerprint":"sha256:host-1","display_name":"My PC","version":"0.1.0"` + rotateField + `,"capabilities":{"protocol_version":1,"capture":["dxgi-duplication"],"video_codecs":["h264"],"transports":["webrtc"],"hardware_encoder":true,"input":[],"monitors":1,"unattended_enabled":false,"secure_desktop":false}}`
}

func registerRemoteHost(t *testing.T, server *httptest.Server) string {
	t.Helper()
	var result struct {
		HostToken string `json:"host_token"`
	}
	if status := remoteRequest(t, server.Client(), http.MethodPost, server.URL+"/v1/remote/hosts/register", "hook-secret", remoteHostRegistrationBody(false), &result); status != http.StatusOK {
		t.Fatalf("register host status=%d", status)
	}
	if result.HostToken == "" {
		t.Fatal("first host registration did not issue an operational credential")
	}
	return result.HostToken
}

func TestRemoteHTTPReadOnlyLifecycleAndIdentityBinding(t *testing.T) {
	server := newRemoteAPITestServer(t)
	deviceID, token := pairRemotePhone(t, server, "phone-a")
	otherToken := "not-a-paired-device-token"
	hostToken := registerRemoteHost(t, server)

	// Register phone-a as primary device (required for remote control)
	remoteRequest(t, server.Client(), http.MethodPost, server.URL+"/v1/devices/primary/register", token, "", nil)

	var hosts struct {
		Items []map[string]any `json:"items"`
	}
	if status := remoteRequest(t, server.Client(), http.MethodGet, server.URL+"/v1/remote/hosts", token, "", &hosts); status != http.StatusOK || len(hosts.Items) != 1 {
		t.Fatalf("hosts status=%d items=%d", status, len(hosts.Items))
	}
	if _, leaked := hosts.Items[0]["device_fingerprint"]; leaked {
		t.Fatal("phone host list leaked device fingerprint")
	}

	var unsupported map[string]string
	status := remoteRequest(t, server.Client(), http.MethodPost, server.URL+"/v1/remote/sessions", token,
		`{"host_id":"host-1","requested_capabilities":["pointer"]}`, &unsupported)
	if status != http.StatusBadRequest || unsupported["error"] != "REMOTE_CAPABILITY_UNSUPPORTED" {
		t.Fatalf("unsupported status=%d body=%v", status, unsupported)
	}

	var created struct {
		ID                 string `json:"id"`
		ControllerDeviceID string `json:"controller_device_id"`
		State              string `json:"state"`
		Revision           int64  `json:"revision"`
	}
	status = remoteRequest(t, server.Client(), http.MethodPost, server.URL+"/v1/remote/sessions", token,
		`{"host_id":"host-1","requested_capabilities":["view"]}`, &created)
	if status != http.StatusCreated || created.ControllerDeviceID != deviceID || created.State != "waiting_consent" {
		t.Fatalf("create status=%d result=%+v", status, created)
	}
	var forbidden map[string]string
	status = remoteRequest(t, server.Client(), http.MethodGet, server.URL+"/v1/remote/sessions/"+created.ID, otherToken, "", &forbidden)
	if status != http.StatusUnauthorized {
		t.Fatalf("cross-device get status=%d body=%v", status, forbidden)
	}

	var accepted struct {
		Session struct {
			State    string `json:"state"`
			Revision int64  `json:"revision"`
		} `json:"session"`
		Ticket struct {
			Ticket string `json:"ticket"`
		} `json:"ticket"`
	}
	status = remoteRequest(t, server.Client(), http.MethodPost,
		server.URL+"/v1/remote/hosts/host-1/sessions/"+created.ID+"/accept", hostToken,
		`{"revision":1}`, &accepted)
	if status != http.StatusOK || accepted.Session.State != "negotiating" || accepted.Session.Revision != 2 || accepted.Ticket.Ticket == "" {
		t.Fatalf("accept status=%d result=%+v", status, accepted)
	}
	var controllerTicket struct {
		Ticket   string `json:"ticket"`
		Revision int64  `json:"revision"`
	}
	status = remoteRequest(t, server.Client(), http.MethodPost,
		server.URL+"/v1/remote/sessions/"+created.ID+"/ticket/refresh", token, "", &controllerTicket)
	if status != http.StatusOK || controllerTicket.Ticket == "" || controllerTicket.Revision != 2 {
		t.Fatalf("refresh status=%d result=%+v", status, controllerTicket)
	}
}

func TestRemoteHostCredentialRotationAndRevocation(t *testing.T) {
	server := newRemoteAPITestServer(t)
	hostToken := registerRemoteHost(t, server)
	heartbeatURL := server.URL + "/v1/remote/hosts/host-1/heartbeat"

	if status := remoteRequest(t, server.Client(), http.MethodPost, heartbeatURL, "hook-secret", "", nil); status != http.StatusUnauthorized {
		t.Fatalf("global hook token accessed operational host route: status=%d", status)
	}
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/v1/remote/ws"
	hookConn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := hookConn.WriteJSON(map[string]any{
		"v": 1, "type": "remote.join", "role": "host", "endpoint_id": "host-1", "token": "hook-secret",
	}); err != nil {
		hookConn.Close()
		t.Fatal(err)
	}
	authError := readRemoteType(t, hookConn, "remote.error")
	hookConn.Close()
	if authError["error"] != "REMOTE_AUTH_FAILED" {
		t.Fatalf("global hook token joined host websocket: event=%v", authError)
	}
	var heartbeat struct {
		Version      string `json:"version"`
		Capabilities struct {
			Input []string `json:"input"`
		} `json:"capabilities"`
	}
	heartbeatBody := `{"version":"0.2.0","capabilities":{"protocol_version":1,"capture":["dxgi-duplication"],"video_codecs":["h264"],"transports":["webrtc"],"hardware_encoder":false,"input":["pointer","keyboard","text"],"monitors":1,"unattended_enabled":false,"secure_desktop":false}}`
	if status := remoteRequest(t, server.Client(), http.MethodPost, heartbeatURL, hostToken, heartbeatBody, &heartbeat); status != http.StatusOK {
		t.Fatalf("host credential heartbeat status=%d", status)
	}
	if heartbeat.Version != "0.2.0" || strings.Join(heartbeat.Capabilities.Input, ",") != "pointer,keyboard,text" {
		t.Fatalf("host heartbeat did not refresh capabilities: %+v", heartbeat)
	}

	var repeated struct {
		HostToken string `json:"host_token"`
	}
	if status := remoteRequest(t, server.Client(), http.MethodPost, server.URL+"/v1/remote/hosts/register",
		"hook-secret", remoteHostRegistrationBody(false), &repeated); status != http.StatusOK || repeated.HostToken != "" {
		t.Fatalf("repeat registration status=%d token_was_returned=%v", status, repeated.HostToken != "")
	}

	var rotated struct {
		HostToken string `json:"host_token"`
	}
	if status := remoteRequest(t, server.Client(), http.MethodPost, server.URL+"/v1/remote/hosts/register",
		"hook-secret", remoteHostRegistrationBody(true), &rotated); status != http.StatusOK || rotated.HostToken == "" || rotated.HostToken == hostToken {
		t.Fatalf("rotation status=%d produced_new_token=%v", status, rotated.HostToken != "" && rotated.HostToken != hostToken)
	}
	if status := remoteRequest(t, server.Client(), http.MethodPost, heartbeatURL, hostToken, "", nil); status != http.StatusUnauthorized {
		t.Fatalf("old host credential survived rotation: status=%d", status)
	}
	if status := remoteRequest(t, server.Client(), http.MethodPost, heartbeatURL, rotated.HostToken, "", nil); status != http.StatusOK {
		t.Fatalf("rotated host credential heartbeat status=%d", status)
	}

	revokeURL := server.URL + "/v1/remote/hosts/host-1/credential/revoke"
	if status := remoteRequest(t, server.Client(), http.MethodPost, revokeURL, "hook-secret", "", nil); status != http.StatusNoContent {
		t.Fatalf("revoke status=%d", status)
	}
	if status := remoteRequest(t, server.Client(), http.MethodPost, heartbeatURL, rotated.HostToken, "", nil); status != http.StatusUnauthorized {
		t.Fatalf("revoked host credential remained valid: status=%d", status)
	}
}

func TestRemoteWebSocketRoutesOnlyToBoundEndpointsAndRejectsReplay(t *testing.T) {
	server := newRemoteAPITestServer(t)
	_, token := pairRemotePhone(t, server, "phone-a")
	// Register phone-a as primary device (required for remote control)
	remoteRequest(t, server.Client(), http.MethodPost, server.URL+"/v1/devices/primary/register", token, "", nil)
	hostToken := registerRemoteHost(t, server)
	var created struct {
		ID string `json:"id"`
	}
	remoteRequest(t, server.Client(), http.MethodPost, server.URL+"/v1/remote/sessions", token,
		`{"host_id":"host-1","requested_capabilities":["view"]}`, &created)
	var accepted struct {
		Ticket struct {
			Ticket   string `json:"ticket"`
			Revision int64  `json:"revision"`
		} `json:"ticket"`
	}
	remoteRequest(t, server.Client(), http.MethodPost,
		server.URL+"/v1/remote/hosts/host-1/sessions/"+created.ID+"/accept", hostToken, `{"revision":1}`, &accepted)
	var controllerTicket struct {
		Ticket   string `json:"ticket"`
		Revision int64  `json:"revision"`
	}
	remoteRequest(t, server.Client(), http.MethodPost,
		server.URL+"/v1/remote/sessions/"+created.ID+"/ticket/refresh", token, "", &controllerTicket)

	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/v1/remote/ws"
	hostConn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer hostConn.Close()
	controllerConn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer controllerConn.Close()
	if err := hostConn.WriteJSON(map[string]any{"v": 1, "type": "remote.join", "role": "host", "endpoint_id": "host-1", "token": hostToken}); err != nil {
		t.Fatal(err)
	}
	if err := controllerConn.WriteJSON(map[string]any{"v": 1, "type": "remote.join", "role": "controller", "endpoint_id": "spoofed", "token": token}); err != nil {
		t.Fatal(err)
	}
	readRemoteType(t, hostConn, "remote.joined")
	joined := readRemoteType(t, controllerConn, "remote.joined")
	if joined["endpoint_id"] == "spoofed" {
		t.Fatal("controller endpoint accepted spoofed device id")
	}

	hostReady := map[string]any{"v": 1, "type": "remote.signal.client_ready", "session_id": created.ID,
		"revision": accepted.Ticket.Revision, "ticket": accepted.Ticket.Ticket}
	controllerReady := map[string]any{"v": 1, "type": "remote.signal.client_ready", "session_id": created.ID,
		"revision": controllerTicket.Revision, "ticket": controllerTicket.Ticket}
	if err := hostConn.WriteJSON(hostReady); err != nil {
		t.Fatal(err)
	}
	if err := controllerConn.WriteJSON(controllerReady); err != nil {
		t.Fatal(err)
	}
	readyAtController := readRemoteType(t, controllerConn, "remote.signal.client_ready")
	if _, leaked := readyAtController["ticket"]; leaked {
		t.Fatal("forwarded ready event leaked one-time ticket")
	}
	readRemoteType(t, hostConn, "remote.signal.client_ready")

	offer := map[string]any{"v": 1, "type": "remote.signal.offer", "session_id": created.ID, "revision": int64(2),
		"description": map[string]any{"type": "offer", "sdp": "v=0\r\n"}}
	if err := hostConn.WriteJSON(offer); err != nil {
		t.Fatal(err)
	}
	readRemoteType(t, controllerConn, "remote.signal.offer")

	// Reusing the exact controller ticket must fail and must not be forwarded.
	if err := controllerConn.WriteJSON(controllerReady); err != nil {
		t.Fatal(err)
	}
	errorEvent := readRemoteType(t, controllerConn, "remote.error")
	if errorEvent["error"] != "REMOTE_AUTH_TICKET_REPLAYED" {
		t.Fatalf("replay error=%v", errorEvent)
	}
	var connected struct {
		State    string `json:"state"`
		Revision int64  `json:"revision"`
	}
	remoteRequest(t, server.Client(), http.MethodPost,
		server.URL+"/v1/remote/hosts/host-1/sessions/"+created.ID+"/connected", hostToken, `{"revision":2}`, &connected)
	if connected.State != "connected_view" || connected.Revision != 3 {
		t.Fatalf("connected=%#v", connected)
	}
	readRemoteType(t, controllerConn, "remote.session.connected")
	readRemoteType(t, hostConn, "remote.session.connected")

	// Once the last authenticated Host signaling connection leaves, the paired
	// controller receives a real reconnecting state followed by a scoped
	// peer-left event carrying the new revision.
	hostConn.Close()
	reconnecting := readRemoteType(t, controllerConn, "remote.session.reconnecting")
	reconnectingSession, ok := reconnecting["session"].(map[string]any)
	if !ok || reconnectingSession["state"] != "reconnecting" {
		t.Fatalf("reconnecting event=%#v", reconnecting)
	}
	peerLeft := readRemoteType(t, controllerConn, "remote.signal.peer_left")
	if peerLeft["session_id"] != created.ID || peerLeft["revision"] != json.Number("4") {
		t.Fatalf("peer-left session=%v want=%s", peerLeft["session_id"], created.ID)
	}

	// The old revision cannot send ICE into the new negotiation.
	if err := controllerConn.WriteJSON(map[string]any{"v": 1, "type": "remote.signal.ice", "session_id": created.ID,
		"revision": int64(2), "candidate": map[string]any{"candidate": "candidate:stale"}}); err != nil {
		t.Fatal(err)
	}
	staleError := readRemoteType(t, controllerConn, "remote.error")
	if staleError["error"] != "REMOTE_STATE_CONFLICT" {
		t.Fatalf("stale signal error=%v", staleError)
	}
}

func readRemoteType(t *testing.T, conn *websocket.Conn, want string) map[string]any {
	t.Helper()
	_, raw, err := conn.ReadMessage()
	if err != nil {
		t.Fatal(err)
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var event map[string]any
	if err := decoder.Decode(&event); err != nil {
		t.Fatal(err)
	}
	if event["type"] != want {
		t.Fatalf("event type=%v want=%s raw=%s", event["type"], want, raw)
	}
	return event
}
