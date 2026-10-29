package main

import (
	"cmp"
	"context"
	"flag"
	"fmt"
	"os"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/oleksandr/super-pi-beam/clients/agy-tui/internal/rpc"
	"github.com/oleksandr/super-pi-beam/clients/agy-tui/internal/tui"
)

func main() {
	rpcAddr := flag.String("rpc-addr", cmp.Or(os.Getenv("SUPER_PI_RPC_ADDR"), "127.0.0.1:4000"), "SuperPi.RPC.Server TCP address")
	convID := flag.Int64("conversation", 0, "Conversation ID to open or attach")
	model := flag.String("model", "gemini-3-flash-preview", "Initial LLM model")
	effort := flag.String("effort", "medium", "Initial reasoning effort")
	mode := flag.String("mode", "auto", "Execution mode (auto|plan|accept-edits)")
	workspace := flag.String("workspace", "", "Workspace directory")
	prompt := flag.String("prompt", "", "Optional initial prompt to submit on startup")
	flag.Parse()

	wsDir := *workspace
	if wsDir == "" {
		wsDir, _ = os.Getwd()
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	client, err := rpc.Dial(ctx, *rpcAddr)
	cancel()
	if err != nil {
		fmt.Fprintf(os.Stderr, "agy-tui: failed to connect to SuperPi.RPC.Server at %s: %v\n", *rpcAddr, err)
		os.Exit(1)
	}
	defer client.Close()

	openCtx, openCancel := context.WithTimeout(context.Background(), 10*time.Second)
	openRes, err := client.OpenSession(openCtx, *convID, map[string]any{
		"model":          *model,
		"effort":         *effort,
		"executionMode":  *mode,
		"workspacePaths": []string{wsDir},
	}, "agy")
	openCancel()
	if err != nil {
		fmt.Fprintf(os.Stderr, "agy-tui: session.open failed: %v\n", err)
		os.Exit(1)
	}

	watchCtx, watchCancel := context.WithTimeout(context.Background(), 5*time.Second)
	if err := client.WatchSession(watchCtx, openRes.ConversationID); err != nil {
		watchCancel()
		fmt.Fprintf(os.Stderr, "agy-tui: session.watch failed: %v\n", err)
		os.Exit(1)
	}
	watchCancel()

	m := tui.NewModel(tui.Config{
		Client:         client,
		ConversationID: openRes.ConversationID,
		Model:          *model,
		Effort:         *effort,
		Mode:           *mode,
		WorkspaceDir:   wsDir,
		InitialPrompt:  *prompt,
	})

	p := tea.NewProgram(m, tea.WithAltScreen(), tea.WithMouseCellMotion())
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "agy-tui error: %v\n", err)
		os.Exit(1)
	}
}
