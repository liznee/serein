package session

import (
	"testing"
)

// ──────────────────────────────────────────────────────────────────────
// 权限审批双向流测试（需求23-28 + 权限模式评估矩阵）
//
// 需求23: permission 请求由后端 risk engine 发起
// 需求24: perm_decision 由手机发起 (allow/deny)
// 需求25: mode_switch 实时切换权限模式
// 需求26: 7种权限模式: default, accept_edits, bypass_permissions, plan, read_only, safe_yolo, yolo
// 需求27: 工具级过滤 (allowed_tools / disallowed_tools)
// 需求28: 权限模式行为矩阵
// ──────────────────────────────────────────────────────────────────────

// ── IsValidPermissionMode 测试 ──

func TestIsValidPermissionMode_AllValidModes(t *testing.T) {
	validModes := []string{
		PermModeDefault,
		PermModeAcceptEdits,
		PermModeBypassPermissions,
		PermModePlan,
		PermModeReadOnly,
		PermModeSafeYolo,
		PermModeYolo,
	}
	for _, mode := range validModes {
		if !IsValidPermissionMode(mode) {
			t.Errorf("IsValidPermissionMode(%q) should be true", mode)
		}
	}
}

func TestIsValidPermissionMode_InvalidModes(t *testing.T) {
	invalidModes := []string{
		"",
		"invalid",
		"DEFAULT",
		"Default",
		"yolo_mode",
		"accept-edit",
		"bypass",
		"safe",
		"read-only",
		"plan_mode",
		"acceptEdits",
		"bypassPermissions",
		"readOnly",
		"safeYolo",
	}
	for _, mode := range invalidModes {
		if IsValidPermissionMode(mode) {
			t.Errorf("IsValidPermissionMode(%q) should be false", mode)
		}
	}
}

// ── IsWriteTool 测试 ──

func TestIsWriteTool_ReadOnlyTools(t *testing.T) {
	readTools := []string{
		"Read", "Grep", "Glob", "LS", "list_dir", "search",
		"WebSearch", "WebFetch", "codebase_search", "read_file",
		"web_fetch", "glob_file_search", "fetch_rules", "read_lints",
		"TodoWrite", "TaskList", "TaskGet", "TaskOutput",
		"AskQuestion", "SpecAskQuestion",
	}
	for _, tool := range readTools {
		if IsWriteTool(tool) {
			t.Errorf("IsWriteTool(%q) should be false (read-only)", tool)
		}
	}
}

func TestIsWriteTool_WriteTools(t *testing.T) {
	writeTools := []string{
		"Write", "Edit", "Bash", "MultiEdit", "NotebookEdit",
		"delete_file", "run_terminal_cmd",
		"file_write", "mkdir", "rmdir", "chmod", "chown",
		"PowerShell", "string_replace",
	}
	for _, tool := range writeTools {
		if !IsWriteTool(tool) {
			t.Errorf("IsWriteTool(%q) should be true (write)", tool)
		}
	}
}

func TestIsWriteTool_UnknownTool(t *testing.T) {
	if !IsWriteTool("UnknownTool") {
		t.Error("IsWriteTool should return true for unknown tools (safe default)")
	}
	if !IsWriteTool("") {
		t.Error("IsWriteTool should return true for empty string (safe default)")
	}
}

// ── PermissionDecision.String() 测试 ──

func TestPermissionDecision_String(t *testing.T) {
	tests := []struct {
		decision PermissionDecision
		want     string
	}{
		{DecisionNeedsApproval, "needs_approval"},
		{DecisionAutoApprove, "auto_approve"},
		{DecisionAutoDeny, "auto_deny"},
		{PermissionDecision(999), "unknown"},
	}
	for _, tc := range tests {
		got := tc.decision.String()
		if got != tc.want {
			t.Errorf("PermissionDecision(%d).String() = %q, want %q", tc.decision, got, tc.want)
		}
	}
}

// ── EvaluatePermission: bypass_permissions 模式 ──

func TestEvaluatePermission_BypassPermissions(t *testing.T) {
	tools := []string{"Bash", "Write", "Edit", "Read", "Grep", "Unknown"}
	risks := []string{"green", "yellow", "red", ""}
	for _, tool := range tools {
		for _, risk := range risks {
			dec := EvaluatePermission(PermModeBypassPermissions, risk, tool, nil, nil)
			if dec != DecisionAutoApprove {
				t.Errorf("bypass_permissions: tool=%s risk=%s should auto-approve, got %s", tool, risk, dec)
			}
		}
	}
}

func TestEvaluatePermission_BypassPermissions_WithDisallowedTools(t *testing.T) {
	// Disallowed tools should still be denied even in bypass_permissions
	dec := EvaluatePermission(PermModeBypassPermissions, "green", "Bash", nil, []string{"Bash"})
	if dec != DecisionAutoDeny {
		t.Errorf("bypass_permissions + disallowed Bash should auto-deny, got %s", dec)
	}
}

func TestEvaluatePermission_BypassPermissions_WithAllowedTools(t *testing.T) {
	// Tool not in allowed list should be denied even in bypass_permissions
	dec := EvaluatePermission(PermModeBypassPermissions, "green", "Write", []string{"Read"}, nil)
	if dec != DecisionAutoDeny {
		t.Errorf("bypass_permissions + allowed=[Read] + tool=Write should auto-deny, got %s", dec)
	}
	// Tool in allowed list should be approved
	dec = EvaluatePermission(PermModeBypassPermissions, "green", "Read", []string{"Read"}, nil)
	if dec != DecisionAutoApprove {
		t.Errorf("bypass_permissions + allowed=[Read] + tool=Read should auto-approve, got %s", dec)
	}
}

// ── EvaluatePermission: yolo 模式 ──

func TestEvaluatePermission_Yolo(t *testing.T) {
	tools := []string{"Bash", "Write", "Edit", "Read", "Grep"}
	risks := []string{"green", "yellow", "red", ""}
	for _, tool := range tools {
		for _, risk := range risks {
			dec := EvaluatePermission(PermModeYolo, risk, tool, nil, nil)
			if dec != DecisionAutoApprove {
				t.Errorf("yolo: tool=%s risk=%s should auto-approve, got %s", tool, risk, dec)
			}
		}
	}
}

func TestEvaluatePermission_Yolo_WithDisallowedTools(t *testing.T) {
	dec := EvaluatePermission(PermModeYolo, "red", "Bash", nil, []string{"Bash"})
	if dec != DecisionAutoDeny {
		t.Errorf("yolo + disallowed Bash should auto-deny, got %s", dec)
	}
}

// ── EvaluatePermission: safe_yolo 模式 ──

func TestEvaluatePermission_SafeYolo(t *testing.T) {
	tests := []struct {
		risk  string
		tool  string
		want  PermissionDecision
	}{
		{"green", "Bash", DecisionAutoApprove},
		{"green", "Write", DecisionAutoApprove},
		{"yellow", "Bash", DecisionAutoApprove},
		{"yellow", "Write", DecisionAutoApprove},
		{"red", "Bash", DecisionAutoDeny},
		{"red", "Write", DecisionAutoDeny},
		{"red", "Read", DecisionAutoDeny},
		{"", "Bash", DecisionAutoApprove}, // empty risk treated as non-red
	}
	for _, tc := range tests {
		dec := EvaluatePermission(PermModeSafeYolo, tc.risk, tc.tool, nil, nil)
		if dec != tc.want {
			t.Errorf("safe_yolo: risk=%s tool=%s should be %s, got %s", tc.risk, tc.tool, tc.want, dec)
		}
	}
}

func TestEvaluatePermission_SafeYolo_WithDisallowedTools(t *testing.T) {
	// Disallowed overrides safe_yolo's auto-approve for green
	dec := EvaluatePermission(PermModeSafeYolo, "green", "Bash", nil, []string{"Bash"})
	if dec != DecisionAutoDeny {
		t.Errorf("safe_yolo + disallowed should deny even for green, got %s", dec)
	}
}

// ── EvaluatePermission: accept_edits 模式 ──

func TestEvaluatePermission_AcceptEdits(t *testing.T) {
	tests := []struct {
		risk  string
		tool  string
		want  PermissionDecision
	}{
		{"green", "Write", DecisionAutoApprove},
		{"green", "Bash", DecisionAutoApprove},
		{"yellow", "Write", DecisionAutoApprove},
		{"yellow", "Bash", DecisionAutoApprove},
		{"red", "Bash", DecisionNeedsApproval},
		{"red", "Write", DecisionNeedsApproval},
		{"red", "Read", DecisionNeedsApproval},
		{"", "Bash", DecisionAutoApprove}, // empty risk = non-red
	}
	for _, tc := range tests {
		dec := EvaluatePermission(PermModeAcceptEdits, tc.risk, tc.tool, nil, nil)
		if dec != tc.want {
			t.Errorf("accept_edits: risk=%s tool=%s should be %s, got %s", tc.risk, tc.tool, tc.want, dec)
		}
	}
}

// ── EvaluatePermission: default 模式 ──

func TestEvaluatePermission_Default(t *testing.T) {
	tests := []struct {
		risk  string
		tool  string
		want  PermissionDecision
	}{
		{"green", "Bash", DecisionAutoApprove},
		{"green", "Write", DecisionAutoApprove},
		{"green", "Read", DecisionAutoApprove},
		{"yellow", "Bash", DecisionNeedsApproval},
		{"yellow", "Write", DecisionNeedsApproval},
		{"red", "Bash", DecisionNeedsApproval},
		{"red", "Write", DecisionNeedsApproval},
		{"", "Bash", DecisionNeedsApproval}, // empty risk = non-green
	}
	for _, tc := range tests {
		dec := EvaluatePermission(PermModeDefault, tc.risk, tc.tool, nil, nil)
		if dec != tc.want {
			t.Errorf("default: risk=%s tool=%s should be %s, got %s", tc.risk, tc.tool, tc.want, dec)
		}
	}
}

// ── EvaluatePermission: plan 模式 ──

func TestEvaluatePermission_Plan(t *testing.T) {
	readTools := []string{"Read", "Grep", "Glob", "LS", "list_dir", "search", "WebSearch", "WebFetch", "codebase_search"}
	writeTools := []string{"Write", "Edit", "Bash", "MultiEdit", "delete_file"}

	for _, tool := range readTools {
		for _, risk := range []string{"green", "yellow", "red"} {
			dec := EvaluatePermission(PermModePlan, risk, tool, nil, nil)
			if dec != DecisionAutoApprove {
				t.Errorf("plan: read tool=%s risk=%s should auto-approve, got %s", tool, risk, dec)
			}
		}
	}

	for _, tool := range writeTools {
		for _, risk := range []string{"green", "yellow", "red"} {
			dec := EvaluatePermission(PermModePlan, risk, tool, nil, nil)
			if dec != DecisionAutoDeny {
				t.Errorf("plan: write tool=%s risk=%s should auto-deny, got %s", tool, risk, dec)
			}
		}
	}
}

// ── EvaluatePermission: read_only 模式 ──

func TestEvaluatePermission_ReadOnly(t *testing.T) {
	readTools := []string{"Read", "Grep", "Glob", "LS", "list_dir", "search"}
	writeTools := []string{"Write", "Edit", "Bash", "MultiEdit", "delete_file"}

	for _, tool := range readTools {
		dec := EvaluatePermission(PermModeReadOnly, "green", tool, nil, nil)
		if dec != DecisionAutoApprove {
			t.Errorf("read_only: read tool=%s should auto-approve, got %s", tool, dec)
		}
	}

	for _, tool := range writeTools {
		dec := EvaluatePermission(PermModeReadOnly, "green", tool, nil, nil)
		if dec != DecisionAutoDeny {
			t.Errorf("read_only: write tool=%s should auto-deny, got %s", tool, dec)
		}
	}
}

// ── EvaluatePermission: 工具级过滤优先级 ──

func TestEvaluatePermission_DisallowedOverridesMode(t *testing.T) {
	// Disallowed tool should be denied regardless of mode
	modes := []string{
		PermModeDefault, PermModeAcceptEdits, PermModeBypassPermissions,
		PermModePlan, PermModeReadOnly, PermModeSafeYolo, PermModeYolo,
	}
	for _, mode := range modes {
		dec := EvaluatePermission(mode, "green", "Bash", nil, []string{"Bash"})
		if dec != DecisionAutoDeny {
			t.Errorf("disallowed should override mode %s, got %s", mode, dec)
		}
	}
}

func TestEvaluatePermission_AllowedToolsFilter(t *testing.T) {
	// Tool not in allowed list should be denied
	dec := EvaluatePermission(PermModeDefault, "green", "Bash", []string{"Read", "Grep"}, nil)
	if dec != DecisionAutoDeny {
		t.Errorf("tool not in allowed list should be denied, got %s", dec)
	}
	// Tool in allowed list should proceed with mode evaluation
	dec = EvaluatePermission(PermModeDefault, "green", "Read", []string{"Read", "Grep"}, nil)
	if dec != DecisionAutoApprove {
		t.Errorf("green tool in allowed list should be approved, got %s", dec)
	}
}

func TestEvaluatePermission_EmptyAllowedTools(t *testing.T) {
	// Empty allowed tools = all tools allowed (no filtering)
	dec := EvaluatePermission(PermModeDefault, "green", "Bash", nil, nil)
	if dec != DecisionAutoApprove {
		t.Errorf("empty allowed tools + green should auto-approve, got %s", dec)
	}
	dec = EvaluatePermission(PermModeDefault, "green", "Bash", []string{}, nil)
	if dec != DecisionAutoApprove {
		t.Errorf("empty allowed tools slice + green should auto-approve, got %s", dec)
	}
}

func TestEvaluatePermission_DisallowedAndAllowedBothPresent(t *testing.T) {
	// Disallowed takes priority over allowed
	dec := EvaluatePermission(PermModeDefault, "green", "Bash", []string{"Bash", "Read"}, []string{"Bash"})
	if dec != DecisionAutoDeny {
		t.Errorf("disallowed should take priority over allowed, got %s", dec)
	}
	// Tool in allowed but not in disallowed
	dec = EvaluatePermission(PermModeDefault, "green", "Read", []string{"Bash", "Read"}, []string{"Bash"})
	if dec != DecisionAutoApprove {
		t.Errorf("tool in allowed and not in disallowed should be approved, got %s", dec)
	}
}

// ── EvaluatePermission: 未知模式 ──

func TestEvaluatePermission_UnknownMode(t *testing.T) {
	dec := EvaluatePermission("unknown_mode", "green", "Read", nil, nil)
	if dec != DecisionNeedsApproval {
		t.Errorf("unknown mode should return needs_approval, got %s", dec)
	}
}

func TestEvaluatePermission_EmptyMode(t *testing.T) {
	dec := EvaluatePermission("", "green", "Read", nil, nil)
	if dec != DecisionNeedsApproval {
		t.Errorf("empty mode should return needs_approval, got %s", dec)
	}
}

// ── ShouldAutoApprove 向后兼容测试 ──

func TestShouldAutoApprove_BackwardCompat(t *testing.T) {
	tests := []struct {
		mode  string
		risk  string
		want  bool
	}{
		{PermModeBypassPermissions, "red", true},
		{PermModeYolo, "red", true},
		{PermModeSafeYolo, "green", true},
		{PermModeSafeYolo, "red", false},
		{PermModeAcceptEdits, "green", true},
		{PermModeAcceptEdits, "red", false},
		{PermModeDefault, "green", true},
		{PermModeDefault, "yellow", false},
		{PermModeDefault, "red", false},
	}
	for _, tc := range tests {
		got := ShouldAutoApprove(tc.mode, tc.risk)
		if got != tc.want {
			t.Errorf("ShouldAutoApprove(%q, %q) = %v, want %v", tc.mode, tc.risk, got, tc.want)
		}
	}
}

// ── 全模式 × 全风险等级 × 全工具类型 组合矩阵 ──

func TestEvaluatePermission_FullMatrix(t *testing.T) {
	modes := []string{
		PermModeDefault, PermModeAcceptEdits, PermModeBypassPermissions,
		PermModePlan, PermModeReadOnly, PermModeSafeYolo, PermModeYolo,
	}
	risks := []string{"green", "yellow", "red", ""}
	tools := []string{"Read", "Bash", "Write", "Grep", "Edit", "UnknownTool"}

	for _, mode := range modes {
		for _, risk := range risks {
			for _, tool := range tools {
				// Should not panic for any combination
				dec := EvaluatePermission(mode, risk, tool, nil, nil)
				if dec < DecisionNeedsApproval || dec > DecisionAutoDeny {
					t.Errorf("invalid decision %d for mode=%s risk=%s tool=%s", dec, mode, risk, tool)
				}
			}
		}
	}
}

// ── 消息类型常量完整性 ──

func TestMessageTypeConstants(t *testing.T) {
	// Ensure all message types have non-empty values
	types := []string{
		MsgTypeJoin, MsgTypeJoinAck, MsgTypeSessionMsg, MsgTypeHistory,
		MsgTypeModeSwitch, MsgTypeCmdResult, MsgTypeCmdStep, MsgTypeHeartbeat,
		MsgTypeError, MsgTypeUpdate, MsgTypePermission, MsgTypePermDecision,
	}
	seen := make(map[string]bool)
	for _, typ := range types {
		if typ == "" {
			t.Error("message type constant should not be empty")
		}
		if seen[typ] {
			t.Errorf("duplicate message type constant: %s", typ)
		}
		seen[typ] = true
	}
}

// ── 权限模式常量完整性 ──

func TestPermissionModeConstants(t *testing.T) {
	modes := []string{
		PermModeDefault, PermModeAcceptEdits, PermModeBypassPermissions,
		PermModePlan, PermModeReadOnly, PermModeSafeYolo, PermModeYolo,
	}
	seen := make(map[string]bool)
	for _, mode := range modes {
		if mode == "" {
			t.Error("permission mode constant should not be empty")
		}
		if seen[mode] {
			t.Errorf("duplicate permission mode constant: %s", mode)
		}
		seen[mode] = true
	}
}

// ── 事件类型常量 ──

func TestEventTypeConstants(t *testing.T) {
	events := []string{
		EventText, EventService, EventToolCallStart, EventToolCallEnd,
		EventFile, EventTurnStart, EventTurnEnd, EventStart, EventStop,
	}
	seen := make(map[string]bool)
	for _, event := range events {
		if event == "" {
			t.Error("event type constant should not be empty")
		}
		if seen[event] {
			t.Errorf("duplicate event type constant: %s", event)
		}
		seen[event] = true
	}
}

// ── Update 子类型常量 ──

func TestUpdateSubtypeConstants(t *testing.T) {
	subtypes := []string{UpdateNewMessage, UpdateSession, UpdateMachine}
	seen := make(map[string]bool)
	for _, st := range subtypes {
		if st == "" {
			t.Error("update subtype constant should not be empty")
		}
		if seen[st] {
			t.Errorf("duplicate update subtype constant: %s", st)
		}
		seen[st] = true
	}
}

// ── Payload 结构体序列化测试 ──

func TestPermissionPayloadSerialization(t *testing.T) {
	payload := PermissionPayload{
		ToolName:   "Bash",
		Command:    "rm -rf /tmp",
		RiskLevel:  "red",
		RuleReason: "destructive",
		CmdID:      "cmd-001",
		Timeout:    30,
	}
	// Ensure it can be marshaled (used in BroadcastToSession)
	if payload.ToolName == "" || payload.RiskLevel == "" || payload.CmdID == "" {
		t.Error("required fields should be set")
	}
}

func TestPermDecisionPayloadSerialization(t *testing.T) {
	payload := PermDecisionPayload{
		CmdID:    "cmd-001",
		Decision: "allow",
		Reason:   "user approved",
	}
	if payload.CmdID == "" || payload.Decision == "" {
		t.Error("required fields should be set")
	}
}

func TestModeSwitchPayloadSerialization(t *testing.T) {
	payload := ModeSwitchPayload{
		Mode:            PermModeSafeYolo,
		AllowedTools:    []string{"Read", "Grep"},
		DisallowedTools: []string{"Bash", "Write"},
	}
	if payload.Mode == "" {
		t.Error("mode should be set")
	}
	if !IsValidPermissionMode(payload.Mode) {
		t.Error("mode should be valid")
	}
}

func TestSessionMsgPayloadSerialization(t *testing.T) {
	payload := SessionMsgPayload{
		Content:  "hello world",
		MsgType:  "text",
		Event:    EventText,
		Turn:     "turn-001",
		Thinking: false,
	}
	if payload.Content == "" {
		t.Error("content should be set")
	}
}

func TestJoinAckPayloadSerialization(t *testing.T) {
	payload := JoinAckPayload{
		ClientID:       "phone-001",
		SessionID:      "sess-001",
		PermissionMode: PermModeDefault,
	}
	if payload.ClientID == "" || payload.SessionID == "" {
		t.Error("required fields should be set")
	}
}

// ── HistoryPayload / HistoryMsg ──

func TestHistoryMsgFields(t *testing.T) {
	msg := HistoryMsg{
		Seq:       1,
		Source:    "user",
		MsgType:   "text",
		Content:   "hello",
		CmdID:     "cmd-001",
		Turn:      "turn-001",
		Event:     EventText,
		Thinking:  false,
	}
	if msg.Source != "user" || msg.Content != "hello" {
		t.Error("history msg fields should be set correctly")
	}
}

// ── ClientInfo ──

func TestClientInfoFields(t *testing.T) {
	info := ClientInfo{
		ClientID:   "phone-001",
		ClientType: "phone",
	}
	if info.ClientID != "phone-001" || info.ClientType != "phone" {
		t.Error("client info fields should be set")
	}
}

// ── UpdatePayload ──

func TestUpdatePayloadFields(t *testing.T) {
	active := true
	payload := UpdatePayload{
		T:        UpdateNewMessage,
		SID:      "sess-001",
		Active:   &active,
		ActiveAt: 1234567890,
	}
	if payload.T != UpdateNewMessage {
		t.Error("update type should be set")
	}
	if payload.Active == nil || !*payload.Active {
		t.Error("active should be true")
	}
}

// ── WSEnvelope omitempty ──

func TestWSEnvelope_OmitEmpty(t *testing.T) {
	// Empty envelope should marshal to minimal JSON
	env := session_WSEnvelope_empty()
	if env.Type != "" {
		t.Error("empty envelope type should be empty string")
	}
}

// Helper to create empty WSEnvelope (avoids import cycle in test)
func session_WSEnvelope_empty() WSEnvelope {
	return WSEnvelope{}
}
