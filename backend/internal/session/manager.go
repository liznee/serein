package session

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"log"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"serein/internal/agent"
)

// BroadcastHub 定义广播接口，由 wsHub 实现。
type BroadcastHub interface {
	BroadcastToSession(sessionID, msgType string, data any, excludeClientID string)
}

// Session 代表一个实时同步会话。
type Session struct {
	ID              string
	Project         string
	Scope           string                 // non-empty for an independently recoverable collaboration work item
	Clients         map[string]*ClientInfo // clientID -> ClientInfo
	CreatedAt       time.Time
	LastActivity    time.Time // 最后一次活动时间，用于自动清理
	PendingDeleteAt time.Time // 非零值时表示会话正在等待延迟删除（LastActivity+30s），用于短时断连重用的窗口期
}

// sessionStaleTimeout 会话无活动超时：超过此时间无客户端活动的会话将被自动清理
const sessionStaleTimeout = 30 * time.Minute

// Collaboration scopes survive ordinary phone/relay disconnects. The Agent's
// own session ID is persisted separately, so an expired transport session can
// still be recreated without mixing work items.
const scopedSessionStaleTimeout = 7 * 24 * time.Hour

// sessionPendingDeleteDelay 最后客户端离开后，会话延迟删除的时间窗口。
// 手机 App 切后台等短时断连可在此窗口内重用原 sessionID，避免中继层
// sessionID 不匹配导致的短暂通信中断。
const sessionPendingDeleteDelay = 30 * time.Second

// sessionCleanupInterval 会话清理检查间隔
const sessionCleanupInterval = 5 * time.Minute

// SessionManager 管理所有活跃 Session。
// 包装现有 agent.Queue，不重复存储消息。
type SessionManager struct {
	mu       sync.RWMutex
	sessions map[string]*Session // sessionID -> Session
	projects map[string]string   // project -> sessionID
	scopes   map[string]string   // project + NUL + collaboration scope -> sessionID
	queue    *agent.Queue        // 底层 Queue（现有组件）
	seq      int64               // 全局单调递增 seq
	hub      BroadcastHub        // 广播接口
	stopCh   chan struct{}       // 关闭通知，用于优雅停止 cleanupLoop
	stopOnce sync.Once           // 保护 stopCh 不被重复关闭，防止 double-close panic
}

// NewSessionManager 创建 SessionManager。
func NewSessionManager(queue *agent.Queue, hub BroadcastHub) *SessionManager {
	sm := &SessionManager{
		sessions: make(map[string]*Session),
		projects: make(map[string]string),
		scopes:   make(map[string]string),
		queue:    queue,
		hub:      hub,
		stopCh:   make(chan struct{}),
	}
	// 启动定期清理 goroutine，移除过期会话
	go sm.cleanupLoop()
	return sm
}

// Stop 通知 cleanupLoop 退出，用于服务器优雅关闭。
// 使用 sync.Once 防止重复调用导致 close(channel) panic。
func (sm *SessionManager) Stop() {
	sm.stopOnce.Do(func() {
		close(sm.stopCh)
	})
}

// cleanupLoop 定期清理过期会话。
// 每 sessionCleanupInterval 检查一次，移除超过 sessionStaleTimeout 无客户端活动的空会话。
// 支持通过 Stop() 关闭通道实现优雅退出。
func (sm *SessionManager) cleanupLoop() {
	ticker := time.NewTicker(sessionCleanupInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			sm.cleanup()
		case <-sm.stopCh:
			return
		}
	}
}

// cleanup 清理无活跃客户端且过期的会话，以及等待延迟删除的会话。
func (sm *SessionManager) cleanup() {
	sm.mu.Lock()
	defer sm.mu.Unlock()
	now := time.Now()
	for id, s := range sm.sessions {
		if len(s.Clients) == 0 {
			if s.Scope != "" {
				if now.Sub(s.LastActivity) > scopedSessionStaleTimeout {
					delete(sm.sessions, id)
					sm.removeSessionMappings(id)
					log.Printf("[Session] cleaned up stale scoped session: %s project=%s", shortID(id), s.Project)
				}
				continue
			}
			// 优先检查延迟删除窗口（短时断连重用）
			if !s.PendingDeleteAt.IsZero() && now.After(s.PendingDeleteAt) {
				delete(sm.sessions, id)
				sm.removeSessionMappings(id)
				log.Printf("[Session] removed pending-delete session: %s project=%s", shortID(id), s.Project)
				continue
			}
			// 原始清理逻辑：无客户端且超过长时间无活动
			if now.Sub(s.LastActivity) > sessionStaleTimeout {
				delete(sm.sessions, id)
				sm.removeSessionMappings(id)
				log.Printf("[Session] cleaned up stale session: %s project=%s age=%v", shortID(id), s.Project, now.Sub(s.CreatedAt))
			}
		}
	}
}

// NextSeq 返回下一个全局 seq。
func (sm *SessionManager) NextSeq() int64 {
	return atomic.AddInt64(&sm.seq, 1)
}

// createSessionLocked creates a new session for the given project.
// Caller must hold sm.mu write lock.
func (sm *SessionManager) createSessionLocked(project string) *Session {
	// Return existing session if one is already active for this project.
	if sid, ok := sm.projects[project]; ok {
		if s, ok2 := sm.sessions[sid]; ok2 {
			return s
		}
	}
	id := generateSessionID()
	now := time.Now()
	s := &Session{
		ID:           id,
		Project:      project,
		Clients:      make(map[string]*ClientInfo),
		CreatedAt:    now,
		LastActivity: now,
	}
	sm.sessions[id] = s
	sm.projects[project] = id
	log.Printf("[Session] created: %s project=%s", shortID(id), project)
	return s
}

// CreateSession creates a new session (or returns existing) for a project.
// Acquires write lock internally. For bulk operations, prefer GetOrCreateSession
// to avoid re-acquiring the lock.
func (sm *SessionManager) CreateSession(project string) *Session {
	sm.mu.Lock()
	defer sm.mu.Unlock()
	return sm.createSessionLocked(project)
}

// GetOrCreateSession finds or creates a session by project.
// Uses a single write lock to avoid the RLock->RUnlock->Lock race window.
// This is the primary method; CreateSession is a wrapper.
func (sm *SessionManager) GetOrCreateSession(project string) *Session {
	sm.mu.Lock()
	defer sm.mu.Unlock()
	return sm.createSessionLocked(project)
}

// GetOrCreateScopedSession returns a transport session isolated by external
// work item. Re-entering the same Issue gets the same live session; another
// Issue in the same repository/project gets a different one.
func (sm *SessionManager) GetOrCreateScopedSession(project, scope string) *Session {
	sm.mu.Lock()
	defer sm.mu.Unlock()
	key := scopedSessionKey(project, scope)
	if sid, ok := sm.scopes[key]; ok {
		if s, exists := sm.sessions[sid]; exists {
			s.LastActivity = time.Now()
			return s
		}
	}
	id := generateSessionID()
	now := time.Now()
	s := &Session{
		ID: id, Project: project, Scope: scope,
		Clients: make(map[string]*ClientInfo), CreatedAt: now, LastActivity: now,
	}
	sm.sessions[id] = s
	sm.scopes[key] = id
	log.Printf("[Session] created scoped: %s project=%s", shortID(id), project)
	return s
}

// GetSession returns an immutable metadata snapshot for routing scoped events.
func (sm *SessionManager) GetSession(sessionID string) *Session {
	sm.mu.RLock()
	defer sm.mu.RUnlock()
	s, ok := sm.sessions[sessionID]
	if !ok {
		return nil
	}
	return &Session{
		ID: s.ID, Project: s.Project, Scope: s.Scope,
		CreatedAt: s.CreatedAt, LastActivity: s.LastActivity,
	}
}

// JoinSession 客户端加入 session。
func (sm *SessionManager) JoinSession(sessionID, clientID, clientType string) {
	sm.mu.Lock()
	defer sm.mu.Unlock()

	s, ok := sm.sessions[sessionID]
	if !ok {
		log.Printf("[Session] join failed: session not found %s", shortID(sessionID))
		return
	}
	s.Clients[clientID] = &ClientInfo{
		ClientID:   clientID,
		ClientType: clientType,
		JoinedAt:   time.Now(),
	}
	s.LastActivity = time.Now()
	// 客户端重连时取消延迟删除标记，允许会话继续使用（短时断连重用）
	s.PendingDeleteAt = time.Time{}
	log.Printf("[Session] client joined: %s type=%s session=%s (pending delete cancelled)", clientID, clientType, shortID(sessionID))
}

// LeaveSession 客户端离开 session。
// 当最后一个客户端离开时，不会立即删除 session，而是设置延迟删除标记，
// 为短时断连（如 App 切后台）预留重用窗口。窗口期后清理 goroutine 会移除该 session。
func (sm *SessionManager) LeaveSession(sessionID, clientID string) {
	sm.mu.Lock()
	defer sm.mu.Unlock()

	s, ok := sm.sessions[sessionID]
	if !ok {
		return
	}
	delete(s.Clients, clientID)
	s.LastActivity = time.Now()
	log.Printf("[Session] client left: %s session=%s", clientID, shortID(sessionID))

	// session 空时设置延迟删除标记（而非立即删除），
	// 为短时断连预留重用窗口。cleanupLoop 会在 PendingDeleteAt 过期后清理。
	if len(s.Clients) == 0 {
		if s.Scope != "" {
			// Scoped collaboration sessions are intentionally recoverable after the
			// phone leaves. Long-term cleanup is handled by scopedSessionStaleTimeout.
			s.PendingDeleteAt = time.Time{}
			return
		}
		s.PendingDeleteAt = time.Now().Add(sessionPendingDeleteDelay)
		log.Printf("[Session] session pending delete: %s project=%s (delay=%v)", shortID(sessionID), s.Project, sessionPendingDeleteDelay)
	}
}

// BroadcastToSession 向 session 内所有客户端广播消息（统一广播出口）。
func (sm *SessionManager) BroadcastToSession(sessionID, msgType string, data any, excludeID string) {
	if sm.hub == nil {
		return
	}
	sm.hub.BroadcastToSession(sessionID, msgType, data, excludeID)
}

// GetHistory 从底层 Queue 拉取历史消息，按用户命令 + 助理回复配对格式输出。
// 按 sessionID 过滤：只返回指定 session 内的命令历史，防止跨 session 泄漏。
// 跳过 chat action 的结果：relay 模式通过 cmd_step 实时推送，CmdQueue 中的
// chat 结果（如 "skipped, handled by relay"）是管理面噪音。
func (sm *SessionManager) GetHistory(sessionID string, n int) []HistoryMsg {
	if sm.queue == nil {
		return nil
	}
	results := sm.queue.History(n)
	if len(results) == 0 {
		return nil
	}
	msgs := make([]HistoryMsg, 0, len(results)*2)
	var nextSeq int64 // 本地序号，不在 GetHistory 中使用全局 NextSeq()，避免每次调用消耗全局序列号造成历史消息序号空洞
	for _, r := range results {
		// 按 session 隔离：跳过不属于当前 session 的命令。
		// 使用 Result.SessionID（由 NotifyResult 从 cmd.SessionID 复制），
		// 不依赖 cmd 仍在队列 map 中（超时命令的 cmd 可能已被清理）。
		if r.SessionID == "" || r.SessionID != sessionID {
			continue
		}

		// 查找关联命令（获取用户输入的文本、action 类型）
		cmd := sm.queue.GetCmd(r.CmdID)
		// 跳过 chat action：relay 模式通过 cmd_step 实时推送输出，
		// CmdQueue 中的 chat 结果是管理面噪音（"skipped" 等），
		// 不应出现在 GetHistory 中污染用户的历史视图。
		// cmd 可能在 evict 后为 nil，此时用 Result.Action 兜底判断
		//（Result.Action 由 NotifyResult 从 cmd.Action 复制，cmd 被 evict 后仍可识别）。
		action := r.Action
		if cmd != nil {
			action = cmd.Action
		}
		if action == agent.ActionChat {
			continue
		}

		// 兼容兜底：旧版 do_chat 结果的 Action 字段为空（Result 增加
		// Action 字段前创建的记录），此时检查 Output 内容是不是 JSON
		// 错误字符串（如 {"error":"previous chat still running..."}），
		// 是则跳过，防止遗留错误污染 relay 模式的会话历史。
		if action == "" && !isValidChatOutput(r.Output) {
			continue
		}

		nextSeq++

		cmdText := ""
		if cmd != nil {
			cmdText = cmd.Command
		}

		// 用户消息（命令输入），仅当有文本时才添加
		if cmdText != "" {
			msgs = append(msgs, HistoryMsg{
				Seq:       nextSeq,
				Source:    "user",
				MsgType:   "text",
				Content:   cmdText,
				CmdID:     r.CmdID,
				Timestamp: r.CreatedAt,
			})
		}

		nextSeq++

		// 助理/Agent 响应（命令输出）
		content := ""
		if r.Output != nil {
			switch v := r.Output.(type) {
			case string:
				content = v
			default:
				if b, err := json.Marshal(v); err == nil {
					content = string(b)
				} else {
					log.Printf("[Session] GetHistory: marshal Output failed for cmd=%s: %v", r.CmdID, err)
					content = "(content unavailable)"
				}
			}
		}
		// 非 chat action 标记为 "command"
		msgType := "command"
		msgs = append(msgs, HistoryMsg{
			Seq:       nextSeq,
			Source:    "agent",
			MsgType:   msgType,
			Content:   content,
			CmdID:     r.CmdID,
			Timestamp: r.CreatedAt,
		})
	}
	if len(msgs) == 0 {
		return nil
	}
	return msgs
}

// GetSessionByProject 按 project 查找 session。
func (sm *SessionManager) GetSessionByProject(project string) *Session {
	sm.mu.RLock()
	defer sm.mu.RUnlock()
	if sid, ok := sm.projects[project]; ok {
		return sm.sessions[sid]
	}
	return nil
}

// GetSessionByID 按 ID 查找 session。
func (sm *SessionManager) GetSessionByID(id string) *Session {
	sm.mu.RLock()
	defer sm.mu.RUnlock()
	return sm.sessions[id]
}

// RemoveSession 删除 session。
func (sm *SessionManager) RemoveSession(sessionID string) {
	sm.mu.Lock()
	defer sm.mu.Unlock()
	if s, ok := sm.sessions[sessionID]; ok {
		delete(sm.sessions, sessionID)
		sm.removeSessionMappings(sessionID)
		log.Printf("[Session] removed: %s project=%s", shortID(sessionID), s.Project)
	}
}

// removeSessionMappings removes default-project and scoped mappings.
// 调用方必须持有 sm.mu 写锁。
func (sm *SessionManager) removeSessionMappings(sessionID string) {
	for proj, sid := range sm.projects {
		if sid == sessionID {
			delete(sm.projects, proj)
		}
	}
	for scope, sid := range sm.scopes {
		if sid == sessionID {
			delete(sm.scopes, scope)
		}
	}
}

func scopedSessionKey(project, scope string) string {
	return project + "\x00" + scope
}

// shortID 截断 session ID 的前 8 字符用于日志，避免完整 ID 泄漏。
func shortID(id string) string {
	if len(id) > 8 {
		return id[:8]
	}
	return id
}

// isValidChatOutput 检查 Output 是否为有效的聊天输出（非 JSON 错误）。
// 用于兼容兜底：旧版 do_chat 结果的 Output 字段是 JSON 错误字符串
// （如 {"error":"previous chat still running..."}），这些结果在升级
// 前没有设置 Action 字段，无法通过 action chat 过滤，需要内容检测。
func isValidChatOutput(output any) bool {
	if output == nil {
		return false
	}
	s, ok := output.(string)
	if !ok {
		// 非 string 类型的 Output（如 map/struct）视为有效输出
		return true
	}
	// 常见 do_chat 错误模式
	if len(s) == 0 {
		return false
	}
	// JSON 错误消息：以 {"error": 开头
	if strings.HasPrefix(s, `{"error":"`) {
		return false
	}
	// 纯文本 timeout
	if s == "timeout waiting for agent" || s == "request cancelled" {
		return false
	}
	return true
}

// generateSessionID 生成 session ID（时间戳前缀 + 随机后缀，避免冲突）。
// 使用 8 字节 (64 bits) 随机数，防止枚举。
func generateSessionID() string {
	buf := make([]byte, 8)
	if _, err := rand.Read(buf); err != nil {
		// rand.Read 在现代 Go 中永不返回错误，此路径仅为防御性编程
		return "sess-" + time.Now().Format("060102-150405.000")
	}
	return "sess-" + time.Now().Format("060102-150405.000") + "-" + hex.EncodeToString(buf)
}
