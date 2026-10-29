package tui_test

import (
	"bufio"
	"encoding/json/jsontext"
	"encoding/json/v2"
	"net"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/oleksandr/super-pi-beam/clients/agy-tui/internal/rpc"
	"github.com/oleksandr/super-pi-beam/clients/agy-tui/internal/tui"
)

func TestRPCClientAndK2AckBackpressure(t *testing.T) {
	ctx := t.Context()

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("failed to listen: %v", err)
	}
	defer ln.Close()

	ackedBatchIDs := make(chan int64, 10)

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

			switch req.Method {
			case "session.open":
				resp := map[string]any{
					"jsonrpc": "2.0",
					"id":      req.ID,
					"result": map[string]any{
						"conversation_id": 42,
						"seq":             7,
						"agent":           map[string]any{"model": "gemini-3-flash-preview"},
					},
				}
				raw, _ := json.Marshal(resp)
				_, _ = conn.Write(append(raw, '\n'))

			case "session.watch":
				resp := map[string]any{
					"jsonrpc": "2.0",
					"id":      req.ID,
					"result":  map[string]any{"watching": 42, "max_in_flight": 2},
				}
				raw, _ := json.Marshal(resp)
				_, _ = conn.Write(append(raw, '\n'))

				// Emit two streaming batches to verify automatic K=2 acks
				for b := range 2 {
					batchID := int64(b + 1)
					notif := map[string]any{
						"jsonrpc": "2.0",
						"method":  "session.event",
						"params": map[string]any{
							"batch_id": batchID,
							"events": []map[string]any{
								{"type": "text_delta", "delta": "Hello "},
							},
						},
					}
					nRaw, _ := json.Marshal(notif)
					_, _ = conn.Write(append(nRaw, '\n'))
				}

			case "session.ack":
				var params struct {
					BatchID int64 `json:"batch_id"`
				}
				_ = json.Unmarshal(jsontext.Value(req.Params), &params)
				ackedBatchIDs <- params.BatchID
			}
		}
	}()

	client, err := rpc.Dial(ctx, ln.Addr().String())
	if err != nil {
		t.Fatalf("Dial failed: %v", err)
	}
	defer client.Close()

	openRes, err := client.OpenSession(ctx, 0, map[string]any{"model": "gemini-3-flash-preview"}, "agy")
	if err != nil {
		t.Fatalf("OpenSession failed: %v", err)
	}
	if openRes.ConversationID != 42 {
		t.Fatalf("expected conversation 42, got %d", openRes.ConversationID)
	}

	if err := client.WatchSession(ctx, 42); err != nil {
		t.Fatalf("WatchSession failed: %v", err)
	}

	for expected := int64(1); expected <= 2; expected++ {
		select {
		case got := <-ackedBatchIDs:
			if got != expected {
				t.Fatalf("expected ack for batch %d, got %d", expected, got)
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("timed out waiting for session.ack %d", expected)
		}
	}

	if client.AckedBatches() != 2 {
		t.Fatalf("expected AckedBatches() == 2, got %d", client.AckedBatches())
	}
}

func TestBubbleTeaModelStreamingAndSlashAutocomplete(t *testing.T) {
	m := tui.NewModel(tui.Config{
		ConversationID: 101,
		Model:          "gemini-3-flash-preview",
		Effort:         "medium",
		Mode:           "auto",
		WorkspaceDir:   ".",
	})

	// Resize window
	nextModel, _ := m.Update(tea.WindowSizeMsg{Width: 120, Height: 40})
	m = nextModel.(tui.Model)

	// Simulate streaming thinking, tool execution with hook overwrite, and markdown assistant output
	events := []rpc.WatchEvent{
		{Type: "state_changed", Status: "streaming_llm", Seq: 1},
		{Type: "thinking_delta", Delta: "Analyzing repository architecture..."},
		{Type: "tool_started", ToolCallID: "call_1", Name: "bash", OverwrittenKeys: []string{"command"}},
		{Type: "tool_completed", ToolCallID: "call_1", Name: "bash", Output: "[Hook Notice: PreToolUse rewrote tool arguments]\nOK"},
		{Type: "text_delta", Delta: "Here is the **verified** result."},
		{Type: "turn_completed", Seq: 2},
	}

	for _, ev := range events {
		nextModel, _ = m.Update(tui.WatchMsg(ev))
		m = nextModel.(tui.Model)
	}

	streamedView := m.View()
	if !strings.Contains(streamedView, "Hook Rewrote: command") {
		t.Fatalf("expected tool block to show Hook Rewrote badge, got:\n%s", streamedView)
	}
	if !strings.Contains(streamedView, "Analyzing repository architecture") {
		t.Fatalf("expected thinking block in view, got:\n%s", streamedView)
	}

	// Test permission UI modal (ui.request)
	nextModel, _ = m.Update(tui.UIRequestMsg{
		RequestID: "req_99",
		Title:     "Execute bash(rm -rf /tmp/test)",
		Prompt:    "Allow execution outside allowlist?",
	})
	m = nextModel.(tui.Model)
	modalView := m.View()
	if !strings.Contains(modalView, "PERMISSION REQUIRED") {
		t.Fatalf("expected permission modal in view, got:\n%s", modalView)
	}
	// Resolve modal with 'y'
	nextModel, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'y'}})
	m = nextModel.(tui.Model)

	// Type "/pl" to trigger slash command autocomplete
	for _, r := range "/pl" {
		nextModel, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
		m = nextModel.(tui.Model)
	}

	viewWithPopup := m.View()
	if !strings.Contains(viewWithPopup, "/plan") {
		t.Fatalf("expected slash autocomplete popup to contain /plan, got:\n%s", viewWithPopup)
	}

	// Press Tab to complete "/plan " and Enter to submit
	nextModel, _ = m.Update(tea.KeyMsg{Type: tea.KeyTab})
	m = nextModel.(tui.Model)
	nextModel, _ = m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	m = nextModel.(tui.Model)

	viewInPlanMode := m.View()
	if !strings.Contains(viewInPlanMode, "MODE: PLAN") {
		t.Fatalf("expected header bar to switch to MODE: PLAN, got:\n%s", viewInPlanMode)
	}
}
