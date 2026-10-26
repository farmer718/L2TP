# L2TP & NAT 部署脚本

两个脚本，各一条命令。**落地脚本是先删后装**：跑一次 = 把这台机器上的 L2TP / xray
配置全部删掉，再从零装一遍。在线隧道会断，跑完即用，不留备份。

落地脚本**每次运行都会停下来问一次 VPN_ID**：直接回车 = 沿用当前网段，
输个数字 = 换网段（旧网段的 NAT 规则会被一起删掉）。不想要这一步就在命令行上直接给。

## ① 落地机 —— L2TP 服务端

```bash
bash <(curl -sL https://raw.githubusercontent.com/farmer718/L2TP/main/l2tp_deploy.sh)
```

## ② 中转机 —— UDP 端口转发

```bash
bash <(curl -sL https://raw.githubusercontent.com/farmer718/L2TP/main/nat_a_entry.sh)
```

**这两个不会跑在同一台机器上** —— 落地机跑 ①，中转机跑 ②。

跑过老脚本的机器也是直接跑这一条，**不需要先准备什么**：脚本会自己认出正在用的网段，
填在提问的默认值里，你回车就行。

### 前提

| 要求 | 说明 |
|---|---|
| Debian / Ubuntu | 走 apt；需要 systemd |
| pppd + `/dev/ppp` | `apt` 装 `xl2tpd` 时会带上 `ppp`。**不需要** `l2tp_ppp` 内核模块 |
| root | 脚本会检查，不是 root 直接拒绝 |
| 能连软件源 | 装包用（`curl` / `unzip` 也会一起装上） |
| 能连 GitHub | 只在 `/opt/xray-redir/xray` 缺失或版本不是 26.3.27 时才下载（~36MB，`XTLS/Xray-core`） |

内核 ≥4.9 才有 BBR；低了只是没加速，不影响 L2TP。

### 默认参数

| 项目 | 值 |
|---|---|
| L2TP 端口 | **17001**（UDP，非标准 1701） |
| 本地 IP | 10.10.{VPN_ID}.1 |
| 分配 IP 范围 | 10.10.{VPN_ID}.10 - 10.10.{VPN_ID}.50 |
| MTU / MRU | 1420 |
| 用户名 | farmer |
| 密码 | chp1qaz!QAZ |
| xray 版本 | 26.3.27，装在 `/opt/xray-redir` |
| 接管入口 | TCP 12345（REDIRECT）/ UDP 12346（TPROXY）→ `freedom` 直出 |

`VPN_ID` 决定用哪个 `10.10.x.0/24` 网段。**每次运行都会问一次**，默认值按这个顺序取：

```
命令行参数  >  /etc/l2tp-deploy.conf  >  现存 xl2tpd.conf 自动识别
```

提问时长这样，直接回车用默认值，输数字就换网段：

```
 当前 VPN_ID : 12   →   网段 10.10.12.0/24
 来源        : 现存 xl2tpd.conf（自动识别）
 直接回车保持不变，输入数字则换网段
 VPN_ID (1-200):
```

命令行给了参数（`sudo ./l2tp_deploy.sh 12`）就不再问。换网段**会删掉旧网段的 NAT 规则**
—— 这台机器上的旧配置一律不留。

### 跑完会自检

L2TP 那层：服务 active / 端口监听 / `ip_forward` / NAT 规则 / unit 是否带 `Restart=always` /
unit 是否声明 `RuntimeDirectory=xl2tpd` / **`chap-secrets` 里有没有账号**。

xray 那层：服务 active / 12345 与 12346 在听 / nat 有 REDIRECT / mangle 有 TPROXY /
**`ip rule` 里有 `fwmark 0x1 lookup 100`** / table 100 有 local 路由 /
**规则有没有真的落到 `/etc/iptables/rules.v4`** / networkd 那个开关真的生效了没有。

有 ✘ 就以**非 0** 退出。不会再出现"打印了部署完成但其实没成"。

后两条是**回归防线**，不是当下的保险 —— 它们要防的 bug 都在更早的写入步骤里，
那一步失败时 `set -e` 会当场非 0 退出，自检根本轮不到跑（已实测）。
具体分量：`chap-secrets` 那条 2026-09-28 补，`RuntimeDirectory` 那条 2026-10-07 补。
它防的是将来有人再往写入那步加"跳过条件"，也就是这个 bug 的原始形状。
背景见下面「chap-secrets 那个坑」。

---
---

# 细节（跑之前不用看）

## 三种执行写法，第三种是坑

```bash
# ✅ 进程替换：stdin 还是终端，脚本里的 read 能正常问你
bash <(curl -sL https://raw.githubusercontent.com/farmer718/L2TP/main/l2tp_deploy.sh)

# ✅ 带参数：脚本看 stdin 不是终端就不问了，管道也安全
curl -sL https://raw.githubusercontent.com/farmer718/L2TP/main/l2tp_deploy.sh | bash -s 11

# ❌ 管道 + 不给参数：read 会去读脚本自身，行为错乱
curl -sL https://raw.githubusercontent.com/farmer718/L2TP/main/l2tp_deploy.sh | bash
```

第三种现在不会静默出错 —— 检测到 stdin 不是终端又没参数，会直接报错退出。

给参数必须用 `| bash -s 11` 这种写法。`bash <(curl ...) 11` **不行** —— bash 会把
`11` 当成另一个脚本文件名去读，参数根本传不进去。

最小化系统如果连 `curl` 都没有，先 `apt-get install -y curl`（或 `wget` 下来再跑）。

## 已经在跑的机器上重跑会怎样

**先删后装。** 不管这台机器上装的是哪个版本的脚本，新脚本都先把它清空：

| 删掉的 | 说明 |
|---|---|
| `xray-redir` / `xl2tpd` 两个服务 | 停掉，取消 enable |
| iptables 里的 REDIRECT / TPROXY / DROP / 旧网段 MASQUERADE | 用旧防火墙脚本自己的 `remove` 精确删，不 flush 任何链 |
| `/opt/xray-redir` | 整个目录，连 xray 内核一起删，重装时重新下载 |
| 旧 unit / `xl2tpd.conf` / `options.xl2tpd` / 旧 needrestart 黑名单 / 旧 sysctl | 全部删掉重写 |

网段从现存 `xl2tpd.conf` 里认出来当提问的默认值，回车即沿用。

**唯一不删的是 `/etc/ppp/chap-secrets`** —— 里面是账号密码，不是拓扑状态，
删了就得知道原账号才恢复得回来。有有效账号就一个字不动，一个账号都没有才写默认账号。

代价：**在线隧道断一次**（几秒，客户端会自动重连），跑的那一刻正在传的连接也会断。
脚本每次都重启服务，不判断配置有没有变。想先看清楚：`sudo DRY_RUN=1 ./l2tp_deploy.sh 11`。

没有备份，没有回滚目录。要换什么就重跑。

## chap-secrets 那个坑（2026-09-28 修）

**症状极有迷惑性**：服务 `active`、UDP 17001 在听、`ip_forward=1`、NAT 规则在位、
自检全绿 —— 但客户端就是连不上，反复重拨，一次都分不到 IP。日志里是：

```
pppd: The remote system is required to authenticate itself
pppd: but I couldn't find any suitable secret (password) for it to use to do so.
```

**原因**：`Debian`/`Ubuntu` 的 `ppp` 包装完就**自带**一份 `/etc/ppp/chap-secrets`，
里面只有两行注释 + 两个空行。旧版脚本判断的是"文件不存在或是空的才写"，
而这份自带文件是 80 字节、非空 —— 于是**永远跳过写入，一个账号都没有**。
每一台全新机器都会中招；老脚本部署过的机器不会，因为账号早就在了。

**现在的行为**：按**有效账号数**判（grep 掉注释和空行）。
有账号 → 一个字不动，绝不覆盖你手工加的；一个都没有 → 追加默认账号 `farmer`。
这就是修复本身 —— 全新机器上那个账号**一定会被写上**。
自检里另加了一条账号检查当回归防线（详见上面"跑完会自检"那节说明它的分量）。

手工补（不想重跑脚本的话）：

```bash
echo 'farmer   l2tpd   "chp1qaz!QAZ"   *' >> /etc/ppp/chap-secrets
chmod 600 /etc/ppp/chap-secrets
```

改完不用重启 xl2tpd —— pppd 每次拨号都重新读这个文件。

## l2tp_deploy.sh 具体做了什么

- **换掉发行版的 sysv init 脚本，装 native systemd unit。**

  发行版 `/etc/init.d/xl2tpd` 的 stop 分支没有 `--retry`：发完 SIGTERM 立刻返回，不等
  进程退出。systemd 紧接着执行 start，此时旧进程还活着、pidfile 还在，
  `start-stop-daemon --start` 判定 "already running" 拒绝启动并返回 1；而那个脚本第 32
  行有 `set -e`，于是整个 unit 变成 failed。sysv-generator 生成的 unit 又是
  `Restart=no` + `KillMode=process` —— 不重试、不兜底，**服务就此永久躺平，直到有人发现**。

  这个竞态**只在服务被重启时触发**，所以全新部署（start）永远不会中招；重跑、自动升级、
  手工 restart 才会。native unit 用 `Type=simple` + `-D` 彻底绕开 pidfile 和这个竞态，
  并带 `Restart=always`。

  换 unit 时还带出过第二个坑（2026-10-07 在 103.197.211.71 上踩实，`up 13 min`
  就是重启计数 54 次）：**unit 必须声明 `RuntimeDirectory=xl2tpd`。**
  `/var/run` 是指向 `/run` 的软链、而 `/run` 是 tmpfs，重启即清空；
  `/var/run/xl2tpd` 这个目录原本由发行版 init 脚本每次 start 时 `mkdir -p`，
  native unit 把它顶掉之后就再没人建了。缺了它的症状是
  `open_controlfd: Unable to open /var/run/xl2tpd/l2tp-control for reading.`，
  退出码 1，被 `Restart=always` + `StartLimitIntervalSec=0` 顶成每 3 秒一次的死循环。

  **形状是"装完全绿、重启即死"**：刚装完自检每一项都是真的（目录还在），
  唯独重启后服务再也起不来。所以自检里加了一条专门查 unit 有没有声明它 ——
  这条查的是「重启之后还活着」，不是「现在活着」。

- **禁止 needrestart 重启 xl2tpd。**

  unattended-upgrades 装完包后，needrestart 会按库升级重启守护进程。它是上面那个竞态最
  稳定的触发源，每次都来一次。脚本写入 `/etc/needrestart/conf.d/zz-xl2tpd-no-restart.conf`
  把它排除。

- **装包时把 debconf 和 needrestart 的弹窗全关掉。**

  新机器上 `apt` 会弹三个窗口：前两个是 `iptables-persistent` 问要不要保存 IPv4/IPv6
  规则（默认就是 Yes，回车即可）；**第三个是 needrestart 的「Which services should be
  restarted?」多选框，它已经替你勾好了它想重启的服务，回车 = 让它们全重启** —— 如果列表里
  有 xl2tpd，走的就是上面那个没有 `--retry` 的分支，而此刻 native unit 还没装上。
  脚本用 `DEBIAN_FRONTEND=noninteractive` 关掉前两个，`NEEDRESTART_SUSPEND=1` 关掉第三个
  （它不是普通 debconf 提问，非交互模式下 debconf 会拿 needrestart 预置的答案直接返回，
  等于"不问、静默重启"，所以 `DEBIAN_FRONTEND` 单独挡不住）。

- **内核参数写到 `/etc/sysctl.d/zz-l2tp.conf`，用 `sysctl --system` 加载。**

  `sysctl --system` 把 `sysctl.d/*`（含 `/usr/lib/sysctl.d/`）和 `/etc/sysctl.conf` 汇成
  **一个按文件名排序的列表**依次应用，同名键后应用者胜。实测顺序：

  ```
  * Applying /usr/lib/sysctl.d/10-apparmor.conf ...
  * Applying /etc/sysctl.d/10-* ...
  * Applying /etc/sysctl.d/99-sysctl.conf ...   ← Ubuntu 上它是 /etc/sysctl.conf 的软链
  * Applying /etc/sysctl.conf ...               ← 最末又应用一次
  ```

  所以 `zz-` 能压过镜像自带的 `99-*`；但 `/etc/sysctl.conf` 是**最后一个应用的，它才是
  最终赢家** —— 那里面有冲突的值（比如 `ip_forward = 0`）时 `zz-` 挡不住。因此脚本不假设
  谁生效，而是加载完直接读**实际值**断言，不对就列出是哪些文件在抢。

- **`mtu/mru` 显式写 1420。**

  pppd 默认是 1500，接口 MTU 实际是 `min(1500, 客户端在 LCP 里要的 MRU)`，线上实测客户端
  要的就是 1420 —— 所以写死 1420 对现状是**零改动**，同时能挡住不自限的客户端
  （L2TP 封装后不限 MTU 早晚撞 PMTU 黑洞：能拨上、小包通、大包卡死）。要改就动脚本顶部的 `MTU=`。

- **NAT 规则只增不删**，绝不 `-F POSTROUTING`（那会连 docker 和其他转发规则一起清掉）。

- **部署 xray 接管层，把隧道里的流量全部重新发起。**

  两个 `dokodemo-door` 入口 + 一个 `freedom` 出站。TCP 靠 `nat REDIRECT` → 12345，
  UDP 靠 `mangle TPROXY --on-port 12346 --tproxy-mark 0x1/0x1` → 12346。
  客户端发什么，落地机就用自己的协议栈重新发起一遍，所以多个客户端在对面看来是同一台主机。

  UDP 必须用 TPROXY，不能用 REDIRECT —— REDIRECT 不给原始目的地址，`followRedirect`
  就无从得知该连哪儿。TPROXY 又依赖两条手工状态：`ip rule add fwmark 1 lookup 100`
  和 `ip route add local 0.0.0.0/0 dev lo table 100`。

  **2026-10-22 的故障就出在这里。** unattended-upgrade 升 liblzma5 触发 needrestart
  重启了 systemd-networkd，而 systemd 255 的 networkd 默认
  `ManageForeignRoutingPolicyRules=yes` —— 启动时把"外来"策略规则删了。
  table 100 的路由没被删，于是只剩"路由对、规则没了"的半死状态：包被 mark 了却没有
  规则去查 table 100，从主表用公网地址出去，回包对不上。表现是 **UDP 全死、TCP 全活**
  （TCP 走 iptables REDIRECT，networkd 不碰 iptables），和 DNS 故障长得一模一样。

  脚本把 `ManageForeignRoutingPolicyRules=no` 写进 networkd 配置。**写完不用重启
  networkd** —— 规则只在 networkd 启动那一刻才会被删，而配置是每次启动都读的，
  文件写下去，"下一次启动"这个点就已经堵住了，不管那次启动是升级触发还是重启触发。
  想亲眼看：`systemctl restart systemd-networkd` 之后 `ip rule show` 里那条还在不在。

- **重启后照样生效，靠三件事叠起来。**

  ① iptables 规则落 `/etc/iptables/rules.v4`，开机由 netfilter-persistent 恢复；
  ② `ip rule` / table 100 不在 iptables 里，只能由 `xray-redir` 的 `ExecStartPre`
     在每次启动时补 —— 所以它带 `Restart=always` + `StartLimitIntervalSec=0`；
  ③ networkd 不会再清理它。

  `netfilter-persistent save` 必须排在 xray 铺规则**之后**，否则 rules.v4 里没有接管规则，
  开机窗口内流量会直接 MASQUERADE 出去 —— 那是漏，不是断。

## 机器上已经装着 xray / sing-box 会怎样

**内核共存没问题。** 本脚本的 xray 放在 `/opt/xray-redir/xray`，unit 叫 `xray-redir`，
跟系统的 `xray.service` / `sing-box.service`、跟 `/usr/local/bin/xray` 各过各的，
互不覆盖、互不停止。

会撞上的只有三件事：

| 冲突 | 后果 | 脚本怎么处理 |
|---|---|---|
| 12345 / 12346 / 17001 被占 | `xray-redir` 起不来；它带 `Restart=always` + `StartLimitIntervalSec=0`，会每 2 秒重启一次永远刷日志 | **擦除之前**就检查，撞了就退出，什么都不动 |
| 已有针对同一网段的 TPROXY / REDIRECT | iptables 顺序决定谁吃流量，可能双层接管或漏接 | 不自动处理 |
| 已有 `fwmark 1 lookup 100` | 本脚本会往 table 100 补 `local default dev lo`，把原有的 tun 默认路由顶掉 | 擦除后检测到就报出来，并把 table 100 打出来 |

第三条最阴 —— **sing-box 的 tun 默认就是 `fwmark 1` + `table 100`**。跑之前先看一眼：

```bash
ss -lntup | grep -E ':(12345|12346|17001)[[:space:]]'
ip rule show | grep fwmark
ip route show table 100
```

前两条干净（端口没人在听、`ip rule` 里没有 fwmark、table 100 是空的）就可以放心跑。

## 客户端连接

系统自带 VPN 客户端，选 L2TP/IPSec（注意：本脚本只部署 L2TP，**不含 IPSec**）。
端口填 **17001**。

拨上之后，客户端发的所有 IPv4 流量都会被 xray 接住，从这台落地机重新发起。
例外只有两条：发给本机的（`addrtype LOCAL`）、发给 `10.0.0.0/8` 的直连，不进 xray。

（不做「本机所在公网段」这条例外 —— 落地机可能只有上游交换机分配的私网地址，
那时推出来的网段要么是空的、要么跟这里无关。发给本机自己的流量 `addrtype LOCAL`
已经挡住了。）

排障先看这几条：

```bash
ip rule show | grep fwmark                  # 必须有 0x1 lookup 100
ip route show table 100                     # 必须有 local default dev lo
/usr/local/sbin/l2tp-redir-firewall.sh status
journalctl -u xray-redir -n 30 --no-pager
```

**别用 `ss` 看推流那根连接。** TPROXY 转发的 UDP 会话不出现在 `ss` 里，
要看流量用 `tcpdump -ni <网卡> 'udp and host <ingest>'`，或者
`journalctl -u xray-redir | grep accepted`。

## nat_a_entry.sh 用法

```
客户端 → A(监听UDP端口) → DNAT + SNAT → B_IP:B_PORT
```

```bash
sudo ./nat_a_entry.sh                      # 首次交互；之后读映射表全自动重铺
sudo ./nat_a_entry.sh 5000 1.2.3.4 6000    # 追加一条：A_PORT B_IP B_PORT
sudo ./nat_a_entry.sh --list               # 列出已有映射
sudo ./nat_a_entry.sh --remove 5000        # 删掉 A_PORT=5000 那条
```

映射表在 `/etc/l2tp-nat-a.mappings`，一行一条 `A_PORT B_IP B_PORT`。

### 规则是累加的

不同端口、不同目标各加一条，**互不覆盖、永久保留**。同一组参数重复执行不会重复添加。
重跑 = 把映射表整张重新铺一遍，防丢。删规则只能走 `--remove`，脚本永远不会主动清掉
你没让删的东西。

### B 机器：不需要执行脚本

A 已经做了 MASQUERADE，所以包到 B 的时候源已经是 **A 的公网 IP**（`A公网IP:随机端口`）。
只要 `B_PORT` 是 **B 本机在听的服务**，包就投递给本地，不过 FORWARD、不需要 SNAT ——
**B 侧零配置**。唯一例外是 `B_PORT` 不是本机服务、B 纯粹当路由器往外转，真遇到再单独处理。

### ⚠️ 会 `netfilter-persistent save`

不 save 的话规则**一重启就全没了** —— 典型症状是"配完通、重启后失效"，不报错，只能靠发现。
脚本结尾会自检规则有没有真的落到 `/etc/iptables/rules.v4`。

---

## Panabit OEM 安装包

```bash
wget https://raw.githubusercontent.com/farmer718/L2TP/main/PanabitFREE_TANGr7p9_20260622_Linux3.tar.gz
```
