package banner

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

type LineSpec struct {
	Glyph string
	RGB   string
}

// SuperPiLogo defines the 5-line Greek Pi with Erlang/Elixir BEAM energy gradient.
var SuperPiLogo = []LineSpec{
	{Glyph: "   ▄▄▄▄▄▄▄▄▄▄▄   ", RGB: "#DC2626"}, // Erlang Red
	{Glyph: "   ▀▀▀██  ██▀▀   ", RGB: "#C026D3"}, // Magenta
	{Glyph: "      ██  ██     ", RGB: "#A855F7"}, // Elixir Purple
	{Glyph: "      ██  ██ ▄   ", RGB: "#6366F1"}, // Indigo
	{Glyph: "     ▀▀▀  ▀▀▀▀   ", RGB: "#38BDF8"}, // BEAM Electric Cyan
}

// Config holds the metadata displayed next to the hero logo.
type Config struct {
	Version      string
	UserAccount  string
	ModelDisplay string
	Workspace    string
}

// Render returns the full 5-line Super-Pi-BEAM hero banner matching agy's layout.
func Render(cfg Config) string {
	versionStr := cfg.Version
	if versionStr == "" {
		versionStr = "1.0.0 (OTP 28.4 / Elixir 1.20)"
	}
	userStr := cfg.UserAccount
	if userStr == "" {
		userStr = "Durable BEAM Harness (SQLite WAL)"
	}
	modelStr := cfg.ModelDisplay
	if modelStr == "" {
		modelStr = "Gemini 3.8 Flash (Medium)"
	}
	wsStr := cfg.Workspace
	if wsStr == "" {
		wsStr = "."
	}

	titleStyle := lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#60A5FA"))
	dimStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("#94A3B8"))
	versionDim := lipgloss.NewStyle().Foreground(lipgloss.Color("#64748B"))

	meta := []string{
		titleStyle.Render("Super-Pi-BEAM ") + versionDim.Render(versionStr),
		dimStyle.Render(userStr),
		dimStyle.Render(modelStr),
		dimStyle.Render(wsStr),
		"",
	}

	var lines []string
	for i, spec := range SuperPiLogo {
		glyph := lipgloss.NewStyle().Foreground(lipgloss.Color(spec.RGB)).Render(spec.Glyph)
		lines = append(lines, fmt.Sprintf(" %s    %s", glyph, meta[i]))
	}

	return strings.Join(lines, "\n")
}
