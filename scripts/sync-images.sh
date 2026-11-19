#!/usr/bin/env bash
# sync-images.sh — copy container images from Docker into Kiri.
#
# Kiri has no registry client of its own; images are moved with the
# standard `docker save` / `docker load` pipe.
#
#   ./sync-images.sh              # sync every image the stack needs
#   ./sync-images.sh <image>...   # sync specific images
set -euo pipefail

KIRI_SOCK="${KIRI_SOCK:-unix:///run/kiri/docker.sock}"
KIRI_DOCKER="${KIRI_DOCKER:-docker}"

IMAGES=(
  "ghcr.io/home-assistant/home-assistant:2026.11.1"
  "eclipse-mosquitto:2.0"
  "nodered/node-red:latest"
  "ghcr.io/riddix/home-assistant-matter-hub:1.7.18"
)

[ $# -gt 0 ] && IMAGES=("$@")

for img in "${IMAGES[@]}"; do
  echo "=== $img ==="
  if docker image inspect "$img" >/dev/null 2>&1; then
    echo "  本地已有，直接加载"
  else
    echo "  拉取…"
    docker pull "$img"
  fi
  docker save "$img" | env "DOCKER_HOST=$KIRI_SOCK" "$KIRI_DOCKER" load
  echo "  ✓ 已同步到 Kiri"
done

echo
echo "完成。验证："
echo "  DOCKER_HOST=$KIRI_SOCK $KIRI_DOCKER images"
