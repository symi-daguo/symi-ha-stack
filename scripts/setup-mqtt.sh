#!/usr/bin/env bash
# setup-mqtt.sh — create the MQTT user, password file and broker config.
#
# Generates:
#   $STACK_DIR/mosquitto/config/.ha_mqtt_password   (0600, random password)
#   $STACK_DIR/mosquitto/config/passwd              (0640, mosquitto password hash)
#   $STACK_DIR/mosquitto/config/mosquitto.conf      (0644, broker config)
#
# Run once before the first start. Re-running is a no-op unless the password
# file is deleted first — regenerating the password means the HA MQTT
# integration has to be updated to match.
set -euo pipefail

STACK_DIR="${STACK_DIR:-/opt/ha-stack}"
MQTT_USER="${MQTT_USER:-ha_user}"
CFG="$STACK_DIR/mosquitto/config"

mkdir -p "$CFG" "$STACK_DIR/mosquitto/data" "$STACK_DIR/mosquitto/log"

# ── locate a working Docker endpoint ────────────────────────────────────────
# The socket path is not the same everywhere: plain Docker uses
# /var/run/docker.sock, snap Docker uses a versioned path under
# /var/snap/docker/, and Kiri uses /run/kiri/docker.sock. Probe instead of
# assuming, and fail with a message that says what to do.
DOCKER_BIN="${DOCKER_BIN:-docker}"
DOCKER_ENDPOINT="${DOCKER_ENDPOINT:-}"
# Extra CLI candidates. Some container engines (Kiri) only accept their own
# socket access list from a matching client — the stock docker CLI gets
# "permission denied" on a socket that a compatible CLI opens fine.
KIRI_DOCKER="${KIRI_DOCKER:-}"

CLIS=("$DOCKER_BIN")
[ -n "$KIRI_DOCKER" ] && CLIS+=("$KIRI_DOCKER")
for c in /usr/local/bin/docker-kiri "$HOME/.local/bin/docker-kiri"; do
  [ -x "$c" ] && CLIS+=("$c")
done

# Probe one (cli, endpoint) pair. On success sets CLI_OK and exports
# DOCKER_HOST so the later `docker run` calls talk to the same engine.
CLI_OK=""
try_endpoint() {
  local cli=$1 ep=$2
  if [ -n "$ep" ]; then
    DOCKER_HOST="$ep" "$cli" info >/dev/null 2>&1 || return 1
    export DOCKER_HOST="$ep"
  else
    env -u DOCKER_HOST "$cli" info >/dev/null 2>&1 || return 1
    unset DOCKER_HOST
  fi
  CLI_OK=$cli
  return 0
}

find_docker() {
  # 1. explicit endpoint
  if [ -n "$DOCKER_ENDPOINT" ]; then
    local cli
    for cli in "${CLIS[@]}"; do
      try_endpoint "$cli" "$DOCKER_ENDPOINT" && return 0
    done
    return 1
  fi
  # 2. whatever the environment already points at
  local cli
  for cli in "${CLIS[@]}"; do
    try_endpoint "$cli" "" && return 0
  done
  # 3. known socket locations
  local sock
  for sock in /var/run/docker.sock \
              /var/snap/docker/common/run/docker.sock \
              /var/snap/docker/current/run/docker.sock \
              /run/snap.docker.sock \
              /run/kiri/docker.sock; do
    [ -S "$sock" ] || continue
    for cli in "${CLIS[@]}"; do
      try_endpoint "$cli" "unix://$sock" && return 0
    done
  done
  return 1
}

if ! find_docker; then
  cat >&2 <<EOF
错误: 找不到可用的 Docker 端点，无法生成 MQTT 凭据。

已尝试的端点:
  - \$DOCKER_HOST / \$DOCKER_ENDPOINT
  - /var/run/docker.sock                    (标准 Docker)
  - /var/snap/docker/common/run/docker.sock  (snap Docker)
  - /run/kiri/docker.sock                  (Kiri)

已尝试的客户端:
$(printf '  - %s\n' "${CLIS[@]}")

如果报的是 permission denied，说明你的用户没有该 socket 的访问权限：
  - 标准 Docker: 把用户加入 docker 组 (sudo usermod -aG docker \$USER)
  - Kiri:         把用户加入 kiri 组   (sudo usermod -aG kiri   \$USER)
然后重新登录（或用 newgrp docker / newgrp kiri）使组生效。

也可以显式指定端点和客户端:
  DOCKER_ENDPOINT=unix:///var/run/docker.sock \\
  DOCKER_BIN=docker ./scripts/setup-mqtt.sh
EOF
  exit 1
fi
DOCKER_BIN="$CLI_OK"
echo "  Docker 端点: ${DOCKER_HOST:-默认}  (客户端: $DOCKER_BIN)"

# ── password ────────────────────────────────────────────────────────────────
if [ -f "$CFG/.ha_mqtt_password" ]; then
  echo "密码文件已存在: $CFG/.ha_mqtt_password"
  echo "如需重置，删除该文件后重跑本脚本。"
  exit 0
fi

PASS=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 24)
printf '%s' "$PASS" > "$CFG/.ha_mqtt_password"
chmod 600 "$CFG/.ha_mqtt_password"

# ── mosquitto password file ────────────────────────────────────────────────
# mosquitto_passwd writes the hash into the file given with -c.
#
# Three pitfalls this avoids:
#   * An empty password file makes the broker refuse to start, so write to a
#     temp file and only move it into place once it is non-empty.
#   * The file must end up readable by the broker's uid (1883). Generating it
#     inside the container as uid 1883 gives it the right owner directly —
#     a file created by root would be 0600 root:root and unreadable by the
#     broker.
#   * The container's uid needs write access to the target directory. The
#     directory is normally owned by the installing user, so temporarily
#     widen it and restore it afterwards.
TMP_PASSWD=$(mktemp)
trap 'rm -f "$TMP_PASSWD"' EXIT
: > "$TMP_PASSWD"

DIR_MODE_BEFORE=$(stat -c '%a' "$CFG" 2>/dev/null || echo 755)
chmod 777 "$CFG" 2>/dev/null || true

"$DOCKER_BIN" run --rm \
  -e MQTT_USER="$MQTT_USER" -e MQTT_PASS="$PASS" \
  -v "$CFG:/out" \
  --user 1883:1883 \
  eclipse-mosquitto:2.0 \
  sh -c 'mosquitto_passwd -b -c /out/passwd.tmp "$MQTT_USER" "$MQTT_PASS"' >/dev/null 2>&1 || true

if [ -s "$CFG/passwd.tmp" ]; then
  mv "$CFG/passwd.tmp" "$CFG/passwd"
else
  rm -f "$CFG/passwd.tmp"
  # The bind mount may not be writable; capture stdout instead.
  "$DOCKER_BIN" run --rm -i \
    -e MQTT_USER="$MQTT_USER" -e MQTT_PASS="$PASS" \
    eclipse-mosquitto:2.0 \
    sh -c 'mosquitto_passwd -b -c /dev/stdout "$MQTT_USER" "$MQTT_PASS"' > "$TMP_PASSWD" 2>/dev/null || true
  if [ ! -s "$TMP_PASSWD" ]; then
    chmod "$DIR_MODE_BEFORE" "$CFG" 2>/dev/null || true
    echo "错误: mosquitto_passwd 没能生成密码文件" >&2
    echo "提示: 如果 $CFG 目录不可写，用 sudo 重新运行本脚本" >&2
    exit 1
  fi
  cp "$TMP_PASSWD" "$CFG/passwd"
fi

chmod "$DIR_MODE_BEFORE" "$CFG" 2>/dev/null || true

if [ ! -s "$CFG/passwd" ]; then
  echo "错误: 生成的 passwd 文件为空" >&2
  exit 1
fi
# 0640: owner rw, group r. The broker runs as 1883:1883 and reads it via
# the group bit. The password itself is printed to stdout below, so the
# installing user does not need to read this file back.
# The container created this file as uid 1883 with mode 0600, so it is
# already owned by the broker's uid and therefore readable by the broker —
# no chown/chmod needed, and no privilege required. (Changing either would
# need ownership we do not have as an unprivileged installer.)
#
# The hash stays 0600 deliberately: it is only read by the broker itself.
# The plaintext password is in .ha_mqtt_password (0600, owned by the
# installer) and is printed to stdout below.

# ── broker config ───────────────────────────────────────────────────────────
cat > "$CFG/mosquitto.conf" <<'EOF'
# Eclipse Mosquitto broker config — managed by symi-ha-stack.
# Regenerate with scripts/setup-mqtt.sh

persistence true
persistence_location /mosquitto/data/

# Only loopback. To let LAN devices connect, change this AND the compose
# file's port mapping.
listener 1883 127.0.0.1
protocol mqtt

# WebSocket, used by the HA Mosquitto integration.
listener 9001 127.0.0.1
protocol websockets

allow_anonymous false
password_file /mosquitto/config/passwd

log_dest stdout
log_type error
log_type warning
log_type notice
log_type information

# Raise the limit — a busy HA instance opens many short-lived connections.
max_connections -1
EOF
chmod 644 "$CFG/mosquitto.conf"

# mosquitto runs as uid 1883 inside the container; the bind-mounted files
# must be readable by it.
chown -R 1883:1883 "$STACK_DIR/mosquitto" 2>/dev/null || true

echo "✓ MQTT broker 配置完成"
echo "  用户名  : $MQTT_USER"
echo "  密码    : $PASS"
echo "  密码文件: $CFG/.ha_mqtt_password"
echo
echo "请在 HA 的 Mosquitto 集成里填入同样的用户名和密码。"
