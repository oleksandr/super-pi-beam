package tui

import (
	"cmp"
	"context"
	"encoding/json/jsontext"
	"encoding/json/v2"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/spinner"
	"github.com/charmbracelet/bubbles/textarea"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/glamour"
	"github.com/charmbracelet/lipgloss"
	"github.com/oleksandr/super-pi-beam/clients/agy-tui/internal/rpc"
)

// ChatItemKind identifies the visual block type in the conversation timeline.
type ChatItemKind string

const (
	ItemUser      ChatItemKind = "user"
	ItemAssistant ChatItemKind = "assistant"
	ItemThinking  ChatItemKind = "thinking"
	ItemTool      ChatItemKind = "tool"
	ItemSystem    ChatItemKind = "system"
)

// ChatItem represents an entry in the rich conversation viewport.
type ChatItem struct {
	Kind            ChatItemKind
	Text            string
	ToolCallID      string
	ToolName        string
	Arguments       map[string]any
	OverwrittenKeys []string
	IsError         bool
	Done            bool
	Collapsed       bool
	Timestamp       time.Time
}

// SlashCommandSpec describes an interactive slash command in the autocomplete popup.
type SlashCommandSpec struct {
	Name        string
	Description string
}

var defaultSlashCommands = []SlashCommandSpec{
	{Name: "/plan", Description: "Switch to read-only architectural planning mode"},
	{Name: "/goal", Description: "Run autonomous multi-step goal with verification"},
	{Name: "/boost", Description: "Maximize reasoning effort (effort=max)"},
	{Name: "/compact", Description: "Compact conversation context (4-mode cut-point)"},
	{Name: "/model", Description: "Cycle or switch active LLM model"},
	{Name: "/mode", Description: "Cycle execution mode (auto -> plan -> accept-edits)"},
	{Name: "/fork", Description: "Fork current conversation branch"},
	{Name: "/clear", Description: "Clear local viewport timeline"},
	{Name: "/help", Description: "Display keyboard shortcuts and slash commands"},
}

var availableModels = []string{
	"gemini-3-flash-preview",
	"gemini-4-argon-medium",
	"gemini-4-argon-high",
	"claude-opus-5-5-high",
	"claude-sonnet-5-5-medium",
}

var availableModes = []string{
	"auto",
	"plan",
	"accept-edits",
}

// Config holds the initial session configuration passed to the TUI.
type Config struct {
	Client         *rpc.Client
	ConversationID int64
	Model          string
	Effort         string
	Mode           string
	WorkspaceDir   string
	InitialPrompt  string
}

// WatchMsg wraps an rpc.WatchEvent for Bubble Tea's Update loop.
type WatchMsg rpc.WatchEvent

// UIRequestMsg wraps an rpc.UIRequestParams for Bubble Tea's Update loop.
type UIRequestMsg rpc.UIRequestParams

type rpcErrorMsg struct{ err error }

// Model implements tea.Model for the Antigravity CLI clone TUI.
type Model struct {
	cfg               Config
	viewport          viewport.Model
	composer          textarea.Model
	spin              spinner.Model
	mdRenderer        *glamour.TermRenderer
	width             int
	height            int
	ready             bool
	machineState      string
	seq               int64
	items             []ChatItem
	collapseThinking  bool
	collapseTools     bool
	suggestions       []SlashCommandSpec
	fileSuggestions   []string
	selectedSuggest   int
	activeUIRequest   *rpc.UIRequestParams
	workspaceFiles    []string
}

// NewModel initializes the Bubble Tea TUI model.
func NewModel(cfg Config) Model {
	ta := textarea.New()
	ta.Placeholder = "Ask Antigravity anything... (/ for commands, @ for files, Enter to send, Ctrl+S to steer)"
	ta.Focus()
	ta.Prompt = "❯ "
	ta.CharLimit = 32768
	ta.SetWidth(94)
	ta.SetHeight(3)
	ta.ShowLineNumbers = false
	ta.KeyMap.InsertNewline.SetKeys("alt+enter", "ctrl+j")

	sp := spinner.New()
	sp.Spinner = spinner.MiniDot
	sp.Style = lipgloss.NewStyle().Foreground(lipgloss.Color("#38BDF8"))

	vp := viewport.New(98, 20)

	md, _ := glamour.NewTermRenderer(
		glamour.WithStandardStyle("dark"),
		glamour.WithWordWrap(76),
	)

	wsDir := cmp.Or(cfg.WorkspaceDir, ".")
	files := scanWorkspaceFiles(wsDir, 150)

	items := []ChatItem{
		{
			Kind:      ItemSystem,
			Text:      fmt.Sprintf("Connected to Super-Pi-BEAM RPC • Conversation #%d • Workspace %s", cfg.ConversationID, wsDir),
			Done:      true,
			Timestamp: time.Now(),
		},
	}

	m := Model{
		cfg: Config{
			Client:         cfg.Client,
			ConversationID: cfg.ConversationID,
			Model:          cmp.Or(cfg.Model, "gemini-3-flash-preview"),
			Effort:         cmp.Or(cfg.Effort, "medium"),
			Mode:           cmp.Or(cfg.Mode, "auto"),
			WorkspaceDir:   wsDir,
			InitialPrompt:  cfg.InitialPrompt,
		},
		viewport:         vp,
		composer:         ta,
		spin:             sp,
		mdRenderer:       md,
		width:            100,
		height:           30,
		ready:            true,
		machineState:     "idle",
		items:            items,
		collapseThinking: false,
		collapseTools:    false,
		workspaceFiles:   files,
	}
	m.recalculateLayout()
	m.refreshViewport()
	return m
}

// Init starts the spinner, RPC event watcher, and optional initial prompt.
func (m Model) Init() tea.Cmd {
	cmds := []tea.Cmd{
		textarea.Blink,
		m.spin.Tick,
		waitForRPCEvent(m.cfg.Client),
		waitForUIRequest(m.cfg.Client),
	}
	if m.cfg.InitialPrompt != "" {
		prompt := m.cfg.InitialPrompt
		cmds = append(cmds, func() tea.Msg {
			return submitPromptMsg{text: prompt, mode: "queue"}
		})
	}
	return tea.Batch(cmds...)
}

type submitPromptMsg struct {
	text string
	mode string
}

func waitForRPCEvent(client *rpc.Client) tea.Cmd {
	if client == nil {
		return nil
	}
	return func() tea.Msg {
		ev, ok := <-client.Events()
		if !ok {
			return nil
		}
		return WatchMsg(ev)
	}
}

func waitForUIRequest(client *rpc.Client) tea.Cmd {
	if client == nil {
		return nil
	}
	return func() tea.Msg {
		req, ok := <-client.UIRequests()
		if !ok {
			return nil
		}
		return UIRequestMsg(req)
	}
}

// Update processes keyboard, window resize, spinner, and live RPC streaming events.
func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	var cmds []tea.Cmd

	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = max(msg.Width, 40)
		m.height = max(msg.Height, 14)
		m.recalculateLayout()
		m.refreshViewport()
		return m, nil

	case spinner.TickMsg:
		var cmd tea.Cmd
		m.spin, cmd = m.spin.Update(msg)
		return m, cmd

	case submitPromptMsg:
		return m.handleSubmit(msg.text, msg.mode)

	case WatchMsg:
		m.applyWatchEvent(rpc.WatchEvent(msg))
		m.refreshViewport()
		cmds = append(cmds, waitForRPCEvent(m.cfg.Client))
		return m, tea.Batch(cmds...)

	case UIRequestMsg:
		req := rpc.UIRequestParams(msg)
		m.activeUIRequest = &req
		m.refreshViewport()
		cmds = append(cmds, waitForUIRequest(m.cfg.Client))
		return m, tea.Batch(cmds...)

	case rpcErrorMsg:
		m.items = append(m.items, ChatItem{
			Kind:      ItemSystem,
			Text:      fmt.Sprintf("RPC Error: %v", msg.err),
			IsError:   true,
			Done:      true,
			Timestamp: time.Now(),
		})
		m.refreshViewport()
		return m, nil

	case tea.KeyMsg:
		// 1. Handle active interactive permission / UI modal first
		if m.activeUIRequest != nil {
			switch msg.String() {
			case "y", "Y", "enter":
				return m.resolveUIModal("allow")
			case "a", "A":
				return m.resolveUIModal("always_allow")
			case "n", "N", "esc":
				return m.resolveUIModal("deny")
			}
		}

		// 2. Global shortcuts
		switch msg.String() {
		case "ctrl+c", "esc":
			return m, tea.Quit

		case "ctrl+t":
			m.collapseThinking = !m.collapseThinking
			m.refreshViewport()
			return m, nil

		case "ctrl+o":
			m.collapseTools = !m.collapseTools
			m.refreshViewport()
			return m, nil

		case "pgup", "pgdown":
			var vpCmd tea.Cmd
			m.viewport, vpCmd = m.viewport.Update(msg)
			return m, vpCmd

		case "tab":
			if len(m.suggestions) > 0 {
				chosen := m.suggestions[m.selectedSuggest].Name
				m.composer.SetValue(chosen + " ")
				m.composer.CursorEnd()
				m.updateAutocomplete()
				return m, nil
			}
			if len(m.fileSuggestions) > 0 {
				chosen := m.fileSuggestions[m.selectedSuggest]
				m.replaceTrailingAtToken(chosen)
				m.updateAutocomplete()
				return m, nil
			}

		case "up":
			if len(m.suggestions) > 0 {
				m.selectedSuggest = (m.selectedSuggest - 1 + len(m.suggestions)) % len(m.suggestions)
				return m, nil
			}
			if len(m.fileSuggestions) > 0 {
				m.selectedSuggest = (m.selectedSuggest - 1 + len(m.fileSuggestions)) % len(m.fileSuggestions)
				return m, nil
			}

		case "down":
			if len(m.suggestions) > 0 {
				m.selectedSuggest = (m.selectedSuggest + 1) % len(m.suggestions)
				return m, nil
			}
			if len(m.fileSuggestions) > 0 {
				m.selectedSuggest = (m.selectedSuggest + 1) % len(m.fileSuggestions)
				return m, nil
			}

		case "ctrl+s":
			text := strings.TrimSpace(m.composer.Value())
			if text != "" {
				m.composer.Reset()
				m.updateAutocomplete()
				return m.handleSubmit(text, "steer")
			}
			return m, nil

		case "enter":
			text := strings.TrimSpace(m.composer.Value())
			if text != "" {
				m.composer.Reset()
				m.updateAutocomplete()
				return m.handleSubmit(text, "queue")
			}
			return m, nil
		}

		// Also checktea.KeyEnter type explicitly in case terminal sends \r or \n
		if msg.Type == tea.KeyEnter {
			text := strings.TrimSpace(m.composer.Value())
			if text != "" {
				m.composer.Reset()
				m.updateAutocomplete()
				return m.handleSubmit(text, "queue")
			}
			return m, nil
		}
	}

	var taCmd tea.Cmd
	m.composer, taCmd = m.composer.Update(msg)
	m.updateAutocomplete()
	cmds = append(cmds, taCmd)

	return m, tea.Batch(cmds...)
}

func (m Model) resolveUIModal(decision string) (tea.Model, tea.Cmd) {
	req := m.activeUIRequest
	m.activeUIRequest = nil
	m.items = append(m.items, ChatItem{
		Kind:      ItemSystem,
		Text:      fmt.Sprintf("Permission Request [%s] -> %s", req.Title, strings.ToUpper(decision)),
		Done:      true,
		Timestamp: time.Now(),
	})
	m.refreshViewport()

	if m.cfg.Client == nil {
		return m, nil
	}
	client := m.cfg.Client
	reqID := req.RequestID
	return m, func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := client.RespondUI(ctx, reqID, decision); err != nil {
			return rpcErrorMsg{err: err}
		}
		return nil
	}
}

func (m Model) handleSubmit(text string, mode string) (tea.Model, tea.Cmd) {
	// Handle local TUI slash commands immediately or forward to SuperPi.AGY.Extensions.SlashCommands
	switch {
	case text == "/clear":
		m.items = nil
		m.refreshViewport()
		return m, nil

	case text == "/help":
		var sb strings.Builder
		sb.WriteString("### Antigravity TUI Shortcuts & Commands\n")
		sb.WriteString("- `Enter` — Submit prompt (`queue` mode)\n")
		sb.WriteString("- `Ctrl+S` — Preempt active tool/stream (`steer` mode)\n")
		sb.WriteString("- `Alt+Enter` / `Ctrl+J` — Insert newline in composer\n")
		sb.WriteString("- `Tab` / `Up` / `Down` — Navigate `/slash` and `@file` autocomplete\n")
		sb.WriteString("- `Ctrl+T` — Toggle collapsible Thinking blocks\n")
		sb.WriteString("- `Ctrl+O` — Toggle collapsible Tool call blocks\n")
		sb.WriteString("- `PgUp` / `PgDn` — Scroll conversation viewport\n")
		for _, sc := range defaultSlashCommands {
			sb.WriteString(fmt.Sprintf("- `%s` — %s\n", sc.Name, sc.Description))
		}
		m.items = append(m.items, ChatItem{
			Kind:      ItemSystem,
			Text:      sb.String(),
			Done:      true,
			Timestamp: time.Now(),
		})
		m.refreshViewport()
		return m, nil

	case text == "/model":
		idx := slices.Index(availableModels, m.cfg.Model)
		nextModel := availableModels[(idx+1)%len(availableModels)]
		m.cfg.Model = nextModel
		text = "/model " + nextModel

	case text == "/mode":
		idx := slices.Index(availableModes, m.cfg.Mode)
		nextMode := availableModes[(idx+1)%len(availableModes)]
		m.cfg.Mode = nextMode
		text = "/mode " + nextMode

	case strings.HasPrefix(text, "/model "):
		m.cfg.Model = strings.TrimSpace(strings.TrimPrefix(text, "/model "))

	case strings.HasPrefix(text, "/mode "):
		m.cfg.Mode = strings.TrimSpace(strings.TrimPrefix(text, "/mode "))

	case text == "/plan":
		m.cfg.Mode = "plan"

	case text == "/boost":
		m.cfg.Effort = "max"

	case text == "/compact":
		if m.cfg.Client != nil {
			client := m.cfg.Client
			convID := m.cfg.ConversationID
			return m, func() tea.Msg {
				ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
				defer cancel()
				res, err := client.CompactSession(ctx, convID)
				if err != nil {
					return rpcErrorMsg{err: err}
				}
				return WatchMsg(rpc.WatchEvent{
					Type:   "system_notice",
					Output: fmt.Sprintf("Compacted %d entries (kept %d recent). Head entry #%d.", res.CompactedCount, res.KeptCount, res.HeadEntryID),
				})
			}
		}
	}

	badge := ""
	if mode == "steer" {
		badge = " [STEER PREEMPT]"
	}

	m.items = append(m.items, ChatItem{
		Kind:      ItemUser,
		Text:      text + badge,
		Done:      true,
		Timestamp: time.Now(),
	})
	m.refreshViewport()

	if m.cfg.Client == nil {
		return m, nil
	}

	client := m.cfg.Client
	convID := m.cfg.ConversationID
	return m, func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := client.SubmitAsync(ctx, convID, text, mode); err != nil {
			return rpcErrorMsg{err: err}
		}
		return nil
	}
}

func (m *Model) applyWatchEvent(ev rpc.WatchEvent) {
	if ev.Seq > m.seq {
		m.seq = ev.Seq
	}

	switch ev.Type {
	case "state_changed":
		if ev.Status != "" {
			m.machineState = ev.Status
		}

	case "thinking_delta":
		if len(m.items) > 0 && m.items[len(m.items)-1].Kind == ItemThinking && !m.items[len(m.items)-1].Done {
			m.items[len(m.items)-1].Text += ev.Delta
		} else {
			m.items = append(m.items, ChatItem{
				Kind:      ItemThinking,
				Text:      ev.Delta,
				Timestamp: time.Now(),
			})
		}

	case "text_delta":
		// Mark any open thinking block as done
		for i := range m.items {
			if m.items[i].Kind == ItemThinking {
				m.items[i].Done = true
			}
		}
		if len(m.items) > 0 && m.items[len(m.items)-1].Kind == ItemAssistant && !m.items[len(m.items)-1].Done {
			m.items[len(m.items)-1].Text += ev.Delta
		} else {
			m.items = append(m.items, ChatItem{
				Kind:      ItemAssistant,
				Text:      ev.Delta,
				Timestamp: time.Now(),
			})
		}

	case "tool_started":
		m.items = append(m.items, ChatItem{
			Kind:            ItemTool,
			ToolCallID:      ev.ToolCallID,
			ToolName:        ev.Name,
			Arguments:       ev.Arguments,
			OverwrittenKeys: ev.OverwrittenKeys,
			Done:            false,
			Timestamp:       time.Now(),
		})

	case "tool_completed":
		updated := false
		for i := len(m.items) - 1; i >= 0; i-- {
			if m.items[i].Kind == ItemTool && m.items[i].ToolCallID == ev.ToolCallID {
				m.items[i].Text = ev.Output
				m.items[i].IsError = ev.IsError
				m.items[i].Done = true
				updated = true
				break
			}
		}
		if !updated {
			m.items = append(m.items, ChatItem{
				Kind:       ItemTool,
				ToolCallID: ev.ToolCallID,
				ToolName:   ev.Name,
				Text:       ev.Output,
				IsError:    ev.IsError,
				Done:       true,
				Timestamp:  time.Now(),
			})
		}

	case "tool_blocked":
		m.items = append(m.items, ChatItem{
			Kind:       ItemTool,
			ToolCallID: ev.ToolCallID,
			ToolName:   ev.Name,
			Text:       "Blocked: " + ev.Reason,
			IsError:    true,
			Done:       true,
			Timestamp:  time.Now(),
		})

	case "turn_completed":
		m.machineState = "idle"
		// If no streaming text_delta arrived, populate assistant message from turn_completed result
		hasOpenAssistant := false
		for i := range m.items {
			if m.items[i].Kind == ItemAssistant && !m.items[i].Done {
				hasOpenAssistant = true
			}
			m.items[i].Done = true
		}
		if !hasOpenAssistant && len(ev.Result) > 0 {
			if fallback := extractTextFromResult(ev.Result); fallback != "" {
				m.items = append(m.items, ChatItem{
					Kind:      ItemAssistant,
					Text:      fallback,
					Done:      true,
					Timestamp: time.Now(),
				})
			}
		}

	case "turn_error":
		m.machineState = "idle"
		m.items = append(m.items, ChatItem{
			Kind:      ItemSystem,
			Text:      "Turn Error: " + ev.Error,
			IsError:   true,
			Done:      true,
			Timestamp: time.Now(),
		})

	case "system_notice":
		m.items = append(m.items, ChatItem{
			Kind:      ItemSystem,
			Text:      ev.Output,
			Done:      true,
			Timestamp: time.Now(),
		})
	}
}

func (m *Model) updateAutocomplete() {
	val := m.composer.Value()
	m.suggestions = nil
	m.fileSuggestions = nil

	if strings.HasPrefix(val, "/") && !strings.Contains(val, " ") {
		prefix := strings.ToLower(strings.TrimSpace(val))
		for _, sc := range defaultSlashCommands {
			if strings.HasPrefix(sc.Name, prefix) {
				m.suggestions = append(m.suggestions, sc)
			}
		}
		if m.selectedSuggest >= len(m.suggestions) {
			m.selectedSuggest = 0
		}
		return
	}

	// Check for @file autocomplete token at end of composer
	if _, after, ok := strings.CutLast(val, "@"); ok && !strings.ContainsAny(after, " \n\t") {
		query := strings.ToLower(after)
		for _, f := range m.workspaceFiles {
			if query == "" || strings.Contains(strings.ToLower(f), query) {
				m.fileSuggestions = append(m.fileSuggestions, f)
				if len(m.fileSuggestions) >= 6 {
					break
				}
			}
		}
		if m.selectedSuggest >= len(m.fileSuggestions) {
			m.selectedSuggest = 0
		}
	}
}

func (m *Model) replaceTrailingAtToken(filePath string) {
	val := m.composer.Value()
	if before, _, ok := strings.CutLast(val, "@"); ok {
		m.composer.SetValue(before + "@" + filePath + " ")
		m.composer.CursorEnd()
	}
}

func (m *Model) recalculateLayout() {
	innerW := max(m.width-4, 36)
	m.composer.SetWidth(innerW)
	vpHeight := max(m.height-10, 6)
	m.viewport.Width = m.width - 2
	m.viewport.Height = vpHeight
}

func (m *Model) refreshViewport() {
	var blocks []string
	contentWidth := max(m.width-8, 36)

	userBadge := lipgloss.NewStyle().
		Bold(true).
		Foreground(lipgloss.Color("#0F172A")).
		Background(lipgloss.Color("#38BDF8")).
		Padding(0, 1)

	assistantBadge := lipgloss.NewStyle().
		Bold(true).
		Foreground(lipgloss.Color("#0F172A")).
		Background(lipgloss.Color("#A78BFA")).
		Padding(0, 1)

	thinkingStyle := lipgloss.NewStyle().
		Foreground(lipgloss.Color("#94A3B8")).
		Italic(true).
		Border(lipgloss.NormalBorder(), false, false, false, true).
		BorderForeground(lipgloss.Color("#475569")).
		PaddingLeft(1)

	toolBoxStyle := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(lipgloss.Color("#334155")).
		Padding(0, 1).
		Width(contentWidth)

	errBoxStyle := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(lipgloss.Color("#EF4444")).
		Foreground(lipgloss.Color("#FCA5A5")).
		Padding(0, 1).
		Width(contentWidth)

	sysStyle := lipgloss.NewStyle().
		Foreground(lipgloss.Color("#64748B"))

	for _, item := range m.items {
		switch item.Kind {
		case ItemUser:
			header := userBadge.Render("YOU")
			body := lipgloss.NewStyle().Foreground(lipgloss.Color("#F8FAFC")).PaddingLeft(1).Render(item.Text)
			blocks = append(blocks, header+"\n"+body)

		case ItemThinking:
			if m.collapseThinking {
				blocks = append(blocks, thinkingStyle.Render("💭 Thinking (collapsed — press Ctrl+T to expand)"))
			} else {
				status := "💭 Thinking..."
				if item.Done {
					status = "💭 Thought process"
				}
				blocks = append(blocks, thinkingStyle.Render(status+"\n"+strings.TrimSpace(item.Text)))
			}

		case ItemAssistant:
			header := assistantBadge.Render("ANTIGRAVITY")
			rendered := item.Text
			if m.mdRenderer != nil && item.Done {
				if out, err := m.mdRenderer.Render(item.Text); err == nil {
					rendered = strings.TrimSpace(out)
				}
			}
			blocks = append(blocks, header+"\n"+rendered)

		case ItemTool:
			icon := "⚙"
			if item.Done {
				if item.IsError {
					icon = "✗"
				} else {
					icon = "✓"
				}
			}
			overwriteBadge := ""
			if len(item.OverwrittenKeys) > 0 {
				overwriteBadge = fmt.Sprintf(" [Hook Rewrote: %s]", strings.Join(item.OverwrittenKeys, ", "))
			}
			title := fmt.Sprintf("%s Tool: %s%s", icon, item.ToolName, overwriteBadge)
			if m.collapseTools && item.Done {
				blocks = append(blocks, sysStyle.Render(title+" (collapsed — press Ctrl+O to expand)"))
				continue
			}
			body := strings.TrimSpace(item.Text)
			if body == "" && !item.Done {
				body = "Running in 4-layer SandboxRunner..."
			}
			lines := strings.Split(body, "\n")
			if len(lines) > 12 {
				body = strings.Join(lines[:12], "\n") + fmt.Sprintf("\n... (%d more lines)", len(lines)-12)
			}
			box := toolBoxStyle
			if item.IsError {
				box = errBoxStyle
			}
			blocks = append(blocks, box.Render(lipgloss.NewStyle().Bold(true).Render(title)+"\n"+body))

		case ItemSystem:
			if item.IsError {
				blocks = append(blocks, errBoxStyle.Render(item.Text))
			} else {
				blocks = append(blocks, sysStyle.Render("• "+item.Text))
			}
		}
	}

	m.viewport.SetContent(strings.Join(blocks, "\n\n"))
	m.viewport.GotoBottom()
}

// View renders the full-screen Antigravity TUI layout.
func (m Model) View() string {
	header := m.renderHeaderBar()
	body := m.viewport.View()
	popup := m.renderPopupOrModal()
	composer := m.renderComposerBox()
	footer := m.renderFooterBar()

	parts := []string{header, body}
	if popup != "" {
		parts = append(parts, popup)
	}
	parts = append(parts, composer, footer)
	return lipgloss.JoinVertical(lipgloss.Left, parts...)
}

func (m Model) renderHeaderBar() string {
	titleStyle := lipgloss.NewStyle().
		Bold(true).
		Foreground(lipgloss.Color("#0F172A")).
		Background(lipgloss.Color("#38BDF8")).
		Padding(0, 1)

	pillStyle := lipgloss.NewStyle().
		Foreground(lipgloss.Color("#E2E8F0")).
		Background(lipgloss.Color("#1E293B")).
		Padding(0, 1)

	modeColor := lipgloss.Color("#22C55E")
	if m.cfg.Mode == "plan" {
		modeColor = lipgloss.Color("#F59E0B")
	}
	modePill := lipgloss.NewStyle().
		Bold(true).
		Foreground(lipgloss.Color("#0F172A")).
		Background(modeColor).
		Padding(0, 1).
		Render("MODE: " + strings.ToUpper(m.cfg.Mode))

	stateStr := m.machineState
	if stateStr != "idle" {
		stateStr = m.spin.View() + " " + stateStr
	} else {
		stateStr = "● idle"
	}

	left := lipgloss.JoinHorizontal(
		lipgloss.Center,
		titleStyle.Render("⚡ SUPER-AGY"),
		" ",
		pillStyle.Render(fmt.Sprintf("conv #%d (seq %d)", m.cfg.ConversationID, m.seq)),
		" ",
		pillStyle.Render(m.cfg.Model+" ("+m.cfg.Effort+")"),
		" ",
		modePill,
	)

	right := pillStyle.Render(stateStr)
	gap := max(m.width-lipgloss.Width(left)-lipgloss.Width(right)-2, 1)

	return lipgloss.NewStyle().
		Width(m.width).
		Background(lipgloss.Color("#0F172A")).
		Render(left + strings.Repeat(" ", gap) + right)
}

func (m Model) renderPopupOrModal() string {
	if m.activeUIRequest != nil {
		modalStyle := lipgloss.NewStyle().
			Border(lipgloss.DoubleBorder()).
			BorderForeground(lipgloss.Color("#F59E0B")).
			Padding(0, 2).
			Width(max(m.width-4, 40))

		content := fmt.Sprintf(
			"⚠ PERMISSION REQUIRED: %s\n%s\n\n[y] Allow Once   [a] Always Allow   [n] Deny",
			m.activeUIRequest.Title,
			m.activeUIRequest.Prompt,
		)
		return modalStyle.Render(content)
	}

	if len(m.suggestions) > 0 {
		var rows []string
		for i, sc := range m.suggestions {
			prefix := "  "
			style := lipgloss.NewStyle().Foreground(lipgloss.Color("#94A3B8"))
			if i == m.selectedSuggest {
				prefix = "▸ "
				style = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#38BDF8"))
			}
			rows = append(rows, style.Render(fmt.Sprintf("%s%-12s %s", prefix, sc.Name, sc.Description)))
		}
		return lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(lipgloss.Color("#38BDF8")).
			Padding(0, 1).
			Render(strings.Join(rows, "\n"))
	}

	if len(m.fileSuggestions) > 0 {
		var rows []string
		for i, f := range m.fileSuggestions {
			prefix := "  "
			style := lipgloss.NewStyle().Foreground(lipgloss.Color("#94A3B8"))
			if i == m.selectedSuggest {
				prefix = "▸ "
				style = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#A78BFA"))
			}
			rows = append(rows, style.Render(fmt.Sprintf("%s@%s", prefix, f)))
		}
		return lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(lipgloss.Color("#A78BFA")).
			Padding(0, 1).
			Render(strings.Join(rows, "\n"))
	}

	return ""
}

func (m Model) renderComposerBox() string {
	borderColor := lipgloss.Color("#38BDF8")
	if m.cfg.Mode == "plan" {
		borderColor = lipgloss.Color("#F59E0B")
	}
	return lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(borderColor).
		Padding(0, 1).
		Width(max(m.width-2, 38)).
		Render(m.composer.View())
}

func (m Model) renderFooterBar() string {
	acked := int64(0)
	if m.cfg.Client != nil {
		acked = m.cfg.Client.AckedBatches()
	}
	help := fmt.Sprintf(
		" Enter: send • Ctrl+S: steer preempt • /commands • @files • Ctrl+T: thinking (%v) • Ctrl+O: tools (%v) • K=2 acks: %d • Esc: quit",
		!m.collapseThinking,
		!m.collapseTools,
		acked,
	)
	return lipgloss.NewStyle().
		Foreground(lipgloss.Color("#64748B")).
		Width(m.width).
		Render(help)
}

func extractTextFromResult(raw jsontext.Value) string {
	var payload struct {
		Content []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"content"`
	}
	if err := json.Unmarshal(raw, &payload); err == nil {
		var parts []string
		for _, b := range payload.Content {
			if b.Type == "text" && b.Text != "" {
				parts = append(parts, b.Text)
			}
		}
		return strings.Join(parts, "\n")
	}
	return ""
}

func scanWorkspaceFiles(root string, limit int) []string {
	var out []string
	_ = filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		name := d.Name()
		if d.IsDir() {
			if name == ".git" || name == "_build" || name == "deps" || name == "node_modules" || name == ".elixir_ls" {
				return filepath.SkipDir
			}
			return nil
		}
		rel, err := filepath.Rel(root, path)
		if err == nil {
			out = append(out, rel)
		}
		if len(out) >= limit {
			return filepath.SkipAll
		}
		return nil
	})
	slices.Sort(out)
	return out
}
