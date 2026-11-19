# Operations Manual

简体中文 | [English](./OPERATIONS.md)

> Contents
> 1. [Day-to-day](#1-day-to-day)
> 2. [Monitoring and automatic fallback](#2-monitoring-and-automatic-fallback)
> 3. [Backup and restore](#3-backup-and-restore)
> 4. [Upgrading](#4-upgrading)
> 5. [Troubleshooting](#5-troubleshooting)
> 6. [Configuration](#6-configuration)
> 7. [Never do this](#7-never-do-this)

---

## 1. Day-to-day

### Basic commands

```bash
cd /opt/ha-stack

docker compose ps                  # container status
docker compose logs -f homeassistant
docker compose restart homeassistant
docker compose up -d               # start everything
docker compose down                # stop everything
```

### Switching engines

```bash
/opt/ha-stack/scripts/engine.sh status   # current engine + container status
/opt/ha-stack/scripts/engine.sh docker   # switch to Docker
/opt/ha-stack/scripts/engine.sh kiri     # switch to Kiri
```

Switching works in both directions: the target side stops the other stack, waits
for the ports to be released, cleans up stray containers, and — when switching
back to Kiri — stops the idle Docker daemon.

### Service endpoints

| Service | URL |
|---|---|
| Home Assistant | http://127.0.0.1:8123/ |
| Node-RED | http://127.0.0.1:1880/ |
| Matter Hub Web UI | http://127.0.0.1:8482/ |
| MQTT (local) | 127.0.0.1:1883 |

All three web UIs listen on `0.0.0.0`, so `http://<host-ip>:8123` works from
anywhere on the LAN.

### MQTT client

```bash
# publish
mosquitto_pub -h 127.0.0.1 -u ha_user -P "$(cat /opt/ha-stack/mosquitto/config/.ha_mqtt_password)" \
  -t 'home/sensor/test' -m 'hello'

# subscribe
mosquitto_sub -h 127.0.0.1 -u ha_user -P "$(cat /opt/ha-stack/mosquitto/config/.ha_mqtt_password)" \
  -t '#' -v
```

---

## 2. Monitoring and automatic fallback

`ha-stack-watch.service` (a systemd user unit) polls every 5 minutes and writes
to `/opt/ha-stack/watch.log`:

```
2026-11-18 15:29:31 OK 引擎=8MB HA=561MB 剩avail=3391MB swap=0MB
```

**Three consecutive unhealthy checks → automatic fallback to Docker.** This is
what makes it safe to run a beta engine (Kiri) in production.

Three possible states:

| State | Behaviour |
|---|---|
| Kiri has the containers | normal inspection |
| Kiri has none, Docker has | already fallen back, stand by |
| **Neither has them** | **engine failure → counted → triggers fallback** |

```bash
tail -f /opt/ha-stack/watch.log
systemctl --user status ha-stack-watch.service
```

### Reading container memory

**Read the cgroup, not `.State.Pid`** — Kiri's `.State.Pid` points at s6-init
(~108 KB) while Docker's points at the real process. `memory.current` is
engine-independent and always the true footprint.

```bash
DK="env DOCKER_HOST=unix:///run/kiri/docker.sock docker-kiri"
for c in homeassistant matter-hub nodered mosquitto; do
  pid=$($DK inspect $c --format '{{.State.Pid}}')
  cg=$(awk -F: '/^0::/{print $3}' /proc/$pid/cgroup)
  echo "$c $(awk '{printf "%.0f MB", $1/1048576}' /sys/fs/cgroup$cg/memory.current)"
done
```

**Gotcha:** `free` prints localized headers, so on a Chinese-locale machine
`awk '/^Mem:/'` never matches. Use `sed -n '2p'` / `'3p'` by line number.

**Gotcha:** take the cgroup path from `/proc/PID/cgroup` (authoritative) — do
NOT glob the engine directory, it holds stale cgroups and glob picks the wrong
one.

---

## 3. Backup and restore

### What to back up

| Item | Path | Importance |
|---|---|---|
| HA config and entities | `/opt/ha-stack/ha-config/` | ★★★ |
| Matter bridge state | `/opt/ha-stack/matter-hub-data/` | ★★★ |
| Node-RED flows | `/opt/ha-stack/nodered-data/` | ★★ |
| MQTT credentials and config | `/opt/ha-stack/mosquitto/config/` | ★★ |
| compose + env | `/opt/ha-stack/docker-compose.yml`, `.env` | ★★★ |

### Manual backup

```bash
tar czf ha-stack-$(date +%Y%m%d).tar.gz \
  -C /opt/ha-stack ha-config matter-hub-data nodered-data mosquitto/config \
  docker-compose.yml .env
```

### The backup script

```bash
/opt/ha-stack/scripts/backup.sh              # into $STACK_DIR/backup/
/opt/ha-stack/scripts/backup.sh /mnt/nas/ha  # somewhere else
/opt/ha-stack/scripts/backup.sh --keep 14    # keep the 14 most recent
```

Archives are written with mode 600 — they contain the HA token. Restore:

```bash
cd $STACK_DIR && docker compose down
tar xzf backup/ha-stack-20261119-120000.tar.gz -C $STACK_DIR
docker compose up -d
```

### One-command health check

```bash
/opt/ha-stack/scripts/healthcheck.sh
```

Checks nine things: the engine, all four containers, the HTTP endpoints, MQTT
authentication, a leftover AppArmor profile, mDNS leaking onto internal
interfaces, the HA entity registry, recent errors in the HA log, and the
bind-mount directory ownership. Each problem is reported with the command
that fixes it. Exit code 0 means healthy, 1 means problems found — so it can
be wired straight into monitoring.

### Restore

```bash
cd /opt/ha-stack
docker compose down
tar xzf ha-stack-20261118.tar.gz
docker compose up -d
```

HA entities, the Matter bridge and the pairing code all come back — the Matter
Bridge ID and PIN are persisted in `matter-hub-data/` and **only change if you
delete and recreate the bridge**.

### Scheduled backup (cron)

```bash
0 4 * * * /opt/ha-stack/scripts/backup.sh >> /opt/ha-stack/backup.log 2>&1
```

---

## 4. Upgrading

### Home Assistant

```bash
cd /opt/ha-stack
sed -i 's|home-assistant:2026.11.1|home-assistant:2026.11.2|' docker-compose.yml
docker compose pull homeassistant
docker compose up -d homeassistant
```

**Back up `ha-config/` first** — it is all of HA's configuration.

### Matter Hub

```bash
sed -i 's|MATTER_HUB_VERSION=1.7.18|MATTER_HUB_VERSION=1.7.19|' .env
docker compose pull matter-hub
docker compose up -d matter-hub
```

The **pairing code does not change** across Matter Hub upgrades (it is persisted
in `/data/`), so Apple Home does not need re-pairing.

### Kiri engine

```bash
# 1. switch back to Docker first (an engine upgrade restarts the engine)
/opt/ha-stack/scripts/engine.sh docker

# 2. upgrade Kiri — see the upstream docs
#    https://github.com/libracoder/kiri

# 3. sync images
/opt/ha-stack/scripts/sync-images.sh

# 4. switch back
/opt/ha-stack/scripts/engine.sh kiri
```

---

## 5. Troubleshooting

Full boot-crash analysis: [TROUBLESHOOTING.md](TROUBLESHOOTING.md). Quick table:

| Symptom | Check first |
|---|---|
| Container will not start | `docker compose ps` → `docker compose logs <svc>` |
| Container restarts in a loop | port conflict: `ss -tln \| grep -E '1883\|8123\|1880\|8482'` |
| No DNS / no egress | `iptables -S DOCKER-USER` for the `kiri+` rules |
| mosquitto exits 3 | `dmesg \| grep apparmor` |
| HA floods bluetooth warnings | is `cap_add: [NET_ADMIN, NET_RAW]` in the compose file? |
| Matter devices show offline | is mDNS leaking to internal interfaces? see TROUBLESHOOTING |
| Engine will not start | `journalctl -u kiri.service -n 50` |
| Fallback never triggers | `tail -20 /opt/ha-stack/watch.log` |

### Quick self-check

```bash
/opt/ha-stack/scripts/healthcheck.sh
```

Or check the three most important things by hand:

```bash
/opt/ha-stack/scripts/engine.sh status
curl -s -o /dev/null -w 'HA %{http_code}\n'   http://127.0.0.1:8123/
grep '/usr/sbin/mosquitto' /sys/kernel/security/apparmor/profiles   # should print nothing
```

---

## 6. Configuration

### The compose file

After editing:

```bash
cd /opt/ha-stack
docker compose config --quiet     # validate
docker compose up -d              # apply
```

### Changing which entities the Matter bridge exposes

Web UI → Bridges → your bridge → entity filter.

`domain: switch` is a good starting point — many sensor entities belong to
devices that are permanently offline, and they show up greyed out in Apple Home.

### Changing the Matter mDNS interface

```bash
# .env
MDNS_INTERFACE=wlan0
```

Restart matter-hub afterwards and verify the advertising does not leak:

```bash
avahi-browse -rpt _matter._tcp | grep -oE 'wlp[0-9a-z]+|docker0|br-[a-f0-9]+' | sort -u
# should only show your LAN interface
```

### Adding a service

Add a service to `docker-compose.yml`, then:

```bash
docker compose up -d <new-service>
```

---

## 7. Never do this

- ❌ **Do not delete `ha-config/`** — it is all of HA's configuration; deleting
  it is the same as reinstalling
- ❌ **Do not use `docker compose down -v`** — `-v` deletes volumes, and with
  them the data
- ❌ **Do not run both engines at once** — they fight over the host ports (see
  TROUBLESHOOTING pitfall #4)
- ❌ **Do not delete `matter-hub-data/`** — the bridge state and pairing code live there
- ❌ **Do not drop `NODE_OPTIONS` from the Matter Hub `command:`** — `command:`
  overrides the image's own heap-sizing script, so the limit must be explicit
- ❌ **Do not drop `user: "1883:1883"` from mosquitto** — see TROUBLESHOOTING pitfall #3
- ❌ **Do not commit `HAMH_HA_TOKEN`** — `.env` is in `.gitignore`
- ⚠️ **Back up before upgrading** — a failed HA upgrade may need a config rollback
