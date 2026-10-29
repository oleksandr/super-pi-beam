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
