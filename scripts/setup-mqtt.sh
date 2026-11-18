#!/usr/bin/env bash
# setup-mqtt.sh — create the MQTT user, password file and broker config.
#
# Generates:
#   $STACK_DIR/mosquitto/config/.ha_mqtt_password   (0600, random password)
#   $STACK_DIR/mosquitto/config/passwd              (0640, mosquitto hash)
#   $STACK_DIR/mosquitto/config/mosquitto.conf      (0644, broker config)
#
# Run once before the first start. Safe to re-run: it regenerates the
# password, so HA's MQTT integration must be updated afterwards.
set -euo pipefail

STACK_DIR="${STACK_DIR:-/opt/ha-stack}"
MQTT_USER="${MQTT_USER:-ha_user}"
CFG="$STACK_DIR/mosquitto/config"

mkdir -p "$CFG" "$STACK_DIR/mosquitto/data" "$STACK_DIR/mosquitto/log"

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
# mosquitto_passwd hashes with PBKDF2-SHA512 when given -b.
docker run --rm -i eclipse-mosquitto:2.0 \
  mosquitto_passwd -b -c /dev/stdout "$MQTT_USER" "$PASS" > "$CFG/passwd" 2>/dev/null \
  || {
    # Fallback: run the tool inside a container that can write to a bind mount.
    docker run --rm -v "$CFG:/out" eclipse-mosquitto:2.0 \
      sh -c "mosquitto_passwd -b -c /out/passwd '$MQTT_USER' '$PASS'" >/dev/null
  }
chmod 640 "$CFG/passwd"

# ── broker config ───────────────────────────────────────────────────────────
cat > "$CFG/mosquitto.conf" <<'EOF'
# Eclipse Mosquitto broker config — managed by symi-ha-stack.
# Regenerate with scripts/setup-mqtt.sh

persistence true
persistence_location /mosquitto/data/

# Only loopback: external devices need 0.0.0.0, see the compose file.
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
echo "  用户名: $MQTT_USER"
echo "  密码  : $PASS"
echo "  密码文件: $CFG/.ha_mqtt_password"
echo
echo "请在 HA 的 Mosquitto 集成里填入同样的用户名和密码。"
