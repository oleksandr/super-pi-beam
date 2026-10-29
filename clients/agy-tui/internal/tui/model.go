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
	"github.com/oleksandr/super-pi-beam/clients/agy-tui/internal/banner"
	"github.com/oleksandr/super-pi-beam/clients/agy-tui/internal/diff"
	"github.com/oleksandr/super-pi-beam/clients/agy-tui/internal/panels"
	"github.com/oleksandr/super-pi-beam/clients/agy-tui/internal/rpc"
)

type StepKind string

const (
	StepUser      StepKind = "user"
	StepAssistant StepKind = "assistant"
	StepThinking  StepKind = "thinking"
	StepCommand   StepKind = "command"
	StepExplore   StepKind = "explore"
	StepEdit      StepKind = "edit"
	StepNotice    StepKind = "notice"
)

// StepItem represents a bullet step or message in the scrollback.
type StepItem struct {
	Kind            StepKind
	Text            string
	ToolName        string
	Path            string
	Command         string
	Diff            *diff.DiffBlock
	Duration        time.Duration
	Tokens          int
	IsError         bool
	Done            bool
	Collapsed       bool
	OverwrittenKeys []string
	Timestamp       time.Time
}

// ActivePanel designates any open interactive subview mounted below the composer.
type ActivePanel int

const (
	PanelNone ActivePanel = iota
	PanelModelPicker
	PanelHelp
	PanelUsage
	PanelPermission
)

type SlashEntry struct {
	Name        string
	Description string
	Action      string
}

var allSlashEntries = []SlashEntry{
	{Name: "/add-dir", Description: "Add a directory to the workspace"},
	{Name: "/agents", Description: "List available custom agents"},
	{Name: "/artifact", Description: "View and review artifacts"},
	{Name: "/btw", Description: "Ask a side question without interrupting the current task"},
	{Name: "/changelog", Description: "Show release notes and changes"},
	{Name: "/clear", Description: "Clear conversation and start a new one"},
	{Name: "/context", Description: "Visualize current context usage"},
	{Name: "/diff", Description: "View uncommitted changes and per-turn diffs"},
	{Name: "/effort", Description: "Set the reasoning effort (low|medium|high|max)"},
	{Name: "/exit", Description: "Exit the CLI"},
	{Name: "/fork", Description: "Create a branch of the current conversation"},
	{Name: "/help", Description: "Show available commands and keybindings"},
	{Name: "/hooks", Description: "Manage hook configurations for tool events"},
	{Name: "/keybindings", Description: "Set custom keybindings"},
	{Name: "/mcp", Description: "Manage MCP servers"},
	{Name: "/model", Description: "Set a model, or run a single prompt on another model"},
	{Name: "/open", Description: "Open a file or view opened/edited files"},
	{Name: "/permissions", Description: "Manage tool permissions"},
	{Name: "/plugin", Description: "Manage plugins"},
	{Name: "/resume", Description: "Browse and resume past conversations"},
	{Name: "/rewind", Description: "Rewind conversation to a previous message"},
	{Name: "/skills", Description: "List available skills"},
	{Name: "/usage", Description: "View model quota usage"},
	{Name: "/plan", Description: "Plan carefully before executing a task"},
	{Name: "/goal", Description: "Run until the specified goal is completely finished"},
	{Name: "/boost", Description: "Invoke Boost multi-agent orchestrator"},
	{Name: "/compact", Description: "Compact conversation now"},
}

// Config holds initial session settings for the TUI.
type Config struct {
	Client         *rpc.Client
	ConversationID int64
	Model          string
	Effort         string
	Mode           string
	WorkspaceDir   string
	InitialPrompt  string
}

// WatchMsg wraps rpc.WatchEvent for the Bubble Tea loop.
type WatchMsg rpc.WatchEvent

// UIRequestMsg wraps rpc.UIRequestParams for the Bubble Tea loop.
type UIRequestMsg rpc.UIRequestParams

type rpcErrorMsg struct{ err error }

type submitMsg struct {
	text string
	mode string
}

// agySpinner is the exact 8-frame cyan braille spinner used by antigravity CLI.
var agySpinner = spinner.Spinner{
	Frames: []string{"⣷", "⣯", "⣟", "⡿", "⢿", "⣻", "⣽", "⣾"},
	FPS:    time.Second / 12,
}

// Model implements the exact inline Bubble Tea TUI for Super-Pi-BEAM.
type Model struct {
	cfg              Config
	composer         textarea.Model
	viewport         viewport.Model
	spin             spinner.Model
	mdRenderer       *glamour.TermRenderer
	width            int
	height           int
	steps            []StepItem
	activePanel      ActivePanel
	panelCursor      int
	helpTab          int
	activeUIRequest  *rpc.UIRequestParams
	suggestions      []SlashEntry
	fileSuggestions  []string
	selectedSuggest  int
	workspaceFiles   []string
	showTrajectory   bool
	machineState     string
	inFlightStepText string
	isBusy           bool
	activityLabel    string
}

// NewModel constructs an inline agy-class model with the SuperPi logo.
func NewModel(cfg Config) Model {
	ta := textarea.New()
	ta.Placeholder = ""
	ta.Focus()
	ta.Prompt = lipgloss.NewStyle().Foreground(lipgloss.Color("#60A5FA")).Render("> ")
	ta.CharLimit = 32768
	ta.SetWidth(100)
	ta.SetHeight(1)
	ta.ShowLineNumbers = false
	ta.KeyMap.InsertNewline.SetKeys("alt+enter", "ctrl+j", "shift+enter")

	sp := spinner.New()
	sp.Spinner = agySpinner
	sp.Style = lipgloss.NewStyle().Foreground(lipgloss.Color("#38BDF8"))

	vp := viewport.New(100, 25)
	vp.MouseWheelEnabled = true
	vp.MouseWheelDelta = 3

	md, _ := glamour.NewTermRenderer(
		glamour.WithStandardStyle("dark"),
		glamour.WithWordWrap(96),
	)

	wsDir := cmp.Or(cfg.WorkspaceDir, ".")
	files := scanWorkspaceFiles(wsDir, 150)

	m := Model{
		cfg: Config{
			Client:         cfg.Client,
			ConversationID: cfg.ConversationID,
			Model:          cmp.Or(cfg.Model, "Gemini 3.8 Flash"),
			Effort:         cmp.Or(cfg.Effort, "medium"),
			Mode:           cmp.Or(cfg.Mode, "auto"),
			WorkspaceDir:   wsDir,
			InitialPrompt:  cfg.InitialPrompt,
		},
		composer:       ta,
		viewport:       vp,
		spin:           sp,
		mdRenderer:     md,
		width:          100,
		height:         35,
		steps:          nil,
		activePanel:    PanelNone,
		workspaceFiles: files,
		showTrajectory: false,
		machineState:   "idle",
		isBusy:         false,
		activityLabel:  "",
	}
	m.syncViewportContent()
	return m
}

// Init starts tea commands.
func (m Model) Init() tea.Cmd {
	cmds := []tea.Cmd{
		textarea.Blink,
		m.spin.Tick,
		waitForRPCEvent(m.cfg.Client),
		waitForUIRequest(m.cfg.Client),
	}
	if m.cfg.InitialPrompt != "" {
		p := m.cfg.InitialPrompt
		cmds = append(cmds, func() tea.Msg {
			return submitMsg{text: p, mode: "queue"}
		})
	}
	return tea.Batch(cmds...)
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

// calculateViewportHeight calculates exact available height for the history viewport.
func (m Model) calculateViewportHeight() int {
	h := m.height - m.composer.Height() - 3 // 3 for topRule, bottomRule, statusline
	if m.activePanel != PanelNone {
		switch m.activePanel {
		case PanelModelPicker:
			h -= 14
		case PanelHelp:
			h -= 16
		case PanelUsage:
			h -= 8
		case PanelPermission:
			h -= 9
		}
	} else if len(m.suggestions) > 0 {
		h -= min(len(m.suggestions), 5) + 2
	} else if len(m.fileSuggestions) > 0 {
		h -= min(len(m.fileSuggestions), 5) + 2
	}
	if !m.viewport.AtBottom() && m.viewport.TotalLineCount() > h {
		h -= 1
	}
	return max(h, 4)
}

// syncViewportContent re-renders history steps and updates the viewport.
func (m *Model) syncViewportContent() {
	var sections []string

	// 1. Initial Hero Banner if conversation is empty
	if len(m.steps) == 0 {
		sections = append(sections, banner.Render(banner.Config{
			Version:      "1.0.0 (OTP 28.4 / Elixir 1.20)",
			UserAccount:  "Durable BEAM Harness (SQLite WAL)",
			ModelDisplay: fmt.Sprintf("%s (%s)", m.cfg.Model, strings.Title(m.cfg.Effort)),
			Workspace:    m.cfg.WorkspaceDir,
		}))
	}

	// 2. Render steps in scrollback
	for _, s := range m.steps {
		sections = append(sections, m.renderStepItem(s))
	}

	// 3. In-flight activity indicator
	if m.isBusy && m.activityLabel != "" {
		sections = append(sections, fmt.Sprintf("%s  %s", m.spin.View(), m.activityLabel))
	}

	rendered := strings.Join(sections, "\n\n")

	wasAtBottom := m.viewport.AtBottom() || m.viewport.TotalLineCount() == 0
	m.viewport.SetContent(rendered)
	if wasAtBottom {
		m.viewport.GotoBottom()
	}
}

// Update processes keystrokes, mouse wheel scrolling, and streaming events.
func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	var cmds []tea.Cmd

	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = max(msg.Width, 50)
		m.height = max(msg.Height, 15)
		m.composer.SetWidth(max(m.width-4, 40))
		m.viewport.Width = m.width
		m.viewport.Height = m.calculateViewportHeight()
		m.syncViewportContent()
		return m, nil

	case spinner.TickMsg:
		var cmd tea.Cmd
		m.spin, cmd = m.spin.Update(msg)
		if m.isBusy {
			m.syncViewportContent()
		}
		return m, cmd

	case tea.MouseMsg:
		switch msg.Type {
		case tea.MouseWheelUp:
			m.viewport.LineUp(3)
			return m, nil
		case tea.MouseWheelDown:
			m.viewport.LineDown(3)
			return m, nil
		}
		var cmd tea.Cmd
		m.viewport, cmd = m.viewport.Update(msg)
		return m, cmd

	case submitMsg:
		return m.handleSubmit(msg.text, msg.mode)

	case WatchMsg:
		m.applyWatchEvent(rpc.WatchEvent(msg))
		cmds = append(cmds, waitForRPCEvent(m.cfg.Client))
		return m, tea.Batch(cmds...)

	case UIRequestMsg:
		req := rpc.UIRequestParams(msg)
		m.activeUIRequest = &req
		m.activePanel = PanelPermission
		m.viewport.Height = m.calculateViewportHeight()
		cmds = append(cmds, waitForUIRequest(m.cfg.Client))
		return m, tea.Batch(cmds...)

	case rpcErrorMsg:
		m.isBusy = false
		m.activityLabel = ""
		m.steps = append(m.steps, StepItem{
			Kind:      StepNotice,
			Text:      fmt.Sprintf("RPC Error: %v", msg.err),
			IsError:   true,
			Done:      true,
			Timestamp: time.Now(),
		})
		m.syncViewportContent()
		return m, nil

	case tea.KeyMsg:
		// Active panel keystroke interceptors
		if m.activePanel != PanelNone {
			switch msg.String() {
			case "esc", "ctrl+c":
				m.closePanel()
				return m, nil
			}

			switch m.activePanel {
			case PanelModelPicker:
				switch msg.String() {
				case "up":
					m.panelCursor = (m.panelCursor - 1 + len(panels.DefaultModels)) % len(panels.DefaultModels)
					return m, nil
				case "down":
					m.panelCursor = (m.panelCursor + 1) % len(panels.DefaultModels)
					return m, nil
				case "left":
					m.cycleEffort(-1)
					return m, nil
				case "right":
					m.cycleEffort(1)
					return m, nil
				case "enter":
					chosen := panels.DefaultModels[m.panelCursor]
					m.cfg.Model = chosen.DisplayName
					m.steps = append(m.steps, StepItem{
						Kind:      StepNotice,
						Text:      fmt.Sprintf("> /model\n  ⎿  Model set to %s (%s)", chosen.DisplayName, strings.Title(m.cfg.Effort)),
						Done:      true,
						Timestamp: time.Now(),
					})
					m.activePanel = PanelNone
					m.viewport.Height = m.calculateViewportHeight()
					m.syncViewportContent()
					return m, nil
				}

			case PanelHelp:
				switch msg.String() {
				case "tab", "right":
					m.helpTab = (m.helpTab + 1) % 3
					return m, nil
				case "left":
					m.helpTab = (m.helpTab - 1 + 3) % 3
					return m, nil
				}

			case PanelPermission:
				switch msg.String() {
				case "1", "y", "enter":
					return m.resolvePermission("allow")
				case "2", "a":
					return m.resolvePermission("always_allow_session")
				case "3":
					return m.resolvePermission("always_allow_persist")
				case "4", "n":
					return m.resolvePermission("deny")
				}
			}
		}

		// Scrolling keys: support shift+up/down, pageup/pagedown, ctrl+home/end
		switch msg.String() {
		case "shift+up", "\x1b[1;2A", "pgup", "pageup", "\x1b[5~":
			m.viewport.HalfViewUp()
			return m, nil

		case "shift+down", "\x1b[1;2B", "pgdown", "pagedown", "\x1b[6~":
			m.viewport.HalfViewDown()
			return m, nil

		case "ctrl+home", "\x1b[1;5H":
			m.viewport.GotoTop()
			return m, nil

		case "ctrl+end", "\x1b[1;5F":
			m.viewport.GotoBottom()
			return m, nil

		case "esc":
			if m.isBusy {
				m.isBusy = false
				m.activityLabel = ""
				m.inFlightStepText = ""
				m.steps = append(m.steps, StepItem{
					Kind:      StepNotice,
					Text:      "Turn cancelled by user.",
					Done:      true,
					Timestamp: time.Now(),
				})
				m.syncViewportContent()
				if m.cfg.Client != nil {
					client := m.cfg.Client
					convID := m.cfg.ConversationID
					return m, func() tea.Msg {
						ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
						defer cancel()
						_ = client.CancelSession(ctx, convID)
						return nil
					}
				}
				return m, nil
			}

		case "ctrl+c":
			return m, tea.Quit

		case "ctrl+d":
			if strings.TrimSpace(m.composer.Value()) == "" {
				return m, tea.Quit
			}

		case "ctrl+o":
			m.showTrajectory = !m.showTrajectory
			m.syncViewportContent()
			return m, nil

		case "?":
			if strings.TrimSpace(m.composer.Value()) == "" && !m.isBusy {
				m.activePanel = PanelHelp
				m.helpTab = 2 // shortcuts tab
				m.viewport.Height = m.calculateViewportHeight()
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

		case "enter":
			text := strings.TrimSpace(m.composer.Value())
			if text != "" {
				m.composer.Reset()
				m.updateAutocomplete()
				return m.handleSubmit(text, "queue")
			}
			return m, nil
		}

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
	// Auto-expand composer lines (1 to 6)
	lines := strings.Count(m.composer.Value(), "\n") + 1
	m.composer.SetHeight(min(max(lines, 1), 6))
	m.updateAutocomplete()
	m.viewport.Height = m.calculateViewportHeight()
	cmds = append(cmds, taCmd)

	return m, tea.Batch(cmds...)
}

func (m *Model) closePanel() {
	cmdName := ""
	switch m.activePanel {
	case PanelModelPicker:
		cmdName = "/model"
	case PanelHelp:
		cmdName = "/help"
	case PanelUsage:
		cmdName = "/usage"
	}
	m.activePanel = PanelNone
	m.viewport.Height = m.calculateViewportHeight()
	if cmdName != "" {
		m.steps = append(m.steps, StepItem{
			Kind:      StepNotice,
			Text:      fmt.Sprintf("> %s\n  ⎿  Exited %s command", cmdName, cmdName),
			Done:      true,
			Timestamp: time.Now(),
		})
		m.syncViewportContent()
	}
}

func (m *Model) cycleEffort(dir int) {
	levels := []string{"low", "medium", "high"}
	idx := slices.Index(levels, m.cfg.Effort)
	if idx == -1 {
		idx = 1
	}
	next := (idx + dir + len(levels)) % len(levels)
	m.cfg.Effort = levels[next]
}

func (m Model) resolvePermission(decision string) (tea.Model, tea.Cmd) {
	req := m.activeUIRequest
	m.activeUIRequest = nil
	m.activePanel = PanelNone
	m.viewport.Height = m.calculateViewportHeight()
	m.steps = append(m.steps, StepItem{
		Kind:      StepNotice,
		Text:      fmt.Sprintf("Permission: %s -> %s", req.Title, strings.ToUpper(decision)),
		Done:      true,
		Timestamp: time.Now(),
	})
	m.syncViewportContent()

	if m.cfg.Client == nil {
		return m, nil
	}
	client := m.cfg.Client
	reqID := req.RequestID
	return m, func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = client.RespondUI(ctx, reqID, decision)
		return nil
	}
}

func (m Model) handleSubmit(text string, mode string) (tea.Model, tea.Cmd) {
	// Handle slash commands that open specialized panels
	switch text {
	case "/model":
		m.activePanel = PanelModelPicker
		m.panelCursor = 0
		m.viewport.Height = m.calculateViewportHeight()
		return m, nil
	case "/help":
		m.activePanel = PanelHelp
		m.helpTab = 0
		m.viewport.Height = m.calculateViewportHeight()
		return m, nil
	case "/usage", "/credits", "/context":
		m.activePanel = PanelUsage
		m.viewport.Height = m.calculateViewportHeight()
		return m, nil
	case "/clear":
		m.steps = nil
		m.isBusy = false
		m.activityLabel = ""
		m.syncViewportContent()
		m.viewport.GotoTop()
		return m, nil
	case "/exit", "/quit":
		return m, tea.Quit
	case "/diff":
		m.showTrajectory = true
		m.syncViewportContent()
		return m, nil
	}

	m.steps = append(m.steps, StepItem{
		Kind:      StepUser,
		Text:      text,
		Done:      true,
		Timestamp: time.Now(),
	})
	m.isBusy = true
	m.activityLabel = "Generating..."
	m.inFlightStepText = "Generating..."
	m.syncViewportContent()
	m.viewport.GotoBottom()

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
	switch ev.Type {
	case "state_changed":
		m.machineState = ev.Status
		switch ev.Status {
		case "preparing_request":
			m.isBusy = true
			m.activityLabel = "Preparing request..."
		case "streaming_llm":
			m.isBusy = true
			if m.activityLabel == "" || m.activityLabel == "Preparing request..." {
				m.activityLabel = "Generating..."
			}
		case "executing_tools":
			m.isBusy = true
		case "idle":
			m.isBusy = false
			m.activityLabel = ""
			m.inFlightStepText = ""
		}

	case "thinking_delta":
		m.isBusy = true
		m.activityLabel = "Thinking..."
		if len(m.steps) > 0 && m.steps[len(m.steps)-1].Kind == StepThinking && !m.steps[len(m.steps)-1].Done {
			m.steps[len(m.steps)-1].Text += ev.Delta
		} else {
			m.steps = append(m.steps, StepItem{
				Kind:      StepThinking,
				Text:      ev.Delta,
				Timestamp: time.Now(),
			})
		}

	case "text_delta":
		m.isBusy = true
		m.activityLabel = "Generating..."
		// Mark open thinking block as done
		for i := range m.steps {
			if m.steps[i].Kind == StepThinking {
				m.steps[i].Done = true
			}
		}
		if len(m.steps) > 0 && m.steps[len(m.steps)-1].Kind == StepAssistant && !m.steps[len(m.steps)-1].Done {
			m.steps[len(m.steps)-1].Text += ev.Delta
		} else {
			m.steps = append(m.steps, StepItem{
				Kind:      StepAssistant,
				Text:      ev.Delta,
				Timestamp: time.Now(),
			})
		}

	case "tool_started":
		m.isBusy = true
		kind := StepCommand
		label := fmt.Sprintf("Running %s...", ev.Name)
		if ev.Name == "edit" || ev.Name == "write" {
			kind = StepEdit
			label = "Editing files..."
		} else if ev.Name == "read" || ev.Name == "ls" || ev.Name == "find" || ev.Name == "grep" {
			kind = StepExplore
			label = "Searching codebase..."
		} else if ev.Name == "bash" || ev.Name == "cmd" || ev.Name == "sh" {
			kind = StepCommand
			label = "Running command..."
		}
		m.activityLabel = label
		m.inFlightStepText = label

		cmd := ""
		if c, ok := ev.Arguments["command"].(string); ok {
			cmd = c
		}
		path := ""
		if p, ok := ev.Arguments["path"].(string); ok {
			path = p
		}

		m.steps = append(m.steps, StepItem{
			Kind:            kind,
			ToolName:        ev.Name,
			Command:         cmd,
			Path:            path,
			OverwrittenKeys: ev.OverwrittenKeys,
			Done:            false,
			Timestamp:       time.Now(),
		})

	case "tool_completed":
		m.isBusy = true
		m.activityLabel = "Generating..."
		m.inFlightStepText = "Generating..."
		for i := len(m.steps) - 1; i >= 0; i-- {
			if !m.steps[i].Done && (m.steps[i].Kind == StepCommand || m.steps[i].Kind == StepEdit || m.steps[i].Kind == StepExplore) {
				m.steps[i].Done = true
				m.steps[i].IsError = ev.IsError
				m.steps[i].Text = ev.Output
				if m.steps[i].Kind == StepEdit {
					parsed := diff.ParseSimpleDiff(m.steps[i].Path, "", ev.Output)
					m.steps[i].Diff = &parsed
				}
				break
			}
		}

	case "turn_completed":
		m.isBusy = false
		m.machineState = "idle"
		m.activityLabel = ""
		m.inFlightStepText = ""
		hasOpenAssistant := false
		for i := range m.steps {
			if m.steps[i].Kind == StepAssistant && !m.steps[i].Done {
				hasOpenAssistant = true
			}
			m.steps[i].Done = true
		}
		if !hasOpenAssistant && len(ev.Result) > 0 {
			if fallback := extractTextFromResult(ev.Result); fallback != "" {
				m.steps = append(m.steps, StepItem{
					Kind:      StepAssistant,
					Text:      fallback,
					Done:      true,
					Timestamp: time.Now(),
				})
			}
		}

	case "turn_cancelled":
		m.isBusy = false
		m.machineState = "idle"
		m.activityLabel = ""
		m.inFlightStepText = ""
		for i := range m.steps {
			m.steps[i].Done = true
		}

	case "turn_error":
		m.isBusy = false
		m.machineState = "idle"
		m.activityLabel = ""
		m.inFlightStepText = ""
		m.steps = append(m.steps, StepItem{
			Kind:      StepNotice,
			Text:      "Turn Error: " + ev.Error,
			IsError:   true,
			Done:      true,
			Timestamp: time.Now(),
		})
	}
	m.syncViewportContent()
}

func (m *Model) updateAutocomplete() {
	val := m.composer.Value()
	m.suggestions = nil
	m.fileSuggestions = nil

	if strings.HasPrefix(val, "/") && !strings.Contains(val, " ") {
		prefix := strings.ToLower(strings.TrimSpace(val))
		for _, se := range allSlashEntries {
			if strings.HasPrefix(se.Name, prefix) || strings.Contains(se.Name, prefix[1:]) {
				m.suggestions = append(m.suggestions, se)
			}
		}
		if m.selectedSuggest >= len(m.suggestions) {
			m.selectedSuggest = 0
		}
		return
	}

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

// View renders the exact inline terminal layout matching agy.
func (m Model) View() string {
	rule := lipgloss.NewStyle().Foreground(lipgloss.Color("#475569")).Render(strings.Repeat("─", max(m.width, 40)))

	var sections []string

	// 1. History viewport
	sections = append(sections, m.viewport.View())

	// 2. Floating scroll hint if scrolled up
	if !m.viewport.AtBottom() && m.viewport.TotalLineCount() > m.viewport.Height {
		hint := lipgloss.NewStyle().Foreground(lipgloss.Color("#F59E0B")).Render(
			fmt.Sprintf("  ↓ Scrolled up (%d%%) · ctrl+end or shift+down to jump to bottom", int(m.viewport.ScrollPercent()*100)),
		)
		sections = append(sections, hint)
	}

	// 3. Top rule
	sections = append(sections, rule)

	// 4. Composer line
	sections = append(sections, m.composer.View())

	// 5. Bottom rule
	sections = append(sections, rule)

	// 6. Inline popup, modal, or panel below composer
	if m.activePanel != PanelNone {
		switch m.activePanel {
		case PanelModelPicker:
			sections = append(sections, panels.RenderModelPicker(m.panelCursor, m.cfg.Effort, m.width))
		case PanelHelp:
			sections = append(sections, panels.RenderHelpTabs(m.helpTab, 0, m.width))
		case PanelUsage:
			sections = append(sections, panels.RenderUsagePanel(m.cfg.Model))
		case PanelPermission:
			title := ""
			cmd := ""
			if m.activeUIRequest != nil {
				title = m.activeUIRequest.Title
				cmd = cmp.Or(m.activeUIRequest.Command, m.activeUIRequest.Prompt)
			}
			sections = append(sections, panels.RenderPermissionPrompt(title, cmd))
		}
	} else if len(m.suggestions) > 0 {
		sections = append(sections, m.renderSlashPopup())
	} else if len(m.fileSuggestions) > 0 {
		sections = append(sections, m.renderFilePopup())
	}

	// 7. Footer statusline
	sections = append(sections, m.renderStatusline())

	return strings.Join(sections, "\n")
}

func (m Model) renderStepItem(s StepItem) string {
	bulletGreen := lipgloss.NewStyle().Foreground(lipgloss.Color("#22C55E")).Render("●")
	bulletYellow := lipgloss.NewStyle().Foreground(lipgloss.Color("#EAB308")).Render("●")
	elbow := lipgloss.NewStyle().Foreground(lipgloss.Color("#64748B")).Render("  ⎿  ")

	switch s.Kind {
	case StepUser:
		return fmt.Sprintf("> %s", lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#F8FAFC")).Render(s.Text))

	case StepCommand:
		cmdText := s.Command
		if cmdText == "" {
			cmdText = s.Text
		}
		var line string
		if !s.Done {
			line = fmt.Sprintf("%s Running (%s)", bulletYellow, lipgloss.NewStyle().Foreground(lipgloss.Color("#FBBF24")).Render(cmdText))
		} else {
			line = fmt.Sprintf("%s Ran (%s)", bulletGreen, lipgloss.NewStyle().Foreground(lipgloss.Color("#FBBF24")).Render(cmdText))
		}
		if s.Done && s.Text != "" && m.showTrajectory {
			body := strings.TrimSpace(s.Text)
			lines := strings.Split(body, "\n")
			if len(lines) > 8 {
				body = strings.Join(lines[:8], "\n") + "\n            ..."
			}
			return fmt.Sprintf("%s\n%sCommand exited with code 0.\n            Command output:\n            %s", line, elbow, body)
		}
		return line

	case StepExplore:
		if !s.Done {
			return fmt.Sprintf("%s Exploring files (%s)...", bulletYellow, s.Path)
		}
		return fmt.Sprintf("%s Explored 1 file (%s)", bulletGreen, s.Path)

	case StepEdit:
		if !s.Done {
			return fmt.Sprintf("%s Editing 1 file (%s) (ctrl+o to expand)", bulletYellow, s.Path)
		}
		if s.Diff != nil && m.showTrajectory {
			return diff.Render(*s.Diff, m.width)
		}
		return fmt.Sprintf("%s Edit(%s)\n%sAdded lines (ctrl+o to expand)", bulletGreen, s.Path, elbow)

	case StepThinking:
		if !s.Done {
			return lipgloss.NewStyle().Foreground(lipgloss.Color("#94A3B8")).Render("▾ Thinking...")
		}
		dur := "3s"
		tok := "120"
		head := lipgloss.NewStyle().Foreground(lipgloss.Color("#94A3B8")).Render(fmt.Sprintf("▾ Thought for %s, %s tokens", dur, tok))
		if m.showTrajectory {
			body := lipgloss.NewStyle().Foreground(lipgloss.Color("#64748B")).Italic(true).Render("  " + strings.TrimSpace(s.Text))
			return head + "\n" + body
		}
		return head

	case StepAssistant:
		rendered := s.Text
		if m.mdRenderer != nil && s.Done {
			if out, err := m.mdRenderer.Render(s.Text); err == nil {
				rendered = strings.TrimSpace(out)
			}
		}
		return rendered

	case StepNotice:
		if s.IsError {
			return lipgloss.NewStyle().Foreground(lipgloss.Color("#EF4444")).Render(s.Text)
		}
		return lipgloss.NewStyle().Foreground(lipgloss.Color("#94A3B8")).Render(s.Text)
	}

	return s.Text
}

func (m Model) renderSlashPopup() string {
	maxShow := 5
	var rows []string
	window := m.suggestions
	if len(window) > maxShow {
		window = window[:maxShow]
	}

	for i, se := range window {
		prefix := "  "
		style := lipgloss.NewStyle().Foreground(lipgloss.Color("#94A3B8"))
		if i == m.selectedSuggest {
			prefix = "❯ "
			style = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#60A5FA"))
		}
		desc := se.Description
		if len(desc) > 60 {
			desc = desc[:60] + "..."
		}
		rows = append(rows, fmt.Sprintf("%s%-16s %s", style.Render(prefix), style.Render(se.Name), lipgloss.NewStyle().Foreground(lipgloss.Color("#64748B")).Render(desc)))
	}

	if len(m.suggestions) > maxShow {
		rows = append(rows, lipgloss.NewStyle().Foreground(lipgloss.Color("#64748B")).Render(fmt.Sprintf("   ↓ %d more", len(m.suggestions)-maxShow)))
	}

	hints := lipgloss.NewStyle().Foreground(lipgloss.Color("#64748B")).Render(
		"  " + lipgloss.NewStyle().Foreground(lipgloss.Color("#60A5FA")).Render("↑/↓") + " Navigate · " +
			lipgloss.NewStyle().Foreground(lipgloss.Color("#60A5FA")).Render("enter") + " Select · " +
			lipgloss.NewStyle().Foreground(lipgloss.Color("#60A5FA")).Render("tab") + " Complete",
	)

	return strings.Join(append(rows, "", hints), "\n")
}

func (m Model) renderFilePopup() string {
	var rows []string
	for i, f := range m.fileSuggestions {
		prefix := "  "
		style := lipgloss.NewStyle().Foreground(lipgloss.Color("#94A3B8"))
		if i == m.selectedSuggest {
			prefix = "❯ "
			style = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#A78BFA"))
		}
		rows = append(rows, fmt.Sprintf("%s@%s", prefix, style.Render(f)))
	}
	return strings.Join(rows, "\n")
}

func (m Model) renderStatusline() string {
	var left string
	if m.isBusy {
		escStyle := lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#F8FAFC"))
		textStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("#94A3B8"))
		left = escStyle.Render("esc") + textStyle.Render(" to cancel")
	} else if m.activePanel != PanelNone {
		left = lipgloss.NewStyle().Foreground(lipgloss.Color("#64748B")).Render("esc to close")
	} else {
		left = lipgloss.NewStyle().Foreground(lipgloss.Color("#64748B")).Render("? for shortcuts")
	}

	var rightParts []string
	if m.isBusy && m.activityLabel != "" {
		actStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("#38BDF8"))
		rightParts = append(rightParts, fmt.Sprintf("%s %s", m.spin.View(), actStyle.Render(m.activityLabel)))
	}
	modelInfo := fmt.Sprintf("%s · %s", m.cfg.Model, m.cfg.Effort)
	rightParts = append(rightParts, lipgloss.NewStyle().Foreground(lipgloss.Color("#64748B")).Render(modelInfo))

	right := strings.Join(rightParts, "   ")

	gap := max(m.width-lipgloss.Width(left)-lipgloss.Width(right)-2, 1)
	return left + strings.Repeat(" ", gap) + right
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
