#Requires -Version 5.1
<#
.SYNOPSIS
    中国矿业大学校园网自动登录 / 断网自动重连（Windows）

.DESCRIPTION
    通过校园网认证服务器（默认 http://10.2.5.251:801）的 ePortal 接口，
    使用“学号@运营商”账号自动完成认证；认证后会做真实联网校验，
    校验不通过时自动“注销 -> 重登 -> 刷新 DNS -> 续租 IP”。

.PARAMETER ConfigPath
    配置文件路径，默认脚本目录下的 config.json。

.PARAMETER Force
    跳过“当前是否已联网”的判断，强制执行一次认证（切换账号或排查问题时使用）。

.PARAMETER Watch
    守护模式：常驻后台，定时检测，断网自动重连。

.PARAMETER Diagnose
    只打印诊断信息（网卡、门户、联网探测结果），不执行登录。

.PARAMETER VerboseLog
    把每次认证尝试的细节也写入日志（DEBUG 级别）。

.PARAMETER IntervalSeconds
    守护模式下的检测间隔（秒），默认取配置文件，最小 20。

.PARAMETER PortalHost
    临时覆盖认证服务器地址。

.PARAMETER PortalPort
    临时覆盖认证服务器端口。

.PARAMETER Quiet
    不在控制台输出，只写日志。

.EXAMPLE
    .\Connect-CampusNet.ps1
    执行一次“检测 -> 认证 -> 联网校验”，适合计划任务每分钟调用。

.EXAMPLE
    .\Connect-CampusNet.ps1 -Watch
    常驻后台守护，断网自动重连。

.EXAMPLE
    .\Connect-CampusNet.ps1 -Diagnose -VerboseLog
    输出诊断信息，排查“连上 WiFi 却上不了网”的原因。
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [switch]$Force,
    [switch]$Watch,
    [switch]$Diagnose,
    [switch]$VerboseLog,
    [int]$IntervalSeconds = 0,
    [string]$PortalHost = '',
    [int]$PortalPort = 0,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# 全局状态
# ---------------------------------------------------------------------------
$script:Config = $null
$script:LogFile = ''
$script:VerboseLog = $false
$script:Quiet = $false
$script:LastFailureKind = ''
$script:IsAdmin = $false

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal -ArgumentList $identity
    $script:IsAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }

# 让 HTTPS 探测在 Windows PowerShell 5.1 下也能正常工作
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11
    [Net.ServicePointManager]::DefaultConnectionLimit = 20
    [Net.ServicePointManager]::Expect100Continue = $false
} catch { }

# ---------------------------------------------------------------------------
# 日志
# ---------------------------------------------------------------------------
function Initialize-Log {
    $candidates = New-Object System.Collections.ArrayList
    if ($script:Config.LogFile) {
        [void]$candidates.Add([string]$script:Config.LogFile)
    } else {
        if ($env:LOCALAPPDATA) {
            [void]$candidates.Add((Join-Path $env:LOCALAPPDATA 'CUMTNet\campusnet.log'))
        }
        $scriptDir = $PSScriptRoot
        if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
        [void]$candidates.Add((Join-Path $scriptDir 'campusnet.log'))
    }

    foreach ($path in $candidates) {
        try {
            $dir = Split-Path -Parent $path
            if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
            }
            if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path -ErrorAction SilentlyContinue).Length -gt 2MB) {
                Move-Item -LiteralPath $path -Destination ($path + '.1') -Force -ErrorAction SilentlyContinue
            }
            [System.IO.File]::AppendAllText($path, '')
            $script:LogFile = $path
            return
        } catch { }
    }
    $script:LogFile = ''
}

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )
    if ($Level -eq 'DEBUG' -and -not $script:VerboseLog) { return }

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

    if (-not $script:Quiet) {
        $color = 'Gray'
        switch ($Level) {
            'OK'    { $color = 'Green' }
            'WARN'  { $color = 'Yellow' }
            'ERROR' { $color = 'Red' }
            'DEBUG' { $color = 'DarkGray' }
            'INFO'  { $color = 'Gray' }
        }
        Write-Host $line -ForegroundColor $color
    }

    if ($script:LogFile) {
        try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
    }
}

# ---------------------------------------------------------------------------
# HTTP / 网络基础函数
# ---------------------------------------------------------------------------
function Read-ResponseBody {
    param($Response)
    $stream = $null
    try {
        $stream = $Response.GetResponseStream()
        if (-not $stream) { return '' }
        $memory = New-Object System.IO.MemoryStream
        $stream.CopyTo($memory)
        $bytes = $memory.ToArray()
        if (-not $bytes -or $bytes.Length -eq 0) { return '' }

        $encoding = [System.Text.Encoding]::UTF8
        $charset = [string]$Response.CharacterSet
        if ($charset) {
            try { $encoding = [System.Text.Encoding]::GetEncoding($charset) } catch { }
        }
        return $encoding.GetString($bytes).TrimStart([char]0xFEFF)
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Invoke-Http {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$TimeoutMs = 4000,
        [switch]$NoRedirect,
        [string]$UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
    )

    $result = [pscustomobject]@{
        Url = $Url; Ok = $false; Status = 0; Body = ''; Error = ''; FinalUrl = $Url; ContentType = ''
    }

    $request = $null
    $response = $null
    try {
        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.Method = 'GET'
        $request.Timeout = $TimeoutMs
        $request.ReadWriteTimeout = $TimeoutMs
        $request.AllowAutoRedirect = (-not $NoRedirect)
        $request.MaximumAutomaticRedirections = 5
        $request.UserAgent = $UserAgent
        $request.Accept = 'text/html,application/json,*/*'
        $request.KeepAlive = $false
        $request.Proxy = $null

        $response = $request.GetResponse()
        $result.Ok = $true
        $result.Status = [int]$response.StatusCode
        $result.FinalUrl = $response.ResponseUri.AbsoluteUri
        $result.ContentType = [string]$response.ContentType
        $result.Body = Read-ResponseBody -Response $response
    } catch [System.Net.WebException] {
        $webError = $_.Exception
        $result.Error = $webError.Message
        if ($webError.Response) {
            try {
                $response = $webError.Response
                $result.Status = [int]$response.StatusCode
                $result.FinalUrl = $response.ResponseUri.AbsoluteUri
                $result.ContentType = [string]$response.ContentType
                $result.Body = Read-ResponseBody -Response $response
            } catch { }
        }
    } catch {
        $result.Error = $_.Exception.Message
    } finally {
        if ($response) { try { $response.Dispose() } catch { } }
    }
    return $result
}

function Get-LocalAddressFor {
    param(
        [System.Net.IPAddress]$TargetAddress,
        [int]$Port = 80
    )
    if (-not $TargetAddress) { return $null }
    $socket = $null
    try {
        $socket = New-Object System.Net.Sockets.Socket -ArgumentList @(
            [System.Net.Sockets.AddressFamily]::InterNetwork,
            [System.Net.Sockets.SocketType]::Dgram,
            [System.Net.Sockets.ProtocolType]::Udp
        )
        $socket.Connect($TargetAddress, $Port)
        return $socket.LocalEndPoint.Address
    } catch {
        return $null
    } finally {
        if ($socket) { try { $socket.Dispose() } catch { } }
    }
}

function Get-WlanSsid {
    try {
        $lines = & netsh.exe wlan show interfaces 2>$null
        if ($LASTEXITCODE -ne 0) { return '' }
        foreach ($line in $lines) {
            if ($line -match '^\s*SSID\s*:\s*(.+?)\s*$') { return $Matches[1] }
        }
    } catch { }
    return ''
}

function Connect-Wlan {
    param([string]$Ssid)
    if (-not $Ssid) { return $false }
    Write-Log ("尝试自动连接 WiFi：{0}" -f $Ssid) 'INFO'
    try {
        $profiles = (& netsh.exe wlan show profiles 2>$null) -join "`n"
        if ($profiles -notmatch [regex]::Escape($Ssid)) {
            Write-Log ("系统没有保存名为 {0} 的 WiFi，请先手动连接一次。" -f $Ssid) 'WARN'
            return $false
        }
        $connectOutput = & netsh.exe wlan connect "name=$Ssid" "ssid=$Ssid" 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Get-NetworkInfo {
    param(
        [string]$TargetHost = '10.2.5.251',
        [int]$TargetPort = 801
    )

    $info = [pscustomobject]@{
        IP = ''; MAC = ''; Gateway = ''; InterfaceName = ''; IsWireless = $false; Ssid = ''
    }

    $targetIp = $null
    try {
        $targetIp = [System.Net.IPAddress]::Parse($TargetHost)
    } catch {
        try {
            $targetIp = @([System.Net.Dns]::GetHostAddresses($TargetHost) |
                Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork }) |
                Select-Object -First 1
        } catch { }
    }

    $routeIp = Get-LocalAddressFor -TargetAddress $targetIp -Port $TargetPort
    if (-not $routeIp) {
        try {
            $routeIp = Get-LocalAddressFor -TargetAddress ([System.Net.IPAddress]::Parse('223.5.5.5')) -Port 53
        } catch { }
    }

    $candidates = New-Object System.Collections.ArrayList
    foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        try {
            if ($nic.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
            if ($nic.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback) { continue }
            if ($nic.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Tunnel) { continue }

            $props = $nic.GetIPProperties()
            $ipv4 = @($props.UnicastAddresses | Where-Object {
                $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
                -not $_.Address.IsLoopback -and
                -not ([string]$_.Address).StartsWith('169.254.')
            })
            if ($ipv4.Count -eq 0) { continue }

            $gateways = @($props.GatewayAddresses | Where-Object {
                $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
                -not $_.Address.Equals([System.Net.IPAddress]::Any)
            })

            [void]$candidates.Add([pscustomobject]@{
                Nic = $nic
                IP = $ipv4[0].Address
                Gateway = $(if ($gateways.Count -gt 0) { $gateways[0].Address } else { $null })
                HasGateway = ($gateways.Count -gt 0)
            })
        } catch { }
    }

    $chosen = $null
    if ($routeIp) {
        $chosen = $candidates | Where-Object { $_.IP.Equals($routeIp) } | Select-Object -First 1
    }
    if (-not $chosen) {
        $chosen = $candidates | Where-Object { $_.HasGateway } | Select-Object -First 1
    }
    if (-not $chosen -and $candidates.Count -gt 0) {
        $chosen = $candidates[0]
    }
    if (-not $chosen) { return $info }

    $info.IP = [string]$chosen.IP
    if ($chosen.Gateway) { $info.Gateway = [string]$chosen.Gateway }
    $info.InterfaceName = $chosen.Nic.Name

    $macBytes = $chosen.Nic.GetPhysicalAddress().GetAddressBytes()
    if ($macBytes -and $macBytes.Length -eq 6) {
        $info.MAC = (($macBytes | ForEach-Object { $_.ToString('X2') }) -join ':')
    }

    if ($chosen.Nic.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Wireless80211) {
        $info.IsWireless = $true
        $info.Ssid = Get-WlanSsid
    }
    return $info
}

function Test-TcpPort {
    param(
        [string]$ComputerName,
        [int]$Port,
        [int]$TimeoutMs = 2000
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        try { $client.Close() } catch { }
    }
}

function Resolve-PortalPort {
    param([string]$HostName, [int]$Preferred)
    if ($Preferred -gt 0 -and (Test-TcpPort -ComputerName $HostName -Port $Preferred -TimeoutMs 2500)) {
        return $Preferred
    }
    foreach ($port in @(801, 80, 8080)) {
        if ($port -ne $Preferred -and (Test-TcpPort -ComputerName $HostName -Port $port -TimeoutMs 2000)) {
            return $port
        }
    }
    return 0
}

# ---------------------------------------------------------------------------
# ePortal 认证
# ---------------------------------------------------------------------------
function ConvertFrom-PortalJson {
    param([string]$Body)
    if ([string]::IsNullOrWhiteSpace($Body)) { return $null }
    $text = $Body.Trim()
    $start = $text.IndexOf('{')
    $end = $text.LastIndexOf('}')
    if ($start -lt 0 -or $end -le $start) { return $null }
    $json = $text.Substring($start, $end - $start + 1)
    try { return ($json | ConvertFrom-Json) } catch { return $null }
}

function Get-PortalMessage {
    param($Obj, [string]$Body)
    if ($Obj) {
        foreach ($name in @('msg', 'message', 'error')) {
            if ($Obj.PSObject.Properties[$name] -and $Obj.PSObject.Properties[$name].Value) {
                return [string]$Obj.PSObject.Properties[$name].Value
            }
        }
    }
    if ($Body) {
        $plain = ($Body -replace '<[^>]+>', ' ' -replace '\s+', ' ').Trim()
        if ($plain.Length -gt 200) { $plain = $plain.Substring(0, 200) }
        return $plain
    }
    return ''
}

function Test-PortalSuccess {
    param($Obj)
    if (-not $Obj) { return $false }

    $result = ''
    if ($Obj.PSObject.Properties['result']) { $result = ([string]$Obj.result).ToLowerInvariant() }
    if ($result -eq '1' -or $result -eq 'ok' -or $result -eq 'true' -or $result -eq 'success') { return $true }

    $msg = ''
    if ($Obj.PSObject.Properties['msg']) { $msg = [string]$Obj.msg }
    if ($msg -match '认证成功|登录成功|已在线|已经在线|当前已登录') { return $true }

    return $false
}

function Get-PortalFailureKind {
    param($Obj)
    if (-not $Obj) { return 'unknown' }
    $msg = ''
    if ($Obj.PSObject.Properties['msg']) { $msg = [string]$Obj.msg }
    if (-not $msg) { return 'unknown' }
    if ($msg -match '已在线|在线数|终端数|上限|设备数') { return 'online' }
    if ($msg -match '密码|账号|帐号|用户名|欠费|停机|冻结|未注册|不存在|绑定') { return 'auth' }
    return 'unknown'
}

function New-PortalUrl {
    param(
        [ValidateSet('legacy', 'portal')][string]$Style,
        [ValidateSet('login', 'logout')][string]$Action,
        [int]$Port,
        [string]$Query
    )
    $portalHost = [string]$script:Config.PortalHost
    if ($Style -eq 'legacy') {
        return ('http://{0}:{1}/eportal/?c=Portal&a={2}&{3}' -f $portalHost, $Port, $Action, $Query)
    }
    return ('http://{0}:{1}/eportal/portal/{2}?{3}' -f $portalHost, $Port, $Action, $Query)
}

function Invoke-PortalLogin {
    param($Net, [int]$Port)

    $cfg = $script:Config
    $account = [string]$cfg.Account
    if ($account -notmatch '@') { $account = '{0}@{1}' -f $account, $cfg.Carrier }
    $userEnc = [Uri]::EscapeDataString($account)
    $passEnc = [Uri]::EscapeDataString([string]$cfg.Password)

    $variants = @(
        @{ Ip = [string]$Net.IP; Mac = [string]$Net.MAC; Label = '带本机IP/MAC' },
        @{ Ip = ''; Mac = ''; Label = '由网关自动识别' }
    )

    $lastMessage = '认证接口无有效返回'
    $lastKind = 'unknown'

    foreach ($style in @('legacy', 'portal')) {
        foreach ($variant in $variants) {
            $nonce = Get-Random -Minimum 1000 -Maximum 9999
            $query = 'login_method=1&user_account={0}&user_password={1}&wlan_user_ip={2}&wlan_user_mac={3}&wlan_ac_ip=&wlan_ac_name=&jsVersion=4.2&v={4}&lang=zh' -f `
                $userEnc, $passEnc, [Uri]::EscapeDataString($variant.Ip), [Uri]::EscapeDataString($variant.Mac), $nonce
            $url = New-PortalUrl -Style $style -Action 'login' -Port $Port -Query $query

            $response = Invoke-Http -Url $url -TimeoutMs 6000
            $obj = ConvertFrom-PortalJson -Body $response.Body
            $message = Get-PortalMessage -Obj $obj -Body $response.Body
            if (-not $message) { $message = ('HTTP {0} {1}' -f $response.Status, $response.Error) }

            if (Test-PortalSuccess $obj) {
                Write-Log ("认证接口返回成功（{0} 接口，{1}）：{2}" -f $style, $variant.Label, $message) 'OK'
                return [pscustomobject]@{ Success = $true; Message = $message; Kind = 'ok' }
            }

            $kind = Get-PortalFailureKind -Obj $obj
            $lastMessage = $message
            $lastKind = $kind

            Write-Log ("认证未成功（{0} 接口 / {1}）：HTTP {2}，返回：{3}" -f $style, $variant.Label, $response.Status, $message) 'DEBUG'
            if ($response.Body -and -not $obj) {
                $snippet = ($response.Body -replace '\s+', ' ').Trim()
                if ($snippet.Length -gt 300) { $snippet = $snippet.Substring(0, 300) }
                Write-Log ("非 JSON 返回内容：{0}" -f $snippet) 'DEBUG'
            }

            if ($kind -eq 'auth') {
                return [pscustomobject]@{ Success = $false; Message = $message; Kind = 'auth' }
            }
            Start-Sleep -Milliseconds 250
        }
    }

    return [pscustomobject]@{ Success = $false; Message = $lastMessage; Kind = $lastKind }
}

function Invoke-PortalLogout {
    param($Net, [int]$Port)

    $cfg = $script:Config
    $accounts = @('drcom', [string]$cfg.Account)

    foreach ($style in @('legacy', 'portal')) {
        foreach ($account in $accounts) {
            $nonce = Get-Random -Minimum 1000 -Maximum 9999
            $query = 'login_method=1&user_account={0}&user_password=123&ac_logout=1&register_mode=1&wlan_user_ip={1}&wlan_user_mac={2}&wlan_ac_ip=&wlan_ac_name=&v={3}' -f `
                [Uri]::EscapeDataString($account), [Uri]::EscapeDataString([string]$Net.IP), [Uri]::EscapeDataString([string]$Net.MAC), $nonce
            $url = New-PortalUrl -Style $style -Action 'logout' -Port $Port -Query $query

            $response = Invoke-Http -Url $url -TimeoutMs 5000
            $obj = ConvertFrom-PortalJson -Body $response.Body
            $message = Get-PortalMessage -Obj $obj -Body $response.Body

            Write-Log ("注销请求（{0} 接口 / {1}）：{2}" -f $style, $account, $message) 'DEBUG'
            if ($obj -and (([string]$obj.result -eq '1') -or ($message -match '注销成功|成功'))) {
                return [pscustomobject]@{ Success = $true; Message = $message }
            }
        }
    }

    return [pscustomobject]@{ Success = $false; Message = '注销接口未返回成功' }
}

# ---------------------------------------------------------------------------
# 联网校验
# ---------------------------------------------------------------------------
function Test-Dns {
    try {
        $addresses = [System.Net.Dns]::GetHostAddresses('www.baidu.com')
        return ($addresses.Count -gt 0)
    } catch {
        return $false
    }
}

function Get-InternetStatus {
    param([int]$ProbeTimeoutMs = 3000)

    $detail = New-Object System.Collections.ArrayList
    $portalHost = [string]$script:Config.PortalHost

    foreach ($url in @('http://connect.rom.miui.com/generate_204', 'http://wifi.vivo.com.cn/generate_204')) {
        $probe = Invoke-Http -Url $url -TimeoutMs $ProbeTimeoutMs -NoRedirect
        [void]$detail.Add(('{0}={1}' -f ([Uri]$url).Host, $probe.Status))
        if ($probe.Status -eq 204) {
            return [pscustomobject]@{ Online = $true; Detail = ('204 via ' + ([Uri]$url).Host) }
        }
    }

    $baidu = Invoke-Http -Url 'http://www.baidu.com/' -TimeoutMs $ProbeTimeoutMs
    [void]$detail.Add(('baidu={0}' -f $baidu.Status))
    if ($baidu.Status -eq 200 -and $baidu.Body -match 'baidu\.com' -and $baidu.FinalUrl -notmatch [regex]::Escape($portalHost)) {
        return [pscustomobject]@{ Online = $true; Detail = 'baidu 200' }
    }

    $qq = Invoke-Http -Url 'http://www.qq.com/' -TimeoutMs $ProbeTimeoutMs
    [void]$detail.Add(('qq={0}' -f $qq.Status))
    if ($qq.Status -eq 200 -and $qq.Body -match 'qq\.com' -and $qq.FinalUrl -notmatch [regex]::Escape($portalHost)) {
        return [pscustomobject]@{ Online = $true; Detail = 'qq 200' }
    }

    if (-not (Test-Dns)) { [void]$detail.Add('dns=fail') }
    return [pscustomobject]@{ Online = $false; Detail = ($detail -join ', ') }
}

function Wait-Internet {
    param([int]$TimeoutSeconds = 30)
    # 认证前 DNS 可能被门户劫持过，先刷新缓存再用真实内容校验
    try { & ipconfig.exe /flushdns 2>$null | Out-Null } catch { }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ((Get-InternetStatus).Online) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

# ---------------------------------------------------------------------------
# 诊断
# ---------------------------------------------------------------------------
function Invoke-Diagnose {
    $cfg = $script:Config
    Write-Log '================= 校园网诊断 =================' 'INFO'
    Write-Log ("时间：{0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) 'INFO'
    Write-Log ("系统：{0}，PowerShell {1}，管理员：{2}" -f [Environment]::OSVersion.VersionString, $PSVersionTable.PSVersion.ToString(), $script:IsAdmin) 'INFO'
    Write-Log ("认证地址：http://{0}:{1}/，账号：{2}@{3}" -f $cfg.PortalHost, $cfg.PortalPort, $cfg.Account, $cfg.Carrier) 'INFO'

    $net = Get-NetworkInfo -TargetHost ([string]$cfg.PortalHost) -TargetPort ([int]$cfg.PortalPort)
    Write-Log ("本机 IP={0}，MAC={1}，网关={2}，网卡={3}，无线={4}" -f $net.IP, $net.MAC, $net.Gateway, $net.InterfaceName, $net.IsWireless) 'INFO'
    Write-Log ("当前 WiFi：{0}" -f $net.Ssid) 'INFO'

    if ($net.Gateway) {
        $ping = $false
        try { $ping = Test-Connection -ComputerName $net.Gateway -Count 1 -Quiet -ErrorAction SilentlyContinue } catch { }
        Write-Log ("网关 {0} ping：{1}" -f $net.Gateway, $ping) 'INFO'
    }

    Write-Log ("DNS 解析 www.baidu.com：{0}" -f (Test-Dns)) 'INFO'

    foreach ($port in @(80, 801, 8080)) {
        Write-Log ("TCP {0}:{1} 可达：{2}" -f $cfg.PortalHost, $port, (Test-TcpPort -ComputerName ([string]$cfg.PortalHost) -Port $port -TimeoutMs 2000)) 'INFO'
    }

    $root = Invoke-Http -Url ('http://{0}/' -f $cfg.PortalHost) -TimeoutMs 4000
    Write-Log ("门户首页：HTTP {0}，最终地址 {1}，长度 {2}" -f $root.Status, $root.FinalUrl, $root.Body.Length) 'INFO'
    if ($root.Body) {
        $title = ''
        if ($root.Body -match '<title>(.*?)</title>') { $title = $Matches[1] }
        if ($title) { Write-Log ("门户标题：{0}" -f $title.Trim()) 'INFO' }
        foreach ($keyword in @('eportal', 'srun', '深澜', '锐捷', '注销', 'Portal')) {
            if ($root.Body -match [regex]::Escape($keyword)) {
                Write-Log ("首页包含关键字：{0}" -f $keyword) 'INFO'
            }
        }
    }

    $eportal = Invoke-Http -Url ('http://{0}:801/eportal/' -f $cfg.PortalHost) -TimeoutMs 4000
    $eportalText = ($eportal.Body -replace '\s+', ' ').Trim()
    if ($eportalText.Length -gt 200) { $eportalText = $eportalText.Substring(0, 200) }
    Write-Log ("eportal 接口：HTTP {0}，长度 {1}，内容：{2}" -f $eportal.Status, $eportal.Body.Length, $eportalText) 'INFO'

    $status = Get-InternetStatus
    Write-Log ("联网探测：在线={0}，明细={1}" -f $status.Online, $status.Detail) 'INFO'
    Write-Log '==============================================' 'INFO'
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
function Invoke-CampusLogin {
    param(
        [switch]$ForceLogin,
        [switch]$SuppressOnlineLog
    )

    $cfg = $script:Config
    $script:LastFailureKind = ''

    # 1. 已联网则直接结束（守护模式不刷日志）
    if (-not $ForceLogin) {
        if ((Get-InternetStatus).Online) {
            if (-not $SuppressOnlineLog) { Write-Log '当前网络正常，无需认证。' 'OK' }
            return $true
        }
        if ($SuppressOnlineLog) {
            Write-Log '检测到无法上网，开始自动认证。' 'DEBUG'
        } else {
            Write-Log '检测到无法上网，开始校园网认证...' 'WARN'
        }
    }

    # 2. 取本机在校园网中的 IP / MAC
    $net = Get-NetworkInfo -TargetHost ([string]$cfg.PortalHost) -TargetPort ([int]$cfg.PortalPort)
    if (-not $net.IP -and $cfg.Ssid) {
        Write-Log ("未获取到 IPv4，尝试自动连接 WiFi：{0}" -f $cfg.Ssid) 'WARN'
        Connect-Wlan -Ssid ([string]$cfg.Ssid) | Out-Null
        for ($i = 0; $i -lt 10; $i++) {
            Start-Sleep -Seconds 2
            $net = Get-NetworkInfo -TargetHost ([string]$cfg.PortalHost) -TargetPort ([int]$cfg.PortalPort)
            if ($net.IP) { break }
        }
    }
    if (-not $net.IP) {
        Write-Log '未获取到 IPv4 地址：请确认已连接校园 WiFi 或插好网线。' 'ERROR'
        return $false
    }
    Write-Log ("本机 IP={0}，MAC={1}，网关={2}" -f $net.IP, $net.MAC, $net.Gateway) 'DEBUG'
    if ($net.Ssid) { Write-Log ("当前 WiFi：{0}" -f $net.Ssid) 'DEBUG' }

    # 3. 确认认证服务器可达
    $port = Resolve-PortalPort -HostName ([string]$cfg.PortalHost) -Preferred ([int]$cfg.PortalPort)
    if ($port -eq 0) {
        Write-Log ("认证服务器 {0} 的 80/801/8080 端口均不可达：可能未连接校园网，或认证服务器故障。" -f $cfg.PortalHost) 'ERROR'
        return $false
    }
    if ($port -ne [int]$cfg.PortalPort) {
        Write-Log ("认证端口 {0} 不可用，改用 {1}。" -f $cfg.PortalPort, $port) 'WARN'
    }

    # 4. 第一次认证
    $login = Invoke-PortalLogin -Net $net -Port $port
    if ($login.Success) {
        if (Wait-Internet -TimeoutSeconds ([int]$cfg.VerifyTimeoutSeconds)) {
            Write-Log '认证成功，联网校验通过。' 'OK'
            return $true
        }
        Write-Log '认证接口返回成功，但仍无法上网（常见于会话失效/多设备占线），执行注销重登...' 'WARN'
    } else {
        Write-Log ("认证失败：{0}" -f $login.Message) 'ERROR'
        if ($login.Kind -eq 'auth') {
            $script:LastFailureKind = 'auth'
            Write-Log '服务器拒绝了账号或密码，请检查 config.json；已停止重试以避免账号被锁。' 'ERROR'
            return $false
        }
    }

    # 5. 注销 -> 重新认证
    $logout = Invoke-PortalLogout -Net $net -Port $port
    Start-Sleep -Seconds 1
    $login2 = Invoke-PortalLogin -Net $net -Port $port
    if ($login2.Success -and (Wait-Internet -TimeoutSeconds ([int]$cfg.VerifyTimeoutSeconds))) {
        Write-Log '注销并重新认证成功，联网校验通过。' 'OK'
        return $true
    }

    # 6. 修复：刷新 DNS；管理员权限下续租 IP
    Write-Log '认证后仍无法上网，尝试刷新 DNS 缓存...' 'WARN'
    try { & ipconfig.exe /flushdns | Out-Null } catch { }

    if ($script:IsAdmin) {
        try {
            Write-Log ("续租 IP（网卡：{0}）..." -f $net.InterfaceName) 'WARN'
            & ipconfig.exe /renew $net.InterfaceName | Out-Null
            Start-Sleep -Seconds 3
            $net = Get-NetworkInfo -TargetHost ([string]$cfg.PortalHost) -TargetPort ([int]$cfg.PortalPort)
            $port = Resolve-PortalPort -HostName ([string]$cfg.PortalHost) -Preferred ([int]$cfg.PortalPort)
            if ($net.IP -and $port -gt 0) {
                $login3 = Invoke-PortalLogin -Net $net -Port $port
                if ($login3.Success -and (Wait-Internet -TimeoutSeconds ([int]$cfg.VerifyTimeoutSeconds))) {
                    Write-Log '续租 IP 后重新认证成功，联网校验通过。' 'OK'
                    return $true
                }
            }
        } catch {
            Write-Log ("续租 IP 失败：{0}" -f $_.Exception.Message) 'DEBUG'
        }
    } else {
        Write-Log '当前不是管理员权限，跳过 IP 续租修复。' 'DEBUG'
    }

    Write-Log '自动登录未成功：认证或联网校验失败，可运行 -Diagnose 查看详细诊断。' 'ERROR'
    return $false
}

function Start-WatchLoop {
    $interval = [int]$script:Config.IntervalSeconds
    if ($interval -lt 20) { $interval = 20 }

    Write-Log ("守护模式启动：每 {0} 秒检测一次，断网自动重连。" -f $interval) 'INFO'
    $lastState = $null
    $failureCount = 0

    while ($true) {
        $online = $false
        try {
            $online = Invoke-CampusLogin -SuppressOnlineLog
        } catch {
            Write-Log ("运行异常：{0}" -f $_.Exception.Message) 'ERROR'
        }

        if ($online) {
            if ($lastState -ne $true) { Write-Log '网络状态：在线' 'OK' }
            $lastState = $true
            $failureCount = 0
            $sleep = $interval
        } else {
            if ($lastState -ne $false) { Write-Log '网络状态：离线，后台继续重试' 'ERROR' }
            $lastState = $false
            $failureCount++

            if ($script:LastFailureKind -eq 'auth') {
                $sleep = 600
            } else {
                $exponent = [Math]::Min($failureCount - 1, 4)
                $sleep = [Math]::Min(300, [int]($interval * [Math]::Pow(2, $exponent)))
            }
            Write-Log ("第 {0} 次重试失败，{1} 秒后再次尝试。" -f $failureCount, $sleep) 'DEBUG'
        }

        Start-Sleep -Seconds ([int]$sleep)
    }
}

# ===========================================================================
# 入口
# ===========================================================================
$script:VerboseLog = ($VerboseLog.IsPresent -or $Diagnose.IsPresent)
$script:Quiet = $Quiet.IsPresent

$script:Config = [ordered]@{
    PortalHost           = '10.2.5.251'
    PortalPort           = 801
    Account              = ''
    Password             = ''
    Carrier              = 'cmcc'
    Ssid                 = ''
    IntervalSeconds      = 30
    VerifyTimeoutSeconds = 30
    LogFile              = ''
}

if (-not $ConfigPath) {
    $scriptDir = $PSScriptRoot
    if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
    $ConfigPath = Join-Path $scriptDir 'config.json'
}

if (Test-Path -LiteralPath $ConfigPath) {
    try {
        $rawConfig = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
        $jsonConfig = $rawConfig | ConvertFrom-Json
        foreach ($property in $jsonConfig.PSObject.Properties) {
            if ($script:Config.Contains($property.Name)) {
                $script:Config[$property.Name] = $property.Value
            }
        }
    } catch {
        Write-Warning ("配置文件解析失败：{0}，请检查 config.json 格式。" -f $_.Exception.Message)
    }
} else {
    Write-Warning ("未找到配置文件：{0}，请参照 config.example.json 创建并填写账号密码。" -f $ConfigPath)
}

if ($PortalHost) { $script:Config.PortalHost = $PortalHost }
if ($PortalPort -gt 0) { $script:Config.PortalPort = $PortalPort }
if ($IntervalSeconds -gt 0) { $script:Config.IntervalSeconds = $IntervalSeconds }

# 运营商写法归一化：支持“移动 / 中国移动 / cmcc”等写法
$carrierAliases = @{
    '移动' = 'cmcc'; '中国移动' = 'cmcc'; 'cmcc' = 'cmcc'; 'yidong' = 'cmcc'
    '联通' = 'unicom'; '中国联通' = 'unicom'; 'unicom' = 'unicom'; 'liantong' = 'unicom'
    '电信' = 'telecom'; '中国电信' = 'telecom'; 'telecom' = 'telecom'; 'dianxin' = 'telecom'
}
$carrierKey = ([string]$script:Config.Carrier).Trim().ToLowerInvariant()
if ($carrierAliases.ContainsKey($carrierKey)) {
    $script:Config.Carrier = $carrierAliases[$carrierKey]
} else {
    Write-Warning ("未知运营商 {0}，将按原样拼接到账号后面。" -f $script:Config.Carrier)
}

$script:Config.PortalPort = [int]$script:Config.PortalPort
$script:Config.IntervalSeconds = [int]$script:Config.IntervalSeconds
$script:Config.VerifyTimeoutSeconds = [int]$script:Config.VerifyTimeoutSeconds

Initialize-Log
Write-Log '================ 校园网自动登录 ================' 'INFO'
if (([string]$script:Config.Account).Trim() -ne '') {
    Write-Log ("认证地址 http://{0}:{1}/，账号 {2}@{3}" -f $script:Config.PortalHost, $script:Config.PortalPort, $script:Config.Account, $script:Config.Carrier) 'INFO'
} else {
    Write-Log ("认证地址 http://{0}:{1}/（尚未配置账号）" -f $script:Config.PortalHost, $script:Config.PortalPort) 'INFO'
}
if ($script:LogFile) { Write-Log ("日志文件：{0}" -f $script:LogFile) 'DEBUG' }

if (-not $Diagnose -and (([string]$script:Config.Account).Trim() -eq '' -or [string]$script:Config.Password -eq '')) {
    Write-Log '未配置账号或密码：请用记事本打开 config.json，填写 Account（学号）和 Password 后重试。' 'ERROR'
    exit 1
}

if ($Diagnose) {
    Invoke-Diagnose
    exit 0
}

if ($Watch) {
    $mutex = New-Object System.Threading.Mutex($false, 'Local\CUMTNetAutoLogin')
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne(0)
        } catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            Write-Log '已有守护进程在运行，本实例退出。' 'WARN'
            exit 0
        }
        Start-WatchLoop
    } finally {
        if ($acquired) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
} else {
    $ok = Invoke-CampusLogin -ForceLogin:$Force.IsPresent
    if ($ok) { exit 0 } else { exit 1 }
}
