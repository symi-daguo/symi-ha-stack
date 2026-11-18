#!/usr/bin/env bash
# disable-mosquitto-apparmor.sh
#
# Disables a leftover AppArmor profile that breaks the mosquitto container
# on runtimes that do not impose a default profile (Kiri).
#
# The problem
# -----------
# Some hosts carry /etc/apparmor.d/mosquitto — a profile owned by the
# `apparmor` package, left behind after the mosquitto apt package was
# removed. It is a path profile:
#
#     profile mosquitto /usr/sbin/mosquitto { ... }
#
# so it attaches to ANY process whose executable is /usr/sbin/mosquitto,
# including the one inside a container.
#
#   - Docker force-applies the `docker-default` profile, which overrides
#     path profiles → the container works and the problem stays invisible.
#   - Kiri applies no profile of its own → the host profile lands on the
#     container's binary → the container may only read /etc/mosquitto/*,
#     not /mosquitto/config/mosquitto.conf → the broker exits with code 3
#     → `restart: unless-stopped` retries forever (28 times in 7 minutes
#     in our own incident).
#
# Evidence from the kernel audit log:
#
#     apparmor="DENIED" operation="open" class="file" profile="mosquitto"
#     name="/mosquitto/config/mosquitto.conf" fsuid=1883 ouid=1883
#
# The fix
# -------
# Two steps are needed. Renaming the file alone is NOT enough: the profile
# stays loaded in the kernel and `apparmor.service` re-attaches it by path
# hint on every boot. The only reliable check is:
#
#     grep '/usr/sbin/mosquitto' /sys/kernel/security/apparmor/profiles
#
# Run this from systemd (see systemd/disable-mosquitto-apparmor.service)
# AFTER apparmor.service, so it also runs correctly at boot.
set -eux

PROFILE=/etc/apparmor.d/mosquitto
DISABLED=/etc/apparmor.d/mosquitto.disabled

# 1. Rename so apparmor_parser no longer loads it.
if [ -f "$PROFILE" ]; then
  mv "$PROFILE" "$DISABLED"
fi

# 2. Unload it from the kernel.
apparmor_parser -R "$DISABLED" 2>/dev/null || true

# 3. Verify.
if grep -q '/usr/sbin/mosquitto' /sys/kernel/security/apparmor/profiles 2>/dev/null; then
  echo "WARNING: mosquitto AppArmor profile is still loaded" >&2
  exit 1
fi
echo "OK: mosquitto AppArmor profile disabled"
