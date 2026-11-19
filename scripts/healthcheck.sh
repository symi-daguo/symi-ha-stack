#!/usr/bin/env bash
# healthcheck.sh — one command that tells you whether the stack is healthy.
#
#   ./healthcheck.sh          # check and print a report
#   ./healthcheck.sh --quiet  # only exit code (for monitoring)
#
# Exit code: 0 = healthy, 1 = problems found.
#
# Checks
#   1. which engine is running
#   2. all four containers healthy
#   3. HA / Node-RED / Matter Hub answer on their ports
#   4. MQTT accepts an authenticated client
#   5. no leftover AppArmor profile that would break the broker on Kiri
#   6. mDNS advertising only on the LAN interface
#   7. HA entity registry is intact
#   8. no errors in the recent HA log
#   9. bind-mount directory ownership matches the container uids
set -uo pipefail

STACK_DIR="${STACK_DIR:-/opt/ha-stack}"
KIRI_SOCK="${KIRI_SOCK:-unix:///run/kiri/docker.sock}"
KIRI_DOCKER="${KIRI_DOCKER:-docker}"
QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

PROBLEMS=0
ok()   { [ "$QUIET" = "1" ] || printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { PROBLEMS=$((PROBLEMS+1)); [ "$QUIET" = "1" ] || printf '  \033[31m✗\033[0m %s\n' "$*"; }
info() { [ "$QUIET" = "1" ] || printf '  \033[2m·\033[0m %s\n' "$*"; }
head_() { [ "$QUIET" = "1" ] || printf '\n\033[1m%s\033[0m\n' "$*"; }

# ── find a usable CLI ────────────────────────────────────────────────────────
CLI=""
for c in "$KIRI_DOCKER" docker /usr/local/bin/docker-kiri "$HOME/.local/bin/docker-kiri"; do
  [ -n "$c" ] || continue
  # Resolve the candidate: an absolute path must exist and be executable,
  # a bare name is looked up on PATH.
  case "$c" in
    /*) [ -x "$c" ] || continue ;;
    *)  command -v "$c" >/dev/null 2>&1 || continue ;;
  esac
  if DOCKER_HOST="$KIRI_SOCK" "$c" info >/dev/null 2>&1; then
    CLI="$c"; ENDPOINT="$KIRI_SOCK"; break
  fi
  # A plain Docker host: no endpoint override needed.
  if env -u DOCKER_HOST "$c" info >/dev/null 2>&1; then
    CLI="$c"; ENDPOINT=""; break
  fi
done
if [ -z "$CLI" ]; then
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    CLI=docker
    ENDPOINT=""
  else
    echo "找不到可用的容器引擎端点" >&2
    exit 1
  fi
fi

# Use the endpoint that actually answered. Forcing the Kiri socket here
# made every command talk to a socket that may not exist on a
# Docker-only host — the README quick start never mentions Kiri, and
# the MQTT check then reported "authentication failed" against a
# perfectly healthy broker.
if [ -n "$ENDPOINT" ]; then
  DC() { DOCKER_HOST="$ENDPOINT" "$CLI" "$@"; }
else
  DC() { env -u DOCKER_HOST "$CLI" "$@"; }
fi

# ── 1. engine ────────────────────────────────────────────────────────────────
head_ "引擎"
if DC ps --format '{{.Names}}' 2>/dev/null | grep -qx homeassistant; then
  ok "Kiri 在运行"
  ENGINE_MEM=$(ps -eo rss,args --no-headers 2>/dev/null \
    | grep -E '/usr/bin/kiri daemon' | grep -v grep \
    | awk '{s+=$1} END {printf "%.1f", s/1024}')
  [ -n "$ENGINE_MEM" ] && info "引擎内存 ${ENGINE_MEM} MB"
elif docker info >/dev/null 2>&1 && \
     docker ps --filter name=^/homeassistant$ --format '{{.Names}}' 2>/dev/null | grep -qx homeassistant; then
  ok "Docker 在运行"
else
  bad "没有检测到运行中的 stack"
fi

# ── 2. containers ────────────────────────────────────────────────────────────
head_ "容器"
if DC ps --format '{{.Names}}' 2>/dev/null | grep -qx homeassistant; then
  for c in homeassistant nodered matter-hub mosquitto; do
    st=$(DC inspect "$c" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null)
    if [ "$st" = "healthy" ]; then
      ok "$c healthy"
    else
      bad "$c = ${st:-未知}"
    fi
  done
else
  for c in homeassistant nodered matter-hub mosquitto; do
    st=$(docker inspect "$c" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null)
    if [ "$st" = "healthy" ]; then
      ok "$c healthy"
    else
      bad "$c = ${st:-未知}"
    fi
  done
fi

# ── 3. HTTP endpoints ────────────────────────────────────────────────────────
head_ "服务响应"
for entry in "8123:Home Assistant" "1880:Node-RED" "8482:Matter Hub"; do
  port=${entry%%:*}; name=${entry##*:}
  code=$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/" 2>/dev/null)
  if [ -n "$code" ] && [ "$code" != "000" ]; then
    ok "$name (:$port) → HTTP $code"
  else
    bad "$name (:$port) 无响应"
  fi
done

# ── 4. MQTT ──────────────────────────────────────────────────────────────────
head_ "MQTT"
# The password file lives next to the broker config. Older layouts kept it
# one level up; accept both so the check works either way.
PWFILE=""
for candidate in "$STACK_DIR/mosquitto/config/.ha_mqtt_password" \
                 "$STACK_DIR/mosquitto/.ha_mqtt_password"; do
  if [ -r "$candidate" ]; then PWFILE=$candidate; break; fi
done
if [ -n "$PWFILE" ]; then
  PW=$(cat "$PWFILE")
  if DC exec mosquitto mosquitto_pub -h 127.0.0.1 -u "${MQTT_USER:-ha_user}" -P "$PW" \
       -t 'SYS/healthcheck' -m ping >/dev/null 2>&1; then
    ok "认证发布成功"
  else
    bad "认证发布失败"
  fi
else
  bad "读不到密码文件（找过 $STACK_DIR/mosquitto/config/ 和 $STACK_DIR/mosquitto/）"
fi

# ── 5. AppArmor ──────────────────────────────────────────────────────────────
head_ "AppArmor"
if [ -r /sys/kernel/security/apparmor/profiles ]; then
  if grep -q '/usr/sbin/mosquitto' /sys/kernel/security/apparmor/profiles 2>/dev/null; then
    bad "宿主仍有 mosquitto AppArmor profile（Kiri 上会导致 broker exit 3）"
  else
    ok "无残留 mosquitto profile"
  fi
else
  info "无法读取 AppArmor profile 列表（需要 root）"
fi

# ── 6. mDNS ──────────────────────────────────────────────────────────────────
head_ "mDNS"
if command -v avahi-browse >/dev/null 2>&1; then
  nets=$(timeout 6 avahi-browse -rpt _matter._tcp 2>/dev/null \
    | grep -oE 'wlp[0-9a-z]+|wl[a-z0-9]+|enp[0-9]+|eth[0-9]+|docker0|br-[a-f0-9]+|kiri[a-z0-9]*' \
    | sort -u | tr '\n' ' ')
  if [ -z "$nets" ]; then
    info "没有 _matter._tcp 广播（还没创建 Bridge，或 Matter Hub 未运行）"
  else
    leaked=$(echo "$nets" | tr ' ' '\n' | grep -cE '^(docker0|br-|kiri)' || true)
    if [ "$leaked" -gt 0 ]; then
      bad "广播泄漏到内部网卡: $nets"
    else
      ok "广播仅在局域网网卡: $nets"
    fi
  fi
else
  info "没装 avahi-utils，跳过"
fi

# ── 7. HA entities ───────────────────────────────────────────────────────────
head_ "Home Assistant 数据"
run_ha() {
  if DC ps --format '{{.Names}}' 2>/dev/null | grep -qx homeassistant; then
    DC exec homeassistant "$@"
  else
    docker exec homeassistant "$@"
  fi
}
ENT=$(run_ha python3 -c "
import json
try:
    print(len(json.load(open('/config/.storage/core.entity_registry'))['data']['entities']))
except Exception:
    print('')
" 2>/dev/null | tr -d '\r')
if [ -n "$ENT" ]; then
  ok "entity registry: $ENT 个实体"
else
  bad "读不到 entity registry"
fi

# ── 8. recent errors ─────────────────────────────────────────────────────────
head_ "日志"
# Collect the log text first, then count. Piping the count straight out
# of the command chain made an empty result indistinguishable from "no
# errors": if the log could not be read at all, the chain produced
# nothing, the count was empty, and the report said "no ERROR" — a
# broken Home Assistant was reported as a clean log.
# --tail, not --since: Kiri silently ignores --since and returns nothing,
# which made this check report "no ERROR" on an empty log every single
# time — it never actually read the log at all. --tail works on both
# engines.
LOGOUT=""
if DC ps --format '{{.Names}}' 2>/dev/null | grep -qx homeassistant; then
  LOGOUT=$(DC logs homeassistant --tail 2000 2>/dev/null)
fi
if [ -z "$LOGOUT" ]; then
  LOGOUT=$(docker logs homeassistant --tail 2000 2>/dev/null)
fi
if [ -z "$LOGOUT" ]; then
  bad "读不到 homeassistant 日志（无法判断是否有 ERROR）"
else
  ERRS=$(printf '%s' "$LOGOUT" | grep -c ' ERROR ' || true)
  if [ "${ERRS:-0}" -eq 0 ]; then
    ok "最近 2000 行日志无 ERROR"
  else
    bad "最近 2000 行日志有 $ERRS 条 ERROR"
  fi
fi

# ── 9. directory ownership ───────────────────────────────────────────────────
head_ "目录属主"
for entry in "mosquitto/config:1883" "nodered-data:1000"; do
  name=${entry%%:*}; want=${entry##*:}
  dir="$STACK_DIR/$name"
  [ -d "$dir" ] || continue
  got=$(stat -c '%u' "$dir" 2>/dev/null)
  if [ "$got" = "$want" ]; then
    ok "$name 属主 uid $got"
  else
    bad "$name 属主 uid $got（应为 $want）→ sudo $STACK_DIR/scripts/fix-permissions.sh"
  fi
done

# ── verdict ──────────────────────────────────────────────────────────────────
if [ "$PROBLEMS" -eq 0 ]; then
  [ "$QUIET" = "1" ] || printf '\n\033[32m全部正常\033[0m\n'
  exit 0
else
  [ "$QUIET" = "1" ] || printf '\n\033[31m发现 %d 个问题\033[0m\n' "$PROBLEMS"
  exit 1
fi
