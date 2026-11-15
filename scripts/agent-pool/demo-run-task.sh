#!/usr/bin/env bash
# 演示管线：任何认领到的任务立即产出结果（真实机器上替换为 sec03/CLI 管线）。
# 自包含：直接写 ir-result.json + done，不依赖 post_result / 补丁机制。
set -u
tid="$1"; slot="$2"
POOL="${POOL_DIR:-/tmp/stock-edge}"
d="$POOL/runs/$tid"; mkdir -p "$d"; cd "$d" || exit 1
t=$(cat)
input=$(echo "$t" | jq -c '.input // {}')
echo "DEMO executed: $(echo "$t" | head -c 300)" >> "$POOL/pool.log"
result=$(jq -n --arg t "$tid" --argjson i "$input" \
  '{task_id:$t, status:"completed",
    result:{analysis:"demo", symbol:($i.symbol // "unknown"), brief:($i.brief // ""),
            recommendation:{method:"MAX_SHARPE", rationale:"Demo pipeline output"},
            executive_summary:"Demo analysis completed successfully"},
    usage:{promptTokens:10, completionTokens:5, totalTokens:15}}')
printf '%s' "$result" > "$d/ir-result.json"
touch "$d/done"
