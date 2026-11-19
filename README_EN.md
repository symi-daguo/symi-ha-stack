# symi-ha-stack

**A production-grade container stack for Home Assistant + Matter Bridge** — five
services (Home Assistant / Mosquitto / Node-RED / Matter Hub) from one compose
file, runnable on **either Docker or Kiri**, with automatic failure fallback.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/symi-daguo/symi-ha-stack.svg)](https://github.com/symi-daguo/symi-ha-stack/releases)
[![Docs](https://img.shields.io/badge/docs-bilingual-blue.svg)](docs/)

English | [简体中文](./README.md)

---

## Why this exists

The state of the existing pieces:

| Component | Upstream | Status |
|---|---|---|
| Matter Hub | [riddix/home-assistant-matter-hub](https://github.com/riddix/home-assistant-matter-hub) | ✅ mature, official image |
| Kiri engine | [libracoder/kiri](https://github.com/libracoder/kiri) | ⚠️ beta (0.2.x) |
| HA container orchestration | scattered community compose files | ❌ no production-grade integration |

**The gap is the integration layer.** Running those two together on a small home
server hits a series of traps nobody has written down. This project open-sources
that integration along with **five real boot-crash fixes**.

### Measured gains

On a 6.8 GB Ubuntu home server:

| | Docker (snap) | **Kiri 0.2.1** |
|---|---|---|
| Engine resident memory | 159 MB (dockerd + containerd + 4 shims) | **7 MB** (daemon + init) |
| Image disk usage | 8.36 GB | **1.04 GB** |
| Engine cold start | seconds | **333 ms** |
| Stack recovery after a crash | depends on restart policy | **~15 s, whole stack** |

Container footprints are unchanged (HA ~600-770 MB / Matter Hub ~130-190 MB /
Node-RED ~56 MB / Mosquitto ~19 MB). What shrinks is the engine and the images.

---

## Highlights

### 1. Hot-switchable engines with automatic fallback

```bash
./scripts/engine.sh status   # which engine is running
./scripts/engine.sh docker   # switch to Docker
./scripts/engine.sh kiri     # switch to Kiri
```

`scripts/watch.sh` polls every 5 minutes and **falls back to Docker after 3
consecutive unhealthy checks**. That is what makes it safe to run a beta engine
in production: if Kiri regresses, the stack returns on its own within ~15
minutes, no human needed.

Both directions are tested, including the emergency case where the Docker
daemon is not running when you switch to it.

### 2. Five real boot crashes fixed

The most valuable part of this project. Full details in
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

| # | Symptom | Root cause | Fix |
|---|---|---|---|
| 1 | Engine killed in a loop | systemd `ExecStartPost=` (no `-`) failure fails the whole unit | Move rules into a script + `ExecStartPost=-` |
| 2 | Containers have no DNS / no egress | DOCKER-USER chain missing and no default route at boot | Wait 90 s, create the chain ourselves |
| 3 | mosquitto exits 3 forever | A leftover host AppArmor path profile lands in the container | Rename + `apparmor_parser -R` + boot unit |
| 4 | Both engines fight over ports | dockerd autostarts and starts all containers | Disable dockerd autostart, stop it on switch-back |
| 5 | Engine killed at boot | script waits 180s, over systemd's 90s default | shorter waits + explicit `TimeoutStartSec=180` |

#3 is the subtlest: Docker force-applies `docker-default`, which overrides path
profiles, so **the bug is invisible on Docker** and only shows up on runtimes
that apply no profile of their own.

### 3. Matter bridging that works out of the box

- HA entities are mapped to Matter endpoints automatically, visible in Apple Home
- **mDNS advertising is pinned to the LAN interface**
  (`--mdns-network-interface` + `--mdns-strip-global-ipv6`, the upstream fix for
  #361). Without it Matter writes `docker0`/`br-*`/`kiri*` addresses into its
  advertisements too, and a controller may pick one it cannot reach — which
  presents as "device offline".
- Bridge state, pairing code and PIN are persisted and **survive restarts**

### 4. No cloud dependency

HA, MQTT, Node-RED and Matter Hub all live on the LAN. The 13 integration
domains already present in HA (WLED / SONOS / Thread / Sun / custom KNX sync /
go2rtc / bluetooth / …) all keep working offline.

---

## Quick start

### Prerequisites

- Ubuntu 22.04+ / Debian 12+ (AppArmor, systemd, nftables)
- Docker + Compose v2
- Optional: [Kiri 0.2.1+](https://github.com/libracoder/kiri) (to save memory)

### 1. Clone and configure

```bash
git clone https://github.com/symi-daguo/symi-ha-stack.git
cd symi-ha-stack

export STACK_DIR=/opt/ha-stack
sudo mkdir -p "$STACK_DIR"
cp examples/.env.example "$STACK_DIR/.env"
cp examples/docker-compose.yml "$STACK_DIR/docker-compose.yml"
```

Edit `$STACK_DIR/.env` (that is, `/opt/ha-stack/.env`) and fill in at least these three:

```ini
STACK_DIR=/opt/ha-stack
MDNS_INTERFACE=wlan0          # interface name from: ip route show default
HAMH_HA_TOKEN=eyJ...              # HA → avatar → Security → Long-lived access tokens
```

### 2. Generate the MQTT credentials

```bash
STACK_DIR=/opt/ha-stack ./scripts/setup-mqtt.sh
```

### 3. Start

```bash
cd /opt/ha-stack
docker compose up -d
docker compose ps          # all four services should be healthy
```

### 4. Connect Matter

Open `http://<host>:8482` in a browser → **Bridges** → create a Bridge → pick
the entity domains (recommend `domain: switch`) → note the manual pairing code.

Apple Home → Add Accessory → More Options → Manual Code → enter the code.

### 5. (Optional) switch to Kiri to save memory

```bash
# sync images first
STACK_DIR=/opt/ha-stack ./scripts/sync-images.sh

# install the systemd units (autostart + monitoring)
sudo cp systemd/disable-mosquitto-apparmor.service /etc/systemd/system/
sudo systemctl enable --now disable-mosquitto-apparmor.service

# switch over
STACK_DIR=/opt/ha-stack ./scripts/engine.sh kiri
```

---

## Repository layout

```
symi-ha-stack/
├── examples/
│   ├── docker-compose.yml     # four-service stack (paths/interface via .env)
│   ├── .env.example           # configuration template
│   └── kiri.service           # reference unit (TimeoutStartSec and other fixes)
├── scripts/
│   ├── engine.sh              # engine switching (status / docker / kiri)
│   ├── watch.sh               # health polling + automatic fallback
│   ├── kiri-forward.sh        # Kiri bridge egress rules (boot-race handling)
│   ├── disable-mosquitto-apparmor.sh  # unload leftover AppArmor profile
│   ├── setup-mqtt.sh          # generate MQTT credentials
│   ├── fix-permissions.sh      # fix bind-mount dir ownership (container uid)
│   ├── backup.sh               # back up and restore
│   ├── healthcheck.sh          # one-command health check (9 checks)
│   ├── sync-images.sh         # Docker → Kiri image sync
│   └── sanitize-scan.sh        # the sanitisation scan (CI and local runs share it)
├── tests/fixtures/plant-leaks.sh  # planted leaks for the scanner self-test
├── systemd/
│   ├── ha-stack.service               # Docker autostart
│   ├── ha-stack-kiri.service          # Kiri autostart
│   ├── ha-stack-watch.service         # monitoring + fallback
│   └── disable-mosquitto-apparmor.service
├── docs/
│   ├── OPERATIONS.md          # operations manual (Chinese)
│   ├── OPERATIONS_EN.md       # operations manual (English)
│   └── TROUBLESHOOTING.md     # the five boot crashes in detail
├── install/install.sh         # one-shot installer
├── CHANGELOG.md
├── CONTRIBUTING.md
├── SECURITY.md
└── LICENSE (MIT)
```

---

## Documentation

| Document | Contents |
|---|---|
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | Operations: day-to-day, backup, upgrade, monitoring |
| [docs/OPERATIONS_EN.md](docs/OPERATIONS_EN.md) | Same, in English |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Full diagnosis and evidence for the five boot crashes |

---

## Credits and scope

This project contains **no upstream code** — it is purely an integration and
fix layer:

- [riddix/home-assistant-matter-hub](https://github.com/riddix/home-assistant-matter-hub) — Matter bridge
- [libracoder/kiri](https://github.com/libracoder/kiri) — container engine
- [Home Assistant](https://www.home-assistant.io/) — home automation platform
- [Eclipse Mosquitto](https://mosquitto.org/) — MQTT broker
- [Node-RED](https://nodered.org/) — low-code automation

Kiri is still beta (0.2.x). **Always deploy the automatic fallback** — that is
exactly what `watch.sh` in this project is for.

---

## Versioning

Current: **1.1.4**

Semantic versioning from here: patch releases (1.1.x) for fixes and docs,
minor releases (1.2.0) for features.

## License

[MIT](LICENSE)
