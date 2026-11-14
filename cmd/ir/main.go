// ir —— Intelligent Router 的机器端程序：CLI + 常驻 daemon + 本地 Web 控制台。
//
// 单二进制两种形态：
//   ir daemon            常驻：连接平台 agent-api（claim/renew/complete/heartbeat），
//                        按本机路由表把任务派发给对应的 Agent（exec/HTTP）
//   ir init / agents …   配置与管理子命令
//   （daemon 内嵌本地 Web 控制台 127.0.0.1:7800，配置与状态查看双入口之一）
//
// 与平台的关系：只通过 agent-api HTTP 协议通信（契约见平台仓库
// doc/AGENT-PULL-API.md），不依赖平台任何内部包——两个项目独立演进。
package main

import (
	"flag"
	"fmt"
	"os"
)

const version = "dev"

func main() {
	fs := flag.NewFlagSet("ir", flag.ExitOnError)
	showVersion := fs.Bool("version", false, "print version")
	_ = fs.Parse(os.Args[1:])
	if *showVersion {
		fmt.Println("ir", version)
		return
	}
	fmt.Fprintln(os.Stderr, "ir: 子命令实现见 internal/app/agentd（骨架阶段）")
	fmt.Fprintln(os.Stderr, "  计划子命令: init / agents add|list|remove|test / daemon / service install / status / submit")
	os.Exit(2)
}
