// Package agentd 定义 Edge 节点上的智能体域：声明、运行态与执行端口。
package agentd

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"sync"
	"time"
)

// AgentDef 是一个本机智能体的执行定义。
type AgentDef struct {
	Slug        string            `yaml:"slug" json:"slug"`
	Key         string            `yaml:"key" json:"-"`
	Capacity    int               `yaml:"capacity" json:"capacity"`
	TimeoutSecs int64             `yaml:"timeoutSecs" json:"timeoutSecs"`
	Exec        []string          `yaml:"exec" json:"exec"`
	Dir         string            `yaml:"dir,omitempty" json:"dir,omitempty"`
	Env         map[string]string `yaml:"env,omitempty" json:"env,omitempty"`
}

// Runner 执行任务：input JSON → 结果 JSON。
type Runner interface {
	Run(ctx context.Context, input json.RawMessage) (json.RawMessage, error)
}

// ExecRunner 用子进程执行：payload → stdin，stdout → 结果。
type ExecRunner struct {
	Command []string
	Dir     string
	Env     map[string]string
}

// Run 实现 Runner。
func (r *ExecRunner) Run(ctx context.Context, input json.RawMessage) (json.RawMessage, error) {
	if len(r.Command) == 0 {
		return nil, fmt.Errorf("exec is empty")
	}
	cmd := exec.CommandContext(ctx, r.Command[0], r.Command[1:]...)
	if r.Dir != "" {
		cmd.Dir = r.Dir
	}
	cmd.Stdin = bytes.NewReader(input)
	var stdout bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("exec: %w", err)
	}
	out := bytes.TrimSpace(stdout.Bytes())
	if len(out) == 0 {
		return json.RawMessage(`{}`), nil
	}
	if json.Valid(out) {
		return json.RawMessage(out), nil
	}
	escaped, _ := json.Marshal(string(out))
	return json.RawMessage(fmt.Sprintf(`{"text":%s}`, escaped)), nil
}

// HTTPRunner 用本地 HTTP 服务执行。
type HTTPRunner struct {
	URL string
}

// Run 实现 Runner。
func (r *HTTPRunner) Run(ctx context.Context, input json.RawMessage) (json.RawMessage, error) {
	req, err := http.NewRequestWithContext(ctx, "POST", r.URL, bytes.NewReader(input))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("http runner: %d", resp.StatusCode)
	}
	var buf bytes.Buffer
	buf.ReadFrom(resp.Body)
	out := bytes.TrimSpace(buf.Bytes())
	if json.Valid(out) {
		return json.RawMessage(out), nil
	}
	escaped, _ := json.Marshal(string(out))
	return json.RawMessage(fmt.Sprintf(`{"text":%s}`, escaped)), nil
}

// RunRecord 是一条运行记录。
type RunRecord struct {
	RunID      string    `json:"runId"`
	Status     string    `json:"status"`
	DurationMs int64     `json:"durationMs"`
	CreatedAt  time.Time `json:"createdAt"`
}

// AgentState 是单个智能体的运行态。
type AgentState struct {
	Slug       string          `json:"slug"`
	Online     bool            `json:"online"`
	InFlight   int             `json:"inFlight"`
	Capacity   int             `json:"capacity"`
	LastResult json.RawMessage `json:"lastResult,omitempty"`
	LastError  string          `json:"lastError,omitempty"`
	Runs       []RunRecord     `json:"runs,omitempty"`
}

// StateStore 是线程安全的运行态容器。
type StateStore struct {
	mu     sync.RWMutex
	agents map[string]*AgentState
}

// NewStateStore .
func NewStateStore() *StateStore {
	return &StateStore{agents: make(map[string]*AgentState)}
}

// Update 原子更新。
func (s *StateStore) Update(slug string, fn func(a *AgentState)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.agents[slug] == nil {
		s.agents[slug] = &AgentState{Slug: slug}
	}
	fn(s.agents[slug])
	if len(s.agents[slug].Runs) > 20 {
		s.agents[slug].Runs = s.agents[slug].Runs[len(s.agents[slug].Runs)-20:]
	}
}

// Snapshot 只读快照。
func (s *StateStore) Snapshot() []AgentState {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]AgentState, 0, len(s.agents))
	for _, a := range s.agents {
		out = append(out, *a)
	}
	return out
}
