// Package agentd
// daemon 内核 —— per-slug claim 长轮询 / renew（abort|409 → 杀进程树）/ complete（幂等重试 + undelivered 留档）/ heartbeat（自适应间隔）；配置热重载（在途收尾不硬杀）。
//
// 骨架占位：实现顺序见 README 里程碑。
package agentd
