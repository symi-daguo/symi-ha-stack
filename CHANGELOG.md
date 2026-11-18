# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.0.0] — 2026-11-18

First public release. Extracted from a production deployment that had been
running a Home Assistant + Matter stack on the Kiri container engine.

### Added

- **Four-service stack** — Home Assistant, Mosquitto, Node-RED and Matter Hub in
  one compose file (`examples/docker-compose.yml`), fully parameterised through
  `.env` (no hardcoded paths or interface names).
- **Dual-engine switching** (`scripts/engine.sh`) — `status` / `docker` / `kiri`.
  Handles port-release waits and stray-container cleanup on both directions.
- **Automatic fallback** (`scripts/watch.sh`) — polls every 5 minutes and
  switches back to Docker after 3 consecutive unhealthy checks.
- **Kiri bridge egress rules** (`scripts/kiri-forward.sh`) — waits for the
  `DOCKER-USER` chain and the default route, and creates the chain itself when
  Docker is not up yet.
- **AppArmor cleanup** (`scripts/disable-mosquitto-apparmor.sh` +
  `systemd/disable-mosquitto-apparmor.service`) — unloads the leftover host
  `mosquitto` path profile that breaks the broker on runtimes without a default
  profile.
- **MQTT credential generator** (`scripts/setup-mqtt.sh`).
- **Image sync helper** (`scripts/sync-images.sh`) — `docker save | docker load`
  into Kiri.
- **Systemd units** — Docker stack, Kiri stack, watch/fallback service, and the
  AppArmor cleanup unit.
- **Bilingual documentation** — `README.md` (Chinese) and `README_EN.md`
  (English), `docs/OPERATIONS.md` and `docs/OPERATIONS_EN.md`, plus
  `docs/TROUBLESHOOTING.md`.
- **One-shot installer** (`install/install.sh`).

### Fixed

- **systemd `ExecStartPost=` without the `-` prefix** made an occasional
  `iptables` failure fail the entire `kiri.service` unit, killing the engine
  in a restart loop.
- **Boot-time races** — the `DOCKER-USER` chain does not exist and no default
  route is present when the engine starts, leaving bridge containers without DNS
  or egress.
- **Leftover host AppArmor `mosquitto` profile** attached to the container's
  binary on runtimes that apply no default profile, making the broker exit 3
  in an infinite retry loop. Invisible on Docker because `docker-default`
  overrides path profiles.
- **Both engines autostarting at once** and fighting over the host ports
  (8123 / 1880 / 1883 / 8482); whichever started first won and the other
  crash-looped.
- **Health monitor's "engine not present" branch** waited forever when *both*
  engines were down, so the fallback never triggered.
- **`compose down` returned before the ports were actually released**, letting
  the new stack fail to bind and crash-loop.
- **HA bluetooth warnings** — `cap_add: [NET_ADMIN, NET_RAW]` for the
  container.
- **Mosquitto container user** — explicit `user: "1883:1883"` so the broker can
  read its own config on engines without a DAC_OVERRIDE-capable root.

### Measured

| | Docker (snap) | Kiri 0.2.1 |
|---|---|---|
| Engine resident memory | 159 MB | 7 MB |
| Image disk usage | 8.36 GB | 1.04 GB |
| Engine cold start | seconds | 333 ms |
| Stack recovery after a crash | restart-policy dependent | ~15 s |

[1.0.0]: https://github.com/symi-daguo/symi-ha-stack/releases/tag/v1.0.0
