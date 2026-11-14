#!/usr/bin/env bash
# IR Agent Pool 调度环 —— DeAlan pool.sh 的 Intelligent Router 适配版。
#
# 与 dispatcher 版的差异（语义映射见 README.md）：
#   claim  POST {IR_SERVER}/agent-api/v1/claim（长轮询；Bearer 智能体密钥）
#   槽位   本地并发计数 + 服务端租约（SKIP LOCKED 独占）——不再需要 slots/N.lock
#   重派   服务端 reaper 全托管（attempts/墙钟/孤儿）——本地无超时监视/孤儿扫描
#   停用   renew 回执 abort:true → 杀进程组放弃（管理台停用即生效）
#   执行   原管线复用：启动时对原 run-task.sh 打补丁（运行目录 d= 行改挂 POOL_DIR +
#          dispatcher 上报行改为落盘 ir-result.json），本脚本读补丁版结果转 IR complete
#          （幂等，重试 5 次 2/4/6/8s + undelivered 留档）
#
# 依赖：bash jq curl；机器上原 sec03 管线照常（RUN_TASK_ORIG 指向原版）。
set -u

IR_SERVER="${IR_SERVER:?need IR_SERVER (e.g. https://ir.example.com)}"
AGENT_SLUG="${AGENT_SLUG:?need AGENT_SLUG}"
AGENT_KEY="${AGENT_KEY:?need agent signing key or cluster subkey}"
CLUSTER="${CLUSTER:-}"
MAX_SLOTS="${MAX_SLOTS:-5}"
POOL="${POOL_DIR:?need POOL_DIR (ir-pool working dir)}"
RUN_TASK_ORIG="${RUN_TASK_ORIG:-}"   # 可选：提供时对原版打补丁复用；不提供则使用池目录内已备好的 run-task.sh（install.sh 部署）
# 兼容保留（DeAlan 遗留变量，本脚本不再读）：超时由服务端 executionDeadline/reaper 全托管
TASK_TIMEOUT_SECS="${TASK_TIMEOUT_SECS:-600}"

worker_id() { # 服务端校验 [a-z0-9-]{2,64}
  local id="${CLUSTER}-${AGENT_SLUG}"
  id=$(echo "$id" | tr '[:upper:]_' '[:lower:]-')
  echo "${id:0:64}"
}
WORKER_ID=$(worker_id)

log() { echo "$(date "+%Y-%m-%dT%H:%M:%S%z") $*"; }

# 启动校验：worker_id 服务端校验 [a-z0-9-]{2,64}（不合法时 heartbeat/claim 全 400，尽早暴露）；
# MAX_SLOTS 必须为正整数（0 会使 slot 派生除零）。
printf '%s' "$WORKER_ID" | grep -qE '^[a-z0-9-]{2,64}$' || {
  echo "FATAL  worker_id 非法: '$WORKER_ID'（由 CLUSTER/AGENT_SLUG 派生，须 [a-z0-9-]{2,64}）" >&2
  exit 1
}
case "$MAX_SLOTS" in '' | *[!0-9]* | 0)
  echo "FATAL  MAX_SLOTS 必须为正整数: '$MAX_SLOTS'" >&2
  exit 1 ;;
esac

# api: $1=path $2=body(可空) → REPLY_BODY(响应体)/REPLY_STATUS(HTTP 码)。
# 直接调用（不经命令替换——$() 子 shell 会丢副作用变量）。临时文件用 mktemp：
# 主循环 claim / 后台 heartbeat+renew 并发调用不可共用固定名（$$ 在子 shell
# 里不变、各自计数会交错——曾因此互相删除响应体）。
api() { # $1=path $2=body $3=额外头（\n 分隔，可空）。调用方必读 REPLY_STATUS/REPLY_BODY。
  local path="$1" body="${2:-}" tmp code args=() hdr
  REPLY_STATUS=000 REPLY_BODY=""   # 提前返回路径（mktemp 失败等）下调用方不会踩 set -u
  tmp=$(mktemp /tmp/ir-pool.XXXXXX) || return 0
  code=$(mktemp /tmp/ir-poolc.XXXXXX) || { rm -f "$tmp"; return 0; }
  while IFS= read -r hdr; do args+=(-H "$hdr"); done < <(auth_headers)
  if [ -n "${3:-}" ]; then
    while IFS= read -r hdr; do [ -n "$hdr" ] && args+=(-H "$hdr"); done <<<"$3"
  fi
  if [ -n "$body" ]; then
    args+=(-H 'Content-Type: application/json' -d "$body")
  fi
  curl -sS -m 40 -o "$tmp" -w '%{http_code}' \
    -X POST "${IR_SERVER}/agent-api/v1${path}" "${args[@]}" > "$code" 2>/dev/null || true
  REPLY_STATUS=$(cat "$code" 2>/dev/null)
  REPLY_STATUS=${REPLY_STATUS:-000}
  REPLY_BODY=$(cat "$tmp" 2>/dev/null)
  rm -f "$tmp" "$code"
}

auth_headers() {
  printf 'Authorization: Bearer %s\nX-Agent-Slug: %s\n' "$AGENT_KEY" "$AGENT_SLUG"
  [ -n "$CLUSTER" ] && printf 'X-Agent-Cluster: %s\n' "$CLUSTER"
  return 0
}

# ---------------------------------------------------------------------------
# 原管线补丁，三处替换，其余逐字节保留：
#   1. AGENT_KEY 必填 → 可缺省（池侧凭据不进子进程硬校验）
#   2. 运行目录 d= 行改挂 POOL_DIR（原脚本内部 POOL 硬编码 $HOME/pi-workers
#      或 $HOME/claude-pool——不重定向则 done/ir-result 落在旧目录，本脚本
#      永远等不到结果；POOL_DIR 未设时回退原值，手工单独运行行为不变）
#   3. dispatcher 上报行 post_result（含缩进的 runner fast-fail 分支）替换为
#      落盘 ir-result.json（缩进分支不替换会把任务载荷 POST 给旧平台端点）
# 特征码双校验（上报行 + d= 行任一未命中即拒绝启动）；源文件更新自动重打。
# ---------------------------------------------------------------------------
prepare_patched() {
  # 未提供原管线时跳过补丁（install.sh/演示管线已把执行器放好）。
  if [ -z "$RUN_TASK_ORIG" ]; then
    [ -f "$POOL/run-task.sh" ] || log "WARN  无 run-task.sh（RUN_TASK_ORIG 未设且池目录缺失执行器）"
    return 0
  fi
  local dst="$POOL/run-task.sh"
  if [ -f "$dst" ] && grep -q "IR-PATCHED" "$dst" && [ "$RUN_TASK_ORIG" -nt "$dst" ]; then
    log "patch  源 run-task.sh 更新，重新打补丁"
    rm -f "$dst"
  fi
  if [ ! -f "$dst" ]; then
    sed -e 's,AGENT_KEY="${AGENT_KEY:?need nodek_ key}",AGENT_KEY="${AGENT_KEY:-}",' \
        -e 's,^d="\$POOL/runs/\$tid".*,d="${POOL_DIR:-$POOL}/runs/$tid"; mkdir -p "$d"; cd "$d" || exit 1  # IR-PATCHED,' \
        -e 's,^\( *\)post_result "\$payload"$,\1printf "%s" "$payload" > "$d/ir-result.json"  # IR-PATCHED,' \
        "$RUN_TASK_ORIG" > "$dst.tmp" || {
      log "FATAL  打补丁失败: $RUN_TASK_ORIG 不可读"; exit 1;
    }
    grep -q 'POOL_DIR:-' "$dst.tmp" || {
      log "FATAL  补丁未命中（run-task.sh 的运行目录 d= 行已变化），拒绝启动"; exit 1;
    }
    grep -q '^printf "%s" "\$payload" > "\$d/ir-result.json"' "$dst.tmp" || {
      log "FATAL  补丁未命中（原脚本上报行已变化），拒绝启动"; exit 1;
    }
    mv "$dst.tmp" "$dst"
    chmod +x "$dst"
    log "patch  已生成 IR-PATCHED run-task.sh at $dst"
  fi
}

# setsid（Linux util-linux）可用时任务进独立进程组，kill 树用负 pid；
# macOS 无 setsid，降级普通后台 + 直接 kill（本地测试用）。
START_BACKEND=setsid
command -v setsid >/dev/null 2>&1 || START_BACKEND=""

kill_tree() { # $1=pid（setsid 模式=组长）
  if [ -n "$START_BACKEND" ]; then
    kill -- -"$1" 2>/dev/null
    sleep 1
    kill -9 -- -"$1" 2>/dev/null
  else
    kill "$1" 2>/dev/null
    sleep 1
    kill -9 "$1" 2>/dev/null
  fi
}

mkdir -p "$POOL/runs" "$POOL/undelivered"
cd "$POOL" || exit 1
prepare_patched

running_workers=()
in_flight() {
  local n=0 p alive=()
  for p in "${running_workers[@]:-}"; do
    [ -n "$p" ] || continue
    if kill -0 "$p" 2>/dev/null; then n=$((n + 1)); alive+=("$p"); fi
  done
  running_workers=("${alive[@]:-}")
  echo "$n"
}

# report_ir_complete: $1=runId $2=payload_json（status/payload/error/usage/metrics）
# 幂等：重试 5 次 2/4/6/8s；全败落 undelivered/<runId>.json 供补投。
report_ir_complete() {
  local runId="$1" payload="$2" i
  local extra; extra=$(printf 'X-Agent-Run-ID: %s\nX-Agent-Worker-ID: %s' "$runId" "$WORKER_ID")
  for i in 1 2 3 4 5; do
    api "/complete" "$payload" "$extra"
    if [ "$REPLY_STATUS" = "200" ] || [ "$REPLY_STATUS" = "409" ] || [ "$REPLY_STATUS" = "404" ]; then
      log "complete $runId → $REPLY_STATUS"
      return 0
    fi
    [ "$i" = 5 ] || sleep $((i * 2))
  done
  printf '%s' "$payload" > "$POOL/undelivered/$runId.json"
  log "post   $runId 回报 5 次失败,已留档 undelivered/$runId.json"
}

deadline_epoch() { # RFC3339 → epoch（含时区）；失败回退 0=无墙钟。
  # 用 python3 解析（sec03 管线同款依赖）：date -d/-j 的时区语义在 GNU/BSD
  # 间不一致，UTC 值会被按本地时区误读导致假超时。
  [ -n "${1:-}" ] && python3 -c '
import sys
from datetime import datetime
try:
    print(int(datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00")).timestamp()))
except Exception:
    print(0)
' "$1" || echo 0
}

# run_worker: $1=runId $2=renewAfterSecs $3=executionDeadline(rfc3339) $4=taskJsonFile
# 后台执行：起补丁版 run-task.sh（独立进程组）+ renew 循环 + 完成后转 IR complete。
run_worker() {
  local runId="$1" renewAfter="$2" deadline="$3" tf="$4"
  local d="$POOL/runs/$runId" slot=$((RANDOM % MAX_SLOTS + 1))
  local runhdr; runhdr=$(printf 'X-Agent-Run-ID: %s\nX-Agent-Worker-ID: %s' "$runId" "$WORKER_ID")

  # 契约 §12.2：执行前先续一次租。409（LEASE_LOST/TASK_DEADLINE_EXCEEDED）/404
  # → 任务已重派/终态，不启动本地执行；abort:true → 直接终局回执。
  api "/renew" "" "$runhdr"
  case "$REPLY_STATUS" in
    200)
      if jq -e '.abort == true' <<<"$REPLY_BODY" >/dev/null 2>&1; then
        log "ABORT  runId=$runId 启动前续租即被取消 → complete(aborted)"
        report_ir_complete "$runId" '{"status":"aborted"}'
        rm -f "$tf"
        return 0
      fi
      ;;
    409 | 404)
      log "SKIP   runId=$runId 启动前续租 $REPLY_STATUS → 租约失效/已重派，放弃"
      rm -f "$tf"
      return 0
      ;;
  esac

  mkdir -p "$d"
  if [ -n "$START_BACKEND" ]; then
    setsid nohup "$POOL/run-task.sh" "$runId" "$slot" <"$tf" >>"$POOL/pool.log" 2>&1 &
  else
    nohup "$POOL/run-task.sh" "$runId" "$slot" <"$tf" >>"$POOL/pool.log" 2>&1 &
  fi
  local pid=$!
  rm -f "$tf"   # stdin 重定向的 fd 已打开，删除路径安全（否则 claim.*.json 无限堆积）
  log "dispatch runId=$runId slot=$slot renewAfter=${renewAfter}s pid=$pid backend=${START_BACKEND:-plain}"

  local deadEpoch; deadEpoch=$(deadline_epoch "$deadline")
  local aborted=0 reason="" nextRenew=$renewAfter elapsed=0
  # 2s 粒度轮询：完成/取消即刻响应；每 renewAfter 间隔才发一次 renew。
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$deadEpoch" -gt 0 ] && [ "$(date +%s)" -ge "$deadEpoch" ]; then
      aborted=1; reason="task_timeout"
      log "TIMEOUT runId=$runId 超 executionDeadline → 杀进程组"
      break
    fi
    [ -f "$d/done" ] && break
    sleep 2
    elapsed=$((elapsed + 2))
    if [ "$elapsed" -lt "$nextRenew" ]; then continue; fi
    nextRenew=$((nextRenew + renewAfter))
    api "/renew" "" "$runhdr"   # 契约 §2：run/worker 标识走头，无请求体
    local rbody="$REPLY_BODY"
    case "$REPLY_STATUS" in
      200)
        if jq -e '.abort == true' <<<"$rbody" >/dev/null 2>&1; then
          aborted=1; reason="aborted"
          log "ABORT  runId=$runId 平台请求取消 → 杀进程组"
          break
        fi
        ;;
      409)
        reason=$(jq -r '.code // "lease_lost"' <<<"$rbody" 2>/dev/null || echo lease_lost)
        aborted=1
        log "LOST   runId=$runId $reason → 放弃本地执行（结果不会被接受）"
        break
        ;;
      404)
        aborted=1; reason="run_not_found"
        break
        ;;
    esac
  done
  if [ "$aborted" = "1" ]; then
    kill_tree "$pid"
    [ "$reason" = "task_timeout" ] && touch "$d/done"
  fi
  # 等原管线收尾（done 由补丁版写入；abort 路径直接终局）
  local waited=0
  while [ ! -f "$d/done" ] && [ "$waited" -lt 20 ]; do
    sleep 1; waited=$((waited + 1))
  done
  rm -f "$d/attempt" "$d/last_slot" 2>/dev/null

  # 结果转换 → IR complete
  local payload
  if [ -f "$d/ir-result.json" ]; then
    local rstatus
    rstatus=$(jq -r '.status // "failed"' "$d/ir-result.json" 2>/dev/null)
    if [ "$rstatus" = "completed" ] || [ "$rstatus" = "succeeded" ]; then
      # usage 转换：原管线 BoundRunUsage(promptTokens/completionTokens/totalTokens)
      # → IR camelCase 计量契约；totalTokens 必填（RULE-BND-001，兜底 > 0）。
      # 注意 $p 引用（.p 是 jq 输入的字段，恒 null——曾致 payload 恒 null 的critical bug）；
      # usage 在原管线位于 result.usage（top-level usage 仅兜底）。
      payload=$(jq -n --argjson p "$(cat "$d/ir-result.json")" '
        (($p.result.usage // $p.usage) // {}) as $u |
        {status:"succeeded",
         payload:($p.result // $p),
         usage:{inputTokens:($u.promptTokens // $u.inputTokens // 0),
                outputTokens:($u.completionTokens // $u.outputTokens // 0),
                totalTokens:($u.totalTokens // (($u.promptTokens // $u.inputTokens // 0) + ($u.completionTokens // $u.outputTokens // 0) + 1))},
         metrics:{durationMs:0}}')
    else
      local emsg
      emsg=$(jq -r '.error_message // "executor failed"' "$d/ir-result.json" 2>/dev/null)
      payload=$(jq -n --arg m "${emsg:0:500}" \
        '{status:"failed", error:{code:"executor_failed", message:$m}}')
    fi
  elif [ "$reason" = "aborted" ]; then
    payload='{"status":"aborted"}'
  else
    # 原管线启动即死且无结果：留给服务端租约超时重派（不回传，避免占用 attempts 语义）
    log "WARN   runId=$runId 无 ir-result.json（启动即死?）——交服务端租约超时处理"
    return 0
  fi
  report_ir_complete "$runId" "$payload"
  log "done   runId=$runId"
}

# heartbeat 独立循环：容量上报 + 服务端自适应间隔；401 即退出（密钥失效）。
# inFlight 读主循环落盘快照（$POOL/.inflight）——本函数是独立子进程，fork 后
# 的变量快照永久冻结，直接调 in_flight 只会永远上报 0。
run_heartbeat() {
  local interval=60
  while true; do
    local body want nf
    # cat 而非 read：文件无换行结尾时 read 置变量成功但退出码非 0，`|| nf=0` 会把值冲掉
    nf=$(cat "$POOL/.inflight" 2>/dev/null)
    case "$nf" in '' | *[!0-9]*) nf=0 ;; esac
    body=$(jq -n --arg w "$WORKER_ID" --argjson f "$nf" --argjson c "$MAX_SLOTS" \
      --arg s "$AGENT_SLUG" \
      '{workerId:$w, inFlight:$f, capacity:$c, capabilities:{slugs:[$s], version:"agent-pool/1"}}')
    api "/heartbeat" "$body"
    if [ "$REPLY_STATUS" = "200" ]; then
      want=$(jq -r '.heartbeatIntervalSeconds // 60' <<<"$REPLY_BODY" 2>/dev/null)
      case "$want" in ''|*[!0-9]*) want=60 ;; esac
      [ "$want" -lt 1 ] && want=60        # 0 会退化成忙等请求风暴
      [ "$want" -gt 3600 ] && want=3600
      interval=$want
    elif [ "$REPLY_STATUS" = "401" ]; then
      log "FATAL  heartbeat 401：密钥无效/被吊销，退出"
      exit 1
    fi
    sleep "$interval"
  done
}

# 退出清理：kill heartbeat 子进程。TERM/INT 也要走 EXIT trap——bash 收到未捕获
# 的 TERM 会立即死、不执行 EXIT trap，heartbeat 就会变孤儿继续打心跳。
cleanup() { kill "${HEARTBEAT_PID:-}" 2>/dev/null; }
trap 'cleanup; exit 0' EXIT
trap 'exit 0' TERM INT
run_heartbeat &
HEARTBEAT_PID=$!

log "start  worker=$WORKER_ID slug=$AGENT_SLUG slots=$MAX_SLOTS server=$IR_SERVER"
while true; do
  in_flight >/dev/null   # 顺带回收已退出的 worker pid
  local_free=$(in_flight)
  # inFlight 快照落盘给 heartbeat 子进程读（原子替换，避免半写状态）
  printf '%s' "$local_free" > "$POOL/.inflight.tmp" 2>/dev/null &&
    mv "$POOL/.inflight.tmp" "$POOL/.inflight" 2>/dev/null
  find "$POOL/runs" -mindepth 1 -maxdepth 1 -type d -mtime +3 -exec rm -rf {} + 2>/dev/null
  if [ "$local_free" -lt "$MAX_SLOTS" ]; then
    body=$(jq -n --arg w "$WORKER_ID" --argjson f "$local_free" --argjson c "$MAX_SLOTS" \
      --arg s "$AGENT_SLUG" \
      '{workerId:$w, maxWaitSeconds:20, inFlight:$f, capacity:$c, preferredSlugs:[$s]}')
    api "/claim" "$body"
    case "$REPLY_STATUS" in
      200)
        runId=$(jq -r '.runId' <<<"$REPLY_BODY" 2>/dev/null)
        # claim 响应字段缺失/非法 JSON 时 jq 会得到 "" 或字面量 null——不设防会派发脏 runId
        if [ -z "$runId" ] || [ "$runId" = "null" ]; then
          log "WARN   claim 200 但 runId 缺失，跳过本轮"
          sleep 1
          continue
        fi
        renewAfter=$(jq -r '.renewAfterSeconds // 30' <<<"$REPLY_BODY" 2>/dev/null)
        deadline=$(jq -r '.executionDeadline // ""' <<<"$REPLY_BODY" 2>/dev/null)
        attempts=$(jq -r '.attempts // 1' <<<"$REPLY_BODY" 2>/dev/null)
        log "claim  runId=$runId attempts=$attempts"
        # IR input → dispatcher 任务格式（原 run-task.sh stdin 契约 {task_id,prompt,input}）：
        # taskBrief → prompt；params → input（与原 input.json/sec03 管线对接）。
        tf=$(mktemp "$POOL/runs/claim.XXXXXX.json")
        jq -n --arg id "$runId" --argjson in "$(jq -c '.input // {}' <<<"$REPLY_BODY")" \
          '{task_id:$id,
            prompt:(if ($in.taskBrief // "" | length) > 0 then $in.taskBrief else ($in | tostring) end),
            input:($in.params // {})}' > "$tf"
        if [ ! -s "$tf" ]; then
          log "WARN   runId=$runId 任务文件构造失败（input 非法?），跳过"
          rm -f "$tf"
          sleep 1
          continue
        fi
        run_worker "$runId" "$renewAfter" "$deadline" "$tf" &
        running_workers+=($!)
        ;;
      204) continue ;;   # 空队列：契约 §1 立即重新 claim（长轮询窗口服务端持有，勿加 sleep）
      429) sleep 2 ;;    # 契约建议按 Retry-After 退避；固定 2s 保守兜底
      401)
        log "FATAL  claim 401：密钥无效/被吊销，退出"
        exit 1
        ;;
      403)
        log "FATAL  claim 403：令牌 scope 不含任何可用 slug（配置错误），退出"
        exit 1
        ;;
      *) sleep 1 ;;
    esac
  fi
  sleep 1
done
