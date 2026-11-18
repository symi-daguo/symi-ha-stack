# 运维手册 / Operations Manual

[English](./OPERATIONS_EN.md) | 简体中文

> 目录
> 1. [日常操作](#一日常操作)
> 2. [监控与自动回落](#二监控与自动回落)
> 3. [备份与恢复](#三备份与恢复)
> 4. [升级](#四升级)
> 5. [故障排查](#五故障排查)
> 6. [配置修改](#六配置修改)
> 7. [不能做的事](#七不能做的事)

---

## 一、日常操作

### 基础命令

```bash
cd /opt/ha-stack

docker compose ps                  # 看容器状态
docker compose logs -f homeassistant
docker compose restart homeassistant
docker compose up -d               # 启动全部
docker compose down                # 停止全部
```

### 引擎切换

```bash
/opt/ha-stack/scripts/engine.sh status   # 当前引擎 + 容器状态
/opt/ha-stack/scripts/engine.sh docker   # 切到 Docker
/opt/ha-stack/scripts/engine.sh kiri     # 切到 Kiri
```

切换是**双向可用**的：切过去会先停掉另一侧的栈、等端口释放、清理游离容器，
切回来会顺手停掉空转的 dockerd。

### 服务入口

| 服务 | 地址 |
|---|---|
| Home Assistant | http://127.0.0.1:8123/ |
| Node-RED | http://127.0.0.1:1880/ |
| Matter Hub Web UI | http://127.0.0.1:8482/ |
| MQTT (本地) | 127.0.0.1:1883 |

三个 Web UI 都监听 `0.0.0.0`，局域网内可用 `http://<host-ip>:8123` 访问。

### MQTT 客户端

```bash
# 发布
mosquitto_pub -h 127.0.0.1 -u ha_user -P "$(cat /opt/ha-stack/mosquitto/config/.ha_mqtt_password)" \
  -t 'home/sensor/test' -m 'hello'

# 订阅
mosquitto_sub -h 127.0.0.1 -u ha_user -P "$(cat /opt/ha-stack/mosquitto/config/.ha_mqtt_password)" \
  -t '#' -v
```

---

## 二、监控与自动回落

`ha-stack-watch.service`（systemd user unit）每 5 分钟巡检一次，写入
`/opt/ha-stack/watch.log`：

```
2026-11-18 15:29:31 OK 引擎=8MB HA=561MB 剩avail=3391MB swap=0MB
```

**连续 3 次不健康 → 自动切回 Docker。** 这是 Kiri（beta 引擎）敢上生产的
前提保障。

三种判定状态：

| 情况 | 行为 |
|---|---|
| Kiri 上有容器 | 正常巡检 |
| Kiri 上没有 + Docker 有 | 已回落，待命 |
| 两边都没有 | **引擎故障 → 计入失败 → 触发回落** |

手动查看：

```bash
tail -f /opt/ha-stack/watch.log
systemctl --user status ha-stack-watch.service
```

### 内存怎么看

**必须读 cgroup，不能用 `.State.Pid`** —— Kiri 的 `.State.Pid` 指向 s6-init
（约 108 KB），Docker 指向真正的进程，语义不同。`memory.current` 是引擎无关的真实占用。

```bash
DK="env DOCKER_HOST=unix:///run/kiri/docker.sock docker-kiri"
for c in homeassistant matter-hub nodered mosquitto; do
  pid=$($DK inspect $c --format '{{.State.Pid}}')
  cg=$(awk -F: '/^0::/{print $3}' /proc/$pid/cgroup)
  echo "$c $(awk '{printf "%.0f MB", $1/1048576}' /sys/fs/cgroup$cg/memory.current)"
done
```

**坑**：`free` 的输出标题受 locale 影响，中文系统是「内存：/交换：」，
`awk '/^Mem:/'` 永远匹配不到 → 用 `sed -n '2p'` / `'3p'` 按行号取。

**坑**：cgroup 路径要从 `/proc/PID/cgroup` 取，不要 glob 引擎目录
（`/sys/fs/cgroup/system.slice/kiri.service/kiri/` 下有历史残留目录，glob 会挑错）。

---

## 三、备份与恢复

### 需要备份什么

| 内容 | 路径 | 重要性 |
|---|---|---|
| HA 配置与实体 | `/opt/ha-stack/ha-config/` | ★★★ |
| Matter 桥接状态 | `/opt/ha-stack/matter-hub-data/` | ★★★ |
| Node-RED flows | `/opt/ha-stack/nodered-data/` | ★★ |
| MQTT 凭据与配置 | `/opt/ha-stack/mosquitto/config/` | ★★ |
| compose + env | `/opt/ha-stack/docker-compose.yml`, `.env` | ★★★ |

### 备份脚本

```bash
/opt/ha-stack/scripts/backup.sh          # 打包到 /opt/ha-stack/backup/
```

### 手工备份

```bash
tar czf ha-stack-$(date +%Y%m%d).tar.gz \
  -C /opt/ha-stack ha-config matter-hub-data nodered-data mosquitto/config \
  docker-compose.yml .env
```

### 恢复

```bash
cd /opt/ha-stack
docker compose down
tar xzf ha-stack-20261118.tar.gz
docker compose up -d
```

恢复后 HA 的实体、Matter 桥接、配对码都会回来（Matter 的 Bridge ID 和 PIN
持久化在 `matter-hub-data/` 里，**只有删除 bridge 重建才会变**）。

### 定期备份（cron）

```bash
0 4 * * * /opt/ha-stack/scripts/backup.sh >> /opt/ha-stack/backup.log 2>&1
```

---

## 四、升级

### 升级 HA

```bash
cd /opt/ha-stack
sed -i 's|home-assistant:2026.11.1|home-assistant:2026.11.2|' docker-compose.yml
docker compose pull homeassistant
docker compose up -d homeassistant
```

**升级前先备份 `ha-config/`** —— 这是 HA 的全部配置。

### 升级 Matter Hub

```bash
sed -i 's|MATTER_HUB_VERSION=1.7.18|MATTER_HUB_VERSION=1.7.19|' .env
docker compose pull matter-hub
docker compose up -d matter-hub
```

Matter Hub 升级后**配对码不变**（持久化在 `/data/`），不需要重新配对 Apple Home。

### 升级 Kiri 引擎

```bash
# 1. 先切回 Docker（引擎升级要重启引擎，会停所有容器）
/opt/ha-stack/scripts/engine.sh docker

# 2. 升级 Kiri（见上游文档）
#    https://github.com/libracoder/kiri

# 3. 同步镜像
/opt/ha-stack/scripts/sync-images.sh

# 4. 切回 Kiri
/opt/ha-stack/scripts/engine.sh kiri
```

### 切换到新版本号

改 `docker-compose.yml` 里的镜像 tag，然后：

```bash
/opt/ha-stack/scripts/sync-images.sh
/opt/ha-stack/scripts/engine.sh kiri
```

---

## 五、故障排查

完整的开机崩溃分析见 [TROUBLESHOOTING.md](TROUBLESHOOTING.md)。这里是速查表。

| 症状 | 先查 |
|---|---|
| 容器起不来 | `docker compose ps` → `docker compose logs <svc>` |
| 容器反复重启 | 端口冲突：`ss -tln \| grep -E '1883\|8123\|1880\|8482'` |
| 容器无 DNS / 无出网 | `iptables -S DOCKER-USER` 有没有 `kiri+` 规则 |
| mosquitto exit 3 | `dmesg \| grep apparmor` |
| HA 刷蓝牙告警 | compose 里有没有 `cap_add: [NET_ADMIN, NET_RAW]` |
| Matter 设备显示离线 | mDNS 是否泄漏到内部网卡，见 TROUBLESHOOTING |
| 引擎起不来 | `journalctl -u kiri.service -n 50` |
| 自动回落没触发 | `tail -20 /opt/ha-stack/watch.log` |

### 快速自检

```bash
/opt/ha-stack/scripts/engine.sh status
curl -s -o /dev/null -w 'HA %{http_code}\n'   http://127.0.0.1:8123/
curl -s -o /dev/null -w 'NR %{http_code}\n'   http://127.0.0.1:1880/
curl -s -o /dev/null -w 'MH %{http_code}\n'   http://127.0.0.1:8482/
grep '/usr/sbin/mosquitto' /sys/kernel/security/apparmor/profiles   # 应无输出
```

---

## 六、配置修改

### compose 文件

改完必须：

```bash
cd /opt/ha-stack
docker compose config --quiet     # 语法校验
docker compose up -d              # 应用
```

### 改 Matter 桥接的实体范围

Web UI → Bridges → 你的 Bridge → 实体过滤器。

推荐 `domain: switch` —— sensor 里有不少实体对应的设备常年离线，
桥接过去在 Apple Home 里也是灰的。

### 改 Matter 的 mDNS 网卡

```bash
# .env
MDNS_INTERFACE=wlan0
```

改完必须重启 matter-hub，并检查广播没有泄漏：

```bash
avahi-browse -rpt _matter._tcp | grep -oE 'wlp[0-9a-z]+|docker0|br-[a-f0-9]+' | sort -u
# 应只出现你的局域网网卡
```

### 加新服务

在 `docker-compose.yml` 里加一个 service，然后：

```bash
docker compose up -d <新服务>
```

---

## 七、不能做的事

- ❌ **不要删 `ha-config/`** —— 这是 HA 的全部配置，删了等于重装
- ❌ **不要用 `docker compose down -v`** —— `-v` 会删卷，数据没了
- ❌ **不要同时开两套引擎** —— 会互抢端口，见 TROUBLESHOOTING 坑 4
- ❌ **不要删 `matter-hub-data/`** —— 桥接状态和配对码在里面
- ❌ **不要给 Matter Hub 的 `command:` 去掉 `NODE_OPTIONS`** ——
  `command:` 覆盖了镜像原本按内存算堆大小的脚本，堆大小要显式给
- ❌ **不要改 mosquitto 的 `user: "1883:1883"`** —— 见 TROUBLESHOOTING 坑 3
- ❌ **不要把 `HA_TOKEN` 提交到 git** —— `.env` 已在 `.gitignore` 里
- ⚠️ **升级前先备份** —— HA 升级失败可能需要回滚配置
