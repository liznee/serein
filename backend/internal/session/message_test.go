package session

import (
	"encoding/json"
	"testing"
)

func TestIsValidPermissionMode(t *testing.T) {
	tests := []struct {
		mode string
		want bool
	}{
		{PermModeDefault, true},
		{PermModeAcceptEdits, true},
		{PermModeBypassPermissions, true},
		{PermModePlan, true},
		{PermModeReadOnly, true},
		{PermModeSafeYolo, true},
		{PermModeYolo, true},
		{"", false},
		{"invalid", false},
		{"DEFAULT", false}, // case-sensitive
		{"yolo ", false},   // trailing space
	}
	for _, tc := range tests {
		t.Run(tc.mode, func(t *testing.T) {
			if got := IsValidPermissionMode(tc.mode); got != tc.want {
				t.Errorf("IsValidPermissionMode(%q) = %v, want %v", tc.mode, got, tc.want)
			}
		})
	}
}

func TestShouldAutoApprove(t *testing.T) {
	tests := []struct {
		name       string
		mode       string
		riskLevel  string
		want       bool
	}{
		// default: green auto-approve, yellow/red need approval
		{"default+green", PermModeDefault, "green", true},
		{"default+yellow", PermModeDefault, "yellow", false},
		{"default+red", PermModeDefault, "red", false},

		// accept_edits: green+yellow auto-approve, red needs approval
		{"accept_edits+green", PermModeAcceptEdits, "green", true},
		{"accept_edits+yellow", PermModeAcceptEdits, "yellow", true},
		{"accept_edits+red", PermModeAcceptEdits, "red", false},

		// bypass_permissions: always auto-approve
		{"bypass+green", PermModeBypassPermissions, "green", true},
		{"bypass+yellow", PermModeBypassPermissions, "yellow", true},
		{"bypass+red", PermModeBypassPermissions, "red", true},

		// plan: always need approval (via ShouldAutoApprove without toolName)
		{"plan+green", PermModePlan, "green", false},
		{"plan+yellow", PermModePlan, "yellow", false},

		// read_only: always need approval (via ShouldAutoApprove without toolName)
		{"read_only+green", PermModeReadOnly, "green", false},

		// safe_yolo: green+yellow auto-approve, red denied
		{"safe_yolo+green", PermModeSafeYolo, "green", true},
		{"safe_yolo+yellow", PermModeSafeYolo, "yellow", true},
		{"safe_yolo+red", PermModeSafeYolo, "red", false},

		// yolo: always auto-approve
		{"yolo+green", PermModeYolo, "green", true},
		{"yolo+yellow", PermModeYolo, "yellow", true},
		{"yolo+red", PermModeYolo, "red", true},

		// unknown mode: default to false
		{"unknown+green", "unknown", "green", false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := ShouldAutoApprove(tc.mode, tc.riskLevel); got != tc.want {
				t.Errorf("ShouldAutoApprove(%q, %q) = %v, want %v", tc.mode, tc.riskLevel, got, tc.want)
			}
		})
	}
}

func TestEvaluatePermission(t *testing.T) {
	tests := []struct {
		name             string
		mode             string
		riskLevel        string
		toolName         string
		allowedTools     []string
		disallowedTools  []string
		want             PermissionDecision
	}{
		// ── bypass_permissions / yolo: always auto-approve ──
		{"bypass+green", PermModeBypassPermissions, "green", "Bash", nil, nil, DecisionAutoApprove},
		{"bypass+red", PermModeBypassPermissions, "red", "Bash", nil, nil, DecisionAutoApprove},
		{"yolo+red", PermModeYolo, "red", "Bash", nil, nil, DecisionAutoApprove},

		// ── safe_yolo: green+yellow auto-approve, red auto-deny ──
		{"safe_yolo+green", PermModeSafeYolo, "green", "Bash", nil, nil, DecisionAutoApprove},
		{"safe_yolo+yellow", PermModeSafeYolo, "yellow", "Bash", nil, nil, DecisionAutoApprove},
		{"safe_yolo+red", PermModeSafeYolo, "red", "Bash", nil, nil, DecisionAutoDeny},

		// ── accept_edits: green+yellow auto-approve, red needs approval ──
		{"accept_edits+green", PermModeAcceptEdits, "green", "Write", nil, nil, DecisionAutoApprove},
		{"accept_edits+yellow", PermModeAcceptEdits, "yellow", "Write", nil, nil, DecisionAutoApprove},
		{"accept_edits+red", PermModeAcceptEdits, "red", "Bash", nil, nil, DecisionNeedsApproval},

		// ── default: green auto-approve, yellow+red needs approval ──
		{"default+green", PermModeDefault, "green", "Bash", nil, nil, DecisionAutoApprove},
		{"default+yellow", PermModeDefault, "yellow", "Bash", nil, nil, DecisionNeedsApproval},
		{"default+red", PermModeDefault, "red", "Bash", nil, nil, DecisionNeedsApproval},

		// ── plan: read tools auto-approve, write tools auto-deny ──
		{"plan+read", PermModePlan, "green", "Read", nil, nil, DecisionAutoApprove},
		{"plan+grep", PermModePlan, "green", "Grep", nil, nil, DecisionAutoApprove},
		{"plan+write", PermModePlan, "green", "Write", nil, nil, DecisionAutoDeny},
		{"plan+bash", PermModePlan, "green", "Bash", nil, nil, DecisionAutoDeny},

		// ── read_only: read tools auto-approve, write tools auto-deny ──
		{"read_only+read", PermModeReadOnly, "green", "Read", nil, nil, DecisionAutoApprove},
		{"read_only+glob", PermModeReadOnly, "green", "Glob", nil, nil, DecisionAutoApprove},
		{"read_only+write", PermModeReadOnly, "green", "Write", nil, nil, DecisionAutoDeny},
		{"read_only+bash", PermModeReadOnly, "red", "Bash", nil, nil, DecisionAutoDeny},

		// ── unknown mode: needs approval ──
		{"unknown", "unknown", "green", "Bash", nil, nil, DecisionNeedsApproval},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := EvaluatePermission(tc.mode, tc.riskLevel, tc.toolName, tc.allowedTools, tc.disallowedTools)
			if got != tc.want {
				t.Errorf("EvaluatePermission(%q, %q, %q) = %v, want %v",
					tc.mode, tc.riskLevel, tc.toolName, got.String(), tc.want.String())
			}
		})
	}
}

func TestEvaluatePermission_ToolFiltering(t *testing.T) {
	// DisallowedTools overrides everything → auto-deny
	t.Run("disallowed overrides yolo", func(t *testing.T) {
		got := EvaluatePermission(PermModeYolo, "green", "Bash", nil, []string{"Bash"})
		if got != DecisionAutoDeny {
			t.Errorf("disallowed+Bash in yolo = %v, want auto_deny", got.String())
		}
	})

	// AllowedTools: tool not in list → auto-deny
	t.Run("not in allowed list → deny", func(t *testing.T) {
		got := EvaluatePermission(PermModeDefault, "green", "Bash", []string{"Read", "Grep"}, nil)
		if got != DecisionAutoDeny {
			t.Errorf("Bash not in allowed list = %v, want auto_deny", got.String())
		}
	})

	// AllowedTools: tool in list → continue mode evaluation
	t.Run("in allowed list, green → approve", func(t *testing.T) {
		got := EvaluatePermission(PermModeDefault, "green", "Read", []string{"Read", "Grep"}, nil)
		if got != DecisionAutoApprove {
			t.Errorf("Read in allowed list, green = %v, want auto_approve", got.String())
		}
	})

	// AllowedTools: tool in list but red → needs approval (default mode)
	t.Run("in allowed list, red, default → needs_approval", func(t *testing.T) {
		got := EvaluatePermission(PermModeDefault, "red", "Bash", []string{"Bash", "Read"}, nil)
		if got != DecisionNeedsApproval {
			t.Errorf("Bash in allowed list, red, default = %v, want needs_approval", got.String())
		}
	})

	// DisallowedTools takes priority over AllowedTools
	t.Run("disallowed overrides allowed", func(t *testing.T) {
		got := EvaluatePermission(PermModeYolo, "green", "Bash", []string{"Bash"}, []string{"Bash"})
		if got != DecisionAutoDeny {
			t.Errorf("Bash in both lists = %v, want auto_deny (disallowed wins)", got.String())
		}
	})

	// Empty AllowedTools → no filtering
	t.Run("empty allowed list → no filtering", func(t *testing.T) {
		got := EvaluatePermission(PermModeYolo, "red", "Bash", nil, nil)
		if got != DecisionAutoApprove {
			t.Errorf("empty allowed, yolo, red = %v, want auto_approve", got.String())
		}
	})
}

func TestIsWriteTool(t *testing.T) {
	readTools := []string{"Read", "Grep", "Glob", "LS", "list_dir", "search", "WebSearch", "WebFetch", "codebase_search"}
	for _, tool := range readTools {
		if IsWriteTool(tool) {
			t.Errorf("IsWriteTool(%q) = true, want false (read-only tool)", tool)
		}
	}

	writeTools := []string{"Bash", "Write", "Edit", "Delete", "Move", "Mkdir", "unknown_tool", ""}
	for _, tool := range writeTools {
		if !IsWriteTool(tool) {
			t.Errorf("IsWriteTool(%q) = false, want true (write tool)", tool)
		}
	}
}

func TestPermissionDecisionString(t *testing.T) {
	tests := []struct {
		d    PermissionDecision
		want string
	}{
		{DecisionAutoApprove, "auto_approve"},
		{DecisionAutoDeny, "auto_deny"},
		{DecisionNeedsApproval, "needs_approval"},
	}
	for _, tc := range tests {
		if got := tc.d.String(); got != tc.want {
			t.Errorf("%d.String() = %q, want %q", tc.d, got, tc.want)
		}
	}
}

func TestWSEnvelopeSerialization(t *testing.T) {
	// Verify WSEnvelope with new fields serializes/deserializes correctly.
	env := WSEnvelope{
		Type:      MsgTypePermission,
		SessionID: "sess-test",
		Seq:       42,
		Source:    "agent",
		Timestamp: "2025-07-06T12:00:00Z",
		Payload: PermissionPayload{
			ToolName:  "Bash",
			Command:   "rm -rf /tmp/test",
			RiskLevel: "red",
			CmdID:     "cmd-001",
		},
	}

	// Marshal
	raw, err := json.Marshal(env)
	if err != nil {
		t.Fatalf("marshal error: %v", err)
	}

	// Verify type field
	var decoded map[string]interface{}
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatalf("unmarshal to map error: %v", err)
	}
	if decoded["type"] != MsgTypePermission {
		t.Errorf("type = %v, want %s", decoded["type"], MsgTypePermission)
	}
}

func TestJoinMessageWithPermissionMode(t *testing.T) {
	// Verify JoinMessage with PermissionMode serializes correctly.
	join := JoinMessage{
		SessionID:      "sess-001",
		ClientType:     "phone",
		ClientID:       "phone-001",
		Project:        "test-proj",
		Token:          "secret",
		PermissionMode: PermModeSafeYolo,
		AllowedTools:   []string{"Bash", "Read"},
	}

	raw, err := json.Marshal(join)
	if err != nil {
		t.Fatalf("marshal error: %v", err)
	}

	var decoded JoinMessage
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatalf("unmarshal error: %v", err)
	}
	if decoded.PermissionMode != PermModeSafeYolo {
		t.Errorf("PermissionMode = %q, want %q", decoded.PermissionMode, PermModeSafeYolo)
	}
	if len(decoded.AllowedTools) != 2 {
		t.Errorf("AllowedTools len = %d, want 2", len(decoded.AllowedTools))
	}
}
