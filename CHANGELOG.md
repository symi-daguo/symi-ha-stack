# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

## [1.0.1] — 2026-11-19

Fixes found by actually running the published repository end to end: a fresh
clone, a trial install into a scratch directory, and booting the stack.

### Fixed

- **Shell scripts were not executable in the git index.** A fresh clone landed
  every script as `100644`, so `./scripts/engine.sh` failed with
  `Permission denied` for anyone following the README verbatim. The local
  filesystem bits were set, but the index was never updated.
- **`setup-mqtt.sh` assumed `/var/run/docker.sock`.** It now probes the known
  socket locations (plain Docker, snap Docker, Kiri) and tries a
  Kiri-compatible client as well — some engines only accept their own socket
  access list from a matching client, and the stock `docker` CLI gets
  `permission denied` on a socket a compatible CLI opens fine.
- **A failed `setup-mqtt.sh` left an empty `passwd` file behind.** An empty
  password file makes the broker refuse to start. The file is now written to
  a temporary path and only moved into place once it is non-empty.
- **The `passwd` file was created by root**, so the broker (uid 1883) could
  not read it and the installing user could not chmod it. It is now generated
  inside the container as uid 1883, giving it the right owner directly.
- **`install.sh` reported "Docker daemon is not running" on a Kiri-only
  host.** It now uses the same endpoint probing as `setup-mqtt.sh`.
- **`install.sh` replaced the live systemd units during a trial install.**
  Installing into a scratch directory pointed the running system at that
  scratch directory. Added `--no-systemd` for trial runs.
- **`--mdns-strip-global-ipv6` is not in the published Matter Hub images.**
  It exists in upstream master but not in 1.x / 2.0.7, where it makes the
  container exit with `Unknown arguments`. It is now opt-in via
  `MATTER_HUB_EXTRA_ARGS`, and the compose file uses shell form so an empty
  value does not pass an empty argument.
- **`container_name` was hardcoded**, so a second copy of the stack could not
  run on the same engine. Now prefixed with `CONTAINER_PREFIX`.
- **Bind-mounted directories must be owned by the uid the container runs as.**
  mosquitto (1883) and node-red (1000) both exited with a permission error
  on a path that clearly exists. Added `scripts/fix-permissions.sh` and
  wired it into the installer.
- **The FORWARD script could outlast the systemd start timeout.**
  `ExecStartPre` (up to 90s) plus `ExecStartPost` (up to 90s) exceeded
  systemd's 90s `TimeoutStartSec` default, so systemd killed the
  `ExecStartPost` and the engine with it. This only shows up once the Docker
  daemon is not started at boot — the chain never appears, so the wait always
  burns out the timeout. Waits shortened to 10s / 20s and
  `TimeoutStartSec=180` set explicitly. See
  [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for the full story.

### Added

- `examples/kiri.service` — reference engine unit carrying the
  `TimeoutStartSec` and `ExecStartPost=-` fixes.
- `scripts/fix-permissions.sh` — set the bind-mount directory ownership to
  the uid each container runs as.
- `--no-systemd` option for `install/install.sh`.

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
