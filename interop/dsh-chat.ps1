#!/usr/bin/env pwsh
# dsh-chat Windows entry point (PowerShell).
# Equivalent to dsh-chat.cmd: forwards arguments (including paths with spaces
# and non-ASCII text), preserves the native exit code, and emits UTF-8.
[CmdletBinding()]
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]] $Arguments
)

try {
  [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
  $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
} catch {
  # Older hosts can refuse to change the console encoding; keep going.
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$node = $env:DSH_NODE
if (-not $node) {
  $command = Get-Command node -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($command) { $node = $command.Source }
}
if (-not $node) {
  [Console]::Error.WriteLine('dsh-chat: node.exe not found on PATH. Install Node.js 20+ or set DSH_NODE to node.exe.')
  exit 127
}

& $node (Join-Path $scriptDir 'dsh-chat.mjs') @Arguments
exit $LASTEXITCODE
