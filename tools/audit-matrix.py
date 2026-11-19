#!/usr/bin/env python3
"""
需求矩阵审查 —— 按 spec-compliance-audit 的方法。

对每个文档承诺 / 用户要求，逐项核对当前仓库状态，
分类为 ok / MISSING，并给出证据行。

用法: python3 tools/audit-matrix.py [仓库路径]

退出码: 0 = 全部通过, 1 = 有缺口。

为什么要有这个文件：CI 的四道闸门检查的是"文件格式对不对"，
但没有检查"文档承诺的东西是不是真的存在且真的工作"。
这份矩阵把承诺逐条列出来，任何一条被破坏都能在本地立刻发现。
"""
import os
import re
import subprocess
import sys

REPO = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
os.chdir(REPO)


def sh(cmd):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True,
                              timeout=60).stdout
    except Exception as e:
        return f"ERROR: {e}"


def hasf(literal, files):
    """固定字符串匹配（避免 BRE 里 () 等特殊字符）。
    模式以 - 开头时必须用 -- 分隔，否则 grep 把它当选项。"""
    cmd = ("grep -nF -- " + " ".join(f"'{literal}'" for _ in [0])
           + " " + " ".join(files) + " 2>/dev/null | head -2")
    out = sh(cmd).strip()
    return (bool(out), out.replace("\n", " | ")[:180])


def has(pattern, files, flags="-nE"):
    """pattern 在指定文件里是否有命中，返回 (bool, 证据行)"""
    cmd = f"grep {flags} '{pattern}' {' '.join(files)} 2>/dev/null | head -2"
    out = sh(cmd).strip()
    return (bool(out), out.replace("\n", " | ")[:180])


def truthy(v):
    """把检查函数的返回值归一化成 (bool, evidence)。"""
    if isinstance(v, tuple):
        ok = bool(v[0])
        ev = v[1] if len(v) > 1 else ""
        return ok, ev
    return bool(v), ""


ALL = sh("git ls-files").split()

# ── 需求矩阵 ──────────────────────────────────────────────────────────────
# 每行：(需求ID, 来源, 需求描述, 检查函数)
REQUIREMENTS = [
    # ── 文档承诺 ──
    ("DOC-01", "README.md:快速开始",
     "步骤 1 明确告知用户先编辑 .env 再启动",
     lambda: has(r'编辑.*\.env|fill in at least these three', ["README.md", "README_EN.md"])),
    ("DOC-02", "README.md:快速开始",
     "步骤 2 给出 setup-mqtt.sh 生成凭据",
     lambda: has(r'setup-mqtt\.sh', ["README.md", "README_EN.md"])),
    ("DOC-03", "docs/OPERATIONS.md",
     "备份一节指向 scripts/backup.sh 且该文件存在",
     lambda: (has(r'scripts/backup\.sh', ["docs/OPERATIONS.md", "docs/OPERATIONS_EN.md"])[0]
               and os.path.exists("scripts/backup.sh"))),
    ("DOC-04", "docs/OPERATIONS.md",
     "快速自检指向 scripts/healthcheck.sh 且该文件存在",
     lambda: (has(r'scripts/healthcheck\.sh', ["docs/OPERATIONS.md", "docs/OPERATIONS_EN.md"])[0]
               and os.path.exists("scripts/healthcheck.sh"))),
    ("DOC-05", "docs/TROUBLESHOOTING.md",
     "五个开机坑全部有独立小节",
     lambda: (sh("grep -c '^## 坑 [0-9]' docs/TROUBLESHOOTING.md").strip() == "5")),
    ("DOC-06", "README.md:版本",
     "README 与 README_EN 版本号一致",
     lambda: (has(r'当前：\*\*(\S+?)\*\*', ["README.md"])[1].split("当前：")[1].strip("*） ") ==
               has(r'Current: \*\*(\S+?)\*\*', ["README_EN.md"])[1].split("Current:")[1].strip("*） "))),
    ("DOC-07", "docs/TROUBLESHOOTING.md",
     "英文摘要在文末且覆盖全部五个坑",
     lambda: (has(r'The fifth pitfall', ["docs/TROUBLESHOOTING.md"])[0]
               and has(r'## English summary', ["docs/TROUBLESHOOTING.md"])[0]
               and re.search(r'## English summary', sh("cat docs/TROUBLESHOOTING.md")).start()
               > sh("cat docs/TROUBLESHOOTING.md").find("## 坑 5"))),

    # ── 功能承诺 ──
    ("FUNC-01", "engine.sh",
     "engine.sh 支持 status/docker/kiri 三个子命令",
     lambda: has(r'case "\$\{1:-status\}" in', ["scripts/engine.sh"])
             and has(r'^\s+status\)|^\s+docker\)|^\s+kiri\)', ["scripts/engine.sh"])),
    ("FUNC-02", "engine.sh",
     "切换前等端口释放（host 网络容器抢端口）",
     lambda: has(r'wait_ports_free', ["scripts/engine.sh"])),
    ("FUNC-03", "engine.sh",
     "清理游离容器（compose down 管不到的）",
     lambda: has(r'stop_stray_containers', ["scripts/engine.sh"])),
    ("FUNC-04", "engine.sh",
     "切回 Kiri 时停掉空转的 dockerd",
     lambda: has(r'stop snap\.docker\.dockerd\.service', ["scripts/engine.sh"])),
    ("FUNC-05", "watch.sh",
     "连续 3 次不健康自动切回 Docker",
     lambda: has(r'MAXBAD=.*3', ["scripts/watch.sh"])),
    ("FUNC-06", "watch.sh",
     "引擎故障（两边都没容器）也要计入失败，不能永远待命",
     lambda: has(r'引擎故障', ["scripts/watch.sh"])),
    ("FUNC-07", "healthcheck.sh",
     "检查 9 项：引擎/容器/HTTP/MQTT/AppArmor/mDNS/实体/日志/属主",
     lambda: len(re.findall(r'head_ "', sh("cat scripts/healthcheck.sh"))) >= 9),
    ("FUNC-08", "healthcheck.sh",
     "退出码 0=正常 1=有问题（可挂监控）",
     lambda: has(r'exit 0', ["scripts/healthcheck.sh"])),
    ("FUNC-09", "kiri-forward.sh",
     "等 DOCKER-USER 链且链不存在时自建",
     lambda: has(r'iptables -w 5 -N DOCKER-USER', ["scripts/kiri-forward.sh"])),
    ("FUNC-10", "kiri-forward.sh",
     "永远 exit 0（规则失败不能拖垮引擎）",
     lambda: has(r'exit 0', ["scripts/kiri-forward.sh"])),
    ("FUNC-11", "kiri-forward.sh",
     "等待时间远小于 systemd TimeoutStartSec（90s 默认）",
     lambda: (lambda m: bool(m) and int(m.group(1)) <= 30)(
         re.search(r'WAIT_CHAIN="\$\{KIRI_WAIT_CHAIN:-(\d+)\}',
                   sh("cat scripts/kiri-forward.sh")))),
    ("FUNC-12", "setup-mqtt.sh",
     "自动探测 Docker 端点（不假设 /var/run/docker.sock）",
     lambda: has(r'find_docker', ["scripts/setup-mqtt.sh"])),
    ("FUNC-13", "setup-mqtt.sh",
     "passwd 非空才落地（空文件会让 broker 拒绝启动）",
     lambda: has(r'if \[ ! -s "\$CFG/passwd" \]', ["scripts/setup-mqtt.sh"])),
    ("FUNC-14", "fix-permissions.sh",
     "只改容器真正写入的子目录，不动顶层（否则夺走密码文件读权限）",
     lambda: (has(r'\[mosquitto/config\]="1883:1883"', ["scripts/fix-permissions.sh"])[0]
               and not re.search(r'\n\s*\[mosquitto\]="1883:1883"',
                                  sh("cat scripts/fix-permissions.sh")))),
    ("FUNC-15", "backup.sh",
     "归档权限 600（含 HA token）",
     lambda: has(r'chmod 600 "\$ARCHIVE"', ["scripts/backup.sh"])),
    ("FUNC-16", "backup.sh",
     "支持 --keep N 清理旧归档",
     lambda: (hasf("--keep)", ["scripts/backup.sh"])[0]
               and hasf('KEEP="${KEEP:-', ["scripts/backup.sh"])[0])),

    # ── compose 契约 ──
    ("CMP-01", "examples/docker-compose.yml",
     "HA 用 host 网络（mDNS/SSDP 需要）",
     lambda: has(r'network_mode: host', ["examples/docker-compose.yml"])),
    ("CMP-02", "examples/docker-compose.yml",
     "Mosquitto 显式 user 1883:1883（Kiri 下权限坑）",
     lambda: has(r'user: "1883:1883"', ["examples/docker-compose.yml"])),
    ("CMP-03", "examples/docker-compose.yml",
     "HA 授予 NET_ADMIN/NET_RAW（蓝牙 scanner）",
     lambda: has(r'NET_ADMIN', ["examples/docker-compose.yml"])
             and has(r'NET_RAW', ["examples/docker-compose.yml"])),
    ("CMP-04", "examples/docker-compose.yml",
     "Matter mDNS 限定网卡",
     lambda: has(r'mdns-network-interface', ["examples/docker-compose.yml"])),
    ("CMP-05", "examples/docker-compose.yml",
     "--mdns-strip-global-ipv6 是可选（发布版镜像没有该参数）",
     lambda: has(r'MATTER_HUB_EXTRA_ARGS', ["examples/docker-compose.yml"])),
    ("CMP-06", "examples/docker-compose.yml",
     "container_name 可加前缀（同一引擎跑两份栈）",
     lambda: has(r'CONTAINER_PREFIX', ["examples/docker-compose.yml"])),
    ("CMP-07", "examples/docker-compose.yml",
     "NODE_OPTIONS 显式给堆上限（command 覆盖了镜像原脚本）",
     lambda: has(r'NODE_OPTIONS: --max-old-space-size=256', ["examples/docker-compose.yml"])),

    # ── systemd 契约 ──
    ("SYS-01", "systemd/*.service",
     "所有 ExecStartPost/ExecStopPost 带 '-' 前缀（失败不拖垮 unit）",
     lambda: all(re.match(r'Exec(Start|Stop)Post=-', l.strip())
                for l in sh("cat systemd/*.service examples/kiri.service").splitlines()
                if re.match(r'\s*Exec(Start|Stop)Post=', l))),
    ("SYS-02", "systemd/*.service",
     "带等待的 unit 显式设置 TimeoutStartSec",
     lambda: has(r'TimeoutStartSec=', ["examples/kiri.service"])),
    ("SYS-03", "systemd/*.service",
     "unit 传 STACK_DIR 环境变量（改路径不改变量=操作错目录）",
     lambda: has(r'Environment=STACK_DIR=', ["systemd/ha-stack-watch.service"])
             and has(r'Environment=STACK_DIR=', ["systemd/ha-stack-kiri.service"])),
    ("SYS-04", "install/install.sh",
     "安装时同时重写路径和 Environment=STACK_DIR",
     lambda: has(r'Environment=STACK_DIR=\$STACK_DIR', ["install/install.sh"])),
    ("SYS-05", "install/install.sh",
     "支持 --no-systemd（试验安装不污染线上 unit）",
     lambda: hasf("--no-systemd)", ["install/install.sh"])),

    # ── CI 契约 ──
    ("CI-01", ".github/workflows/ci.yml",
     "四道闸门：lint / compose / 脱敏 / 文档",
     lambda: all(has(f'  {j}:', [".github/workflows/ci.yml"])[0]
                 for j in ("lint", "compose", "secrets", "docs"))),
    ("CI-02", ".github/workflows/ci.yml",
     "脱敏扫描覆盖文档（不排除 docs/ 与 README）",
     lambda: has(r"'\*\.md'", [".github/workflows/ci.yml"])),
    ("CI-03", "scripts/sanitize-scan.sh",
     "扫描规则不自匹配（私钥 pattern 拼开）",
     lambda: hasf("BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE", ["scripts/sanitize-scan.sh"])),
    ("CI-04", ".github/workflows/ci.yml",
     "链接检查用进程替换（管道子 shell 里 exit 1 不生效）",
     lambda: has(r'done < <\(', [".github/workflows/ci.yml"])),
    ("CI-05", ".github/workflows/ci.yml",
     "校验文档引用的文件真实存在",
     lambda: has(r'Every script referenced in the docs exists', [".github/workflows/ci.yml"])),
    ("CI-06", ".github/workflows/ci.yml",
     "校验 README 版本 == 发布 tag",
     lambda: has(r'mention the released version', [".github/workflows/ci.yml"])),

    # ── 脱敏扫描器（v1.1.2 新增）──
    ("SCAN-01", "scripts/sanitize-scan.sh",
     "扫描器是独立脚本（CI 与自检共用同一份代码）",
     lambda: (os.path.exists("scripts/sanitize-scan.sh")
               and hasf("scripts/sanitize-scan.sh", [".github/workflows/ci.yml"])[0])),
    ("SCAN-02", "scripts/sanitize-scan.sh",
     "变量名列表包含裸 TOKEN / PASSWORD / SECRET",
     lambda: hasf("(HAMH_HA_TOKEN|HASS_TOKEN|HA_TOKEN|TOKEN|", ["scripts/sanitize-scan.sh"])),
    ("SCAN-03", "scripts/sanitize-scan.sh",
     "有散文长串规则（贴进文档的 token 不会被变量名规则抓到）",
     lambda: hasf("[A-Za-z0-9+/]{40,}={0,2}", ["scripts/sanitize-scan.sh"])),
    ("SCAN-04", "scripts/sanitize-scan.sh",
     "私钥 pattern 拼开不自匹配",
     lambda: hasf("BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE", ["scripts/sanitize-scan.sh"])),
    ("SCAN-05", "scripts/sanitize-scan.sh",
     "自检样本文件被排除（否则扫描器永远红）",
     lambda: hasf(":!scripts/selftest-fixtures.sh", ["scripts/sanitize-scan.sh"])),
    ("SCAN-06", "scripts/sanitize-scan.sh",
     "CI workflow 本身不被豁免（豁免它等于给真 token 开后门）",
     lambda: (":!.github/workflows" not in sh("cat scripts/sanitize-scan.sh")
               and "ci.yml:" not in sh("cat scripts/sanitize-scan.sh"))),
    ("SCAN-07", "scripts/selftest-fixtures.sh",
     "样本脚本存在且用 openssl 生成真私钥",
     lambda: (os.path.exists("scripts/selftest-fixtures.sh")
               and hasf("openssl genrsa", ["scripts/selftest-fixtures.sh"])[0])),
    ("SCAN-08", ".github/workflows/ci.yml",
     "有 scanner-selftest job（防扫描规则退化）",
     lambda: hasf("scanner-selftest:", [".github/workflows/ci.yml"])),
    ("SCAN-09", ".github/workflows/ci.yml",
     "自检 job 断言每个植入的样本都被报出",
     lambda: hasf("did not report the planted leak", [".github/workflows/ci.yml"])),
    ("SCAN-10", ".github/workflows/ci.yml",
     "自检 job 断言占位符不被误报",
     lambda: hasf("flagged the placeholder", [".github/workflows/ci.yml"])),
    ("SCAN-11", ".github/workflows/ci.yml",
     "自检 job 用 set +e（扫描器预期失败，不能让 set -e 提前退出）",
     lambda: hasf("set +e", [".github/workflows/ci.yml"])),
    ("SCAN-12", "CONTRIBUTING.md",
     "文档说明了扫描器与自检的用法（中英）",
     lambda: (hasf("./scripts/sanitize-scan.sh", ["CONTRIBUTING.md"])[0]
               and hasf("./scripts/selftest-fixtures.sh", ["CONTRIBUTING.md"])[0])),

    # ── GitHub 规范 ──
    ("GH-01", "仓库根",
     "LICENSE 存在且是 MIT",
     lambda: os.path.exists("LICENSE") and has(r'MIT License', ["LICENSE"])),
    ("GH-02", "仓库根",
     "CHANGELOG 遵循 Keep a Changelog 且有 Unreleased 段",
     lambda: has(r'Keep a Changelog', ["CHANGELOG.md"])
             and has(r'## \[Unreleased\]', ["CHANGELOG.md"])),
    ("GH-03", "仓库根",
     "CONTRIBUTING 存在",
     lambda: os.path.exists("CONTRIBUTING.md")),
    ("GH-04", "仓库根",
     "SECURITY 存在",
     lambda: os.path.exists("SECURITY.md")),
    ("GH-05", "仓库根",
     "Issue 模板存在",
     lambda: len(sh("ls .github/ISSUE_TEMPLATE/ 2>/dev/null").split()) >= 2),
    ("GH-06", "仓库根",
     ".gitignore 覆盖所有敏感路径",
     lambda: all(p in sh("cat .gitignore") for p in
                  (".env", "ha-config", "matter-hub-data", "nodered-data"))),
    ("GH-07", "仓库根",
     "脚本在 git index 里带可执行位",
     lambda: int(sh("git ls-files -s | grep -c '^100755'").strip() or 0) >= 8),
]


def main():
    rows = []
    for rid, src, req, check in REQUIREMENTS:
        try:
            ok, evidence = truthy(check())
        except Exception as e:
            ok, evidence = False, f"CHECK-ERROR: {e}"
        rows.append((rid, src, req, "ok" if ok else "MISSING", evidence))

    w = max(len(r[0]) for r in rows)
    print(f"{'ID':<{w}}  {'STATUS':<8} 需求")
    print("-" * (w + 60))
    for rid, src, req, status, ev in rows:
        mark = "✓" if status == "ok" else "✗"
        print(f"{rid:<{w}}  {mark} {status:<6} {req}")
        if status != "ok" and ev:
            print(f"{'':<{w}}          └─ {ev[:150]}")

    missing = [r for r in rows if r[3] != "ok"]
    print()
    print(f"总计 {len(rows)} 项，通过 {len(rows)-len(missing)}，缺口 {len(missing)}")
    if missing:
        print("\n缺口明细:")
        for rid, src, req, status, ev in missing:
            print(f"  {rid} [{src}] {req}")
            if ev:
                print(f"       {ev[:160]}")
    return 0 if not missing else 1


if __name__ == "__main__":
    sys.exit(main())
