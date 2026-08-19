// Package agent 远程控制命令中继。本地 Agent 通过 HTTP 长轮询从服务器取命令。
package agent

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"strconv"
	"sync"
	"time"

	"serein/internal/store"
)

type Action string

const (
	ActionStart     Action = "start"
	ActionStop      Action = "stop"
	ActionStatus    Action = "status"
	ActionExec      Action = "exec"
	ActionKillAll   Action = "kill-all"   // 紧急刹车：杀掉所有 claude.exe + 清空 chat 队列
	ActionChat      Action = "chat"       // 聊天消息（由 relay PTY 注入）
	ActionFileWrite Action = "file_write" // 手机上传文件写入项目目录
)

type Command struct {
	ID               string    `json:"id"`
	Action           Action    `json:"action"`
	Project          string    `json:"project"`
	AgentType        string    `json:"agent_type,omitempty"`         // start 时选择 claude/codex
	WorkScope        string    `json:"work_scope,omitempty"`         // isolated collaboration work item key
	AgentSessionID   string    `json:"agent_session_id,omitempty"`   // Codex/Claude session target
	AgentSessionMode string    `json:"agent_session_mode,omitempty"` // "new" or "resume"
	RuntimeMode      string    `json:"runtime_mode,omitempty"`       // "cli" or "desktop"
	Command          string    `json:"command,omitempty"`
	FileName         string    `json:"file_name,omitempty"`  // 文件上传：原始文件名
	FileData         string    `json:"file_data,omitempty"`  // 文件上传：Base64 编码的文件内容
	SessionID        string    `json:"session_id,omitempty"` // 关联的实时同步会话 ID
	CreatedAt        time.Time `json:"created_at"`
	notify           chan *Result
}

// Step 代表 agent 执行命令过程中的一个中间步骤（如 web_search、read_file、thinking 等）。
type Step struct {
	CmdID   string `json:"cmd_id"`
	Seq     int    `json:"seq"`               // 步序号，单调递增
	Event   string `json:"event"`             // "tool_use" / "tool_result" / "text" / "hook"
	Name    string `json:"name,omitempty"`    // 工具名如 "web_search"、"read_file"
	Content string `json:"content,omitempty"` // 步骤摘要（可 truncate）
}

type Result struct {
	CmdID     string    `json:"cmd_id"`
	Success   bool      `json:"success"`
	Output    any       `json:"output"`
	SessionID string    `json:"session_id,omitempty"` // 关联的 session ID（用于 GetHistory 按 session 过滤）
	CreatedAt time.Time `json:"created_at,omitempty"` // 命令创建时间（用于历史消息时间戳）
	Action    Action    `json:"action,omitempty"`     // 命令类型（持久化在 Result 中，供 GetHistory 在 cmd 被 evict 后仍可识别）
}

type Queue struct {
	mu         sync.Mutex
	pending    []*Command
	commands   map[string]*Command // cmdID -> Command (用于 Report 查找已 dequeue 的命令)
	dequeued   map[string]bool     // cmdID -> 已出队标记（防同一命令出队两次）
	reported   map[string]bool     // cmdID -> 已报告标记（身份绑定：同一 cmd_id 只能被 report 一次）
	history    []*Result
	waiters    []chan *Command
	maxHistory int
	steps      []*Step // 全局步骤缓冲区，最多保留最近 500 条
	maxSteps   int

	cmdRepo      *store.CommandRepo  // 命令执行统计持久化（可选）
	activityRepo *store.ActivityRepo // 活动时间线持久化（可选）
}

// maxStoredCommands commands map 中最多保留的命令数。超过此阈值时清理已完成命令，防止内存泄漏。
const maxStoredCommands = 500

func NewQueue(maxHistory int) *Queue {
	if maxHistory <= 0 {
		maxHistory = 20
	}
	return &Queue{
		maxHistory: maxHistory,
		maxSteps:   500,
		commands:   make(map[string]*Command),
		dequeued:   make(map[string]bool),
		reported:   make(map[string]bool),
	}
}

func (q *Queue) EnqueueCmd(ctx context.Context, cmd *Command, timeout time.Duration) *Result {
	cmd.ID = generateID()
	cmd.CreatedAt = time.Now()
	cmd.notify = make(chan *Result, 1)

	q.mu.Lock()
	q.pending = append(q.pending, cmd)
	q.commands[cmd.ID] = cmd
	if len(q.commands) > maxStoredCommands {
		q.evictCompletedCommands()
	}
	for _, ch := range q.waiters {
		select {
		case ch <- cmd:
		default:
		}
	}
	q.waiters = nil
	q.mu.Unlock()

	timer := time.NewTimer(timeout)
	defer timer.Stop()

	// Race-safe result handling. After timeout/cancel we removeCmd so late
	// NotifyResult arrivals are rejected by the `!ok` branch, preventing stale
	// results from polluting history or overwriting the timeout result.
	select {
	case r := <-cmd.notify:
		// 收到结果，停止 timer 并可能 drain fired 值
		if !timer.Stop() {
			select {
			case <-timer.C:
			default:
			}
		}
		q.recordResult(r)
		// 不移除 commands 映射：GetHistory 需要 cmd.Command 来生成用户消息。
		// 命令保留在 map 中直到被后续命令自然覆盖。EnqueueOnly 路径也从不移除。
		return r
	case <-timer.C:
		return q.handleTimeoutOrCancel(cmd, "timeout waiting for agent")
	case <-ctx.Done():
		if !timer.Stop() {
			select {
			case <-timer.C:
			default:
			}
		}
		return q.handleTimeoutOrCancel(cmd, "request cancelled")
	}
}

// handleTimeoutOrCancel handles the common timeout/cancel pattern.
// Ensures reported marking, result creation, and cleanup are consistent
// between timeout and context cancellation paths, preventing duplicate
// result pollution and late-arriving NotifyResult races.
func (q *Queue) handleTimeoutOrCancel(cmd *Command, errMsg string) *Result {
	q.mu.Lock()
	alreadyReported := q.reported[cmd.ID]
	if !alreadyReported {
		q.reported[cmd.ID] = true
	}
	q.mu.Unlock()
	r := &Result{CmdID: cmd.ID, Success: false, Output: errMsg, CreatedAt: cmd.CreatedAt, Action: cmd.Action}
	if !alreadyReported {
		q.recordResult(r)
	}
	q.removeCmd(cmd.ID)
	return r
}

// EnqueueOnly 入队但不阻塞等待执行结果。
// 用于 App 端快速连续发送命令的场景——后端立即返回 cmd_id，
// App 端轮询 /agent/history 拿结果，避免同步阻塞导致的并发上限。
func (q *Queue) EnqueueOnly(cmd *Command) string {
	cmd.ID = generateID()
	cmd.CreatedAt = time.Now()
	q.mu.Lock()
	q.pending = append(q.pending, cmd)
	q.commands[cmd.ID] = cmd
	if len(q.commands) > maxStoredCommands {
		q.evictCompletedCommands()
	}
	for _, ch := range q.waiters {
		select {
		case ch <- cmd:
		default:
		}
	}
	q.waiters = nil
	q.mu.Unlock()
	return cmd.ID
}

func (q *Queue) Dequeue(ctx context.Context, timeout time.Duration) *Command {
	q.mu.Lock()
	// 跳过已出队过的命令（防同一命令被取两次）
	for len(q.pending) > 0 {
		cmd := q.pending[0]
		q.pending = q.pending[1:]
		if q.dequeued[cmd.ID] {
			continue // 已出队过，丢弃
		}
		q.dequeued[cmd.ID] = true
		q.mu.Unlock()
		return cmd
	}
	ch := make(chan *Command, 1)
	q.waiters = append(q.waiters, ch)
	q.mu.Unlock()

	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case cmd := <-ch:
		// waiter 收到命令也标记已出队
		if !timer.Stop() {
			select {
			case <-timer.C:
			default:
			}
		}
		q.mu.Lock()
		if q.dequeued[cmd.ID] {
			q.mu.Unlock()
			return nil // 已出队过，不重复返回
		}
		q.dequeued[cmd.ID] = true
		q.mu.Unlock()
		return cmd
	case <-timer.C:
		q.mu.Lock()
		for i, w := range q.waiters {
			if w == ch {
				q.waiters = append(q.waiters[:i], q.waiters[i+1:]...)
				break
			}
		}
		q.mu.Unlock()
		return nil
	case <-ctx.Done():
		if !timer.Stop() {
			select {
			case <-timer.C:
			default:
			}
		}
		q.mu.Lock()
		for i, w := range q.waiters {
			if w == ch {
				q.waiters = append(q.waiters[:i], q.waiters[i+1:]...)
				break
			}
		}
		q.mu.Unlock()
		return nil
	}
}

// NotifyResult 接收 Agent 命令执行结果。
//
// 身份绑定：同一 cmd_id 只能被报告一次（reported map 守卫），
// 防止持有 HOOK_TOKEN 的多个 agent 同时 Report 同一个 cmd_id，
// 或 Agent 在 EnqueueCmd 超时后仍发送过期报告造成结果污损。
//
// 释放后访问防护：在锁下读取 cmd 所有需要的字段（CreatedAt / SessionID /
// Action / Project / notify）后释放锁，确保不出现"解锁后 cmd 被移除
// 仍访问其字段"的释放后访问（use-after-free）竞态。
func (q *Queue) NotifyResult(cmdID string, success bool, output any) {
	q.mu.Lock()

	// 身份绑定：拒绝重复报告
	if q.reported[cmdID] {
		q.mu.Unlock()
		return
	}

	cmd, ok := q.commands[cmdID]
	if !ok {
		// 命令已不存在（如 EnqueueCmd 超时已调用 removeCmd 清理），
		// 拒绝接受过期报告，防止与超时结果冲突。
		q.mu.Unlock()
		return
	}

	// 标记为已报告（必须在锁内，拒绝并发 NotifyResult 重复提交）
	q.reported[cmdID] = true

	// 在锁下读取 cmd 所有需要的字段，之后释放锁以避免 channel 操作持锁
	createdAt := cmd.CreatedAt
	sessionID := cmd.SessionID
	action := cmd.Action
	project := cmd.Project
	notifyCh := cmd.notify

	q.mu.Unlock()

	// 记录结果（内部有锁，不会与已释放的 cmd 产生竞态）
	result := &Result{CmdID: cmdID, Success: success, Output: output,
		SessionID: sessionID, CreatedAt: createdAt, Action: action}
	q.recordResult(result)

	// 通知等待的 EnqueueCmd goroutine（非阻塞，channel 缓冲区为 1）
	if notifyCh != nil {
		select {
		case notifyCh <- result:
		default:
		}
	}

	// 持久化命令执行统计（cmd 字段已在锁内读取，不再依赖 cmd 指针）
	if q.cmdRepo != nil {
		duration := time.Since(createdAt).Milliseconds()
		q.cmdRepo.Save(cmdID, string(action), project, sessionID, success, duration)
	}
}

func (q *Queue) LastStatus() *Result {
	q.mu.Lock()
	defer q.mu.Unlock()
	if len(q.history) == 0 {
		return nil
	}
	return q.history[len(q.history)-1]
}

func (q *Queue) PendingCount() int {
	q.mu.Lock()
	defer q.mu.Unlock()
	return len(q.pending)
}

// NotifyStep 接收一个中间步骤，追加到步骤缓冲区（不阻塞主 Result 通道）。
func (q *Queue) NotifyStep(step *Step) {
	q.mu.Lock()
	q.steps = append(q.steps, step)
	if len(q.steps) > q.maxSteps {
		q.steps = q.steps[len(q.steps)-q.maxSteps:]
	}
	q.mu.Unlock()
}

// Steps 返回指定 cmd_id 的步骤列表（按 seq 升序，从全局 500 条缓冲中筛选）。
func (q *Queue) Steps(cmdID string, afterSeq int) []Step {
	q.mu.Lock()
	defer q.mu.Unlock()
	out := []Step{}
	for _, s := range q.steps {
		if s.CmdID == cmdID && s.Seq > afterSeq {
			out = append(out, *s)
		}
	}
	return out
}

// History 返回最近 N 条执行结果（浅拷贝，无锁不放指针）。
func (q *Queue) History(n int) []Result {
	q.mu.Lock()
	defer q.mu.Unlock()
	if n <= 0 || n > len(q.history) {
		n = len(q.history)
	}
	out := make([]Result, n)
	start := len(q.history) - n
	for i := 0; i < n; i++ {
		h := q.history[start+i]
		out[i] = *h
	}
	return out
}

func (q *Queue) recordResult(r *Result) {
	q.mu.Lock()
	q.history = append(q.history, r)
	if len(q.history) > q.maxHistory {
		q.history = q.history[len(q.history)-q.maxHistory:]
	}
	q.mu.Unlock()
}

func (q *Queue) SetCmdRepo(repo *store.CommandRepo) {
	q.mu.Lock()
	q.cmdRepo = repo
	q.mu.Unlock()
}

func (q *Queue) CmdRepo() *store.CommandRepo {
	q.mu.Lock()
	defer q.mu.Unlock()
	return q.cmdRepo
}

func (q *Queue) SetActivityRepo(repo *store.ActivityRepo) {
	q.mu.Lock()
	q.activityRepo = repo
	q.mu.Unlock()
}

func (q *Queue) ActivityRepo() *store.ActivityRepo {
	q.mu.Lock()
	defer q.mu.Unlock()
	return q.activityRepo
}

// GetCmd 通过 cmdID 查找命令（只读，用于 Report 时获取 SessionID）。
// 返回浅拷贝，避免锁外修改，同时复制 notify channel 引用以防止调用方误用 nil channel 死锁。
func (q *Queue) GetCmd(cmdID string) *Command {
	q.mu.Lock()
	defer q.mu.Unlock()
	cmd, ok := q.commands[cmdID]
	if !ok {
		return nil
	}
	return &Command{
		ID: cmd.ID, Action: cmd.Action, Project: cmd.Project,
		Command: cmd.Command, FileName: cmd.FileName, FileData: cmd.FileData,
		SessionID: cmd.SessionID, CreatedAt: cmd.CreatedAt,
		notify: cmd.notify,
	}
}

// evictCompletedCommands 清理 commands map 中已完成的通知命令。
// 当 commands map 超过 maxStoredCommands 阈值时触发。
// 一个命令可被清理的条件：
//   - 不在 pending 队列中（不再等待 agent 取走）
//   - 在 history 中有对应结果（已通知完结）
//   - 或创建超过 30 分钟且无 history 的僵尸命令（EnqueueOnly 后永不 report）
//
// 调用方必须持有 q.mu 锁。
func (q *Queue) evictCompletedCommands() {
	pendingIDs := make(map[string]bool, len(q.pending))
	for _, c := range q.pending {
		pendingIDs[c.ID] = true
	}
	historyIDs := make(map[string]bool, len(q.history))
	for _, r := range q.history {
		if r != nil {
			historyIDs[r.CmdID] = true
		}
	}
	timeThreshold := time.Now().Add(-30 * time.Minute)
	for id := range q.commands {
		if pendingIDs[id] {
			continue
		}
		if historyIDs[id] {
			delete(q.commands, id)
			delete(q.dequeued, id)
			delete(q.reported, id)
			continue
		}
		// 僵尸命令兜底：超过 30 分钟仍未 report 的 EnqueueOnly 命令
		if cmd, ok := q.commands[id]; ok && cmd.CreatedAt.Before(timeThreshold) {
			delete(q.commands, id)
			delete(q.dequeued, id)
			delete(q.reported, id)
		}
	}
}

func (q *Queue) removeCmd(cmdID string) {
	q.mu.Lock()
	delete(q.commands, cmdID)
	delete(q.reported, cmdID)
	delete(q.dequeued, cmdID)
	// Remove from pending queue to prevent zombie commands
	for i, c := range q.pending {
		if c.ID == cmdID {
			q.pending = append(q.pending[:i], q.pending[i+1:]...)
			break
		}
	}
	q.mu.Unlock()
}

var idCounter struct {
	sync.Mutex
	n int64
}

func generateID() string {
	idCounter.Lock()
	idCounter.n++
	n := idCounter.n
	idCounter.Unlock()

	// 加入 4 字节随机十六进制后缀（crypto/rand），防止进程重启后计数器归零
	// 导致同一秒内生成与重启前相同的 ID。相比 math/rand，crypto/rand 提供
	// 密码学安全随机性，且无需全局种子初始化。
	var buf [4]byte
	if _, err := rand.Read(buf[:]); err != nil {
		// 极端情况（如熵池耗尽）回退为纯自增，仍可满足唯一性要求
		return time.Now().Format("20060102-150405") + "-" + strconv.Itoa(int(n))
	}
	return time.Now().Format("20060102-150405") + "-" + strconv.Itoa(int(n)) + "-" + hex.EncodeToString(buf[:])
}
