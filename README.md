# L2TP & NAT 部署脚本

两个脚本（原 B 脚本已删除），**都可以重复执行**：同一组参数再跑一遍不会重复添加、
不会覆盖已有配置、不会删你手工加过的东西。参数存在 `/etc/*.conf`，
第一次问一次，之后全自动。

两者**不会**跑在同一台机器上，互不干扰。

---

## 刚装好系统的服务器，能直接跑吗

**能。** 脚本自己装依赖、自己检查，不需要先手工 `apt install` 任何东西。

- `l2tp_deploy.sh` —— 装 `xl2tpd` + `iptables-persistent`
- `nat_a_entry.sh` —— 先确认 `iptables` / `netfilter-persistent` 在不在，缺就装
  （最小化安装的 Debian 不一定自带 iptables）

### 硬性要求

| 要求 | 说明 |
|---|---|
| Debian / Ubuntu | 走的 apt |
| systemd | 用 systemctl / journalctl |
| **KVM 或物理机** | L2TP 走内核态，要 `l2tp_ppp` 模块。**OpenVZ / 受限容器加载不了，起不来** |
| root | 两个脚本都会检查，不是 root 直接拒绝 |
| 内核 ≥ 4.9 | 只为 BBR；低了只是没加速，不影响 L2TP |
| 能连软件源 | 装包用 |

不是 KVM 也不用猜 —— 跑完自检那步会明确告诉你内核里有没有 `l2tp_ppp`。

### 一键执行的三种写法（第三种是坑）

```bash
# ✅ 进程替换：stdin 还是终端，脚本里的 read 能正常问你
bash <(curl -sL https://raw.githubusercontent.com/farmer718/L2TP/main/l2tp_deploy.sh)

# ✅ 带参数就没有 read 了，管道也安全
curl -sL https://raw.githubusercontent.com/farmer718/L2TP/main/l2tp_deploy.sh | bash -s 11

# ❌ 管道 + 不给参数：read 会去读脚本自身，行为错乱
curl -sL https://raw.githubusercontent.com/farmer718/L2TP/main/l2tp_deploy.sh | bash
```

第三种现在不会静默出错 —— 脚本检测到 stdin 不是终端又没有参数，会直接报错退出。

最小化系统如果连 `curl` 都没有，先 `apt-get install -y curl`（或者 `wget` 下来再跑）。

### 跑完会自检

结尾打印：服务 active / 端口监听 / `ip_forward` / NAT 规则 / unit 是否带 `Restart=always`，
有 ✘ 就以**非 0** 退出。不会再出现"打印了部署完成但其实没成"。

---

## 已经在跑老脚本的机器，直接跑新的会怎样

**直接一键跑就行，不用先手工准备什么。** 老机器上没有 `/etc/l2tp-deploy.conf`，
脚本会从现存的 `/etc/xl2tpd/xl2tpd.conf` 里**自动认出正在用的网段**，不需要你输入，
所以也不会填错。取值优先级：

```
命令行参数 > /etc/l2tp-deploy.conf > 现存 xl2tpd.conf 自动识别 > 问人
```

想换网段就显式传：`sudo ./l2tp_deploy.sh 12`（传了就以你传的为准）。

| 项目 | 结果 |
|---|---|
| 在线隧道 | ⚠️ **断一次**（几秒，客户端会自动重连）—— 换 native unit 必须重启 |
| `xl2tpd.conf` | 网段/端口不变（前提是 `VPN_ID` 填对），改写前备份到 `/var/backups/l2tp-deploy/` |
| `options.xl2tpd` | 多出 `mtu/mru 1420`，对实测的 1420 是零改动 |
| `chap-secrets` | ✅ 原样保留，不覆盖 |
| sysctl | 值相同，无变化。老脚本写在 `/etc/sysctl.conf` 的行留着，无害 |
| `/etc/init.d/xl2tpd` + `rc*.d` 软链 | 留着但失效（native unit 在 `/etc/systemd/system/` 里优先） |
| NAT 规则 | ⚠️ 老规则没带 `l2tp-deploy` 标记，认不出来 → **会多出一条重复的 MASQUERADE**，无害但重复，脚本会报出来并给出删除命令 |

那唯一会断的一下没法避免：`Restart=always` 的 native unit 要生效就得重启一次。
想先看清楚再动手，用 `sudo DRY_RUN=1 ./l2tp_deploy.sh 11` 只打印计划。

出问题要回滚：`/var/backups/l2tp-deploy/` 里是**第一次跑本脚本之前**的原件。

---

## L2TP VPN 一键部署（l2tp_deploy.sh）

基于 xl2tpd 的 L2TP 服务端，适用于 Debian / Ubuntu（需 systemd，需 KVM/物理机）。

### 用法

```bash
# 首次：交互式问 VPN_ID
bash <(curl -sL https://raw.githubusercontent.com/farmer718/L2TP/main/l2tp_deploy.sh)

# 重跑：读 /etc/l2tp-deploy.conf，全自动、幂等；配置没变时连隧道都不会断
sudo ./l2tp_deploy.sh

# 指定 / 更换 VPN_ID
sudo ./l2tp_deploy.sh 12

# 只看计划，不动手
sudo DRY_RUN=1 ./l2tp_deploy.sh
```

### 默认配置

| 项目 | 值 |
|------|-----|
| L2TP 端口 | **17001**（UDP，非标准 1701） |
| 本地 IP | 10.10.{VPN_ID}.1 |
| 分配 IP 范围 | 10.10.{VPN_ID}.10 - 10.10.{VPN_ID}.50 |
| MTU / MRU | 1420 |
| 用户名 | farmer |
| 密码 | chp1qaz!QAZ |

MTU 这条容易误会，单独说：**1400 不是 pppd 的默认值**，1500 才是。老脚本根本没写
`mtu`/`mru`，所以接口 MTU 是 `min(1500, 客户端在 LCP 里要的 MRU)`。线上实测：

```
ppp0  mtu 1420          ← 客户端自己要了 1420，所以早就不是 1500
/usr/sbin/pppd ... （命令行里没有任何 mtu 参数）
```

显式写死 `1420` 对现状是**零改动**，同时能挡住不自限的客户端 —— L2TP 封装后不限制
早晚撞 PMTU 黑洞（能拨上、小包通、大包卡死）。要改就动 `l2tp_deploy.sh` 顶部的 `MTU=`。

`/etc/ppp/chap-secrets` **只在不存在时写入**，重跑不会覆盖你手工加的账号。
想重置口令就先删掉这个文件再跑。

### 部署时做了什么（以及为什么）

- **换掉发行版的 sysv init 脚本，装 native systemd unit。**

  发行版 `/etc/init.d/xl2tpd` 的 stop 分支没有 `--retry`：发完 SIGTERM 立刻返回，
  不等进程退出。systemd 紧接着执行 start，此时旧进程还活着、pidfile 还在，
  `start-stop-daemon --start` 判定 "already running" 拒绝启动并返回 1；
  而那个脚本第 32 行有 `set -e`，于是整个 unit 变成 failed。
  sysv-generator 生成的 unit 又是 `Restart=no` + `KillMode=process` —— 不重试、不兜底，
  服务就此永久躺平，直到有人发现。

  这个竞态**只在服务被重启时触发**，所以全新部署（start）永远不会中招，
  重跑、自动升级、手工 restart 才会。native unit 用 `Type=simple` + `-D` 彻底绕开
  pidfile 和这个竞态，并带 `Restart=always`。

- **禁止 needrestart 重启 xl2tpd。**

  unattended-upgrades 装完包后，needrestart 会按库升级重启守护进程。
  它是上面那个竞态最稳定的触发源，每次都来一次。脚本写入
  `/etc/needrestart/conf.d/zz-xl2tpd-no-restart.conf` 把它排除。

- **内核参数写到 `/etc/sysctl.d/zz-l2tp.conf`，用 `sysctl --system` 加载。**

  `sysctl --system` 把 `sysctl.d/*`（含 `/usr/lib/sysctl.d/`）和 `/etc/sysctl.conf`
  汇成**一个按文件名排序的列表**依次应用，同名键后应用者胜。实测顺序：

  ```
  * Applying /usr/lib/sysctl.d/10-apparmor.conf ...
  * Applying /etc/sysctl.d/10-* ...
  * Applying /etc/sysctl.d/99-sysctl.conf ...   ← Ubuntu 上它是 /etc/sysctl.conf 的软链
  * Applying /etc/sysctl.conf ...               ← 最末又应用一次
  ```

  所以 `zz-` 排在 `99-` 之后能压过镜像自带的 `99-*`；但 `/etc/sysctl.conf` 是**最后
  一个应用的，它才是最终赢家** —— 如果那里面有冲突的值（比如 `ip_forward = 0`），
  `zz-` 挡不住。因此脚本不假设谁生效，而是加载完直接读**实际值**断言，
  不对就列出是哪些文件在抢。

- **NAT 规则只增不删**，绝不 `-F POSTROUTING`（那会连 docker 和其他转发规则一起清掉）。

### 客户端连接

系统自带 VPN 客户端，选 L2TP/IPSec（注意：本脚本只部署 L2TP，**不含 IPSec**）。
端口填 **17001**。

---

## NAT 转发（nat_a_entry.sh）

A 机器作为 NAT 入口，把 UDP 流量转给 B 机器。

```
客户端 → A(监听UDP端口) → DNAT + SNAT → B_IP:B_PORT
```

### 用法

```bash
sudo ./nat_a_entry.sh                      # 首次交互；之后读映射表全自动重铺
sudo ./nat_a_entry.sh 5000 1.2.3.4 6000    # 追加一条：A_PORT B_IP B_PORT
sudo ./nat_a_entry.sh --list               # 列出已有映射
sudo ./nat_a_entry.sh --remove 5000        # 删掉 A_PORT=5000 那条
```

映射表在 `/etc/l2tp-nat-a.mappings`，一行一条 `A_PORT B_IP B_PORT`。

### 规则是累加的

不同端口、不同目标各加一条，**互不覆盖、永久保留**。同一组参数重复执行不会重复添加。
重跑 = 把映射表整张重新铺一遍，防丢。

删规则只能走 `--remove`，脚本永远不会主动清掉你没让删的东西。

### B 机器：不需要执行脚本

A 已经做了 MASQUERADE，所以包到 B 的时候源已经是 **A 的公网 IP**：

```
A公网IP:随机端口  →  B_IP:B_PORT
```

只要 `B_PORT` 是 **B 本机在听的服务**（代理、落地服务等），包就投递给本地，
不过 FORWARD、不需要 SNAT —— **B 侧零配置**。所以 B 脚本已删除。

唯一例外是 `B_PORT` 不是本机服务、B 纯粹当路由器往外转。真遇到再单独处理。

### ⚠️ 会 `netfilter-persistent save`

不 save 的话规则**一重启就全没了** —— 典型症状是"配完通、重启后失效"，
不报错，只能靠发现。脚本结尾会自检规则有没有真的落到 `/etc/iptables/rules.v4`。

---

## Panabit OEM 安装包

```bash
wget https://raw.githubusercontent.com/farmer718/L2TP/main/PanabitFREE_TANGr7p9_20260622_Linux3.tar.gz
```
