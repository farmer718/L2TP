#!/bin/bash
#
# L2TP (xl2tpd) 落地机部署 —— 幂等，可重复执行
#
#   sudo ./l2tp_deploy.sh             首次交互问 VPN_ID；之后读 /etc/l2tp-deploy.conf，全自动
#   sudo ./l2tp_deploy.sh 12          指定/更换 VPN_ID（旧网段的 NAT 规则会保留，不删）
#   sudo DRY_RUN=1 ./l2tp_deploy.sh   只看计划，不动手
#
set -euo pipefail

# ---------------------------------------------------------------- 常量

L2TP_PORT=17001
CONF=/etc/l2tp-deploy.conf
XL_CONF=/etc/xl2tpd/xl2tpd.conf
PPP_CONF=/etc/ppp/options.xl2tpd
UNIT=/etc/systemd/system/xl2tpd.service
NR_CONF=/etc/needrestart/conf.d/zz-xl2tpd-no-restart.conf
SYSCTL_CONF=/etc/sysctl.d/zz-l2tp.conf
BACKUP_DIR=/var/backups/l2tp-deploy
TAG=l2tp-deploy
DRY_RUN=${DRY_RUN:-0}
FAIL=0

# MTU/MRU：实测默认行为是 min(1500, 客户端 LCP 协商的 MRU)，线上跑的是 1420
# （客户端自己要的）。显式钉 1420 对现状是零改动，同时能挡住不自限的客户端
# —— L2TP 封装后不限 MTU 早晚撞 PMTU 黑洞（能拨上、小包通、大包卡死）。
MTU=1420

# ---------------------------------------------------------------- 输出

ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✘\033[0m %s\n' "$*"; FAIL=1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die()  { printf '\n\033[31m✘ %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 小工具

# conf_get KEY —— 读 /etc/...conf 里的值，没有就空
conf_get() { [[ -r $CONF ]] && sed -n "s/^$1=//p" "$CONF" | tail -n1 || true; }

# conf_set KEY VALUE
conf_set() {
    [[ -f $CONF ]] || { : > "$CONF"; chmod 600 "$CONF"; }
    if grep -q "^$1=" "$CONF"; then
        sed -i "s|^$1=.*|$1=$2|" "$CONF"
    else
        printf '%s=%s\n' "$1" "$2" >> "$CONF"
    fi
}

# 只增不删：同一组规则已存在就跳过，不存在才追加。
# 这样重复执行是幂等的，而不同参数会往上叠加，永远不会覆盖/删掉已有规则。
add_rule() {   # add_rule <table> <chain> <规则...>
    local t=$1 c=$2; shift 2
    if iptables -t "$t" -C "$c" "$@" 2>/dev/null; then
        ok "已存在，跳过：$c $*"
    else
        iptables -t "$t" -A "$c" "$@"
        ok "已添加：$c $*"
    fi
}

# 改写前留一份原件。只在没有备份时写，所以 .bak 永远是"第一次跑本脚本之前"
# 的样子 —— 拿老脚本部署过的机器上，那就是可回滚的原点。
backup_once() {
    [[ -e $1 ]] || return 0
    mkdir -p "$BACKUP_DIR"
    local b="$BACKUP_DIR/$(basename "$1").bak"
    if [[ -e $b ]]; then
        printf '    · 已有备份，不覆盖：%s\n' "$b"
    else
        cp -a "$1" "$b" && ok "已备份 $1 → $b"
    fi
}

# ---------------------------------------------------------------- 前置检查

[[ $EUID -eq 0 ]] || die "请用 root 执行：sudo $0"

# ---------------------------------------------------------------- 收集参数

# VPN_ID 取值优先级：命令行参数 > /etc/l2tp-deploy.conf > 现存配置里认出来的 > 问人。
# 老脚本部署过的机器上没有 $CONF，靠第三档自动识别，做到真正的"一键执行"。
VPN_ID="${1:-}"
SRC=""
if [[ -n $VPN_ID ]]; then
    SRC="命令行参数"
else
    VPN_ID="$(conf_get VPN_ID)"
    [[ -n $VPN_ID ]] && SRC="$CONF"
fi

if [[ -z $VPN_ID && -r $XL_CONF ]]; then
    _n="$(sed -n \
        's/^[[:space:]]*local ip[[:space:]]*=[[:space:]]*10\.10\.\([0-9]\+\)\..*/\1/p' \
        "$XL_CONF" | head -n1)"
    if [[ $_n =~ ^[0-9]+$ ]]; then
        VPN_ID="$_n"
        SRC="现存 xl2tpd.conf（自动识别）"
    fi
fi

if [[ -z $VPN_ID ]]; then
    [[ -t 0 ]] || die "非交互运行且没有 $CONF —— 请传参：$0 <VPN_ID>"
    read -rp "请输入 VPN_ID (1-200): " VPN_ID
    SRC="手动输入"
fi

[[ $VPN_ID =~ ^[0-9]+$ ]] || die "VPN_ID 必须是数字，收到：$VPN_ID"
VPN_ID=$((10#$VPN_ID))                       # 去掉前导零，避免被当八进制
(( VPN_ID >= 1 && VPN_ID <= 200 )) || die "VPN_ID 必须在 1-200 之间，收到：$VPN_ID"

VPN_NET="10.10.${VPN_ID}"
LOCAL_IP="${VPN_NET}.1"
IP_RANGE="${VPN_NET}.10-${VPN_NET}.50"
VPN_CIDR="${VPN_NET}.0/24"

# 现存配置里的网段，只用来在抬头提示一句，不拦截 —— 传什么用什么。
EXIST_NET=""
if [[ -r $XL_CONF ]]; then
    EXIST_NET="$(sed -n \
        's/^[[:space:]]*local ip[[:space:]]*=[[:space:]]*\([0-9]\+\.[0-9]\+\.[0-9]\+\)\..*/\1/p' \
        "$XL_CONF" | head -n1)"
fi

echo
echo "=========================================="
echo " VPN 网段   : ${VPN_CIDR}"
echo " VPN_ID来源 : ${SRC}"
echo " 服务端 IP  : ${LOCAL_IP}"
echo " 客户端池   : ${IP_RANGE}"
echo " L2TP 端口  : ${L2TP_PORT}  (UDP)"
echo " MTU / MRU  : ${MTU}"
if [[ -n $EXIST_NET && $EXIST_NET != "$VPN_NET" ]]; then
    echo " ⚠ 现存网段 : ${EXIST_NET}.0/24  →  本次改成 ${VPN_CIDR}"
fi
echo "=========================================="

if [[ $DRY_RUN == 1 ]]; then
    echo
    echo "DRY_RUN=1 —— 只显示计划，未做任何改动。"
    exit 0
fi

conf_set VPN_ID "$VPN_ID"

# 变更前先指纹，用来判断"重跑但配置没变"→ 就不用断隧道
stamp() {
    cat "$XL_CONF" "$PPP_CONF" "$UNIT" 2>/dev/null \
        | sha256sum | cut -d' ' -f1
}
OLD_STAMP="$(stamp)"

# ---------------------------------------------------------------- 1. 装依赖

step "安装依赖"

export DEBIAN_FRONTEND=noninteractive

# needrestart 装完包会弹一个多选框问「重启哪些服务」（模板 needrestart/ui-query_pkgs，
# 默认档位 restart='i'），而且它【预先勾好】自己想重启的那些。
# 老机器上此刻 xl2tpd 还在用发行版 sysv unit —— 那个 stop 分支没有 --retry，
# 一被重启就是本脚本要修的那个竞态，而 native unit 还没装上。
# 它不是普通的 debconf 提问：非交互模式下 debconf 会拿 needrestart 预置的答案直接返回，
# 等于"不问、静默重启"，所以 DEBIAN_FRONTEND 挡不住，必须显式静音。
# apt-pinvoke 在调用 needrestart 之前就检查这个变量，是硬开关。
export NEEDRESTART_SUSPEND=1

# 新机器上 unattended-upgrades 常常正占着 dpkg 锁，硬等一会儿
if command -v fuser >/dev/null 2>&1; then
    for i in $(seq 1 60); do
        fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
              /var/cache/apt/archives/lock >/dev/null 2>&1 || break
        [[ $i == 1 ]] && warn "dpkg 被占用（unattended-upgrades?），等它放锁…"
        sleep 5
    done
fi

apt-get update -qq || die "apt-get update 失败（网络或软件源问题？）"
apt-get install -y -qq \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    xl2tpd iptables-persistent || die "apt-get install xl2tpd/iptables-persistent 失败"

[[ -x /usr/sbin/xl2tpd ]] || die "装完了却找不到 /usr/sbin/xl2tpd"
ok "xl2tpd + iptables-persistent 就位"

# ---------------------------------------------------------------- 2. 内核参数

step "内核参数"

# 写到 /etc/sysctl.d/zz-*。`sysctl --system` 会把 sysctl.d/*（含各发行版自带文件）
# 和 /etc/sysctl.conf 汇成一个按文件名排序的列表依次应用，同名键后应用者胜；
# zz- 排在 99- 之后，能压过镜像自带的 99-*。整文件覆盖写，重复执行不堆积。
# 注意 /etc/sysctl.conf 在列表最末再应用一次 —— 所以下面按【实际值】断言，
# 而不是假定这个文件一定生效。
cat > "$SYSCTL_CONF" <<'EOF'
# 由 l2tp_deploy.sh 管理，请勿手工编辑
net.ipv4.ip_forward = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

# 镜像里别的 sysctl 文件可能有错，会让 --system 返回非零；不因此中断，
# 真正算数的是下面两个按实际值做的断言。
sysctl --system >/dev/null 2>&1 \
    || warn "sysctl --system 报了错（多半来自镜像里其他 sysctl 文件），按下面的实际值判定"
ok "已写入 $SYSCTL_CONF 并加载（sysctl --system，会读到 sysctl.d）"

if [[ "$(sysctl -n net.ipv4.ip_forward)" == 1 ]]; then
    ok "ip_forward = 1"
else
    bad "ip_forward 没生效"
    # 谁把它压回去了：/etc/sysctl.conf 排在最末应用，最可能是它
    printf '      ↳ 是这些文件在抢：\n'
    grep -rl '^[[:space:]]*net\.ipv4\.ip_forward' /etc/sysctl.conf /etc/sysctl.d 2>/dev/null \
        | sed 's/^/        /' || true
    printf '      ↳ 把里面的 ip_forward 改成 1（或删掉那一行）再重跑本脚本\n'
fi

if [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == bbr ]]; then
    ok "BBR 生效"
else
    warn "BBR 没生效（内核 <4.9 或模块缺失？不影响 L2TP，但没加速）"
fi

# ---------------------------------------------------------------- 3. L2TP 配置

step "写 xl2tpd / ppp 配置"

mkdir -p /etc/xl2tpd

backup_once "$XL_CONF"
backup_once "$PPP_CONF"

cat > "$XL_CONF" <<EOF
[global]
port = ${L2TP_PORT}

[lns default]
ip range = ${IP_RANGE}
local ip = ${LOCAL_IP}
require authentication = yes
name = l2tpd
pppoptfile = /etc/ppp/options.xl2tpd
EOF

# mtu/mru 一定要给：L2TP 封装后不限制的话容易 PMTU 黑洞
# （能拨上、小包通、大包卡死，典型的"连上了但打不开网页"）
cat > "$PPP_CONF" <<EOF
require-chap
noccp
auth
nodefaultroute

mtu ${MTU}
mru ${MTU}

lcp-echo-interval 30
lcp-echo-failure 4
EOF

chmod 600 "$PPP_CONF"
ok "xl2tpd.conf（port=${L2TP_PORT}）+ options.xl2tpd（mtu/mru ${MTU}）"

# chap-secrets 只在不存在时写：重跑不会覆盖你手工加过的账号
if [[ ! -s /etc/ppp/chap-secrets ]]; then
    cat > /etc/ppp/chap-secrets <<'EOF'
farmer   l2tpd   "chp1qaz!QAZ"   *
EOF
    ok "已写入默认 chap-secrets"
else
    warn "chap-secrets 已存在，保留不动（想重置请先删掉 /etc/ppp/chap-secrets）"
fi
chmod 600 /etc/ppp/chap-secrets

# ---------------------------------------------------------------- 4. native unit（根因修复）

step "部署 native systemd unit（替换发行版 sysv unit）"

# 为什么必须换：/etc/init.d/xl2tpd 的 stop 分支没有 --retry，发完 SIGTERM 立刻返回；
# systemd 随即执行 start，此时旧进程还活着、pidfile 还在，
# start-stop-daemon 判定 "already running" 拒绝启动并返回 1，
# 而脚本第 32 行有 set -e —— 整个 unit 变成 failed。
# sysv-generator 生成的是 Restart=no + KillMode=process，于是不重试、永久躺平。
# 用 Type=simple + -D 彻底绕开 pidfile，再无这个竞态。
cat > "$UNIT" <<'EOF'
[Unit]
Description=xl2tpd L2TP daemon (LNS)
Documentation=man:xl2tpd(8)
After=network-online.target
Wants=network-online.target
# 永远不要因为"重启太频繁"而被 systemd 放弃
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/usr/sbin/xl2tpd -D -l -c /etc/xl2tpd/xl2tpd.conf
Restart=always
RestartSec=3
KillMode=control-group
KillSignal=SIGTERM
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xl2tpd >/dev/null 2>&1 || true

FRAG="$(systemctl show xl2tpd -p FragmentPath | cut -d= -f2-)"
if [[ $FRAG == "$UNIT" ]]; then
    ok "unit 已生效：$FRAG"
else
    die "unit 没生效，systemd 实际用的是：${FRAG:-（空）}"
fi

# ---------------------------------------------------------------- 5. 禁止 needrestart 碰它

step "禁止 needrestart 重启 xl2tpd"

if [[ -d /etc/needrestart/conf.d ]]; then
    # zz- 前缀保证排在最后，不会被别的 drop-in 覆盖掉 blacklist_rc
    cat > "$NR_CONF" <<'EOF'
# xl2tpd 是 L2TP 落地服务，重启会掐断所有在线隧道。
# 它由 systemd (Restart=always) 负责兜底，needrestart 不要碰。
$nrconf{blacklist_rc} = [
    qr(^xl2tpd),
];
EOF
    ok "已写入 $NR_CONF"
else
    warn "没有 /etc/needrestart/conf.d —— needrestart 未安装，本来就不会来重启它"
fi

# ---------------------------------------------------------------- 6. NAT

step "配置 NAT 转发"

# 只增不删，也绝不清空整条 POSTROUTING（那会连 docker、其他转发规则一起干掉）
add_rule nat POSTROUTING -s "$VPN_CIDR" \
    -m comment --comment "$TAG" -j MASQUERADE

# 老脚本铺的 MASQUERADE 没有 comment，认不出来 → 会多出一条重复的。
# 功能上无害（包只走第一条），但既然是别人铺的规则就不动它，只报出来。
MASQ_N="$(iptables -t nat -S POSTROUTING 2>/dev/null \
          | grep -F -- "-s ${VPN_CIDR} " | grep -cF -- "-j MASQUERADE" || true)"
if (( MASQ_N > 1 )); then
    warn "POSTROUTING 里有 ${MASQ_N} 条 ${VPN_CIDR} 的 MASQUERADE —— 老脚本铺的那条没带标记，认不出"
    warn "无害，脚本不会主动删。想去掉重复的手工来："
    printf '        iptables -t nat -L POSTROUTING -n --line-number   # 不带 /* %s */ 的那条就是要删的\n' "$TAG"
    printf '        iptables -t nat -D POSTROUTING <行号> && netfilter-persistent save\n'
fi

netfilter-persistent save >/dev/null
ok "iptables 规则已持久化（重启不丢）"

# ---------------------------------------------------------------- 7. 启动

step "启动 xl2tpd"

NEW_STAMP="$(stamp)"
if [[ $OLD_STAMP == "$NEW_STAMP" ]] && systemctl is-active --quiet xl2tpd; then
    ok "配置无变化且服务在跑 —— 跳过重启，隧道不断"
else
    systemctl restart xl2tpd
    ok "已重启 xl2tpd"
fi

# ---------------------------------------------------------------- 8. 自检

step "自检"

sleep 1

if systemctl is-active --quiet xl2tpd; then
    ok "服务 active"
else
    bad "服务没起来 —— journalctl -u xl2tpd -n 50 --no-pager 看原因"
fi

if ss -lun 2>/dev/null | grep -qE "[:.]${L2TP_PORT}[[:space:]]"; then
    ok "UDP ${L2TP_PORT} 在监听"
else
    bad "UDP ${L2TP_PORT} 没在监听"
    # 常见原因之一：内核没有 l2tp_ppp（OpenVZ / 受限容器加载不了内核模块）
    if ! lsmod 2>/dev/null | grep -q '^l2tp_ppp'; then
        printf '      ↳ 内核里没看到 l2tp_ppp 模块。KVM/裸机的官方内核都有，\n'
        printf '        OpenVZ 或受限容器加载不了它，L2TP 落地起不来。\n'
        printf '        手工确认：modprobe l2tp_ppp && lsmod | grep l2tp\n'
    fi
    printf '      ↳ 也可以直接看：journalctl -u xl2tpd -n 50 --no-pager\n'
fi

if iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -q "$VPN_CIDR"; then
    ok "NAT 规则在位"
else
    bad "NAT 规则不在位"
fi

if grep -q '^Restart=always' "$UNIT"; then
    ok "unit 带 Restart=always（挂了会自己回来）"
else
    bad "unit 缺 Restart=always"
fi

# ---------------------------------------------------------------- 结果

step "最近日志"
journalctl -u xl2tpd -n 20 --no-pager 2>/dev/null || true

echo
if [[ $FAIL -eq 0 ]]; then
    printf '\033[32m部署完成\033[0m\n'
    echo "  网段     : ${VPN_CIDR}"
    echo "  服务端   : ${LOCAL_IP}"
    echo "  客户端池 : ${IP_RANGE}"
    echo "  端口     : UDP ${L2TP_PORT}"
    echo
    echo "重跑本脚本 = 全自动、幂等、不断隧道（配置没变时）。"
else
    printf '\033[31m部署有问题，见上面 ✘ 的项\033[0m\n' >&2
    exit 1
fi
