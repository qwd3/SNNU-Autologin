<#
=======================================================================
 SNNU 校园网自动认证 - 安装/卸载 开机自启
=======================================================================
 用法:
   .\install-autostart.ps1                # 安装(默认用计划任务,失败自动退回启动文件夹)
   .\install-autostart.ps1 -Method Startup   # 强制用启动文件夹方式
   .\install-autostart.ps1 -Method Task      # 强制用计划任务方式
   .\install-autostart.ps1 -RunNow           # 安装后立刻启动一次
   .\install-autostart.ps1 -Uninstall        # 卸载
   .\install-autostart.ps1 -Status           # 查看当前安装状态

 不需要管理员权限(以当前用户身份登录时运行)。
=======================================================================
#>

[CmdletBinding()]
param(
    [ValidateSet('Task','Startup')][string]$Method = 'Task',
    [switch]$Uninstall,
    [switch]$Status,
    [switch]$RunNow
)

$ErrorActionPreference = 'Stop'

$ScriptRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$MainScript  = Join-Path $ScriptRoot 'SNNU-AutoLogin.ps1'
$TaskName    = 'SNNU-AutoLogin'
$StartupDir  = [Environment]::GetFolderPath('Startup')
$VbsPath     = Join-Path $StartupDir 'SNNU-AutoLogin.vbs'

function Write-Info  { param($m) Write-Host $m -ForegroundColor Cyan }
function Write-Good  { param($m) Write-Host $m -ForegroundColor Green }
function Write-Warn2 { param($m) Write-Host $m -ForegroundColor Yellow }
function Write-Err   { param($m) Write-Host $m -ForegroundColor Red }

# 查找真正的守护进程。
# 注意: 不能只匹配命令行里的 "SNNU-AutoLogin" —— 调用本脚本的父进程命令行里
# 也含这些字样, 会造成误报。所以要排除自己以及自己的祖先进程。
function Get-DaemonProcess {
    $exclude = New-Object System.Collections.Generic.HashSet[int]
    $null = $exclude.Add($PID)

    # 向上追溯 3 层父进程, 一并排除(覆盖 pwsh/终端包装进程)
    $cur = $PID
    for ($i = 0; $i -lt 3; $i++) {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$cur" -ErrorAction SilentlyContinue
        if (-not $proc -or -not $proc.ParentProcessId) { break }
        $cur = [int]$proc.ParentProcessId
        $null = $exclude.Add($cur)
    }

    return @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
             Where-Object {
                 $_.CommandLine -like '*SNNU-AutoLogin.ps1*' -and
                 $_.CommandLine -like '*-Daemon*' -and
                 -not $exclude.Contains([int]$_.ProcessId)
             })
}

# 守护进程是否存活 —— 用三个独立信号判断, 不再单靠 WMI。
# 教训: 只看 Win32_Process.CommandLine 是不可靠的, WMI 偶发返回空值,
#       那样进程会被过滤掉, 于是"明明在跑却报未运行", 害用户白重装一次。
#   信号1: 计划任务处于 Running(动作是 wscript 且它会等子进程, 所以 Running ≈ 守护进程活着)
#   信号2: 日志在最近 75 秒内还在写(守护进程每 30 秒写一条心跳)
#   信号3: 退回进程扫描(带 3 次重试, 缓解 WMI 抖动)
function Test-DaemonAlive {
    try {
        $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($t -and $t.State -eq 'Running') { return $true }
    } catch { }

    try {
        $logPath = Join-Path $ScriptRoot 'logs\snnu-autologin.log'
        if (Test-Path $logPath) {
            if (((Get-Date) - (Get-Item $logPath).LastWriteTime).TotalSeconds -lt 75) { return $true }
        }
    } catch { }

    for ($i = 1; $i -le 3; $i++) {
        if (@(Get-DaemonProcess).Count -gt 0) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

if (-not (Test-Path $MainScript)) {
    Write-Err "找不到主脚本: $MainScript"
    exit 1
}

# 配置是否已完成(账号 + 密码至少有一个非空)
# 没配置就装自启毫无意义: 守护进程每次启动都会因为缺配置而报错退出。
function Test-ConfigReady {
    $cfgPath = Join-Path $ScriptRoot 'config.json'
    if (-not (Test-Path $cfgPath)) { return $false }
    try {
        $c = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $a = [string]$c.account
        $hasPwd = [bool]([string]$c.password) -or [bool]([string]$c.passwordProtected)
        if (-not $a -or -not $hasPwd) { return $false }
        if ($a -match '在这里填|xxxx' -or ([string]$c.password) -match '在这里填|填你的|你的密码') { return $false }
        return $true
    } catch { return $false }
}

# ---------------------------------------------------------------- 状态
function Show-Status {
    Write-Info ''
    Write-Info '===== SNNU 自动认证 - 安装状态 ====='

    $task = $null
    try { $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch { }

    if (Test-ConfigReady) {
        Write-Good '配置      : 已完成(账号 + 密码)'
    } else {
        Write-Err  '配置      : 未完成 —— 请先运行  .\SNNU-AutoLogin.ps1 -Setup'
    }

    if ($task) {
        Write-Good "计划任务  : 已安装 (状态: $($task.State))"
        try {
            $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
            if ($info) {
                Write-Host  "            上次运行: $($info.LastRunTime)  结果: $($info.LastTaskResult)"
                Write-Host  "            下次运行: $($info.NextRunTime)"
            }
        } catch { }
    } else {
        Write-Warn2 '计划任务  : 未安装'
    }

    if (Test-Path $VbsPath) {
        Write-Good "启动文件夹: 已安装 ($VbsPath)"
    } else {
        Write-Warn2 '启动文件夹: 未安装'
    }

    $procs = @(Get-DaemonProcess)
    if (Test-DaemonAlive) {
        $pids = if ($procs.Count -gt 0) { ' (PID: ' + ($procs.ProcessId -join ', ') + ')' } else { '' }
        Write-Good "守护进程  : 正在运行$pids"
    } else {
        Write-Warn2 '守护进程  : 未在运行(可运行 .\install-autostart.ps1 重新拉起)'
    }

    if (Test-Path (Join-Path $ScriptRoot 'logs\snnu-autologin.log')) {
        Write-Host ''
        Write-Info '--- 最近 8 行日志 ---'
        Get-Content (Join-Path $ScriptRoot 'logs\snnu-autologin.log') -Tail 8 | ForEach-Object { Write-Host "  $_" }
    }
    Write-Host ''
}

if ($Status) { Show-Status; return }

# ---------------------------------------------------------------- 卸载
function Remove-All {
    Write-Info '正在卸载...'

    try {
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Good '已删除计划任务。'
        }
    } catch { Write-Warn2 "删除计划任务失败: $($_.Exception.Message)" }

    if (Test-Path $VbsPath) {
        Remove-Item $VbsPath -Force
        Write-Good '已删除启动文件夹项。'
    }

    $hiddenVbs = Join-Path $ScriptRoot 'SNNU-AutoLogin-hidden.vbs'
    if (Test-Path $hiddenVbs) {
        Remove-Item $hiddenVbs -Force
        Write-Good '已删除无窗口启动器。'
    }

    # wscript 可能还在等守护进程退出,一并收掉
    foreach ($w in @(Get-CimInstance Win32_Process -Filter "Name='wscript.exe'" -ErrorAction SilentlyContinue |
                     Where-Object { $_.CommandLine -like '*SNNU-AutoLogin-hidden.vbs*' })) {
        try { Stop-Process -Id $w.ProcessId -Force; Write-Good "已停止启动器 wscript PID $($w.ProcessId)" } catch { }
    }

    foreach ($p in @(Get-DaemonProcess)) {
        try { Stop-Process -Id $p.ProcessId -Force; Write-Good "已停止守护进程 PID $($p.ProcessId)" } catch { }
    }

    Write-Good '卸载完成。'
}

if ($Uninstall) { Remove-All; return }

# ---------------------------------------------------------------- 无窗口启动器
# 为什么不能直接用 powershell.exe -WindowStyle Hidden:
#   那个参数是在控制台窗口已经创建之后才去隐藏它的,所以每次启动都会闪一下。
#   自愈触发器每 5 分钟拉一次,就等于每 5 分钟闪一次,很烦人。
# wscript.exe 属于 GUI 子系统程序,自己压根不创建控制台;
# 由它去启动 PowerShell 并指定窗口样式 0,才是真正的完全无窗口。
function Write-HiddenLauncher {
    $vbsPath = Join-Path $ScriptRoot 'SNNU-AutoLogin-hidden.vbs'
    $cmd = 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{0}"" -Daemon' -f $MainScript
    $vbs = @"
' SNNU 校园网自动认证 - 无窗口启动器(由 install-autostart.ps1 自动生成,勿手改)
' 最后一个参数 True 表示等 PowerShell 退出后再返回,
' 这样计划任务在整个守护进程生命周期内都保持 Running 状态,进程树不会被提前收走。
Dim sh, rc
Set sh = CreateObject("WScript.Shell")
rc = sh.Run("$cmd", 0, True)
WScript.Quit rc
"@
    Set-Content -Path $vbsPath -Value $vbs -Encoding ASCII
    return $vbsPath
}

# ---------------------------------------------------------------- 安装: 计划任务
function Install-Task {
    $vbsPath = Write-HiddenLauncher
    Write-Good "已生成无窗口启动器: SNNU-AutoLogin-hidden.vbs"

    # 关键: 执行的是 wscript.exe(无控制台),而不是 powershell.exe(会闪窗)
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' `
        -Argument ('//nologo "{0}"' -f $vbsPath) `
        -WorkingDirectory $ScriptRoot

    # 触发器 1: 登录后 15 秒启动,给网络栈留出协商时间
    $triggerLogon = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $triggerLogon.Delay = 'PT15S'

    # 触发器 2: 每 1 分钟重复运行一次,无限期。
    # 真正的自愈机制 —— 进程被杀/崩溃/被安全软件误杀后,最多 1 分钟就会被重新拉起。
    # 之所以用 1 分钟: 守护进程存活期间任务一直是 Running, MultipleInstances=IgnoreNew
    # 会让重复触发直接跳过, 所以健康时这个触发器零开销; 而一旦死了, 恢复快得多。
    # (之前是 5 分钟, 加上下面"注册后立即启动"的改动, 空窗期从最长 5 分钟降到几秒。)
    $triggerRepeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes 1)
    # PS 5.1 默认会给重复设一个 Duration 导致只重复有限次;清空才是"无限期重复"
    try {
        $triggerRepeat.Repetition.Duration = ''
        $triggerRepeat.Repetition.StopAtDurationEnd = $false
    } catch { }

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit ([TimeSpan]::Zero)

    # 显式写这两个属性: 早期版本用 -RestartCount 参数时没能真正落盘(导出的 XML 里
    # <RestartOnFailure> 是空的),所以这里直接赋值。
    $settings.RestartCount    = 3
    $settings.RestartInterval = 'PT1M'
    $settings.Hidden          = $true

    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

    Register-ScheduledTask -TaskName $TaskName -Action $action `
        -Trigger $triggerLogon, $triggerRepeat `
        -Settings $settings -Principal $principal `
        -Description 'SNNU 校园网自动认证守护进程(掉线自动重连, 无窗口)' -Force | Out-Null

    Write-Good "已注册计划任务: $TaskName (登录时 + 每1分钟自愈, 经 wscript 启动, 不闪窗)"

    # 关键: 注册/覆盖任务会终止掉正在运行的旧实例(连带守护进程一起),
    # 如果只等下一个重复触发器, 就会留下最长 1 分钟的保护空窗。
    # 所以注册完立刻把任务拉起来 —— 用户跑完安装马上就有保护。
    Write-Info '正在立即启动守护进程...'
    Start-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $okStart = $false
    for ($i = 1; $i -le 15; $i++) {
        Start-Sleep -Seconds 1
        if (Test-DaemonAlive) { $okStart = $true; break }
    }
    if ($okStart) {
        $pids = @(Get-DaemonProcess | Select-Object -ExpandProperty ProcessId)
        if ($pids.Count -gt 0) { Write-Good ("守护进程已在运行 (PID " + ($pids -join ',') + ")") }
        else { Write-Good '守护进程已在运行' }
    } else {
        Write-Warn2 '守护进程没有在 15 秒内起来, 但计划任务的每分钟触发器会在 1 分钟内把它拉起来。'
    }
}

# ---------------------------------------------------------------- 安装: 启动文件夹
function Install-Startup {
    # 用 VBS 启动可以做到完全无窗口闪现
    $vbs = @"
' SNNU 校园网自动认证 - 无窗口启动器
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$MainScript"" -Daemon", 0, False
"@
    Set-Content -Path $VbsPath -Value $vbs -Encoding ASCII
    Write-Good "已写入启动项: $VbsPath"
}

# ---------------------------------------------------------------- 执行安装
Write-Info ''
Write-Info '===== 安装 SNNU 校园网自动认证 ====='

# 没配置就装自启是没意义的: 守护进程每次启动都会因缺配置报错退出。
if (-not (Test-ConfigReady)) {
    Write-Err ''
    Write-Err '配置还没完成,先配置再装开机自启。'
    Write-Err '  配置文件: ' + (Join-Path $ScriptRoot 'config.json')
    Write-Host ''
    Write-Host '请先运行(会在窗口里依次问你账号、代理商、密码):' -ForegroundColor Gray
    Write-Host '  .\SNNU-AutoLogin.ps1 -Setup' -ForegroundColor Gray
    Write-Host ''
    Write-Host '配置好之后,再运行一次本脚本即可。' -ForegroundColor Gray
    Write-Host ''
    exit 1
}

$ok = $false
if ($Method -eq 'Task') {
    try {
        Install-Task
        $ok = $true
    } catch {
        Write-Warn2 "计划任务方式失败: $($_.Exception.Message)"
        Write-Warn2 '自动改用启动文件夹方式...'
    }
}

if (-not $ok) {
    Write-Warn2 '本次使用启动文件夹方式安装。'
    Install-Startup
}

if ($RunNow) {
    Write-Info '正在立即启动守护进程...'
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Daemon' -f $MainScript) `
        -WindowStyle Hidden
    Start-Sleep -Seconds 3
}

Show-Status
Write-Good '安装完成。下次登录 Windows 时会自动开始认证。'
Write-Host ''
Write-Host '手动控制:' -ForegroundColor Gray
Write-Host ("  查看状态: .\{0} -Status" -f (Split-Path $MainScript -Leaf)) -ForegroundColor Gray
Write-Host '  卸载    : .\install-autostart.ps1 -Uninstall' -ForegroundColor Gray
Write-Host ''
