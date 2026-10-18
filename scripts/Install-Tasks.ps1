#Requires -Version 5.1
<#
.SYNOPSIS
    注册 dsh-run-bubble 的两个 Windows 计划任务（幂等）。
.DESCRIPTION
    由 run-bubble.ps1 install 调用；也可以单独用于测试/修复：

        pwsh -NoProfile -File scripts\Install-Tasks.ps1 `
             -InstallDir "$env:LOCALAPPDATA\dsh-run-bubble" `
             -NodePath "C:\Program Files\nodejs\node.exe" `
             -DaemonTaskName "DshRunBubble-Test-xxxx" `
             -OverlayTaskName "DshRunBubble-Test-yyyy"

    任务契约（同时满足 launchd KeepAlive 语义）：
      * 登录触发器（-AtLogOn），当前用户；
      * 运行身份 = 当前用户、-RunLevel Limited（不要求管理员）；
      * MultipleInstances=IgnoreNew（单实例）；
      * 失败后 1 分钟重启（RestartCount 999 / RestartInterval 1m）；
      * ExecutionTimeLimit 0（不限制运行时长）、允许电池启动、切电池不停；
      * overlay 任务 -Hidden（任务计划程序里隐藏），daemon 窗口由 pwsh -WindowStyle Hidden 隐藏。

    注册优先使用 ScheduledTasks 模块 cmdlet；若当前环境拒绝 CIM 写入（例如 WMI 权限
    受限），自动回退到等价的 schtasks.exe + 任务 XML，最终设置完全一致。
#>
param(
    [Parameter(Mandatory = $true)][string]$InstallDir,
    [Parameter(Mandatory = $true)][string]$NodePath,
    [string]$DaemonTaskName = 'DshRunBubble-Daemon',
    [string]$OverlayTaskName = 'DshRunBubble-Overlay',
    [string]$UserId = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-EnvValue {
    param([string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ($null -eq $value) { return '' }
    return $value
}

function Write-WarnLine {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Yellow
}

function Invoke-Schtasks {
    param([string[]]$Arguments)
    # Windows PowerShell 5.1 会把原生 stderr 变成错误记录；配上
    # $ErrorActionPreference='Stop' 时，"任务不存在" 这种正常情况也会抛异常。
    # 这里局部降级为 Continue，只依据退出码判断。
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& schtasks.exe @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    return @{ ExitCode = $exitCode; Text = (($output | Out-String).Trim()) }
}

# ---------------------------------------------------------------------------
# 路径与运行身份
# ---------------------------------------------------------------------------

$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)
$daemonScript = Join-Path $InstallDir 'daemon.mjs'
$daemonWrapper = Join-Path $InstallDir 'scripts\Start-Daemon.ps1'
$overlayExe = Join-Path $InstallDir 'RunBubbleOverlay.exe'

$missing = New-Object System.Collections.Generic.List[string]
if (-not (Test-Path -LiteralPath $daemonScript)) { $missing.Add($daemonScript) }
if (-not (Test-Path -LiteralPath $daemonWrapper)) { $missing.Add($daemonWrapper) }
if (-not (Test-Path -LiteralPath $overlayExe)) { $missing.Add($overlayExe) }
if (-not (Test-Path -LiteralPath $NodePath)) { $missing.Add($NodePath) }
if ($missing.Count -gt 0) {
    Write-Host 'Install-Tasks: 安装目录不完整，缺少以下文件：' -ForegroundColor Red
    foreach ($path in $missing) { Write-Host ("  - {0}" -f $path) }
    Write-Host '下一步: 重新运行 run-bubble.ps1 install（它会先构建并复制全部文件）。'
    exit 1
}

if ([string]::IsNullOrWhiteSpace($UserId)) {
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        if ($null -ne $identity -and -not [string]::IsNullOrWhiteSpace($identity.Name)) {
            $UserId = $identity.Name
        }
    }
    catch { }
    if ([string]::IsNullOrWhiteSpace($UserId)) {
        $domain = Get-EnvValue 'USERDOMAIN'
        $userName = Get-EnvValue 'USERNAME'
        if (-not [string]::IsNullOrWhiteSpace($domain)) {
            $UserId = ('{0}\{1}' -f $domain, $userName)
        }
        else {
            $UserId = $userName
        }
    }
}

if ([string]::IsNullOrWhiteSpace($UserId)) {
    Write-Host 'Install-Tasks: 无法确定当前用户身份，不能注册登录触发的计划任务。' -ForegroundColor Red
    exit 1
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

$psExe = Resolve-PowerShellExe

# daemon 由 pwsh 包装器启动（隐藏窗口 + stdout/stderr 落盘）；overlay 直接起 exe。
$daemonArguments = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Node "{1}"' -f $daemonWrapper, $NodePath)
$daemonDescription = 'dsh-run-bubble 采集守护进程（node daemon.mjs）'
$overlayDescription = 'dsh-run-bubble 置顶气泡 overlay（RunBubbleOverlay.exe）'

# ---------------------------------------------------------------------------
# 计划任务读写助手（容错：不存在是正常情况）
# ---------------------------------------------------------------------------

function Test-TaskExists {
    param([string]$TaskName)
    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($null -ne $task) { return $true }
    }
    catch { }
    $queryResult = Invoke-Schtasks -Arguments @('/query', '/tn', $TaskName)
    return ($queryResult.ExitCode -eq 0)
}

function Get-TaskState {
    param([string]$TaskName)
    try { return (Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop) }
    catch { return $null }
}

function Remove-ExistingTask {
    param([string]$TaskName)
    if (-not (Test-TaskExists -TaskName $TaskName)) { return }
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
    }
    catch {
        $deleteResult = Invoke-Schtasks -Arguments @('/delete', '/tn', $TaskName, '/f')
        if ($deleteResult.ExitCode -ne 0) {
            throw ("无法删除已存在的计划任务 {0}: {1}" -f $TaskName, $deleteResult.Text)
        }
    }
    if (Test-TaskExists -TaskName $TaskName) {
        throw ("计划任务 {0} 删除后仍然存在。" -f $TaskName)
    }
}

function ConvertTo-XmlText {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return [System.Security.SecurityElement]::Escape($Text)
}

# ---------------------------------------------------------------------------
# 后端 A：ScheduledTasks 模块（契约要求的 cmdlet 参数）
# ---------------------------------------------------------------------------

function Register-TaskWithCmdlets {
    param(
        [string]$TaskName,
        [string]$Executable,
        [string]$Arguments,
        [string]$WorkingDirectory,
        [string]$Description,
        [bool]$Hidden
    )

    # overlay 任务没有额外参数；-Argument '' 会被 Register-ScheduledTask 拒绝
    # （"Argument 不能为 Null 或空"），所以空参数时要整个省略。
    $actionParameters = @{
        Execute          = $Executable
        WorkingDirectory = $WorkingDirectory
    }
    if (-not [string]::IsNullOrWhiteSpace($Arguments)) {
        $actionParameters['Argument'] = $Arguments
    }
    $action = New-ScheduledTaskAction @actionParameters
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $UserId
    $settingsParameters = @{
        MultipleInstances           = 'IgnoreNew'
        RestartCount                = 999
        RestartInterval             = (New-TimeSpan -Minutes 1)
        ExecutionTimeLimit          = 0
        AllowStartIfOnBatteries     = $true
        DontStopIfGoingOnBatteries  = $true
    }
    if ($Hidden) { $settingsParameters['Hidden'] = $true }
    $settings = New-ScheduledTaskSettingsSet @settingsParameters
    $principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType Interactive -RunLevel Limited
    $definition = New-ScheduledTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description $Description
    Register-ScheduledTask -TaskName $TaskName -InputObject $definition -Force -ErrorAction Stop | Out-Null
}

# ---------------------------------------------------------------------------
# 后端 B：schtasks.exe + 任务 XML（与后端 A 的设置逐项等价）
# ---------------------------------------------------------------------------

$taskXmlTemplate = @'
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>{{DESCRIPTION}}</Description>
    <URI>\{{TASK_NAME}}</URI>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>{{USER_ID}}</UserId>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>{{USER_ID}}</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>true</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>{{HIDDEN}}</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>999</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>{{COMMAND}}</Command>
      <Arguments>{{ARGUMENTS}}</Arguments>
      <WorkingDirectory>{{WORKING_DIR}}</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
'@

function Register-TaskWithXml {
    param(
        [string]$TaskName,
        [string]$Executable,
        [string]$Arguments,
        [string]$WorkingDirectory,
        [string]$Description,
        [bool]$Hidden
    )

    $hiddenText = 'false'
    if ($Hidden) { $hiddenText = 'true' }

    $xml = $taskXmlTemplate
    $xml = $xml.Replace('{{DESCRIPTION}}', (ConvertTo-XmlText $Description))
    $xml = $xml.Replace('{{TASK_NAME}}', (ConvertTo-XmlText $TaskName))
    $xml = $xml.Replace('{{USER_ID}}', (ConvertTo-XmlText $UserId))
    $xml = $xml.Replace('{{HIDDEN}}', $hiddenText)
    $xml = $xml.Replace('{{COMMAND}}', (ConvertTo-XmlText $Executable))
    $xml = $xml.Replace('{{ARGUMENTS}}', (ConvertTo-XmlText $Arguments))
    $xml = $xml.Replace('{{WORKING_DIR}}', (ConvertTo-XmlText $WorkingDirectory))

    $xmlPath = Join-Path ([System.IO.Path]::GetTempPath()) ('dsh-run-bubble-task-' + [guid]::NewGuid().ToString('N') + '.xml')
    Set-Content -LiteralPath $xmlPath -Value $xml -Encoding Unicode
    try {
        $createResult = Invoke-Schtasks -Arguments @('/create', '/xml', $xmlPath, '/tn', $TaskName, '/f')
    }
    finally {
        Remove-Item -LiteralPath $xmlPath -Force -ErrorAction SilentlyContinue
    }
    if ($createResult.ExitCode -ne 0) {
        throw ("schtasks.exe /create 失败（退出码 {0}）: {1}" -f $createResult.ExitCode, $createResult.Text)
    }
}

# ---------------------------------------------------------------------------
# 注册单个任务：cmdlet 优先，失败自动回退 XML
# ---------------------------------------------------------------------------

function Install-OneTask {
    param(
        [string]$TaskName,
        [string]$Executable,
        [string]$Arguments,
        [string]$WorkingDirectory,
        [string]$Description,
        [bool]$Hidden
    )

    Remove-ExistingTask -TaskName $TaskName

    $backend = 'ScheduledTasks cmdlet'
    $cmdletError = ''
    try {
        Register-TaskWithCmdlets -TaskName $TaskName -Executable $Executable -Arguments $Arguments -WorkingDirectory $WorkingDirectory -Description $Description -Hidden $Hidden
    }
    catch {
        $cmdletError = $_.Exception.Message
        $backend = 'schtasks.exe XML 回退'
        Register-TaskWithXml -TaskName $TaskName -Executable $Executable -Arguments $Arguments -WorkingDirectory $WorkingDirectory -Description $Description -Hidden $Hidden
    }

    if (-not (Test-TaskExists -TaskName $TaskName)) {
        throw ("计划任务 {0} 注册后不存在（后端: {1}）。" -f $TaskName, $backend)
    }

    $task = Get-TaskState -TaskName $TaskName
    Write-Host ("  已注册: {0}（后端: {1}）" -f $TaskName, $backend) -ForegroundColor Green
    if (-not [string]::IsNullOrWhiteSpace($cmdletError)) {
        Write-WarnLine ("    注意: Register-ScheduledTask 不可用（{0}），已使用等价的 schtasks XML。" -f $cmdletError)
    }
    Write-Host ("    目标: {0} {1}" -f $Executable, $Arguments)
    if ($null -ne $task) {
        $settings = $task.Settings
        $principal = $task.Principal
        Write-Host ("    登录触发 / 用户={0} / 运行级别={1} / 多实例={2}" -f $principal.UserId, $principal.RunLevel, $settings.MultipleInstances)
        Write-Host ("    失败重启: 每 {0}，最多 {1} 次 / 时限={2} / 隐藏={3}" -f $settings.RestartInterval, $settings.RestartCount, $settings.ExecutionTimeLimit, $settings.Hidden)
    }
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

Write-Host '注册 dsh-run-bubble 计划任务...' -ForegroundColor Cyan
Write-Host ("  安装目录: {0}" -f $InstallDir)
Write-Host ("  启动器  : {0}" -f $psExe)
Write-Host ("  node    : {0}" -f $NodePath)
Write-Host ("  用户    : {0}" -f $UserId)

Install-OneTask -TaskName $DaemonTaskName -Executable $psExe -Arguments $daemonArguments -WorkingDirectory $InstallDir -Description $daemonDescription -Hidden $false
Install-OneTask -TaskName $OverlayTaskName -Executable $overlayExe -Arguments '' -WorkingDirectory $InstallDir -Description $overlayDescription -Hidden $true

Write-Host '计划任务注册完成。' -ForegroundColor Green
exit 0
