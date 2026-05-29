#!/usr/bin/env pwsh
# Unified Windows recovery helper:
# - Default: repair/upgrade in place
# - Optional hard reset: wipe runtime dirs then reinstall/repair/restart
#
# Usage:
#   irm https://raw.githubusercontent.com/bean-la/slyce-install/main/recover-slyce.ps1 | iex
#
# Optional envs (set before running):
#   $env:SLYCE_RECOVER_CHANNEL = "prod"   # or "staging"
#   $env:SLYCE_RECOVER_WIPE = "1"         # hard reset mode

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$isWindowsPlatform = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
if (-not $isWindowsPlatform) {
  throw "recover-slyce: this helper currently targets Windows hosts only."
}

function Get-Channel {
  $raw = [string]$env:SLYCE_RECOVER_CHANNEL
  if ([string]::IsNullOrWhiteSpace($raw)) { return "prod" }
  $v = $raw.Trim().ToLowerInvariant()
  if ($v -eq "staging") { return "staging" }
  return "prod"
}

function Get-WipeMode {
  $raw = [string]$env:SLYCE_RECOVER_WIPE
  if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
  return @("1", "true", "yes", "y").Contains($raw.Trim().ToLowerInvariant())
}

function Try-RunSlyce {
  param([Parameter(Mandatory = $true)][string[]]$Args)
  if (-not (Get-Command slyce -ErrorAction SilentlyContinue)) { return }
  try { & slyce @Args } catch { Write-Host "recover-slyce: slyce $($Args -join ' ') failed: $($_.Exception.Message)" }
}

function Stop-SlyceServicesBestEffort {
  $names = @("SlyceCloudflared", "SlyceStaticWebServer", "SlyceMediaMTX", "SlyceWorker", "SlycePlane")
  foreach ($name in $names) {
    try { Stop-Service -Name $name -Force -ErrorAction SilentlyContinue } catch {}
  }
}

function Wipe-RuntimeDirs {
  $root = if ($env:ProgramData) { Join-Path $env:ProgramData "Slyce" } else { "C:\ProgramData\Slyce" }
  $targets = @(
    (Join-Path $root "current"),
    (Join-Path $root "releases"),
    (Join-Path $root "sws-default-root"),
    (Join-Path $root "logs")
  )
  foreach ($target in $targets) {
    if (Test-Path -Path $target) {
      try {
        Remove-Item -Path $target -Recurse -Force
        Write-Host "recover-slyce: removed $target"
      } catch {
        Write-Host "recover-slyce: warning - failed to remove $target"
      }
    }
  }
}

$channel = Get-Channel
$wipe = Get-WipeMode
$installScript = if ($channel -eq "staging") {
  "https://raw.githubusercontent.com/bean-la/slyce-install/main/install-slyce-staging.ps1"
} else {
  "https://raw.githubusercontent.com/bean-la/slyce-install/main/install-slyce.ps1"
}

Write-Host "recover-slyce: channel=$channel"
Write-Host "recover-slyce: wipe=$wipe"

$env:WORKER_UPDATE_CHANNEL = $channel

if (Get-Command slyce -ErrorAction SilentlyContinue) {
  try {
    $before = (& slyce version 2>$null | Select-Object -First 1)
    if ($before) { Write-Host "recover-slyce: current slyce version=$before" }
  } catch {}
}

Stop-SlyceServicesBestEffort
if ($wipe) {
  Wipe-RuntimeDirs
}

Write-Host "recover-slyce: running installer..."
Invoke-Expression ((Invoke-RestMethod -Uri $installScript))

Try-RunSlyce -Args @("upgrade")
Try-RunSlyce -Args @("service", "repair")
Try-RunSlyce -Args @("restart")

if (Get-Command slyce -ErrorAction SilentlyContinue) {
  try {
    $after = (& slyce version 2>$null | Select-Object -First 1)
    if ($after) { Write-Host "recover-slyce: final slyce version=$after" }
  } catch {}
}

Write-Host "recover-slyce: complete."
