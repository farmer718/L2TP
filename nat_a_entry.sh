#!/bin/bash

echo "=============================="
echo " A机器 NAT入口配置"
echo " DNAT + SNAT"
echo "=============================="

# root检查
if [ "$EUID" -ne 0 ]; then
    echo "请使用root执行"
    exit 1
fi


read -p "请输入A监听端口(客户访问端口): " A_PORT

read -p "请输入B香港公网IP: " B_IP

read -p "请输入B目标端口: " B_PORT


# 端口检查
if ! [[ "$A_PORT" =~ ^[0-9]+$ ]] || \
   ! [[ "$B_PORT" =~ ^[0-9]+$ ]]; then
    echo "端口必须是数字"
    exit 1
fi


# IP简单检查
if ! [[ "$B_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "IP格式错误"
    exit 1
fi


echo ""
echo "配置如下:"
echo "A端口:"
echo $A_PORT

echo "转发到:"
echo $B_IP:$B_PORT

read -p "确认执行? (y/n): " CONFIRM

if [ "$CONFIRM" != "y" ]; then
    exit 0
fi



echo "开启IP转发..."

cat >> /etc/sysctl.conf <<EOF
net.ipv4.ip_forward=1
EOF

sysctl -p



echo "添加DNAT规则..."

iptables -t nat -A PREROUTING \
-p tcp \
--dport $A_PORT \
-j DNAT \
--to-destination $B_IP:$B_PORT



echo "添加SNAT规则..."

iptables -t nat -A POSTROUTING \
-p tcp \
-d $B_IP \
--dport $B_PORT \
-j MASQUERADE



echo "放行FORWARD..."

iptables -A FORWARD \
-p tcp \
-d $B_IP \
--dport $B_PORT \
-j ACCEPT


iptables -A FORWARD \
-p tcp \
-s $B_IP \
--sport $B_PORT \
-j ACCEPT



echo ""
echo "=============================="
echo "A配置完成"
echo "=============================="

iptables -t nat -L -n --line-number
