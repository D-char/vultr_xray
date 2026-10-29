<#
.SYNOPSIS
    快速判断一个 IP 在国内是否被墙。只测，不装、不改、不花钱。

.DESCRIPTION
    从本机出发打三层，跟 deploy.ps1 的判定标准一致，任何一层活着就不算被墙：

      1. ICMP        ping 4 次。不通不代表被墙（很多机器禁 ping）
      2. TCP 端口    22 / 80 / 443（可改）。裸连接，能过说明 IP 层没被整包丢
      3. TLS 真握手  用 SNI 直连服务器 IP 取 https://<SNI>/，拿到 2xx/3xx/4xx 才算数

    第 3 层是关键：TCP 443 能连上 和 能正常跑 Reality 是两回事。Reality 会把
    "没有正确密钥"的 TLS 连接原样中转给真站（www.microsoft.com），所以能拿到
    HTTP 状态码就说明链路真的活着，而不只是三次握手过了。

    还会先看一眼本机出口在哪：这个脚本只有从国内跑才有意义。如果本机不在国内，
    会直接告诉你结果不作数，别拿它当结论。

.PARAMETER Ip
    要测的 IP，可多个用逗号分隔。不传就读 nodes.txt（本目录或上一层）里最近的一条。

.PARAMETER Ports
    要探的 TCP 端口，默认 22,80,443

.PARAMETER TlsPort
    做 TLS 真握手用的端口，默认 443。换过 Xray 端口就一起改

.PARAMETER Sni
    握手用的伪装域名，必须和客户端/服务端一致，默认 www.microsoft.com

.PARAMETER TimeoutMs
    单个 TCP 连接的等待毫秒数，默认 4000

.PARAMETER SkipPing
    跳过 ICMP，只测 TCP + TLS。机器禁 ping 时省 4 秒

.PARAMETER NoVantage
    跳过"本机在不在国内"的查询（不想访问第三方 IP 查询接口时用）

.EXAMPLE
    .\Test-Blocked.ps1 45.76.1.1
    最常用

.EXAMPLE
    .\Test-Blocked.ps1
    不带参数：读 nodes.txt 里最近一台的 IP

.EXAMPLE
    .\Test-Blocked.ps1 45.76.1.1,45.76.1.2
    一次测多个

.EXAMPLE
    .\Test-Blocked.ps1 45.76.1.1 -Ports 22,8443 -TlsPort 8443
    换过端口的节点

.EXAMPLE
    .\Test-Blocked.ps1 45.76.1.1 -SkipPing -NoVantage
    最快的一档：不 ping、不查出口位置
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string[]]$Ip,

    [int[]]$Ports = @(22, 80, 443),
    [int]$TlsPort = 443,
    [string]$Sni = 'www.microsoft.com',
    [int]$TimeoutMs = 4000,

    [switch]$SkipPing,
    [switch]$NoVantage
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

function Step($m) { Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  [OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [!!] $m" -ForegroundColor Yellow }
function Bad($m)  { Write-Host "  [XX] $m" -ForegroundColor Red }
function Dim($m)  { Write-Host "      $m" -ForegroundColor DarkGray }

# ============================================================ 基础探测

function Get-PingStat {
    param([string]$Target)
    $recv = 0
    $avg  = 0
    try {
        $pings = @(Test-Connection -ComputerName $Target -Count 4 -ErrorAction SilentlyContinue)
        $recv  = @($pings | Where-Object { $_ }).Count
        if ($recv -gt 0) {
            $avg = [math]::Round((($pings | Measure-Object -Property ResponseTime -Average).Average), 0)
        }
    }
    catch { $recv = 0 }
    [pscustomobject]@{
        Received = $recv
        Loss     = [math]::Round((4 - $recv) / 4 * 100, 0)
        AvgMs    = $avg
    }
}

# 多个端口同时发起连接，然后统一等。
# 串行探 3 个端口、每个超时 4 秒 = 最坏 12 秒；并发之后最坏还是 4 秒，
# 而且每个端口各自的计时窗口不会被前一个拖长。
function Test-TcpPorts {
    param([string]$TargetHost, [int[]]$Ports, [int]$TimeoutMs = 4000)

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $jobs = @()
    foreach ($p in $Ports) {
        $client = New-Object System.Net.Sockets.TcpClient
        $job = [pscustomobject]@{
            Port   = $p
            Client = $client
            Async  = $null
            Start  = $sw.ElapsedMilliseconds
            Ok     = $false
            Ms     = 0
            Note   = ''
        }
        try { $job.Async = $client.BeginConnect($TargetHost, $p, $null, $null) }
        catch { $job.Note = '无法发起连接' }
        $jobs += $job
    }

    foreach ($job in $jobs) {
        if (-not $job.Async) { continue }
        $left = $TimeoutMs - ($sw.ElapsedMilliseconds - $job.Start)
        if ($left -lt 0) { $left = 0 }
        try {
            if ($job.Async.AsyncWaitHandle.WaitOne($left)) {
                $job.Client.EndConnect($job.Async)
                $job.Ok = $true
                $job.Ms = $sw.ElapsedMilliseconds - $job.Start
            }
            else { $job.Note = '超时' }
        }
        catch {
            # 拒绝和超时要分开说：拒绝 = 机器活着但没开这个端口，超时 = 根本没回音
            $inner = $_.Exception.InnerException
            if ($inner -and $inner.Message -match 'refused|拒绝') { $job.Note = '端口未开放(拒绝)' }
            elseif ($job.Note -eq '') { $job.Note = '连接失败' }
        }
    }

    foreach ($job in $jobs) { try { $job.Client.Close() } catch { } }
    return $jobs
}

# 真实握手：用 SNI 直连服务器 IP。
# 拿到 2xx/3xx/4xx = 链路活着 + 端口没被单独封 + Reality 在干活。
# 拿不到不一定是墙：服务没起、SNI 不对、系统时间偏差太大都会这样，
# 所以把 curl 的退出码翻成原因，别让人对着一串 000 猜。
function Test-TlsHandshake {
    param([string]$Ip, [string]$SniName, [int]$Port, [int]$TimeLimitSec = 8)

    $curl = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source
    if (-not $curl) {
        return [pscustomobject]@{ Ok = $null; Code = ''; Why = '本机没有 curl.exe，跳过 TLS 握手检测' }
    }

    $hostPort = if ($Port -eq 443) { $SniName } else { "${SniName}:${Port}" }
    $rc = -1
    $code = '000'
    # curl 失败会往 stderr 写东西，PS5.1 下 2>&1 会把它变成 ErrorRecord 触发 EAP=Stop，必须临时降级
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out  = & $curl -k -sS -o NUL -w '%{http_code}' --max-time $TimeLimitSec `
                        --resolve "${SniName}:${Port}:${Ip}" "https://${hostPort}/" 2>&1
        $rc    = $LASTEXITCODE
        # curl 失败时会把报错也写进 stderr，被 2>&1 混进来，
        # 所以只认干净的三位状态码：先按行找，再退一步认结尾的三位数
        $parts = @($out | ForEach-Object { $_.ToString().Trim() })
        $code  = ''
        foreach ($part in $parts) { if ($part -match '^\d{3}$') { $code = $part } }
        if (-not $code) {
            $m = [regex]::Match(($parts -join "`n"), '(\d{3})\s*$')
            if ($m.Success) { $code = $m.Groups[1].Value } else { $code = '000' }
        }
    }
    catch { $code = '000' }
    finally { $ErrorActionPreference = $prevEAP }

    $ok = $code -match '^[234]\d\d$'
    $why = ''
    if (-not $ok) {
        switch ($rc) {
            6  { $why = '本机 DNS 解析失败（和墙无关）' }
            7  { $why = '连不上端口，包被丢了' }
            28 { $why = '超时，一直没有响应' }
            35 { $why = 'TCP 连上了，但 TLS 握手被打断' }
            52 { $why = '连上但服务端没发数据（服务可能没跑）' }
            default { if ($rc -ge 0) { $why = "curl 退出码 $rc" } else { $why = '握手失败' } }
        }
    }
    [pscustomobject]@{ Ok = $ok; Code = $code; Why = $why }
}

# 本机出口在哪。这脚本只有从国内跑才有意义：从境外跑，墙根本不在路径上，
# 测出来"通"不能证明国内能通。
function Get-Vantage {
    param([int]$TimeoutMs = 4000)
    $text = ''
    try {
        $req = [Net.WebRequest]::Create('http://myip.ipip.net/')
        $req.Timeout = $TimeoutMs
        # 必须绕开系统代理：v2rayN 一开系统代理，这里报的就是代理的出口，不是本机的位置
        try { $req.Proxy = [Net.GlobalProxySelection]::GetEmptyWebProxy() } catch { }
        $resp = $req.GetResponse()
        $sr   = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
        $text = $sr.ReadToEnd()
        $sr.Close(); $resp.Close()
    }
    catch { return [pscustomobject]@{ Ok = $null; Detail = ''; InChina = $null } }

    $text = ($text -replace '\s+', ' ').Trim()
    $inChina = $null
    if ($text -match '中国|China') { $inChina = $true }
    elseif ($text) { $inChina = $false }
    [pscustomobject]@{ Ok = [bool]$text; Detail = $text; InChina = $inChina }
}

# 没给 IP 时从 nodes.txt 里捡最近的一条。里面是 vless://uuid@IP:port?...#名字，
# 也可能有人手动粘了裸 IP，两种都认。
function Get-RecentIpFromNodes {
    $cands = @(
        (Join-Path $PSScriptRoot 'nodes.txt'),
        (Join-Path (Split-Path -Parent $PSScriptRoot) 'nodes.txt')
    )
    foreach ($f in $cands) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $lines = @(Get-Content -LiteralPath $f -Encoding UTF8 -ErrorAction SilentlyContinue |
                   Where-Object { $_.Trim() })
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            $m = [regex]::Match($lines[$i], '(\d{1,3}(?:\.\d{1,3}){3})')
            if ($m.Success) { return [pscustomobject]@{ Ip = $m.Groups[1].Value; File = $f } }
        }
    }
    return $null
}

# ============================================================ 判定

function Get-Verdict {
    param($Ping, $Tcp, $Tls, [string]$Target)

    $openPorts = @($Tcp | Where-Object { $_.Ok } | ForEach-Object { $_.Port })
    $anyTcp    = $openPorts.Count -gt 0
    $pingOk    = ($Ping -and $Ping.Received -gt 0)

    # 第一层：TLS 真握手过了，别的都不用看了
    if ($Tls.Ok -eq $true) {
        return [pscustomobject]@{
            Level = 'OK'; Title = '没被墙，链路可用'
            Hints = @("握手拿到了 HTTP $($Tls.Code)，说明国内到你服务器这条路是通的")
        }
    }

    # 第二层：TCP 通、握手不通 —— 不是整 IP 被封，是端口/服务的问题
    if ($anyTcp) {
        return [pscustomobject]@{
            Level = 'WARN'; Title = 'IP 没被整封，但 TLS 握手没成功'
            Hints = @(
                "通的端口：$($openPorts -join ', ')；握手端口 $TlsPort 失败（$($Tls.Why)）",
                "先 ssh 上去 systemctl status xray，确认服务在跑、端口对得上",
                "服务正常就是 $TlsPort 被单独阻断了，换端口：-Ports 22,8443 -TlsPort 8443",
                "SNI 不对也会这样，检查 -Sni 是否和服务端一致"
            )
        }
    }

    # 下面都是 TCP 全不通
    if ($Tls.Ok -eq $null -and -not $Ping) {
        # 既不 ping 也没 curl，只剩 TCP 一个证据
        return [pscustomobject]@{
            Level = 'BAD'; Title = '所有 TCP 端口都不通'
            Hints = @('去掉 -SkipPing 再跑一次，补上 ICMP 证据')
        }
    }
    if ($pingOk) {
        return [pscustomobject]@{
            Level = 'BAD'; Title = 'ICMP 通但 TCP 全不通 —— 典型的 IP 级阻断，大概率被墙'
            Hints = @(
                "换了这些端口一个都没开：$($Ports -join ', ')",
                "也先排除机器自己的防火墙/服务没起：iptables -L -n 看有没有全 DROP",
                "确认不是墙的问题，就在 Vultr 后台 Destroy 重建换 IP"
            )
        }
    }
    $what = if ($Ping) { '三层全无响应（ICMP 也没回包）' } else { 'TCP 和 TLS 都不通（跳过了 ICMP）' }
    return [pscustomobject]@{
        Level = 'BAD'; Title = "$what —— 被墙，或者机器根本没开机"
        Hints = @(
            'Vultr 后台看一眼实例是不是 running',
            '实例在跑、IP 也是这个，那就是 IP 被墙了，Destroy 重建换一个',
            '想自动换 IP：回到根目录跑 .\deploy.ps1 -New'
        )
    }
}

# ============================================================ 主流程

if (-not $Ip -or $Ip.Count -eq 0) {
    $recent = Get-RecentIpFromNodes
    if ($recent) {
        $Ip = @($recent.Ip)
        Dim "没给 IP，用 nodes.txt 里最近的一条：$($recent.Ip)  ($($recent.File))"
    }
}
if (-not $Ip -or $Ip.Count -eq 0) {
    $ans = Read-Host "请输入要检测的服务器 IP（多个用逗号分隔）"
    $Ip = @($ans -split '[,;\s]+' | Where-Object { $_ })
}
if (-not $Ip -or $Ip.Count -eq 0) { Bad "没有拿到 IP，退出"; exit 1 }

$Ip = @($Ip | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)

Write-Host ""
Write-Host "  IP 快检  |  从本机看这个 IP 在国内通不通" -ForegroundColor White
Dim "三层：ICMP -> TCP $($Ports -join ',') -> TLS 握手(SNI=$Sni, 端口 $TlsPort)。任何一层活着就不算被墙"

$vantage = $null
if (-not $NoVantage) {
    $vantage = Get-Vantage -TimeoutMs ([math]::Max(3000, $TimeoutMs))
}
if ($vantage) {
    if ($vantage.Ok -eq $null) {
        Warn "查不到本机出口位置（接口超时/被屏蔽），下面结果按『本机在国内』解读"
    }
    elseif ($vantage.InChina -eq $true) {
        Ok "检测视角：$($vantage.Detail)  —— 在国内，结果可作数"
    }
    else {
        Warn "检测视角：$($vantage.Detail)  —— 不在国内"
        Dim "墙只挡国内到境外的路，从这边测出『通』证明不了国内能通。"
        Dim "要拿到真结论：在国内的网络/手机上跑这个脚本，或者在国内的朋友那边跑一次。"
    }
}

$results = @()
foreach ($target in $Ip) {
    Step "检测 $target"

    $ping = $null
    if (-not $SkipPing) {
        $ping = Get-PingStat -Target $target
        if ($ping.Received -gt 0) {
            Ok ("ICMP        {0}/4 回包   平均 {1} ms{2}" -f $ping.Received, $ping.AvgMs,
                $(if ($ping.Loss -gt 0) { "   丢包 $($ping.Loss)%" } else { '' }))
        }
        else {
            Warn "ICMP        4 次全无回包（有的机器禁 ping，先看下面的 TCP）"
        }
    }

    $tcp = Test-TcpPorts -TargetHost $target -Ports $Ports -TimeoutMs $TimeoutMs
    foreach ($t in $tcp) {
        if ($t.Ok) { Ok ("TCP {0,-6}   通        {1} ms" -f $t.Port, $t.Ms) }
        else { Bad ("TCP {0,-6}   {1}" -f $t.Port, $t.Note) }
    }

    $tls = Test-TlsHandshake -Ip $target -SniName $Sni -Port $TlsPort `
                             -TimeLimitSec ([math]::Max(4, [int]($TimeoutMs / 1000) * 2))
    if ($tls.Ok -eq $true) {
        Ok ("TLS 握手    HTTP $($tls.Code)   ${Sni}:${TlsPort} 直连成功")
    }
    elseif ($tls.Ok -eq $null) {
        Warn "TLS 握手    $($tls.Why)"
    }
    else {
        Bad ("TLS 握手    失败（$($tls.Code) / $($tls.Why)）")
    }

    $v = Get-Verdict -Ping $ping -Tcp $tcp -Tls $tls -Target $target
    Write-Host ""
    if ($v.Level -eq 'OK') { Write-Host "  ==> 结论：$($v.Title)" -ForegroundColor Green }
    elseif ($v.Level -eq 'WARN') { Write-Host "  ==> 结论：$($v.Title)" -ForegroundColor Yellow }
    else { Write-Host "  ==> 结论：$($v.Title)" -ForegroundColor Red }
    foreach ($h in $v.Hints) { Dim "· $h" }

    $results += [pscustomobject]@{ Ip = $target; Level = $v.Level; Title = $v.Title }
}

if ($results.Count -gt 1) {
    Step "汇总"
    foreach ($r in $results) {
        $tag = if ($r.Level -eq 'OK') { '[OK]' } elseif ($r.Level -eq 'WARN') { '[!!]' } else { '[XX]' }
        $color = if ($r.Level -eq 'OK') { 'Green' } elseif ($r.Level -eq 'WARN') { 'Yellow' } else { 'Red' }
        Write-Host ("  {0} {1,-16} {2}" -f $tag, $r.Ip, $r.Title) -ForegroundColor $color
    }
}

# 退出码给 .bat 包装和批处理看：
#   0 = 通了，能用
#   1 = 被墙 / 完全不通，换 IP
#   2 = IP 没被整封，但握手不成，先查服务/端口，别急着换机器
if (@($results | Where-Object { $_.Level -eq 'BAD' }).Count -gt 0) { exit 1 }
if (@($results | Where-Object { $_.Level -eq 'WARN' }).Count -gt 0) { exit 2 }
exit 0
