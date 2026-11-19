#!/usr/bin/env bash
# sanitize-scan.sh — check the tracked files for anything that must not
# be published.
#
# ./sanitize-scan.sh              # scan the repository this script lives in
# ./sanitize-scan.sh --path DIR   # scan another git repository
#
# Exit code: 0 = clean, 1 = something that must not be published.
#
# Why this is a script and not a wall of greps inside the workflow:
# the CI workflow and the scanner self-test must run the SAME rules. If the
# rules live only in the workflow, a change to them can silently weaken the
# check while the self-test keeps passing against the old behaviour.

set -uo pipefail

# The repository to scan is the one this script lives in. It is NOT
# STACK_DIR: that variable names the stack's data directory, and reusing
# it here meant an unrelated STACK_DIR in the environment silently
# pointed the scan at a different directory — or at a non-repository,
# where the scan found nothing and reported "clean".
REPO="$(cd "$(dirname "$0")/.." && pwd)"
if [ "${1:-}" = "--path" ]; then
  REPO="${2:?--path needs a directory}"
fi
cd "$REPO" || exit 1

# A repository is required. Without this, a scan of a non-repository
# directory reports "clean" — the worst possible failure mode for a
# gate that protects a public repository.
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "::error::$REPO is not a git repository — nothing was scanned"
  exit 1
fi

fail=0

# The self-test samples live in scripts/selftest-fixtures.sh, which is
# excluded by name — they are fixtures, not leaks, and they have to look
# like real ones for the self-test to mean anything. Everything else,
# including the workflow file itself, is scanned.

report() {
  echo "::error::$1"
  fail=1
}

# 1. Assignment of a long opaque string to a credential-ish name.
#    Placeholders are excluded explicitly rather than by excluding whole
#    directories — documentation is exactly where a pasted token survives.
hits=$(git grep -nIE \
  '(HAMH_HA_TOKEN|HASS_TOKEN|HA_TOKEN|TOKEN|MQTT_PASSWORD|MQTT_PASS|PASSWORD|PASSWD|ACCESS_TOKEN|AUTH_TOKEN|API_KEY|APIKEY|SECRET_KEY|SECRET|PRIVATE_KEY|CREDENTIAL)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9+/=_-]{16,}' \
  -- . ':!examples/.env.example' ':!scripts/selftest-fixtures.sh' 2>/dev/null \
  | grep -vE 'REPLACE_WITH|CHANGE_ME|dummy|placeholder|example[_-]?token|your[_-]?(token|password|key)|\$\(|<[^>]+>|\{[^}]+\}|xxxxx|\*{4,}' || true)
if [ -n "$hits" ]; then
  echo "$hits"
  report "possible credential committed"
fi

# 2. A pasted credential in prose. This is the leak that survives a
#    variable-name based scan: "set your token to AbCdEf0123..." has no
#    TOKEN= in front of it. A real Home Assistant token is a long
#    high-entropy run (JWT-like, 183 characters), so any base64-ish run
#    that long deserves a human look.
hits=$(git grep -nE '[A-Za-z0-9+/]{40,}={0,2}' \
  -- . ':!examples/.env.example' ':!scripts/selftest-fixtures.sh' 2>/dev/null \
  | grep -vE 'REPLACE_WITH|CHANGE_ME|dummy|placeholder|xxxxx|sanitize-scan\.sh:' || true)
if [ -n "$hits" ]; then
  echo "$hits"
  report "a long high-entropy string (pasted credential?) in a tracked file"
fi

# 3. Private key blocks.
#    The pattern is built from parts so this rule does not match its own
#    source line.
if git grep -nE 'BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE' -- . ':!scripts/selftest-fixtures.sh' 2>/dev/null; then
  report "private key committed"
fi

# 4. Host-specific absolute paths.
hits=$(git grep -nIE '(^|[^A-Za-z0-9_])/home/[a-z][a-z0-9_-]*/|/Users/[A-Za-z][A-Za-z0-9_-]*/' \
  -- . ':!examples/.env.example' ':!scripts/selftest-fixtures.sh' 2>/dev/null \
  | grep -vE '/home/<|/Users/<|your-username|\$HOME' || true)
if [ -n "$hits" ]; then
  echo "$hits"
  report "host-specific home path committed"
fi

# 5. Private LAN addresses. The RFC1918 ranges that appear as CIDR
#    notation (NO_PROXY=192.168.0.0/16) are configuration intent, not a
#    leak — only concrete addresses are.
hits=$(git grep -nIE '\b(10|172\.(1[6-9]|2[0-9]|3[01])|192\.168)\.[0-9]{1,3}\.[0-9]{1,3}\b' \
  -- . ':!scripts/selftest-fixtures.sh' 2>/dev/null \
  | grep -vE '192\.168\.0\.0/16|172\.16\.0\.0/12|10\.0\.0\.0/8|192\.168\.x|selftest-fixtures\.sh:' || true)
if [ -n "$hits" ]; then
  echo "$hits"
  report "private LAN address committed"
fi

# 6. Device identifiers: MAC addresses and Matter bridge ids.
hits=$(git grep -nE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' \
  -- . ':!scripts/selftest-fixtures.sh' 2>/dev/null || true)
if [ -n "$hits" ]; then
  echo "$hits"
  report "MAC address committed"
fi

# A bridge id is 32 hex characters. The troubleshooting guide mentions it
# as a redacted example, so only flag it outside the documentation.
# A bridge id is 32 hex characters. home-assistant-matter-hub publishes
# them in UPPERCASE, so the pattern has to accept both cases. The
# troubleshooting guide mentions one as a redacted example, so only flag
# it outside the documentation.
if git grep -niE '\b[0-9a-f]{32}\b' -- . ':!*.md' ':!scripts/selftest-fixtures.sh' 2>/dev/null; then
  report "32-hex identifier (bridge id?) committed"
fi

# 7. Any file that looks like a secret but is not on the ignore list — a
#    stray .env.local or credentials.json would slip past the pattern
#    checks if it happened to use an unexpected variable name.
#    The example files are the legitimate counterpart of these names.
suspicious=$(git ls-files \
  | grep -iE '(^|/)([^/]*\.env(\.[^/]*)?|credentials[^/]*|secrets?\.[^/]*|\.netrc|\.pgpass|id_rsa|id_ed25519)$' \
  | grep -vE '\.example$|examples/' || true)
if [ -n "$suspicious" ]; then
  echo "$suspicious"
  report "a file that commonly holds secrets is tracked"
fi

# 8. No binary files — a stray .tar.gz or image layer could hide anything
#    the text scan cannot see.
binary=$(git ls-files | while read -r f; do
  [ -f "$f" ] || continue
  file --mime-encoding "$f" 2>/dev/null | grep -qE 'us-ascii|utf-8|empty' || echo "$f"
done || true)
if [ -n "$binary" ]; then
  echo "$binary"
  report "binary file committed"
fi

if [ "$fail" = "0" ]; then
  echo "no credentials, host paths, LAN addresses or device identifiers in tracked files"
  exit 0
fi
exit 1
