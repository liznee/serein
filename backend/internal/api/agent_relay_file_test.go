package api

import (
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// TestSanitizeFileName 验证文件名清理逻辑
func TestSanitizeFileName(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected string
	}{
		{"normal file", "test.txt", "test.txt"},
		{"path traversal with /", "../../etc/passwd", ".._.._etc_passwd"},
		{"path traversal with \\", "..\\..\\windows\\system32", ".._.._windows_system32"},
		{"null byte", "file\x00.txt", "file.txt"},
		{"very long name trimmed", strings.Repeat("a", 300), strings.Repeat("a", 255)},
		{"empty becomes default", "", "uploaded_file"},
		{"just slash", "/", "_"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := sanitizeFileName(tt.input)
			if got != tt.expected {
				t.Errorf("sanitizeFileName(%q) = %q, want %q", tt.input, got, tt.expected)
			}
		})
	}
}

// TestIsAllowedFileType 验证文件类型白名单校验逻辑
func TestIsAllowedFileType(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		allowed  bool
	}{
		{"standard .txt", "test.txt", true},
		{"standard .go", "main.go", true},
		{"standard .py", "app.py", true},
		{"standard .json", "config.json", true},
		{"uppercase extension", "TEST.GO", true},
		{"mixed case extension", "Test.Py", true},
		{"executable .exe", "virus.exe", false},
		{"archive .zip", "data.zip", false},
		{"binary .dll", "lib.dll", false},
		{"no extension reject", "README", false},
		{"unknown dotfile reject", ".envrc", false},
		// allowedFileExtraNames 精确匹配
		{"Dockerfile exact", "Dockerfile", true},
		{"Makefile exact", "Makefile", true},
		{"gitignore exact", ".gitignore", true},
		{"lowercase makefile", "makefile", true},
		{"lowercase dockerfile", "dockerfile", true},
		// 负例
		{"Dockerfile with ext", "Dockerfile.txt", true},   // 匹配 .txt
		{"false Makefile", "fake_Makefile", false},         // 不在白名单
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := isAllowedFileType(tt.input)
			if got != tt.allowed {
				t.Errorf("isAllowedFileType(%q) = %v, want %v", tt.input, got, tt.allowed)
			}
		})
	}
}

// TestBase64DecodeString 验证 Base64 解码
func TestBase64DecodeString(t *testing.T) {
	// 标准 Base64
	original := "Hello, World!"
	encoded := base64.StdEncoding.EncodeToString([]byte(original))
	decoded, err := base64DecodeString(encoded)
	if err != nil {
		t.Fatalf("standard base64 decode failed: %v", err)
	}
	if string(decoded) != original {
		t.Errorf("standard decode: got %q, want %q", string(decoded), original)
	}

	// URL-safe Base64（无填充）
	rawBytes := []byte{0xFF, 0xFE, 0xFD}
	urlEncoded := base64.RawURLEncoding.EncodeToString(rawBytes)
	decoded2, err2 := base64DecodeString(urlEncoded)
	if err2 != nil {
		t.Fatalf("url-safe base64 decode failed: %v", err2)
	}
	if len(decoded2) != 3 || decoded2[0] != 0xFF || decoded2[1] != 0xFE || decoded2[2] != 0xFD {
		t.Errorf("url-safe decode: got %v, want [255 254 253]", decoded2)
	}

	// 非法 Base64
	_, err3 := base64DecodeString("!!!invalid!!!")
	if err3 == nil {
		t.Error("invalid base64 should return error")
	}
}

// TestFileUploadBasic 测试基本文件上传流程
func TestFileUploadBasic(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	content := "print('hello')"
	b64Content := base64.StdEncoding.EncodeToString([]byte(content))

	resp := agentRelayDo(t, srv, "POST", "/agent/file", "application/json",
		`{"file_name":"test.py","file_data":"`+b64Content+`","project":"test-proj"}`)
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("file upload want 200, got %d", resp.StatusCode)
	}

	var body map[string]interface{}
	json.NewDecoder(resp.Body).Decode(&body)
	if body["ok"] != true {
		t.Errorf("file upload want ok:true, got %v", body)
	}
	if body["cmd_id"] == "" || body["cmd_id"] == nil {
		t.Errorf("file upload want non-empty cmd_id, got %v", body["cmd_id"])
	}
	if body["file_name"] != "test.py" {
		t.Errorf("file upload want file_name=test.py, got %v", body["file_name"])
	}
	if body["queued"] != true {
		t.Errorf("file upload want queued:true, got %v", body["queued"])
	}
}

// TestFileUploadRejectsBadType 测试非法文件类型的拒绝
func TestFileUploadRejectsBadType(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	content := "some binary"
	b64Content := base64.StdEncoding.EncodeToString([]byte(content))

	resp := agentRelayDo(t, srv, "POST", "/agent/file", "application/json",
		`{"file_name":"virus.exe","file_data":"`+b64Content+`","project":"test"}`)
	defer resp.Body.Close()
	if resp.StatusCode != 400 {
		t.Fatalf("bad file type want 400, got %d", resp.StatusCode)
	}
	var body map[string]string
	json.NewDecoder(resp.Body).Decode(&body)
	if !strings.Contains(body["error"], "file type not allowed") {
		t.Errorf("want file type error, got %v", body)
	}
}

// TestFileUploadRejectsTooLarge 测试超大文件的拒绝
func TestFileUploadRejectsTooLarge(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	// 超过 10MB 的 Base64 数据
	large := strings.Repeat("A", 16*1024*1024) // ~16MB base64
	resp := agentRelayDo(t, srv, "POST", "/agent/file", "application/json",
		`{"file_name":"big.txt","file_data":"`+large+`","project":"test"}`)
	defer resp.Body.Close()
	if resp.StatusCode != 400 {
		t.Fatalf("too large want 400, got %d", resp.StatusCode)
	}
}

// TestFileUploadAllowsDockerfile 测试 Dockerfile 精确文件名匹配
func TestFileUploadAllowsDockerfile(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	content := "FROM ubuntu:22.04\nCMD [\"bash\"]"
	b64Content := base64.StdEncoding.EncodeToString([]byte(content))

	resp := agentRelayDo(t, srv, "POST", "/agent/file", "application/json",
		`{"file_name":"Dockerfile","file_data":"`+b64Content+`","project":"test"}`)
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("Dockerfile upload want 200, got %d: %s", resp.StatusCode, readBody(t, resp))
	}
}

// TestFileUploadRejectsNoContentType 测试缺少 Content-Type 时的拒绝
func TestFileUploadRejectsNoContentType(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	req, _ := http.NewRequest("POST", srv.URL+"/agent/file",
		strings.NewReader(`{"file_name":"test.py","file_data":"dGVzdA==","project":"test"}`))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 415 {
		t.Errorf("no content-type want 415, got %d", resp.StatusCode)
	}
}

// TestFileUploadRejectsInvalidBase64 测试非法 Base64 的拒绝
func TestFileUploadRejectsInvalidBase64(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp := agentRelayDo(t, srv, "POST", "/agent/file", "application/json",
		`{"file_name":"test.py","file_data":"!!!invalid!!!","project":"test"}`)
	defer resp.Body.Close()
	if resp.StatusCode != 400 {
		t.Fatalf("invalid base64 want 400, got %d", resp.StatusCode)
	}
	var body map[string]string
	json.NewDecoder(resp.Body).Decode(&body)
	if !strings.Contains(body["error"], "invalid base64") {
		t.Errorf("want invalid base64 error, got %v", body)
	}
}

// TestFileUploadDefaultsProject 测试默认项目名
func TestFileUploadDefaultsProject(t *testing.T) {
	handler := setupAgentRelayTestServer(t, "hook-secret", "", true)
	srv := httptest.NewServer(handler)
	defer srv.Close()

	content := "data"
	b64Content := base64.StdEncoding.EncodeToString([]byte(content))

	resp := agentRelayDo(t, srv, "POST", "/agent/file", "application/json",
		`{"file_name":"test.txt","file_data":"`+b64Content+`"}`)
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("default project want 200, got %d", resp.StatusCode)
	}
}

// readBody 辅助读取响应体字符串
func readBody(t *testing.T, resp *http.Response) string {
	t.Helper()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	return string(b)
}
