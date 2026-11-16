// Package agentapiclient 封装 IR Link（agent-api/v1）的 HTTP 客户端。
package agentapiclient

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// Config .
type Config struct {
	Server  string
	Slug    string
	Key     string
	Cluster string
	Timeout time.Duration
}

// Client .
type Client struct {
	cfg Config
	hc  *http.Client
}

// New .
func New(cfg Config) *Client {
	if cfg.Timeout <= 0 {
		cfg.Timeout = 40 * time.Second
	}
	return &Client{cfg: cfg, hc: &http.Client{Timeout: cfg.Timeout}}
}

func (c *Client) post(ctx context.Context, path string, body any) (int, []byte, error) {
	data, err := json.Marshal(body)
	if err != nil {
		return 0, nil, err
	}
	req, err := http.NewRequestWithContext(ctx, "POST", c.cfg.Server+"/agent-api/v1"+path, bytes.NewReader(data))
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+c.cfg.Key)
	if c.cfg.Slug != "" {
		req.Header.Set("X-Agent-Slug", c.cfg.Slug)
	}
	if c.cfg.Cluster != "" {
		req.Header.Set("X-Agent-Cluster", c.cfg.Cluster)
	}
	resp, err := c.hc.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	return resp.StatusCode, out, nil
}

// ClaimResult .
type ClaimResult struct {
	RunID             string          `json:"runId"`
	AgentSlug         string          `json:"agentSlug"`
	Input             json.RawMessage `json:"input"`
	Attempts          int             `json:"attempts"`
	LeaseSeconds      int             `json:"leaseSeconds"`
	RenewAfterSeconds int             `json:"renewAfterSeconds"`
}

// Claim .
func (c *Client) Claim(ctx context.Context, workerID string, inflight, capacity int) (*ClaimResult, bool, error) {
	st, data, err := c.post(ctx, "/claim", map[string]any{
		"workerId": workerID, "maxWaitSeconds": 20,
		"inFlight": inflight, "capacity": capacity,
		"preferredSlugs": []string{c.cfg.Slug},
	})
	if err != nil {
		return nil, false, err
	}
	if st == 204 {
		return nil, false, nil
	}
	if st != 200 {
		return nil, false, fmt.Errorf("claim %d: %s", st, data)
	}
	var r ClaimResult
	if err := json.Unmarshal(data, &r); err != nil {
		return nil, false, err
	}
	return &r, true, nil
}

// Renew .
func (c *Client) Renew(ctx context.Context, runID string) (bool, error) {
	st, _, err := c.post(ctx, "/renew", map[string]string{})
	if err != nil {
		return false, err
	}
	return st == 409 || st == 404, nil // true = abort
}

// Complete .
func (c *Client) Complete(ctx context.Context, runID string, status string, payload json.RawMessage, usage map[string]uint64, durationMs int64) error {
	body := map[string]any{
		"status": status, "payload": payload,
		"metrics": map[string]int64{"durationMs": durationMs},
		"usage":   usage,
	}
	if status == "failed" {
		body["error"] = map[string]string{"code": "executor_failed", "message": "execution failed"}
	}
	st, data, err := c.post(ctx, "/complete", body)
	if err != nil {
		return err
	}
	if st != 200 {
		return fmt.Errorf("complete %d: %s", st, data)
	}
	return nil
}

// Heartbeat .
func (c *Client) Heartbeat(ctx context.Context, workerID string, inflight, capacity int) error {
	_, _, err := c.post(ctx, "/heartbeat", map[string]any{
		"workerId": workerID, "inFlight": inflight, "capacity": capacity,
		"capabilities": map[string]any{"slugs": []string{c.cfg.Slug}, "version": "ir-edge/1"},
	})
	return err
}
