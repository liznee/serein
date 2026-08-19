//go:build windows

// Package main: Input injection via Windows SendInput API.
//
// This file provides the bridge's ability to inject mouse and keyboard events
// received from the phone via WebRTC DataChannel into the Windows desktop.
//
// Security: The bridge only injects input when:
// 1. A DataChannel message with a valid input event is received
// 2. The PeerConnection is in the Connected state
// 3. The session has been explicitly authorized by the host user
//
// The input protocol uses short JSON field names to minimize overhead:
//
//	{"t":"pm","x":0.5,"y":0.5}             — pointer move (normalized 0–1)
//	{"t":"pd","b":"left","x":0.5,"y":0.5}  — pointer button down
//	{"t":"pu","b":"left"}                  — pointer button up
//	{"t":"ps","d":1,"x":0.5,"y":0.5}       — pointer scroll (delta ±1)
//	{"t":"kd","c":13}                      — key down (virtual-key code)
//	{"t":"ku","c":13}                      — key up
//	{"t":"kt","s":"hello"}                 — Unicode text input
//
// Coordinates are normalized (0.0–1.0) and mapped to absolute screen
// coordinates (0–65535) as required by MOUSEEVENTF_ABSOLUTE.
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"strings"
	"syscall"
	"unsafe"
)

var (
	user32                       = syscall.NewLazyDLL("user32.dll")
	procSendInput                = user32.NewProc("SendInput")
	procGetSystemMetrics         = user32.NewProc("GetSystemMetrics")
	procGetForegroundWindow      = user32.NewProc("GetForegroundWindow")
	procGetWindowThreadProcessId = user32.NewProc("GetWindowThreadProcessId")
	procGetGUIThreadInfo         = user32.NewProc("GetGUIThreadInfo")
	procGetClassNameW            = user32.NewProc("GetClassNameW")
)

const (
	inputMouse    = 0
	inputKeyboard = 1

	mouseeventfMove       = 0x0001
	mouseeventfAbsolute   = 0x8000
	mouseeventfLeftDown   = 0x0002
	mouseeventfLeftUp     = 0x0004
	mouseeventfRightDown  = 0x0008
	mouseeventfRightUp    = 0x0010
	mouseeventfMiddleDown = 0x0020
	mouseeventfMiddleUp   = 0x0040
	mouseeventfWheel      = 0x0800

	keyeventfKeyUp   = 0x0002
	keyeventfUnicode = 0x0004

	smCXScreen       = 0
	smCYScreen       = 1
	guiCaretBlinking = 0x00000001
)

type winRect struct {
	Left   int32
	Top    int32
	Right  int32
	Bottom int32
}

// guiThreadInfo is the Win32 GUITHREADINFO layout. The foreground thread's
// caret bit tells us whether the click actually landed in an editable control;
// it avoids guessing from video pixels on the phone.
type guiThreadInfo struct {
	CbSize        uint32
	Flags         uint32
	HwndActive    uintptr
	HwndFocus     uintptr
	HwndCapture   uintptr
	HwndMenuOwner uintptr
	HwndMoveSize  uintptr
	HwndCaret     uintptr
	RcCaret       winRect
}

// mouseInput corresponds to the Windows MOUSEINPUT structure.
type mouseInput struct {
	Dx          int32
	Dy          int32
	MouseData   uint32
	DwFlags     uint32
	Time        uint32
	DwExtraInfo uintptr
}

// keybdInput corresponds to the Windows KEYBDINPUT structure.
type keybdInput struct {
	WVk         uint16
	WScan       uint16
	DwFlags     uint32
	Time        uint32
	DwExtraInfo uintptr
}

// hardwardInput covers the same union size as mouseInput (the largest member).
// Using mouseInput as the union overlay since it's 32 bytes on 64-bit.
type tagINPUT struct {
	Type uint32
	Pad  uint32 // alignment padding (union starts at offset 8)
	Mi   mouseInput
}

// screenMetrics returns the virtual screen width and height for absolute
// coordinate mapping. SM_CXSCREEN/SM_CYSCREEN return the primary monitor
// resolution in pixels.
func screenMetrics() (cx, cy int32) {
	cxRet, _, _ := procGetSystemMetrics.Call(smCXScreen)
	cyRet, _, _ := procGetSystemMetrics.Call(smCYScreen)
	return int32(cxRet), int32(cyRet)
}

// sendInput wraps the Windows SendInput API.
func sendInput(inputs []tagINPUT) error {
	if len(inputs) == 0 {
		return nil
	}
	n, _, err := procSendInput.Call(
		uintptr(len(inputs)),
		uintptr(unsafe.Pointer(&inputs[0])),
		unsafe.Sizeof(inputs[0]),
	)
	if n != uintptr(len(inputs)) {
		return fmt.Errorf("SendInput returned %d (err: %v)", n, err)
	}
	return nil
}

// normalizeToAbsolute maps a normalized [0.0, 1.0] coordinate to the
// Windows absolute coordinate system [0, 65535].
func normalizeToAbsolute(n float64) int32 {
	if n < 0 {
		n = 0
	}
	if n > 1 {
		n = 1
	}
	return int32(n * 65535)
}

// injectPointerMove moves the cursor to the normalized position.
func injectPointerMove(x, y float64) error {
	inputs := []tagINPUT{{
		Type: inputMouse,
		Mi: mouseInput{
			Dx:      normalizeToAbsolute(x),
			Dy:      normalizeToAbsolute(y),
			DwFlags: mouseeventfMove | mouseeventfAbsolute,
		},
	}}
	return sendInput(inputs)
}

// injectPointerButton presses or releases a mouse button at a position.
func injectPointerButton(button string, down bool, x, y float64) error {
	var flag uint32
	switch button {
	case "left":
		if down {
			flag = mouseeventfLeftDown
		} else {
			flag = mouseeventfLeftUp
		}
	case "right":
		if down {
			flag = mouseeventfRightDown
		} else {
			flag = mouseeventfRightUp
		}
	case "middle":
		if down {
			flag = mouseeventfMiddleDown
		} else {
			flag = mouseeventfMiddleUp
		}
	default:
		return fmt.Errorf("unknown button: %s", button)
	}
	// The browser includes a position for button-down, but intentionally omits
	// it for button-up. Moving again on release would otherwise warp the cursor
	// to (0,0), making the Windows taskbar/Dock unreachable.
	mi := mouseInput{DwFlags: flag}
	if down {
		mi.Dx = normalizeToAbsolute(x)
		mi.Dy = normalizeToAbsolute(y)
		mi.DwFlags |= mouseeventfMove | mouseeventfAbsolute
	}
	inputs := []tagINPUT{{Type: inputMouse, Mi: mi}}
	return sendInput(inputs)
}

func focusedWindowClass(hwnd uintptr) string {
	if hwnd == 0 {
		return ""
	}
	buffer := make([]uint16, 256)
	n, _, _ := procGetClassNameW.Call(hwnd, uintptr(unsafe.Pointer(&buffer[0])), uintptr(len(buffer)))
	if n == 0 {
		return ""
	}
	return strings.ToLower(syscall.UTF16ToString(buffer[:n]))
}

// focusedTextInput checks the foreground GUI thread after a normal left click.
// Most native, browser and editor text fields expose a blinking caret. The
// class fallback covers common edit controls which may not blink briefly while
// their focus animation is still settling.
func focusedTextInput() bool {
	foreground, _, _ := procGetForegroundWindow.Call()
	if foreground == 0 {
		return false
	}
	threadID, _, _ := procGetWindowThreadProcessId.Call(foreground, 0)
	if threadID == 0 {
		return false
	}
	info := guiThreadInfo{CbSize: uint32(unsafe.Sizeof(guiThreadInfo{}))}
	ok, _, _ := procGetGUIThreadInfo.Call(threadID, uintptr(unsafe.Pointer(&info)))
	if ok == 0 || info.HwndFocus == 0 {
		return false
	}
	if info.Flags&guiCaretBlinking != 0 {
		return true
	}
	className := focusedWindowClass(info.HwndFocus)
	return className == "edit" || strings.Contains(className, "richedit") ||
		strings.Contains(className, "scintilla") || strings.Contains(className, "textbox")
}

func isLeftButtonUp(data []byte) bool {
	var event inputEvent
	if err := json.Unmarshal(data, &event); err != nil {
		return false
	}
	return event.T == "pu" && event.B == "left"
}

// injectPointerScroll sends a vertical scroll event at a position.
func injectPointerScroll(delta int, x, y float64) error {
	inputs := []tagINPUT{{
		Type: inputMouse,
		Mi: mouseInput{
			Dx:        normalizeToAbsolute(x),
			Dy:        normalizeToAbsolute(y),
			MouseData: uint32(delta * 120), // WHEEL_DELTA = 120
			DwFlags:   mouseeventfMove | mouseeventfAbsolute | mouseeventfWheel,
		},
	}}
	return sendInput(inputs)
}

// injectKeyPress sends a key down + key up for a virtual-key code.
func injectKeyPress(vk uint16) error {
	inputs := []tagINPUT{
		{Type: inputKeyboard, Mi: mouseInput{}}, // zero-initialize union
		{Type: inputKeyboard, Mi: mouseInput{}},
	}
	// Overlay keybdInput onto the mouseInput union memory.
	ki1 := (*keybdInput)(unsafe.Pointer(&inputs[0].Mi))
	ki1.WVk = vk
	ki1.DwFlags = 0
	ki2 := (*keybdInput)(unsafe.Pointer(&inputs[1].Mi))
	ki2.WVk = vk
	ki2.DwFlags = keyeventfKeyUp
	return sendInput(inputs)
}

// injectKeyDown sends a key down event.
func injectKeyDown(vk uint16) error {
	inputs := []tagINPUT{{Type: inputKeyboard, Mi: mouseInput{}}}
	ki := (*keybdInput)(unsafe.Pointer(&inputs[0].Mi))
	ki.WVk = vk
	ki.DwFlags = 0
	return sendInput(inputs)
}

// injectKeyUp sends a key up event.
func injectKeyUp(vk uint16) error {
	inputs := []tagINPUT{{Type: inputKeyboard, Mi: mouseInput{}}}
	ki := (*keybdInput)(unsafe.Pointer(&inputs[0].Mi))
	ki.WVk = vk
	ki.DwFlags = keyeventfKeyUp
	return sendInput(inputs)
}

// injectText sends Unicode text input character by character.
func injectText(text string) error {
	runes := []rune(text)
	if len(runes) == 0 {
		return nil
	}
	inputs := make([]tagINPUT, 0, len(runes)*2)
	for _, r := range runes {
		// Key down (Unicode)
		down := tagINPUT{Type: inputKeyboard, Mi: mouseInput{}}
		kiDown := (*keybdInput)(unsafe.Pointer(&down.Mi))
		kiDown.WScan = uint16(r)
		kiDown.DwFlags = keyeventfUnicode
		inputs = append(inputs, down)

		// Key up (Unicode)
		up := tagINPUT{Type: inputKeyboard, Mi: mouseInput{}}
		kiUp := (*keybdInput)(unsafe.Pointer(&up.Mi))
		kiUp.WScan = uint16(r)
		kiUp.DwFlags = keyeventfUnicode | keyeventfKeyUp
		inputs = append(inputs, up)
	}
	// Send in batches of 32 to avoid exceeding SendInput's practical limit.
	for i := 0; i < len(inputs); i += 32 {
		end := i + 32
		if end > len(inputs) {
			end = len(inputs)
		}
		if err := sendInput(inputs[i:end]); err != nil {
			return err
		}
	}
	return nil
}

// inputEvent is the JSON message format received from the phone via DataChannel.
type inputEvent struct {
	T string  `json:"t"` // event type: pm/pd/pu/ps/kd/ku/kt
	X float64 `json:"x,omitempty"`
	Y float64 `json:"y,omitempty"`
	B string  `json:"b,omitempty"` // button: left/right/middle
	D int     `json:"d,omitempty"` // scroll delta
	C int     `json:"c,omitempty"` // virtual-key code
	S string  `json:"s,omitempty"` // text string
}

// handleInputEvent parses and executes an input event from the DataChannel.
// Returns an error if the event is malformed or injection fails.
func handleInputEvent(data []byte) error {
	var event inputEvent
	if err := json.Unmarshal(data, &event); err != nil {
		return fmt.Errorf("input event parse: %w", err)
	}
	switch event.T {
	case "pm": // pointer move
		return injectPointerMove(event.X, event.Y)
	case "pd": // pointer button down
		return injectPointerButton(event.B, true, event.X, event.Y)
	case "pu": // pointer button up
		return injectPointerButton(event.B, false, event.X, event.Y)
	case "ps": // pointer scroll
		return injectPointerScroll(event.D, event.X, event.Y)
	case "kd": // key down
		return injectKeyDown(uint16(event.C))
	case "ku": // key up
		return injectKeyUp(uint16(event.C))
	case "kt": // text input
		return injectText(event.S)
	default:
		return fmt.Errorf("unknown input event type: %s", event.T)
	}
}

// releaseAllInput sends key-up events for common modifier keys to prevent
// stuck keys when the DataChannel disconnects. This is a best-effort cleanup.
func releaseAllInput() {
	// Release common modifier keys that could get stuck: Shift, Ctrl, Alt, Win
	modifiers := []uint16{0x10, 0x11, 0x12, 0x5B, 0x5C} // VK_SHIFT, VK_CONTROL, VK_MENU, VK_LWIN, VK_RWIN
	for _, vk := range modifiers {
		inputs := []tagINPUT{{Type: inputKeyboard, Mi: mouseInput{}}}
		ki := (*keybdInput)(unsafe.Pointer(&inputs[0].Mi))
		ki.WVk = vk
		ki.DwFlags = keyeventfKeyUp
		if err := sendInput(inputs); err != nil {
			log.Printf("serein-remote-bridge: release key 0x%X: %v", vk, err)
		}
	}
	// Release mouse buttons
	for _, flag := range []uint32{mouseeventfLeftUp, mouseeventfRightUp, mouseeventfMiddleUp} {
		inputs := []tagINPUT{{
			Type: inputMouse,
			Mi:   mouseInput{DwFlags: flag},
		}}
		if err := sendInput(inputs); err != nil {
			log.Printf("serein-remote-bridge: release mouse button: %v", err)
		}
	}
	log.Printf("serein-remote-bridge: released all input buttons/keys")
}
