<#
=======================================================================
 陕西师范大学 (SNNU) 校园网自动认证脚本
=======================================================================
 认证方式: SNNU 自建网络 Portal (非深澜/锐捷)
   Portal   : http://202.117.144.205:8601/snnuportal/
   登录接口 : POST /snnuportal/login
   断开接口 : GET  /snnuportal/logoff
   状态页面 : GET  /snnuportal/login.jsp
             (未认证 => 登录表单; 已认证 => 显示"当前登录账号")

 依赖: 无。纯 Windows PowerShell 5.1,不需要 Python / 第三方模块。

 用法:
   .\SNNU-AutoLogin.ps1 -Setup          # 首次配置/改配置: 交互式输入账号、代理商、密码
   .\SNNU-AutoLogin.ps1                 # 检查一次,离线就认证 (首次运行会自动进入配置引导)
   .\SNNU-AutoLogin.ps1 -Status         # 只看当前状态,不做任何操作
   .\SNNU-AutoLogin.ps1 -Daemon         # 常驻后台,掉线自动重连(开机自启用这个)
   .\SNNU-AutoLogin.ps1 -Force          # 先断开再登录(强制重新认证)
   .\SNNU-AutoLogin.ps1 -Logout         # 断开校园网
   .\SNNU-AutoLogin.ps1 -Diagnose       # 打印诊断信息
   .\SNNU-AutoLogin.ps1 -TestLogin      # 只验证账号密码,不断开现有连接

 说明: 首次运行时若没有 config.json(或账号密码为空),会自动进入交互式配置引导。
       密码默认用 DPAPI 加密保存,只有本机本用户能解开。
       守护进程(-Daemon)永远不会弹交互提示, 配置缺失时它会报错退出而不是卡住。
=======================================================================
#>

[CmdletBinding()]
param(
    # 配置文件路径,默认同目录 config.json
    [string]$Config,

    # 常驻模式:循环检查,掉线自动重连
    [switch]$Daemon,

    # 只查询状态,不做任何认证操作
    [switch]$Status,

    # 强制重新认证(先 logoff 再 login)
    [switch]$Force,

    # 主动断开校园网
    [switch]$Logout,

    # 打印诊断信息(网络/portal 可达性/配置)
    [switch]$Diagnose,

    # 只验证账号密码是否正确(不断开现有连接,安全测试)
    [switch]$TestLogin,

    # 首次配置 / 重新配置: 交互式输入账号、代理商、密码,并写入 config.json
    [switch]$Setup,

    # 配合 -Setup 使用, 直接指定代理商(不输入则交互选择):
    #   '' = 校园网(默认) / unicom = 联通 / mobile = 移动 / telecom = 电信
    [string]$Isp,

    # 覆盖检查间隔(秒)
    [int]$Interval = 0,

    # 覆盖账号/密码。配合 -Setup 时作为配置输入(不提示);单独使用时仅为临时覆盖
    [string]$Account,
    [string]$Password,

    # 输出到控制台(默认常驻模式只写日志)
    [switch]$Verbose2
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 记录 -Isp 是否被显式指定('' 是合法值,表示校园网,所以不能用 $Isp 是否为空来判断)
$Script:IspProvided = $PSBoundParameters.ContainsKey('Isp')
$Script:IspParam    = $Isp

# ---------------------------------------------------------------- 常量
$Script:ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:LogDir     = Join-Path $Script:ScriptRoot 'logs'
$Script:LogFile    = Join-Path $Script:LogDir 'snnu-autologin.log'
$Script:MutexName  = 'Global\SNNU-AutoLogin-SingleInstance'

# ================================================================ 日志
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','OK','WARN','ERROR','DEBUG')][string]$Level = 'INFO'
    )
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"

    if (-not (Test-Path $Script:LogDir)) {
        New-Item -ItemType Directory -Path $Script:LogDir -Force | Out-Null
    }

    # 简单轮转,超过 1MB 就备份成 .old
    if (Test-Path $Script:LogFile) {
        $size = (Get-Item $Script:LogFile).Length
        if ($size -gt 1MB) {
            Move-Item $Script:LogFile "$Script:LogFile.old" -Force
        }
    }
    Add-Content -Path $Script:LogFile -Value $line -Encoding UTF8

    if ($Verbose2 -or -not $Daemon -or $Level -in @('OK','WARN','ERROR')) {
        $color = switch ($Level) {
            'OK'    { 'Green' }
            'WARN'  { 'Yellow' }
            'ERROR' { 'Red' }
            'DEBUG' { 'DarkGray' }
            default { 'Gray' }
        }
        Write-Host $line -ForegroundColor $color
    }
}

# ================================================================ 首次配置引导
# 判断当前环境能不能做交互式提问。
# 这一点非常重要: 守护进程(-Daemon)是计划任务用 wscript 无窗口启动的,
# 如果配置缺失时它去 Read-Host,就会永久挂住等待一个永远不会来的输入。
function Test-CanPrompt {
    if ($Daemon) { return $false }        # 守护模式永远不问

    # 用参数直接给了账号密码(脚本化安装)时不需要问
    if ($Account -and $Password) { return $false }

    try { if (-not [Environment]::UserInteractive) { return $false } } catch { return $false }
    try { if ([Console]::IsInputRedirected)  { return $false } } catch { return $false }
    try { if ([Console]::IsOutputRedirected) { return $false } } catch { return $false }
    return $true
}

function Read-PlainPassword {
    param([string]$Prompt)
    $sec = Read-Host $Prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# 统一的输入入口: 环境不能交互时给出人话错误,而不是抛 Read-Host 的原始异常
function Read-InputLine {
    param([string]$Prompt, [switch]$AsSecret)
    if (-not (Test-CanPrompt)) {
        throw ("当前环境没有可用的交互控制台,无法输入配置。`n" +
               "请在【普通 PowerShell 窗口】里运行:  .\SNNU-AutoLogin.ps1 -Setup`n" +
               "或用参数一次性给出:  .\SNNU-AutoLogin.ps1 -Setup -Account 学号 -Isp mobile -Password 密码")
    }
    try {
        if ($AsSecret) { return Read-PlainPassword $Prompt }
        return Read-Host $Prompt
    } catch {
        throw ("读取输入失败: $($_.Exception.Message)`n" +
               "请在【普通 PowerShell 窗口】里运行:  .\SNNU-AutoLogin.ps1 -Setup")
    }
}

# 交互式引导: 让用户自己输入账号 / 代理商 / 密码, 然后写入 config.json
function Invoke-Setup {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Defaults
    )

    $canPrompt = Test-CanPrompt

    Write-Host ''
    Write-Host '==========================================================' -ForegroundColor Cyan
    Write-Host ' 陕西师范大学校园网自动认证 - 首次配置' -ForegroundColor Cyan
    Write-Host '==========================================================' -ForegroundColor Cyan
    Write-Host ''

    # ---------------- 账号 ----------------
    $acc = $Account
    if (-not $acc) {
        while (-not $acc) {
            $acc = (Read-InputLine '请输入校园网账号(学号, 例如 20250001)').Trim()
            if (-not $acc) { Write-Host '  账号不能为空。' -ForegroundColor Yellow }
        }
    } else {
        Write-Host ("账号: {0}  (由参数提供)" -f $acc) -ForegroundColor Gray
    }

    # ---------------- 代理商 / 出口 ----------------
    $ispChoices = @(
        @{ Key = '1'; Value = '';        Label = '校园网(默认)   走教育网, 有 IPv6, 每月有免费外网额度' },
        @{ Key = '2'; Value = 'unicom';  Label = '中国联通(代拨) 费用自理, 不限量' },
        @{ Key = '3'; Value = 'mobile';  Label = '中国移动(代拨) 费用自理, 不限量' },
        @{ Key = '4'; Value = 'telecom'; Label = '中国电信(代拨) 费用自理, 不限量' }
    )

    $isp = $null
    if ($Script:IspProvided) {
        $isp = $Script:IspParam
        Write-Host ("代理商: {0}  (由参数提供)" -f $(if ($isp) { $isp } else { '校园网(默认)' })) -ForegroundColor Gray
    } elseif ($canPrompt) {
        Write-Host '请选择上网出口(代理商):'
        foreach ($c in $ispChoices) {
            Write-Host ("  {0}) {1}" -f $c.Key, $c.Label)
        }
        do {
            $sel = (Read-InputLine '请输入 1-4 (直接回车 = 1 校园网)').Trim()
            if (-not $sel) { $sel = '1' }
            $hit = $ispChoices | Where-Object { $_.Key -eq $sel }
            if (-not $hit) { Write-Host '  请输入 1、2、3 或 4。' -ForegroundColor Yellow }
        } while (-not $hit)
        $isp = $hit.Value
    } else {
        $isp = $Defaults['isp']
    }

    # ---------------- 密码 ----------------
    $pwd = $Password
    if (-not $pwd) {
        while (-not $pwd) {
            $p1 = Read-InputLine '请输入校园网密码(输入时不显示)' -AsSecret
            if (-not $p1) { Write-Host '  密码不能为空。' -ForegroundColor Yellow; continue }
            $p2 = Read-InputLine '请再次输入以确认' -AsSecret
            if ($p1 -ne $p2) { Write-Host '  两次输入不一致, 请重新输入。' -ForegroundColor Yellow; continue }
            $pwd = $p1
        }
    } else {
        Write-Host '密码: 已由参数提供' -ForegroundColor Gray
    }

    # ---------------- 组装并校验 ----------------
    Write-Host ''
    Write-Host '正在校验账号...' -ForegroundColor Cyan
    $portal = $Defaults['portal']
    $chk = $null
    try { $chk = Test-AccountExists -Portal $portal -Acc $acc -Pwd $pwd } catch { }

    if ($chk -and $chk.Reached -and -not $chk.Exists) {
        Write-Host ("  ✗ portal 里查不到账号 '{0}', 请确认学号是否输错。" -f $acc) -ForegroundColor Red
        if ($canPrompt) {
            $again = (Read-InputLine '要重新输入账号吗? (Y/n)').Trim().ToLower()
            if ($again -ne 'n') { return Invoke-Setup -Path $Path -Defaults $Defaults }
        }
        throw '账号校验失败, 已放弃写入配置。'
    } elseif ($chk -and $chk.Exists) {
        Write-Host ("  ✓ 账号 {0} 在 portal 中存在" -f $acc) -ForegroundColor Green
    } else {
        Write-Host '  ! portal 当前不可达(可能不在校园网内), 跳过账号校验, 仍然保存配置。' -ForegroundColor Yellow
    }

    # 密码用 DPAPI 加密保存(只有本机本用户能解开)
    $secStr = ConvertTo-SecureString -String $pwd -AsPlainText -Force
    $enc    = ConvertFrom-SecureString $secStr

    $cfg = [ordered]@{
        account              = $acc
        password             = ''
        passwordProtected    = $enc
        isp                  = $isp
        portal               = $Defaults['portal']
        portalFallback       = $Defaults['portalFallback']
        checkIntervalSeconds = $Defaults['checkIntervalSeconds']
        failureRetrySeconds  = $Defaults['failureRetrySeconds']
        expectedSsid         = $Defaults['expectedSsid']
        accountWithSuffix    = $Defaults['accountWithSuffix']
        logoffBeforeLogin    = $Defaults['logoffBeforeLogin']
        checkUrls            = $Defaults['checkUrls']
    }
    $cfg | ConvertTo-Json -Depth 6 | Set-Content -Path $Path -Encoding UTF8

    Write-Host ''
    Write-Host '--------------------- 配置完成 ---------------------' -ForegroundColor Green
    Write-Host ("  账号     : {0}" -f $acc)
    Write-Host ("  代理商   : {0}" -f $(if ($isp) { "$isp(代拨)" } else { '校园网(默认)' }))
    Write-Host ("  密码     : 已用 DPAPI 加密(仅本机本用户可解密)")
    Write-Host ("  配置文件 : {0}" -f $Path)
    Write-Host ''
    Write-Host '下一步建议(注意 -Force 会短暂断网):' -ForegroundColor Gray
    Write-Host '  .\SNNU-AutoLogin.ps1 -Diagnose     # 先体检' -ForegroundColor Gray
    Write-Host '  .\SNNU-AutoLogin.ps1 -Force        # 真实断开重连测试' -ForegroundColor Gray
    Write-Host '  .\install-autostart.ps1            # 确认没问题后装开机自启' -ForegroundColor Gray
    Write-Host ''
}

# ================================================================ 配置
function Get-Config {
    param([string]$Path, [switch]$NoSetup)

    if (-not $Path) { $Path = Join-Path $Script:ScriptRoot 'config.json' }

    $default = [ordered]@{
        account              = ''
        password             = ''
        passwordProtected    = ''      # DPAPI 加密后的密码(优先于 password)
        isp                  = ''      # 运营商: 空=校园网 / unicom=联通 / mobile=移动 / telecom=电信
        portal               = 'http://202.117.144.205:8601'
        portalFallback       = 'http://202.117.144.205:8602'
        checkIntervalSeconds = 30
        failureRetrySeconds  = 60
        expectedSsid         = 'SNNU'   # 只在连到这个 WiFi 时才认证;留空=不限制
        accountWithSuffix    = 'auto'   # auto = 失败后自动尝试 account@isp 形式
        logoffBeforeLogin    = $false   # 需要时改 true(等价 -Force)
        checkUrls            = @(
            'http://connect.rom.miui.com/generate_204',
            'http://www.msftconnecttest.com/connecttest.txt',
            'http://captive.apple.com/hotspot-detect.html'
        )
    }

    # ---------------- 判断是否需要走首次配置引导 ----------------
    $needSetup = $false
    if (-not (Test-Path $Path)) {
        $needSetup = $true
    } else {
        try {
            $probe = Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            $a = [string]$probe.account
            $p = [string]$probe.password
            $q = [string]$probe.passwordProtected
            if (-not $a) { $needSetup = $true }
            elseif (-not $p -and -not $q) { $needSetup = $true }
            elseif ($p -match '在这里填|填你的|你的密码|xxxx' -or $a -match '在这里填|xxxx') { $needSetup = $true }
        } catch {
            Write-Log "配置文件无法解析,将重新引导配置: $($_.Exception.Message)" 'WARN'
            $needSetup = $true
        }
    }

    if ($Setup) {
        Invoke-Setup -Path $Path -Defaults $default
        $needSetup = $false
    } elseif ($needSetup) {
        if ($NoSetup) {
            # 只读模式(查状态/诊断/断开): 允许没有配置。
            # 这三个命令本来就应该在"还没配好"的时候能用, 尤其是 -Diagnose。
            if (-not (Test-Path $Path)) {
                $bare = @{}
                foreach ($k in $default.Keys) { $bare[$k] = $default[$k] }
                $bare['portal'] = $bare['portal'].TrimEnd('/')
                Write-Log "尚未配置(找不到 $Path), 只读模式继续。" 'WARN'
                return $bare
            }
        } else {
            Write-Log '检测到尚未完成配置,进入首次配置引导...' 'WARN'
            Invoke-Setup -Path $Path -Defaults $default
            $needSetup = $false
        }
    }

    $json = Get-Content -Path $Path -Raw -Encoding UTF8
    try {
        $cfg = $json | ConvertFrom-Json
    } catch {
        throw "config.json 解析失败(JSON 格式错误): $($_.Exception.Message)"
    }

    # 合并默认值: 配置里没写的字段用默认值补齐
    $result = @{}
    foreach ($k in $default.Keys) { $result[$k] = $default[$k] }
    foreach ($p in $cfg.PSObject.Properties) { $result[$p.Name] = $p.Value }

    # 运行时覆盖
    if ($Account) { $result['account'] = $Account }
    if ($Password) { $result['password'] = $Password }

    # DPAPI 解密(只有本机本用户能解)
    if ($result['passwordProtected']) {
        try {
            $sec  = ConvertTo-SecureString $result['passwordProtected']
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
            $result['password'] = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        } catch {
            throw "passwordProtected 解密失败(换机器/换用户后需重新生成: 运行 .\SNNU-AutoLogin.ps1 -Setup)。"
        }
    }

    # 只读模式(查状态/诊断/断开)不强制要求账号密码
    if (-not $NoSetup) {
        if (-not $result['account'])  { throw 'config.json 里 account 未填写。运行 -Setup 重新配置。' }
        if (-not $result['password']) { throw 'config.json 里 password 未填写。运行 -Setup 重新配置。' }
    }

    $result['portal'] = $result['portal'].TrimEnd('/')
    if ($result['portalFallback']) { $result['portalFallback'] = $result['portalFallback'].TrimEnd('/') }

    return $result
}

# ================================================================ HTTP 底层
# 用 HttpWebRequest 而不是 Invoke-WebRequest:
#   1) 能精确控制 GB2312 解码(Invoke-WebRequest 在 PS5.1 会按 charset 乱猜)
#   2) 能拿到 302/4xx/5xx 的响应体(Invoke-WebRequest 遇错抛异常丢 body)
function Invoke-PortalRequest {
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$Method = 'GET',
        [string]$Body,
        [System.Net.CookieContainer]$Cookies,
        [int]$TimeoutSec = 15,
        [switch]$NoRedirect
    )

    if (-not $Cookies) { $Cookies = New-Object System.Net.CookieContainer }

    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method                 = $Method
    $req.Timeout                = $TimeoutSec * 1000
    $req.ReadWriteTimeout       = $TimeoutSec * 1000
    $req.AllowAutoRedirect      = (-not $NoRedirect)
    $req.MaximumAutomaticRedirections = 5
    $req.CookieContainer        = $Cookies
    $req.UserAgent              = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
    $req.Accept                 = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
    $req.Headers.Add('Accept-Language', 'zh-CN,zh;q=0.9')
    $req.KeepAlive              = $false

    if ($Method -eq 'POST' -and $null -ne $Body) {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
        $req.ContentType   = 'application/x-www-form-urlencoded'
        $req.ContentLength = $bytes.Length
        $st = $req.GetRequestStream()
        $st.Write($bytes, 0, $bytes.Length)
        $st.Close()
    }

    $resp = $null
    try {
        $resp = $req.GetResponse()
    } catch [System.Net.WebException] {
        $resp = $_.Exception.Response
        if ($null -eq $resp) {
            throw "无法连接 $Url : $($_.Exception.Message)"
        }
    }

    $raw = @()
    try {
        $stream = $resp.GetResponseStream()
        $ms = New-Object System.IO.MemoryStream
        $buf = New-Object byte[] 8192
        while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) { $ms.Write($buf, 0, $n) }
        $raw = $ms.ToArray()
        $ms.Dispose(); $stream.Dispose()
    } catch { }

    # 编码: 优先响应头 charset;JSON 接口用 UTF-8;portal 的 HTML 页面是 GB2312
    $charset = $null
    try {
        if ($resp.ContentType -match 'charset\s*=\s*"?([\w\-]+)"?') { $charset = $Matches[1] }
    } catch { }
    if (-not $charset) {
        if ($resp.ContentType -match 'json') { $charset = 'UTF-8' } else { $charset = 'GB2312' }
    }
    try   { $enc = [Text.Encoding]::GetEncoding($charset) }
    catch { $enc = [Text.Encoding]::UTF8; $charset = 'UTF-8' }

    [pscustomobject]@{
        StatusCode = [int]$resp.StatusCode
        Content    = $enc.GetString($raw)
        RawLength  = $raw.Length
        FinalUrl   = $(try { $resp.ResponseUri.AbsoluteUri } catch { $Url })
        Charset    = $charset
        Cookies    = $Cookies
    }
}

function New-FormBody {
    param([System.Collections.IDictionary]$Fields)
    $pairs = @()
    foreach ($k in $Fields.Keys) {
        $pairs += ('{0}={1}' -f [Uri]::EscapeDataString([string]$k), [Uri]::EscapeDataString([string]$Fields[$k]))
    }
    return ($pairs -join '&')
}

# ================================================================ 账号存在性检查(不含密码)
# portal 的 bind/getUserInfo 接口只回答"这个账号存不存在",不校验密码。
# 实测记录(务必不要误用):
#   账号 20250001 + 正确密码 -> {"data":"S","success":"true",...}
#   账号 20250001 + 错误密码 -> {"data":"S","success":"true",...}   <- 与正确密码完全一样
#   账号 00000000 + 任意密码 -> {"data":"", "success":"true",...}   <- success 恒为 true
# 结论: success 字段无意义;只有 data 非空才说明账号存在。
#       密码是否正确只能靠真实登录(POST /snnuportal/login)来验证。
function Test-AccountExists {
    param(
        [Parameter(Mandatory)][string]$Portal,
        [Parameter(Mandatory)][string]$Acc,
        [Parameter(Mandatory)][string]$Pwd
    )

    $cookies = New-Object System.Net.CookieContainer

    try {
        $null = Invoke-PortalRequest -Url "$Portal/snnuportal/login" -Cookies $cookies -TimeoutSec 12
    } catch {
        return [pscustomobject]@{ Reached = $false; Exists = $false; Reason = "连接 portal 失败: $($_.Exception.Message)"; Raw = ''; Data = '' }
    }

    $body = New-FormBody -Fields ([ordered]@{
        account  = $Acc
        password = $Pwd
        method   = 'getUserInfo'
    })

    $r = $null
    try {
        $r = Invoke-PortalRequest -Url "$Portal/snnuportal/bind" -Method POST -Body $body -Cookies $cookies -TimeoutSec 15
    } catch {
        return [pscustomobject]@{ Reached = $false; Exists = $false; Reason = "查询请求失败: $($_.Exception.Message)"; Raw = ''; Data = '' }
    }

    $raw = ($r.Content -replace '\s+', ' ').Trim()
    $data = ''; $reason = ''

    try {
        $j = $raw | ConvertFrom-Json
        $data = [string]$j.data
    } catch {
        return [pscustomobject]@{ Reached = $true; Exists = $false; Reason = "响应无法解析: $raw"; Raw = $raw; Data = '' }
    }

    if (-not $data) { $reason = 'portal 里查不到这个账号(账号输入可能有误)' }

    return [pscustomobject]@{
        Reached = $true
        Exists  = [bool]$data
        Reason  = $reason
        Raw     = $raw
        Data    = $data
    }
}

# ================================================================ 连通性检测
# 判定"能不能上外网": 用 generate_204 之类的探测点。
# 未认证时校园网会返回 302 重定向到 portal,所以 2xx 才算通。
function Test-Internet {
    param(
        [string[]]$Urls,
        [int]$TimeoutSec = 6
    )
    if (-not $Urls) { $Urls = @('http://connect.rom.miui.com/generate_204') }

    foreach ($u in $Urls) {
        try {
            $req = [System.Net.HttpWebRequest]::Create($u)
            $req.Method            = 'GET'
            $req.Timeout           = $TimeoutSec * 1000
            $req.ReadWriteTimeout  = $TimeoutSec * 1000
            $req.AllowAutoRedirect = $false      # 有重定向 = 被劫持到 portal = 不通
            $req.UserAgent         = 'Mozilla/5.0'
            $resp = $req.GetResponse()
            $code = [int]$resp.StatusCode
            $resp.Close()
            if ($code -ge 200 -and $code -lt 300) { return $true }
        } catch [System.Net.WebException] {
            $r = $_.Exception.Response
            if ($r) {
                $code = [int]$r.StatusCode
                $r.Close()
                if ($code -ge 200 -and $code -lt 300) { return $true }
            }
        } catch { }
    }
    return $false
}

# ================================================================ 当前 WiFi SSID
function Get-CurrentSsid {
    try {
        $out = netsh wlan show interfaces 2>$null
        foreach ($line in $out) {
            if ($line -match '^\s*SSID\s*:\s*(.+?)\s*$') { return $Matches[1] }
        }
    } catch { }
    return ''
}

# ================================================================ portal 状态
# 返回: online / offline / unknown
function Get-PortalStatus {
    param(
        [string]$Portal,
        [System.Net.CookieContainer]$Cookies,
        [switch]$Detailed
    )
    $url = "$Portal/snnuportal/login.jsp"
    $r = Invoke-PortalRequest -Url $url -Cookies $Cookies -TimeoutSec 12

    $state  = 'unknown'
    $who    = ''
    $ip     = ''
    $since  = ''

    if ($r.Content -match '当前登录账号') {
        $state = 'online'
        if ($r.Content -match '当前登录账号：\s*<span[^>]*>([^<]+)</span>') { $who = $Matches[1].Trim() }
        if ($r.Content -match '当前IP：\s*([0-9\.]+)')                       { $ip  = $Matches[1].Trim() }
        if ($r.Content -match '登录时间：\s*([0-9\-: ]+)')                    { $since = $Matches[1].Trim() }
    }
    elseif ($r.Content -match 'name\s*=\s*"password"') {
        $state = 'offline'
    }
    # 有些版本的未登录页也带"当前登录账号"字样但为空,做个兜底
    if ($state -eq 'online' -and $r.Content -match '当前登录账号：\s*<span[^>]*>\s*(?:&nbsp;)?\s*</span>') {
        $state = 'offline'
    }

    if ($Detailed) {
        return [pscustomobject]@{ State = $state; Account = $who; Ip = $ip; LoginTime = $since; StatusCode = $r.StatusCode; FinalUrl = $r.FinalUrl }
    }
    return $state
}

# ================================================================ 登录
function Invoke-PortalLogin {
    param(
        [string]$Portal,
        [string]$Acc,
        [string]$Pwd,
        [string]$Isp,
        [switch]$AgainLogin,
        [switch]$UseSuffixAccount
    )

    $cookies = New-Object System.Net.CookieContainer

    # 1) 先 GET 一次拿到 JSESSIONID
    try {
        $null = Invoke-PortalRequest -Url "$Portal/snnuportal/login" -Cookies $cookies -TimeoutSec 12
    } catch {
        return [pscustomobject]@{ Success = $false; Stage = 'connect'; Message = "连接 portal 失败: $($_.Exception.Message)"; Detail = '' }
    }

    # 2) 组装表单 (与网页表单字段一致)
    $accValue = $Acc
    if ($UseSuffixAccount -and $Isp) { $accValue = "$Acc@$Isp" }

    $fields = [ordered]@{
        sourceurl = 'null'
        account   = $accValue
        password  = $Pwd
        yys       = $Isp
        issave    = ''
    }
    if ($AgainLogin) { $fields['againLogin'] = '1' }

    $body = New-FormBody -Fields $fields

    # 3) POST 登录
    $r = $null
    try {
        $r = Invoke-PortalRequest -Url "$Portal/snnuportal/login" -Method POST -Body $body -Cookies $cookies -TimeoutSec 20
    } catch {
        return [pscustomobject]@{ Success = $false; Stage = 'post'; Message = "登录请求失败: $($_.Exception.Message)"; Detail = '' }
    }

    $html = $r.Content

    # 4) 判断结果
    $ok     = $false
    $detail = ''

    if ($html -match '当前登录账号') {
        $ok = $true
        if ($html -match '当前登录账号：\s*<span[^>]*>([^<]+)</span>') { $detail = "已认证账号 $($Matches[1].Trim())" }
    }
    elseif ($html -match '已在线|已经在线|已登录|已在其他|您已') {
        $ok = $true; $detail = '账号已在线'
    }
    elseif ($html -match 'name\s*=\s*"password"') {
        $ok = $false
        # 抓页面里的中文提示语,便于判断具体原因
        $msgs = @()
        foreach ($pat in @('用户名或密码错误','账号或密码错误','密码错误','用户不存在','账号不存在','验证码','已欠费','余额不足','该账号已停机','账号被锁定','不在认证时段','绑定')) {
            if ($html -match $pat) { $msgs += $pat }
        }
        # 常见的 <div class="...">提示文字</div>
        if ($html -match '(?s)class\s*=\s*"[^"]*(?:error|tip|msg|alert)[^"]*"\s*>(.{2,200}?)<') {
            $t = ($Matches[1] -replace '<[^>]+>', '' -replace '\s+', ' ').Trim()
            if ($t) { $msgs += $t }
        }
        $detail = if ($msgs.Count) { ($msgs | Select-Object -Unique) -join ' | ' } else { '返回登录表单(未说明原因)' }
    }
    else {
        $ok = $false; $detail = "未识别的响应 (HTTP $($r.StatusCode), $($r.RawLength) 字节)"
    }

    return [pscustomobject]@{
        Success   = $ok
        Stage     = 'login'
        Message   = if ($ok) { '登录成功' } else { '登录未成功' }
        Detail    = $detail
        StatusCode= $r.StatusCode
        FinalUrl  = $r.FinalUrl
    }
}

# ================================================================ 断开
function Invoke-PortalLogout {
    param([string]$Portal)

    $cookies = New-Object System.Net.CookieContainer
    $null = Invoke-PortalRequest -Url "$Portal/snnuportal/login" -Cookies $cookies -TimeoutSec 12
    $r = Invoke-PortalRequest -Url "$Portal/snnuportal/logoff" -Cookies $cookies -TimeoutSec 15

    $state = Get-PortalStatus -Portal $Portal -Cookies $cookies
    return [pscustomobject]@{ Success = ($state -ne 'online'); State = $state; StatusCode = $r.StatusCode }
}

# ================================================================ 认证主流程
# 返回 $true 表示最终网络可用
function Invoke-Authenticate {
    param(
        [hashtable]$Cfg,
        [switch]$ForceRelogin
    )

    $ssid = Get-CurrentSsid
    if ($Cfg['expectedSsid']) {
        if ($ssid -and $ssid -ne $Cfg['expectedSsid']) {
            Write-Log "当前 WiFi 是 '$ssid',不是 '$($Cfg['expectedSsid'])',跳过认证。" 'DEBUG'
            return $false
        }
    }

    # 先看能不能上网(最直接的判据)
    $online = Test-Internet -Urls $Cfg['checkUrls']
    if ($online -and -not $ForceRelogin) {
        Write-Log '网络正常,无需认证。' 'DEBUG'
        return $true
    }

    # 选一个可达的 portal
    $portal = $null
    foreach ($p in @($Cfg['portal'], $Cfg['portalFallback'])) {
        if (-not $p) { continue }
        try {
            $null = Invoke-PortalRequest -Url "$p/snnuportal/login" -TimeoutSec 8
            $portal = $p; break
        } catch {
            Write-Log "portal 不可达: $p ($($_.Exception.Message))" 'DEBUG'
        }
    }
    if (-not $portal) {
        Write-Log '两个 portal 地址都不可达,可能不在校园网内。' 'WARN'
        return $false
    }

    $cookies = New-Object System.Net.CookieContainer

    # 账号存在性检查: 账号在 portal 里查不到时,就没必要断开/登录了。
    # 注意: 这个接口不校验密码(见 Test-AccountExists 注释),别指望它挡错误密码。
    # 错误密码由下面的登录结果 + 断路器退避来处理。
    $accChk = Test-AccountExists -Portal $portal -Acc $Cfg['account'] -Pwd $Cfg['password']
    if ($accChk.Reached -and -not $accChk.Exists) {
        Write-Log "账号存在性检查未通过: $($accChk.Reason)。放弃本次认证,你当前的连接不会被断开。" 'ERROR'
        return $false
    }
    if ($accChk.Exists) {
        Write-Log "账号在 portal 中存在 (data=$($accChk.Data));密码正确性只能由真实登录验证。" 'DEBUG'
    }

    $state = Get-PortalStatus -Portal $portal -Cookies $cookies
    Write-Log "portal 状态: $state (SSID=$ssid, 外网=$online)"

    if ($ForceRelogin -or $Cfg['logoffBeforeLogin']) {
        Write-Log '执行断开(logoff)...'
        $lo = Invoke-PortalLogout -Portal $portal
        Write-Log "断开结果: $($lo.State)"
        Start-Sleep -Seconds 2
    }
    elseif ($state -eq 'online' -and -not $online) {
        # portal 说在线但上不了网 => 会话僵死,先断开再登
        Write-Log 'portal 显示已在线但外网不通,判定为僵死会话,先断开。' 'WARN'
        $lo = Invoke-PortalLogout -Portal $portal
        Write-Log "断开结果: $($lo.State)"
        Start-Sleep -Seconds 2
    }

    # 尝试登录: 先原始账号,失败再试 "账号@运营商"
    $attempts = @()
    $attempts += [pscustomobject]@{ Acc = $Cfg['account']; Suffix = $false; Label = "account=$($Cfg['account']), yys=$($Cfg['isp'])" }
    if ($Cfg['accountWithSuffix'] -ne 'never' -and $Cfg['isp']) {
        $attempts += [pscustomobject]@{ Acc = $Cfg['account']; Suffix = $true; Label = "account=$($Cfg['account'])@$($Cfg['isp']), yys=$($Cfg['isp'])" }
    }

    $n = 0
    foreach ($a in $attempts) {
        $n++
        Write-Log "尝试登录 ($n/$($attempts.Count)): $($a.Label)"
        $res = Invoke-PortalLogin -Portal $portal -Acc $a.Acc -Pwd $Cfg['password'] -Isp $Cfg['isp'] -UseSuffixAccount:$a.Suffix
        Write-Log "  结果: Success=$($res.Success) Detail=$($res.Detail)" $(if ($res.Success) { 'OK' } else { 'WARN' })

        if ($res.Success) {
            # 等 DHCP/网关放开,再确认外网
            for ($i = 1; $i -le 5; $i++) {
                Start-Sleep -Seconds 2
                if (Test-Internet -Urls $Cfg['checkUrls']) {
                    Write-Log '外网连通,认证完成。' 'OK'
                    return $true
                }
            }
            Write-Log 'portal 报告登录成功,但外网仍不通(可能需要等一会儿或换个运营商)。' 'WARN'
            return $false
        }
    }

    Write-Log "认证失败: $($attempts.Count) 种方式都没成功。请手动打开浏览器登录一次确认账号密码/是否被要求验证码。" 'ERROR'
    return $false
}

# ================================================================ 诊断
function Invoke-Diagnose {
    param([hashtable]$Cfg)

    Write-Host ''
    Write-Host '===== SNNU 校园网自动认证 - 诊断 =====' -ForegroundColor Cyan
    Write-Host ("时间          : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Write-Host ("脚本目录      : {0}" -f $Script:ScriptRoot)
    Write-Host ("PowerShell    : {0}" -f $PSVersionTable.PSVersion)
    Write-Host ("管理员        : {0}" -f ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))

    Write-Host ''
    Write-Host '--- 网络 ---' -ForegroundColor Cyan
    Write-Host ("当前 WiFi SSID: {0}" -f (Get-CurrentSsid))
    try {
        Get-NetAdapter | Where-Object Status -eq 'Up' |
            Select-Object Name, InterfaceDescription, LinkSpeed | Format-Table -AutoSize | Out-String | Write-Host
    } catch { }
    try {
        Get-NetIPConfiguration | Where-Object { $_.NetAdapter.Status -eq 'Up' -and $_.IPv4Address } |
            ForEach-Object {
                Write-Host ("  {0,-14} IP={1,-18} 网关={2}" -f `
                    $_.InterfaceAlias,
                    ($_.IPv4Address.IPAddress -join ','),
                    ($_.IPv4DefaultGateway.NextHop -join ','))
            }
    } catch { }

    Write-Host ''
    Write-Host '--- 外网连通性 ---' -ForegroundColor Cyan
    foreach ($u in $Cfg['checkUrls']) {
        $ok = Test-Internet -Urls @($u) -TimeoutSec 5
        Write-Host ("  {0,-52} {1}" -f $u, $(if ($ok) { '通' } else { '不通' })) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
    }

    Write-Host ''
    Write-Host '--- Portal 可达性 ---' -ForegroundColor Cyan
    foreach ($p in @($Cfg['portal'], $Cfg['portalFallback'])) {
        if (-not $p) { continue }
        try {
            $r = Invoke-PortalRequest -Url "$p/snnuportal/login.jsp" -TimeoutSec 8
            Write-Host ("  {0,-45} HTTP {1}  {2} 字节" -f $p, $r.StatusCode, $r.RawLength) -ForegroundColor Green
        } catch {
            Write-Host ("  {0,-45} 不可达: {1}" -f $p, $_.Exception.Message) -ForegroundColor Red
        }
    }

    Write-Host ''
    Write-Host '--- Portal 状态 ---' -ForegroundColor Cyan
    try {
        $st = Get-PortalStatus -Portal $Cfg['portal'] -Cookies (New-Object System.Net.CookieContainer) -Detailed
        Write-Host ("  状态     : {0}" -f $st.State)
        Write-Host ("  在线账号 : {0}" -f $st.Account)
        Write-Host ("  当前 IP  : {0}" -f $st.Ip)
        Write-Host ("  登录时间 : {0}" -f $st.LoginTime)
    } catch {
        Write-Host ("  查询失败: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }

    Write-Host ''
    Write-Host '--- 配置 ---' -ForegroundColor Cyan
    Write-Host ("  账号   : {0}" -f $Cfg['account'])
    Write-Host ("  密码   : {0}" -f $(if ($Cfg['password']) { ('*' * [Math]::Min(8, $Cfg['password'].Length)) } else { '(空)' }))
    Write-Host ("  运营商 : {0}" -f $(if ($Cfg['isp']) { $Cfg['isp'] } else { '(校园网默认)' }))
    Write-Host ("  间隔   : {0} 秒" -f $Cfg['checkIntervalSeconds'])
    Write-Host ("  限定SSID: {0}" -f $(if ($Cfg['expectedSsid']) { $Cfg['expectedSsid'] } else { '(不限制)' }))
    Write-Host ''
}

# ================================================================ 常驻守护
function Start-Daemon {
    param([hashtable]$Cfg)

    $interval = if ($Interval -gt 0) { $Interval } else { [int]$Cfg['checkIntervalSeconds'] }
    $failWait = [int]$Cfg['failureRetrySeconds']

    Write-Log "守护模式启动 (检查间隔 $interval 秒, PID=$PID)" 'OK'

    $consecutiveFail = 0
    while ($true) {
        # 整轮都包在 try 里,并且把 Start-Sleep 放在 finally 之外的最后。
        # 这样即使 Write-Log 本身出错(日志被占用/磁盘满/被杀软锁文件),
        # 也不会把异常抛出循环导致进程直接退出 —— 之前正是这个弱点。
        $wait = $interval
        try {
            try {
                $ok = Invoke-Authenticate -Cfg $Cfg
                if ($ok) { $consecutiveFail = 0 } else { $consecutiveFail++ }
            } catch {
                $consecutiveFail++
                try { Write-Log "认证过程异常: $($_.Exception.Message)" 'ERROR' } catch { }
            }

            # 断路器: 连续失败则指数退避,上限 30 分钟一次。
            # 目的是避免密码错误时反复登录,触发学校的验证码/账号锁定。
            if ($consecutiveFail -ge 3) {
                $exp  = [Math]::Min($consecutiveFail - 2, 6)
                $wait = [Math]::Min($failWait * [Math]::Pow(2, $exp - 1), 1800)
                try { Write-Log "连续失败 $consecutiveFail 次,退避 $([int]$wait) 秒后再试(避免触发账号锁定)。" 'WARN' } catch { }
            }
        } catch {
            # 兜底: 任何没预料到的异常都不允许终止守护进程
            try { Write-Log "守护循环未预期异常(已忽略并继续): $($_.Exception.Message)" 'ERROR' } catch { }
            $wait = $interval
        }

        Start-Sleep -Seconds $wait
    }
}

# ================================================================ 入口
function Main {
    # 只读模式: 查状态 / 诊断 / 断开 都不需要账号密码, 也不该触发首次配置引导。
    # 尤其是 -Diagnose —— 那正是"还没配好时"用来体检的命令。
    $readOnlyMode = (($Status -or $Diagnose -or $Logout) -and -not $Setup)
    $cfg = Get-Config -Path $Config -NoSetup:$readOnlyMode

    # -Setup: 只跑配置引导, 配置完就结束(不立刻动网络, 让用户先自行体检)
    if ($Setup) {
        Write-Host '配置已更新。' -ForegroundColor Green
        Write-Host ''
        return
    }

    if ($Diagnose) { Invoke-Diagnose -Cfg $cfg; return }

    if ($Logout) {
        Write-Log '主动断开校园网...'
        $r = Invoke-PortalLogout -Portal $cfg['portal']
        Write-Log "断开完成,portal 状态: $($r.State)" $(if ($r.Success) { 'OK' } else { 'WARN' })
        return
    }

    if ($Status) {
        $st = Get-PortalStatus -Portal $cfg['portal'] -Cookies (New-Object System.Net.CookieContainer) -Detailed
        $net = Test-Internet -Urls $cfg['checkUrls']
        Write-Host ''
        Write-Host ("Portal 状态 : {0}" -f $st.State) -ForegroundColor $(if ($st.State -eq 'online') { 'Green' } else { 'Yellow' })
        Write-Host ("在线账号    : {0}" -f $st.Account)
        Write-Host ("当前 IP     : {0}" -f $st.Ip)
        Write-Host ("登录时间    : {0}" -f $st.LoginTime)
        Write-Host ("外网连通    : {0}" -f $(if ($net) { '通' } else { '不通' })) -ForegroundColor $(if ($net) { 'Green' } else { 'Red' })
        Write-Host ("当前 WiFi   : {0}" -f (Get-CurrentSsid))
        Write-Host ''
        return
    }

    if ($TestLogin) {
        # 走 bind/getUserInfo: 只查账号存不存在, 不建立会话, 不断开现有连接
        Write-Host ''
        Write-Host '正在检查账号...' -ForegroundColor Cyan
        $c = Test-AccountExists -Portal $cfg['portal'] -Acc $cfg['account'] -Pwd $cfg['password']
        $typeText = switch ($c.Data) {
            'S'     { 'S = 校园网基础账号(需选运营商代拨上网)' }
            ''      { '(未返回)' }
            default { $c.Data }
        }
        Write-Host ''
        Write-Host ("账号       : {0}" -f $cfg['account'])
        Write-Host ("存在性     : {0}" -f $(if ($c.Exists) { '存在' } else { '查不到该账号' })) `
            -ForegroundColor $(if ($c.Exists) { 'Green' } else { 'Red' })
        Write-Host ("账号类型   : {0}" -f $typeText)
        Write-Host ("运营商     : {0}" -f $(if ($cfg['isp']) { "$($cfg['isp'])(代拨)" } else { '校园网默认' }))
        if ($c.Reason) { Write-Host ("说明       : {0}" -f $c.Reason) }
        Write-Host ("原始响应   : {0}" -f $c.Raw)
        Write-Host ''
        Write-Host '重要: 这个接口不校验密码,所以它无法确认密码是否正确。' -ForegroundColor Yellow
        Write-Host '   要真正验证密码 + 断线重连链路,请运行:  .\SNNU-AutoLogin.ps1 -Force' -ForegroundColor Yellow
        Write-Host '   (-Force 会先断开再登录,网络中断约 10 秒;密码错会登不上,需要浏览器手动登录)' -ForegroundColor DarkGray
        Write-Host ''
        if (-not $c.Exists) {
            Write-Host 'portal 里查不到这个账号,请检查 config.json 的 account 是否写错。' -ForegroundColor Yellow
            Write-Host ''
            exit 1
        }
        Write-Host '账号没问题。密码是否正确仍需 -Force 实测。' -ForegroundColor Green
        Write-Host ''
        return
    }

    if ($Daemon) {
        # 单实例: 防止多个守护进程互相抢认证
        $createdNew = $false
        $mutex = New-Object System.Threading.Mutex($true, $Script:MutexName, [ref]$createdNew)
        if (-not $createdNew) {
            Write-Log '已有一个认证守护进程在运行,本次退出。' 'WARN'
            return
        }
        try { Start-Daemon -Cfg $cfg }
        finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
        return
    }

    # 单次执行
    $ok = Invoke-Authenticate -Cfg $cfg -ForceRelogin:$Force
    if (-not $Verbose2) {
        if ($ok) { Write-Host 'OK - 网络已连通' -ForegroundColor Green }
        else     { Write-Host 'FAIL - 未能连通,详见日志 logs\snnu-autologin.log' -ForegroundColor Red }
    }
    if (-not $ok) { exit 1 }
}

# 顶层错误处理: 把异常变成人能看懂的一句话,而不是甩一屏 PowerShell 堆栈
try {
    Main
} catch {
    Write-Host ''
    Write-Host ('错误: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host ''
    try { Write-Host ('  位置: ' + ($_.InvocationInfo.PositionMessage -replace '\s+', ' ').Trim()) -ForegroundColor DarkGray } catch { }
    Write-Host '  提示: 首次使用请先运行  .\SNNU-AutoLogin.ps1 -Setup' -ForegroundColor DarkGray
    Write-Host ''
    exit 1
}
