# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

## [1.1.4] — 2026-11-19

Patch release: the gates themselves are now real gates.

A second independent review found that several of the checks added in
1.1.2 could not fail. This release fixes the checks, not the code they
check — except where the code was wrong too.

### Fixed

**The scan-self-test could pass with the scanner broken.** Its assertions
only asked whether a file NAME appeared anywhere in the scanner's output.
A mutant with the private-key rule disabled still printed `key.pem` — the
high-entropy rule matched the file's body — and the job went green. The
assertions now pair each planted sample with the message of the rule that
is supposed to catch it, so a disabled rule turns the job red.

**The systemd-unit validation could never fail.** It ended with `|| true`
and a plain `echo`, so appending garbage lines to the unit still reported
"engine unit parsed". It now looks for the parse errors systemd-analyze
reports and exits 1.

**The version check failed on every pull request.** It used
`GITHUB_REF_NAME`, which is `<pr-number>/merge` on a pull_request event,
so the READMEs would have had to literally contain "42/merge". It now
uses the tag on a tag push and the newest CHANGELOG entry otherwise.

**The private-key rule did not know encrypted or PGP keys.** It matched
RSA, EC, DSA and OPENSSH headers only, so
`-----BEGIN ENCRYPTED PRIVATE KEY-----` and
`-----BEGIN PGP PRIVATE KEY BLOCK-----` passed.

**The bridge-id rule skipped the documentation.** It excluded `*.md`,
which is exactly where a pasted bridge id would survive. No 32-hex string
exists in the markdown today, so the exclusion bought nothing and cost a
blind spot. The rule now also matches uppercase, which is the form Matter
Hub actually publishes.

**The home-path rule missed macOS user names with a dot.** `/Users/john.smith/`
passed; the pattern allowed only letters, digits, dash and underscore.

**The requirement matrix gave false green lights.** Ten of its checks
were string-presence assertions — they confirmed that a pattern's TEXT
was on a line, never that the pattern matched anything. The worst was
CI-02, which grepped the workflow file for the literal `*.md` and was
satisfied by an unrelated string; excluding every markdown file from the
scanner still reported "ok". The ones that named a behaviour are now
behavioural: the matrix plants a private key and requires the scanner to
catch it, it refuses an empty set where `all([])` would be true, it
compares the README version against the CHANGELOG's newest entry, and it
checks each documented script's executable bit individually instead of
counting them.

**The matrix's `sh()` helper could not tell "nothing matched" from "the
command failed".** A check that read a file which did not exist passed
silently. The helper now keeps stderr and distinguishes grep's "no
match" (exit 1, no output) from a command that did not run.

**The interface name of the machine this was developed on was in
`examples/.env.example`.** A real wireless interface name is hardware
information about the author's machine and has no business being in a
public repository. The example now reads `eth0`, and the matrix keeps
the real name out — it reads the name from the fixture file so that not
even the matrix contains it.

### Changed

**The planted-leak samples moved to `tests/fixtures/`.** The scanner
excluded them by file name, so a second fixture file would have escaped
the gate unnoticed. It now excludes the directory, and the samples are
the only place in the repository that contains a literal private-key
header or device id — including the matrix itself, which reads its
samples from there.

**The documentation now says five boot crashes everywhere.** The title,
the introduction and both READMEs still said four while the guide
documented five.

**The README project tree lists the scripts that exist**, and the
`CONTRIBUTING.md` shellcheck command matches what CI runs
(`--severity=warning`) — the bare command returned 1 on a clean tree.

### Verification

Every fix was checked in both directions: the scan must reject the
planted leaks and accept the repository; the self-test must pass on the
real scanner and go red on a mutant with a rule disabled; the unit
validation must pass on a valid unit and fail on one with garbage
appended; the version check must pass on `main`, on a tag and on a pull
request, and fail when the README names the wrong version.

The requirement matrix grew to 85 checks. Each new one was verified by
reintroducing the regression it names.


## [1.1.3] — 2026-11-19

Patch release: the log check now actually reads the log.

### Fixed

**`healthcheck.sh` never read a single log line.** It asked for the
recent errors with `docker logs homeassistant --since 30m`. Kiri
silently ignores `--since` and returns nothing, with exit code 0. The
pipeline then counted the errors in an empty log, got 0, and reported
"no ERROR in the last 30 minutes" — every single time, on a healthy
stack and on a broken one alike. The check now uses `--tail`, which both
engines support.

**A log that cannot be read was reported as a clean log.** Piping the
count straight out of the command chain made an empty result
indistinguishable from "no errors". The two cases are now separate: if
the log cannot be read, the report says so.

The requirement matrix grew two checks for this, verified by
reintroducing the `--since` usage.

Found by the first independent reviewer, which was stopped mid-run but
had already noted that shellcheck at `severity=info` reports notes the CI
does not check for. The other two notes it surfaced are intentional: the
SC2016 single quotes keep `$MQTT_USER` and `$MQTT_PASS` from expanding on
the host, and the SC2015 fallbacks are deliberate.


## [1.1.2] — 2026-11-19

Patch release: the sanitisation scan becomes a tested artefact, and the
documentation gets a requirement matrix. No behaviour change for a running
stack.

### Added

- **`scripts/sanitize-scan.sh`** — the sanitisation rules now live in one
  file instead of being inline in the workflow. The CI job and the
  self-test run the same code, so a change to the rules cannot silently
  make the self-test pass against the old behaviour.
- **`scripts/selftest-fixtures.sh`** — plants real leaks (a credential in
  a `.env`, a credential pasted into prose, a LAN address, a MAC address,
  and private keys generated with `openssl`) into a throwaway repository.
- **A `scanner-selftest` CI job.** A scan that quietly stopped matching is
  worse than no scan at all, because it reports "clean" while leaks pass.
  The job now requires the scanner to reject the planted leaks, requires
  every one of them to be named in the output, and requires the
  placeholder in `examples/.env.example` to stay unreported.
- **`tools/audit-matrix.py`** — 60 checks that the promises the
  documentation makes are still true: every script the docs tell the
  reader to run exists, the systemd units still pass the environment they
  need, the compose template still pins what it claims to pin. A new
  `audit` CI job runs it. Verified by breaking things on purpose: deleting
  `scripts/healthcheck.sh` produced three gaps, removing `--no-systemd`
  produced one.

### Fixed

- **The scanner missed a credential pasted into prose.** The rules only
  matched `TOKEN=<value>` style assignments. A token written into a
  sentence — "set your token to eyJhbG..." — has no `TOKEN=` in front of
  it and passed the scan. A real Home Assistant token is a long
  high-entropy run (JWT-like, 183 characters), so any base64-ish run that
  long is now reported.
- **The scanner missed the plain variable names.** The list covered
  `HA_TOKEN` and `MQTT_PASSWORD` but not a bare `TOKEN`, `PASSWORD`,
  `PASSWD`, `SECRET` or `CREDENTIAL`.
- **The English summary of the troubleshooting guide said "four boot
  crashes"** while the Chinese guide documented five. It now says five and
  marks the fifth explicitly — that one is worth reading twice, because it
  only appears when two individually correct fixes interact.

### Changed

- **The self-test samples moved out of the workflow file.** They have to
  look like real leaks for the self-test to mean anything, which means the
  workflow file itself would trip the scan — and exempting the workflow
  would have opened a hole: a real token pasted into a workflow would then
  go unnoticed. The samples now live in `scripts/selftest-fixtures.sh`,
  which is excluded by name, and the workflow is scanned like everything
  else.
- **`CONTRIBUTING.md` documents every script** in the repository, in both
  languages, plus how to run the scan and how to verify it in reverse.

### Verification

The scan was checked in both directions: it exits 1 on the planted leaks
and exits 0 on the repository. Every rule was exercised against a real
sample — real RSA and EC private keys from `openssl`, a real-length
Home Assistant token — not against a fake header.

The requirement matrix was verified by breaking things on purpose:
deleting `scripts/healthcheck.sh` produced three gaps, removing
`--no-systemd` produced one, and reintroducing the `$STACK_DIR` hijack
produced another.

The self-test fixtures grew to eight planted samples, including the three
that the independent review found holes for: a credential on a line that
also contains "example", a credential in a home directory path, and an
uppercase Matter bridge id.

One candidate finding did not hold: the claim that the CI self-test could
pass with the scanner's content rules disabled. Tested directly, the
assertions name every planted sample, so disabling the rules turns the
job red.

All six CI jobs were run locally from the workflow file itself, and again
on a fresh clone of the published branch.


## [1.1.1] — 2026-11-19

Patch release: documentation corrections and a hardened sanitisation scan.
No new features, no behaviour changes.

### Fixed

- **The CI link check could not fail.** It piped a `while read` loop, which
  runs in a subshell: the `exit 1` inside it never failed the step and the
  `fail=1` assignment was lost. Broken links in the documentation passed CI
  silently. The loop now runs in a process substitution, so a broken link
  actually fails the job.
- **The README files still said the current version was 1.0.0.** They now
  say 1.1.1, and CI checks that the README files mention the released tag.

### Changed

- **The sanitisation scan now covers the documentation.** The old scan
  excluded `docs/`, `README*` and `*.example` — but documentation is exactly
  where a pasted token survives: a "worked example" in a troubleshooting
  guide, a real LAN address in a command line, a pairing code in a caption.
  The scan now covers every tracked file, with placeholders excluded
  explicitly rather than whole directories.
- **The scan checks more than credentials.** It now also looks for host
  home paths, private LAN addresses, MAC addresses, 32-hex bridge ids,
  private key blocks, and tracked files whose names suggest they hold
  secrets (`*.env`, `credentials*`, `id_rsa`, …). Binary files are rejected
  outright — a stray archive or image layer could hide anything the text
  scan cannot see.
- **CI validates the reference engine unit** and checks that every script
  and example file referenced in the documentation actually exists.

The scan was verified against deliberately planted leaks: it catches a token
in `.env`, a token in a markdown guide, a LAN address, and a MAC address,
while still allowing the placeholders in `examples/.env.example`.


## [1.1.0] — 2026-11-19

New operational tooling, plus a fix for a bug that only shows up when the
stack is installed somewhere other than the default path.

### Added

- **`scripts/healthcheck.sh`** — one command that checks nine things: which
  engine is running, all four containers, the three HTTP endpoints, MQTT
  authentication, a leftover AppArmor profile, mDNS leaking onto internal
  interfaces, the HA entity registry, recent errors in the HA log, and the
  bind-mount directory ownership. Each problem is reported with the command
  that fixes it. Exit code 0 means healthy, so it can be wired into
  monitoring directly.
- **`scripts/backup.sh`** — timestamped archive of `ha-config`,
  `matter-hub-data`, `nodered-data`, `mosquitto/config`, the compose file and
  `.env`. Archives are written with mode 600 because they contain the HA
  token. Supports a custom destination and `--keep N` pruning. The
  operations manual referenced this script since v1.0.0 but it did not
  exist.
- **`examples/kiri.service`** — reference engine unit carrying the
  `TimeoutStartSec` and `ExecStartPost=-` fixes, with a comment on each.

### Fixed

- **The systemd units did not pass `STACK_DIR` to the scripts.** The
  installer rewrote the `ExecStart` path, but the scripts locate the stack
  through the `STACK_DIR` environment variable — which stayed at its
  built-in default. Installing to anything other than `/opt/ha-stack` made
  the units operate on the wrong directory. The units now set
  `Environment=STACK_DIR=` and the installer rewrites that line too.
- **`fix-permissions.sh` changed the wrong directories.** It set the
  ownership of `mosquitto/` as a whole, which also took the plaintext
  password file away from the installing user. It now only touches the
  directories the container actually writes to (`mosquitto/config`,
  `mosquitto/data`, `mosquitto/log`) and leaves the parent with the
  installer.
- **`healthcheck.sh` looked for the MQTT password in the wrong place** and
  reported the whole `mosquitto/` tree as needing uid 1883. Both are fixed;
  the check now also accepts the older layout where the password file sits
  one level up.

### Notes

Two of these were found by running `healthcheck.sh` against the live
production stack, which is the point of shipping it: the Node-RED data
directory was owned by root instead of uid 1000, and the Mosquitto
directories had drifted. Both are latent failures on Kiri — Docker hides
them because its root has `CAP_DAC_OVERRIDE` and can read anything.


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
