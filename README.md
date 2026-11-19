# symi-ha-stack

**Home Assistant + Matter Bridge 生产级容器栈** —— 一套 compose 起四个服务
（Home Assistant / Mosquitto / Node-RED / Matter Hub），可运行在 **Docker** 或
**Kiri** 两种引擎上，带自动故障回落。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/symi-daguo/symi-ha-stack.svg)](https://github.com/symi-daguo/symi-ha-stack/releases)
[![Docs](https://img.shields.io/badge/docs-bilingual-blue.svg)](docs/)

[English](./README_EN.md) | 简体中文

---

## 为什么做这个

现成方案的现状：

| 组件 | 上游 | 状态 |
|---|---|---|
| Matter Hub | [riddix/home-assistant-matter-hub](https://github.com/riddix/home-assistant-matter-hub) | ✅ 成熟，有官方镜像 |
| Kiri 引擎 | [libracoder/kiri](https://github.com/libracoder/kiri) | ⚠️ beta（0.2.x） |
| HA 容器编排 | 社区零散 compose | ❌ 没有生产级整合 |

**空白在整合层**：把这两者组合起来跑在小型家用服务器上，会撞上一串没人写下来的坑。
本项目把这套整合连同**五个真实的开机崩溃修复**一起开源出来。

### 实测收益

在 6.8 GB 内存的 Ubuntu 家用机上：

| | Docker (snap) | **Kiri 0.2.1** |
|---|---|---|
| 引擎常驻内存 | 159 MB（dockerd + containerd + 4 shim） | **7 MB**（daemon + init） |
| 镜像磁盘占用 | 8.36 GB | **1.04 GB** |
| 引擎冷启动 | 数秒 | **333 ms** |
| 容器崩溃后恢复 | 依赖 restart policy | **~15 s 全栈恢复** |

容器本身占用不变（HA ~600-770 MB / Matter Hub ~130-190 MB / Node-RED ~56 MB /
Mosquitto ~19 MB）。省的是引擎和镜像。

---

## 核心特性

### 1. 双引擎可热切换 + 自动故障回落

```bash
./scripts/engine.sh status   # 看当前跑在哪个引擎
./scripts/engine.sh docker   # 切到 Docker
./scripts/engine.sh kiri     # 切到 Kiri
```

`scripts/watch.sh` 每 5 分钟巡检，**连续 3 次不健康自动切回 Docker**。
这让 beta 引擎敢上生产：Kiri 出问题，15 分钟内栈自己回来，无需人工介入。

双向切换均已实测，包括「dockerd 停着时切 Docker」这种应急场景。

### 2. 修复了五个真实的开机崩溃

这些是本项目最有价值的部分。详见 [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)。

| # | 症状 | 根因 | 修复 |
|---|---|---|---|
| 1 | 引擎反复被杀 | systemd `ExecStartPost=`（无 `-`）失败 = 整个 unit 失败 | 规则挪进脚本 + `ExecStartPost=-` |
| 2 | 容器无 DNS、无出网 | 开机时 DOCKER-USER 链不存在 + 默认路由未就绪 | 脚本等 90s，自建链兜底 |
| 3 | mosquitto 无限 exit 3 | 宿主残留 AppArmor 路径 profile 挂进容器 | 改名 + `apparmor_parser -R` + 开机 unit |
| 4 | 两套引擎互抢端口 | dockerd 自启把容器全拉起来 | 禁用 dockerd 自启，切回时停掉 |
| 5 | 引擎开机被杀 | 脚本等待 180s 超过 systemd 默认 90s 超时 | 缩短等待 + 显式 `TimeoutStartSec=180` |

第 3 个最隐蔽：Docker 强制套 `docker-default` 覆盖了路径 profile，所以**在
Docker 上永远看不到这个 bug**，只有 Kiri 这类不套默认 profile 的运行时才会暴露。

### 3. Matter 桥接开箱可用

- HA 的实体自动映射成 Matter 端点，Apple Home 直接可见
- **mDNS 广播限定在局域网网卡**（`--mdns-network-interface` + `--mdns-strip-global-ipv6`，
  上游 #361 的官方修法）。不限定的话，Matter 会把 `docker0`/`br-*`/`kiri*`
  等内部网卡的地址也写进广播，控制器可能挑一个它到不了的地址，表现为「设备离线」
- 桥接状态、配对码、PIN 全部持久化，**重启后不变**

### 4. 无线上依赖

HA、MQTT、Node-RED、Matter Hub 全在局域网内。HA 侧现有 13 个集成域
（WLED / SONOS / Thread / Sun / KNX 自研同步 / go2rtc / bluetooth …）都能离线跑。

---

## 快速开始

### 前置条件

- Ubuntu 22.04+ / Debian 12+（AppArmor、systemd、nftables）
- Docker + Compose v2
- 可选：[Kiri 0.2.1+](https://github.com/libracoder/kiri)（省内存用）

### 1. 克隆并配置

```bash
git clone https://github.com/symi-daguo/symi-ha-stack.git
cd symi-ha-stack

export STACK_DIR=/opt/ha-stack
sudo mkdir -p "$STACK_DIR"
cp examples/.env.example "$STACK_DIR/.env"
cp examples/docker-compose.yml "$STACK_DIR/docker-compose.yml"
```

编辑 `$STACK_DIR/.env`（即 `/opt/ha-stack/.env`），至少填这三项：

```ini
STACK_DIR=/opt/ha-stack
MDNS_INTERFACE=wlan0          # ip route show default 看网卡名
HAMH_HA_TOKEN=eyJ...              # HA → 头像 → 安全 → 长期访问令牌
```

### 2. 生成 MQTT 凭据

```bash
STACK_DIR=/opt/ha-stack ./scripts/setup-mqtt.sh
```

### 3. 启动

```bash
cd /opt/ha-stack
docker compose up -d
docker compose ps          # 4 个服务应当都是 healthy
```

### 4. 接入 Matter

浏览器打开 `http://<host>:8482` → **Bridges** → 创建 Bridge → 选实体域
（推荐 `domain: switch`）→ 记下手动配对码。

Apple Home → 添加配件 → 更多选项 → 手动代码 → 输入配对码。

### 5. （可选）切到 Kiri 省内存

```bash
# 先同步镜像
STACK_DIR=/opt/ha-stack ./scripts/sync-images.sh

# 装 systemd unit（开机自启 + 监控）
sudo cp systemd/disable-mosquitto-apparmor.service /etc/systemd/system/
sudo systemctl enable --now disable-mosquitto-apparmor.service

# 切过去
STACK_DIR=/opt/ha-stack ./scripts/engine.sh kiri
```

---

## 项目结构

```
symi-ha-stack/
├── examples/
│   ├── docker-compose.yml     # 四服务栈（路径/网卡全部走 .env）
│   ├── .env.example           # 配置模板
│   └── kiri.service           # 参考 unit（含 TimeoutStartSec 等修复）
├── scripts/
│   ├── engine.sh              # 引擎切换（status / docker / kiri）
│   ├── watch.sh               # 健康巡检 + 自动回落
│   ├── kiri-forward.sh        # Kiri bridge 出网规则（开机竞态处理）
│   ├── disable-mosquitto-apparmor.sh  # 卸载残留 AppArmor profile
│   ├── setup-mqtt.sh          # 生成 MQTT 凭据
│   ├── fix-permissions.sh      # 修正 bind mount 目录属主（容器内 uid）
│   ├── backup.sh               # 备份/恢复（打包 + 保留份数）
│   ├── healthcheck.sh          # 一键体检（9 项检查）
│   ├── sync-images.sh         # Docker → Kiri 镜像同步
│   └── sanitize-scan.sh        # 脱敏扫描（CI 与本地共用）
├── tests/fixtures/plant-leaks.sh  # planted leaks for the scanner self-test
├── systemd/
│   ├── ha-stack.service               # Docker 版自启
│   ├── ha-stack-kiri.service          # Kiri 版自启
│   ├── ha-stack-watch.service         # 监控 + 自动回落
│   └── disable-mosquitto-apparmor.service
├── docs/
│   ├── OPERATIONS.md          # 运维手册（中文）
│   ├── OPERATIONS_EN.md       # 运维手册（English）
│   └── TROUBLESHOOTING.md     # 五个开机坑详解
├── install/install.sh         # 一键安装
├── CHANGELOG.md
├── CONTRIBUTING.md
├── SECURITY.md
└── LICENSE (MIT)
```

---

## 文档

| 文档 | 内容 |
|---|---|
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | 运维手册：日常操作、备份、升级、监控 |
| [docs/OPERATIONS_EN.md](docs/OPERATIONS_EN.md) | Same, in English |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | 五个开机崩溃的完整排查过程与证据 |

---

## 致谢与边界

本项目**不包含**任何上游代码，是纯粹的整合与修复层：

- [riddix/home-assistant-matter-hub](https://github.com/riddix/home-assistant-matter-hub) —— Matter 桥接实现
- [libracoder/kiri](https://github.com/libracoder/kiri) —— 容器引擎
- [Home Assistant](https://www.home-assistant.io/) —— 家居自动化平台
- [Eclipse Mosquitto](https://mosquitto.org/) —— MQTT broker
- [Node-RED](https://nodered.org/) —— 低代码自动化

Kiri 目前仍是 beta（0.2.x）。**请务必同时部署自动回落** —— 本项目里的
`watch.sh` 就是为此存在的。

---

## 版本

当前：**1.1.4**

后续按语义化版本迭代：小版本（1.1.x）修 bug 与文档，中版本（1.2.0）加功能。

## 许可证

[MIT](LICENSE)
