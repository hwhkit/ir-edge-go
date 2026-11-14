# ir-agent-go

Intelligent Router 的机器端程序：`ir` —— 单二进制 = CLI + 常驻 daemon + 本地 Web 控制台（127.0.0.1:7800）。

每台机器安装 `ir` 后，daemon 通过平台 agent-api（claim/renew/complete/heartbeat，
出站 HTTPS + 智能体密钥认证）认领任务，按本机路由表派发给机器上对应的
Agent（exec 进程 / 本地 HTTP 服务），并把定时任务经 `/runs` 直提。

## 与平台的关系（项目边界）

- 平台服务端：`hwhkit/agent-server-go`（本目录之外）——只通过 HTTP 协议通信
- 协议契约：平台仓库 `doc/AGENT-PULL-API.md`（两端共同遵循，唯一耦合面）
- 本仓库不 import 平台任何内部包、不访问平台数据库

## 结构

```
cmd/ir/                 CLI 入口（init/agents/daemon/service/status/submit）
internal/domain/agentd/ 本机 Agent 声明、注册表、运行态、Runner 接口
internal/app/agentd/    daemon 内核 + 本地 Web 用例（热重载、执行器）
internal/api/localweb/  本地控制台路由 + 内嵌 UI
internal/infra/         agentapiclient（平台客户端）/ nodecfg（配置）/ keyring（密钥）
scripts/agent-pool/     bash 版池连接器（无 Go 环境机器用；语义同 daemon）
```

## 里程碑

1. 骨架 + 配置/密钥/客户端 infra（本提交）
2. daemon 内核（多 Agent 路由 + Exec/HTTP 执行器 + 热重载）
3. 本地 Web 控制台（API + 内嵌 UI）
4. 子命令补齐 + service install（systemd/launchd）
5. goreleaser + brew tap + install.sh
