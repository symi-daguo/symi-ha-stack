#!/usr/bin/env bash
# selftest-fixtures.sh — plant real leaks so the sanitisation scanner can
# be proven to still catch them.
#
# This file is a FIXTURE, not a configuration file. It deliberately
# contains things that look like credentials, private keys and host
# identifiers. The scanner excludes this file by name for exactly that
# reason — the same way it excludes the placeholder example file.
#
# It is never executed against a real repository and it is never a source
# of truth for anything: the scanner self-test in CI calls it to build a
# throwaway repository in /tmp and then requires the scanner to fail on it.

set -euo pipefail

TARGET="${1:?usage: selftest-fixtures.sh TARGET_DIR}"

rm -rf "$TARGET"
mkdir -p "$TARGET/examples"
cd "$TARGET"

git init -q
git config user.email selftest@example.invalid
git config user.name selftest

# A credential in a .env
printf 'TOKEN=AbCdEf0123456789XYZ\n' > leak.env

# A credential pasted into prose. There is no TOKEN= in front of it,
# which is exactly what a variable-name based scan misses.
printf 'Set your token to eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJoYSI6ImEiLCJleHAiOjE3NzE1MDAwMDAsInR5cCI6IkpXVCJ9.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c in the guide.\n' > guide.md

# A private LAN address and a MAC address
printf 'HOST=192.168.31.79\nMAC=C8:6E:08:08:27:70\n' > net.conf

# Real private keys, generated with openssl. A fake header would only
# test that the rule matches a fake header.
openssl genrsa -out key.pem 2048 2>/dev/null
openssl ecparam -genkey -name prime256v1 -noout -out ec.pem 2>/dev/null

# A credential on a line that also contains the word "example". The rules
# once excluded the bare word "example" to let the placeholder file
# through, which skipped the WHOLE line — a real credential written in a
# sentence containing "example" passed the scan.
printf 'for example set MQTT_PASSWORD=AbCdEf0123456789XYZ here\n' > prose.txt

# A credential in a home directory path.
printf 'the config lives at /home/alice/config and holds a token\n' > homepath.md

# The legitimate counterpart of a .env, which the scanner must leave alone.
printf 'TOKEN=REPLACE_WITH_YOUR_TOKEN\n' > examples/.env.example

git add -A
echo "planted leaks in $TARGET"
