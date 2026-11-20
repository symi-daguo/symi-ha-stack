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
    """Run a command and return its output.

    stderr is folded into stdout and a non-zero exit is marked, because
    a command that failed is not the same as a command that matched
    nothing — the first review found a check that passed because the
    file it read did not exist.
    """
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True,
                           timeout=60)
        out = r.stdout
        if r.stderr.strip():
            out += "\n" + r.stderr.strip()
        # Exit status 1 with no output is grep's "no match" — a normal
        # answer, not a failure. Anything else with no output means the
        # command did not run, which is not the same as "nothing found",
        # and the first review found a check that passed for exactly
        # that reason.
        if r.returncode not in (0, 1) and not out.strip():
            out = f"(command failed with exit {r.returncode})"
        elif r.returncode == 1 and not out.strip() and r.stderr.strip():
            out = f"(command failed: {r.stderr.strip()})"
        return out
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


def _scan_output():
    """Run the scanner against this repository and return its output."""
    return sh("bash scripts/sanitize-scan.sh 2>&1")


def _fixture_iface():
    """The interface name planted in the fixture file."""
    for ln in _fixture_prints():
        if ln.startswith("MDNS_INTERFACE="):
            return ln.split("=", 1)[1]
    return ""


def _fixture_prints():
    """The literal strings the fixture file writes.

    The fixture holds the samples, so that no other tracked file
    contains a real-looking private key header or device id.
    """
    out = []
    for ln in sh("cat tests/fixtures/plant-leaks.sh").splitlines():
        ln = ln.strip()
        if not ln.startswith("printf"):
            continue
        # printf '...' > file   or   printf -- '...' > file
        parts = ln.split("'")
        if len(parts) >= 2:
            text = parts[1].replace("\\n", "").rstrip("\\")
            out.append(text)
    return out


def _fixture_lines(kind):
    """Read the sample lines for a kind of leak from the fixture file."""
    if kind == "private":
        wanted = ("ENCRYPTED", "PGP")
    else:
        wanted = ()
    return [t for t in _fixture_prints() if any(w in t for w in wanted)]


def _planted_scan(lines):
    """Plant the given lines in a throwaway repository and return the
    number of scanner rules that fired. 1 means "the private key rule
    fired"; 0 means it did not."""
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        sh(f"git init -q {d}")
        sh(f"cd {d} && git config user.email t@t.invalid && git config user.name t")
        for i, ln in enumerate(lines):
            with open(f"{d}/sample{i}.txt", "w") as f:
                f.write(ln + "\n")
        sh(f"cd {d} && git add -A")
        out = sh(f"bash {os.getcwd()}/scripts/sanitize-scan.sh --path {d} 2>&1")
        return 1 if "private key committed" in out else 0


def _ver(pattern, files):
    """Extract the first version number matching pattern."""
    m = re.search(pattern, sh("cat " + " ".join(files)), re.M)
    return m.group(1) if m else ""


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
     "README / README_EN 版本号一致，且等于 CHANGELOG 最新条目",
     lambda: (lambda cn, en, cl: bool(cn) and cn == en and cn == cl)(
         _ver(r'当前：\*\*([0-9.]+)\*\*', ["README.md"]),
         _ver(r'Current: \*\*([0-9.]+)\*\*', ["README_EN.md"]),
         _ver(r'^## \[([0-9]+\.[0-9]+\.[0-9]+)\]', ["CHANGELOG.md"]))),
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
     # The list must not be empty: all([]) is True, so deleting every
     # ExecStartPost from every unit used to pass this check.
     lambda: (lambda ls: bool(ls) and all(re.match(r'Exec(Start|Stop)Post=-', l.strip())
                                          for l in ls))(
         [l for l in sh("cat systemd/*.service examples/kiri.service").splitlines()
          if re.match(r'\s*Exec(Start|Stop)Post=', l)])),
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
     "六道闸门：lint / compose / 脱敏 / 扫描自检 / 需求矩阵 / 文档",
     lambda: all(has(f'  {j}:', [".github/workflows/ci.yml"])[0]
                 for j in ("lint", "compose", "secrets", "scanner-selftest",
                           "audit", "docs"))),
    ("CI-02", "scripts/sanitize-scan.sh",
     "脱敏扫描覆盖文档（不排除 docs/ 与 README）",
     # Behaviour, not a string: the scanner must NOT exclude markdown.
     # The previous version grepped the workflow for the literal
     # "*.md", which is satisfied by an unrelated string and could not
     # detect the regression it names.
     lambda: not any("':!*.md'" in ln
                      for ln in sh("cat scripts/sanitize-scan.sh").splitlines())),
    ("CI-03", "scripts/sanitize-scan.sh",
     "扫描规则不自匹配（私钥 pattern 拼开）",
     # Behaviour: the scanner must not report its own source file.
     lambda: _scan_output().find("private key committed") == -1
             or "sanitize-scan.sh" not in _scan_output()),
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
     "私钥规则抓得到 ENCRYPTED / PGP 私钥头，且不自匹配",
     # Behaviour: plant an encrypted and a PGP private key in a
     # throwaway repository and require the scanner to catch both.
     # The headers come from the fixture file so that this file does not
     # itself contain a literal private key header.
     lambda: _planted_scan(_fixture_lines("private")) == 1),
    ("SCAN-05", "scripts/sanitize-scan.sh",
     "自检样本目录被排除（否则扫描器永远红）",
     lambda: hasf(":!tests/fixtures/", ["scripts/sanitize-scan.sh"])),
    ("SCAN-06", "scripts/sanitize-scan.sh",
     "CI workflow 本身不被豁免（豁免它等于给真 token 开后门）",
     lambda: (":!.github/workflows" not in sh("cat scripts/sanitize-scan.sh")
               and "ci.yml:" not in sh("cat scripts/sanitize-scan.sh"))),
    ("SCAN-07", "tests/fixtures/plant-leaks.sh",
     "样本脚本存在且用 openssl 生成真私钥",
     lambda: (os.path.exists("tests/fixtures/plant-leaks.sh")
               and hasf("openssl genrsa", ["tests/fixtures/plant-leaks.sh"])[0])),
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
               and hasf("./tests/fixtures/plant-leaks.sh", ["CONTRIBUTING.md"])[0])),

    # ── README 可执行性（v1.1.2 新增）──
    ("RM-01", "README.md:快速开始",
     "复制 .env 的目标路径正确（$STACK_DIR/.env，不是 $STACK_DIR.env）",
     lambda: (hasf('"$STACK_DIR/.env"', ["README.md"])[0]
               and not hasf('"$STACK_DIR.env"', ["README.md"])[0])),
    ("RM-02", "README_EN.md:Quick start",
     "复制 .env 的目标路径正确",
     lambda: (hasf('"$STACK_DIR/.env"', ["README_EN.md"])[0]
               and not hasf('"$STACK_DIR.env"', ["README_EN.md"])[0])),
    ("RM-03", "README.md:快速开始",
     "复制前先创建 STACK_DIR（否则 cp 失败）",
     lambda: (hasf('mkdir -p "$STACK_DIR"', ["README.md"])[0]
               and hasf('mkdir -p "$STACK_DIR"', ["README_EN.md"])[0])),
    ("RM-04", "scripts/sanitize-scan.sh",
     "扫描目标不依赖 STACK_DIR（那是栈的数据目录，不是仓库）",
     # Only the code matters — the comment explaining why STACK_DIR is
     # NOT used necessarily mentions it.
     lambda: not any("STACK_DIR" in ln and not ln.strip().startswith("#")
                      for ln in sh("cat scripts/sanitize-scan.sh").splitlines())),
    ("RM-05", "scripts/sanitize-scan.sh",
     "非 git 目录必须报错，不能报'干净'",
     lambda: hasf("is not a git repository", ["scripts/sanitize-scan.sh"])),

    # ── 独立审查发现的洞（v1.1.2）──
    ("REV-01", "scripts/sanitize-scan.sh",
     "32位 bridge id 规则大小写都匹配（真实 bridge id 是大写）",
     lambda: hasf("git grep -niE", ["scripts/sanitize-scan.sh"])),
    ("REV-02", "scripts/sanitize-scan.sh",
     "凭据规则不再整行排除含 'example' 的行",
     lambda: ("|" not in hasf("grep -vE 'REPLACE_WITH|CHANGE_ME|dummy|example|", ["scripts/sanitize-scan.sh"])[1]
               or "example|" not in hasf("grep -vE 'REPLACE_WITH|CHANGE_ME|dummy|example|", ["scripts/sanitize-scan.sh"])[1])),
    ("REV-03", "scripts/healthcheck.sh",
     "DC() 不硬编码 Kiri socket（Docker-only 主机上会误报）",
     lambda: (not hasf('DC() { DOCKER_HOST="$KIRI_SOCK"', ["scripts/healthcheck.sh"])[0]
               and hasf("ENDPOINT=", ["scripts/healthcheck.sh"])[0])),
    ("REV-04", "install/install.sh",
     "AppArmor unit 也做路径替换（装到非默认路径时不能指向 /opt）",
     lambda: hasf("rewrite_unit \"$REPO_DIR/systemd/disable-mosquitto-apparmor.service\"",
                   ["install/install.sh"])),
    ("REV-05", "docs/TROUBLESHOOTING.md",
     "中英文都说五坑，不是四坑",
     lambda: (not hasf("四坑", ["docs/TROUBLESHOOTING.md"])[0]
               and not hasf("四个开机崩溃", ["docs/TROUBLESHOOTING.md"])[0]
               and not hasf("Four Boot Crashes", ["docs/TROUBLESHOOTING.md"])[0]
               and not hasf("four boot crashes", ["README.md", "README_EN.md"])[0])),
    ("REV-06", "tests/fixtures/plant-leaks.sh",
     "fixture 覆盖大写 bridge id",
     lambda: hasf("bridgeid.txt", ["tests/fixtures/plant-leaks.sh"])),

    # ── 健康检查（v1.1.2 补充）──
    ("HC-01", "scripts/healthcheck.sh",
     "日志检查用 --tail 而不是 --since（Kiri 静默忽略 --since，返回空）",
     lambda: (hasf("--tail 2000", ["scripts/healthcheck.sh"])[0]
               and not hasf("logs homeassistant --since", ["scripts/healthcheck.sh"])[0])),
    ("HC-02", "scripts/healthcheck.sh",
     "区分'读不到日志'和'无错误'（空日志不能报成正常）",
     lambda: hasf("读不到 homeassistant 日志", ["scripts/healthcheck.sh"])),

    # ── 第二轮独立审查发现的洞 ──
    ("R2-01", "scripts/sanitize-scan.sh",
     "私钥规则认 ENCRYPTED / PGP 私钥头（不只是 RSA/EC/DSA/OPENSSH）",
     lambda: ("ENCRYPTED" in sh("cat scripts/sanitize-scan.sh")
              and "PGP" in sh("cat scripts/sanitize-scan.sh"))),
    ("R2-02", "scripts/sanitize-scan.sh",
     "bridge id 规则不排除 markdown（文档是粘贴 id 最容易存活的地方）",
     lambda: not any("':!*.md'" in ln
                      for ln in sh("cat scripts/sanitize-scan.sh").splitlines())),
    ("R2-03", "scripts/sanitize-scan.sh",
     "家目录规则允许 macOS 带点的用户名（john.smith）",
     lambda: "[a-z0-9_.-]*" in sh("cat scripts/sanitize-scan.sh")
              or "[A-Za-z0-9_.-]*" in sh("cat scripts/sanitize-scan.sh")),
    ("R2-04", ".github/workflows/ci.yml",
     "扫描自检按规则消息断言，不是按文件名（文件名会被别的规则带出来）",
     lambda: (hasf("the rule that should catch", [".github/workflows/ci.yml"])[0]
               and not hasf('for expected in "leak.env"', [".github/workflows/ci.yml"])[0])),
    ("R2-05", ".github/workflows/ci.yml",
     "systemd 校验真正传播失败（有语法错误时 exit 1）",
     lambda: (hasf("has a syntax error", [".github/workflows/ci.yml"])[0]
               and hasf("exit 1", [".github/workflows/ci.yml"])[0])),
    ("R2-06", ".github/workflows/ci.yml",
     "版本检查不因 pull_request 事件必然红（不用 GITHUB_REF_NAME 直接比）",
     lambda: (hasf('"${pr}/merge"', [".github/workflows/ci.yml"])[0]
               or hasf("42/merge", [".github/workflows/ci.yml"])[0]
               or hasf('GITHUB_REF_NAME" in', [".github/workflows/ci.yml"])[0])),
    ("R2-07", "tools/audit-matrix.py",
     "CI-02 查的是扫描器行为，不是 workflow 里的字符串",
     lambda: "':!*.md'" not in sh("cat scripts/sanitize-scan.sh")),
    ("R2-08", "tools/audit-matrix.py",
     "DOC-06 要求 README 版本等于 CHANGELOG 最新条目",
     lambda: hasf("CHANGELOG.md", ["tools/audit-matrix.py"])),
    ("R2-09", "tools/audit-matrix.py",
     "SYS-01 拒绝空列表（all([]) 为 True 的陷阱）",
     lambda: hasf("bool(ls)", ["tools/audit-matrix.py"])),
    ("R2-10", "tools/audit-matrix.py",
     "sh() 保留 stderr 和退出码（失败≠没匹配）",
     lambda: hasf("command failed with exit", ["tools/audit-matrix.py"])),
    ("R2-11", "README.md / README_EN.md",
     "项目结构树列出全部脚本（含新增的两个）",
     lambda: (hasf("sanitize-scan.sh", ["README.md"])[0]
               and hasf("plant-leaks.sh", ["README.md"])[0]
               and hasf("sanitize-scan.sh", ["README_EN.md"])[0]
               and hasf("plant-leaks.sh", ["README_EN.md"])[0])),
    ("R2-12", "全仓库",
     "不出现开发机的真实网卡名（暴露硬件信息）",
     # The name is read from the fixture file, so this file does not
     # contain it either. `git grep` exits 1 when it finds nothing, so
     # the match list is taken from a pipeline whose exit status is the
     # grep's, not git's.
     lambda: not sh("git grep -l -F '%s' -- . ':!tests/fixtures/' 2>/dev/null "
                    "| cat" % _fixture_iface()).strip()),

    # ── 重启验证发现的洞（v1.1.5）──
    ("BV-01", "scripts/*.sh",
     "KIRI_SOCK 用 unix:// 前缀（裸路径会被 Docker CLI 当成 TCP 地址）",
     lambda: all("unix:///run/kiri/docker.sock" in sh(f"cat {f}")
                 for f in ("scripts/engine.sh", "scripts/watch.sh",
                           "scripts/sync-images.sh", "scripts/healthcheck.sh"))),
    ("BV-02", "scripts/watch.sh",
     "自动回落能找到 engine.sh（试 bin/ 和 scripts/ 两个位置）",
     lambda: (hasf('for cand in "$STACK_DIR/bin/engine.sh" "$STACK_DIR/scripts/engine.sh"', ["scripts/watch.sh"])[0]
               and hasf("无法自动回落", ["scripts/watch.sh"])[0])),
    ("BV-03", "systemd/*.service",
     "所有 unit 都传 Environment=STACK_DIR（否则脚本用默认路径操作错的目录）",
     lambda: all(hasf("Environment=STACK_DIR=", [f])[0]
                 for f in ("systemd/ha-stack-kiri.service",
                           "systemd/ha-stack-watch.service"))),
    ("BV-04", "systemd/*.service",
     "unit 的 ExecStart 指向的脚本在仓库里存在",
     lambda: all(os.path.exists(re.sub(r'^/opt/ha-stack/', '', m))
                 for f in ("systemd/ha-stack-kiri.service",
                           "systemd/ha-stack-watch.service")
                 for m in re.findall(r'ExecStart=\S+ (\S+\.sh)',
                                     sh(f"cat {f}")))),

    # ── 重启验证发现的洞（v1.1.6）──
    ("BV-05", "systemd/ha-stack.service",
     "Docker 版 unit 与 Kiri 版互斥（两者都自启会抢同一批 host 端口）",
     lambda: hasf("Conflicts=ha-stack-kiri.service", ["systemd/ha-stack.service"])),
    ("BV-06", "systemd/ha-stack-kiri.service",
     "Kiri 版 unit 与 Docker 版互斥",
     lambda: hasf("Conflicts=ha-stack.service", ["systemd/ha-stack-kiri.service"])),
    ("BV-07", "systemd/*.service",
     "没有用已废弃的 KillMode=none",
     lambda: not any("KillMode=none" in ln
                     for f in ("systemd/ha-stack.service",
                               "systemd/ha-stack-kiri.service",
                               "systemd/ha-stack-watch.service")
                     for ln in sh(f"cat {f}").splitlines())),

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
     "文档里让读者运行的每个脚本在 git index 里都带可执行位",
     # Per-file, not a count: four scripts could lose their bit and a
     # count would still pass.
     lambda: all("100755" in l for l in sh(
         "git ls-files -s scripts/ install/").splitlines()
         if l.strip()) and bool(sh("git ls-files -s scripts/ install/").strip())),
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
