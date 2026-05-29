#!/usr/bin/env pwsh
# Slyce doctor helper for Windows-focused runtime recovery.
#
# One-liner:
# powershell -NoProfile -ExecutionPolicy Bypass -Command "$IsWindows=$true; irm https://raw.githubusercontent.com/bean-la/slyce-install/main/doctor-slyce.ps1 | iex"
#
# Optional channel override:
# $env:SLYCE_DOCTOR_CHANNEL = "prod"

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:IsWindowsPlatform = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)

if (-not $script:IsWindowsPlatform) {
  throw "doctor-slyce: this helper currently targets Windows hosts."
}

$doctorChannel = if ($env:SLYCE_DOCTOR_CHANNEL -and $env:SLYCE_DOCTOR_CHANNEL.Trim()) {
  $env:SLYCE_DOCTOR_CHANNEL.Trim().ToLowerInvariant()
}
else {
  "prod"
}

$installScript = if ($doctorChannel -eq "staging") {
  "https://raw.githubusercontent.com/bean-la/slyce-install/main/install-slyce-staging.ps1"
}
else {
  "https://raw.githubusercontent.com/bean-la/slyce-install/main/install-slyce.ps1"
}

Write-Host "doctor-slyce: channel=$doctorChannel"
Write-Host "doctor-slyce: install-script=$installScript"

if (-not (Get-Command slyce -ErrorAction SilentlyContinue)) {
  Write-Host "doctor-slyce: slyce command not found yet (will install now)."
}
else {
  try {
    $beforeVersion = (& slyce version 2>$null | Select-Object -First 1)
    if ($beforeVersion) {
      Write-Host "doctor-slyce: current slyce version=$beforeVersion"
    }
  }
  catch {
    Write-Host "doctor-slyce: current version check failed; continuing."
  }
}

# Ensure runtime upgrade checks point at selected channel for follow-up upgrades.
$env:WORKER_UPDATE_CHANNEL = $doctorChannel

Write-Host "doctor-slyce: running installer..."
Invoke-Expression ((Invoke-RestMethod -Uri $installScript))

if (Get-Command slyce -ErrorAction SilentlyContinue) {
  try {
    Write-Host "doctor-slyce: running slyce upgrade..."
    & slyce upgrade
  }
  catch {
    Write-Host "doctor-slyce: slyce upgrade failed: $($_.Exception.Message)"
  }

  try {
    Write-Host "doctor-slyce: running slyce service repair..."
    & slyce service repair
  }
  catch {
    Write-Host "doctor-slyce: slyce service repair failed: $($_.Exception.Message)"
  }

  try {
    Write-Host "doctor-slyce: running slyce restart..."
    & slyce restart
  }
  catch {
    Write-Host "doctor-slyce: slyce restart failed: $($_.Exception.Message)"
  }

  try {
    $afterVersion = (& slyce version 2>$null | Select-Object -First 1)
    if ($afterVersion) {
      Write-Host "doctor-slyce: final slyce version=$afterVersion"
    }
  }
  catch {
    Write-Host "doctor-slyce: final version check failed."
  }
}
else {
  Write-Host "doctor-slyce: slyce command still missing after install."
}

Write-Host "doctor-slyce: complete."
