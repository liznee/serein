package risk

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestClassifyGreen(t *testing.T) {
	e := New(nil, nil, nil)
	cases := []struct{ tool, cmd string }{
		{"Read", ""}, {"Glob", ""}, {"Grep", ""}, {"LS", ""},
		{"Bash", "ls -la"}, {"Bash", "cat README.md"}, {"Bash", "pwd"}, {"Bash", "echo hello"},
		{"Bash", "git status"}, {"Bash", "git log --oneline"}, {"Bash", "git diff"},
		{"Bash", "go test ./..."}, {"Bash", "go build ./cmd/server"},
		{"Bash", "npm run build"}, {"Bash", "npm run test"},
		{"Bash", "grep -r foo ."}, {"Bash", "rg pattern src/"},
		{"Bash", "python --version"}, {"Bash", "go version"},
		{"Bash", "docker ps"}, {"Bash", "pytest tests/"},
	}
	for _, c := range cases {
		lvl, _ := e.Classify("", c.tool, c.cmd)
		if lvl != Green {
			t.Errorf("%q %q: want green, got %s", c.tool, c.cmd, lvl)
		}
	}
}

func TestClassifyYellow(t *testing.T) {
	e := New(nil, nil, nil)
	cases := []struct{ tool, cmd string }{
		{"Edit", ""}, {"Write", ""}, {"NotebookEdit", ""},
		{"Bash", "git add ."}, {"Bash", "git commit -m msg"}, {"Bash", "git stash"},
		{"Bash", "npm install"}, {"Bash", "npm install lodash"},
		{"Bash", "pip install requests"}, {"Bash", "go get x"}, {"Bash", "go mod tidy"},
		{"Bash", "mkdir build"}, {"Bash", "cp a b"}, {"Bash", "touch f"},
	}
	for _, c := range cases {
		lvl, _ := e.Classify("", c.tool, c.cmd)
		if lvl != Yellow {
			t.Errorf("%q %q: want yellow, got %s", c.tool, c.cmd, lvl)
		}
	}
}

func TestClassifyRed(t *testing.T) {
	e := New(nil, nil, nil)
	cases := []struct{ tool, cmd string }{
		{"Bash", "rm -rf build/"}, {"Bash", "rm -f file"}, {"Bash", "rm -r dir"},
		{"Bash", "del /s /q *.tmp"}, {"Bash", "Remove-Item -Recurse folder"},
		{"Bash", "format D:"}, {"Bash", "dd if=x of=/dev/sdb"},
		{"Bash", "git push origin main"}, {"Bash", "git fetch"}, {"Bash", "scp f h:/"},
		{"Bash", "sudo apt install"}, {"Bash", "runas /user:admin cmd"},
		{"Bash", "reg add HKLM\\Software\\X"}, {"Bash", "setx PATH x"},
		{"Bash", "npm install -g ts"}, {"Bash", "pip install -g x"},
		{"Bash", "shutdown /s"}, {"Bash", "systemctl stop nginx"},
		{"Bash", "echo x > file.txt"}, {"Bash", "curl -X POST url -d data"},
		{"Bash", "crontab -e"},
	}
	// fork bomb 单独测(语法)
	for _, c := range cases {
		lvl, _ := e.Classify("", c.tool, c.cmd)
		if lvl != Red {
			t.Errorf("%q %q: want red, got %s", c.tool, c.cmd, lvl)
		}
	}
}

func TestClassifyForkBomb(t *testing.T) {
	e := New(nil, nil, nil)
	lvl, _ := e.Classify("", "Bash", ":(){ :|:& };:")
	if lvl != Red {
		t.Errorf("fork bomb: want red, got %s", lvl)
	}
}

func TestClassifyBlacklist(t *testing.T) {
	e := New(nil, nil, nil)
	cases := []string{"rm -rf /", "rm -rf ~", "rm -rf /*", "rm -rf *", "mkfs.ext4 /dev/sda1"}
	for _, cmd := range cases {
		lvl, reason := e.Classify("", "Bash", cmd)
		if lvl != Red {
			t.Errorf("%q: want red, got %s", cmd, lvl)
		}
		if !strings.Contains(reason, "blacklisted") {
			t.Errorf("%q: want blacklisted reason, got %s", cmd, reason)
		}
	}
}

func TestClassifyDefault(t *testing.T) {
	e := New(nil, nil, nil)
	lvl, reason := e.Classify("", "Bash", "some-weird-cmd --flag")
	if lvl != Yellow {
		t.Errorf("want yellow, got %s", lvl)
	}
	if !strings.Contains(reason, "default yellow") {
		t.Errorf("want default yellow reason, got %s", reason)
	}
}

func TestClassifyEmpty(t *testing.T) {
	e := New(nil, nil, nil)
	lvl, _ := e.Classify("", "Bash", "")
	if lvl != Yellow {
		t.Errorf("empty cmd: want yellow, got %s", lvl)
	}
}

func TestRmRfTmpNotBlacklisted(t *testing.T) {
	e := New(nil, nil, nil)
	lvl, reason := e.Classify("", "Bash", "rm -rf /tmp")
	if lvl != Red {
		t.Errorf("want red, got %s", lvl)
	}
	if strings.Contains(reason, "blacklisted") {
		t.Errorf("/tmp should not be blacklisted, got %s", reason)
	}
}

// ── RulesManager 测试 ──

func TestRulesManagerDefaults(t *testing.T) {
	rm := NewRulesManager()
	rules := rm.Export()

	if len(rules.Green) == 0 {
		t.Error("default green rules should not be empty")
	}
	if len(rules.Red) == 0 {
		t.Error("default red rules should not be empty")
	}
	if len(rules.Blacklist) == 0 {
		t.Error("default blacklist should not be empty")
	}
}

func TestRulesManagerReload(t *testing.T) {
	rm := NewRulesManager()

	jsonRules := `{
		"red": [
			{"pattern": "^custom-danger\\b", "description": "my custom danger"}
		],
		"green": [
			{"pattern": "^custom-safe\\b", "description": "my safe cmd"}
		]
	}`

	if err := rm.Reload([]byte(jsonRules)); err != nil {
		t.Fatalf("reload failed: %v", err)
	}

	rules := rm.Export()

	// 自定义 red 应替换默认
	if len(rules.Red) != 1 || rules.Red[0].Pattern != "^custom-danger\\b" {
		t.Errorf("want 1 custom red rule, got %d", len(rules.Red))
	}

	// 自定义 green 应替换默认
	if len(rules.Green) != 1 || rules.Green[0].Pattern != "^custom-safe\\b" {
		t.Errorf("want 1 custom green rule, got %d", len(rules.Green))
	}

	// 未指定的 yellow/blacklist 应保持默认
	if len(rules.Yellow) == 0 {
		t.Error("yellow should keep defaults when not specified in reload")
	}
	if len(rules.Blacklist) == 0 {
		t.Error("blacklist should keep defaults when not specified in reload")
	}
}

func TestRulesManagerReloadBadJSON(t *testing.T) {
	rm := NewRulesManager()
	if err := rm.Reload([]byte(`not json`)); err == nil {
		t.Error("should fail on bad JSON")
	}
}

func TestRulesManagerSnapshotAfterReload(t *testing.T) {
	rm := NewRulesManager()

	jsonRules := `{"red": [{"pattern": "^danger$", "description": "danger"}]}`
	rm.Reload([]byte(jsonRules))

	// 应包含自定义 red 规则
	e := New(nil, nil, nil)
	e.rules = rm

	level, _ := e.Classify("", "Bash", "danger")
	if level != Red {
		t.Errorf("custom-danger should be Red, got %s", level)
	}

	// 重载后未指定的规则保持默认(green/yellow/blacklist 未变)
	level, _ = e.Classify("", "Bash", "echo hello")
	if level != Green {
		t.Errorf("echo should still be Green via defaults, got %s", level)
	}
}

func TestRulesExportRoundTrip(t *testing.T) {
	rm := NewRulesManager()
	initial := rm.Export()

	// 重新加载导出结果应不变
	data, _ := json.Marshal(initial)
	rm.Reload(data)
	after := rm.Export()

	if len(after.Red) != len(initial.Red) {
		t.Errorf("red count changed after round-trip: %d vs %d", len(after.Red), len(initial.Red))
	}
}
