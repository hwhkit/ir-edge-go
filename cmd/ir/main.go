// ir — IR Edge 机器端程序：CLI + 常驻 daemon + Node Console（127.0.0.1:7800）。
//
// 用法：
//
//	ir daemon --config agentd.yaml          # 启动守护进程 + Node Console
//	ir daemon -s https://ir.example.com -slug my-agent -key <key> -exec "python3 a.py"
//	ir version
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"

	"ir-edge/internal/api/localweb"
	"ir-edge/internal/app/daemon"
	"ir-edge/internal/infra/nodecfg"
)

const version = "0.1.0"

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	switch os.Args[1] {
	case "daemon":
		runDaemon(os.Args[2:])
	case "version", "--version", "-v":
		fmt.Println("ir", version)
	default:
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, `ir — IR Edge machine-side agent

Usage:
  ir daemon [flags]        Start the daemon + Node Console (127.0.0.1:7800)
  ir version                Show version

Daemon flags:
  --config <path>           Path to agentd.yaml (recommended)
  --server <url>            IR Core address (required if no --config)
  --slug <slug>             Agent slug (required if no --config)
  --key <key>               Agent signing key (required if no --config)
  --cluster <id>            Cluster identifier (default: hostname)
  --exec <cmd>              Execution command (default: demo echo)
  --capacity <n>            Concurrent slots (default: 2)
  --port <n>                Node Console port (default: 7800)

Example:
  ir daemon --config /etc/ir/agentd.yaml
  ir daemon -s https://ir.example.com -slug analyst -key abc123 -exec "python3 /opt/analyst.py"`)
}

func runDaemon(args []string) {
	fs := flag.NewFlagSet("daemon", flag.ExitOnError)
	cfgPath := fs.String("config", "", "path to agentd.yaml")
	server := fs.String("server", "", "IR Core address")
	slug := fs.String("slug", "", "agent slug")
	key := fs.String("key", "", "agent signing key")
	cluster := fs.String("cluster", "", "cluster id")
	execCmd := fs.String("exec", "", "execution command")
	capacity := fs.Int("capacity", 2, "concurrent slots")
	port := fs.Int("port", 7800, "node console port")
	fs.Parse(args)

	var cfg *nodecfg.Config
	var err error

	if *cfgPath != "" {
		cfg, err = nodecfg.Load(*cfgPath)
		if err != nil {
			slog.Error("load config", "err", err)
			os.Exit(1)
		}
	} else {
		// 命令行模式：构造单 agent 配置
		if *server == "" || *slug == "" || *key == "" {
			slog.Error("daemon requires --server, --slug, --key (or --config)")
			os.Exit(1)
		}
		if *cluster == "" {
			hostname, _ := os.Hostname()
			*cluster = hostname
		}
		exec := []string{"echo", `{"demo":true}`}
		if *execCmd != "" {
			exec = []string{"sh", "-c", *execCmd}
		}
		cfg = &nodecfg.Config{
			Server:  *server,
			Cluster: *cluster,
			Port:    *port,
			Agents: []nodecfg.AgentDef{{
				Slug: *slug, Key: *key, Capacity: *capacity, TimeoutSecs: 600, Exec: exec,
			}},
		}
	}
	if cfg.Port == 0 {
		cfg.Port = *port
	}

	// 启动 daemon
	ctx, cancel := context.WithCancel(context.Background())
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sig
		slog.Info("shutting down...")
		cancel()
	}()

	d := daemon.NewDaemon(cfg)
	d.Start(ctx)

	// Node Console
	consoleAddr := fmt.Sprintf("127.0.0.1:%d", cfg.Port)
	consoleHandler := localweb.NewHandler(d)
	consoleSrv := &http.Server{
		Addr:    consoleAddr,
		Handler: consoleHandler.Router(),
	}
	go func() {
		slog.Info("node console", "addr", "http://"+consoleAddr)
		if err := consoleSrv.ListenAndServe(); err != http.ErrServerClosed {
			slog.Error("console server", "err", err)
		}
	}()

	<-ctx.Done()
	consoleSrv.Shutdown(context.Background())
	d.Stop()
}
