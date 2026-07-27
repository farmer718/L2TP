#!/bin/bash

echo "=============================="
echo " B机器 香港出口配置"
echo " SNAT出口"
echo "=============================="


if [ "$EUID" -ne 0 ]; then
    echo "请使用root执行"
    exit 1
fi


read -p "请输入B公网出口网卡名称(例如eth0): " WAN_IF


# 检查网卡

if ! ip link show $WAN_IF >/dev/null 2>&1
then
    echo "网卡不存在: $WAN_IF"
    exit 1
fi



echo ""
echo "出口网卡:"
echo $WAN_IF


read -p "确认执行? (y/n): " CONFIRM


if [ "$CONFIRM" != "y" ]; then
    exit 0
fi



echo "开启IP转发..."

cat >> /etc/sysctl.conf <<EOF
net.ipv4.ip_forward=1
EOF

sysctl -p



echo "添加出口SNAT..."

iptables -t nat -A POSTROUTING \
-o $WAN_IF \
-j MASQUERADE



echo "允许转发..."

iptables -A FORWARD \
-i $WAN_IF \
-m state \
--state ESTABLISHED,RELATED \
-j ACCEPT


iptables -A FORWARD \
-o $WAN_IF \
-j ACCEPT



echo ""
echo "=============================="
echo "B配置完成"
echo "=============================="


iptables -t nat -L -n --line-number
