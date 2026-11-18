# Security Policy

## Supported versions

| Version | Supported |
|---|---|
| 1.0.x | ✅ |

## Reporting a vulnerability

Please **do not open a public issue** for a security problem.

Use GitHub's private reporting: *Security → Report a vulnerability* on
<https://github.com/symi-daguo/symi-ha-stack>, or email the maintainer.

Please include:

- what the issue is and which component is affected
- reproduction steps
- the impact you believe it has

You can expect an acknowledgement within a few days. Fixes for confirmed
issues are released as a patch version, and the reporter is credited in the
changelog unless they prefer otherwise.

## Handling secrets

The stack holds a few secrets. Handle them accordingly:

| Secret | Where | Notes |
|---|---|---|
| HA long-lived access token | `.env` → `HAMH_HA_TOKEN` | `.env` is git-ignored; never commit it |
| MQTT password | `mosquitto/config/.ha_mqtt_password` | mode 0600, owned by uid 1883 |
| Matter pairing code / PIN | Matter Hub Web UI, persisted in `matter-hub-data/` | treat as a local-network credential |

**Never commit**: `.env`, `mosquitto/config/.ha_mqtt_password`, `mosquitto/config/passwd`,
`matter-hub-data/`, or `ha-config/` — they contain tokens, credentials and
personal device data.

The CI workflow runs a secret scan on every push and pull request to catch
accidental commits.

## Exposure notes

- The MQTT broker binds to `127.0.0.1` by default. Change it to `0.0.0.0` only
  if you intend LAN devices to connect, and be aware that anyone on the LAN can
  then reach the broker port (authentication is still required).
- The Matter bridge requires **host networking** and advertises over mDNS on
  your LAN. It is reachable by any device on the same network, which is
  inherent to the Matter protocol.
- `disable-mosquitto-apparmor.sh` removes one AppArmor profile. It only
  disables the leftover `mosquitto` path profile, which belongs to the
  `apparmor` package and is not part of any installed mosquitto package. The
  rest of AppArmor stays enabled.
