#!/bin/bash
#
# L2TP 落地机部署（含 xray 接管层）—— 破坏性重装，跑完即用
#
#   sudo ./l2tp_deploy.sh             交互：问一次 VPN_ID，回车沿用当前网段
#   sudo ./l2tp_deploy.sh 12          直接指定 VPN_ID
#   sudo DRY_RUN=1 ./l2tp_deploy.sh   只打印计划，不动手
#
# 三条例规：
#   1. 先删后装。这台机器上旧的 L2TP / xray 配置全部删掉（iptables 规则、unit、
#      配置、脚本），再从零装一遍。不存在"增量升级"这条路，也就不存在新旧混杂。
#   2. 重启后继续生效。iptables 落 rules.v4；ip rule 由 xray-redir 启动时补；
#      networkd 设成不再清理外来策略规则。
#   3. 不留备份。跑之前什么样不回滚，要换就重跑。
#
# 唯一不删的是 /etc/ppp/chap-secrets：里面是账号密码，不是拓扑状态，
# 删了就得知道原账号才恢复得回来。有账号就原样保留，一个都没有才写默认账号。
set -Eeuo pipefail

# ---------------------------------------------------------------- 常量

L2TP_PORT=17001
MTU=1420
TAG=l2tp-deploy

VPN_ID_FILE=/etc/l2tp-deploy.conf
XL_CONF=/etc/xl2tpd/xl2tpd.conf
PPP_CONF=/etc/ppp/options.xl2tpd
CHAP_SECRETS=/etc/ppp/chap-secrets
UNIT=/etc/systemd/system/xl2tpd.service
NR_CONF=/etc/needrestart/conf.d/zz-xl2tpd-no-restart.conf
SYSCTL_CONF=/etc/sysctl.d/zz-l2tp.conf

# xray 接管层
XRAY_DIR=/opt/xray-redir
XRAY_VER=26.3.27
XRAY_UNIT=/etc/systemd/system/xray-redir.service
REDIR_SH=/usr/local/sbin/l2tp-redir-firewall.sh
NETD_CONF=/etc/systemd/networkd.conf.d/99-l2tp-redir.conf
TCP_PORT=12345
UDP_PORT=12346

DRY_RUN=${DRY_RUN:-0}
FAIL=0

# ---------------------------------------------------------------- 输出

ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✘\033[0m %s\n' "$*"; FAIL=1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die()  { printf '\n\033[31m✘ %s\033[0m\n' "$*" >&2; exit 1; }

# 任何"意外的"失败都报出行号再退。-E（errtrace）让它也能进函数体，
# 不然函数内的失败照样一声不吭。
trap 'st=$?; printf "\n\033[31m✘ 第 %s 行失败（退出码 %s）—— 上面最后一条输出就是现场\033[0m\n" "$LINENO" "$st" >&2' ERR

# ---------------------------------------------------------------- 小工具

conf_get() { [[ -r $VPN_ID_FILE ]] && sed -n "s/^$1=//p" "$VPN_ID_FILE" | tail -n1 || true; }

conf_set() {
    [[ -f $VPN_ID_FILE ]] || { : > "$VPN_ID_FILE"; chmod 600 "$VPN_ID_FILE"; }
    if grep -q "^$1=" "$VPN_ID_FILE"; then
        sed -i "s|^$1=.*|$1=$2|" "$VPN_ID_FILE"
    else
        printf '%s=%s\n' "$1" "$2" >> "$VPN_ID_FILE"
    fi
}

# 只增不删：同一组规则已存在就跳过，不存在才追加。重复执行幂等，不同参数往上叠加。
add_rule() {
    local t=$1 c=$2; shift 2
    if iptables -t "$t" -C "$c" "$@" 2>/dev/null; then
        printf '    · 已存在，跳过：%s %s\n' "$c" "$*"
    else
        iptables -t "$t" -A "$c" "$@"
        printf '    \033[32m+\033[0m 已添加：%s %s\n' "$c" "$*"
    fi
}

# ---------------------------------------------------------------- 前置检查

[[ $EUID -eq 0 ]] || die "请用 root 执行：sudo $0"

# ---------------------------------------------------------------- 收集 VPN_ID

# 擦除用的旧网段：只认磁盘上已有的痕迹，跟这次要装的新网段无关。
# 换网段时（`./l2tp_deploy.sh 12`，机器上还是 11）必须删旧的，
# 拿新值去删等于什么都没删。
PREV_ID="$(conf_get VPN_ID)"
if [[ -z $PREV_ID && -r $XL_CONF ]]; then
    PREV_ID="$(sed -n \
        's/^[[:space:]]*local ip[[:space:]]*=[[:space:]]*10\.10\.\([0-9]\+\)\..*/\1/p' \
        "$XL_CONF" | head -n1 || true)"
fi
[[ $PREV_ID =~ ^[0-9]+$ ]] || PREV_ID=""
OLD_NET=""
[[ -n $PREV_ID ]] && OLD_NET="10.10.${PREV_ID}.0/24"

# 默认值来源优先级：命令行参数 > /etc/l2tp-deploy.conf > 现存 xl2tpd.conf 自动识别
# 交互运行时一定停下来问一次（换网段会换掉线上客户端的 IP，不能替人猜）。
VPN_ID="${1:-}"
ARG_ID="$VPN_ID"
SRC=""
if [[ -n $VPN_ID ]]; then
    SRC="命令行参数"
else
    VPN_ID="$(conf_get VPN_ID)"
    [[ -n $VPN_ID ]] && SRC="$VPN_ID_FILE"
fi

if [[ -z $VPN_ID && -r $XL_CONF ]]; then
    # 末尾的 || true 不是多余的：sed | head 在 pipefail 下有 SIGPIPE 竞态。
    _n="$(sed -n \
        's/^[[:space:]]*local ip[[:space:]]*=[[:space:]]*10\.10\.\([0-9]\+\)\..*/\1/p' \
        "$XL_CONF" | head -n1 || true)"
    if [[ $_n =~ ^[0-9]+$ ]]; then
        VPN_ID="$_n"
        SRC="现存 xl2tpd.conf（自动识别）"
    fi
fi

if [[ -z $ARG_ID && -t 0 ]]; then
    echo
    if [[ -n $VPN_ID ]]; then
        printf ' 当前 VPN_ID : %s   →   网段 10.10.%s.0/24\n' "$VPN_ID" "$VPN_ID"
        printf ' 来源        : %s\n' "$SRC"
        printf ' 直接回车保持不变，输入数字则换网段（旧网段会被一起删掉）\n'
    fi
    while :; do
        read -rp " VPN_ID (1-200): " _ans || die "读不到输入（终端被关了？）"
        if [[ -z $_ans ]]; then
            [[ -n $VPN_ID ]] && break
            echo " 这台机器上没认出 VPN_ID，必须输一个"
            continue
        fi
        [[ $_ans =~ ^[0-9]+$ ]] || { echo " 必须是数字，重新输入"; continue; }
        _ans=$((10#$_ans))
        (( _ans >= 1 && _ans <= 200 )) || { echo " 必须在 1-200 之间，重新输入"; continue; }
        VPN_ID=$_ans
        break
    done
    echo
fi

[[ -n $VPN_ID ]] || die "非交互运行且没认出 VPN_ID —— 请传参：$0 <VPN_ID>"
[[ $VPN_ID =~ ^[0-9]+$ ]] || die "VPN_ID 必须是数字，收到：$VPN_ID"
VPN_ID=$((10#$VPN_ID))
(( VPN_ID >= 1 && VPN_ID <= 200 )) || die "VPN_ID 必须在 1-200 之间，收到：$VPN_ID"

VPN_NET="10.10.${VPN_ID}"
LOCAL_IP="${VPN_NET}.1"
IP_RANGE="${VPN_NET}.10-${VPN_NET}.50"
VPN_CIDR="${VPN_NET}.0/24"

# ---------------------------------------------------------------- 本机公网段

# 排除「落地机自己所在网段」，否则发给同网段（网关、邻居）的包会被绕进 xray。
# `ip route show scope link` 里内核已经把网段算好了（103.227.227.0/24 dev ens17
# proto kernel scope link src ...），不用自己做按位与。RFC1918 排除掉。
# 推不出来不算错：--dst-type LOCAL 那条仍然护住本机。
BOXLOCAL="$(ip -4 route show scope link 2>/dev/null \
    | awk '$1 ~ /^[0-9]+(\.[0-9]+){3}\/[0-9]+$/ {print $1}' \
    | grep -vE '^(10\.|127\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' \
    | paste -sd' ' - || true)"

echo
echo "=========================================="
echo " VPN 网段   : ${VPN_CIDR}"
echo " VPN_ID来源 : ${SRC}"
echo " 服务端 IP  : ${LOCAL_IP}"
echo " 客户端池   : ${IP_RANGE}"
echo " L2TP 端口  : ${L2TP_PORT}  (UDP)"
echo " MTU / MRU  : ${MTU}"
echo " xray 入口  : TCP ${TCP_PORT} (REDIRECT) / UDP ${UDP_PORT} (TPROXY)"
echo " 本机网段   : ${BOXLOCAL:-（推不出来，只排除本机地址）}"
if [[ -n $OLD_NET && $OLD_NET != "$VPN_CIDR" ]]; then
    echo " ⚠ 旧网段   : ${OLD_NET}  →  本次改成 ${VPN_CIDR}（旧规则先删掉）"
fi
echo "=========================================="
echo " 会先删掉这台机器上所有旧的 L2TP / xray 配置，再重装。"
echo " 在线隧道会断，服务会被重启；不留备份。"
echo "=========================================="

if [[ $DRY_RUN == 1 ]]; then
    echo
    echo "DRY_RUN=1 —— 只显示计划，未做任何改动。"
    exit 0
fi

# ---------------------------------------------------------------- 1. 擦除

step "擦除旧配置（先删后装）"

systemctl disable --now xray-redir >/dev/null 2>&1 || true
systemctl disable --now xl2tpd   >/dev/null 2>&1 || true

# 旧防火墙脚本还在就用它自己的 remove 精确删规则（它按 --check 逐条对，不用解析输出）
if [[ -x $REDIR_SH ]]; then
    "$REDIR_SH" remove >/dev/null 2>&1 || true
    ok "已用旧脚本撤掉 REDIRECT/TPROXY/ip rule"
fi

# NAT：按旧网段精确删。两种形状都试——带 comment 的（本脚本）和不带的（老脚本）。
if [[ -n $OLD_NET ]]; then
    n=0
    while iptables -t nat -D POSTROUTING -s "$OLD_NET" -m comment --comment "$TAG" -j MASQUERADE 2>/dev/null; do
        n=$((n + 1))
    done
    while iptables -t nat -D POSTROUTING -s "$OLD_NET" -j MASQUERADE 2>/dev/null; do
        n=$((n + 1))
    done
    (( n > 0 )) && ok "已删掉 ${OLD_NET} 的 ${n} 条 MASQUERADE"
fi

rm -f "$XRAY_UNIT" "$REDIR_SH" "$UNIT" "$XL_CONF" "$PPP_CONF" "$NR_CONF" "$SYSCTL_CONF"
rm -f /etc/needrestart/conf.d/99-xl2tpd-no-restart.conf
# xray 内核留着不删。删了就得每次重跑都重新下 36MB，网络一抖这台机器当场变下线。
# 版本对不上时第 7 步会重下。
rm -f "$XRAY_DIR/config.json"
systemctl daemon-reload
ok "已删掉旧 unit / 配置 / 旧防火墙脚本（xray 内核保留）"
warn "chap-secrets 没动（要保留账号）；有重复账号的话自己看一眼 $CHAP_SECRETS"

# ---------------------------------------------------------------- 2. 依赖

step "安装依赖"

export DEBIAN_FRONTEND=noninteractive
# needrestart 装完包会弹多选框并预勾好要重启的服务，非交互模式下还会"不问、静默重启"。
# 这个变量是 apt-pinvoke 里的硬开关，DEBIAN_FRONTEND 挡不住它。
export NEEDRESTART_SUSPEND=1

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
    xl2tpd ppp iptables-persistent curl unzip || die "apt-get install 失败"

[[ -x /usr/sbin/xl2tpd ]] || die "装完了却找不到 /usr/sbin/xl2tpd"
ok "xl2tpd / ppp / iptables-persistent / curl / unzip 就位"

# ---------------------------------------------------------------- 3. 内核参数

step "内核参数"

cat > "$SYSCTL_CONF" <<'EOF'
# 由 l2tp_deploy.sh 管理，请勿手工编辑
net.ipv4.ip_forward = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

# 镜像里别的 sysctl 文件可能有错，会让 --system 返回非零；算数的是下面的实际值。
sysctl --system >/dev/null 2>&1 \
    || warn "sysctl --system 报了错（多半来自镜像里其他 sysctl 文件），按实际值判定"

if [[ "$(sysctl -n net.ipv4.ip_forward)" == 1 ]]; then
    ok "ip_forward = 1"
else
    bad "ip_forward 没生效"
    printf '      ↳ 是这些文件在抢（/etc/sysctl.conf 最后应用，优先级最高）：\n'
    grep -rl '^[[:space:]]*net\.ipv4\.ip_forward' /etc/sysctl.conf /etc/sysctl.d 2>/dev/null \
        | sed 's/^/        /' || true
fi

if [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == bbr ]]; then
    ok "BBR 生效（落地→对端那段走 BBR，跨洋丢包时比客户端自己扛更快）"
else
    warn "BBR 没生效（内核 <4.9 或模块缺失？不影响 L2TP，但没加速）"
fi

# ---------------------------------------------------------------- 4. L2TP 配置

step "写 xl2tpd / ppp 配置"

mkdir -p /etc/xl2tpd

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

# mtu/mru 一定要给：L2TP 封装后不限制容易 PMTU 黑洞（能拨上、小包通、大包卡死）
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

# chap-secrets 按【有效账号数】判：有账号就一个字不动。
# （坑的形状：ppp 包装完就自带一份只有注释的 chap-secrets，80 字节、非空，
#  按 -s 判会永远跳过写入 —— 症状是服务全绿但客户端卡在 PPP 认证。）
if [[ -f $CHAP_SECRETS ]] && grep -qvE '^[[:space:]]*(#|$)' "$CHAP_SECRETS"; then
    ok "chap-secrets 里已有 $(grep -cvE '^[[:space:]]*(#|$)' "$CHAP_SECRETS") 个账号，保留不动"
else
    [[ -f $CHAP_SECRETS ]] || : > "$CHAP_SECRETS"
    cat >> "$CHAP_SECRETS" <<'EOF'
farmer   l2tpd   "chp1qaz!QAZ"   *
EOF
    ok "chap-secrets 里原本没有账号，已补上默认账号 farmer"
fi
chmod 600 "$CHAP_SECRETS"

# ---------------------------------------------------------------- 5. native unit

step "部署 native systemd unit"

# 为什么必须换掉发行版 sysv 脚本：/etc/init.d/xl2tpd 的 stop 分支没有 --retry，
# 发完 SIGTERM 立刻返回，systemd 紧接着 start 时旧进程还在、pidfile 还在，
# start-stop-daemon 判定 "already running" 拒绝启动并返回 1，而那个脚本有 set -e
# —— unit 变 failed，而 sysv-generator 生成的是 Restart=no，服务就此永久躺平。
# Type=simple + -D 彻底绕开 pidfile 和这个竞态。
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
# /var/run 是 /run 的软链、/run 是 tmpfs，重启即清空。发行版 init 脚本每次 start
# 都 mkdir -p /var/run/xl2tpd，native unit 顶掉它之后就没人建了，缺了它的症状是
#   open_controlfd: Unable to open /var/run/xl2tpd/l2tp-control for reading.
# 退出码 1，被 Restart=always 顶成每 3 秒一次的死循环（装完全绿、重启即死）。
RuntimeDirectory=xl2tpd
RuntimeDirectoryMode=0755
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
[[ $FRAG == "$UNIT" ]] || die "unit 没生效，systemd 实际用的是：${FRAG:-（空）}"
ok "unit 已生效：$FRAG"

# ---------------------------------------------------------------- 6. needrestart

step "禁止 needrestart 重启 xl2tpd"

mkdir -p /etc/needrestart/conf.d
cat > "$NR_CONF" <<'EOF'
# xl2tpd 是 L2TP 落地服务，重启会掐断所有在线隧道。
# 它由 systemd (Restart=always) 负责兜底，needrestart 不要碰。
$nrconf{blacklist_rc} = [
    qr(^xl2tpd),
];
EOF
ok "已写入 $NR_CONF"

# ---------------------------------------------------------------- 7. xray 接管层

step "部署 xray 接管层"

# ---- 7.1 内核
mkdir -p "$XRAY_DIR"
case "$(uname -m)" in
    x86_64)          XZIP="Xray-linux-64.zip" ;;
    aarch64|arm64)   XZIP="Xray-linux-arm64-v8a.zip" ;;
    *)               die "不认识的 CPU 架构：$(uname -m)" ;;
esac
XURL="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VER}/${XZIP}"

# 版本一致就不动它；不一致（或压根没有）才重下。`|| true` 是给 xray 不存在时
# 那个 127 准备的 —— 否则 pipefail + 裸赋值会让 set -e 静默退出。
CUR_VER="$("$XRAY_DIR/xray" version 2>/dev/null | awk 'NR==1{print $2}' || true)"
if [[ $CUR_VER == "$XRAY_VER" ]]; then
    ok "xray 已在位：v${CUR_VER}"
else
    [[ -n $CUR_VER ]] && warn "现装的是 v${CUR_VER}，要的是 v${XRAY_VER}，重新下载"
    t="$(mktemp -d)"
    curl -fsSL --connect-timeout 20 -o "$t/x.zip" "$XURL" \
        || die "下载 xray 失败：$XURL"
    unzip -oq "$t/x.zip" -d "$XRAY_DIR" || die "解包 xray 失败"
    rm -rf "$t"
    chmod +x "$XRAY_DIR/xray"
    [[ -x $XRAY_DIR/xray ]] && "$XRAY_DIR/xray" version >/dev/null 2>&1 \
        || die "xray 解包后跑不起来"
    ok "xray 已安装：$("$XRAY_DIR/xray" version | head -n1)"
fi

# ---- 7.2 配置：两个 dokodemo-door 入口 + freedom 直出
# followRedirect 让入口直接从 socket 取原始目的地址（REDIRECT 取 SO_ORIGINAL_DST，
# TPROXY 取本地路由），freedom 再按这个地址重新发起连接。
cat > "$XRAY_DIR/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "tcp-redir",
      "listen": "0.0.0.0",
      "port": ${TCP_PORT},
      "protocol": "dokodemo-door",
      "settings": { "network": "tcp", "followRedirect": true },
      "streamSettings": { "sockopt": { "tproxy": "redirect" } }
    },
    {
      "tag": "udp-tproxy",
      "listen": "0.0.0.0",
      "port": ${UDP_PORT},
      "protocol": "dokodemo-door",
      "settings": { "network": "udp", "followRedirect": true },
      "streamSettings": { "sockopt": { "tproxy": "tproxy" } }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "tag": "direct" } ]
}
EOF
ok "config.json（TCP ${TCP_PORT} / UDP ${UDP_PORT}）"

# ---- 7.3 防火墙脚本：网段在本机算好写死，不靠运行时猜
{
    echo '#!/bin/bash'
    echo '# Transparent re-origination for L2TP clients.'
    echo '# Usage: l2tp-redir-firewall.sh apply|remove|status'
    echo '# 由 l2tp_deploy.sh 生成，勿手工编辑。只增不删，永不 flush 任何链。'
    echo 'set -u'
    echo
    printf 'SUBNET=%q\n'   "$VPN_CIDR"
    printf 'BOXLOCAL=%q\n'  "$BOXLOCAL"
    printf 'TCP_PORT=%s\n'  "$TCP_PORT"
    printf 'UDP_PORT=%s\n'  "$UDP_PORT"
    cat <<'BODY'

apply_one() {
  local table="$1"; shift
  iptables -t "$table" -C "$@" 2>/dev/null || iptables -t "$table" -A "$@"
}

del_one() {
  local table="$1"; shift
  while iptables -t "$table" -D "$@" 2>/dev/null; do :; done
}

apply() {
  # TCP -> REDIRECT。三条 RETURN 必须排在动作规则前面。
  apply_one nat PREROUTING -s "$SUBNET" -m addrtype --dst-type LOCAL -j RETURN
  apply_one nat PREROUTING -s "$SUBNET" -d 10.0.0.0/8 -j RETURN
  for net in $BOXLOCAL; do
    apply_one nat PREROUTING -s "$SUBNET" -d "$net" -j RETURN
  done
  apply_one nat PREROUTING -s "$SUBNET" -p tcp -j REDIRECT --to-ports "$TCP_PORT"

  # UDP -> TPROXY（UDP 的 REDIRECT 拿不到原始目的地址，只能用 TPROXY）
  apply_one mangle PREROUTING -s "$SUBNET" -m addrtype --dst-type LOCAL -j RETURN
  apply_one mangle PREROUTING -s "$SUBNET" -d 10.0.0.0/8 -j RETURN
  for net in $BOXLOCAL; do
    apply_one mangle PREROUTING -s "$SUBNET" -d "$net" -j RETURN
  done
  apply_one mangle PREROUTING -s "$SUBNET" -p udp -j TPROXY --on-port "$UDP_PORT" --tproxy-mark 0x1/0x1

  # 两个监听端口只对隧道内开放
  apply_one filter INPUT -p udp --dport "$UDP_PORT" ! -s "$SUBNET" -j DROP
  apply_one filter INPUT -p tcp --dport "$TCP_PORT" ! -s "$SUBNET" -j DROP

  # TPROXY 的落地条件：mark 0x1 的包查 table 100，table 100 里 default 指向本机 lo。
  ip rule show | grep -q 'fwmark 0x1 lookup 100' || ip rule add fwmark 1 lookup 100
  # 实际显示是 `local default dev lo`，不是 `local 0.0.0.0/0`；两种都认。
  ip route show table 100 2>/dev/null | grep -qE '^(local default|local 0\.0\.0\.0/0)' \
    || ip route add local 0.0.0.0/0 dev lo table 100
}

remove() {
  del_one nat PREROUTING -s "$SUBNET" -p tcp -j REDIRECT --to-ports "$TCP_PORT"
  for net in $BOXLOCAL; do
    del_one nat PREROUTING -s "$SUBNET" -d "$net" -j RETURN
  done
  del_one nat PREROUTING -s "$SUBNET" -d 10.0.0.0/8 -j RETURN
  del_one nat PREROUTING -s "$SUBNET" -m addrtype --dst-type LOCAL -j RETURN

  del_one mangle PREROUTING -s "$SUBNET" -p udp -j TPROXY --on-port "$UDP_PORT" --tproxy-mark 0x1/0x1
  for net in $BOXLOCAL; do
    del_one mangle PREROUTING -s "$SUBNET" -d "$net" -j RETURN
  done
  del_one mangle PREROUTING -s "$SUBNET" -d 10.0.0.0/8 -j RETURN
  del_one mangle PREROUTING -s "$SUBNET" -m addrtype --dst-type LOCAL -j RETURN

  del_one filter INPUT -p udp --dport "$UDP_PORT" ! -s "$SUBNET" -j DROP
  del_one filter INPUT -p tcp --dport "$TCP_PORT" ! -s "$SUBNET" -j DROP

  ip rule del fwmark 1 lookup 100 2>/dev/null || true
  ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null || true
}

status() {
  echo "--- nat PREROUTING ---";    iptables -t nat -S PREROUTING
  echo "--- mangle PREROUTING ---"; iptables -t mangle -S PREROUTING
  echo "--- filter INPUT ---";      iptables -t filter -S INPUT
  echo "--- ip rule ---";           ip rule show
  echo "--- table 100 ---";         ip route show table 100
}

case "${1:-}" in
  apply)  apply ;;
  remove) remove ;;
  status) status ;;
  *) echo "usage: $0 apply|remove|status" >&2; exit 2 ;;
esac
BODY
} > "$REDIR_SH"
chmod 755 "$REDIR_SH"
ok "防火墙脚本：$REDIR_SH（SUBNET=${VPN_CIDR}）"

# ---- 7.4 unit
# ExecStartPre 是 ip rule 的唯一来源：重启后内核里的规则是空的，靠它补。
# StartLimitIntervalSec=0 和 xl2tpd 一样 —— 崩了就一直重试，别被 systemd 放弃。
# Before=xl2tpd：开机时先有接管，再开隧道。
cat > "$XRAY_UNIT" <<'EOF'
[Unit]
Description=Xray transparent redirect for L2TP egress re-origination
After=network-online.target netfilter-persistent.service
Wants=network-online.target
Before=xl2tpd.service
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStartPre=/usr/local/sbin/l2tp-redir-firewall.sh apply
ExecStart=/opt/xray-redir/xray run -c /opt/xray-redir/config.json
ExecStopPost=/usr/local/sbin/l2tp-redir-firewall.sh remove
Restart=always
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xray-redir >/dev/null 2>&1 || true
ok "unit 已部署：$XRAY_UNIT"

# ---------------------------------------------------------------- 8. NAT

step "配置 NAT 转发"

add_rule nat POSTROUTING -s "$VPN_CIDR" -m comment --comment "$TAG" -j MASQUERADE

# ---------------------------------------------------------------- 9. 启动

step "启动服务"

systemctl restart xl2tpd || bad "systemctl restart xl2tpd 失败 —— 见下面自检和日志"
systemctl restart xray-redir || bad "systemctl restart xray-redir 失败 —— journalctl -u xray-redir -n 50"

# ---------------------------------------------------------------- 10. 持久化

step "持久化 iptables（必须排在 xray 铺规则之后）"

# 先起 xray 再 save，rules.v4 里才会有 REDIRECT/TPROXY，重启后开机即接管。
# 顺序反了的话，开机窗口里流量会直接 MASQUERADE 出去 —— 那是漏，不是断。
if netfilter-persistent save >/dev/null; then
    ok "iptables 规则已保存"
else
    bad "netfilter-persistent save 失败 —— 重启后规则会丢"
fi

# ---------------------------------------------------------------- 11. networkd

step "锁定 networkd（策略规则不再被清）"

# 病根：systemd 255 的 networkd 默认 ManageForeignRoutingPolicyRules=yes，
# 每次启动都会把"外来"的策略规则删掉。2026-10-22 一次 unattended-upgrade 触发
# needrestart 重启了 networkd，`fwmark 0x1 lookup 100` 就这么没了；
# table 100 的路由还在，于是只剩"路由对、规则没了"的半死状态 ——
# 包被 mark 了却没有规则查 table 100，从主表用公网地址出去，回包对不上。
# 表现是 UDP 全死、TCP 全活（TCP 走 iptables REDIRECT，networkd 不碰 iptables）。
if systemctl is-active --quiet systemd-networkd; then
    mkdir -p /etc/systemd/networkd.conf.d
    cat > "$NETD_CONF" <<'EOF'
# 由 l2tp_deploy.sh 管理，请勿手工编辑
# 不清理外来策略规则：xray 的 TPROXY 依赖 `ip rule add fwmark 1 lookup 100`，
# networkd 一启动就把它删掉会让 UDP 转发全挂。
[Network]
ManageForeignRoutingPolicyRules=no
EOF

    # drop-in 要 systemd >= 249。老版本读不到就往主文件里写。
    if ! systemd-analyze cat-config systemd/networkd.conf 2>/dev/null \
            | grep -q '^ManageForeignRoutingPolicyRules=no'; then
        warn "systemd 不认 networkd.conf.d，改为直接改 /etc/systemd/networkd.conf"
        if grep -qE '^#?ManageForeignRoutingPolicyRules=' /etc/systemd/networkd.conf; then
            sed -i 's/^#\?ManageForeignRoutingPolicyRules=.*/ManageForeignRoutingPolicyRules=no/' \
                /etc/systemd/networkd.conf
        elif grep -q '^\[Network\]' /etc/systemd/networkd.conf; then
            awk '{print} /^\[Network\]/{print "ManageForeignRoutingPolicyRules=no"}' \
                /etc/systemd/networkd.conf > /etc/systemd/networkd.conf.new
            mv /etc/systemd/networkd.conf.new /etc/systemd/networkd.conf
        else
            die "networkd.conf 里没有 [Network] 段，没法写入"
        fi
    fi
    # 这里【不】重启 networkd。配置是它每次启动时读的，而规则只在它启动那一刻
    # 才会被删 —— 文件写下去，"下一次启动"这个点就已经被堵住了，不管那次启动是
    # 无人值守更新触发的还是重启触发的。现在手动重启只是白冒一次断网的风险。
    # 想亲眼验证：systemctl restart systemd-networkd 之后看 ip rule 还在不在。
    if systemd-analyze cat-config systemd/networkd.conf 2>/dev/null \
            | grep -q '^ManageForeignRoutingPolicyRules=no'; then
        ok "已配置 ManageForeignRoutingPolicyRules=no（下次 networkd 启动起生效）"
    else
        bad "配置没被 systemd 认到 —— 查 systemd 版本"
    fi
else
    warn "systemd-networkd 没在跑，跳过（这台机器不用它管网络）"
fi

# ---------------------------------------------------------------- 12. 自检

step "自检"

sleep 1

if systemctl is-active --quiet xl2tpd; then
    ok "xl2tpd active"
else
    bad "xl2tpd 没起来 —— journalctl -u xl2tpd -n 50 --no-pager"
fi

if systemctl is-active --quiet xray-redir; then
    ok "xray-redir active"
else
    bad "xray-redir 没起来 —— journalctl -u xray-redir -n 50 --no-pager"
fi

if ss -lun 2>/dev/null | grep -qE "[:.]${L2TP_PORT}[[:space:]]"; then
    ok "UDP ${L2TP_PORT} 在监听（L2TP）"
else
    bad "UDP ${L2TP_PORT} 没在监听"
    command -v pppd >/dev/null 2>&1 || printf '      ↳ 没有 pppd —— apt-get install -y ppp\n'
    [[ -c /dev/ppp ]] || printf '      ↳ 没有 /dev/ppp —— modprobe ppp_generic\n'
fi

if ss -lnt 2>/dev/null | grep -qE "[:.]${TCP_PORT}[[:space:]]" \
   && ss -lun 2>/dev/null | grep -qE "[:.]${UDP_PORT}[[:space:]]"; then
    ok "xray 在听 TCP ${TCP_PORT} / UDP ${UDP_PORT}"
else
    bad "xray 的入口端口没在听（config.json 或进程有问题）"
fi

if iptables -t nat -S PREROUTING | grep -qF -- "--to-ports ${TCP_PORT}"; then
    ok "nat PREROUTING 有 REDIRECT → ${TCP_PORT}"
else
    bad "nat PREROUTING 缺 REDIRECT"
fi

if iptables -t mangle -S PREROUTING | grep -qF -- "--on-port ${UDP_PORT}"; then
    ok "mangle PREROUTING 有 TPROXY → ${UDP_PORT}"
else
    bad "mangle PREROUTING 缺 TPROXY"
fi

# 这两条查的是【重启之后还在不在】，不是【现在在不在】。
if ip rule show | grep -q 'fwmark 0x1 lookup 100'; then
    ok "ip rule 有 fwmark 0x1 lookup 100"
else
    bad "ip rule 缺 fwmark 0x1 lookup 100 —— UDP 会被打到公网出口，回包对不上"
    printf '      ↳ $REDIR_SH apply 补一条，并确认 networkd 那个配置真的生效了\n'
fi

if ip route show table 100 2>/dev/null | grep -qE '^(local default|local 0\.0\.0\.0/0)'; then
    ok "table 100 有 local 路由"
else
    bad "table 100 缺 local 路由 —— mark 过的包无处可去"
fi

if grep -q "$VPN_CIDR" <(iptables -t nat -S POSTROUTING 2>/dev/null); then
    ok "NAT MASQUERADE 在位"
else
    bad "NAT MASQUERADE 不在位"
fi

if grep -q 'fwmark\|--to-ports' /etc/iptables/rules.v4 2>/dev/null; then
    ok "规则已落到 /etc/iptables/rules.v4（重启后开机即接管，不会漏）"
else
    bad "rules.v4 里没有接管规则 —— 重启后开机窗口内流量会直接出网"
fi

if systemctl is-active --quiet systemd-networkd; then
    if systemd-analyze cat-config systemd/networkd.conf 2>/dev/null \
            | grep -q '^ManageForeignRoutingPolicyRules=no'; then
        ok "networkd 不会清理外来策略规则（重启/升级后 fwmark 规则不再丢）"
    else
        bad "ManageForeignRoutingPolicyRules 没生效 —— 下次 networkd 重启会清掉 ip rule"
    fi
fi

if grep -q '^Restart=always' "$UNIT"; then
    ok "xl2tpd unit 带 Restart=always"
else
    bad "xl2tpd unit 缺 Restart=always"
fi

if grep -q '^RuntimeDirectory=xl2tpd' "$UNIT"; then
    ok "xl2tpd unit 声明了 RuntimeDirectory（重启后 /var/run/xl2tpd 自己回来）"
else
    bad "xl2tpd unit 缺 RuntimeDirectory —— 这台机器一重启 xl2tpd 就永久起不来"
fi

if grep -q '^StartLimitIntervalSec=0' "$XRAY_UNIT" && grep -q '^Restart=always' "$XRAY_UNIT"; then
    ok "xray-redir unit 崩了会一直重试（不会每 3 秒死一次就被放弃）"
else
    bad "xray-redir unit 缺 Restart=always 或 StartLimitIntervalSec=0"
fi

if [[ -f $CHAP_SECRETS ]] && grep -qvE '^[[:space:]]*(#|$)' "$CHAP_SECRETS"; then
    ok "chap-secrets 里有 $(grep -cvE '^[[:space:]]*(#|$)' "$CHAP_SECRETS") 个账号"
else
    bad "chap-secrets 里一个账号都没有 —— 客户端会卡在 PPP 认证"
fi

# ---------------------------------------------------------------- 结果

step "最近日志"
journalctl -u xl2tpd -n 8 --no-pager 2>/dev/null || true
journalctl -u xray-redir -n 8 --no-pager 2>/dev/null || true

echo
if [[ $FAIL -eq 0 ]]; then
    printf '\033[32m部署完成\033[0m\n'
    echo "  网段     : ${VPN_CIDR}"
    echo "  服务端   : ${LOCAL_IP}"
    echo "  客户端池 : ${IP_RANGE}"
    echo "  L2TP     : UDP ${L2TP_PORT}"
    echo "  接管     : TCP ${TCP_PORT} / UDP ${UDP_PORT} → xray → freedom"
    echo
    echo "客户端拨上后，所有 IPv4 流量都会被 xray 接住从这台机器重新发起。"
    echo "重启后照样生效：iptables 落盘 + xray-redir 开机补 ip rule + networkd 不清理。"
else
    printf '\033[31m部署有问题，见上面 ✘ 的项\033[0m\n' >&2
    exit 1
fi
