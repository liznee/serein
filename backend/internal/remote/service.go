package remote

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
)

var (
	ErrUnauthorized      = errors.New("remote access unauthorized")
	ErrInvalidCapability = errors.New("invalid remote capability")
	ErrHostOffline       = errors.New("remote host offline")
)

type Event struct {
	Type    string  `json:"type"`
	Session Session `json:"session"`
}

type EventSink func(Event)

type Service struct {
	repo    *Repository
	tickets *TicketIssuer
	now     func() time.Time

	sinkMu sync.RWMutex
	sink   EventSink

	credentialMu sync.Mutex
}

func NewService(repo *Repository, tickets *TicketIssuer) *Service {
	return &Service{repo: repo, tickets: tickets, now: time.Now}
}

func (s *Service) SetEventSink(sink EventSink) {
	s.sinkMu.Lock()
	s.sink = sink
	s.sinkMu.Unlock()
}

func (s *Service) emit(event Event) {
	s.sinkMu.RLock()
	sink := s.sink
	s.sinkMu.RUnlock()
	if sink != nil {
		sink(event)
	}
}

func (s *Service) RegisterHost(input RegisterHostInput) (*Host, error) {
	input.ID = strings.TrimSpace(input.ID)
	input.DeviceFingerprint = strings.TrimSpace(input.DeviceFingerprint)
	input.DisplayName = strings.TrimSpace(input.DisplayName)
	if input.ID == "" || len(input.ID) > 128 || input.DeviceFingerprint == "" || len(input.DeviceFingerprint) > 256 ||
		input.DisplayName == "" || len(input.DisplayName) > 128 || len(input.Version) > 64 {
		return nil, errors.New("invalid remote host identity")
	}
	if err := validateHostCapabilities(input.Capabilities); err != nil {
		return nil, err
	}
	now := s.now().UTC()
	host := Host{ID: input.ID, DeviceFingerprint: input.DeviceFingerprint, DisplayName: input.DisplayName,
		Version: input.Version, Capabilities: input.Capabilities, Online: true, LastSeenAt: now}
	if err := s.repo.UpsertHost(host); err != nil {
		return nil, err
	}
	_ = s.audit("", "host", host.ID, "remote.host.registered", map[string]any{"version": host.Version})

	// Requests created while the PC was offline advance only when a real host
	// heartbeat arrives. This preserves the state machine without inventing an
	// online status.
	s.promoteWaitingHost(host.ID, now)
	return &host, nil
}

// RegisterHostCredential bootstraps a per-host operational credential. The
// raw token is returned only for a new credential or an explicit rotation.
// Re-registering an existing host never reveals or silently replaces it.
func (s *Service) RegisterHostCredential(input RegisterHostInput) (*HostRegistrationResult, error) {
	host, err := s.RegisterHost(input)
	if err != nil {
		return nil, err
	}

	s.credentialMu.Lock()
	defer s.credentialMu.Unlock()

	_, _, credentialErr := s.repo.HostCredentialHash(host.ID)
	needsCredential := errors.Is(credentialErr, ErrNotFound)
	if credentialErr != nil && !needsCredential {
		return nil, credentialErr
	}
	if !needsCredential && !input.RotateCredential {
		return &HostRegistrationResult{Host: *host}, nil
	}

	token, err := generateHostCredential()
	if err != nil {
		return nil, err
	}
	now := s.now().UTC()
	if err := s.repo.SetHostCredential(host.ID, hashHostCredential(token), now); err != nil {
		return nil, err
	}
	eventType := "remote.host.credential_issued"
	if !needsCredential {
		eventType = "remote.host.credential_rotated"
	}
	_ = s.audit("", "host", host.ID, eventType, nil)
	return &HostRegistrationResult{Host: *host, HostToken: token}, nil
}

// credentialMaxAge 定义 host credential 的最大有效期。超过此期限的 credential
// 会被拒绝(host 必须重新轮换),限制被窃取的 credential 的可用窗口。
const credentialMaxAge = 7 * 24 * time.Hour

func (s *Service) AuthenticateHost(hostID, token string) error {
	hostID = strings.TrimSpace(hostID)
	if hostID == "" || token == "" {
		return ErrUnauthorized
	}
	storedHash, revoked, err := s.repo.HostCredentialHash(hostID)
	if err != nil || revoked {
		return ErrUnauthorized
	}
	presentedHash := hashHostCredential(token)
	if subtle.ConstantTimeCompare([]byte(storedHash), []byte(presentedHash)) != 1 {
		return ErrUnauthorized
	}
	host, err := s.repo.GetHost(hostID)
	if err != nil || host.RevokedAt != nil {
		return ErrUnauthorized
	}
	// 安全加固:credential 过期检查。超过 7 天的 credential 被拒绝,
	// host 必须通过 RegisterHostCredential(RotateCredential=true) 重新轮换。
	if age, ageErr := s.repo.HostCredentialAge(hostID); ageErr == nil {
		if s.now().UTC().Sub(age) > credentialMaxAge {
			_ = s.audit("", "host", hostID, "remote.host.credential_expired", nil)
			return ErrUnauthorized
		}
	}
	return nil
}

func (s *Service) RevokeHostCredential(hostID string) error {
	hostID = strings.TrimSpace(hostID)
	if hostID == "" {
		return ErrNotFound
	}
	if err := s.repo.RevokeHostCredential(hostID, s.now().UTC()); err != nil {
		return err
	}
	_ = s.audit("", "host", hostID, "remote.host.credential_revoked", nil)
	return nil
}

func generateHostCredential() (string, error) {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", fmt.Errorf("generate remote host credential: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(raw), nil
}

func hashHostCredential(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

func (s *Service) HeartbeatHost(hostID string) (*Host, error) {
	return s.HeartbeatHostWithCapabilities(hostID, nil)
}

func (s *Service) HeartbeatHostWithCapabilities(hostID string, input *HeartbeatHostInput) (*Host, error) {
	now := s.now().UTC()
	if input != nil && input.Capabilities != nil {
		if len(input.Version) > 64 {
			return nil, errors.New("invalid remote host version")
		}
		if err := validateHostCapabilities(*input.Capabilities); err != nil {
			return nil, err
		}
		current, err := s.repo.GetHost(hostID)
		if err != nil {
			return nil, err
		}
		current.Capabilities = *input.Capabilities
		if input.Version != "" {
			current.Version = input.Version
		}
		current.Online = true
		current.LastSeenAt = now
		if err := s.repo.UpsertHost(*current); err != nil {
			return nil, err
		}
	} else if err := s.repo.TouchHost(hostID, now); err != nil {
		return nil, err
	}
	s.promoteWaitingHost(hostID, now)
	return s.repo.GetHost(hostID)
}

func (s *Service) promoteWaitingHost(hostID string, now time.Time) {
	pending, err := s.repo.ListSessionsByHostState(hostID, StateWaitingHost)
	if err != nil {
		return
	}
	for _, item := range pending {
		advanced, transitionErr := s.repo.TransitionSession(item.ID, item.Revision,
			[]string{StateWaitingHost}, StateWaitingConsent, nil, "", "", now)
		if transitionErr == nil {
			_ = s.audit(item.ID, "host", hostID, "remote.session.consent_required", nil)
			s.emit(Event{Type: "remote.session.consent_required", Session: *advanced})
		}
	}
}

func (s *Service) ListHosts() ([]Host, error) {
	hosts, err := s.repo.ListHosts()
	if err != nil {
		return nil, err
	}
	cutoff := s.now().UTC().Add(-90 * time.Second)
	for i := range hosts {
		hosts[i].Online = hosts[i].Online && hosts[i].LastSeenAt.After(cutoff) && hosts[i].RevokedAt == nil
	}
	return hosts, nil
}

func (s *Service) GetHost(hostID string) (*Host, error) {
	host, err := s.repo.GetHost(hostID)
	if err != nil {
		return nil, err
	}
	if !host.LastSeenAt.After(s.now().UTC().Add(-90 * time.Second)) {
		host.Online = false
	}
	return host, nil
}

func (s *Service) RequestSession(controllerDeviceID string, input RequestSessionInput) (*Session, error) {
	if controllerDeviceID == "" {
		return nil, ErrUnauthorized
	}
	host, err := s.GetHost(strings.TrimSpace(input.HostID))
	if err != nil {
		return nil, err
	}
	requested, err := normalizeRequestedCapabilities(input.RequestedCapabilities)
	if err != nil {
		return nil, err
	}
	if !hostSupportsView(host.Capabilities) {
		return nil, ErrInvalidCapability
	}
	if containsCapability(requested, CapabilityInput) && !hostSupportsInput(host.Capabilities) {
		return nil, ErrInvalidCapability
	}
	now := s.now().UTC()
	// 心跳宽限窗口:host 每 10s 心跳一次,30s 内有心跳视为 online。
	// 这避免了 host 刚注册但还没下一次心跳时 session 卡在 waiting_host
	// 的延迟,同时 30s 无心跳能正确判定为离线。
	// 安全注意:此窗口必须 <= applyTimeout 里 StateWaitingHost 的 ttl(2min),
	// 否则过期 session 仍可能被推进到 waiting_consent。
	// A primary device can reach the host immediately. Any other paired phone
	// must first receive an explicit decision on the primary phone. In
	// particular, never expose that request to the Windows host before it is
	// approved.
	state := StateWaitingPrimary
	primaryApproved := false
	if input.PrimaryDevice {
		primaryApproved = true
		state = StateWaitingHost
		if host.RevokedAt == nil && host.LastSeenAt.After(now.Add(-30*time.Second)) {
			state = StateWaitingConsent
		}
	}
	if err := s.repo.UpsertAuthorization(uuid.NewString(), host.ID, controllerDeviceID, requested, now); err != nil {
		return nil, err
	}
	session := Session{ID: uuid.NewString(), HostID: host.ID, ControllerDeviceID: controllerDeviceID,
		State: state, Revision: 1, ControllerIsPrimary: input.PrimaryDevice, PrimaryApproved: primaryApproved, RequestedCapabilities: requested, GrantedCapabilities: []string{},
		RequestedAt: now, UpdatedAt: now}
	if err := s.repo.InsertSession(session); err != nil {
		return nil, err
	}
	_ = s.audit(session.ID, "controller", controllerDeviceID, "remote.session.requested",
		map[string]any{"state": state})
	s.emit(Event{Type: "remote.session.requested", Session: session})
	return &session, nil
}

func (s *Service) GetSessionForController(sessionID, controllerID string) (*Session, error) {
	session, err := s.repo.GetSession(sessionID)
	if err != nil {
		return nil, err
	}
	if controllerID == "" || session.ControllerDeviceID != controllerID {
		return nil, ErrUnauthorized
	}
	return s.applyTimeout(session)
}

func (s *Service) GetSessionForHost(sessionID, hostID string) (*Session, error) {
	session, err := s.repo.GetSession(sessionID)
	if err != nil {
		return nil, err
	}
	if hostID == "" || session.HostID != hostID {
		return nil, ErrUnauthorized
	}
	return s.applyTimeout(session)
}

func (s *Service) ListPendingForHost(hostID string) ([]Session, error) {
	if _, err := s.repo.GetHost(hostID); err != nil {
		return nil, err
	}
	items, err := s.repo.ListSessionsByHostState(hostID, StateWaitingConsent)
	if err != nil {
		return nil, err
	}
	out := make([]Session, 0, len(items))
	for index := range items {
		current, timeoutErr := s.applyTimeout(&items[index])
		if timeoutErr != nil {
			return nil, timeoutErr
		}
		if current.State == StateWaitingConsent {
			out = append(out, *current)
		}
	}
	return out, nil
}

// ListPendingForPrimary returns only requests which are waiting for the
// current primary phone. Device identity is checked by the API handler; the
// repository deliberately returns no historical or already-approved items.
func (s *Service) ListPendingForPrimary() ([]Session, error) {
	items, err := s.repo.ListSessionsByState(StateWaitingPrimary)
	if err != nil {
		return nil, err
	}
	out := make([]Session, 0, len(items))
	for index := range items {
		current, timeoutErr := s.applyTimeout(&items[index])
		if timeoutErr != nil {
			return nil, timeoutErr
		}
		if current.State == StateWaitingPrimary {
			out = append(out, *current)
		}
	}
	return out, nil
}

func (s *Service) ApproveByPrimary(sessionID, primaryDeviceID string, expectedRevision int64) (*Session, error) {
	if primaryDeviceID == "" {
		return nil, ErrUnauthorized
	}
	updated, err := s.repo.ApprovePrimarySession(sessionID, expectedRevision, s.now().UTC())
	if err != nil {
		return nil, err
	}
	_ = s.audit(sessionID, "primary_device", primaryDeviceID, "remote.session.primary_approved", map[string]any{"revision": updated.Revision})
	s.emit(Event{Type: "remote.session.primary_approved", Session: *updated})
	return updated, nil
}

func (s *Service) RejectByPrimary(sessionID, primaryDeviceID, reason string, expectedRevision int64) (*Session, error) {
	if primaryDeviceID == "" {
		return nil, ErrUnauthorized
	}
	current, err := s.repo.GetSession(sessionID)
	if err != nil {
		return nil, err
	}
	if expectedRevision == 0 {
		expectedRevision = current.Revision
	}
	reason = normalizeEndReason(reason, "rejected_by_primary")
	updated, err := s.repo.TransitionSession(sessionID, expectedRevision,
		[]string{StateWaitingPrimary}, StateEnded, nil, "", reason, s.now().UTC())
	if err != nil {
		return nil, err
	}
	_ = s.audit(sessionID, "primary_device", primaryDeviceID, "remote.session.primary_rejected", map[string]any{"reason": reason})
	s.emit(Event{Type: "remote.session.ended", Session: *updated})
	return updated, nil
}

func (s *Service) applyTimeout(session *Session) (*Session, error) {
	if IsTerminalState(session.State) {
		return session, nil
	}
	var ttl time.Duration
	var reason string
	switch session.State {
	case StateWaitingPrimary:
		ttl, reason = 2*time.Minute, "primary_approval_timeout"
	case StateWaitingHost:
		// 安全加固:缩短从 5min → 2min,减少未完成 session 占用资源窗口
		ttl, reason = 2*time.Minute, "host_timeout"
	case StateWaitingConsent:
		ttl, reason = 60*time.Second, "consent_timeout"
	case StateNegotiating:
		ttl, reason = 2*time.Minute, "negotiation_timeout"
	case StateReconnecting:
		ttl, reason = 30*time.Second, "reconnect_timeout"
	default:
		return session, nil
	}
	now := s.now().UTC()
	if session.UpdatedAt.Add(ttl).After(now) {
		return session, nil
	}
	updated, err := s.repo.TransitionSession(session.ID, session.Revision,
		[]string{session.State}, StateFailed, nil, "", reason, now)
	if err != nil {
		if errors.Is(err, ErrConflict) {
			return s.repo.GetSession(session.ID)
		}
		return nil, err
	}
	_ = s.audit(session.ID, "system", "remote-timeout", "remote.session.failed", map[string]any{"reason": reason})
	s.emit(Event{Type: "remote.session.failed", Session: *updated})
	return updated, nil
}

func (s *Service) Accept(sessionID, hostID string, expectedRevision int64) (*Session, TicketResult, error) {
	current, err := s.GetSessionForHost(sessionID, hostID)
	if err != nil {
		return nil, TicketResult{}, err
	}
	if expectedRevision == 0 {
		expectedRevision = current.Revision
	}
	updated, err := s.repo.TransitionSession(sessionID, expectedRevision,
		[]string{StateWaitingConsent}, StateNegotiating, current.RequestedCapabilities, "webrtc", "", s.now().UTC())
	if err != nil {
		return nil, TicketResult{}, err
	}
	ticket, err := s.tickets.Issue(*updated, hostID, RoleHost)
	if err != nil {
		return nil, TicketResult{}, err
	}
	_ = s.audit(sessionID, "host", hostID, "remote.session.accepted", map[string]any{"revision": updated.Revision})
	s.emit(Event{Type: "remote.session.accepted", Session: *updated})
	return updated, ticket, nil
}

func (s *Service) Reject(sessionID, hostID, reason string, expectedRevision int64) (*Session, error) {
	current, err := s.GetSessionForHost(sessionID, hostID)
	if err != nil {
		return nil, err
	}
	if expectedRevision == 0 {
		expectedRevision = current.Revision
	}
	reason = normalizeEndReason(reason, "rejected_by_host")
	updated, err := s.repo.TransitionSession(sessionID, expectedRevision,
		[]string{StateWaitingHost, StateWaitingConsent}, StateEnded, nil, "", reason, s.now().UTC())
	if err != nil {
		return nil, err
	}
	_ = s.audit(sessionID, "host", hostID, "remote.session.rejected", map[string]any{"reason": reason})
	s.emit(Event{Type: "remote.session.ended", Session: *updated})
	return updated, nil
}

func (s *Service) EndByController(sessionID, controllerID, reason string, expectedRevision int64) (*Session, error) {
	current, err := s.GetSessionForController(sessionID, controllerID)
	if err != nil {
		return nil, err
	}
	return s.end(current, "controller", controllerID, reason, expectedRevision)
}

func (s *Service) EndByHost(sessionID, hostID, reason string, expectedRevision int64) (*Session, error) {
	current, err := s.GetSessionForHost(sessionID, hostID)
	if err != nil {
		return nil, err
	}
	return s.end(current, "host", hostID, reason, expectedRevision)
}

func (s *Service) end(current *Session, actorType, actorID, reason string, expectedRevision int64) (*Session, error) {
	if IsTerminalState(current.State) {
		return current, nil
	}
	if expectedRevision == 0 {
		expectedRevision = current.Revision
	}
	reason = normalizeEndReason(reason, "ended_by_user")
	updated, err := s.repo.TransitionSession(current.ID, expectedRevision,
		[]string{StateRequesting, StateWaitingPrimary, StateWaitingHost, StateWaitingConsent, StateNegotiating,
			StateConnectedView, StateConnectedControl, StateReconnecting, StateEnding},
		StateEnded, nil, "", reason, s.now().UTC())
	if err != nil {
		return nil, err
	}
	_ = s.audit(current.ID, actorType, actorID, "remote.session.ended", map[string]any{"reason": reason})
	s.emit(Event{Type: "remote.session.ended", Session: *updated})
	return updated, nil
}

func (s *Service) MarkConnected(sessionID, hostID string, expectedRevision int64) (*Session, error) {
	current, err := s.GetSessionForHost(sessionID, hostID)
	if err != nil {
		return nil, err
	}
	if expectedRevision == 0 {
		expectedRevision = current.Revision
	}
	connectedState := StateConnectedView
	if containsCapability(current.GrantedCapabilities, CapabilityInput) {
		connectedState = StateConnectedControl
	}
	updated, err := s.repo.TransitionSession(sessionID, expectedRevision,
		[]string{StateNegotiating, StateReconnecting}, connectedState,
		current.GrantedCapabilities, "webrtc", "", s.now().UTC())
	if err != nil {
		return nil, err
	}
	_ = s.audit(sessionID, "host", hostID, "remote.session.connected", map[string]any{"transport": "webrtc"})
	s.emit(Event{Type: "remote.session.connected", Session: *updated})
	return updated, nil
}

// MarkReconnecting moves an established media session back to negotiation when
// the last authenticated signaling connection for either endpoint disappears.
// Waiting/negotiating sessions are deliberately not advanced here: losing a
// signaling socket before the first connection does not prove that media had
// ever been established.
func (s *Service) MarkReconnecting(sessionID, endpointID, role string, expectedRevision int64) (*Session, error) {
	var current *Session
	var err error
	if role == RoleController {
		current, err = s.GetSessionForController(sessionID, endpointID)
	} else if role == RoleHost {
		current, err = s.GetSessionForHost(sessionID, endpointID)
	} else {
		return nil, ErrUnauthorized
	}
	if err != nil {
		return nil, err
	}
	if current.State == StateReconnecting || IsTerminalState(current.State) {
		return current, nil
	}
	if expectedRevision == 0 {
		expectedRevision = current.Revision
	}
	updated, err := s.repo.TransitionSession(sessionID, expectedRevision,
		[]string{StateConnectedView, StateConnectedControl}, StateReconnecting,
		current.GrantedCapabilities, current.TransportType, "", s.now().UTC())
	if err != nil {
		return nil, err
	}
	_ = s.audit(sessionID, role, endpointID, "remote.session.reconnecting", map[string]any{"transport": current.TransportType})
	s.emit(Event{Type: "remote.session.reconnecting", Session: *updated})
	return updated, nil
}

func (s *Service) RefreshTicket(sessionID, endpointID, role string) (TicketResult, error) {
	var session *Session
	var err error
	if role == RoleController {
		session, err = s.GetSessionForController(sessionID, endpointID)
	} else if role == RoleHost {
		session, err = s.GetSessionForHost(sessionID, endpointID)
	} else {
		return TicketResult{}, ErrUnauthorized
	}
	if err != nil {
		return TicketResult{}, err
	}
	if session.State != StateNegotiating && session.State != StateReconnecting {
		return TicketResult{}, ErrConflict
	}
	return s.tickets.Issue(*session, endpointID, role)
}

func (s *Service) ConsumeTicket(ticket, sessionID, endpointID, role string, revision int64) (*TicketClaims, error) {
	session, err := s.repo.GetSession(sessionID)
	if err != nil {
		return nil, err
	}
	if session.Revision != revision || (session.State != StateNegotiating && session.State != StateReconnecting) {
		return nil, ErrConflict
	}
	if role == RoleController && session.ControllerDeviceID != endpointID {
		return nil, ErrUnauthorized
	}
	if role == RoleHost && session.HostID != endpointID {
		return nil, ErrUnauthorized
	}
	return s.tickets.ValidateAndConsume(ticket, sessionID, endpointID, role, revision)
}

func (s *Service) ListAuditForController(controllerID, hostID string, limit int) ([]AuditEvent, error) {
	if controllerID == "" {
		return nil, ErrUnauthorized
	}
	return s.repo.ListAudit(controllerID, hostID, limit)
}

func (s *Service) audit(sessionID, actorType, actorID, eventType string, metadata map[string]any) error {
	safe := make(map[string]any)
	for key, value := range metadata {
		switch key {
		case "state", "reason", "transport", "revision", "version", "error_code":
			safe[key] = value
		}
	}
	return s.repo.InsertAudit(AuditEvent{ID: uuid.NewString(), SessionID: sessionID,
		ActorType: actorType, ActorID: actorID, EventType: eventType, SafeMetadata: safe, CreatedAt: s.now().UTC()})
}

func validateHostCapabilities(c HostCapabilities) error {
	if c.ProtocolVersion != ProtocolVersion || c.Monitors < 0 || c.Monitors > 32 {
		return errors.New("unsupported remote host capabilities")
	}
	for _, group := range [][]string{c.Capture, c.VideoCodecs, c.Transports, c.Input} {
		if len(group) > 16 {
			return errors.New("too many remote host capabilities")
		}
		for _, item := range group {
			if strings.TrimSpace(item) == "" || len(item) > 64 {
				return errors.New("invalid remote host capability")
			}
		}
	}
	return nil
}

func hostSupportsView(capabilities HostCapabilities) bool {
	if capabilities.Monitors <= 0 || len(capabilities.Capture) == 0 {
		return false
	}
	h264 := false
	for _, codec := range capabilities.VideoCodecs {
		if strings.EqualFold(codec, "h264") {
			h264 = true
		}
	}
	webrtc := false
	for _, transport := range capabilities.Transports {
		if strings.EqualFold(transport, "webrtc") {
			webrtc = true
		}
	}
	return h264 && webrtc
}

func normalizeRequestedCapabilities(values []string) ([]string, error) {
	if len(values) == 0 {
		return []string{CapabilityView}, nil
	}
	// Validate each requested capability against the known set.
	valid := map[string]bool{CapabilityView: true, CapabilityInput: true}
	seen := make(map[string]bool)
	for _, v := range values {
		v = strings.TrimSpace(v)
		if !valid[v] || seen[v] {
			return nil, ErrInvalidCapability
		}
		seen[v] = true
	}
	// "view" must always be present.
	if !seen[CapabilityView] {
		return nil, ErrInvalidCapability
	}
	canonical := []string{CapabilityView}
	if seen[CapabilityInput] {
		canonical = append(canonical, CapabilityInput)
	}
	return canonical, nil
}

func containsCapability(values []string, capability string) bool {
	for _, value := range values {
		if value == capability {
			return true
		}
	}
	return false
}

func hostSupportsInput(capabilities HostCapabilities) bool {
	hasPointer := false
	hasKeyboard := false
	for _, value := range capabilities.Input {
		switch strings.ToLower(strings.TrimSpace(value)) {
		case "pointer":
			hasPointer = true
		case "keyboard":
			hasKeyboard = true
		}
	}
	return hasPointer && hasKeyboard
}

func normalizeEndReason(value, fallback string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		value = fallback
	}
	if len(value) > 64 {
		value = value[:64]
	}
	for _, r := range value {
		if !(r == '_' || r == '-' || r == '.' || r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9') {
			return fallback
		}
	}
	return value
}

func (s *Service) String() string {
	return fmt.Sprintf("remote service protocol v%d", ProtocolVersion)
}
