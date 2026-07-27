#!/bin/bash

echo "================================"
echo " B机器 UDP出口配置"
echo " SNAT"
echo "================================"


if [ "$EUID" -ne 0 ]; then
    echo "请使用root执行"
    exit 1
fi


read -p "请输入B公网出口网卡名称(例如eth0): " WAN_IF


if ! ip link show $WAN_IF >/dev/null 2>&1
then
    echo "网卡不存在: $WAN_IF"
    exit 1
fi


echo ""
echo "出口网卡:"
echo "$WAN_IF"


read -p "确认执行? (y/n): " CONFIRM


if [ "$CONFIRM" != "y" ]; then
    exit 0
fi



echo "开启IP转发..."

grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || \
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

sysctl -w net.ipv4.ip_forward=1



echo "添加UDP出口SNAT..."

iptables -t nat -A POSTROUTING \
-p udp \
-o $WAN_IF \
-j MASQUERADE



echo "允许UDP转发..."

iptables -A FORWARD \
-p udp \
-o $WAN_IF \
-j ACCEPT


iptables -A FORWARD \
-p udp \
-i $WAN_IF \
-m conntrack \
--ctstate ESTABLISHED,RELATED \
-j ACCEPT



echo ""
echo "================================"
echo "B UDP NAT配置完成"
echo "================================"


iptables -t nat -L -n --line-number
