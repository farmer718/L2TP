#!/bin/bash

# ==========================
# 输入VPN_ID
# ==========================

read -p "请输入 VPN_ID (1-200): " VPN_ID


# ==========================
# VPN_ID校验
# ==========================

if ! [[ "$VPN_ID" =~ ^[0-9]+$ ]]; then
    echo "错误: VPN_ID必须是数字"
    exit 1
fi


if [ "$VPN_ID" -lt 1 ] || [ "$VPN_ID" -gt 200 ]; then
    echo "错误: VPN_ID范围必须是1-200"
    exit 1
fi


# ==========================
# 生成网络参数
# ==========================

VPN_NET="10.10.${VPN_ID}"

LOCAL_IP="${VPN_NET}.1"

IP_RANGE="${VPN_NET}.10-${VPN_NET}.50"

VPN_CIDR="${VPN_NET}.0/24"


echo "=========================="
echo "VPN网段: ${VPN_CIDR}"
echo "服务端IP: ${LOCAL_IP}"
echo "客户端范围: ${IP_RANGE}"
echo "=========================="


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
# xl2tpd配置
# ==========================

cat << EOF > /etc/xl2tpd/xl2tpd.conf

[global]
port = 1701

[lns default]
ip range = ${IP_RANGE}
local ip = ${LOCAL_IP}
require authentication = yes
name = l2tpd
pppoptfile = /etc/ppp/options.xl2tpd

EOF


# ==========================
# PPP配置
# ==========================

cat << EOF > /etc/ppp/options.xl2tpd

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

cat << EOF > /etc/ppp/chap-secrets

farmer   l2tpd   "chp1qaz!QAZ"   *

EOF


# ==========================
# NAT转发
# ==========================

iptables -t nat -F POSTROUTING


iptables -t nat -A POSTROUTING \
-s ${VPN_CIDR} \
-j MASQUERADE


# ==========================
# 保存iptables规则
# ==========================

netfilter-persistent save


# ==========================
# 重启L2TP服务
# ==========================

systemctl restart xl2tpd


echo ""
echo "=========================="
echo "L2TP部署完成"
echo ""
echo "VPN网段: ${VPN_CIDR}"
echo "服务端IP: ${LOCAL_IP}"
echo "客户端池: ${IP_RANGE}"
echo ""
echo "香港Panabit拨号时:"
echo "客户端IP将来自 ${IP_RANGE}"
echo "=========================="


# ==========================
# 查看日志
# ==========================

journalctl -u xl2tpd -f
