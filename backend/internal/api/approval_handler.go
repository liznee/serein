package api

import (
	"encoding/json"
	"net/http"

	"serein/internal/approval"
	rdplog "serein/internal/log"
	"serein/internal/notify"
	"serein/internal/pushkit"
	"serein/internal/risk"
	"serein/internal/session"
	"serein/internal/store"

	"github.com/go-chi/chi/v5"
)

// Handler HTTP 请求处理器。
type Handler struct {
	svc          *approval.Service
	pub          *notify.Publisher
	engine       *risk.Engine
	sessionRepo  *store.SessionRepo
	log          *rdplog.Logger
	wsHub        *wsHub // WebSocket hub for approval_update broadcasts
	push         *pushkit.Dispatcher
	BuildVersion string
}

func NewHandler(svc *approval.Service, pub *notify.Publisher, engine *risk.Engine, sessionRepo *store.SessionRepo, logger *rdplog.Logger) *Handler {
	return &Handler{svc: svc, pub: pub, engine: engine, sessionRepo: sessionRepo, log: logger}
}

// SetWSHub injects the WebSocket hub for broadcasting approval_update events.
func (h *Handler) SetWSHub(hub *wsHub) {
	h.wsHub = hub
}

// SetPushDispatcher injects the optional Huawei Push Kit delivery worker.
func (h *Handler) SetPushDispatcher(dispatcher *pushkit.Dispatcher) {
	h.push = dispatcher
}

type createReq struct {
	SessionID  string `json:"session_id"`
	ToolName   string `json:"tool_name"`
	Command    string `json:"command"`
	Cwd        string `json:"cwd"`
	RiskLevel  string `json:"risk_level"`
	RuleReason string `json:"rule_reason"`
	Project    string `json:"project"`
	Diff       string `json:"diff,omitempty"`
}

// Create POST /approvals —— hook 提交审批,后端二次分级 + 建记录 + 推送 ntfy。
func (h *Handler) Create(w http.ResponseWriter, r *http.Request) {
	var req createReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid json"})
		return
	}
	if req.Command == "" && req.ToolName == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing tool_name/command"})
		return
	}
	project := req.Project
	if project == "" {
		project = "default"
	}

	// Phase 2: 后端二次分级(检查会话记忆/白名单)
	level, reason := h.engine.Classify(req.SessionID, req.ToolName, req.Command)
	finalLevel := level
	finalReason := reason
	createReqVal := approval.CreateReq{
		SessionID: req.SessionID, ToolName: req.ToolName, Command: req.Command,
		Cwd: req.Cwd, RiskLevel: string(level), RuleReason: reason, Project: project,
		Diff: req.Diff,
	}

	if level != risk.Red {
		// 会话记忆或白名单放行 → 创建自动审批记录
		rec, err := h.svc.Create(r.Context(), createReqVal)
		if err != nil {
			h.log.DBError("create-auto-approve", err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
			return
		}
		if _, err := h.svc.Decide(r.Context(), rec.ID, approval.DecisionAllow, "auto(memo/whitelist)"); err != nil {
			h.log.DBError("auto-decide", err)
		} else {
			h.log.AutoApproved(rec.ID, req.SessionID, string(level))
		}
		writeJSON(w, http.StatusCreated, map[string]string{"id": rec.ID, "decision": approval.DecisionAllow, "auto": "true"})
		return
	}

	// ── 权限模式评估 ──
	// 根据手机端设置的权限模式 (yolo / safe_yolo / accept_edits 等)
	// 决定是否自动批准/拒绝，还是需要人工审批。
	permMode := session.PermModeDefault
	if h.wsHub != nil {
		permMode = h.wsHub.GetPermissionMode()
	}
	permDecision := session.EvaluatePermission(permMode, string(finalLevel), req.ToolName, nil, nil)

	if permDecision == session.DecisionAutoApprove {
		// 模式允许自动批准 (如 yolo / bypass_permissions)
		rec, err := h.svc.Create(r.Context(), createReqVal)
		if err != nil {
			h.log.DBError("create-mode-auto-approve", err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
			return
		}
		if _, err := h.svc.Decide(r.Context(), rec.ID, approval.DecisionAllow, "auto(mode:"+permMode+")"); err != nil {
			h.log.DBError("auto-decide", err)
		} else {
			h.log.AutoApproved(rec.ID, req.SessionID, string(finalLevel))
		}
		writeJSON(w, http.StatusCreated, map[string]string{"id": rec.ID, "decision": approval.DecisionAllow, "auto": "true"})
		return
	}

	if permDecision == session.DecisionAutoDeny {
		// 模式自动拒绝 (如 safe_yolo + red, read_only, plan)
		rec, err := h.svc.Create(r.Context(), createReqVal)
		if err != nil {
			h.log.DBError("create-mode-auto-deny", err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
			return
		}
		if _, err := h.svc.Decide(r.Context(), rec.ID, approval.DecisionDeny, "auto(mode:"+permMode+")"); err != nil {
			h.log.DBError("auto-decide-deny", err)
		}
		writeJSON(w, http.StatusCreated, map[string]string{"id": rec.ID, "decision": approval.DecisionDeny, "auto": "true"})
		return
	}

	// 仍为红色且需人工审批 → 创建 pending 审批
	createReqVal.RiskLevel = string(finalLevel)
	createReqVal.RuleReason = finalReason
	rec, err := h.svc.Create(r.Context(), createReqVal)
	if err != nil {
		h.log.DBError("create-approval", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		return
	}

	h.log.ApprovalCreated(rec.ID, req.SessionID, string(finalLevel), req.Command)

	// Broadcast approval_update to phone clients via WS so they can refresh
	// pending approval list without HTTP polling.
	if h.wsHub != nil {
		h.wsHub.BroadcastToPhones("approval_update", map[string]interface{}{
			"event":       "created",
			"approval_id": rec.ID,
			"project":     project,
			"risk_level":  string(finalLevel),
		})
	}

	// 始终推送轻量审批信号。relay 在线时仍可能只有电脑端内联事件，
	// 手机后台需要该信号来展示常驻通知和拉取审批详情；客户端按审批 ID 去重。
	// 信号不含命令正文或凭证，推送失败也不阻塞审批主流程。
	if err := h.pub.Publish(r.Context(), notify.ApprovalMessage{
		ID: rec.ID, RiskLevel: string(finalLevel), Project: project,
	}); err != nil {
		h.log.NtfyError(rec.ID, err)
	}
	if h.push != nil {
		h.push.EnqueueApproval(rec.ID, string(finalLevel), project)
	}

	writeJSON(w, http.StatusCreated, map[string]string{"id": rec.ID})
}

// Status GET /approvals/{id}/status —— hook 轮询审批结果。
func (h *Handler) Status(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	decision, reason, err := h.svc.Status(r.Context(), id)
	if err != nil {
		if err == approval.ErrNotFound {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
			return
		}
		h.log.DBError("status", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{
		"id": id, "decision": decision, "reason": reason,
	})
}

type decideReq struct {
	Decision string `json:"decision"` // allow / deny
	Reason   string `json:"reason"`
}

// Decide POST /approvals/{id}/decide —— 客户端回执。
func (h *Handler) Decide(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	var req decideReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid json"})
		return
	}
	if req.Decision != approval.DecisionAllow && req.Decision != approval.DecisionDeny {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "decision must be allow or deny"})
		return
	}
	updated, err := h.svc.Decide(r.Context(), id, req.Decision, "client")
	if err != nil {
		h.log.DBError("decide", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		return
	}
	if !updated {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "already decided or timeout"})
		return
	}

	h.log.Decided(id, req.Decision, "client")

	// Broadcast approval_update to phone clients via WS so they can refresh
	// pending approval list without HTTP polling.
	if h.wsHub != nil {
		h.wsHub.BroadcastToPhones("approval_update", map[string]interface{}{
			"event":       "decided",
			"approval_id": id,
			"decision":    req.Decision,
		})
	}

	// Phase 2: 用户同意后记录到会话记忆
	if req.Decision == approval.DecisionAllow && h.sessionRepo != nil {
		rec, err := h.svc.Get(r.Context(), id)
		if err == nil {
			if err := h.sessionRepo.Remember(rec.SessionID, rec.Command); err != nil {
				h.log.DBError("session-remember", err)
			}
		}
	}

	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// History GET /approvals/history —— 审批历史。支持 project 过滤。
func (h *Handler) History(w http.ResponseWriter, r *http.Request) {
	limit, offset := parsePaging(r)
	status := r.URL.Query().Get("status")
	project := r.URL.Query().Get("project")
	items, total, err := h.svc.List(r.Context(), limit, offset, status, project)
	if err != nil {
		h.log.DBError("history-list", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"total": total, "items": items,
	})
}

// Detail GET /approvals/{id} —— 客户端查看审批详情。
func (h *Handler) Detail(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	rec, err := h.svc.Get(r.Context(), id)
	if err != nil {
		if err == approval.ErrNotFound {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
			return
		}
		h.log.DBError("detail", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		return
	}
	writeJSON(w, http.StatusOK, rec)
}

// ClearHistory DELETE /approvals/history —— 清空所有非 pending 的历史记录。
func (h *Handler) ClearHistory(w http.ResponseWriter, r *http.Request) {
	n, err := h.svc.DeleteAllExceptPending(r.Context())
	if err != nil {
		h.log.DBError("clear-history", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"ok": true, "deleted": n})
}

// Stats GET /approvals/stats —— 返回按日聚合的统计数据
func (h *Handler) Stats(w http.ResponseWriter, r *http.Request) {
	days := 7
	project := r.URL.Query().Get("project")
	stats, err := h.svc.GetDailyStats(r.Context(), days, project)
	if err != nil {
		h.log.DBError("stats", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"items": stats})
}

// Healthz GET /healthz
func (h *Handler) Healthz(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]interface{}{"ok": true, "version": h.BuildVersion})
}

// Version GET /version
func (h *Handler) Version(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"version": h.BuildVersion})
}

func writeJSON(w http.ResponseWriter, code int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("X-Frame-Options", "DENY")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}
