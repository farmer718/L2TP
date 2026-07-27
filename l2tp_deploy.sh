#!/bin/bash

# ==========================
# 安装 xl2tpd
# ==========================

apt update
apt install xl2tpd iptables-persistent -y


# ==========================
# 开启 IP 转发
# ==========================

sysctl -w net.ipv4.ip_forward=1

grep -q "^net.ipv4.ip_forward" /etc/sysctl.conf || \
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf


# ==========================
# TCP BBR + fq
# ==========================

grep -q "^net.core.default_qdisc" /etc/sysctl.conf || \
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf

grep -q "^net.ipv4.tcp_congestion_control" /etc/sysctl.conf || \
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf


sysctl -p


# ==========================
# xl2tpd 配置
# ==========================

cat << 'EOF' > /etc/xl2tpd/xl2tpd.conf

[global]
port = 1701

[lns default]
ip range = 10.10.99.10-10.10.99.50
local ip = 10.10.99.1
require authentication = yes
name = l2tpd
pppoptfile = /etc/ppp/options.xl2tpd

EOF


# ==========================
# PPP配置
# ==========================

cat << 'EOF' > /etc/ppp/options.xl2tpd

require-chap
noccp
auth
nodefaultroute

lcp-echo-interval 30
lcp-echo-failure 4

EOF


# ==========================
# 用户认证
# ==========================

cat << 'EOF' > /etc/ppp/chap-secrets

vps_a_user   l2tpd   "vps_a_pass"   *

EOF


# ==========================
# NAT转发
# ==========================

iptables -t nat -F POSTROUTING

iptables -t nat -A POSTROUTING \
-s 10.10.99.0/24 \
-j MASQUERADE


# ==========================
# 保存iptables规则
# ==========================

netfilter-persistent save


# ==========================
# 重启服务
# ==========================

systemctl restart xl2tpd


# ==========================
# 查看日志
# ==========================

journalctl -u xl2tpd -f
