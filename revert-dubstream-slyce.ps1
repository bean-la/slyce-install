# Revert Slyce CLI — restore from .backup file
# Run this on the dubstream box if the upgrade caused issues.
# Finds the most recent .backup file and restores it.

$ErrorActionPreference = "Stop"

# Locate slyce.exe
$candidates = @(
    "$env:LOCALAPPDATA\Slyce\slyce.exe",
    "$env:ProgramData\Slyce\slyce.exe",
    "$env:ProgramFiles\Slyce\slyce.exe",
    "$env:USERPROFILE\.slyce\slyce.exe",
    (Get-Command "slyce.exe" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
)

$slycePath = $null
foreach ($c in $candidates) {
    if ($c -and (Test-Path $c)) {
        $slycePath = $c
        break
    }
}

if (-not $slycePath) {
    Write-Host "ERROR: Could not find slyce.exe" -ForegroundColor Red
    exit 1
}

$slyceDir = Split-Path $slycePath -Parent

# Find the most recent backup
$backups = Get-ChildItem -Path $slyceDir -Filter "slyce.exe.backup-*" | Sort-Object LastWriteTime -Descending
if ($backups.Count -eq 0) {
    Write-Host "ERROR: No backup files found in $slyceDir" -ForegroundColor Red
    exit 1
}

$latestBackup = $backups[0].FullName
$oldVersion = & $latestBackup --version 2>&1 | Select-Object -First 1
$currentVersion = & $slycePath --version 2>&1 | Select-Object -First 1

Write-Host "Current: $currentVersion" -ForegroundColor Yellow
Write-Host "Restore: $oldVersion (from $latestBackup)" -ForegroundColor Yellow
Write-Host ""

# Check for staged .update.exe and clean it up
$stagedPath = $slycePath -replace '\.exe$', '.update.exe'
if (Test-Path $stagedPath) {
    Write-Host "Removing staged update: $stagedPath" -ForegroundColor DarkYellow
    Remove-Item $stagedPath -Force
}

# Also clean up .old if present
$oldPath = "$slycePath.old"
if (Test-Path $oldPath) {
    Remove-Item $oldPath -Force
}

# Restore
Copy-Item -Path $latestBackup -Destination $slycePath -Force
Write-Host "Restored: $slycePath" -ForegroundColor Green

$verify = & $slycePath --version 2>&1 | Select-Object -First 1
Write-Host "Verified: $verify" -ForegroundColor Green
