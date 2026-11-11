#!/usr/bin/env pwsh
# Validate and repair the persistent SWS root mappings before SWS starts.
# The manifest is written by the runtime bootstrap from the box's Super settings.

param(
  [string]$Root = "C:\ProgramData\Slyce\sws-default-root"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$manifestPath = Join-Path $Root ".sws-mappings.json"
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
  throw "SWS mapping manifest is missing: $manifestPath"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.version -ne 1 -or -not ($manifest.mappings -is [System.Array])) {
  throw "SWS mapping manifest is invalid: $manifestPath"
}

foreach ($mapping in $manifest.mappings) {
  $publicPath = ([string]$mapping.publicPath).Replace('/', '\').Trim('\')
  if ([string]::IsNullOrWhiteSpace($publicPath) -or $publicPath -match '(^|\\)\.\.(\\|$)' -or [IO.Path]::IsPathRooted($publicPath)) {
    throw "SWS mapping has an unsafe public path."
  }

  $target = [IO.Path]::GetFullPath([string]$mapping.localPath)
  if (-not (Test-Path -LiteralPath $target -PathType Container)) {
    throw "SWS mapping target is missing: $target"
  }

  $link = [IO.Path]::GetFullPath((Join-Path $Root $publicPath))
  if (-not $link.StartsWith(([IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) {
    throw "SWS mapping escapes the configured root."
  }

  $parent = Split-Path -Parent $link
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }

  $existing = Get-ChildItem -LiteralPath $parent -Force | Where-Object { $_.Name -ieq (Split-Path -Leaf $link) } | Select-Object -First 1
  if ($null -ne $existing) {
    $item = $existing
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
      throw "Refusing to replace a real directory at SWS mapping path: $link"
    }
    $query = & "$env:SystemRoot\System32\fsutil.exe" reparsepoint query $link 2>$null
    if ($LASTEXITCODE -eq 0) {
      $substituteLine = $query | Select-String 'Substitute Name:' | Select-Object -First 1
      $actual = if ($null -ne $substituteLine) { ($substituteLine.Line -replace '^.*Substitute Name:\s*', '').TrimEnd('\') -replace '^\\\?\?\\', '' } else { '' }
      if ($actual -ieq $target.TrimEnd('\')) { continue }
    }
    & "$env:SystemRoot\System32\fsutil.exe" reparsepoint delete $link
    if ($LASTEXITCODE -ne 0) { throw "Could not remove stale SWS reparse point: $link" }
    [IO.Directory]::Delete($link, $false)
  } elseif (Test-Path -LiteralPath $link) {
    throw "SWS mapping path exists and is not a directory junction: $link"
  }

  New-Item -ItemType Junction -Path $link -Target $target | Out-Null
  if (-not (Test-Path -LiteralPath $link -PathType Container)) {
    throw "SWS mapping failed validation after repair: $link"
  }
}

Write-Output "Validated $($manifest.mappings.Count) SWS root mappings."
