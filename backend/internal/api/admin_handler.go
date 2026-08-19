package api

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type AdminHandler struct {
	BinaryPath    string
	NewBinaryPath string
	HapPath       string

	mu       sync.Mutex
	dlTokens map[string]time.Time // token → expiry
}

// DlLink POST /admin/dl-link — 生成一次性下载链接（需 CLIENT_TOKEN）
func (h *AdminHandler) DlLink(w http.ResponseWriter, r *http.Request) {
	if h.HapPath == "" {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "no HAP"})
		return
	}
	token := make([]byte, 16)
	rand.Read(token)
	t := hex.EncodeToString(token)

	h.mu.Lock()
	if h.dlTokens == nil {
		h.dlTokens = make(map[string]time.Time)
	}
	h.dlTokens[t] = time.Now().Add(5 * time.Minute)
	h.mu.Unlock()

	writeJSON(w, http.StatusOK, map[string]string{
		"url": "/dl/hap?t=" + t,
	})
}

// DlHap GET /dl/hap?t=xxx — 公开一次性下载
func (h *AdminHandler) DlHap(w http.ResponseWriter, r *http.Request) {
	t := r.URL.Query().Get("t")
	if t == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing token"})
		return
	}

	h.mu.Lock()
	expiry, ok := h.dlTokens[t]
	if !ok || time.Now().After(expiry) {
		if ok {
			delete(h.dlTokens, t)
		}
		h.mu.Unlock()
		writeJSON(w, http.StatusGone, map[string]string{"error": "token expired or used"})
		return
	}
	delete(h.dlTokens, t) // 一次性使用
	h.mu.Unlock()

	if h.HapPath == "" {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "no HAP configured"})
		return
	}
	info, err := os.Stat(h.HapPath)
	if err != nil {
		slog.Error("DlHap Stat failed", "path", h.HapPath, "err", err)
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "HAP file not found"})
		return
	}
	f, err := os.Open(h.HapPath)
	if err != nil {
		slog.Error("DlHap Open failed", "path", h.HapPath, "err", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "cannot open HAP file"})
		return
	}
	defer f.Close()
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Length", fmt.Sprintf("%d", info.Size()))
	w.Header().Set("Content-Disposition", "attachment; filename=serein.hap")
	io.Copy(w, f)
}

// serveHap 共用（Download 路由使用，auth 中间件已校验权限）
func (h *AdminHandler) serveHap(w http.ResponseWriter) {
	if h.HapPath == "" {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "no HAP configured"})
		return
	}
	info, err := os.Stat(h.HapPath)
	if err != nil {
		slog.Error("serveHap Stat failed", "path", h.HapPath, "err", err)
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "HAP file not found"})
		return
	}
	f, err := os.Open(h.HapPath)
	if err != nil {
		slog.Error("serveHap Open failed", "path", h.HapPath, "err", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "cannot open HAP file"})
		return
	}
	defer f.Close()
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Length", fmt.Sprintf("%d", info.Size()))
	w.Header().Set("Content-Disposition", "attachment; filename=serein.hap")
	io.Copy(w, f)
}

// Download GET /admin/dl — 需要 CLIENT_TOKEN（auth 中间件校验）
// 保留供 App 内下载使用
func (h *AdminHandler) Download(w http.ResponseWriter, r *http.Request) {
	h.serveHap(w)
}

// Deploy POST /admin/deploy
// 1. rename 旧二进制 → .old
// 2. copy 新二进制到目标
// 3. 回 200 给客户端
// 4. 延时 1s 后退出 → run.sh 自动重启新版
func (h *AdminHandler) Deploy(w http.ResponseWriter, r *http.Request) {
	if _, err := os.Stat(h.NewBinaryPath); os.IsNotExist(err) {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "no new binary"})
		return
	}

	oldPath := h.BinaryPath + ".old"
	if err := os.Rename(h.BinaryPath, oldPath); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "rename failed: " + err.Error()})
		return
	}

	if err := copyFileAtomic(h.NewBinaryPath, h.BinaryPath); err != nil {
		os.Rename(oldPath, h.BinaryPath)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "copy failed: " + err.Error()})
		return
	}
	os.Chmod(h.BinaryPath, 0755)

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"ok":      true,
		"message": "binary replaced, restarting",
	})

	// 部署完成后删除 next 文件，避免检查更新重复提示
	os.Remove(h.NewBinaryPath)

	// 延时退出 — run.sh 会检测进程退出并自动重启新版本
	go func() {
		time.Sleep(1 * time.Second)
		os.Exit(0)
	}()
}

// UploadBinary POST /admin/upload-binary — 通过 HTTP 上传新二进制文件（替代 SCP）。
// 鉴权：deployAuth（HOOK_TOKEN 或 CLIENT_TOKEN）。
// 接收原始二进制 body，写入 NewBinaryPath，后续可调用 /admin/deploy 热替换。
// 用于 SSH 不可达时通过 HTTPS (Cloudflare) 部署新版本。
func (h *AdminHandler) UploadBinary(w http.ResponseWriter, r *http.Request) {
	t0 := time.Now()

	// 限制 body 大小（50MB，后端二进制通常 < 30MB）
	r.Body = http.MaxBytesReader(w, r.Body, 50<<20)
	data, err := io.ReadAll(r.Body)
	if err != nil {
		slog.Error("UploadBinary: read body failed", "err", err)
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "read body failed: " + err.Error()})
		return
	}
	if len(data) == 0 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "empty body"})
		return
	}
	expectedHex := strings.TrimSpace(r.Header.Get("X-Binary-SHA256"))
	expected, decodeErr := hex.DecodeString(expectedHex)
	if decodeErr != nil || len(expected) != sha256.Size {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing or invalid X-Binary-SHA256"})
		return
	}
	actual := sha256.Sum256(data)
	if subtle.ConstantTimeCompare(actual[:], expected) != 1 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "binary sha256 mismatch"})
		return
	}

	// 写入 NewBinaryPath
	if err := writeFileAtomic(h.NewBinaryPath, data, 0755); err != nil {
		slog.Error("UploadBinary: write failed", "path", h.NewBinaryPath, "err", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "write failed: " + err.Error()})
		return
	}
	os.Chmod(h.NewBinaryPath, 0755)

	readMs := time.Since(t0).Milliseconds()
	slog.Info("UploadBinary: uploaded", "size", len(data), "path", h.NewBinaryPath, "read_ms", readMs)
	log.Printf("[UploadBinary] size=%d path=%s read_ms=%d", len(data), h.NewBinaryPath, readMs)

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"ok":      true,
		"message": "binary uploaded, call /admin/deploy to hot-swap",
		"size":    len(data),
		"sha256":  hex.EncodeToString(actual[:]),
	})
}

func (h *AdminHandler) CheckUpdate(w http.ResponseWriter, r *http.Request) {
	exists := false
	if _, err := os.Stat(h.NewBinaryPath); err == nil {
		exists = true
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"update_available": exists,
	})
}

// DeployConfig POST /agent/deploy-config — 返回部署命令模板字符串。
// 将部署命令构造从 HAP 侧移到服务端，避免在 HAP 中硬编码 Python 内联命令。
// 接受的 type: "backend" / "app" / "full"，返回值中的 "command" 字段即为可执行的
// Python 内联命令，由 agent 的 exec action 在 PC 端执行。
// PC 端的部署环境变量（DEPLOY_HOST、SEREIN_PROJECT_ROOT 等）在运行时通过
// os.environ.get() 读取，不在网络传输中暴露具体值。
func (h *AdminHandler) DeployConfig(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Type string `json:"type"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid json"})
		return
	}

	cmd, err := h.buildDeployCmd(req.Type)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	cmd = addArtifactHashHeader(cmd)
	writeJSON(w, http.StatusOK, map[string]string{
		"command": cmd,
	})
}

// addArtifactHashHeader keeps the generated release command compatible with
// UploadBinary's integrity check without duplicating the long inline command
// in every deploy variant.
func addArtifactHashHeader(cmd string) string {
	cmd = strings.ReplaceAll(cmd, "import subprocess,urllib.request;", "import subprocess,urllib.request,hashlib;")
	cmd = strings.ReplaceAll(cmd,
		"data=open('/tmp/serein-server','rb').read(),method='POST'",
		"data=(data:=open('/tmp/serein-server','rb').read()),method='POST'")
	cmd = strings.ReplaceAll(cmd,
		"req.add_header('Content-Type','application/octet-stream');",
		"req.add_header('Content-Type','application/octet-stream'); req.add_header('X-Binary-SHA256',hashlib.sha256(data).hexdigest());")
	return cmd
}

// buildDeployCmd 构建部署用的 Python 内联命令字符串。
// 拷贝自 harmony/DeployConfig.ets 的同名函数，将命令构造逻辑从 HAP 移到后端。
func (h *AdminHandler) buildDeployCmd(typeStr string) (string, error) {
	validTypes := map[string]bool{"backend": true, "app": true, "full": true}
	if !validTypes[typeStr] {
		return "", fmt.Errorf("invalid deploy type: %s (must be backend/app/full)", typeStr)
	}

	// 环境变量键名
	envKeys := map[string]string{
		"ENV_PROJECT_ROOT":    "SEREIN_PROJECT_ROOT",
		"ENV_PYTHON_EXE":      "SEREIN_PYTHON",
		"ENV_HARMONY_PROJECT": "SEREIN_HARMONY_PROJECT",
		"ENV_HVIGOR_BAT":      "SEREIN_HVIGOR_BAT",
		"ENV_JBR_BIN":         "SEREIN_JBR_BIN",
		"ENV_SDK_HOME":        "SEREIN_SDK_HOME",
	}

	pyEnvRead := fmt.Sprintf(
		`import os;h=os.environ.get("DEPLOY_HOST","");u=os.environ.get("DEPLOY_USER","");p=os.environ.get("DEPLOY_TARGET_PATH","");pr=os.environ.get("%s","");pp=os.environ.get("%s","");ph=os.environ.get("%s","");pv=os.environ.get("%s","");pj=os.environ.get("%s","");ps=os.environ.get("%s","");errs=[];if not h: errs.append("DEPLOY_HOST");if not u: errs.append("DEPLOY_USER");if not p: errs.append("DEPLOY_TARGET_PATH");if not pr: errs.append("%s");if not pp: errs.append("%s");if not ph: errs.append("%s");if not pv: errs.append("%s");if not pj: errs.append("%s");if not ps: errs.append("%s");if errs: raise RuntimeError("缺少环境变量: "+", ".join(errs));dest=f"{u}@{h}:{p}"`,
		envKeys["ENV_PROJECT_ROOT"], envKeys["ENV_PYTHON_EXE"],
		envKeys["ENV_HARMONY_PROJECT"], envKeys["ENV_HVIGOR_BAT"],
		envKeys["ENV_JBR_BIN"], envKeys["ENV_SDK_HOME"],
		envKeys["ENV_PROJECT_ROOT"], envKeys["ENV_PYTHON_EXE"],
		envKeys["ENV_HARMONY_PROJECT"], envKeys["ENV_HVIGOR_BAT"],
		envKeys["ENV_JBR_BIN"], envKeys["ENV_SDK_HOME"],
	)

	switch typeStr {
	case "backend":
		// 使用 HTTP 上传替代 SCP（SSH 可能被 Cloudflare/防火墙阻断）
		// 流程：交叉编译 → HTTP 上传到 /admin/upload-binary → 手机点部署
		return fmt.Sprintf("python -c \"%s; import subprocess,urllib.request; os.chdir(pr); subprocess.run([pp,'scripts/bump_version.py','patch']); v=open('VERSION').read().strip(); os.chdir('backend'); subprocess.run(['go','build','-ldflags',f'-X main.BuildVersion={v}','-o','/tmp/serein-server','./cmd/server'],env={**os.environ,'GOOS':'linux','GOARCH':'amd64'}); backend_url=os.environ.get('SEREIN_BACKEND',''); token=os.environ.get('SEREIN_HOOK_TOKEN',''); req=urllib.request.Request(backend_url+'/admin/upload-binary',data=open('/tmp/serein-server','rb').read(),method='POST'); req.add_header('Authorization','Bearer '+token); req.add_header('Content-Type','application/octet-stream'); resp=urllib.request.urlopen(req,timeout=120); print('后端已上传:',resp.read().decode()); print('去设置页点部署新版本')\"", pyEnvRead), nil
	case "app":
		return fmt.Sprintf("python -c \"%s; import subprocess; env={**os.environ,'PATH':pj+';'+os.environ.get('PATH',''),'DEVECO_SDK_HOME':ps}; subprocess.run([pv,'--mode','module','-p','module=entry','-p','buildMode=debug','assembleHap'],cwd=ph,env=env); print('HAP编译完成，PC执行 hdc install -r 安装')\"", pyEnvRead), nil
	default: // "full"
		// 使用 HTTP 上传替代 SCP
		return fmt.Sprintf("python -c \"%s; import subprocess,urllib.request; os.chdir(pr); subprocess.run([pp,'scripts/bump_version.py','patch']); v=open('VERSION').read().strip(); os.chdir('backend'); subprocess.run(['go','build','-ldflags',f'-X main.BuildVersion={v}','-o','/tmp/serein-server','./cmd/server'],env={**os.environ,'GOOS':'linux','GOARCH':'amd64'}); backend_url=os.environ.get('SEREIN_BACKEND',''); token=os.environ.get('SEREIN_HOOK_TOKEN',''); req=urllib.request.Request(backend_url+'/admin/upload-binary',data=open('/tmp/serein-server','rb').read(),method='POST'); req.add_header('Authorization','Bearer '+token); req.add_header('Content-Type','application/octet-stream'); resp=urllib.request.urlopen(req,timeout=120); print('后端已上传:',resp.read().decode()); env2={**os.environ,'PATH':pj+';'+os.environ.get('PATH',''),'DEVECO_SDK_HOME':ps}; subprocess.run([pv,'--mode','module','-p','module=entry','-p','buildMode=debug','assembleHap'],cwd=ph,env=env2); print('全量发版完成，后端去设置页部署，前端PC hdc安装')\"", pyEnvRead), nil
	}
}

func copyFileAtomic(src, dst string) error {
	s, err := os.Open(src)
	if err != nil {
		return err
	}
	defer s.Close()
	dir := filepath.Dir(dst)
	tmp, err := os.CreateTemp(dir, "."+filepath.Base(dst)+".tmp-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	cleanup := func() {
		_ = tmp.Close()
		_ = os.Remove(tmpName)
	}
	if _, err = io.Copy(tmp, s); err != nil {
		cleanup()
		return err
	}
	if err = tmp.Sync(); err != nil {
		cleanup()
		return err
	}
	if err = tmp.Close(); err != nil {
		_ = os.Remove(tmpName)
		return err
	}
	if err = os.Chmod(tmpName, 0755); err != nil {
		_ = os.Remove(tmpName)
		return err
	}
	if err = os.Rename(tmpName, dst); err != nil {
		_ = os.Remove(tmpName)
		return err
	}
	return nil
}

func writeFileAtomic(path string, data []byte, mode os.FileMode) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, "."+filepath.Base(path)+".tmp-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	cleanup := func() {
		_ = tmp.Close()
		_ = os.Remove(tmpName)
	}
	if _, err = tmp.Write(data); err != nil {
		cleanup()
		return err
	}
	if err = tmp.Sync(); err != nil {
		cleanup()
		return err
	}
	if err = tmp.Close(); err != nil {
		_ = os.Remove(tmpName)
		return err
	}
	if err = os.Chmod(tmpName, mode); err != nil {
		_ = os.Remove(tmpName)
		return err
	}
	if err = os.Rename(tmpName, path); err != nil {
		_ = os.Remove(tmpName)
		return err
	}
	return nil
}
