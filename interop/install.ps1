#Requires -Version 5.1
<#
.SYNOPSIS
  Install the dsh-chat interop shim for DeepSeek Harness (Windows).

.DESCRIPTION
  Windows equivalent of interop/install.sh. It:
    1. copies dsh-chat.mjs and SKILL.md to %USERPROFILE%\.dsh\interop
    2. writes dsh-chat.cmd (and dsh-chat.ps1 unless -NoPs1Shim) to
       %LOCALAPPDATA%\dsh-run-bubble\bin
    3. adds that bin directory to the *User* PATH (idempotent, de-duplicated)

  It never requests administrator rights and never touches the machine-wide
  PATH. PATH changes only affect new terminals; reopen your terminal after
  installing.

.PARAMETER Uninstall
  Remove the installed shims and the bin directory from the User PATH. The
  copied scripts under ~\.dsh\interop are kept unless -Purge is also given.

.PARAMETER Purge
  With -Uninstall, also delete %USERPROFILE%\.dsh\interop.

.PARAMETER DryRun
  Print the full plan (files and PATH diff) without changing anything.

.PARAMETER NoPathUpdate
  Copy files but do not modify the User PATH.

.PARAMETER NoPs1Shim
  Do not install dsh-chat.ps1. Useful when the PowerShell execution policy
  blocks local scripts; dsh-chat.cmd keeps working in every shell.

.PARAMETER Dest
  Override the script copy location (default: ~\.dsh\interop).

.PARAMETER BinDir
  Override the shim/PATH location (default: %LOCALAPPDATA%\dsh-run-bubble\bin).

.EXAMPLE
  pwsh -NoProfile -File interop\install.ps1
.EXAMPLE
  pwsh -NoProfile -File interop\install.ps1 -DryRun
.EXAMPLE
  pwsh -NoProfile -File interop\install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
  [switch] $Uninstall,
  [switch] $Purge,
  [switch] $DryRun,
  [switch] $NoPathUpdate,
  [switch] $NoPs1Shim,
  [string] $Dest,
  [string] $BinDir
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-HomeDirectory {
  $profileDir = [Environment]::GetFolderPath('UserProfile')
  if ($profileDir) { return $profileDir }
  if ($env:USERPROFILE) { return $env:USERPROFILE }
  return $HOME
}

function Find-NodeExecutable {
  $candidates = New-Object 'System.Collections.Generic.List[string]'
  if ($env:DSH_NODE) { $candidates.Add($env:DSH_NODE) }
  $command = Get-Command node -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($command -and $command.Source) { $candidates.Add($command.Source) }
  if ($env:ProgramFiles) { $candidates.Add((Join-Path $env:ProgramFiles 'nodejs\node.exe')) }
  $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
  if ($programFilesX86) { $candidates.Add((Join-Path $programFilesX86 'nodejs\node.exe')) }
  if ($env:LOCALAPPDATA) { $candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe')) }
  foreach ($candidate in $candidates) {
    if (-not $candidate) { continue }
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return (Resolve-Path -LiteralPath $candidate).Path
    }
  }
  return $null
}

function Get-NodeMajorVersion {
  param([string] $NodePath)
  try {
    $output = & $NodePath --version 2>$null
    if ($output -match '^v(\d+)\.') { return [int] $Matches[1] }
  } catch { }
  return 0
}

function Normalize-PathEntry {
  param([string] $Entry)
  $value = $Entry.Trim()
  if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) {
    $value = $value.Substring(1, $value.Length - 2)
  }
  while ($value.Length -gt 3 -and $value.EndsWith('\')) {
    $value = $value.Substring(0, $value.Length - 1)
  }
  if ($value -match '^[A-Za-z]:$') { $value = $value + '\' }
  return $value
}

function Update-PathList {
  param(
    [AllowNull()] [string] $Current,
    [Parameter(Mandatory = $true)] [string] $Directory,
    [switch] $Remove
  )
  if ($null -eq $Current) { $Current = '' }
  $target = Normalize-PathEntry $Directory
  $entries = New-Object 'System.Collections.Generic.List[string]'
  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  $present = $false
  $duplicates = 0
  foreach ($raw in ($Current -split ';')) {
    $entry = $raw.Trim()
    if (-not $entry) { continue }
    $normalized = Normalize-PathEntry $entry
    if ($normalized -ieq $target) {
      $present = $true
      if ($Remove) { continue }
    }
    if (-not $seen.Add($normalized)) {
      $duplicates += 1
      continue
    }
    $entries.Add($entry)
  }
  $added = $false
  if (-not $Remove -and -not $present) {
    $entries.Add($Directory)
    $added = $true
  }
  $newPath = ($entries -join ';')
  return [pscustomobject]@{
    Path             = $newPath
    Present          = $present
    Added            = $added
    Removed          = ($Remove -and $present)
    DuplicatesRemoved = $duplicates
    Changed          = ($newPath -ne $Current)
  }
}

function Write-PathPlan {
  param($Plan, [string] $Current, [switch] $VerbosePath)
  if ($Plan.Removed) {
    Write-Host "PATH (User): remove $BinDir"
  } elseif ($Plan.Added) {
    Write-Host "PATH (User): add $BinDir"
  } elseif ($Plan.Present) {
    Write-Host "PATH (User): $BinDir already present (no change)"
  } else {
    Write-Host "PATH (User): $BinDir not present (no change needed)"
  }
  if ($Plan.DuplicatesRemoved -gt 0) {
    Write-Host "PATH (User): de-duplicated $($Plan.DuplicatesRemoved) duplicate path entry/entries"
  }
  if ($VerbosePath) {
    $previous = $Current
    if (-not $previous) { $previous = '<empty>' }
    Write-Host ''
    Write-Host 'Previous User PATH:'
    Write-Host "  $previous"
    Write-Host 'New User PATH:'
    Write-Host "  $($Plan.Path)"
    Write-Host ''
  }
}

function Write-TextFile {
  param(
    [string] $Path,
    [string] $Content,
    [switch] $Bom,
    [switch] $Crlf
  )
  $text = $Content
  if ($Crlf) { $text = ($text -replace "`r?`n", "`r`n") }
  $encoding = New-Object System.Text.UTF8Encoding([bool] $Bom)
  [System.IO.File]::WriteAllText($Path, $text, $encoding)
}

function Test-AsciiOnly {
  param([string] $Value)
  foreach ($character in $Value.ToCharArray()) {
    if ([int] $character -gt 127) { return $false }
  }
  return $true
}

# cmd.exe parses .cmd files with the OEM code page, so UTF-8 (or ANSI) Chinese
# paths embedded in a batch file get mangled. Generated batch files therefore
# stay pure ASCII: the script is copied next to the shim (%~dp0) and node.exe is
# referenced through environment variables such as %ProgramFiles%.
function ConvertTo-NodeBatchToken {
  param([string] $NodePath)
  $roots = @(
    @{ Name = 'ProgramFiles'; Value = $env:ProgramFiles },
    @{ Name = 'ProgramFiles(x86)'; Value = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)') },
    @{ Name = 'LOCALAPPDATA'; Value = $env:LOCALAPPDATA },
    @{ Name = 'USERPROFILE'; Value = $env:USERPROFILE }
  )
  foreach ($root in $roots) {
    if (-not $root.Value) { continue }
    $prefix = $root.Value.TrimEnd('\')
    if ($NodePath.StartsWith($prefix + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
      return '%' + $root.Name + '%' + $NodePath.Substring($prefix.Length)
    }
  }
  if (Test-AsciiOnly $NodePath) { return $NodePath }
  return 'node'
}

function ConvertTo-SingleQuotedLiteral {
  param([string] $Value)
  return $Value.Replace("'", "''")
}

function New-CmdShimContent {
  param([string] $NodeToken)
  $template = @'
@echo off
rem Generated by dsh-run-bubble interop/install.ps1. Do not edit.
rem Self-contained: dsh-chat.mjs lives next to this shim (%~dp0).
rem UTF-8 console so Chinese titles/prompts are not garbled; restored on exit.
setlocal EnableExtensions
for /f "tokens=2 delims=:" %%A in ('chcp') do set "DSH_CHAT_OLDCP=%%A"
if defined DSH_CHAT_OLDCP set "DSH_CHAT_OLDCP=%DSH_CHAT_OLDCP: =%"
chcp 65001 >nul 2>&1
if defined DSH_NODE (
  "%DSH_NODE%" "%~dp0dsh-chat.mjs" %*
) else (
  "__NODE__" "%~dp0dsh-chat.mjs" %*
)
set "DSH_CHAT_CODE=%ERRORLEVEL%"
if defined DSH_CHAT_OLDCP chcp %DSH_CHAT_OLDCP% >nul 2>&1
exit /b %DSH_CHAT_CODE%
'@
  # __NODE__ may itself contain %VAR% expansions; do not escape those percents.
  return $template.Replace('__NODE__', $NodeToken)
}

function New-Ps1ShimContent {
  param([string] $NodePath)
  $node = ConvertTo-SingleQuotedLiteral $NodePath
  $template = @'
# Generated by dsh-run-bubble interop/install.ps1. Do not edit.
# Self-contained: dsh-chat.mjs lives next to this shim.
try {
  [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
  $OutputEncoding = New-Object System.Text.UTF8Encoding($false)
} catch { }
$node = if ($env:DSH_NODE) { $env:DSH_NODE } else { '__NODE__' }
if (-not (Test-Path -LiteralPath $node -PathType Leaf)) {
  $node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty Source
}
if (-not $node) {
  [Console]::Error.WriteLine('dsh-chat: node.exe not found. Set DSH_NODE or install Node.js 20+.')
  exit 127
}
& $node (Join-Path $PSScriptRoot 'dsh-chat.mjs') @args
exit $LASTEXITCODE
'@
  return $template.Replace('__NODE__', $node)
}

# ---------------------------------------------------------------------------
# Resolve locations
# ---------------------------------------------------------------------------

$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$sourceScript = Join-Path $scriptDir 'dsh-chat.mjs'
$sourceSkill = Join-Path $scriptDir 'SKILL.md'

$homeDir = Get-HomeDirectory
if (-not $Dest) { $Dest = Join-Path $homeDir '.dsh\interop' }
if (-not $BinDir) {
  if ($env:LOCALAPPDATA) { $BinDir = Join-Path $env:LOCALAPPDATA 'dsh-run-bubble\bin' }
  else { $BinDir = Join-Path $homeDir 'AppData\Local\dsh-run-bubble\bin' }
}
$Dest = [System.IO.Path]::GetFullPath($Dest)
$BinDir = [System.IO.Path]::GetFullPath($BinDir)

$currentUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')

# Test hook: -DryRun can simulate a User PATH without reading it back.
if ($DryRun -and $null -ne $env:DSH_INSTALL_DRYRUN_USER_PATH) {
  $currentUserPath = $env:DSH_INSTALL_DRYRUN_USER_PATH
}
if ($null -eq $currentUserPath) { $currentUserPath = '' }

$pathPlan = Update-PathList -Current $currentUserPath -Directory $BinDir -Remove:$Uninstall
$shimFiles = @(
  (Join-Path $BinDir 'dsh-chat.cmd'),
  (Join-Path $BinDir 'dsh-chat.ps1'),
  (Join-Path $BinDir 'dsh-chat.mjs')
)

Write-Host ''
Write-Host 'dsh-chat interop installer (Windows)'

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

if ($Uninstall) {
  if ($DryRun) { Write-Host 'Mode: dry run for -Uninstall (nothing will be changed)' }
  Write-Host "shim dir:  $BinDir"
  foreach ($file in $shimFiles) {
    if (Test-Path -LiteralPath $file) {
      if ($DryRun) { Write-Host "would remove: $file" }
      else { Remove-Item -LiteralPath $file -Force; Write-Host "removed: $file" }
    }
  }
  if ($Purge) {
    if (Test-Path -LiteralPath $Dest) {
      if ($DryRun) { Write-Host "would remove: $Dest" }
      else { Remove-Item -LiteralPath $Dest -Recurse -Force; Write-Host "removed: $Dest" }
    }
  } else {
    Write-Host "kept: $Dest (add -Purge to remove)"
  }
  if ($NoPathUpdate) {
    Write-Host 'PATH (User): skipped (-NoPathUpdate)'
  } else {
    Write-PathPlan -Plan $pathPlan -Current $currentUserPath -VerbosePath:$DryRun
    if (-not $DryRun -and $pathPlan.Changed) {
      [Environment]::SetEnvironmentVariable('Path', $pathPlan.Path, 'User')
      Write-Host 'PATH (User): updated'
    }
  }
  # Remove the now-empty bin directory if this installer created it.
  if (-not $DryRun -and (Test-Path -LiteralPath $BinDir)) {
    $remaining = @(Get-ChildItem -LiteralPath $BinDir -Force)
    if ($remaining.Count -eq 0) {
      Remove-Item -LiteralPath $BinDir -Force
      Write-Host "removed empty dir: $BinDir"
    }
  }
  if (-not $DryRun) { Write-Host ''; Write-Host 'Done. If the dsh-chat command still resolves, reopen your terminal.' }
  exit 0
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

$nodeExe = Find-NodeExecutable
if (-not $nodeExe) {
  Write-Host 'ERROR: node.exe was not found (PATH, %ProgramFiles%\nodejs, %LOCALAPPDATA%\Programs\nodejs).' -ForegroundColor Red
  Write-Host '       Install Node.js 20+ or set DSH_NODE to node.exe, then run this script again.' -ForegroundColor Red
  exit 1
}
$nodeMajor = Get-NodeMajorVersion -NodePath $nodeExe
if ($nodeMajor -gt 0 -and $nodeMajor -lt 20) {
  Write-Host "WARNING: Node $nodeMajor.x found; Node 20+ is recommended." -ForegroundColor Yellow
}

Write-Host "node:      $nodeExe"
Write-Host "source:    $scriptDir"
Write-Host "dest:      $Dest"
Write-Host "shim dir:  $BinDir"

if ($DryRun) {
  Write-Host 'Mode: dry run (nothing will be changed)'
  Write-Host ''
  Write-Host "would copy: $sourceScript -> $Dest\dsh-chat.mjs"
  Write-Host "would copy: $sourceSkill -> $Dest\SKILL.md"
  Write-Host "would copy: $sourceScript -> $(Join-Path $BinDir 'dsh-chat.mjs') (shim copy)"
  Write-Host "would write: $(Join-Path $BinDir 'dsh-chat.cmd') (ASCII, CRLF, UTF-8 console)"
  if ($NoPs1Shim) { Write-Host 'would skip: dsh-chat.ps1 (-NoPs1Shim)' }
  else { Write-Host "would write: $(Join-Path $BinDir 'dsh-chat.ps1')" }
  if ($NoPathUpdate) {
    Write-Host 'PATH (User): skipped (-NoPathUpdate)'
  } else {
    Write-PathPlan -Plan $pathPlan -Current $currentUserPath -VerbosePath
    if ($pathPlan.Changed) {
      Write-Host 'PATH (User): would be updated'
    } else {
      Write-Host 'PATH (User): already up to date'
    }
  }
  Write-Host ''
  Write-Host 'No changes were made. Re-run without -DryRun to install.'
  exit 0
}

foreach ($required in @($sourceScript)) {
  if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
    Write-Host "ERROR: missing $required (run this script from the interop directory)." -ForegroundColor Red
    exit 1
  }
}

if (-not (Test-Path -LiteralPath $Dest -PathType Container)) {
  New-Item -ItemType Directory -Path $Dest -Force | Out-Null
}
Copy-Item -LiteralPath $sourceScript -Destination (Join-Path $Dest 'dsh-chat.mjs') -Force
Write-Host "installed: $(Join-Path $Dest 'dsh-chat.mjs')"
if (Test-Path -LiteralPath $sourceSkill -PathType Leaf) {
  Copy-Item -LiteralPath $sourceSkill -Destination (Join-Path $Dest 'SKILL.md') -Force
  Write-Host "skill:     $(Join-Path $Dest 'SKILL.md')"
}

if (-not (Test-Path -LiteralPath $BinDir -PathType Container)) {
  New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
}
# Keep a self-contained script copy next to the shim: the .cmd can then use
# %~dp0 and stays pure ASCII no matter where the user profile lives.
$shimScript = Join-Path $BinDir 'dsh-chat.mjs'
Copy-Item -LiteralPath $sourceScript -Destination $shimScript -Force
$nodeToken = ConvertTo-NodeBatchToken -NodePath $nodeExe
if ($nodeToken -eq 'node' -and -not (Get-Command node -CommandType Application -ErrorAction SilentlyContinue)) {
  Write-Host 'WARNING: node.exe is not on PATH; dsh-chat.cmd could not embed its absolute path.' -ForegroundColor Yellow
  Write-Host '         Set DSH_NODE or add Node.js to PATH.' -ForegroundColor Yellow
}
$cmdShim = Join-Path $BinDir 'dsh-chat.cmd'
Write-TextFile -Path $cmdShim -Content (New-CmdShimContent -NodeToken $nodeToken) -Crlf
Write-Host "shim:      $cmdShim"
if (-not $NoPs1Shim) {
  $ps1Shim = Join-Path $BinDir 'dsh-chat.ps1'
  Write-TextFile -Path $ps1Shim -Content (New-Ps1ShimContent -NodePath $nodeExe) -Bom
  Write-Host "shim:      $ps1Shim"
}
Write-Host "script:    $shimScript (shim copy)"

if ($NoPathUpdate) {
  Write-Host 'PATH (User): skipped (-NoPathUpdate)'
  Write-Host "To use it manually: $BinDir\dsh-chat.cmd"
} else {
  Write-PathPlan -Plan $pathPlan -Current $currentUserPath
  if ($pathPlan.Changed) {
    [Environment]::SetEnvironmentVariable('Path', $pathPlan.Path, 'User')
    Write-Host 'PATH (User): updated'
  } else {
    Write-Host 'PATH (User): already up to date'
  }
  $env:Path = "$BinDir;$env:Path"
}

Write-Host ''
Write-Host 'Installed. Reopen your terminal (or log off/on) so the updated User PATH is loaded.'
Write-Host 'Try:  dsh-chat --help'
Write-Host '      dsh-chat ask --source codex --title "Auth refactor" "Reply with exactly: HELLO"'
exit 0
