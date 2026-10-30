# 生成密钥：本地造一对 ed25519

一个纯本地脚本。**不连服务器、不改配置**，跑完在磁盘上多两个文件。

```
.\New-SshKey.ps1
```

或者双击 `生成密钥.bat`。默认落到 `C:\Users\<你>\.ssh\vultr` 和 `vultr.pub`。

```
==> 1/3：检查环境
  [OK] ssh-keygen  C:\Windows\System32\OpenSSH\ssh-keygen.exe

==> 2/3：生成 ed25519 密钥对

==> 3/3：校验
  [OK] 私钥  C:\Users\me\.ssh\vultr
  [OK] 公钥  C:\Users\me\.ssh\vultr.pub
  [OK] 指纹  256 SHA256:R7OkDn8XnhBGXISU1xqhljENAMqlVDmaWjEkf5P3SuE me@PC (ED25519)
  [OK] 校验  私钥能反推出同一把公钥（无密码短语）

==> 公钥（整行复制，已放进剪贴板）

ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEL+v7wIUgkkuUbcYPHRzCgePcObKYI57EJdFH68d13y me@PC
```

## 什么时候需要它

**它是根目录流程的第 1 步**：一对 key 反复用，之后每台新机器开机时选中它，
登录就是 `ssh -i ~/.ssh/vultr root@<IP>`，不用去详情页翻随机密码。

为什么要 key 而不是密码：

| 场景 | 为什么 |
|---|---|
| 密码登录开着，22 在公网上 | root + 密码 + 公网 22，几小时内就会有人来敲 |
| 装了 `--no-lockdown`，22 一直开着 | 同上。密码迟早出现在某个日志里 |
| 机器要留几周几个月 | 同上 |
| 每次开机去详情页查密码 | key 是自动的，一次配好，机器重建多少次都一样 |

> 选了 key，Vultr 就不再生成 root 密码 —— 这牵出一个连锁反应，见下面第一个坑。

## 参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `-Name` | `vultr` | 文件名（不含 `.pub`），放在 `-OutDir` 下 |
| `-OutDir` | `~\.ssh` | 存放目录。别指向本仓库 |
| `-Passphrase` | 空 | 给了就加密私钥，每次用都要输。空 = 不加密 |
| `-Comment` | `user@host` | 公钥尾部注释，只影响可读性，用来分辨是哪台机器的 key |
| `-Force` | - | 已存在时先把旧的改名成 `<名字>.bak-<时间戳>`，再生成 |

```powershell
.\New-SshKey.ps1                                    # ~\.ssh\vultr
.\New-SshKey.ps1 seoul -Comment "vultr-seoul"       # 按机房分开
.\New-SshKey.ps1 vultr -Force                       # 重来一次（旧文件留着备份）
```

## 它比手动 `ssh-keygen` 多做的三件事

1. **生成后真的验一遍**：用私钥反推出公钥，和 `.pub` 逐字节比。
   文件存在 ≠ 能用：私钥被截断、密码短语没生效，都会在这一步露出来。
2. **公钥整行进剪贴板**。`authorized_keys` 里错一个字符就登不上，而肉眼对不出来。
3. **把"粘到哪"打出来**，带上你本机的真实路径和完整的 `echo '...' >> ~/.ssh/authorized_keys` 行。

## 三个坑

### 选了 key，Vultr 就不给 root 密码了

开机时在 SSH Keys 里选中了 key，详情页的 **Root Password 那栏是空的**。
而默认封口之后，唯一还能进机器的是 **View Console**，它要的正是那个密码 ——
也就是说这台机器从此只能靠 key 进，key 一丢就只能 destroy。

想留后路，**在封口之前**用 key 登进去自己设一个：

```bash
echo 'root:自己起个密码' | chpasswd
```

### 私钥在用户目录外，ssh 可能不认

`-OutDir D:\keys` 这种，Windows 的 `ssh.exe` 会因为它权限太松直接拒绝
（`bad permissions`）。要手动收紧：只留当前用户 + SYSTEM + Administrators。
默认的 `~\.ssh` 天然满足，所以别乱改 `-OutDir`。

### 私钥不能进仓库

脚本会拒绝把密钥写进本仓库目录。这不是洁癖：这个仓库的立意就是"公开可参考"，
一把私钥提交上去，等于把那台机器的钥匙印在封面上 —— 而且 git 历史删不干净，改密码也没用，
只能换 key。

## 换 key 的正确顺序

别在原地生成一把新的去替换旧的（这台机器可能就再也进不去了）。顺序是：

1. 生成新 key（换个名字，比如 `vultr-2`）
2. 把**新**公钥追加进服务器的 `authorized_keys` —— 注意是追加 `>>`，不是覆盖 `>`
3. 本地用 `ssh -i C:\Users\me\.ssh\vultr-2 root@<IP>` **验证能进**
4. 确认能进之后，再从 `authorized_keys` 里删掉旧的那一行

`.pub` 和私钥是一对，丢一个都不行。私钥文件（没有 `.pub` 后缀的那个）复制走就等于把钥匙复制走了。
