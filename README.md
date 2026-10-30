## 客户端下载

官方下载地址 [https://github.com/2dust/v2rayN/releases/](https://github.com/2dust/v2rayN/releases/)

Reality 要 v2rayN 6.x / v2rayNG 1.8+；老版本能导入但连不上







## vultr_xray



在 Vultr 上手动开一台 Ubuntu，跑一条命令装好 **Xray（VLESS + Vision + Reality）**，
拿到一条能直接导入 v2rayN 的 `vless://` 链接。

不是 WireGuard / OpenVPN 那种内核层 VPN，是代理协议（客户端当系统代理 / TUN 用，
体感一样，但协议不同）。

| 目录 | 干什么 |
|---|---|
| [`step_vps_install/`](step_vps_install/) | 在服务器上跑，装好 Xray 并打印节点链接 |
| [`ping_vps/`](ping_vps/) | 在本地跑，判断这个 IP 从国内还能不能连 |
| [`gen_ssh_key/`](gen_ssh_key/) | 在本地跑，生成 ed25519 密钥对（第 1 步，只做一次） |

---

## 使用流程

### 1. 生成本地 SSH key（没有才做，一对 key 反复用）

后面每一条 `ssh` 都靠它登录，所以先把它备好。

```powershell
cd gen_ssh_key
.\New-SshKey.ps1
```

生成两个文件：`C:\Users\<你>\.ssh\vultr`（**私钥**，留在本地）和 `vultr.pub`（**公钥**，要贴出去）。
脚本会把公钥整行放进剪贴板，并打印该粘到哪。

**把公钥放到 Vultr 账号上**（贴 `.pub` 那个，私钥不出本机）：

Vultr 控制台 → 右上头像 → **Account** → **SSH Keys** → **Add SSH Key** ——
名字随便起（比如 `local-win`），Key 里粘上面那一行，保存。之后所有新建实例都能选中它。

> 已经加过 key 的直接跳过这一步，从第 2 步开始。

### 2. 开机器

Vultr 上新建实例，注意三点：

| 项 | 选什么 |
|---|---|
| 系统 | **Ubuntu 24.04 / 22.04** 或 Debian 12（没有 `apt-get` 脚本会直接拒绝） |
| 机房 | 首尔 `icn`、东京 `nrt`、新加坡 `sgp` 延迟较低 |
| SSH Keys | **选中第 1 步加的那把 key**（列表里就是你起的那个名字，可以多选） |

部署完成后在详情页只需要拿一样东西：**公网 IP**。

> 选了 SSH Key，Vultr 就不再生成 root 密码 —— 详情页 **Root Password** 那栏是空的，点眼睛也是空的。
> 这是有意的：没有密码，就没有可爆破的入口。代价是 **View Console 也进不去**（它要密码），
> 而这个仓库默认装完会封掉 22，View Console 正是那之后唯一的入口。所以**登录后先补一个密码**，
> 见第 4 步。

### 3. 先测墙（拿到 IP 后的第一个动作）

**别急着装。** 先花 30 秒确认这个 IP 从国内通不通，再决定要不要往上装东西。
不确定就先装，装完才发现 IP 是死的，那 3 分钟和一次 Destroy 都白花了。

```powershell
cd ping_vps
.\Test-Blocked.ps1 45.76.1.1
```

或者双击 [`ping_vps/测墙.bat`](ping_vps/测墙.bat)。目录里没有 `nodes.txt` 时它会弹框让你手输 IP
——这个文件不会自动生成，也不用建，细节见 [ping_vps/README.md](ping_vps/README.md)。

新机器上还没装 Xray，443 没人在听，所以第三层 TLS 握手一定失败。**正常的输出是这样：**

```
  [OK] ICMP        4/4 回包   平均 82 ms
  [OK] TCP 22      通        85 ms
  [XX] TCP 443     端口未开放(拒绝)
  [XX] TLS 握手    失败（000 / 连不上端口，包被丢了）

  ==> 结论：IP 没被整封，但 TLS 握手没成功        ← 退出码 2 / WARN
```

**这个 WARN 就是放行信号，直接去装。** 它不是问题：

- `端口未开放(拒绝)` 是好事——「拒绝」意味着包一路进到了机器里、被内核回了 RST，IP 层是活的
- TLS 那句「包被丢了」措辞不准，真实原因只是 443 上没有服务
- 脚本底下那几条「`ssh` 上去 `systemctl status xray`、换 8443 端口」是给**装完之后还握手不通**准备的，此刻还不成立，别照着做

真正要拦住的是这一种（退出码 1 / BAD）：

| 结论 | 含义 | 怎么办 |
|---|---|---|
| `ICMP 通但 TCP 全不通` | 典型的 IP 级阻断 | Vultr 后台 Destroy 重建换 IP，别在这台上耗 |
| `三层全无响应` | 被墙，或者机器根本没开机 | 先看实例是不是 Running；是的话同样换 IP |

测之前两个前提：

- 实例状态必须是 **Running**。还在 provisioning 的时候测，会得到一个假的「被墙」
- 把 v2rayN 的**系统代理关掉**，否则本机出口会显示成代理的，结论不可信

装完（下一步）之后**再跑一次同一个命令**，那时 443 上有 Xray 了，应该拿到
`[OK] TLS 握手 HTTP 200` + `结论：没被墙，链路可用`——那才是有决定性证据的一次。

### 4. 登录并装

**A. 本地一条命令跑完**（不用先登进去）

```powershell
ssh -i $HOME\.ssh\vultr root@<你的IP> "curl -fsSL https://raw.githubusercontent.com/D-char/vultr_xray/main/step_vps_install/install.sh -o /tmp/i.sh && bash /tmp/i.sh"
```

**B. 或者先登进去，在里面跑**

```bash
ssh -i ~/.ssh/vultr root@<你的IP>
# 第一次连问 yes/no 输 yes（把新 IP 的指纹记到本地）；用 key 登录不会再问密码
curl -fsSL https://raw.githubusercontent.com/D-char/vultr_xray/main/step_vps_install/install.sh -o /tmp/i.sh
bash /tmp/i.sh
```

> **装之前先补一个 root 密码。** 第 2 步选了 key，Vultr 就没给你密码；装完封口之后
> 唯一还能进机器的是 View Console，它要的正是密码。登进去敲一次：
>
> ```bash
> echo 'root:自己起个密码' | chpasswd
> ```
>
> 别贴到聊天窗口、截图或仓库里 —— 它和私钥一样，是这台机器的最高权限。

**A 那条命令的引号是故意写成双引号的。** PowerShell / cmd 里套单引号，那对引号经常传不到远端，
拿到的报错是 `bash: -c: line 1: unexpected EOF while looking for matching '` ——
看着像服务器坏了，其实连接和认证都已经成功，只是远端收到了一个没闭合的字符串，
一个字节都没执行。就这样写，或者干脆走 B（先 `ssh` 进去，两条命令分开敲，一个引号都不用）。

Git Bash / WSL 里 `~/.ssh/vultr` 和单引号都能用，两种写法等价。

`curl` 是在**服务器上**执行的，取的是服务器到 GitHub 的连通性，和你本地能不能访问
`raw.githubusercontent.com` 无关。

常用变体（接在 `bash /tmp/i.sh` 后面）：

```bash
--port 8443        # 443 不通时换监听端口
--sni www.apple.com
--ip 1.2.3.4       # 取不到公网 IP 时手动指定
-y                 # 不询问直接装
--force            # 已装过则重装（会生成新链接，旧链接立即失效）
--no-lockdown      # 装完不封口，22 端口保持开放
-h                 # 看帮助
```

### 5. 拿链接

成功的标志是这两行（缺第二行就不算成功）：

```
==> 6/7：自检（本机真握手 + 用刚生成的链接真代理一次）
    [OK] 握手成功（HTTP 200），Reality 转发正常
    [OK] 链接可用（临时客户端经 socks5 代理请求成功）
```

然后脚本打印一条 `vless://...`，同时存在服务器的 `/root/node.txt`。

- 第一行只证明「端口在听 + Reality 在转发 + 能出网」，**密钥写错时它照样绿**（鉴权失败也是转发给伪装目标）。
- 第二行会起一个临时客户端，用**即将发给你的那条链接的凭据**真请求一次网页。
  只有它绿，才说明这条 `vless://` 导入就能用。

### 6. 回本地导入

1. v2rayN → 服务器 → 从剪贴板导入批量 URL
2. `Ctrl+E` 设为活动节点
3. 托盘图标 → 系统代理 → 自动配置系统代理
4. 打开 google.com 验证

连不上就回到[第 3 步](#3-先测墙拿到-ip-后的第一个动作)再测一次，
确认是 IP 被墙（而不是链接写错、SNI 不对、端口没放行）之后回 Vultr 换 IP / 重建实例 ——
不是继续折腾这台机器。重建完从第 2 步开始就行（key 已经有了，不用再生成），新 IP 先测墙、再装。

---

## 注意的几点

### 别用 `curl ... | bash`

管道会占掉 stdin：脚本里「回车开始」读不到键盘，重装保护的 `[ -t 0 ]` 会判成非交互；
非 root 时也没法通过管道提权重跑自己。必须 `-o` 落盘再 `bash`。

### 默认会把 22 端口一起封掉，这是故意的

装完默认用 ufw `default deny incoming`，只放行 Xray 那个端口。在 SSH 会话里跑的话：

- **当前这条连接不会断**（ufw 自带 conntrack `ESTABLISHED` 放行），
- 链接在封口**之前**就打印完了，所以你拿得到，
- 但**之后新的 SSH 连接再也进不来**。

要再进机器只能用 Vultr 实例页的 **View Console**（走宿主机控制台通道，不经过虚拟机网络栈，
root 密码照样能登 —— 前提是[第 4 步](#4-登录并装)补过密码；只用 key 没设密码的话它进不去，
这台机器之后就只有手里这把私钥能开了）。想留着 SSH 就加 `--no-lockdown`。

后果之一是：**封口之后再跑测墙，`TCP 22` 会显示不通，这是正常的**，别当成被墙。
看实际监听的那个端口和 TLS 握手结果就行；换过端口要一起带参数：

```powershell
.\Test-Blocked.ps1 45.76.1.1 -Ports 8443 -TlsPort 8443
```

「建机器 → 用 → destroy」这种用法下封口是最省事的做法：暴露窗口只有安装那 2~3 分钟，
这期间 22 上只认你带来的 key（没有私钥就进不去），封口之后连 22 都没了。

不过[第 4 步](#4-登录并装)补的那个 root 密码，在 Vultr 的镜像里默认也能从 22 密码登录
（`PermitRootLogin yes`）。想让它只在 View Console 里可用、不在公网上可用，照
[step_vps_install/README.md](step_vps_install/README.md)第 6 节的 `00-no-password.conf` 关掉 SSH 密码登录 ——
那是一个文件加 `systemctl restart ssh`，两分钟。

### Vultr 防火墙组要另外开

脚本只管机器内的 ufw。如果实例挂了 Firewall Group，得在控制台放行 `${PORT}/tcp`，否则外面照样进不来。

### 443 不通就换端口

`--port 8443`。脚本会明确拒绝 22（Reality 占掉 SSH 端口等于把自己锁在门外）。
`--sni` 换的必须是真实可访问、证书正常的网站。

### 公开仓库的两条纪律

- **不要提交 `/root/node.txt`**：里面是节点链接 / UUID / 公钥，提交上去等于把你的节点公开。
  这些值每台机器不同，都是脚本运行时现生成的，仓库里不需要任何一份。
- **想固定版本就把 URL 里的 `main` 换成某个 commit SHA**（`.../raw/<sha>/install.sh`）。
  否则仓库一更新，你下次在另一台机器上装的就是另一份脚本 —— 这是往 root shell 里灌远程代码，
  固定 SHA 至少让「这台机器装的是哪一版」可查。

`.gitattributes` 已经把 `*.sh` 固定成 LF。别让 Windows 编辑器 / WinSCP 文本模式存成 CRLF：
脚本第 2 行有自愈，但只在 `bash install.sh` 下有效；`./install.sh` 会先死在 shebang 上
（内核拿 `bash\r` 当解释器路径），那时一行代码都还没跑到。

### 能连上 ≠ 能用

脚本的自检只覆盖服务器端。从国内能不能连，得回本地导入链接实测 —— 那是
[`ping_vps/`](ping_vps/) 这一层要回答的问题。
