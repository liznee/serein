package remote

import "time"

const (
	ProtocolVersion = 1

	StateRequesting = "requesting"
	// StateWaitingPrimary is used for a paired phone that is not the primary
	// device. The Windows host never sees this state.
	StateWaitingPrimary   = "waiting_primary"
	StateWaitingHost      = "waiting_host"
	StateWaitingConsent   = "waiting_consent"
	StateNegotiating      = "negotiating"
	StateConnectedView    = "connected_view"
	StateConnectedControl = "connected_control"
	StateReconnecting     = "reconnecting"
	StateEnding           = "ending"
	StateEnded            = "ended"
	StateFailed           = "failed"

	RoleController = "controller"
	RoleHost       = "host"

	CapabilityView  = "view"
	CapabilityInput = "input"
)

// HostCapabilities contains only facts reported by the Windows host. Unsupported
// capabilities are omitted instead of being represented by invented values.
type HostCapabilities struct {
	ProtocolVersion   int      `json:"protocol_version"`
	Capture           []string `json:"capture"`
	VideoCodecs       []string `json:"video_codecs"`
	Transports        []string `json:"transports"`
	HardwareEncoder   bool     `json:"hardware_encoder"`
	Input             []string `json:"input"`
	Monitors          int      `json:"monitors"`
	UnattendedEnabled bool     `json:"unattended_enabled"`
	SecureDesktop     bool     `json:"secure_desktop"`
}

type Host struct {
	ID                string           `json:"id"`
	DeviceFingerprint string           `json:"device_fingerprint,omitempty"`
	DisplayName       string           `json:"display_name"`
	Version           string           `json:"version"`
	Capabilities      HostCapabilities `json:"capabilities"`
	Online            bool             `json:"online"`
	LastSeenAt        time.Time        `json:"last_seen_at"`
	RevokedAt         *time.Time       `json:"revoked_at,omitempty"`
}

type Session struct {
	ID                    string     `json:"id"`
	HostID                string     `json:"host_id"`
	ControllerDeviceID    string     `json:"controller_device_id"`
	ControllerIsPrimary   bool       `json:"controller_is_primary"`
	PrimaryApproved       bool       `json:"primary_approved"`
	State                 string     `json:"state"`
	Revision              int64      `json:"revision"`
	RequestedCapabilities []string   `json:"requested_capabilities"`
	GrantedCapabilities   []string   `json:"granted_capabilities"`
	TransportType         string     `json:"transport_type,omitempty"`
	RequestedAt           time.Time  `json:"requested_at"`
	UpdatedAt             time.Time  `json:"updated_at"`
	StartedAt             *time.Time `json:"started_at,omitempty"`
	EndedAt               *time.Time `json:"ended_at,omitempty"`
	EndReason             string     `json:"end_reason,omitempty"`
}

type AuditEvent struct {
	ID           string         `json:"id"`
	SessionID    string         `json:"session_id,omitempty"`
	ActorType    string         `json:"actor_type"`
	ActorID      string         `json:"actor_id"`
	EventType    string         `json:"event_type"`
	SafeMetadata map[string]any `json:"safe_metadata"`
	ClientIP     string         `json:"client_ip,omitempty"`
	CreatedAt    time.Time      `json:"created_at"`
}

type TicketClaims struct {
	Audience     string   `json:"aud"`
	SessionID    string   `json:"session_id"`
	EndpointID   string   `json:"endpoint_id"`
	Role         string   `json:"role"`
	Capabilities []string `json:"capabilities"`
	Revision     int64    `json:"revision"`
	Nonce        string   `json:"nonce"`
	IssuedAt     int64    `json:"issued_at"`
	ExpiresAt    int64    `json:"expires_at"`
}

type RegisterHostInput struct {
	ID                string           `json:"id"`
	DeviceFingerprint string           `json:"device_fingerprint"`
	DisplayName       string           `json:"display_name"`
	Version           string           `json:"version"`
	Capabilities      HostCapabilities `json:"capabilities"`
	RotateCredential  bool             `json:"rotate_credential,omitempty"`
}

// HeartbeatHostInput lets an already-authenticated Host refresh facts that may
// change after an upgrade (for example, a newly installed WebRTC/input bridge).
// Identity fields remain immutable on this operational endpoint.
type HeartbeatHostInput struct {
	Version      string            `json:"version,omitempty"`
	Capabilities *HostCapabilities `json:"capabilities,omitempty"`
}

// HostRegistrationResult returns a credential only on first registration or
// an explicit rotation. Callers must persist HostToken immediately because the
// backend stores only its hash and cannot return it again.
type HostRegistrationResult struct {
	Host      Host   `json:"host"`
	HostToken string `json:"host_token,omitempty"`
}

type RequestSessionInput struct {
	HostID                string   `json:"host_id"`
	RequestedCapabilities []string `json:"requested_capabilities"`
	PrimaryDevice         bool     `json:"primary_device"`
	ControllerIsPrimary   bool     `json:"controller_is_primary"`
}

type TicketResult struct {
	Ticket    string    `json:"ticket"`
	ExpiresAt time.Time `json:"expires_at"`
	Revision  int64     `json:"revision"`
}

func IsTerminalState(state string) bool {
	return state == StateEnded || state == StateFailed
}
