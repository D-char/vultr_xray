# 第 1 步：在服务器上装好 VPN 环境

这一份**只在服务器上跑**。它假设你已经在 Vultr（或任何云）上开好了一台 Ubuntu 机器，
并且能用 **root 密码** SSH 登进去（本文件就是按这条路写的；用公钥登录当然也行，
只是第 5 步可以跳过）。

它做一件事：装好 Xray → 启动 → 自检两次 → 打印一条能直接导入 v2rayN 的 `vless://` 链接 →
把公网入口关掉（只留 Xray 端口），这样爆破流量跟这台机器无关，用完直接 destroy 就行。

不做的事（留给后面的步骤）：不建机器、不 ping、不测墙、失败不自动重来。

---

## 1. 开机器

Vultr 上新建实例，注意三点：

| 项 | 选什么 |
|---|---|
| 系统 | **Ubuntu 24.04 / 22.04** 或 Debian 12（别的发行版没有 `apt-get`，脚本会直接拒绝） |
| 机房 | 首尔 `icn`、东京 `nrt`、新加坡 `sgp` 延迟较低 |
| SSH Keys | **留空，不选任何 key** —— 这样 Vultr 才会给你生成 root 密码 |

部署完成后，在实例详情页拿两样东西：

- **公网 IP**
- **root 密码**：页面上有一栏 Root Password，点旁边的眼睛图标显示，可以直接复制

> 这个密码是 Vultr 自动生成的、只在这里显示。**别贴到聊天窗口、截图或仓库里**——
> 它就是这台机器的最高权限。

## 2. 用密码登录

```bash
ssh root@45.76.1.1
```

第一次连会问 `Are you sure you want to continue connecting (yes/no)?`，输 `yes` 回车
（这是把新 IP 的指纹记到本地，正常步骤）。然后输 root 密码——**输密码时屏幕上什么都不显示，
一个星号都没有，这是正常的**，输完直接回车。

两个岔路：

| 现象 | 处理 |
|---|---|
| `Permission denied (publickey)` | 这个镜像不接受密码登录。回 Vultr 实例页点 **View Console**（网页版终端），用同一个 root 密码登录，后面所有命令在浏览器里跑，效果一样 |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | 你之前用过同一个 IP。执行 `ssh-keygen -R 45.76.1.1` 清掉旧指纹再连 |

## 3. 一条命令装完

**在你自己的电脑上执行**（不用先登服务器）：

```bash
ssh root@45.76.1.1 'curl -fsSL https://raw.githubusercontent.com/D-char/vultr_xray/main/step_vps_install/install.sh -o /tmp/i.sh && bash /tmp/i.sh -y'
```

这一条把全部做完：装依赖 → 装 Xray → 写配置 → 启动 → 自检两次 → 把 `vless://` 链接打印在
**你本地的终端**上 → 最后用 ufw 把公网入口关掉，只留 Xray 那个端口。

最后那步「封口」是默认行为，就是用来解决爆破流量的：装完 22 端口立刻从公网不可达，整个
暴露窗口只有安装的那 2~3 分钟，而且这期间 root 密码是 Vultr 随机生成的。

**要留着机器长期用、之后还想 SSH 进去，就加 `--no-lockdown`。**

也可以先登进服务器再跑，效果一样：

```bash
ssh root@45.76.1.1
curl -fsSL https://raw.githubusercontent.com/D-char/vultr_xray/main/step_vps_install/install.sh -o /tmp/i.sh
bash /tmp/i.sh
```

常用变体（接在命令末尾）：

```bash
bash /tmp/i.sh --port 8443         # 443 不通时换端口
bash /tmp/i.sh --sni www.apple.com
bash /tmp/i.sh --no-lockdown       # 装完不封口，22 端口保持开放
bash /tmp/i.sh -y                  # 不询问直接装
bash /tmp/i.sh --force             # 已经装过，重装（旧链接会失效）
bash /tmp/i.sh -h                  # 看帮助
```

### 不用 GitHub 也行（仓库是 private / 想手工传）

**A. Windows 命令行**

```powershell
cd C:\Users\m\Desktop\vultr-xray\step_vps_install
scp .\install.sh root@45.76.1.1:/root/
```

**B. WinSCP / FileZilla**

拖到 `/root/` 就行。但**文件传输模式必须选 Binary**，选成 Text / ASCII 会把换行改成
CRLF（脚本能自动修，但没必要给它找麻烦）。

**C. 服务器上现敲**

```bash
nano /root/install.sh      # 把内容粘进去，Ctrl+O 保存，Ctrl+X 退出
```

三种方式都传上去之后：`bash /root/install.sh`。

### 用 URL 装的话，记四条规则

- **用 root 跑**（Vultr 默认就是）。非 root 时脚本要 sudo 自己再跑一遍，管道方式拿不到
  脚本原文，会直接报错让你先落盘——这是故意的，不是 bug。
- **别用 `curl ... | bash`**：管道会占掉 stdin，脚本里「回车开始」这类确认读不到键盘，
  重装保护（`[ -t 0 ]`）也会判成非交互。上面那种 `-o` 落盘再 `bash` 的写法两个问题都没有。
- **想固定版本**就把 URL 里的 `main` 换成某个 commit SHA（`.../raw/<sha>/...`）。否则
  仓库一更新，你下次在另一台机器上装的就是另一份脚本——这是往 root shell 里灌远程代码，
  固定 SHA 至少让「这台机器装的是哪一版」可查。
- **仓库里不要放 `/root/node.txt`**。生成出来的节点链接、UUID、公钥只属于那台机器，
  提交上去等于把你的节点公开。

## 4. 看结果

成功的标志是这一段（第 6 步有两条 OK）：

```
==> 6/7：自检（本机真握手 + 用刚生成的链接真代理一次）
    [OK] 握手成功（HTTP 200），Reality 转发正常
    [OK] 链接可用（临时客户端经 socks5 代理请求成功）

============================================================
 安装完成，且已通过握手 + 代理自检
 节点链接（同时保存在 /root/node.txt）：
============================================================

vless://xxxx@45.76.1.1:443?encryption=none&flow=xtls-rprx-vision&...&type=tcp#VPS-45.76.1.1
```

接着是封口那一步（默认开启）：

```
==> 封口：只保留 443/tcp，关掉 22 等公网入口
    [OK] ufw 已启用，只放行 443/tcp

         To                         Action      From
         --                         ------      ----
         22/tcp                     DENY        Anywhere
         443/tcp                    ALLOW       Anywhere

         现在 SSH 已经连不进来了。要再操作这台机器，用 Vultr 的 View Console
         （宿主机通道，不经过 ufw；root 密码照样能登）
         用完了直接在面板上 Destroy Instance 即可
```

把那条 `vless://` 整行复制走（网页控制台里可能没法直接复制，就先 `cat /root/node.txt`
再手抄，或者用 WinSCP 把文件拖回本地）。它同时存在 `/root/node.txt` 里，随时能再翻出来。

这两条 OK 分别是什么：

- **握手成功**：用 `www.microsoft.com` 这个 SNI 连了自己的端口。Reality 会把没有正确密钥的
  TLS 连接原样转发给伪装目标，所以拿到 HTTP 2xx/3xx/4xx 就证明：端口在听 + Reality 在转发 +
  服务器能出网。
- **链接可用**：临时起一个 Xray 客户端，用那条链接里的 UUID / 公钥 / ShortID / SNI 真的走一遍
  socks5 代理去请求 `generate_204`。**只有这一条绿，才说明发出来的 `vless://` 本身是对的**——
  上一条在密钥/ShortID 写错时照样会绿（鉴权失败也是"转发给目标"）。

## 5. 装完之后

默认封口之后，这台机器的 22 端口已经从公网不可达，**你不需要再做任何 SSH 加固**——
没有入口可爆破。剩下的事只有两件：

| 要做什么 | 怎么做 |
|---|---|
| 改配置 / 重装 | Vultr 实例页 → **View Console**，用 root 密码登录 |
| 不想用了 | 面板 → 实例右侧 **⋮** → **Destroy Instance**，计费停止、IP 释放 |

View Console 走的是宿主机到虚拟机的控制台通道，**不经过虚拟机的网络栈**，所以 ufw 把 22
关死对它没有任何影响。万一连控制台也进不去（系统起不来之类），直接 destroy 重建一台，
对你来说就是三分钟的事。

---

## 6. 可选：长期留着这台机器时才需要

> 用了 `--no-lockdown`，或者你打算让机器跑几周几个月，才需要看这一节。
> **默认封口的情况下整节可以跳过。**

root + 密码 + 公网 22 端口，在 Vultr 的 IP 上**几小时内就会被爆破**——这不是概率问题，
是常态。安装脚本完全不碰 sshd，所以这一步得你自己做，花两分钟。

**在本地生成一对密钥：**

```bash
ssh-keygen -t ed25519 -f ~/.ssh/vultr -N ""
```

Windows 上就是 `C:\Users\<你>\.ssh\vultr` 和 `vultr.pub` 两个文件。

**服务器上**（把 `vultr.pub` 的内容整行粘进去，注意是 `.pub` 那个）：

```bash
mkdir -p ~/.ssh
echo 'ssh-ed25519 AAAA...你的公钥...' >> ~/.ssh/authorized_keys
chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys
```

**先验证密钥能登进来**，这一步别跳：

```bash
# 本地新开一个窗口
ssh -i ~/.ssh/vultr root@45.76.1.1     # 能进，再往下走
```

**确认能进之后**，才关掉密码：

```bash
# 1. 先看当前生效值（这才是真相，别靠猜）
sshd -T | grep -iE 'passwordauthentication|kbdinteractiveauthentication'

# 2. 写覆盖文件。文件名必须排在 50-cloud-init.conf 前面，原因见下
tee /etc/ssh/sshd_config.d/00-no-password.conf >/dev/null <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
EOF

# 3. 重启前确认生效值已经是 no，再重启
sshd -T | grep -iE 'passwordauthentication|kbdinteractiveauthentication'
systemctl restart ssh
```

> **为什么是 `00-` 而不是常见的 `99-`**：sshd 的规则是「同一个关键字，**先读到的值生效**」
> （`sshd_config(5)`: *the first obtained value will be used*），和 nginx / sysctl 的
> 「后面覆盖前面」正好相反。而 `sshd_config.d/` 是按文件名字典序加载的，
> cloud-init 写的 `50-cloud-init.conf` 里有 `PasswordAuthentication yes` —— 你写 `99-`
> 排在它后面，**根本盖不住**。要么用 `00-` 这样的前缀，要么直接删掉那个文件：
> `rm -f /etc/ssh/sshd_config.d/50-cloud-init.conf`。
>
> 两个都要关：`PasswordAuthentication` 管密码认证，`KbdInteractiveAuthentication`
> 管 PAM 的键盘交互认证（它也能用密码过），只关前者等于没关。

验证：从本地再试一次密码登录，应该被拒。

```bash
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password root@45.76.1.1
# 期望：Permission denied (publickey)
```

以后连接：

```bash
ssh -i ~/.ssh/vultr root@45.76.1.1
```

> **不会把自己锁死**：上面的设置只关掉 sshd 的密码登录，root 账号本身的密码还在。
> 所以万一密钥丢了，回 Vultr 点 **View Console** 用密码登网页控制台照样能进
> （它走的是本地 PAM 登录，不经过 sshd）。**千万别去 `passwd -l` 锁账号**，
> 那才是真锁死。

嫌这套麻烦也行：在 Vultr 账号的 SSH Keys 里存一个公钥，下次部署勾一下，
从第一步起就完全不需要密码了。

## 7. 回本地导入

1. v2rayN → 服务器 → 从剪贴板导入批量 URL
2. `Ctrl+E` 设为活动节点
3. 右下角托盘图标 → 系统代理 → 自动配置系统代理
4. 打开 google.com 验证

---

## 出错了怎么办

| 现象 | 原因 | 处理 |
|---|---|---|
| `Permission denied (publickey)` | 镜像不接受密码登录 | 用 Vultr 的 **View Console** 网页控制台，或改用公钥登录 |
| 详情页找不到 root 密码 | 部署时勾了 SSH Key | 有 key 就直接用 key 登录；当初没 key 的话重建实例 |
| `找不到 apt-get` | 系统不是 Ubuntu/Debian | 重装成 Ubuntu 24.04 |
| `端口 443 被占用了` | 有 nginx / apache / 旧 xray 在跑 | 停掉它，或 `--port 8443` |
| `apt-get update 失败` | 服务器 DNS / 网络有问题 | `ping -c3 8.8.8.8` 看看 |
| `Xray 安装脚本执行失败` | 服务器拉不到 GitHub | 换一台机器；这是服务器端网络问题 |
| `[XX] 握手失败` | 端口被中间设备拦 / 服务器无外网 / SNI 解析不了 | 换 `--port 8443` 或 `--sni` 重试，日志会跟着打出来 |
| `[XX] 链接不可用` | 转发通了，但凭据对不上（UUID / 公钥 / ShortID / flow） | 脚本自己生成的凭据不会错到这一步，通常是中途改了配置；`/tmp/xray-selftest-client.log` 有日志，重跑一次 `--force` 即可 |
| 装完但本地连不上 | **服务端是好的，是这个 IP 被墙了** | 这是第 2 步的结论：回 Vultr 换 IP / 重建实例 |
| 装完再也 SSH 不进去 | **正常**，ufw 已经把 22 关了 | 不用修。要进就用 **View Console**；不想要这个行为下次加 `--no-lockdown` |
| `[!!] ufw 没能启用` | ufw 装不上 / 内核没有 netfilter | 22 端口仍开放，机器照常能用；想封口就手动跑那条打印出来的命令 |
| 关掉密码后连不上 | 密钥没生效 / 写错了文件 | 用 **View Console** 进去，检查 `~/.ssh/authorized_keys` 和 `chmod` 那两条 |

判断"服务端没问题"和"你连不上"是两件事，这样分开才能知道该修哪头。

## 已经处理掉的坑

- **CRLF 自动修**：文件被 Windows 编辑器或 WinSCP 文本模式存成 CRLF 时，第 2 行会自动
  去掉 `\r` 再重跑。否则 bash 会在 `set -euo pipefail` 那里就报 `invalid option name`，
  报错行号还全是错的。但这只在 `bash install.sh` 下有效——CRLF 文件用 `./install.sh`
  会先死在 shebang 上（内核拿 `bash\r` 当解释器路径），那时一行代码都没跑到。
- **用链接自测**：自检不只看"服务在跑"或"转发通了"，还会起一个临时客户端，用发出去那条
  链接的凭据真的请求一次网页。公钥/ShortID 写错会在这里红，而不是等你回本地才发现。
- **cloud-init 抢 apt 锁**：刚开机的机器会等 cloud-init 收尾（最多等 180 秒），并给 apt
  设 180 秒等锁上限，不然全新实例第一次跑必然撞 `dpkg` 锁。
- **配置先自检**：写完后先 `xray run -test`，配置有语法错会当场指出，而不是等服务启动失败。
- **配置权限**：显式设成 `root:xray 640`，因为服务是以 `User=xray` 跑的，读不到配置会起不来
  且日志里看不出原因。
- **密钥输出格式兼容**：`xray x25519` 的输出标签在不同版本间变过（`Private key` /
  `PrivateKey` / `Password`），三种格式和"裸 token"都有对应解析，解析不出来会打印原始输出。
- **端口 22 直接拒绝**：防止你把 SSH 端口占了锁死自己。
- **重跑不误伤**：已经装过时默认停下并打印旧链接，要重装必须显式 `--force`；
  覆盖前会把旧配置和 `node.txt` 备份到 `/root/xray-backup-<时间戳>/`。
- **BBR**：顺手开，高丢包线路上快不少。写 `/etc/sysctl.d/99-xray-bbr.conf` 并**回读验证**，
  没开起来会黄字提示，而不是假装开好了。
- **装完封口**：默认用 ufw 把除 Xray 端口外的入站全关掉（含 22）。ufw 自带
  conntrack `ESTABLISHED` 放行，所以安装时那条 SSH 连接不会断，只是新连接进不来。
  封口发生在自检和打印链接**之后**，所以就算它出问题，你手上也已经有链接了。
- **ufw**：只有 ufw 处于 active 时才放行端口；云厂商的安全组要你另外在控制台开。

## 下一步

这一步只证明服务器端装好了。从你这边能不能连上，要导入链接实测——
那是第 2 步，失败的话结论是「IP 被墙」，处理方式是换机器，而不是继续折腾这台。
