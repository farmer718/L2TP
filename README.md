# L2TP VPN 一键部署脚本

基于 xl2tpd 的 L2TP VPN 自动部署脚本，适用于 Debian/Ubuntu 系统。

## 功能

- 安装 xl2tpd 及依赖
- 开启 IP 转发
- 启用 TCP BBR 拥塞控制 + fq 队列
- 配置 xl2tpd 服务端
- 配置 PPP 认证
- 设置 NAT 转发规则
- 保存 iptables 规则并启动服务

## 使用方法

```bash
chmod +x l2tp_deploy.sh
sudo ./l2tp_deploy.sh
```

## 默认配置

| 项目 | 值 |
|------|-----|
| L2TP 端口 | 1701 |
| 本地 IP | 10.10.99.1 |
| 分配 IP 范围 | 10.10.99.10 - 10.10.99.50 |
| 用户名 | vps_a_user |
| 密码 | vps_a_pass |

## 自定义

部署前请修改脚本中的以下内容：

- `/etc/ppp/chap-secrets` 中的用户名和密码
- `/etc/xl2tpd/xl2tpd.conf` 中的 IP 范围

## 客户端连接

使用系统自带 VPN 客户端，选择 L2TP/IPSec（注意：本脚本仅部署 L2TP，不含 IPSec）。
