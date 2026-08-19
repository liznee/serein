// Command serein-remote-bridge is the WebRTC transport bridge for the Serein
// Windows Remote Host. It reads H.264 NAL units from the native host's named
// pipe, packetizes them into RTP via Pion, and exchanges SDP/ICE with the
// controller (phone) through the backend signaling WebSocket.
//
// The bridge is a short-lived per-session process. It holds the one-time host
// ticket only in memory, never logs SDP/ICE/tickets/media, and exits when the
// session ends, the pipe breaks, or the PeerConnection fails.
package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/gorilla/websocket"

	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"
)

const (
	protocolVersion        = 1
	pipeConnectTimeout     = 10 * time.Second
	pipeReadTimeout        = 5 * time.Minute // was 30s — too short when screen hasn't changed
	wsJoinTimeout          = 20 * time.Second
	connectionTimeout      = 60 * time.Second
	controllerReadyTimeout = 30 * time.Second
	httpTimeout            = 15 * time.Second
	maxNALSize             = 8 * 1024 * 1024
	maxSDPSize             = 262144
)

type bridgeConfig struct {
	BackendURL   string
	HostID       string
	HostToken    string
	SessionID    string
	Revision     int64
	HostTicket   string
	StreamPipe   string
	MonitorIndex int
	FPS          int
	Bitrate      int
	InputEnabled bool
}

type signalMessage struct {
	V           int                 `json:"v"`
	Type        string              `json:"type"`
	Role        string              `json:"role,omitempty"`
	EndpointID  string              `json:"endpoint_id,omitempty"`
	Token       string              `json:"token,omitempty"`
	SessionID   string              `json:"session_id,omitempty"`
	Revision    int64               `json:"revision,omitempty"`
	Ticket      string              `json:"ticket,omitempty"`
	Description *sessionDescription `json:"description,omitempty"`
	Candidate   *iceCandidate       `json:"candidate,omitempty"`
}

type sessionDescription struct {
	Type string `json:"type"`
	SDP  string `json:"sdp"`
}

type iceCandidate struct {
	Candidate        string  `json:"candidate"`
	SDPMid           *string `json:"sdpMid,omitempty"`
	SDPMLineIndex    *uint16 `json:"sdpMLineIndex,omitempty"`
	UsernameFragment *string `json:"usernameFragment,omitempty"`
}

type revisionRequest struct {
	Revision int64  `json:"revision"`
	Reason   string `json:"reason,omitempty"`
}

func main() {
	if len(os.Args) == 2 && os.Args[1] == "--capabilities" {
		input := []string{}
		if runtime.GOOS == "windows" {
			input = []string{"pointer", "keyboard", "text"}
		}
		_ = json.NewEncoder(os.Stdout).Encode(map[string]interface{}{
			"protocol_version":    1,
			"input":               input,
			"desktop_pixels_read": false,
		})
		return
	}
	config, err := loadConfig()
	if err != nil {
		log.Fatalf("serein-remote-bridge: invalid configuration: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		log.Printf("serein-remote-bridge: received shutdown signal")
		cancel()
	}()

	if err := run(ctx, config); err != nil {
		log.Printf("serein-remote-bridge: session ended: %v", err)
		endSession(config, "bridge_error")
		os.Exit(1)
	}
}

func loadConfig() (*bridgeConfig, error) {
	cfg := &bridgeConfig{
		BackendURL:   os.Getenv("SEREIN_REMOTE_BACKEND_URL"),
		HostID:       os.Getenv("SEREIN_REMOTE_HOST_ID"),
		HostToken:    os.Getenv("SEREIN_REMOTE_HOST_TOKEN"),
		SessionID:    os.Getenv("SEREIN_REMOTE_SESSION_ID"),
		StreamPipe:   os.Getenv("SEREIN_REMOTE_STREAM_PIPE"),
		HostTicket:   os.Getenv("SEREIN_REMOTE_HOST_TICKET"),
		MonitorIndex: 0,
		FPS:          15,
		Bitrate:      2_000_000,
	}

	if cfg.BackendURL == "" {
		return nil, errors.New("SEREIN_REMOTE_BACKEND_URL is required")
	}
	if cfg.HostID == "" || len(cfg.HostID) > 128 {
		return nil, errors.New("SEREIN_REMOTE_HOST_ID is required")
	}
	if cfg.HostToken == "" {
		return nil, errors.New("SEREIN_REMOTE_HOST_TOKEN is required")
	}
	if cfg.SessionID == "" || len(cfg.SessionID) > 128 {
		return nil, errors.New("SEREIN_REMOTE_SESSION_ID is required")
	}
	if cfg.StreamPipe == "" {
		return nil, errors.New("SEREIN_REMOTE_STREAM_PIPE is required")
	}
	if cfg.HostTicket == "" || len(cfg.HostTicket) > 4096 {
		return nil, errors.New("SEREIN_REMOTE_HOST_TICKET is required")
	}
	switch os.Getenv("SEREIN_REMOTE_INPUT_ENABLED") {
	case "1":
		cfg.InputEnabled = true
	case "0":
		cfg.InputEnabled = false
	default:
		return nil, errors.New("SEREIN_REMOTE_INPUT_ENABLED must be 0 or 1")
	}

	if rev := os.Getenv("SEREIN_REMOTE_REVISION"); rev != "" {
		var r int64
		if _, err := fmt.Sscanf(rev, "%d", &r); err != nil || r <= 0 {
			return nil, fmt.Errorf("invalid SEREIN_REMOTE_REVISION: %s", rev)
		}
		cfg.Revision = r
	} else {
		return nil, errors.New("SEREIN_REMOTE_REVISION is required")
	}

	if fps := os.Getenv("SEREIN_REMOTE_FPS"); fps != "" {
		var f int
		if _, err := fmt.Sscanf(fps, "%d", &f); err != nil || f < 1 || f > 60 {
			return nil, fmt.Errorf("invalid SEREIN_REMOTE_FPS: %s", fps)
		}
		cfg.FPS = f
	}

	return cfg, nil
}

func run(ctx context.Context, config *bridgeConfig) error {
	wsURL := strings.Replace(config.BackendURL, "https://", "wss://", 1)
	wsURL = strings.Replace(wsURL, "http://", "ws://", 1)
	wsURL = strings.TrimRight(wsURL, "/") + "/v1/remote/ws"

	dialer := websocket.Dialer{HandshakeTimeout: wsJoinTimeout}
	ws, _, err := dialer.DialContext(ctx, wsURL, nil)
	if err != nil {
		return fmt.Errorf("ws dial: %w", err)
	}
	defer ws.Close()
	ws.SetReadLimit(320 * 1024)

	joinMsg := signalMessage{
		V:          protocolVersion,
		Type:       "remote.join",
		Role:       "host",
		EndpointID: config.HostID,
		Token:      config.HostToken,
	}
	if err := ws.WriteJSON(joinMsg); err != nil {
		return fmt.Errorf("ws join write: %w", err)
	}

	joined := false
	ws.SetReadDeadline(time.Now().Add(wsJoinTimeout))
	_, raw, err := ws.ReadMessage()
	if err != nil {
		return fmt.Errorf("ws join read: %w", err)
	}
	var joinResp signalMessage
	if err := json.Unmarshal(raw, &joinResp); err != nil || joinResp.V != protocolVersion || joinResp.Type != "remote.joined" {
		return fmt.Errorf("ws join unexpected response")
	}
	joined = true
	_ = joined
	log.Printf("serein-remote-bridge: signaling connected hostID=%s session=%s rev=%d joinEndpoint=%s",
		config.HostID, config.SessionID, config.Revision, joinResp.EndpointID)

	readyMsg := signalMessage{
		V:         protocolVersion,
		Type:      "remote.signal.client_ready",
		SessionID: config.SessionID,
		Revision:  config.Revision,
		Ticket:    config.HostTicket,
	}
	if err := ws.WriteJSON(readyMsg); err != nil {
		return fmt.Errorf("ws client_ready write: %w", err)
	}
	log.Printf("serein-remote-bridge: host ready sent, waiting for controller (hostID=%s)", config.HostID)

	peerConnection, err := webrtc.NewPeerConnection(webrtc.Configuration{
		ICEServers: []webrtc.ICEServer{},
	})
	if err != nil {
		return fmt.Errorf("peer connection create: %w", err)
	}
	defer peerConnection.Close()

	videoTrack, err := webrtc.NewTrackLocalStaticSample(
		webrtc.RTPCodecCapability{
			MimeType:  webrtc.MimeTypeH264,
			ClockRate: 90000,
		},
		"video", "serein",
	)
	if err != nil {
		return fmt.Errorf("video track create: %w", err)
	}
	if _, err := peerConnection.AddTrack(videoTrack); err != nil {
		return fmt.Errorf("track add: %w", err)
	}

	if config.InputEnabled {
		// The input DataChannel exists only when the backend granted the session's
		// explicit input capability. View-only sessions therefore have no path to
		// SendInput even if a modified controller tries to send input messages.
		inputChannel, err := peerConnection.CreateDataChannel("serein-input", &webrtc.DataChannelInit{
			Ordered:    nil,
			Negotiated: nil,
		})
		if err != nil {
			return fmt.Errorf("data channel create: %w", err)
		}
		inputChannel.OnOpen(func() {
			log.Printf("serein-remote-bridge: input data channel open")
		})
		inputChannel.OnMessage(func(msg webrtc.DataChannelMessage) {
			if err := handleInputEvent(msg.Data); err != nil {
				log.Printf("serein-remote-bridge: input error: %v", err)
				return
			}
			// Text focus can settle on mouse-up, especially in Chromium controls.
			// Check shortly afterwards and return only a boolean, never window
			// titles, text, or desktop data.
			if isLeftButtonUp(msg.Data) {
				go func() {
					time.Sleep(80 * time.Millisecond)
					if focusedTextInput() {
						if err := inputChannel.SendText(`{"t":"focus","input":true}`); err != nil {
							log.Printf("serein-remote-bridge: keyboard-focus notify error: %v", err)
						}
					}
				}()
			}
		})
		inputChannel.OnClose(func() {
			log.Printf("serein-remote-bridge: input data channel closed, releasing all keys")
			releaseAllInput()
		})
	} else {
		log.Printf("serein-remote-bridge: input disabled for view-only session")
	}

	var pendingCandidates []webrtc.ICECandidateInit
	var candidatesMu sync.Mutex
	remoteDescSet := false

	peerConnection.OnICECandidate(func(candidate *webrtc.ICECandidate) {
		if candidate == nil {
			return
		}
		init := candidate.ToJSON()
		msg := signalMessage{
			V:         protocolVersion,
			Type:      "remote.signal.ice",
			SessionID: config.SessionID,
			Revision:  config.Revision,
			Candidate: &iceCandidate{
				Candidate:        init.Candidate,
				SDPMid:           init.SDPMid,
				SDPMLineIndex:    init.SDPMLineIndex,
				UsernameFragment: init.UsernameFragment,
			},
		}
		if err := ws.WriteJSON(msg); err != nil {
			log.Printf("serein-remote-bridge: ice send error: %v", err)
		}
	})

	connStateCh := make(chan webrtc.PeerConnectionState, 4)
	peerConnection.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		log.Printf("serein-remote-bridge: peer connection state: %s", state)
		// Release all pressed keys/buttons when the connection drops to
		// prevent stuck inputs (e.g. user holding a key when network fails).
		if state == webrtc.PeerConnectionStateFailed ||
			state == webrtc.PeerConnectionStateClosed ||
			state == webrtc.PeerConnectionStateDisconnected {
			releaseAllInput()
		}
		select {
		case connStateCh <- state:
		default:
		}
	})

	// Start the signaling read loop BEFORE creating the offer. The controller
	// (phone) must join signaling and send its own client_ready before the
	// offer is useful — otherwise the backend has no controller WebSocket to
	// forward the offer to, and the offer is silently dropped.
	wsDone := make(chan struct{})
	controllerReady := make(chan struct{}, 1)
	go func() {
		defer close(wsDone)
		for {
			// No read deadline: WS pings are handled at protocol level, not ReadMessage
			ws.SetReadDeadline(time.Time{})
			_, raw, err := ws.ReadMessage()
			if err != nil {
				log.Printf("serein-remote-bridge: ws read ended: %v", err)
				return
			}
			var msg signalMessage
			if err := json.Unmarshal(raw, &msg); err != nil || msg.V != protocolVersion {
				continue
			}
			log.Printf("serein-remote-bridge: recv %s", msg.Type)

			// The controller's client_ready is forwarded by the backend after
			// the phone joins signaling and consumes its ticket. We accept it
			// without a strict session-envelope check because the backend
			// already validated session/revision/ticket before forwarding.
			if msg.Type == "remote.signal.client_ready" {
				select {
				case controllerReady <- struct{}{}:
				default:
				}
				continue
			}

			if msg.SessionID != config.SessionID || msg.Revision != config.Revision {
				continue
			}
			switch msg.Type {
			case "remote.signal.answer":
				if msg.Description == nil || msg.Description.Type != "answer" ||
					len(msg.Description.SDP) == 0 || len(msg.Description.SDP) > maxSDPSize {
					continue
				}
				if err := peerConnection.SetRemoteDescription(webrtc.SessionDescription{
					Type: webrtc.SDPTypeAnswer,
					SDP:  msg.Description.SDP,
				}); err != nil {
					log.Printf("serein-remote-bridge: remote description set error: %v", err)
					return
				}
				candidatesMu.Lock()
				remoteDescSet = true
				pending := pendingCandidates
				pendingCandidates = nil
				candidatesMu.Unlock()
				for _, c := range pending {
					if err := peerConnection.AddICECandidate(c); err != nil {
						log.Printf("serein-remote-bridge: pending ice add error: %v", err)
					}
				}
				log.Printf("serein-remote-bridge: answer received")
			case "remote.signal.ice":
				if msg.Candidate == nil || len(msg.Candidate.Candidate) > 65536 {
					continue
				}
				init := webrtc.ICECandidateInit{
					Candidate:        msg.Candidate.Candidate,
					SDPMid:           msg.Candidate.SDPMid,
					SDPMLineIndex:    msg.Candidate.SDPMLineIndex,
					UsernameFragment: msg.Candidate.UsernameFragment,
				}
				candidatesMu.Lock()
				set := remoteDescSet
				if !set {
					pendingCandidates = append(pendingCandidates, init)
				}
				candidatesMu.Unlock()
				if set {
					if err := peerConnection.AddICECandidate(init); err != nil {
						log.Printf("serein-remote-bridge: ice add error: %v", err)
					}
				}
			case "remote.signal.peer_left":
				log.Printf("serein-remote-bridge: peer left")
				return
			case "remote.error":
				// Do NOT exit on signaling errors. Media + DataChannel are independent of signaling revision.
				log.Printf("serein-remote-bridge: signaling error from server (ignored)")
			}
		}
	}()

	// Wait for the controller (phone) to join signaling and signal readiness
	// before creating the SDP offer. Without this gate the offer is sent to a
	// controller that may not yet be connected, and the backend silently drops
	// it — the phone never sees the offer and the bridge times out.
	select {
	case <-controllerReady:
		log.Printf("serein-remote-bridge: controller ready, creating offer")
	case <-time.After(controllerReadyTimeout):
		return errors.New("timeout waiting for controller ready")
	case <-ctx.Done():
		return ctx.Err()
	case <-wsDone:
		return errors.New("signaling disconnected before controller ready")
	}

	offer, err := peerConnection.CreateOffer(nil)
	if err != nil {
		return fmt.Errorf("offer create: %w", err)
	}
	if err := peerConnection.SetLocalDescription(offer); err != nil {
		return fmt.Errorf("local description set: %w", err)
	}

	offerMsg := signalMessage{
		V:         protocolVersion,
		Type:      "remote.signal.offer",
		SessionID: config.SessionID,
		Revision:  config.Revision,
		Description: &sessionDescription{
			Type: "offer",
			SDP:  offer.SDP,
		},
	}
	if err := ws.WriteJSON(offerMsg); err != nil {
		return fmt.Errorf("offer send: %w", err)
	}
	log.Printf("serein-remote-bridge: offer sent")

	select {
	case state := <-connStateCh:
		if state != webrtc.PeerConnectionStateConnected {
			select {
			case state = <-connStateCh:
			case <-time.After(connectionTimeout):
				return errors.New("connection timeout")
			case <-ctx.Done():
				return ctx.Err()
			case <-wsDone:
				return errors.New("signaling disconnected before connection")
			}
		}
		if state != webrtc.PeerConnectionStateConnected {
			return fmt.Errorf("peer connection failed: %s", state)
		}
	case <-time.After(connectionTimeout):
		return errors.New("connection timeout")
	case <-ctx.Done():
		return ctx.Err()
	case <-wsDone:
		return errors.New("signaling disconnected before connection")
	}

	log.Printf("serein-remote-bridge: connected, marking session")
	if err := markConnected(config); err != nil {
		return fmt.Errorf("mark connected: %w", err)
	}

	pipe, err := openPipeWithRetry(config.StreamPipe, pipeConnectTimeout)
	if err != nil {
		return fmt.Errorf("pipe open: %w", err)
	}
	defer pipe.Close()
	log.Printf("serein-remote-bridge: stream pipe connected")

	frameDuration := time.Duration(1_000_000_000/int64(config.FPS)) * time.Nanosecond
	headerBuf := make([]byte, 4)

	streamCtx, streamCancel := context.WithCancel(ctx)
	defer streamCancel()

	go func() {
		select {
		case <-streamCtx.Done():
		case state := <-connStateCh:
			if state == webrtc.PeerConnectionStateFailed || state == webrtc.PeerConnectionStateClosed || state == webrtc.PeerConnectionStateDisconnected {
				streamCancel()
			}
		case <-wsDone:
			streamCancel()
		}
	}()

	for {
		select {
		case <-streamCtx.Done():
			return streamCtx.Err()
		default:
		}

		pipe.SetReadDeadline(time.Now().Add(pipeReadTimeout))
		if _, err := io.ReadFull(pipe, headerBuf); err != nil {
			return fmt.Errorf("pipe header read: %w", err)
		}
		payloadSize := binary.BigEndian.Uint32(headerBuf)
		if payloadSize == 0 || payloadSize > maxNALSize {
			return fmt.Errorf("invalid nal size: %d", payloadSize)
		}

		nalData := make([]byte, payloadSize)
		pipe.SetReadDeadline(time.Now().Add(pipeReadTimeout))
		if _, err := io.ReadFull(pipe, nalData); err != nil {
			return fmt.Errorf("pipe payload read: %w", err)
		}

		if err := videoTrack.WriteSample(media.Sample{
			Data:     nalData,
			Duration: frameDuration,
		}); err != nil {
			log.Printf("serein-remote-bridge: sample write error: %v", err)
		}
	}
}

func openPipeWithRetry(path string, timeout time.Duration) (*os.File, error) {
	deadline := time.Now().Add(timeout)
	var lastErr error
	for {
		f, err := os.OpenFile(path, os.O_RDONLY, 0)
		if err == nil {
			return f, nil
		}
		lastErr = err
		if !os.IsNotExist(err) && !isPipeBusy(err) {
			return nil, err
		}
		if time.Now().After(deadline) {
			return nil, fmt.Errorf("pipe %s not available after %s: %w", path, timeout, lastErr)
		}
		time.Sleep(200 * time.Millisecond)
	}
}

func isPipeBusy(err error) bool {
	return err != nil && (strings.Contains(err.Error(), "pipe is busy") ||
		strings.Contains(err.Error(), "All pipe instances are busy"))
}

func markConnected(config *bridgeConfig) error {
	body := revisionRequest{Revision: config.Revision}
	return postBackend(config, fmt.Sprintf("/v1/remote/hosts/%s/sessions/%s/connected",
		config.HostID, config.SessionID), body)
}

func endSession(config *bridgeConfig, reason string) {
	// Use revision 0 so the backend applies the end to the session's current
	// revision. The bridge may outlive the negotiating revision (e.g. after
	// markConnected bumps it), and a stale CAS revision would silently fail.
	body := revisionRequest{Reason: reason}
	if err := postBackend(config, fmt.Sprintf("/v1/remote/hosts/%s/sessions/%s/end",
		config.HostID, config.SessionID), body); err != nil {
		log.Printf("serein-remote-bridge: end session error: %v", err)
	}
}

func postBackend(config *bridgeConfig, path string, body interface{}) error {
	url := strings.TrimRight(config.BackendURL, "/") + path
	payload, err := json.Marshal(body)
	if err != nil {
		return err
	}
	req, err := http.NewRequest("POST", url, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+config.HostToken)
	client := &http.Client{Timeout: httpTimeout}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("backend %s returned %d", path, resp.StatusCode)
	}
	return nil
}
