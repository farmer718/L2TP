#!/bin/bash
#
# L2TP (xl2tpd) 落地机部署 —— 幂等，可重复执行
#
#   sudo ./l2tp_deploy.sh             交互运行时问一次 VPN_ID（回车=沿用当前的，输数字=换网段）
#   sudo ./l2tp_deploy.sh 12          直接指定 VPN_ID，不再问（旧网段的 NAT 规则会保留，不删）
#   sudo DRY_RUN=1 ./l2tp_deploy.sh   只看计划，不动手
#
set -Eeuo pipefail

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

# 兜底：任何"意外的"失败都要报出行号再退。
# 没有它的时候，set -e 下随便一条裸命令返回非 0 就是【静默退出】——
# 现场只留一半输出、没有任何错误信息，只能靠猜（就因为这个吃过一次）。
# 上面的 -E（errtrace）是必须的：不带它 trap 不进函数体，conf_set/backup_once
# 这类函数内部的失败照样静默退，一行提示都没有。
# 副作用是顶层赋值调函数时可能重复报 2-3 行，但第一条就指向真凶行。
# die 路径不受影响：它在 || 列表里，ERR trap 对那种位置有豁免。
trap 'st=$?; printf "\n\033[31m✘ 第 %s 行失败（退出码 %s）—— 上面最后一条输出就是现场\033[0m\n" "$LINENO" "$st" >&2' ERR

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

# VPN_ID 的【默认值】来源，优先级：
#   命令行参数 > /etc/l2tp-deploy.conf > 现存 xl2tpd.conf 自动识别
# 前三档只负责把默认值填好 —— 交互运行时下面一定会停下来问你，
# 最终用哪个由你按键决定（换网段会影响线上客户端，不能让脚本替你猜）。
VPN_ID="${1:-}"
ARG_ID="$VPN_ID"
SRC=""
if [[ -n $VPN_ID ]]; then
    SRC="命令行参数"
else
    VPN_ID="$(conf_get VPN_ID)"
    [[ -n $VPN_ID ]] && SRC="$CONF"
fi

if [[ -z $VPN_ID && -r $XL_CONF ]]; then
    # 末尾的 || true 不是多余的：sed | head 在 pipefail 下有 SIGPIPE 竞态
    # （head 拿到第一行就退出，sed 再写就收 141），而这里是裸赋值 → 会静默退出。
    _n="$(sed -n \
        's/^[[:space:]]*local ip[[:space:]]*=[[:space:]]*10\.10\.\([0-9]\+\)\..*/\1/p' \
        "$XL_CONF" | head -n1 || true)"
    if [[ $_n =~ ^[0-9]+$ ]]; then
        VPN_ID="$_n"
        SRC="现存 xl2tpd.conf（自动识别）"
    fi
fi

# 交互运行时【总是】停下来问一次：上面认出来的值当默认值，回车沿用、输数字换网段。
# 换网段会换掉线上客户端的 IP，这种事必须由人拍板，不能让脚本自己猜。
#
# 三种情况【不问】：
#   ① 命令行给了参数（$0 12）—— 你已经在命令行上决定了，再问一遍是废话；
#   ② stdin 不是终端（curl | bash、cron、CI）—— 问了也没人答，会卡死；
#   ③ 上面三档一个都没认出来且非交互 —— 下面直接 die，不猜。
if [[ -z $ARG_ID && -t 0 ]]; then
    echo
    if [[ -n $VPN_ID ]]; then
        printf ' 当前 VPN_ID : %s   →   网段 10.10.%s.0/24\n' "$VPN_ID" "$VPN_ID"
        printf ' 来源        : %s\n' "$SRC"
        printf ' 直接回车保持不变，输入数字则换网段\n'
    fi
    while :; do
        read -rp " VPN_ID (1-200): " _ans || die "读不到输入（终端被关了？）"
        if [[ -z $_ans ]]; then
            [[ -n $VPN_ID ]] && break          # 回车 = 沿用默认值
            echo " 这台机器上没认出 VPN_ID，必须输一个"
            continue
        fi
        [[ $_ans =~ ^[0-9]+$ ]] || { echo " 必须是数字，重新输入"; continue; }
        _ans=$((10#$_ans))
        (( _ans >= 1 && _ans <= 200 )) || { echo " 必须在 1-200 之间，重新输入"; continue; }
        [[ $_ans == "$VPN_ID" ]] || SRC="手动输入${VPN_ID:+（原 $VPN_ID）}"
        VPN_ID=$_ans
        break
    done
    echo
fi

[[ -n $VPN_ID ]] || die "非交互运行且没认出 VPN_ID —— 请传参：$0 <VPN_ID>"
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
        "$XL_CONF" | head -n1 || true)"
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

# 变更前先指纹，用来判断"重跑但配置没变"→ 就不用断隧道。
#
# 坑（2026-09-27 在 61.13.236.126 上踩实）：$UNIT 第一次跑时还不存在（native unit
# 正是本脚本要装的），cat 有文件读不到就返回 1，pipefail 把它传出来，而
# OLD_STAMP="$(stamp)" 是裸赋值 —— set -e 当场静默退出，一句错都不打，
# 表现为"抬头打印完就回到提示符"。所以 cat 的退出码必须在花括号里就地吃掉，
# 指纹照算"现有的那部分"，函数本身永远返回 0。
stamp() {
    { cat "$XL_CONF" "$PPP_CONF" "$UNIT" 2>/dev/null || true; } \
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

# chap-secrets：只在【一个有效账号都没有】时补上默认账号；有账号就一个字不动。
#
# 坑（2026-09-28 在 218.208.109.112 上踩实，全新机器 100% 中招）：
# 原来判的是 `[[ ! -s ... ]]`，即"文件不存在或为空才写"。但 Debian/Ubuntu 的 ppp 包
# 装完就【自带】一份 /etc/ppp/chap-secrets —— 里面只有两行注释 + 两个空行，
# 文件却是 80 字节，`-s` 判真。于是全新机器永远走 else 分支：一个账号都不写。
# 症状极具迷惑性：服务 active、17001 在听、自检全绿、L2TP 隧道和 Call 都能建起来，
# 但 pppd 每次都报
#     "The remote system is required to authenticate itself
#      but I couldn't find any suitable secret (password) for it to use to do so."
# 客户端反复重拨、一次都分不到 IP —— 而"服务是好的"会把排查方向彻底带偏。
# （老脚本部署过的机器不会暴露，因为 farmer 账号早就在了。）
#
# 现在按【有效账号数】判：grep -v 掉注释和空行，还剩东西就认为你手工配过，不碰。
CHAP_SECRETS=/etc/ppp/chap-secrets
if [[ -f $CHAP_SECRETS ]] && grep -qvE '^[[:space:]]*(#|$)' "$CHAP_SECRETS"; then
    warn "chap-secrets 里已有账号，保留不动（不覆盖你手工加的）"
else
    # 追加而不是覆盖：ppp 包自带的注释头留着，将来好认
    [[ -f $CHAP_SECRETS ]] || : > "$CHAP_SECRETS"
    cat >> "$CHAP_SECRETS" <<'EOF'
farmer   l2tpd   "chp1qaz!QAZ"   *
EOF
    ok "chap-secrets 里原本没有任何账号，已补上默认账号 farmer"
fi
chmod 600 "$CHAP_SECRETS"

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

FRAG="$(systemctl show xl2tpd -p FragmentPath | cut -d= -f2- || true)"
if [[ $FRAG == "$UNIT" ]]; then
    ok "unit 已生效：$FRAG"
else
    die "unit 没生效，systemd 实际用的是：${FRAG:-（空）}"
fi

# ---------------------------------------------------------------- 5. 禁止 needrestart 碰它

step "禁止 needrestart 重启 xl2tpd"

# 无条件建目录再写。
#
# 原来写的是 `if [[ -d /etc/needrestart/conf.d ]]` —— "目录在才写"。在
# 【先跑脚本、后装 needrestart】的机器上会静默跳过，而且之后再也不会补写。
# 目录不是 conffile，apt 后来装 needrestart 时它已存在也不冲突，所以直接 mkdir -p
# 没有副作用（没装 needrestart 的机器上就多一个空目录）。
#
# 这条的份量说清楚：装完 native unit 之后，needrestart 再重启 xl2tpd 已经不会把服务
# 搞死了（那个缺 --retry 的竞态在发行版 sysv init 脚本里，native unit 不用 pidfile）。
# 所以这个黑名单防的是【白白掐断在线隧道】，不是【防服务躺平】——
# 漏写的代价是"将来某次系统自动更新，隧道断几秒"，不是灾难。但既然一行就能堵上，就堵上。
mkdir -p /etc/needrestart/conf.d
# zz- 前缀保证排在最后，不会被别的 drop-in 覆盖掉 blacklist_rc
cat > "$NR_CONF" <<'EOF'
# xl2tpd 是 L2TP 落地服务，重启会掐断所有在线隧道。
# 它由 systemd (Restart=always) 负责兜底，needrestart 不要碰。
$nrconf{blacklist_rc} = [
    qr(^xl2tpd),
];
EOF
# 提示只是提示（文件已经写好了），但别报错话：按 dpkg 的实际安装状态判，
# 不用 `command -v`（PATH 里没有 /usr/sbin 时会误报"没装"）。
if dpkg-query -W -f='${Status}' needrestart 2>/dev/null | grep -q 'install ok installed'; then
    ok "已写入 $NR_CONF"
else
    ok "已写入 $NR_CONF（这台还没装 needrestart，先放着，将来装上也生效）"
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

if netfilter-persistent save >/dev/null; then
    ok "iptables 规则已持久化（重启不丢）"
else
    bad "netfilter-persistent save 失败 —— 重启后 NAT 规则会丢"
fi

# ---------------------------------------------------------------- 7. 启动

step "启动 xl2tpd"

NEW_STAMP="$(stamp)"
if [[ $OLD_STAMP == "$NEW_STAMP" ]] && systemctl is-active --quiet xl2tpd; then
    ok "配置无变化且服务在跑 —— 跳过重启，隧道不断"
else
    if systemctl restart xl2tpd; then
        ok "已重启 xl2tpd"
    else
        bad "systemctl restart xl2tpd 失败 —— 见下面自检和日志"
    fi
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
    # 别再往 l2tp_ppp 上引了 —— 那是错的。
    # xl2tpd 是用户态实现，自己处理 L2TP，再用 pppd 建 ppp 接口，
    # 【不需要】l2tp_ppp / pppol2tp 内核模块。2026-09-27 在 61.13.236.126 上实测：
    # 那台机器 modinfo l2tp_ppp 直接 "not found"，/lib/modules/*/kernel/net/l2tp/
    # 目录都不存在，客户端照样连得上、日志里有 ppp0 Gained carrier。
    # 真正的前提是 pppd + /dev/ppp。下面直接查这两个，给出能动手的命令。
    printf '      ↳ 先核对依赖（L2TP 走用户态，不需要 l2tp_ppp 内核模块）：\n'
    command -v pppd >/dev/null 2>&1 \
        || printf '        ✘ 没有 pppd —— apt-get install -y ppp\n'
    [[ -c /dev/ppp ]] \
        || printf '        ✘ 没有 /dev/ppp —— modprobe ppp_generic（受限容器可能加载不了）\n'
    printf '      ↳ 依赖没问题的话，就是配置或启动失败，直接看：\n'
    printf '        journalctl -u xl2tpd -n 50 --no-pager\n'
    printf '        /usr/sbin/xl2tpd -D -c %s   # 前台跑一遍，报错直接打在屏幕上\n' "$XL_CONF"
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

# 这一条是 2026-09-28 补的。这个 bug 的形状是【每一项都真、结论是错】：
# 服务在跑、端口在听、NAT 在位、unit 也对，一台 chap-secrets 里一个账号都没有的
# 机器却照样报【部署完成、全绿】—— 前面每一项都是真的，唯独没有客户端能连上来。
#
# 说清楚它现在的分量（别当它是这次的保险）：上面写账号那步失败时 set -e 会当场
# 中断（非 0 退出），自检根本轮不到跑 —— 已实测。所以这条 bad 分支在正常流程里
# 够不着，它防的是【将来有人再往里加跳过条件】这种回退，也就是这个 bug 的原始形状。
# 真正的修复在上面那步：改成按有效账号数判，且没有账号就一定写。
if [[ -f $CHAP_SECRETS ]] && grep -qvE '^[[:space:]]*(#|$)' "$CHAP_SECRETS"; then
    ok "chap-secrets 里有 $(grep -cvE '^[[:space:]]*(#|$)' "$CHAP_SECRETS") 个账号"
else
    bad "chap-secrets 里一个账号都没有 —— 客户端会卡在 PPP 认证，连不上"
    printf '      ↳ 症状：pppd 报 "couldn'"'"'t find any suitable secret"\n'
    printf '      ↳ 补一个：echo '"'"'farmer   l2tpd   "chp1qaz!QAZ"   *'"'"' >> %s\n' "$CHAP_SECRETS"
    printf '        然后 chmod 600 %s\n' "$CHAP_SECRETS"
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
