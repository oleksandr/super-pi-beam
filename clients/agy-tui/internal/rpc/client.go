package rpc

import (
	"bufio"
	"cmp"
	"context"
	"encoding/json/jsontext"
	"encoding/json/v2"
	"fmt"
	"net"
	"sync"
	"sync/atomic"
)

// Request represents a JSON-RPC 2.0 outbound request.
type Request struct {
	JSONRPC string `json:"jsonrpc"`
	ID      int64  `json:"id,omitzero"`
	Method  string `json:"method"`
	Params  any    `json:"params,omitempty"`
}

// RPCError represents a JSON-RPC 2.0 error object.
type RPCError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func (e *RPCError) Error() string {
	return fmt.Sprintf("rpc error (%d): %s", e.Code, e.Message)
}

// InboundFrame represents either a JSON-RPC 2.0 response or a server-to-client notification.
type InboundFrame struct {
	JSONRPC string         `json:"jsonrpc"`
	ID      int64          `json:"id,omitzero"`
	Method  string         `json:"method,omitempty"`
	Result  jsontext.Value `json:"result,omitempty"`
	Error   *RPCError      `json:"error,omitempty"`
	Params  jsontext.Value `json:"params,omitempty"`
}

// EventBatchParams represents the payload of a `session.event` notification.
type EventBatchParams struct {
	BatchID int64        `json:"batch_id"`
	Events  []WatchEvent `json:"events"`
}

// WatchEvent represents a streaming event inside a `session.event` batch.
type WatchEvent struct {
	Type            string         `json:"type"`
	ConversationID  int64          `json:"conversation_id,omitzero"`
	Seq             int64          `json:"seq,omitzero"`
	Status          string         `json:"status,omitempty"`
	Index           any            `json:"index,omitempty"`
	Delta           string         `json:"delta,omitempty"`
	ToolCallID      string         `json:"tool_call_id,omitempty"`
	Name            string         `json:"name,omitempty"`
	Arguments       map[string]any `json:"arguments,omitempty"`
	OverwrittenKeys []string       `json:"overwritten_keys,omitempty"`
	IsError         bool           `json:"is_error,omitzero"`
	Output          string         `json:"output,omitempty"`
	Reason          string         `json:"reason,omitempty"`
	Error           string         `json:"error,omitempty"`
	Result          jsontext.Value `json:"result,omitempty"`
}

// UIRequestParams represents a server-initiated `ui.request` prompt modal.
type UIRequestParams struct {
	RequestID string   `json:"request_id"`
	Kind      string   `json:"kind"`
	Title     string   `json:"title"`
	Prompt    string   `json:"prompt"`
	ToolName  string   `json:"tool_name,omitempty"`
	Command   string   `json:"command,omitempty"`
	Options   []string `json:"options,omitempty"`
}

// SessionOpenResult represents the result of `session.open`.
type SessionOpenResult struct {
	ConversationID int64          `json:"conversation_id"`
	Seq            int64          `json:"seq"`
	Agent          map[string]any `json:"agent"`
}

// CompactResult represents the result of `session.compact`.
type CompactResult struct {
	EntryID        int64  `json:"entry_id"`
	HeadEntryID    int64  `json:"head_entry_id"`
	CompactedCount int    `json:"compacted_count"`
	KeptCount      int    `json:"kept_count"`
	Summary        string `json:"summary"`
}

// ForkResult represents the result of `session.fork`.
type ForkResult struct {
	ConversationID       int64 `json:"conversation_id"`
	ParentConversationID int64 `json:"parent_conversation_id"`
	ParentEntryID        int64 `json:"parent_entry_id"`
	Seq                  int64 `json:"seq"`
}

// Client manages a persistent line-delimited JSON-RPC 2.0 connection to SuperPi.RPC.Server
// and automatically acknowledges `session.event` batches to advance the K=2 flow-control window.
type Client struct {
	conn       net.Conn
	writeMu    sync.Mutex
	nextID     atomic.Int64
	pendingMu  sync.Mutex
	pending    map[int64]chan InboundFrame
	eventsCh   chan WatchEvent
	uiReqCh    chan UIRequestParams
	ackedCount atomic.Int64
	wg         sync.WaitGroup
}

// Dial connects to SuperPi.RPC.Server over TCP (e.g. "127.0.0.1:41234").
func Dial(ctx context.Context, addr string) (*Client, error) {
	var d net.Dialer
	conn, err := d.DialContext(ctx, "tcp", cmp.Or(addr, "127.0.0.1:4000"))
	if err != nil {
		return nil, err
	}
	return NewClient(conn), nil
}

// NewClient wraps an existing net.Conn as a SuperPi JSON-RPC 2.0 client.
func NewClient(conn net.Conn) *Client {
	c := &Client{
		conn:     conn,
		pending:  make(map[int64]chan InboundFrame),
		eventsCh: make(chan WatchEvent, 256),
		uiReqCh:  make(chan UIRequestParams, 16),
	}
	c.wg.Go(c.readLoop)
	return c
}

// Events returns the channel of live WatchEvents streamed from the server.
func (c *Client) Events() <-chan WatchEvent {
	return c.eventsCh
}

// UIRequests returns the channel of server-initiated UI requests (`ui.request`).
func (c *Client) UIRequests() <-chan UIRequestParams {
	return c.uiReqCh
}

// AckedBatches returns the total count of `session.ack` frames sent by this client.
func (c *Client) AckedBatches() int64 {
	return c.ackedCount.Load()
}

// Close closes the underlying socket and waits for the reader goroutine to exit.
func (c *Client) Close() error {
	err := c.conn.Close()
	c.wg.Wait()
	return err
}

// Call invokes a JSON-RPC 2.0 method and decodes the result into `out`.
func (c *Client) Call(ctx context.Context, method string, params any, out any) error {
	id := c.nextID.Add(1)
	ch := make(chan InboundFrame, 1)

	c.pendingMu.Lock()
	c.pending[id] = ch
	c.pendingMu.Unlock()

	defer func() {
		c.pendingMu.Lock()
		delete(c.pending, id)
		c.pendingMu.Unlock()
	}()

	req := Request{
		JSONRPC: "2.0",
		ID:      id,
		Method:  method,
		Params:  params,
	}

	if err := c.writeJSON(req); err != nil {
		return err
	}

	select {
	case <-ctx.Done():
		return ctx.Err()
	case frame, ok := <-ch:
		if !ok {
			return fmt.Errorf("connection closed while waiting for %s", method)
		}
		if frame.Error != nil {
			return frame.Error
		}
		if out != nil && len(frame.Result) > 0 {
			return json.Unmarshal(frame.Result, out)
		}
		return nil
	}
}

// OpenSession opens or creates a durable SuperPi conversation with optional AGY extensions preset.
func (c *Client) OpenSession(ctx context.Context, conversationID int64, agentCfg map[string]any, preset string) (*SessionOpenResult, error) {
	params := map[string]any{
		"preset": cmp.Or(preset, "agy"),
	}
	if conversationID > 0 {
		params["conversation_id"] = conversationID
	}
	if len(agentCfg) > 0 {
		params["agent"] = agentCfg
	}
	var res SessionOpenResult
	if err := c.Call(ctx, "session.open", params, &res); err != nil {
		return nil, err
	}
	return &res, nil
}

// WatchSession subscribes to `session.event` notifications for `conversationID`.
func (c *Client) WatchSession(ctx context.Context, conversationID int64) error {
	params := map[string]any{"conversation_id": conversationID}
	return c.Call(ctx, "session.watch", params, nil)
}

// SubmitAsync submits user input (`queue`, `steer`, or `write`) asynchronously so streaming events flow via Events().
func (c *Client) SubmitAsync(ctx context.Context, conversationID int64, text string, mode string) error {
	params := map[string]any{
		"conversation_id": conversationID,
		"text":            text,
		"mode":            cmp.Or(mode, "queue"),
		"async":           true,
		"preset":          "agy",
	}
	return c.Call(ctx, "session.submit", params, nil)
}

// ConfigureAgent updates the `pi.agent` document on the active conversation.
func (c *Client) ConfigureAgent(ctx context.Context, conversationID int64, patch map[string]any) error {
	params := map[string]any{
		"conversation_id": conversationID,
		"agent":           patch,
	}
	return c.Call(ctx, "session.configure", params, nil)
}

// CompactSession triggers manual context compaction on `conversationID`.
func (c *Client) CompactSession(ctx context.Context, conversationID int64) (*CompactResult, error) {
	params := map[string]any{"conversation_id": conversationID}
	var res CompactResult
	if err := c.Call(ctx, "session.compact", params, &res); err != nil {
		return nil, err
	}
	return &res, nil
}

// RespondUI sends `ui.respond` for an interactive permission or prompt modal.
func (c *Client) RespondUI(ctx context.Context, requestID string, value any) error {
	params := map[string]any{
		"request_id": requestID,
		"value":      value,
	}
	return c.Call(ctx, "ui.respond", params, nil)
}

func (c *Client) sendAck(batchID int64) error {
	c.ackedCount.Add(1)
	ack := Request{
		JSONRPC: "2.0",
		Method:  "session.ack",
		Params:  map[string]any{"batch_id": batchID},
	}
	return c.writeJSON(ack)
}

func (c *Client) writeJSON(v any) error {
	raw, err := json.Marshal(v)
	if err != nil {
		return err
	}
	raw = append(raw, '\n')
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	_, err = c.conn.Write(raw)
	return err
}

func (c *Client) readLoop() {
	scanner := bufio.NewScanner(c.conn)
	scanner.Buffer(make([]byte, 64*1024), 4*1024*1024)

	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var frame InboundFrame
		if err := json.Unmarshal(line, &frame); err != nil {
			continue
		}

		if frame.Method == "session.event" && len(frame.Params) > 0 {
			var batch EventBatchParams
			if err := json.Unmarshal(frame.Params, &batch); err == nil {
				for _, ev := range batch.Events {
					select {
					case c.eventsCh <- ev:
					default:
					}
				}
				_ = c.sendAck(batch.BatchID)
			}
			continue
		}

		if frame.Method == "ui.request" && len(frame.Params) > 0 {
			var req UIRequestParams
			if err := json.Unmarshal(frame.Params, &req); err == nil {
				select {
				case c.uiReqCh <- req:
				default:
				}
			}
			continue
		}

		if frame.ID != 0 {
			c.pendingMu.Lock()
			ch, ok := c.pending[frame.ID]
			c.pendingMu.Unlock()
			if ok {
				ch <- frame
			}
		}
	}

	c.pendingMu.Lock()
	for _, ch := range c.pending {
		close(ch)
	}
	clear(c.pending)
	c.pendingMu.Unlock()
	close(c.eventsCh)
}
