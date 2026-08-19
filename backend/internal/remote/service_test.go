package remote

import (
	"errors"
	"strings"
	"testing"
	"time"

	"serein/internal/store"
)

func newRemoteTestService(t *testing.T) (*Service, *TicketIssuer) {
	t.Helper()
	db, err := store.Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	if _, err := store.NewDeviceRepo(db).Pair("phone-1", "phone", "client-token-1"); err != nil {
		t.Fatal(err)
	}
	repo := NewRepository(db)
	issuer, err := NewTicketIssuer(repo, []byte("0123456789abcdef0123456789abcdef"))
	if err != nil {
		t.Fatal(err)
	}
	return NewService(repo, issuer), issuer
}

func validHostInput() RegisterHostInput {
	return RegisterHostInput{
		ID: "host-1", DeviceFingerprint: "sha256:host-1", DisplayName: "My PC", Version: "0.1.0",
		Capabilities: HostCapabilities{ProtocolVersion: 1, Capture: []string{"dxgi-duplication"},
			VideoCodecs: []string{"h264"}, Transports: []string{"webrtc"}, HardwareEncoder: true,
			Input: []string{"pointer", "keyboard", "text"}, Monitors: 1},
	}
}

func TestRemoteHostCredentialIsOneTimeHashedRotatableAndRevocable(t *testing.T) {
	service, _ := newRemoteTestService(t)
	first, err := service.RegisterHostCredential(validHostInput())
	if err != nil || first.HostToken == "" {
		t.Fatalf("first registration=%#v err=%v", first, err)
	}
	storedHash, revoked, err := service.repo.HostCredentialHash("host-1")
	if err != nil || revoked || storedHash == first.HostToken || storedHash != hashHostCredential(first.HostToken) {
		t.Fatalf("stored credential hash=%q revoked=%v err=%v", storedHash, revoked, err)
	}
	if err := service.AuthenticateHost("host-1", first.HostToken); err != nil {
		t.Fatalf("authenticate first token: %v", err)
	}

	repeated, err := service.RegisterHostCredential(validHostInput())
	if err != nil || repeated.HostToken != "" {
		t.Fatalf("repeat registration leaked/replaced credential: %#v err=%v", repeated, err)
	}
	rotation := validHostInput()
	rotation.RotateCredential = true
	rotated, err := service.RegisterHostCredential(rotation)
	if err != nil || rotated.HostToken == "" || rotated.HostToken == first.HostToken {
		t.Fatalf("rotation=%#v err=%v", rotated, err)
	}
	if err := service.AuthenticateHost("host-1", first.HostToken); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("old token auth err=%v", err)
	}
	if err := service.AuthenticateHost("host-1", rotated.HostToken); err != nil {
		t.Fatalf("rotated token auth: %v", err)
	}
	if err := service.RevokeHostCredential("host-1"); err != nil {
		t.Fatal(err)
	}
	if err := service.AuthenticateHost("host-1", rotated.HostToken); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("revoked token auth err=%v", err)
	}
}

func TestRemoteHostCredentialExpiresAfterMaxAge(t *testing.T) {
	service, _ := newRemoteTestService(t)
	reg, err := service.RegisterHostCredential(validHostInput())
	if err != nil || reg.HostToken == "" {
		t.Fatalf("registration=%#v err=%v", reg, err)
	}
	// 初始认证成功
	if err := service.AuthenticateHost("host-1", reg.HostToken); err != nil {
		t.Fatalf("initial auth: %v", err)
	}
	// 模拟时间前进 8 天(超过 7 天有效期)
	base := service.now()
	service.now = func() time.Time { return base.Add(8 * 24 * time.Hour) }
	// 过期 credential 应被拒绝
	if err := service.AuthenticateHost("host-1", reg.HostToken); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("expired credential auth err=%v, want ErrUnauthorized", err)
	}
	// 轮换后新 credential 在当前时间应能认证
	rotation := validHostInput()
	rotation.RotateCredential = true
	rotated, err := service.RegisterHostCredential(rotation)
	if err != nil || rotated.HostToken == "" {
		t.Fatalf("rotation=%#v err=%v", rotated, err)
	}
	if err := service.AuthenticateHost("host-1", rotated.HostToken); err != nil {
		t.Fatalf("rotated credential auth: %v", err)
	}
}

func TestRemoteReadOnlyLifecycleAndTicketReplayProtection(t *testing.T) {
	service, _ := newRemoteTestService(t)
	if _, err := service.RegisterHost(validHostInput()); err != nil {
		t.Fatal(err)
	}
	session, err := service.RequestSession("phone-1", RequestSessionInput{HostID: "host-1", RequestedCapabilities: []string{"view"}, PrimaryDevice: true})
	if err != nil {
		t.Fatal(err)
	}
	if session.State != StateWaitingConsent || session.Revision != 1 {
		t.Fatalf("unexpected requested state: %#v", session)
	}
	accepted, hostTicket, err := service.Accept(session.ID, "host-1", session.Revision)
	if err != nil {
		t.Fatal(err)
	}
	if accepted.State != StateNegotiating || accepted.Revision != 2 || strings.Join(accepted.GrantedCapabilities, ",") != "view" {
		t.Fatalf("unexpected accepted state: %#v", accepted)
	}
	controllerTicket, err := service.RefreshTicket(session.ID, "phone-1", RoleController)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := service.ConsumeTicket(hostTicket.Ticket, session.ID, "host-1", RoleHost, 2); err != nil {
		t.Fatalf("consume host ticket: %v", err)
	}
	if _, err := service.ConsumeTicket(controllerTicket.Ticket, session.ID, "phone-1", RoleController, 2); err != nil {
		t.Fatalf("consume controller ticket: %v", err)
	}
	if _, err := service.ConsumeTicket(controllerTicket.Ticket, session.ID, "phone-1", RoleController, 2); !errors.Is(err, ErrTicketConsumed) {
		t.Fatalf("ticket replay = %v, want ErrTicketConsumed", err)
	}
	connected, err := service.MarkConnected(session.ID, "host-1", 2)
	if err != nil || connected.State != StateConnectedView || connected.Revision != 3 {
		t.Fatalf("connected=%#v err=%v", connected, err)
	}
	reconnecting, err := service.MarkReconnecting(session.ID, "phone-1", RoleController, 3)
	if err != nil || reconnecting.State != StateReconnecting || reconnecting.Revision != 4 {
		t.Fatalf("reconnecting=%#v err=%v", reconnecting, err)
	}
	if _, err := service.RefreshTicket(session.ID, "phone-1", RoleController); err != nil {
		t.Fatalf("refresh reconnect ticket: %v", err)
	}
	reconnected, err := service.MarkConnected(session.ID, "host-1", 4)
	if err != nil || reconnected.State != StateConnectedView || reconnected.Revision != 5 {
		t.Fatalf("reconnected=%#v err=%v", reconnected, err)
	}
	ended, err := service.EndByController(session.ID, "phone-1", "ended_by_user", 5)
	if err != nil || ended.State != StateEnded || ended.EndedAt == nil || ended.Revision != 6 {
		t.Fatalf("ended=%#v err=%v", ended, err)
	}
	if _, err := service.EndByController(session.ID, "phone-1", "ended_by_user", 5); err != nil {
		t.Fatalf("idempotent end should return terminal state: %v", err)
	}
}

func TestRemoteControlRequiresAdvertisedInputAndUsesControlState(t *testing.T) {
	service, _ := newRemoteTestService(t)
	host := validHostInput()
	host.Capabilities.Input = nil
	if _, err := service.RegisterHost(host); err != nil {
		t.Fatal(err)
	}
	if _, err := service.RequestSession("phone-1", RequestSessionInput{
		HostID: "host-1", RequestedCapabilities: []string{"input", "view"},
	}); !errors.Is(err, ErrInvalidCapability) {
		t.Fatalf("input request without advertised input err=%v", err)
	}

	capabilities := validHostInput().Capabilities
	updated, err := service.HeartbeatHostWithCapabilities("host-1", &HeartbeatHostInput{
		Version: "0.2.0", Capabilities: &capabilities,
	})
	if err != nil || updated.Version != "0.2.0" || !hostSupportsInput(updated.Capabilities) {
		t.Fatalf("updated host=%#v err=%v", updated, err)
	}
	session, err := service.RequestSession("phone-1", RequestSessionInput{
		HostID: "host-1", RequestedCapabilities: []string{"input", "view"}, PrimaryDevice: true,
	})
	if err != nil || strings.Join(session.RequestedCapabilities, ",") != "view,input" {
		t.Fatalf("control request=%#v err=%v", session, err)
	}
	accepted, _, err := service.Accept(session.ID, "host-1", session.Revision)
	if err != nil {
		t.Fatal(err)
	}
	connected, err := service.MarkConnected(session.ID, "host-1", accepted.Revision)
	if err != nil || connected.State != StateConnectedControl ||
		strings.Join(connected.GrantedCapabilities, ",") != "view,input" {
		t.Fatalf("control connected=%#v err=%v", connected, err)
	}
}

func TestRemoteRejectsControlAndCrossDeviceAccess(t *testing.T) {
	service, _ := newRemoteTestService(t)
	if _, err := service.RegisterHost(validHostInput()); err != nil {
		t.Fatal(err)
	}
	if _, err := service.RequestSession("phone-1", RequestSessionInput{HostID: "host-1", RequestedCapabilities: []string{"pointer"}}); !errors.Is(err, ErrInvalidCapability) {
		t.Fatalf("control capability err=%v", err)
	}
	session, err := service.RequestSession("phone-1", RequestSessionInput{HostID: "host-1", PrimaryDevice: true})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := service.GetSessionForController(session.ID, "phone-2"); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("cross-device get err=%v", err)
	}
	if _, _, err := service.Accept(session.ID, "other-host", 1); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("cross-host accept err=%v", err)
	}
	if _, err := service.Reject(session.ID, "host-1", "rejected_by_host", 99); !errors.Is(err, ErrConflict) {
		t.Fatalf("stale revision err=%v", err)
	}
}

func TestRemoteRejectsViewWhenHostHasNoVerifiedMediaCapability(t *testing.T) {
	service, _ := newRemoteTestService(t)
	host := validHostInput()
	host.Capabilities.VideoCodecs = nil
	if _, err := service.RegisterHost(host); err != nil {
		t.Fatal(err)
	}
	if _, err := service.RequestSession("phone-1", RequestSessionInput{HostID: "host-1"}); !errors.Is(err, ErrInvalidCapability) {
		t.Fatalf("request without codec err=%v", err)
	}
}

func TestRemoteOfflineHostUsesWaitingHostUntilRegistration(t *testing.T) {
	service, _ := newRemoteTestService(t)
	base := time.Date(2026, 7, 19, 0, 0, 0, 0, time.UTC)
	service.now = func() time.Time { return base }
	if _, err := service.RegisterHost(validHostInput()); err != nil {
		t.Fatal(err)
	}
	service.now = func() time.Time { return base.Add(2 * time.Minute) }
	session, err := service.RequestSession("phone-1", RequestSessionInput{HostID: "host-1", PrimaryDevice: true})
	if err != nil {
		t.Fatal(err)
	}
	if session.State != StateWaitingHost {
		t.Fatalf("state=%s, want waiting_host", session.State)
	}
	if _, err := service.RegisterHost(validHostInput()); err != nil {
		t.Fatal(err)
	}
	advanced, err := service.GetSessionForController(session.ID, "phone-1")
	if err != nil || advanced.State != StateWaitingConsent || advanced.Revision != 2 {
		t.Fatalf("advanced=%#v err=%v", advanced, err)
	}
}

func TestRemoteTicketExpiresAndClaimsAreScoped(t *testing.T) {
	service, issuer := newRemoteTestService(t)
	base := time.Date(2026, 7, 19, 0, 0, 0, 0, time.UTC)
	service.now = func() time.Time { return base }
	issuer.now = service.now
	issuer.ttl = time.Second
	if _, err := service.RegisterHost(validHostInput()); err != nil {
		t.Fatal(err)
	}
	session, _ := service.RequestSession("phone-1", RequestSessionInput{HostID: "host-1", PrimaryDevice: true})
	accepted, ticket, err := service.Accept(session.ID, "host-1", 1)
	if err != nil {
		t.Fatal(err)
	}
	issuer.now = func() time.Time { return base.Add(2 * time.Second) }
	if _, err := issuer.ValidateAndConsume(ticket.Ticket, accepted.ID, "host-1", RoleHost, accepted.Revision); !errors.Is(err, ErrTicketExpired) {
		t.Fatalf("expired ticket err=%v", err)
	}
}

func TestRemoteConsentTimeoutFailsClosed(t *testing.T) {
	service, issuer := newRemoteTestService(t)
	base := time.Date(2026, 7, 19, 0, 0, 0, 0, time.UTC)
	service.now = func() time.Time { return base }
	issuer.now = service.now
	if _, err := service.RegisterHost(validHostInput()); err != nil {
		t.Fatal(err)
	}
	session, err := service.RequestSession("phone-1", RequestSessionInput{HostID: "host-1", PrimaryDevice: true})
	if err != nil {
		t.Fatal(err)
	}
	service.now = func() time.Time { return base.Add(61 * time.Second) }
	latest, err := service.GetSessionForController(session.ID, "phone-1")
	if err != nil {
		t.Fatal(err)
	}
	if latest.State != StateFailed || latest.EndReason != "consent_timeout" {
		t.Fatalf("latest=%#v", latest)
	}
	if _, _, err := service.Accept(session.ID, "host-1", session.Revision); !errors.Is(err, ErrConflict) {
		t.Fatalf("late accept err=%v", err)
	}
}

func TestRemoteNonPrimaryRequestWaitsForPrimaryApproval(t *testing.T) {
	service, _ := newRemoteTestService(t)
	if _, err := service.RegisterHost(validHostInput()); err != nil {
		t.Fatal(err)
	}
	session, err := service.RequestSession("phone-secondary", RequestSessionInput{HostID: "host-1"})
	if err != nil || session.State != StateWaitingPrimary || session.PrimaryApproved {
		t.Fatalf("request=%#v err=%v", session, err)
	}
	if pending, err := service.ListPendingForHost("host-1"); err != nil || len(pending) != 0 {
		t.Fatalf("host must not see unapproved request: %#v err=%v", pending, err)
	}
	pending, err := service.ListPendingForPrimary()
	if err != nil || len(pending) != 1 || pending[0].ID != session.ID {
		t.Fatalf("primary pending=%#v err=%v", pending, err)
	}
	approved, err := service.ApproveByPrimary(session.ID, "phone-primary", session.Revision)
	if err != nil || approved.State != StateWaitingConsent || !approved.PrimaryApproved || approved.Revision != 2 {
		t.Fatalf("approved=%#v err=%v", approved, err)
	}
	pending, err = service.ListPendingForHost("host-1")
	if err != nil || len(pending) != 1 || pending[0].ID != session.ID {
		t.Fatalf("host pending=%#v err=%v", pending, err)
	}
}
