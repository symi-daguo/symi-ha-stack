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
2. **Fixes to the five documented pitfalls** in
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
shellcheck --severity=warning scripts/*.sh install/*.sh

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

## 脱敏（提交前必做）

对外提交的仓库**绝不能**包含以下内容：

| 类型 | 检查方式 |
|---|---|
| HA token / MQTT 密码 | 搜 `TOKEN=` `PASSWORD=` 后面跟长串 |
| 本机绝对路径 | 搜 `/home/<用户名>` `/Users/<用户名>` |
| 内网 IP | 搜 `192.168.` `10.x.x.x` `172.16-31.x.x` |
| MAC 地址 | 搜 `XX:XX:XX:XX:XX:XX` |
| Matter Bridge ID / 配对码 | 搜 32 位十六进制、11 位数字 |
| 二进制文件 | `file --mime-encoding` 应只输出 us-ascii/utf-8/empty |

CI 会自动跑这些检查，但**先自己扫一遍**——CI 红了会挡住合并。

示例文件（`examples/.env.example`）必须用占位符（`REPLACE_WITH_...`），
不能填真值。

## Sanitisation (before you push)

A public repository must **never** contain:

| Kind | How to look for it |
|---|---|
| HA token / MQTT password | a long opaque string after `TOKEN=` / `PASSWORD=` |
| Host absolute paths | `/home/<user>` or `/Users/<user>` |
| Private LAN addresses | `192.168.`, `10.x.x.x`, `172.16-31.x.x` |
| MAC addresses | `XX:XX:XX:XX:XX:XX` |
| Matter bridge id / pairing code | 32 hex characters, 11 digits |
| Binary files | `file --mime-encoding` should print only us-ascii/utf-8/empty |

CI runs these checks, but **scan yourself first** — a red CI blocks the merge.

Example files (`examples/.env.example`) must use placeholders
(`REPLACE_WITH_...`), never real values.

## 仓库里的脚本

| 脚本 | 作用 |
|---|---|
| `scripts/engine.sh` | 在 Docker 与 Kiri 之间切换引擎 |
| `scripts/watch.sh` | 健康监控，连续失败自动切回 Docker |
| `scripts/healthcheck.sh` | 一键体检，退出码可用于监控 |
| `scripts/backup.sh` | 备份配置与数据 |
| `scripts/setup-mqtt.sh` | 生成 MQTT 凭据 |
| `scripts/sync-images.sh` | 在两个引擎之间同步镜像 |
| `scripts/fix-permissions.sh` | 修正 bind mount 的属主 |
| `scripts/kiri-forward.sh` | 维护 Kiri 的出网规则 |
| `scripts/disable-mosquitto-apparmor.sh` | 卸载残留的 AppArmor profile |
| `scripts/sanitize-scan.sh` | 脱敏扫描（CI 与本地都用它） |
| `tests/fixtures/plant-leaks.sh` | 自检用的泄漏样本（**不是**配置） |

### 脱敏扫描

本地跑一遍，和 CI 用的是同一份代码：

```bash
./scripts/sanitize-scan.sh
```

退出码 0 = 干净，1 = 有东西不能发布。

改扫描规则后**必须**跑一次反向验证——扫描器不再匹配，比没有扫描器更危险，
因为它会报"干净"：

```bash
./tests/fixtures/plant-leaks.sh /tmp/leaks
./scripts/sanitize-scan.sh --path /tmp/leaks   # 必须退出 1
```

## Scripts in this repository

| Script | What it does |
|---|---|
| `scripts/engine.sh` | Switch between the Docker and Kiri engines |
| `scripts/watch.sh` | Health monitor; falls back to Docker after repeated failures |
| `scripts/healthcheck.sh` | One-command health report, exit code usable by monitoring |
| `scripts/backup.sh` | Back up configuration and data |
| `scripts/setup-mqtt.sh` | Generate the MQTT credentials |
| `scripts/sync-images.sh` | Copy images between the two engines |
| `scripts/fix-permissions.sh` | Fix the ownership of the bind-mounted directories |
| `scripts/kiri-forward.sh` | Maintain Kiri's egress rules |
| `scripts/disable-mosquitto-apparmor.sh` | Unload the leftover AppArmor profile |
| `scripts/sanitize-scan.sh` | The sanitisation scan (CI and local runs use this same file) |
| `tests/fixtures/plant-leaks.sh` | The planted leaks used by the self-test (**not** configuration) |

### The sanitisation scan

Run it locally — it is the same code CI runs:

```bash
./scripts/sanitize-scan.sh
```

Exit code 0 = clean, 1 = something must not be published.

After changing a rule, **verify it in reverse**. A scanner that quietly
stopped matching is worse than no scanner at all, because it reports
"clean" while leaks pass:

```bash
./tests/fixtures/plant-leaks.sh /tmp/leaks
./scripts/sanitize-scan.sh --path /tmp/leaks   # must exit 1
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
