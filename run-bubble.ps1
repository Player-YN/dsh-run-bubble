#Requires -Version 5.1
<#
.SYNOPSIS
    dsh-run-bubble 的 Windows 生命周期启动器（等价 macOS 的 run-bubble）。
.DESCRIPTION
    管理两个进程：
      * node daemon.mjs            —— 采集会话，写 %USERPROFILE%\.dsh\run-bubble\status.json
      * RunBubbleOverlay.exe       —— 置顶气泡渲染
    通过两个计划任务（DshRunBubble-Daemon / DshRunBubble-Overlay）实现登录自启，
    等价 launchd 的 KeepAlive（登录触发 + 单实例 + 失败 1 分钟重启）。

    兼容 Windows PowerShell 5.1 与 PowerShell 7.x。
    参数同时接受 PowerShell 原生写法（-Rebuild）与 macOS 文档风格（--rebuild）。

.EXAMPLE
    powershell.exe -NoProfile -File run-bubble.ps1 install
    pwsh -NoProfile -File run-bubble.ps1 install -Rebuild -SelfContained
    pwsh -NoProfile -File run-bubble.ps1 status
    pwsh -NoProfile -File run-bubble.ps1 snapshot "$env:TEMP\bubble.png"
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ===========================================================================
# 基础工具
# ===========================================================================

function Get-EnvValue {
    param([string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ($null -eq $value) { return '' }
    return $value
}

function Invoke-Native {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @()
    )
    # Windows PowerShell 5.1 会把原生 stderr 变成错误记录；配合 Stop 时，
    # "任务不存在"、"schtasks 查询失败" 这类正常情况会中断脚本。
    # 局部降级为 Continue，只依据退出码做判断。
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $FilePath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    return @{ ExitCode = $exitCode; Text = (($output | Out-String).Trim()) }
}

function Get-FileIntegrityLabel {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '缺失' }
    $result = Invoke-Native -FilePath 'icacls.exe' -Arguments @($Path)
    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.Text)) { return '未知' }
    if ($result.Text -like '*Low Mandatory Level*') { return 'Low' }
    if ($result.Text -like '*Medium Mandatory Level*') { return 'Medium' }
    if ($result.Text -like '*High Mandatory Level*') { return 'High' }
    if ($result.Text -like '*System Mandatory Level*') { return 'System' }
    if ($result.Text -like '*Mandatory Label*') { return '未知' }
    # 没有显式标签时进程按 Medium 运行（安装目录 %LOCALAPPDATA% 继承默认级别）。
    return '无标签'
}

function Get-EffectiveIntegrityLabel {
    param([string]$Label)
    if ($Label -eq '无标签') { return 'Medium（默认）' }
    return $Label
}

function Set-FileIntegrityMedium {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $result = Invoke-Native -FilePath 'icacls.exe' -Arguments @($Path, '/setintegritylevel', 'Medium')
    return ($result.ExitCode -eq 0)
}

function Write-WarnLine {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Yellow
}

function Write-Fail {
    param(
        [string]$Message,
        [string[]]$Hints = @()
    )
    Write-Host ''
    Write-Host ("run-bubble: {0}" -f $Message) -ForegroundColor Red
    foreach ($hint in $Hints) { Write-Host ("  {0}" -f $hint) }
    Write-Host ''
    exit 1
}

function Show-Usage {
    Write-Host ''
    Write-Host 'dsh-run-bubble（Windows 启动器）' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '用法: run-bubble.ps1 <命令> [参数]'
    Write-Host ''
    Write-Host '命令:'
    Write-Host '  install [-Rebuild] [-SelfContained]'
    Write-Host '                 构建（如需）→ 复制到 %LOCALAPPDATA%\dsh-run-bubble → 注册计划任务 → 启动'
    Write-Host '  start          启动两个计划任务'
    Write-Host '  stop           停止计划任务，并按 PID 清理残留的 daemon / overlay 进程'
    Write-Host '  restart        stop + start'
    Write-Host '  status         查看 daemon / overlay PID、status.json 摘要与 daemon 判定模式（只读）'
    Write-Host '  doctor         一次性自检：node / .NET / 产物 / 计划任务 / 进程 / status.json / 租约探针'
    Write-Host '  logs           tail 三个日志文件最后 40 行'
    Write-Host '  snapshot [path] 调用 overlay 生成 PNG 快照（默认 %TEMP%\dsh-run-bubble.png）'
    Write-Host '  uninstall      停止 → 注销计划任务 → 删除安装目录（保留会话状态文件）'
    Write-Host '  help           显示本帮助'
    Write-Host ''
    Write-Host '选项（与 --flag 写法等价）:'
    Write-Host '  -Rebuild / --rebuild            强制重新构建 overlay'
    Write-Host '  -SelfContained / --self-contained  自包含发布（目标机无需 .NET 运行时）'
    Write-Host ''
    Write-Host '环境变量:'
    Write-Host '  RUN_BUBBLE_INSTALL_DIR   覆盖安装目录（默认 %LOCALAPPDATA%\dsh-run-bubble）'
    Write-Host '  RUN_BUBBLE_STATUS_DIR    覆盖状态目录（默认 %DSH_HOME%\run-bubble 或 %USERPROFILE%\.dsh\run-bubble）'
    Write-Host '  DSH_HOME                 会话库根目录（默认 %USERPROFILE%\.dsh）'
    Write-Host '  RUN_BUBBLE_TASK_DAEMON / RUN_BUBBLE_TASK_OVERLAY  覆盖计划任务名（仅供测试）'
    Write-Host ''
    Write-Host '计划任务: 登录触发、当前用户、Limited 权限、MultipleInstances=IgnoreNew、失败 1 分钟重启。'
    Write-Host ''
}

# ===========================================================================
# 路径解析（安装目录 / 状态目录 / 计划任务名）
# ===========================================================================

$script:RepoRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($script:RepoRoot)) {
    $script:RepoRoot = (Get-Location).Path
}
$script:RepoRoot = [System.IO.Path]::GetFullPath($script:RepoRoot)

$installDirOverride = Get-EnvValue 'RUN_BUBBLE_INSTALL_DIR'
if (-not [string]::IsNullOrWhiteSpace($installDirOverride)) {
    $script:InstallDir = [System.IO.Path]::GetFullPath($installDirOverride)
}
else {
    $localAppData = Get-EnvValue 'LOCALAPPDATA'
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        $localAppData = Join-Path (Get-EnvValue 'USERPROFILE') 'AppData\Local'
    }
    $script:InstallDir = [System.IO.Path]::GetFullPath((Join-Path $localAppData 'dsh-run-bubble'))
}
$script:LogDir = Join-Path $script:InstallDir 'logs'

$statusDirOverride = Get-EnvValue 'RUN_BUBBLE_STATUS_DIR'
if (-not [string]::IsNullOrWhiteSpace($statusDirOverride)) {
    $script:StatusDir = [System.IO.Path]::GetFullPath($statusDirOverride)
}
else {
    $dshHome = Get-EnvValue 'DSH_HOME'
    if ([string]::IsNullOrWhiteSpace($dshHome)) {
        $userProfile = Get-EnvValue 'USERPROFILE'
        if ([string]::IsNullOrWhiteSpace($userProfile)) { $userProfile = $HOME }
        $dshHome = Join-Path $userProfile '.dsh'
    }
    $script:StatusDir = [System.IO.Path]::GetFullPath((Join-Path $dshHome 'run-bubble'))
}

$daemonTaskOverride = Get-EnvValue 'RUN_BUBBLE_TASK_DAEMON'
if (-not [string]::IsNullOrWhiteSpace($daemonTaskOverride)) { $script:TaskDaemon = $daemonTaskOverride }
else { $script:TaskDaemon = 'DshRunBubble-Daemon' }

$overlayTaskOverride = Get-EnvValue 'RUN_BUBBLE_TASK_OVERLAY'
if (-not [string]::IsNullOrWhiteSpace($overlayTaskOverride)) { $script:TaskOverlay = $overlayTaskOverride }
else { $script:TaskOverlay = 'DshRunBubble-Overlay' }

$script:StatusFile = Join-Path $script:StatusDir 'status.json'
$script:DaemonStateFile = Join-Path $script:StatusDir 'daemon.json'
$script:CurrentDaemonInfo = $null
$script:DoctorFailures = 0

# ===========================================================================
# 工具定位
# ===========================================================================

function Resolve-NodeExe {
    $command = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace($command.Source)) {
        return $command.Source
    }
    $candidates = New-Object System.Collections.Generic.List[string]
    $programFiles = Get-EnvValue 'ProgramFiles'
    if (-not [string]::IsNullOrWhiteSpace($programFiles)) {
        $candidates.Add((Join-Path $programFiles 'nodejs\node.exe'))
    }
    $programFilesX86 = Get-EnvValue 'ProgramFiles(x86)'
    if (-not [string]::IsNullOrWhiteSpace($programFilesX86)) {
        $candidates.Add((Join-Path $programFilesX86 'nodejs\node.exe'))
    }
    $localAppData = Get-EnvValue 'LOCALAPPDATA'
    if (-not [string]::IsNullOrWhiteSpace($localAppData)) {
        $candidates.Add((Join-Path $localAppData 'Programs\nodejs\node.exe'))
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Resolve-DotnetExe {
    $command = Get-Command dotnet.exe -ErrorAction SilentlyContinue
    if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace($command.Source)) {
        return $command.Source
    }
    $programFiles = Get-EnvValue 'ProgramFiles'
    if (-not [string]::IsNullOrWhiteSpace($programFiles)) {
        $candidate = Join-Path $programFiles 'dotnet\dotnet.exe'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Resolve-PowerShellExe {
    $command = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace($command.Source)) {
        return $command.Source
    }
    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($PSHOME)) {
        $candidates.Add((Join-Path $PSHOME 'pwsh.exe'))
        $candidates.Add((Join-Path $PSHOME 'powershell.exe'))
    }
    $systemRoot = Get-EnvValue 'SystemRoot'
    if (-not [string]::IsNullOrWhiteSpace($systemRoot)) {
        $candidates.Add((Join-Path $systemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'))
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return 'powershell.exe'
}

function Get-NodeVersionText {
    $nodeExe = Resolve-NodeExe
    if ($null -eq $nodeExe) { return '' }
    try { return (& $nodeExe --version 2>$null | Out-String).Trim() } catch { return '' }
}

# ===========================================================================
# 格式化 / JSON 小工具
# ===========================================================================

function Format-Duration {
    param([double]$Seconds)
    if ($Seconds -lt 0) { $Seconds = 0 }
    $total = [int][math]::Floor($Seconds)
    $hours = [int][math]::Floor($total / 3600)
    $minutes = [int][math]::Floor(($total % 3600) / 60)
    $rest = $total % 60
    if ($hours -gt 0) { return ('{0}:{1:00}:{2:00}' -f $hours, $minutes, $rest) }
    return ('{0}:{1:00}' -f $minutes, $rest)
}

function Get-ShortText {
    param([string]$Text, [int]$MaxLength)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    if ($Text.Length -le $MaxLength) { return $Text }
    if ($MaxLength -le 1) { return $Text.Substring(0, $MaxLength) }
    return $Text.Substring(0, $MaxLength - 1) + '…'
}

function Get-JsonProperty {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function ConvertTo-DoubleValue {
    param($Value, [double]$Default = 0)
    if ($null -eq $Value) { return $Default }
    try { return [double]$Value } catch { return $Default }
}

function Get-PngSizeText {
    param([string]$Path)
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -lt 24) { return $null }
        if ($bytes[0] -ne 0x89 -or $bytes[1] -ne 0x50 -or $bytes[2] -ne 0x4E -or $bytes[3] -ne 0x47) { return $null }
        $width = ([int]$bytes[16] -shl 24) -bor ([int]$bytes[17] -shl 16) -bor ([int]$bytes[18] -shl 8) -bor ([int]$bytes[19])
        $height = ([int]$bytes[20] -shl 24) -bor ([int]$bytes[21] -shl 16) -bor ([int]$bytes[22] -shl 8) -bor ([int]$bytes[23])
        return ('{0} x {1} 像素' -f $width, $height)
    }
    catch { return $null }
}

function Get-LogTail {
    param([string]$Path, [int]$Count = 40)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    try { return @(Get-Content -LiteralPath $Path -Tail $Count -ErrorAction Stop) }
    catch { return @() }
}

# ===========================================================================
# 进程 / 计划任务
# ===========================================================================

function Test-ProcessAlive {
    param([int]$ProcessId)
    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        return ($null -ne $process)
    }
    catch { return $false }
}

function Get-ProcessCommandLine {
    param([int]$ProcessId)
    try {
        $process = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $ProcessId) -ErrorAction Stop
        if ($null -ne $process) { return [string]$process.CommandLine }
    }
    catch { }
    return ''
}

function Get-CandidateProcesses {
    # 返回 @{ Available = <bool>; Items = <进程数组> }。
    # Available=$false 表示进程表不可用（例如 WMI 受限），与“没有进程”区分开。
    try {
        $filter = "Name='node.exe' OR Name='RunBubbleOverlay.exe' OR Name='pwsh.exe' OR Name='powershell.exe'"
        $items = @(Get-CimInstance Win32_Process -Filter $filter -ErrorAction Stop)
        return @{ Available = $true; Items = $items }
    }
    catch {
        return @{ Available = $false; Items = @() }
    }
}

function Get-InstallProcesses {
    $result = @{
        Available = $true
        Daemon    = @()
        Overlay   = @()
        Wrapper   = @()
    }
    $processSnapshot = Get-CandidateProcesses
    if (-not $processSnapshot.Available) {
        $result.Available = $false
        return $result
    }
    $processes = @($processSnapshot.Items)
    if (-not (Test-Path -LiteralPath $script:InstallDir)) { return $result }

    $overlayExe = Join-Path $script:InstallDir 'RunBubbleOverlay.exe'
    $daemonFile = Join-Path $script:InstallDir 'daemon.mjs'
    $wrapperFile = Join-Path $script:InstallDir 'scripts\Start-Daemon.ps1'

    $daemonIds = New-Object System.Collections.Generic.List[int]
    $overlayIds = New-Object System.Collections.Generic.List[int]
    $wrapperIds = New-Object System.Collections.Generic.List[int]

    foreach ($process in $processes) {
        $name = [string]$process.Name
        $commandLine = [string]$process.CommandLine
        $executablePath = [string]$process.ExecutablePath
        if ($name -ieq 'RunBubbleOverlay.exe') {
            if ($commandLine -like ('*' + $overlayExe + '*') -or $executablePath -ieq $overlayExe) {
                $overlayIds.Add([int]$process.ProcessId)
            }
        }
        elseif ($name -ieq 'node.exe') {
            if ($commandLine -like ('*' + $daemonFile + '*')) {
                $daemonIds.Add([int]$process.ProcessId)
            }
        }
        elseif ($name -ieq 'pwsh.exe' -or $name -ieq 'powershell.exe') {
            if ($commandLine -like ('*' + $wrapperFile + '*')) {
                $wrapperIds.Add([int]$process.ProcessId)
            }
        }
    }

    $result.Daemon = $daemonIds.ToArray()
    $result.Overlay = $overlayIds.ToArray()
    $result.Wrapper = $wrapperIds.ToArray()
    return $result
}

function Get-DaemonStateInfo {
    $result = @{
        Exists           = $false
        Pid              = $null
        Mode             = ''
        LeaseProbe       = ''
        SourceProbe      = ''
        IncludeAmbiguous = $null
    }
    if (-not (Test-Path -LiteralPath $script:DaemonStateFile)) { return $result }
    $document = $null
    try {
        $raw = Get-Content -LiteralPath $script:DaemonStateFile -Raw -ErrorAction Stop
        $document = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch { return $result }

    $result.Exists = $true
    $pidValue = Get-JsonProperty -Object $document -Name 'pid'
    if ($null -ne $pidValue) {
        try { $result.Pid = [int]$pidValue } catch { }
    }
    $modeValue = Get-JsonProperty -Object $document -Name 'mode'
    if ($null -ne $modeValue) { $result.Mode = [string]$modeValue }
    $leaseValue = Get-JsonProperty -Object $document -Name 'leaseProbe'
    if ($null -ne $leaseValue) { $result.LeaseProbe = [string]$leaseValue }
    $sourceValue = Get-JsonProperty -Object $document -Name 'sourceProbe'
    if ($null -ne $sourceValue) { $result.SourceProbe = [string]$sourceValue }
    $includeValue = Get-JsonProperty -Object $document -Name 'includeAmbiguous'
    if ($null -ne $includeValue) { $result.IncludeAmbiguous = [bool]$includeValue }

    # daemon 尚未写 leaseProbe/sourceProbe 时按 mode 推导，保证 status 输出稳定。
    if ([string]::IsNullOrWhiteSpace($result.LeaseProbe) -and -not [string]::IsNullOrWhiteSpace($result.Mode)) {
        if ($result.Mode -eq 'win-lease') { $result.LeaseProbe = 'ok' } else { $result.LeaseProbe = 'unavailable' }
    }
    if ([string]::IsNullOrWhiteSpace($result.SourceProbe) -and -not [string]::IsNullOrWhiteSpace($result.Mode)) {
        if ($result.Mode -eq 'win-lease' -or $result.Mode -eq 'win-sidecar') { $result.SourceProbe = 'cim' }
        else { $result.SourceProbe = 'none' }
    }
    return $result
}

function Get-DaemonStatePid {
    $state = Get-DaemonStateInfo
    return $state.Pid
}

function Test-TaskExists {
    param([string]$TaskName)
    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($null -ne $task) { return $true }
    }
    catch { }
    $queryResult = Invoke-Native -FilePath 'schtasks.exe' -Arguments @('/query', '/tn', $TaskName)
    return ($queryResult.ExitCode -eq 0)
}

function Get-TaskState {
    param([string]$TaskName)
    try { return (Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop) }
    catch { return $null }
}

function Stop-TaskSafely {
    param([string]$TaskName)
    # 三态区分：未注册 / 已注册但未运行 / 运行中，避免把"已注册但没在跑"说成"不存在"。
    $task = Get-TaskState -TaskName $TaskName
    if ($null -eq $task) {
        if (-not (Test-TaskExists -TaskName $TaskName)) {
            Write-Host ("  计划任务 {0}: 跳过（未注册）" -f $TaskName)
            return
        }
        Write-Host ("  计划任务 {0}: 已注册但读取状态失败，尝试直接停止" -f $TaskName)
    }
    else {
        $stateText = [string]$task.State
        if ($stateText -ne 'Running' -and $stateText -ne 'Queued') {
            Write-Host ("  计划任务 {0}: 无需停止（已注册，状态 {1}）" -f $TaskName, $stateText)
            return
        }
    }
    try {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        Write-Host ("  计划任务 {0}: 已停止" -f $TaskName)
        return
    }
    catch { }
    $endResult = Invoke-Native -FilePath 'schtasks.exe' -Arguments @('/end', '/tn', $TaskName)
    if ($endResult.ExitCode -eq 0) {
        Write-Host ("  计划任务 {0}: 已停止（schtasks 回退）" -f $TaskName)
    }
    else {
        Write-WarnLine ("  计划任务 {0}: 停止失败（{1}）" -f $TaskName, $endResult.Text)
    }
}

function Remove-TaskSafely {
    param([string]$TaskName)
    if (-not (Test-TaskExists -TaskName $TaskName)) {
        Write-Host ("  计划任务 {0}: 不存在，无需注销" -f $TaskName)
        return
    }
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Host ("  计划任务 {0}: 已注销" -f $TaskName)
        return
    }
    catch { }
    $deleteResult = Invoke-Native -FilePath 'schtasks.exe' -Arguments @('/delete', '/tn', $TaskName, '/f')
    if ($deleteResult.ExitCode -eq 0) {
        Write-Host ("  计划任务 {0}: 已注销（schtasks 回退）" -f $TaskName)
    }
    else {
        Write-WarnLine ("  计划任务 {0}: 注销失败（{1}）" -f $TaskName, $deleteResult.Text)
    }
}

function Start-BubbleServices {
    $startedCount = 0
    foreach ($taskName in @($script:TaskDaemon, $script:TaskOverlay)) {
        if (-not (Test-TaskExists -TaskName $taskName)) {
            Write-WarnLine ("  计划任务 {0}: 不存在（请先运行 install）" -f $taskName)
            continue
        }
        try {
            Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
            Write-Host ("  已启动计划任务 {0}" -f $taskName)
            $startedCount++
            continue
        }
        catch { }
        $runResult = Invoke-Native -FilePath 'schtasks.exe' -Arguments @('/run', '/tn', $taskName)
        if ($runResult.ExitCode -eq 0) {
            Write-Host ("  已启动计划任务 {0}（schtasks 回退）" -f $taskName)
            $startedCount++
        }
        else {
            Write-WarnLine ("  启动计划任务 {0} 失败（{1}）" -f $taskName, $runResult.Text)
        }
    }
    return $startedCount
}

function Stop-BubbleProcesses {
    param($StatePid = $null, [switch]$Quiet)
    $info = Get-InstallProcesses
    $candidateIds = New-Object System.Collections.Generic.List[int]
    foreach ($processId in @($info.Daemon)) { $candidateIds.Add([int]$processId) }
    foreach ($processId in @($info.Wrapper)) { $candidateIds.Add([int]$processId) }
    foreach ($processId in @($info.Overlay)) { $candidateIds.Add([int]$processId) }

    if ($null -ne $StatePid -and (Test-ProcessAlive -ProcessId ([int]$StatePid))) {
        # 必须用命令行确认它确实是 daemon.mjs：daemon.json 里的 pid 可能已陈旧并被系统复用，
        # 只按进程名 node 杀会误伤其他 Node 程序。
        $stateCommandLine = Get-ProcessCommandLine -ProcessId ([int]$StatePid)
        if ($stateCommandLine -like '*daemon.mjs*') {
            $candidateIds.Add([int]$StatePid)
        }
    }

    $killed = @()
    foreach ($processId in @($candidateIds | Sort-Object -Unique)) {
        try {
            Stop-Process -Id $processId -Force -ErrorAction Stop
            $killed += $processId
        }
        catch { }
    }
    if ($killed.Count -gt 0) {
        Write-Host ("  已结束残留进程 PID: {0}" -f ($killed -join ', '))
    }
    elseif (-not $Quiet) {
        Write-Host '  没有发现残留的 daemon / overlay 进程'
    }
}

function Remove-StaleDaemonState {
    if (-not (Test-Path -LiteralPath $script:DaemonStateFile)) { return }
    $statePid = Get-DaemonStatePid
    if ($null -ne $statePid -and (Test-ProcessAlive -ProcessId $statePid)) { return }
    try {
        Remove-Item -LiteralPath $script:DaemonStateFile -Force -ErrorAction Stop
        Write-Host '  已清理陈旧的 daemon.json'
    }
    catch { }
}

# ===========================================================================
# status / logs / snapshot
# ===========================================================================

function Show-ProcessLine {
    param(
        [string]$Label,
        [object]$ProcessIds,
        [string]$TaskName,
        [bool]$Installed
    )
    $ids = @($ProcessIds | Sort-Object -Unique)
    $value = '未运行'
    if ($ids.Count -gt 0) {
        $value = '运行中 PID ' + ($ids -join ', ')
    }
    $suffix = ''
    if ($Installed) {
        $task = Get-TaskState -TaskName $TaskName
        if ($null -ne $task) {
            $suffix = ('（计划任务 {0}: {1}）' -f $TaskName, [string]$task.State)
        }
        else {
            $suffix = ('（计划任务 {0} 未注册）' -f $TaskName)
        }
    }
    Write-Host ("  {0,-8}: {1}{2}" -f $Label, $value, $suffix)
}

function Show-StatusFile {
    Write-Host ''
    if (-not (Test-Path -LiteralPath $script:StatusFile)) {
        Write-Host ("  status.json: 未找到（{0}）" -f $script:StatusFile) -ForegroundColor Yellow
        Write-Host '    提示: daemon 尚未生成状态文件；运行 install/start 后重试，或查看 logs。'
        return
    }

    $item = Get-Item -LiteralPath $script:StatusFile
    $ageSeconds = ((Get-Date).ToUniversalTime() - $item.LastWriteTimeUtc).TotalSeconds
    if ($ageSeconds -lt 0) { $ageSeconds = 0 }
    $ageText = ('{0} 秒前更新' -f [int][math]::Round($ageSeconds))
    Write-Host ("  status.json: {0}（{1}）" -f $script:StatusFile, $ageText)
    if ($ageSeconds -gt 6) {
        Write-WarnLine '    状态已过期（>6s）：daemon 可能未运行或采集卡住，查看 logs。'
    }

    $raw = ''
    try { $raw = Get-Content -LiteralPath $script:StatusFile -Raw -ErrorAction Stop }
    catch {
        Write-WarnLine '    （无法读取状态文件，可能正在写入）'
        return
    }

    $document = $null
    try { $document = $raw | ConvertFrom-Json -ErrorAction Stop }
    catch {
        Write-WarnLine '    （status.json 解析失败：可能正在写入，稍后重试）'
        return
    }

    $roots = @()
    $rootsProperty = Get-JsonProperty -Object $document -Name 'roots'
    if ($null -ne $rootsProperty) { $roots = @($rootsProperty) }

    $childrenCount = 0
    $tokenTotal = 0
    $totals = Get-JsonProperty -Object $document -Name 'totals'
    if ($null -ne $totals) {
        $childrenCount = [int](ConvertTo-DoubleValue -Value (Get-JsonProperty -Object $totals -Name 'children') -Default 0)
        $tokens = Get-JsonProperty -Object $totals -Name 'tokens'
        if ($null -ne $tokens) {
            $tokenTotal = ConvertTo-DoubleValue -Value (Get-JsonProperty -Object $tokens -Name 'total') -Default 0
        }
    }

    Write-Host ("  roots: {0}  children: {1}  tokens.total: {2:N0}" -f $roots.Count, $childrenCount, $tokenTotal)

    if ($roots.Count -eq 0) {
        Write-Host '    （当前没有外部任务在运行）'
        if ($null -ne $script:CurrentDaemonInfo -and $script:CurrentDaemonInfo.Mode -eq 'win-lease') {
            Write-Host '    提示: 桌面会话已隐藏（RUN_BUBBLE_INCLUDE_DESKTOP=1 可显示）。'
        }
        return
    }

    for ($index = 0; $index -lt $roots.Count; $index++) {
        $root = $roots[$index]
        $title = [string](Get-JsonProperty -Object $root -Name 'title')
        $shortId = [string](Get-JsonProperty -Object $root -Name 'shortId')
        if ([string]::IsNullOrWhiteSpace($title)) { $title = $shortId }
        if ([string]::IsNullOrWhiteSpace($title)) { $title = '(未命名会话)' }

        $source = [string](Get-JsonProperty -Object $root -Name 'sourceLabel')
        if ([string]::IsNullOrWhiteSpace($source)) { $source = [string](Get-JsonProperty -Object $root -Name 'source') }
        if ([string]::IsNullOrWhiteSpace($source)) { $source = 'unknown' }

        $turn = [int](ConvertTo-DoubleValue -Value (Get-JsonProperty -Object $root -Name 'turn') -Default 0)
        $elapsedMs = ConvertTo-DoubleValue -Value (Get-JsonProperty -Object $root -Name 'elapsedMs') -Default 0
        $activeValue = Get-JsonProperty -Object $root -Name 'active'
        $activeText = '空闲'
        if ($null -ne $activeValue) {
            if ([bool]$activeValue) { $activeText = '活跃' }
        }

        Write-Host ("    {0}. [{1}] {2} · turn {3} · {4} · {5}" -f ($index + 1), $source, (Get-ShortText -Text $title -MaxLength 40), $turn, (Format-Duration -Seconds ($elapsedMs / 1000)), $activeText)
    }
}

function Show-Status {
    Write-Host ''
    Write-Host 'dsh-run-bubble 状态' -ForegroundColor Cyan

    $installed = Test-Path -LiteralPath $script:InstallDir
    if ($installed) {
        Write-Host ("  安装目录 : {0}" -f $script:InstallDir)
    }
    else {
        Write-Host ("  安装目录 : {0}（未安装，先运行 install）" -f $script:InstallDir) -ForegroundColor Yellow
    }

    $info = Get-InstallProcesses

    $daemonIds = @($info.Daemon)
    $statePid = Get-DaemonStatePid
    if ($null -ne $statePid -and (Test-ProcessAlive -ProcessId $statePid)) {
        $alreadyListed = $false
        foreach ($existingId in $daemonIds) {
            if ([int]$existingId -eq $statePid) { $alreadyListed = $true; break }
        }
        if (-not $alreadyListed) {
            $stateCommandLine = Get-ProcessCommandLine -ProcessId $statePid
            if ($stateCommandLine -like '*daemon.mjs*') {
                $daemonIds += $statePid
            }
        }
    }

    Show-ProcessLine -Label 'daemon' -ProcessIds $daemonIds -TaskName $script:TaskDaemon -Installed $installed
    Show-ProcessLine -Label 'overlay' -ProcessIds $info.Overlay -TaskName $script:TaskOverlay -Installed $installed
    if (@($info.Wrapper).Count -gt 0) {
        Write-Host ("  包装器   : 运行中 PID {0}（daemon 由计划任务包装器拉起）" -f (@($info.Wrapper) -join ', '))
    }
    if (-not $info.Available) {
        Write-WarnLine '  （进程表不可用：PID 仅依据 daemon.json 判断）'
    }

    if ($installed) {
        $overlayIntegrity = '-'
        $probeIntegrity = '-'
        $daemonIntegrity = '-'
        $overlayBinary = Join-Path $script:InstallDir 'RunBubbleOverlay.exe'
        $probeBinary = Join-Path $script:InstallDir 'DshLeaseProbe.exe'
        $daemonBinary = Join-Path $script:InstallDir 'daemon.mjs'
        if (Test-Path -LiteralPath $overlayBinary) {
            $overlayIntegrity = Get-EffectiveIntegrityLabel -Label (Get-FileIntegrityLabel -Path $overlayBinary)
        }
        if (Test-Path -LiteralPath $probeBinary) {
            $probeIntegrity = Get-EffectiveIntegrityLabel -Label (Get-FileIntegrityLabel -Path $probeBinary)
        }
        if (Test-Path -LiteralPath $daemonBinary) {
            $daemonIntegrity = Get-EffectiveIntegrityLabel -Label (Get-FileIntegrityLabel -Path $daemonBinary)
        }
        Write-Host ("  完整性   : overlay={0}  probe={1}  daemon.mjs={2}" -f $overlayIntegrity, $probeIntegrity, $daemonIntegrity)
    }

    $daemonState = Get-DaemonStateInfo
    $script:CurrentDaemonInfo = $daemonState
    if ($daemonState.Exists) {
        $modeText = $daemonState.Mode
        if ([string]::IsNullOrWhiteSpace($modeText)) { $modeText = 'unknown' }
        $leaseText = $daemonState.LeaseProbe
        if ([string]::IsNullOrWhiteSpace($leaseText)) { $leaseText = 'unknown' }
        $sourceText = $daemonState.SourceProbe
        if ([string]::IsNullOrWhiteSpace($sourceText)) { $sourceText = 'none' }
        Write-Host ("  mode     : {0}    leaseProbe: {1}    sourceProbe: {2}" -f $modeText, $leaseText, $sourceText)
        if ($null -ne $daemonState.IncludeAmbiguous -and $daemonState.IncludeAmbiguous) {
            Write-Host '             （includeAmbiguous=on：未证明归属的会话也会显示）'
        }
    }
    else {
        Write-Host '  mode     : 未知（没有 daemon.json，daemon 未运行过）'
    }

    Show-StatusFile
}

function Show-Logs {
    if (-not (Test-Path -LiteralPath $script:InstallDir)) {
        Write-WarnLine ("尚未安装：{0} 不存在。先运行 run-bubble.ps1 install。" -f $script:InstallDir)
        return
    }
    $entries = @(
        @{ Path = (Join-Path $script:LogDir 'daemon.out.log'); Label = 'daemon 标准输出'; Hint = 'daemon 尚未启动，或还没有输出。' },
        @{ Path = (Join-Path $script:LogDir 'daemon.err.log'); Label = 'daemon 标准错误'; Hint = 'daemon 尚未启动，或还没有错误输出。' },
        @{ Path = (Join-Path $script:LogDir 'overlay.err.log'); Label = 'overlay 标准错误'; Hint = 'overlay 是无控制台窗口程序，通常不产生 stderr；不存在属正常。' },
        @{ Path = (Join-Path $script:LogDir 'daemon.log'); Label = 'daemon 自身日志'; Hint = 'daemon 自己的守护日志（采集错误/重试会写这里）。' }
    )
    foreach ($entry in $entries) {
        Write-Host ''
        Write-Host ("===== {0}（{1}）=====" -f $entry.Path, $entry.Label) -ForegroundColor Cyan
        if (-not (Test-Path -LiteralPath $entry.Path)) {
            Write-WarnLine ("（未找到）{0}" -f $entry.Hint)
            continue
        }
        $lines = @(Get-LogTail -Path $entry.Path -Count 40)
        if ($lines.Count -eq 0) {
            Write-Host '（空）'
            continue
        }
        foreach ($line in $lines) { Write-Host $line }
    }
    Write-Host ''
}

function Invoke-Snapshot {
    param([string]$TargetPath)
    $exePath = Join-Path $script:InstallDir 'RunBubbleOverlay.exe'
    if (-not (Test-Path -LiteralPath $exePath)) {
        $exePath = Join-Path $script:RepoRoot 'dist\RunBubbleOverlay.exe'
    }
    if (-not (Test-Path -LiteralPath $exePath)) {
        Write-Fail '找不到 RunBubbleOverlay.exe。' @(
            '先运行 build.ps1 生成 dist\RunBubbleOverlay.exe，或运行 run-bubble.ps1 install。',
            '确认 overlay 源码（src\overlay）已完成构建。'
        )
    }

    if ([string]::IsNullOrWhiteSpace($TargetPath)) {
        $TargetPath = Join-Path ([System.IO.Path]::GetTempPath()) 'dsh-run-bubble.png'
    }
    if (-not [System.IO.Path]::IsPathRooted($TargetPath)) {
        $TargetPath = Join-Path (Get-Location).Path $TargetPath
    }
    $TargetPath = [System.IO.Path]::GetFullPath($TargetPath)
    $targetDirectory = Split-Path -Parent $TargetPath
    if (-not [string]::IsNullOrWhiteSpace($targetDirectory) -and -not (Test-Path -LiteralPath $targetDirectory)) {
        New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
    }

    # overlay 通过 RUN_BUBBLE_STATUS_DIR 定位 status.json（与 macOS 版一致）。
    $env:RUN_BUBBLE_STATUS_DIR = $script:StatusDir

    Write-Host ("生成快照: {0}" -f $TargetPath)
    $exitCode = 1
    try {
        # 数组 + 预引号：路径含空格/中文时不会被 Start-Process 的字符串拼接拆开。
        $snapshotArguments = @('--snapshot', ('"{0}"' -f $TargetPath))
        $process = Start-Process -FilePath $exePath -ArgumentList $snapshotArguments -Wait -PassThru -ErrorAction Stop
        $exitCode = $process.ExitCode
    }
    catch {
        Write-Fail ("启动 overlay 失败：{0}" -f $_.Exception.Message) @(
            '确认 dist 目录中的 dll / runtimeconfig.json 与 exe 一起复制到了安装目录。',
            '手动运行 exe --snapshot <path> 查看具体错误。'
        )
    }

    if ($exitCode -ne 0) {
        Write-Fail ("overlay --snapshot 退出码 {0}。" -f $exitCode) @(
            '检查 overlay 版本是否支持 --snapshot。',
            ("查看日志: {0}" -f (Join-Path $script:LogDir 'overlay.err.log'))
        )
    }
    if (-not (Test-Path -LiteralPath $TargetPath)) {
        Write-Fail 'overlay 已退出但未生成快照文件。' @(
            '确认安装目录里的 RunBubbleOverlay.exe 是完整构建产物。',
            '手动运行: & "<安装目录>\RunBubbleOverlay.exe" --snapshot "<path>"'
        )
    }

    $size = (Get-Item -LiteralPath $TargetPath).Length
    $sizeText = Get-PngSizeText -Path $TargetPath
    Write-Host ("  路径: {0}" -f $TargetPath)
    Write-Host ("  大小: {0} 字节" -f $size)
    if ($null -ne $sizeText) { Write-Host ("  尺寸: {0}" -f $sizeText) }
    else { Write-WarnLine '  （无法解析 PNG 尺寸）' }
}

# ===========================================================================
# 租约探针健康检查 / doctor
# ===========================================================================

function Test-LeaseProbeHealth {
    param([string]$ProbePath)
    if ([string]::IsNullOrWhiteSpace($ProbePath) -or -not (Test-Path -LiteralPath $ProbePath)) {
        return @{ Ok = $false; ExitCode = -1; Detail = ('未找到 ' + [string]$ProbePath); Text = ''; LeaseCount = 0; Parsed = $false }
    }
    $result = Invoke-Native -FilePath $ProbePath -Arguments @()
    $ok = $false
    $leaseCount = 0
    $parsed = $false
    if ($result.ExitCode -eq 0) {
        $jsonText = ''
        foreach ($line in ($result.Text -split "`n")) {
            $candidate = $line.Trim()
            if ($candidate.StartsWith('{')) { $jsonText = $candidate }
        }
        if (-not [string]::IsNullOrWhiteSpace($jsonText)) {
            try {
                $document = $jsonText | ConvertFrom-Json -ErrorAction Stop
                $okValue = Get-JsonProperty -Object $document -Name 'ok'
                if ($null -ne $okValue -and [bool]$okValue) { $ok = $true }
                $leasesValue = Get-JsonProperty -Object $document -Name 'leases'
                if ($null -ne $leasesValue) { $leaseCount = @($leasesValue).Count }
                $parsed = $true
            }
            catch { }
        }
        if (-not $parsed) {
            if ($result.Text -like '*"ok":true*' -or $result.Text -like '*"ok": true*') { $ok = $true }
        }
    }
    return @{
        Ok         = $ok
        ExitCode   = $result.ExitCode
        Detail     = (Get-ShortText -Text $result.Text -MaxLength 240)
        Text       = $result.Text
        LeaseCount = $leaseCount
        Parsed     = $parsed
    }
}

function Show-LeaseProbeHealth {
    param([string]$ProbePath)
    $health = Test-LeaseProbeHealth -ProbePath $ProbePath
    if ($health.Ok) {
        Write-Host '  租约探针 : 可用（ok:true，daemon 使用 win-lease 精确判定）' -ForegroundColor Green
    }
    else {
        Write-WarnLine '  租约探针 : 不可用 — 将降级为 mtime/sidecar 启发式（气泡可能误判活跃性与归属）。'
        if (-not [string]::IsNullOrWhiteSpace($health.Detail)) {
            Write-WarnLine ('    输出: ' + $health.Detail)
        }
        Write-WarnLine '    这不阻断安装；修复后重跑 install，或直接检查 <安装目录>\DshLeaseProbe.exe。'
    }
    return $health
}

function Add-DoctorCheck {
    param(
        [bool]$Ok,
        [string]$Label,
        [string]$Detail = ''
    )
    if ($Ok) {
        $line = ('  ✅ {0}' -f $Label)
        if (-not [string]::IsNullOrWhiteSpace($Detail)) { $line = $line + ('  — ' + $Detail) }
        Write-Host $line
    }
    else {
        $script:DoctorFailures++
        $line = ('  ❌ {0}' -f $Label)
        if (-not [string]::IsNullOrWhiteSpace($Detail)) { $line = $line + ('  — ' + $Detail) }
        Write-Host $line -ForegroundColor Red
    }
}

function Invoke-Doctor {
    $script:DoctorFailures = 0
    Write-Host ''
    Write-Host 'dsh-run-bubble 自检 (doctor)' -ForegroundColor Cyan
    Write-Host ''

    # ---- 1. Node.js ----
    $nodeExe = Resolve-NodeExe
    if ($null -eq $nodeExe) {
        Add-DoctorCheck -Ok $false -Label 'Node.js' -Detail '未找到 node.exe（需要 Node.js 20+）'
    }
    else {
        $nodeVersion = Get-NodeVersionText
        $nodeMajorOk = $false
        if ($nodeVersion -match '^v(\d+)') {
            if ([int]$matches[1] -ge 20) { $nodeMajorOk = $true }
        }
        Add-DoctorCheck -Ok $nodeMajorOk -Label 'Node.js' -Detail ("{0}（{1}）" -f $nodeExe, $nodeVersion)
    }

    # ---- 2. .NET 运行时 ----
    $installDirExists = Test-Path -LiteralPath $script:InstallDir
    $installed = $installDirExists -and (Test-Path -LiteralPath (Join-Path $script:InstallDir 'daemon.mjs'))
    $selfContained = $false
    if ($installed -and (Test-Path -LiteralPath (Join-Path $script:InstallDir 'hostfxr.dll'))) {
        $selfContained = $true
    }
    $dotnetExe = Resolve-DotnetExe
    if ($null -eq $dotnetExe) {
        if ($installed -and -not $selfContained) {
            Add-DoctorCheck -Ok $false -Label '.NET 运行时' -Detail '未找到 dotnet；框架依赖发布需要 .NET 8 Desktop Runtime'
        }
        else {
            Add-DoctorCheck -Ok $true -Label '.NET 运行时' -Detail '未找到 dotnet（自包含发布或尚未安装，不影响运行）'
        }
    }
    else {
        $runtimesText = ''
        $dotnetVersionText = ''
        $runtimeResult = Invoke-Native -FilePath $dotnetExe -Arguments @('--list-runtimes')
        if ($runtimeResult.ExitCode -eq 0) { $runtimesText = $runtimeResult.Text }
        $versionResult = Invoke-Native -FilePath $dotnetExe -Arguments @('--version')
        if ($versionResult.ExitCode -eq 0) { $dotnetVersionText = $versionResult.Text }
        $hasDesktopRuntime = $runtimesText -like '*Microsoft.WindowsDesktop.App 8.*'
        if ($hasDesktopRuntime -or $selfContained) {
            Add-DoctorCheck -Ok $true -Label '.NET 运行时' -Detail ("Desktop 8.x 可用（dotnet {0}）" -f $dotnetVersionText)
        }
        elseif (-not $installed) {
            Add-DoctorCheck -Ok $true -Label '.NET 运行时' -Detail ("dotnet {0}（安装后再校验 Desktop 运行时）" -f $dotnetVersionText)
        }
        else {
            Add-DoctorCheck -Ok $false -Label '.NET 运行时' -Detail '未检测到 Microsoft.WindowsDesktop.App 8.x；框架依赖模式无法启动 overlay'
        }
    }

    # ---- 3. 安装目录与产物 ----
    $installDetail = $script:InstallDir
    if (-not $installed) { $installDetail = '未安装或安装不完整（运行 run-bubble.ps1 install）' }
    Add-DoctorCheck -Ok $installed -Label '安装' -Detail $installDetail
    if ($installed) {
        $artifacts = @(
            @{ Label = 'daemon.mjs'; Path = (Join-Path $script:InstallDir 'daemon.mjs') },
            @{ Label = 'RunBubbleOverlay.exe'; Path = (Join-Path $script:InstallDir 'RunBubbleOverlay.exe') },
            @{ Label = 'DshLeaseProbe.exe'; Path = (Join-Path $script:InstallDir 'DshLeaseProbe.exe') },
            @{ Label = 'scripts\Start-Daemon.ps1'; Path = (Join-Path $script:InstallDir 'scripts\Start-Daemon.ps1') },
            @{ Label = 'src\win'; Path = (Join-Path $script:InstallDir 'src\win') }
        )
        foreach ($artifact in $artifacts) {
            $artifactExists = Test-Path -LiteralPath $artifact.Path
            Add-DoctorCheck -Ok $artifactExists -Label ('安装文件 ' + $artifact.Label) -Detail $artifact.Path
        }

        $integrityTargets = @(
            @{ Label = 'RunBubbleOverlay.exe'; Path = (Join-Path $script:InstallDir 'RunBubbleOverlay.exe') },
            @{ Label = 'DshLeaseProbe.exe'; Path = (Join-Path $script:InstallDir 'DshLeaseProbe.exe') },
            @{ Label = 'daemon.mjs'; Path = (Join-Path $script:InstallDir 'daemon.mjs') }
        )
        foreach ($target in $integrityTargets) {
            $rawLabel = Get-FileIntegrityLabel -Path $target.Path
            $effectiveLabel = Get-EffectiveIntegrityLabel -Label $rawLabel
            if ($effectiveLabel -eq 'Low') {
                Add-DoctorCheck -Ok $false -Label ('完整性 ' + $target.Label) -Detail 'Low —— 该目录下的进程会以 Low 运行；请以管理员身份在该目录执行: icacls * /setintegritylevel Medium'
            }
            elseif ($rawLabel -eq '缺失') {
                Add-DoctorCheck -Ok $false -Label ('完整性 ' + $target.Label) -Detail '文件缺失（重新 install -Rebuild）'
            }
            elseif ($rawLabel -eq '未知') {
                Add-DoctorCheck -Ok $false -Label ('完整性 ' + $target.Label) -Detail '无法读取完整性标签（icacls 不可用或权限不足）'
            }
            else {
                Add-DoctorCheck -Ok $true -Label ('完整性 ' + $target.Label) -Detail $effectiveLabel
            }
        }
    }

    # ---- 4. overlay 可运行（--demo --snapshot 到临时文件） ----
    $overlayExe = Join-Path $script:InstallDir 'RunBubbleOverlay.exe'
    if ($installed -and (Test-Path -LiteralPath $overlayExe)) {
        $doctorSnapshot = Join-Path ([System.IO.Path]::GetTempPath()) ('dsh-run-bubble-doctor-' + [guid]::NewGuid().ToString('N') + '.png')
        $doctorStderr = $doctorSnapshot + '.err.txt'
        $overlayOk = $false
        $overlayDetail = ''
        try {
            $doctorOverlayArguments = @('--demo', '--snapshot', ('"{0}"' -f $doctorSnapshot))
            $overlayProcess = Start-Process -FilePath $overlayExe -ArgumentList $doctorOverlayArguments -Wait -PassThru -RedirectStandardError $doctorStderr -ErrorAction Stop
            if ($overlayProcess.ExitCode -eq 0 -and (Test-Path -LiteralPath $doctorSnapshot)) {
                $overlayOk = $true
            }
            else {
                $overlayDetail = ('退出码 {0}' -f $overlayProcess.ExitCode)
            }
        }
        catch {
            $overlayDetail = $_.Exception.Message
        }
        if (-not $overlayOk -and (Test-Path -LiteralPath $doctorStderr)) {
            $errLines = @(Get-Content -LiteralPath $doctorStderr -Tail 3 -ErrorAction SilentlyContinue)
            if ($errLines.Count -gt 0) {
                $overlayDetail = (($overlayDetail + ' ' + ($errLines -join ' ')).Trim())
                $overlayDetail = Get-ShortText -Text $overlayDetail -MaxLength 200
            }
        }
        Add-DoctorCheck -Ok $overlayOk -Label 'RunBubbleOverlay.exe 可运行' -Detail $overlayDetail
        Remove-Item -LiteralPath $doctorSnapshot -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $doctorStderr -Force -ErrorAction SilentlyContinue
    }
    elseif ($installed) {
        Add-DoctorCheck -Ok $false -Label 'RunBubbleOverlay.exe 可运行' -Detail '产物缺失（重新 install -Rebuild）'
    }

    # ---- 5. 租约探针 ----
    $probeExe = Join-Path $script:InstallDir 'DshLeaseProbe.exe'
    $probeHealth = $null
    if ($installed -and (Test-Path -LiteralPath $probeExe)) {
        $probeHealth = Test-LeaseProbeHealth -ProbePath $probeExe
        if ($probeHealth.Ok -and $probeHealth.LeaseCount -gt 0) {
            Add-DoctorCheck -Ok $true -Label 'DshLeaseProbe.exe（租约探针）' -Detail ("ok:true，leases={0}" -f $probeHealth.LeaseCount)
        }
        elseif ($probeHealth.Ok) {
            Add-DoctorCheck -Ok $false -Label 'DshLeaseProbe.exe（租约探针）' -Detail 'ok:true 但 leases=0（没有活跃租约或探针失效）；daemon 可能降级 win-mtime'
        }
        else {
            Add-DoctorCheck -Ok $false -Label 'DshLeaseProbe.exe（租约探针）' -Detail ("不可用：{0}；daemon 将降级 win-mtime（气泡可能误判活跃性与归属）" -f $probeHealth.Detail)
        }
    }
    elseif ($installed) {
        Add-DoctorCheck -Ok $false -Label 'DshLeaseProbe.exe（租约探针）' -Detail '产物缺失（重新 install -Rebuild）'
    }

    # ---- 5b. daemon 判定模式（区分探针/任务接线问题） ----
    $daemonStateForMode = Get-DaemonStateInfo
    if ($daemonStateForMode.Exists) {
        $modeForCheck = $daemonStateForMode.Mode
        if ([string]::IsNullOrWhiteSpace($modeForCheck)) { $modeForCheck = 'unknown' }
        if ($daemonStateForMode.LeaseProbe -eq 'ok') {
            Add-DoctorCheck -Ok $true -Label 'daemon 判定模式' -Detail ("mode={0}，leaseProbe=ok" -f $modeForCheck)
        }
        else {
            $leaseHint = '探针不可用（DLL 缺失 / 完整性 Low / OS 权限限制）→ daemon 降级 win-mtime'
            if ($null -ne $probeHealth -and $probeHealth.Ok) {
                $leaseHint = '探针本身可运行，但 daemon 未启用 lease → 检查计划任务工作目录与 daemon 启动日志（任务可能未重启）'
            }
            $leaseProbeText = $daemonStateForMode.LeaseProbe
            if ([string]::IsNullOrWhiteSpace($leaseProbeText)) { $leaseProbeText = 'unknown' }
            Add-DoctorCheck -Ok $false -Label 'daemon 判定模式' -Detail ("mode={0}，leaseProbe={1}；{2}" -f $modeForCheck, $leaseProbeText, $leaseHint)
        }
    }
    else {
        Write-Host '  ℹ daemon.json 不存在：daemon 未运行过，无法判断 lease 模式。'
    }

    # ---- 6. 计划任务 ----
    foreach ($taskName in @($script:TaskDaemon, $script:TaskOverlay)) {
        $task = Get-TaskState -TaskName $taskName
        if ($null -eq $task) {
            Add-DoctorCheck -Ok $false -Label ('计划任务 ' + $taskName) -Detail '未注册（运行 run-bubble.ps1 install）'
        }
        else {
            if ([string]$task.State -eq 'Running') {
                Add-DoctorCheck -Ok $true -Label ('计划任务 ' + $taskName) -Detail 'Running'
            }
            else {
                Add-DoctorCheck -Ok $false -Label ('计划任务 ' + $taskName) -Detail ('状态=' + [string]$task.State + '（运行 run-bubble.ps1 start）')
            }
            if ($installed) {
                $actionExecute = ''
                $actionArguments = ''
                if ($null -ne $task.Actions -and @($task.Actions).Count -gt 0) {
                    $actionExecute = [string]$task.Actions[0].Execute
                    $actionArguments = [string]$task.Actions[0].Arguments
                }
                $actionTarget = ($actionExecute + ' ' + $actionArguments).Trim()
                $actionOk = $actionTarget -like ('*' + $script:InstallDir + '*')
                $actionDetail = $actionTarget
                if (-not $actionOk) { $actionDetail = '未指向安装目录: ' + $actionTarget }
                Add-DoctorCheck -Ok $actionOk -Label ('任务 Action ' + $taskName) -Detail $actionDetail
            }
        }
    }

    # ---- 7. 进程 ----
    $processInfo = Get-InstallProcesses
    $daemonIds = @($processInfo.Daemon)
    $daemonState = Get-DaemonStateInfo
    if ($null -ne $daemonState.Pid -and (Test-ProcessAlive -ProcessId ([int]$daemonState.Pid))) {
        $alreadyListed = $false
        foreach ($existingId in $daemonIds) {
            if ([int]$existingId -eq [int]$daemonState.Pid) { $alreadyListed = $true; break }
        }
        if (-not $alreadyListed) {
            $stateCommandLine = Get-ProcessCommandLine -ProcessId ([int]$daemonState.Pid)
            if ($stateCommandLine -like '*daemon.mjs*') { $daemonIds += [int]$daemonState.Pid }
        }
    }
    $daemonIds = @($daemonIds | Sort-Object -Unique)
    $daemonDetail = '未运行'
    if ($daemonIds.Count -gt 0) { $daemonDetail = 'PID ' + ($daemonIds -join ', ') }
    Add-DoctorCheck -Ok ($daemonIds.Count -gt 0) -Label 'daemon 进程' -Detail $daemonDetail

    $overlayIds = @($processInfo.Overlay | Sort-Object -Unique)
    $overlayDetailText = '未运行'
    if ($overlayIds.Count -gt 0) { $overlayDetailText = 'PID ' + ($overlayIds -join ', ') }
    Add-DoctorCheck -Ok ($overlayIds.Count -gt 0) -Label 'overlay 进程' -Detail $overlayDetailText
    if (-not $processInfo.Available) {
        Write-WarnLine '  ℹ 进程表不可用：进程检查可能不完整'
    }

    # ---- 8. status.json 新鲜度 ----
    if (Test-Path -LiteralPath $script:StatusFile) {
        $statusItem = Get-Item -LiteralPath $script:StatusFile
        $statusAge = [int][math]::Round(((Get-Date).ToUniversalTime() - $statusItem.LastWriteTimeUtc).TotalSeconds)
        if ($statusAge -lt 0) { $statusAge = 0 }
        Add-DoctorCheck -Ok ($statusAge -le 6) -Label 'status.json 新鲜度' -Detail ("{0} 秒前更新（>6s 视为过期）" -f $statusAge)
    }
    else {
        Add-DoctorCheck -Ok $false -Label 'status.json 新鲜度' -Detail ('尚未生成: ' + $script:StatusFile)
    }

    # ---- 9. 判定模式 / 日志路径（信息项） ----
    if ($daemonState.Exists) {
        $modeText = $daemonState.Mode
        if ([string]::IsNullOrWhiteSpace($modeText)) { $modeText = 'unknown' }
        $leaseText = $daemonState.LeaseProbe
        if ([string]::IsNullOrWhiteSpace($leaseText)) { $leaseText = 'unknown' }
        $sourceText = $daemonState.SourceProbe
        if ([string]::IsNullOrWhiteSpace($sourceText)) { $sourceText = 'none' }
        Write-Host ("  ℹ 模式      : {0}    leaseProbe: {1}    sourceProbe: {2}" -f $modeText, $leaseText, $sourceText)
    }
    else {
        Write-Host '  ℹ 模式      : 未知（没有 daemon.json，daemon 未运行过）'
    }
    Write-Host ("  ℹ 日志      : {0}" -f $script:LogDir)

    Write-Host ''
    if ($script:DoctorFailures -eq 0) {
        Write-Host '自检通过：所有检查项正常。' -ForegroundColor Green
        return 0
    }
    Write-Host ("自检发现 {0} 个 ❌ 问题；按上面的提示逐项处理（install / start / logs）。" -f $script:DoctorFailures) -ForegroundColor Yellow
    return 1
}

# ===========================================================================
# 生命周期命令
# ===========================================================================

function Invoke-RepoBuild {
    param([bool]$SelfContained)
    $buildScript = Join-Path $script:RepoRoot 'build.ps1'
    if (-not (Test-Path -LiteralPath $buildScript)) {
        Write-Fail ("找不到 build.ps1: {0}" -f $buildScript) @(
            '请从仓库根目录运行 run-bubble.ps1 install。'
        )
    }
    $psExe = Resolve-PowerShellExe
    $buildArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $buildScript)
    if ($SelfContained) { $buildArguments += '-SelfContained' }
    Write-Host ("  构建命令: {0} {1}" -f $psExe, ($buildArguments -join ' '))
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # 输出走 host 通道（不进成功输出流），否则函数会把 build.ps1 的输出行
        # 和退出码一起返回，调用方拿到的就不是数字。
        & $psExe @buildArguments | Out-Host
        $buildExitCode = [int]$LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    return [int]$buildExitCode
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Copy-DirectoryTree {
    param([string]$Source, [string]$Destination)
    if (-not (Test-Path -LiteralPath $Source)) { return }
    Ensure-Directory -Path $Destination
    foreach ($item in @(Get-ChildItem -LiteralPath $Source -Force)) {
        $target = Join-Path $Destination $item.Name
        if ($item.PSIsContainer) {
            Copy-DirectoryTree -Source $item.FullName -Destination $target
        }
        else {
            Copy-Item -LiteralPath $item.FullName -Destination $target -Force
        }
    }
}

function Get-UnknownFlagList {
    param([hashtable]$Flags, [string[]]$Allowed)
    $unknown = @()
    foreach ($key in $Flags.Keys) {
        $isAllowed = $false
        foreach ($allowedKey in $Allowed) {
            if ($key -eq $allowedKey) { $isAllowed = $true; break }
        }
        if (-not $isAllowed) { $unknown += ('-' + $key) }
    }
    return $unknown
}

function Show-InstallDiagnostics {
    Write-Host ''
    Write-Host '诊断信息:' -ForegroundColor Yellow

    $nodeExe = Resolve-NodeExe
    if ($null -ne $nodeExe) {
        Write-Host ("  node     : {0}（{1}）" -f $nodeExe, (Get-NodeVersionText))
    }
    else {
        Write-Host '  node     : 未找到（运行期需要 Node.js 20+，内置 zstd 解压）' -ForegroundColor Red
    }

    $dotnetExe = Resolve-DotnetExe
    if ($null -ne $dotnetExe) {
        $dotnetVersion = ''
        try { $dotnetVersion = (& $dotnetExe --version 2>$null | Out-String).Trim() } catch { }
        Write-Host ("  dotnet   : {0}（{1}，构建期需要 .NET 8 SDK）" -f $dotnetExe, $dotnetVersion)
    }
    else {
        Write-Host '  dotnet   : 未找到（构建期需要 .NET 8 SDK）' -ForegroundColor Yellow
    }

    $installedProbeForDiagnostics = Join-Path $script:InstallDir 'DshLeaseProbe.exe'
    if (Test-Path -LiteralPath $installedProbeForDiagnostics) {
        $diagnosticHealth = Test-LeaseProbeHealth -ProbePath $installedProbeForDiagnostics
        if ($diagnosticHealth.Ok) {
            Write-Host '  租约探针 : 可用（ok:true）'
        }
        else {
            Write-WarnLine ("  租约探针 : 不可用 — {0}" -f $diagnosticHealth.Detail)
        }
    }
    else {
        Write-Host ("  租约探针 : 未找到 {0}" -f $installedProbeForDiagnostics)
    }

    foreach ($taskName in @($script:TaskDaemon, $script:TaskOverlay)) {
        $task = Get-TaskState -TaskName $taskName
        if ($null -eq $task) {
            Write-Host ("  任务 {0}: 未注册" -f $taskName)
            continue
        }
        $lastRun = ''
        $lastResult = ''
        try {
            $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction Stop
            $lastRun = [string]$taskInfo.LastRunTime
            $lastResult = [string]$taskInfo.LastTaskResult
        }
        catch { }
        Write-Host ("  任务 {0}: 状态={1} 上次运行={2} 上次结果={3}" -f $taskName, [string]$task.State, $lastRun, $lastResult)
    }

    if (Test-Path -LiteralPath $script:StatusFile) {
        $item = Get-Item -LiteralPath $script:StatusFile
        $age = [int][math]::Round(((Get-Date).ToUniversalTime() - $item.LastWriteTimeUtc).TotalSeconds)
        if ($age -lt 0) { $age = 0 }
        Write-Host ("  status.json: {0}（{1} 秒前写入）" -f $script:StatusFile, $age)
    }
    else {
        Write-Host ("  status.json: 尚未生成（{0}）" -f $script:StatusFile)
    }

    foreach ($logName in @('daemon.err.log', 'daemon.out.log')) {
        $logPath = Join-Path $script:LogDir $logName
        Write-Host ("  --- {0}（最后 20 行）---" -f $logPath)
        $lines = @(Get-LogTail -Path $logPath -Count 20)
        if ($lines.Count -eq 0) {
            Write-Host '  （空 / 不存在）'
        }
        else {
            foreach ($line in $lines) { Write-Host ("  | {0}" -f $line) }
        }
    }
}

function Invoke-Install {
    param([bool]$Rebuild, [bool]$SelfContained)

    $repoFull = $script:RepoRoot.TrimEnd('\')
    $installFull = $script:InstallDir.TrimEnd('\')
    if ($repoFull -ieq $installFull) {
        Write-Fail '当前脚本就在安装目录里，不能从安装目录执行 install。' @(
            ('请从仓库目录运行: {0}\run-bubble.ps1 install' -f $script:RepoRoot),
            '安装目录只保留运行时文件。'
        )
    }

    Write-Host '安装 dsh-run-bubble（Windows）...' -ForegroundColor Cyan

    # ---- 1. 运行期依赖 ----
    $nodeExe = Resolve-NodeExe
    if ($null -eq $nodeExe) {
        Write-Fail '找不到 node.exe。' @(
            '安装 Node.js 20+（需要内置 zstd 解压能力）: https://nodejs.org/',
            '安装后重开终端，运行 node --version 验证。'
        )
    }
    $nodeVersion = Get-NodeVersionText
    Write-Host ("  node: {0}（{1}）" -f $nodeExe, $nodeVersion)
    if ($nodeVersion -match '^v(\d+)') {
        $nodeMajor = [int]$matches[1]
        if ($nodeMajor -lt 20) {
            Write-WarnLine ("  警告: Node 版本偏低（{0}），建议 20+（daemon 需要内置 zstd）。" -f $nodeVersion)
        }
    }

    # ---- 2. 源码就绪检查（并行开发中避免安装半成品） ----
    $daemonSource = Join-Path $script:RepoRoot 'daemon.mjs'
    if (-not (Test-Path -LiteralPath $daemonSource)) {
        Write-Fail ("找不到 daemon.mjs: {0}" -f $daemonSource) @(
            '请从仓库根目录运行 install。'
        )
    }
    $winSource = Join-Path $script:RepoRoot 'src\win'
    if (-not (Test-Path -LiteralPath $winSource)) {
        Write-Fail 'daemon 的 Windows 模块尚未就绪（src\win 不存在）。' @(
            '这是并行开发中的正常状态：等 daemon 移植完成后再 install。',
            '已中止安装，未注册任何计划任务、未改动现有安装。'
        )
    }
    $winModuleCount = @(Get-ChildItem -LiteralPath $winSource -Filter '*.mjs' -File -Recurse -ErrorAction SilentlyContinue).Count
    if ($winModuleCount -eq 0) {
        Write-Fail 'src\win 目录里没有 .mjs 模块，daemon 可能无法启动。' @(
            '等 daemon 移植（process-table / zstd / liveness 模块）就绪后重试。',
            '已中止安装，未注册任何计划任务。'
        )
    }

    # ---- 3. 构建产物（overlay + 租约探针；都在且未 -Rebuild 时跳过） ----
    $distExe = Join-Path $script:RepoRoot 'dist\RunBubbleOverlay.exe'
    $distProbe = Join-Path $script:RepoRoot 'dist\DshLeaseProbe.exe'
    $distDir = Join-Path $script:RepoRoot 'dist'
    $needBuild = $Rebuild -or (-not (Test-Path -LiteralPath $distExe)) -or (-not (Test-Path -LiteralPath $distProbe))
    if ($needBuild) {
        if ($Rebuild) {
            Write-Host '  -Rebuild: 强制重新构建 overlay + 租约探针...'
        }
        else {
            Write-Host '  dist 产物不完整，先构建 overlay + 租约探针...'
        }
        $buildExitCode = Invoke-RepoBuild -SelfContained $SelfContained
        if ($buildExitCode -ne 0) {
            Write-Fail ("构建失败（build.ps1 退出码 {0}），已中止安装，未注册任何计划任务。" -f $buildExitCode) @(
                '根据上面的构建错误修复 overlay 源码。',
                '修复后重试: run-bubble.ps1 install -Rebuild',
                '只验证脚本可用: build.ps1 单独运行即可。'
            )
        }
    }
    else {
        Write-Host '  构建产物已存在，跳过构建（需要重建请加 -Rebuild）'
    }
    if (-not (Test-Path -LiteralPath $distExe)) {
        Write-Fail ("构建后仍找不到产物: {0}" -f $distExe) @(
            '检查 overlay 工程的 OutputType / AssemblyName。',
            '重试: run-bubble.ps1 install -Rebuild'
        )
    }
    if (-not (Test-Path -LiteralPath $distProbe)) {
        Write-Fail ("构建后仍找不到租约探针产物: {0}" -f $distProbe) @(
            'build.ps1 应同时构建 src\lease-probe\LeaseProbe.csproj。',
            '检查 lease-probe 工程后重试: run-bubble.ps1 install -Rebuild'
        )
    }

    # ---- 4. 停旧任务 + 清理残留进程（幂等） ----
    $hadInstall = (Test-Path -LiteralPath $script:InstallDir) -or (Test-TaskExists -TaskName $script:TaskDaemon) -or (Test-TaskExists -TaskName $script:TaskOverlay)
    if ($hadInstall) {
        Write-Host '  停止旧的计划任务 / 进程（幂等）...'
        Invoke-Stop
    }
    else {
        Write-Host '  首次安装：没有旧任务需要停止'
    }
    Remove-TaskSafely -TaskName $script:TaskDaemon
    Remove-TaskSafely -TaskName $script:TaskOverlay

    # ---- 5. 复制运行时文件 ----
    Write-Host ("  复制安装文件到 {0}" -f $script:InstallDir)
    try {
        Ensure-Directory -Path $script:InstallDir
        Ensure-Directory -Path $script:LogDir
        # dist 可能包含 exe 之外的 dll / runtimeconfig.json（框架依赖发布），整树复制。
        Copy-DirectoryTree -Source $distDir -Destination $script:InstallDir
        Copy-Item -LiteralPath $daemonSource -Destination (Join-Path $script:InstallDir 'daemon.mjs') -Force
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'run-bubble.ps1') -Destination (Join-Path $script:InstallDir 'run-bubble.ps1') -Force
        Copy-DirectoryTree -Source $winSource -Destination (Join-Path $script:InstallDir 'src\win')
        $scriptsSource = Join-Path $script:RepoRoot 'scripts'
        if (Test-Path -LiteralPath $scriptsSource) {
            Copy-DirectoryTree -Source $scriptsSource -Destination (Join-Path $script:InstallDir 'scripts')
        }
    }
    catch {
        Write-Fail ("复制安装文件失败：{0}" -f $_.Exception.Message) @(
            '可能有旧的 daemon / overlay 进程占用文件：先运行 run-bubble.ps1 stop，再重试 install。'
        )
    }
    $installedProbe = Join-Path $script:InstallDir 'DshLeaseProbe.exe'
    if (-not (Test-Path -LiteralPath $installedProbe)) {
        Write-Fail ("安装目录缺少租约探针: {0}" -f $installedProbe) @(
            'dist 目录应包含 DshLeaseProbe.exe；先运行 build.ps1 后重试 install。'
        )
    }

    $installedOverlayExe = Join-Path $script:InstallDir 'RunBubbleOverlay.exe'

    # ---- 5b. 显式重设完整性标签为 Medium ----
    # DSH 工作区文件可能带 Low 标签（Low 镜像启动的进程无法枚举句柄、也无法写 Medium
    # 位置）。Copy-Item 通常会在目标目录继承 Medium，但 robocopy /COPYALL、Move-Item、
    # 手工拷贝等路径可能把 Low 带进来，所以这里无条件重标一次。
    foreach ($integrityName in @('RunBubbleOverlay.exe', 'DshLeaseProbe.exe', 'daemon.mjs')) {
        $integrityPath = Join-Path $script:InstallDir $integrityName
        if (-not (Test-Path -LiteralPath $integrityPath)) { continue }
        $integrityOk = Set-FileIntegrityMedium -Path $integrityPath
        $integrityLabel = Get-EffectiveIntegrityLabel -Label (Get-FileIntegrityLabel -Path $integrityPath)
        if ($integrityOk) {
            Write-Host ("  完整性: {0} → {1}" -f $integrityName, $integrityLabel)
        }
        else {
            Write-WarnLine ("  警告: 无法重设 {0} 的完整性标签（icacls 不可用/权限不足）；进程可能以 Low 运行。" -f $integrityName)
        }
    }

    # ---- 5c. 安装产物自检 ----
    # 框架依赖发布是多文件产物：exe 旁边的 dll / deps.json / runtimeconfig.json 缺一个
    # apphost 就起不来。这里直接跑 --demo --snapshot 验证 overlay 真能运行并写出 PNG。
    Write-Host '  自检安装产物（overlay --demo --snapshot）...'
    $selfCheckPng = Join-Path $script:InstallDir 'selfcheck.png'
    $selfCheckStderr = Join-Path $script:InstallDir 'selfcheck.err.txt'
    Remove-Item -LiteralPath $selfCheckPng, $selfCheckStderr -Force -ErrorAction SilentlyContinue
    $overlaySelfCheckOk = $false
    $overlaySelfCheckDetail = ''
    try {
        $selfCheckArguments = @('--demo', '--snapshot', ('"{0}"' -f $selfCheckPng))
        $selfCheckProcess = Start-Process -FilePath $installedOverlayExe -ArgumentList $selfCheckArguments -Wait -PassThru -RedirectStandardError $selfCheckStderr -ErrorAction Stop
        if ($selfCheckProcess.ExitCode -eq 0 -and (Test-Path -LiteralPath $selfCheckPng)) {
            $overlaySelfCheckOk = $true
        }
        else {
            $overlaySelfCheckDetail = ('退出码 {0}' -f $selfCheckProcess.ExitCode)
        }
    }
    catch {
        $overlaySelfCheckDetail = $_.Exception.Message
    }
    if (-not $overlaySelfCheckOk -and (Test-Path -LiteralPath $selfCheckStderr)) {
        $selfCheckLines = @(Get-Content -LiteralPath $selfCheckStderr -Tail 5 -ErrorAction SilentlyContinue)
        if ($selfCheckLines.Count -gt 0) {
            $overlaySelfCheckDetail = Get-ShortText -Text (($overlaySelfCheckDetail + ' ' + ($selfCheckLines -join ' ')).Trim()) -MaxLength 240
        }
    }
    Remove-Item -LiteralPath $selfCheckPng, $selfCheckStderr -Force -ErrorAction SilentlyContinue
    if (-not $overlaySelfCheckOk) {
        Write-Fail ("安装产物自检失败：RunBubbleOverlay.exe --demo --snapshot 未通过（{0}）。" -f $overlaySelfCheckDetail) @(
            'dist 发布目录必须包含与 exe 同名的 dll / deps.json / runtimeconfig.json；install 已整目录复制。',
            '重新运行 build.ps1 后再 install（不要手工只拷 exe）。',
            '已中止安装：未注册计划任务、未启动服务。'
        )
    }
    Write-Host '  overlay 自检: 通过（dll / runtimeconfig 齐全，能写出 PNG）'

    # ---- 6. 注册计划任务 ----
    $installTasksScript = Join-Path $script:RepoRoot 'scripts\Install-Tasks.ps1'
    if (-not (Test-Path -LiteralPath $installTasksScript)) {
        Write-Fail ("找不到计划任务注册脚本: {0}" -f $installTasksScript) @(
            '确认 scripts\Install-Tasks.ps1 存在（由 launcher 提供）。'
        )
    }
    Write-Host '  注册计划任务...'
    $psExe = Resolve-PowerShellExe
    $installTaskArguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $installTasksScript,
        '-InstallDir', $script:InstallDir,
        '-NodePath', $nodeExe,
        '-DaemonTaskName', $script:TaskDaemon,
        '-OverlayTaskName', $script:TaskOverlay
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $psExe @installTaskArguments | Out-Host
        $installTasksExitCode = [int]$LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    if ($installTasksExitCode -ne 0) {
        Write-Fail ("计划任务注册失败（Install-Tasks.ps1 退出码 {0}）。" -f $installTasksExitCode) @(
            '确认当前用户可以直接创建计划任务（无需管理员）。',
            '查看上面的详细错误；修复后重试 run-bubble.ps1 install。'
        )
    }

    # ---- 7. 启动并校验 status.json（5 秒内） ----
    $statusStart = (Get-Date).ToUniversalTime()
    Write-Host '  启动计划任务...'
    $startedCount = Start-BubbleServices
    if ($startedCount -eq 0) {
        Show-InstallDiagnostics
        Write-Fail '计划任务已注册，但没有任何一个启动成功。' @(
            '检查任务计划程序里的 DshRunBubble-* 任务状态。',
            '修复后重试: run-bubble.ps1 start'
        )
    }

    $fresh = $false
    $deadline = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $script:StatusFile) {
            try {
                $item = Get-Item -LiteralPath $script:StatusFile -ErrorAction Stop
                if ($item.LastWriteTimeUtc -ge $statusStart.AddSeconds(-1)) {
                    $fresh = $true
                    break
                }
            }
            catch { }
        }
        Start-Sleep -Milliseconds 250
    }

    Show-Status

    $probeHealth = Show-LeaseProbeHealth -ProbePath (Join-Path $script:InstallDir 'DshLeaseProbe.exe')

    $daemonStateAfterInstall = Get-DaemonStateInfo
    if ($daemonStateAfterInstall.Exists) {
        if ($daemonStateAfterInstall.LeaseProbe -eq 'ok') {
            Write-Host '  daemon 判定: win-lease（leaseProbe=ok）'
        }
        else {
            $modeAfterInstall = $daemonStateAfterInstall.Mode
            if ([string]::IsNullOrWhiteSpace($modeAfterInstall)) { $modeAfterInstall = 'unknown' }
            if ($null -ne $probeHealth -and $probeHealth.Ok) {
                Write-WarnLine ("  daemon 判定: {0}（leaseProbe={1}）— 探针本身可运行，但 daemon 未启用 lease；检查计划任务工作目录（{2}）与 daemon 日志。" -f $modeAfterInstall, $daemonStateAfterInstall.LeaseProbe, $script:InstallDir)
            }
            else {
                Write-WarnLine ("  daemon 判定: {0}（leaseProbe={1}）— 租约探针不可用（DLL 缺失 / 完整性 Low / OS 权限限制），已降级 mtime 启发式。" -f $modeAfterInstall, $daemonStateAfterInstall.LeaseProbe)
            }
        }
    }
    else {
        Write-WarnLine '  daemon.json 尚未生成（daemon 可能刚启动）：稍后运行 run-bubble.ps1 status 确认 leaseProbe=ok。'
    }

    if (-not $fresh) {
        Show-InstallDiagnostics
        Write-Fail '已注册计划任务，但 5 秒内没有检测到 status.json 更新。' @(
            ("Node 版本: {0}（需要 20+）" -f (Get-NodeVersionText)),
            ("检查日志: {0}" -f (Join-Path $script:LogDir 'daemon.err.log')),
            ("手动前台试跑: & ""{0}"" ""{1}""" -f $nodeExe, (Join-Path $script:InstallDir 'daemon.mjs')),
            '确认 .NET 8 SDK 可用于构建；框架依赖模式下目标机还需要 .NET 8 Desktop Runtime。',
            '修复后重试: run-bubble.ps1 install（或仅 run-bubble.ps1 start 重启服务）。'
        )
    }

    Write-Host ''
    Write-Host '安装完成。' -ForegroundColor Green
    Write-Host ("  安装目录: {0}" -f $script:InstallDir)
    Write-Host ("  日志    : {0}" -f $script:LogDir)
    Write-Host ("  计划任务: {0} / {1}" -f $script:TaskDaemon, $script:TaskOverlay)
    if ($null -ne $probeHealth -and $probeHealth.Ok) {
        Write-Host '  租约探针: 可用（daemon 使用 win-lease 精确判定）'
    }
    else {
        Write-Host '  租约探针: 不可用（daemon 降级为 mtime 启发式）' -ForegroundColor Yellow
    }
    Write-Host '  下一步  : run-bubble.ps1 status | doctor | logs | snapshot'
    Write-Host ''
}

function Invoke-Start {
    $installedDaemon = Join-Path $script:InstallDir 'daemon.mjs'
    if (-not (Test-Path -LiteralPath $installedDaemon)) {
        Write-Fail '尚未安装（安装目录里没有 daemon.mjs）。' @(
            '先运行: run-bubble.ps1 install'
        )
    }
    Write-Host '启动 dsh-run-bubble...'
    $startedCount = Start-BubbleServices
    if ($startedCount -eq 0) {
        Write-Fail '没有可启动的计划任务（可能未注册）。' @(
            '重新注册并启动: run-bubble.ps1 install'
        )
    }
    Start-Sleep -Milliseconds 1200
    Show-Status
}

function Invoke-Stop {
    Write-Host '停止 dsh-run-bubble...'
    # 契约要求：停之前先读 daemon.json 里的 pid。
    $statePid = Get-DaemonStatePid
    Stop-TaskSafely -TaskName $script:TaskDaemon
    Stop-TaskSafely -TaskName $script:TaskOverlay
    Start-Sleep -Milliseconds 700
    Stop-BubbleProcesses -StatePid $statePid
    Start-Sleep -Milliseconds 300
    Stop-BubbleProcesses -StatePid $statePid -Quiet
    Remove-StaleDaemonState
    Write-Host '已停止。'
}

function Invoke-Restart {
    $installedDaemon = Join-Path $script:InstallDir 'daemon.mjs'
    if (-not (Test-Path -LiteralPath $installedDaemon)) {
        Write-Fail '尚未安装（安装目录里没有 daemon.mjs）。' @(
            '先运行: run-bubble.ps1 install'
        )
    }
    Invoke-Stop
    Start-Sleep -Milliseconds 400
    Invoke-Start
}

function Invoke-Uninstall {
    if (Test-Path -LiteralPath $script:InstallDir) {
        Invoke-Stop
    }
    else {
        Write-Host '未安装（安装目录不存在），仍检查并注销计划任务...'
    }
    Remove-TaskSafely -TaskName $script:TaskDaemon
    Remove-TaskSafely -TaskName $script:TaskOverlay

    if (Test-Path -LiteralPath $script:InstallDir) {
        $fullInstallDir = [System.IO.Path]::GetFullPath($script:InstallDir)
        $parentDirectory = Split-Path -Parent $fullInstallDir
        if ([string]::IsNullOrWhiteSpace($parentDirectory) -or $fullInstallDir -ieq $parentDirectory) {
            Write-Fail ("拒绝删除异常的安装目录路径: {0}" -f $fullInstallDir)
        }
        Write-Host ("删除安装目录: {0}" -f $fullInstallDir)
        try {
            Remove-Item -LiteralPath $fullInstallDir -Recurse -Force -ErrorAction Stop
        }
        catch {
            Write-Fail ("删除安装目录失败：{0}" -f $_.Exception.Message) @(
                '可能有进程占用文件：先运行 run-bubble.ps1 stop 后重试。',
                '若当前工作目录就在安装目录内，请先 cd 到其他目录。'
            )
        }
    }

    Write-Host ''
    Write-Host '已卸载。以下会话状态已保留（未删除）:' -ForegroundColor Green
    foreach ($stateName in @('status.json', 'position.json')) {
        $statePath = Join-Path $script:StatusDir $stateName
        if (Test-Path -LiteralPath $statePath) {
            Write-Host ("  - {0}" -f $statePath)
        }
        else {
            Write-Host ("  - {0}（不存在）" -f $statePath)
        }
    }
    Write-Host '  说明: daemon.json 属于运行时 PID 状态，已在停止时清理；会话日志与 status.json / position.json 保留。'
    Write-Host ("  如需彻底清理，可手动删除: {0}" -f $script:StatusDir)
    Write-Host ''
}

# ===========================================================================
# 参数解析 + 分发（同时接受 -Flag 与 --flag）
# ===========================================================================

$rawArguments = @($args)
$commandName = 'help'
$positionalArguments = New-Object System.Collections.Generic.List[string]
$flagBag = @{}

foreach ($rawArgument in $rawArguments) {
    if ($null -eq $rawArgument) { continue }
    $token = [string]$rawArgument
    if ([string]::IsNullOrWhiteSpace($token)) { continue }
    if ($token -match '^--?(.+)$') {
        $flagName = ($matches[1] -replace '[-_]', '').ToLowerInvariant()
        $flagBag[$flagName] = $true
    }
    else {
        $positionalArguments.Add($token)
    }
}

if ($positionalArguments.Count -gt 0) {
    $commandName = $positionalArguments[0].ToLowerInvariant()
}
$commandArguments = @()
for ($argumentIndex = 1; $argumentIndex -lt $positionalArguments.Count; $argumentIndex++) {
    $commandArguments += $positionalArguments[$argumentIndex]
}

# 任一位置出现 help / -h / --help 都显示帮助。
if ($flagBag.ContainsKey('help') -or $flagBag.ContainsKey('h') -or $flagBag.ContainsKey('?')) {
    Show-Usage
    exit 0
}

if ($commandName -eq 'help' -or $commandName -eq '-help' -or $commandName -eq '--help') {
    Show-Usage
    exit 0
}

if ($commandName -eq 'install') {
    $unknownFlags = @(Get-UnknownFlagList -Flags $flagBag -Allowed @('rebuild', 'selfcontained'))
    if ($unknownFlags.Count -gt 0) {
        Write-Host ("run-bubble: install 不支持这些参数: {0}" -f ($unknownFlags -join ' ')) -ForegroundColor Red
        Show-Usage
        exit 2
    }
    if ($commandArguments.Count -gt 0) {
        Write-Host ("run-bubble: install 不接受位置参数: {0}" -f ($commandArguments -join ' ')) -ForegroundColor Red
        Show-Usage
        exit 2
    }
    $rebuildFlag = $flagBag.ContainsKey('rebuild')
    $selfContainedFlag = $flagBag.ContainsKey('selfcontained')
    Invoke-Install -Rebuild $rebuildFlag -SelfContained $selfContainedFlag
    exit 0
}

if ($commandName -eq 'start') {
    $unknownFlags = @(Get-UnknownFlagList -Flags $flagBag -Allowed @())
    if ($unknownFlags.Count -gt 0) {
        Write-Host ("run-bubble: start 不支持这些参数: {0}" -f ($unknownFlags -join ' ')) -ForegroundColor Red
        exit 2
    }
    Invoke-Start
    exit 0
}

if ($commandName -eq 'stop') {
    $unknownFlags = @(Get-UnknownFlagList -Flags $flagBag -Allowed @())
    if ($unknownFlags.Count -gt 0) {
        Write-Host ("run-bubble: stop 不支持这些参数: {0}" -f ($unknownFlags -join ' ')) -ForegroundColor Red
        exit 2
    }
    Invoke-Stop
    exit 0
}

if ($commandName -eq 'restart') {
    $unknownFlags = @(Get-UnknownFlagList -Flags $flagBag -Allowed @())
    if ($unknownFlags.Count -gt 0) {
        Write-Host ("run-bubble: restart 不支持这些参数: {0}" -f ($unknownFlags -join ' ')) -ForegroundColor Red
        exit 2
    }
    Invoke-Restart
    exit 0
}

if ($commandName -eq 'status') {
    $unknownFlags = @(Get-UnknownFlagList -Flags $flagBag -Allowed @())
    if ($unknownFlags.Count -gt 0) {
        Write-Host ("run-bubble: status 不支持这些参数: {0}" -f ($unknownFlags -join ' ')) -ForegroundColor Red
        exit 2
    }
    Show-Status
    exit 0
}

if ($commandName -eq 'logs') {
    $unknownFlags = @(Get-UnknownFlagList -Flags $flagBag -Allowed @())
    if ($unknownFlags.Count -gt 0) {
        Write-Host ("run-bubble: logs 不支持这些参数: {0}" -f ($unknownFlags -join ' ')) -ForegroundColor Red
        exit 2
    }
    Show-Logs
    exit 0
}

if ($commandName -eq 'snapshot') {
    $unknownFlags = @(Get-UnknownFlagList -Flags $flagBag -Allowed @())
    if ($unknownFlags.Count -gt 0) {
        Write-Host ("run-bubble: snapshot 不支持这些参数: {0}" -f ($unknownFlags -join ' ')) -ForegroundColor Red
        exit 2
    }
    if ($commandArguments.Count -gt 1) {
        Write-Host ("run-bubble: snapshot 只接受一个输出路径，收到: {0}" -f ($commandArguments -join ' ')) -ForegroundColor Red
        exit 2
    }
    $snapshotTarget = ''
    if ($commandArguments.Count -eq 1) { $snapshotTarget = [string]$commandArguments[0] }
    Invoke-Snapshot -TargetPath $snapshotTarget
    exit 0
}

if ($commandName -eq 'uninstall') {
    $unknownFlags = @(Get-UnknownFlagList -Flags $flagBag -Allowed @())
    if ($unknownFlags.Count -gt 0) {
        Write-Host ("run-bubble: uninstall 不支持这些参数: {0}" -f ($unknownFlags -join ' ')) -ForegroundColor Red
        exit 2
    }
    Invoke-Uninstall
    exit 0
}

if ($commandName -eq 'doctor') {
    $unknownFlags = @(Get-UnknownFlagList -Flags $flagBag -Allowed @())
    if ($unknownFlags.Count -gt 0) {
        Write-Host ("run-bubble: doctor 不支持这些参数: {0}" -f ($unknownFlags -join ' ')) -ForegroundColor Red
        exit 2
    }
    $doctorExitCode = Invoke-Doctor
    exit $doctorExitCode
}

Write-Host ("run-bubble: 未知命令: {0}" -f $commandName) -ForegroundColor Red
Show-Usage
exit 2
