#!/usr/bin/env bash
# ============================================================
# wg-install — 跨发行版 WireGuard 客户端一键安装脚本
# Project : https://github.com/NetApptool/wg-install
# License : MIT
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/NetApptool/wg-install/main/wg-install.sh -o /tmp/wg-install.sh
#   sudo bash /tmp/wg-install.sh
#
# Tested on:
#   Ubuntu 22.04+ / Debian 12 / Rocky 9 / RHEL 9 / AlmaLinux 9 /
#   Fedora 39+ / openEuler 22+ / Arch / Manjaro
#
# Known limits:
#   Kernel < 5.6 (CentOS 7, Ubuntu 18.04, Kylin V10 SP3 等老系统) 需要
#   dkms 编译 wireguard 模块,可能因缺 kernel-headers 失败,脚本会友好告知。
# ============================================================

VERSION="0.2.1"

set -euo pipefail

# ---------- CLI ----------
case "${1:-}" in
    -h|--help)
        cat <<EOF
wg-install v$VERSION  跨发行版 WireGuard 客户端一键安装脚本

Usage:
  curl -fsSL https://raw.githubusercontent.com/NetApptool/wg-install/main/wg-install.sh -o /tmp/wg-install.sh
  sudo bash /tmp/wg-install.sh

Features:
  - 自动识别发行版并装 wireguard-tools
  - 交互粘贴 conf, Ctrl+D 结束
  - SSH 自保护(0.0.0.0/0 全流量时防 SSH 断连)
  - 可选 Kill Switch
  - DNS 自管(不依赖 systemd-resolved/openresolv,跨发行版稳定)
  - 自动开机自启 + 启动后连通性自检

Project: https://github.com/NetApptool/wg-install
EOF
        exit 0
        ;;
    -v|--version)
        echo "wg-install v$VERSION"
        exit 0
        ;;
esac

# ---------- 颜色 ----------
if [ -t 1 ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

# ---------- 日志 ----------
LOG_FILE=/tmp/wg-install.log
: > "$LOG_FILE" 2>/dev/null || LOG_FILE=/dev/null
log()  { echo "[$(date +%H:%M:%S)] $*" >> "$LOG_FILE" 2>/dev/null || true; }
ok()   { echo -e "      ${GREEN}✓${RESET} $*"; log "OK: $*"; }
warn() { echo -e "      ${YELLOW}⚠${RESET}  $*"; log "WARN: $*"; }
err()  { echo -e "${RED}✗${RESET} $*" >&2; log "ERR: $*"; }
step() { echo -e "\n${BOLD}${CYAN}[$1/6]${RESET} $2"; log "STEP $1: $2"; }
die()  { err "$*"; exit 1; }

banner() {
    echo -e "${BOLD}${CYAN}"
    echo "═══════════════════════════════════════════════"
    echo "  wg-install v$VERSION  WireGuard 一键客户端安装"
    echo "═══════════════════════════════════════════════"
    echo -e "${RESET}"
}

# ---------- 交互输入(兼容 curl|bash) ----------
if [ -t 0 ]; then
    TTY_IN=/dev/stdin
elif [ -e /dev/tty ]; then
    TTY_IN=/dev/tty
else
    die "无可用终端。请先下载脚本再运行: curl -fsSL <url> -o /tmp/wg-install.sh && sudo bash /tmp/wg-install.sh"
fi

ask() {
    local prompt="$1" default="${2:-Y}" answer
    read -r -p "      $prompt" answer < "$TTY_IN" || answer=""
    answer="${answer:-$default}"
    case "$answer" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

ask_choice() {
    local prompt="$1" default="$2" answer
    read -r -p "      $prompt" answer < "$TTY_IN" || answer=""
    echo "${answer:-$default}"
}

# ============================================================
# 主流程
# ============================================================
banner

[ "$(id -u)" -eq 0 ] || die "需要 root 权限,请用 sudo 运行"

# ---------- [1/6] 检测系统 ----------
step 1 "检测系统..."

[ -f /etc/os-release ] || die "无法识别系统(缺少 /etc/os-release)"
. /etc/os-release
DISTRO=${ID:-unknown}
KERNEL=$(uname -r)
KMAJ=$(uname -r | cut -d. -f1)
KMIN=$(uname -r | cut -d. -f2)

PKG_MGR=""
case "$DISTRO" in
    ubuntu|debian|kali|raspbian|deepin|linuxmint|pop)
        PKG_MGR=apt ;;
    centos|rhel|rocky|almalinux|fedora|kylin|openEuler|anolis|uos|amzn)
        if command -v dnf >/dev/null 2>&1; then PKG_MGR=dnf; else PKG_MGR=yum; fi ;;
    arch|manjaro|endeavouros|cachyos)
        PKG_MGR=pacman ;;
    opensuse*|sles|sled)
        PKG_MGR=zypper ;;
    alpine)
        PKG_MGR=apk ;;
    *)
        die "暂不支持的发行版: $DISTRO  (欢迎 Issue: https://github.com/NetApptool/wg-install/issues)" ;;
esac

ok "${PRETTY_NAME:-$DISTRO}  内核 $KERNEL"
ok "包管理器: $PKG_MGR"

# ---------- [2/6] 安装依赖 ----------
step 2 "安装依赖..."

# 内核 ≥ 5.6 内置 wireguard 模块,老内核需要 dkms 或 kmod 包
NEED_DKMS=0
if [ "$KMAJ" -lt 5 ] || { [ "$KMAJ" -eq 5 ] && [ "$KMIN" -lt 6 ]; }; then
    NEED_DKMS=1
    warn "内核 $KERNEL < 5.6,将尝试装 wireguard 模块包(dkms/kmod)"
fi

# 注意: 故意不装 resolvconf/openresolv —— DNS 由本脚本接管,
# 兼容性比依赖系统 resolvconf 链(systemd-resolved/openresolv/netconfig)更好
case "$PKG_MGR" in
    apt)
        if [ "$NEED_DKMS" = 1 ]; then
            PKGS="linux-headers-$(uname -r) wireguard-dkms wireguard-tools curl iproute2 iptables"
        else
            PKGS="wireguard-tools curl iproute2 iptables"
        fi ;;
    dnf|yum)
        if [ "$NEED_DKMS" = 1 ]; then
            $PKG_MGR install -y -q epel-release >> "$LOG_FILE" 2>&1 || true
            PKGS="kmod-wireguard wireguard-tools curl iproute iptables"
        else
            PKGS="wireguard-tools curl iproute iptables"
        fi ;;
    pacman) PKGS="wireguard-tools curl iproute2 iptables" ;;
    zypper) PKGS="wireguard-tools curl iproute2 iptables" ;;
    apk)    PKGS="wireguard-tools curl iproute2 iptables" ;;
esac

# RHEL 系健壮安装:
#   1) 只装"当前缺失"的包 —— 不去碰已装的 curl/iproute/iptables,避免 dnf 把
#      它们往上游升级,从而触发 openssl 等核心库升级链(在 RHEL/CentOS-Stream
#      源版本错位的机器上会撞 openssl-fips-provider 的 fips.so 文件冲突)。
#   2) wireguard-tools 仍装不上时(其硬依赖 systemd-resolved 在错位源上不可
#      满足),回退到"单独下 rpm + rpm -Uvh --nodeps"最小安装 —— wg 运行只需
#      内核模块(≥5.6 内置)+ wg/wg-quick 两个用户态工具,systemd-resolved 非
#      必需(本脚本 DNS 已自管)。
rpm_install_robust() {
    local mgr="$1"; shift
    local want="$*" missing="" p
    for p in $want; do
        rpm -q "$p" >/dev/null 2>&1 || missing="$missing $p"
    done
    # wg 已在则不再碰 wireguard-tools
    command -v wg >/dev/null 2>&1 && missing=$(echo " $missing " | sed 's/ wireguard-tools / /g')
    missing=$(echo $missing | xargs)   # trim
    [ -z "$missing" ] && { log "依赖已满足,无需安装"; return 0; }

    # 先常规安装缺失包
    $mgr install -y -q $missing >> "$LOG_FILE" 2>&1 && return 0

    # 失败 → 最小化安装 wireguard-tools(绕开 openssl/systemd 升级链)
    log "常规 $mgr 安装失败,回退最小化安装 wireguard-tools"
    command -v wg >/dev/null 2>&1 && return 0
    local dldir; dldir=$(mktemp -d)
    $mgr install -y -q 'dnf-command(download)' >> "$LOG_FILE" 2>&1 || true
    if   $mgr download --destdir="$dldir"     wireguard-tools >> "$LOG_FILE" 2>&1 \
      || $mgr download --downloaddir="$dldir" wireguard-tools >> "$LOG_FILE" 2>&1 \
      || ( cd "$dldir" && yumdownloader wireguard-tools >> "$LOG_FILE" 2>&1 ); then
        if ls "$dldir"/wireguard-tools-*.rpm >/dev/null 2>&1 \
           && rpm -Uvh --nodeps "$dldir"/wireguard-tools-*.rpm >> "$LOG_FILE" 2>&1; then
            rm -rf "$dldir"; log "最小化安装 wireguard-tools 成功"; return 0
        fi
    fi
    rm -rf "$dldir"; return 1
}

install_pkgs() {
    case "$PKG_MGR" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get update -qq >> "$LOG_FILE" 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $PKGS >> "$LOG_FILE" 2>&1 ;;
        dnf)    rpm_install_robust dnf $PKGS ;;
        yum)    rpm_install_robust yum $PKGS ;;
        pacman) pacman -Sy --noconfirm --needed $PKGS >> "$LOG_FILE" 2>&1 ;;
        zypper) zypper -n install $PKGS >> "$LOG_FILE" 2>&1 ;;
        apk)    apk add --no-progress $PKGS >> "$LOG_FILE" 2>&1 ;;
    esac
}

echo -n "      正在安装 $PKGS ..."
T0=$(date +%s)
if install_pkgs; then
    echo -e " ${GREEN}✓${RESET} 完成(耗时 $(( $(date +%s) - T0 )) 秒)"
else
    echo
    err "依赖安装失败,日志末尾:"
    tail -n 10 "$LOG_FILE" >&2
    cat <<EOF >&2

  可能原因:
    1) 软件源不通       → 试 ping mirrors.<distro>.org
    2) 老内核没 wg 模块 → 内核 $KERNEL 可能需要换更新发行版
    3) 这台机器不联网    → 离线场景请手动装 wireguard-tools

  完整日志: $LOG_FILE
EOF
    die "请检查软件源"
fi

command -v wg >/dev/null      || die "wg 命令未安装成功"
command -v wg-quick >/dev/null || die "wg-quick 命令未安装成功"

if ! lsmod 2>/dev/null | grep -q '^wireguard'; then
    if modprobe wireguard 2>>"$LOG_FILE"; then
        ok "已加载 wireguard 内核模块"
    else
        err "无法加载 wireguard 内核模块"
        cat <<EOF >&2

  原因可能是:
    - 内核 $KERNEL 不带 wireguard 且 dkms 编译失败(缺 kernel-headers)
    - 这是内核精简版(如某些 minimal cloud image)

  尝试:
    $PKG_MGR install kernel-devel-$KERNEL  # 或 linux-headers-$KERNEL
    然后重跑本脚本
EOF
        die "缺 wireguard 内核模块"
    fi
fi

# ---------- [3/6] 粘贴配置 ----------
step 3 "请粘贴你的 WireGuard 配置"
echo -e "      粘贴完成后按 ${BOLD}Ctrl+D${RESET} 结束:"
echo "      ────────────────────────────────────────"

WG_TMP=$(mktemp /tmp/wg0.conf.XXXXXX)
trap 'rm -f "$WG_TMP"' EXIT

cat > "$WG_TMP" < "$TTY_IN"

echo "      ────────────────────────────────────────"

grep -q '^\[Interface\]' "$WG_TMP" || die "配置无效:缺少 [Interface] 段"
grep -q '^\[Peer\]'      "$WG_TMP" || die "配置无效:缺少 [Peer] 段"

ENDPOINT=$(grep -oP '^\s*Endpoint\s*=\s*\K\S+'    "$WG_TMP" | head -n1)
ALLOWED=$( grep -oP '^\s*AllowedIPs\s*=\s*\K.+'   "$WG_TMP" | head -n1)
DNS_LINE=$(grep -oP '^\s*DNS\s*=\s*\K.+'          "$WG_TMP" | head -n1 || true)
ADDRESS=$( grep -oP '^\s*Address\s*=\s*\K\S+'     "$WG_TMP" | head -n1)

[ -n "$ENDPOINT" ] || die "配置无效:未找到 Endpoint"
[ -n "$ADDRESS"  ] || die "配置无效:未找到 Address"

# 把 DNS = 行注释掉 —— DNS 改用 PostUp/PostDown 自管,
# 避免 wg-quick 调系统 resolvconf 在不同发行版踩坑
if [ -n "$DNS_LINE" ]; then
    sed -i 's/^\(\s*DNS\s*=\)/# \1  # handled by wg-install PostUp/' "$WG_TMP"
fi

ok "配置已识别  对端: $ENDPOINT"
if [[ "$ALLOWED" == *"0.0.0.0/0"* ]]; then
    ok "全流量模式 (0.0.0.0/0)"
    FULL_TUNNEL=1
else
    ok "分流模式: $ALLOWED"
    FULL_TUNNEL=0
fi

# ---------- [4/6] 几个小问题 ----------
step 4 "几个小问题:"

# 4.1 旧配置处理
if [ -f /etc/wireguard/wg0.conf ]; then
    echo
    warn "发现 /etc/wireguard/wg0.conf 已存在"
    echo "      [1] 备份后覆盖(推荐)"
    echo "      [2] 取消安装"
    CHOICE=$(ask_choice "请选择 [1/2]: " "1")
    case "$CHOICE" in
        2) die "用户取消" ;;
        *) BACKUP=/etc/wireguard/wg0.conf.bak.$(date +%Y%m%d-%H%M%S)
           cp -a /etc/wireguard/wg0.conf "$BACKUP"
           systemctl stop wg-quick@wg0 2>/dev/null || true
           wg-quick down wg0           2>/dev/null || true
           ok "已备份到 $(basename "$BACKUP")"
           ;;
    esac
fi

# 4.2 SSH 自保护
SSH_PROTECT=0; SSH_IP=""
if [ -n "${SSH_CLIENT:-${SSH_CONNECTION:-}}" ]; then
    SSH_IP=$(echo "${SSH_CLIENT:-${SSH_CONNECTION:-}}" | awk '{print $1}')
fi
if [ -n "$SSH_IP" ] && [ "$FULL_TUNNEL" = "1" ]; then
    echo
    warn "检测到你正在通过 SSH 连接(来自 $SSH_IP)"
    echo "      启动 VPN 后这条 SSH 会断开,要保护吗?"
    if ask "保护当前 SSH 连接? [Y/n]: " "Y"; then
        SSH_PROTECT=1
        ok "已加保护规则,启动后 SSH 不会断"
    else
        warn "跳过(注意启动后 SSH 可能断)"
    fi
fi

# 4.3 Kill Switch
KILL_SWITCH=0
echo
if ask "是否启用 Kill Switch?(VPN 断了就断网,防 IP 泄漏)[y/N]: " "N"; then
    KILL_SWITCH=1
    ok "已启用 Kill Switch"
else
    ok "跳过"
fi

# 4.4 连通性自检
echo
TEST_CONN=1
if ask "启动后自动测试连通性? [Y/n]: " "Y"; then ok "好的"; else TEST_CONN=0; fi

# 4.5 立即启动
echo
START_NOW=1
if ask "立即启动并设置开机自启? [Y/n]: " "Y"; then :; else START_NOW=0; fi

# ---------- 准备 /etc/wireguard 目录与 helper 脚本 ----------
mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

# DNS helper:wg0 起来时把 /etc/resolv.conf 备份并替换为 conf 里指定的 DNS
if [ -n "$DNS_LINE" ]; then
    {
        echo '#!/bin/sh'
        echo '# auto-generated by wg-install — wg0 PostUp DNS handler'
        echo '[ -f /etc/resolv.conf ] && cp -a /etc/resolv.conf /etc/resolv.conf.wg-install.bak 2>/dev/null'
        echo '{'
        for d in $(echo "$DNS_LINE" | tr ',' ' '); do
            echo "    echo 'nameserver $d'"
        done
        echo '} > /etc/resolv.conf'
    } > /etc/wireguard/wg0-dns-up.sh
    chmod 755 /etc/wireguard/wg0-dns-up.sh

    cat > /etc/wireguard/wg0-dns-down.sh <<'DNS_DOWN_EOF'
#!/bin/sh
# auto-generated by wg-install — wg0 PostDown DNS handler
[ -f /etc/resolv.conf.wg-install.bak ] && mv /etc/resolv.conf.wg-install.bak /etc/resolv.conf
DNS_DOWN_EOF
    chmod 755 /etc/wireguard/wg0-dns-down.sh
fi

# ---------- 注入 PostUp/PostDown/PreDown 到 conf ----------
INJECT=""

# DNS 自管(代替 wg-quick 调 resolvconf)
if [ -n "$DNS_LINE" ]; then
    INJECT+="PostUp = /etc/wireguard/wg0-dns-up.sh"$'\n'
    INJECT+="PostDown = /etc/wireguard/wg0-dns-down.sh"$'\n'
fi

# SSH 自保护
if [ "$SSH_PROTECT" = "1" ] && [ -n "$SSH_IP" ]; then
    DEFAULT_GW=$(ip route show default | awk '/default/ {print $3; exit}')
    DEFAULT_IF=$(ip route show default | awk '/default/ {print $5; exit}')
    if [ -n "$DEFAULT_GW" ] && [ -n "$DEFAULT_IF" ]; then
        INJECT+="PostUp = ip route add ${SSH_IP}/32 via ${DEFAULT_GW} dev ${DEFAULT_IF}"$'\n'
        INJECT+="PostDown = ip route del ${SSH_IP}/32"$'\n'
    else
        warn "未找到默认网关,SSH 保护规则跳过"
    fi
fi

# Kill Switch
if [ "$KILL_SWITCH" = "1" ]; then
    INJECT+="PostUp = iptables -I OUTPUT ! -o %i -m mark ! --mark \$(wg show %i fwmark) -m addrtype ! --dst-type LOCAL -j REJECT"$'\n'
    INJECT+="PreDown = iptables -D OUTPUT ! -o %i -m mark ! --mark \$(wg show %i fwmark) -m addrtype ! --dst-type LOCAL -j REJECT"$'\n'
fi

if [ -n "$INJECT" ]; then
    TMP2=$(mktemp)
    awk -v inject="$INJECT" '
        BEGIN { done = 0 }
        /^\[Peer\]/ && !done { printf "%s", inject; done = 1 }
        { print }
    ' "$WG_TMP" > "$TMP2"
    mv "$TMP2" "$WG_TMP"
fi

# ---------- 落地正式配置 ----------
install -m 600 "$WG_TMP" /etc/wireguard/wg0.conf
chown root:root /etc/wireguard/wg0.conf

# ---------- [5/6] 启动 ----------
if [ "$START_NOW" = "1" ]; then
    step 5 "启动隧道..."
    if wg-quick up wg0 >> "$LOG_FILE" 2>&1; then
        ok "wg-quick up wg0"
    else
        err "启动失败,日志末尾:"
        tail -n 20 "$LOG_FILE" >&2
        die "启动失败,详见 $LOG_FILE"
    fi
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        if systemctl enable wg-quick@wg0 >> "$LOG_FILE" 2>&1; then
            ok "systemctl enable wg-quick@wg0  (开机自启已开)"
        else
            warn "开机自启设置失败"
        fi
    else
        warn "未检测到 systemd,请自行设置开机自启"
    fi
else
    step 5 "跳过启动"
    ok "你可以稍后手动启动: sudo wg-quick up wg0"
fi

# ---------- [6/6] 连通性测试 ----------
EXIT_IP=""
HANDSHAKE_OK=0
if [ "$TEST_CONN" = "1" ] && [ "$START_NOW" = "1" ]; then
    step 6 "连通性测试..."

    # 等几秒让握手发生
    sleep 3

    # 检查握手
    if wg show wg0 latest-handshakes 2>/dev/null | awk '$2 > 0 {found=1} END {exit !found}'; then
        ok "握手成功 (peer 已确认)"
        HANDSHAKE_OK=1
    else
        warn "尚未握手 — 可能 server 端没注册本机 peer 公钥,或网络不通到 Endpoint"
    fi

    if [ -n "$DNS_LINE" ]; then
        DNS_FIRST=$(echo "$DNS_LINE" | tr ',' ' ' | awk '{print $1}')
        if PING_OUT=$(ping -c 3 -W 2 "$DNS_FIRST" 2>/dev/null); then
            RTT=$(echo "$PING_OUT" | tail -1 | awk -F/ '{printf "%.0f", $5}')
            ok "ping $DNS_FIRST  ${RTT}ms"
        else
            warn "ping $DNS_FIRST 失败"
        fi
    fi

    EXIT_IP=$(curl -fsS --max-time 10 https://api.ipify.org    2>/dev/null \
           || curl -fsS --max-time 10 https://ipinfo.io/ip     2>/dev/null \
           || curl -fsS --max-time 10 https://ifconfig.me      2>/dev/null \
           || echo "查询失败")
    ok "出口 IP  $EXIT_IP"

    if getent hosts example.com >/dev/null 2>&1; then
        ok "DNS 解析 (example.com)  正常"
    else
        warn "DNS 解析失败"
    fi
else
    step 6 "跳过连通性测试"
fi

# ---------- 总结 ----------
echo
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════"
echo -e "  ✅ 全部完成!"
echo -e "═══════════════════════════════════════════════${RESET}"
echo
if [ "$START_NOW" = "1" ]; then
    [ -n "$EXIT_IP" ] && echo "  当前出口 IP : $EXIT_IP"
    echo "  隧道接口    : wg0  →  $ADDRESS"
    echo "  开机自启    : 已启用"
    [ "$HANDSHAKE_OK" = 0 ] && echo "  ${YELLOW}⚠  尚未握手 — 检查 server 端是否注册了本机 peer 公钥${RESET}"
else
    echo "  状态        : 已安装(未启动)"
fi
echo "  配置文件    : /etc/wireguard/wg0.conf  (权限 600)"
echo
echo "  常用命令:"
echo "    查看状态  : sudo wg show"
echo "    临时关闭  : sudo wg-quick down wg0"
echo "    临时启动  : sudo wg-quick up wg0"
echo "    重启隧道  : sudo systemctl restart wg-quick@wg0"
echo "    永久禁用  : sudo systemctl disable --now wg-quick@wg0"
echo "    改配置    : sudo vi /etc/wireguard/wg0.conf  改完重启"
echo
echo "  日志: $LOG_FILE"
echo "  反馈: https://github.com/NetApptool/wg-install/issues"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════${RESET}"
echo
