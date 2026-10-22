#Requires -Version 5.1
<#
.SYNOPSIS
    安装 / 卸载“中国矿业大学校园网自动登录”计划任务。

.DESCRIPTION
    安装后会在当前用户登录 Windows 时自动启动 Connect-CampusNet.ps1 -Watch，
    以后台守护方式每 30 秒检测一次网络，断网自动重连。

.PARAMETER Uninstall
    删除计划任务并停止正在运行的守护进程。

.PARAMETER DryRun
    只打印将要创建的计划任务信息，不实际注册（用于检查配置）。

.PARAMETER NoTest
    安装完成后不立即执行一次登录测试。

.PARAMETER Pause
    结束时等待回车（由安装脚本自动提升时使用）。
#>

[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$DryRun,
    [switch]$NoTest,
    [switch]$Pause
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
$taskName = 'CUMT校园网自动登录'
$mainScript = Join-Path $scriptDir 'Connect-CampusNet.ps1'
$configFile = Join-Path $scriptDir 'config.json'
$currentUser = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME

function Test-Administrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal -ArgumentList $identity
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Wait-KeyIfNeeded {
    if ($Pause) { Read-Host '按回车键退出' | Out-Null }
}

Write-Host '====================================================' -ForegroundColor Cyan
Write-Host '  中国矿业大学校园网自动登录 - 安装/卸载工具' -ForegroundColor Cyan
Write-Host '====================================================' -ForegroundColor Cyan
Write-Host ''

if (-not (Test-Administrator) -and -not $DryRun) {
    Write-Host '需要管理员权限，正在请求提升（请在 UAC 窗口点“是”）...' -ForegroundColor Yellow
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    if ($Uninstall) { $arguments += '-Uninstall' }
    $arguments += '-Pause'
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs
    exit
}

# ---------------------------------------------------------------------------
# 卸载
# ---------------------------------------------------------------------------
if ($Uninstall) {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host '已删除计划任务，自动登录已关闭。' -ForegroundColor Green
    } else {
        Write-Host '没有找到计划任务，无需卸载。' -ForegroundColor Yellow
    }
    Wait-KeyIfNeeded
    exit
}

# ---------------------------------------------------------------------------
# 安装
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $mainScript)) {
    Write-Host ("找不到主脚本：{0}" -f $mainScript) -ForegroundColor Red
    Write-Host '请确认 Connect-CampusNet.ps1 与本安装脚本在同一个文件夹。' -ForegroundColor Red
    Wait-KeyIfNeeded
    exit 1
}

if (-not (Test-Path -LiteralPath $configFile)) {
    Write-Host ("警告：没有找到配置文件 {0}，将使用脚本内置账号。" -f $configFile) -ForegroundColor Yellow
}

$arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Watch' -f $mainScript
$description = '登录中国矿业大学校园网（10.2.5.251，中国移动），断网自动重连。'

if ($DryRun) {
    Write-Host '【DryRun】将创建以下计划任务：' -ForegroundColor Cyan
    Write-Host ("  任务名称：{0}" -f $taskName)
    Write-Host ("  运行账号：{0}（最高权限）" -f $currentUser)
    Write-Host '  触发条件：当前用户登录时（延迟 10 秒）'
    Write-Host ("  执行命令：powershell.exe {0}" -f $arguments)
    Write-Host '  运行策略：仅在交流电/电池下都运行；无限时长；多实例忽略新任务'
    Write-Host ("  主脚本：{0}" -f $mainScript)
    Write-Host ("  配置文件：{0}" -f $configFile)
    Write-Host '【DryRun】未做任何修改。'
    exit 0
}

$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host '检测到旧任务，先停止并删除...' -ForegroundColor Yellow
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments -WorkingDirectory $scriptDir
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
try { $trigger.Delay = 'PT10S' } catch { }

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::Zero)
try {
    $settings.RestartCount = 3
    $settings.RestartInterval = 'PT1M'
} catch { }

$principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Highest

Register-ScheduledTask -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description $description `
    -Force | Out-Null

Write-Host '计划任务创建成功。' -ForegroundColor Green
Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 2

$taskInfo = Get-ScheduledTask -TaskName $taskName | Get-ScheduledTaskInfo
Write-Host ("任务状态：{0}，上次结果：{1}" -f (Get-ScheduledTask -TaskName $taskName).State, $taskInfo.LastTaskResult) -ForegroundColor Gray

if (-not $NoTest) {
    Write-Host ''
    Write-Host '正在执行一次登录测试（可能需要 5~40 秒）...' -ForegroundColor Cyan
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $mainScript -Force
    if ($LASTEXITCODE -eq 0) {
        Write-Host '登录测试通过：当前可以正常上网。' -ForegroundColor Green
    } else {
        Write-Host '登录测试未通过：如果你现在不在校园网环境，这是正常的；连上校园网后守护进程会自动登录。' -ForegroundColor Yellow
        Write-Host '如已在校园网仍失败，请运行：powershell -ExecutionPolicy Bypass -File .\Connect-CampusNet.ps1 -Diagnose' -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host '----------------------------------------------------' -ForegroundColor Cyan
Write-Host '安装完成。' -ForegroundColor Green
Write-Host ("  任务名称：{0}" -f $taskName)
Write-Host '  触发方式：登录 Windows 后自动在后台运行'
Write-Host '  检测间隔：30 秒（断网自动重连）'
Write-Host ("  日志文件：{0}" -f (Join-Path $env:LOCALAPPDATA 'CUMTNet\campusnet.log'))
Write-Host ("  修改账号：记事本打开 {0}" -f $configFile)
Write-Host '  卸载方法：运行“卸载自动登录.cmd”'
Write-Host '----------------------------------------------------' -ForegroundColor Cyan

Wait-KeyIfNeeded
