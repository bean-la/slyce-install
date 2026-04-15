#!/usr/bin/env pwsh
# Install the `slyce` CLI from the release CDN.
#
# Stable one-liner (tracks main; pin a commit SHA in production if you need immutability):
# irm https://raw.githubusercontent.com/bean-la/slyce-install/main/install-slyce.ps1 | iex
#
# Or with a custom base URL:
# $env:SLYCE_RELEASE_BASE_URL = "https://example.com"; irm ... | iex
#
# Installs to $env:INSTALL_DIR (default: $HOME/.local/bin). Ensure that directory is on PATH.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-SlycePlatform {
  if ($IsWindows) { return "win32" }
  if ($IsMacOS) { return "darwin" }
  if ($IsLinux) { return "linux" }
  throw "install-slyce: unsupported platform."
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
    throw "install-slyce: empty checksum file."
  }

  $candidate = ($raw.Trim() -split "\s+")[0].ToLowerInvariant()
  if ($candidate -notmatch "^[a-f0-9]{64}$") {
    throw "install-slyce: invalid checksum format."
  }
  return $candidate
}

function Ensure-InstallDirOnPath {
  param([Parameter(Mandatory = $true)][string]$InstallDir)

  if (-not $IsWindows) {
    return
  }

  $normalized = $InstallDir.TrimEnd("\")
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  $entries = @()
  if (-not [string]::IsNullOrWhiteSpace($userPath)) {
    $entries = $userPath -split ";"
  }

  $present = $false
  foreach ($entry in $entries) {
    if ([string]::IsNullOrWhiteSpace($entry)) {
      continue
    }
    if ($entry.TrimEnd("\") -ieq $normalized) {
      $present = $true
      break
    }
  }

  if (-not $present) {
    $newUserPath = if ([string]::IsNullOrWhiteSpace($userPath)) {
      $InstallDir
    }
    else {
      $userPath.TrimEnd(";") + ";" + $InstallDir
    }

    [Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")
    Write-Host "install-slyce: added $InstallDir to user PATH"
  }
  else {
    Write-Host "install-slyce: $InstallDir already present in user PATH"
  }

  $sessionEntries = $env:Path -split ";"
  $sessionPresent = $false
  foreach ($entry in $sessionEntries) {
    if ([string]::IsNullOrWhiteSpace($entry)) {
      continue
    }
    if ($entry.TrimEnd("\") -ieq $normalized) {
      $sessionPresent = $true
      break
    }
  }
  if (-not $sessionPresent) {
    $env:Path = if ([string]::IsNullOrWhiteSpace($env:Path)) {
      $InstallDir
    }
    else {
      $env:Path.TrimEnd(";") + ";" + $InstallDir
    }
  }
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

$installDir = if ($env:INSTALL_DIR) {
  $env:INSTALL_DIR
}
elseif ($HOME) {
  Join-Path $HOME ".local/bin"
}
else {
  Join-Path $env:USERPROFILE ".local/bin"
}

$platform = Get-SlycePlatform
$arch = Get-SlyceArch
$latestUrl = "$base/slyce/$platform/$arch/latest.json"

Write-Host "install-slyce: reading $latestUrl"

$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("slyce-install-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmpDir | Out-Null

try {
  $latestPath = Join-Path $tmpDir "latest.json"
  Invoke-WebRequest -Uri $latestUrl -OutFile $latestPath

  $latest = Get-Content -Path $latestPath -Raw | ConvertFrom-Json
  if (-not $latest.version -or $latest.version -isnot [string]) {
    throw "install-slyce: latest.json is missing a valid version."
  }
  $version = $latest.version

  $ext = if ($platform -eq "win32") { ".exe" } else { "" }
  $binUrl = "$base/slyce/$platform/$arch/$version/slyce$ext"
  Write-Host "install-slyce: downloading $binUrl"

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
    Write-Host "install-slyce: verifying SHA-256"
    $expected = Read-ExpectedChecksum -Path $tmpSum
    $actual = (Get-FileHash -Path $tmpBin -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($expected -ne $actual) {
      throw "install-slyce: checksum mismatch (expected $expected, got $actual)"
    }
  }
  else {
    Write-Host "install-slyce: no .sha256 sidecar found; skipping checksum verify"
  }

  New-Item -ItemType Directory -Path $installDir -Force | Out-Null
  $targetPath = Join-Path $installDir "slyce$ext"
  Move-Item -Path $tmpBin -Destination $targetPath -Force

  if (-not $IsWindows) {
    & chmod +x $targetPath
  }
  else {
    Ensure-InstallDirOnPath -InstallDir $installDir
  }

  Write-Host "install-slyce: installed to $targetPath"
  Write-Host "install-slyce: ensure $installDir is on your PATH"
}
finally {
  if (Test-Path -Path $tmpDir) {
    Remove-Item -Path $tmpDir -Recurse -Force
  }
}
