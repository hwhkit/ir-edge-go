# IR Edge

**IR（Intelligent Router，智能路由）** 的机器端程序：`ir` —— 单二进制 = CLI + 常驻 daemon（ir-noded）+ 本地 Web 控制台（127.0.0.1:7800，Node Console）。

## 术语体系（IR 家族）

| 术语 | 中文 | 指代 |
|---|---|---|
| **IR** | 智能路由 | 整个产品伞形品牌 |
| **IR Core** | 核心路由器（控制面） | 平台服务端（repo `agent-server-go`） |
| **IR Edge** | 边缘路由器（执行节点） | 本仓库——机器端程序 |
| **IR Mesh** | 智能体组网 | Core + 全部 Edge 构成的分布式网络 |
| **IR Link** | 链路协议 | agent-api/v1 的协议名（契约见 Core 仓库 doc/） |
| **ir-noded** | 节点守护进程 | `ir daemon` 的服务形态 |
| **Node Console** | 节点控制台 | 127.0.0.1:7800 本机 Web |
| **Central Console** | 中央控制台 | Core 的管理台 SPA |
| **Node Key** | 节点密钥 | 智能体主密钥（入站签名 + 连接认证） |
| **Cluster Key** | 集群子密钥 | Node Key 的 HMAC 派生（按集群吊销） |
| **Fleet** | 机群 | 一台 Edge 上的执行池（DeAlan pi-pool/cc-pool 的继任概念） |
| **Run** | 运行 | 一次任务执行（全程审计） |
| **Position / Team** | 岗位 / 编排 | 业务层概念（Core 管理） |


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
