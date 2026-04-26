#!/usr/bin/env pwsh
# Install the `slyce` CLI from the release CDN.
#
# Stable one-liner (tracks main; pin a commit SHA in production if you need immutability):
# irm https://raw.githubusercontent.com/bean-la/slyce-install/main/install-slyce.ps1 | iex
#
# Or with a custom base URL:
# $env:SLYCE_RELEASE_BASE_URL = "https://example.com"; irm ... | iex
#
# Installs to $env:INSTALL_DIR (default: runtime root bin directory).
# Windows: C:\ProgramData\Slyce\bin
# macOS: ~/Library/Application Support/Slyce/bin
# Linux: /var/lib/slyce/bin

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

function Get-DefaultInstallDir {
  if ($env:INSTALL_DIR) {
    return $env:INSTALL_DIR
  }
  if ($IsWindows) {
    $programData = if ($env:ProgramData) { $env:ProgramData } else { "C:\ProgramData" }
    return Join-Path $programData "Slyce\bin"
  }
  if ($IsMacOS) {
    return Join-Path $HOME "Library/Application Support/Slyce/bin"
  }
  return "/var/lib/slyce/bin"
}

function Remove-LegacyUserScopedSlyceBinaries {
  if (-not $IsWindows) {
    return
  }
  $legacyCandidates = @(
    (Join-Path $HOME ".local\bin\slyce.exe"),
    (Join-Path $HOME ".local\bin\slyce.new.exe"),
    (Join-Path $HOME ".slyce\bin\slyce.exe"),
    (Join-Path $HOME ".slyce\bin\slyce.new.exe")
  )
  foreach ($candidate in $legacyCandidates) {
    if (Test-Path -Path $candidate) {
      try {
        Remove-Item -Path $candidate -Force
        Write-Host "install-slyce: removed legacy user binary $candidate"
      }
      catch {
        Write-Host "install-slyce: warning - could not remove legacy user binary $candidate"
      }
    }
  }
}

function Sync-WindowsPathToRuntimeCli {
  param([Parameter(Mandatory = $true)][string]$InstallDir)

  if (-not $IsWindows) {
    return
  }

  $legacyDirs = @(
    (Join-Path $HOME ".local\bin").TrimEnd("\"),
    (Join-Path $HOME ".slyce\bin").TrimEnd("\")
  )
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
  Write-Host "install-slyce: normalized user PATH for runtime CLI directory"
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

$installDir = Get-DefaultInstallDir

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
    Remove-LegacyUserScopedSlyceBinaries
    Sync-WindowsPathToRuntimeCli -InstallDir $installDir
  }
  Write-Host "install-slyce: installed to $targetPath"
}
finally {
  if (Test-Path -Path $tmpDir) {
    Remove-Item -Path $tmpDir -Recurse -Force
  }
}
