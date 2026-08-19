package api

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"serein/internal/agent"
	"serein/internal/session"

	"github.com/go-chi/chi/v5"
)

// fileUploadRequest is the input for /agent/file.
type fileUploadRequest struct {
	FileName string `json:"file_name"`
	FileData string `json:"file_data"` // Base64 编码的文件内容
	Project  string `json:"project"`
}

// allowedFileExtensions 文件上传允许的文件扩展名白名单。
// 不含前导点的条目（如 Makefile、Dockerfile、.gitignore）匹配无扩展名常见文件名，
// 由 allowedFileExtraNames 兜底匹配。
var allowedFileExtensions = map[string]bool{
	".txt": true, ".py": true, ".go": true, ".js": true, ".ts": true,
	".json": true, ".yaml": true, ".yml": true, ".md": true, ".html": true,
	".css": true, ".java": true, ".rs": true, ".sh": true, ".bat": true,
	".ps1": true, ".png": true, ".jpg": true, ".jpeg": true, ".gif": true,
	".svg": true, ".bmp": true, ".webp": true, ".csv": true, ".xml": true,
	".toml": true, ".ini": true, ".cfg": true, ".conf": true, ".log": true,
	".sql": true, ".c": true, ".cpp": true, ".h": true, ".hpp": true,
	".proto": true, ".gradle": true, ".properties": true, ".env": true,
	".gitignore": true,
}

// allowedFileExtraNames 精确文件名匹配白名单（无扩展名的常见构建/配置文件）。
var allowedFileExtraNames = map[string]bool{
	"makefile": true, "dockerfile": true,
}

// maxFileSize 上传文件最大字节数（原始内容解码后）。
const maxFileSize = 10 << 20 // 10MB

// maxFileNameLen 文件名最大长度。
const maxFileNameLen = 255

// maxFileDataLen Base64 编码后允许的最大长度（10MB 原始数据 ≈ 14MB Base64）。
const maxFileDataLen = 15 << 20 // 15MB

// sanitizeFileName 清理文件名：URL 解码 + 去掉路径分隔符和空字符，截断超长名。
// 先 TrimSpace 防止纯空格文件名绕过空值检查后给用户困惑的错误消息。
func sanitizeFileName(name string) string {
	// URL 解码：手机端 picker 返回的 URI 可能包含 URL 编码的中文文件名
	if decoded, err := url.QueryUnescape(name); err == nil && decoded != "" {
		name = decoded
	}
	cleaned := strings.TrimSpace(strings.ReplaceAll(strings.ReplaceAll(name, "/", "_"), "\\", "_"))
	cleaned = strings.ReplaceAll(cleaned, "\x00", "")
	if len(cleaned) > maxFileNameLen {
		cleaned = cleaned[:maxFileNameLen]
	}
	if cleaned == "" {
		cleaned = "uploaded_file"
	}
	return cleaned
}

// isAllowedFileType 检查文件名扩展名是否在白名单中。
// 优先匹配精确文件名（无扩展名常见文件，如 Makefile、Dockerfile），
// 回退到后缀匹配标准扩展名。
func isAllowedFileType(name string) bool {
	lower := strings.ToLower(name)
	if allowedFileExtraNames[lower] {
		return true
	}
	for ext := range allowedFileExtensions {
		if strings.HasSuffix(lower, ext) {
			return true
		}
	}
	return false
}

// File POST /agent/file — 手机上传文件到服务器，创建 file_write 命令供 Agent 写入项目目录。
func (a *AgentRelay) File(w http.ResponseWriter, r *http.Request) {
	if !a.checkCmdQueue(w) {
		return
	}
	if !requireJSONContentType(w, r) {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxRequestBodyLen)

	var req fileUploadRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid json"})
		return
	}

	// 校验项目名
	if req.Project == "" {
		req.Project = "serein"
	}
	if len(req.Project) > maxProjectLen || !isPrintable(req.Project) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid project"})
		return
	}

	// 校验文件名
	req.FileName = sanitizeFileName(req.FileName)
	if req.FileName == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "file_name required"})
		return
	}
	if !isAllowedFileType(req.FileName) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "file type not allowed: " + req.FileName})
		return
	}

	// 校验 Base64 数据长度
	if len(req.FileData) > maxFileDataLen {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "file data too large"})
		return
	}
	if len(req.FileData) == 0 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "file_data required"})
		return
	}

	// 解码 Base64 验证合法性和大小
	decoded, err := base64DecodeString(req.FileData)
	if err != nil || len(decoded) == 0 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid base64 file_data"})
		return
	}
	if len(decoded) > maxFileSize {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "file too large (max 10MB)"})
		return
	}

	// 审计日志
	log.Printf("[File] upload: project=%q file=%q size=%d from=%s",
		req.Project, req.FileName, len(decoded), realClientIP(r))

	// 创建 sessionID（可选）
	sessionID := ""
	if a.SessionManager != nil {
		if s := a.SessionManager.GetOrCreateSession(req.Project); s != nil {
			sessionID = s.ID
		}
	}

	cmd := &agent.Command{
		Action:    agent.ActionFileWrite,
		Project:   req.Project,
		FileName:  req.FileName,
		FileData:  req.FileData, // 传递给 agent 的 base64 数据
		SessionID: sessionID,
	}
	cmdID := a.CmdQueue.EnqueueOnly(cmd)
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"ok": true, "cmd_id": cmdID, "file_name": req.FileName, "queued": true,
	})
}

// base64DecodeString 解码 base64 字符串，返回原始字节。
// HarmonyOS Base64Helper.encodeToString 输出标准 Base64（可能无 `=` 填充），
// 因此先补全填充再解码，然后回退 URL-safe 格式。
func base64DecodeString(s string) ([]byte, error) {
	// 补全 padding（标准 Base64 要求输入长度是 4 的倍数）
	if m := len(s) % 4; m != 0 {
		s += strings.Repeat("=", 4-m)
	}
	// 先尝试标准 base64（带填充）
	decoded, err := base64.StdEncoding.DecodeString(s)
	if err == nil {
		return decoded, nil
	}
	// 回退到 URL-safe base64（也补全填充）
	s2 := strings.ReplaceAll(strings.ReplaceAll(s, "+", "-"), "/", "_")
	if m := len(s2) % 4; m != 0 {
		s2 += strings.Repeat("=", 4-m)
	}
	return base64.URLEncoding.DecodeString(s2)
}

// ══════════════════════════════════════════════════════════════
// fileStore — 内存文件存储（TTL 自动清理）
// 用于 /agent/upload → relay HTTP 下载的文件中转。
// 文件在内存中保留最多 10 分钟，relay 下载后可主动删除。
// ══════════════════════════════════════════════════════════════

type storedFile struct {
	data      []byte
	fileName  string
	project   string
	sessionID string
	createdAt time.Time
}

type fileStore struct {
	mu    sync.RWMutex
	files map[string]*storedFile
}

func newFileStore() *fileStore {
	fs := &fileStore{files: make(map[string]*storedFile)}
	go fs.cleanup()
	return fs
}

func (fs *fileStore) store(data []byte, fileName, project, sessionID string) string {
	id := generateFileID()
	fs.mu.Lock()
	fs.files[id] = &storedFile{
		data:      data,
		fileName:  fileName,
		project:   project,
		sessionID: sessionID,
		createdAt: time.Now(),
	}
	// 防止内存泄漏：超过 50 个文件时清理最旧的
	if len(fs.files) > 50 {
		var oldestID string
		var oldestTime time.Time
		for id, f := range fs.files {
			if oldestID == "" || f.createdAt.Before(oldestTime) {
				oldestID = id
				oldestTime = f.createdAt
			}
		}
		delete(fs.files, oldestID)
	}
	fs.mu.Unlock()
	return id
}

func (fs *fileStore) get(id string) (*storedFile, bool) {
	fs.mu.RLock()
	f, ok := fs.files[id]
	fs.mu.RUnlock()
	return f, ok
}

func (fs *fileStore) delete(id string) {
	fs.mu.Lock()
	delete(fs.files, id)
	fs.mu.Unlock()
}

func (fs *fileStore) cleanup() {
	ticker := time.NewTicker(5 * time.Minute)
	defer ticker.Stop()
	for range ticker.C {
		fs.mu.Lock()
		for id, f := range fs.files {
			if time.Since(f.createdAt) > 10*time.Minute {
				delete(fs.files, id)
			}
		}
		fs.mu.Unlock()
	}
}

// generateFileID 生成 16 字节随机 hex 文件 ID（crypto/rand 保证唯一性）。
func generateFileID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		// 极端情况回退：用时间戳保证唯一性
		return strconv.FormatInt(time.Now().UnixNano(), 16)
	}
	return hex.EncodeToString(b)
}

// hasRelayInSession 检查指定 session 中是否有已连接的 relay 客户端。
func (h *wsHub) hasRelayInSession(sessionID string) bool {
	if sessionID == "" {
		return false
	}
	h.mu.RLock()
	defer h.mu.RUnlock()
	for c := range h.relayClients {
		if c.sessionID == sessionID {
			return true
		}
	}
	return false
}

// Upload POST /agent/upload — 手机上传原始二进制文件（无 Base64 编码）。
// 如果 relay 在线：发送 WS file_transfer 通知 relay 下载，绕过命令队列。
// 如果 relay 不在线：回退到命令队列（Base64 编码），由 Python agent 处理。
func (a *AgentRelay) Upload(w http.ResponseWriter, r *http.Request) {
	if !a.checkCmdQueue(w) {
		return
	}
	t0 := time.Now()

	// 从 Header 读取元数据
	fileName := sanitizeFileName(r.Header.Get("X-File-Name"))
	project := r.Header.Get("X-Project")
	if project == "" {
		project = "serein"
	}
	if len(project) > maxProjectLen || !isPrintable(project) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid project"})
		return
	}
	if fileName == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "X-File-Name header required"})
		return
	}
	if !isAllowedFileType(fileName) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "file type not allowed: " + fileName})
		return
	}

	// 读取原始二进制 body（无 Base64）
	r.Body = http.MaxBytesReader(w, r.Body, maxFileSize)
	data, err := io.ReadAll(r.Body)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "read body failed"})
		return
	}
	if len(data) == 0 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "empty file"})
		return
	}
	if len(data) > maxFileSize {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "file too large (max 10MB)"})
		return
	}
	t1 := time.Now()
	readMs := t1.Sub(t0).Milliseconds()

	// 获取或创建 session
	sessionID := ""
	if a.SessionManager != nil {
		if s := a.SessionManager.GetOrCreateSession(project); s != nil {
			sessionID = s.ID
		}
	}

	// 存储文件到内存
	fileID := a.fileStore.store(data, fileName, project, sessionID)

	log.Printf("[Upload] file=%q size=%d project=%q file_id=%s read_ms=%d from=%s",
		fileName, len(data), project, fileID, readMs, realClientIP(r))

	// 检查 relay 是否在线
	if a.wsHub != nil && a.wsHub.hasRelayInSession(sessionID) {
		// relay 在线：发送 WS file_transfer 通知 relay 下载
		a.wsHub.BroadcastToSession(sessionID, session.MsgTypeFileTransfer, map[string]interface{}{
			"file_id":   fileID,
			"file_name": fileName,
			"project":   project,
			"size":      len(data),
		}, "")
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"ok": true, "file_id": fileID, "via": "relay",
		})
		return
	}

	// relay 不在线：回退到命令队列（Base64 编码）
	base64Data := base64.StdEncoding.EncodeToString(data)
	cmd := &agent.Command{
		Action:    agent.ActionFileWrite,
		Project:   project,
		FileName:  fileName,
		FileData:  base64Data,
		SessionID: sessionID,
	}
	cmdID := a.CmdQueue.EnqueueOnly(cmd)
	// 回退模式下可以删除内存中的文件（命令队列已有 Base64 副本）
	a.fileStore.delete(fileID)
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"ok": true, "file_id": fileID, "cmd_id": cmdID, "via": "agent",
	})
}

// DownloadFile GET /agent/file/{id} — relay/agent 下载原始二进制文件。
// 鉴权：HOOK_TOKEN（relay/agent 侧）。下载后自动删除内存副本（一次性下载）。
func (a *AgentRelay) DownloadFile(w http.ResponseWriter, r *http.Request) {
	if !a.checkCmdQueue(w) {
		return
	}
	t0 := time.Now()
	fileID := chi.URLParam(r, "id")
	if fileID == "" || len(fileID) > maxCmdIDLen {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid file id"})
		return
	}

	f, ok := a.fileStore.get(fileID)
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "file not found or expired"})
		return
	}

	// 写入 HTTP 响应（原始二进制，无 Base64）
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", "attachment; filename=\""+f.fileName+"\"")
	w.Header().Set("Content-Length", strconv.Itoa(len(f.data)))
	w.Write(f.data)

	log.Printf("[DownloadFile] file_id=%s file=%q size=%d send_ms=%d to=%s",
		fileID, f.fileName, len(f.data), time.Since(t0).Milliseconds(), realClientIP(r))

	// 下载完成后删除内存副本（一次性下载，防止内存泄漏）
	a.fileStore.delete(fileID)
}
