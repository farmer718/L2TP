# L2TP & NAT 部署脚本

两个脚本，各一条命令，重跑幂等。

落地脚本**每次运行都会停下来问一次 VPN_ID**：直接回车 = 沿用当前网段（就是幂等重跑），
输个数字 = 换网段。不想要这一步就在命令行上直接给，那就不会再问。

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
| 能连软件源 | 装包用 |

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

命令行给了参数（`sudo ./l2tp_deploy.sh 12`）就不再问。换网段**不会删旧网段的 NAT 规则**。

### 跑完会自检

服务 active / 端口监听 / `ip_forward` / NAT 规则 / unit 是否带 `Restart=always` /
**`chap-secrets` 里有没有账号**，有 ✘ 就以**非 0** 退出。
不会再出现"打印了部署完成但其实没成"。

最后那条是 2026-09-28 补的。真正的修复在写账号那一步（改成按有效账号数判、没账号就一定写）；
自检这条是**回归防线**，不是这次的保险 —— 写账号失败时脚本会当场非 0 退出，自检根本轮不到跑。
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

## 已经在跑老脚本的机器，直接跑新的会怎样

**直接一键跑就行。** 老机器上没有 `/etc/l2tp-deploy.conf`，脚本会从现存的
`/etc/xl2tpd/xl2tpd.conf` 里自动认出正在用的网段，摆成提问的默认值 —— **回车即保持原样**，
所以不会填错。想换网段就当场输数字，或者显式传：`sudo ./l2tp_deploy.sh 12`。

（以前是"认出来就直接用、压根不问"。改成必问是因为换网段会换掉客户端的 IP，
这种事让脚本替你决定不合适。）

| 项目 | 结果 |
|---|---|
| 在线隧道 | ⚠️ **断一次**（几秒，客户端会自动重连）—— 换 native unit 必须重启 |
| `xl2tpd.conf` | 网段/端口不变，改写前备份到 `/var/backups/l2tp-deploy/` |
| `options.xl2tpd` | 多出 `mtu/mru 1420`，对实测的 1420 是零改动 |
| `chap-secrets` | ✅ 有账号就**原样保留、一个字不动**；一个账号都没有才补上默认的 |
| sysctl | 值相同，无变化。老脚本写在 `/etc/sysctl.conf` 的行留着，无害 |
| `/etc/init.d/xl2tpd` + `rc*.d` 软链 | 留着但失效（`/etc/systemd/system/` 里的 native unit 优先） |
| NAT 规则 | ⚠️ 老规则没带 `l2tp-deploy` 标记，认不出来 → **会多出一条重复的 MASQUERADE**，无害，脚本会报出来并给出删除命令 |

那唯一会断的一下没法避免：`Restart=always` 的 native unit 要生效就得重启一次。
想先看清楚再动手：`sudo DRY_RUN=1 ./l2tp_deploy.sh 11` 只打印计划。

出问题要回滚：`/var/backups/l2tp-deploy/` 里是**第一次跑本脚本之前**的原件。

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

## 客户端连接

系统自带 VPN 客户端，选 L2TP/IPSec（注意：本脚本只部署 L2TP，**不含 IPSec**）。
端口填 **17001**。

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
