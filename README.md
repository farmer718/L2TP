# L2TP & NAT 部署脚本

## L2TP VPN 一键部署

基于 xl2tpd 的 L2TP VPN 自动部署脚本，适用于 Debian/Ubuntu 系统。

### 功能

- 安装 xl2tpd 及依赖
- 开启 IP 转发
- 启用 TCP BBR 拥塞控制 + fq 队列
- 配置 xl2tpd 服务端
- 配置 PPP 认证
- 设置 NAT 转发规则
- 保存 iptables 规则并启动服务

### 使用方法

一键执行：

```bash
bash <(curl -sL https://raw.githubusercontent.com/farmer718/L2TP/main/l2tp_deploy.sh)
```

或手动下载执行：

```bash
chmod +x l2tp_deploy.sh
sudo ./l2tp_deploy.sh
```

### 默认配置

| 项目 | 值 |
|------|-----|
| L2TP 端口 | 1701 |
| 本地 IP | 10.10.{VPN_ID}.1 |
| 分配 IP 范围 | 10.10.{VPN_ID}.10 - 10.10.{VPN_ID}.50 |
| 用户名 | farmer |
| 密码 | chp1qaz!QAZ |

### 自定义

脚本运行时会提示输入 VPN_ID (1-200)，自动生成对应网段。如需修改用户名密码，请编辑脚本中 `/etc/ppp/chap-secrets` 部分。

### 客户端连接

使用系统自带 VPN 客户端，选择 L2TP/IPSec（注意：本脚本仅部署 L2TP，不含 IPSec）。

---

## NAT 转发（A 通过 B 上网）

A 机器作为 NAT 入口，将流量转发到 B 机器（香港出口），实现通过 B 上网。当前脚本为 **UDP** 转发。

### 架构

```
客户端 → A(监听UDP端口) → DNAT/SNAT → B(香港出口) → 互联网
```

### A 机器配置（nat_a_entry.sh）

在 A 机器上执行，配置 UDP DNAT + SNAT 转发规则。

一键执行：

```bash
bash <(curl -sL https://raw.githubusercontent.com/farmer718/L2TP/main/nat_a_entry.sh)
```

运行时需输入：
- A 监听 UDP 端口
- B 香港公网 IP
- B 目标 UDP 端口

### B 机器配置（nat_b_exit.sh）

在 B 机器（香港）上执行，配置 UDP 出口 SNAT 和转发规则。

一键执行：

```bash
bash <(curl -sL https://raw.githubusercontent.com/farmer718/L2TP/main/nat_b_exit.sh)
```

运行时需输入：
- B 公网出口网卡名称（如 eth0）
