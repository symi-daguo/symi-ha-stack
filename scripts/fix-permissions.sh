#!/usr/bin/env bash
# fix-permissions.sh — make the bind-mounted data directories writable by
# the uid each container runs as.
#
# Why this is needed
# -------------------
# The stack bind-mounts host directories into containers. A container runs as
# a fixed non-root uid (mosquitto 1883, node-red 1000), and it cannot write
# into a host directory owned by somebody else. The symptom is confusing —
# the container exits with a permission error on a path that clearly exists:
#
#   Error: EACCES: permission denied, lstat '/data/settings.js'
#   Error: Unable to open config file /mosquitto/config/mosquitto.conf.
#
# The second one is especially misleading: it looks like a missing file, but
# it is a permission problem (and on runtimes without a DAC_OVERRIDE-capable
# root it is fatal — see docs/TROUBLESHOOTING.md).
#
# On Docker the root user inside the container has CAP_DAC_OVERRIDE and can
# read anything, so this never shows up. On Kiri it does.
#
# Usage:
#   ./fix-permissions.sh              # fix every known directory
#   ./fix-permissions.sh mosquitto    # fix just one
set -euo pipefail

STACK_DIR="${STACK_DIR:-/opt/ha-stack}"
# uid:gid per service. mosquitto and node-red are the two that run as a
# non-root uid; HA and Matter Hub run as root and need no adjustment.
declare -A OWNERS=(
  [mosquitto]="1883:1883"
  [nodered-data]="1000:1000"
)

fix_one() {
  local name=$1 owner=$2
  local dir="$STACK_DIR/$name"
  [ -d "$dir" ] || { echo "  跳过 $name（$dir 不存在）"; return 0; }
  local cur
  cur=$(stat -c '%u:%g' "$dir")
  if [ "$cur" = "$owner" ]; then
    echo "  $name 已是 $owner"
    return 0
  fi
  chown -R "$owner" "$dir" 2>/dev/null \
    && echo "  $name: $cur → $owner" \
    || { echo "  $name: 修改失败（需要 root）" >&2; return 1; }
}

if [ $# -gt 0 ]; then
  for name in "$@"; do
    [ -n "${OWNERS[$name]:-}" ] || { echo "未知服务: $name" >&2; exit 1; }
    fix_one "$name" "${OWNERS[$name]}"
  done
else
  for name in "${!OWNERS[@]}"; do
    fix_one "$name" "${OWNERS[$name]}"
  done
fi

echo
echo "完成。如果容器仍在报权限错误，确认 compose 里的 user: 与这里一致。"
