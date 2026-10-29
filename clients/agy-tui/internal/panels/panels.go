package panels

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// ModelSpec describes a selectable model and reasoning effort.
type ModelSpec struct {
	ID          string
	DisplayName string
	Current     bool
}

// DefaultModels defines the catalog of models in SuperPi.
var DefaultModels = []ModelSpec{
	{ID: "gemini-3.8-flash", DisplayName: "Gemini 3.8 Flash"},
	{ID: "gemini-4-argon", DisplayName: "Gemini 4 Argon"},
	{ID: "claude-opus-5-5", DisplayName: "Claude Opus 5.5"},
	{ID: "claude-sonnet-5-5", DisplayName: "Claude Sonnet 5.5"},
	{ID: "gpt-oss-120b", DisplayName: "GPT-OSS 120B (Medium)"},
}

// RenderModelPicker renders the exact Switch Model screen captured from agy.
func RenderModelPicker(cursor int, effort string, width int) string {
	title := lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#F8FAFC")).Render("Switch Model")

	searchLine := "  Search: \n          " + lipgloss.NewStyle().Foreground(lipgloss.Color("#64748B")).Render("────────────────────")

	var rows []string
	for i, m := range DefaultModels {
		prefix := "  "
		style := lipgloss.NewStyle().Foreground(lipgloss.Color("#F8FAFC"))
		badge := ""
		if m.Current {
			badge = lipgloss.NewStyle().Foreground(lipgloss.Color("#64748B")).Render("       (current)")
		}
		if i == cursor {
			prefix = "❯ "
			style = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#38BDF8"))
		}
		rows = append(rows, fmt.Sprintf("%s%-20s%s", style.Render(prefix), style.Render(m.DisplayName), badge))
	}

	effortSlider := renderEffortSlider(effort)

	hints := lipgloss.NewStyle().Foreground(lipgloss.Color("#94A3B8")).Render(
		"Keyboard: " +
			lipgloss.NewStyle().Foreground(lipgloss.Color("#38BDF8")).Render("↑/↓") + " Navigate  " +
			lipgloss.NewStyle().Foreground(lipgloss.Color("#38BDF8")).Render("←/→") + " Effort  " +
			lipgloss.NewStyle().Foreground(lipgloss.Color("#38BDF8")).Render("enter") + " Select  " +
			lipgloss.NewStyle().Foreground(lipgloss.Color("#38BDF8")).Render("esc") + " Go Back",
	)

	return strings.Join([]string{
		title,
		"",
		searchLine,
		"",
		strings.Join(rows, "\n"),
		"",
		effortSlider,
		"",
		hints,
	}, "\n")
}

func renderEffortSlider(effort string) string {
	slider := "●━━━━━━━━━━━━━━◉──────────────○"
	desc := "Balanced speed and reasoning quality for most tasks"
	switch effort {
	case "low":
		slider = "◉──────────────○──────────────○"
		desc = "Fastest responses with minimal reasoning steps"
	case "high", "max":
		slider = "●──────────────○━━━━━━━━━━━━━━◉"
		desc = "Maximum reasoning depth for complex programming tasks"
	}

	arrowLeft := lipgloss.NewStyle().Foreground(lipgloss.Color("#38BDF8")).Render("◂")
	arrowRight := lipgloss.NewStyle().Foreground(lipgloss.Color("#38BDF8")).Render("▸")
	bar := lipgloss.NewStyle().Foreground(lipgloss.Color("#F59E0B")).Render(slider)

	labels := "                  low          medium          high"
	descStyled := lipgloss.NewStyle().Foreground(lipgloss.Color("#94A3B8")).Italic(true).Render("            " + desc)

	return fmt.Sprintf("  Effort  %s        %s        %s\n%s\n%s", arrowLeft, bar, arrowRight, labels, descStyled)
}

// RenderHelpTabs renders the 3-tab Help view (General, Commands, Shortcuts).
func RenderHelpTabs(activeTab int, scrollIdx int, width int) string {
	tabs := []string{"general", "commands", "shortcuts"}
	var renderedTabs []string
	for i, t := range tabs {
		if i == activeTab {
			renderedTabs = append(renderedTabs, lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#38BDF8")).Underline(true).Render(t))
		} else {
			renderedTabs = append(renderedTabs, lipgloss.NewStyle().Foreground(lipgloss.Color("#94A3B8")).Render(t))
		}
	}

	header := fmt.Sprintf(
		"%s   %s   (←/→ or tab to cycle)",
		lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#F8FAFC")).Render("Super-Pi-BEAM CLI"),
		strings.Join(renderedTabs, "    "),
	)

	hints := lipgloss.NewStyle().Foreground(lipgloss.Color("#94A3B8")).Render(
		"Keyboard: " +
			lipgloss.NewStyle().Foreground(lipgloss.Color("#38BDF8")).Render("↑/↓") + " Navigate  " +
			lipgloss.NewStyle().Foreground(lipgloss.Color("#38BDF8")).Render("←/→") + " Switch View  " +
			lipgloss.NewStyle().Foreground(lipgloss.Color("#38BDF8")).Render("esc") + " Close",
	)

	body := ""
	switch activeTab {
	case 0:
		body = `Super-Pi-BEAM understands your codebase, runs tools through isolated 4-layer
sandboxes, and executes tasks deterministically on Erlang/OTP 28.

Version 1.0.0 (OTP 28.4 / Elixir 1.20)
Engine:         SuperPi.Durable (SQLite WAL default)
RPC Server:     JSON-RPC 2.0 with K=2 ack-clocked backpressure
Extensions:     12-hook modular pipeline

Quick Reference
  /  Type / to see available commands`

	case 1:
		body = `Available Commands

  /add-dir                        Add a directory to the workspace
  /agents                         List available custom agents
  /artifact                       View and review artifacts
  /btw                            Ask a side question without interrupting the current task
  /changelog                      Show release notes and changes
  /clear (new)                    Clear conversation and start a new one
  /context                        Visualize current context usage
  /diff                           View uncommitted changes and per-turn diffs
  /effort                         Set the reasoning effort (low|medium|high|max)
  /exit (quit)                    Exit the CLI
  /fork (branch)                  Create a branch of the current conversation
  /help                           Show available commands and keybindings
  /hooks                          Manage hook configurations for tool events
  /keybindings                    Set custom keybindings
  /mcp                            Manage MCP servers
  /model                          Set a model, or run a single prompt on another model
  /open                           Open a file or view opened/edited files
  /permissions                    Manage tool permissions
  /plugin                         Manage, discover, and install plugins
  /resume                         Browse and resume past conversations
  /rewind (undo)                  Rewind conversation to a previous message
  /skills                         List available skills
  /usage                          View model quota usage
  [1-23 of 59 items]`

	case 2:
		body = `Keyboard Shortcuts
  /keybindings to customize

> /                               Open slash commands
  \ + enter                       Insert newline fallback
  alt+enter, ctrl+j, shift+enter  Insert newline
  ctrl+c, esc                     Go back / dismiss
  ctrl+d                          Exit
  ctrl+g                          Open prompt in $EDITOR
  ctrl+l                          Clear CLI screen
  ctrl+o                          Toggle trajectory / diff view
  ctrl+s                          Preempt with steer input
  ctrl+t                          Toggle thinking blocks
  enter                           Send message or confirm
  tab                             Complete autocomplete suggestion
  [1-12 of 27 items]`
	}

	return strings.Join([]string{header, "", body, "", hints}, "\n")
}

// RenderUsagePanel renders the token/quota meter from /usage.
func RenderUsagePanel(modelName string) string {
	title := lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#F8FAFC")).Render("└ Context & Quota Usage")

	bar1 := lipgloss.NewStyle().Foreground(lipgloss.Color("#22C55E")).Render("[████████████████████████████████████████████████░░] 96.0%")
	bar2 := lipgloss.NewStyle().Foreground(lipgloss.Color("#38BDF8")).Render("[███████████████████████████░░░░░░░░░░░░░░░░░░░░░░░] 54.0%")

	return strings.Join([]string{
		title,
		"",
		"GEMINI AND GPT MODELS",
		"  Five Hour Limit Remaining",
		"    " + bar1,
		"    Refreshes in 4h 12m",
		"",
		"CLAUDE OPUS AND SONNET MODELS",
		"  Weekly Limit Remaining",
		"    " + bar2,
		"    Refreshes in 120h 30m",
		"",
		"Related: /context · /artifact · /rewind",
		"  " + lipgloss.NewStyle().Foreground(lipgloss.Color("#94A3B8")).Render("esc Close"),
	}, "\n")
}

// RenderPermissionPrompt renders the numbered interactive approval menu.
func RenderPermissionPrompt(title string, cmd string) string {
	head := lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#F59E0B")).Render("Requesting permission for:")
	cmdBox := "   " + lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#F8FAFC")).Render(cmd)

	q := lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#E2E8F0")).Render("Run this command?")
	opts := []string{
		"❯ 1. Yes, run command",
		"  2. Yes, and always allow in this conversation for commands that start with this prefix",
		"  3. Yes, and always allow (Persist to settings.json)",
		"  4. No, cancel",
	}

	hints := lipgloss.NewStyle().Foreground(lipgloss.Color("#94A3B8")).Render(
		"  " + lipgloss.NewStyle().Foreground(lipgloss.Color("#38BDF8")).Render("↑/↓") + " Navigate · " +
			lipgloss.NewStyle().Foreground(lipgloss.Color("#38BDF8")).Render("1-4") + " Quick Select · " +
			lipgloss.NewStyle().Foreground(lipgloss.Color("#38BDF8")).Render("esc") + " Cancel",
	)

	return strings.Join([]string{
		head,
		cmdBox,
		"",
		q,
		strings.Join(opts, "\n"),
		hints,
	}, "\n")
}
