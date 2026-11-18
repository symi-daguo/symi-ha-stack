# Contributing

Thanks for taking the time to contribute.

## Scope

This project is an **integration and operations layer** on top of:

- [riddix/home-assistant-matter-hub](https://github.com/riddix/home-assistant-matter-hub) — Matter bridge
- [libracoder/kiri](https://github.com/libracoder/kiri) — container engine
- [Home Assistant](https://www.home-assistant.io/) — home automation
- [Eclipse Mosquitto](https://mosquitto.org/) — MQTT broker
- [Node-RED](https://nodered.org/) — low-code automation

We do **not** fork or vendor their code. Contributions that add upstream
functionality belong upstream; contributions that make the *integration* work
better belong here.

## What is most useful

1. **Boot-time and runtime failure reports**, especially from other distros
   (Debian, Fedora, Raspberry Pi OS) or other container runtimes
   (Podman, containerd).
2. **Fixes to the four documented pitfalls** in
   [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for environments we
   have not tested.
3. **Real numbers** — memory, disk, recovery time — from your hardware. The
   benchmark table in the README is only as good as the reports behind it.
4. **Documentation in both languages** when you change behaviour.

## Development

```bash
git clone https://github.com/symi-daguo/symi-ha-stack.git
cd symi-ha-stack

# shellcheck the scripts
shellcheck scripts/*.sh install/*.sh

# validate the compose template
STACK_DIR=/tmp/ha-stack MDNS_INTERFACE=lo \
  HAMH_HA_TOKEN=dummy \
  docker compose -f examples/docker-compose.yml config --quiet
```

CI runs shellcheck, compose validation and a secret scan on every pull request.

## Commit messages

Conventional Commits:

```
fix(engine): wait for DOCKER-USER chain before inserting rules
feat(scripts): add backup.sh helper
docs: clarify the mDNS leak symptom
```

## Pull requests

- One logical change per PR.
- Explain *why*, not just *what*. If it fixes a bug, include the symptom and
  the evidence (log lines, `dmesg` output, before/after numbers).
- Update `CHANGELOG.md` under the "Unreleased" heading.
- If behaviour changes, update **both** `README.md` and `README_EN.md`, and
  the matching `docs/OPERATIONS*.md` files.

## Versioning

Semantic versioning:

- **patch** (1.0.x) — bug fixes, doc fixes
- **minor** (1.1.0) — new features, new scripts, new options
- **major** (2.0.0) — breaking changes to the compose layout or script interface

## Security

Do not open a public issue for a vulnerability. See [SECURITY.md](SECURITY.md).

## License

By contributing you agree that your contributions are licensed under the
[MIT License](LICENSE).
