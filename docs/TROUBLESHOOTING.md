# 开机崩溃四坑详解 / The Four Boot Crashes

> 中文为主，关键排查命令附英文说明。English summary at the bottom.

本文记录把 Home Assistant + Matter 栈迁到 Kiri 引擎时，真实踩到的四个开机崩溃。
每一个都附**根因证据**和**可复现的验证方法**，不是猜测。

**背景**：2026-11-18 早上 10:21 机器重启后，Kiri 引擎起不来，mosquitto 容器
在 7 分钟内崩溃 28 次，生产栈靠自动回落机制切回 Docker 才没有中断服务。

---

## 坑 1：systemd `ExecStartPost=` 缺 `-` 前缀 → 引擎被反复杀

### 现象

```
kiri.service: Control process exited, code=exited, status=1/FAILURE
kiri.service: Failed to start kiri.service - Kiri container engine.
kiri.service: Scheduled restart job, restart counter is at 1.
```

引擎永远起不来，systemd 无限重启它。

### 根因

我们给 `kiri.service` 加了一个 drop-in，用来在开机时往 `DOCKER-USER` 链插
放行规则：

```ini
# 错的写法
[Service]
ExecStartPost=/bin/sh -c 'iptables -C DOCKER-USER ... || iptables -I DOCKER-USER ...'
```

systemd 的语义：**`ExecStartPost=`（不带 `-`）执行失败，等于整个 unit 启动失败**。
而 `ExecStartPost=-`（带 `-`）表示「忽略失败」。

上游原始 unit 自带的就是 `ExecStartPost=-`。我们写 drop-in 时把 `-` 漏了，
于是「iptables 偶尔失败」被升级成「引擎永远起不来」。

### 修复

1. 基础 unit 完整重写，确保 `ExecStartPost=` 都带 `-` 前缀。
2. 规则逻辑挪进独立脚本 `scripts/kiri-forward.sh`，**脚本永远 `exit 0`**，
   失败只写 syslog，绝不拖垮引擎。

```ini
[Service]
ExecStartPost=-/bin/bash /opt/ha-stack/scripts/kiri-forward.sh apply
ExecStopPost=-/bin/bash /opt/ha-stack/scripts/kiri-forward.sh remove
```

### 验证

```bash
systemctl show kiri.service -p NRestarts -p Result
# 期望：NRestarts=0  Result=success
```

---

## 坑 2：开机时 DOCKER-USER 链不存在 + 默认路由未就绪 → 容器无 DNS 无出网

### 现象

```
sh: iptables: No chain/target/match by that name.
kiri-init: no uplink: no default route
```

容器起来了但**没有 DNS、不能出网**。

### 根因

两个独立的启动竞态：

**2a — DOCKER-USER 链不存在**
本机 FORWARD 策略是 `DROP`（Docker 的默认值）。Kiri 装自己的 nftables 规则时
用的是 accept 策略，但宿主策略先被评估，所以 Kiri 的 bridge 容器默认出不去
（上游 issue [#261](https://github.com/libracoder/kiri/issues/261)、
[#247](https://github.com/libracoder/kiri/issues/247)、
[#330](https://github.com/libracoder/kiri/issues/330)）。

修法是往 `DOCKER-USER` 链插 ACCEPT 规则。但**开机那一刻 Docker 还没启动**，
链不存在，`iptables` 直接报错。

**2b — 默认路由未就绪**
Kiri 启动时读 `/proc/net/route` 找默认网卡来决定 bridge 用哪个 uplink。
路由还没就绪就报 `no uplink: no default route`。
注意：Ubuntu 的 `network-online.target` **并不真的保证**默认路由已就绪，
不能指望它。

### 修复

`scripts/kiri-forward.sh` 里做两件事：

```bash
wait_route 90   # 等 ip route show default 有输出
wait_chain 90   # 等 DOCKER-USER 链出现；等不到就自己建一条并挂进 FORWARD 首位
```

同时在 unit 里加 `ExecStartPre=` 循环等路由（最多 90s，之后照常启动，
不阻塞开机）。

### 验证

```bash
# 模拟开机：删掉链 + 删掉路由，重启引擎
iptables -D DOCKER-USER -i kiri+ -j ACCEPT
ip route del default
systemctl restart kiri.service

systemctl show kiri.service -p NRestarts -p Result
# 期望：NRestarts=0  Result=success

iptables -S DOCKER-USER
# 期望：-A DOCKER-USER -i kiri+ -j ACCEPT
```

---

## 坑 3：宿主残留 AppArmor profile → mosquitto 读不到配置（最隐蔽）

### 现象

```
Error: Unable to open config file /mosquitto/config/mosquitto.conf.
```

容器反复 exit 3，`restart: unless-stopped` 无限重试（实测 7 分钟内 28 次）。

### 根因

宿主有个 `/etc/apparmor.d/mosquitto`——**这个文件属于 `apparmor` 包**，是
mosquitto 的 apt 包被卸载后残留的。它是个路径 profile：

```
profile mosquitto /usr/sbin/mosquitto { ... }
```

路径 profile 会挂到**任何** executable 是 `/usr/sbin/mosquitto` 的进程上，
包括容器里那个。

- **Docker** 给容器强制套 `docker-default` profile，覆盖掉路径 profile
  → Docker 侧永远正常，**这个 bug 在 Docker 上完全不可见**
- **Kiri** 不套任何 profile → 宿主的 profile 直接挂到容器里的
  `/usr/sbin/mosquitto` → 容器只被允许读 `/etc/mosquitto/*`，读不到
  `/mosquitto/config/mosquitto.conf` → exit 3

### 证据（内核审计日志）

```bash
dmesg | grep -i apparmor | tail
```

```
apparmor="DENIED" operation="open" class="file" profile="mosquitto"
name="/mosquitto/config/mosquitto.conf" fsuid=1883 ouid=1883
```

### 走过的弯路（别重复）

- **改文件权限没用**（试过 644 / 755 / 777）：AppArmor 拒绝的是路径，不是权限位。
- **改属主也没用**：owner 匹配了照样被 LSM 拒。
- **只把 profile 文件改名成 `.disabled` 不够**：文件确实不再被加载，但**内核里
  profile 还挂着**，而且 `apparmor.service` 每次开机都会按路径 hint 挂回来。
- **唯一有效的判据**：

  ```bash
  grep '/usr/sbin/mosquitto' /sys/kernel/security/apparmor/profiles
  ```

  有输出 = 还在 = 还会出事。

### 修复

两步都要做：

```bash
mv /etc/apparmor.d/mosquitto /etc/apparmor.d/mosquitto.disabled
apparmor_parser -R /etc/apparmor.d/mosquitto.disabled
```

并且用 systemd unit 在开机时执行，**必须排在 `apparmor.service` 之后**：

```ini
[Unit]
After=apparmor.service
Requires=apparmor.service
```

### 通用排查心法

容器报 EACCES 但权限看着完全正常时：

1. **先 `dmesg | grep apparmor`**，不要猜权限
2. 容器内 `strace` 也能定位，但要装 strace，慢
3. 看到 `open() = -1 EACCES` 而 `stat` 权限没问题 → 就是 LSM，不是权限

---

## 坑 4：两套引擎同时自启 → 互抢端口

### 现象

开机后 Docker 侧的 `homeassistant` / `nodered` 容器反复
`Restarting (1)`，日志刷满端口绑定失败。

### 根因

`snap.docker.dockerd.service` 开机自启 → 把 Docker 侧的 ha-stack 容器
（`restart: unless-stopped`）全部拉起来 → **和 Kiri 抢同一批端口**
（8123 / 1880 / 1883 / 8482）。

谁先起来谁拿到端口，另一方无限重启。2026-11-18 的两次开机分别出现了
两种结果：早上 Docker 侧赢（Kiri 起不来，就是坑 1~3 的现场），
下午 Kiri 侧赢（Docker 侧无限重启）。

**这是坑 1~3 的上游原因** —— 不是三个独立故障，而是「两套引擎竞争」
引发的连锁反应。

### 修复

```bash
systemctl disable snap.docker.dockerd.service   # 不再开机自启
```

回落能力不能丢，所以 `engine.sh docker` 里加了按需拉起：

```bash
if ! docker info >/dev/null 2>&1; then
  systemctl start snap.docker.dockerd.service
  # 轮询等 docker info 就绪
fi
```

另外，切回 Kiri 时如果 Docker 侧已空，顺手把空转的 dockerd 停掉
（`dockerd + containerd` 白占 50–200 MB）。

### 附带修的两处

- **HA 蓝牙告警 56 → 0**：compose 给 homeassistant 加
  `cap_add: [NET_ADMIN, NET_RAW]`。缺这两个 cap 时 HA 每次启停都刷
  `hci0 (xx:xx): Failed to force stop scanner`。
  验证：`CapEff` 从 `0xa80425fb` 变成 `0xa80435fb`。
- **mosquitto 显式 `user: "1883:1883"`**：官方镜像 entrypoint 会 chown 后
  降权运行；Kiri 下容器内 root 读 0600 属主 1883 的文件会 EACCES。
  显式指定用户后 owner 匹配，密码文件可以保持 0600 不放宽。

---

## 附带修的两处生产缺陷

### 监控的「引擎不在位」漏判

原 `watch.sh` 只判断「Kiri 上有没有 homeassistant 容器」，没有就当成
「已回落 Docker，监控待命」。

**但如果引擎挂了（kiri.service 挂了 / socket 失效）且 Docker 侧也没栈，
这个分支会永远待命 → 永远不回落 → 生产直接断。**

现在分三种情况：

| 情况 | 判断 |
|---|---|
| Kiri 有 homeassistant 容器 | 正常巡检 |
| Kiri 没有 + Docker 有 | 已回落，待命 |
| **两边都没有** | **引擎故障，计入 BAD，3 次后切回 Docker** |

### `compose down` 之后必须等端口释放

host 网络的容器直接占宿主端口。`compose down` 返回后 docker-proxy 可能还在
收尾，不等就会让新容器抢不到端口 → exit 3 循环。

另外 `compose down` **只管本项目容器**，调试遗留的游离容器用 host 网络抢端口，
`down` 管不到 → `engine.sh` 现在按镜像过滤把它们 stop 掉（**只 stop，不 rm**）。

---

## 坑 5：脚本等待时间超过 systemd 启动超时 → 引擎被杀（修复之间的相互影响）

### 现象

```
Process: 11922 ExecStartPost=/bin/bash .../kiri-forward.sh apply (code=killed, signal=TERM)
kiri.service: start-post operation timed out. Terminating.
INFO  engine shutting down signal=15
```

引擎在开机时反复被杀。而且这个 bug **只在"某两个修复同时生效"时才出现**，
单独看每个修复都是对的。

### 根因：两个正确修复互相打架

修复 #2 让脚本开机时等 `DOCKER-USER` 链出现（最多 90s）。
修复 #4 禁用了 dockerd 开机自启 —— 于是**开机时根本不会有 Docker 启动，
链永远不会出现**，脚本必然死等满 90s。

而 systemd 的 `TimeoutStartSec` 默认是 **90s**。`ExecStartPre`（等路由，最多 90s）
加上 `ExecStartPost`（等链，最多 90s）最坏需要 180s，远超预算。

systemd 的行为是：**启动超时 → 杀掉 ExecStartPost → 认为 unit 失败 →
终止主进程**。于是引擎被自己装的规则脚本害死。

```
ExecStartPre  等路由        ≤ 90s
ExecStartPost 等链 + 插规则  ≤ 90s   ← 加起来 180s > TimeoutStartSec 90s
                                        → systemd 杀 ExecStartPost → 引擎死
```

### 修复

1. **缩短等待时间**。等链本来就没意义 —— 等不到就自己建链，等再久也一样：

   ```bash
   WAIT_CHAIN="${KIRI_WAIT_CHAIN:-10}"    # 原来 90
   WAIT_ROUTE="${KIRI_WAIT_ROUTE:-20}"    # 原来 90
   ```

2. **显式设置 `TimeoutStartSec=180`**（见 `examples/kiri.service`），
   留出余量，别依赖默认值。

3. **给 systemd unit 加 `TimeoutStartSec`** 是个通用原则：任何带等待的
   `ExecStartPre`/`ExecStartPost` 都要和它对齐。

### 验证

```bash
# 模拟开机：删掉链，测冷启动耗时
iptables -F DOCKER-USER; iptables -X DOCKER-USER
time systemctl restart kiri.service
systemctl show kiri.service -p NRestarts -p Result
# 期望：耗时 < 30s，NRestarts=0，Result=success
```

实测修复后：**10 秒完成**，规则正确安装。

### 教训

**修 A 让 B 失效时，故障会出现在两者的交集上，而不是任何单独一个。**
所以每个修复都必须配一个"组合场景"的验证 —— 这里就是：
「链不存在 + 引擎启动」。

---

## 完整验证清单

```bash
# 1. 引擎
systemctl show kiri.service -p NRestarts -p Result
#    NRestarts=0  Result=success

# 2. 容器全健康
DOCKER_HOST=unix:///run/kiri/docker.sock docker-kiri ps

# 3. 功能
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8123/   # 200
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:1880/   # 200
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8482/   # 200

# 4. MQTT 认证
docker-kiri exec mosquitto sh -c \
  'mosquitto_pub -h 127.0.0.1 -u ha_user -P "$(cat /mosquitto/config/.ha_mqtt_password)" -t SYS/t -m p'

# 5. 零错误
docker-kiri logs homeassistant --since 1h | grep -c ' ERROR '     # 0
docker-kiri logs homeassistant --since 1h | grep -c 'force stop scanner'  # 0
docker-kiri logs matter-hub --since 1h | grep -cE 'WARN.*Mdns'    # 0

# 6. AppArmor 已卸载
grep '/usr/sbin/mosquitto' /sys/kernel/security/apparmor/profiles  # 无输出

# 7. mDNS 只在局域网网卡
avahi-browse -rpt _matter._tcp | grep -oE 'wlp[0-9a-z]+|docker0|br-[a-f0-9]+'
#    只应出现你的局域网网卡

# 8. HA 实体完整
docker-kiri exec homeassistant python3 -c \
  "import json;print(len(json.load(open('/config/.storage/core.entity_registry'))['data']['entities']))"

# 9. 引擎重启后自动恢复
systemctl restart kiri.service
sleep 15
docker-kiri ps --filter health=healthy --format '{{.Names}}'   # 4 个
```

---

## English summary

Five boot crashes hit when moving an HA + Matter stack onto the Kiri engine.
Each one below has root-cause evidence, not guesswork.

The fifth pitfall is the one to read twice: it only appears when two
individually correct fixes interact, so testing either fix on its own
never reveals it.

1. **`ExecStartPost=` without the `-` prefix.** In systemd, a failing
   `ExecStartPost=` (no dash) fails the *entire unit* — so an occasional
   `iptables` error became "the engine never starts". Fix: `-` prefix plus a
   script that always exits 0.

2. **Boot-time races.** The `DOCKER-USER` chain does not exist yet (Docker has
   not started) and no default route exists yet (`network-online.target` does
   not really guarantee it). The host FORWARD policy is DROP, so bridge
   containers end up with no DNS/egress. Fix: wait up to 90 s for both, and
   create the chain ourselves if needed.

3. **A leftover host AppArmor path profile.** `/etc/apparmor.d/mosquitto`
   belongs to the `apparmor` package and attaches to any process whose
   executable is `/usr/sbin/mosquitto` — including the one in a container.
   Docker force-applies `docker-default` and hides this completely; Kiri does
   not, so the broker exits 3 in a retry loop. Fix: rename the file **and**
   `apparmor_parser -R`, plus a systemd unit that runs *after*
   `apparmor.service`. The only valid check is
   `grep '/usr/sbin/mosquitto' /sys/kernel/security/apparmor/profiles`.

   **Rule of thumb: when a container gets EACCES but the permissions look
   right, run `dmesg | grep apparmor` before touching permissions.**

4. **Two engines autostarting at once.** The Docker daemon started its
   `restart: unless-stopped` containers and fought Kiri for the same host
   ports; whoever started first won and the other crash-looped. This is the
   *cause* of #1–#3. Fix: `systemctl disable snap.docker.dockerd.service` and
   start it on demand in `engine.sh docker`.

5. **The fifth pitfall: a script that waits longer than the systemd start
   timeout.** The
   `ExecStartPost` that installs the FORWARD rules waited up to 90s for the
   `DOCKER-USER` chain, and `ExecStartPre` waited up to 90s for the default
   route — 180s in total, against systemd's 90s `TimeoutStartSec` default.
   systemd killed the `ExecStartPost` and took the engine with it.

   This one only appears when **two correct fixes interact**: waiting for
   the chain is right, and not starting the Docker daemon at boot is also
   right — but together they mean the chain never appears, so the wait
   always burns out the timeout. Fix: shorten the waits (the chain wait is
   pointless — we create the chain ourselves when it is missing) and set
   `TimeoutStartSec=180` explicitly.

   **Lesson: when fix A invalidates fix B, the failure shows up at their
   intersection, not in either one alone.** Every fix needs a combined
   scenario test — here: "chain absent + engine start".

Two production defects fixed along the way: the health monitor's
"engine not present" branch could wait forever when *both* engines were down
(now it counts as a failure and triggers the fallback), and `compose down`
needs an explicit wait for port release plus cleanup of stray containers it
does not know about.
