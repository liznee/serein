package api

import (
	"context"
	"database/sql"
	"encoding/json"
	"log"
	"math"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"

	"serein/internal/agent"
	"serein/internal/notify"
	"serein/internal/session"
	"serein/internal/store"

	"github.com/go-chi/chi/v5"
)

// AgentRelay 远程控制命令中继。内维护本地 Agent 的最后心跳缓存，
// /agent/status 读缓存即可，不再挤占命令队列。
type AgentRelay struct {
	CmdQueue       *agent.Queue
	SessionManager *session.SessionManager // 双端实时同步会话管理器
	Pub            *notify.Publisher       // ntfy 通知推送（可为 nil，不推送）

	mu                  sync.RWMutex
	lastOutput          map[string]interface{} // Agent 最后一次 do_status() 的返回值
	lastSeen            time.Time
	sysInfo             map[string]interface{} // 缓存的系统信息（CPU/内存/磁盘）
	sysInfoAt           time.Time
	sysInfoRepo         *store.SysInfoRepo         // 用于持久化 sysinfo 快照（sparkline 趋势图数据源）
	monitoringAlertRepo *store.MonitoringAlertRepo // 独立监控告警记录（不属于审批）
	wsHub               *wsHub                     // WebSocket 广播（可为 nil，不广播）
	alertCh             chan alertJob              // 告警工作通道（替代 alertMu 锁，防 HTTP 阻塞）
	alertStopCh         chan struct{}              // 关闭信号，通知 alert worker goroutine 退出
	sysSaveMu           sync.Mutex                 // saveSysInfoSnapshot 串行化锁，防止 DB 卡顿时 goroutine 堆积
	cmdSem              chan struct{}              // 信号量：当前正在执行的 /agent/cmd 请求数上限保护，缓冲容量=maxCmdConcurrent
	fileStore           *fileStore                 // 内存文件存储（/agent/upload → relay HTTP 下载中转）
	collaborationRuns   map[string]*collaborationRun
	collaborationRepo   *store.CollaborationRunRepo
}

// alertJob 告警推送任务
type alertJob struct {
	title        string
	message      string
	tags         []string
	monitoringID string
	level        string
}

// agentHeartbeatTimeout Agent 心跳超时，超过此时间视为离线。
const agentHeartbeatTimeout = 35 * time.Second

// 输入验证常量
const (
	maxProjectLen     = 100
	maxCommandLen     = 8000
	maxCmdIDLen       = 50
	maxRequestBodyLen = 10 << 20 // 10MB
	maxAlertBodyLen   = 1 << 20  // 1MB
	// maxCmdTimeout 同步命令超时上限（与 request Context 配合形成分层超时）。
	// Agent 执行最长等待，但客户端断开或 HTTP 超时 (120s) 可提前退出。
	maxCmdTimeout = 300 * time.Second
	// httpCmdTimeout HTTP 层超时：客户端挂起等待的最长时间。
	httpCmdTimeout = 120 * time.Second
	// maxCmdConcurrent /agent/cmd 最大并发请求数，超出返回 503。
	// 与路由层 rateLimit 中间件配合（限制单位时间请求频率），此计数器限制瞬时并发量。
	maxCmdConcurrent = 5
	// maxStepContentLen CmdStep 中间步骤 Content 最大字节数（纵深防御 HOOK_TOKEN 泄露时注入长内容）
	maxStepContentLen = 100000
)

// validActions 合法 action 枚举
var validActions = map[agent.Action]bool{
	agent.ActionStart:     true,
	agent.ActionStop:      true,
	agent.ActionStatus:    true,
	agent.ActionExec:      true,
	agent.ActionKillAll:   true,
	agent.ActionFileWrite: true,
}

func isValidAction(a agent.Action) bool {
	return validActions[a]
}

// containsShellMeta 检测命令内容是否包含危险的 shell 元字符。
// 用于 APP 端 token 泄露时的纵深防御：阻止通过注入 shell 元字符执行未授权命令。
// 注意：exec action 的 command 内容本身就是 shell 命令，跳过此项检查（由 Agent 侧执行环境管控）。
//
// 仅匹配真正危险的 shell 元字符：; | & $ ` < >
// 移除 ! ? # * [ ] { } ( ) ~ ' " \ \n \r 等自然语言标点，
// 避免手机端聊天消息（含 ? ! ' " 等）被静默丢弃。
var shellMetaRe = regexp.MustCompile("[;&|$`<>]")
var workScopePattern = regexp.MustCompile(`^[A-Za-z0-9._:/-]{1,500}$`)
var uuidPattern = regexp.MustCompile(`(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

func isSafeWorkScope(value string) bool {
	return workScopePattern.MatchString(value)
}

func containsShellMeta(s string) bool {
	return shellMetaRe.MatchString(s)
}

// dangerousExecPattern 单个危险命令模式（预编译正则）。
// 启动时预编译避免每次请求重新编译全部正则。
type dangerousExecPattern struct {
	re     *regexp.Regexp
	reason string
}

// dangerousExecPatterns 定义 exec action 中应被阻止的极危险命令模式。
// 这些命令即使在正常 shell 使用场景中也极少出现，但 token 泄露时可能导致毁灭性后果。
// exec action 的 command 本质是 shell 命令，不适用 containsShellMeta 检查，
// 因此用此黑名单做针对性防护（纵深防御，非白名单）。
// 使用 init-time 初始化函数预编译所有正则，避免每次 containsDangerousExec 调用都重新编译。
var dangerousExecPatterns = func() []dangerousExecPattern {
	raw := []struct {
		pattern string
		reason  string
	}{
		{`\brm\s+(-rf\s+)?[\\/](\S|$)`, "危险性递归删除"},
		{`\brm\s+(-rf\s+)?/\s+-r\b`, "危险性递归删除"},
		{`\brm\s+-rf\s+\.{2}(\s|$)`, "危险性递归删除（目录遍历）"},
		{`\brm\s+-rf\s+\.(\s|$)`, "危险性递归删除（当前目录）"},
		{`\brm\s+-rf\s+\*(\s|$)`, "危险性递归删除（通配符）"},
		{`\bdd\s+if=`, "危险磁盘操作"},
		{`\bmkfs\b`, "危险磁盘操作"},
		{`\bmke2fs\b`, "危险磁盘操作"},
		{`\bmkfs\.`, "危险磁盘操作"},
		{`\bfdisk\b`, "危险磁盘操作"},
		{`\bparted\b`, "危险磁盘操作"},
		{`\bchmod\s+-R\s+0\s+/`, "危险权限修改"},
		{`\bchown\s+-R\b`, "危险权限修改"},
		{`\b:\(\)\s*\{`, "fork 炸弹"},
		{`\bwget\s+.+[|;]`, "远程下载并执行"},
		{`\bcurl\s+.+[|;]`, "远程下载并执行"},
		{"\\becho\\s+\"`\\s*rm\\b", "命令注入删除"},
	}
	dp := make([]dangerousExecPattern, len(raw))
	for i, r := range raw {
		dp[i] = dangerousExecPattern{re: regexp.MustCompile(r.pattern), reason: r.reason}
	}
	return dp
}()

// containsDangerousExec 检测 exec action 命令是否包含极危险模式。
// 注意：此函数是纵深防御，不能替代 token 安全。如果 token 已泄露，攻击者仍可找到绕过方式。
// 目的是阻止最常见的毁灭性命令意外或无意执行。
func containsDangerousExec(cmd string) (bool, string) {
	lower := strings.ToLower(strings.TrimSpace(cmd))
	for _, dp := range dangerousExecPatterns {
		if dp.re.MatchString(lower) {
			return true, dp.reason
		}
	}
	return false, ""
}

// allowedOutputKeys 定义 Report handler output 字段的白名单及类型校验函数。
// 拒绝任何不在白名单中的 key，将值转换为正确类型或置零。
// 用于 HOOK_TOKEN 泄露场景下防止攻击者注入任意数据毒化前端/缓存。
var allowedOutputKeys = map[string]func(v interface{}) bool{
	"_heartbeat": func(v interface{}) bool { _, ok := v.(bool); return ok },
	"status":     func(v interface{}) bool { _, ok := v.(string); return ok },
	"message":    func(v interface{}) bool { _, ok := v.(string); return ok },
	"error":      func(v interface{}) bool { _, ok := v.(string); return ok },
	"project":    func(v interface{}) bool { _, ok := v.(string); return ok },
	"cmd_id":     func(v interface{}) bool { _, ok := v.(string); return ok },
	"success":    func(v interface{}) bool { _, ok := v.(bool); return ok },
	"ok":         func(v interface{}) bool { _, ok := v.(bool); return ok },
	"path":       func(v interface{}) bool { _, ok := v.(string); return ok },
	"filename":   func(v interface{}) bool { _, ok := v.(string); return ok },
	"cpu":        func(v interface{}) bool { _, ok := v.(float64); return ok },
	"sysinfo":    func(v interface{}) bool { _, ok := v.(map[string]interface{}); return ok },
	"memory":     func(v interface{}) bool { _, ok := v.(map[string]interface{}); return ok },
	"disk":       func(v interface{}) bool { _, ok := v.(map[string]interface{}); return ok },
	"tokens":     func(v interface{}) bool { _, ok := v.(map[string]interface{}); return ok },
	"gpu":        func(v interface{}) bool { _, ok := v.(map[string]interface{}); return ok },
	// do_status() 心跳/状态响应字段（local_agent.py do_status）
	"running": func(v interface{}) bool { _, ok := v.([]interface{}); return ok },
	"details": func(v interface{}) bool { _, ok := v.(map[string]interface{}); return ok },
	// do_exec() 命令执行输出字段（agent_exec.py do_exec）
	"stdout":     func(v interface{}) bool { _, ok := v.(string); return ok },
	"stderr":     func(v interface{}) bool { _, ok := v.(string); return ok },
	"returncode": func(v interface{}) bool { _, ok := v.(float64); return ok },
	// do_start() / do_stop() 操作返回字段
	"killed":     func(v interface{}) bool { _, ok := v.(bool); return ok },
	"context":    func(v interface{}) bool { _, ok := v.(string); return ok },
	"session":    func(v interface{}) bool { _, ok := v.(string); return ok },
	"agent_type": func(v interface{}) bool { _, ok := v.(string); return ok },
	"runtime_mode": func(v interface{}) bool {
		s, ok := v.(string)
		return ok && (s == "cli" || s == "desktop")
	},
	"work_scope": func(v interface{}) bool {
		s, ok := v.(string)
		return ok && (s == "" || isSafeWorkScope(s))
	},
	"agent_session_id": func(v interface{}) bool {
		s, ok := v.(string)
		return ok && (s == "" || uuidPattern.MatchString(s))
	},
	"agent_types": func(v interface{}) bool { _, ok := v.([]interface{}); return ok },
	// do_kill_all() 返回的已杀进程 PID 列表
	"killed_pids": func(v interface{}) bool { _, ok := v.([]interface{}); return ok },
	// do_status() 返回的完整 PROJECT_PATHS 映射
	"projects": func(v interface{}) bool { _, ok := v.(map[string]interface{}); return ok },
	"desktop_projects": func(v interface{}) bool {
		projects, ok := v.(map[string]interface{})
		if !ok {
			return false
		}
		for project, raw := range projects {
			if project == "" || len(project) > maxProjectLen {
				return false
			}
			value, ok := raw.(map[string]interface{})
			if !ok {
				return false
			}
			available, availableOK := value["available"].(bool)
			count, countOK := value["thread_count"].(float64)
			if !availableOK || !available || !countOK || count < 1 || count > 100000 {
				return false
			}
		}
		return true
	},
	// project -> []credential-free canonical remote keys
	"git_remotes": func(v interface{}) bool {
		remotes, ok := v.(map[string]interface{})
		if !ok {
			return false
		}
		for project, raw := range remotes {
			if project == "" || len(project) > maxProjectLen {
				return false
			}
			values, ok := raw.([]interface{})
			if !ok || len(values) > 20 {
				return false
			}
			for _, value := range values {
				remote, ok := value.(string)
				if !ok || len(remote) > 500 || strings.ContainsAny(remote, "?#@") {
					return false
				}
			}
		}
		return true
	},
	"collaboration_sessions": func(v interface{}) bool {
		sessions, ok := v.(map[string]interface{})
		if !ok || len(sessions) > 500 {
			return false
		}
		for scope, raw := range sessions {
			if !isSafeWorkScope(scope) {
				return false
			}
			entry, ok := raw.(map[string]interface{})
			if !ok {
				return false
			}
			id, idOK := entry["agent_session_id"].(string)
			agentType, typeOK := entry["agent_type"].(string)
			project, projectOK := entry["project"].(string)
			updatedAt, updatedOK := entry["updated_at"].(string)
			if !idOK || !uuidPattern.MatchString(id) || !typeOK || (agentType != "codex" && agentType != "claude") || !projectOK || project == "" || len(project) > maxProjectLen || !updatedOK || len(updatedAt) > 64 {
				return false
			}
		}
		return true
	},
	// do_start() 返回的 relay 启动成功标志
	"relay_started": func(v interface{}) bool { _, ok := v.(bool); return ok },
}

// maxSanitizeDepth sanitizeOutput 递归最大深度，超过此深度时截断（防止恶意深度嵌套导致栈溢出）。
const maxSanitizeDepth = 10

// sanitizeOutput 过滤 output map：只保留白名单中的 key，拒绝未知 key 和类型不匹配的值。
// 返回全新 map，不修改入参。
//
// 在深度 d == 0（顶层）时严格校验 key 是否在白名单中；
// 在深度 d > 0（嵌套 map）时宽松校验：不校验 key 名，仅校验值是合法基本类型，
// 确保嵌套字段（如 memory.percent、disk.used_gb 等）不被误杀。
func sanitizeOutput(output map[string]interface{}, depth ...int) map[string]interface{} {
	if output == nil {
		return nil
	}
	d := 0
	if len(depth) > 0 {
		d = depth[0]
	}
	if d >= maxSanitizeDepth {
		log.Printf("[sanitizeOutput] max depth reached (%d), truncating", maxSanitizeDepth)
		return nil
	}
	cleaned := make(map[string]interface{}, len(output))
	for k, v := range output {
		if d == 0 {
			// 顶层：严格校验 key 在白名单中
			validator, ok := allowedOutputKeys[k]
			if !ok {
				log.Printf("[sanitizeOutput] removing unknown key: %s", k)
				continue
			}
			if !validator(v) {
				log.Printf("[sanitizeOutput] removing key %s with invalid type %T", k, v)
				continue
			}
		} else {
			// 嵌套层：宽松校验——仅验证值是合法基本类型，不校验 key 名
			if !isValidNestedValue(v) {
				log.Printf("[sanitizeOutput] nested: removing key %s with invalid type %T", k, v)
				continue
			}
		}
		// 递归清理嵌套 map（深度递增）
		if m, ok2 := v.(map[string]interface{}); ok2 {
			cleaned[k] = sanitizeOutput(m, d+1)
		} else {
			cleaned[k] = v
		}
	}
	return cleaned
}

// isValidNestedValue 判断嵌套 map 中的值是否为合法基本类型。
// 允许的类型：string、float64、bool、map[string]interface{}、[]interface{}、nil。
// 不校验 key 名，确保嵌套字段不被误杀。
func isValidNestedValue(v interface{}) bool {
	if v == nil {
		return true
	}
	switch v.(type) {
	case string, float64, bool, map[string]interface{}, []interface{}:
		return true
	}
	return false
}

// isPrintable 检查字符串是否仅包含可打印字符、制表符及换行符。
// 换行符允许通过，因为手机消息可能包含多行文本（如 Markdown 段落）。
// 使用 unicode.IsPrint 允许中文等多字节字符的项目名。
func isPrintable(s string) bool {
	for _, r := range s {
		if !unicode.IsPrint(r) && r != '\t' && r != '\n' && r != '\r' {
			return false
		}
	}
	return true
}

// checkCmdQueue 检查 CmdQueue 是否就绪，未就绪则写 503 并返回 false。
func (a *AgentRelay) checkCmdQueue(w http.ResponseWriter) bool {
	if a.CmdQueue == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "command queue not initialized"})
		return false
	}
	return true
}

// requireJSONContentType 检查 Content-Type 是否为 application/json，否则返回 false。
func requireJSONContentType(w http.ResponseWriter, r *http.Request) bool {
	ct := r.Header.Get("Content-Type")
	if ct == "" || !strings.HasPrefix(ct, "application/json") {
		writeJSON(w, http.StatusUnsupportedMediaType, map[string]string{"error": "content-type must be application/json"})
		return false
	}
	return true
}

// cmdRequest 是 Cmd handler 的输入结构体。
type cmdRequest struct {
	Action           string `json:"action"`
	Project          string `json:"project"`
	AgentType        string `json:"agent_type,omitempty"`
	WorkScope        string `json:"work_scope,omitempty"`
	AgentSessionID   string `json:"agent_session_id,omitempty"`
	AgentSessionMode string `json:"agent_session_mode,omitempty"`
	RuntimeMode      string `json:"runtime_mode,omitempty"`
	Command          string `json:"command,omitempty"`
}

// validateCmdRequest 校验命令请求各字段，不合法时直接写错误响应并返回 false。
func (a *AgentRelay) validateCmdRequest(w http.ResponseWriter, req *cmdRequest) bool {
	if req.Action == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "action required"})
		return false
	}
	// 校验 action 是否合法（在 kill-all 特殊路径之前做，确保非法 action 返回正确错误）
	if !isValidAction(agent.Action(req.Action)) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid action: " + req.Action})
		return false
	}
	// kill-all 是全局紧急刹车，不需要指定 project；其他 action 仍要求 project
	if req.Action != string(agent.ActionKillAll) && req.Project == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "project required"})
		return false
	}
	// project 字段可打印性校验（非 kill-all 时）
	if req.Action != string(agent.ActionKillAll) && !isPrintable(req.Project) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "project contains non-printable characters"})
		return false
	}
	if req.Action == string(agent.ActionExec) && req.Command == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "command required for exec action"})
		return false
	}
	// Agent 类型只对 start 有意义。空值保持向后兼容，由本地 Agent 默认到 Claude。
	if req.AgentType != "" {
		if req.Action != string(agent.ActionStart) {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "agent_type is only valid for start action"})
			return false
		}
		if req.AgentType != "claude" && req.AgentType != "codex" {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "unsupported agent_type: " + req.AgentType})
			return false
		}
	}
	if req.RuntimeMode != "" {
		if req.Action != string(agent.ActionStart) {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "runtime_mode is only valid for start action"})
			return false
		}
		if req.RuntimeMode != "cli" && req.RuntimeMode != "desktop" {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid runtime_mode"})
			return false
		}
		if req.RuntimeMode == "desktop" && req.AgentType != "codex" {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "desktop runtime requires agent_type=codex"})
			return false
		}
	}
	if req.WorkScope != "" || req.AgentSessionID != "" || req.AgentSessionMode != "" {
		if req.Action != string(agent.ActionStart) {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "work scope fields are only valid for start action"})
			return false
		}
		if len(req.WorkScope) > 500 || !isSafeWorkScope(req.WorkScope) {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid work_scope"})
			return false
		}
		if req.AgentSessionID != "" && !uuidPattern.MatchString(req.AgentSessionID) {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid agent_session_id"})
			return false
		}
		if req.AgentSessionMode != "" && req.AgentSessionMode != "new" && req.AgentSessionMode != "resume" {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid agent_session_mode"})
			return false
		}
		if req.AgentSessionMode != "" && req.AgentSessionID == "" {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "agent_session_id required for session mode"})
			return false
		}
	}
	// exec action 极危险命令检测（纵深防御，token 泄露时阻止毁灭性操作）
	if req.Action == string(agent.ActionExec) && req.Command != "" {
		if dangerous, reason := containsDangerousExec(req.Command); dangerous {
			log.Printf("[agent_relay] 拒绝危险 exec 命令 (reason: %s)", reason)
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "exec command rejected: " + reason})
			return false
		}
	}
	// 字段长度校验
	if len(req.Project) > maxProjectLen {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "project too long"})
		return false
	}
	if len(req.Command) > maxCommandLen {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "command too long"})
		return false
	}
	// 纵深防御：非 exec action 禁止包含 shell 元字符（exec 的 command 本身就是 shell 命令，跳过）
	if req.Action != string(agent.ActionExec) && containsShellMeta(req.Command) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "command contains disallowed shell metacharacters"})
		return false
	}
	return true
}

// handleCmdAsync 处理异步命令：入队后立即返回 cmd_id。
// 注意：不广播 commandText 为 session_msg（旧代码曾在此处广播，导致 relay PTY
// 将 exec 等非 chat 命令的文字写入 claude.exe，造成双重执行）。命令执行结果
// 由 Report handler 在 agent 回报后通过 cmd_result 广播。
//
// 例外：chat 命令需要通过 session_msg 广播给 relay（WS 实时通道），
// 因为 relay 不走命令队列轮询，只通过 WS session_msg 接收用户输入。
// 当手机 WS 断连时通过 HTTP fallback 发送 chat，后端需要广播给 relay。
func (a *AgentRelay) handleCmdAsync(w http.ResponseWriter, cmd *agent.Command) {
	cmdID := a.CmdQueue.EnqueueOnly(cmd)
	// chat 命令通过 session_msg 广播给 relay（WS 实时通道）
	if cmd.Action == agent.ActionChat && a.SessionManager != nil && cmd.SessionID != "" {
		a.SessionManager.BroadcastToSession(cmd.SessionID, "session_msg", map[string]interface{}{
			"content": cmd.Command,
			"project": cmd.Project,
		}, "")
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"ok": true, "action": string(cmd.Action), "project": cmd.Project, "cmd_id": cmdID, "queued": true,
	})
}

// handleCmdSync 处理同步命令：入队后等待执行结果。
func (a *AgentRelay) handleCmdSync(w http.ResponseWriter, r *http.Request, cmd *agent.Command) {
	ctx, cancel := context.WithTimeout(r.Context(), httpCmdTimeout)
	defer cancel()
	result := a.CmdQueue.EnqueueCmd(ctx, cmd, maxCmdTimeout)
	if result.Success {
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"ok": true, "action": string(cmd.Action), "project": cmd.Project, "output": result.Output,
		})
	} else {
		writeJSON(w, http.StatusGatewayTimeout, map[string]interface{}{
			"ok": false, "error": result.Output,
		})
	}
}

// Cmd POST /agent/cmd —— App 发起远程命令。
func (a *AgentRelay) Cmd(w http.ResponseWriter, r *http.Request) {
	if !a.checkCmdQueue(w) {
		return
	}
	if !requireJSONContentType(w, r) {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxRequestBodyLen)

	var req cmdRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid json"})
		return
	}
	if !a.validateCmdRequest(w, &req) {
		return
	}

	// 并发上限保护：使用 channel 信号量，超过 maxCmdConcurrent 个并发时返回 503。
	// 与路由层 rateLimit 中间件（限制单位时间频率）形成分层防护。
	select {
	case a.cmdSem <- struct{}{}:
		defer func() { <-a.cmdSem }()
	default:
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "too many concurrent requests"})
		return
	}

	// 审计日志：记录谁发送了什么命令（用于安全事故追溯）
	log.Printf("[Cmd] action=%s project=%q command_len=%d from=%s",
		req.Action, req.Project, len(req.Command), realClientIP(r))

	// 获取或创建 project 的 session
	sessionID := ""
	if a.SessionManager != nil {
		var s *session.Session
		if req.WorkScope != "" {
			s = a.SessionManager.GetOrCreateScopedSession(req.Project, req.WorkScope)
		} else {
			s = a.SessionManager.GetOrCreateSession(req.Project)
		}
		if s != nil {
			sessionID = s.ID
		}
	}
	cmd := &agent.Command{
		Action:           agent.Action(req.Action),
		Project:          req.Project,
		AgentType:        req.AgentType,
		WorkScope:        req.WorkScope,
		AgentSessionID:   req.AgentSessionID,
		AgentSessionMode: req.AgentSessionMode,
		RuntimeMode:      req.RuntimeMode,
		Command:          req.Command,
		SessionID:        sessionID,
	}

	// ?async=true → 异步非阻塞；否则同步阻塞
	if r.URL.Query().Get("async") == "true" {
		a.handleCmdAsync(w, cmd)
	} else {
		a.handleCmdSync(w, r, cmd)
	}
}

// Queue GET /agent/queue —— Agent 轮询取命令。
func (a *AgentRelay) Queue(w http.ResponseWriter, r *http.Request) {
	if !a.checkCmdQueue(w) {
		return
	}
	cmd := a.CmdQueue.Dequeue(r.Context(), 25*time.Second)
	if cmd == nil {
		writeJSON(w, http.StatusOK, map[string]interface{}{"has_cmd": false})
		return
	}
	resp := map[string]interface{}{
		"has_cmd": true, "cmd_id": cmd.ID, "action": string(cmd.Action), "project": cmd.Project, "command": cmd.Command,
	}
	if cmd.AgentType != "" {
		resp["agent_type"] = cmd.AgentType
	}
	if cmd.WorkScope != "" {
		resp["work_scope"] = cmd.WorkScope
	}
	if cmd.AgentSessionID != "" {
		resp["agent_session_id"] = cmd.AgentSessionID
	}
	if cmd.AgentSessionMode != "" {
		resp["agent_session_mode"] = cmd.AgentSessionMode
	}
	if cmd.RuntimeMode != "" {
		resp["runtime_mode"] = cmd.RuntimeMode
	}
	if cmd.SessionID != "" {
		resp["session_id"] = cmd.SessionID
	}
	if cmd.FileName != "" {
		resp["file_name"] = cmd.FileName
	}
	if cmd.FileData != "" {
		resp["file_data"] = cmd.FileData
	}
	writeJSON(w, http.StatusOK, resp)
}

// Report POST /agent/report —— Agent 回报执行结果。同时更新心跳缓存。
func (a *AgentRelay) Report(w http.ResponseWriter, r *http.Request) {
	if !a.checkCmdQueue(w) {
		return
	}
	if !requireJSONContentType(w, r) {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxRequestBodyLen)

	var req struct {
		CmdID   string                 `json:"cmd_id"`
		Success bool                   `json:"success"`
		Output  map[string]interface{} `json:"output"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid json"})
		return
	}

	// 对 output 做 schema 校验过滤：只保留白名单 key，拒绝未知 key 和类型不匹配的值。
	// 确保即使 HOOK_TOKEN 泄露，攻击者也无法通过 Report 注入任意数据毒化前端/缓存。
	cleanedOutput := sanitizeOutput(req.Output)

	// 心跳：agent 报告的是自身状态快照，更新缓存以服务 /agent/status
	if req.Success && cleanedOutput != nil {
		if _, isHeartbeat := cleanedOutput["_heartbeat"]; isHeartbeat || req.CmdID == "" {
			if a.wsHub != nil {
				a.wsHub.Broadcast("heartbeat", cleanedOutput)
			}
			a.mu.Lock()
			a.lastOutput = cleanedOutput
			a.lastSeen = time.Now()
			// 提取 sysinfo（如果心跳中附带）
			if si, ok := cleanedOutput["sysinfo"]; ok {
				if siMap, ok2 := si.(map[string]interface{}); ok2 {
					a.sysInfo = siMap
					a.sysInfoAt = time.Now()
					// 异步持久化快照（sparkline 数据源），使用 goroutine 避免阻塞心跳
					if a.sysInfoRepo != nil {
						go a.saveSysInfoSnapshot(siMap)
					}
				}
			}
			a.mu.Unlock()
			writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
			return
		}
	}

	a.CmdQueue.NotifyResult(req.CmdID, req.Success, cleanedOutput)
	// 通过 SessionManager 广播（避免双推）
	if a.SessionManager != nil {
		cmd := a.CmdQueue.GetCmd(req.CmdID)
		sessionID := ""
		action := agent.Action("")
		if cmd != nil {
			sessionID = cmd.SessionID
			action = cmd.Action
		}
		// chat 命令由 relay PTY 实时处理，relay 通过 WS cmd_step 推送手机端。
		// Agent 的 Report（"skipped, handled by relay"）是管理面噪音，
		// 不应广播到 session 造成手机端重复显示。
		if action != agent.ActionChat && sessionID != "" {
			a.SessionManager.BroadcastToSession(sessionID, "cmd_result", map[string]interface{}{
				"cmd_id":  req.CmdID,
				"success": req.Success,
				"output":  cleanedOutput,
				"action":  string(action),
			}, "")
		} else if a.wsHub != nil {
			// 没有 sessionID 时只广播到 relay 客户端，不做全局广播（防止数据泄漏到非预期客户端）
			a.wsHub.BroadcastToRelays("result", map[string]interface{}{
				"cmd_id":  req.CmdID,
				"success": req.Success,
				"output":  cleanedOutput,
				"action":  string(action),
			})
		}
	}

	// 非心跳 Report（do_start / do_stop 等命令执行回报）不更新 lastOutput 缓存，
	// 以免用不包含 running/projects 的临时结果覆盖心跳快照。
	// 但若 lastOutput 尚为 nil（心跳未到达前第一条消息即是命令回报），
	// 则存入当前 output 作为兜底，避免 Projects()/Status() 返回空数据。
	if req.Success && cleanedOutput != nil {
		a.mu.Lock()
		if a.lastOutput == nil {
			a.lastOutput = cleanedOutput
		}
		a.lastSeen = time.Now()
		a.mu.Unlock()
	}

	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// Status GET /agent/status — 读缓存，不阻塞、不沾队列。
func (a *AgentRelay) Status(w http.ResponseWriter, r *http.Request) {
	a.mu.RLock()
	output := a.lastOutput
	seen := a.lastSeen
	a.mu.RUnlock()

	alive := time.Since(seen) < agentHeartbeatTimeout
	if alive && output != nil {
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"running": true,
			"output":  output,
		})
	} else {
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"running": false,
		})
	}
}

// Projects GET /agent/projects — 返回缓存的项目路径映射 + 各项目 relay 运行状态。
func (a *AgentRelay) Projects(w http.ResponseWriter, r *http.Request) {
	a.mu.RLock()
	output := a.lastOutput
	seen := a.lastSeen
	a.mu.RUnlock()

	alive := time.Since(seen) < agentHeartbeatTimeout
	resp := map[string]interface{}{
		"alive":   alive,
		"running": []string{},
	}
	if alive && output != nil {
		if projects, ok := output["projects"]; ok {
			resp["projects"] = projects
		}
		if running, ok := output["running"]; ok {
			resp["running"] = running
		}
		if details, ok := output["details"]; ok {
			resp["details"] = details
		}
		if remotes, ok := output["git_remotes"]; ok {
			resp["git_remotes"] = remotes
		}
		if sessions, ok := output["collaboration_sessions"]; ok {
			resp["collaboration_sessions"] = sessions
		}
		if desktopProjects, ok := output["desktop_projects"]; ok {
			resp["desktop_projects"] = desktopProjects
		}
	}
	writeJSON(w, http.StatusOK, resp)
}

// SysInfo GET /agent/sysinfo — 返回缓存的系统信息（CPU/内存/磁盘）。
func (a *AgentRelay) SysInfo(w http.ResponseWriter, r *http.Request) {
	a.mu.RLock()
	si := a.sysInfo
	seen := a.sysInfoAt
	a.mu.RUnlock()

	// sysinfo 更新频率低（60s），放宽超时窗口
	alive := time.Since(seen) < agentHeartbeatTimeout*2
	if alive && si != nil {
		// 复制 map，不在锁外修改缓存
		resp := make(map[string]interface{}, len(si)+1)
		for k, v := range si {
			resp[k] = v
		}
		resp["_timestamp"] = seen.Unix()
		writeJSON(w, http.StatusOK, resp)
	} else {
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"cpu":    0,
			"memory": map[string]float64{"percent": 0, "total_mb": 0, "used_mb": 0, "free_mb": 0},
			"disk":   map[string]float64{"percent": 0, "total_gb": 0, "used_gb": 0, "free_gb": 0},
		})
	}
}

// validStepEvents CmdStep handler Event 字段枚举校验白名单。
// 防止持有 HOOK_TOKEN 的 agent 推送非法 Event 类型毒化步骤数据。
var validStepEvents = map[string]bool{
	"tool_use":    true,
	"tool_result": true,
	"text":        true,
	"hook":        true,
}

// CmdStep POST /agent/cmd/{id}/step — Agent 回报命令执行过程中的中间步骤。
// 步骤写入队列的环形缓冲区，App 通过 GET /agent/cmd/{id}/steps 轮询读取。
func (a *AgentRelay) CmdStep(w http.ResponseWriter, r *http.Request) {
	if !a.checkCmdQueue(w) {
		return
	}
	if !requireJSONContentType(w, r) {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxRequestBodyLen)

	var req struct {
		Seq     int    `json:"seq"`
		Event   string `json:"event"` // "tool_use" / "tool_result" / "text" / "hook"
		Name    string `json:"name,omitempty"`
		Content string `json:"content,omitempty"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid json"})
		return
	}
	cmdID := chi.URLParam(r, "id")
	if cmdID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "cmd_id required"})
		return
	}
	if len(cmdID) > maxCmdIDLen {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "cmd_id too long"})
		return
	}
	// Event 字段枚举校验（拒绝未知 event 类型，防止注入非法步骤数据）
	if !validStepEvents[req.Event] {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid event type: " + req.Event})
		return
	}

	// Content 字段安全校验（可打印字符 + 长度限制，纵深防御 HOOK_TOKEN 泄露场景）
	if !isPrintable(req.Content) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "step content contains non-printable characters"})
		return
	}
	if len(req.Content) > maxStepContentLen {
		log.Printf("[CmdStep] content too long: %d bytes (max %d), cmd_id=%s", len(req.Content), maxStepContentLen, cmdID)
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "step content too long"})
		return
	}

	step := &agent.Step{
		CmdID:   cmdID,
		Seq:     req.Seq,
		Event:   req.Event,
		Name:    req.Name,
		Content: req.Content,
	}
	a.CmdQueue.NotifyStep(step)
	// 步骤广播走 SessionManager
	if a.SessionManager != nil {
		cmd := a.CmdQueue.GetCmd(cmdID)
		sessionID := ""
		if cmd != nil {
			sessionID = cmd.SessionID
		}
		if sessionID != "" {
			a.SessionManager.BroadcastToSession(sessionID, "cmd_step", step, "")
		} else if a.wsHub != nil {
			a.wsHub.BroadcastToRelays("step", step)
		}
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// CmdSteps GET /agent/cmd/{id}/steps — App 端轮询中间步骤。
// 可选查询参数 ?after=<seq>，只返回大于该序号的步骤。
func (a *AgentRelay) CmdSteps(w http.ResponseWriter, r *http.Request) {
	if !a.checkCmdQueue(w) {
		return
	}
	cmdID := chi.URLParam(r, "id")
	if cmdID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "cmd_id required"})
		return
	}
	afterStr := r.URL.Query().Get("after")
	afterSeq := -1 // 默认 -1 确保 seq=0 的步骤也被返回
	if n, err := strconv.Atoi(afterStr); err == nil {
		afterSeq = n
	}
	steps := a.CmdQueue.Steps(cmdID, afterSeq)
	if steps == nil {
		steps = []agent.Step{}
	}
	writeJSON(w, http.StatusOK, steps)
}

// CommandsStats GET /stats/commands — 返回命令执行统计。
// 响应结构：{ summary: [按 action 聚合], by_project: [按 project 聚合], daily: [每日趋势] }
// 可选参数 ?days=1|7|30，默认 7 天。
func (a *AgentRelay) CommandsStats(w http.ResponseWriter, r *http.Request) {
	days := 7
	if d, err := strconv.Atoi(r.URL.Query().Get("days")); err == nil && d > 0 && d <= 90 {
		days = d
	}
	if a.CmdQueue == nil || a.CmdQueue.CmdRepo() == nil {
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"summary":    []store.CommandStats{},
			"by_project": []store.ProjectCommandStats{},
			"daily":      []store.CommandDailyStat{},
		})
		return
	}
	repo := a.CmdQueue.CmdRepo()
	summary, err := repo.Stats(days)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	byProject, err := repo.StatsByProject(days)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	daily, err := repo.DailyStats(days)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	if summary == nil {
		summary = []store.CommandStats{}
	}
	if byProject == nil {
		byProject = []store.ProjectCommandStats{}
	}
	if daily == nil {
		daily = []store.CommandDailyStat{}
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"summary":    summary,
		"by_project": byProject,
		"daily":      daily,
	})
}

// History GET /agent/history — App 端轮询已完成的命令结果（不阻塞，快速返回）。
// 必填参数（二选一）：
//   - ?session_id=<sessionID>：按 session 精确过滤
//   - ?project=<project>：按项目名查找对应 session 并过滤
//
// 可选参数 ?since=<cmd_id>，只返回该 cmd_id 之后的结果（跳过旧数据）。
// 安全：session_id 和 project 都不提供时返回空列表，防止跨项目命令历史泄漏。
func (a *AgentRelay) History(w http.ResponseWriter, r *http.Request) {
	if !a.checkCmdQueue(w) {
		return
	}
	history := a.CmdQueue.History(50)

	// 确定过滤用的 sessionID
	// 优先级：session_id > project 查找
	sessionID := r.URL.Query().Get("session_id")
	if sessionID == "" {
		project := r.URL.Query().Get("project")
		if project != "" && a.SessionManager != nil {
			if s := a.SessionManager.GetSessionByProject(project); s != nil {
				sessionID = s.ID
			}
		}
	}
	// 安全要求：session_id 或 project 必填其一，无参数时返回空列表
	if sessionID == "" {
		writeJSON(w, http.StatusOK, []agent.Result{})
		return
	}

	// 按 session_id 过滤
	// 使用 Result.SessionID（由 NotifyResult 从 cmd.SessionID 复制），
	// 不依赖 cmd 仍在队列 map 中（超时命令的 cmd 可能已被清理）。
	filtered := []agent.Result{}
	for _, h := range history {
		if h.SessionID == sessionID {
			filtered = append(filtered, h)
		}
	}

	since := r.URL.Query().Get("since")
	if since != "" {
		afterSince := []agent.Result{}
		found := false
		for _, h := range filtered {
			if found {
				afterSince = append(afterSince, h)
			} else if h.CmdID == since {
				found = true
			}
		}
		writeJSON(w, http.StatusOK, afterSince)
		return
	}
	writeJSON(w, http.StatusOK, filtered)
}

func (a *AgentRelay) Sparkline(w http.ResponseWriter, r *http.Request) {
	countStr := r.URL.Query().Get("count")
	count := 60
	if n, err := strconv.Atoi(countStr); err == nil && n > 0 && n <= 500 {
		count = n
	}
	if a.sysInfoRepo == nil {
		writeJSON(w, http.StatusOK, []interface{}{})
		return
	}
	snaps, err := a.sysInfoRepo.RecentN(count)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	if snaps == nil {
		snaps = []store.SysInfoSnapshot{}
	}
	writeJSON(w, http.StatusOK, snaps)
}

// Overview GET /stats/overview — 返回 token 趋势 + 资源趋势（统计页用）。
// 可选参数 ?days=1|7|30，默认 7 天；hours = days * 24。
func (a *AgentRelay) Overview(w http.ResponseWriter, r *http.Request) {
	if a.sysInfoRepo == nil {
		writeJSON(w, http.StatusOK, map[string]interface{}{"daily": []store.DailyStats{}, "hourly": []store.HourlyResource{}})
		return
	}
	days := 7
	if d, err := strconv.Atoi(r.URL.Query().Get("days")); err == nil && d > 0 && d <= 90 {
		days = d
	}
	hours := days * 24
	daily, err := a.sysInfoRepo.DailyAggregates(days)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	hourly, err := a.sysInfoRepo.HourlyResource(hours)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	if daily == nil {
		daily = []store.DailyStats{}
	}
	if hourly == nil {
		hourly = []store.HourlyResource{}
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"daily":  daily,
		"hourly": hourly,
	})
}

// Activities GET /activities/recent — 返回最近活动时间线（合并审批+命令+系统事件）。
func (a *AgentRelay) Activities(w http.ResponseWriter, r *http.Request) {
	if a.CmdQueue == nil || a.CmdQueue.ActivityRepo() == nil {
		writeJSON(w, http.StatusOK, []interface{}{})
		return
	}
	// 多取一些再由客户端筛选 chat/resume，避免 start/stop 等系统活动
	// 挤掉真正的最近会话记录。
	items, err := a.CmdQueue.ActivityRepo().Recent(50)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	if items == nil {
		items = []store.ActivityItem{}
	}
	writeJSON(w, http.StatusOK, items)
}

// RunningProjects returns the list of currently running project names
// from the agent's last heartbeat. Returns nil if agent is offline or no data.
// Used by wsHub.notifyRelayStateChange to include running projects in state_update
// broadcasts, eliminating the need for phone clients to poll /agent/status.
func (a *AgentRelay) RunningProjects() []string {
	a.mu.RLock()
	defer a.mu.RUnlock()
	if time.Since(a.lastSeen) >= agentHeartbeatTimeout {
		return nil
	}
	if a.lastOutput == nil {
		return nil
	}
	running, ok := a.lastOutput["running"].([]interface{})
	if !ok {
		return nil
	}
	result := make([]string, 0, len(running))
	for _, v := range running {
		if s, ok := v.(string); ok {
			result = append(result, s)
		}
	}
	return result
}

// StartAlertWorker 启动后台告警推送 worker，处理 alertCh 中的告警任务。
// alertCh 带缓冲（队列最大 100），超过时丢弃最旧任务，防止内存无限增长。
// 通过调用 StopAlertWorker 关闭 alertStopCh 来停止 worker goroutine。
func (a *AgentRelay) StartAlertWorker() {
	a.alertCh = make(chan alertJob, 100)
	a.alertStopCh = make(chan struct{})
	go func() {
		for {
			select {
			case job := <-a.alertCh:
				if a.Pub == nil {
					continue
				}
				alertCtx, alertCancel := context.WithTimeout(context.Background(), 10*time.Second)
				var err error
				if job.monitoringID != "" {
					err = a.Pub.PublishMonitoringAlert(alertCtx, job.monitoringID, job.level)
				} else {
					err = a.Pub.PublishAlert(alertCtx, job.title, job.message, job.tags)
				}
				if err != nil {
					log.Printf("[Alert] ntfy publish error: %v", err)
				}
				alertCancel()
			case <-a.alertStopCh:
				// 收到关闭信号，退出 worker 循环
				return
			}
		}
	}()
}

// StopAlertWorker 发送关闭信号，停止 alert worker goroutine。
// 停止后调用 StartAlertWorker 可重新启动。
func (a *AgentRelay) StopAlertWorker() {
	if a.alertStopCh != nil {
		select {
		case <-a.alertStopCh:
			// 已关闭，忽略
		default:
			close(a.alertStopCh)
		}
	}
}

type monitoringObservationRequest struct {
	Metric    string  `json:"metric"`
	Value     float64 `json:"value"`
	Threshold float64 `json:"threshold"`
	Active    bool    `json:"active"`
}

func validMonitoringObservation(o monitoringObservationRequest) bool {
	if math.IsNaN(o.Value) || math.IsInf(o.Value, 0) || math.IsNaN(o.Threshold) || math.IsInf(o.Threshold, 0) || o.Value < 0 || o.Threshold <= 0 {
		return false
	}
	switch o.Metric {
	case "cpu", "gpu", "mem":
		return o.Value <= 100 && o.Threshold <= 100
	case "gpu_temp":
		return o.Value <= 200 && o.Threshold <= 150
	default:
		return false
	}
}

// Alert POST /agent/alert — receives bounded monitor observations. The server
// is the dedupe authority: only a newly opened lifecycle is forwarded to ntfy.
func (a *AgentRelay) Alert(w http.ResponseWriter, r *http.Request) {
	if !requireJSONContentType(w, r) {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxAlertBodyLen)

	var req struct {
		Observations []monitoringObservationRequest `json:"observations"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid json"})
		return
	}

	if len(req.Observations) == 0 || len(req.Observations) > 4 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "1-4 observations required"})
		return
	}
	observations := make([]store.MonitoringObservation, 0, len(req.Observations))
	seen := map[string]bool{}
	for _, observation := range req.Observations {
		if !validMonitoringObservation(observation) || seen[observation.Metric] {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid monitoring observation"})
			return
		}
		seen[observation.Metric] = true
		observations = append(observations, store.MonitoringObservation{Metric: observation.Metric, Value: observation.Value, Threshold: observation.Threshold, Active: observation.Active})
	}
	if a.monitoringAlertRepo == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "monitoring alerts unavailable"})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	opened, err := a.monitoringAlertRepo.Observe(ctx, observations)
	if err != nil {
		log.Printf("[Alert] observe failed: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to persist monitoring alerts"})
		return
	}
	for _, record := range opened {
		a.enqueueMonitoringAlert(record)
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"ok": true, "opened": len(opened)})
}

func (a *AgentRelay) enqueueMonitoringAlert(record store.MonitoringAlertRecord) {
	if a.alertCh == nil {
		return
	}
	job := alertJob{monitoringID: record.ID, level: record.Level}
	select {
	case a.alertCh <- job:
	default:
		select {
		case <-a.alertCh:
		default:
		}
		select {
		case a.alertCh <- job:
		default:
		}
	}
}

// MonitoringAlerts GET /monitoring/alerts — client-authenticated alert history.
func (a *AgentRelay) MonitoringAlerts(w http.ResponseWriter, r *http.Request) {
	if a.monitoringAlertRepo == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "monitoring alerts unavailable"})
		return
	}
	state := r.URL.Query().Get("state")
	if state != "" && state != "active" && state != "resolved" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid state"})
		return
	}
	limit, offset := 50, 0
	if n, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && n > 0 && n <= 100 {
		limit = n
	}
	if n, err := strconv.Atoi(r.URL.Query().Get("offset")); err == nil && n >= 0 {
		offset = n
	}
	items, total, err := a.monitoringAlertRepo.List(r.Context(), state, limit, offset)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to load monitoring alerts"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"items": items, "total": total})
}

func (a *AgentRelay) MonitoringAlertSummary(w http.ResponseWriter, r *http.Request) {
	if a.monitoringAlertRepo == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "monitoring alerts unavailable"})
		return
	}
	summary, err := a.monitoringAlertRepo.Summary(r.Context())
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to load monitoring alert summary"})
		return
	}
	writeJSON(w, http.StatusOK, summary)
}

func (a *AgentRelay) MonitoringAlertDetail(w http.ResponseWriter, r *http.Request) {
	if a.monitoringAlertRepo == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "monitoring alerts unavailable"})
		return
	}
	id := chi.URLParam(r, "id")
	if len(id) != 32 || !regexp.MustCompile(`^[a-f0-9]+$`).MatchString(id) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid alert id"})
		return
	}
	record, err := a.monitoringAlertRepo.Detail(r.Context(), id)
	if err == sql.ErrNoRows {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "monitoring alert not found"})
		return
	}
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to load monitoring alert"})
		return
	}
	writeJSON(w, http.StatusOK, record)
}

// saveSysInfoSnapshot 从 sysinfo map 抽取字段并写入数据库。
// 在心跳循环中 goroutine 调用，带 10s 超时 context 防止 DB 卡顿时阻塞心跳。
// 使用 sysSaveMu 串行化写入，确保同一时间只有一个写入进行中。
func (a *AgentRelay) saveSysInfoSnapshot(m map[string]interface{}) {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("[saveSysInfoSnapshot] panic: %v", r)
		}
	}()
	a.sysSaveMu.Lock()
	defer a.sysSaveMu.Unlock()

	cpu, _ := m["cpu"].(float64)
	mem, _ := m["memory"].(map[string]interface{})
	var memUsed, memTotal float64
	if mem != nil {
		memUsed, _ = mem["used_mb"].(float64)
		memTotal, _ = mem["total_mb"].(float64)
	}
	disk, _ := m["disk"].(map[string]interface{})
	var diskUsed, diskTotal float64
	if disk != nil {
		diskUsed, _ = disk["used_gb"].(float64)
		diskTotal, _ = disk["total_gb"].(float64)
	}
	tokens, _ := m["tokens"].(map[string]interface{})
	var tok int64
	if t, ok := tokens["estimated_tokens"].(float64); ok {
		tok = int64(t)
	}
	gpuMap, _ := m["gpu"].(map[string]interface{})
	var gpuUtil, gpuTemp float64
	if gpuMap != nil {
		gpuUtil, _ = gpuMap["util"].(float64)
		gpuTemp, _ = gpuMap["temp"].(float64)
	}
	cpuTemp, _ := m["cpu_temp"].(float64)
	if a.sysInfoRepo != nil {
		// 带 10s 超时的 context，防止 DB 卡顿时 goroutine 永久阻塞
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := a.sysInfoRepo.Save(ctx, cpu, memUsed, memTotal, diskUsed, diskTotal, tok, gpuUtil, cpuTemp, gpuTemp); err != nil {
			log.Printf("[saveSysInfoSnapshot] failed to save: %v", err)
		}
	}
}

// batchCmdRequest 批量多项目命令请求
type batchCmdRequest struct {
	Projects []string `json:"projects"`
	Command  string   `json:"command"`
}

// batchCmdItem 批量命令中单个项目的执行标识
type batchCmdItem struct {
	Project string `json:"project"`
	CmdID   string `json:"cmd_id"`
}

// BatchCmd POST /agent/batch-cmd — 多项目批量执行相同命令。
//
// 接收 {projects:["serein","environment"], command:"git pull"}，
// 为每个项目创建独立 session 并排队 exec 命令，汇总返回各项目的 cmd_id。
// 前端 App 通过轮询 /agent/history 或 /agent/cmd/{id}/steps 获取各命令的执行结果。
//
// 并发安全：每个项目各自入队，CmdQueue 内部以 FIFO 顺序处理。
func (a *AgentRelay) BatchCmd(w http.ResponseWriter, r *http.Request) {
	if !a.checkCmdQueue(w) {
		return
	}
	if !requireJSONContentType(w, r) {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxRequestBodyLen)

	var req batchCmdRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid json"})
		return
	}
	if len(req.Projects) == 0 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "projects required"})
		return
	}
	if req.Command == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "command required"})
		return
	}
	if len(req.Command) > maxCommandLen {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "command too long"})
		return
	}
	// 纵深防御：同 exec action 一样检测极危险命令模式
	if dangerous, reason := containsDangerousExec(req.Command); dangerous {
		log.Printf("[BatchCmd] rejected dangerous command (reason: %s)", reason)
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "exec command rejected: " + reason})
		return
	}
	// 项目数量上限，防止恶意构造大量项目名耗尽服务器资源
	const maxBatchProjects = 10
	if len(req.Projects) > maxBatchProjects {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "too many projects (max 10)"})
		return
	}
	// 校验各项目名
	for _, p := range req.Projects {
		if len(p) > maxProjectLen || !isPrintable(p) {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid project name: " + p})
			return
		}
	}

	// 审计日志
	log.Printf("[BatchCmd] projects=%d from=%s", len(req.Projects), realClientIP(r))

	items := make([]batchCmdItem, 0, len(req.Projects))
	for _, project := range req.Projects {
		sessionID := ""
		if a.SessionManager != nil {
			if s := a.SessionManager.GetOrCreateSession(project); s != nil {
				sessionID = s.ID
			}
		}
		cmd := &agent.Command{
			Action:    agent.ActionExec,
			Project:   project,
			Command:   req.Command,
			SessionID: sessionID,
		}
		cmdID := a.CmdQueue.EnqueueOnly(cmd)
		items = append(items, batchCmdItem{Project: project, CmdID: cmdID})
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"ok": true, "items": items,
	})
}

// aiCommitRequest is the input for /agent/ai-commit.
type aiCommitRequest struct {
	Project string `json:"project"`
	Scope   string `json:"scope,omitempty"` // "staged" (default) or "all"
}

// resolveProjectDir 根据项目名查找项目目录。
// 优先从 Agent 心跳缓存的 PROJECT_PATHS 映射中查找，
// 找不到时回退到 SEREIN_PROJECT 环境变量。
func (a *AgentRelay) resolveProjectDir(project string) string {
	if project != "" {
		a.mu.RLock()
		output := a.lastOutput
		a.mu.RUnlock()
		if output != nil {
			if projs, ok := output["projects"].(map[string]interface{}); ok {
				if path, ok2 := projs[project].(string); ok2 && path != "" {
					return path
				}
			}
		}
	}
	// fallback: 无项目名或未找到映射时使用环境变量
	dir := os.Getenv("SEREIN_PROJECT")
	if dir == "" {
		return "."
	}
	return dir
}

// AiCommit POST /agent/ai-commit — AI 生成 commit message。
//
// 流程：
//  1. 在项目目录执行 git diff，获取代码变更
//  2. 返回 diff 内容，手机端经由 relay claude 生成规范 commit message
//
// 项目目录从 req.Project 映射 PROJECT_PATHS 获取（fallback: SEREIN_PROJECT 环境变量）。
func (a *AgentRelay) AiCommit(w http.ResponseWriter, r *http.Request) {
	if !requireJSONContentType(w, r) {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxRequestBodyLen)

	var req aiCommitRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid json"})
		return
	}

	// 审计日志：记录哪个项目触发了 ai-commit
	// project 为可选参数，仅用于审计日志（server 端没有 PROJECT_PATHS 映射，
	// 项目目录由 SEREIN_PROJECT 环境变量决定）。
	if req.Project != "" && len(req.Project) > maxProjectLen {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "project too long"})
		return
	}
	log.Printf("[AiCommit] project=%q scope=%q from=%s", req.Project, req.Scope, realClientIP(r))

	// 确定项目目录：优先从 Agent 心跳缓存的 PROJECT_PATHS 映射查找，
	// 找不到时回退到 SEREIN_PROJECT 环境变量。
	projectDir := a.resolveProjectDir(req.Project)

	// 构建 git diff 命令
	scope := req.Scope
	if scope == "" {
		scope = "staged"
	}

	var args []string
	switch scope {
	case "staged":
		args = []string{"diff", "--cached"}
	case "all":
		args = []string{"diff", "HEAD"}
	default:
		args = []string{"diff", "--cached"}
	}

	// 执行 git diff
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", args...)
	cmd.Dir = projectDir
	output, err := cmd.Output()
	if err != nil {
		// git diff 可能返回非零退出码（无变更时 exit 0，有变更时 exit 0，error 时 exit 非零）
		if ctx.Err() != nil {
			writeJSON(w, http.StatusGatewayTimeout, map[string]interface{}{
				"success": false, "error": "git diff 超时",
			})
			return
		}
		// 可能没有 git 仓库或 git 不在 PATH
		log.Printf("[AiCommit] git diff failed: project=%q err=%v", projectDir, err)
		writeJSON(w, http.StatusInternalServerError, map[string]interface{}{
			"success": false, "error": "git diff 执行失败",
		})
		return
	}

	diffText := string(output)
	if diffText == "" {
		// 无变更
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"message": "无未提交的变更",
			"diff":    "",
		})
		return
	}

	// 脱敏处理：移除 diff 中的敏感信息（密钥、token、密码、连接字符串等）
	diffText = sanitizeDiff(diffText)

	// 返回 diff，手机端将 diff 注入 chat 让 claude 生成 commit message
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"diff":    diffText,
	})
}

// sanitizeDiff 对 git diff 文本做脱敏处理，替换敏感信息（密钥、token、密码等）。
// 脱敏使用正则匹配，不修改原行结构，仅将敏感值替换为 <REDACTED>。
func sanitizeDiff(diff string) string {
	// 使用预编译正则替换敏感信息
	sensitivePatterns := []*regexp.Regexp{
		// API 密钥/令牌：key=xxx, token=xxx, secret=xxx, apikey=xxx 等（不区分大小写）
		regexp.MustCompile(`(?i)(\b(?:api[_-]?key|token|secret|password|passwd|credential|private[_-]?key|access[_-]?key|secret[_-]?key|auth[_-]?token|refresh[_-]?token|session[_-]?key|signing[_-]?key|encrypt(?:ion)?[_-]?key|db[_-]?password|ssh[_-]?key)\s*[=:]\s*)(['"]?)([^\s'"]{4,})`),
		// 连接字符串: postgres://, mysql://, redis://, mongodb:// 等
		regexp.MustCompile(`(?i)(postgres(?:ql)?|mysql|redis|mongodb|rediss|amqp|rabbitmq)://[^:]+:[^@]+@`),
		// 私钥块
		regexp.MustCompile(`(?s)-----BEGIN\s+(?:RSA|EC|DSA|OPENSSH|PGP|PRIVATE)\s+PRIVATE\s+KEY-----.*?-----END\s+(?:RSA|EC|DSA|OPENSSH|PGP|PRIVATE)\s+PRIVATE\s+KEY-----`),
		// .env 文件中的敏感环境变量
		regexp.MustCompile(`(?i)^(\s*[+#-]?\s*(?:export\s+)?(?:API_KEY|SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL|PRIVATE_KEY|ACCESS_KEY|SECRET_KEY|AUTH_TOKEN|DB_PASSWORD|SSH_KEY|ENCRYPTION_KEY)\s*[=:]\s*)(.+)$`),
		// JWT 令牌（eyJ... 格式，base64url 编码的 JWT）
		regexp.MustCompile(`\beyJ[a-zA-Z0-9_-]{10,}\.[a-zA-Z0-9_-]{10,}\.[a-zA-Z0-9_-]{10,}\b`),
	}

	// 先处理跨行模式（私钥块等）
	result := diff
	for _, re := range sensitivePatterns {
		result = re.ReplaceAllString(result, "${1}<REDACTED>")
	}
	return result
}

// realClientIP returns the real client IP, delegating to the shared clientIP function.
// Priority: X-Real-IP > X-Forwarded-For first entry > RemoteAddr (port stripped).
// In production, strip external X-Forwarded-For entries at the reverse proxy layer.
func realClientIP(r *http.Request) string {
	ip := clientIP(r)
	if ip == "" {
		return "unknown"
	}
	return ip
}
