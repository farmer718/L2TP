#!/bin/bash
#
# A 机 UDP 入口：客户端 → A:A_PORT → DNAT → B_IP:B_PORT，并 SNAT 成 A 的公网 IP
#
# 规则是【累加】的：不同端口 / 不同目标各加一条，互不覆盖，
# 也永远不会删掉你已有的任何规则。同一组参数重复执行不会重复添加。
#
# 所有映射记在 $MAPFILE，重跑 = 把整张表重新铺一遍（防丢、防重启后失效）。
#
#   sudo ./nat_a_entry.sh                     首次交互；之后读映射表全自动重铺
#   sudo ./nat_a_entry.sh 5000 1.2.3.4 6000   追加一条映射 A_PORT B_IP B_PORT
#   sudo ./nat_a_entry.sh --list              列出已有映射
#   sudo ./nat_a_entry.sh --remove 5000       删掉 A_PORT=5000 那条映射
#
set -euo pipefail

TAG=nat-a
MAPFILE=/etc/l2tp-nat-a.mappings
SYSCTL_CONF=/etc/sysctl.d/zz-nat-a.conf
FAIL=0

# ---------------------------------------------------------------- 输出

ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✘\033[0m %s\n' "$*"; FAIL=1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die()  { printf '\n\033[31m✘ %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 规则增删（只增不删）

add_rule() {   # add_rule <table> <chain> <规则...>
    local t=$1 c=$2; shift 2
    if iptables -t "$t" -C "$c" "$@" 2>/dev/null; then
        printf '    · 已存在，跳过\n'
    else
        iptables -t "$t" -A "$c" "$@"
        printf '    \033[32m+\033[0m 已添加：%s\n' "$*"
    fi
}

del_rule() {   # 只在 --remove 时用
    local t=$1 c=$2; shift 2
    if iptables -t "$t" -C "$c" "$@" 2>/dev/null; then
        iptables -t "$t" -D "$c" "$@"
        printf '    \033[33m-\033[0m 已删除：%s\n' "$*"
    else
        printf '    · 本来就没有\n'
    fi
}

apply_mapping() {   # $1=A_PORT $2=B_IP $3=B_PORT
    local a=$1 b=$2 p=$3
    step "铺映射：A:${a}  →  ${b}:${p}"
    add_rule nat PREROUTING  -p udp --dport "$a" -m comment --comment "$TAG" -j DNAT --to-destination "${b}:${p}"
    add_rule nat POSTROUTING -p udp -d "$b" --dport "$p" -m comment --comment "$TAG" -j MASQUERADE
    add_rule filter FORWARD  -p udp -d "$b" --dport "$p" -m comment --comment "$TAG" -j ACCEPT
    add_rule filter FORWARD  -p udp -s "$b" --sport "$p" -m comment --comment "$TAG" -j ACCEPT
}

remove_mapping() {   # $1=A_PORT $2=B_IP $3=B_PORT
    local a=$1 b=$2 p=$3
    step "拆映射：A:${a}  →  ${b}:${p}"
    del_rule nat PREROUTING  -p udp --dport "$a" -m comment --comment "$TAG" -j DNAT --to-destination "${b}:${p}"
    del_rule nat POSTROUTING -p udp -d "$b" --dport "$p" -m comment --comment "$TAG" -j MASQUERADE
    del_rule filter FORWARD  -p udp -d "$b" --dport "$p" -m comment --comment "$TAG" -j ACCEPT
    del_rule filter FORWARD  -p udp -s "$b" --sport "$p" -m comment --comment "$TAG" -j ACCEPT
}

# ---------------------------------------------------------------- 映射表

map_list() { [[ -r $MAPFILE ]] && grep -vE '^[[:space:]]*(#|$)' "$MAPFILE" || true; }

map_has() {   # $1=A_PORT $2=B_IP $3=B_PORT
    map_list | awk -v a="$1" -v b="$2" -v p="$3" \
        '$1==a && $2==b && $3==p {f=1} END{exit !f}'
}

map_add() {
    [[ -f $MAPFILE ]] || { : > "$MAPFILE"; chmod 600 "$MAPFILE"; }
    if map_has "$1" "$2" "$3"; then
        warn "映射表里已有这条，不重复写"
    else
        printf '%s %s %s\n' "$1" "$2" "$3" >> "$MAPFILE"
        ok "已写入映射表：A:${1} → ${2}:${3}"
    fi
}

map_del() {   # $1=A_PORT
    [[ -f $MAPFILE ]] || return 0
    local tmp; tmp="$(mktemp)"
    awk -v a="$1" '$1!=a' "$MAPFILE" > "$tmp"
    cat "$tmp" > "$MAPFILE"          # 保留原 inode 与 600 权限
    rm -f "$tmp"
}

# ---------------------------------------------------------------- 校验

is_port() { [[ $1 =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
is_ipv4() { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

chk_all() {   # $1=A_PORT $2=B_IP $3=B_PORT
    is_port "$1" || die "A 端口不合法：$1"
    is_ipv4 "$2" || die "B IP 不合法：$2"
    is_port "$3" || die "B 端口不合法：$3"
}

# ---------------------------------------------------------------- 前置检查

[[ $EUID -eq 0 ]] || die "请用 root 执行：sudo $0"

# ---- --list
if [[ ${1:-} == --list || ${1:-} == -l ]]; then
    if [[ -s $MAPFILE ]]; then
        echo "已有映射（$MAPFILE）："
        map_list | awk '{printf "  A:%-6s → %s:%s\n", $1, $2, $3}'
    else
        echo "还没有任何映射。"
    fi
    exit 0
fi

# ---- --remove
if [[ ${1:-} == --remove ]]; then
    [[ -n ${2:-} ]] || die "用法：$0 --remove <A_PORT>"
    is_port "$2" || die "端口不合法：$2"
    # 这一步在依赖检查之前，没有 iptables 的话规则删不掉、映射表却会删掉，
    # 留下"表里没有、线上还在"的静默不一致。先讲清楚。
    command -v iptables >/dev/null 2>&1 \
        || warn "这台机器上没有 iptables —— 映射表会删掉，但线上残留的规则删不掉，得手工清"
    while read -r b p; do
        [[ -n $b && -n $p ]] && remove_mapping "$2" "$b" "$p"
    done < <(map_list | awk -v a="$2" '$1==a {print $2, $3}')
    map_del "$2"
    netfilter-persistent save >/dev/null 2>&1 || true
    ok "已从映射表移除 A_PORT=$2"
    exit 0
fi

# ---------------------------------------------------------------- 收集参数

NEW_MAP=0

if [[ $# -ge 3 ]]; then
    A_PORT=$1; B_IP=$2; B_PORT=$3
    chk_all "$A_PORT" "$B_IP" "$B_PORT"
    NEW_MAP=1
elif [[ $# -ne 0 ]]; then
    die "参数要么全给（A_PORT B_IP B_PORT），要么全不给（走映射表）"
fi

if [[ $NEW_MAP == 0 && ! -s $MAPFILE ]]; then
    [[ -t 0 ]] || die "非交互运行且没有 $MAPFILE —— 请传参：$0 <A_PORT> <B_IP> <B_PORT>"
    read -rp "请输入A监听UDP端口: " A_PORT
    read -rp "请输入B香港公网IP: "  B_IP
    read -rp "请输入B目标UDP端口: " B_PORT
    chk_all "$A_PORT" "$B_IP" "$B_PORT"
    NEW_MAP=1
fi

# 预演条数：现在几条，写完几条。map_add 在下面才执行，所以不能直接 map_list | wc -l
CUR_N="$(map_list | wc -l)"
PROJ_N=$CUR_N
if [[ $NEW_MAP == 1 ]] && ! map_has "$A_PORT" "$B_IP" "$B_PORT"; then
    PROJ_N=$((CUR_N + 1))
fi

echo
echo "=========================================="
[[ $NEW_MAP == 1 ]] && echo " 本次追加 : A:${A_PORT} → ${B_IP}:${B_PORT}"
echo " 映射总数 : ${CUR_N} → ${PROJ_N} 条"
echo " 现有规则不会被覆盖或删除"
echo "=========================================="

# ---------------------------------------------------------------- 0. 依赖
# 必须在任何 iptables 调用之前 —— 最小化安装的 Debian 不一定自带 iptables，
# 而 iptables-persistent 依赖 iptables，装上就一起有了。

step "检查依赖"

if command -v iptables >/dev/null 2>&1 && command -v netfilter-persistent >/dev/null 2>&1; then
    ok "iptables / netfilter-persistent 已就位"
else
    warn "缺 iptables 或 netfilter-persistent，正在安装…（iptables-persistent 会带上 iptables）"
    export DEBIAN_FRONTEND=noninteractive

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
        iptables-persistent || die "安装 iptables-persistent 失败"

    command -v iptables >/dev/null 2>&1 || die "装完了还是没有 iptables"
    ok "依赖已装好"
fi

# ---------------------------------------------------------------- 1. IP 转发

step "开启 IP 转发"

cat > "$SYSCTL_CONF" <<'EOF'
# 由 nat_a_entry.sh 管理，请勿手工编辑
net.ipv4.ip_forward = 1
EOF

sysctl --system >/dev/null 2>&1 \
    || warn "sysctl --system 报了错（多半来自镜像里其他 sysctl 文件），按下面的实际值判定"

if [[ "$(sysctl -n net.ipv4.ip_forward)" == 1 ]]; then
    ok "ip_forward = 1（已持久化到 $SYSCTL_CONF）"
else
    bad "ip_forward 没生效"
fi

# ---------------------------------------------------------------- 2. 铺规则

[[ $NEW_MAP == 1 ]] && map_add "$A_PORT" "$B_IP" "$B_PORT"

step "铺全部映射（只增不删）"
while read -r a b p; do
    [[ -n $a && -n $b && -n $p ]] && apply_mapping "$a" "$b" "$p"
done < <(map_list)

# ---------------------------------------------------------------- 3. 持久化

step "持久化 iptables"
if netfilter-persistent save >/dev/null; then
    ok "规则已保存，重启不丢"
else
    bad "netfilter-persistent save 失败 —— 重启可能会丢规则"
fi

# ---------------------------------------------------------------- 4. 自检

step "自检"

# 一条映射铺的是 4 条规则，必须 4 条都验。
# 只验 DNAT 会放过最常见的死法：DNAT 在位、FORWARD 没放行 —— 包转不出去，
# 脚本却报 ✔。"配完不通"基本都是这么来的。
count=0
while read -r a b p; do
    [[ -n $a && -n $b && -n $p ]] || continue
    miss=""
    iptables -t nat -C PREROUTING -p udp --dport "$a" \
        -m comment --comment "$TAG" -j DNAT --to-destination "${b}:${p}" 2>/dev/null \
        || miss+=" DNAT(入口)"
    iptables -t nat -C POSTROUTING -p udp -d "$b" --dport "$p" \
        -m comment --comment "$TAG" -j MASQUERADE 2>/dev/null \
        || miss+=" SNAT(出去)"
    iptables -t filter -C FORWARD -p udp -d "$b" --dport "$p" \
        -m comment --comment "$TAG" -j ACCEPT 2>/dev/null \
        || miss+=" FORWARD(出去)"
    iptables -t filter -C FORWARD -p udp -s "$b" --sport "$p" \
        -m comment --comment "$TAG" -j ACCEPT 2>/dev/null \
        || miss+=" FORWARD(回来)"
    if [[ -z $miss ]]; then
        ok "A:${a} → ${b}:${p}   4/4 条齐"
        count=$((count + 1))
    else
        bad "A:${a} → ${b}:${p}   缺：${miss# }"
    fi
done < <(map_list)

if [[ -f /etc/iptables/rules.v4 ]]; then
    if grep -q "$TAG" /etc/iptables/rules.v4 2>/dev/null; then
        ok "已落到 /etc/iptables/rules.v4（重启会自动恢复）"
    else
        bad "规则没写进 /etc/iptables/rules.v4 —— 重启会丢"
    fi
else
    bad "没有 /etc/iptables/rules.v4 —— 重启会丢"
fi

echo
echo "共 ${count} 条映射生效"
iptables -t nat -L PREROUTING -n --line-number 2>/dev/null | grep -F "/* $TAG */" || true

echo
if [[ $FAIL -eq 0 ]]; then
    printf '\033[32mNAT 入口配置完成\033[0m\n'
    echo "  重跑本脚本 = 把映射表重新铺一遍，不会覆盖已有规则。"
    echo "  查看映射：$0 --list"
else
    printf '\033[31m有项目失败，见上面 ✘\033[0m\n' >&2
    exit 1
fi
