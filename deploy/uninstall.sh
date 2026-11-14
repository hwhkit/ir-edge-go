#!/usr/bin/env bash
# uninstall.sh —— 卸载 IR Edge 子节点（install.sh 的逆操作）。
# 默认保留数据与密钥；--purge 连 /var/lib 数据、密钥文件与日志一并删除。
set -u
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

if [ "$(id -u)" = "0" ]; then
  systemctl disable --now ir-edge.service 2>/dev/null && echo "已停止并禁用 ir-edge.service"
  [ -f /etc/systemd/system/ir-edge.service ] && rm -f /etc/systemd/system/ir-edge.service && systemctl daemon-reload
  rm -f /etc/ir-edge/pool-env
  rmdir /etc/ir-edge 2>/dev/null || true
  rm -rf /opt/ir-edge
fi

if [ "$PURGE" = "1" ]; then
  rm -rf "${HOME}/ir-edge" /var/lib/ir-edge
  echo "已清除数据目录（runs/undelivered/日志）"
else
  echo "数据目录已保留（--purge 可一并删除）"
fi
echo "卸载完成"
