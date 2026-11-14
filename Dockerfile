# IR Edge —— 机器端连接器镜像（bash 版池：claim → 演示管线 → complete）
# 构建上下文：edge/
#   docker build -f edge/Dockerfile -t ir-edge edge/
FROM alpine:3.20
RUN apk add --no-cache bash jq curl coreutils python3
WORKDIR /pool
COPY scripts/agent-pool/pool.sh ./pool.sh
COPY scripts/agent-pool/submit.sh ./submit.sh
COPY scripts/agent-pool/derive-key.sh ./derive-key.sh
COPY scripts/agent-pool/README.md ./README.md
# 演示管线：任何任务都立即产出结果（真实机器上替换为 sec03/CLI 管线）
COPY scripts/agent-pool/demo-run-task.sh ./demo-run-task.sh
RUN chmod +x pool.sh submit.sh derive-key.sh demo-run-task.sh
ENTRYPOINT ["./pool.sh"]
