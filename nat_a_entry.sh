#!/bin/bash

echo "================================"
echo " A机器 UDP NAT入口配置"
echo " DNAT + SNAT"
echo "================================"

if [ "$EUID" -ne 0 ]; then
    echo "请使用root执行"
    exit 1
fi


read -p "请输入A监听UDP端口: " A_PORT

read -p "请输入B香港公网IP: " B_IP

read -p "请输入B目标UDP端口: " B_PORT


# 端口检查
if ! [[ "$A_PORT" =~ ^[0-9]+$ ]] || \
   ! [[ "$B_PORT" =~ ^[0-9]+$ ]]; then
    echo "端口格式错误"
    exit 1
fi


# IP检查
if ! [[ "$B_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "IP格式错误"
    exit 1
fi


echo ""
echo "=============================="
echo "配置确认"
echo "A UDP端口 : $A_PORT"
echo "转发目标  : $B_IP:$B_PORT"
echo "=============================="

read -p "确认执行? (y/n): " CONFIRM

if [ "$CONFIRM" != "y" ]; then
    exit 0
fi



echo "开启IP转发..."

grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || \
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

sysctl -w net.ipv4.ip_forward=1



echo "添加UDP DNAT规则..."

iptables -t nat -A PREROUTING \
-p udp \
--dport $A_PORT \
-j DNAT \
--to-destination $B_IP:$B_PORT



echo "添加UDP SNAT规则..."

iptables -t nat -A POSTROUTING \
-p udp \
-d $B_IP \
--dport $B_PORT \
-j MASQUERADE



echo "添加FORWARD规则..."

iptables -A FORWARD \
-p udp \
-d $B_IP \
--dport $B_PORT \
-j ACCEPT


iptables -A FORWARD \
-p udp \
-s $B_IP \
--sport $B_PORT \
-j ACCEPT



echo ""
echo "================================"
echo "A UDP NAT配置完成"
echo "================================"

iptables -t nat -L -n --line-number
