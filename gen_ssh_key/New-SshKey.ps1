<#
.SYNOPSIS
    在本地生成一对 ssh-ed25519 密钥，用来登录 VPS。只生成文件，不连任何服务器。

.DESCRIPTION
    生成 id 私钥 + 对应 .pub 公钥，落盘后做三项校验，然后把"该粘哪一行、粘到哪"打出来：

      1. 文件存在，且 .pub 以 ssh-ed25519 开头
      2. 私钥能反推出同一把公钥（证明配对没错、密码短语确实生效）
      3. 打印 SHA256 指纹，方便和服务器上的 authorized_keys 对账

    私钥（没有 .pub 后缀的那个）是秘密，只在本地留着；公钥（.pub）随便贴。

    为什么不直接调 ssh-keygen：Windows PowerShell 5.1 在传参给原生 exe 时会把
    空字符串参数丢掉，`-N ""`（无密码短语）会变成 `-N -C xxx`，ssh-keygen 直接
    报 Too many arguments。所以这里用 .NET Process 自己拼参数串。

.PARAMETER Name
    密钥文件名（不含 .pub），默认 vultr。放在 -OutDir 下。

.PARAMETER OutDir
    存放目录，默认 ~\.ssh。不要指向本仓库，私钥绝不能进 git。

.PARAMETER Passphrase
    私钥的密码短语。默认空 = 不加密，ssh 登录时不用输。
    给了值就会同时写进校验步骤，能生成也能验证。

.PARAMETER Comment
    公钥尾部的注释（只影响可读性，默认 ssh-keygen 自己的 user@host）。
    服务器靠它区分是哪台机器的 key。

.PARAMETER Force
    目标文件已存在时，先改名备份成 <名字>.bak-<时间戳> 再生成，而不是覆盖。

.EXAMPLE
    .\New-SshKey.ps1
    最常用：C:\Users\<你>\.ssh\vultr 和 vultr.pub

.EXAMPLE
    .\New-SshKey.ps1 seoul -Comment "vultr-seoul"
    换个名字，注释标一下是哪台机器

.EXAMPLE
    .\New-SshKey.ps1 vultr -Passphrase (Read-Host -AsSecureString | ConvertFrom-SecureString -AsPlainText)
    给私钥加密码短语（磁盘上泄露了也用不了）
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Name = 'vultr',

    [string]$OutDir = (Join-Path $HOME '.ssh'),

    [string]$Passphrase = '',

    [string]$Comment = '',

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Step($m) { Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  [OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [!!] $m" -ForegroundColor Yellow }
function Bad($m)  { Write-Host "  [XX] $m" -ForegroundColor Red }
function Dim($m)  { Write-Host "      $m" -ForegroundColor DarkGray }
function Die($m)  { Bad $m; exit 1 }

# ============================================================ 0 参数体检

# 名字会直接拼进文件路径，路径分隔符和通配符一律不接受
if ([string]::IsNullOrWhiteSpace($Name)) { Die "密钥名字不能为空" }
$Name = $Name -replace '\.pub$', ''
if ($Name -match '[\\/:*?"<>|]') { Die "密钥名字里不能有路径分隔符或通配符：$Name" }
if ($Passphrase.Contains('"'))   { Die "密码短语里不要带英文双引号（这条命令行的引号会打架）" }
if ($Comment.Contains('"'))      { Die "注释里不要带英文双引号（这条命令行的引号会打架）" }

$OutDir    = [IO.Path]::GetFullPath($OutDir)
$privPath  = Join-Path $OutDir $Name
$pubPath   = "$privPath.pub"

# 私钥进仓库 = 把节点钥匙公开。哪怕这个仓库是私有的一时半会儿，也别养成这个习惯。
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ($OutDir.TrimEnd('\') -eq $repoRoot.TrimEnd('\') -or $OutDir -like "$repoRoot\*") {
    Die "拒绝生成到仓库里（$repoRoot）。私钥不该被 git 看见，换 -OutDir 或直接回车用默认的 ~\.ssh"
}

# ============================================================ 1 找 ssh-keygen

Step "1/3：检查环境"

# 顺序有意义：System32 那份和用户平时敲的 ssh.exe 是同一套，先在它俩里找；
# Git for Windows 自带的那份格式一样能用，只是在没装 OpenSSH 客户端的机器上兜底。
$candidates = @(
    (Join-Path $env:WINDIR 'System32\OpenSSH\ssh-keygen.exe'),
    (Get-Command ssh-keygen -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
    'C:\Program Files\Git\usr\bin\ssh-keygen.exe'
) | Where-Object { $_ -and (Test-Path $_ -PathType Leaf) }

if (-not $candidates) {
    Bad "找不到 ssh-keygen"
    Dim "Windows 10 1809+ 自带，只是可能没装 OpenSSH 客户端："
    Dim "  设置 → 应用 → 可选功能 → 添加功能 → OpenSSH 客户端"
    Dim "或者：Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0  （要管理员）"
    exit 1
}
$sshKeygen = $candidates[0]
Ok "ssh-keygen  $sshKeygen"

# 私钥只在 ~ 下面才自动继承好 ACL。放到别处（比如 D:\、共享盘）ssh 会以
# "bad permissions" 拒绝使用，得手动 icacls 收紧，这里只提醒不动手。
if (-not ($OutDir -like "$HOME*")) {
    Warn "生成到用户目录之外：$OutDir"
    Dim "ssh 可能以 bad permissions 拒绝读这把私钥，到时用 icacls 只留当前用户的权限"
}

# ============================================================ 2 生成

Step "2/3：生成 ed25519 密钥对"

if (-not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    Ok "新建目录 $OutDir"
}

foreach ($f in @($privPath, $pubPath)) {
    if (Test-Path $f) {
        if (-not $Force) {
            Bad "已存在：$f"
            Dim "不覆盖。换名字：.\New-SshKey.ps1 $Name-2"
            Dim "确实要重来（旧 key 会失效）：.\New-SshKey.ps1 $Name -Force   —— 旧文件会先改名备份"
            exit 1
        }
    }
}
if ($Force) {
    # 不直接删：这把 key 可能是登进某台机器的唯一方式，改名留着比毁掉好
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    foreach ($f in @($privPath, $pubPath)) {
        if (Test-Path $f) {
            $bak = "$f.bak-$stamp"
            Move-Item -LiteralPath $f -Destination $bak -Force
            Warn "旧文件已改名：$bak"
        }
    }
}

# 用 .NET Process 而不是 & ssh-keygen：理由见文件头（PS 5.1 会吞掉 ""）
function Invoke-SshKeygen {
    param([string]$ArgString)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $sshKeygen
    $psi.Arguments              = $ArgString
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true

    $p = [System.Diagnostics.Process]::Start($psi)
    # 关掉 stdin：万一还是弹了交互提示，它读到 EOF 立刻失败，而不是把命令挂死等人按键
    $p.StandardInput.Close()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()

    [pscustomobject]@{
        Code = $p.ExitCode
        Out  = $outTask.Result
        Err  = $errTask.Result
    }
}

function Quote([string]$s) { '"' + $s + '"' }

$keygenArgs =
    "-t ed25519 -f $(Quote $privPath) -q -N $(Quote $Passphrase)" +
    $(if ($Comment) { " -C $(Quote $Comment)" } else { '' })

$r = Invoke-SshKeygen $keygenArgs
if ($r.Code -ne 0 -or -not (Test-Path $privPath) -or -not (Test-Path $pubPath)) {
    Bad "ssh-keygen 失败（退出码 $($r.Code)）"
    if ($r.Err.Trim()) { Dim $r.Err.Trim() }
    exit 1
}

# ============================================================ 3 校验

Step "3/3：校验"

$pubLine = (Get-Content -LiteralPath $pubPath -Raw).Trim()
if ($pubLine -notmatch '^ssh-ed25519 [A-Za-z0-9+/=]+') {
    Die "公钥内容不像 ed25519：$pubLine"
}

# 反推：能从私钥算出同一把公钥，才说明「配对正确 + 密码短语就是刚才给的那个」。
# 这一条比「文件存在」有意义得多 —— 私钥被截断、-N 没生效，都会在这里露出来。
$r = Invoke-SshKeygen "-y -P $(Quote $Passphrase) -f $(Quote $privPath)"
$derived = ($r.Out -split '\s+' | Select-Object -First 2) -join ' '
$expect  = ($pubLine -split '\s+' | Select-Object -First 2) -join ' '
if ($r.Code -ne 0 -or $derived -ne $expect) {
    Bad "私钥和公钥对不上（或私钥有未提供的密码短语），这对 key 别用"
    if ($r.Err.Trim()) { Dim $r.Err.Trim() }
    exit 1
}

$fp = (Invoke-SshKeygen "-l -E sha256 -f $(Quote $pubPath)").Out.Trim()
Ok "私钥  $privPath"
Ok "公钥  $pubPath"
Ok "指纹  $fp"
Ok "校验  私钥能反推出同一把公钥（$(if ($Passphrase) { '带密码短语' } else { '无密码短语' })）"

# 公钥整行丢进剪贴板，省下手动选中/漏字符的麻烦。没有剪贴板的环境（远程会话）不影响生成。
try { Set-Clipboard -Value $pubLine } catch { }

# ============================================================ 打印

Step "公钥（整行复制，已放进剪贴板）"
Write-Host ""
Write-Host $pubLine -ForegroundColor White
Write-Host ""

Step "下一步（选一个）"

Write-Host "  A. 新机器：开机的时候就把 key 交给 Vultr（推荐，之后不用记密码）" -ForegroundColor White
Dim "Account → SSH Keys → Add SSH Key，名字随便起，内容粘上面那一行，保存"
Dim "新建实例时在 SSH Keys 里选中它"
Warn "选了 key，Vultr 一般就不再生成 root 密码 —— 详情页那栏是空的。"
Dim "  这个仓库默认装完会封掉 22，之后唯一的入口是 View Console，而它要密码。"
Dim "  想留后路，就在封口前用自己的 key 登进去设一个："
Dim "    echo 'root:自己起个密码' | chpasswd"

Write-Host ""
Write-Host "  B. 机器已经在跑：登进去把公钥追加到 authorized_keys" -ForegroundColor White
Dim "ssh root@<IP>"
Dim "mkdir -p ~/.ssh"
Dim "echo '$pubLine' >> ~/.ssh/authorized_keys"
Dim "chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"
Dim ""
Dim "先验证再关密码登录（这一步别跳）："
Dim "ssh -i `"$privPath`" root@<IP>"

Write-Host ""
Dim "私钥 $privPath 是秘密：别贴聊天窗口、别进仓库、别传网盘。公钥随便发。"
exit 0
