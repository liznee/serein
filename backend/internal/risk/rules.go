package risk

import (
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"sync"
)

// RulesFile 可热更新的风险规则 JSON 文件格式。
// 与 backend/internal/risk/engine.go 的静态规则对应，
// LoadRulesFile 读入后会合并：文件中未指定的规则保持内置默认值。
type RulesFile struct {
	Green     []RuleEntry `json:"green"`
	Yellow    []RuleEntry `json:"yellow"`
	Red       []RuleEntry `json:"red"`
	Blacklist []RuleEntry `json:"blacklist"`
}

// RuleEntry 单条规则。
type RuleEntry struct {
	Pattern     string `json:"pattern"`
	Description string `json:"description"`
}

// RuleSet 已编译的规则集（内部用，线程安全由 Engine 的 mu 保护）。
type ruleSet struct {
	green     []rule
	yellow    []rule
	red       []rule
	blacklist []rule
}

// RulesManager 管理规则加载、热更新、序列化。
type RulesManager struct {
	mu      sync.RWMutex
	current ruleSet
}

// NewRulesManager 创建管理器，以内置默认规则初始化。
func NewRulesManager() *RulesManager {
	return &RulesManager{
		current: ruleSet{
			green:     defaultGreenRules,
			yellow:    defaultYellowRules,
			red:       defaultRedRules,
			blacklist: defaultStaticBlacklist,
		},
	}
}

// LoadFile 从 JSON 文件加载规则，合并内置默认值。
// 文件中未指定的规则列表保留内置默认；已指定的完全替换。
func (rm *RulesManager) LoadFile(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("read rules file: %w", err)
	}
	return rm.Reload(data)
}

// Reload 从 JSON 字节重载规则。
func (rm *RulesManager) Reload(data []byte) error {
	var f RulesFile
	if err := json.Unmarshal(data, &f); err != nil {
		return fmt.Errorf("parse rules json: %w", err)
	}

	rs := ruleSet{
		green:     mergeCompile(f.Green, defaultGreenRules),
		yellow:    mergeCompile(f.Yellow, defaultYellowRules),
		red:       mergeCompile(f.Red, defaultRedRules),
		blacklist: mergeCompile(f.Blacklist, defaultStaticBlacklist),
	}

	rm.mu.Lock()
	rm.current = rs
	rm.mu.Unlock()
	return nil
}

// Snapshot 返回当前规则集的快照（用于分级）。
func (rm *RulesManager) Snapshot() ruleSet {
	rm.mu.RLock()
	defer rm.mu.RUnlock()
	return rm.current
}

// Export 将当前规则导出为 RulesFile JSON。
func (rm *RulesManager) Export() RulesFile {
	rm.mu.RLock()
	defer rm.mu.RUnlock()
	return ruleSetToFile(rm.current)
}

// mergeCompile 将用户规则编译，若用户提供了则用用户的，否则回退到默认。
func mergeCompile(user []RuleEntry, defaults []rule) []rule {
	if len(user) > 0 {
		return compileRules(user)
	}
	return defaults
}

func compileRules(entries []RuleEntry) []rule {
	rs := make([]rule, 0, len(entries))
	for _, e := range entries {
		re, err := regexp.Compile(e.Pattern)
		if err != nil {
			continue // 跳过无效正则（日志级别警告，但调用方应捕获）
		}
		rs = append(rs, rule{pat: re, desc: e.Description})
	}
	return rs
}

func ruleSetToFile(rs ruleSet) RulesFile {
	return RulesFile{
		Green:     rulesToEntries(rs.green),
		Yellow:    rulesToEntries(rs.yellow),
		Red:       rulesToEntries(rs.red),
		Blacklist: rulesToEntries(rs.blacklist),
	}
}

func rulesToEntries(rs []rule) []RuleEntry {
	entries := make([]RuleEntry, len(rs))
	for i, r := range rs {
		entries[i] = RuleEntry{Pattern: r.pat.String(), Description: r.desc}
	}
	return entries
}
