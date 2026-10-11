<#
=======================================================================
 把校园网密码用 Windows DPAPI 加密后写进 config.json
=======================================================================
 加密后的密码只有"本机 + 本用户"能解开,别人拷走 config.json 也读不出密码。

 用法:
   .\Set-Password.ps1                     # 交互式输入密码(不显示在屏幕上)
   .\Set-Password.ps1 -Account 20250001   # 顺便改账号
   .\Set-Password.ps1 -Plain              # 改回明文保存(不推荐)

 说明: 加密后 config.json 里的 password 会留空,
      改用 passwordProtected 字段。
=======================================================================
#>

[CmdletBinding()]
param(
    [string]$Account,
    [switch]$Plain
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptRoot 'config.json'

if (-not (Test-Path $ConfigPath)) {
    Write-Host "找不到 config.json: $ConfigPath" -ForegroundColor Red
    exit 1
}

$cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

if ($Account) { $cfg.account = $Account }

if ($Plain) {
    $sec = Read-Host '请输入校园网密码(明文保存)' -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    $cfg.password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    $cfg.passwordProtected = ''
    Write-Host '已改为明文保存。' -ForegroundColor Yellow
} else {
    $sec = Read-Host '请输入校园网密码(输入时不显示)' -AsSecureString
    $enc = ConvertFrom-SecureString $sec
    $cfg.password = ''
    $cfg.passwordProtected = $enc
    Write-Host '密码已用 DPAPI 加密(仅本机本用户可解密)。' -ForegroundColor Green
}

# 保持原有字段顺序,排序后写回
$ordered = [ordered]@{}
foreach ($k in @('account','password','passwordProtected','isp','portal','portalFallback',
                 'checkIntervalSeconds','failureRetrySeconds','expectedSsid',
                 'accountWithSuffix','logoffBeforeLogin','checkUrls')) {
    if ($cfg.PSObject.Properties.Name -contains $k) { $ordered[$k] = $cfg.$k }
}
foreach ($p in $cfg.PSObject.Properties) {
    if (-not $ordered.Contains($p.Name)) { $ordered[$p.Name] = $p.Value }
}

$ordered | ConvertTo-Json -Depth 6 | Set-Content -Path $ConfigPath -Encoding UTF8
Write-Host "已更新: $ConfigPath" -ForegroundColor Green
Write-Host ''
Write-Host '现在可以验证一下:' -ForegroundColor Gray
Write-Host '  .\SNNU-AutoLogin.ps1 -Diagnose' -ForegroundColor Gray
Write-Host ''
