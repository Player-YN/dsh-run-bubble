#Requires -Version 5.1
<#
.SYNOPSIS
    dsh-run-bubble 的 daemon 启动包装器（由 Windows 计划任务调用）。
.DESCRIPTION
    计划任务不能直接重定向标准输出，所以 DshRunBubble-Daemon 计划任务实际调用本脚本：
    它定位 node.exe，在安装目录里前台运行 daemon.mjs，并把 stdout/stderr 追加到
    %LOCALAPPDATA%\dsh-run-bubble\logs\daemon.{out,err}.log。

    注意：PowerShell 对原生命令的 `1>>`/`2>>` 重定向带缓冲，长时间运行的 daemon
    在退出前看不到输出。这里改用 cmd.exe 继承文件句柄（无缓冲、可追加），
    `logs` 命令因此能实时看到 daemon 输出。

    也可以手动运行来复现安装后的行为：
        pwsh -NoProfile -File "%LOCALAPPDATA%\dsh-run-bubble\scripts\Start-Daemon.ps1"
.PARAMETER Node
    node.exe 的绝对路径（install 时写入计划任务参数，避免依赖 PATH）。
.PARAMETER InstallDir
    安装目录；默认取本脚本所在 scripts 目录的上一级。
#>
param(
    [string]$Node = '',
    [string]$InstallDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-EnvValue {
    param([string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ($null -eq $value) { return '' }
    return $value
}

function Write-DaemonLog {
    param([string]$Message)
    try {
        Add-Content -LiteralPath $script:OutLog -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    catch {
        # 日志写入失败时不再抛出：包装器必须保持安静并返回非零退出码。
    }
}

# ---------------------------------------------------------------------------
# 安装目录 / 日志路径
# ---------------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $InstallDir = (Get-Location).Path
    }
    else {
        $InstallDir = Split-Path -Parent $PSScriptRoot
    }
}
$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)
$script:LogDir = Join-Path $InstallDir 'logs'
$script:OutLog = Join-Path $script:LogDir 'daemon.out.log'
$script:ErrLog = Join-Path $script:LogDir 'daemon.err.log'

try {
    if (-not (Test-Path -LiteralPath $script:LogDir)) {
        New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    }
}
catch {
    # 无法创建日志目录时仍尝试直接运行（计划任务会记录退出码）。
}

# ---------------------------------------------------------------------------
# 定位 node.exe
# ---------------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($Node) -or -not (Test-Path -LiteralPath $Node)) {
    $command = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace($command.Source)) {
        $Node = $command.Source
    }
    else {
        $candidates = @(
            (Join-Path (Get-EnvValue 'ProgramFiles') 'nodejs\node.exe'),
            (Join-Path (Get-EnvValue 'ProgramFiles(x86)') 'nodejs\node.exe'),
            (Join-Path (Get-EnvValue 'LOCALAPPDATA') 'Programs\nodejs\node.exe')
        )
        foreach ($candidate in $candidates) {
            if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
                $Node = $candidate
                break
            }
        }
    }
}

$daemonPath = Join-Path $InstallDir 'daemon.mjs'
$launcherScript = $null

try {
    if ([string]::IsNullOrWhiteSpace($Node) -or -not (Test-Path -LiteralPath $Node)) {
        throw ('找不到 node.exe。请安装 Node.js 20+，或重新运行 run-bubble.ps1 install。')
    }
    if (-not (Test-Path -LiteralPath $daemonPath)) {
        throw ('找不到 daemon.mjs：{0}（安装目录不完整，请重新运行 run-bubble.ps1 install）' -f $daemonPath)
    }

    Write-DaemonLog ("启动 daemon：node={0} daemon={1}" -f $Node, $daemonPath)

    # 用 cmd.exe 的追加重定向运行 node：文件句柄直接继承，输出不被 PowerShell 缓冲。
    $launcherDir = Join-Path ([System.IO.Path]::GetTempPath()) 'dsh-run-bubble'
    if (-not (Test-Path -LiteralPath $launcherDir)) {
        New-Item -ItemType Directory -Path $launcherDir -Force | Out-Null
    }
    $launcherScript = Join-Path $launcherDir ('start-daemon-' + [guid]::NewGuid().ToString('N') + '.cmd')
    $commandLines = @(
        '@echo off',
        ('"{0}" "{1}" 1>>"{2}" 2>>"{3}"' -f $Node, $daemonPath, $script:OutLog, $script:ErrLog),
        'exit /b %ERRORLEVEL%'
    )
    Set-Content -LiteralPath $launcherScript -Value ($commandLines -join "`r`n") -Encoding Ascii

    $comspec = Get-EnvValue 'ComSpec'
    if ([string]::IsNullOrWhiteSpace($comspec)) { $comspec = 'cmd.exe' }
    & $comspec /d /c $launcherScript
    $exitCode = $LASTEXITCODE

    Write-DaemonLog ("daemon 退出，退出码 {0}" -f $exitCode)
    exit $exitCode
}
catch {
    try {
        Add-Content -LiteralPath $script:ErrLog -Value ("[{0}] 启动失败: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message) -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    catch { }
    exit 1
}
finally {
    if (-not [string]::IsNullOrWhiteSpace($launcherScript) -and (Test-Path -LiteralPath $launcherScript)) {
        Remove-Item -LiteralPath $launcherScript -Force -ErrorAction SilentlyContinue
    }
}
