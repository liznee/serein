package api

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"strconv"

	"serein/internal/risk"
	"serein/internal/store"

	"github.com/go-chi/chi/v5"
)

// ConfigHandler 白/黑名单 + 规则管理 HTTP 处理器。
type ConfigHandler struct {
	wl     *store.WhitelistRepo
	bl     *store.BlacklistRepo
	engine *risk.Engine
}

func NewConfigHandler(wl *store.WhitelistRepo, bl *store.BlacklistRepo, engine *risk.Engine) *ConfigHandler {
	return &ConfigHandler{wl: wl, bl: bl, engine: engine}
}

// ── 白名单 ──

// ListWhitelist GET /config/whitelist
func (h *ConfigHandler) ListWhitelist(w http.ResponseWriter, r *http.Request) {
	entries, err := h.wl.List()
	if err != nil {
		slog.Error("whitelist list failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		return
	}
	if entries == nil {
		entries = []*store.WhitelistEntry{}
	}
	writeJSON(w, http.StatusOK, entries)
}

// AddWhitelist POST /config/whitelist
func (h *ConfigHandler) AddWhitelist(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Pattern     string `json:"pattern"`
		Description string `json:"description"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid json"})
		return
	}
	if req.Pattern == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing pattern"})
		return
	}
	entry, err := h.wl.Add(req.Pattern, req.Description)
	if err != nil {
		slog.Error("whitelist add failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		return
	}
	writeJSON(w, http.StatusCreated, entry)
}

// RemoveWhitelist DELETE /config/whitelist/{id}
func (h *ConfigHandler) RemoveWhitelist(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.Atoi(chi.URLParam(r, "id"))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid id"})
		return
	}
	ok, err := h.wl.Remove(id)
	if err != nil {
		slog.Error("whitelist remove failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		return
	}
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// ── 黑名单 ──

// ListBlacklist GET /config/blacklist
func (h *ConfigHandler) ListBlacklist(w http.ResponseWriter, r *http.Request) {
	entries, err := h.bl.List()
	if err != nil {
		slog.Error("blacklist list failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		return
	}
	if entries == nil {
		entries = []*store.BlacklistEntry{}
	}
	writeJSON(w, http.StatusOK, entries)
}

// AddBlacklist POST /config/blacklist
func (h *ConfigHandler) AddBlacklist(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Pattern     string `json:"pattern"`
		Description string `json:"description"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid json"})
		return
	}
	if req.Pattern == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing pattern"})
		return
	}
	entry, err := h.bl.Add(req.Pattern, req.Description)
	if err != nil {
		slog.Error("blacklist add failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		return
	}
	writeJSON(w, http.StatusCreated, entry)
}

// RemoveBlacklist DELETE /config/blacklist/{id}
func (h *ConfigHandler) RemoveBlacklist(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.Atoi(chi.URLParam(r, "id"))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid id"})
		return
	}
	ok, err := h.bl.Remove(id)
	if err != nil {
		slog.Error("blacklist remove failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		return
	}
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// ── 规则热更新 ──

// GetRules GET /config/rules — 导出当前规则。
func (h *ConfigHandler) GetRules(w http.ResponseWriter, r *http.Request) {
	if h.engine == nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "engine not available"})
		return
	}
	rules := h.engine.Rules().Export()
	writeJSON(w, http.StatusOK, rules)
}

// UpdateRules PUT /config/rules — 热更新规则。
func (h *ConfigHandler) UpdateRules(w http.ResponseWriter, r *http.Request) {
	if h.engine == nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "engine not available"})
		return
	}
	body, err := io.ReadAll(r.Body)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "read body failed"})
		return
	}
	if err := h.engine.Rules().Reload(body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	rules := h.engine.Rules().Export()
	writeJSON(w, http.StatusOK, rules)
}
