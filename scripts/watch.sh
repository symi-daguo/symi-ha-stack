#!/usr/bin/env bash
# watch.sh — health monitor with automatic fallback to Docker.
#
# Runs every 5 minutes:
#   - records engine memory, HA container memory, available RAM, swap
#   - if the stack is unhealthy 3 times in a row → switch back to Docker
#
# The fallback is what makes it safe to run a beta container engine in
# production: if Kiri regresses, the stack comes back on Docker within
# ~15 minutes without human intervention.
#
# Install as a systemd user unit (see systemd/ha-stack-watch.service).
set -uo pipefail

STACK_DIR="${STACK_DIR:-/opt/ha-stack}"
LOG="${WATCH_LOG:-$STACK_DIR/watch.log}"
KIRI_SOCK="${KIRI_SOCK:-/run/kiri/docker.sock}"
KIRI_DOCKER="${KIRI_DOCKER:-docker}"
INTERVAL="${WATCH_INTERVAL:-300}"
MAXBAD="${WATCH_MAX_BAD:-3}"

BAD=0
ts() { date '+%Y-%m-%d %H:%M:%S'; }

# Memory of a container, read from the cgroup rather than .State.Pid.
# Kiri's .State.Pid points at s6-init (~108 kB) while Docker's points at
# the real process — the semantics differ, but cgroup memory.current is
# engine-independent and always the true footprint.
# The cgroup path comes from /proc/PID/cgroup (authoritative); do NOT glob
# the engine directory — it holds stale cgroups and glob picks the wrong one.
container_mem_mb() {
  local name=$1 pid cg
  pid=$(env "DOCKER_HOST=$KIRI_SOCK" "$KIRI_DOCKER" inspect "$name" \
        --format '{{.State.Pid}}' 2>/dev/null)
  [ -z "$pid" ] || [ "$pid" = "0" ] && { echo ""; return; }
  cg=$(awk -F: '/^0::/{print $3}' "/proc/$pid/cgroup" 2>/dev/null)
  [ -z "$cg" ] && { echo ""; return; }
  [ -r "/sys/fs/cgroup$cg/memory.current" ] || { echo ""; return; }
  awk '{printf "%.0f", $1/1048576}' "/sys/fs/cgroup$cg/memory.current"
}

while true; do
  # Engine presence has three distinct cases. Conflating them is a trap:
  #   a) Kiri has the containers  → engine in place, normal inspection.
  #   b) Kiri has none, Docker has → already fallen back, stand by.
  #   c) NEITHER has them         → the engine is DEAD. This must count as
  #                                 unhealthy, otherwise the monitor waits
  #                                 forever and the stack never comes back.
  ha_on_kiri=$(env "DOCKER_HOST=$KIRI_SOCK" "$KIRI_DOCKER" ps --format '{{.Names}}' 2>/dev/null | grep -cx homeassistant)
  ha_on_docker=$(docker ps --filter name=^/homeassistant$ --format '{{.Names}}' 2>/dev/null | grep -cx homeassistant)

  if [ "$ha_on_kiri" -eq 0 ]; then
    if [ "$ha_on_docker" -gt 0 ]; then
      echo "$(ts) 引擎不在 Kiri（已回落 Docker），监控待命" >> "$LOG"
      BAD=0
      sleep "$INTERVAL"
      continue
    fi
    unhealthy=" 引擎故障(kiri无容器+docker无容器)"
  else
    unhealthy=""
    for c in homeassistant nodered matter-hub mosquitto; do
      st=$(env "DOCKER_HOST=$KIRI_SOCK" "$KIRI_DOCKER" inspect "$c" \
           --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null)
      [ "$st" = "healthy" ] || unhealthy="$unhealthy $c($st)"
    done
  fi

  eng=$(ps -eo rss,args --no-headers | grep -E '/usr/bin/kiri daemon' | grep -v grep \
        | awk '{s+=$1} END {printf "%.0f", s/1024}')
  har=$(container_mem_mb homeassistant)

  # `free` prints localized headers on this machine (Chinese), so matching
  # /^Mem:/ never works. Take the values by line number instead.
  memline=$(free -m | sed -n '2p')
  swapline=$(free -m | sed -n '3p')
  avail=$(echo "$memline"  | awk '{print $7}')
  swap=$(echo "$swapline" | awk '{print $3}')

  if [ -z "$unhealthy" ]; then
    BAD=0
    echo "$(ts) OK 引擎=${eng}MB HA=${har}MB 剩avail=${avail}MB swap=${swap}MB" >> "$LOG"
  else
    BAD=$((BAD+1))
    echo "$(ts) BAD($BAD/$MAXBAD)$unhealthy 引擎=${eng}MB HA=${har}MB avail=${avail}MB swap=${swap}MB" >> "$LOG"
    if [ "$BAD" -ge "$MAXBAD" ]; then
      echo "$(ts) === 连续 $MAXBAD 次不健康，自动切回 Docker ===" >> "$LOG"
      "$STACK_DIR/scripts/engine.sh" docker >> "$LOG" 2>&1
      BAD=0
      sleep "$INTERVAL"
    fi
  fi
  sleep "$INTERVAL"
done
