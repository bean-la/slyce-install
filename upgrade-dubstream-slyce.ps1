# Upgrade Slyce CLI — dubstream Win10
# Run this on the dubstream box via Tailnet SSH/RDP.
# It upgrades the slyce CLI from main-legacy (worker-v2.0.x) to current (slyce-v3.3.x),
# backs up the old binary, and provides a one-command revert.

$ErrorActionPreference = "Stop"
$script:logFile = "$env:TEMP\slyce-upgrade-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

function Log($msg) {
    $timestamp = Get-Date -Format "HH:mm:ss"
    $line = "[$timestamp] $msg"
    Write-Host $line
    Add-Content -Path $script:logFile -Value $line
}

# ── 1. Locate the slyce CLI ──────────────────────────────────────────────────
Log "Looking for slyce CLI..."

# Common install locations
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
    Log "ERROR: Could not find slyce.exe. Check PATH or known locations."
    exit 1
}

Log "Found slyce at: $slycePath"

# ── 2. Check current version ─────────────────────────────────────────────────
$currentVersion = & $slycePath --version 2>&1 | Select-Object -First 1
Log "Current version: $currentVersion"

# ── 3. Backup the current binary ─────────────────────────────────────────────
$backupPath = "$slycePath.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Copy-Item -Path $slycePath -Destination $backupPath -Force
Log "Backed up to: $backupPath"

# ── 4. Run the upgrade ───────────────────────────────────────────────────────
Log "Running: slyce upgrade..."
$upgrade = & $slycePath upgrade 2>&1
Log "Upgrade output: $upgrade"

# Check if the upgrade staged a new binary
$stagedPath = $slycePath -replace '\.exe$', '.update.exe'
if (Test-Path $stagedPath) {
    Log "New CLI staged at: $stagedPath"
    Log "Waiting for swap (powerShell defer script)..."
    Start-Sleep -Seconds 5
}

# ── 5. Verify the new version ────────────────────────────────────────────────
# After upgrade, the swap happens on next cold start of slyce.exe.
# Force a quick version probe (may still show old version if swap didn't run)
$newVersion = & $slycePath --version 2>&1 | Select-Object -First 1
Log "Post-upgrade version: $newVersion"

if ($newVersion -match '3\.\d+\.\d+') {
    Log "SUCCESS: Upgraded to slyce v3.x"
} elseif (Test-Path $stagedPath) {
    Log "Swap pending. The new binary is staged. Run 'slyce version' after a restart."
    Log "To force the swap now, run:"
    Log "  Stop-Process -Name slyce -Force -ErrorAction SilentlyContinue"
    Log "  Start-Sleep 2"
    Log "  & $slycePath --version"
} else {
    Log "WARNING: Version doesn't look like slyce v3.x. Check manually."
}

# ── 6. Print revert instructions ─────────────────────────────────────────────
$backupName = Split-Path $backupPath -Leaf
$slyceDir = Split-Path $slycePath -Parent
$slyceName = Split-Path $slycePath -Leaf

Log ""
Log "═══════════════════════════════════════════════════"
Log "  REVERT INSTRUCTIONS"
Log "═══════════════════════════════════════════════════"
Log "  If something breaks, restore the backup:"
Log ""
Log "    Copy-Item '$backupPath' '$slycePath' -Force"
Log ""
Log "  Or from File Explorer, rename:"
Log "    $backupName → $slyceName"
Log "    (in $slyceDir)"
Log ""
Log "═══════════════════════════════════════════════════"
Log "Log saved to: $script:logFile"
