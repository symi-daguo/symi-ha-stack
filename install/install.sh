#!/usr/bin/env bash
# install.sh — set up the stack on a fresh host.
#
#   sudo ./install.sh                    # install into /opt/ha-stack, start on Docker
#   STACK_DIR=/srv/ha sudo ./install.sh  # different location
#   ./install.sh --no-start              # install only
#
# This script does NOT create the Home Assistant long-lived access token —
# that has to be done in the HA UI. It generates the MQTT credentials, copies
# the compose file and the scripts, and starts the stack.
set -euo pipefail

STACK_DIR="${STACK_DIR:-/opt/ha-stack}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
START=1
ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --no-start) START=0 ;;
    --yes|-y)   ASSUME_YES=1 ;;
    --stack-dir) STACK_DIR="$2"; shift ;;
    -h|--help)
      sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
  shift
done

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m警告: %s\033[0m\n' "$*"; }
die() { printf '\033[31m错误: %s\033[0m\n' "$*" >&2; exit 1; }

# ── prerequisites ────────────────────────────────────────────────────────────
say "检查依赖"
command -v docker >/dev/null 2>&1 || die "找不到 docker，请先安装 Docker"
docker compose version >/dev/null 2>&1 || die "需要 Docker Compose v2 (docker compose)"
docker info >/dev/null 2>&1 || die "Docker daemon 没运行，先启动它"
echo "  docker: $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
command -v ss >/dev/null 2>&1 || warn "找不到 ss (iproute2)，端口检查会不准"

# ── layout ───────────────────────────────────────────────────────────────────
say "创建目录结构 $STACK_DIR"
mkdir -p "$STACK_DIR"/{scripts,systemd,ha-config,matter-hub-data,nodered-data,backup}
mkdir -p "$STACK_DIR"/mosquitto/{config,data,log}

say "复制文件"
cp "$REPO_DIR/examples/docker-compose.yml" "$STACK_DIR/docker-compose.yml"
cp "$REPO_DIR/scripts/"*.sh "$STACK_DIR/scripts/"
chmod +x "$STACK_DIR/scripts/"*.sh

if [ ! -f "$STACK_DIR/.env" ]; then
  cp "$REPO_DIR/examples/.env.example" "$STACK_DIR/.env"
  chmod 600 "$STACK_DIR/.env"
  echo "  已生成 $STACK_DIR/.env（请编辑里面的 HAMH_HA_TOKEN 和 MDNS_INTERFACE）"
else
  echo "  $STACK_DIR/.env 已存在，保留原文件"
fi

# ── MQTT credentials ─────────────────────────────────────────────────────────
say "配置 MQTT"
if [ -f "$STACK_DIR/mosquitto/config/.ha_mqtt_password" ]; then
  echo "  凭据已存在，跳过"
else
  export STACK_DIR
  "$STACK_DIR/scripts/setup-mqtt.sh"
fi

# ── AppArmor ─────────────────────────────────────────────────────────────────
if [ "$(id -u)" = "0" ] && [ -f /etc/apparmor.d/mosquitto ]; then
  say "处理残留的 AppArmor profile"
  warn "检测到 /etc/apparmor.d/mosquitto —— 在不套默认 profile 的运行时上会让容器读不到配置"
  if [ "$ASSUME_YES" = "1" ]; then
    cp "$REPO_DIR/systemd/disable-mosquitto-apparmor.service" /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable --now disable-mosquitto-apparmor.service
  else
    read -r -p "  现在卸载它吗？[y/N] " a
    if [ "${a,,}" = "y" ]; then
      cp "$REPO_DIR/systemd/disable-mosquitto-apparmor.service" /etc/systemd/system/
      systemctl daemon-reload
      systemctl enable --now disable-mosquitto-apparmor.service
    fi
  fi
fi

# ── systemd (user units) ─────────────────────────────────────────────────────
if [ -d "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user" ] || [ -d "$HOME/.config/systemd/user" ]; then
  say "安装 systemd user unit"
  UNITDIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  mkdir -p "$UNITDIR"
  sed "s|/opt/ha-stack|$STACK_DIR|g" "$REPO_DIR/systemd/ha-stack-watch.service" > "$UNITDIR/ha-stack-watch.service"
  sed "s|/opt/ha-stack|$STACK_DIR|g" "$REPO_DIR/systemd/ha-stack-kiri.service" > "$UNITDIR/ha-stack-kiri.service"
  systemctl --user daemon-reload
  if systemctl --user enable ha-stack-watch.service 2>/dev/null; then
    echo "  ha-stack-watch.service 已启用（自动回落监控）"
  else
    warn "无法启用 ha-stack-watch.service（可稍后手动处理）"
  fi
fi

# ── start ────────────────────────────────────────────────────────────────────
if [ "$START" = "1" ]; then
  say "启动栈"
  if ! grep -qE '^HAMH_HA_TOKEN=.+' "$STACK_DIR/.env" || \
     grep -q 'REPLACE_WITH' "$STACK_DIR/.env"; then
    warn ".env 里的 HAMH_HA_TOKEN 还没填 —— 先在 HA 里生成长期访问令牌"
    warn "现在启动 Matter Hub 会失败（它需要 token），其他服务不受影响"
    read -r -p "  仍然启动吗？[y/N] " a
    [ "${a,,}" = "y" ] || exit 0
  fi
  ( cd "$STACK_DIR" && docker compose up -d )
  echo
  docker compose -f "$STACK_DIR/docker-compose.yml" ps
fi

say "完成"
cat <<EOF

下一步：
  1. 编辑 $STACK_DIR/.env
       HAMH_HA_TOKEN  ← HA → 头像 → 安全 → 长期访问令牌
       MDNS_INTERFACE ← ip route show default 看到的网卡名
  2. 启动:  cd $STACK_DIR && docker compose up -d
  3. Matter: 浏览器打开 http://<host>:8482 → Bridges → 创建 Bridge
  4. Apple Home → 添加配件 → 更多选项 → 手动代码

文档: https://github.com/symi-daguo/symi-ha-stack
EOF
