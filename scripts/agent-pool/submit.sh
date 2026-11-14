#!/usr/bin/env bash
# submit.sh —— cron/本地事件直接提交运行结果（POST /agent-api/v1/runs）。
# 用法：
#   submit.sh -slug my-agent -status succeeded -payload result.json [-input in.json] [-runid cron-20260101] [-code ERR_X]
#   ... | submit.sh -slug my-agent -payload -        # payload 从 stdin 读
# 定时任务包装示例（crontab）：
#   30 1 * * * /path/run-analysis.sh | ~/ir-pool/submit.sh -slug my-agent -payload - >> ~/ir-pool/cron.log 2>&1
set -u
IR_SERVER="${IR_SERVER:?need IR_SERVER}"
AGENT_SLUG_DEFAULT="${AGENT_SLUG:-}"
AGENT_KEY="${AGENT_KEY:?need agent signing key or cluster subkey}"
CLUSTER="${CLUSTER:-}"

slug="" status="succeeded" runId="" payloadFile="" inputFile="" errorCode=""
# 手工解析：文档化的长名（-slug/-status/-payload/-input/-runid/-code）与短名（-s/-p/-i/-r/-c）
# 双兼容。原 getopts "s:p:i:r:c:" 版会静默错解长名（"-slug x" 被当作 -s 取值 "lug"），
# 且 -status 根本没有对应字母位——status 永远是默认 succeeded。
usage() { echo "usage: submit.sh -slug S -status succeeded|failed -payload FILE|- [-input FILE] [-runid ID] [-code CODE]" >&2; }
while [ $# -gt 0 ]; do
  opt="$1"
  case "$opt" in
    -slug | -status | -payload | -input | -runid | -code | -s | -p | -i | -r | -c) ;;
    *) usage; exit 2 ;;
  esac
  if [ $# -lt 2 ]; then
    echo "missing value for $opt" >&2
    usage
    exit 2
  fi
  val="$2"
  shift 2
  case "$opt" in
    -slug | -s) slug="$val" ;;
    -status) status="$val" ;;
    -payload | -p) payloadFile="$val" ;;
    -input | -i) inputFile="$val" ;;
    -runid | -r) runId="$val" ;;
    -code | -c) errorCode="$val" ;;
  esac
done
[ -n "$slug" ] || slug="$AGENT_SLUG_DEFAULT"
[ -n "$slug" ] || { echo "need -slug or AGENT_SLUG" >&2; exit 2; }

status="${status:-succeeded}"
[ "$status" = "succeeded" ] || [ "$status" = "failed" ] || { echo "-status must be succeeded|failed" >&2; exit 2; }

payload="{}"
if [ -n "$payloadFile" ]; then
  if [ "$payloadFile" = "-" ]; then
    payload=$(cat)
  else
    payload=$(cat "$payloadFile")
  fi
fi
input="null"
if [ -n "$inputFile" ]; then
  input=$(cat "$inputFile")
fi

# 本地先校验 JSON：原来非法 JSON 会被 --argjson 静默吞掉、以空体发给平台吃 400。
# 用 jq empty（纯解析，不带 -e——null/false 也是合法 JSON）
jq empty <<<"$payload" >/dev/null 2>&1 || {
  echo "payload is not valid JSON (from ${payloadFile:--}): ${payload:0:200}" >&2
  exit 2
}
jq empty <<<"$input" >/dev/null 2>&1 || {
  echo "input is not valid JSON (from $inputFile): ${input:0:200}" >&2
  exit 2
}

body=$(jq -n --arg slug "$slug" --arg status "$status" --arg runId "$runId" \
  --argjson payload "$payload" --argjson input "$input" --arg code "$errorCode" \
  '{slug:$slug, status:$status, payload:$payload, input:$input} +
   (if $runId != "" then {runId:$runId} else {} end) +
   (if $code != "" then {error:{code:$code, message:"submitted by submit.sh"}} else {} end)')

args=(-H "Authorization: Bearer $AGENT_KEY" -H "X-Agent-Slug: $slug")
[ -n "$CLUSTER" ] && args+=(-H "X-Agent-Cluster: $CLUSTER")
args+=(-H 'Content-Type: application/json' -d "$body")

resp=$(curl -sS -m 30 -w '\n%{http_code}' -X POST "${IR_SERVER}/agent-api/v1/runs" "${args[@]}")
code=${resp##*$'\n'}
body_out=${resp%$'\n'*}
if [ "$code" = "200" ]; then
  echo "$body_out"
else
  echo "submit rejected: HTTP $code $body_out" >&2
  exit 1
fi
