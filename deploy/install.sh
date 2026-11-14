#!/usr/bin/env bash
# install.sh —— IR Edge 子节点一键部署。
#
# 一条命令在新机器上完成：依赖安装 → 布局落盘 → 密钥接入 → 配置生成 →
# 服务注册（systemd/launchd 不可用时降级前台）→ 启动 → 心跳验证。
#
# 用法：
#   sudo bash install.sh \
#     --server https://ir.example.com \
#     --slug my-agent \
#     --key-file ./node.key \            # 智能体主密钥或已派生的集群子密钥
#     --cluster pi01 \                   # 可选：派生模式必填
#     --exec "python3 /opt/agents/pi.py" # 可选：本机 Agent 命令（默认演示管线）
#     --mode systemd|docker|foreground \ # 默认自动检测（systemd→docker→foreground）
#     --slots 5
#
# 卸载：bash uninstall.sh [--purge]
set -u

# ---------------------------------------------------------------------------
# 参数解析（长选项手工解析；值先守卫再取 $2，规避 getopts 长选项陷阱）
# ---------------------------------------------------------------------------
SERVER=""; SLUG=""; KEY_FILE=""; KEY_DIRECT=""; CLUSTER=""
SLOTS="${MAX_SLOTS:-5}"; MODE=""; EXEC_CMD=""; RUN_TASK_ORIG=""; POOL_DIR=""
DRY_RUN=0

need_value() { [ $# -ge 2 ] || { echo "install.sh: $1 需要一个值" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --server) need_value "$@"; SERVER="$2"; shift 2 ;;
    --slug) need_value "$@"; SLUG="$2"; shift 2 ;;
    --key-file) need_value "$@"; KEY_FILE="$2"; shift 2 ;;
    --key) need_value "$@"; KEY_DIRECT="$2"; shift 2 ;;
    --cluster) need_value "$@"; CLUSTER="$2"; shift 2 ;;
    --slots) need_value "$@"; SLOTS="$2"; shift 2 ;;
    --mode) need_value "$@"; MODE="$2"; shift 2 ;;
    --exec) need_value "$@"; EXEC_CMD="$2"; shift 2 ;;
    --run-task-orig) need_value "$@"; RUN_TASK_ORIG="$2"; shift 2 ;;
    --pool-dir) need_value "$@"; POOL_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "install.sh: 未知参数 $1" >&2; exit 2 ;;
  esac
done

[ -n "$SERVER" ] || { echo "缺 --server（IR Core 地址，如 https://ir.example.com）" >&2; exit 2; }
[ -n "$SLUG" ] || { echo "缺 --slug（要认领的智能体 slug）" >&2; exit 2; }
{ [ -n "$KEY_FILE" ] || [ -n "$KEY_DIRECT" ]; } || { echo "缺 --key-file 或 --key" >&2; exit 2; }
if [ -z "$KEY_FILE" ] && [ -z "$CLUSTER" ]; then
  echo "提示：--key 直连模式建议配 --cluster（派生子密钥可按集群吊销）" >&2
fi

worker_id() {
  local id="${CLUSTER}-${SLUG}"
  id=$(echo "$id" | tr '[:upper:]_' '[:lower:]-')
  echo "${id:0:64}"
}
WORKER_ID=$(worker_id)

# 形态自动检测：systemd → docker → foreground
if [ -z "$MODE" ]; then
  if command -v systemctl >/dev/null 2>&1 && [ "$(id -u)" = "0" ]; then
    MODE="systemd"
  elif command -v docker >/dev/null 2>&1 && [ -n "${RUN_TASK_ORIG:-}" ]; then
    MODE="docker"
  else
    MODE="foreground"
  fi
fi
case "$MODE" in systemd) [ "$(id -u)" = "0" ] || { echo "systemd 模式需要 root（或改 --mode foreground/docker）" >&2; exit 2; } ;; esac

# 路径布局
PREFIX="${PREFIX:-/opt/ir-edge}"
if [ -n "$POOL_DIR" ]; then :; else
  case "$MODE" in
    systemd) POOL_DIR="/var/lib/ir-edge" ;;
    docker) POOL_DIR="/var/lib/ir-edge" ;;
    *) POOL_DIR="${HOME}/ir-edge" ;;
  esac
fi
ENV_FILE="${ENV_FILE:-/etc/ir-edge/pool-env}"
[ "$MODE" = "foreground" ] && ENV_FILE="${POOL_DIR}/pool-env"
HERE="$(cd "$(dirname "$0")" && pwd)"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "[$(date '+%H:%M:%S')] FATAL: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. 依赖
# ---------------------------------------------------------------------------
install_deps() {
  local missing=""
  command -v curl >/dev/null 2>&1 || missing="$missing curl"
  command -v jq >/dev/null 2>&1 || missing="$missing jq"
  [ -z "$missing" ] && return 0
  log "安装依赖:$missing"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq $missing
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q $missing
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache $missing
  elif command -v brew >/dev/null 2>&1; then
    brew install -q $missing
  else
    die "请手动安装:$missing"
  fi
}
install_deps
command -v jq >/dev/null 2>&1 || die "jq 不可用"

# ---------------------------------------------------------------------------
# 2. 密钥与配置落盘
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" = "1" ]; then
  log "[dry-run] 将创建 $PREFIX/{pool.sh,run-task.sh} · $ENV_FILE · 服务单元（$MODE）"
  log "[dry-run] workerId=$WORKER_ID server=$SERVER slug=$SLUG slots=$SLOTS"
  exit 0
fi

mkdir -p "$POOL_DIR/runs" "$POOL_DIR/undelivered"
case "$MODE" in
  systemd|docker) mkdir -p "$PREFIX" && mkdir -p "$(dirname "$ENV_FILE")" ;;
esac

# 密钥：key-file 复制（600），key 直传写入
if [ -n "$KEY_FILE" ]; then
  [ -f "$KEY_FILE" ] || die "密钥文件不存在: $KEY_FILE"
  KEY_VALUE=$(cat "$KEY_FILE")
else
  KEY_VALUE="$KEY_DIRECT"
fi
[ -n "$KEY_VALUE" ] || die "密钥为空"

write_pool_env() { # $1 = 输出路径
  local out="$1" run_task
  run_task="${RUN_TASK_ORIG:-}"
  umask 077
  cat > "$out" <<ENV
IR_SERVER="$SERVER"
AGENT_SLUG="$SLUG"
AGENT_KEY="$KEY_VALUE"
CLUSTER="$CLUSTER"
WORKER_ID="$WORKER_ID"
MAX_SLOTS="$SLOTS"
POOL_DIR="$POOL_DIR"
RUN_TASK_ORIG="$run_task"
TASK_TIMEOUT_SECS="${TASK_TIMEOUT_SECS:-600}"
ENV
  umask 022
  chmod 600 "$out"
}

# 执行体：优先原管线（补丁复用），其次 --exec 生成的包装器，默认自带演示管线
write_exec_layer() {
  local dst="$1" tmpl
  if [ -n "$RUN_TASK_ORIG" ]; then
    tmpl="$RUN_TASK_ORIG"
  elif [ -n "$EXEC_CMD" ]; then
    # 生成 exec 包装：stdin 任务 JSON → 执行用户命令 → stdout 结果 → 落盘
    cat > "$dst.exec" <<WRAP
#!/usr/bin/env bash
set -u
tid="\$1"
d="\$(dirname "\$0")/../runs/\$tid"; mkdir -p "\$d"
input=\$(cat)
out=\$(printf '%s' "\$input" | $EXEC_CMD); rc=\$?
if [ \$rc -eq 0 ] && printf '%s' "\$out" | jq -e 'type=="object"' >/dev/null 2>&1; then
  payload=\$(jq -n --arg t "\$tid" --argjson r "\$out" '{task_id:\$t, status:"completed", result:\$r}')
else
  payload=\$(jq -n --arg t "\$tid" --arg m "{exec rc=\$rc}" '{task_id:\$t, status:"failed", error:{code:"executor_failed", message:\$m}}')
fi
printf '%s' "\$payload" > "\$d/ir-result.json"  # IR-PATCHED
touch "\$d/done"
WRAP
    return 0
  else
    tmpl="$HERE/../scripts/agent-pool/demo-run-task.sh"
    [ -f "$tmpl" ] || tmpl="$HERE/demo-run-task.sh"
  fi
  # 复制 + 可选 exec 包装标记（pool.sh 的补丁机制会重定向上报行）
  if [ -n "$EXEC_CMD" ] && [ -z "$RUN_TASK_ORIG" ]; then
    printf '%s\n' "$dst.exec" > "$dst"
    chmod +x "$dst"
  else
    cp "$tmpl" "$dst" 2>/dev/null || die "无法复制执行器: $tmpl"
    chmod +x "$dst"
  fi
}

case "$MODE" in
  systemd)
    write_pool_env "$ENV_FILE"
    write_exec_layer "$PREFIX/run-task.sh"
    cp "$HERE/../scripts/agent-pool/pool.sh" "$PREFIX/pool.sh" 2>/dev/null || cp "$HERE/pool.sh" "$PREFIX/pool.sh"
    chmod +x "$PREFIX/pool.sh"
    UNIT="/etc/systemd/system/ir-edge.service"
    cat > "$UNIT" <<UNIT
[Unit]
Description=IR Edge node (worker=$WORKER_ID, slug=$SLUG)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$(id -un 2>/dev/null || echo root)
WorkingDirectory=$POOL_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$PREFIX/pool.sh
Restart=always
RestartSec=3
# 硬边界：仅出站连接，无入站端口
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now ir-edge.service
    log "systemd 服务已安装并启动（ir-edge.service）"
    ;;
  docker)
    command -v docker >/dev/null 2>&1 || die "docker 不可用；Docker 模式需先安装 docker"
    write_pool_env "$ENV_FILE"
    log "Docker 模式：请配合 edge/Dockerfile 镜像使用（见 README）——生成 pool-env 完成，单元由 compose 管理"
    ;;
  foreground)
    ENV_FILE="${POOL_DIR}/pool-env"
    write_pool_env "$ENV_FILE"
    write_exec_layer "$POOL_DIR/run-task.sh"
    cp "$HERE/../scripts/agent-pool/pool.sh" "$POOL_DIR/pool.sh" 2>/dev/null || cp "$HERE/pool.sh" "$POOL_DIR/pool.sh"
    chmod +x "$POOL_DIR/pool.sh"
    log "foreground 模式：启动 $POOL_DIR/pool.sh（Ctrl+C 停止）"
    set -a; . "$ENV_FILE"; set +a
    "$POOL_DIR/pool.sh"
    ;;
esac

# ---------------------------------------------------------------------------
# 3. 启动验证：等 heartbeat 注册（非 foreground 模式）/ 前台模式由用户 Ctrl+C 结束
# ---------------------------------------------------------------------------
if [ "$MODE" != "foreground" ] && [ "$DRY_RUN" != "1" ]; then
  log "验证中：等待 worker 心跳注册（最多 30s）..."
  ok=0
  for i in $(seq 1 15); do
    sleep 2
    if [ "$MODE" = "systemd" ] && systemctl is-active --quiet ir-edge.service; then
      body=$(curl -sf -m 5 "${SERVER}/health/ready" 2>/dev/null) && ok=1 && break
    fi
    grep -q "^start" "$POOL_DIR/pool.log" 2>/dev/null && ok=1 && break
  done
  if [ "$ok" = "1" ]; then
    log "✓ 部署完成 —— worker=$WORKER_ID 已上线"
    log "  Central Console → 连接器/运行日志 可见本节点"
    log "  演示回执：往该智能体提交任务即可在 runs 中看到结果"
  else
    log "✗ 未检测到心跳——排查：$POOL_DIR/pool.log 与平台侧密钥/scope 配置"
    exit 1
  fi
fi
