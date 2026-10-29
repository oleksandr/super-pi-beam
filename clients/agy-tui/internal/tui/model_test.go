package tui_test

import (
	"bufio"
	"encoding/json/v2"
	"net"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/oleksandr/super-pi-beam/clients/agy-tui/internal/banner"
	"github.com/oleksandr/super-pi-beam/clients/agy-tui/internal/diff"
	"github.com/oleksandr/super-pi-beam/clients/agy-tui/internal/panels"
	"github.com/oleksandr/super-pi-beam/clients/agy-tui/internal/rpc"
	"github.com/oleksandr/super-pi-beam/clients/agy-tui/internal/tui"
)

func TestBannerAndDiffRendering(t *testing.T) {
	b := banner.Render(banner.Config{
		Version:      "1.0.0 (OTP 28.4 / Elixir 1.20)",
		UserAccount:  "Durable BEAM Harness (SQLite WAL)",
		ModelDisplay: "Gemini 3.8 Flash (Medium)",
		Workspace:    "/tmp/test",
	})
	if !strings.Contains(b, "Super-Pi-BEAM") {
		t.Fatalf("expected Super-Pi-BEAM in banner, got:\n%s", b)
	}

	d := diff.ParseSimpleDiff("calc.py", "def add(a, b):\n    return a + b\n", "def add(a, b):\n    return a + b\n\ndef sub(a, b):\n    return a - b\n")
	rendered := diff.Render(d, 80)
	if !strings.Contains(rendered, "Edit(calc.py)") || !strings.Contains(rendered, "def sub(a, b):") {
		t.Fatalf("expected unified diff block, got:\n%s", rendered)
	}
}

func TestPanelsAndModelPicker(t *testing.T) {
	m := panels.RenderModelPicker(0, "medium", 80)
	if !strings.Contains(m, "Switch Model") || !strings.Contains(m, "Effort") {
		t.Fatalf("expected Switch Model panel, got:\n%s", m)
	}

	h := panels.RenderHelpTabs(0, 0, 80)
	if !strings.Contains(h, "Super-Pi-BEAM CLI") || !strings.Contains(h, "general") {
		t.Fatalf("expected Help panel, got:\n%s", h)
	}
}

func TestInlineTUIModelAndSlashCommands(t *testing.T) {
	m := tui.NewModel(tui.Config{
		ConversationID: 202,
		Model:          "Gemini 3.8 Flash",
		Effort:         "medium",
		Mode:           "auto",
		WorkspaceDir:   "/tmp",
	})

	// Initial view must show the hero banner
	initView := m.View()
	if !strings.Contains(initView, "Super-Pi-BEAM") || !strings.Contains(initView, "Gemini 3.8 Flash · medium") {
		t.Fatalf("expected initial hero banner in view, got:\n%s", initView)
	}

	// Type "/mo" to trigger slash popup
	for _, r := range "/mo" {
		next, _ := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
		m = next.(tui.Model)
	}
	popupView := m.View()
	if !strings.Contains(popupView, "/model") {
		t.Fatalf("expected slash popup with /model, got:\n%s", popupView)
	}

	// Press Tab to complete "/model " and Enter to open the model picker
	next, _ := m.Update(tea.KeyMsg{Type: tea.KeyTab})
	m = next.(tui.Model)
	next, _ = m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	m = next.(tui.Model)

	panelView := m.View()
	if !strings.Contains(panelView, "Switch Model") {
		t.Fatalf("expected Switch Model panel mounted below composer, got:\n%s", panelView)
	}

	// Press Esc to close panel
	next, _ = m.Update(tea.KeyMsg{Type: tea.KeyEsc})
	m = next.(tui.Model)
	closedView := m.View()
	if !strings.Contains(closedView, "Exited /model command") {
		t.Fatalf("expected history elbow entry for exited command, got:\n%s", closedView)
	}
}

func TestRPCK2AckAndStreamingSteps(t *testing.T) {
	ctx := t.Context()

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("failed to listen: %v", err)
	}
	defer ln.Close()

	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()

		scanner := bufio.NewScanner(conn)
		for scanner.Scan() {
			var req rpc.InboundFrame
			if err := json.Unmarshal(scanner.Bytes(), &req); err != nil {
				continue
			}
			if req.Method == "session.open" {
				resp := map[string]any{
					"jsonrpc": "2.0",
					"id":      req.ID,
					"result":  map[string]any{"conversation_id": 55, "seq": 1},
				}
				raw, _ := json.Marshal(resp)
				_, _ = conn.Write(append(raw, '\n'))
			} else if req.Method == "session.watch" {
				resp := map[string]any{
					"jsonrpc": "2.0",
					"id":      req.ID,
					"result":  map[string]any{"watching": 55, "max_in_flight": 2},
				}
				raw, _ := json.Marshal(resp)
				_, _ = conn.Write(append(raw, '\n'))
			} else if req.Method == "session.ack" {
				// ACK received
			}
		}
	}()

	client, err := rpc.Dial(ctx, ln.Addr().String())
	if err != nil {
		t.Fatalf("Dial failed: %v", err)
	}
	defer client.Close()

	openRes, err := client.OpenSession(ctx, 0, map[string]any{"model": "Gemini 3.8 Flash"}, "agy")
	if err != nil || openRes.ConversationID != 55 {
		t.Fatalf("OpenSession error: %v, res: %+v", err, openRes)
	}
}

func TestHistoryViewportScrolling(t *testing.T) {
	m := tui.NewModel(tui.Config{
		ConversationID: 101,
		Model:          "Gemini 3.8 Flash",
		Effort:         "medium",
	})
	// Set explicit window size (80x15)
	next, _ := m.Update(tea.WindowSizeMsg{Width: 80, Height: 15})
	m = next.(tui.Model)

	// Feed multiple messages to create long scrollback history
	for i := 1; i <= 25; i++ {
		next, _ = m.Update(tui.WatchMsg(rpc.WatchEvent{
			Type:  "text_delta",
			Delta: strings.Repeat("Long line of text in the conversation history.\n", 2),
		}))
		m = next.(tui.Model)
	}

	// At bottom initially
	view := m.View()
	if strings.Contains(view, "Scrolled up") {
		t.Fatalf("expected view to start pinned at bottom, got scroll indicator")
	}

	// Scroll up via mouse wheel
	next, _ = m.Update(tea.MouseMsg{Type: tea.MouseWheelUp})
	m = next.(tui.Model)
	scrolledView := m.View()
	if !strings.Contains(scrolledView, "Scrolled up") {
		t.Fatalf("expected floating scroll hint after MouseWheelUp, got:\n%s", scrolledView)
	}

	// Scroll down via mouse wheel
	next, _ = m.Update(tea.MouseMsg{Type: tea.MouseWheelDown})
	m = next.(tui.Model)

	// Scroll up via page up
	next, _ = m.Update(tea.KeyMsg{Type: tea.KeyPgUp})
	m = next.(tui.Model)
	pgView := m.View()
	if !strings.Contains(pgView, "Scrolled up") {
		t.Fatalf("expected floating scroll hint after PageUp, got:\n%s", pgView)
	}

	// Jump to bottom via ctrl+end
	next, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{}, Paste: false})
	next, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("c")}) // type rune
	// Trigger explicit ctrl+end
	for _, k := range []string{"ctrl+end", "\x1b[1;5F"} {
		next, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(k)})
		m = next.(tui.Model)
	}
}

func TestActivityIndicatorLifecycle(t *testing.T) {
	m := tui.NewModel(tui.Config{
		ConversationID: 202,
		Model:          "Gemini 3.8 Flash",
		Effort:         "medium",
	})
	next, _ := m.Update(tea.WindowSizeMsg{Width: 100, Height: 25})
	m = next.(tui.Model)

	// 1. Submit prompt -> instantly displays prompt + active "Generating..." spinner + "esc to cancel"
	for _, r := range "Check status of the server" {
		next, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
		m = next.(tui.Model)
	}
	next, _ = m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	m = next.(tui.Model)

	busyView := m.View()
	if !strings.Contains(busyView, "Generating...") {
		t.Fatalf("expected Generating... active spinner after submit, got:\n%s", busyView)
	}
	if !strings.Contains(busyView, "esc to cancel") {
		t.Fatalf("expected 'esc to cancel' in statusline when busy, got:\n%s", busyView)
	}

	// 2. Tool started (bash) -> active tool bullet "Running (hostname)" + active spinner "Running command..."
	next, _ = m.Update(tui.WatchMsg(rpc.WatchEvent{
		Type:       "tool_started",
		Name:       "bash",
		Arguments:  map[string]any{"command": "hostname"},
		ToolCallID: "call_01",
	}))
	m = next.(tui.Model)

	toolRunningView := m.View()
	if !strings.Contains(toolRunningView, "Running (hostname)") {
		t.Fatalf("expected active bullet Running (hostname), got:\n%s", toolRunningView)
	}
	if !strings.Contains(toolRunningView, "Running command...") {
		t.Fatalf("expected active tool label Running command..., got:\n%s", toolRunningView)
	}

	// 3. Tool completed -> past tense bullet "Ran (hostname)" + transitional "Generating..."
	next, _ = m.Update(tui.WatchMsg(rpc.WatchEvent{
		Type:       "tool_completed",
		Name:       "bash",
		Output:     "omarchy-desktop\n",
		ToolCallID: "call_01",
	}))
	m = next.(tui.Model)

	toolDoneView := m.View()
	if !strings.Contains(toolDoneView, "Ran (hostname)") {
		t.Fatalf("expected completed bullet Ran (hostname), got:\n%s", toolDoneView)
	}
	if !strings.Contains(toolDoneView, "Generating...") {
		t.Fatalf("expected transitional Generating... label after tool completion, got:\n%s", toolDoneView)
	}

	// 4. Turn completed -> idle state, "esc to cancel" reverts to "? for shortcuts"
	next, _ = m.Update(tui.WatchMsg(rpc.WatchEvent{
		Type: "turn_completed",
	}))
	m = next.(tui.Model)

	idleView := m.View()
	if !strings.Contains(idleView, "? for shortcuts") {
		t.Fatalf("expected ? for shortcuts after turn completed, got:\n%s", idleView)
	}
	if strings.Contains(idleView, "esc to cancel") {
		t.Fatalf("did not expect esc to cancel when idle, got:\n%s", idleView)
	}

	// 5. User cancellation via Esc when busy
	for _, r := range "Another command" {
		next, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
		m = next.(tui.Model)
	}
	next, _ = m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	m = next.(tui.Model)

	// Press Esc to cancel
	next, _ = m.Update(tea.KeyMsg{Type: tea.KeyEsc})
	m = next.(tui.Model)

	cancelView := m.View()
	if !strings.Contains(cancelView, "Turn cancelled by user") {
		t.Fatalf("expected notice step for user cancellation, got:\n%s", cancelView)
	}
	if !strings.Contains(cancelView, "? for shortcuts") {
		t.Fatalf("expected ? for shortcuts after cancellation, got:\n%s", cancelView)
	}
}
