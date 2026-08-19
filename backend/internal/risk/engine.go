package risk

import (
	"serein/internal/store"
	"regexp"
)

// Level 风险级别。
type Level string

const (
	Green  Level = "green"
	Yellow Level = "yellow"
	Red    Level = "red"
)

type rule struct {
	pat  *regexp.Regexp
	desc string
}

func match(rs []rule, cmd string) string {
	for _, r := range rs {
		if r.pat.MatchString(cmd) {
			return r.desc
		}
	}
	return ""
}

func mustCompile(ps [][2]string) []rule {
	rs := make([]rule, len(ps))
	for i, p := range ps {
		rs[i] = rule{regexp.MustCompile(p[0]), p[1]}
	}
	return rs
}

// ---- 工具级快速通道 ----
// 覆盖所有 Claude Code / CatPaw 工具，与 hooks/risk_classify.py 保持同步

var greenTools = map[string]bool{
	// Claude Code 标准只读工具
	"Read": true, "Glob": true, "Grep": true, "LS": true,
	"WebSearch": true, "WebFetch": true,
	"TodoWrite": true, "TaskList": true, "TaskGet": true, "TaskOutput": true,
	// CatPaw / 扩展只读工具
	"list_dir": true, "search": true, "codebase_search": true, "read_file": true,
	"web_fetch": true, "glob_file_search": true, "fetch_rules": true, "read_lints": true,
	"AskQuestion": true, "SpecAskQuestion": true,
}

var yellowTools = map[string]bool{
	"Edit": true, "Write": true, "NotebookEdit": true, "MultiEdit": true,
	"string_replace": true, // CatPaw 字符串替换
}

// ---- 内置默认规则（不可删除，规则文件覆盖时可替换） ----

var defaultStaticBlacklist = mustCompile([][2]string{
	{`\brm\s+-rf?\s+/\s*$`, "rm -rf 根目录(极危)"},
	{`\brm\s+-rf?\s+/\*`, "rm -rf /* (删根)"},
	{`\brm\s+-rf?\s+~\s*$`, "rm -rf 家目录(极危)"},
	{`\brm\s+-rf?\s+~/`, "rm -rf ~/ (删家目录)"},
	{`\brm\s+-rf?\s+\*\s*$`, "rm -rf * (全删)"},
	{`mkfs\.\w+\s+/dev/`, "格式化磁盘设备"},
	{`dd\s+.*of=/dev/[sh]d`, "dd 写裸磁盘"},
})

var defaultRedRules = mustCompile([][2]string{
	{`\brm\b.*\s-[^-]*[rf]`, "递归/强制删除"},
	{`^del\s+/[sSfFqQ]`, "Windows 递归删除"},
	{`Remove-Item.*-Recurse`, "PowerShell 递归删除"},
	{`^(format|dd|mkfs|diskpart|fdisk)\b`, "磁盘格式化/写"},
	{`^git (push|fetch|pull)\b`, "git 外发"},
	{`^(scp|rsync|sftp)\b`, "远程文件传输"},
	{`^(sudo|runas|doas)\b`, "提权执行"},
	{`\breg (add|delete|import|load|save)\b`, "注册表修改"},
	{`\bsetx\b`, "环境变量持久化"},
	{`^npm install\b.*(\s-g\b|--global\b)`, "系统级 npm 安装"},
	{`^(pip|pip3) install\b.*(\s-g\b|--global\b)`, "系统级 pip 安装"},
	{`^(shutdown|reboot|halt|poweroff)\b`, "关机/重启"},
	{`:\(\)\s*\{\s*:\|:&\s*\}\s*;`, "fork bomb"},
	{`(?:^|[^0-9])>(>?)\s*\S`, "文件重定向覆盖/追加"},
	{`^(curl|wget|Invoke-WebRequest)\b.*(-X\s*(POST|PUT|DELETE|PATCH)|--upload-file|--data|-d\b|-T\b|--post)`, "HTTP 写/上传"},
	{`chmod\s+0?777\b`, "过度开放权限"},
	{`^crontab\b`, "定时任务修改"},
	{`^(systemctl|service)\s+(start|stop|restart|reload|enable|disable)\b`, "系统服务控制"},
})

var defaultYellowRules = mustCompile([][2]string{
	{`^git (add|commit|stash|checkout|switch|merge|rebase|reset)\b`, "git 本地操作"},
	{`^npm install\b`, "npm 本地安装"},
	{`^(pip|pip3) install\b`, "pip 本地安装"},
	{`^(mkdir|touch|cp|mv|ln|sed|awk)\b`, "文件操作(可逆)"},
	{`^go (get|install|mod tidy|mod download)\b`, "go 依赖安装"},
	{`^(docker|kubectl) (run|exec|build|start|stop|restart|create)\b`, "容器本地操作"},
	{`^(make|cmake|cargo build)\b`, "本地构建"},
})

var defaultGreenRules = mustCompile([][2]string{
	{`^(ls|ll|la|cat|pwd|echo|whoami|date|dir|cd|cls|clear|true)\b`, "只读命令"},
	{`^git (status|log|diff|show|branch|stash list|remote -v|config --get)\b`, "git 只读"},
	{`^(go test|go build|go vet|go fmt|go list|go mod|go env|go version|go doc)\b`, "go 构建/测试"},
	{`^(npm run|npx|yarn|pnpm) (build|test|lint|dev|start|run|ci)\b`, "npm 构建/测试"},
	{`^(grep|rg|find|fd|where|which|tree|head|tail|less|more|wc|sort|uniq)\b`, "搜索/查看命令"},
	{`^(python|python3|py|node|go|java|rustc|gcc|flutter|dart) --version\b`, "版本查询"},
	{`^(docker|kubectl) (ps|logs|get|describe|top|version|info)\b`, "容器只读"},
	{`^(pytest|jest|vitest|cargo test)\b`, "运行测试"},
})

// Engine 风险分级引擎。
// 优先级: DB黑名单(最高) > 会话记忆 > DB白名单 > 静态黑名单 > 静态红 > 静态黄 > 静态绿 > 默认黄。
// RulesManager 提供可热更新的规则集，线程安全。
type Engine struct {
	blacklist *store.BlacklistRepo
	whitelist *store.WhitelistRepo
	session   *store.SessionRepo
	rules     *RulesManager
}

func New(bl *store.BlacklistRepo, wl *store.WhitelistRepo, sm *store.SessionRepo) *Engine {
	return &Engine{
		blacklist: bl,
		whitelist: wl,
		session:   sm,
		rules:     NewRulesManager(),
	}
}

// Rules 返回 RulesManager（供 API 导出和热重载）。
func (e *Engine) Rules() *RulesManager { return e.rules }

// Classify 完整风险分级（含 DB 查找和规则快照）。
func (e *Engine) Classify(sessionID, toolName, command string) (Level, string) {
	// 工具级别快速通道
	if greenTools[toolName] {
		return Green, "read-only tool: " + toolName
	}
	if yellowTools[toolName] {
		return Yellow, "file edit tool: " + toolName
	}

	cmd := command
	if cmd == "" {
		return Yellow, "empty command"
	}

	// 1. DB 黑名单（最高优先）— 不可豁免
	if e.blacklist != nil {
		if desc, ok := e.blacklist.Match(cmd); ok {
			return Red, "db blacklisted: " + desc
		}
	}

	// 2. 当前静态黑名单快照
	rs := e.rules.Snapshot()

	if desc := match(rs.blacklist, cmd); desc != "" {
		return Red, "blacklisted: " + desc
	}

	// 3. 会话记忆
	if sessionID != "" && e.session != nil {
		if known, err := e.session.IsKnown(sessionID, cmd); err == nil && known {
			return Green, "session memo: command already approved this session"
		}
	}

	// 4. DB 白名单
	if e.whitelist != nil {
		if desc, ok := e.whitelist.Match(cmd); ok {
			return Green, "whitelisted: " + desc
		}
	}

	// 5. 当前规则链
	if desc := match(rs.red, cmd); desc != "" {
		return Red, "red rule: " + desc
	}
	if desc := match(rs.yellow, cmd); desc != "" {
		return Yellow, "yellow rule: " + desc
	}
	if desc := match(rs.green, cmd); desc != "" {
		return Green, "green rule: " + desc
	}
	return Yellow, "unknown command, default yellow"
}

// StaticClassify 纯静态分级（不含 DB 查找）。
func (e *Engine) StaticClassify(toolName, command string) (Level, string) {
	return e.Classify("", toolName, command)
}
