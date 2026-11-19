#!/usr/bin/env bash
# plant-leaks.sh — plant real leaks so the sanitisation scanner can
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

TARGET="${1:?usage: plant-leaks.sh TARGET_DIR}"

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

# A Matter bridge id. home-assistant-matter-hub publishes them in
# UPPERCASE, so a lowercase-only pattern would miss the real thing.
printf 'bridge id 3F7A9C2B1D4E5F60718293A4B5C6D7E8 here\n' > bridgeid.txt

# An encrypted private key. "BEGIN ENCRYPTED PRIVATE KEY" is a private
# key too — the original rule only knew RSA, EC, DSA and OPENSSH.
printf -- '-----BEGIN ENCRYPTED PRIVATE KEY-----\n' > encrypted.pem

# A PGP private key block.
printf -- '-----BEGIN PGP PRIVATE KEY BLOCK-----\n' > pgp.pem

# A macOS home path with a dot in the user name. The original pattern
# allowed only letters, digits, dash and underscore.
printf 'the log lives at /Users/john.smith/app.log\n' > macos.txt

# A macOS home path whose user name contains a dot. The original pattern
# allowed only letters, digits, dash and underscore, so /Users/john.smith
# passed.
printf 'the log lives at /Users/john.smith/app.log\n' > macos.txt

# The interface name of the machine this repository was developed on.
# It is hardware information about the author's machine and has no
# business being in a public repository.
printf 'MDNS_INTERFACE=wlp0s20f3\n' > iface.txt

# The legitimate counterpart of a .env, which the scanner must leave alone.
printf 'TOKEN=REPLACE_WITH_YOUR_TOKEN\n' > examples/.env.example

git add -A
echo "planted leaks in $TARGET"
