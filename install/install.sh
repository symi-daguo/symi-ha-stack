#!/usr/bin/env bash
# install.sh — set up the stack on a fresh host.
#
#   sudo ./install.sh                    # install into /opt/ha-stack, start on Docker
#   STACK_DIR=/srv/ha sudo ./install.sh  # different location
#   ./install.sh --no-start              # install only
#   ./install.sh --no-systemd            # install only, leave systemd units alone
#   ./install.sh --yes                   # do not prompt
#
# This script does NOT create the Home Assistant long-lived access token —
# that has to be done in the HA UI. It generates the MQTT credentials, copies
# the compose file and the scripts, and starts the stack.
set -euo pipefail

STACK_DIR="${STACK_DIR:-/opt/ha-stack}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
START=1
ASSUME_YES=0
INSTALL_SYSTEMD=1

while [ $# -gt 0 ]; do
  case "$1" in
    --no-start) START=0 ;;
    --no-systemd) INSTALL_SYSTEMD=0 ;;
    --yes|-y)   ASSUME_YES=1 ;;
    --stack-dir) STACK_DIR="$2"; shift ;;
    -h|--help)
      sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
  shift
done

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m警告: %s\033[0m\n' "$*"; }
die() { printf '\033[31m错误: %s\033[0m\n' "$*" >&2; exit 1; }

# ── locate a working container engine ───────────────────────────────────────
# The socket path differs between plain Docker (/var/run/docker.sock), snap
# Docker (/var/snap/docker/...) and Kiri (/run/kiri/docker.sock). Some engines
# only accept their own socket access list from a matching client, so probe
# both the endpoint and the CLI.
DOCKER_BIN="${DOCKER_BIN:-docker}"
DOCKER_ENDPOINT="${DOCKER_ENDPOINT:-}"
KIRI_DOCKER="${KIRI_DOCKER:-}"

CLIS=("$DOCKER_BIN")
[ -n "$KIRI_DOCKER" ] && CLIS+=("$KIRI_DOCKER")
# The real home directory, not $HOME: under `sudo` $HOME is /root, so a
# client installed in the invoking user's ~/.local/bin would be missed.
REAL_HOME="${REAL_HOME:-$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)}"
[ -n "$REAL_HOME" ] || REAL_HOME="$HOME"
for c in /usr/local/bin/docker-kiri "$REAL_HOME/.local/bin/docker-kiri" \
         "$HOME/.local/bin/docker-kiri"; do
  [ -x "$c" ] && CLIS+=("$c")
done

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

find_engine() {
  local cli sock
  if [ -n "$DOCKER_ENDPOINT" ]; then
    for cli in "${CLIS[@]}"; do try_endpoint "$cli" "$DOCKER_ENDPOINT" && return 0; done
    return 1
  fi
  for cli in "${CLIS[@]}"; do try_endpoint "$cli" "" && return 0; done
  for sock in /var/run/docker.sock \
              /var/snap/docker/common/run/docker.sock \
              /var/snap/docker/current/run/docker.sock \
              /run/snap.docker.sock \
              /run/kiri/docker.sock; do
    [ -S "$sock" ] || continue
    for cli in "${CLIS[@]}"; do try_endpoint "$cli" "unix://$sock" && return 0; done
  done
  return 1
}

# ── prerequisites ────────────────────────────────────────────────────────────
say "检查依赖"
command -v docker >/dev/null 2>&1 || command -v docker-kiri >/dev/null 2>&1 \
  || die "找不到 docker，请先安装 Docker"
if ! find_engine; then
  cat >&2 <<EOF
错误: 找不到可用的容器引擎端点。

已尝试的端点:
  - \$DOCKER_HOST / \$DOCKER_ENDPOINT
  - /var/run/docker.sock                    (标准 Docker)
  - /var/snap/docker/common/run/docker.sock  (snap Docker)
  - /run/kiri/docker.sock                  (Kiri)

已尝试的客户端:
$(printf '  - %s\n' "${CLIS[@]}")

请先启动引擎:
  systemctl start snap.docker.dockerd.service   # snap Docker
  systemctl start kiri.service                   # Kiri

如果报 permission denied，把用户加入对应组后重新登录:
  sudo usermod -aG docker \$USER    # 标准/snap Docker
  sudo usermod -aG kiri   \$USER    # Kiri
EOF
  exit 1
fi
DOCKER_BIN="$CLI_OK"
echo "  容器引擎: ${DOCKER_HOST:-默认}  (客户端: $DOCKER_BIN)"
"$DOCKER_BIN" compose version >/dev/null 2>&1 \
  || die "需要 Docker Compose v2 (docker compose)"
echo "  compose: $("$DOCKER_BIN" compose version --short 2>/dev/null)"
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
  export STACK_DIR DOCKER_BIN
  "$STACK_DIR/scripts/setup-mqtt.sh"
fi

# ── permissions ─────────────────────────────────────────────────────────────
# The bind-mounted data directories must be owned by the uid each container
# runs as (mosquitto 1883, node-red 1000), otherwise those containers exit
# with a permission error on a path that clearly exists.
if [ "$(id -u)" = "0" ]; then
  say "修正数据目录属主"
  export STACK_DIR
  "$STACK_DIR/scripts/fix-permissions.sh" || true
else
  warn "非 root 运行，无法修改数据目录属主"
  warn "启动前请执行: sudo $STACK_DIR/scripts/fix-permissions.sh"
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
# Skipped when --no-systemd is given. This matters for testing: installing
# the units replaces the live ones, so a trial install into a scratch
# directory must not point the running system at that scratch directory.
UNITDIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
if [ "$INSTALL_SYSTEMD" = "1" ] && [ -d "$UNITDIR" ] && command -v systemctl >/dev/null 2>&1; then
  say "安装 systemd user unit"
  mkdir -p "$UNITDIR"
  # Rewrite both the ExecStart path AND the Environment=STACK_DIR line.
  # Rewriting only the path would leave STACK_DIR at its built-in default
  # (/opt/ha-stack), so the scripts would operate on the wrong directory
  # when the stack is installed somewhere else.
  for unit in ha-stack-watch ha-stack-kiri; do
    sed -e "s|/opt/ha-stack|$STACK_DIR|g" \
        -e "s|^Environment=STACK_DIR=.*|Environment=STACK_DIR=$STACK_DIR|" \
        "$REPO_DIR/systemd/$unit.service" > "$UNITDIR/$unit.service"
  done
  echo "  已写入 $UNITDIR/ha-stack-watch.service, ha-stack-kiri.service"
  echo "  （STACK_DIR=$STACK_DIR）"
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
    if [ "$ASSUME_YES" = "0" ]; then
      read -r -p "  仍然启动吗？[y/N] " a
      [ "${a,,}" = "y" ] || exit 0
    fi
  fi
  ( cd "$STACK_DIR" && "$DOCKER_BIN" compose up -d )
  echo
  "$DOCKER_BIN" compose -f "$STACK_DIR/docker-compose.yml" ps
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
