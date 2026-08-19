package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"

	"github.com/go-chi/chi/v5"

	"serein/internal/remote"
)

const remoteJSONLimit = 64 * 1024

type remoteHandler struct {
	service *remote.Service
	hub     *remoteWSHub
}

func newRemoteHandler(service *remote.Service, hub *remoteWSHub) *remoteHandler {
	return &remoteHandler{service: service, hub: hub}
}

func (h *remoteHandler) RegisterHost(w http.ResponseWriter, r *http.Request) {
	var input remote.RegisterHostInput
	if err := decodeRemoteJSON(w, r, &input); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid remote host payload"})
		return
	}
	result, err := h.service.RegisterHostCredential(input)
	if err != nil {
		writeRemoteError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, result)
}

func (h *remoteHandler) RevokeHostCredential(w http.ResponseWriter, r *http.Request) {
	if err := h.service.RevokeHostCredential(chi.URLParam(r, "hostID")); err != nil {
		writeRemoteError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *remoteHandler) HeartbeatHost(w http.ResponseWriter, r *http.Request) {
	var input remote.HeartbeatHostInput
	if r.ContentLength != 0 {
		if err := decodeRemoteJSON(w, r, &input); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid remote heartbeat payload"})
			return
		}
	}
	host, err := h.service.HeartbeatHostWithCapabilities(chi.URLParam(r, "hostID"), &input)
	if err != nil {
		writeRemoteError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, host)
}

func (h *remoteHandler) PendingHostSessions(w http.ResponseWriter, r *http.Request) {
	sessions, err := h.service.ListPendingForHost(chi.URLParam(r, "hostID"))
	if err != nil {
		writeRemoteError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": sessions})
}

func (h *remoteHandler) ListHosts(w http.ResponseWriter, r *http.Request) {
	if authenticatedDevice(r) == nil {
		unauthorized(w)
		return
	}
	hosts, err := h.service.ListHosts()
	if err != nil {
		writeRemoteError(w, err)
		return
	}
	for i := range hosts {
		hosts[i].DeviceFingerprint = ""
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": hosts})
}

func (h *remoteHandler) HostCapabilities(w http.ResponseWriter, r *http.Request) {
	if authenticatedDevice(r) == nil {
		unauthorized(w)
		return
	}
	host, err := h.service.GetHost(chi.URLParam(r, "hostID"))
	if err != nil {
		writeRemoteError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"host_id": host.ID, "online": host.Online, "version": host.Version,
		"capabilities": host.Capabilities, "last_seen_at": host.LastSeenAt,
	})
}

func (h *remoteHandler) CreateSession(w http.ResponseWriter, r *http.Request) {
	device := authenticatedDevice(r)
	if device == nil {
		unauthorized(w)
		return
	}
	// 安全策略：只有主设备可以发起远程桌面会话。
	// 这防止非主设备的已配对手机随意发起远控请求。
	var input remote.RequestSessionInput
	if err := decodeRemoteJSON(w, r, &input); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid remote session payload"})
		return
	}
	input.PrimaryDevice = device.IsPrimary
	input.ControllerIsPrimary = device.IsPrimary
	session, err := h.service.RequestSession(device.ID, input)
	if err != nil {
		writeRemoteError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, session)
}

// PrimaryPendingSessions exposes pending cross-device control requests only to
// the currently registered primary device.
func (h *remoteHandler) PrimaryPendingSessions(w http.ResponseWriter, r *http.Request) {
	device := authenticatedDevice(r)
	if device == nil {
		unauthorized(w)
		return
	}
	if !device.IsPrimary {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "REMOTE_PRIMARY_REQUIRED"})
		return
	}
	sessions, err := h.service.ListPendingForPrimary()
	if err != nil {
		writeRemoteError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": sessions})
}

func (h *remoteHandler) ApprovePrimarySession(w http.ResponseWriter, r *http.Request) {
	device := authenticatedDevice(r)
	if device == nil {
		unauthorized(w)
		return
	}
	if !device.IsPrimary {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "REMOTE_PRIMARY_REQUIRED"})
		return
	}
	var input remoteRevisionRequest
	if err := decodeRemoteJSONAllowEmpty(w, r, &input); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid remote decision payload"})
		return
	}
	session, err := h.service.ApproveByPrimary(chi.URLParam(r, "sessionID"), device.ID, input.Revision)
	if err != nil {
		writeRemoteError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, session)
}

func (h *remoteHandler) RejectPrimarySession(w http.ResponseWriter, r *http.Request) {
	device := authenticatedDevice(r)
	if device == nil {
		unauthorized(w)
		return
	}
	if !device.IsPrimary {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "REMOTE_PRIMARY_REQUIRED"})
		return
	}
	var input remoteRevisionRequest
	if err := decodeRemoteJSONAllowEmpty(w, r, &input); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid remote decision payload"})
		return
	}
	session, err := h.service.RejectByPrimary(chi.URLParam(r, "sessionID"), device.ID, input.Reason, input.Revision)
	if err != nil {
		writeRemoteError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, session)
}

func (h *remoteHandler) GetSession(w http.ResponseWriter, r *http.Request) {
	device := authenticatedDevice(r)
	if device == nil {
		unauthorized(w)
		return
	}
	session, err := h.service.GetSessionForController(chi.URLParam(r, "sessionID"), device.ID)
	if err != nil {
		writeRemoteError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, session)
}

type remoteRevisionRequest struct {
	Revision int64  `json:"revision"`
	Reason   string `json:"reason,omitempty"`
}

func (h *remoteHandler) AcceptSession(w http.ResponseWriter, r *http.Request) {
	var input remoteRevisionRequest
	if err := decodeRemoteJSONAllowEmpty(w, r, &input); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid remote decision payload"})
		return
	}
	session, ticket, err := h.service.Accept(chi.URLParam(r, "sessionID"), chi.URLParam(r, "hostID"), input.Revision)
	if err != nil {
		writeRemoteError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"session": session, "ticket": ticket})
}

func (h *remoteHandler) RejectSession(w http.ResponseWriter, r *http.Request) {
	var input remoteRevisionRequest
	if err := decodeRemoteJSONAllowEmpty(w, r, &input); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid remote decision payload"})
		return
	}
	session, err := h.service.Reject(chi.URLParam(r, "sessionID"), chi.URLParam(r, "hostID"), input.Reason, input.Revision)
	if err != nil {
		writeRemoteError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, session)
}

func (h *remoteHandler) EndSessionByController(w http.ResponseWriter, r *http.Request) {
	device := authenticatedDevice(r)
	if device == nil {
		unauthorized(w)
		return
	}
	var input remoteRevisionRequest
	if err := decodeRemoteJSONAllowEmpty(w, r, &input); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid remote end payload"})
		return
	}
	session, err := h.service.EndByController(chi.URLParam(r, "sessionID"), device.ID, input.Reason, input.Revision)
	if err != nil {
		writeRemoteError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, session)
}

func (h *remoteHandler) EndSessionByHost(w http.ResponseWriter, r *http.Request) {
	var input remoteRevisionRequest
	if err := decodeRemoteJSONAllowEmpty(w, r, &input); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid remote end payload"})
		return
	}
	session, err := h.service.EndByHost(chi.URLParam(r, "sessionID"), chi.URLParam(r, "hostID"), input.Reason, input.Revision)
	if err != nil {
		writeRemoteError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, session)
}

func (h *remoteHandler) MarkConnected(w http.ResponseWriter, r *http.Request) {
	var input remoteRevisionRequest
	if err := decodeRemoteJSONAllowEmpty(w, r, &input); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid remote state payload"})
		return
	}
	session, err := h.service.MarkConnected(chi.URLParam(r, "sessionID"), chi.URLParam(r, "hostID"), input.Revision)
	if err != nil {
		writeRemoteError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, session)
}

func (h *remoteHandler) RefreshControllerTicket(w http.ResponseWriter, r *http.Request) {
	device := authenticatedDevice(r)
	if device == nil {
		unauthorized(w)
		return
	}
	ticket, err := h.service.RefreshTicket(chi.URLParam(r, "sessionID"), device.ID, remote.RoleController)
	if err != nil {
		writeRemoteError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, ticket)
}

func (h *remoteHandler) Audit(w http.ResponseWriter, r *http.Request) {
	device := authenticatedDevice(r)
	if device == nil {
		unauthorized(w)
		return
	}
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	events, err := h.service.ListAuditForController(device.ID, strings.TrimSpace(r.URL.Query().Get("host_id")), limit)
	if err != nil {
		writeRemoteError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": events})
}

func decodeRemoteJSON(w http.ResponseWriter, r *http.Request, target any) error {
	r.Body = http.MaxBytesReader(w, r.Body, remoteJSONLimit)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	var trailing any
	if decoder.Decode(&trailing) == nil {
		return errors.New("multiple JSON values")
	}
	return nil
}

func decodeRemoteJSONAllowEmpty(w http.ResponseWriter, r *http.Request, target any) error {
	if r.Body == nil || r.ContentLength == 0 {
		return nil
	}
	return decodeRemoteJSON(w, r, target)
}

func writeRemoteError(w http.ResponseWriter, err error) {
	status := http.StatusInternalServerError
	code := "REMOTE_INTERNAL"
	switch {
	case errors.Is(err, remote.ErrNotFound):
		status, code = http.StatusNotFound, "REMOTE_NOT_FOUND"
	case errors.Is(err, remote.ErrUnauthorized):
		status, code = http.StatusForbidden, "REMOTE_AUTH_FORBIDDEN"
	case errors.Is(err, remote.ErrConflict), errors.Is(err, remote.ErrTicketConsumed):
		status, code = http.StatusConflict, "REMOTE_STATE_CONFLICT"
	case errors.Is(err, remote.ErrTicketExpired):
		status, code = http.StatusUnauthorized, "REMOTE_AUTH_TICKET_EXPIRED"
	case errors.Is(err, remote.ErrInvalidCapability):
		status, code = http.StatusBadRequest, "REMOTE_CAPABILITY_UNSUPPORTED"
	default:
		if strings.Contains(err.Error(), "invalid remote") || strings.Contains(err.Error(), "unsupported remote") || strings.Contains(err.Error(), "too many remote") {
			status, code = http.StatusBadRequest, "REMOTE_INVALID_REQUEST"
		}
	}
	writeJSON(w, status, map[string]string{"error": code})
}
