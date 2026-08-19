package remote

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

const ticketAudience = "serein-remote"

type TicketIssuer struct {
	repo *Repository
	key  []byte
	now  func() time.Time
	ttl  time.Duration
}

func NewTicketIssuer(repo *Repository, key []byte) (*TicketIssuer, error) {
	if len(key) < 32 {
		return nil, errors.New("remote ticket signing key must be at least 32 bytes")
	}
	return &TicketIssuer{repo: repo, key: append([]byte(nil), key...), now: time.Now, ttl: 90 * time.Second}, nil
}

func NewEphemeralTicketIssuer(repo *Repository) (*TicketIssuer, error) {
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		return nil, fmt.Errorf("generate remote ticket key: %w", err)
	}
	return NewTicketIssuer(repo, key)
}

func (i *TicketIssuer) Issue(session Session, endpointID, role string) (TicketResult, error) {
	if endpointID == "" || (role != RoleController && role != RoleHost) {
		return TicketResult{}, errors.New("invalid remote ticket endpoint")
	}
	now := i.now().UTC()
	_ = i.repo.DeleteExpiredTicketNonces(now)
	expires := now.Add(i.ttl)
	nonceBytes := make([]byte, 24)
	if _, err := rand.Read(nonceBytes); err != nil {
		return TicketResult{}, fmt.Errorf("generate remote ticket nonce: %w", err)
	}
	nonce := base64.RawURLEncoding.EncodeToString(nonceBytes)
	claims := TicketClaims{
		Audience: ticketAudience, SessionID: session.ID, EndpointID: endpointID,
		Role: role, Capabilities: append([]string(nil), session.GrantedCapabilities...),
		Revision: session.Revision, Nonce: nonce, IssuedAt: now.Unix(), ExpiresAt: expires.Unix(),
	}
	payload, err := json.Marshal(claims)
	if err != nil {
		return TicketResult{}, err
	}
	payloadPart := base64.RawURLEncoding.EncodeToString(payload)
	signature := i.sign(payloadPart)
	token := payloadPart + "." + base64.RawURLEncoding.EncodeToString(signature)
	if err := i.repo.CreateTicketNonce(hashNonce(nonce), session.ID, endpointID, role, session.Revision, expires, now); err != nil {
		return TicketResult{}, err
	}
	return TicketResult{Ticket: token, ExpiresAt: expires, Revision: session.Revision}, nil
}

// ValidateAndConsume verifies signature, scope, expiry and the single-use nonce.
// The raw ticket is never stored or logged.
func (i *TicketIssuer) ValidateAndConsume(token, sessionID, endpointID, role string, revision int64) (*TicketClaims, error) {
	if len(token) == 0 || len(token) > 4096 {
		return nil, errors.New("invalid remote ticket size")
	}
	parts := strings.Split(token, ".")
	if len(parts) != 2 {
		return nil, errors.New("invalid remote ticket format")
	}
	signature, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, errors.New("invalid remote ticket signature")
	}
	want := i.sign(parts[0])
	if len(signature) != len(want) || subtle.ConstantTimeCompare(signature, want) != 1 {
		return nil, errors.New("invalid remote ticket signature")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return nil, errors.New("invalid remote ticket payload")
	}
	var claims TicketClaims
	decoder := json.NewDecoder(strings.NewReader(string(payload)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&claims); err != nil {
		return nil, errors.New("invalid remote ticket claims")
	}
	now := i.now().UTC()
	if claims.Audience != ticketAudience || claims.SessionID != sessionID || claims.EndpointID != endpointID ||
		claims.Role != role || claims.Revision != revision || claims.Nonce == "" {
		return nil, errors.New("remote ticket scope mismatch")
	}
	if claims.ExpiresAt <= now.Unix() || claims.IssuedAt > now.Add(30*time.Second).Unix() {
		return nil, ErrTicketExpired
	}
	if err := i.repo.ConsumeTicketNonce(hashNonce(claims.Nonce), sessionID, endpointID, role, revision, now); err != nil {
		return nil, err
	}
	return &claims, nil
}

func (i *TicketIssuer) sign(payload string) []byte {
	mac := hmac.New(sha256.New, i.key)
	mac.Write([]byte(payload))
	return mac.Sum(nil)
}

func hashNonce(nonce string) string {
	sum := sha256.Sum256([]byte(nonce))
	return hex.EncodeToString(sum[:])
}
