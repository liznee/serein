package api

import (
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"

	"serein/internal/store"

	"github.com/google/uuid"
)

// DeviceHandler 设备配对 HTTP 处理器。
type DeviceHandler struct {
	repo                *store.DeviceRepo
	pairCode            string
	pushDeliveryEnabled bool
}

func NewDeviceHandler(repo *store.DeviceRepo, pairCode string) *DeviceHandler {
	return &DeviceHandler{repo: repo, pairCode: pairCode}
}

// SetPushDeliveryEnabled tells the phone whether registering a Push Kit token
// is enough for this backend to deliver system notifications. A self-hosted
// backend without Huawei credentials keeps using the existing ntfy fallback.
func (h *DeviceHandler) SetPushDeliveryEnabled(enabled bool) {
	h.pushDeliveryEnabled = enabled
}

type pairReq struct {
	DeviceName string `json:"device_name"`
	PairCode   string `json:"pair_code"`
}

type registerPushTokenReq struct {
	PushToken string `json:"push_token"`
}

// Pair POST /devices/pair —— 首次配对换取 CLIENT_TOKEN。
// 匹配 pair_code 后将设备注册入库,返回专属 CLIENT_TOKEN。
func (h *DeviceHandler) Pair(w http.ResponseWriter, r *http.Request) {
	if h.pairCode == "" {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "pairing is not configured"})
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 4<<10)
	var req pairReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid json"})
		return
	}
	if req.DeviceName == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing device_name"})
		return
	}
	if len(req.DeviceName) > 128 || !isPrintable(req.DeviceName) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid device_name"})
		return
	}
	if req.PairCode != h.pairCode {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "invalid pair_code"})
		return
	}

	id := uuid.NewString()
	token := uuid.NewString()

	dev, err := h.repo.Pair(id, req.DeviceName, token)
	if err != nil {
		if errors.Is(err, store.ErrDeviceAlreadyPaired) {
			// Do not expose the currently paired device's name or identifier to a
			// device that has not authenticated yet.
			writeJSON(w, http.StatusConflict, map[string]string{"error": "DEVICE_ALREADY_PAIRED"})
			return
		}
		slog.Error("device pair failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		return
	}

	writeJSON(w, http.StatusCreated, map[string]string{
		"device_id":    dev.ID,
		"device_name":  dev.DeviceName,
		"client_token": dev.ClientToken,
	})
}

// UnpairCurrent DELETE /devices/current removes only the authenticated phone.
// Once it succeeds, the next phone may use the normal QR pairing flow.
func (h *DeviceHandler) UnpairCurrent(w http.ResponseWriter, r *http.Request) {
	device := authenticatedDevice(r)
	if device == nil {
		unauthorized(w)
		return
	}
	if err := h.repo.Unpair(device.ClientToken); err != nil {
		slog.Error("device unpair failed", "error", err, "device_id", device.ID)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		return
	}
	slog.Info("device unpaired", "device_id", device.ID, "device_name", device.DeviceName)
	w.WriteHeader(http.StatusNoContent)
}

// RegisterPushToken PUT /devices/current/push-token stores the HarmonyOS Push
// Kit token for the authenticated phone. It is intentionally write-only: the
// response never echoes the token and server logs contain only the device ID.
func (h *DeviceHandler) RegisterPushToken(w http.ResponseWriter, r *http.Request) {
	device := authenticatedDevice(r)
	if device == nil {
		unauthorized(w)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 8<<10)
	var req registerPushTokenReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid json"})
		return
	}
	// Push Kit currently returns a roughly 112-character opaque token, but its
	// documented length may change. Keep a conservative bound and reject control
	// characters so the value cannot become a log/header injection primitive.
	if len(req.PushToken) < 16 || len(req.PushToken) > 4096 || !isPrintable(req.PushToken) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid push_token"})
		return
	}
	if err := h.repo.SetPushToken(device.ID, req.PushToken); err != nil {
		if errors.Is(err, store.ErrDeviceNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "device not found"})
			return
		}
		slog.Error("push token registration failed", "error", err, "device_id", device.ID)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		return
	}
	slog.Info("push token registered", "device_id", device.ID)
	writeJSON(w, http.StatusOK, map[string]bool{
		"registered":       true,
		"delivery_enabled": h.pushDeliveryEnabled,
	})
}

// RegisterPrimary POST /v1/devices/primary/register
// 将当前已认证设备标记为主设备。同一时间只有一台设备可以是主设备，
// 设置新主设备会自动取消旧主设备标记。
// 主设备拥有远程控制权限——只有主设备可以发起远程桌面会话。
func (h *DeviceHandler) RegisterPrimary(w http.ResponseWriter, r *http.Request) {
	device := authenticatedDevice(r)
	if device == nil {
		unauthorized(w)
		return
	}
	if err := h.repo.SetPrimary(device.ID); err != nil {
		if errors.Is(err, store.ErrDeviceNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "device not found"})
			return
		}
		slog.Error("set primary device failed", "error", err, "device_id", device.ID)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		return
	}
	slog.Info("primary device registered", "device_id", device.ID, "device_name", device.DeviceName)
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"device_id":   device.ID,
		"device_name": device.DeviceName,
		"is_primary":  true,
	})
}

// GetPrimaryStatus GET /v1/devices/primary
// 返回当前已认证设备是否为主设备。
func (h *DeviceHandler) GetPrimaryStatus(w http.ResponseWriter, r *http.Request) {
	device := authenticatedDevice(r)
	if device == nil {
		unauthorized(w)
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"device_id":   device.ID,
		"device_name": device.DeviceName,
		"is_primary":  device.IsPrimary,
	})
}

// ClearPrimary DELETE /v1/devices/primary
// 取消当前已认证设备的主设备标记。
// 用户主动放弃远程控制发起权限时调用。操作幂等——即使设备本来就不是主设备也返回 200。
func (h *DeviceHandler) ClearPrimary(w http.ResponseWriter, r *http.Request) {
	device := authenticatedDevice(r)
	if device == nil {
		unauthorized(w)
		return
	}
	if err := h.repo.ClearPrimary(device.ID); err != nil {
		slog.Error("clear primary device failed", "error", err, "device_id", device.ID)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		return
	}
	slog.Info("primary device cleared", "device_id", device.ID, "device_name", device.DeviceName)
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"device_id":   device.ID,
		"device_name": device.DeviceName,
		"is_primary":  false,
	})
}
