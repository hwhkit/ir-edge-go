// Package agentd 实现 Edge daemon 内核：per-agent claim/execute/complete 循环 + heartbeat。
package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"ir-edge/internal/domain/agentd"
	"ir-edge/internal/infra/agentapiclient"
	"ir-edge/internal/infra/nodecfg"
)

// Daemon 是 Edge 节点守护进程。
type Daemon struct {
	cfg   *nodecfg.Config
	state *agentd.StateStore
	stop  context.CancelFunc
	wg    sync.WaitGroup
}

// NewDaemon 创建守护进程。
func NewDaemon(cfg *nodecfg.Config) *Daemon {
	return &Daemon{cfg: cfg, state: agentd.NewStateStore()}
}

// State 暴露运行态（Node Console 读取）。
func (d *Daemon) State() *agentd.StateStore { return d.state }

// Config 暴露配置。
func (d *Daemon) Config() *nodecfg.Config { return d.cfg }

// Start 启动全部 agent worker 循环。
func (d *Daemon) Start(ctx context.Context) {
	ctx, d.stop = context.WithCancel(ctx)
	for _, def := range d.cfg.Agents {
		d.wg.Add(2)
		go d.workerLoop(ctx, def)
		go d.heartbeatLoop(ctx, def)
	}
	slog.Info("daemon started", "agents", len(d.cfg.Agents), "server", d.cfg.Server)
}

// Stop 优雅停机。
func (d *Daemon) Stop() {
	if d.stop != nil {
		d.stop()
	}
	d.wg.Wait()
	slog.Info("daemon stopped")
}

// workerLoop 是单个智能体的 claim→execute→complete 循环。
func (d *Daemon) workerLoop(ctx context.Context, def agentd.AgentDef) {
	defer d.wg.Done()
	client := agentapiclient.New(agentapiclient.Config{
		Server: d.cfg.Server, Slug: def.Slug, Key: def.Key, Cluster: d.cfg.Cluster,
	})
	workerID := fmt.Sprintf("%s-%s", d.cfg.Cluster, def.Slug)
	runner := &agentd.ExecRunner{Command: def.Exec, Dir: def.Dir, Env: def.Env}
	var inflight atomic.Int64

	d.state.Update(def.Slug, func(a *agentd.AgentState) {
		a.Online = true
		a.Capacity = def.Capacity
	})

	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		n := int(inflight.Load())
		if n >= def.Capacity {
			time.Sleep(2 * time.Second)
			continue
		}

		task, ok, err := client.Claim(ctx, workerID, n, def.Capacity)
		if err != nil {
			slog.Warn("claim failed", "slug", def.Slug, "err", err)
			time.Sleep(time.Second)
			continue
		}
		if !ok {
			continue // 204 空队列，立即重试
		}

		inflight.Add(1)
		d.executeTask(ctx, client, def, runner, task, workerID)
		inflight.Add(-1)
	}
}

// executeTask 执行单个任务并回传。
func (d *Daemon) executeTask(ctx context.Context, client *agentapiclient.Client,
	def agentd.AgentDef, runner agentd.Runner, task *agentapiclient.ClaimResult, workerID string) {
	started := time.Now()
	slog.Info("task claimed", "slug", def.Slug, "run_id", task.RunID)

	// renew 循环
	renewCtx, renewCancel := context.WithCancel(ctx)
	go func() {
		interval := time.Duration(task.RenewAfterSeconds) * time.Second
		if interval <= 0 {
			interval = 30 * time.Second
		}
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-renewCtx.Done():
				return
			case <-ticker.C:
				abort, _ := client.Renew(renewCtx, task.RunID)
				if abort {
					renewCancel()
					return
				}
			}
		}
	}()

	// 执行
	timeout := time.Duration(def.TimeoutSecs) * time.Second
	execCtx, execCancel := context.WithTimeout(renewCtx, timeout)
	result, runErr := runner.Run(execCtx, task.Input)
	renewCancel()
	execCancel()

	durationMs := time.Since(started).Milliseconds()
	var status string
	var payload json.RawMessage
	if runErr != nil {
		status = "failed"
		payload = json.RawMessage(`{}`)
		slog.Warn("task failed", "run_id", task.RunID, "err", runErr)
	} else {
		status = "succeeded"
		payload = result
		slog.Info("task done", "run_id", task.RunID, "duration_ms", durationMs)
	}

	// complete（带重试）
	completeCtx, completeCancel := context.WithTimeout(ctx, 30*time.Second)
	err := client.Complete(completeCtx, task.RunID, status, payload,
		map[string]uint64{"inputTokens": 0, "outputTokens": 0, "totalTokens": 1}, durationMs)
	completeCancel()
	if err != nil {
		slog.Error("complete failed", "run_id", task.RunID, "err", err)
	}

	// 更新运行态
	d.state.Update(def.Slug, func(a *agentd.AgentState) {
		if runErr != nil {
			a.LastError = runErr.Error()
		} else {
			a.LastResult = payload
			a.LastError = ""
		}
		a.Runs = append(a.Runs, agentd.RunRecord{
			RunID: task.RunID, Status: status, DurationMs: durationMs, CreatedAt: time.Now(),
		})
	})
}

// heartbeatLoop 定期上报存活与容量。
func (d *Daemon) heartbeatLoop(ctx context.Context, def agentd.AgentDef) {
	defer d.wg.Done()
	client := agentapiclient.New(agentapiclient.Config{
		Server: d.cfg.Server, Slug: def.Slug, Key: def.Key, Cluster: d.cfg.Cluster,
	})
	workerID := fmt.Sprintf("%s-%s", d.cfg.Cluster, def.Slug)
	ticker := time.NewTicker(60 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := client.Heartbeat(ctx, workerID, 0, def.Capacity); err != nil {
				slog.Warn("heartbeat failed", "slug", def.Slug, "err", err)
			}
		}
	}
}
