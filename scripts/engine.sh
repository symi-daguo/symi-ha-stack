#!/usr/bin/env bash
# engine.sh — switch the Home Assistant stack between Docker and Kiri.
#
#   engine.sh status   show which engine is running
#   engine.sh docker   run the stack on Docker
#   engine.sh kiri     run the stack on Kiri
#
# Why two engines: Kiri uses ~7 MB of engine memory vs ~160-210 MB for
# dockerd + containerd + shims. On a small home server that difference is
# real. Docker stays as a fallback so a Kiri regression can never take the
# stack down (see scripts/watch.sh for the automatic fallback).
#
# Requirements:
#   - Docker:  docker + docker compose (v2)
#   - Kiri:    kiri >= 0.2.1  →  https://github.com/libracoder/kiri
#              plus a static Docker CLI pointed at the Kiri socket.
#
# Environment:
#   STACK_DIR   where the stack lives (default /opt/ha-stack)
#   KIRI_SOCK   Kiri socket path (default /run/kiri/docker.sock)
#   KIRI_DOCKER Kiri-compatible docker CLI (default: docker)
set -uo pipefail

STACK_DIR="${STACK_DIR:-/opt/ha-stack}"
KIRI_SOCK="${KIRI_SOCK:-/run/kiri/docker.sock}"
KIRI_DOCKER="${KIRI_DOCKER:-docker}"
COMPOSE="$STACK_DIR/docker-compose.yml"
LOG="$STACK_DIR/engine.log"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }

# Ports every service in this stack binds on the host (host network mode).
PORTS='1883|9001|8123|1880|8482|5540'

wait_ports_free() {
  # Host-network containers bind the host ports directly. `compose down`
  # returns before docker-proxy has fully let go, and a stale container from
  # an aborted run still holds the port. Without this wait the new stack
  # starts, fails to bind, and crash-loops.
  local limit=${1:-30} busy
  for _ in $(seq 1 "$limit"); do
    busy=$(ss -tln 2>/dev/null | grep -cE ":($PORTS)\s" || true)
    [ "$busy" -eq 0 ] && return 0
    sleep 2
  done
  log "  警告: 端口仍被占用"
  return 1
}

stop_stray_containers() {
  # `compose down` only touches containers of this compose project. Debug
  # leftovers and containers from an interrupted run use host networking and
  # hold the same ports, which `down` cannot see. Stop them by image.
  # Only stop — never remove — so a stray container keeps its data.
  local engine=$1
  local docker_cmd=()
  [ "$engine" = "kiri" ] && docker_cmd=(env "DOCKER_HOST=$KIRI_SOCK" "$KIRI_DOCKER")
  [ "$engine" = "docker" ] && docker_cmd=(env -u DOCKER_HOST docker)

  local img c name
  for img in \
    ghcr.io/home-assistant/home-assistant:2026.11.1 \
    eclipse-mosquitto:2.0 \
    nodered/node-red:latest \
    ghcr.io/riddix/home-assistant-matter-hub; do
    for c in $("${docker_cmd[@]}" ps -aq --filter "ancestor=$img" 2>/dev/null); do
      name=$("${docker_cmd[@]}" inspect -f '{{.Name}}' "$c" 2>/dev/null | tr -d /)
      case "$name" in
        ha-stack*|"") continue ;;   # the real stack — compose already handled it
      esac
      log "  停止游离容器 $name (镜像 $img)"
      "${docker_cmd[@]}" stop "$c" >/dev/null 2>&1 || true
    done
  done
}

cmd_status() {
  if [ -S "$KIRI_SOCK" ] && \
     env "DOCKER_HOST=$KIRI_SOCK" "$KIRI_DOCKER" ps --format '{{.Names}}' 2>/dev/null | grep -qx homeassistant; then
    echo "当前引擎: kiri"
  elif docker ps --filter name=^/homeassistant$ --format '{{.Names}}' 2>/dev/null | grep -qx homeassistant; then
    echo "当前引擎: docker"
  else
    echo "当前引擎: 无（stack 未运行）"
  fi
  env "DOCKER_HOST=$KIRI_SOCK" "$KIRI_DOCKER" ps --format '  {{.Names}}\t{{.Status}}' 2>/dev/null
  local mem
  mem=$(ps -eo rss,args --no-headers | grep -E '/usr/bin/kiri daemon' | grep -v grep \
        | awk '{s+=$1} END {printf "%.1f", s/1024}')
  [ -n "$mem" ] && echo "  引擎内存: ${mem} MB"
}

cmd_docker() {
  log "=== 切换到 Docker ==="

  # The Docker daemon is normally disabled (no boot autostart) so it cannot
  # race Kiri for the host ports. Start it on demand instead.
  if ! docker info >/dev/null 2>&1; then
    log "  Docker daemon 未运行，尝试启动…"
    if command -v systemctl >/dev/null 2>&1; then
      systemctl start snap.docker.dockerd.service 2>/dev/null \
        || systemctl start docker.service 2>/dev/null || true
    fi
    for _ in $(seq 1 30); do
      docker info >/dev/null 2>&1 && { log "  Docker 就绪"; break; }
      sleep 2
    done
  fi
  docker info >/dev/null 2>&1 || { log "  Docker 不可用，中止"; return 1; }

  log "[1/3] 停 Kiri 上的 stack…"
  env "DOCKER_HOST=$KIRI_SOCK" "$KIRI_DOCKER" compose -f "$COMPOSE" \
    --project-name ha-stack --project-directory "$STACK_DIR" down 2>/dev/null
  stop_stray_containers kiri
  log "  等端口释放…"
  wait_ports_free 30

  log "[2/3] 起 Docker…"
  ( cd "$STACK_DIR" && docker compose up -d --no-build ) || return 1

  log "[3/3] 等待健康…"
  local n
  for _ in $(seq 1 30); do
    n=$(docker ps --filter health=healthy --format '{{.Names}}' 2>/dev/null | wc -l)
    [ "$n" -ge 4 ] && break
    sleep 10
  done
  docker ps --format '  {{.Names}}\t{{.Status}}'
}

cmd_kiri() {
  log "=== 切换到 Kiri ==="

  log "[0/5] 检查 Kiri 前置条件…"
  if [ ! -S "$KIRI_SOCK" ]; then
    log "  找不到 $KIRI_SOCK"
    log "  安装 Kiri: https://github.com/libracoder/kiri"
    return 1
  fi
  if ! systemctl is-active --quiet kiri.service 2>/dev/null; then
    log "  kiri.service 未运行，尝试启动…"
    systemctl start kiri.service 2>/dev/null || true
    sleep 3
  fi
  systemctl is-active --quiet kiri.service 2>/dev/null \
    || { log "  kiri.service 启动失败，中止"; return 1; }

  log "[1/5] 停 Docker 上的 stack…"
  ( cd "$STACK_DIR" && docker compose down ) 2>/dev/null
  stop_stray_containers docker
  log "  等端口释放…"
  wait_ports_free 30

  log "[2/5] 检查 Kiri 镜像是否齐…"
  local img missing=0
  for img in \
    ghcr.io/home-assistant/home-assistant:2026.11.1 \
    eclipse-mosquitto:2.0 \
    nodered/node-red:latest \
    ghcr.io/riddix/home-assistant-matter-hub; do
    if env "DOCKER_HOST=$KIRI_SOCK" "$KIRI_DOCKER" images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
         | grep -qx "$img"; then
      log "  ok  $img"
    else
      log "  缺  $img  → docker save | $KIRI_DOCKER load"
      missing=1
    fi
  done
  if [ "$missing" -eq 1 ]; then
    log "  用 scripts/sync-images.sh 把镜像同步到 Kiri 后重试"
    return 1
  fi

  log "[3/5] 起 Kiri…"
  ( cd "$STACK_DIR" && env "DOCKER_HOST=$KIRI_SOCK" "$KIRI_DOCKER" compose up -d --no-build ) || return 1

  log "[4/5] 等待健康…"
  local n
  for _ in $(seq 1 30); do
    n=$(env "DOCKER_HOST=$KIRI_SOCK" "$KIRI_DOCKER" ps --filter health=healthy \
         --format '{{.Names}}' 2>/dev/null | wc -l)
    [ "$n" -ge 4 ] && break
    sleep 10
  done
  env "DOCKER_HOST=$KIRI_SOCK" "$KIRI_DOCKER" ps --format '  {{.Names}}\t{{.Status}}'

  log "[5/5] Docker 侧已空 → 停掉空转的 dockerd（省 50-200 MB）…"
  if [ "$(docker ps -aq 2>/dev/null | wc -l)" -eq 0 ]; then
    systemctl stop snap.docker.dockerd.service 2>/dev/null || true
    systemctl stop docker.service 2>/dev/null || true
    log "  dockerd: $(systemctl is-active snap.docker.dockerd.service 2>/dev/null || echo stopped)"
  fi
}

case "${1:-status}" in
  status) cmd_status ;;
  docker) cmd_docker ;;
  kiri)   cmd_kiri ;;
  *)
    echo "用法: $0 {status|docker|kiri}" >&2
    exit 1
    ;;
esac
