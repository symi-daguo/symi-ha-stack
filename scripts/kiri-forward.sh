#!/usr/bin/env bash
# kiri-forward.sh — make Kiri bridge containers able to reach the network.
#
#   apply    install the FORWARD rules (called by kiri.service)
#   remove   remove them again (called by kiri.service on stop)
#
# Why this is needed
# ------------------
# The host's FORWARD policy is DROP (Docker's default). Kiri installs its
# own nftables rules with an accept policy, but the host policy is
# evaluated first, so bridge containers end up with no DNS and no outbound
# connectivity (upstream issues #261, #247, #330).
#
# The fix is an ACCEPT rule for the `kiri+` interfaces in DOCKER-USER.
# Two boot-time races make this non-trivial:
#
#   1. At boot, Docker has not started yet, so the DOCKER-USER chain does
#      not exist and `iptables` fails with
#      "No chain/target/match by that name".
#   2. Kiri reads /proc/net/route at startup to find the default uplink.
#      If no default route exists yet it aborts with
#      "kiri-init: no uplink: no default route".
#
# So: wait for the chain (and the route), and create the chain ourselves if
# Docker never shows up.
#
# IMPORTANT: this script must ALWAYS exit 0. A failure here must never take
# the engine down with it — see the ExecStartPost= note in the systemd unit.
set -u

SELF=dev.symi.ha-stack.kiri-forward
# These waits must stay well under systemd's TimeoutStartSec (default 90s),
# otherwise systemd kills this ExecStartPost and takes the engine down with
# it ("start-post operation timed out. Terminating.").
#
# The chain wait is deliberately short: when the stack runs on Kiri, the
# Docker daemon is NOT started at boot, so the DOCKER-USER chain usually
# never appears — and we create it ourselves anyway. Waiting a long time for
# it is pointless and, with the systemd default timeout, fatal.
WAIT_CHAIN="${KIRI_WAIT_CHAIN:-10}"
WAIT_ROUTE="${KIRI_WAIT_ROUTE:-20}"

logger_tag() { logger -t "$SELF" "$*" 2>/dev/null || true; }

wait_chain() {
  local tries=${1:-90}
  for _ in $(seq 1 "$tries"); do
    if iptables -w 5 -n -L DOCKER-USER >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_route() {
  local tries=${1:-90}
  for _ in $(seq 1 "$tries"); do
    if ip route show default 2>/dev/null | grep -q '^default'; then
      return 0
    fi
    sleep 1
  done
  return 1
}

ensure_rules() {
  # Chain present → insert into it. Chain absent → create it and hook it
  # into FORWARD ourselves.
  if ! iptables -w 5 -n -L DOCKER-USER >/dev/null 2>&1; then
    iptables -w 5 -N DOCKER-USER 2>/dev/null || return 1
    iptables -w 5 -I FORWARD 1 -j DOCKER-USER 2>/dev/null || return 1
    logger_tag "created DOCKER-USER chain (Docker was not up yet)"
  fi
  iptables -w 5 -C DOCKER-USER -i kiri+ -j ACCEPT 2>/dev/null \
    || iptables -w 5 -I DOCKER-USER -i kiri+ -j ACCEPT 2>/dev/null || return 1
  iptables -w 5 -C DOCKER-USER -o kiri+ -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
    || iptables -w 5 -I DOCKER-USER -o kiri+ -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || return 1
  return 0
}

remove_rules() {
  iptables -w 5 -D DOCKER-USER -i kiri+ -j ACCEPT 2>/dev/null
  iptables -w 5 -D DOCKER-USER -o kiri+ -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
  return 0
}

case "${1:-apply}" in
  apply)
    wait_route "$WAIT_ROUTE" || logger_tag "WARNING: no default route after ${WAIT_ROUTE}s"
    wait_chain "$WAIT_CHAIN" || logger_tag "WARNING: DOCKER-USER chain absent after ${WAIT_CHAIN}s, creating our own"
    if ensure_rules; then
      logger_tag "kiri FORWARD rules installed"
    else
      logger_tag "WARNING: could not install kiri FORWARD rules"
    fi
    # Always succeed — this rule must never take the engine down.
    exit 0
    ;;
  remove)
    remove_rules
    exit 0
    ;;
  *)
    echo "usage: $0 {apply|remove}" >&2
    exit 1
    ;;
esac
