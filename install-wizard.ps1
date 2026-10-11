<#
=======================================================================
 一键向导 —— 把「配置 → 校验 → 测试 → 装自启」串成一步
=======================================================================
 这个脚本是给不熟悉 PowerShell 的人用的: 双击对应的 .bat 就行。
   一键安装.bat  -> -Mode Install
   查看状态.bat  -> -Mode Status
   一键卸载.bat  -> -Mode Uninstall

 关于"为什么用子进程":
   主脚本在失败时会调用 exit。如果直接在同进程里 & 调用,
   那个 exit 会把整个向导一起结束掉,用户就看不到友好提示了。
   所以每一步都用 & powershell.exe 起子进程, 只取它的退出码。
   子进程继承同一个控制台, 所以 -Setup 里的交互提问照样能用。
=======================================================================
#>

[CmdletBinding()]
param(
    [ValidateSet('Install','Status','Uninstall')][string]$Mode = 'Install'
)

$ErrorActionPreference = 'Stop'

# 脚本级兜底: 任何没预料到的异常都变成一句人话, 而不是甩一屏 PowerShell 堆栈
trap {
    Write-Host ''
    Write-Host ('出错了: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host '可以把上面这段截图发给我。' -ForegroundColor DarkGray
    Write-Host ''
    exit 1
}

$Root       = Split-Path -Parent $MyInvocation.MyCommand.Path
$MainScript = Join-Path $Root 'SNNU-AutoLogin.ps1'
$InstScript = Join-Path $Root 'install-autostart.ps1'
$CfgPath    = Join-Path $Root 'config.json'
$LogPath    = Join-Path $Root 'logs\snnu-autologin.log'

try { $Host.UI.RawUI.WindowTitle = 'SNNU 校园网自动认证 - 一键工具' } catch { }

# ---------------------------------------------------------------- 输出helpers
function Say   { param([string]$m, [string]$c = 'Gray')  Write-Host $m -ForegroundColor $c }
function Step  { param($n, $t, [string]$title) Write-Host ''; Write-Host "[$n/$t] $title" -ForegroundColor Cyan }
function Ok    { param([string]$m) Write-Host ('      ✓ ' + $m) -ForegroundColor Green }
function Note  { param([string]$m) Write-Host ('      ! ' + $m) -ForegroundColor Yellow }
function Bad   { param([string]$m) Write-Host ('      ✗ ' + $m) -ForegroundColor Red }

function Invoke-Child {
    param([string]$ScriptPath, [string[]]$ChildArgs = @())
    if (-not (Test-Path $ScriptPath)) { throw "找不到脚本: $ScriptPath" }

    # 为什么用 Start-Process 而不是 & powershell.exe:
    #   & 会把子进程的 stdout 收进 PowerShell 管道, 后果是
    #     (1) 子进程的界面被"吃掉", 用户看不到任何提问
    #     (2) 函数返回的 $code 变成"输出文本 + 退出码"的数组, 拿它和 0 比较在
    #         PowerShell 里永远为真 -> 不管用户输什么都会误报"配置没有完成"
    #   Start-Process 不经过管道, 子进程直接继承本控制台: 输出原样显示、
    #   交互提问(Read-Host)正常、退出码是干净的整数。
    $argLine = (@('-NoProfile','-ExecutionPolicy','Bypass','-File', ('"{0}"' -f $ScriptPath)) + $ChildArgs) -join ' '

    if ($script:DryRun) {
        Say ('      [演练] 本应执行: powershell ' + $argLine) 'DarkGray'
        return 0
    }

    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -NoNewWindow -Wait -PassThru
    return [int]$p.ExitCode
}

# 演练模式: 设环境变量 SNNU_WIZARD_DRYRUN=1 启动, 只走流程不真正改系统。
# 用途: 让别人先看看会做什么, 也方便自动化测试这个向导本身。
$script:DryRun = ($env:SNNU_WIZARD_DRYRUN -eq '1')

function Ask-Yes {
    param([string]$Prompt, [bool]$DefaultYes = $true)
    $hint = if ($DefaultYes) { '(Y/n)' } else { '(y/N)' }
    if ($script:DryRun) {
        Say ('      [演练] ' + $Prompt + ' -> 采用默认值: ' + $(if ($DefaultYes) { '是' } else { '否' })) 'DarkGray'
        return $DefaultYes
    }
    while ($true) {
        $r = (Read-Host ('      ' + $Prompt + ' ' + $hint)).Trim().ToLower()
        if (-not $r) { return $DefaultYes }
        if ($r -eq 'y' -or $r -eq 'yes') { return $true }
        if ($r -eq 'n' -or $r -eq 'no')  { return $false }
        Note '请输入 y 或 n'
    }
}

function Get-Ssid {
    try {
        foreach ($line in (netsh wlan show interfaces 2>$null)) {
            if ($line -match '^\s*SSID\s*:\s*(.+?)\s*$') { return $Matches[1] }
        }
    } catch { }
    return ''
}

function Test-Net {
    foreach ($u in @('http://connect.rom.miui.com/generate_204','http://www.msftconnecttest.com/connecttest.txt')) {
        try {
            $req = [System.Net.HttpWebRequest]::Create($u)
            $req.Method = 'GET'; $req.Timeout = 6000; $req.AllowAutoRedirect = $false; $req.UserAgent = 'Mozilla/5.0'
            $resp = $req.GetResponse(); $c = [int]$resp.StatusCode; $resp.Close()
            if ($c -ge 200 -and $c -lt 300) { return $true }
        } catch [System.Net.WebException] {
            $r = $_.Exception.Response
            if ($r) { $c = [int]$r.StatusCode; $r.Close(); if ($c -ge 200 -and $c -lt 300) { return $true } }
        } catch { }
    }
    return $false
}

function Get-ConfigState {
    if (-not (Test-Path $CfgPath)) { return $null }
    try {
        $c = Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $acc = [string]$c.account
        $hasPwd = [bool]([string]$c.password) -or [bool]([string]$c.passwordProtected)
        if (-not $acc -or -not $hasPwd) { return $null }
        if ($acc -match '在这里填|xxxx') { return $null }
        return $c
    } catch { return $null }
}

# ================================================================ 查看状态
if ($Mode -eq 'Status') {
    Say ''
    Say '==============================================' 'Cyan'
    Say '  校园网自动认证 - 当前状态' 'Cyan'
    Say '==============================================' 'Cyan'

    $null = Invoke-Child -ScriptPath $MainScript -ChildArgs @('-Status')

    Say ''
    Say '--- 后台守护进程 ---' 'Cyan'
    # 用多个独立信号判断, 不单靠 WMI 读进程命令行。
    # (WMI 偶发返回空 CommandLine, 单看它会把"正在运行"误报成"未运行",
    #  害用户白重装一次 —— 这个坑踩过一次了。)
    $alive = $false
    $pids  = @()
    try {
        $t = Get-ScheduledTask -TaskName 'SNNU-AutoLogin' -ErrorAction SilentlyContinue
        if ($t -and $t.State -eq 'Running') { $alive = $true }
    } catch { }
    if (-not $alive -and (Test-Path $LogPath)) {
        try {
            if (((Get-Date) - (Get-Item $LogPath).LastWriteTime).TotalSeconds -lt 75) { $alive = $true }
        } catch { }
    }
    if (-not $alive) {
        $excl = New-Object System.Collections.Generic.HashSet[int]
        $null = $excl.Add($PID)
        $cur = $PID
        for ($i = 0; $i -lt 3; $i++) {
            $p = Get-CimInstance Win32_Process -Filter "ProcessId=$cur" -ErrorAction SilentlyContinue
            if (-not $p -or -not $p.ParentProcessId) { break }
            $cur = [int]$p.ParentProcessId
            $null = $excl.Add($cur)
        }
        for ($k = 1; $k -le 3; $k++) {
            $d = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                   Where-Object { $_.CommandLine -like '*SNNU-AutoLogin.ps1*' -and $_.CommandLine -like '*-Daemon*' -and -not $excl.Contains([int]$_.ProcessId) })
            if ($d.Count -gt 0) { $alive = $true; $pids = @($d.ProcessId); break }
            Start-Sleep -Milliseconds 400
        }
    }
    if ($alive) {
        if ($pids.Count -gt 0) { Ok ('正在运行 (PID ' + ($pids -join ', ') + ')') } else { Ok '正在运行' }
    } else {
        Note '没有在运行 —— 重新双击「一键安装.bat」即可恢复(最多 1 分钟内会自动拉起)'
    }

    Say ''
    Say '--- 最近 10 行运行日志 ---' 'Cyan'
    if (Test-Path $LogPath) {
        Get-Content $LogPath -Tail 10 | ForEach-Object { Say ('  ' + $_) }
    } else {
        Say '  (还没有日志)'
    }
    Say ''
    exit 0
}

# ================================================================ 卸载
if ($Mode -eq 'Uninstall') {
    Say ''
    Say '==============================================' 'Cyan'
    Say '  卸载校园网自动认证' 'Cyan'
    Say '==============================================' 'Cyan'
    Say ''
    Say '这会: 停止后台守护进程 + 删掉开机自启的计划任务。' 'Yellow'
    Say '不会: 删除账号配置文件 config.json(里面的密码是加密的)。' 'DarkGray'
    Say ''
    if (-not (Ask-Yes '确定要卸载吗?' $false)) { Say ''; Say '已取消, 什么都没动。'; exit 0 }
    Say ''
    $code = Invoke-Child -ScriptPath $InstScript -ChildArgs @('-Uninstall')
    Say ''
    if ($code -eq 0) { Ok '卸载完成。校园网不会再自动认证了。' } else { Bad "卸载过程返回了错误码 $code, 请看上面的信息。" }
    exit $code
}

# ================================================================ 安装(默认)
Say ''
Say '==============================================' 'Cyan'
Say '  陕西师范大学 校园网自动认证' 'Cyan'
Say '  一键安装' 'Cyan'
Say '==============================================' 'Cyan'
Say ''
Say '接下来会自动做 5 件事, 全程大约 1 分钟。' 'DarkGray'
Say '中途只会问你两三个问题, 其它都不用管。' 'DarkGray'

# ---------------- 1/5 ----------------
Step 1 5 '检查网络环境'
$ssid = Get-Ssid
if ($ssid) {
    Ok ('当前 WiFi: ' + $ssid)
    if ($ssid -ne 'SNNU') {
        Note "现在连的不是 SNNU。配置可以照做, 但认证只会在连上 SNNU 时自动生效。"
    }
} else {
    Note '没有检测到 WiFi 名称。可能用的是网线, 或者无线网卡没连上 —— 不影响继续。'
}

$online = Test-Net
if ($online) { Ok '现在能上外网(可能还没到校园网认证的时间段)' } else { Ok '现在上不了外网 —— 正常, 装好之后它会自动连' }

# ---------------- 2/5 ----------------
Step 2 5 '配置账号密码'
$cfg = Get-ConfigState
if ($cfg) {
    Ok ('已经配置过: 账号 ' + $cfg.account)
    if (Ask-Yes '要改成别的账号 / 换代理商 / 改密码吗?' $false) {
        $code = Invoke-Child -ScriptPath $MainScript -ChildArgs @('-Setup')
        if ($code -ne 0) { Bad '配置没有完成。'; exit $code }
        Ok '配置已更新'
    } else {
        Note '保持原配置不变'
    }
} else {
    Note '还没配置过, 现在问你三件事(只填这一次)'
    Say ''
    $code = Invoke-Child -ScriptPath $MainScript -ChildArgs @('-Setup')
    Say ''
    if ($code -ne 0) { Bad '配置没有完成, 安装中止。'; exit $code }
    Ok '配置已保存(密码已加密)'
}

# ---------------- 3/5 ----------------
Step 3 5 '校验账号'
$code = Invoke-Child -ScriptPath $MainScript -ChildArgs @('-TestLogin')
if ($code -ne 0) {
    Note '账号没能通过校验。可能是: 现在不在校园网内 / 账号或密码有问题。'
    if (-not (Ask-Yes '继续安装吗?(之后连上校园网会自动重试)' $true)) { Say ''; Say '已取消。'; exit 1 }
} else {
    Ok '账号没问题'
}

Say ''
Say '      要不要现在做一次真实测试? 会短暂断网约 10 秒。' 'Yellow'
Say '      (如果密码填错了, 测完会暂时上不了网 —— 用浏览器打开认证页手动登录即可)' 'DarkGray'
if (Ask-Yes '现在做真实测试吗?' $true) {
    $code = Invoke-Child -ScriptPath $MainScript -ChildArgs @('-Force')
    if ($code -eq 0) { Ok '真实测试通过: 能正常认证上网' } else { Note '真实测试没通过, 详见日志。装好之后它也会每 30 秒自动重试。' }
} else {
    Note '已跳过真实测试'
}

# ---------------- 4/5 ----------------
Step 4 5 '安装开机自启'
$code = Invoke-Child -ScriptPath $InstScript -ChildArgs @('-Method','Task')
if ($code -ne 0) { Bad '安装自启失败, 请把上面的信息发给我。'; exit $code }
Ok '已装好: 下次开机登录后会自动连接, 而且不会弹窗'

# ---------------- 5/5 ----------------
Step 5 5 '完成'
Say ''
Say '        ---------------------------------------------' 'Green'
Say '         装好了! 以后开机自动连校园网, 你什么都不用做。' 'Green'
Say '        ---------------------------------------------' 'Green'
Say ''
Say '  想随时查看状态:  双击「查看状态.bat」' 'Gray'
Say '  想让它别自动连:  双击「一键卸载.bat」' 'Gray'
Say '  掉线怎么办:      不用管, 它每 30 秒检查一次, 掉线会在 30 秒内自动重连' 'Gray'
Say ''
exit 0
