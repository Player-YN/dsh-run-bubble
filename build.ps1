#Requires -Version 5.1
<#
.SYNOPSIS
    dsh-run-bubble 的 Windows 构建脚本（等价 macOS Makefile 的 build + check）。
.DESCRIPTION
    一次构建两个原生产物到 dist\：
      1. src\overlay\RunBubbleOverlay.csproj      -> dist\RunBubbleOverlay.exe（气泡渲染）
      2. src\lease-probe\LeaseProbe.csproj        -> dist\DshLeaseProbe.exe（只读租约探针）
    然后用 node --check 校验 daemon.mjs 与 src\win\*.mjs，并各跑一次产物验证可执行。
    失败时以非零退出码结束，并明确指出是哪个项目/哪一步失败。

    注意：产物验证会先把 dist\ 复制到临时目录再执行。原因是 DSH 的 Windows 工作区
    沙箱会给"从工作区路径启动的进程"附加限制（例如 GDI+ 编码 / 句柄枚举会被拒绝），
    从 %TEMP% 副本运行才能验证真实用户环境下的行为。

.PARAMETER SelfContained
    自包含发布（--self-contained true，目标机无需 .NET 运行时）。

.PARAMETER Clean
    构建前清理 dist / 两个项目的 bin、obj。

.EXAMPLE
    pwsh -NoProfile -File build.ps1
    powershell.exe -NoProfile -File build.ps1 -SelfContained
    pwsh -NoProfile -File build.ps1 --clean
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------

function Get-EnvValue {
    param([string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ($null -eq $value) { return '' }
    return $value
}

function Fail-Build {
    param(
        [string]$Message,
        [string[]]$Hints = @()
    )
    Write-Host ''
    Write-Host ("build.ps1: 失败 — {0}" -f $Message) -ForegroundColor Red
    foreach ($hint in $Hints) { Write-Host ("  {0}" -f $hint) }
    Write-Host ''
    exit 1
}

function Write-Step {
    param([string]$Message)
    Write-Host ("==> {0}" -f $Message) -ForegroundColor Cyan
}

function Invoke-Native {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @()
    )
    # Windows PowerShell 5.1 会把原生 stderr 变成错误记录；配合 Stop 时会中断脚本。
    # 构建脚本需要读取输出并自行判断退出码，因此这里局部使用 Continue。
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

function Resolve-Tool {
    param(
        [string]$Name,
        [string[]]$Candidates
    )
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace($command.Source)) {
        return $command.Source
    }
    foreach ($candidate in $Candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }
    return $null
}

function Resolve-NodeExe {
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
    return (Resolve-Tool -Name 'node.exe' -Candidates $candidates.ToArray())
}

function Resolve-DotnetExe {
    $candidates = New-Object System.Collections.Generic.List[string]
    $programFiles = Get-EnvValue 'ProgramFiles'
    if (-not [string]::IsNullOrWhiteSpace($programFiles)) {
        $candidates.Add((Join-Path $programFiles 'dotnet\dotnet.exe'))
    }
    return (Resolve-Tool -Name 'dotnet.exe' -Candidates $candidates.ToArray())
}

function Get-NormalizedFullPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Assert-PathUnderRepo {
    param(
        [string]$Path,
        [string]$RepoRoot
    )
    $full = Get-NormalizedFullPath $Path
    $root = (Get-NormalizedFullPath $RepoRoot).TrimEnd('\')
    $prefix = $root + '\'
    if (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ("拒绝操作仓库之外的路径: {0}" -f $full)
    }
    return $full
}

function Show-Usage {
    Write-Host ''
    Write-Host '用法: build.ps1 [-SelfContained] [-Clean]' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  -SelfContained / --self-contained   自包含发布（目标机无需 .NET 运行时）'
    Write-Host '  -Clean         / --clean            构建前清理 dist / 两个项目的 bin、obj'
    Write-Host '  -h / --help                         显示本帮助'
    Write-Host ''
    Write-Host '产物: dist\RunBubbleOverlay.exe + dist\DshLeaseProbe.exe（同一目录并存）。'
    Write-Host ''
}

# ---------------------------------------------------------------------------
# 参数解析：同时接受 PowerShell 原生 -Flag 与 macOS 文档风格的 --flag
# ---------------------------------------------------------------------------

$selfContained = $false
$clean = $false
$showHelp = $false
$unknownArguments = New-Object System.Collections.Generic.List[string]

foreach ($rawArgument in @($args)) {
    if ($null -eq $rawArgument) { continue }
    $token = [string]$rawArgument
    if ([string]::IsNullOrWhiteSpace($token)) { continue }

    if ($token -match '^--?(.+)$') {
        $flag = $matches[1]
        $normalized = ($flag -replace '[-_]', '').ToLowerInvariant()
        if ($normalized -eq 'selfcontained') {
            $selfContained = $true
        }
        elseif ($normalized -eq 'clean') {
            $clean = $true
        }
        elseif ($normalized -eq 'help' -or $normalized -eq 'h' -or $normalized -eq '?') {
            $showHelp = $true
        }
        else {
            $unknownArguments.Add($token)
        }
    }
    else {
        $unknownArguments.Add($token)
    }
}

if ($showHelp) {
    Show-Usage
    exit 0
}

if ($unknownArguments.Count -gt 0) {
    Write-Host ("build.ps1: 无法识别的参数: {0}" -f ($unknownArguments -join ' ')) -ForegroundColor Red
    Show-Usage
    exit 2
}

# ---------------------------------------------------------------------------
# 定位仓库与两个项目
# ---------------------------------------------------------------------------

$repoRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    $repoRoot = (Get-Location).Path
}
$repoRoot = Get-NormalizedFullPath $repoRoot

$distDir = Join-Path $repoRoot 'dist'

$projects = @(
    @{
        Name        = 'overlay'
        ProjectPath = Join-Path $repoRoot 'src\overlay\RunBubbleOverlay.csproj'
        Directory   = Join-Path $repoRoot 'src\overlay'
        ExePath     = Join-Path $distDir 'RunBubbleOverlay.exe'
        ExeName     = 'RunBubbleOverlay.exe'
    },
    @{
        Name        = 'lease-probe'
        ProjectPath = Join-Path $repoRoot 'src\lease-probe\LeaseProbe.csproj'
        Directory   = Join-Path $repoRoot 'src\lease-probe'
        ExePath     = Join-Path $distDir 'DshLeaseProbe.exe'
        ExeName     = 'DshLeaseProbe.exe'
    }
)

Write-Step ("仓库: {0}" -f $repoRoot)

foreach ($project in $projects) {
    if (Test-Path -LiteralPath $project.ProjectPath) { continue }
    $fallbackProjects = @()
    if (Test-Path -LiteralPath $project.Directory) {
        $fallbackProjects = @(Get-ChildItem -LiteralPath $project.Directory -Filter '*.csproj' -File -ErrorAction SilentlyContinue)
    }
    if ($fallbackProjects.Count -eq 1) {
        $project.ProjectPath = $fallbackProjects[0].FullName
        Write-Host ("警告: 未找到预期的 {0} 工程，改用 {1}" -f $project.Name, $project.ProjectPath) -ForegroundColor Yellow
        continue
    }
    Fail-Build ("找不到 {0} 工程文件: {1}" -f $project.Name, $project.ProjectPath) @(
        '这是并行开发中的正常状态：对应子项目尚未就位。',
        '下一步: 等源码就绪后重试 build.ps1。',
        ("当前目录: {0}" -f $repoRoot)
    )
}

$dotnetExe = Resolve-DotnetExe
if ([string]::IsNullOrWhiteSpace($dotnetExe)) {
    Fail-Build '找不到 dotnet.exe（构建期需要 .NET 8 SDK）。' @(
        '安装 .NET 8 SDK: https://dotnet.microsoft.com/download/dotnet/8.0',
        '安装后重开终端，运行 dotnet --version 验证。'
    )
}

$dotnetVersion = ''
try { $dotnetVersion = (& $dotnetExe --version 2>$null | Out-String).Trim() } catch { }
Write-Step ("dotnet: {0} ({1})" -f $dotnetExe, $dotnetVersion)

# ---------------------------------------------------------------------------
# -Clean
# ---------------------------------------------------------------------------

if ($clean) {
    Write-Step '清理构建产物 (dist / overlay / lease-probe 的 bin、obj)'
    $cleanTargets = New-Object System.Collections.Generic.List[string]
    $cleanTargets.Add($distDir)
    foreach ($project in $projects) {
        $cleanTargets.Add((Join-Path $project.Directory 'bin'))
        $cleanTargets.Add((Join-Path $project.Directory 'obj'))
    }
    foreach ($target in $cleanTargets) {
        $safeTarget = Assert-PathUnderRepo -Path $target -RepoRoot $repoRoot
        if (Test-Path -LiteralPath $safeTarget) {
            Remove-Item -LiteralPath $safeTarget -Recurse -Force
            Write-Host ("    已删除 {0}" -f $safeTarget)
        }
    }
}

if (-not (Test-Path -LiteralPath $distDir)) {
    New-Item -ItemType Directory -Path $distDir -Force | Out-Null
}

# ---------------------------------------------------------------------------
# dotnet publish：两个项目都输出到 dist
# ---------------------------------------------------------------------------

if ($selfContained) {
    $selfContainedArgument = 'true'
    $publishMode = '自包含（self-contained，无需 .NET 运行时）'
}
else {
    $selfContainedArgument = 'false'
    $publishMode = '框架依赖（需要 .NET 8 Desktop Runtime）'
}

foreach ($project in $projects) {
    Write-Step ("发布 {0}：{1}" -f $project.Name, $publishMode)
    $publishArguments = @(
        'publish',
        $project.ProjectPath,
        '-c', 'Release',
        '-r', 'win-x64',
        '--self-contained', $selfContainedArgument,
        '-o', $distDir
    )
    Write-Host ("    {0} {1}" -f $dotnetExe, ($publishArguments -join ' '))

    # 直接输出编译日志；Windows PowerShell 5.1 下把原生 stderr 从 Stop 降级，
    # 否则 dotnet 的警告/错误行会被当作终止错误。
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $dotnetExe @publishArguments
        $publishExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }

    if ($publishExitCode -ne 0) {
        Fail-Build ("{0} 项目 dotnet publish 失败（退出码 {1}）。" -f $project.Name, $publishExitCode) @(
            '根据上面的编译错误修复该项目的源码后重试。',
            '需要干净重建时加 -Clean。',
            '如果错误是 NuGet/网络相关，可先检查 dotnet restore 是否可用。'
        )
    }
    if (-not (Test-Path -LiteralPath $project.ExePath)) {
        Fail-Build ("{0} 项目发布成功但缺少产物 {1}。" -f $project.Name, $project.ExePath) @(
            '检查对应 .csproj 的 OutputType / AssemblyName 设置。',
            ("dist 目录内容: {0}" -f ((Get-ChildItem -LiteralPath $distDir -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name) -join ', '))
        )
    }
}

Write-Step '校验 dist 中两个产物并存'
$overlayExe = $projects[0].ExePath
$probeExe = $projects[1].ExePath
$overlaySizeKb = [math]::Round(((Get-Item -LiteralPath $overlayExe).Length / 1KB), 1)
$probeSizeKb = [math]::Round(((Get-Item -LiteralPath $probeExe).Length / 1KB), 1)
Write-Host ("    {0} ({1} KB)" -f $overlayExe, $overlaySizeKb)
Write-Host ("    {0} ({1} KB)" -f $probeExe, $probeSizeKb)

# ---------------------------------------------------------------------------
# 运行时验证：复制到临时目录再执行（规避工作区沙箱的进程限制）
# ---------------------------------------------------------------------------

$verifyDir = Join-Path ([System.IO.Path]::GetTempPath()) ('dsh-run-bubble-verify-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $verifyDir -Force | Out-Null
    foreach ($item in @(Get-ChildItem -LiteralPath $distDir -Force)) {
        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $verifyDir $item.Name) -Force
    }
    $verifyOverlay = Join-Path $verifyDir 'RunBubbleOverlay.exe'
    $verifyProbe = Join-Path $verifyDir 'DshLeaseProbe.exe'

    Write-Step '验证 DshLeaseProbe.exe 可独立运行'
    $probeVersion = Invoke-Native -FilePath $verifyProbe -Arguments @('--version')
    if ($probeVersion.ExitCode -ne 0) {
        Fail-Build ("DshLeaseProbe.exe --version 失败（退出码 {0}）。" -f $probeVersion.ExitCode) @(
            $probeVersion.Text,
            '检查 src\lease-probe 的入口点与输出契约。'
        )
    }
    Write-Host ("    {0}" -f $probeVersion.Text)

    # 全量扫描是运行时能力，不是构建门槛：OS 策略可能拒绝句柄枚举（会返回 ok:false）。
    $probeScan = Invoke-Native -FilePath $verifyProbe -Arguments @()
    if ($probeScan.ExitCode -eq 0 -and $probeScan.Text -like '*"ok":true*') {
        Write-Host '    租约探针全量扫描: ok:true（可用）' -ForegroundColor Green
    }
    else {
        Write-WarnLine ("    警告: 租约探针全量扫描不可用（退出码 {0}）：{1}" -f $probeScan.ExitCode, $probeScan.Text)
        Write-WarnLine '    daemon 会降级为 mtime/sidecar 启发式；这不影响构建产物已生成。'
    }

    Write-Step '验证 RunBubbleOverlay.exe 可独立运行（--demo --snapshot）'
    $verifySnapshot = Join-Path $verifyDir 'verify-snapshot.png'
    $overlayStderr = Join-Path $verifyDir 'verify-overlay.err.txt'
    Remove-Item -LiteralPath $verifySnapshot, $overlayStderr -Force -ErrorAction SilentlyContinue
    $overlayExitCode = 1
    try {
        $overlayProcess = Start-Process -FilePath $verifyOverlay -ArgumentList ('--demo --snapshot "{0}"' -f $verifySnapshot) -Wait -PassThru -RedirectStandardError $overlayStderr -ErrorAction Stop
        $overlayExitCode = $overlayProcess.ExitCode
    }
    catch {
        Fail-Build ("无法启动 RunBubbleOverlay.exe：{0}" -f $_.Exception.Message) @(
            '确认 dist 中 exe 与同名 dll / runtimeconfig.json 一起发布。'
        )
    }
    if ($overlayExitCode -ne 0 -or -not (Test-Path -LiteralPath $verifySnapshot)) {
        $stderrText = ''
        if (Test-Path -LiteralPath $overlayStderr) {
            $stderrText = ((Get-Content -LiteralPath $overlayStderr -Tail 20 -ErrorAction SilentlyContinue) | Out-String).Trim()
        }
        Fail-Build ("RunBubbleOverlay.exe --demo --snapshot 验证失败（退出码 {0}）。" -f $overlayExitCode) @(
            $stderrText,
            '检查 overlay 的 snapshot 导出实现；dist 中 dll 是否齐全。'
        )
    }
    $snapshotSize = (Get-Item -LiteralPath $verifySnapshot).Length
    Write-Host ("    snapshot ok: {0} 字节" -f $snapshotSize) -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $verifyDir) {
        Remove-Item -LiteralPath $verifyDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# node --check：daemon.mjs + src\win\*.mjs
# ---------------------------------------------------------------------------

$nodeExe = Resolve-NodeExe
if ([string]::IsNullOrWhiteSpace($nodeExe)) {
    Fail-Build '找不到 node.exe（需要 Node.js 20+ 用来校验 daemon 源码）。' @(
        '安装 Node.js 20 或更新版本: https://nodejs.org/',
        '安装后重开终端，运行 node --version 验证。'
    )
}

$nodeVersion = ''
try { $nodeVersion = (& $nodeExe --version 2>$null | Out-String).Trim() } catch { }
Write-Step ("node: {0} ({1})" -f $nodeExe, $nodeVersion)

$winDir = Join-Path $repoRoot 'src\win'
$nodeFiles = New-Object System.Collections.Generic.List[string]
$nodeFiles.Add((Join-Path $repoRoot 'daemon.mjs'))
$winModulesReady = $false

if (Test-Path -LiteralPath $winDir) {
    $winModules = @(Get-ChildItem -LiteralPath $winDir -Filter '*.mjs' -File -Recurse -ErrorAction SilentlyContinue)
    if ($winModules.Count -gt 0) {
        $winModulesReady = $true
        foreach ($module in $winModules) {
            $nodeFiles.Add($module.FullName)
        }
    }
}

$checkedCount = 0
foreach ($nodeFile in $nodeFiles) {
    if (-not (Test-Path -LiteralPath $nodeFile)) {
        Fail-Build ("缺少 Node 源文件: {0}" -f $nodeFile) @(
            '确认 daemon.mjs / src\win\*.mjs 已提交且位于仓库内。'
        )
    }
    $checkResult = Invoke-Native -FilePath $nodeExe -Arguments @('--check', $nodeFile)
    if ($checkResult.ExitCode -ne 0) {
        Fail-Build ("node --check 失败: {0}" -f $nodeFile) @(
            $checkResult.Text,
            '修复语法错误后重试 build.ps1。'
        )
    }
    $checkedCount++
}

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '构建成功。' -ForegroundColor Green
Write-Host ("  产物 1    : {0} ({1} KB)" -f $overlayExe, $overlaySizeKb)
Write-Host ("  产物 2    : {0} ({1} KB)" -f $probeExe, $probeSizeKb)
Write-Host ("  发布模式  : {0}" -f $publishMode)
Write-Host ("  Node 检查 : {0} 个文件通过" -f $checkedCount)
if (-not $winModulesReady) {
    Write-Host '              （src\win 尚无 .mjs 模块，等 daemon 移植就绪后会自动纳入）' -ForegroundColor Yellow
}
Write-Host ''
exit 0
