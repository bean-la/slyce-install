#!/usr/bin/env pwsh
# Install the `slyce` CLI from the **staging** release channel on the CDN
# (same layout as WORKER_UPDATE_CHANNEL=staging: slyce/staging/<platform>/<arch>/...).
#
# Staging one-liner (tracks main of this repo; pin a commit SHA if you need immutability):
# irm https://raw.githubusercontent.com/bean-la/slyce-install/main/install-slyce-staging.ps1 | iex
#
# Or with a custom base URL (still uses the staging channel prefix):
# $env:SLYCE_RELEASE_BASE_URL = "https://example.com"; irm ... | iex
#
# Production / flat channel installer (no `staging` path segment):
# irm https://raw.githubusercontent.com/bean-la/slyce-install/main/install-slyce.ps1 | iex
#
# Installs to $env:INSTALL_DIR (default: runtime root bin directory).
# Windows: C:\ProgramData\Slyce\bin
# macOS: ~/Library/Application Support/Slyce/bin
# Linux: /var/lib/slyce/bin

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:IsWindowsPlatform = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
$script:IsMacOSPlatform = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)
$script:IsLinuxPlatform = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Linux)

function Get-SlycePlatform {
  if ($script:IsWindowsPlatform) { return "win32" }
  if ($script:IsMacOSPlatform) { return "darwin" }
  if ($script:IsLinuxPlatform) { return "linux" }
  throw "install-slyce-staging: unsupported platform."
}

function Get-SlyceArch {
  $arch = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
  switch ($arch) {
    "x64" { return "x64" }
    "arm64" { return "arm64" }
    default { return $arch }
  }
}

function Read-ExpectedChecksum {
  param([Parameter(Mandatory = $true)][string]$Path)
  $raw = Get-Content -Path $Path -Raw
  if ([string]::IsNullOrWhiteSpace($raw)) {
    throw "install-slyce-staging: empty checksum file."
  }

  $candidate = ($raw.Trim() -split "\s+")[0].ToLowerInvariant()
  if ($candidate -notmatch "^[a-f0-9]{64}$") {
    throw "install-slyce-staging: invalid checksum format."
  }
  return $candidate
}

function Get-DefaultInstallDir {
  if ($env:INSTALL_DIR) {
    return $env:INSTALL_DIR
  }
  if ($script:IsWindowsPlatform) {
    $programData = if ($env:ProgramData) { $env:ProgramData } else { "C:\ProgramData" }
    return Join-Path $programData "Slyce\bin"
  }
  if ($script:IsMacOSPlatform) {
    return Join-Path $HOME "Library/Application Support/Slyce/bin"
  }
  return "/var/lib/slyce/bin"
}

function Remove-LegacyUserScopedSlyceBinaries {
  if (-not $script:IsWindowsPlatform) {
    return
  }
  $homeDir = [string]$HOME
  $legacyCandidates = @(
    "$homeDir\.local\bin\slyce.exe",
    "$homeDir\.local\bin\slyce.new.exe",
    "$homeDir\.slyce\bin\slyce.exe",
    "$homeDir\.slyce\bin\slyce.new.exe"
  )
  foreach ($candidate in $legacyCandidates) {
    if (Test-Path -Path $candidate) {
      try {
        Remove-Item -Path $candidate -Force
        Write-Host "install-slyce-staging: removed legacy user binary $candidate"
      }
      catch {
        Write-Host "install-slyce-staging: warning - could not remove legacy user binary $candidate"
      }
    }
  }
}

function Sync-WindowsPathToRuntimeCli {
  param([Parameter(Mandatory = $true)][string]$InstallDir)

  if (-not $script:IsWindowsPlatform) {
    return
  }

  $homeDir = [string]$HOME
  $legacyDirs = @("$homeDir\.local\bin", "$homeDir\.slyce\bin") |
    ForEach-Object { $_.TrimEnd("\") }
  $normalizedInstall = $InstallDir.TrimEnd("\")
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  $entries = @()
  if (-not [string]::IsNullOrWhiteSpace($userPath)) {
    $entries = $userPath -split ";"
  }

  $filtered = New-Object System.Collections.Generic.List[string]
  $hasInstall = $false
  foreach ($entry in $entries) {
    if ([string]::IsNullOrWhiteSpace($entry)) { continue }
    $normalizedEntry = $entry.TrimEnd("\")
    if ($legacyDirs -contains $normalizedEntry) {
      continue
    }
    if ($normalizedEntry -ieq $normalizedInstall) {
      $hasInstall = $true
    }
    $filtered.Add($entry)
  }

  if (-not $hasInstall) {
    $filtered.Insert(0, $InstallDir)
  }

  $newUserPath = ($filtered -join ";")
  [Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")
  $env:Path = $newUserPath
  Write-Host "install-slyce-staging: normalized user PATH for runtime CLI directory"
}

$base = if ($env:SLYCE_RELEASE_BASE_URL) {
  $env:SLYCE_RELEASE_BASE_URL
}
elseif ($env:WORKER_UPDATE_BASE_URL) {
  $env:WORKER_UPDATE_BASE_URL
}
else {
  "https://slyce.moiste.la"
}

$slyceRoot = "slyce/staging"

$installDir = Get-DefaultInstallDir

$platform = Get-SlycePlatform
$arch = Get-SlyceArch
$latestUrl = "$base/$slyceRoot/$platform/$arch/latest.json"

Write-Host "install-slyce-staging: reading $latestUrl"

$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("slyce-install-staging-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmpDir | Out-Null

try {
  $latestPath = Join-Path $tmpDir "latest.json"
  Invoke-WebRequest -Uri $latestUrl -OutFile $latestPath

  $latest = Get-Content -Path $latestPath -Raw | ConvertFrom-Json
  if (-not $latest.version -or $latest.version -isnot [string]) {
    throw "install-slyce-staging: latest.json is missing a valid version."
  }
  $version = $latest.version

  $ext = if ($platform -eq "win32") { ".exe" } else { "" }
  $binUrl = "$base/$slyceRoot/$platform/$arch/$version/slyce$ext"
  Write-Host "install-slyce-staging: downloading $binUrl"

  $tmpBin = Join-Path $tmpDir "slyce$ext"
  Invoke-WebRequest -Uri $binUrl -OutFile $tmpBin

  $tmpSum = Join-Path $tmpDir "slyce.sha256"
  $hasChecksum = $true
  try {
    Invoke-WebRequest -Uri "$binUrl.sha256" -OutFile $tmpSum
  }
  catch {
    $hasChecksum = $false
  }

  if ($hasChecksum -and (Test-Path -Path $tmpSum) -and ((Get-Item -Path $tmpSum).Length -gt 0)) {
    Write-Host "install-slyce-staging: verifying SHA-256"
    $expected = Read-ExpectedChecksum -Path $tmpSum
    $actual = (Get-FileHash -Path $tmpBin -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($expected -ne $actual) {
      throw "install-slyce-staging: checksum mismatch (expected $expected, got $actual)"
    }
  }
  else {
    Write-Host "install-slyce-staging: no .sha256 sidecar found; skipping checksum verify"
  }

  New-Item -ItemType Directory -Path $installDir -Force | Out-Null
  $targetPath = Join-Path $installDir "slyce$ext"
  if (Test-Path -Path $targetPath) {
    try {
      Remove-Item -Path $targetPath -Force
    }
    catch {
      throw "install-slyce-staging: could not replace existing binary at $targetPath. It may be in use by another process. Close Slyce processes and retry."
    }
  }
  Move-Item -Path $tmpBin -Destination $targetPath -Force

  if (-not $script:IsWindowsPlatform) {
    & chmod +x $targetPath
  }
  else {
    Remove-LegacyUserScopedSlyceBinaries
    Sync-WindowsPathToRuntimeCli -InstallDir $installDir
  }
  Write-Host "install-slyce-staging: installed staging-channel CLI to $targetPath"
}
finally {
  if (Test-Path -Path $tmpDir) {
    Remove-Item -Path $tmpDir -Recurse -Force
  }
}
