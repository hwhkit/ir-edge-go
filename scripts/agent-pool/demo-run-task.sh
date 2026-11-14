#!/usr/bin/env bash
# 演示管线：任何认领到的任务立即产出结果（真实机器上替换为 sec03/CLI 管线）。
# 含原 run-task.sh 契约特征行（AGENT_KEY 检查 + post_result 调用），
# pool.sh 启动时打补丁：post_result → 落盘 ir-result.json。
set -u
tid="$1"; slot="$2"
POOL="${POOL_DIR:-/pool}"
d="$POOL/runs/$tid"; mkdir -p "$d"; cd "$d" || exit 1
t=$(cat)
echo "DEMO executed: $(echo "$t" | head -c 200)" >> "$POOL/pool.log"
input=$(echo "$t" | jq -c '.input // {}')
payload=$(jq -n --arg t "$tid" --argjson i "$input" \
  '{task_id:$t, status:"completed",
    result:{text:"hello from IR Edge (docker demo)", echo:$i},
    usage:{promptTokens:10, completionTokens:5, totalTokens:15}}')
post_result "$payload"
touch "$d/done"
