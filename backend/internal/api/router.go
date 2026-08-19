package api

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"html"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"serein/internal/agent"
	"serein/internal/approval"
	rdplog "serein/internal/log"
	"serein/internal/notify"
	"serein/internal/pushkit"
	"serein/internal/remote"
	"serein/internal/risk"
	"serein/internal/session"
	"serein/internal/store"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
)

// #review: 从 Go 逻辑中提取的 HTML 模板，使 joinQR / pairQR 可读性更好，修改样式无需改 Go 逻辑。
// 使用 fmt.Sprintf 的 %s 占位符注入动态值。
//
// joinQRPage 用于 /join/{project} 页面，占位符:
//
//	%s — safeProject（HTML 转义后的项目名）
//	%s — safeProject（重复，h1 标题）
//	%s — jsSafePayload（JSON 序列化的 payload，安全嵌入 JS 字符串上下文）
//	%s — nonce（CSP script-src nonce 值，允许 inline script 执行）
var joinQRPage = `<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>serein 加入项目 %s</title>
<script src="https://cdn.jsdelivr.net/npm/qrcodejs@1.0.0/qrcode.min.js" integrity="sha384-3zSEDfvllQohrq0PHL1fOXJuC/jSOO34H46t6UQfobFOmxE5BpjjaIJY5F2/bMnU" crossorigin="anonymous"></script>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{background:#111418;color:#E1E2E8;font-family:monospace;display:flex;align-items:center;justify-content:center;min-height:100vh;flex-direction:column;gap:20px;padding:20px}
h1{font-size:20px;color:#ADC6FF;text-align:center}
.sub{font-size:13px;color:#8C909F;text-align:center}
.qr{background:#fff;padding:16px;border-radius:12px}
.code{background:rgba(255,255,255,0.05);padding:10px 18px;border-radius:8px;font-size:14px;color:#4AE176;letter-spacing:2px}
.btn{display:inline-block;padding:10px 24px;border-radius:8px;background:#ADC6FF;color:#0B0E12;text-decoration:none;font-size:14px;font-weight:bold}
</style></head><body>
<h1>📱 serein<br>%s</h1>
<p class="sub">扫码将此项目添加到手机</p>
<div class="qr" id="qr"></div>
<script nonce="%s">
const data = %s;
new QRCode(document.getElementById("qr"),{text:data,width:240,height:240});
</script>
</body></html>`

// pairQRPage 用于 /pair 页面，占位符:
//
//	%s — nonce（CSP script-src nonce 值，允许 inline script 执行）
//
// 注：之前为无动态参数的纯静态模板，加入 nonce 后增加一个 %s 占位符。
var pairQRPage = `<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>serein 扫码配对</title>
<script src="https://cdn.jsdelivr.net/npm/qrcodejs@1.0.0/qrcode.min.js" integrity="sha384-3zSEDfvllQohrq0PHL1fOXJuC/jSOO34H46t6UQfobFOmxE5BpjjaIJY5F2/bMnU" crossorigin="anonymous"></script>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{background:#111418;color:#E1E2E8;font-family:monospace;display:flex;align-items:center;justify-content:center;min-height:100vh;flex-direction:column;gap:24px}
h1{font-size:22px;color:#ADC6FF}
.info{font-size:13px;color:#8C909F;text-align:center}
.qr{background:#fff;padding:16px;border-radius:12px}
</style></head><body>
<h1>serein 扫码配对</h1>
<div class="qr" id="qr"></div>
<p class="info">打开 App → 点「📷 扫码配对」→ 扫描上方二维码<br>自动填充地址和配对码，无需手输</p>
<script nonce="%s">
const data = %s;
new QRCode(document.getElementById("qr"),{text:data,width:260,height:260});
</script>
</body></html>`

// RouterConfig NewRouter 的配置参数，提取为 struct 替代 14 个位置参数。
type RouterConfig struct {
	HookToken         string
	GlobalClientToken string
	PairCode          string
	DevMode           bool
	TLS               bool // 是否启用 TLS(影响 HSTS 头)
	Svc               *approval.Service
	Pub               *notify.Publisher
	Engine            *risk.Engine
	SessionRepo       *store.SessionRepo
	DeviceRepo        *store.DeviceRepo
	DevHandler        *DeviceHandler
	CfgHandler        *ConfigHandler
	Logger            *rdplog.Logger
	Version           string
	SysInfoRepo       *store.SysInfoRepo
	PushDispatcher    *pushkit.Dispatcher
}

// NewRouter 组装 HTTP 路由。
func NewRouter(cfg RouterConfig) http.Handler {
	r := chi.NewRouter()
	r.Use(middleware.Logger, middleware.Recoverer, securityHeaders(cfg.TLS))

	h := NewHandler(cfg.Svc, cfg.Pub, cfg.Engine, cfg.SessionRepo, cfg.Logger)
	h.BuildVersion = cfg.Version
	h.SetPushDispatcher(cfg.PushDispatcher)
	admin := &AdminHandler{
		BinaryPath:    getEnvOrDefault("SEREIN_BINARY_PATH", "/opt/serein/serein-server"),
		NewBinaryPath: getEnvOrDefault("SEREIN_NEW_BINARY_PATH", "/opt/serein/serein-server-next"),
		HapPath:       getEnvOrDefault("SEREIN_HAP_PATH", "/opt/serein/serein.hap"),
	}
	collaborationOAuth := newCollaborationOAuthHandlerFromEnv()

	// 远程控制命令中继（替代 SSH 反向隧道）
	hub := newWSHub()
	hub.SetHookToken(cfg.HookToken)
	hub.SetDeviceRepo(cfg.DeviceRepo)
	agentRelay := &AgentRelay{CmdQueue: agent.NewQueue(100), sysInfoRepo: cfg.SysInfoRepo, wsHub: hub, Pub: cfg.Pub, cmdSem: make(chan struct{}, maxCmdConcurrent), fileStore: newFileStore()}
	if cfg.SysInfoRepo != nil && cfg.SysInfoRepo.DB() != nil {
		agentRelay.monitoringAlertRepo = store.NewMonitoringAlertRepo(cfg.SysInfoRepo.DB())
		agentRelay.collaborationRepo = store.NewCollaborationRunRepo(cfg.SysInfoRepo.DB())
		if err := agentRelay.collaborationRepo.DeleteOlderThan(time.Now().Add(-90 * 24 * time.Hour)); err != nil {
			log.Printf("collaboration result cleanup failed: %v", err)
		}
	}
	// 初始化告警推送后台 worker（替代 alertMu 互斥锁，防 HTTP 阻塞）
	agentRelay.StartAlertWorker()
	// 初始化 SessionManager（双端实时同步）
	sm := session.NewSessionManager(agentRelay.CmdQueue, hub)
	agentRelay.SessionManager = sm
	hub.SetRelay(agentRelay)
	h.SetWSHub(hub)

	// Start approval timeout scanner — scans pending approvals that have exceeded
	// their timeout_at and pushes ntfy alerts so the user is reminded even if they
	// missed the initial push. Scans every 30s; each approval is notified at most
	// once (dedup by ID).
	approvalTimeoutScanner := approval.NewApprovalTimeoutScanner(cfg.Svc, cfg.Pub, 30*time.Second)
	go approvalTimeoutScanner.Start(context.Background())

	// Remote desktop uses an isolated control plane and signaling WebSocket.
	// It shares the paired-device database but never joins an Agent session and
	// never forwards media through the backend.
	var remoteAPI *remoteHandler
	var remoteHub *remoteWSHub
	if cfg.SysInfoRepo != nil && cfg.SysInfoRepo.DB() != nil {
		remoteRepo := remote.NewRepository(cfg.SysInfoRepo.DB())
		issuer, err := remote.NewEphemeralTicketIssuer(remoteRepo)
		if err != nil {
			log.Printf("remote ticket issuer unavailable: %v", err)
		} else {
			remoteService := remote.NewService(remoteRepo, issuer)
			remoteHub = newRemoteWSHub(remoteService, cfg.DeviceRepo)
			remoteService.SetEventSink(remoteHub.Notify)
			remoteAPI = newRemoteHandler(remoteService, remoteHub)
			// Start audit scanner for remote control security alerts via ntfy.
			// Scans remote_audit_events every 60s for credential expiry, session
			// failures, and repeated auth rejections from the same IP.
			auditScanner := remote.NewAuditScanner(remoteRepo, cfg.Pub, 60*time.Second)
			go auditScanner.Start(context.Background())
		}
	}
	// 如果有 sysInfoRepo 的 DB，初始化 CommandRepo + ActivityRepo
	if cfg.SysInfoRepo != nil {
		cmdRepo := store.NewCommandRepo(cfg.SysInfoRepo.DB())
		agentRelay.CmdQueue.SetCmdRepo(cmdRepo)
		actRepo := store.NewActivityRepo(cfg.SysInfoRepo.DB())
		agentRelay.CmdQueue.SetActivityRepo(actRepo)
	}

	r.Get("/healthz", h.Healthz)
	r.Get("/version", h.Version)
	// /debug-headers: 仅 dev 模式可用,生产模式返回 404(防 Authorization 头泄漏)
	if cfg.DevMode {
		r.Get("/debug-headers", func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			out := map[string]string{}
			for k, v := range r.Header {
				out[k] = v[0]
			}
			json.NewEncoder(w).Encode(out)
		})
	}
	r.Get("/dl/hap", admin.DlHap)
	r.With(rateLimit(30, time.Minute)).Get("/ws", hub.HandleWS)
	if remoteHub != nil {
		r.With(rateLimit(30, time.Minute)).Get("/v1/remote/ws", remoteHub.HandleWS)
	}
	r.Get("/pair", func(w http.ResponseWriter, req *http.Request) {
		pairQR(w, req, cfg.PairCode)
	})
	r.Get("/pair/qrcode", func(w http.ResponseWriter, req *http.Request) {
		pairQRCode(w, req, cfg.PairCode)
	})
	r.Get("/join/{project}", joinQR)
	// OAuth callback is opened by GitHub/Gitee in the system browser. State is
	// cryptographically random and the resulting token is delivered once through
	// the authenticated status endpoint below.
	r.With(rateLimit(30, time.Minute)).Get("/collaboration/oauth/{provider}/callback", collaborationOAuth.Callback)

	r.With(rateLimit(10, time.Minute)).Post("/devices/pair", cfg.DevHandler.Pair)

	// hook + Agent 路由组 (HOOK_TOKEN)
	r.Group(func(r chi.Router) {
		r.Use(rateLimit(120, time.Minute), hookAuth(cfg.HookToken, cfg.DevMode))
		r.Post("/approvals", h.Create)
		r.Get("/approvals/{id}/status", h.Status)
		// Agent 长轮询取命令 + 回报结果
		r.Get("/agent/queue", agentRelay.Queue)
		r.Post("/agent/report", agentRelay.Report)
		// Agent intermediate steps (HOOK_TOKEN push, CLIENT_TOKEN read)
		r.Post("/agent/cmd/{id}/step", agentRelay.CmdStep)
		// Agent 告警推送（HOOK_TOKEN 鉴权）
		// auth.go hookAuth 已内置空 token 拒检逻辑：token 为空且非 dev 模式直接返回 401，
		// 不依赖 main.go panic 兜底。生产部署仍建议设置非空 HOOK_TOKEN。
		r.Post("/agent/alert", agentRelay.Alert)
		// 文件下载端点（relay HTTP 下载原始二进制文件）
		r.Get("/agent/file/{id}", agentRelay.DownloadFile)
		if remoteAPI != nil {
			r.Post("/v1/remote/hosts/register", remoteAPI.RegisterHost)
			r.Post("/v1/remote/hosts/{hostID}/credential/revoke", remoteAPI.RevokeHostCredential)
		}
		// HTTP 上传新二进制（替代 SCP，relay/PC 用 HOOK_TOKEN 鉴权）
		r.Post("/admin/upload-binary", admin.UploadBinary)

	})

	// 客户端路由组 (per-device CLIENT_TOKEN)
	// Windows Host operational routes use a per-host credential. They are kept
	// outside the Hook Token group so the bootstrap secret is not a standing
	// credential for every remote-control host.
	if remoteAPI != nil {
		r.Group(func(r chi.Router) {
			r.Use(rateLimit(240, time.Minute), remoteHostAuth(remoteAPI.service))
			r.Post("/v1/remote/hosts/{hostID}/heartbeat", remoteAPI.HeartbeatHost)
			r.Get("/v1/remote/hosts/{hostID}/sessions/pending", remoteAPI.PendingHostSessions)
			r.Post("/v1/remote/hosts/{hostID}/sessions/{sessionID}/accept", remoteAPI.AcceptSession)
			r.Post("/v1/remote/hosts/{hostID}/sessions/{sessionID}/reject", remoteAPI.RejectSession)
			r.Post("/v1/remote/hosts/{hostID}/sessions/{sessionID}/end", remoteAPI.EndSessionByHost)
			r.Post("/v1/remote/hosts/{hostID}/sessions/{sessionID}/connected", remoteAPI.MarkConnected)
		})
	}

	r.Group(func(r chi.Router) {
		r.Use(rateLimit(120, time.Minute), clientAuth(cfg.DeviceRepo, cfg.GlobalClientToken, cfg.DevMode))
		r.Delete("/devices/current", cfg.DevHandler.UnpairCurrent)
		r.Put("/devices/current/push-token", cfg.DevHandler.RegisterPushToken)
		r.Get("/approvals/history", h.History)
		r.Get("/approvals/stats", h.Stats)
		r.Delete("/approvals/history", h.ClearHistory)
		r.Post("/approvals/{id}/decide", h.Decide)
		r.Get("/approvals/{id}", h.Detail)

		r.Get("/config/whitelist", cfg.CfgHandler.ListWhitelist)
		r.Post("/config/whitelist", cfg.CfgHandler.AddWhitelist)
		r.Delete("/config/whitelist/{id}", cfg.CfgHandler.RemoveWhitelist)

		r.Get("/config/rules", cfg.CfgHandler.GetRules)
		r.Put("/config/rules", cfg.CfgHandler.UpdateRules)

		r.Get("/config/blacklist", cfg.CfgHandler.ListBlacklist)
		r.Post("/config/blacklist", cfg.CfgHandler.AddBlacklist)
		r.Delete("/config/blacklist/{id}", cfg.CfgHandler.RemoveBlacklist)

		r.Get("/admin/check-update", admin.CheckUpdate)
		// 部署端点：clientAuth 之后加 deployAuth 二次校验（HOOK_TOKEN 或 CLIENT_TOKEN）
		r.With(deployAuth(cfg.HookToken, cfg.DevMode, cfg.DeviceRepo)).Post("/admin/deploy", admin.Deploy)
		r.With(deployAuth(cfg.HookToken, cfg.DevMode, cfg.DeviceRepo)).Post("/admin/dl-link", admin.DlLink)
		r.With(deployAuth(cfg.HookToken, cfg.DevMode, cfg.DeviceRepo)).Post("/agent/deploy-config", admin.DeployConfig)
		r.With(deployAuth(cfg.HookToken, cfg.DevMode, cfg.DeviceRepo)).Get("/admin/dl", admin.Download)

		// 远程控制（App 侧）
		r.Post("/agent/cmd", agentRelay.Cmd)
		r.Get("/agent/history", agentRelay.History)
		r.Get("/agent/cmd/{id}/steps", agentRelay.CmdSteps)
		// 系统监控（需认证）
		r.Get("/agent/status", agentRelay.Status)
		r.Get("/agent/sysinfo", agentRelay.SysInfo)
		r.Get("/monitoring/alerts", agentRelay.MonitoringAlerts)
		r.Get("/monitoring/alerts/summary", agentRelay.MonitoringAlertSummary)
		r.Get("/monitoring/alerts/{id}", agentRelay.MonitoringAlertDetail)
		r.Get("/stats/sparkline", agentRelay.Sparkline)
		r.Get("/stats/overview", agentRelay.Overview)
		r.Get("/stats/commands", agentRelay.CommandsStats)
		r.Get("/agent/projects", agentRelay.Projects)
		r.Get("/activities/recent", agentRelay.Activities)
		r.Get("/collaboration/oauth/config", collaborationOAuth.Config)
		r.Post("/collaboration/oauth/{provider}/start", collaborationOAuth.Start)
		r.Get("/collaboration/oauth/{provider}/status/{state}", collaborationOAuth.Status)
		r.Post("/collaboration/handoff", agentRelay.CollaborationHandoff)
		r.Get("/collaboration/result", agentRelay.CollaborationResult)
		r.Delete("/collaboration/result", agentRelay.DeleteCollaborationResult)
		r.Post("/agent/ai-commit", agentRelay.AiCommit)
		r.Post("/agent/batch-cmd", agentRelay.BatchCmd)
		r.Post("/agent/file", agentRelay.File)
		r.Post("/agent/upload", agentRelay.Upload)
		if remoteAPI != nil {
			r.Get("/v1/remote/hosts", remoteAPI.ListHosts)
			r.Get("/v1/remote/hosts/{hostID}/capabilities", remoteAPI.HostCapabilities)
			r.Post("/v1/remote/sessions", remoteAPI.CreateSession)
			r.Get("/v1/remote/primary/requests", remoteAPI.PrimaryPendingSessions)
			r.Post("/v1/remote/primary/requests/{sessionID}/approve", remoteAPI.ApprovePrimarySession)
			r.Post("/v1/remote/primary/requests/{sessionID}/reject", remoteAPI.RejectPrimarySession)
			r.Get("/v1/remote/sessions/{sessionID}", remoteAPI.GetSession)
			r.Post("/v1/remote/sessions/{sessionID}/end", remoteAPI.EndSessionByController)
			r.Post("/v1/remote/sessions/{sessionID}/ticket/refresh", remoteAPI.RefreshControllerTicket)
			r.Get("/v1/remote/audit", remoteAPI.Audit)
		}
		// 主设备注册与状态查询（远程控制权限前提）
		r.Post("/v1/devices/primary/register", cfg.DevHandler.RegisterPrimary)
		r.Get("/v1/devices/primary", cfg.DevHandler.GetPrimaryStatus)
		r.Delete("/v1/devices/primary", cfg.DevHandler.ClearPrimary)
	})

	return r
}

func isValidOrigin(origin string) bool {
	// 只允许可打印 ASCII（32-126）字符，禁止控制字符和超长输入
	if len(origin) > 512 {
		return false
	}
	for i := 0; i < len(origin); i++ {
		if origin[i] < 32 || origin[i] > 126 {
			return false
		}
	}
	return true
}

// generateNonce 生成 CSP nonce 值（16 字节随机数，Base64 URL-safe 编码）。
// 用于 HTML 页面 CSP script-src nonce 保护，仅允许带有匹配 nonce 的 inline script 执行。
// fallback：如果 crypto/rand 读取失败，使用时间戳 + PID 组合（不涉及网络地址，安全无风险）。
func generateNonce() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return fmt.Sprintf("n%d-%d", time.Now().UnixNano(), os.Getpid())
	}
	return base64.RawURLEncoding.EncodeToString(b)
}

// pairQRCode GET /pair/qrcode — 返回纯文本配对标识（终端显示，无 HTML 包装）
func pairQRCode(w http.ResponseWriter, r *http.Request, pairCode string) {
	if pairCode == "" {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "pairing is not configured"})
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	origin := r.URL.Query().Get("origin")
	if origin == "" {
		origin = r.Header.Get("Origin")
	}
	if origin == "" || !isValidOrigin(origin) {
		origin = "https://" + r.Host
	}
	payload := origin + "|" + pairCode
	w.Write([]byte("serein 扫码配对\n"))
	w.Write([]byte("扫描下方配对码连接:\n\n"))
	w.Write([]byte(generateTerminalQR(payload)))
	w.Write([]byte("\n\n或手动输入配对码: " + pairCode + "\n"))
	w.Write([]byte("配对 URL: " + origin + "/pair\n"))
}

// generateTerminalQR 生成终端可用的纯文本配对标识。
// 此文本端点是 HTML QR 页面（/pair, /join/{project}）的 fallback，
// 直接输出配对 URL 和 payload，终端用户可手动复制。
func generateTerminalQR(payload string) string {
	sep := strings.Index(payload, "|")
	baseURL := payload
	if sep > 0 {
		baseURL = payload[:sep]
	}
	return "配对数据: " + payload + "\n" +
		"配对页面: " + baseURL + "/pair\n" +
		"\n(安全提示: 此配对数据包含配对密钥，请勿分享给他人)"
}

// joinQR GET /join/{project} — 固定项目二维码页面（长期可用）
func joinQR(w http.ResponseWriter, r *http.Request) {
	project := chi.URLParam(r, "project")
	if project == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing project"})
		return
	}
	origin := r.URL.Query().Get("origin")
	if origin == "" || !isValidOrigin(origin) {
		origin = "https://" + r.Host
	}
	// QR payload 使用 JSON 格式，匹配手机端 handleScanAddProject 的 JSON 解析逻辑。
	// 旧格式 "url|join|project" 无法被手机端正确解析（非 JSON 也非纯项目名）。
	payloadJSON, _ := json.Marshal(map[string]string{
		"name":       project,
		"backendUrl": origin,
	})
	payload := string(payloadJSON)
	// HTML 转义（标题/描述等 HTML 上下文）
	safeProject := html.EscapeString(project)
	// 使用 json.Marshal 为 JS 字符串上下文转义 payload（自动转义 < > & " \n 等，
	// 防止 origin 或 project 中的特殊字符导致 XSS 注入到 JS 字符串字面量）
	payloadBytes, err := json.Marshal(payload)
	if err != nil {
		log.Printf("joinQR: json.Marshal error: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		return
	}
	// json.Marshal 输出带引号的 JSON 字符串，直接嵌入（模板中不再加额外引号）
	jsSafePayload := string(payloadBytes)
	nonce := generateNonce()
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Content-Security-Policy", fmt.Sprintf("script-src 'self' https://cdn.jsdelivr.net 'nonce-%s'; object-src 'none'; base-uri 'none'", nonce))
	w.Write([]byte(fmt.Sprintf(joinQRPage, safeProject, safeProject, nonce, jsSafePayload)))
}

// pairQR GET /pair — 返回扫码配对 HTML 页面（含二维码）
func pairQR(w http.ResponseWriter, r *http.Request, pairCode string) {
	nonce := generateNonce()
	scheme := r.Header.Get("X-Forwarded-Proto")
	if scheme != "http" && scheme != "https" {
		scheme = "http"
		if r.TLS != nil {
			scheme = "https"
		}
	}
	origin := scheme + "://" + r.Host
	payloadBytes, _ := json.Marshal(origin + "|" + pairCode)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Content-Security-Policy", fmt.Sprintf("script-src 'self' https://cdn.jsdelivr.net 'nonce-%s'; object-src 'none'; base-uri 'none'", nonce))
	w.Write([]byte(fmt.Sprintf(pairQRPage, nonce, string(payloadBytes))))
}

func parsePaging(r *http.Request) (limit, offset int) {
	limit, _ = strconv.Atoi(r.URL.Query().Get("limit"))
	offset, _ = strconv.Atoi(r.URL.Query().Get("offset"))
	// 负值保护：limit 和 offset 不能为负，防止 SQL 注入利用负值放大查询范围
	if limit < 0 {
		limit = 0
	}
	if offset < 0 {
		offset = 0
	}
	// 上限保护：limit 超过 1000 时截断，防止恶意客户端请求过大值导致数据库压力
	if limit > 1000 {
		limit = 1000
	}
	return limit, offset
}

// getEnvOrDefault 读取环境变量，未设置时返回默认值。
// 用于替换硬编码的服务器路径等配置，使部署更灵活。
func getEnvOrDefault(key, defaultVal string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return defaultVal
}
