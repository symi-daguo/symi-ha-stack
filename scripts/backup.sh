#!/usr/bin/env bash
# backup.sh — back up the stack's state to a timestamped archive.
#
#   ./backup.sh                 # back up into $STACK_DIR/backup/
#   ./backup.sh /mnt/nas/ha     # back up somewhere else
#   ./backup.sh --keep 14       # keep the 14 most recent archives
#
# What is backed up
# -----------------
#   ha-config/          Home Assistant configuration and entity registry
#   matter-hub-data/    Matter bridge state (Bridge ID, PIN, pairing code)
#   nodered-data/       Node-RED flows and credentials
#   mosquitto/config/   Broker config and the password file
#   docker-compose.yml  the compose file
#   .env                the configuration (contains the HA token — keep it safe)
#
# What is NOT backed up
# ---------------------
#   nodered-data/node_modules  (reinstalled by Node-RED on start)
#   mosquitto/data             (runtime persistence, regenerated)
#
# The archive contains secrets. It is written with mode 600.
set -euo pipefail

STACK_DIR="${STACK_DIR:-/opt/ha-stack}"
DEST="${1:-$STACK_DIR/backup}"
KEEP="${KEEP:-7}"
if [ "${1:-}" = "--keep" ]; then KEEP="${2:-7}"; DEST="$STACK_DIR/backup"; fi

case "${1:-}" in
  --keep) ;;
  -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
esac

mkdir -p "$DEST"
STAMP=$(date '+%Y%m%d-%H%M%S')
ARCHIVE="$DEST/ha-stack-$STAMP.tar.gz"

ITEMS=()
for item in ha-config matter-hub-data nodered-data mosquitto/config \
            docker-compose.yml .env; do
  [ -e "$STACK_DIR/$item" ] && ITEMS+=("$item")
done

if [ ${#ITEMS[@]} -eq 0 ]; then
  echo "错误: $STACK_DIR 下没有可备份的内容" >&2
  exit 1
fi

echo "==> 打包 ${#ITEMS[@]} 项到 $ARCHIVE"
tar czf "$ARCHIVE" -C "$STACK_DIR" "${ITEMS[@]}"
chmod 600 "$ARCHIVE"

SIZE=$(du -h "$ARCHIVE" | cut -f1)
echo "    完成: $ARCHIVE ($SIZE)"

# ── prune old archives ───────────────────────────────────────────────────────
COUNT=$(find "$DEST" -maxdepth 1 -name 'ha-stack-*.tar.gz' -type f | wc -l)
if [ "$COUNT" -gt "$KEEP" ]; then
  echo "==> 清理旧备份（保留最近 $KEEP 份）"
  find "$DEST" -maxdepth 1 -name 'ha-stack-*.tar.gz' -type f -printf '%T@ %p\n' \
    | sort -rn | tail -n +$((KEEP+1)) | cut -d' ' -f2- \
    | while read -r old; do
        echo "    删除 $old"
        rm -f "$old"
      done
fi

echo
echo "恢复方法:"
echo "  cd $STACK_DIR && docker compose down"
echo "  tar xzf $ARCHIVE -C $STACK_DIR"
echo "  docker compose up -d"
