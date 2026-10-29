package diff

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// Line represents a single line in a unified diff view.
type Line struct {
	Type   string // " ", "+", "-", "@"
	LineNo int
	Text   string
}

// DiffBlock represents an edited file's unified diff.
type DiffBlock struct {
	Path     string
	Added    int
	Deleted  int
	Lines    []Line
	Summary  string
}

// Render renders a diff block matching agy's exact formatting:
// ● Edit(path)
//   ⎿  Added X lines
//         1    def add(a, b):
//         2 +  def subtract(a, b):
func Render(d DiffBlock, width int) string {
	bullet := lipgloss.NewStyle().Foreground(lipgloss.Color("#22C55E")).Render("●")
	title := lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#EAB308")).Render("Edit")
	pathStr := lipgloss.NewStyle().Foreground(lipgloss.Color("#F8FAFC")).Render("(" + d.Path + ")")
	elbow := lipgloss.NewStyle().Foreground(lipgloss.Color("#94A3B8")).Render("  ⎿  ")

	header := fmt.Sprintf("%s %s%s", bullet, title, pathStr)
	tally := elbow + fmt.Sprintf("Added %d lines", d.Added)
	if d.Deleted > 0 {
		tally += fmt.Sprintf(", Deleted %d lines", d.Deleted)
	}

	lineNoStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("#64748B"))
	addStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("#22C55E"))
	delStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("#EF4444"))
	contextStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("#CBD5E1"))

	var out []string
	out = append(out, header, tally)

	for _, l := range d.Lines {
		num := fmt.Sprintf("%6d ", l.LineNo)
		switch l.Type {
		case "+":
			out = append(out, fmt.Sprintf("     %s%s%s", lineNoStyle.Render(num), addStyle.Render("+ "), addStyle.Render(l.Text)))
		case "-":
			out = append(out, fmt.Sprintf("     %s%s%s", lineNoStyle.Render(num), delStyle.Render("- "), delStyle.Render(l.Text)))
		default:
			out = append(out, fmt.Sprintf("     %s  %s", lineNoStyle.Render(num), contextStyle.Render(l.Text)))
		}
	}

	return strings.Join(out, "\n")
}

// ParseSimpleDiff takes oldText and newText and generates a compact unified diff block.
func ParseSimpleDiff(path string, oldText string, newText string) DiffBlock {
	oldLines := strings.Split(oldText, "\n")
	newLines := strings.Split(newText, "\n")

	var diffLines []Line
	added := 0
	deleted := 0

	// Simple line-level diff calculation
	for i, nl := range newLines {
		lineNo := i + 1
		if i < len(oldLines) && oldLines[i] == nl {
			diffLines = append(diffLines, Line{Type: " ", LineNo: lineNo, Text: nl})
		} else {
			diffLines = append(diffLines, Line{Type: "+", LineNo: lineNo, Text: nl})
			added++
		}
	}

	return DiffBlock{
		Path:    path,
		Added:   added,
		Deleted: deleted,
		Lines:   diffLines,
	}
}
